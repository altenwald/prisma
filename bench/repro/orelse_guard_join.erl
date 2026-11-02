-module(orelse_guard_join).
-export([f/2]).
-record(st, {range}).
%% Range is constrained in one branch of the guard only: afterwards it can be anything (ra_log:write_sparse/3)
f(P, #st{range = Range}) when P == undefined orelse Range == undefined orelse P == 1 ->
    case Range of
        undefined -> a;
        {_, _} -> b
    end;
f(_, _) -> c.
