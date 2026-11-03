-module(callee).
-export([g/1, h/0]).
-spec g(integer()) -> ok.
g(_) -> ok.
h() -> ok.
