%% @doc Hybrid static analyzer combining Success Typing and Gradual Typing.
-module(spectra_checker).

-include("spectra.hrl").

-export([
    check_module/2,
    check_module/3,
    check_plt/2,
    check_plt/3,
    format_warning/1
]).

%% @doc Analyzes all modules in `TargetPlt` against `DepsPlt` in hybrid mode.
-spec check_plt(#spectra_plt{}, #spectra_plt{}) -> [#spectra_warning{}].
check_plt(TargetPlt, DepsPlt) ->
    check_plt(TargetPlt, DepsPlt, #{mode => hybrid}).

%% @doc Analyzes all modules in `TargetPlt` against `DepsPlt` with `Opts`.
-spec check_plt(#spectra_plt{}, #spectra_plt{}, map()) -> [#spectra_warning{}].
check_plt(#spectra_plt{modules = TargetMods} = TargetPlt, DepsPlt, Opts) ->
    CombinedPlt = spectra_plt:merge(DepsPlt, TargetPlt),
    lists:flatmap(
        fun({_Mod, Summary}) ->
            check_module(Summary, CombinedPlt, Opts)
        end,
        lists:sort(maps:to_list(TargetMods))
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

check_contract(Contract, Plt, Mode) ->
    DiscrepancyWarnings =
        case Mode of
            gradual -> [];
            _ -> collect_discrepancies(Contract, Plt)
        end,
    GradualWarnings =
        case Mode of
            discrepancy ->
                [];
            _ ->
                SpecBodyWarnings = verify_gradual_spec(
                    Contract#func_contract.mfa,
                    Contract#func_contract.declared_specs,
                    Contract#func_contract.inferred_type,
                    Contract#func_contract.line,
                    Plt
                ),
                CallWarnings = verify_gradual_calls(Contract, Plt),
                SpecBodyWarnings ++ CallWarnings
        end,
    lists:usort(DiscrepancyWarnings ++ GradualWarnings).

collect_discrepancies(#func_contract{mfa = {CallerMod, _, _} = CallerMFA, local_warnings = LocalWarns, call_sites = Sites}, Plt) ->
    InterModWarns = lists:flatmap(
        fun({Line, {CalleeMod, _, _} = CalleeMFA, ActualArgs}) ->
            case CalleeMod =:= CallerMod of
                true ->
                    [];
                false ->
                    check_remote_discrepancy_call(CallerMFA, Line, CalleeMFA, ActualArgs, Plt)
            end
        end,
        Sites
    ),
    LocalWarns ++ InterModWarns.

check_remote_discrepancy_call({CallerMod, _, _} = CallerMFA, Line, {CalleeMod, _, _} = CalleeMFA, ActualArgs, Plt) ->
    case spectra_plt:lookup_mfa(CalleeMFA, Plt) of
        {ok, #func_contract{declared_specs = Specs, inferred_type = Inferred}} ->
            case resolve_expected_args(CallerMod, CalleeMod, Specs, Inferred, Plt) of
                {ok, ExpectedArgs} when length(ExpectedArgs) =:= length(ActualArgs) ->
                    spectra_infer:check_call_site(CallerMFA, Line, CalleeMFA, lists:zip(ActualArgs, ExpectedArgs));
                _ ->
                    []
            end;
        error ->
            []
    end.

verify_gradual_calls(#func_contract{mfa = {CallerMod, _, _} = CallerMFA, call_sites = Sites}, Plt) ->
    lists:flatmap(
        fun({Line, {CalleeMod, _, _} = CalleeMFA, ActualArgs}) ->
            case spectra_plt:lookup_mfa(CalleeMFA, Plt) of
                {ok, #func_contract{declared_specs = [ _ | _ ] = Specs, inferred_type = Inferred}} ->
                    case resolve_expected_args(CallerMod, CalleeMod, Specs, Inferred, Plt) of
                        {ok, ExpectedArgs} when length(ExpectedArgs) =:= length(ActualArgs) ->
                            check_gradual_args(CallerMFA, Line, CalleeMFA, lists:zip(ActualArgs, ExpectedArgs));
                        _ ->
                            []
                    end;
                _ ->
                    []
            end
        end,
        Sites
    ).

check_gradual_args(CallerMFA, Line, {CM, CF, CA}, ZipArgs) ->
    {Warns, _} = lists:foldl(
        fun({Actual, Expected}, {WAcc, Idx}) ->
            case spectra_type:consistent_subtype(Actual, Expected) of
                true ->
                    {WAcc, Idx + 1};
                false ->
                    Kind = classify_gradual_failure(Actual, Expected),
                    Msg = iolist_to_binary(
                        io_lib:format(
                            "Call to ~s:~s/~B: argument #~B of type ~p is not a gradual subtype of ~p",
                            [CM, CF, CA, Idx, Actual, Expected]
                        )
                    ),
                    W = #spectra_warning{
                        kind = Kind,
                        mfa = CallerMFA,
                        line = Line,
                        message = Msg
                    },
                    {[W | WAcc], Idx + 1}
            end
        end,
        {[], 1},
        ZipArgs
    ),
    lists:reverse(Warns).

classify_gradual_failure({opaque, _, _, _, _}, _) -> opacity_violation;
classify_gradual_failure(_, {opaque, _, _, _, _}) -> opacity_violation;
classify_gradual_failure(_, _) -> gradual_mismatch.

resolve_expected_args(CallerMod, CalleeMod, [SpecClause | _], _Inferred, Plt) ->
    case spectra_type:unfold_bounded_fun(SpecClause) of
        {fun_type, SpecArgs, _Ret} ->
            Resolved = [
                case spectra_plt:resolve_type(CallerMod, CalleeMod, A, Plt) of
                    {ok, R} -> R;
                    _ -> A
                end
                || A <- SpecArgs
            ],
            {ok, Resolved};
        _ ->
            error
    end;
resolve_expected_args(_CallerMod, _CalleeMod, [], {fun_type, InferredArgs, _Ret}, _Plt) ->
    {ok, InferredArgs};
resolve_expected_args(_, _, _, _, _) ->
    error.

verify_gradual_spec(_MFA, [], _Inferred, _Line, _Plt) ->
    [];
verify_gradual_spec({Mod, _, _} = MFA, [_ | _] = SpecClauses, {fun_type, _InferredArgs, InferredRet}, Line, Plt) ->
    DeclaredReturns = lists:filtermap(
        fun(Clause) ->
            case extract_spec_return(Mod, Clause, Plt) of
                {ok, Ret} -> {true, Ret};
                error -> false
            end
        end,
        SpecClauses
    ),
    case DeclaredReturns of
        [] ->
            [];
        _ ->
            DeclaredUnion = spectra_type:normalize_union(DeclaredReturns),
            case spectra_type:consistent_subtype(InferredRet, DeclaredUnion) of
                true ->
                    [];
                false ->
                    Kind = classify_gradual_failure(InferredRet, DeclaredUnion),
                    Msg = iolist_to_binary(
                        io_lib:format(
                            "Gradual spec mismatch: declared return type ~p is incompatible with inferred return type ~p",
                            [DeclaredUnion, InferredRet]
                        )
                    ),
                    [#spectra_warning{
                        kind = Kind,
                        mfa = MFA,
                        line = Line,
                        message = Msg
                    }]
            end
    end;
verify_gradual_spec(_MFA, _Specs, _Inferred, _Line, _Plt) ->
    [].

extract_spec_return(Mod, SpecClause, Plt) ->
    case spectra_type:unfold_bounded_fun(SpecClause) of
        {fun_type, _Args, RetType} ->
            case spectra_plt:resolve_type(Mod, Mod, RetType, Plt) of
                {ok, Resolved} -> {ok, Resolved};
                {error, _} -> {ok, RetType}
            end;
        _ ->
            error
    end.

%% @doc Formats a `#spectra_warning{}` as a human-readable line.
-spec format_warning(#spectra_warning{}) -> binary().
format_warning(#spectra_warning{kind = Kind, mfa = {M, F, A}, line = Line, message = Msg}) ->
    iolist_to_binary(
        io_lib:format("[~s] ~s:~s/~B (line ~B): ~s", [Kind, M, F, A, Line, Msg])
    ).
