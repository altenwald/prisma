%% @doc Hybrid static analyzer combining Success Typing and Gradual Typing.
-module(spectra_checker).

-include("spectra.hrl").

-export([
    check_module/2,
    check_module/3,
    check_plt/2,
    format_warning/1
]).

%% @doc Analyzes all modules in `TargetPlt` against `DepsPlt`.
-spec check_plt(#spectra_plt{}, #spectra_plt{}) -> [#spectra_warning{}].
check_plt(#spectra_plt{modules = TargetMods} = TargetPlt, DepsPlt) ->
    CombinedPlt = spectra_plt:merge(DepsPlt, TargetPlt),
    lists:flatmap(
        fun({_Mod, Summary}) ->
            check_module(Summary, CombinedPlt, #{mode => hybrid})
        end,
        maps:to_list(TargetMods)
    ).

%% @doc Analyzes a `#module_summary{}` in hybrid mode.
-spec check_module(#module_summary{}, #spectra_plt{}) -> [#spectra_warning{}].
check_module(Summary, Plt) ->
    check_module(Summary, Plt, #{mode => hybrid}).

%% @doc Analyzes a `#module_summary{}` using the configured mode (`hybrid`, `gradual`, `discrepancy`).
-spec check_module(#module_summary{}, #spectra_plt{}, map()) -> [#spectra_warning{}].
check_module(#module_summary{functions = Funcs}, Plt, Opts) ->
    Mode = maps:get(mode, Opts, hybrid),
    lists:flatmap(
        fun({_MFA, Contract}) ->
            check_contract(Contract, Plt, Mode)
        end,
        lists:sort(maps:to_list(Funcs))
    ).

check_contract(#func_contract{mfa = MFA, declared_specs = Specs, inferred_type = Inferred, line = Line}, Plt, Mode) ->
    case {Mode, Specs} of
        {discrepancy, _} -> [];
        {_, []} -> [];
        {_, SpecClauses} ->
            verify_gradual_spec(MFA, SpecClauses, Inferred, Line, Plt)
    end.

verify_gradual_spec({Mod, _, _} = MFA, [SpecClause | _], {fun_type, _InferredArgs, InferredRet}, Line, Plt) ->
    case extract_spec_return(Mod, SpecClause, Plt) of
        {ok, DeclaredRet} ->
            case types_compatible(DeclaredRet, InferredRet) of
                true ->
                    [];
                false ->
                    Msg = iolist_to_binary(
                        io_lib:format(
                            "Gradual spec mismatch: declared return type ~p is incompatible with inferred return type ~p",
                            [DeclaredRet, InferredRet]
                        )
                    ),
                    [#spectra_warning{
                        kind = gradual_mismatch,
                        mfa = MFA,
                        line = Line,
                        message = Msg
                    }]
            end;
        error ->
            []
    end;
verify_gradual_spec(_MFA, _Specs, _Inferred, _Line, _Plt) ->
    [].

extract_spec_return(Mod, SpecClause, Plt) ->
    case spectra_type:unfold_bounded_fun(SpecClause) of
        {fun_type, _Args, RetType} ->
            case spectra_plt:resolve_type(Mod, RetType, Plt) of
                {ok, Resolved} -> {ok, Resolved};
                {error, _} -> {ok, RetType}
            end;
        _ ->
            error
    end.

types_compatible(any, _) -> true;
types_compatible(_, any) -> true;
types_compatible({var, _}, _) -> true;
types_compatible(_, {var, _}) -> true;
types_compatible(Same, Same) -> true;
types_compatible(number, integer) -> true;
types_compatible(number, pos_integer) -> true;
types_compatible(number, non_neg_integer) -> true;
types_compatible(number, neg_integer) -> true;
types_compatible(number, {int_lit, _}) -> true;
types_compatible(number, {int_range, _, _}) -> true;
types_compatible(number, float) -> true;
types_compatible(integer, pos_integer) -> true;
types_compatible(integer, non_neg_integer) -> true;
types_compatible(integer, neg_integer) -> true;
types_compatible(integer, {int_lit, _}) -> true;
types_compatible(integer, {int_range, _, _}) -> true;
types_compatible(pos_integer, {int_lit, I}) when I > 0 -> true;
types_compatible(non_neg_integer, {int_lit, I}) when I >= 0 -> true;
types_compatible(neg_integer, {int_lit, I}) when I < 0 -> true;
types_compatible({int_range, Lo, Hi}, {int_lit, I})
  when (Lo =:= neg_inf orelse I >= Lo) andalso (Hi =:= pos_inf orelse I =< Hi) ->
    true;
types_compatible(atom, boolean) -> true;
types_compatible(atom, {atom_lit, _}) -> true;
types_compatible(boolean, {atom_lit, B}) when is_boolean(B) -> true;
types_compatible({list, _}, nil) -> true;
types_compatible({list, Elem1}, {nonempty_list, Elem2}) ->
    types_compatible(Elem1, Elem2);
types_compatible({list, Elem1}, {list, Elem2}) ->
    types_compatible(Elem1, Elem2);
types_compatible({nonempty_list, Elem1}, {nonempty_list, Elem2}) ->
    types_compatible(Elem1, Elem2);
types_compatible(any_map, {map, _}) -> true;
types_compatible({map, _}, any_map) -> true;
types_compatible(any_tuple, {tuple, _}) -> true;
types_compatible({tuple, E1}, {tuple, E2}) when length(E1) =:= length(E2) ->
    lists:all(fun({A, B}) -> types_compatible(A, B) end, lists:zip(E1, E2));
types_compatible({union, Members}, Inferred) ->
    lists:any(fun(M) -> types_compatible(M, Inferred) end, Members);
types_compatible(Declared, {union, Members}) ->
    lists:all(fun(M) -> types_compatible(Declared, M) end, Members);
types_compatible(_, _) ->
    false.

%% @doc Formats a `#spectra_warning{}` as a human-readable line.
-spec format_warning(#spectra_warning{}) -> binary().
format_warning(#spectra_warning{kind = Kind, mfa = {M, F, A}, line = Line, message = Msg}) ->
    iolist_to_binary(
        io_lib:format("[~s] ~s:~s/~B (line ~B): ~s", [Kind, M, F, A, Line, Msg])
    ).
