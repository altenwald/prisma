%% @doc Extracts types, structs, specs, and AST clauses from Elixir BEAM debug_info.
%%
%% Translates `{elixir_v1, Map, Specs}` chunks directly into Erlang Abstract Format
%% so Elixir modules can be analyzed even without the Elixir runtime loaded.
-module(spectra_elixir).

-include("spectra.hrl").

-export([
    from_elixir_dbgi/4,
    to_abstract_forms/3
]).

%% @doc Builds a `#module_summary{}` from an Elixir `debug_info_v1` chunk.
-spec from_elixir_dbgi(module(), term(), [{atom(), arity()}], #module_summary{}) ->
    #module_summary{}.
from_elixir_dbgi(Mod, {debug_info_v1, elixir_erl, {elixir_v1, Map, SpecsForms}}, Exports, Summary)
  when is_map(Map), is_list(SpecsForms) ->
    Forms = to_abstract_forms(Mod, Map, SpecsForms),
    spectra_abstract:parse_abstract_forms(Forms, Exports, Summary);
from_elixir_dbgi(_Mod, _Dbgi, Exports, #module_summary{module = Mod} = Summary) ->
    Funcs = maps:from_list([
        {{Mod, F, A}, #func_contract{mfa = {Mod, F, A}, exported = true}}
        || {F, A} <- Exports
    ]),
    Summary#module_summary{functions = Funcs}.

%% @doc Converts an Elixir `elixir_v1` metadata map and specs list into Erlang Abstract Format forms.
-spec to_abstract_forms(module(), map(), [term()]) -> [term()].
to_abstract_forms(Mod, Map, SpecsForms) ->
    StructForms = extract_struct_forms(Mod, maps:get(struct, Map, nil), SpecsForms),
    Defs = maps:get(definitions, Map, []),
    FunForms = lists:append([
        translate_definition(Def)
        || {{_F, _A}, Kind, _Meta, _Clauses} = Def <- Defs,
           Kind =:= def orelse Kind =:= defp
    ]),
    SpecsForms ++ StructForms ++ FunForms.

extract_struct_forms(Mod, StructFields, SpecsForms) when is_list(StructFields) ->
    HasExplicitT = lists:any(
        fun
            ({attribute, _, Kind, {t, _, []}}) when Kind =:= type; Kind =:= opaque -> true;
            (_) -> false
        end,
        SpecsForms
    ),
    case HasExplicitT of
        true ->
            [];
        false ->
            Anno = erl_anno:new(1),
            FieldAsts = lists:filtermap(
                fun
                    (#{field := '__struct__'}) ->
                        false;
                    (#{field := FieldName}) when is_atom(FieldName) ->
                        {true, {type, Anno, map_field_exact, [{atom, Anno, FieldName}, {type, Anno, any, []}]}};
                    ({FieldName, _Default}) when is_atom(FieldName), FieldName =/= '__struct__' ->
                        {true, {type, Anno, map_field_exact, [{atom, Anno, FieldName}, {type, Anno, any, []}]}};
                    (_) ->
                        false
                end,
                StructFields
            ),
            StructTagAst = {type, Anno, map_field_exact, [{atom, Anno, '__struct__'}, {atom, Anno, Mod}]},
            MapTypeAst = {type, Anno, map, [StructTagAst | FieldAsts]},
            [
                {attribute, Anno, export_type, [{t, 0}]},
                {attribute, Anno, type, {t, MapTypeAst, []}}
            ]
    end;
extract_struct_forms(_Mod, _Struct, _SpecsForms) ->
    [].

translate_definition({{Name, Arity}, _Kind, Meta, Clauses}) when is_list(Clauses) ->
    Anno = meta_anno(Meta),
    ErlClauses = [translate_clause(C, Name) || C <- Clauses],
    FunForm = {function, Anno, Name, Arity, ErlClauses},
    case is_elixir_generated(Name, Meta) of
        true ->
            [{attribute, Anno, compiler_generated, {Name, Arity}}, FunForm];
        false ->
            [FunForm]
    end.

is_elixir_generated(Name, Meta) ->
    case atom_to_list(Name) of
        "__" ++ _ -> true;
        Str ->
            string:str(Str, "overridable") > 0 orelse
            proplists:get_value(context, Meta) =:= elixir_def orelse
            proplists:get_value(generated, Meta) =:= true
    end.

translate_clause({Meta, Args, Guards, Body}, CurrentFun) when is_list(Args), is_list(Guards) ->
    Anno = meta_anno(Meta),
    PatArgs = [translate_pattern(A) || A <- Args],
    ErlGuards = case Guards of
        [] -> [];
        _ -> [[translate_guard(G) || G <- Guards]]
    end,
    ErlBody = translate_body(Body, CurrentFun),
    {clause, Anno, PatArgs, ErlGuards, ErlBody};
translate_clause(_, _CurrentFun) ->
    Anno = erl_anno:new(1),
    {clause, Anno, [], [], [{atom, Anno, ok}]}.

translate_body(Body) ->
    translate_body(Body, undefined).

translate_body({'__block__', _Meta, Exprs}, CurrentFun) when is_list(Exprs), Exprs =/= [] ->
    [translate_expr_with_fun(E, CurrentFun) || E <- Exprs];
translate_body(SingleExpr, CurrentFun) ->
    [translate_expr_with_fun(SingleExpr, CurrentFun)].

translate_expr_with_fun({super, Meta, Args}, CurrentFun) when is_atom(CurrentFun), is_list(Args) ->
    Anno = meta_anno(Meta),
    {call, Anno, {atom, Anno, CurrentFun}, [translate_expr(A) || A <- Args]};
translate_expr_with_fun(Other, _CurrentFun) ->
    translate_expr(Other).

translate_pattern({'_', Meta, Ctx}) when is_atom(Ctx) ->
    {var, meta_anno(Meta), '_'};
translate_pattern({VarName, Meta, Ctx}) when is_atom(VarName), is_atom(Ctx) ->
    {var, meta_anno(Meta), elixir_var(VarName, Meta, Ctx)};
translate_pattern({'^', _Meta, [Inner]}) ->
    translate_pattern(Inner);
translate_pattern({'=', Meta, [P1, P2]}) ->
    {match, meta_anno(Meta), translate_pattern(P1), translate_pattern(P2)};
translate_pattern({'%', Meta, [{'_', _, _}, {'%{}', _, Pairs}]}) when is_list(Pairs) ->
    Anno = meta_anno(Meta),
    TagField = {map_field_exact, Anno, {atom, Anno, '__struct__'}, {var, Anno, '_'}},
    {map, Anno, [TagField | translate_map_pat_pairs(Anno, Pairs)]};
translate_pattern({'%', Meta, [StructModAst, {'%{}', _, Pairs}]}) when is_list(Pairs) ->
    Anno = meta_anno(Meta),
    StructMod = unwrap_atom(StructModAst),
    TagField = {map_field_exact, Anno, {atom, Anno, '__struct__'}, {atom, Anno, StructMod}},
    {map, Anno, [TagField | translate_map_pat_pairs(Anno, Pairs)]};
translate_pattern({'%{}', Meta, Pairs}) when is_list(Pairs) ->
    Anno = meta_anno(Meta),
    {map, Anno, translate_map_pat_pairs(Anno, Pairs)};
translate_pattern({'{}', Meta, Elems}) when is_list(Elems) ->
    {tuple, meta_anno(Meta), [translate_pattern(E) || E <- Elems]};
translate_pattern({A, B}) ->
    Anno = erl_anno:new(1),
    {tuple, Anno, [translate_pattern(A), translate_pattern(B)]};
translate_pattern([{'|', Meta, [H, T]}]) ->
    {cons, meta_anno(Meta), translate_pattern(H), translate_pattern(T)};
translate_pattern(List) when is_list(List) ->
    Anno = erl_anno:new(1),
    lists:foldr(
        fun(E, Acc) -> {cons, Anno, translate_pattern(E), Acc} end,
        {nil, Anno},
        List
    );
translate_pattern(Int) when is_integer(Int) ->
    {integer, erl_anno:new(1), Int};
translate_pattern(Float) when is_float(Float) ->
    {float, erl_anno:new(1), Float};
translate_pattern(Atom) when is_atom(Atom) ->
    {atom, erl_anno:new(1), Atom};
translate_pattern({'<<>>', Meta, _Segments}) ->
    {bin, meta_anno(Meta), []};
translate_pattern(Bin) when is_binary(Bin) ->
    Anno = erl_anno:new(1),
    {bin, Anno, [{bin_element, Anno, {string, Anno, binary_to_list(Bin)}, default, default}]};
translate_pattern(_) ->
    {var, erl_anno:new(1), '_'}.

translate_map_pat_pairs(Anno, Pairs) when is_list(Pairs) ->
    lists:flatmap(
        fun
            ({'|', _, [_Base, InnerPairs]}) when is_list(InnerPairs) ->
                translate_map_pat_pairs(Anno, InnerPairs);
            ({K, V}) ->
                [{map_field_exact, Anno, translate_pattern(K), translate_pattern(V)}];
            (_) ->
                []
        end,
        Pairs
    );
translate_map_pat_pairs(_Anno, _) ->
    [].

translate_guard(Expr) ->
    translate_expr(Expr).

translate_expr({'__block__', _Meta, [Single]}) ->
    translate_expr(Single);
translate_expr({'__block__', Meta, Exprs}) when is_list(Exprs), Exprs =/= [] ->
    {'block', meta_anno(Meta), [translate_expr(E) || E <- Exprs]};
translate_expr({'=', Meta, [Pat, Rhs]}) ->
    {match, meta_anno(Meta), translate_pattern(Pat), translate_expr(Rhs)};
translate_expr({'case', Meta, [Scrutinee, Blocks]}) when is_list(Blocks) ->
    Anno = meta_anno(Meta),
    DoClauses = case proplists:get_value(do, Blocks, []) of
        L when is_list(L) -> L;
        _ -> []
    end,
    {'case', Anno, translate_expr(Scrutinee), [translate_case_clause(C) || C <- DoClauses]};
translate_expr({'%', Meta, [_StructModAst, {'%{}', _, [{'|', _, [Base, Pairs]}]}]}) when is_list(Pairs) ->
    Anno = meta_anno(Meta),
    {map, Anno, translate_expr(Base), translate_map_expr_pairs(Anno, Pairs)};
translate_expr({'%', Meta, [StructModAst, {'%{}', _, Pairs}]}) when is_list(Pairs) ->
    Anno = meta_anno(Meta),
    StructMod = unwrap_atom(StructModAst),
    TagField = {map_field_exact, Anno, {atom, Anno, '__struct__'}, {atom, Anno, StructMod}},
    {map, Anno, [TagField | translate_map_expr_pairs(Anno, Pairs)]};
translate_expr({'%{}', Meta, [{'|', _, [Base, Pairs]}]}) when is_list(Pairs) ->
    Anno = meta_anno(Meta),
    {map, Anno, translate_expr(Base), translate_map_expr_pairs(Anno, Pairs)};
translate_expr({'%{}', Meta, Pairs}) when is_list(Pairs) ->
    Anno = meta_anno(Meta),
    {map, Anno, translate_map_expr_pairs(Anno, Pairs)};
translate_expr({'{}', Meta, Elems}) when is_list(Elems) ->
    {tuple, meta_anno(Meta), [translate_expr(E) || E <- Elems]};
translate_expr({{'.', _, [erlang, Op]}, Meta, [L, R]}) ->
    case is_erl_binop(Op) of
        true ->
            {op, meta_anno(Meta), Op, translate_expr(L), translate_expr(R)};
        false ->
            Anno = meta_anno(Meta),
            {call, Anno, {remote, Anno, {atom, Anno, erlang}, {atom, Anno, Op}}, [translate_expr(L), translate_expr(R)]}
    end;
translate_expr({{'.', _, [erlang, Op]}, Meta, [Arg]}) ->
    case is_erl_unop(Op) of
        true ->
            {op, meta_anno(Meta), Op, translate_expr(Arg)};
        false ->
            Anno = meta_anno(Meta),
            {call, Anno, {remote, Anno, {atom, Anno, erlang}, {atom, Anno, Op}}, [translate_expr(Arg)]}
    end;
translate_expr({{'.', _, [{FunVar, FunMeta, Ctx}]}, Meta, Args}) when is_atom(FunVar), is_atom(Ctx), is_list(Args) ->
    Anno = meta_anno(Meta),
    {call, Anno, {var, Anno, elixir_var(FunVar, FunMeta, Ctx)}, [translate_expr(A) || A <- Args]};
translate_expr({{'.', _, [Target]}, Meta, Args}) when is_list(Args) ->
    Anno = meta_anno(Meta),
    {call, Anno, translate_expr(Target), [translate_expr(A) || A <- Args]};
translate_expr({{'.', _, [Target, Field]}, Meta, []}) when is_atom(Field) ->
    Anno = meta_anno(Meta),
    {call, Anno, {remote, Anno, {atom, Anno, erlang}, {atom, Anno, map_get}}, [{atom, Anno, Field}, translate_expr(Target)]};
translate_expr({{'.', _, [ModAst, FunAtom]}, Meta, Args}) when is_atom(FunAtom), is_list(Args) ->
    Anno = meta_anno(Meta),
    {call, Anno, {remote, Anno, translate_expr(ModAst), {atom, Anno, FunAtom}}, [translate_expr(A) || A <- Args]};
translate_expr({fn, Meta, Clauses}) when is_list(Clauses) ->
    Anno = meta_anno(Meta),
    ErlClauses = [translate_case_clause(C) || C <- Clauses],
    {'fun', Anno, {clauses, ErlClauses}};
translate_expr({'/', Meta, [{Fun, _FunMeta, Ctx}, Arity]})
  when is_atom(Fun), is_atom(Ctx), is_integer(Arity) ->
    Anno = meta_anno(Meta),
    {'fun', Anno, {function, Fun, Arity}};
translate_expr({'&', Meta, [{'/', _, [{Fun, _FunMeta, Ctx}, Arity]}]})
  when is_atom(Fun), is_atom(Ctx), is_integer(Arity) ->
    Anno = meta_anno(Meta),
    {'fun', Anno, {function, Fun, Arity}};
translate_expr({'/', Meta, [{{'.', _, [Mod, Fun]}, _, []}, Arity]})
  when is_atom(Fun), is_integer(Arity) ->
    Anno = meta_anno(Meta),
    {'fun', Anno, {function, translate_expr(Mod), {atom, Anno, Fun}, {integer, Anno, Arity}}};
translate_expr({'&', Meta, [{'/', _, [{{'.', _, [Mod, Fun]}, _, []}, Arity]}]})
  when is_atom(Fun), is_integer(Arity) ->
    Anno = meta_anno(Meta),
    {'fun', Anno, {function, translate_expr(Mod), {atom, Anno, Fun}, {integer, Anno, Arity}}};
translate_expr({'&', Meta, [{Fun, FunMeta, Ctx}]}) when is_atom(Fun), is_atom(Ctx) ->
    Anno = meta_anno(Meta),
    {var, Anno, elixir_var(Fun, FunMeta, Ctx)};
translate_expr({'&', Meta, [{{'.', _, [Mod, Fun]}, _, []}, Arity]}) when is_integer(Arity) ->
    Anno = meta_anno(Meta),
    {'fun', Anno, {function, translate_expr(Mod), {atom, Anno, Fun}, {integer, Anno, Arity}}};
translate_expr({'_', Meta, Ctx}) when is_atom(Ctx) ->
    {var, meta_anno(Meta), '_'};
translate_expr({VarName, Meta, Ctx}) when is_atom(VarName), is_atom(Ctx) ->
    {var, meta_anno(Meta), elixir_var(VarName, Meta, Ctx)};
translate_expr({FunAtom, Meta, Args}) when is_atom(FunAtom), is_list(Args) ->
    Anno = meta_anno(Meta),
    {call, Anno, {atom, Anno, FunAtom}, [translate_expr(A) || A <- Args]};
translate_expr({A, B}) ->
    Anno = erl_anno:new(1),
    {tuple, Anno, [translate_expr(A), translate_expr(B)]};
translate_expr([{'|', Meta, [H, T]}]) ->
    {cons, meta_anno(Meta), translate_expr(H), translate_expr(T)};
translate_expr(List) when is_list(List) ->
    Anno = erl_anno:new(1),
    lists:foldr(
        fun(E, Acc) -> {cons, Anno, translate_expr(E), Acc} end,
        {nil, Anno},
        List
    );
translate_expr(Int) when is_integer(Int) ->
    {integer, erl_anno:new(1), Int};
translate_expr(Float) when is_float(Float) ->
    {float, erl_anno:new(1), Float};
translate_expr(Atom) when is_atom(Atom) ->
    {atom, erl_anno:new(1), Atom};
translate_expr(Bin) when is_binary(Bin) ->
    Anno = erl_anno:new(1),
    {bin, Anno, [{bin_element, Anno, {string, Anno, binary_to_list(Bin)}, default, default}]};
translate_expr(_) ->
    {atom, erl_anno:new(1), ok}.

translate_case_clause({'->', Meta, [[{'when', _, ArgsAndGuard}], Body]})
  when is_list(ArgsAndGuard), length(ArgsAndGuard) >= 2 ->
    Pat = hd(ArgsAndGuard),
    Guard = lists:last(ArgsAndGuard),
    {clause, meta_anno(Meta), [translate_pattern(Pat)], [[translate_guard(Guard)]], translate_body(Body)};
translate_case_clause({'->', Meta, [[Pat], Body]}) ->
    {clause, meta_anno(Meta), [translate_pattern(Pat)], [], translate_body(Body)};
translate_case_clause({'->', Meta, [Pats, Body]}) when is_list(Pats) ->
    {clause, meta_anno(Meta), [translate_pattern(P) || P <- Pats], [], translate_body(Body)};
translate_case_clause(_) ->
    Anno = erl_anno:new(1),
    {clause, Anno, [{var, Anno, '_'}], [], [{atom, Anno, ok}]}.

translate_map_expr_pairs(Anno, Pairs) when is_list(Pairs) ->
    lists:flatmap(
        fun
            ({'|', _, [_Base, InnerPairs]}) when is_list(InnerPairs) ->
                translate_map_expr_pairs(Anno, InnerPairs);
            ({K, V}) ->
                [{map_field_exact, Anno, translate_expr(K), translate_expr(V)}];
            (_) ->
                []
        end,
        Pairs
    );
translate_map_expr_pairs(_Anno, _) ->
    [].

is_erl_binop('+') -> true;
is_erl_binop('-') -> true;
is_erl_binop('*') -> true;
is_erl_binop('/') -> true;
is_erl_binop('div') -> true;
is_erl_binop('rem') -> true;
is_erl_binop('andalso') -> true;
is_erl_binop('orelse') -> true;
is_erl_binop('and') -> true;
is_erl_binop('or') -> true;
is_erl_binop('xor') -> true;
is_erl_binop('>') -> true;
is_erl_binop('>=') -> true;
is_erl_binop('<') -> true;
is_erl_binop('=<') -> true;
is_erl_binop('=:=') -> true;
is_erl_binop('==') -> true;
is_erl_binop('++') -> true;
is_erl_binop('--') -> true;
is_erl_binop(_) -> false.

is_erl_unop('not') -> true;
is_erl_unop('-') -> true;
is_erl_unop('+') -> true;
is_erl_unop(_) -> false.

unwrap_atom(Atom) when is_atom(Atom) -> Atom;
unwrap_atom({'__aliases__', _, Parts}) when is_list(Parts) ->
    ModBins = [atom_to_binary(P, utf8) || P <- Parts, is_atom(P)],
    binary_to_atom(iolist_to_binary(lists:join(<<".">>, [<<"Elixir">> | ModBins])), utf8);
unwrap_atom(_) -> 'Elixir.Any'.

elixir_var(VarName, Meta, Ctx) ->
    VerSuffix = case is_list(Meta) of
        true ->
            case proplists:get_value(version, Meta) of
                Ver when is_integer(Ver) -> <<"@", (integer_to_binary(Ver))/binary>>;
                _ -> <<>>
            end;
        false ->
            <<>>
    end,
    CtxSuffix = case Ctx of
        nil -> <<>>;
        _ when is_atom(Ctx) -> <<"@", (atom_to_binary(Ctx, utf8))/binary>>
    end,
    binary_to_atom(
        <<(atom_to_binary(VarName, utf8))/binary, VerSuffix/binary, CtxSuffix/binary>>,
        utf8
    ).

meta_anno(Meta) when is_list(Meta) ->
    case proplists:get_value(line, Meta, 1) of
        Line when is_integer(Line), Line >= 0 -> erl_anno:new(Line);
        _ -> erl_anno:new(1)
    end;
meta_anno(Line) when is_integer(Line), Line >= 0 ->
    erl_anno:new(Line);
meta_anno(_) ->
    erl_anno:new(1).
