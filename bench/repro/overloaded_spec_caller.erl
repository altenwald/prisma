-module(overloaded_spec_caller).
-export([f/0]).
f() -> overloaded_spec_callee:h(non_blocking).
