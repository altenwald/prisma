%% @doc Structural Oxbow Code detector for Erlang and Elixir codebases.
%%
%% Based on the research by Fernando "Brujo" Benavides and Laura M. Castro
%% in "Detecting Oxbow Code in Erlang Codebases with the Highest Degree of Certainty" (2021).
%%
%% Detects:
%% 1. Unused private functions (isolated functions disconnected from roots/exports).
%% 2. Unused ignored parameters (arguments ignored across all clauses in private functions).
%%
%% Adheres to the "Highest Degree of Certainty" principle: zero false alarms,
%% strictly ignoring behavior callbacks, compiler-generated functions (__*), and public exports.
-module(prisma_oxbow).

-include("prisma.hrl").

-export([
    check_module/1,
    check_module/2
]).

%% @doc Runs oxbow code detection on a `#module_summary{}` with default options.
-spec check_module(#module_summary{}) -> [#prisma_warning{}].
check_module(Summary) ->
    check_module(Summary, #{}).

%% @doc Runs oxbow code detection on a `#module_summary{}` with options.
-spec check_module(#module_summary{}, map()) -> [#prisma_warning{}].
check_module(#module_summary{module = Mod, functions = Funcs}, _Opts) when is_map(Funcs) ->
    case maps:size(Funcs) of
        0 ->
            [];
        _ ->
            Roots = find_roots(Funcs),
            CallGraph = build_local_call_graph(Mod, Funcs),
            Reachable = compute_reachable(Roots, sets:from_list(Roots), CallGraph),
            FixedArity = collect_fixed_arity_funs(Mod, Funcs),
            UnusedFuncsWarns = check_unused_functions(Funcs, Reachable),
            UnusedParamsWarns = check_unused_params(Funcs, Reachable, FixedArity),
            lists:sort(
                fun(W1, W2) ->
                    {W1#prisma_warning.line, W1#prisma_warning.mfa} =<
                    {W2#prisma_warning.line, W2#prisma_warning.mfa}
                end,
                UnusedFuncsWarns ++ UnusedParamsWarns
            )
    end;
check_module(_Summary, _Opts) ->
    [].

%% -------------------------------------------------------------------------
%% Reachability & Unused Private Functions
%% -------------------------------------------------------------------------

find_roots(Funcs) ->
    maps:fold(
        fun(MFA, #func_contract{exported = Exported, compiler_generated = Gen}, Acc) ->
            case Exported orelse Gen orelse is_compiler_generated(MFA) of
                true -> [MFA | Acc];
                false -> Acc
            end
        end,
        [],
        Funcs
    ).

is_compiler_generated({_Mod, Fun, _Arity}) ->
    is_compiler_generated_name(Fun).

is_compiler_generated_name(module_info) -> true;
is_compiler_generated_name(behaviour_info) -> true;
is_compiler_generated_name(Fun) when is_atom(Fun) ->
    Str = atom_to_list(Fun),
    case Str of
        "__" ++ _ -> true; %% Elixir compiler/macro generated (__info__, __struct__, etc.)
        "MACRO-" ++ _ -> true; %% Elixir defmacro/defmacrop expanded at compile time
        _ ->
            string:str(Str, "overridable") > 0
    end.

build_local_call_graph(Mod, Funcs) ->
    maps:map(
        fun(_MFA, #func_contract{calls = Calls}) ->
            [C || C <- Calls, element(1, C) =:= Mod, maps:is_key(C, Funcs)]
        end,
        Funcs
    ).

compute_reachable([], Visited, _Graph) ->
    Visited;
compute_reachable([Node | Rest], Visited, Graph) ->
    Neighbors = maps:get(Node, Graph, []),
    NewNeighbors = [N || N <- Neighbors, not sets:is_element(N, Visited)],
    NewVisited = lists:foldl(fun sets:add_element/2, Visited, NewNeighbors),
    compute_reachable(NewNeighbors ++ Rest, NewVisited, Graph).

check_unused_functions(Funcs, Reachable) ->
    maps:fold(
        fun({M, F, A} = MFA, #func_contract{exported = Exported, compiler_generated = Gen, line = Line}, Acc) ->
            case not Exported andalso
                 not Gen andalso
                 Line > 1 andalso
                 not is_compiler_generated_name(F) andalso
                 not sets:is_element(MFA, Reachable) of
                true ->
                    ModStr = prisma_type:clean_module(M),
                    Msg = iolist_to_binary(
                        io_lib:format(
                            "Unused private function: ~s:~s/~B is never called and can be safely removed",
                            [ModStr, atom_to_list(F), A]
                        )
                    ),
                    [#prisma_warning{
                        kind = oxbow_code,
                        mfa = MFA,
                        line = Line,
                        message = Msg
                    } | Acc];
                false ->
                    Acc
            end
        end,
        [],
        Funcs
    ).

%% -------------------------------------------------------------------------
%% Unused Ignored Parameters in Private Functions
%% -------------------------------------------------------------------------

check_unused_params(Funcs, Reachable, FixedArity) ->
    maps:fold(
        fun({_M, F, Arity} = MFA, #func_contract{exported = Exported, compiler_generated = Gen, clauses = Clauses, line = Line}, Acc) ->
            case not Exported andalso
                 not Gen andalso
                 Line > 1 andalso
                 not is_compiler_generated_name(F) andalso
                 sets:is_element(MFA, Reachable) andalso
                 not sets:is_element(MFA, FixedArity) andalso
                 Arity >= 1 andalso
                 Clauses =/= [] andalso
                 not is_stub_raise_only(Clauses) of
                true ->
                    Warns = detect_ignored_params(MFA, Line, Arity, Clauses),
                    Warns ++ Acc;
                false ->
                    Acc
            end
        end,
        [],
        Funcs
    ).

collect_fixed_arity_funs(Mod, Funcs) ->
    maps:fold(
        fun({_M, CallerFun, _A}, #func_contract{compiler_generated = Gen, line = Line, calls = Calls, clauses = Clauses}, Acc0) ->
            Acc1 = case Gen orelse Line =< 1 orelse is_compiler_generated_name(CallerFun) of
                true ->
                    lists:foldl(
                        fun(C, S) when element(1, C) =:= Mod -> sets:add_element(C, S);
                           (_, S) -> S
                        end,
                        Acc0,
                        Calls
                    );
                false ->
                    Acc0
            end,
            collect_fixed_arity_in_ast(Mod, Clauses, Acc1)
        end,
        sets:new(),
        Funcs
    ).

collect_fixed_arity_in_ast(Mod, {'fun', _, {function, Fun, Arity}}, Acc) ->
    sets:add_element({Mod, Fun, Arity}, Acc);
collect_fixed_arity_in_ast(Mod, {'fun', _, {function, Mod, Fun, Arity}}, Acc) ->
    sets:add_element({Mod, Fun, Arity}, Acc);
collect_fixed_arity_in_ast(Mod, {'fun', _, {function, {atom, _, Mod}, {atom, _, Fun}, {integer, _, Arity}}}, Acc) ->
    sets:add_element({Mod, Fun, Arity}, Acc);
collect_fixed_arity_in_ast(Mod, {call, Anno, {atom, _, Fun}, Args}, Acc) ->
    Acc1 = case erl_anno:generated(Anno) orelse erl_anno:line(Anno) =< 1 orelse has_macro_hygiene_var(Args) of
        true -> sets:add_element({Mod, Fun, length(Args)}, Acc);
        false -> Acc
    end,
    collect_fixed_arity_in_ast(Mod, Args, Acc1);
collect_fixed_arity_in_ast(Mod, T, Acc) when is_tuple(T) ->
    collect_fixed_arity_in_ast(Mod, tuple_to_list(T), Acc);
collect_fixed_arity_in_ast(Mod, L, Acc) when is_list(L) ->
    lists:foldl(fun(E, S) -> collect_fixed_arity_in_ast(Mod, E, S) end, Acc, L);
collect_fixed_arity_in_ast(_Mod, _, Acc) ->
    Acc.

has_macro_hygiene_var({var, _, Name}) when is_atom(Name) ->
    string:find(atom_to_list(Name), "@Elixir.") =/= nomatch;
has_macro_hygiene_var(T) when is_tuple(T) ->
    has_macro_hygiene_var(tuple_to_list(T));
has_macro_hygiene_var(L) when is_list(L) ->
    lists:any(fun has_macro_hygiene_var/1, L);
has_macro_hygiene_var(_) ->
    false.

%% A private function whose every clause unconditionally raises/throws/exits is a stub
%% (e.g. `doc!(_)` or `not_implemented(_)`), not a refactorable unused parameter.
is_stub_raise_only(Clauses) ->
    lists:all(fun is_raise_clause/1, Clauses).

is_raise_clause({clause, _Anno, _Pats, _Guards, Body}) when Body =/= [] ->
    is_raise_expr(lists:last(Body));
is_raise_clause(_) ->
    false.

is_raise_expr({call, _, {remote, _, {atom, _, erlang}, {atom, _, Fun}}, _Args})
  when Fun =:= error; Fun =:= throw; Fun =:= exit ->
    true;
is_raise_expr({call, _, {atom, _, Fun}, _Args})
  when Fun =:= error; Fun =:= throw; Fun =:= exit ->
    true;
is_raise_expr({block, _, Exprs}) when Exprs =/= [] ->
    is_raise_expr(lists:last(Exprs));
is_raise_expr(_) ->
    false.

detect_ignored_params({Mod, Fun, Arity} = MFA, Line, Arity, Clauses) ->
    CleanMod = prisma_type:clean_module(Mod),
    lists:filtermap(
        fun(Idx) ->
            case is_param_ignored_all_clauses(Idx, Clauses) of
                true ->
                    Msg = iolist_to_binary(
                        io_lib:format(
                            "Unused parameter: argument #~B is ignored across all clauses of private function ~s:~s/~B and can be safely removed",
                            [Idx, CleanMod, atom_to_list(Fun), Arity]
                        )
                    ),
                    {true, #prisma_warning{
                        kind = oxbow_code,
                        mfa = MFA,
                        line = Line,
                        arg_idx = Idx,
                        message = Msg
                    }};
                false ->
                    false
            end
        end,
        lists:seq(1, Arity)
    ).

is_param_ignored_all_clauses(Idx, Clauses) ->
    lists:all(
        fun
            ({clause, _Anno, Patterns, Guards, Body}) when length(Patterns) >= Idx ->
                Pattern = lists:nth(Idx, Patterns),
                OtherPatterns = [P || {Pos, P} <- lists:zip(lists:seq(1, length(Patterns)), Patterns), Pos =/= Idx],
                is_ignored_clause_pattern(Pattern, OtherPatterns, Guards, Body);
            (_) ->
                false
        end,
        Clauses
    ).

is_ignored_clause_pattern({var, _Anno, '_'}, _OtherPatterns, _Guards, _Body) ->
    true;
is_ignored_clause_pattern({var, _Anno, VarName}, OtherPatterns, Guards, Body) when is_atom(VarName) ->
    case atom_to_list(VarName) of
        "_" ++ _ ->
            not is_var_referenced(VarName, OtherPatterns) andalso
                not is_var_referenced(VarName, Guards) andalso
                not is_var_referenced(VarName, Body);
        _ ->
            false
    end;
is_ignored_clause_pattern(_OtherPattern, _OtherPatterns, _Guards, _Body) ->
    false.

is_var_referenced(VarName, {var, _Anno, VarName}) ->
    true;
is_var_referenced(VarName, Tuple) when is_tuple(Tuple) ->
    is_var_referenced_list(VarName, tuple_to_list(Tuple));
is_var_referenced(VarName, List) when is_list(List) ->
    is_var_referenced_list(VarName, List);
is_var_referenced(_VarName, _Other) ->
    false.

is_var_referenced_list(VarName, Items) ->
    lists:any(fun(Item) -> is_var_referenced(VarName, Item) end, Items).
