-module(spectra_infer_patterns_tests).

-include_lib("eunit/include/eunit.hrl").

%% What a variable is bound to by a pattern when the scrutinee is a union of tuples: only the alternatives the
%% pattern can match count. `{ok, B}` against `{ok, binary()} | {error, atom()}` makes B a binary.

gradual_warnings(Src) ->
    {ok, Tokens, _} = erl_scan:string("-module(pat_sample).\n" ++ Src),
    Forms = parse(Tokens),
    {ok, pat_sample, Beam} = compile:forms(Forms, [debug_info]),
    {ok, Warnings} = spectra:analyze_beams([Beam], #{mode => hybrid}),
    Warnings.

parse(Tokens) ->
    parse(Tokens, [], []).

parse([], [], Acc) -> lists:reverse(Acc);
parse([{dot, _} = D | Rest], Cur, Acc) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([D | Cur])),
    parse(Rest, [], [Form | Acc]);
parse([T | Rest], Cur, Acc) -> parse(Rest, [T | Cur], Acc).

union_of_tagged_tuples_binds_by_tag_test() ->
    Src = "-export([f/1]).\n"
          "-spec g(binary()) -> {ok, binary()} | {error, atom()}.\ng(B) -> {ok, B}.\n"
          "-spec need(binary()) -> non_neg_integer().\nneed(B) -> byte_size(B).\n"
          "-spec f(binary()) -> non_neg_integer() | string() | {error, atom()}.\n"
          "f(B) ->\n    case g(B) of\n        {ok, Etf} -> need(Etf);\n        {error, _} = E -> E\n    end.\n",
    ?assertEqual([], gradual_warnings(Src)).

union_of_tagged_tuples_still_catches_a_wrong_use_test() ->
    Src = "-export([f/1]).\n"
          "-spec g(binary()) -> {ok, binary()} | {error, atom()}.\ng(B) -> {ok, B}.\n"
          "-spec need(atom()) -> string().\nneed(A) -> atom_to_list(A).\n"
          "-spec f(binary()) -> non_neg_integer() | string() | {error, atom()}.\n"
          "f(B) ->\n    case g(B) of\n        {ok, Etf} -> need(Etf);\n        {error, _} = E -> E\n    end.\n",
    ?assertNotEqual([], gradual_warnings(Src)).
