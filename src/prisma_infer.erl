%% @doc Success Typing inference and discrepancy analyzer over Erlang Abstract Format.
%%
%% Infers function argument domains and return types without false positives,
%% detecting guaranteed runtime failures (badarith, badmatch, case_clause,
%% unreachable branches, and incompatible calls).
-module(prisma_infer).

-include("prisma.hrl").

-export([
    infer_module_functions/3,
    check_call_site/4,
    declared_return/2,
    declared_return/3,
    extract_leex_token_map/2
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
    IsLeex = maps:is_key({Mod, yyaction, 5}, ClausesMap) andalso maps:is_key({Mod, yystate, 7}, ClausesMap),
    IsYecc = maps:is_key({Mod, yeccpars0, 5}, ClausesMap) andalso maps:is_key({Mod, yeccpars1, 7}, ClausesMap),
    Own = [MFA || MFA <- maps:keys(InitialContracts),
                  maps:is_key(MFA, ClausesMap),
                  not is_skipped_table_func(Mod, MFA, IsLeex, IsYecc)],
    Contracts1 = fixpoint_loop(Mod, ClausesMap, InitialContracts, 1, Own, callers_of(Mod, ClausesMap, InitialContracts, Own)),
    Contracts2 = case IsLeex of
        true -> refine_leex_contracts(Mod, Contracts1);
        false -> Contracts1
    end,
    case IsYecc of
        true -> refine_yecc_contracts(Mod, ClausesMap, Contracts2);
        false -> Contracts2
    end.

is_skipped_table_func(Mod, {Mod, yystate, 7}, true, _IsYecc) ->
    true;
is_skipped_table_func(Mod, {Mod, F, 7}, _IsLeex, true) ->
    case atom_to_binary(F, utf8) of
        <<"yeccpars2", _/binary>> -> true;
        <<"yeccgoto_", _/binary>> -> true;
        _ -> false
    end;
is_skipped_table_func(_Mod, _MFA, _IsLeex, _IsYecc) ->
    false.

%% Each pass infers again only the functions that may give another answer: the first one all of them, then those that call (or are) a
%% function whose type changed in the last pass. The others would give the same type, warnings and call sites as they have: the inference of a
%% function depends on its own clauses and on the contracts of what it calls, and only the contracts of the functions of the module
%% change between passes (those of other modules are what their `-spec`s declare). `Callers` maps each function of the module to the
%% functions that call it.
fixpoint_loop(Mod, ClausesMap, Contracts, Pass, Dirty, Callers) ->
    NextContracts = lists:foldl(
        fun(MFA, Acc) ->
            {_Line, Clauses} = maps:get(MFA, ClausesMap),
            Acc#{MFA := infer_function(Mod, MFA, Clauses, maps:get(MFA, Acc), Contracts)}
        end,
        Contracts,
        Dirty
    ),
    Changed = [MFA || MFA <- Dirty, (maps:get(MFA, Contracts))#func_contract.inferred_type =/=
                                    (maps:get(MFA, NextContracts))#func_contract.inferred_type],
    case Pass >= ?MAX_FIXPOINT_PASSES orelse Changed =:= [] of
        true ->
            NextContracts;
        false ->
            NextDirty = lists:usort(lists:append([maps:get(MFA, Callers, []) || MFA <- Changed])),
            fixpoint_loop(Mod, ClausesMap, NextContracts, Pass + 1, NextDirty, Callers)
    end.

%% For each function of the module, the functions of the module that call it. Every call that looks like one counts, wherever it is
%% (a fun, a try, a comprehension...): a call that is not made does no harm, and one that is missed would leave a type out of date.
callers_of(Mod, ClausesMap, Contracts, Own) ->
    OwnSet = maps:from_list([{MFA, true} || MFA <- Own]),
    lists:foldl(
        fun(Caller, Acc) ->
            RawCalls = case maps:find(Caller, Contracts) of
                {ok, #func_contract{calls = [_ | _] = PreCalls}} ->
                    PreCalls;
                _ ->
                    {_Line, Clauses} = maps:get(Caller, ClausesMap),
                    called(Mod, Clauses)
            end,
            Callees = lists:usort([C || C <- RawCalls, maps:is_key(C, OwnSet)]),
            lists:foldl(fun(Callee, A) -> A#{Callee => [Caller | maps:get(Callee, A, [])]} end, Acc, Callees)
        end,
        #{},
        Own
    ).

called(Mod, {call, _, Target, Args}) ->
    Direct = case Target of
        {atom, _, F} -> [{Mod, F, length(Args)}];
        {remote, _, {atom, _, M}, {atom, _, F}} -> [{M, F, length(Args)}];
        _ -> []
    end,
    Direct ++ called(Mod, Target) ++ called(Mod, Args);
called(Mod, {'fun', _, {function, F, A}}) when is_atom(F), is_integer(A) ->
    [{Mod, F, A}];
called(_Mod, {'fun', _, {function, {atom, _, M}, {atom, _, F}, {integer, _, A}}}) ->
    [{M, F, A}];
called(Mod, T) when is_tuple(T) ->
    called(Mod, tuple_to_list(T));
called(Mod, L) when is_list(L) ->
    lists:append([called(Mod, X) || X <- L]);
called(_Mod, _) ->
    [].

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
    JoinedRet = prisma_type:normalize_union(lists:reverse(RetTypes)),
    InferredType = {fun_type, [prisma_type:widen(A) || A <- JoinedArgs], prisma_type:widen(JoinedRet)},
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
            prisma_type:normalize_union(Col)
        end,
        lists:seq(1, Arity)
    ).

infer_clause(Mod, MFA, {clause, Anno, PatArgs, Guards, Body}, AllContracts) ->
    SeedArgs = seed_arg_types(MFA, length(PatArgs), AllContracts),
    IsGen = is_generated_function(MFA) orelse is_generated_anno(Anno) orelse is_generated_guard(Guards),
    case bind_patterns(PatArgs, SeedArgs, #{}) of
        unreachable ->
            ClauseWarns = case IsGen of
                true -> [];
                false -> [make_warning(dead_code, MFA, Anno, <<"Function clause pattern cannot match">>)]
            end,
            {unreachable, ClauseWarns};
        {ok, PatTypes, Env0} ->
            TestWarns = case IsGen of
                true -> [];
                false -> guard_warnings(MFA, Guards, Env0, AllContracts)
            end,
            case apply_guard_disjunction(Guards, Env0, AllContracts) of
                unreachable ->
                    GuardWarns = case IsGen of
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
    prisma_type:meet(PatType, maps:get(V, Env, any));
refine_pat_type({match, _, P1, P2}, PatType, Env) ->
    prisma_type:meet(refine_pat_type(P1, PatType, Env), refine_pat_type(P2, PatType, Env));
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
    M = prisma_type:meet(Prev, Expected),
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
    {prisma_type:meet({int_lit, I}, Expected), Env};
bind_pattern({char, _, C}, Expected, Env) ->
    {prisma_type:meet({int_lit, C}, Expected), Env};
bind_pattern({op, _, '-', {integer, _, I}}, Expected, Env) ->
    {prisma_type:meet({int_lit, -I}, Expected), Env};
bind_pattern({float, _, _}, Expected, Env) ->
    {prisma_type:meet(float, Expected), Env};
bind_pattern({atom, _, A}, Expected, Env) ->
    {prisma_type:meet({atom_lit, A}, Expected), Env};
bind_pattern({nil, _}, Expected, Env) ->
    {prisma_type:meet(nil, Expected), Env};
bind_pattern({bin, _, _} = Pattern, Expected, Env) ->
    {prisma_type:meet({binary, 0, 8}, Expected), bind_variables_as_any(Pattern, Env)};
bind_pattern({string, _, S}, Expected, Env) ->
    StrType = case S of
        [] -> nil;
        _ -> {nonempty_list, {int_range, 0, 16#10ffff}}
    end,
    {prisma_type:meet(StrType, Expected), Env};
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
                            {prisma_type:meet(Cell, Expected), Env2}
                    end
            end
    end;
bind_pattern({tuple, _, _} = Pattern, {union, Members}, Env0) ->
    %% only the alternatives the pattern can match bind its variables: `{ok, B}` against `{ok, binary()} | {error, atom()}`
    %% makes B a binary, not a binary or an atom
    Bound = [R || {Type, _} = R <- [bind_pattern(Pattern, M, Env0) || M <- Members], Type =/= none],
    case Bound of
        [] -> {none, Env0};
        _ -> {prisma_type:normalize_union([T || {T, _} <- Bound]), join_envs([E || {_, E} <- Bound])}
    end;
bind_pattern({tuple, _, PatElems}, Expected, Env0) ->
    case extract_tuple_elems(length(PatElems), Expected) of
        none ->
            {none, Env0};
        ElemExpecteds ->
            case bind_patterns(PatElems, ElemExpecteds, Env0) of
                unreachable -> {none, Env0};
                {ok, BoundElems, Env1} -> {prisma_type:meet({tuple, BoundElems}, Expected), Env1}
            end
    end;
bind_pattern({map, _, Fields}, Expected, Env0) ->
    case prisma_type:meet(any_map, Expected) of
        none ->
            {none, Env0};
        _ ->
            bind_map_pat_fields(Fields, Expected, Env0, [])
    end;
bind_pattern({record, _, _, _} = Pattern, Expected, Env) ->
    {Expected, bind_variables_as_any(Pattern, Env)};
bind_pattern(_, Expected, Env) ->
    {Expected, Env}.

%% A pattern that is not looked into still binds its variables: they are recorded (as `any`), so that a later pattern knows that
%% they are bound and compares instead of catching everything.
bind_variables_as_any(Pattern, Env) ->
    lists:foldl(fun(Name, E) -> case maps:is_key(Name, E) of true -> E; false -> E#{Name => any} end end,
                Env, pattern_variables(Pattern)).

pattern_variables({var, _, '_'}) -> [];
pattern_variables({var, _, Name}) -> [Name];
pattern_variables(T) when is_tuple(T) -> pattern_variables(tuple_to_list(T));
pattern_variables([H | T]) -> pattern_variables(H) ++ pattern_variables(T);
pattern_variables(_) -> [].

bind_map_pat_fields([], Expected, Env, Acc) ->
    %% the keys of the pattern are not all the keys: with nothing known of the scrutinee it is a map, not a map with only those
    Type = case unresolved(Expected) of
        true -> any_map;
        false -> prisma_type:meet({map, lists:usort(Acc)}, Expected)
    end,
    {Type, Env};
bind_map_pat_fields([{map_field_exact, _, KAst, VP} | Rest], Expected, Env0, Acc) ->
    KType = literal_or_any(KAst),
    case bind_pattern(VP, any, Env0) of
        {none, Env1} -> {none, Env1};
        {VType, Env1} -> bind_map_pat_fields(Rest, Expected, Env1, [{exact, KType, VType} | Acc])
    end;
bind_map_pat_fields([_ | Rest], Expected, Env, Acc) ->
    bind_map_pat_fields(Rest, Expected, Env, Acc).

unresolved(any) -> true;
unresolved({var, _}) -> true;
unresolved({local_type, _, _}) -> true;
unresolved({remote_type, _, _, _}) -> true;
unresolved({opaque, _, _, _, _}) -> true;
unresolved({recursive_ref, _, _}) -> true;
unresolved(_) -> false.

literal_or_any({atom, _, A}) -> {atom_lit, A};
literal_or_any({integer, _, I}) -> {int_lit, I};
literal_or_any(_) -> any.

extract_list_elem(any) -> any;
extract_list_elem({list, E}) -> E;
extract_list_elem({nonempty_list, E}) -> E;
extract_list_elem({improper_list, E, _}) -> E;
extract_list_elem({union, Members}) ->
    prisma_type:normalize_union([extract_list_elem(M) || M <- Members]);
extract_list_elem(_) -> none.

%% The type of Tail in [H | Tail] when the whole cell has the given type. An unknown cell has an unknown tail (it may
%% be any term), and a maybe-improper list has either another cell, [] or its improper tail.
list_tail_type(any) -> any;
list_tail_type({list, E}) -> {list, E};
list_tail_type({nonempty_list, E}) -> {list, E};
list_tail_type({improper_list, _, T} = Improper) -> prisma_type:normalize_union([Improper, T]);
list_tail_type({union, Members}) -> prisma_type:normalize_union([list_tail_type(M) || M <- Members]);
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

apply_guard_disjunction([], Env, _Contracts) ->
    {ok, Env};
apply_guard_disjunction(ConjList, Env0, Contracts) ->
    ValidEnvs = lists:filtermap(
        fun(Conj) ->
            case apply_guard_conjunction(Conj, Env0, Contracts) of
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

apply_guard_conjunction([], Env, _Contracts) ->
    {ok, Env};
apply_guard_conjunction([Test | Rest], Env0, Contracts) ->
    case apply_guard_test(Test, Env0, Contracts) of
        unreachable -> unreachable;
        {ok, Env1} -> apply_guard_conjunction(Rest, Env1, Contracts)
    end.

%% What each test of a guard says when it is typed as an expression: a BIF given arguments of the wrong type fails whenever it is
%% evaluated, even if another alternative of the guard (`P =:= [] orelse hd(P) ...`) can still hold.
guard_warnings(MFA, Guards, Env, Contracts) ->
    case is_generated_function(MFA) of
        true ->
            [];
        false ->
            lists:append([begin
                              {_, _, Warns, _} = infer_expr(guard, MFA, Test, Env, Contracts, [], []),
                              Warns
                          end || Conj <- Guards, Test <- Conj])
    end.

%% A guard test that cannot succeed (a BIF given arguments of the wrong type, say) makes the guard fail, so the clause can
%% never match: the test is typed as an expression first, and `none` means that it fails.
apply_guard_test(Test, Env, Contracts) ->
    case guard_test_type(Test, Env, Contracts) of
        none -> unreachable;
        {atom_lit, false} -> unreachable;
        _ -> apply_guard_test_refining(Test, Env, Contracts)
    end.

guard_test_type(Test, Env, Contracts) ->
    {Type, _, _, _} = infer_expr(guard, {guard, guard, 0}, Test, Env, Contracts, [], []),
    Type.

apply_guard_test_refining({call, _, {remote, _, {atom, _, erlang}, {atom, _, Fun}}, Args}, Env, Contracts) ->
    apply_guard_bif(Fun, Args, Env, Contracts);
apply_guard_test_refining({call, _, {atom, _, Fun}, Args}, Env, Contracts) ->
    apply_guard_bif(Fun, Args, Env, Contracts);
apply_guard_test_refining({op, _, 'andalso', L, R}, Env0, Contracts) ->
    case apply_guard_test(L, Env0, Contracts) of
        unreachable -> unreachable;
        {ok, Env1} -> apply_guard_test(R, Env1, Contracts)
    end;
apply_guard_test_refining({op, _, 'and', L, R}, Env0, Contracts) ->
    apply_guard_test({op, 0, 'andalso', L, R}, Env0, Contracts);
apply_guard_test_refining({op, _, 'orelse', L, R}, Env0, Contracts) ->
    apply_guard_disjunction([[L], [R]], Env0, Contracts);
apply_guard_test_refining({op, _, Op, {var, _, V}, {integer, _, 0}}, Env, _Contracts)
  when Op =:= '>'; Op =:= '>='; Op =:= '<' ->
    refine_compare_zero(V, Op, Env);
apply_guard_test_refining({op, _, '==', {var, _, V}, {integer, _, I}}, Env, _Contracts) ->
    %% `==` compares numbers by value: X == 0 also holds for 0.0
    refine_var(V, {union, [{int_lit, I}, float]}, Env);
apply_guard_test_refining({op, _, Op, {var, _, V}, Lit}, Env, _Contracts)
  when Op =:= '=:='; Op =:= '==' ->
    refine_var(V, literal_or_any(Lit), Env);
apply_guard_test_refining({op, _, Op, Lit, {var, _, V}}, Env, _Contracts)
  when Op =:= '=:='; Op =:= '==' ->
    refine_var(V, literal_or_any(Lit), Env);
apply_guard_test_refining({atom, _, false}, _Env, _Contracts) ->
    unreachable;
apply_guard_test_refining(_, Env, _Contracts) ->
    {ok, Env}.

%% `V > 0`, `V >= 0`, `V < 0`. Floats qualify as well as integers, and, in the term order (numbers < atoms < ... <
%% lists), every non-number is greater than 0: so `>` and `>=` say nothing about V unless it is known to be a number, and
%% `<` is only true of negative numbers.
refine_compare_zero(V, Op, Env) ->
    Prev = maps:get(V, Env, any),
    KnownNumber = case Prev of
        any -> false;
        {var, _} -> false;
        _ -> prisma_type:consistent_subtype(Prev, number)
    end,
    Type = case Op of
        '<' -> {union, [neg_integer, float]};
        '>' when KnownNumber -> {union, [pos_integer, float]};
        '>=' when KnownNumber -> {union, [non_neg_integer, float]};
        _ -> any
    end,
    refine_var(V, Type, Env).

apply_guard_bif(GuardName, [{var, _, V}], Env, _Contracts) ->
    case guard_type(GuardName) of
        undefined -> {ok, Env};
        Type -> refine_var(V, Type, Env)
    end;
apply_guard_bif(is_record, [{var, _, V}, {atom, _, Tag}], Env, Contracts) ->
    case maps:get({record_def, Tag}, Contracts, undefined) of
        Size when is_integer(Size), Size >= 1 ->
            refine_record_with_size(V, Tag, Size, Env);
        _ ->
            refine_var(V, {record, Tag, []}, Env)
    end;
apply_guard_bif(is_record, [{var, _, V}, {atom, _, Tag}, {integer, _, Size}], Env, _Contracts) ->
    refine_record_with_size(V, Tag, Size, Env);
apply_guard_bif(is_record, [{var, _, V}, _Tag], Env, _Contracts) ->
    refine_var(V, any_tuple, Env);
apply_guard_bif(is_record, [{var, _, V}, _Tag, {integer, _, Size}], Env, _Contracts) when Size >= 1 ->
    refine_var(V, {tuple, lists:duplicate(Size, any)}, Env);
apply_guard_bif(is_record, [{var, _, V}, _Tag, _Size], Env, _Contracts) ->
    refine_var(V, any_tuple, Env);
apply_guard_bif(is_map_key, [_Key, {var, _, V}], Env, _Contracts) ->
    refine_var(V, any_map, Env);
apply_guard_bif(is_function, [{var, _, V}, {integer, _, Arity}], Env, _Contracts) when Arity >= 0 ->
    refine_var(V, {fun_type, lists:duplicate(Arity, any), any}, Env);
apply_guard_bif(is_function, [{var, _, V}, _Arity], Env, _Contracts) ->
    refine_var(V, any_fun, Env);
apply_guard_bif(element, [{integer, _, Pos}, {var, _, V}], Env, _Contracts) when Pos >= 1 ->
    refine_var(V, any_tuple, Env);
apply_guard_bif(_, _, Env, _Contracts) ->
    {ok, Env}.

refine_record_with_size(V, Tag, Size, Env) when is_integer(Size), Size >= 1 ->
    TupleType = {tuple, [{atom_lit, Tag} | lists:duplicate(Size - 1, any)]},
    refine_var(V, TupleType, Env);
refine_record_with_size(V, Tag, _Size, Env) ->
    refine_var(V, {record, Tag, []}, Env).

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
    case prisma_type:meet(Prev, Type) of
        none -> unreachable;
        M -> {ok, Env#{V => M}}
    end.

%% The environment after several alternatives: a variable keeps a type only if every alternative constrains it (one that
%% does not leaves it unconstrained, which is `any`, not nothing).
join_envs([First | Rest]) ->
    maps:fold(
        fun(K, V, Acc) ->
            case lists:all(fun(E) -> maps:is_key(K, E) end, Rest) of
                true -> Acc#{K => lists:foldl(fun(E, T) -> prisma_type:join(T, maps:get(K, E)) end, V, Rest)};
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
    %% `#{k => V}` has the key k: a literal key is a required field of the type, not an optional one
    Exact = [case F of {assoc, {atom_lit, _} = K, V} -> {exact, K, V};
                       {assoc, {int_lit, _} = K, V} -> {exact, K, V};
                       _ -> F end || F <- MapFields],
    {{map, lists:usort(Exact)}, Env1, Warns1, Sites1};
infer_expr(Mod, MFA, {map, Anno, Base, Fields}, Env0, Contracts, Warns0, Sites0) ->
    {BaseType, Env1, Warns1, Sites1} = infer_expr(Mod, MFA, Base, Env0, Contracts, Warns0, Sites0),
    case prisma_type:meet(BaseType, any_map) of
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
    case depends_on_the_system(Scrutinee) of
        false ->
            infer_case(Mod, MFA, Anno, ScrutType, Clauses, Env1, Contracts, Warns1, Sites1);
        true ->
            %% The branches depend on what the running system has. Where the condition can be decided on the system that runs the
            %% analysis, the branch that it takes is checked like any other (it runs here) and the ones it does not take are not an error
            %% of this system; where it cannot, nothing that depends on the system is said in any of them. A branch that another Erlang
            %% would take is not dead code either.
            Mode = case env_value(Scrutinee) of
                {ok, Value} -> {known, Value};
                unknown -> unknown
            end,
            Marked = mark_clauses(Clauses, Mode),
            {Type, EnvOut, Warns2, Sites2} =
                infer_case(Mod, MFA, Anno, ScrutType, Marked, Env1, Contracts, Warns1, Sites1),
            New = lists:sublist(Warns2, length(Warns2) - length(Warns1)),
            Kept = [W || W <- New, W#prisma_warning.kind =/= dead_code],
            %% What is not checked is counted (one note per case), not reported: it would be judged with the API of this OTP
            Note = case [C || {clause, _, _, _, [{'$env_branch', _, Body, _}]} = C <- Marked, contains_remote_call(Body)] of
                [] -> [];
                _ -> [make_warning(system_branch, MFA, Anno, <<"Branches that depend on the system were not checked">>)]
            end,
            {Type, EnvOut, Note ++ Kept ++ Warns1, Sites2}
    end;
%% The body of a branch of a case on the system, marked by `mark_clauses/2`.
infer_expr(Mod, MFA, {'$env_branch', _, Body, Status}, Env, Contracts, Warns0, Sites0) ->
    {Type, EnvOut, Warns, Sites} = infer_body(Mod, MFA, Body, tag_env(Env, environment), Contracts, Warns0, Sites0),
    Out = restore_tag(EnvOut, Env),
    case Status of
        not_taken -> {none, Out, Warns, Sites};
        uncertain -> {Type, Out, Warns, Sites}
    end;
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
%% `fun((A) -> B)`, which Prisma's own code showed on the first run).
infer_expr(Mod, MFA, {'fun', _, {clauses, Clauses}}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_nested_clauses(Mod, MFA, Clauses, Env, Contracts, Warns0, Sites0),
    {any, Env, Warns, Sites};
infer_expr(Mod, MFA, {named_fun, _, _Name, Clauses}, Env, Contracts, Warns0, Sites0) ->
    {Warns, Sites} = infer_nested_clauses(Mod, MFA, Clauses, Env, Contracts, Warns0, Sites0),
    {any, Env, Warns, Sites};
infer_expr(_Mod, _MFA, {'fun', _, _}, Env, _Contracts, Warns, Sites) ->
    {any, Env, Warns, Sites};
infer_expr(Mod, MFA, {'try', _, Body, OfClauses, CatchClauses, After}, Env, Contracts, Warns0, Sites0) ->
    BodyEnv = case catches(CatchClauses) of
        none -> Env;
        Handled -> tag_env(Env, Handled)
    end,
    {_, _, Warns1, Sites1} = infer_body(Mod, MFA, Body, BodyEnv, Contracts, Warns0, Sites0),
    {Warns2, Sites2} = infer_nested_clauses(Mod, MFA, OfClauses, Env, Contracts, Warns1, Sites1),
    {Warns3, Sites3} = infer_nested_clauses(Mod, MFA, CatchClauses, Env, Contracts, Warns2, Sites2),
    {_, _, Warns4, Sites4} = infer_body(Mod, MFA, After, Env, Contracts, Warns3, Sites3),
    {any, Env, Warns4, Sites4};
infer_expr(Mod, MFA, {'catch', _, Expr}, Env, Contracts, Warns0, Sites0) ->
    {_, _, Warns, Sites} = infer_expr(Mod, MFA, Expr, tag_env(Env, any_handled), Contracts, Warns0, Sites0),
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

contains_remote_call({call, _, {remote, _, _, _}, _}) -> true;
contains_remote_call(T) when is_tuple(T) -> lists:any(fun contains_remote_call/1, tuple_to_list(T));
contains_remote_call(L) when is_list(L) -> lists:any(fun contains_remote_call/1, L);
contains_remote_call(_) -> false.

%% The value of an expression that only looks at the system that runs the analysis, or `unknown`: the OTP release, the comparisons and
%% boolean operators over it, and `function_exported/3` of a module that can be loaded here.
env_value({atom, _, A}) -> {ok, A};
env_value({integer, _, I}) -> {ok, I};
env_value({string, _, S}) -> {ok, S};
env_value({call, _, {remote, _, {atom, _, erlang}, {atom, _, system_info}}, [{atom, _, otp_release}]}) ->
    {ok, erlang:system_info(otp_release)};
env_value({call, A, {atom, _, list_to_integer}, Args}) ->
    env_value({call, A, {remote, A, {atom, A, erlang}, {atom, A, list_to_integer}}, Args});
env_value({call, A, {atom, _, function_exported}, Args}) ->
    env_value({call, A, {remote, A, {atom, A, erlang}, {atom, A, function_exported}}, Args});
env_value({call, _, {remote, _, {atom, _, erlang}, {atom, _, list_to_integer}}, [Arg]}) ->
    case env_value(Arg) of
        {ok, S} when is_list(S) ->
            try {ok, list_to_integer(S)} catch _:_ -> unknown end;
        _ ->
            unknown
    end;
env_value({call, _, {remote, _, {atom, _, erlang}, {atom, _, function_exported}}, [{atom, _, M}, {atom, _, F}, {integer, _, A}]}) ->
    case code:ensure_loaded(M) of
        {module, M} -> {ok, erlang:function_exported(M, F, A)};
        _ -> unknown
    end;
env_value({op, _, Op, L, R}) when Op =:= '=='; Op =:= '=:='; Op =:= '/='; Op =:= '=/=';
                                  Op =:= '<'; Op =:= '>'; Op =:= '=<'; Op =:= '>=' ->
    case {env_value(L), env_value(R)} of
        {{ok, A}, {ok, B}} -> {ok, erlang:Op(A, B)};
        _ -> unknown
    end;
env_value({op, _, 'andalso', L, R}) ->
    case env_value(L) of
        {ok, false} -> {ok, false};
        {ok, true} -> env_value(R);
        _ -> unknown
    end;
env_value({op, _, 'orelse', L, R}) ->
    case env_value(L) of
        {ok, true} -> {ok, true};
        {ok, false} -> env_value(R);
        _ -> unknown
    end;
env_value({op, _, 'not', X}) ->
    case env_value(X) of
        {ok, B} when is_boolean(B) -> {ok, not B};
        _ -> unknown
    end;
env_value(_) ->
    unknown.

%% Wraps the body of each clause of a case on the system: a clause that the known value takes stays as it is (it is checked like any
%% other); one that it does not take, or that comes after a clause that takes it, is `not_taken`; and every clause is `uncertain` when the value
%% is not known, or the pattern or the guard cannot be decided.
mark_clauses(Clauses, Mode) ->
    mark_clauses(Clauses, Mode, false, []).

mark_clauses([], _Mode, _Shadowed, Acc) ->
    lists:reverse(Acc);
mark_clauses([{clause, A, Pats, Guards, Body} | Rest], Mode, Shadowed, Acc) ->
    {Status, NowShadowed} = case Mode of
        unknown ->
            {uncertain, Shadowed};
        {known, Value} ->
            case Shadowed of
                true -> {not_taken, true};
                false ->
                    case {pattern_match(Pats, Value), Guards} of
                        {false, _} -> {not_taken, false};
                        {true, []} -> {taken, true};
                        _ -> {uncertain, false}
                    end
            end
    end,
    NewBody = case Status of
        taken -> Body;
        _ -> [{'$env_branch', A, Body, Status}]
    end,
    mark_clauses(Rest, Mode, NowShadowed, [{clause, A, Pats, Guards, NewBody} | Acc]).

pattern_match([{atom, _, A}], V) -> V =:= A;
pattern_match([{integer, _, I}], V) -> V =:= I;
pattern_match([{string, _, S}], V) -> V =:= S;
pattern_match([{var, _, _}], _) -> true;
pattern_match(_, _) -> uncertain.

%% How the code protects a call, kept in the environment under a key that no variable has. `environment` wins over the `try` ones.
tag_env(Env, Tag) ->
    case maps:get('$call_tag', Env, undefined) of
        environment -> Env;
        _ -> Env#{'$call_tag' => Tag}
    end.

restore_tag(EnvOut, EnvBefore) ->
    case maps:find('$call_tag', EnvBefore) of
        {ok, Tag} -> EnvOut#{'$call_tag' => Tag};
        error -> maps:remove('$call_tag', EnvOut)
    end.

site(Env, Line, MFA, ArgTypes) ->
    case maps:get('$call_tag', Env, undefined) of
        undefined -> {Line, MFA, ArgTypes};
        Tag -> {Line, MFA, ArgTypes, Tag}
    end.

%% Whether an expression looks at what the running system has, so what it decides is not decided by the code: the calls below
%% (and comparisons or `andalso`/`orelse` of them).
depends_on_the_system({call, _, {remote, _, {atom, _, M}, {atom, _, F}}, Args}) ->
    lists:member({M, F}, [{erlang, function_exported}, {erlang, is_builtin}, {erlang, system_info}, {erlang, module_loaded},
                          {os, type}, {os, version}, {code, ensure_loaded}, {code, is_loaded}, {code, which}])
        orelse lists:any(fun depends_on_the_system/1, Args);
depends_on_the_system({call, _, {atom, _, F}, _}) when F =:= function_exported; F =:= is_builtin ->
    true;
depends_on_the_system(T) when is_tuple(T) ->
    lists:any(fun depends_on_the_system/1, tuple_to_list(T));
depends_on_the_system(L) when is_list(L) ->
    lists:any(fun depends_on_the_system/1, L);
depends_on_the_system(_) ->
    false.

%% What a `try` catches that matters for a call to a missing function (`error:undef`): `undef_handled` if a clause says so, `any_handled`
%% if a clause takes any error (`error:_`, `_:_`, `C:R`), `none` otherwise. A clause with a guard is not counted.
catches(CatchClauses) ->
    Kinds = [catch_kind(C) || C <- CatchClauses],
    case lists:member(undef_handled, Kinds) of
        true -> undef_handled;
        false ->
            case lists:member(any_handled, Kinds) of
                true -> any_handled;
                false -> none
            end
    end.

catch_kind({clause, _, [{tuple, _, [Class, Reason, _Stack]}], [], _Body}) ->
    case class_may_be_error(Class) of
        false -> none;
        true ->
            case Reason of
                {atom, _, undef} -> undef_handled;
                {var, _, _} -> any_handled;
                _ -> none
            end
    end;
catch_kind(_) ->
    none.

class_may_be_error({atom, _, error}) -> true;
class_may_be_error({var, _, _}) -> true;
class_may_be_error(_) -> false.

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
                case apply_guard_disjunction(Guards, Env1, Contracts) of
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
    LM = prisma_type:meet(LType, number),
    RM = prisma_type:meet(RType, number),
    case (LM =:= none andalso LType =/= none) orelse (RM =:= none andalso RType =/= none) of
        true ->
            Msg = iolist_to_binary(io_lib:format("Arithmetic operator '~s' will fail with badarith (~p, ~p)", [Op, LType, RType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        false ->
            Env1 = constrain_ast_var(LAst, number, constrain_ast_var(RAst, number, Env0)),
            %% an operand that is `any` may be a float or an integer: the result is unknown too, not `number`
            Ret = case LType =:= any orelse RType =:= any of
                true when LM =/= float, RM =/= float -> any;
                _ -> arith_result_type(Op, LM, RM)
            end,
            {Ret, Env1, Warns, Sites}
    end;
infer_binop(MFA, Anno, '/', LAst, LType, RAst, RType, Env0, Warns, Sites) ->
    LM = prisma_type:meet(LType, number),
    RM = prisma_type:meet(RType, number),
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
    LM = prisma_type:meet(LType, integer),
    RM = prisma_type:meet(RType, integer),
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
    case prisma_type:meet(LType, boolean) of
        none when LType =/= none ->
            Msg = iolist_to_binary(io_lib:format("Boolean operator '~s' will fail (~p, ~p)", [Op, LType, RType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        _ ->
            Env1 = constrain_ast_var(LAst, boolean, Env0),
            {short_circuit_type(Op, LType, RType), Env1, Warns, Sites}
    end;
infer_binop(MFA, Anno, Op, LAst, LType, RAst, RType, Env0, Warns, Sites)
  when Op =:= 'and'; Op =:= 'or'; Op =:= 'xor' ->
    LM = prisma_type:meet(LType, boolean),
    RM = prisma_type:meet(RType, boolean),
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
    case prisma_type:meet(LType, {list, any}) of
        none when LType =/= none ->
            Msg = iolist_to_binary(io_lib:format("List operator '~s' requires a list on the left-hand side, got ~p", [Op, LType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        _ ->
            Env1 = constrain_ast_var(LAst, {list, any}, Env0),
            Ret = case Op of '++' -> prisma_type:join(LType, RType); '--' -> LType end,
            {Ret, Env1, Warns, Sites}
    end;
infer_binop(_MFA, _Anno, Op, _LAst, LType, _RAst, RType, Env, Warns, Sites)
  when Op =:= '>'; Op =:= '>='; Op =:= '<'; Op =:= '=<';
       Op =:= '=='; Op =:= '/='; Op =:= '=:='; Op =:= '=/=' ->
    RetType = eval_relop(Op, LType, RType),
    {RetType, Env, Warns, Sites};
infer_binop(_MFA, _Anno, _Op, _LAst, _LType, _RAst, _RType, Env, Warns, Sites) ->
    {boolean, Env, Warns, Sites}.

eval_relop(Op, {int_lit, LVal}, {int_lit, RVal}) ->
    bool_to_lit(eval_raw_op(Op, LVal, RVal));
eval_relop(Op, {atom_lit, LVal}, {atom_lit, RVal}) ->
    bool_to_lit(eval_raw_op(Op, LVal, RVal));
eval_relop(Op, LType, {int_lit, 0}) ->
    eval_relop_zero(Op, LType);
eval_relop(Op, {int_lit, 0}, RType) ->
    eval_relop_zero_left(Op, RType);
eval_relop(Op, LType, RType)
  when Op =:= '=:='; Op =:= '=/=' ->
    case prisma_type:meet(LType, RType) of
        none when LType =/= none, RType =/= none ->
            bool_to_lit(Op =:= '=/=');
        _ ->
            boolean
    end;
eval_relop(Op, LType, RType)
  when Op =:= '=='; Op =:= '/=' ->
    case prisma_type:meet(LType, RType) of
        none when LType =/= none, RType =/= none ->
            case is_numeric_type(LType) andalso is_numeric_type(RType) of
                true -> boolean;
                false -> bool_to_lit(Op =:= '/=')
            end;
        _ ->
            boolean
    end;
eval_relop(_Op, _LType, _RType) ->
    boolean.

bool_to_lit(true) -> {atom_lit, true};
bool_to_lit(false) -> {atom_lit, false}.

eval_raw_op('>', L, R) -> L > R;
eval_raw_op('>=', L, R) -> L >= R;
eval_raw_op('<', L, R) -> L < R;
eval_raw_op('=<', L, R) -> L =< R;
eval_raw_op('==', L, R) -> L == R;
eval_raw_op('/=', L, R) -> L /= R;
eval_raw_op('=:=', L, R) -> L =:= R;
eval_raw_op('=/=', L, R) -> L =/= R.

eval_relop_zero(Op, LType) ->
    case {is_strictly_positive(LType), is_strictly_negative(LType), is_non_negative(LType)} of
        {true, _, _} ->
            case Op of
                '>' -> {atom_lit, true};
                '>=' -> {atom_lit, true};
                '<' -> {atom_lit, false};
                '=<' -> {atom_lit, false};
                '==' -> {atom_lit, false};
                '=:=' -> {atom_lit, false};
                '/=' -> {atom_lit, true};
                '=/=' -> {atom_lit, true};
                _ -> boolean
            end;
        {_, true, _} ->
            case Op of
                '<' -> {atom_lit, true};
                '=<' -> {atom_lit, true};
                '>' -> {atom_lit, false};
                '>=' -> {atom_lit, false};
                '==' -> {atom_lit, false};
                '=:=' -> {atom_lit, false};
                '/=' -> {atom_lit, true};
                '=/=' -> {atom_lit, true};
                _ -> boolean
            end;
        {_, _, true} ->
            case Op of
                '<' -> {atom_lit, false};
                '>=' -> {atom_lit, true};
                _ -> boolean
            end;
        _ ->
            boolean
    end.

eval_relop_zero_left(Op, RType) ->
    case {is_strictly_positive(RType), is_strictly_negative(RType), is_non_negative(RType)} of
        {true, _, _} ->
            case Op of
                '<' -> {atom_lit, true};
                '=<' -> {atom_lit, true};
                '>' -> {atom_lit, false};
                '>=' -> {atom_lit, false};
                '==' -> {atom_lit, false};
                '=:=' -> {atom_lit, false};
                '/=' -> {atom_lit, true};
                '=/=' -> {atom_lit, true};
                _ -> boolean
            end;
        {_, true, _} ->
            case Op of
                '>' -> {atom_lit, true};
                '>=' -> {atom_lit, true};
                '<' -> {atom_lit, false};
                '=<' -> {atom_lit, false};
                '==' -> {atom_lit, false};
                '=:=' -> {atom_lit, false};
                '/=' -> {atom_lit, true};
                '=/=' -> {atom_lit, true};
                _ -> boolean
            end;
        {_, _, true} ->
            case Op of
                '>' -> {atom_lit, false};
                '=<' -> {atom_lit, true};
                _ -> boolean
            end;
        _ ->
            boolean
    end.

is_strictly_positive({int_lit, N}) when is_integer(N), N > 0 -> true;
is_strictly_positive({int_range, Lo, _}) when is_integer(Lo), Lo > 0 -> true;
is_strictly_positive(pos_integer) -> true;
is_strictly_positive({union, Members}) ->
    Members =/= [] andalso lists:all(fun is_strictly_positive/1, Members);
is_strictly_positive(_) -> false.

is_strictly_negative({int_lit, N}) when is_integer(N), N < 0 -> true;
is_strictly_negative({int_range, _, Hi}) when is_integer(Hi), Hi < 0 -> true;
is_strictly_negative(neg_integer) -> true;
is_strictly_negative({union, Members}) ->
    Members =/= [] andalso lists:all(fun is_strictly_negative/1, Members);
is_strictly_negative(_) -> false.

is_non_negative({int_lit, N}) when is_integer(N), N >= 0 -> true;
is_non_negative({int_range, Lo, _}) when is_integer(Lo), Lo >= 0 -> true;
is_non_negative(pos_integer) -> true;
is_non_negative(non_neg_integer) -> true;
is_non_negative({union, Members}) ->
    Members =/= [] andalso lists:all(fun is_non_negative/1, Members);
is_non_negative(_) -> false.

is_numeric_type(integer) -> true;
is_numeric_type(pos_integer) -> true;
is_numeric_type(neg_integer) -> true;
is_numeric_type(non_neg_integer) -> true;
is_numeric_type(float) -> true;
is_numeric_type(number) -> true;
is_numeric_type({int_lit, _}) -> true;
is_numeric_type({int_range, _, _}) -> true;
is_numeric_type({union, Members}) ->
    Members =/= [] andalso lists:all(fun is_numeric_type/1, Members);
is_numeric_type(_) -> false.

infer_unop(MFA, Anno, 'not', ArgAst, ArgType, Env0, Warns, Sites) ->
    case prisma_type:meet(ArgType, boolean) of
        none when ArgType =/= none ->
            Msg = iolist_to_binary(io_lib:format("Unary 'not' requires boolean, got ~p", [ArgType])),
            {none, Env0, [make_warning(discrepancy, MFA, Anno, Msg) | Warns], Sites};
        _ ->
            {boolean, constrain_ast_var(ArgAst, boolean, Env0), Warns, Sites}
    end;
infer_unop(MFA, Anno, Op, ArgAst, ArgType, Env0, Warns, Sites)
  when Op =:= '-'; Op =:= '+' ->
    case prisma_type:meet(ArgType, number) of
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
    prisma_type:normalize_union(ProperPart ++ [cons_type(HType, M) || M <- Other]);
cons_type(HType, {improper_list, TailElem, TailEnd}) ->
    %% [H | improper_list(E, T)] is improper_list(H or E, T): the chain does not nest, however many cells are consed
    {improper_list, prisma_type:join(HType, TailElem), TailEnd};
cons_type(HType, TType) ->
    case proper_tail(TType) of
        true -> proper_cons(HType, TType);
        false -> {improper_list, HType, TType}
    end.

%% [H | T] where T is known to be a proper list (or a union of them).
proper_cons(HType, TType) ->
    ElemJoin = case extract_list_elem(TType) of
        none -> HType;
        TailElem -> prisma_type:join(HType, TailElem)
    end,
    {nonempty_list, ElemJoin}.

%% Is every value of the type a proper list? `any` and type variables are not known to be.
proper_tail(nil) -> true;
proper_tail({list, _}) -> true;
proper_tail({nonempty_list, _}) -> true;
proper_tail({union, Members}) -> lists:all(fun proper_tail/1, Members);
proper_tail(_) -> false.

%% The type of `-X` when X has the given numeric type (anything not modelled is just `number`).
-spec negate_type(prisma_type:stype()) -> prisma_type:stype().
negate_type(none) -> none;
negate_type({int_lit, I}) -> {int_lit, -I};
negate_type({int_range, Lo, Hi}) -> {int_range, negate_bound(Hi), negate_bound(Lo)};
negate_type(pos_integer) -> neg_integer;
negate_type(neg_integer) -> pos_integer;
negate_type(non_neg_integer) -> {int_range, neg_inf, 0};
negate_type({union, Members}) -> prisma_type:normalize_union([negate_type(M) || M <- Members]);
negate_type(T) when T =:= integer; T =:= float; T =:= number -> T;
negate_type(_) -> number.

negate_bound(neg_inf) -> pos_inf;
negate_bound(pos_inf) -> neg_inf;
negate_bound(N) when is_integer(N) -> -N.

arith_result_type(_Op, float, _) -> float;
arith_result_type(_Op, _, float) -> float;
arith_result_type(_Op, number, _) -> number;
arith_result_type(_Op, _, number) -> number;
arith_result_type('-', pos_integer, {int_lit, 1}) -> non_neg_integer;
arith_result_type(Op, L, R) -> integer_with_sign(Op, sign(L), sign(R)).

%% What is known of the sign of an integer type: positive, not negative, or nothing.
sign(pos_integer) -> pos;
sign(non_neg_integer) -> non_neg;
sign({int_lit, N}) when N > 0 -> pos;
sign({int_lit, 0}) -> non_neg;
sign({int_range, Lo, _}) when is_integer(Lo), Lo > 0 -> pos;
sign({int_range, Lo, _}) when is_integer(Lo), Lo >= 0 -> non_neg;
sign(_) -> unknown.

%% 9 + size is positive, two sizes added are not negative, a product of those too; a difference can be anything.
integer_with_sign('+', pos, S) when S =/= unknown -> pos_integer;
integer_with_sign('+', S, pos) when S =/= unknown -> pos_integer;
integer_with_sign('+', non_neg, non_neg) -> non_neg_integer;
integer_with_sign('*', pos, pos) -> pos_integer;
integer_with_sign('*', S1, S2) when S1 =/= unknown, S2 =/= unknown -> non_neg_integer;
integer_with_sign(_, _, _) -> integer.

constrain_ast_var({var, _, '_'}, _Type, Env) ->
    Env;
constrain_ast_var({var, _, V}, Type, Env) ->
    Prev = maps:get(V, Env, any),
    case prisma_type:meet(Prev, Type) of
        none -> Env;
        M -> Env#{V => M}
    end;
constrain_ast_var(_, _Type, Env) ->
    Env.

infer_case(Mod, MFA, Anno, ScrutType, Clauses, Env0, Contracts, Warns0, Sites0) ->
    IsCaseGen = is_generated_function(MFA) orelse is_generated_anno(Anno),
    {BranchRets, BranchEnvs, Warns1, Sites1, _Remaining} = lists:foldl(
        fun({clause, CAnno, Pats, CGuards, CBody}, {RetsAcc, EnvsAcc, WAcc, SAcc, Remaining}) ->
            IsClauseGen = IsCaseGen orelse is_generated_anno(CAnno) orelse is_generated_guard(CGuards),
            PatResult = case Pats of
                [SinglePat] -> bind_pattern(SinglePat, ScrutType, Env0);
                [] -> {any, Env0};
                _ -> {any, Env0}
            end,
            case PatResult of
                {none, _} when ScrutType =/= none ->
                    PWarns = case IsClauseGen of
                        true -> [];
                        false -> [make_warning(dead_code, MFA, CAnno, <<"Clause pattern cannot match scrutinee type">>)]
                    end,
                    {RetsAcc, EnvsAcc, PWarns ++ WAcc, SAcc, Remaining};
                _ ->
                    %% what is left of the scrutinee for this clause: what the earlier clauses without a guard did not take
                    case bind_clause_pattern(Pats, Remaining, Env0) of
                        none ->
                            %% covered by the clauses before it: nothing is said (a catch-all after exhaustive clauses is common)
                            {RetsAcc, EnvsAcc, WAcc, SAcc, Remaining};
                        {ok, CEnv0} ->
                            TestWarns = case IsClauseGen of
                                true -> [];
                                false -> guard_warnings(MFA, CGuards, CEnv0, Contracts)
                            end,
                            Remaining1 = case CGuards of
                                [] -> subtract_pattern(Remaining, Pats, Env0);
                                _ -> Remaining
                            end,
                            case apply_guard_disjunction(CGuards, CEnv0, Contracts) of
                                unreachable ->
                                    GWarns = case IsClauseGen of
                                        true -> [];
                                        false -> [make_warning(dead_code, MFA, CAnno, <<"Clause guard cannot succeed">>)]
                                    end,
                                    {RetsAcc, EnvsAcc, TestWarns ++ GWarns ++ WAcc, SAcc, Remaining1};
                                {ok, CEnv1} ->
                                    {CRet, CEnv2, WNext, SNext} = infer_body(Mod, MFA, CBody, CEnv1, Contracts, TestWarns ++ WAcc, SAcc),
                                    {[CRet | RetsAcc], [CEnv2 | EnvsAcc], WNext, SNext, Remaining1}
                            end
                    end
            end
        end,
        {[], [], Warns0, Sites0, ScrutType},
        Clauses
    ),
    case BranchEnvs of
        [] when ScrutType =/= none ->
            W = make_warning(discrepancy, MFA, Anno, <<"No case/if clause can match">>),
            {none, Env0, [W | Warns1], Sites1};
        [] ->
            {none, Env0, Warns1, Sites1};
        _ ->
            JoinedRet = prisma_type:normalize_union(lists:reverse(BranchRets)),
            JoinedEnv = join_envs(lists:reverse(BranchEnvs)),
            {JoinedRet, JoinedEnv, Warns1, Sites1}
    end.

%% The environment of a clause whose single pattern is matched against what is left of the scrutinee; `none` if nothing is left.
bind_clause_pattern([SinglePat], Remaining, Env0) ->
    case bind_pattern(SinglePat, Remaining, Env0) of
        {none, _} -> none;
        {_, Env} -> {ok, Env}
    end;
bind_clause_pattern(_, _Remaining, Env0) ->
    {ok, Env0}.

%% The scrutinee type without what a clause (with no guard) takes whole. Only a type that the pattern surely covers is removed.
subtract_pattern(Remaining, [SinglePat], Env) ->
    case closed_pattern(SinglePat, Env) of
        false ->
            %% a variable that is already bound is an equality test, not a catch-all: nothing is taken out
            Remaining;
        true ->
            case bind_pattern(SinglePat, any, #{}) of
                {none, _} -> Remaining;
                {PatType, _} -> subtract_covered(Remaining, PatType)
            end
    end;
subtract_pattern(Remaining, _, _Env) ->
    Remaining.

%% Atoms, numbers, strings, tuples and lists of those, `_`, and variables that are new (not bound before: the environment holds
%% every variable that a pattern has bound).
closed_pattern({var, _, '_'}, _Env) -> true;
closed_pattern({var, _, Name}, Env) -> not maps:is_key(Name, Env);
closed_pattern({atom, _, _}, _Env) -> true;
closed_pattern({integer, _, _}, _Env) -> true;
closed_pattern({char, _, _}, _Env) -> true;
closed_pattern({float, _, _}, _Env) -> true;
closed_pattern({string, _, _}, _Env) -> true;
closed_pattern({nil, _}, _Env) -> true;
closed_pattern({tuple, _, Elems}, Env) -> lists:all(fun(E) -> closed_pattern(E, Env) end, Elems);
closed_pattern({cons, _, H, T}, Env) -> closed_pattern(H, Env) andalso closed_pattern(T, Env);
closed_pattern({op, _, '-', {integer, _, _}}, _Env) -> true;
closed_pattern(_, _Env) -> false.

subtract_covered({union, Members}, PatType) ->
    prisma_type:normalize_union([M || M <- Members, not covers(PatType, M)]);
subtract_covered(Remaining, PatType) ->
    case covers(PatType, Remaining) of
        true -> none;
        false -> Remaining
    end.

%% Does a pattern of type P take every value of type M? `any` in the pattern (a variable) takes anything; an unknown in M (an `any`
%% or an unresolved name) is taken only by an equal one.
covers(any, _) -> true;
covers(_, none) -> true;
covers(_, any) -> false;
covers(P, {union, Ms}) -> lists:all(fun(M) -> covers(P, M) end, Ms);
covers({union, Ps}, M) -> lists:any(fun(P) -> covers(P, M) end, Ps);
covers(P, P) -> true;
covers({tuple, Ps}, {tuple, Ms}) when length(Ps) =:= length(Ms) ->
    lists:all(fun({P, M}) -> covers(P, M) end, lists:zip(Ps, Ms));
covers(P, M) ->
    not has_unknown(M) andalso prisma_type:consistent_subtype(M, P).

has_unknown(any) -> true;
has_unknown({var, _}) -> true;
has_unknown({local_type, _, _}) -> true;
has_unknown({remote_type, _, _, _}) -> true;
has_unknown({opaque, _, _, _, _}) -> true;
has_unknown({recursive_ref, _, _}) -> true;
has_unknown({union, Ms}) -> lists:any(fun has_unknown/1, Ms);
has_unknown({tuple, Es}) -> lists:any(fun has_unknown/1, Es);
has_unknown({list, E}) -> has_unknown(E);
has_unknown({nonempty_list, E}) -> has_unknown(E);
has_unknown({improper_list, E, T}) -> has_unknown(E) orelse has_unknown(T);
has_unknown({map, Fields}) -> lists:any(fun({_, K, V}) -> has_unknown(K) orelse has_unknown(V) end, Fields);
has_unknown(_) -> false.

infer_call(Mod, CallerMFA, Anno, Target, ArgAsts, ArgTypes, Env0, Contracts, Warns0, Sites0) ->
    Line = erl_anno:line(Anno),
    case resolve_call_target(Mod, Target, length(ArgTypes)) of
        {ok, {erlang, ExitFn, Arity} = CalleeMFA}
          when (ExitFn =:= error andalso (Arity =:= 1 orelse Arity =:= 2 orelse Arity =:= 3));
               (ExitFn =:= exit andalso Arity =:= 1);
               (ExitFn =:= throw andalso Arity =:= 1);
               (ExitFn =:= halt andalso (Arity =:= 0 orelse Arity =:= 1 orelse Arity =:= 2)) ->
            {none, Env0, Warns0, [{Line, CalleeMFA, ArgTypes} | Sites0]};
        {ok, {erlang, Bif, Arity} = CalleeMFA} ->
            Sites1 = [site(Env0, Line, CalleeMFA, ArgTypes) | Sites0],
            case bif_signature(Bif, Arity) of
                {ok, ExpectedArgs, RetType0} ->
                    RetType = bif_return_type(Bif, ArgTypes, RetType0, Contracts),
                    apply_callee_signature(CallerMFA, Line, CalleeMFA, ArgAsts, ArgTypes, ExpectedArgs, RetType, Env0, Warns0, Sites1);
                error ->
                    {any, Env0, Warns0, Sites1}
            end;
        {ok, CalleeMFA} ->
            Sites1 = [site(Env0, Line, CalleeMFA, ArgTypes) | Sites0],
            case maps:find('$yecc_local_clauses', Contracts) of
                {ok, LocalClauses} when is_map_key(CalleeMFA, LocalClauses) ->
                    case infer_yecc_helper_call(Mod, CalleeMFA, ArgTypes, LocalClauses, Contracts) of
                        {ok, HelperRet} ->
                            {HelperRet, Env0, Warns0, Sites1};
                        error ->
                            infer_contract_call(CallerMFA, Line, CalleeMFA, ArgAsts, ArgTypes, Env0, Contracts, Warns0, Sites1)
                    end;
                _ ->
                    infer_contract_call(CallerMFA, Line, CalleeMFA, ArgAsts, ArgTypes, Env0, Contracts, Warns0, Sites1)
            end;
        dynamic ->
            {any, Env0, Warns0, Sites0}
    end.

infer_contract_call(CallerMFA, Line, CalleeMFA, ArgAsts, ArgTypes, Env0, Contracts, Warns0, Sites1) ->
    case maps:find(CalleeMFA, Contracts) of
        {ok, #func_contract{inferred_type = {fun_type, ExpectedArgs, Inferred}, declared_specs = Specs}} ->
            %% what the callee declares, not what its body happens to give: if the body contradicts the spec the
            %% warning belongs to the callee, and its callers are not named for it
            RetType = case declared_return(Specs, length(ExpectedArgs), ArgTypes) of
                any -> Inferred;
                Declared -> Declared
            end,
            apply_callee_signature(CallerMFA, Line, CalleeMFA, ArgAsts, ArgTypes, ExpectedArgs, RetType, Env0, Warns0, Sites1,
                                   Specs =/= []);
        _ ->
            {any, Env0, Warns0, Sites1}
    end.

infer_yecc_helper_call(Mod, CalleeMFA, ArgTypes, LocalClauses, Contracts) ->
    {_Line, Clauses} = maps:get(CalleeMFA, LocalClauses),
    SubContracts = Contracts#{'$yecc_local_clauses' => maps:remove(CalleeMFA, LocalClauses)},
    Rets = lists:filtermap(
        fun({clause, _, PatArgs, Guards, Body}) ->
            case bind_patterns(PatArgs, ArgTypes, #{}) of
                unreachable ->
                    false;
                {ok, _PatTypes, CEnv0} ->
                    case apply_guard_disjunction(Guards, CEnv0, SubContracts) of
                        unreachable ->
                            false;
                        {ok, CEnv1} ->
                            {Ret, _, _, _} = infer_body(Mod, CalleeMFA, Body, CEnv1, SubContracts, [], []),
                            {true, Ret}
                    end
            end
        end,
        Clauses
    ),
    case Rets of
        [] -> error;
        _ -> {ok, prisma_type:normalize_union(Rets)}
    end.

%% The return type that the specs of a function declare (`any` if there is none or it says nothing). Names that cannot be resolved
%% here (`t()`, `other:t()`, an opaque, a type variable) are unknown, not impossible: a pattern does not match against them.
-spec declared_return([prisma_type:stype()], non_neg_integer()) -> prisma_type:stype().
declared_return(Specs, Arity) ->
    declared_return(Specs, Arity, []).

-spec declared_return([prisma_type:stype()], non_neg_integer(), [prisma_type:stype()]) -> prisma_type:stype().
declared_return(Specs, Arity, ArgTypes) ->
    Clauses = [
        {Args, Ret}
     || Spec <- Specs,
        {fun_type, Args, Ret} <- [prisma_type:unfold_bounded_fun(Spec)],
        length(Args) =:= Arity
    ],
    Matching = case ArgTypes of
        [] ->
            [Ret || {_, Ret} <- Clauses];
        _ when length(ArgTypes) =:= Arity ->
            Compatible = [
                Ret
             || {DeclArgs, Ret} <- Clauses,
                lists:all(
                    fun({Actual, Decl}) ->
                        Actual =:= any orelse Decl =:= any orelse prisma_type:meet(Actual, Decl) =/= none
                    end,
                    lists:zip(ArgTypes, DeclArgs)
                )
            ],
            case Compatible of
                [] -> [Ret || {_, Ret} <- Clauses];
                _ -> Compatible
            end;
        _ ->
            [Ret || {_, Ret} <- Clauses]
    end,
    case Matching of
        [] -> any;
        _ -> erase_unresolved(prisma_type:normalize_union(Matching))
    end.

erase_unresolved({local_type, _, _}) -> any;
erase_unresolved({remote_type, _, _, _}) -> any;
erase_unresolved({opaque, _, _, _, _}) -> any;
erase_unresolved({recursive_ref, _, _}) -> any;
erase_unresolved({var, _}) -> any;
erase_unresolved({union, Members}) -> prisma_type:normalize_union([erase_unresolved(M) || M <- Members]);
erase_unresolved({tuple, Elems}) -> {tuple, [erase_unresolved(E) || E <- Elems]};
erase_unresolved({list, E}) -> {list, erase_unresolved(E)};
erase_unresolved({nonempty_list, E}) -> {nonempty_list, erase_unresolved(E)};
erase_unresolved({improper_list, E, T}) -> {improper_list, erase_unresolved(E), erase_unresolved(T)};
erase_unresolved({map, Fields}) ->
    Erased = [{Kind, erase_unresolved(K), erase_unresolved(V)} || {Kind, K, V} <- Fields],
    %% a required key that was a type variable (`#{Key := Value, _ => _}`, maps:update/3) is unknown, not "some key": the map is just a map
    case lists:any(fun({exact, any, _}) -> true; (_) -> false end, Erased) of
        true -> any_map;
        false -> {map, Erased}
    end;
erase_unresolved({record, Name, Fields}) -> {record, Name, [{F, erase_unresolved(T)} || {F, T} <- Fields]};
erase_unresolved({fun_type, Args, Ret}) -> {fun_type, [erase_unresolved(A) || A <- Args], erase_unresolved(Ret)};
erase_unresolved(Other) -> Other.

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
    apply_callee_signature(CallerMFA, Line, CalleeMFA, ArgAsts, ActualArgs, ExpectedArgs, RetType, Env0, Warns0, Sites, true).

is_union_type({union, _}) -> true;
is_union_type(_) -> false.

%% `Narrow`: an argument that is a variable takes the type the callee expects. When the callee has no `-spec` and what it expects is a
%% union (a function with clauses for a tuple, `none` and a map), that was inferred from the callee's own clauses and is wider than
%% what the caller really passes: a variable that nothing is known of must not become that union, because a later call that
%% needs a map would find `none` and a tuple in it. A single type (`integer`) is still taken: it is how the parameters of a function
%% are inferred.
apply_callee_signature(CallerMFA, Line, CalleeMFA, ArgAsts, ActualArgs, ExpectedArgs, RetType, Env0, Warns0, Sites, Narrow) ->
    case check_call_site(CallerMFA, Line, CalleeMFA, lists:zip(ActualArgs, ExpectedArgs)) of
        [] ->
            Env1 = lists:foldl(
                fun({Ast, Exp}, EAcc) ->
                    case Narrow orelse not is_union_type(Exp) of
                        true -> constrain_ast_var(Ast, Exp, EAcc);
                        false -> EAcc
                    end
                end,
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
    [{prisma_type:stype(), prisma_type:stype()}]
) -> [#prisma_warning{}].
check_call_site(CallerMFA, Line, {CM, CF, CA}, ZipArgs) ->
    {Warns, _} = lists:foldl(
        fun({Actual, Expected}, {WAcc, Idx}) ->
            case prisma_type:meet(Expected, Actual) of
                none when Actual =/= none, Expected =/= none ->
                    Msg = iolist_to_binary(
                        io_lib:format(
                            "Call to ~s:~s/~B will fail: argument #~B of type ~p is disjoint from expected ~p",
                            [CM, CF, CA, Idx, Actual, Expected]
                        )
                    ),
                    W = #prisma_warning{
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
    Decides = prisma_type:meet(LType, Deciding) =/= none,
    RightRuns = prisma_type:meet(LType, Passes) =/= none,
    prisma_type:normalize_union([T || {true, T} <- [{Decides, Deciding}, {RightRuns, RType}]]).

%% Return types that depend on the argument: tl([1 | 2]) is 2, not a list.
bif_return_type(tl, [ArgType], _Static, _Contracts) ->
    case list_tail_type(ArgType) of
        none -> {list, any};
        Tail -> Tail
    end;
bif_return_type(is_record, [TermType, {atom_lit, Tag}], _Static, Contracts) ->
    TupleType = case maps:get({record_def, Tag}, Contracts, undefined) of
        Size when is_integer(Size), Size >= 1 ->
            {tuple, [{atom_lit, Tag} | lists:duplicate(Size - 1, any)]};
        _ ->
            {record, Tag, []}
    end,
    case prisma_type:meet(TermType, TupleType) of
        none when TermType =/= none -> {atom_lit, false};
        _ ->
            case TermType =/= any andalso not has_unknown(TermType) andalso prisma_type:consistent_subtype(TermType, TupleType) of
                true -> {atom_lit, true};
                false -> boolean
            end
    end;
bif_return_type(is_record, [TermType, {atom_lit, Tag}, {int_lit, Size}], _Static, _Contracts) when Size >= 1 ->
    TupleType = {tuple, [{atom_lit, Tag} | lists:duplicate(Size - 1, any)]},
    case prisma_type:meet(TermType, TupleType) of
        none when TermType =/= none -> {atom_lit, false};
        _ ->
            case TermType =/= any andalso not has_unknown(TermType) andalso prisma_type:consistent_subtype(TermType, TupleType) of
                true -> {atom_lit, true};
                false -> boolean
            end
    end;
bif_return_type(is_function, [TermType, {int_lit, Arity}], _Static, _Contracts) when Arity >= 0 ->
    FunType = {fun_type, lists:duplicate(Arity, any), any},
    case prisma_type:meet(TermType, any_fun) of
        none when TermType =/= none -> {atom_lit, false};
        _ ->
            case TermType =/= any andalso not has_unknown(TermType) andalso prisma_type:consistent_subtype(TermType, FunType) of
                true -> {atom_lit, true};
                false -> boolean
            end
    end;
bif_return_type(element, [{int_lit, N}, TupleType], _Static, _Contracts) when N >= 1 ->
    tuple_elem_type(N, TupleType);
bif_return_type(_Bif, _ArgTypes, Static, _Contracts) ->
    Static.

tuple_elem_type(N, {tuple, Elems}) when N >= 1, N =< length(Elems) ->
    lists:nth(N, Elems);
tuple_elem_type(1, {record, Tag, _}) ->
    {atom_lit, Tag};
tuple_elem_type(N, {union, Members}) ->
    prisma_type:normalize_union([tuple_elem_type(N, M) || M <- Members]);
tuple_elem_type(_N, _Other) ->
    any.

bif_signature(length, 1) -> {ok, [{list, any}], non_neg_integer};
%% BIFs that always return integers. Arguments are left as `any`: their types are checked against the spec of the BIF elsewhere.
bif_signature(iolist_size, 1) -> {ok, [any], non_neg_integer};
bif_signature(size, 1) -> {ok, [any], non_neg_integer};
bif_signature(external_size, 1) -> {ok, [any], non_neg_integer};
bif_signature(external_size, 2) -> {ok, [any, any], non_neg_integer};
bif_signature(phash2, 1) -> {ok, [any], non_neg_integer};
bif_signature(phash2, 2) -> {ok, [any, any], non_neg_integer};
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
bif_signature(list_to_integer, 1) -> {ok, [{list, any}], integer};
bif_signature(list_to_integer, 2) -> {ok, [{list, any}, pos_integer], integer};
bif_signature(list_to_float, 1) -> {ok, [{list, any}], float};
bif_signature(binary_to_integer, 1) -> {ok, [{binary, 0, 8}], integer};
bif_signature(binary_to_integer, 2) -> {ok, [{binary, 0, 8}, pos_integer], integer};
bif_signature(binary_to_float, 1) -> {ok, [{binary, 0, 8}], float};
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
bif_signature(is_pid, 1) -> {ok, [any], boolean};
bif_signature(is_port, 1) -> {ok, [any], boolean};
bif_signature(is_reference, 1) -> {ok, [any], boolean};
bif_signature(is_function, 1) -> {ok, [any], boolean};
bif_signature(is_function, 2) -> {ok, [any, non_neg_integer], boolean};
bif_signature(is_record, 2) -> {ok, [any, atom], boolean};
bif_signature(is_record, 3) -> {ok, [any, atom, integer], boolean};
bif_signature(is_map_key, 2) -> {ok, [any, any_map], boolean};
bif_signature(_, _) -> error.

make_warning(Kind, MFA, Anno, Msg) ->
    #prisma_warning{
        kind = Kind,
        mfa = MFA,
        line = erl_anno:line(Anno),
        message = Msg
    }.

is_generated_function({_Mod, Fun, _Arity}) when is_atom(Fun) ->
    case atom_to_binary(Fun, utf8) of
        <<"__", _/binary>> -> true;
        Bin ->
            binary:match(Bin, <<" (overridable ">>) =/= nomatch
    end;
is_generated_function(_) ->
    false.

is_generated_anno(Anno) ->
    try
        erl_anno:generated(Anno)
    catch
        _:_ ->
            case is_list(Anno) of
                true -> proplists:get_value(generated, Anno, false) =:= true;
                false -> false
            end
    end.

is_generated_guard(Guards) when is_list(Guards) ->
    lists:any(fun(Conj) ->
        is_list(Conj) andalso lists:any(fun is_generated_ast/1, Conj)
    end, Guards);
is_generated_guard(_) ->
    false.

is_generated_ast(Node) when is_tuple(Node), tuple_size(Node) >= 2 ->
    Anno = element(2, Node),
    is_generated_anno(Anno);
is_generated_ast(_) ->
    false.

seed_arg_types(MFA, Arity, AllContracts) ->
    case maps:find(MFA, AllContracts) of
        {ok, #func_contract{declared_specs = [_ | _] = Specs}} ->
            SpecArgLists = lists:filtermap(
                fun(Spec) ->
                    case prisma_type:unfold_bounded_fun(Spec) of
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
                            prisma_type:normalize_union(Col)
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
sanitize_seed_type({union, Ms}) -> prisma_type:normalize_union([sanitize_seed_type(M) || M <- Ms]);
sanitize_seed_type(Other) -> Other.

update_map_type({map, BaseFields}, NewFields) ->
    NewKeys = [K || {_Kind, K, _V} <- NewFields],
    KeptBase = [F || {_BKind, BK, _BV} = F <- BaseFields, not lists:member(BK, NewKeys)],
    {map, lists:usort(KeptBase ++ NewFields)};
update_map_type({union, Members}, NewFields) ->
    prisma_type:normalize_union([update_map_type(M, NewFields) || M <- Members]);
update_map_type(_, NewFields) ->
    {map, lists:usort(NewFields)}.

%% @doc Extracts `{CategoryAtom => TokenType}` from a leex lexer module's `yyaction/5` contract.
-spec extract_leex_token_map(module(), #{mfa_key() => #func_contract{}}) -> #{atom() => prisma_type:stype()}.
extract_leex_token_map(Mod, Contracts) ->
    case maps:find({Mod, yyaction, 5}, Contracts) of
        {ok, #func_contract{inferred_type = {fun_type, _, ActionRet}}} ->
            Tokens = extract_leex_tokens(ActionRet),
            lists:foldl(
                fun({tuple, [{atom_lit, Cat} | _]} = Tok, Acc) ->
                        Prev = maps:get(Cat, Acc, none),
                        Acc#{Cat => prisma_type:join(Prev, Tok)};
                   (_, Acc) ->
                        Acc
                end,
                #{},
                Tokens
            );
        _ ->
            #{}
    end.

refine_leex_contracts(Mod, Contracts) ->
    case maps:find({Mod, yyaction, 5}, Contracts) of
        {ok, #func_contract{inferred_type = {fun_type, _, ActionRet}}} ->
            case extract_leex_tokens(ActionRet) of
                [] ->
                    Contracts;
                Tokens ->
                    TokenUnion = prisma_type:widen(prisma_type:normalize_union(Tokens)),
                    Contracts1 = refine_leex_string_fn({Mod, string, 1}, TokenUnion, Contracts),
                    refine_leex_string_fn({Mod, string, 2}, TokenUnion, Contracts1)
            end;
        _ ->
            Contracts
    end.

extract_leex_tokens({union, Members}) ->
    lists:append([extract_leex_tokens(M) || M <- Members]);
extract_leex_tokens({tuple, [{atom_lit, Tag}, Token]})
  when Tag =:= token; Tag =:= end_token ->
    [Token];
extract_leex_tokens({tuple, [{atom_lit, Tag}, Token, _Push]})
  when Tag =:= token; Tag =:= end_token ->
    [Token];
extract_leex_tokens(_) ->
    [].

refine_leex_string_fn(MFA, TokenUnion, Contracts) ->
    case maps:find(MFA, Contracts) of
        {ok, #func_contract{inferred_type = {fun_type, Args, Ret0}} = C} ->
            Ret1 = replace_leex_ok_tokens(Ret0, {list, TokenUnion}),
            Contracts#{MFA => C#func_contract{inferred_type = {fun_type, Args, Ret1}}};
        _ ->
            Contracts
    end.

replace_leex_ok_tokens({union, Members}, TokenListType) ->
    prisma_type:normalize_union([replace_leex_ok_tokens(M, TokenListType) || M <- Members]);
replace_leex_ok_tokens({tuple, [{atom_lit, ok}, _, LocType]}, TokenListType) ->
    {tuple, [{atom_lit, ok}, TokenListType, LocType]};
replace_leex_ok_tokens(Other, _TokenListType) ->
    Other.

refine_yecc_contracts(Mod, ClausesMap, Contracts) ->
    LeexTokens = maps:get('$leex_tokens', Contracts, #{}),
    {StateFuncs, GotoFuncs} = collect_yecc_table_funcs(Mod, ClausesMap),
    AliasMap = build_yecc_alias_map(Mod, ClausesMap, StateFuncs),
    {ShiftSyms, ShiftPreds, AcceptSet, Reductions} = analyze_yecc_states(StateFuncs, AliasMap),
    {IncomingSym, Preds, RootGotos} = analyze_yecc_gotos(GotoFuncs, AcceptSet, ShiftSyms, ShiftPreds),
    case RootGotos of
        [] ->
            Contracts;
        _ ->
            ActionContracts = Contracts#{'$yecc_local_clauses' => ClausesMap},
            NtTypes = run_yecc_fixpoint(Mod, ClausesMap, ActionContracts, Reductions, IncomingSym, Preds, LeexTokens, #{}, 1),
            RootTypes = [maps:get(G, NtTypes, none) || G <- RootGotos],
            case prisma_type:normalize_union(RootTypes) of
                RootAstType when RootAstType =/= none, RootAstType =/= any ->
                    WidenedAst = prisma_type:widen(RootAstType),
                    Contracts1 = update_yecc_entry({Mod, parse, 1}, WidenedAst, Contracts),
                    update_yecc_entry({Mod, parse_and_scan, 1}, WidenedAst, Contracts1);
                _ ->
                    Contracts
            end
    end.

collect_yecc_table_funcs(Mod, ClausesMap) ->
    maps:fold(
        fun({M, F, 7}, {_Line, Clauses}, {SAcc, GAcc}) when M =:= Mod ->
                case atom_to_binary(F, utf8) of
                    <<"yeccpars2_", Rest/binary>> ->
                        case string:to_integer(binary_to_list(Rest)) of
                            {StateNum, ""} when is_integer(StateNum) ->
                                {[{F, StateNum, Clauses} | SAcc], GAcc};
                            _ ->
                                {SAcc, GAcc}
                        end;
                    <<"yeccgoto_", _/binary>> ->
                        {SAcc, [{F, Clauses} | GAcc]};
                    _ ->
                        {SAcc, GAcc}
                end;
           (_, _, Acc) ->
                Acc
        end,
        {[], []},
        ClausesMap
    ).

build_yecc_alias_map(Mod, ClausesMap, StateFuncs) ->
    Base = maps:from_list([{F, [S]} || {F, S, _} <- StateFuncs]),
    FromDispatch = case maps:find({Mod, yeccpars2, 7}, ClausesMap) of
        {ok, {_, DispatchClauses}} ->
            lists:foldl(
                fun({clause, _, [Arg1 | _], _, [{call, _, {atom, _, TargetFn}, _}]}, Acc) ->
                        case extract_yecc_state_int(Arg1) of
                            {ok, StateInt} ->
                                Cur = maps:get(TargetFn, Acc, []),
                                Acc#{TargetFn => lists:usort([StateInt | Cur])};
                            error ->
                                Acc
                        end;
                   (_, Acc) ->
                        Acc
                end,
                Base,
                DispatchClauses
            );
        error ->
            Base
    end,
    lists:foldl(
        fun({F, _S, Clauses}, Acc) ->
            case lists:last(Clauses) of
                {clause, _, [{var, _, _}, {var, _, _} | _], _, [{call, _, {atom, _, DelegatedFn}, _}]} ->
                    case atom_to_binary(DelegatedFn, utf8) of
                        <<"yeccpars2_", _/binary>> ->
                            FStates = maps:get(F, Acc, []),
                            DStates = maps:get(DelegatedFn, Acc, []),
                            Acc#{DelegatedFn => lists:usort(FStates ++ DStates)};
                        _ ->
                            Acc
                    end;
                _ ->
                    Acc
            end
        end,
        FromDispatch,
        StateFuncs
    ).

extract_yecc_state_int({integer, _, N}) -> {ok, N};
extract_yecc_state_int({match, _, {integer, _, N}, _}) -> {ok, N};
extract_yecc_state_int({match, _, _, {integer, _, N}}) -> {ok, N};
extract_yecc_state_int(_) -> error.

analyze_yecc_states(StateFuncs, AliasMap) ->
    lists:foldl(
        fun({F, StateNum, Clauses}, {SymAcc0, PredAcc0, AccSet0, RedAcc0}) ->
            CallerStates = maps:get(F, AliasMap, [StateNum]),
            lists:foldl(
                fun({clause, _, [_, {atom, _, '$end'} | _], _, [{tuple, _, [{atom, _, ok}, _]}]},
                    {SymAcc, PredAcc, AccSet, RedAcc}) ->
                        {SymAcc, PredAcc, AccSet#{F => true}, RedAcc};
                   ({clause, _, [_, {atom, _, Terminal} | _], _, [{call, _, {atom, _, yeccpars1}, [_, {integer, _, ToState} | _]}]},
                    {SymAcc, PredAcc, AccSet, RedAcc}) ->
                        PrevPreds = maps:get(ToState, PredAcc, []),
                        {SymAcc#{ToState => {terminal, Terminal}},
                         PredAcc#{ToState => lists:usort(CallerStates ++ PrevPreds)},
                         AccSet,
                         RedAcc};
                   ({clause, _, _, _, Body}, {SymAcc, PredAcc, AccSet, RedAcc}) ->
                        case extract_yecc_reduction(Body) of
                            {ok, ActionFn, GotoFn} ->
                                {SymAcc, PredAcc, AccSet, [{StateNum, ActionFn, GotoFn} | RedAcc]};
                            error ->
                                {SymAcc, PredAcc, AccSet, RedAcc}
                        end
                end,
                {SymAcc0, PredAcc0, AccSet0, RedAcc0},
                Clauses
            )
        end,
        {#{}, #{}, #{}, []},
        StateFuncs
    ).

extract_yecc_reduction(Body) ->
    Actions = [ActionFn || {match, _, _, {call, _, {atom, _, ActionFn}, _}} <- Body],
    case {Actions, lists:last(Body)} of
        {[ActionFn | _], {call, _, {atom, _, GotoFn}, _}} ->
            case atom_to_binary(GotoFn, utf8) of
                <<"yeccgoto_", _/binary>> -> {ok, ActionFn, GotoFn};
                _ -> error
            end;
        _ ->
            error
    end.

analyze_yecc_gotos(GotoFuncs, AcceptSet, ShiftSyms, ShiftPreds) ->
    lists:foldl(
        fun({GotoFn, Clauses}, {SymAcc0, PredAcc0, RootAcc0}) ->
            lists:foldl(
                fun({clause, _, [Arg1 | _], _, [{call, _, {atom, _, TargetFn}, _}]}, {SymAcc, PredAcc, RootAcc}) ->
                        RootAcc1 = case maps:is_key(TargetFn, AcceptSet) of
                            true -> lists:usort([GotoFn | RootAcc]);
                            false -> RootAcc
                        end,
                        case {extract_yecc_state_int(Arg1), parse_yeccpars2_state(TargetFn)} of
                            {{ok, FromState}, {ok, ToState}} ->
                                PrevPreds = maps:get(ToState, PredAcc, []),
                                {SymAcc#{ToState => {nonterminal, GotoFn}},
                                 PredAcc#{ToState => lists:usort([FromState | PrevPreds])},
                                 RootAcc1};
                            _ ->
                                {SymAcc, PredAcc, RootAcc1}
                        end;
                   (_, Acc) ->
                        Acc
                end,
                {SymAcc0, PredAcc0, RootAcc0},
                Clauses
            )
        end,
        {ShiftSyms, ShiftPreds, []},
        GotoFuncs
    ).

parse_yeccpars2_state(Fn) ->
    case atom_to_binary(Fn, utf8) of
        <<"yeccpars2_", Rest/binary>> ->
            case string:to_integer(binary_to_list(Rest)) of
                {N, ""} when is_integer(N) -> {ok, N};
                _ -> error
            end;
        _ ->
            error
    end.

run_yecc_fixpoint(_Mod, _ClausesMap, _Contracts, _Reductions, _IncomingSym, _Preds, _LeexTokens, NtTypes, Pass)
  when Pass > 6 ->
    NtTypes;
run_yecc_fixpoint(Mod, ClausesMap, Contracts, Reductions, IncomingSym, Preds, LeexTokens, NtTypes0, Pass) ->
    NtTypes1 = lists:foldl(
        fun({StateNum, ActionFn, GotoFn}, Acc) ->
            case maps:find({Mod, ActionFn, 1}, ClausesMap) of
                {ok, {_, [{clause, _, [{var, _, StackVar}], [],
                           [{match, _, ConsPat, {var, _, StackVar}}, {cons, _, ResultExpr, _}]}]}} ->
                    PopVars = extract_cons_vars(ConsPat),
                    case build_yecc_stack_env([StateNum], PopVars, IncomingSym, Preds, Acc, LeexTokens, #{}) of
                        {ok, StackEnv} ->
                            {RuleType, _, _, _} = infer_expr(Mod, {Mod, ActionFn, 1}, ResultExpr, StackEnv, Contracts, [], []),
                            case RuleType of
                                none ->
                                    Acc;
                                _ ->
                                    Prev = maps:get(GotoFn, Acc, none),
                                    Acc#{GotoFn => prisma_type:widen(prisma_type:join(Prev, RuleType))}
                            end;
                        error ->
                            Acc
                    end;
                _ ->
                    Acc
            end
        end,
        NtTypes0,
        Reductions
    ),
    case NtTypes1 =:= NtTypes0 of
        true -> NtTypes1;
        false -> run_yecc_fixpoint(Mod, ClausesMap, Contracts, Reductions, IncomingSym, Preds, LeexTokens, NtTypes1, Pass + 1)
    end.

extract_cons_vars({cons, _, {var, _, V}, Tail}) -> [V | extract_cons_vars(Tail)];
extract_cons_vars({cons, _, _, Tail}) -> ['_' | extract_cons_vars(Tail)];
extract_cons_vars(_) -> [].

build_yecc_stack_env(_CurStates, [], _IncomingSym, _Preds, _NtTypes, _LeexTokens, Env) ->
    {ok, Env};
build_yecc_stack_env(CurStates, [Var | RestVars], IncomingSym, Preds, NtTypes, LeexTokens, Env) ->
    Syms = lists:usort([maps:get(S, IncomingSym) || S <- CurStates, maps:is_key(S, IncomingSym)]),
    Types = [yecc_sym_type(Sym, NtTypes, LeexTokens) || Sym <- Syms],
    ElemType = prisma_type:normalize_union([T || T <- Types, T =/= none]),
    case ElemType of
        none ->
            error;
        _ ->
            Env1 = case Var of
                '_' -> Env;
                _ -> Env#{Var => ElemType}
            end,
            NextStates = lists:usort(lists:append([maps:get(S, Preds, []) || S <- CurStates])),
            build_yecc_stack_env(NextStates, RestVars, IncomingSym, Preds, NtTypes, LeexTokens, Env1)
    end.

yecc_sym_type({nonterminal, GotoFn}, NtTypes, _LeexTokens) ->
    maps:get(GotoFn, NtTypes, none);
yecc_sym_type({terminal, Cat}, _NtTypes, LeexTokens) ->
    case maps:find(Cat, LeexTokens) of
        {ok, TokType} ->
            TokType;
        error ->
            {union, [{tuple, [{atom_lit, Cat}, any]}, {tuple, [{atom_lit, Cat}, any, any]}]}
    end.

update_yecc_entry(MFA, AstType, Contracts) ->
    case maps:find(MFA, Contracts) of
        {ok, #func_contract{inferred_type = {fun_type, Args, Ret0}, declared_specs = Specs0} = C} ->
            Ret1 = replace_yecc_ok_ast(Ret0, AstType),
            Specs1 = [replace_yecc_spec_ast(S, AstType) || S <- Specs0],
            Contracts#{MFA => C#func_contract{inferred_type = {fun_type, Args, Ret1}, declared_specs = Specs1}};
        _ ->
            Contracts
    end.

replace_yecc_spec_ast({fun_type, Args, Ret}, AstType) ->
    {fun_type, Args, replace_yecc_ok_ast(Ret, AstType)};
replace_yecc_spec_ast(Other, _AstType) ->
    Other.

replace_yecc_ok_ast(any, AstType) ->
    {union, [{tuple, [{atom_lit, error}, any]}, {tuple, [{atom_lit, ok}, AstType]}]};
replace_yecc_ok_ast({union, Members}, AstType) ->
    prisma_type:normalize_union([replace_yecc_ok_ast(M, AstType) || M <- Members]);
replace_yecc_ok_ast({tuple, [{atom_lit, ok}, _]}, AstType) ->
    {tuple, [{atom_lit, ok}, AstType]};
replace_yecc_ok_ast({local_type, yecc_ret, _}, AstType) ->
    {union, [{tuple, [{atom_lit, error}, any]}, {tuple, [{atom_lit, ok}, AstType]}]};
replace_yecc_ok_ast(Other, _AstType) ->
    Other.
