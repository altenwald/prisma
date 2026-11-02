-module(comparison_with_zero).
-export([ceiling/1, nonnumber/0]).
%% X - T is a float: `Neg < 0` and `Pos > 0` are reachable (cuttlefish_util:ceiling/1)
ceiling(X) when is_float(X) ->
    T = trunc(X),
    case X - T of
        Neg when Neg < 0 -> T;
        Pos when Pos > 0 -> T + 1;
        _ -> T
    end.
%% every non-number is greater than 0: `b > 0` is true
nonnumber() ->
    V = b,
    if
        V > 0 -> yes;
        true -> no
    end.
