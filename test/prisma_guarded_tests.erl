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
    lists:sort([K || #prisma_warning{kind = K} <- Ws]).

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

try_that_catches_everything_is_not_an_error_but_can_be_asked_for_test() ->
    Body = "    try guard_callee:missing(1) catch error:_ -> ok end",
    ?assertEqual([], kinds(Body)),
    ?assertEqual([handled_undef], kinds(Body, #{show_handled => true})),
    ?assertEqual([handled_undef], kinds("    try guard_callee:missing(1) catch _:_ -> ok end", #{show_handled => true})),
    %% an explicit `error:undef` is the author saying so: nothing to show
    ?assertEqual([], kinds("    try guard_callee:missing(1) catch error:undef -> ok end", #{show_handled => true})).

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
