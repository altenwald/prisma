-module(byte_size_loses_binary).
-export([f/2]).

-spec need(binary()) -> non_neg_integer().
need(B) -> byte_size(B).

%% byte_size/1 accepts any bitstring, but Bin was a binary before the call and stays one after it
-spec f(binary(), non_neg_integer()) -> non_neg_integer() | too_big.
f(Bin, Max) when is_binary(Bin) ->
    case byte_size(Bin) =< Max of
        true -> need(Bin);
        false -> too_big
    end.
