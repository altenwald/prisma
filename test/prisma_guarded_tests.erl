-module(prisma_guarded_tests).

-include_lib("eunit/include/eunit.hrl").
-include("prisma.hrl").

%% A call that the code itself protects is not an error of the code: a check of what the running system has (`function_exported`,
%% `system_info`, `code:ensure_loaded`...), or a `try` that catches the `undef`. Prisma stays quiet there. A catch-all `try`
%% also handles it, but it would hide a misspelled function for good, so that case is a warning of its own (`handled_undef`) that is
%% only shown when asked for.

compile_forms(Name, Src) ->
    {ok, Tokens, _} = erl_scan:string("-module(" ++ Name ++ ").\n" ++ Src),
    Forms = split(Tokens, [], []),
    {ok, _, Beam} = compile:forms(Forms, [debug_info, binary]),
    Beam.

split([], [], Acc) -> lists:reverse(Acc);
split([{dot, _} = D | Rest], Cur, Acc) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([D | Cur])),
    split(Rest, [], [Form | Acc]);
split([T | Rest], Cur, Acc) -> split(Rest, [T | Cur], Acc).

kinds(Body) -> kinds(Body, #{}).

kinds(Body, Opts) ->
    Callee = compile_forms("guard_callee", "-export([present/0]).\npresent() -> ok.\n"),
    Caller = compile_forms("guard_caller", "-export([f/0]).\nf() ->\n" ++ Body ++ ".\n"),
    {ok, Ws} = prisma:analyze_beams([Callee, Caller], Opts#{mode => discrepancy, oxbow => false}),
    lists:sort([K || #prisma_warning{kind = K} <- Ws, K =/= system_branch]).

notes(Body) ->
    Callee = compile_forms("guard_callee", "-export([present/0]).\npresent() -> ok.\n"),
    Caller = compile_forms("guard_caller", "-export([f/0]).\nf() ->\n" ++ Body ++ ".\n"),
    {ok, Ws} = prisma:analyze_beams([Callee, Caller], #{mode => discrepancy, oxbow => false}),
    [K || #prisma_warning{kind = K} <- Ws, K =:= system_branch].

a_call_to_a_missing_function_is_reported_test() ->
    ?assertEqual([unknown_function], kinds("    guard_callee:missing(1)")).

function_exported_protects_the_call_test() ->
    Body = "    case erlang:function_exported(guard_callee, missing, 1) of\n"
           "        true -> guard_callee:missing(1);\n"
           "        false -> ok\n"
           "    end",
    ?assertEqual([], kinds(Body)).

what_the_system_has_protects_the_branch_test() ->
    Body = "    case erlang:system_info(otp_release) of\n"
           "        \"5\" -> guard_callee:missing(1);\n"
           "        _ -> ok\n"
           "    end",
    ?assertEqual([], kinds(Body)),
    Ensure = "    case code:ensure_loaded(guard_callee) of\n"
             "        {module, _} -> guard_callee:missing(1);\n"
             "        {error, _} -> ok\n"
             "    end",
    ?assertEqual([], kinds(Ensure)).

an_error_that_does_not_depend_on_the_system_is_still_reported_test() ->
    Body = "    case erlang:system_info(otp_release) of\n"
           "        \"5\" -> 1 + foo;\n"
           "        _ -> ok\n"
           "    end",
    ?assertEqual([discrepancy], kinds(Body)).

try_that_catches_undef_protects_the_call_test() ->
    ?assertEqual([], kinds("    try guard_callee:missing(1) catch error:undef -> ok end")),
    ?assertEqual([], kinds("    try guard_callee:missing(1) catch _:undef -> ok end")).

try_that_catches_everything_is_a_warning_not_an_error_test() ->
    Body = "    try guard_callee:missing(1) catch error:_ -> ok end",
    ?assertEqual([handled_undef], kinds(Body)),
    ?assertEqual([handled_undef], kinds("    try guard_callee:missing(1) catch _:_ -> ok end")),
    ?assertEqual(warning, prisma_checker:severity(handled_undef)),
    ?assertEqual(error, prisma_checker:severity(unknown_function)),
    %% an explicit `error:undef` is the author saying so: nothing to show
    ?assertEqual([], kinds("    try guard_callee:missing(1) catch error:undef -> ok end")).

try_that_does_not_catch_an_error_does_not_protect_the_call_test() ->
    ?assertEqual([unknown_function], kinds("    try guard_callee:missing(1) catch throw:_ -> ok end")),
    %% the call is in the `catch` clause, not in the protected body
    ?assertEqual([unknown_function], kinds("    try ok catch error:undef -> guard_callee:missing(1) end")).

%% A condition on what the running system has is decided against the system that runs the analysis: a branch that it takes is checked as any
%% other (it runs here, so a call to a function that does not exist fails here), one that it does not take is not an error of this system.

release() -> erlang:system_info(otp_release).

env_case(Cond, Then, Else) ->
    "    case " ++ Cond ++ " of\n        true -> " ++ Then ++ ";\n        false -> " ++ Else ++ "\n    end".

a_branch_that_this_system_takes_is_checked_test() ->
    Body = "    case erlang:system_info(otp_release) of\n"
           "        \"" ++ release() ++ "\" -> guard_callee:missing(1);\n"
           "        _ -> ok\n"
           "    end",
    ?assertEqual([unknown_function], kinds(Body)).

a_branch_that_this_system_does_not_take_is_not_an_error_test() ->
    Body = "    case erlang:system_info(otp_release) of\n"
           "        \"1\" -> guard_callee:missing(1);\n"
           "        _ -> ok\n"
           "    end",
    ?assertEqual([], kinds(Body)),
    %% and the other one is the one that runs
    Other = "    case erlang:system_info(otp_release) of\n"
            "        \"1\" -> ok;\n"
            "        _ -> guard_callee:missing(1)\n"
            "    end",
    ?assertEqual([unknown_function], kinds(Other)).

comparisons_with_the_release_are_decided_test() ->
    Cmp = fun(Op, N) -> "list_to_integer(erlang:system_info(otp_release)) " ++ Op ++ " " ++ integer_to_list(N) end,
    ?assertEqual([unknown_function], kinds(env_case(Cmp(">=", 1), "guard_callee:missing(1)", "ok"))),
    ?assertEqual([], kinds(env_case(Cmp(">=", 9999), "guard_callee:missing(1)", "ok"))),
    ?assertEqual([unknown_function], kinds(env_case(Cmp(">=", 9999), "ok", "guard_callee:missing(1)"))).

function_exported_is_decided_when_the_module_is_known_test() ->
    %% lists:seq/2 exists: the call runs here and the missing function fails
    ?assertEqual([unknown_function],
                 kinds(env_case("erlang:function_exported(lists, seq, 2)", "guard_callee:missing(1)", "ok"))),
    %% lists:nope/0 does not exist: the true branch is not taken here
    ?assertEqual([], kinds(env_case("erlang:function_exported(lists, nope, 0)", "guard_callee:missing(1)", "ok"))),
    ?assertEqual([unknown_function],
                 kinds(env_case("erlang:function_exported(lists, nope, 0)", "ok", "guard_callee:missing(1)"))).


%% What depends on the system and is not taken here is not checked (it would be judged with the API of this OTP, not the one it is for):
%% it is counted, not reported.
a_branch_that_is_not_taken_is_counted_not_reported_test() ->
    Body = "    case erlang:system_info(otp_release) of\n"
           "        \"1\" -> guard_callee:missing(1);\n"
           "        _ -> ok\n"
           "    end",
    ?assertEqual([], kinds(Body)),
    ?assertEqual([system_branch], notes(Body)),
    ?assertEqual(note, prisma_checker:severity(system_branch)),
    %% nothing to check in it: nothing to count
    NoCall = "    case erlang:system_info(otp_release) of\n        \"1\" -> ok;\n        _ -> ok\n    end",
    ?assertEqual([], notes(NoCall)),
    %% a branch that is taken here is checked, so it is not counted
    Taken = "    case erlang:system_info(otp_release) of\n        \"" ++ release() ++ "\" -> guard_callee:missing(1);\n        _ -> ok\n    end",
    ?assertEqual([], notes(Taken)).

%% What a command prints and whether it fails: errors fail, warnings do not unless asked, notes are only counted.
%% Errors are what is proven to fail; dead code and unused parameters are certain but do not fail when the code runs: warnings.
severity_of_each_kind_test() ->
    [?assertEqual(error, prisma_checker:severity(K)) || K <- [discrepancy, unknown_function, gradual_mismatch, opacity_violation]],
    [?assertEqual(warning, prisma_checker:severity(K)) || K <- [dead_code, oxbow_code, handled_undef]],
    ?assertEqual(note, prisma_checker:severity(system_branch)).

report_levels_test() ->
    Mk = fun(Kind) -> #prisma_warning{kind = Kind, mfa = {m, f, 0}, line = 1, message = <<"x">>} end,
    All = [Mk(discrepancy), Mk(handled_undef), Mk(system_branch), Mk(system_branch)],
    R1 = prisma_checker:report(All, #{}),
    ?assertMatch(#{failed := true, errors := 1, warnings := 1, unchecked := 2}, R1),
    R2 = prisma_checker:report([Mk(handled_undef)], #{}),
    ?assertMatch(#{failed := false, errors := 0, warnings := 1}, R2),
    R3 = prisma_checker:report([Mk(handled_undef)], #{warnings_as_errors => true}),
    ?assertMatch(#{failed := true}, R3),
    R4 = prisma_checker:report([Mk(discrepancy), Mk(handled_undef)], #{no_warnings => true}),
    ?assertMatch(#{failed := true, errors := 1, warnings := 0}, R4),
    ?assertEqual(nomatch, string:find(iolist_to_binary(maps:get(output, R4)), "handled_undef")),
    ?assertMatch(#{failed := false, errors := 0, warnings := 0}, prisma_checker:report([], #{})).

cli_options_for_warnings_test() ->
    ?assertMatch(#{no_warnings := true}, prisma:parse_check_opts(["--no-warnings"])),
    ?assertMatch(#{warnings_as_errors := true}, prisma:parse_check_opts(["--warnings-as-errors"])),
    ?assertNot(maps:is_key(show_handled, prisma:parse_check_opts(["--show-handled"]))).
