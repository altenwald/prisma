-module(prisma_otp_specs_tests).

-include_lib("eunit/include/eunit.hrl").

%% False positives that showed up once Prisma knew the specs of OTP and of the dependencies (the comparison with Gradualizer):
%% a value known only by a wide type against the narrower contract of a callee is not a contradiction.

warnings(Src) ->
    {ok, Tokens, _} = erl_scan:string("-module(otp_sample).\n" ++ Src),
    Forms = parse(Tokens, [], []),
    {ok, otp_sample, Beam} = compile:forms(Forms, [debug_info]),
    {ok, Warnings} = prisma:analyze_beams([Beam], #{mode => hybrid, oxbow => false}),
    Warnings.

parse([], [], Acc) -> lists:reverse(Acc);
parse([{dot, _} = D | Rest], Cur, Acc) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([D | Cur])),
    parse(Rest, [], [Form | Acc]);
parse([T | Rest], Cur, Acc) -> parse(Rest, [T | Cur], Acc).

a_map_literal_has_its_keys_test() ->
    %% supervisor:start_child(Sup, #{id => ..., start => ...}): the child spec is a literal
    Src = "-export([f/0]).\n-spec need(#{id := atom(), start := {atom(), atom(), list()}}) -> tuple().\n"
          "need(M) -> {ok, M}.\n"
          "-spec f() -> tuple().\nf() -> need(#{id => a, start => {m, f, []}, restart => transient}).\n",
    ?assertEqual([], warnings(Src)).

an_unknown_fun_fits_a_fun_with_arguments_test() ->
    Src = "-export([f/1]).\n-spec need(fun((integer()) -> integer())) -> tuple().\nneed(F) -> {ok, F}.\n"
          "-spec f(fun()) -> tuple().\nf(F) -> need(F).\n",
    ?assertEqual([], warnings(Src)).

a_binary_fits_a_non_empty_binary_test() ->
    Src = "-export([f/1]).\n-spec need(<<_:8, _:_*8>>) -> tuple().\nneed(B) -> {ok, B}.\n"
          "-spec f(binary()) -> tuple().\nf(B) -> need(B).\n",
    ?assertEqual([], warnings(Src)),
    %% and a bitstring that cannot be a binary of whole bytes is still a clash
    Src2 = "-export([f/1]).\n-spec need(<<_:8, _:_*8>>) -> tuple().\nneed(B) -> {ok, B}.\n"
           "-spec f(<<_:3>>) -> tuple().\nf(B) -> need(B).\n",
    ?assertNotEqual([], warnings(Src2)).

a_non_negative_integer_against_a_positive_one_is_still_reported_test() ->
    %% `N - 1` with `N :: pos_integer()` is `non_neg_integer()`: tolerating it would hide the README example, so
    %% `rand:uniform(non_neg_integer())` stays a true warning (the argument may be 0)
    Src = "-export([f/1]).\n-spec need(pos_integer()) -> tuple().\nneed(N) -> {ok, N}.\n"
          "-spec f(non_neg_integer()) -> tuple().\nf(N) -> need(N).\n",
    ?assertMatch([_], warnings(Src)).

%% A variable that nothing is known of does not become "what the callee accepts" because it was passed to a callee without a
%% `-spec`: that domain was inferred from the callee's clauses (here a tuple, `none` or a map) and the variable is still
%% whatever the caller got. Using it afterwards as a map is not a contradiction.
a_call_to_a_function_without_a_spec_does_not_narrow_an_unknown_variable_test() ->
    Src = "-export([f/1]).\n"
          "active({_, _, _}) -> a;\nactive(none) -> b;\nactive(M) when is_map(M) -> c.\n"
          "-spec getk(map()) -> term().\ngetk(M) -> maps:get(k, M, undefined).\n"
          "f(M) -> {active(M), getk(M)}.\n",
    ?assertEqual([], warnings(Src)).
