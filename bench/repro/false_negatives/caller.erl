-module(caller).
-export([plain/0, in_fun/0, in_try/0, in_record/0, guard_bif/1, bif_body/0, missing/0, ret/0]).
-record(st, {x}).
plain() ->
    callee:g(oops).
in_fun() ->
    F = fun(_) -> callee:g(oops) end,
    F(1).
in_try() ->
    try callee:g(oops) of
        ok -> a
    catch _:_ -> b
    end.
in_record() ->
    #st{x = callee:g(oops)}.
guard_bif(X) when length(oops) > X -> yes;
guard_bif(_) -> no.
bif_body() ->
    length(oops).
missing() ->
    callee:nonexistent(1).
ret() ->
    {ok, V} = callee:h(),
    V.
