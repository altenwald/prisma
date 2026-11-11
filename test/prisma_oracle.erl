%% Semantic oracle shared by the PropEr properties: decides whether a concrete term belongs to a `prisma_type:stype()`.
%% Forms the oracle does not model (maps, funs, records, named types) are answered `true`, so they can never
%% produce a false alarm in a property; only what it models can be falsified.
-module(prisma_oracle).

-export([member/2]).

member(_, any) -> true;
member(_, none) -> false;
member(_, {var, _}) -> true;
member(V, integer) -> is_integer(V);
member(V, pos_integer) -> is_integer(V) andalso V > 0;
member(V, non_neg_integer) -> is_integer(V) andalso V >= 0;
member(V, neg_integer) -> is_integer(V) andalso V < 0;
member(V, {int_lit, I}) -> V =:= I;
member(V, {int_range, Lo, Hi}) ->
    is_integer(V) andalso (Lo =:= neg_inf orelse V >= Lo) andalso (Hi =:= pos_inf orelse V =< Hi);
member(V, float) -> is_float(V);
member(V, number) -> is_number(V);
member(V, atom) -> is_atom(V);
member(V, boolean) -> is_boolean(V);
member(V, {atom_lit, A}) -> V =:= A;
member(V, {binary, Base, 0}) ->
    is_bitstring(V) andalso bit_size(V) =:= Base;
member(V, {binary, Base, Unit}) when Unit > 0 ->
    is_bitstring(V) andalso bit_size(V) >= Base andalso (bit_size(V) - Base) rem Unit =:= 0;
member(V, any_tuple) -> is_tuple(V);
member(V, {tuple, Ts}) ->
    is_tuple(V) andalso tuple_size(V) =:= length(Ts) andalso
        lists:all(fun({X, T}) -> member(X, T) end, lists:zip(tuple_to_list(V), Ts));
member(V, nil) -> V =:= [];
member(V, {list, T}) -> proper(V) andalso lists:all(fun(X) -> member(X, T) end, V);
member(V, {nonempty_list, T}) -> V =/= [] andalso member(V, {list, T});
member(V, {improper_list, H, T}) ->
    %% maybe_improper_list(H, T): [] | [H | Rest] where Rest is again that type or a T
    V =:= [] orelse (is_list(V) andalso improper_ok(V, H, T));
member(V, any_map) -> is_map(V);
member(V, {map, Fields}) ->
    is_map(V) andalso lists:all(
        fun
            ({exact, {atom_lit, K}, VT}) -> maps:is_key(K, V) andalso member(maps:get(K, V), VT);
            ({exact, {int_lit, K}, VT}) -> maps:is_key(K, V) andalso member(maps:get(K, V), VT);
            (_) -> true
        end,
        Fields
    );
member(V, {union, Ts}) -> lists:any(fun(T) -> member(V, T) end, Ts);
member(_, _Unmodelled) -> true.

improper_ok([X | Rest], H, T) ->
    member(X, H) andalso (Rest =:= [] orelse member(Rest, T) orelse improper_ok(Rest, H, T));
improper_ok(_, _, _) -> false.

proper([]) -> true;
proper([_ | T]) -> proper(T);
proper(_) -> false.
