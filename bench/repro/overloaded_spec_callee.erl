-module(overloaded_spec_callee).
-export([h/1]).
-spec h(blocking) -> ok; (non_blocking) -> ok.
h(_) -> ok.
