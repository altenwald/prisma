%% @doc Hybrid static analyzer combining Success Typing and Gradual Typing.
-module(prisma_checker).

-include("prisma.hrl").

-export([
    check_module/2,
    check_module/3,
    check_pplt/2,
    check_pplt/3,
    format_warning/1,
    format_warning/2,
    severity/1,
    report/2,
    format_warnings/1,
    format_warnings/2,
    should_color/1,
    colorize/3
]).

%% The kind as it is written in the text formats: a warning says so, an error is just its kind.
kind_label(Kind) ->
    case severity(Kind) of
        warning -> "warning: " ++ atom_to_list(Kind);
        _ -> atom_to_list(Kind)
    end.

%% @doc How sure Prisma is of a warning: `error` (it fails when it runs), `warning` (the code handles it, or it may fail on another system)
%% or `note` (something that was not checked: it is counted and not listed).
-spec severity(atom()) -> error | warning | note.
severity(handled_undef) -> warning;
severity(system_branch) -> note;
severity(_) -> error.

%% @doc What a command prints and whether it fails. Errors fail; warnings do not unless `warnings_as_errors`, and `no_warnings` leaves
%% them out; notes are only counted (`unchecked`). `output` is what goes to stdout and `unchecked` what the caller says on stderr.
-spec report([#prisma_warning{}], map()) ->
    #{output := iodata(), failed := boolean(), errors := non_neg_integer(), warnings := non_neg_integer(), unchecked := non_neg_integer()}.
report(All, Opts) ->
    Unchecked = length([W || W <- All, severity(W#prisma_warning.kind) =:= note]),
    Errors = [W || W <- All, severity(W#prisma_warning.kind) =:= error],
    Warnings = case maps:get(no_warnings, Opts, false) of
        true -> [];
        false -> [W || W <- All, severity(W#prisma_warning.kind) =:= warning]
    end,
    Shown = [W || W <- All, lists:member(W, Errors) orelse lists:member(W, Warnings)],
    Output = case Shown of
        [] ->
            case maps:get(format, Opts, human) of
                json -> <<"[]\n">>;
                _ -> [colorize("Prisma: 0 warnings found.", "\e[1;32m", should_color(Opts)), $\n]
            end;
        _ ->
            [format_warnings(Shown, Opts), $\n]
    end,
    Failed = Errors =/= [] orelse (maps:get(warnings_as_errors, Opts, false) andalso Warnings =/= []),
    #{output => Output, failed => Failed, errors => length(Errors), warnings => length(Warnings), unchecked => Unchecked}.

%% @doc Analyzes all modules in `TargetPplt` against `DepsPplt` in hybrid mode.
-spec check_pplt(#prisma_pplt{}, #prisma_pplt{}) -> [#prisma_warning{}].
check_pplt(TargetPplt, DepsPplt) ->
    check_pplt(TargetPplt, DepsPplt, #{mode => hybrid}).

%% @doc Analyzes all modules in `TargetPplt` against `DepsPplt` with `Opts`.
-spec check_pplt(#prisma_pplt{}, #prisma_pplt{}, map()) -> [#prisma_warning{}].
check_pplt(#prisma_pplt{modules = TargetMods} = TargetPplt, DepsPplt, Opts) ->
    CombinedPplt = prisma_pplt:merge(DepsPplt, TargetPplt),
    lists:flatmap(
        fun({_Mod, Summary}) ->
            check_module(Summary, CombinedPplt, Opts)
        end,
        lists:sort(maps:to_list(TargetMods))
    ).

%% @doc Analyzes a `#module_summary{}` in hybrid mode.
-spec check_module(#module_summary{}, #prisma_pplt{}) -> [#prisma_warning{}].
check_module(Summary, Pplt) ->
    check_module(Summary, Pplt, #{mode => hybrid}).

%% @doc Analyzes a `#module_summary{}` using the configured mode (`hybrid`, `gradual`, `discrepancy`).
-spec check_module(#module_summary{}, #prisma_pplt{}, map()) -> [#prisma_warning{}].
check_module(#module_summary{file = File, functions = Funcs} = Summary, Pplt, Opts) ->
    Mode = maps:get(mode, Opts, hybrid),
    ContractWarnings = lists:flatmap(
        fun({_MFA, Contract}) ->
            check_contract(Contract, Pplt, Mode)
        end,
        lists:sort(maps:to_list(Funcs))
    ),
    OxbowWarnings = case maps:get(oxbow, Opts, true) of
        true -> prisma_oxbow:check_module(Summary, Opts);
        false -> []
    end,
    AllWarns = lists:usort(ContractWarnings ++ OxbowWarnings),
    attach_file_to_warnings(AllWarns, File).

attach_file_to_warnings(Warns, undefined) ->
    Warns;
attach_file_to_warnings(Warns, File) ->
    [case W#prisma_warning.file of
        undefined -> W#prisma_warning{file = File};
        _ -> W
     end || W <- Warns].

check_contract(Contract, Pplt, Mode) ->
    DiscrepancyWarnings =
        case Mode of
            gradual -> [];
            _ -> collect_discrepancies(Contract, Pplt)
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
                    Pplt
                ),
                CallWarnings = verify_gradual_calls(Contract, Pplt),
                SpecBodyWarnings ++ CallWarnings
        end,
    lists:usort(DiscrepancyWarnings ++ GradualWarnings).

collect_discrepancies(#func_contract{mfa = {CallerMod, _, _} = CallerMFA, local_warnings = LocalWarns, call_sites = Sites}, Pplt) ->
    InterModWarns = lists:flatmap(
        fun(Site) ->
            {Line, {CalleeMod, _, _} = CalleeMFA, ActualArgs, Tag} = site_parts(Site),
            case CalleeMod =:= CallerMod orelse Tag =:= environment of
                true ->
                    [];
                false ->
                    check_remote_discrepancy_call(CallerMFA, Line, CalleeMFA, ActualArgs, Pplt, Tag)
            end
        end,
        Sites
    ),
    LocalWarns ++ InterModWarns.

%% A site is `{Line, MFA, Args}` or has a fourth element that says how the code protects the call (see prisma.hrl).
site_parts({Line, MFA, Args}) -> {Line, MFA, Args, none};
site_parts({Line, MFA, Args, Tag}) -> {Line, MFA, Args, Tag}.

check_remote_discrepancy_call({CallerMod, _, _} = CallerMFA, Line, {CalleeMod, _, _} = CalleeMFA, ActualArgs, Pplt, Tag) ->
    case prisma_pplt:lookup_mfa(CalleeMFA, Pplt) of
        {ok, #func_contract{declared_specs = Specs, inferred_type = Inferred}} ->
            case resolve_expected_arg_vectors(CallerMod, CalleeMod, Specs, Inferred, Pplt) of
                {ok, Vectors} ->
                    check_vectors(Vectors, ActualArgs,
                                  fun(Zipped) -> prisma_infer:check_call_site(CallerMFA, Line, CalleeMFA, Zipped) end);
                _ ->
                    []
            end;
        error ->
            handled(Tag, unknown_function_warnings(CallerMFA, Line, CalleeMFA, Pplt))
    end.

%% A missing function that the code protects with a `try`: `error:undef` is the author saying so; a catch of every error also handles it, but would
%% hide a misspelled name for good, so it is a warning of its own (`handled_undef`), not an error for.
handled(undef_handled, _Warnings) -> [];
handled(any_handled, Warnings) ->
    [W#prisma_warning{kind = handled_undef,
                      message = <<(W#prisma_warning.message)/binary, " (it is handled by a try that catches every error)">>} || W <- Warnings];
handled(_, Warnings) -> Warnings.

%% A call to a function that does not exist in a module the PPLT knows. A module that is not in the PPLT proves nothing (it may just
%% not have been analyzed), a module that is not Erlang (Elixir's generated functions) is left alone, `erlang` is the BIFs, and
%% the compiler adds `module_info/0,1` and `behaviour_info/1` without them being in the code. A function that exists without being
%% exported is not reported either: a module can export everything with a compile attribute.
unknown_function_warnings(CallerMFA, Line, {Mod, F, A} = CalleeMFA, Pplt) ->
    case provided_by_the_compiler(Mod, F, A) of
        true ->
            [];
        false ->
            case prisma_pplt:lookup_module(Mod, Pplt) of
                {ok, #module_summary{language = Language, functions = Funcs}} when Language =/= elixir ->
                    Arities = lists:sort([FA || {M, Fn, FA} <- maps:keys(Funcs), M =:= Mod, Fn =:= F]),
                    Msg = iolist_to_binary(io_lib:format(
                        "Call to ~s:~s/~B: ~s has no such function~s",
                        [Mod, F, A, Mod, case Arities of
                                             [] -> "";
                                             _ -> io_lib:format(" (it has ~s/~s)", [F, lists:join(", ", [integer_to_list(X) || X <- Arities])])
                                         end])),
                    [#prisma_warning{kind = unknown_function, mfa = CallerMFA, line = Line, message = Msg, callee = CalleeMFA}];
                _ ->
                    []
            end
    end.

provided_by_the_compiler(erlang, _, _) -> true;
provided_by_the_compiler(_, module_info, 0) -> true;
provided_by_the_compiler(_, module_info, 1) -> true;
provided_by_the_compiler(_, behaviour_info, 1) -> true;
provided_by_the_compiler(_, _, _) -> false.

verify_gradual_calls(#func_contract{mfa = {CallerMod, _, _} = CallerMFA, call_sites = Sites}, Pplt) ->
    lists:flatmap(
        fun(Site) ->
            {Line, {CalleeMod, _, _} = CalleeMFA, ActualArgs, Tag} = site_parts(Site),
            case Tag =:= environment orelse prisma_pplt:lookup_mfa(CalleeMFA, Pplt) of
                true ->
                    [];
                {ok, #func_contract{declared_specs = [ _ | _ ] = Specs, inferred_type = Inferred}} ->
                    case resolve_expected_arg_vectors(CallerMod, CalleeMod, Specs, Inferred, Pplt) of
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

%% A value known only by its wide type (`integer()`, `number()`, `[T]`) against a narrower contract is a gap in what is proven, not a
%% contradiction: it is not reported. What is proven to fall outside the contract (a literal, a range, another type) still is.
-spec accepts(term(), term()) -> boolean().
accepts(Actual, Expected) ->
    prisma_type:consistent_subtype(Actual, Expected) orelse unproven_gap(Actual, Expected).

unproven_gap({union, Members}, Expected) ->
    lists:all(fun(M) -> accepts(M, Expected) end, Members);
unproven_gap(Actual, {union, Members}) ->
    lists:any(fun(M) -> unproven_gap(Actual, M) end, Members);
unproven_gap(integer, Expected) ->
    narrower_integer(Expected);
unproven_gap(number, Expected) ->
    Expected =:= integer orelse narrower_integer(Expected);
unproven_gap(non_neg_integer, {int_range, 0, _}) ->
    true;
%% a binary known only as `binary()` or `bitstring()` against `<<_:8, _:_*8>>` (a non-empty binary) or `<<_:_*16>>`: it may well be one
unproven_gap({binary, _, _} = Actual, {binary, _, _} = Expected) ->
    prisma_type:meet(Actual, Expected) =/= none;
unproven_gap({list, Elem}, {nonempty_list, ExpectedElem}) ->
    prisma_type:consistent_subtype(Elem, ExpectedElem);
unproven_gap(_, _) ->
    false.

narrower_integer(non_neg_integer) -> true;
narrower_integer(pos_integer) -> true;
narrower_integer(neg_integer) -> true;
narrower_integer({int_range, _, _}) -> true;
narrower_integer(_) -> false.

check_gradual_args(CallerMFA, Line, {CM, CF, CA}, ZipArgs) ->
    {Warns, _} = lists:foldl(
        fun({Actual, Expected}, {WAcc, Idx}) ->
            case accepts(Actual, Expected) of
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
                    W = #prisma_warning{
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
resolve_expected_arg_vectors(CallerMod, CalleeMod, [_ | _] = SpecClauses, _Inferred, Pplt) ->
    Vectors = lists:filtermap(
        fun(SpecClause) ->
            case prisma_type:unfold_bounded_fun(SpecClause) of
                {fun_type, SpecArgs, _Ret} ->
                    {true, [
                        case prisma_pplt:resolve_type(CallerMod, CalleeMod, A, Pplt) of
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
resolve_expected_arg_vectors(_CallerMod, _CalleeMod, [], {fun_type, InferredArgs, _Ret}, _Pplt) ->
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

verify_gradual_spec(_MFA, [], _Inferred, _Line, _Pplt) ->
    [];
verify_gradual_spec({Mod, _, _} = MFA, [_ | _] = SpecClauses, {fun_type, _InferredArgs, InferredRet}, Line, Pplt) ->
    DeclaredReturns = lists:filtermap(
        fun(Clause) ->
            case extract_spec_return(Mod, Clause, Pplt) of
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
            DeclaredUnion = prisma_type:normalize_union(DeclaredReturns),
            case accepts(InferredRet, DeclaredUnion) of
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
                    [#prisma_warning{
                        kind = Kind,
                        mfa = MFA,
                        line = Line,
                        message = Msg,
                        declared = DeclaredUnion,
                        actual = InferredRet
                    }]
            end
    end;
verify_gradual_spec(_MFA, _Specs, _Inferred, _Line, _Pplt) ->
    [].

extract_spec_return(Mod, SpecClause, Pplt) ->
    case prisma_type:unfold_bounded_fun(SpecClause) of
        {fun_type, _Args, RetType} ->
            case prisma_pplt:resolve_type(Mod, Mod, RetType, Pplt) of
                {ok, Resolved} -> {ok, Resolved};
                {error, _} -> {ok, RetType}
            end;
        _ ->
            error
    end.

%% @doc Formats a single `#prisma_warning{}` using default options.
-spec format_warning(#prisma_warning{}) -> binary().
format_warning(Warning) ->
    format_warning(Warning, #{}).

%% @doc Formats a `#prisma_warning{}` according to `Opts` (`human`, `oneline`, `json`, colors).
-spec format_warning(#prisma_warning{}, map()) -> binary().
format_warning(#prisma_warning{} = W, Opts) ->
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

%% @doc Formats a list of `#prisma_warning{}` with default options.
-spec format_warnings([#prisma_warning{}]) -> binary().
format_warnings(Warnings) ->
    format_warnings(Warnings, #{}).

%% @doc Formats a list of `#prisma_warning{}` according to `Opts`.
-spec format_warnings([#prisma_warning{}], map()) -> binary().
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

format_human(#prisma_warning{
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
    CleanMod = prisma_type:clean_module(Mod),
    Lang = case atom_to_binary(Mod, utf8) of
        <<"Elixir.", _/binary>> -> elixir;
        _ -> erlang
    end,
    KindStr = kind_label(Kind),
    KindColor = case Kind of
        discrepancy -> "\e[1;31m";       %% bold red
        dead_code -> "\e[1;33m";         %% bold yellow
        oxbow_code -> "\e[1;33m";        %% bold yellow
        gradual_mismatch -> "\e[1;35m";  %% bold magenta
        opacity_violation -> "\e[1;31m"; %% bold red
        handled_undef -> "\e[2m";        %% dim: the code handles it
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
            DeclStr = prisma_type:format(Decl, #{lang => Lang}),
            ActStr = prisma_type:format(Act, #{lang => Lang}),
            [
                "\n  ", colorize("Declared:", "\e[1;36m", Color), "  ", DeclStr,
                "\n  ", colorize("Inferred:", "\e[1;31m", Color), "  ", ActStr
            ];
        {undefined, Act, Exp} when Exp =/= undefined, Act =/= undefined ->
            ExpStr = prisma_type:format(Exp, #{lang => Lang}),
            ActStr = prisma_type:format(Act, #{lang => Lang}),
            CalleeLines = case Callee of
                {CM, CF, CA} ->
                    CleanCM = prisma_type:clean_module(CM),
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

format_oneline(#prisma_warning{
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
    CleanMod = prisma_type:clean_module(Mod),
    Lang = case atom_to_binary(Mod, utf8) of
        <<"Elixir.", _/binary>> -> elixir;
        _ -> erlang
    end,
    Tag = colorize("[" ++ kind_label(Kind) ++ "]", "\e[1m", Color),
    SourcePrefix = case File of
        undefined -> CleanMod;
        _ -> File
    end,
    Loc = io_lib:format("~s:~B: ~s ~s:~s/~B", [SourcePrefix, Line, Tag, CleanMod, atom_to_list(Fun), Arity]),
    Desc = case {Declared, Actual, Expected} of
        {Decl, Act, undefined} when Decl =/= undefined, Act =/= undefined ->
            io_lib:format("declared ~s is incompatible with inferred ~s", [
                prisma_type:format(Decl, #{lang => Lang}),
                prisma_type:format(Act, #{lang => Lang})
            ]);
        {undefined, Act, Exp} when Exp =/= undefined, Act =/= undefined ->
            Target = case Callee of
                {CM, CF, CA} -> io_lib:format("to ~s:~s/~B ", [prisma_type:clean_module(CM), atom_to_list(CF), CA]);
                _ -> ""
            end,
            ArgStr = case ArgIdx of undefined -> ""; N -> io_lib:format("arg #~B ", [N]) end,
            io_lib:format("call ~s~sof type ~s does not match expected ~s", [
                Target, ArgStr,
                prisma_type:format(Act, #{lang => Lang}),
                prisma_type:format(Exp, #{lang => Lang})
            ]);
        _ ->
            clean_message_text(Msg)
    end,
    iolist_to_binary([Loc, ": ", Desc]).

encode_warning_json(#prisma_warning{
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
    CleanMod = prisma_type:clean_module(Mod),
    Lang = case atom_to_binary(Mod, utf8) of <<"Elixir.", _/binary>> -> elixir; _ -> erlang end,
    Base = [
        <<"  {\n">>,
        <<"    \"kind\": \"">>, atom_to_binary(Kind, utf8), <<"\",\n">>,
        <<"    \"severity\": \"">>, atom_to_binary(severity(Kind), utf8), <<"\",\n">>,
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
        _ -> [<<",\n    \"declared\": \"">>, json_escape(prisma_type:format(Declared, #{lang => Lang})), <<"\"">>]
    end,
    ExtraActual = case Actual of
        undefined -> [];
        _ -> [<<",\n    \"actual\": \"">>, json_escape(prisma_type:format(Actual, #{lang => Lang})), <<"\"">>]
    end,
    ExtraExpected = case Expected of
        undefined -> [];
        _ -> [<<",\n    \"expected\": \"">>, json_escape(prisma_type:format(Expected, #{lang => Lang})), <<"\"">>]
    end,
    ExtraArgIdx = case ArgIdx of
        undefined -> [];
        _ -> [<<",\n    \"arg_idx\": ">>, integer_to_binary(ArgIdx)]
    end,
    ExtraCallee = case Callee of
        {CM, CF, CA} ->
            [
                <<",\n    \"callee\": {\"module\": \"">>, json_escape(prisma_type:clean_module(CM)),
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
