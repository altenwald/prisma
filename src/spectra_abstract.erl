%% @doc Extracts portable type and contract summaries from Erlang and Elixir BEAM files.
%%
%% Uses BEAM debug_info chunks and normalizes types via `spectra_type` without
%% storing absolute filesystem paths.
-module(spectra_abstract).

-include("spectra.hrl").

-export([
    extract_beam/1,
    detect_language/2
]).

%% @doc Extracts a `#module_summary{}` from a BEAM file path or binary.
-spec extract_beam(file:filename_all() | binary()) ->
    {ok, #module_summary{}} | {error, term()}.
extract_beam(BeamInput) ->
    BeamPathOrBin = normalize_input(BeamInput),
    case beam_lib:md5(BeamPathOrBin) of
        {ok, {Module, Md5}} ->
            extract_chunks(BeamPathOrBin, Module, Md5);
        {error, beam_lib, Reason} ->
            {error, Reason}
    end.

normalize_input(Bin) when is_binary(Bin) ->
    case Bin of
        <<"FOR1", _/binary>> -> Bin;
        _ -> unicode:characters_to_list(Bin)
    end;
normalize_input(Path) when is_list(Path) ->
    Path.

extract_chunks(Beam, Module, Md5) ->
    ChunkNames = [exports, attributes, debug_info],
    case beam_lib:chunks(Beam, ChunkNames, [allow_missing_chunks]) of
        {ok, {Module, Chunks}} ->
            Exports = proplists:get_value(exports, Chunks, []),
            Attrs = normalize_chunks_val(proplists:get_value(attributes, Chunks, [])),
            Dbgi = proplists:get_value(debug_info, Chunks, missing_chunk),
            Lang = detect_language(Module, Dbgi),
            Vsn = proplists:get_value(vsn, Attrs, []),
            ExportTypes = lists:append(proplists:get_all_values(export_type, Attrs)),
            BaseSummary = #module_summary{
                module = Module,
                language = Lang,
                vsn = Vsn,
                beam_md5 = Md5,
                exports = Exports,
                export_types = ExportTypes
            },
            enrich_from_debug_info(Beam, Dbgi, Exports, BaseSummary);
        {error, beam_lib, Reason} ->
            {error, Reason}
    end.

normalize_chunks_val(missing_chunk) -> [];
normalize_chunks_val(Val) when is_list(Val) -> Val;
normalize_chunks_val(_) -> [].

%% @doc Detects whether a BEAM module originated from Erlang or Elixir.
-spec detect_language(module(), term()) -> source_lang().
detect_language(_Module, {debug_info_v1, elixir_erl, _}) ->
    elixir;
detect_language(Module, Dbgi) ->
    case atom_to_binary(Module, utf8) of
        <<"Elixir.", _/binary>> -> elixir;
        _ ->
            case Dbgi of
                {debug_info_v1, erl_abstract_code, _} -> erlang;
                _ -> erlang
            end
    end.

enrich_from_debug_info(Beam, Dbgi, Exports, Summary) ->
    case beam_lib:chunks(Beam, [abstract_code]) of
        {ok, {_Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            {ok, parse_abstract_forms(Forms, Exports, Summary)};
        _ ->
            {ok, parse_fallback_dbgi(Dbgi, Exports, Summary)}
    end.

parse_abstract_forms(Forms, Exports, #module_summary{module = Mod, export_types = AttrExpTypes} = Summary) ->
    ExportSet = maps:from_list([{FA, true} || FA <- Exports]),
    {RawTypes, FormExpTypes, Specs, Funcs} = lists:foldl(
        fun(Form, {TAcc, ETAcc, SAcc, FAcc}) ->
            case Form of
                {attribute, _Anno, export_type, ExpList} when is_list(ExpList) ->
                    {TAcc, ExpList ++ ETAcc, SAcc, FAcc};
                {attribute, _Anno, Kind, {_TypeName, _TypeDef, _TypeArgs} = TypeAttr}
                  when Kind =:= type; Kind =:= opaque; Kind =:= nominal ->
                    Decl = spectra_type:from_type_attr(Mod, Kind, TypeAttr),
                    Key = Decl#type_decl.key,
                    {TAcc#{Key => Decl}, ETAcc, SAcc, FAcc};
                {attribute, _Anno, spec, {{F, A}, SpecClauses}} ->
                    Key = {Mod, F, A},
                    NormSpecs = [spectra_type:from_abstract(S) || S <- SpecClauses],
                    {TAcc, ETAcc, SAcc#{Key => NormSpecs}, FAcc};
                {attribute, _Anno, spec, {{M, F, A}, SpecClauses}} ->
                    Key = {M, F, A},
                    NormSpecs = [spectra_type:from_abstract(S) || S <- SpecClauses],
                    {TAcc, ETAcc, SAcc#{Key => NormSpecs}, FAcc};
                {function, Anno, F, A, Clauses} ->
                    Key = {Mod, F, A},
                    Line = erl_anno:line(Anno),
                    Calls = extract_calls_from_clauses(Mod, Clauses),
                    Inferred = infer_simple_clause_type(Clauses),
                    Contract = #func_contract{
                        mfa = Key,
                        exported = maps:is_key({F, A}, ExportSet),
                        inferred_type = Inferred,
                        calls = Calls,
                        line = Line
                    },
                    {TAcc, ETAcc, SAcc, FAcc#{Key => Contract}};
                _ ->
                    {TAcc, ETAcc, SAcc, FAcc}
            end
        end,
        {#{}, AttrExpTypes, #{}, #{}},
        Forms
    ),
    AllExpTypes = lists:usort(FormExpTypes),
    ExpTypeSet = maps:from_list([{TA, true} || TA <- AllExpTypes]),
    MarkedTypes = maps:map(
        fun({_M, TName, TArity}, Decl) ->
            Decl#type_decl{exported = maps:is_key({TName, TArity}, ExpTypeSet)}
        end,
        RawTypes
    ),
    MergedFuncs = merge_specs_into_funcs(Mod, ExportSet, Specs, Funcs),
    Summary#module_summary{
        export_types = AllExpTypes,
        types = MarkedTypes,
        functions = MergedFuncs
    }.

parse_fallback_dbgi({debug_info_v1, elixir_erl, {elixir_v1, _Map, SpecsForms}}, Exports, Summary)
  when is_list(SpecsForms) ->
    parse_abstract_forms(SpecsForms, Exports, Summary);
parse_fallback_dbgi(_, Exports, #module_summary{module = Mod} = Summary) ->
    Funcs = maps:from_list([
        {{Mod, F, A}, #func_contract{mfa = {Mod, F, A}, exported = true}}
        || {F, A} <- Exports
    ]),
    Summary#module_summary{functions = Funcs}.

merge_specs_into_funcs(Mod, ExportSet, Specs, Funcs) ->
    maps:fold(
        fun({M, F, A} = Key, SpecClauses, Acc) when M =:= Mod ->
            case maps:find(Key, Acc) of
                {ok, Existing} ->
                    Acc#{Key => Existing#func_contract{declared_specs = SpecClauses}};
                error ->
                    Acc#{Key => #func_contract{
                        mfa = Key,
                        exported = maps:is_key({F, A}, ExportSet),
                        declared_specs = SpecClauses
                    }}
            end;
           (_OtherKey, _SpecClauses, Acc) ->
            Acc
        end,
        Funcs,
        Specs
    ).

extract_calls_from_clauses(CurrentMod, Clauses) ->
    Calls = lists:foldl(fun(C, Acc) -> collect_calls(CurrentMod, C, Acc) end, #{}, Clauses),
    lists:sort(maps:keys(Calls)).

collect_calls(Mod, {call, _Anno, {remote, _A2, {atom, _A3, M}, {atom, _A4, F}}, Args}, Acc) ->
    Acc1 = Acc#{{M, F, length(Args)} => true},
    collect_calls_list(Mod, Args, Acc1);
collect_calls(Mod, {call, _Anno, {atom, _A2, F}, Args}, Acc) ->
    Acc1 = Acc#{{Mod, F, length(Args)} => true},
    collect_calls_list(Mod, Args, Acc1);
collect_calls(Mod, Tuple, Acc) when is_tuple(Tuple) ->
    collect_calls_list(Mod, tuple_to_list(Tuple), Acc);
collect_calls(Mod, List, Acc) when is_list(List) ->
    collect_calls_list(Mod, List, Acc);
collect_calls(_Mod, _Other, Acc) ->
    Acc.

collect_calls_list(Mod, Items, Acc) ->
    lists:foldl(fun(Item, A) -> collect_calls(Mod, Item, A) end, Acc, Items).

infer_simple_clause_type([{clause, _Anno, Args, _Guards, Body} | _]) ->
    ArgTypes = [infer_expr_type(Arg) || Arg <- Args],
    RetType = infer_expr_type(lists:last(Body)),
    {fun_type, ArgTypes, RetType};
infer_simple_clause_type(_) ->
    any.

infer_expr_type({integer, _, Int}) -> {int_lit, Int};
infer_expr_type({float, _, _}) -> float;
infer_expr_type({atom, _, Atom}) -> {atom_lit, Atom};
infer_expr_type({nil, _}) -> nil;
infer_expr_type({cons, _, H, _T}) -> {nonempty_list, infer_expr_type(H)};
infer_expr_type({bin, _, _}) -> {binary, 0, 8};
infer_expr_type({map, _, _}) -> any_map;
infer_expr_type({tuple, _, Elements}) -> {tuple, [infer_expr_type(E) || E <- Elements]};
infer_expr_type(_) -> any.
