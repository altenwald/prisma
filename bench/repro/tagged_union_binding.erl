-module(tagged_union_binding).
-export([f/1]).

-spec g(binary()) -> {ok, binary()} | {error, atom()}.
g(B) -> {ok, B}.

-spec need(binary()) -> ok.
need(_) -> ok.

%% Etf can only be a binary where the pattern is {ok, Etf}
-spec f(binary()) -> ok | {error, atom()}.
f(B) ->
    case g(B) of
        {ok, Etf} -> need(Etf);
        {error, _} = E -> E
    end.
