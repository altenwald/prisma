%% PropEr properties for the type algebra of `spectra_type`.
%%
%% The oracle is semantic: `member/2` decides whether a concrete Erlang term belongs to a ground type, and the
%% generators build terms of a given type. Types are ground and free of `any` (which is consistent with everything by
%% design, so set inclusion says nothing about it); maps, funs, records and variables are not generated yet.
-module(prop_spectra_type).

-include_lib("proper/include/proper.hrl").

%% -------------------------------------------------------------------------
%% Semantic oracle (shared: test/spectra_oracle.erl)
%% -------------------------------------------------------------------------

member(V, T) -> spectra_oracle:member(V, T).

%% -------------------------------------------------------------------------
%% Generators
%% -------------------------------------------------------------------------

stype() -> ?SIZED(Size, stype(min(Size, 4))).

stype(0) -> leaf();
stype(N) ->
    Sub = ?LAZY(stype(N div 2)),
    frequency([
        {3, leaf()},
        {1, {list, Sub}},
        {1, {nonempty_list, Sub}},
        {1, {improper_list, Sub, non_list()}},
        {1, ?LET(Ts, resize(3, list(Sub)), {tuple, Ts})},
        {2, ?LET(Ts, resize(3, non_empty(list(Sub))), {union, Ts})}
    ]).

%% Tails that cannot be lists. The type language has no non-empty improper list, so meeting an improper list whose tail
%% may be a list with a non-empty list is only a safe superset (it also holds []), not exact.
non_list() -> ?SUCHTHAT(L, leaf(), L =/= nil).

leaf() ->
    oneof([
        integer, pos_integer, non_neg_integer, neg_integer, float, number, atom, boolean, any_tuple, nil,
        {int_lit, range(-5, 5)},
        ?LET({A, B}, {range(-20, 20), range(-20, 20)}, {int_range, min(A, B), max(A, B)}),
        {int_range, range(-10, 10), pos_inf},
        {atom_lit, oneof([a, b, true, false, undefined])}
    ]).

%% A term of type T.
value(integer) -> integer();
value(pos_integer) -> pos_integer();
value(non_neg_integer) -> non_neg_integer();
value(neg_integer) -> neg_integer();
value({int_lit, I}) -> I;
value({int_range, Lo, pos_inf}) -> ?LET(N, non_neg_integer(), Lo + N);
value({int_range, Lo, Hi}) -> range(Lo, Hi);
value(float) -> float();
value(number) -> oneof([integer(), float()]);
value(atom) -> oneof([a, b, c, true, false, undefined]);
value(boolean) -> boolean();
value({atom_lit, A}) -> A;
value(any_tuple) -> ?LET(L, resize(3, list(oneof([integer(), atom()]))), list_to_tuple(L));
value({tuple, Ts}) -> ?LET(L, [value(T) || T <- Ts], list_to_tuple(L));
value(nil) -> [];
value({list, T}) -> resize(4, list(?LAZY(value(T))));
value({nonempty_list, T}) -> resize(4, non_empty(list(?LAZY(value(T)))));
value({improper_list, H, T}) ->
    %% never the bare tail: [] is the only list-less member
    oneof([[], ?LET({Hs, Tail}, {resize(3, non_empty(list(?LAZY(value(H))))), oneof([[], ?LAZY(value(T))])},
                    lists:foldr(fun(X, Acc) -> [X | Acc] end, Tail, Hs))]);
value({union, Ts}) -> ?LET(T, oneof(Ts), value(T)).

%% A type that has at least one inhabitant, with one of them.
inhabited() ->
    ?LET(T, stype(), ?LET(V, value(T), {T, V})).

%% A supertype of T by construction (T is included in the result).
widen(T) ->
    oneof([T, ?LET(X, leaf(), {union, [T, X]}), ?LAZY(widen_inner(T))]).

widen_inner({list, E}) -> ?LET(W, widen(E), {list, W});
widen_inner({nonempty_list, E}) -> oneof([{list, E}, ?LET(W, widen(E), {nonempty_list, W})]);
widen_inner({tuple, Ts}) -> ?LET(Ws, [widen(T) || T <- Ts], {tuple, Ws});
widen_inner({int_lit, _}) -> integer;
widen_inner(pos_integer) -> oneof([integer, non_neg_integer, number]);
widen_inner(non_neg_integer) -> oneof([integer, number]);
widen_inner(neg_integer) -> oneof([integer, number]);
widen_inner(integer) -> number;
widen_inner(float) -> number;
widen_inner({atom_lit, A}) when is_boolean(A) -> oneof([boolean, atom]);
widen_inner({atom_lit, _}) -> atom;
widen_inner(boolean) -> atom;
widen_inner(nil) -> {list, atom};
widen_inner({improper_list, H, T}) -> ?LET({WH, WT}, {widen(H), widen(T)}, {improper_list, WH, WT});
widen_inner(T) -> T.

%% -------------------------------------------------------------------------
%% Properties
%% -------------------------------------------------------------------------

prop_generators_agree_with_oracle() ->
    ?FORALL({T, V}, inhabited(), member(V, T)).

prop_subtype_is_reflexive() ->
    ?FORALL(T, stype(), spectra_type:consistent_subtype(T, T)).

%% If A is consistent-subtype of B, every value of A is a value of B (types are free of `any`).
prop_subtype_is_sound() ->
    ?FORALL({{A, V}, B}, {inhabited(), stype()},
        ?IMPLIES(spectra_type:consistent_subtype(A, B), member(V, B))).

prop_join_is_an_upper_bound() ->
    ?FORALL({{A, V}, B}, {inhabited(), stype()},
        member(V, spectra_type:join(A, B)) andalso member(V, spectra_type:join(B, A))).

prop_meet_is_sound() ->
    ?FORALL({{A, V}, B}, {inhabited(), stype()},
        ?IMPLIES(member(V, spectra_type:meet(A, B)), member(V, B))).

prop_meet_keeps_common_values() ->
    ?FORALL({{A, V}, B}, {inhabited(), stype()},
        ?IMPLIES(member(V, B), member(V, spectra_type:meet(A, B)))).

prop_normalize_union_keeps_members() ->
    ?FORALL({{A, V}, B}, {inhabited(), stype()},
        member(V, spectra_type:normalize_union([A, B]))).

prop_normalize_union_is_idempotent() ->
    ?FORALL(Ts, resize(4, list(stype())),
        begin
            N = spectra_type:normalize_union(Ts),
            N =:= spectra_type:normalize_union([N])
        end).

%% No false mismatch: when B contains A by construction, A must be accepted where B is expected.
prop_widening_is_accepted() ->
    ?FORALL({{A, V}, B}, ?LET(AV, inhabited(), {AV, widen(element(1, AV))}),
        member(V, B) andalso spectra_type:consistent_subtype(A, B)).
