-module(orelse_non_boolean).
-export([e/1, f/0, g/1]).
-spec e(integer()) -> boolean().
e(X) -> X > 0 orelse {false, "negative"}.
-spec h(blocking) -> ok; (non_blocking) -> ok.
h(_) -> ok.
f() -> h(non_blocking).
g(X) -> e(X).
