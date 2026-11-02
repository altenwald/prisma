-module(improper_list_and_andalso).
-export([a/1, b/1, c/0, d/0]).
-define(CELL(H, T), [H | T]).
-spec a(integer() | map()) -> atom().
a(X) when is_integer(X) -> int;
a(X) when is_map(X) -> map.
b(Cell) -> a(tl(Cell)).
c() -> b(?CELL(1, 2)).
d() -> case is_list([a]) andalso lists:keyfind(k, 1, [{k, v}]) of {k, V} -> V; false -> none end.
