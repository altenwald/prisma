-module(improper_cell_pattern).
-export([f/0, g/0]).
f() ->
    case [0 | 0] of
        [H | T] when is_integer(T) -> H + T
    end.
g() -> f() + 1.
