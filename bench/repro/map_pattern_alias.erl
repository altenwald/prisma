-module(map_pattern_alias).
-export([f/1]).

-type inv() :: #{states := map(), apps := map()}.

%% matching a key of the map does not take the other keys of the argument's type away
-spec f(inv()) -> {ok, inv()}.
f(#{states := _} = I) -> {ok, I}.
