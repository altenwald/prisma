%% @doc Success Typing inference and discrepancy analyzer over Erlang Abstract Format.
%%
%% Infers function argument domains and return types without false positives,
%% detecting guaranteed runtime failures (badarith, badmatch, case_clause,
%% unreachable branches, and incompatible calls).
-module(spectra_infer).

-include("spectra.hrl").

-export([
    infer_module_functions/3,
    check_call_site/4
]).

-ifdef(TEST).
-export([negate_type/1]).
-endif.

-define(MAX_FIXPOINT_PASSES, 4).

%% @doc Runs fixpoint success-type inference across all functions in `Mod`.
-spec infer_module_functions(
    module(),
    #{mfa_key() => {non_neg_integer(), [term()]}},
    #{mfa_key() => #func_contract{}}
) -> #{mfa_key() => #func_contract{}}.
infer_module_functions(Mod, ClausesMap, InitialContracts) ->
    fixpoint_loop(Mod, ClausesMap, InitialContracts, 1).

fixpoint_loop(Mod, ClausesMap, Contracts, Pass) ->
    NextContracts = maps:map(
        fun(MFA, Contract) ->
            case maps:find(MFA, ClausesMap) of
                {ok, {_Line, Clauses}} ->
                    infer_function(Mod, MFA, Clauses, Contract, Contracts);
                error ->
                    Contract
            end
        end,
        Contracts
    ),
    case Pass >= ?MAX_FIXPOINT_PASSES orelse same_inferred_types(Contracts, NextContracts) of
        true -> NextContracts;
        false -> fixpoint_loop(Mod, ClausesMap, NextContracts, Pass + 1)
    end.

same_inferred_types(C1, C2) ->
    maps:fold(
        fun(K, #func_contract{inferred_type = T1}, Acc) ->
            Acc andalso case maps:find(K, C2) of
                {ok, #func_contract{inferred_type = T2}} -> T1 =:= T2;
                error -> false
            end
        end,
        true,
        C1
    ).

infer_function(Mod, {_M, _F, Arity} = MFA, Clauses, Contract, AllContracts) ->
    {ArgVectors, RetTypes, Warnings, CallSites} = lists:foldl(
        fun(Clause, {ArgAcc, RetAcc, WarnAcc, SiteAcc}) ->
            case infer_clause(Mod, MFA, Clause, AllContracts) of
                {unreachable, ClauseWarns} ->
                    {ArgAcc, RetAcc, WarnAcc ++ ClauseWarns, SiteAcc};
                {ok, ClauseArgTypes, ClauseRet, ClauseWarns, ClauseSites} ->
                    {[ClauseArgTypes | ArgAcc], [ClauseRet | RetAcc], WarnAcc ++ ClauseWarns, SiteAcc ++ ClauseSites}
            end
        end,
        {[], [], [], []},
        Clauses
    ),
    JoinedArgs = join_arg_vectors(Arity, lists:reverse(ArgVectors)),
    JoinedRet = spectra_type:normalize_union(lists:reverse(RetTypes)),
    InferredType = {fun_type, [spectra_type:widen(A) || A <- JoinedArgs], spectra_type:widen(JoinedRet)},
    Contract#func_contract{
        inferred_type = InferredType,
        call_sites = lists:usort(CallSites),
        local_warnings = lists:usort(Warnings)
    }.

join_arg_vectors(Arity, []) ->
    lists:duplicate(Arity, none);
join_arg_vectors(Arity, Vectors) ->
    lists:map(
        fun(Idx) ->
            Col = [lists:nth(Idx, V) || V <- Vectors],
            spectra_type:normalize_union(Col)
        end,
        lists:seq(1, Arity)
    ).

infer_clause(Mod, MFA, {clause, Anno, PatArgs, Guards, Body}, AllContracts) ->
    SeedArgs = seed_arg_types(MFA, length(PatArgs), AllContracts),
    case bind_patterns(PatArgs, SeedArgs, #{}) of
        unreachable ->
            ClauseWarns = case is_generated_function(MFA) of
                true -> [];
                false -> [make_warning(dead_code, MFA, Anno, <<"Function clause pattern cannot match">>)]
            end,
            {unreachable, ClauseWarns};
        {ok, PatTypes, Env0} ->
            TestWarns = guard_warnings(MFA, Guards, Env0),
            case apply_guard_disjunction(Guards, Env0) of
                unreachable ->
                    GuardWarns = case is_generated_function(MFA) of
                        true -> [];
                        false -> [make_warning(dead_code, MFA, Anno, <<"Function clause guard cannot succeed">>)]
                    end,
                    {unreachable, TestWarns ++ GuardWarns};
                {ok, Env1} ->
                    {RetType, EnvFinal, Warns, Sites} = infer_body(Mod, MFA, Body, Env1, AllContracts, [], []),
                    RefinedArgs = [refine_pat_type(P, T, EnvFinal) || {P, T} <- lists:zip(PatArgs, PatTypes)],
                    {ok, RefinedArgs, RetType, TestWarns ++ Warns, Sites}
            end
    end.

refine_pat_type({var, _, '_'}, PatType, _Env) ->
    PatType;
refine_pat_type({var, _, V}, PatType, Env) ->
    spectra_type:meet(PatType, maps:get(V, Env, any));
refine_pat_type({match, _, P1, P2}, PatType, Env) ->
    spectra_type:meet(refine_pat_type(P1, PatType, Env), refine_pat_type(P2, PatType, Env));
refine_pat_type(_, PatType, _Env) ->
    PatType.

bind_patterns([], [], Env) ->
    {ok, [], Env};
bind_patterns([P | Ps], [Expected | Es], Env0) ->
    case bind_pattern(P, Expected, Env0) of
        {none, _Env1} ->
            unreachable;
        {T, Env1} ->
            case bind_patterns(Ps, Es, Env1) of
                unreachable -> unreachable;
                {ok, Ts, Env2} -> {ok, [T | Ts], Env2}
            end
    end.

bind_pattern({var, _, '_'}, Expected, Env) ->
    {Expected, Env};
bind_pattern({var, _, V}, Expected, Env) ->
    Prev = maps:get(V, Env, any),
    M = spectra_type:meet(Prev, Expected),
    {M, Env#{V => M}};
bind_pattern({match, _, P1, P2}, Expected, Env0) ->
    case bind_pattern(P1, Expected, Env0) of
        {none, Env1} -> {none, Env1};
        {T1, Env1} ->
            case bind_pattern(P2, T1, Env1) of
                {none, Env2} -> {none, Env2};
                {T2, Env2} -> bind_pattern(P1, T2, Env2)
            end
    end;
bind_pattern({integer, _, I}, Expected, Env) ->
    {spectra_type:meet({int_lit, I}, Expected), Env};
bind_pattern({char, _, C}, Expected, Env) ->
    {spectra_type:meet({int_lit, C}, Expected), Env};
bind_pattern({op, _, '-', {integer, _, I}}, Expected, Env) ->
    {spectra_type:meet({int_lit, -I}, Expected), Env};
bind_pattern({float, _, _}, Expected, Env) ->
    {spectra_type:meet(float, Expected), Env};
bind_pattern({atom, _, A}, Expected, Env) ->
    {spectra_type:meet({atom_lit, A}, Expected), Env};
bind_pattern({nil, _}, Expected, Env) ->
    {spectra_type:meet(nil, Expected), Env};
bind_pattern({bin, _, _}, Expected, Env) ->
    {spectra_type:meet({binary, 0, 8}, Expected), Env};
bind_pattern({string, _, S}, Expected, Env) ->
    StrType = case S of
        [] -> nil;
        _ -> {nonempty_list, {int_range, 0, 16#10ffff}}
    end,
    {spectra_type:meet(StrType, Expected), Env};
bind_pattern({cons, _, H, T}, Expected, Env0) ->
    ElemExpected = extract_list_elem(Expected),
    case ElemExpected of
        none ->
            {none, Env0};
        _ ->
            case bind_pattern(H, ElemExpected, Env0) of
                {none, Env1} -> {none, Env1};
                {HT, Env1} ->
                    TailExpected = list_tail_type(Expected),
                    case bind_pattern(T, TailExpected, Env1) of
                        {none, Env2} -> {none, Env2};
                        {TT, Env2} ->
                            Cell = case proper_tail(TT) of
                                true -> {nonempty_list, HT};
                                false -> {improper_list, HT, TT}
                            end,
                            {spectra_type:meet(Cell, Expected), Env2}
                    end
            end
    end;
bind_pattern({tuple, _, PatElems}, Expected, Env0) ->
    case extract_tuple_elems(length(PatElems), Expected) of
        none ->
            {none, Env0};
        ElemExpecteds ->
            case bind_patterns(PatElems, ElemExpecteds, Env0) of
                unreachable -> {none, Env0};
                {ok, BoundElems, Env1} -> {spectra_type:meet({tuple, BoundElems}, Expected), Env1}
            end
    end;
bind_pattern({map, _, Fields}, Expected, Env0) ->
    case spectra_type:meet(any_map, Expected) of
        none ->
            {none, Env0};
        _ ->
            bind_map_pat_fields(Fields, Expected, Env0, [])
    end;
bind_pattern(_, Expected, Env) ->
    {Expected, Env}.

bind_map_pat_fields([], Expected, Env, Acc) ->
    {spectra_type:meet({map, lists:usort(Acc)}, Expected), Env};
bind_map_pat_fields([{map_field_exact, _, KAst, VP} | Rest], Expected, Env0, Acc) ->
    KType = literal_or_any(KAst),
    case bind_pattern(VP, any, Env0) of
        {none, Env1} -> {none, Env1};
        {VType, Env1} -> bind_map_pat_fields(Rest, Expected, Env1, [{exact, KType, VType} | Acc])
    end;
bind_map_pat_fields([_ | Rest], Expected, Env, Acc) ->
    bind_map_pat_fields(Rest, Expected, Env, Acc).

literal_or_any({atom, _, A}) -> {atom_lit, A};
literal_or_any({integer, _, I}) -> {int_lit, I};
literal_or_any(_) -> any.

extract_list_elem(any) -> any;
extract_list_elem({list, E}) -> E;
extract_list_elem({nonempty_list, E}) -> E;
extract_list_elem({improper_list, E, _}) -> E;
extract_list_elem({union, Members}) ->
    spectra_type:normalize_union([extract_list_elem(M) || M <- Members]);
extract_list_elem(_) -> none.

%% The type of Tail in [H | Tail] when the whole cell has the given type. An unknown cell has an unknown tail (it may
%% be any term), and a maybe-improper list has either another cell, [] or its improper tail.
list_tail_type(any) -> any;
list_tail_type({list, E}) -> {list, E};
list_tail_type({nonempty_list, E}) -> {list, E};
list_tail_type({improper_list, _, T} = Improper) -> spectra_type:normalize_union([Improper, T]);
list_tail_type({union, Members}) -> spectra_type:normalize_union([list_tail_type(M) || M <- Members]);
list_tail_type(_) -> none.


extract_tuple_elems(Arity, any) ->
    lists:duplicate(Arity, any);
extract_tuple_elems(Arity, any_tuple) ->
    lists:duplicate(Arity, any);
extract_tuple_elems(Arity, {tuple, Elems}) when length(Elems) =:= Arity ->
    Elems;
extract_tuple_elems(Arity, {union, Members}) ->
    Matching = [extract_tuple_elems(Arity, M) || M <- Members],
    Valid = [V || V <- Matching, V =/= none],
    case Valid of
        [] -> none;
        _ -> join_arg_vectors(Arity, Valid)
    end;
extract_tuple_elems(_, _) ->
    none.

apply_guard_disjunction([], Env) ->
    {ok, Env};
apply_guard_disjunction(ConjList, Env0) ->
    ValidEnvs = lists:filtermap(
        fun(Conj) ->
            case apply_guard_conjunction(Conj, Env0) of
                unreachable -> false;
                {ok, Env1} -> {true, Env1}
            end
        end,
        ConjList
    ),
    case ValidEnvs of
        [] -> unreachable;
        [Single] -> {ok, Single};
        Many -> {ok, join_envs(Many)}
    end.

apply_guard_conjunction([], Env) ->
    {ok, Env};
apply_guard_conjunction([Test | Rest], Env0) ->
    case apply_guard_test(Test, Env0) of
        unreachable -> unreachable;
        {ok, Env1} -> apply_guard_conjunction(Rest, Env1)
    end.

%% What each test of a guard says when it is typed as an expression: a BIF given arguments of the wrong type fails whenever it is
%% evaluated, even if another alternative of the guard (`P =:= [] orelse hd(P) ...`) can still hold.
guard_warnings(MFA, Guards, Env) ->
    case is_generated_function(MFA) of
        true ->
            [];
        false ->
            lists:append([begin
                              {_, _, Warns, _} = infer_expr(guard, MFA, Test, Env, #{}, [], []),
                              Warns
                          end || Conj <- Guards, Test <- Conj])
    end.

%% A guard test that cannot succeed (a BIF given arguments of the wrong type, say) makes the guard fail, so the clause can
%% never match: the test is typed as an expression first, and `none` means that it fails.
apply_guard_test(Test, Env) ->
    case guard_test_type(Test, Env) of
        none -> unreachable;
        _ -> apply_guard_test_refining(Test, Env)
    end.

guard_test_type(Test, Env) ->
    {Type, _, _, _} = infer_expr(guard, {guard, guard, 0}, Test, Env, #{}, [], []),
    Type.

apply_guard_test_refining({call, _, {remote, _, {atom, _, erlang}, {atom, _, Fun}}, Args}, Env) ->
    apply_guard_bif(Fun, Args, Env);
apply_guard_test_refining({call, _, {atom, _, Fun}, Args}, Env) ->
    apply_guard_bif(Fun, Args, Env);
apply_guard_test_refining({op, _, 'andalso', L, R}, Env0) ->
    case apply_guard_test(L, Env0) of
        unreachable -> unreachable;
        {ok, Env1} -> apply_guard_test(R, Env1)
    end;
apply_guard_test_refining({op, _, 'and', L, R}, Env0) ->
    apply_guard_test({op, 0, 'andalso', L, R}, Env0);
apply_guard_test_refining({op, _, 'orelse', L, R}, Env0) ->
    apply_guard_disjunction([[L], [R]], Env0);
apply_guard_test_refining({op, _, Op, {var, _, V}, {integer, _, 0}}, Env)
  when Op =:= '>'; Op =:= '>='; Op =:= '<' ->
    refine_compare_zero(V, Op, Env);
apply_guard_test_refining({op, _, '==', {var, _, V}, {integer, _, I}}, Env) ->
    %% `==` compares numbers by value: X == 0 also holds for 0.0
    refine_var(V, {union, [{int_lit, I}, float]}, Env);
apply_guard_test_refining({op, _, Op, {var, _, V}, Lit}, Env)
  when Op =:= '=:='; Op =:= '==' ->
    refine_var(V, literal_or_any(Lit), Env);
apply_guard_test_refining({atom, _, false}, _Env) ->
    unreachable;
apply_guard_test_refining(_, Env) ->
    {ok, Env}.

%% `V > 0`, `V >= 0`, `V < 0`. Floats qualify as well as integers, and, in the term order (numbers < atoms < ... <
%% lists), every non-number is greater than 0: so `>` and `>=` say nothing about V unless it is known to be a number, and
%% `<` is only true of negative numbers.
refine_compare_zero(V, Op, Env) ->
    Prev = maps:get(V, Env, any),
    KnownNumber = case Prev of
        any -> false;
        {var, _} -> false;
        _ -> spectra_type:consistent_subtype(Prev, number)
    end,
    Type = case Op of
        '<' -> {union, [neg_integer, float]};
        '>' when KnownNumber -> {union, [pos_integer, float]};
        '>=' when KnownNumber -> {union, [non_neg_integer, float]};
        _ -> any
    end,
    refine_var(V, Type, Env).

apply_guard_bif(GuardName, [{var, _, V}], Env) ->
    case guard_type(GuardName) of
        undefined -> {ok, Env};
        Type -> refine_var(V, Type, Env)
    end;
apply_guard_bif(_, _, Env) ->
    {ok, Env}.

guard_type(is_integer) -> integer;
guard_type(is_float) -> float;
guard_type(is_number) -> number;
guard_type(is_atom) -> atom;
guard_type(is_boolean) -> boolean;
guard_type(is_binary) -> {binary, 0, 8};
guard_type(is_bitstring) -> {binary, 0, 1};
guard_type(is_list) -> {list, any};
guard_type(is_tuple) -> any_tuple;
guard_type(is_map) -> any_map;
guard_type(is_pid) -> pid;
guard_type(is_port) -> port;
guard_type(is_reference) -> reference;
guard_type(is_function) -> any_fun;
guard_type(_) -> undefined.

refine_var('_', _Type, Env) ->
    {ok, Env};
refine_var(V, Type, Env) ->
    Prev = maps:get(V, Env, any),
    case spectra_type:meet(Prev, Type) of
        none -> unreachable;
        M -> {ok, Env#{V => M}}
    end.

%% The environment after several alternatives: a variable keeps a type only if every alternative constrains it (one that
%% does not leaves it unconstrained, which is `any`, not nothing).
join_envs([First | Rest]) ->
    maps:fold(
        fun(K, V, Acc) ->
            case lists:all(fun(E) -> maps:is_key(K, E) end, Rest) of
                true -> Acc#{K => lists:foldl(fun(E, T) -> spectra_type:join(T, maps:get(K, E)) end, V, Rest)};
                false -> Acc
            end
        end,
        #{},
        First
    ).

infer_body(_Mod, _MFA, [], Env, _AllContracts, Warns, Sites) ->
    {any, Env, Warns, Sites};
infer_body(Mod, MFA, [Last], Env, AllContracts, Warns, Sites) ->
    infer_expr(Mod, MFA, Last, Env, AllContracts, Warns, Sites);
infer_body(Mod, MFA, [Expr | Rest], Env0, AllContracts, Warns0, Sites0) ->
    {ExprType, Env1, Warns1, Sites1} = infer_expr(Mod, MFA, Expr, Env0, AllContracts, Warns0, Sites0),
    case ExprType of
        none ->
            {none, Env1, Warns1, Sites1};
        _ ->
            infer_body(Mod, MFA, Rest, Env1, AllContracts, Warns1, Sites1)
    end.

infer_expr(_Mod, _MFA, {integer, _, I}, Env, _Contracts, Warns, Sites) ->
    {{int_lit, I}, Env, Warns, Sites};
infer_expr(_Mod, _MFA, {char, _, C}, Env, _Contracts, Warns, Sites) ->
    {{int_lit, C}, Env, Warns, Sites};
infer_expr(_Mod, _MFA, {float, _, _}, Env, _Contracts, Warns, Sites) ->
    {float, Env, Warns, Sites};
infer_expr(_Mod, _MFA, {atom, _, A}, Env, _Contracts, Warns, Sites) ->
    {{atom_lit, A}, Env, Warns, Sites};
infer_expr(_Mod, _MFA, {nil, _}, Env, _Contracts, Warns, Sites) ->
    {nil, Env, Warns, Sites};
infer_expr(Mod, MFA, {bin, _, Elements}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_effects(Mod, MFA, bin_element_exprs(Elements), Env, Contracts, Warns0, Sites0),
    {{binary, 0, 8}, Env, Warns, Sites};
infer_expr(_Mod, _MFA, {string, _, S}, Env, _Contracts, Warns, Sites) ->
    Type = case S of
        [] -> nil;
        _ -> {nonempty_list, {int_range, 0, 16#10ffff}}
    end,
    {Type, Env, Warns, Sites};
infer_expr(_Mod, _MFA, {var, _, '_'}, Env, _Contracts, Warns, Sites) ->
    {any, Env, Warns, Sites};
infer_expr(_Mod, _MFA, {var, _, V}, Env, _Contracts, Warns, Sites) ->
    {maps:get(V, Env, any), Env, Warns, Sites};
infer_expr(Mod, MFA, {tuple, _, Es}, Env0, Contracts, Warns0, Sites0) ->
    {ElemTypes, Env1, Warns1, Sites1} = infer_expr_list(Mod, MFA, Es, Env0, Contracts, Warns0, Sites0),
    case lists:member(none, ElemTypes) of
        true -> {none, Env1, Warns1, Sites1};
        false -> {{tuple, ElemTypes}, Env1, Warns1, Sites1}
    end;
infer_expr(Mod, MFA, {cons, _, H, T}, Env0, Contracts, Warns0, Sites0) ->
    {HType, Env1, Warns1, Sites1} = infer_expr(Mod, MFA, H, Env0, Contracts, Warns0, Sites0),
    {TType, Env2, Warns2, Sites2} = infer_expr(Mod, MFA, T, Env1, Contracts, Warns1, Sites1),
    case HType =:= none orelse TType =:= none of
        true ->
            {none, Env2, Warns2, Sites2};
        false ->
            {cons_type(HType, TType), Env2, Warns2, Sites2}
    end;
infer_expr(Mod, MFA, {map, _, Fields}, Env0, Contracts, Warns0, Sites0) ->
    {MapFields, Env1, Warns1, Sites1} = infer_map_fields(Mod, MFA, Fields, Env0, Contracts, Warns0, Sites0, []),
    {{map, lists:usort(MapFields)}, Env1, Warns1, Sites1};
infer_expr(Mod, MFA, {map, Anno, Base, Fields}, Env0, Contracts, Warns0, Sites0) ->
    {BaseType, Env1, Warns1, Sites1} = infer_expr(Mod, MFA, Base, Env0, Contracts, Warns0, Sites0),
    case spectra_type:meet(BaseType, any_map) of
        none when BaseType =/= none ->
            W = make_warning(discrepancy, MFA, Anno, <<"Map update on non-map value">>),
            {none, Env1, [W | Warns1], Sites1};
        _ ->
            {MapFields, Env2, Warns2, Sites2} = infer_map_fields(Mod, MFA, Fields, Env1, Contracts, Warns1, Sites1, []),
            UpdatedType = update_map_type(BaseType, MapFields),
            {UpdatedType, Env2, Warns2, Sites2}
    end;
infer_expr(Mod, MFA, {match, Anno, Pat, Rhs}, Env0, Contracts, Warns0, Sites0) ->
    {RhsType, Env1, Warns1, Sites1} = infer_expr(Mod, MFA, Rhs, Env0, Contracts, Warns0, Sites0),
    case bind_pattern(Pat, RhsType, Env1) of
        {none, Env2} when RhsType =/= none ->
            Msg = iolist_to_binary(io_lib:format("Pattern match can never succeed against ~p", [RhsType])),
            W = make_warning(discrepancy, MFA, Anno, Msg),
            {none, Env2, [W | Warns1], Sites1};
        {MatchedType, Env2} ->
            {MatchedType, Env2, Warns1, Sites1}
    end;
infer_expr(Mod, MFA, {op, Anno, Op, L, R}, Env0, Contracts, Warns0, Sites0) ->
    {LType, Env1, Warns1, Sites1} = infer_expr(Mod, MFA, L, Env0, Contracts, Warns0, Sites0),
    {RType, Env2, Warns2, Sites2} = infer_expr(Mod, MFA, R, Env1, Contracts, Warns1, Sites1),
    infer_binop(MFA, Anno, Op, L, LType, R, RType, Env2, Warns2, Sites2);
infer_expr(Mod, MFA, {op, Anno, Op, Arg}, Env0, Contracts, Warns0, Sites0) ->
    {ArgType, Env1, Warns1, Sites1} = infer_expr(Mod, MFA, Arg, Env0, Contracts, Warns0, Sites0),
    infer_unop(MFA, Anno, Op, Arg, ArgType, Env1, Warns1, Sites1);
infer_expr(Mod, MFA, {'case', Anno, Scrutinee, Clauses}, Env0, Contracts, Warns0, Sites0) ->
    {ScrutType, Env1, Warns1, Sites1} = infer_expr(Mod, MFA, Scrutinee, Env0, Contracts, Warns0, Sites0),
    infer_case(Mod, MFA, Anno, ScrutType, Clauses, Env1, Contracts, Warns1, Sites1);
infer_expr(Mod, MFA, {'if', Anno, Clauses}, Env0, Contracts, Warns0, Sites0) ->
    infer_case(Mod, MFA, Anno, any, Clauses, Env0, Contracts, Warns0, Sites0);
infer_expr(Mod, MFA, {'block', _Anno, Body}, Env0, Contracts, Warns0, Sites0) ->
    infer_body(Mod, MFA, Body, Env0, Contracts, Warns0, Sites0);
infer_expr(Mod, MFA, {call, Anno, Target, Args}, Env0, Contracts, Warns00, Sites00) ->
    {Warns0, Sites0} = infer_target_effects(Mod, MFA, Target, Env0, Contracts, Warns00, Sites00),
    {ArgTypes, Env1, Warns1, Sites1} = infer_expr_list(Mod, MFA, Args, Env0, Contracts, Warns0, Sites0),
    infer_call(Mod, MFA, Anno, Target, Args, ArgTypes, Env1, Contracts, Warns1, Sites1);
%% The constructs below used to be answered `any` without looking inside, so a call in a fun, a try, a comprehension or a
%% record field was never checked. They are looked into for warnings and call sites only: what is bound inside does not
%% reach the code that follows, and the result stays `any` (a fun typed `any_fun` is not consistent with a declared
%% `fun((A) -> B)`, which Spectra's own code showed on the first run).
infer_expr(Mod, MFA, {'fun', _, {clauses, Clauses}}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_nested_clauses(Mod, MFA, Clauses, Env, Contracts, Warns0, Sites0),
    {any, Env, Warns, Sites};
infer_expr(Mod, MFA, {named_fun, _, _Name, Clauses}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_nested_clauses(Mod, MFA, Clauses, Env, Contracts, Warns0, Sites0),
    {any, Env, Warns, Sites};
infer_expr(_Mod, _MFA, {'fun', _, _}, Env, _Contracts, Warns, Sites) ->
    {any, Env, Warns, Sites};
infer_expr(Mod, MFA, {'try', _, Body, OfClauses, CatchClauses, After}, Env, Contracts, Warns0, Sites0) ->
    {_, _, Warns1, Sites1} = infer_body(Mod, MFA, Body, Env, Contracts, Warns0, Sites0),
    {Warns2, Sites2} = infer_nested_clauses(Mod, MFA, OfClauses, Env, Contracts, Warns1, Sites1),
    {Warns3, Sites3} = infer_nested_clauses(Mod, MFA, CatchClauses, Env, Contracts, Warns2, Sites2),
    {_, _, Warns4, Sites4} = infer_body(Mod, MFA, After, Env, Contracts, Warns3, Sites3),
    {any, Env, Warns4, Sites4};
infer_expr(Mod, MFA, {'catch', _, Expr}, Env, Contracts, Warns0, Sites0) ->
    {_, _, Warns, Sites} = infer_expr(Mod, MFA, Expr, Env, Contracts, Warns0, Sites0),
    {any, Env, Warns, Sites};
infer_expr(Mod, MFA, {'receive', _, Clauses}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_nested_clauses(Mod, MFA, Clauses, Env, Contracts, Warns0, Sites0),
    {any, Env, Warns, Sites};
infer_expr(Mod, MFA, {'receive', _, Clauses, Timeout, AfterBody}, Env, Contracts, Warns0, Sites0) ->
    {Warns1, Sites1} = infer_effects(Mod, MFA, [Timeout], Env, Contracts, Warns0, Sites0),
    {Warns2, Sites2} = infer_nested_clauses(Mod, MFA, Clauses, Env, Contracts, Warns1, Sites1),
    {_, _, Warns3, Sites3} = infer_body(Mod, MFA, AfterBody, Env, Contracts, Warns2, Sites2),
    {any, Env, Warns3, Sites3};
infer_expr(Mod, MFA, {lc, _, Template, Qualifiers}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_comprehension(Mod, MFA, Template, Qualifiers, Env, Contracts, Warns0, Sites0),
    {{list, any}, Env, Warns, Sites};
infer_expr(Mod, MFA, {bc, _, Template, Qualifiers}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_comprehension(Mod, MFA, Template, Qualifiers, Env, Contracts, Warns0, Sites0),
    {{binary, 0, 1}, Env, Warns, Sites};
infer_expr(Mod, MFA, {record, _, _Name, Fields}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_effects(Mod, MFA, record_field_exprs(Fields), Env, Contracts, Warns0, Sites0),
    {any, Env, Warns, Sites};
infer_expr(Mod, MFA, {record, _, Expr, _Name, Fields}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_effects(Mod, MFA, [Expr | record_field_exprs(Fields)], Env, Contracts, Warns0, Sites0),
    {any, Env, Warns, Sites};
infer_expr(Mod, MFA, {record_field, _, Expr, _Name, _Field}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_effects(Mod, MFA, [Expr], Env, Contracts, Warns0, Sites0),
    {any, Env, Warns, Sites};
infer_expr(_Mod, _MFA, _Other, Env, _Contracts, Warns, Sites) ->
    {any, Env, Warns, Sites}.

%% What is computed to find out which function is called: the module and the function of `M:F(...)` when they are not literals
%% (the log macros expand to `(logger_mod()):log(...)`), or the expression that is called, `(f())(X)`.
infer_target_effects(_Mod, _MFA, {atom, _, _}, _Env, _Contracts, Warns, Sites) ->
    {Warns, Sites};
infer_target_effects(_Mod, _MFA, {var, _, _}, _Env, _Contracts, Warns, Sites) ->
    {Warns, Sites};
infer_target_effects(Mod, MFA, {remote, _, ModExpr, FunExpr}, Env, Contracts, Warns, Sites) ->
    infer_effects(Mod, MFA, [ModExpr, FunExpr], Env, Contracts, Warns, Sites);
infer_target_effects(Mod, MFA, Target, Env, Contracts, Warns, Sites) ->
    infer_effects(Mod, MFA, [Target], Env, Contracts, Warns, Sites).

%% Infers each expression only for its warnings and call sites, in the same environment (nothing flows between them).
infer_effects(Mod, MFA, Exprs, Env, Contracts, Warns0, Sites0) ->
    lists:foldl(
        fun(Expr, {W, S}) ->
            {_, _, W1, S1} = infer_expr(Mod, MFA, Expr, Env, Contracts, W, S),
            {W1, S1}
        end, {Warns0, Sites0}, Exprs).

bin_element_exprs(Elements) ->
    lists:append([[Expr | case Size of default -> []; _ -> [Size] end]
                  || {bin_element, _, Expr, Size, _} <- Elements]).

record_field_exprs(Fields) ->
    [Expr || {record_field, _, _Key, Expr} <- Fields].

%% Clauses whose patterns are matched against something unknown (funs, catch, receive, the `of` of a try): each pattern
%% binds its variables to `any`, the guard is applied, the body is inferred; nothing flows out and nothing is reported
%% about the clauses themselves.
infer_nested_clauses(Mod, MFA, Clauses, Env0, Contracts, Warns0, Sites0) ->
    lists:foldl(
        fun({clause, _, Pats, Guards, Body}, {W, S}) ->
                Env1 = lists:foldl(fun(Pat, E) -> {_, E1} = bind_pattern(Pat, any, E), E1 end, Env0, Pats),
                case apply_guard_disjunction(Guards, Env1) of
                    unreachable ->
                        {W, S};
                    {ok, Env2} ->
                        {_, _, W1, S1} = infer_body(Mod, MFA, Body, Env2, Contracts, W, S),
                        {W1, S1}
                end
        end, {Warns0, Sites0}, Clauses).

%% [Template || Qualifiers]: generators bind their pattern to `any`, filters are expressions, the template is inferred last.
infer_comprehension(Mod, MFA, Template, Qualifiers, Env0, Contracts, Warns0, Sites0) ->
    {Env, Warns1, Sites1} = lists:foldl(
        fun({Gen, _, Pat, Source}, {E, W, S}) when Gen =:= generate; Gen =:= generate_strict;
                                                   Gen =:= b_generate; Gen =:= b_generate_strict ->
                {_, _, W1, S1} = infer_expr(Mod, MFA, Source, E, Contracts, W, S),
                {_, E1} = bind_pattern(Pat, any, E),
                {E1, W1, S1};
           (Filter, {E, W, S}) ->
                {_, _, W1, S1} = infer_expr(Mod, MFA, Filter, E, Contracts, W, S),
                {E, W1, S1}
        end, {Env0, Warns0, Sites0}, Qualifiers),
    {_, _, Warns, Sites} = infer_expr(Mod, MFA, Template, Env, Contracts, Warns1, Sites1),
    {Warns, Sites}.

infer_expr_list(Mod, MFA, Exprs, Env0, Contracts, Warns0, Sites0) ->
    lists:foldl(
        fun(E, {TAcc, EAcc, WAcc, SAcc}) ->
            {T, ENext, WNext, SNext} = infer_expr(Mod, MFA, E, EAcc, Contracts, WAcc, SAcc),
            {TAcc ++ [T], ENext, WNext, SNext}
        end,
        {[], Env0, Warns0, Sites0},
        Exprs
    ).

infer_map_fields(_Mod, _MFA, [], Env, _Contracts, Warns, Sites, Acc) ->
    {Acc, Env, Warns, Sites};
infer_map_fields(Mod, MFA, [{Tag, _, K, V} | Rest], Env0, Contracts, Warns0, Sites0, Acc)
  when Tag =:= map_field_assoc; Tag =:= map_field_exact ->
    {KType, Env1, Warns1, Sites1} = infer_expr(Mod, MFA, K, Env0, Contracts, Warns0, Sites0),
    {VType, Env2, Warns2, Sites2} = infer_expr(Mod, MFA, V, Env1, Contracts, Warns1, Sites1),
    Kind = case Tag of map_field_exact -> exact; map_field_assoc -> assoc end,
    infer_map_fields(Mod, MFA, Rest, Env2, Contracts, Warns2, Sites2, [{Kind, KType, VType} | Acc]);
infer_map_fields(Mod, MFA, [_ | Rest], Env, Contracts, Warns, Sites, Acc) ->
    infer_map_fields(Mod, MFA, Rest, Env, Contracts, Warns, Sites, Acc).

infer_binop(_MFA, _Anno, Op, _LAst, LType, _RAst, RType, Env, Warns, Sites)
  when Op =/= 'andalso', Op =/= 'orelse', LType =:= none orelse RType =:= none ->
    {none, Env, Warns, Sites};
infer_binop(MFA, Anno, Op, LAst, LType, RAst, RType, Env0, Warns, Sites)
  when Op =:= '+'; Op =:= '-'; Op =:= '*' ->
    LM = spectra_type:meet(LType, number),
    RM = spectra_type:meet(RType, number),
    case (LM =:= none andalso LType =/= none) orelse (RM =:= none andalso RType =/= none) of
        true ->
            Msg = iolist_to_binary(io_lib:format("Arithmetic operator '~s' will fail with badarith (~p, ~p)", [Op, LType, RType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        false ->
            Env1 = constrain_ast_var(LAst, number, constrain_ast_var(RAst, number, Env0)),
            Ret = arith_result_type(LM, RM),
            {Ret, Env1, Warns, Sites}
    end;
infer_binop(MFA, Anno, '/', LAst, LType, RAst, RType, Env0, Warns, Sites) ->
    LM = spectra_type:meet(LType, number),
    RM = spectra_type:meet(RType, number),
    case (LM =:= none andalso LType =/= none) orelse (RM =:= none andalso RType =/= none) of
        true ->
            Msg = iolist_to_binary(io_lib:format("Division '/' will fail with badarith (~p, ~p)", [LType, RType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        false ->
            Env1 = constrain_ast_var(LAst, number, constrain_ast_var(RAst, number, Env0)),
            {float, Env1, Warns, Sites}
    end;
infer_binop(MFA, Anno, Op, LAst, LType, RAst, RType, Env0, Warns, Sites)
  when Op =:= 'div'; Op =:= 'rem'; Op =:= 'band'; Op =:= 'bor'; Op =:= 'bxor'; Op =:= 'bsl'; Op =:= 'bsr' ->
    LM = spectra_type:meet(LType, integer),
    RM = spectra_type:meet(RType, integer),
    case (LM =:= none andalso LType =/= none) orelse (RM =:= none andalso RType =/= none) of
        true ->
            Msg = iolist_to_binary(io_lib:format("Integer operator '~s' will fail with badarith (~p, ~p)", [Op, LType, RType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        false ->
            Env1 = constrain_ast_var(LAst, integer, constrain_ast_var(RAst, integer, Env0)),
            {integer, Env1, Warns, Sites}
    end;
%% `andalso` / `orelse` short-circuit: only the left operand has to be a boolean, and the result is the right operand
%% (any term) when the left one does not decide: `A andalso B` is `false | B`, `A orelse B` is `true | B`.
infer_binop(MFA, Anno, Op, LAst, LType, _RAst, RType, Env0, Warns, Sites)
  when Op =:= 'andalso'; Op =:= 'orelse' ->
    case spectra_type:meet(LType, boolean) of
        none when LType =/= none ->
            Msg = iolist_to_binary(io_lib:format("Boolean operator '~s' will fail (~p, ~p)", [Op, LType, RType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        _ ->
            Env1 = constrain_ast_var(LAst, boolean, Env0),
            {short_circuit_type(Op, LType, RType), Env1, Warns, Sites}
    end;
infer_binop(MFA, Anno, Op, LAst, LType, RAst, RType, Env0, Warns, Sites)
  when Op =:= 'and'; Op =:= 'or'; Op =:= 'xor' ->
    LM = spectra_type:meet(LType, boolean),
    RM = spectra_type:meet(RType, boolean),
    case (LM =:= none andalso LType =/= none) orelse (RM =:= none andalso RType =/= none) of
        true ->
            Msg = iolist_to_binary(io_lib:format("Boolean operator '~s' will fail (~p, ~p)", [Op, LType, RType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        false ->
            Env1 = constrain_ast_var(LAst, boolean, constrain_ast_var(RAst, boolean, Env0)),
            {boolean, Env1, Warns, Sites}
    end;
infer_binop(MFA, Anno, Op, LAst, LType, _RAst, RType, Env0, Warns, Sites)
  when Op =:= '++'; Op =:= '--' ->
    case spectra_type:meet(LType, {list, any}) of
        none when LType =/= none ->
            Msg = iolist_to_binary(io_lib:format("List operator '~s' requires a list on the left-hand side, got ~p", [Op, LType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        _ ->
            Env1 = constrain_ast_var(LAst, {list, any}, Env0),
            Ret = case Op of '++' -> spectra_type:join(LType, RType); '--' -> LType end,
            {Ret, Env1, Warns, Sites}
    end;
infer_binop(_MFA, _Anno, _Op, _LAst, _LType, _RAst, _RType, Env, Warns, Sites) ->
    {boolean, Env, Warns, Sites}.

infer_unop(MFA, Anno, 'not', ArgAst, ArgType, Env0, Warns, Sites) ->
    case spectra_type:meet(ArgType, boolean) of
        none when ArgType =/= none ->
            Msg = iolist_to_binary(io_lib:format("Unary 'not' requires boolean, got ~p", [ArgType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        _ ->
            {boolean, constrain_ast_var(ArgAst, boolean, Env0), Warns, Sites}
    end;
infer_unop(MFA, Anno, Op, ArgAst, ArgType, Env0, Warns, Sites)
  when Op =:= '-'; Op =:= '+' ->
    case spectra_type:meet(ArgType, number) of
        none when ArgType =/= none ->
            Msg = iolist_to_binary(io_lib:format("Unary '~s' requires number, got ~p", [Op, ArgType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        M ->
            ResType = case {ArgType, Op} of
                {any, _} -> any;
                {_, '-'} -> negate_type(M);
                {_, '+'} -> M
            end,
            {ResType, constrain_ast_var(ArgAst, number, Env0), Warns, Sites}
    end;
infer_unop(_MFA, _Anno, _Op, _ArgAst, _ArgType, Env, Warns, Sites) ->
    {any, Env, Warns, Sites}.

%% [H | T] is a proper list only when T is known to be one. Anything else (an integer, a map, or an unknown term,
%% which may be one of those) can end the chain in a non-list, as in [Index | Header]: a maybe-improper list.
cons_type(HType, {union, Members}) ->
    %% The members that are proper lists make one `nonempty_list` together (their elements joined); only the others (an improper
    %% list, an integer, `any`...) each give their own type. Distributing over every member made the type grow with each
    %% pass of the inference of a recursive function: `ne(A) | ne(B)` is not merged, so K clauses gave K, K^2, K^3 members.
    {Proper, Other} = lists:partition(fun proper_tail/1, Members),
    ProperPart = case Proper of
        [] -> [];
        _ -> [proper_cons(HType, {union, Proper})]
    end,
    spectra_type:normalize_union(ProperPart ++ [cons_type(HType, M) || M <- Other]);
cons_type(HType, {improper_list, TailElem, TailEnd}) ->
    %% [H | improper_list(E, T)] is improper_list(H or E, T): the chain does not nest, however many cells are consed
    {improper_list, spectra_type:join(HType, TailElem), TailEnd};
cons_type(HType, TType) ->
    case proper_tail(TType) of
        true -> proper_cons(HType, TType);
        false -> {improper_list, HType, TType}
    end.

%% [H | T] where T is known to be a proper list (or a union of them).
proper_cons(HType, TType) ->
    ElemJoin = case extract_list_elem(TType) of
        none -> HType;
        TailElem -> spectra_type:join(HType, TailElem)
    end,
    {nonempty_list, ElemJoin}.

%% Is every value of the type a proper list? `any` and type variables are not known to be.
proper_tail(nil) -> true;
proper_tail({list, _}) -> true;
proper_tail({nonempty_list, _}) -> true;
proper_tail({union, Members}) -> lists:all(fun proper_tail/1, Members);
proper_tail(_) -> false.

%% The type of `-X` when X has the given numeric type (anything not modelled is just `number`).
-spec negate_type(spectra_type:stype()) -> spectra_type:stype().
negate_type(none) -> none;
negate_type({int_lit, I}) -> {int_lit, -I};
negate_type({int_range, Lo, Hi}) -> {int_range, negate_bound(Hi), negate_bound(Lo)};
negate_type(pos_integer) -> neg_integer;
negate_type(neg_integer) -> pos_integer;
negate_type(non_neg_integer) -> {int_range, neg_inf, 0};
negate_type({union, Members}) -> spectra_type:normalize_union([negate_type(M) || M <- Members]);
negate_type(T) when T =:= integer; T =:= float; T =:= number -> T;
negate_type(_) -> number.

negate_bound(neg_inf) -> pos_inf;
negate_bound(pos_inf) -> neg_inf;
negate_bound(N) when is_integer(N) -> -N.

arith_result_type(float, _) -> float;
arith_result_type(_, float) -> float;
arith_result_type(number, _) -> number;
arith_result_type(_, number) -> number;
arith_result_type(_, _) -> integer.

constrain_ast_var({var, _, '_'}, _Type, Env) ->
    Env;
constrain_ast_var({var, _, V}, Type, Env) ->
    Prev = maps:get(V, Env, any),
    case spectra_type:meet(Prev, Type) of
        none -> Env;
        M -> Env#{V => M}
    end;
constrain_ast_var(_, _Type, Env) ->
    Env.

infer_case(Mod, MFA, Anno, ScrutType, Clauses, Env0, Contracts, Warns0, Sites0) ->
    {BranchRets, BranchEnvs, Warns1, Sites1} = lists:foldl(
        fun({clause, CAnno, Pats, CGuards, CBody}, {RetsAcc, EnvsAcc, WAcc, SAcc}) ->
            PatResult = case Pats of
                [SinglePat] -> bind_pattern(SinglePat, ScrutType, Env0);
                [] -> {any, Env0};
                _ -> {any, Env0}
            end,
            case PatResult of
                {none, _} when ScrutType =/= none ->
                    PWarns = case is_generated_function(MFA) of
                        true -> [];
                        false -> [make_warning(dead_code, MFA, CAnno, <<"Clause pattern cannot match scrutinee type">>)]
                    end,
                    {RetsAcc, EnvsAcc, PWarns ++ WAcc, SAcc};
                {_Matched, CEnv0} ->
                    TestWarns = guard_warnings(MFA, CGuards, CEnv0),
                    case apply_guard_disjunction(CGuards, CEnv0) of
                        unreachable ->
                            GWarns = case is_generated_function(MFA) of
                                true -> [];
                                false -> [make_warning(dead_code, MFA, CAnno, <<"Clause guard cannot succeed">>)]
                            end,
                            {RetsAcc, EnvsAcc, TestWarns ++ GWarns ++ WAcc, SAcc};
                        {ok, CEnv1} ->
                            {CRet, CEnv2, WNext, SNext} = infer_body(Mod, MFA, CBody, CEnv1, Contracts, TestWarns ++ WAcc, SAcc),
                            {[CRet | RetsAcc], [CEnv2 | EnvsAcc], WNext, SNext}
                    end
            end
        end,
        {[], [], Warns0, Sites0},
        Clauses
    ),
    case BranchEnvs of
        [] when ScrutType =/= none ->
            W = make_warning(discrepancy, MFA, Anno, <<"No case/if clause can match">>),
            {none, Env0, [W | Warns1], Sites1};
        [] ->
            {none, Env0, Warns1, Sites1};
        _ ->
            JoinedRet = spectra_type:normalize_union(lists:reverse(BranchRets)),
            JoinedEnv = join_envs(lists:reverse(BranchEnvs)),
            {JoinedRet, JoinedEnv, Warns1, Sites1}
    end.

infer_call(Mod, CallerMFA, Anno, Target, ArgAsts, ArgTypes, Env0, Contracts, Warns0, Sites0) ->
    Line = erl_anno:line(Anno),
    case resolve_call_target(Mod, Target, length(ArgTypes)) of
        {ok, {erlang, ExitFn, 1} = CalleeMFA}
          when ExitFn =:= error; ExitFn =:= exit; ExitFn =:= throw ->
            {none, Env0, Warns0, [{Line, CalleeMFA, ArgTypes} | Sites0]};
        {ok, {erlang, Bif, Arity} = CalleeMFA} ->
            Sites1 = [{Line, CalleeMFA, ArgTypes} | Sites0],
            case bif_signature(Bif, Arity) of
                {ok, ExpectedArgs, RetType0} ->
                    RetType = bif_return_type(Bif, ArgTypes, RetType0),
                    apply_callee_signature(CallerMFA, Line, CalleeMFA, ArgAsts, ArgTypes, ExpectedArgs, RetType, Env0, Warns0, Sites1);
                error ->
                    {any, Env0, Warns0, Sites1}
            end;
        {ok, CalleeMFA} ->
            Sites1 = [{Line, CalleeMFA, ArgTypes} | Sites0],
            case maps:find(CalleeMFA, Contracts) of
                {ok, #func_contract{inferred_type = {fun_type, ExpectedArgs, RetType}}} ->
                    apply_callee_signature(CallerMFA, Line, CalleeMFA, ArgAsts, ArgTypes, ExpectedArgs, RetType, Env0, Warns0, Sites1);
                _ ->
                    {any, Env0, Warns0, Sites1}
            end;
        dynamic ->
            {any, Env0, Warns0, Sites0}
    end.

resolve_call_target(_Mod, {remote, _, {atom, _, M}, {atom, _, F}}, Arity) ->
    {ok, {M, F, Arity}};
resolve_call_target(Mod, {atom, _, F}, Arity) ->
    case erl_internal:bif(F, Arity) of
        true -> {ok, {erlang, F, Arity}};
        false -> {ok, {Mod, F, Arity}}
    end;
resolve_call_target(_Mod, _Dynamic, _Arity) ->
    dynamic.

apply_callee_signature(CallerMFA, Line, CalleeMFA, ArgAsts, ActualArgs, ExpectedArgs, RetType, Env0, Warns0, Sites) ->
    case check_call_site(CallerMFA, Line, CalleeMFA, lists:zip(ActualArgs, ExpectedArgs)) of
        [] ->
            Env1 = lists:foldl(
                fun({Ast, Exp}, EAcc) -> constrain_ast_var(Ast, Exp, EAcc) end,
                Env0,
                lists:zip(ArgAsts, ExpectedArgs)
            ),
            {RetType, Env1, Warns0, Sites};
        CallWarns ->
            {none, Env0, CallWarns ++ Warns0, Sites}
    end.

%% @doc Checks a call site's actual vs expected argument types for disjointness.
-spec check_call_site(
    mfa_key(),
    non_neg_integer(),
    mfa_key(),
    [{spectra_type:stype(), spectra_type:stype()}]
) -> [#spectra_warning{}].
check_call_site(CallerMFA, Line, {CM, CF, CA}, ZipArgs) ->
    {Warns, _} = lists:foldl(
        fun({Actual, Expected}, {WAcc, Idx}) ->
            case spectra_type:meet(Expected, Actual) of
                none when Actual =/= none, Expected =/= none ->
                    Msg = iolist_to_binary(
                        io_lib:format(
                            "Call to ~s:~s/~B will fail: argument #~B of type ~p is disjoint from expected ~p",
                            [CM, CF, CA, Idx, Actual, Expected]
                        )
                    ),
                    W = #spectra_warning{
                        kind = discrepancy,
                        mfa = CallerMFA,
                        line = Line,
                        message = Msg,
                        callee = {CM, CF, CA},
                        arg_idx = Idx,
                        actual = Actual,
                        expected = Expected
                    },
                    {[W | WAcc], Idx + 1};
                _ ->
                    {WAcc, Idx + 1}
            end
        end,
        {[], 1},
        ZipArgs
    ),
    lists:reverse(Warns).

%% The value of `L andalso R` / `L orelse R` given what L may be.
short_circuit_type(Op, LType, RType) ->
    {Deciding, Passes} = case Op of
        'andalso' -> {{atom_lit, false}, {atom_lit, true}};
        'orelse' -> {{atom_lit, true}, {atom_lit, false}}
    end,
    Decides = spectra_type:meet(LType, Deciding) =/= none,
    RightRuns = spectra_type:meet(LType, Passes) =/= none,
    spectra_type:normalize_union([T || {true, T} <- [{Decides, Deciding}, {RightRuns, RType}]]).

%% Return types that depend on the argument: tl([1 | 2]) is 2, not a list.
bif_return_type(tl, [ArgType], _Static) ->
    case list_tail_type(ArgType) of
        none -> {list, any};
        Tail -> Tail
    end;
bif_return_type(_Bif, _ArgTypes, Static) ->
    Static.

bif_signature(length, 1) -> {ok, [{list, any}], non_neg_integer};
bif_signature(byte_size, 1) -> {ok, [{binary, 0, 1}], non_neg_integer};
bif_signature(bit_size, 1) -> {ok, [{binary, 0, 1}], non_neg_integer};
bif_signature(tuple_size, 1) -> {ok, [any_tuple], non_neg_integer};
bif_signature(map_size, 1) -> {ok, [any_map], non_neg_integer};
%% hd/1 and tl/1 take any non-empty list, proper or not; the type has no "non-empty improper list", so [] is let through.
bif_signature(hd, 1) -> {ok, [{improper_list, any, any}], any};
bif_signature(tl, 1) -> {ok, [{improper_list, any, any}], {list, any}};
bif_signature(abs, 1) -> {ok, [number], number};
bif_signature(trunc, 1) -> {ok, [number], integer};
bif_signature(round, 1) -> {ok, [number], integer};
bif_signature(float, 1) -> {ok, [number], float};
bif_signature(atom_to_binary, 1) -> {ok, [atom], {binary, 0, 8}};
bif_signature(atom_to_list, 1) -> {ok, [atom], {list, {int_range, 0, 16#10ffff}}};
bif_signature(integer_to_binary, 1) -> {ok, [integer], {binary, 0, 8}};
bif_signature(integer_to_list, 1) -> {ok, [integer], {nonempty_list, {int_range, 0, 255}}};
bif_signature(binary_to_list, 1) -> {ok, [{binary, 0, 8}], {list, {int_range, 0, 255}}};
bif_signature(list_to_binary, 1) -> {ok, [{list, any}], {binary, 0, 8}};
bif_signature(element, 2) -> {ok, [pos_integer, any_tuple], any};
bif_signature(is_integer, 1) -> {ok, [any], boolean};
bif_signature(is_float, 1) -> {ok, [any], boolean};
bif_signature(is_number, 1) -> {ok, [any], boolean};
bif_signature(is_atom, 1) -> {ok, [any], boolean};
bif_signature(is_boolean, 1) -> {ok, [any], boolean};
bif_signature(is_binary, 1) -> {ok, [any], boolean};
bif_signature(is_bitstring, 1) -> {ok, [any], boolean};
bif_signature(is_list, 1) -> {ok, [any], boolean};
bif_signature(is_tuple, 1) -> {ok, [any], boolean};
bif_signature(is_map, 1) -> {ok, [any], boolean};
bif_signature(_, _) -> error.

make_warning(Kind, MFA, Anno, Msg) ->
    #spectra_warning{
        kind = Kind,
        mfa = MFA,
        line = erl_anno:line(Anno),
        message = Msg
    }.

is_generated_function({_Mod, Fun, _Arity}) when is_atom(Fun) ->
    case atom_to_binary(Fun, utf8) of
        <<"__", _/binary>> -> true;
        _ -> false
    end;
is_generated_function(_) ->
    false.

seed_arg_types(MFA, Arity, AllContracts) ->
    case maps:find(MFA, AllContracts) of
        {ok, #func_contract{declared_specs = [_ | _] = Specs}} ->
            SpecArgLists = lists:filtermap(
                fun(Spec) ->
                    case spectra_type:unfold_bounded_fun(Spec) of
                        {fun_type, SpecArgs, _} when length(SpecArgs) =:= Arity ->
                            {true, [sanitize_seed_type(A) || A <- SpecArgs]};
                        _ ->
                            false
                    end
                end,
                Specs
            ),
            case SpecArgLists of
                [] ->
                    lists:duplicate(Arity, any);
                _ ->
                    lists:map(
                        fun(Idx) ->
                            Col = [lists:nth(Idx, Args) || Args <- SpecArgLists],
                            spectra_type:normalize_union(Col)
                        end,
                        lists:seq(1, Arity)
                    )
            end;
        _ ->
            lists:duplicate(Arity, any)
    end.

sanitize_seed_type({local_type, _, _}) -> any;
sanitize_seed_type({remote_type, _, _, _}) -> any;
sanitize_seed_type({list, E}) -> {list, sanitize_seed_type(E)};
sanitize_seed_type({nonempty_list, E}) -> {nonempty_list, sanitize_seed_type(E)};
sanitize_seed_type({tuple, Es}) -> {tuple, [sanitize_seed_type(E) || E <- Es]};
sanitize_seed_type({union, Ms}) -> spectra_type:normalize_union([sanitize_seed_type(M) || M <- Ms]);
sanitize_seed_type(Other) -> Other.

update_map_type({map, BaseFields}, NewFields) ->
    NewKeys = [K || {_Kind, K, _V} <- NewFields],
    KeptBase = [F || {_BKind, BK, _BV} = F <- BaseFields, not lists:member(BK, NewKeys)],
    {map, lists:usort(KeptBase ++ NewFields)};
update_map_type({union, Members}, NewFields) ->
    spectra_type:normalize_union([update_map_type(M, NewFields) || M <- Members]);
update_map_type(_, NewFields) ->
    {map, lists:usort(NewFields)}.
