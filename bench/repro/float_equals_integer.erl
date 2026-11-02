-module(float_equals_integer).
-export([f/1]).
f(X) ->
    T = X / 2,
    if
        T == 0 -> zero;
        true -> other
    end.
