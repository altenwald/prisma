%% @doc Hybrid static analyzer combining Success Typing and Gradual Typing.
-module(spectra_checker).

-include("spectra.hrl").

-export([
    check_module/2,
    check_module/3,
    check_plt/2,
    check_plt/3,
    format_warning/1,
    format_warning/2,
    format_warnings/1,
    format_warnings/2,
    should_color/1,
    colorize/3
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
check_module(#module_summary{file = File, functions = Funcs} = Summary, Plt, Opts) ->
    Mode = maps:get(mode, Opts, hybrid),
    ContractWarnings = lists:flatmap(
        fun({_MFA, Contract}) ->
            check_contract(Contract, Plt, Mode)
        end,
        lists:sort(maps:to_list(Funcs))
    ),
    OxbowWarnings = case maps:get(oxbow, Opts, true) of
        true -> spectra_oxbow:check_module(Summary, Opts);
        false -> []
    end,
    AllWarns = lists:usort(ContractWarnings ++ OxbowWarnings),
    attach_file_to_warnings(AllWarns, File).

attach_file_to_warnings(Warns, undefined) ->
    Warns;
attach_file_to_warnings(Warns, File) ->
    [case W#spectra_warning.file of
        undefined -> W#spectra_warning{file = File};
        _ -> W
     end || W <- Warns].

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
            case resolve_expected_arg_vectors(CallerMod, CalleeMod, Specs, Inferred, Plt) of
                {ok, Vectors} ->
                    check_vectors(Vectors, ActualArgs,
                                  fun(Zipped) -> spectra_infer:check_call_site(CallerMFA, Line, CalleeMFA, Zipped) end);
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
                    case resolve_expected_arg_vectors(CallerMod, CalleeMod, Specs, Inferred, Plt) of
                        {ok, Vectors} ->
                            check_vectors(Vectors, ActualArgs,
                                          fun(Zipped) -> check_gradual_args(CallerMFA, Line, CalleeMFA, Zipped) end);
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
                        message = Msg,
                        callee = {CM, CF, CA},
                        arg_idx = Idx,
                        actual = Actual,
                        expected = Expected
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

%% The argument types a call may use: one vector per clause of an overloaded -spec (or the inferred ones when there is no
%% spec). A call is acceptable when ANY vector accepts it as a whole, so clauses are never mixed position by position.
resolve_expected_arg_vectors(CallerMod, CalleeMod, [_ | _] = SpecClauses, _Inferred, Plt) ->
    Vectors = lists:filtermap(
        fun(SpecClause) ->
            case spectra_type:unfold_bounded_fun(SpecClause) of
                {fun_type, SpecArgs, _Ret} ->
                    {true, [
                        case spectra_plt:resolve_type(CallerMod, CalleeMod, A, Plt) of
                            {ok, R} -> R;
                            _ -> A
                        end
                        || A <- SpecArgs
                    ]};
                _ ->
                    false
            end
        end,
        SpecClauses
    ),
    case Vectors of
        [] -> error;
        _ -> {ok, Vectors}
    end;
resolve_expected_arg_vectors(_CallerMod, _CalleeMod, [], {fun_type, InferredArgs, _Ret}, _Plt) ->
    {ok, [InferredArgs]};
resolve_expected_arg_vectors(_, _, _, _, _) ->
    error.

%% No warnings if some vector accepts the call; otherwise the warnings against the first vector.
check_vectors(Vectors, ActualArgs, Check) ->
    Results = [Check(lists:zip(ActualArgs, V)) || V <- Vectors, length(V) =:= length(ActualArgs)],
    case lists:any(fun(Warnings) -> Warnings =:= [] end, Results) of
        true -> [];
        false ->
            case Results of
                [First | _] -> First;
                [] -> []
            end
    end.

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
                        message = Msg,
                        declared = DeclaredUnion,
                        actual = InferredRet
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

%% @doc Formats a single `#spectra_warning{}` using default options.
-spec format_warning(#spectra_warning{}) -> binary().
format_warning(Warning) ->
    format_warning(Warning, #{}).

%% @doc Formats a `#spectra_warning{}` according to `Opts` (`human`, `oneline`, `json`, colors).
-spec format_warning(#spectra_warning{}, map()) -> binary().
format_warning(#spectra_warning{} = W, Opts) ->
    Format = maps:get(format, Opts, human),
    Color = should_color(Opts),
    case Format of
        json ->
            encode_warning_json(W);
        oneline ->
            format_oneline(W, Color);
        _ ->
            format_human(W, Color)
    end.

%% @doc Formats a list of `#spectra_warning{}` with default options.
-spec format_warnings([#spectra_warning{}]) -> binary().
format_warnings(Warnings) ->
    format_warnings(Warnings, #{}).

%% @doc Formats a list of `#spectra_warning{}` according to `Opts`.
-spec format_warnings([#spectra_warning{}], map()) -> binary().
format_warnings(Warnings, Opts) ->
    Format = maps:get(format, Opts, human),
    case Format of
        json ->
            Items = [encode_warning_json(W) || W <- Warnings],
            iolist_to_binary([<<"[\n">>, lists:join(<<",\n">>, Items), <<"\n]">>]);
        oneline ->
            Lines = [format_oneline(W, should_color(Opts)) || W <- Warnings],
            iolist_to_binary(lists:join(<<"\n">>, Lines));
        _ ->
            Blocks = [format_human(W, should_color(Opts)) || W <- Warnings],
            iolist_to_binary(lists:join(<<"\n\n">>, Blocks))
    end.

-spec should_color(map()) -> boolean().
should_color(Opts) ->
    case maps:get(color, Opts, auto) of
        always -> true;
        never -> false;
        auto ->
            case os:getenv("NO_COLOR") of
                Val when is_list(Val), Val =/= "" -> false;
                _ ->
                    case io:columns() of
                        {ok, _} -> true;
                        _ -> false
                    end
            end
    end.

-spec colorize(iodata(), string(), boolean()) -> iodata().
colorize(Text, Ansi, true) -> [Ansi, Text, "\e[0m"];
colorize(Text, _Ansi, false) -> Text.

format_human(#spectra_warning{
    kind = Kind,
    mfa = {Mod, Fun, Arity},
    line = Line,
    message = Msg,
    declared = Declared,
    actual = Actual,
    expected = Expected,
    callee = Callee,
    arg_idx = ArgIdx,
    file = File
}, Color) ->
    CleanMod = spectra_type:clean_module(Mod),
    Lang = case atom_to_binary(Mod, utf8) of
        <<"Elixir.", _/binary>> -> elixir;
        _ -> erlang
    end,
    KindStr = atom_to_list(Kind),
    KindColor = case Kind of
        discrepancy -> "\e[1;31m";       %% bold red
        dead_code -> "\e[1;33m";         %% bold yellow
        oxbow_code -> "\e[1;33m";        %% bold yellow
        gradual_mismatch -> "\e[1;35m";  %% bold magenta
        opacity_violation -> "\e[1;31m"; %% bold red
        _ -> "\e[1;31m"
    end,
    Tag = colorize("[" ++ KindStr ++ "]", KindColor, Color),
    Loc = colorize(CleanMod ++ ":" ++ atom_to_list(Fun) ++ "/" ++ integer_to_list(Arity), "\e[1m", Color),
    LineStr = colorize("(line " ++ integer_to_list(Line) ++ ")", "\e[2m", Color),
    FileLoc = case File of
        undefined -> [];
        _ ->
            FilePathStr = File ++ ":" ++ integer_to_list(Line),
            ["\n  ", colorize(FilePathStr, "\e[2m\e[90m", Color)]
    end,
    Header = [Tag, " ", Loc, " ", LineStr, FileLoc],

    Details = case {Declared, Actual, Expected} of
        {Decl, Act, undefined} when Decl =/= undefined, Act =/= undefined ->
            DeclStr = spectra_type:format(Decl, #{lang => Lang}),
            ActStr = spectra_type:format(Act, #{lang => Lang}),
            [
                "\n  ", colorize("Declared:", "\e[1;36m", Color), "  ", DeclStr,
                "\n  ", colorize("Inferred:", "\e[1;31m", Color), "  ", ActStr
            ];
        {undefined, Act, Exp} when Exp =/= undefined, Act =/= undefined ->
            ExpStr = spectra_type:format(Exp, #{lang => Lang}),
            ActStr = spectra_type:format(Act, #{lang => Lang}),
            CalleeLines = case Callee of
                {CM, CF, CA} ->
                    CleanCM = spectra_type:clean_module(CM),
                    TargetStr = CleanCM ++ ":" ++ atom_to_list(CF) ++ "/" ++ integer_to_list(CA),
                    ArgStr = case ArgIdx of undefined -> ""; N -> io_lib:format(" (argument #~B)", [N]) end,
                    ["\n  ", colorize("Call to:", "\e[1m", Color), "   ", TargetStr, ArgStr];
                _ ->
                    []
            end,
            [
                CalleeLines,
                "\n  ", colorize("Expected:", "\e[1;32m", Color), "  ", ExpStr,
                "\n  ", colorize("Actual:  ", "\e[1;31m", Color), "  ", ActStr
            ];
        _ ->
            CleanMsg = clean_message_text(Msg),
            ["\n  ", CleanMsg]
    end,
    iolist_to_binary([Header, Details]).

format_oneline(#spectra_warning{
    kind = Kind,
    mfa = {Mod, Fun, Arity},
    line = Line,
    message = Msg,
    declared = Declared,
    actual = Actual,
    expected = Expected,
    callee = Callee,
    arg_idx = ArgIdx,
    file = File
}, Color) ->
    CleanMod = spectra_type:clean_module(Mod),
    Lang = case atom_to_binary(Mod, utf8) of
        <<"Elixir.", _/binary>> -> elixir;
        _ -> erlang
    end,
    Tag = colorize("[" ++ atom_to_list(Kind) ++ "]", "\e[1m", Color),
    SourcePrefix = case File of
        undefined -> CleanMod;
        _ -> File
    end,
    Loc = io_lib:format("~s:~B: ~s ~s:~s/~B", [SourcePrefix, Line, Tag, CleanMod, atom_to_list(Fun), Arity]),
    Desc = case {Declared, Actual, Expected} of
        {Decl, Act, undefined} when Decl =/= undefined, Act =/= undefined ->
            io_lib:format("declared ~s is incompatible with inferred ~s", [
                spectra_type:format(Decl, #{lang => Lang}),
                spectra_type:format(Act, #{lang => Lang})
            ]);
        {undefined, Act, Exp} when Exp =/= undefined, Act =/= undefined ->
            Target = case Callee of
                {CM, CF, CA} -> io_lib:format("to ~s:~s/~B ", [spectra_type:clean_module(CM), atom_to_list(CF), CA]);
                _ -> ""
            end,
            ArgStr = case ArgIdx of undefined -> ""; N -> io_lib:format("arg #~B ", [N]) end,
            io_lib:format("call ~s~sof type ~s does not match expected ~s", [
                Target, ArgStr,
                spectra_type:format(Act, #{lang => Lang}),
                spectra_type:format(Exp, #{lang => Lang})
            ]);
        _ ->
            clean_message_text(Msg)
    end,
    iolist_to_binary([Loc, ": ", Desc]).

encode_warning_json(#spectra_warning{
    kind = Kind,
    mfa = {Mod, Fun, Arity},
    line = Line,
    message = Msg,
    declared = Declared,
    actual = Actual,
    expected = Expected,
    callee = Callee,
    arg_idx = ArgIdx,
    file = File
}) ->
    CleanMod = spectra_type:clean_module(Mod),
    Lang = case atom_to_binary(Mod, utf8) of <<"Elixir.", _/binary>> -> elixir; _ -> erlang end,
    Base = [
        <<"  {\n">>,
        <<"    \"kind\": \"">>, atom_to_binary(Kind, utf8), <<"\",\n">>,
        <<"    \"module\": \"">>, json_escape(CleanMod), <<"\",\n">>,
        <<"    \"function\": \"">>, json_escape(atom_to_list(Fun)), <<"\",\n">>,
        <<"    \"arity\": ">>, integer_to_binary(Arity), <<",\n">>,
        <<"    \"line\": ">>, integer_to_binary(Line), <<",\n">>,
        <<"    \"message\": \"">>, json_escape(clean_message_text(Msg)), <<"\"">>
    ],
    ExtraFile = case File of
        undefined -> [];
        _ -> [<<",\n    \"file\": \"">>, json_escape(File), <<"\"">>]
    end,
    ExtraDeclared = case Declared of
        undefined -> [];
        _ -> [<<",\n    \"declared\": \"">>, json_escape(spectra_type:format(Declared, #{lang => Lang})), <<"\"">>]
    end,
    ExtraActual = case Actual of
        undefined -> [];
        _ -> [<<",\n    \"actual\": \"">>, json_escape(spectra_type:format(Actual, #{lang => Lang})), <<"\"">>]
    end,
    ExtraExpected = case Expected of
        undefined -> [];
        _ -> [<<",\n    \"expected\": \"">>, json_escape(spectra_type:format(Expected, #{lang => Lang})), <<"\"">>]
    end,
    ExtraArgIdx = case ArgIdx of
        undefined -> [];
        _ -> [<<",\n    \"arg_idx\": ">>, integer_to_binary(ArgIdx)]
    end,
    ExtraCallee = case Callee of
        {CM, CF, CA} ->
            [
                <<",\n    \"callee\": {\"module\": \"">>, json_escape(spectra_type:clean_module(CM)),
                <<"\", \"function\": \"">>, json_escape(atom_to_list(CF)),
                <<"\", \"arity\": ">>, integer_to_binary(CA), <<"}">>
            ];
        _ -> []
    end,
    iolist_to_binary([Base, ExtraFile, ExtraDeclared, ExtraActual, ExtraExpected, ExtraArgIdx, ExtraCallee, <<"\n  }">>]).

clean_message_text(Msg) when is_binary(Msg) ->
    binary:replace(Msg, <<"Elixir.">>, <<>>, [global]);
clean_message_text(Msg) ->
    binary:replace(iolist_to_binary(Msg), <<"Elixir.">>, <<>>, [global]).

json_escape(Bin) when is_binary(Bin) ->
    json_escape(binary_to_list(Bin));
json_escape(Str) when is_list(Str) ->
    lists:flatmap(
        fun
            ($") -> "\\\"";
            ($\\) -> "\\\\";
            ($\n) -> "\\n";
            ($\r) -> "\\r";
            ($\t) -> "\\t";
            (C) when C < 32 -> io_lib:format("\\u~4.16.0B", [C]);
            (C) -> [C]
        end,
        Str
    ).
