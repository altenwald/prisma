-module(negative_literal).
-export([f/0, g/0, h/0]).
f() -> -1.
g() -> case f() of -1 -> ok end.
h() -> f() + 1.
