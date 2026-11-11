%% @doc Canonical type representation and manipulation for Prisma.
%%
%% Converts Erlang Abstract Format type ASTs into normalized algebraic terms
%% supporting polymorphism, bounded_fun constraints, remote types, opaques,
%% and cycle-safe recursive unfolding.
-module(prisma_type).

-include("prisma.hrl").

-define(MAX_IMPROPER_MEET_DEPTH, 2).
-define(MAX_IMPROPER_MEET_WORDS, 300).
-define(MAX_MEET_PAIRS, 256).
-define(WIDEN_DEPTH, 4).
-define(WIDEN_MEMBERS, 16).
-define(WIDEN_LITERALS, 1024).

-export([
    from_abstract/1,
    from_type_attr/3,
    normalize_union/1,
    widen/1,
    join/2,
    meet/2,
    consistent_subtype/2,
    substitute/2,
    unfold_bounded_fun/1,
    expand/4,
    format/1,
    format/2,
    clean_module/1
]).

-export_type([
    stype/0,
    map_field/0,
    type_lookup_fun/0
]).

%% @typedoc Normalized type term stored in `.pplt` files and used by the checker.
-type map_field() :: {exact | assoc, stype(), stype()}.

-type stype() ::
    any
    | none
    | pid
    | port
    | reference
    | float
    | number
    | integer
    | pos_integer
    | non_neg_integer
    | neg_integer
    | {int_lit, integer()}
    | {int_range, integer() | neg_inf, integer() | pos_inf}
    | atom
    | boolean
    | {atom_lit, atom()}
    | {binary, non_neg_integer(), non_neg_integer()}
    | any_tuple
    | {tuple, [stype()]}
    | {record, atom(), [{atom(), stype()}]}
    | nil
    | {list, stype()}
    | {nonempty_list, stype()}
    | {improper_list, stype(), stype()}
    | any_map
    | {map, [map_field()]}
    | any_fun
    | {fun_any_args, stype()}
    | {fun_type, [stype()], stype()}
    | {bounded_fun, [stype()], stype(), #{atom() => stype()}}
    | {var, atom()}
    | {union, [stype()]}
    | {local_type, atom(), [stype()]}
    | {remote_type, module(), atom(), [stype()]}
    | {opaque, module(), atom(), [stype()], stype()}
    | {recursive_ref, type_key(), [stype()]}.

-type type_lookup_fun() :: fun((type_key()) -> {ok, #type_decl{}} | error).

%% @doc Converts an Erlang Abstract Format type AST into a canonical `stype()`.
-spec from_abstract(term()) -> stype().
from_abstract({ann_type, _, [_Var, Type]}) ->
    from_abstract(Type);
from_abstract({paren_type, _, [Type]}) ->
    from_abstract(Type);
from_abstract({integer, _, Int}) ->
    {int_lit, Int};
from_abstract({char, _, Char}) ->
    {int_lit, Char};
from_abstract({op, _, '-', {integer, _, Int}}) ->
    {int_lit, -Int};
from_abstract({atom, _, Atom}) ->
    {atom_lit, Atom};
from_abstract({var, _, '_'}) ->
    any;
from_abstract({var, _, Name}) ->
    {var, Name};
from_abstract({user_type, _, Name, Args}) ->
    {local_type, Name, [from_abstract(A) || A <- Args]};
from_abstract({remote_type, _, [{atom, _, Mod}, {atom, _, Name}, Args]}) ->
    {remote_type, Mod, Name, [from_abstract(A) || A <- Args]};
from_abstract({type, _, bounded_fun, [FunAst, ConstraintsAst]}) ->
    case from_abstract(FunAst) of
        {fun_type, Args, Ret} ->
            Constraints = parse_constraints(ConstraintsAst),
            case map_size(Constraints) of
                0 -> {fun_type, Args, Ret};
                _ -> {bounded_fun, Args, Ret, Constraints}
            end;
        Other ->
            Other
    end;
from_abstract({type, _, 'fun', []}) ->
    any_fun;
from_abstract({type, _, 'fun', [{type, _, any}, Ret]}) ->
    {fun_any_args, from_abstract(Ret)};
from_abstract({type, _, 'fun', [{type, _, product, Args}, Ret]}) ->
    {fun_type, [from_abstract(A) || A <- Args], from_abstract(Ret)};
from_abstract({type, _, range, [Lo, Hi]}) ->
    {int_range, eval_bound(Lo), eval_bound(Hi)};
from_abstract({type, _, binary, []}) ->
    {binary, 0, 8};
from_abstract({type, _, bitstring, []}) ->
    {binary, 0, 1};
from_abstract({type, _, nonempty_binary, []}) ->
    {binary, 8, 8};
from_abstract({type, _, nonempty_bitstring, []}) ->
    {binary, 1, 1};
from_abstract({type, _, binary, [{integer, _, Base}, {integer, _, Unit}]}) ->
    {binary, Base, Unit};
from_abstract({type, _, tuple, any}) ->
    any_tuple;
from_abstract({type, _, tuple, Elements}) when is_list(Elements) ->
    {tuple, [from_abstract(E) || E <- Elements]};
from_abstract({type, _, record, [{atom, _, Name} | Fields]}) ->
    {record, Name, [parse_record_field(F) || F <- Fields]};
from_abstract({type, _, nil, []}) ->
    nil;
from_abstract({type, _, list, []}) ->
    {list, any};
from_abstract({type, _, list, [Elem]}) ->
    {list, from_abstract(Elem)};
from_abstract({type, _, nonempty_list, []}) ->
    {nonempty_list, any};
from_abstract({type, _, nonempty_list, [Elem]}) ->
    {nonempty_list, from_abstract(Elem)};
from_abstract({type, _, maybe_improper_list, []}) ->
    {improper_list, any, any};
from_abstract({type, _, maybe_improper_list, [Elem, Tail]}) ->
    {improper_list, from_abstract(Elem), from_abstract(Tail)};
from_abstract({type, _, nonempty_improper_list, [Elem, Tail]}) ->
    {improper_list, from_abstract(Elem), from_abstract(Tail)};
from_abstract({type, _, map, any}) ->
    any_map;
from_abstract({type, _, map, Fields}) when is_list(Fields) ->
    {map, [parse_map_field(F) || F <- Fields]};
from_abstract({type, _, union, Types}) ->
    normalize_union([from_abstract(T) || T <- Types]);
from_abstract({type, _, Name, Args}) ->
    from_builtin(Name, Args);
from_abstract(_) ->
    any.

%% @doc Builds a `#type_decl{}` record from an abstract type attribute.
-spec from_type_attr(module(), type | opaque | nominal, {atom(), term(), [term()]}) ->
    #type_decl{}.
from_type_attr(Mod, Kind, {Name, BodyAst, ParamAsts}) ->
    Params = [VarName || {var, _, VarName} <- ParamAsts],
    Arity = length(ParamAsts),
    #type_decl{
        key = {Mod, Name, Arity},
        kind = Kind,
        exported = false,
        params = Params,
        body = from_abstract(BodyAst)
    }.

%% @doc Flattens, deduplicates, and simplifies a list of union member types.
-spec normalize_union([stype()]) -> stype().
normalize_union([]) ->
    none;
normalize_union([{union, _} | _] = Types) ->
    normalize_union_general(Types);
normalize_union([T]) ->
    %% what the general path gives for a single type that is not a union (including `none` and `any`)
    T;
normalize_union([T, T]) ->
    T;
normalize_union(Types) ->
    normalize_union_general(Types).

%% It is called all the time, mostly on lists of one or two types: the clauses above are the shortcuts for those.
normalize_union_general(Types) ->
    Flattened = flatten_unions(Types, []),
    WithoutNone = [T || T <- Flattened, T =/= none],
    case lists:member(any, WithoutNone) of
        true ->
            any;
        false ->
            Unique = lists:usort(collapse_booleans(WithoutNone)),
            Absorbed = absorb_subtypes(Unique),
            case Absorbed of
                [] -> none;
                [Single] -> Single;
                Many -> {union, Many}
            end
    end.

%% @doc Bounds an inferred type: nesting deeper than a few levels, and unions with too many members, become `any` (or `atom` /
%% `integer` for a crowd of literals). The result is always a supertype, so nothing that holds of the original stops holding.
%% Without it the type that the inference of a recursive function builds can contain the whole previous pass of itself several
%% times over: one module (an AMQP table parser) reached 48,000 million words once written out, from 9,000 words of memory.
-spec widen(stype()) -> stype().
widen(Type) ->
    widen(Type, ?WIDEN_DEPTH).

widen({union, Members}, Depth) ->
    %% a union is not a level of nesting: its members keep the depth
    case normalize_union([widen(M, Depth) || M <- Members]) of
        {union, Many} = U ->
            case length(Many) > limit_of(Many) of
                true -> collapse_members(Many);
                false -> U
            end;
        Other -> Other
    end;
widen({tuple, _}, 0) -> any;
widen({list, _}, 0) -> any;
widen({nonempty_list, _}, 0) -> any;
widen({improper_list, _, _}, 0) -> any;
widen({map, _}, 0) -> any;
widen({record, _, _}, 0) -> any;
widen({fun_type, _, _}, 0) -> any;
widen(Atomic, 0) -> Atomic;
widen({tuple, [{atom_lit, Tag} = T, Payload]}, ?WIDEN_DEPTH)
  when Tag =:= ok; Tag =:= error ->
    {tuple, [T, widen(Payload, ?WIDEN_DEPTH)]};
widen({tuple, Elems}, Depth) -> {tuple, [widen(E, Depth - 1) || E <- Elems]};
widen({list, Elem}, Depth) -> {list, widen(Elem, Depth - 1)};
widen({nonempty_list, Elem}, Depth) -> {nonempty_list, widen(Elem, Depth - 1)};
widen({improper_list, Elem, Tail}, Depth) -> {improper_list, widen(Elem, Depth - 1), widen(Tail, Depth - 1)};
widen({map, Fields}, Depth) -> {map, [{Kind, widen(K, Depth - 1), widen(V, Depth - 1)} || {Kind, K, V} <- Fields]};
widen({record, Name, Fields}, Depth) -> {record, Name, [{F, widen(T, Depth - 1)} || {F, T} <- Fields]};
widen({fun_type, Args, Ret}, Depth) -> {fun_type, [widen(A, Depth - 1) || A <- Args], widen(Ret, Depth - 1)};
widen(Other, _Depth) -> Other.

%% A flat union of literals (the names of a protocol's methods, say) is cheap and a spec may list every one of them, so it
%% is kept up to a much larger size; what made types explode was nesting, not width.
limit_of(Members) ->
    case lists:all(fun({atom_lit, _}) -> true; ({int_lit, _}) -> true; (_) -> false end, Members) of
        true -> ?WIDEN_LITERALS;
        false -> ?WIDEN_MEMBERS
    end.

collapse_members(Members) ->
    Collapsed = lists:map(fun({atom_lit, _}) -> atom; ({int_lit, _}) -> integer; (M) -> M end, Members),
    case normalize_union(Collapsed) of
        {union, Still} when length(Still) > ?WIDEN_MEMBERS -> any;
        Other -> Other
    end.

%% `<<_:B, _:_*U>>` holds the sizes B, B+U, B+2U, ... (only B when U is 0): the meet is the sizes that both allow.
meet_binary(B1, 0, B2, U2) -> meet_binary_exact(B1, B2, U2);
meet_binary(B1, U1, B2, 0) -> meet_binary_exact(B2, B1, U1);
meet_binary(B1, U1, B2, U2) ->
    Start = erlang:max(B1, B2),
    Unit = U1 * U2 div gcd(U1, U2),
    case [S || S <- lists:seq(Start, Start + Unit - 1), (S - B1) rem U1 =:= 0, (S - B2) rem U2 =:= 0] of
        [First | _] -> {binary, First, Unit};
        [] -> none
    end.

meet_binary_exact(Size, B, 0) when Size =:= B -> {binary, Size, 0};
meet_binary_exact(Size, B, U) when U > 0, Size >= B, (Size - B) rem U =:= 0 -> {binary, Size, 0};
meet_binary_exact(_, _, _) -> none.

gcd(A, 0) -> A;
gcd(A, B) -> gcd(B, A rem B).

%% @doc Computes the least upper bound (union) of two types.
-spec join(stype(), stype()) -> stype().
join(T1, T2) ->
    normalize_union([T1, T2]).

%% @doc Computes the greatest lower bound (intersection) of two types.
%% Returns `none` when the two types are provably disjoint.
-spec meet(stype(), stype()) -> stype().
meet(none, _) -> none;
meet(_, none) -> none;
meet(any, T) -> T;
meet(T, any) -> T;
meet({var, _}, T) -> T;
meet(T, {var, _}) -> T;
meet({recursive_ref, _, _}, T) -> T;
meet(T, {recursive_ref, _, _}) -> T;
meet({local_type, _, _}, T) -> T;
meet(T, {local_type, _, _}) -> T;
meet({remote_type, _, _, _}, T) -> T;
meet(T, {remote_type, _, _, _}) -> T;
meet({opaque, _, _, _, Body}, T) -> meet(Body, T);
meet(T, {opaque, _, _, _, Body}) -> meet(T, Body);
meet(Same, Same) -> Same;
meet({union, Members} = T1, T2) ->
    case too_many_pairs(Members, T2) of
        true -> smaller(T1, T2);
        false -> normalize_union([meet(M, T2) || M <- Members])
    end;
meet(T1, {union, Members} = T2) ->
    case too_many_pairs(Members, T1) of
        true -> smaller(T1, T2);
        false -> normalize_union([meet(T1, M) || M <- Members])
    end;
meet(T1, T2) ->
    case is_numeric(T1) andalso is_numeric(T2) of
        true -> meet_numeric(T1, T2);
        false -> meet_non_numeric(T1, T2)
    end.

%% @doc Checks the gradual subtyping relation `Sub <~ Super`.
%%
%% Dynamic types (`any`, type variables, recursive refs) are consistent with
%% all types, while unions, maps, records, lists, and opaques are checked strictly.
-spec consistent_subtype(stype(), stype()) -> boolean().
consistent_subtype(any, _) -> true;
consistent_subtype(_, any) -> true;
consistent_subtype({var, _}, _) -> true;
consistent_subtype(_, {var, _}) -> true;
consistent_subtype({recursive_ref, _, _}, _) -> true;
consistent_subtype(_, {recursive_ref, _, _}) -> true;
consistent_subtype({local_type, _, _}, _) -> true;
consistent_subtype(_, {local_type, _, _}) -> true;
consistent_subtype({remote_type, _, _, _}, _) -> true;
consistent_subtype(_, {remote_type, _, _, _}) -> true;
consistent_subtype(any_fun, {fun_type, _, _}) -> true;
consistent_subtype(any_fun, {fun_any_args, _}) -> true;
consistent_subtype(none, _) -> true;
consistent_subtype(_, none) -> false;
consistent_subtype(Same, Same) -> true;
consistent_subtype({union, SubMembers}, Super) ->
    lists:all(fun(M) -> consistent_subtype(M, Super) end, SubMembers);
consistent_subtype({tuple, Elems} = Sub, {union, SuperMembers} = Super) ->
    case lists:any(fun is_union/1, Elems) of
        false ->
            lists:any(fun(M) -> consistent_subtype(Sub, M) end, SuperMembers);
        true ->
            %% {ok, a | b} is {ok, a} | {ok, b}: the whole tuple may need several members of the union to be covered, so each
            %% combination is checked on its own (up to a few; beyond that the tuple has to fit one member)
            case tuple_combinations(Elems) of
                too_many ->
                    lists:any(fun(M) -> consistent_subtype(Sub, M) end, SuperMembers);
                Combinations ->
                    lists:all(fun(Combination) -> consistent_subtype({tuple, Combination}, Super) end, Combinations)
            end
    end;
consistent_subtype(Sub, {union, SuperMembers}) ->
    lists:any(fun(M) -> consistent_subtype(Sub, M) end, SuperMembers);
consistent_subtype(Sub, Super) ->
    case is_numeric(Sub) andalso is_numeric(Super) of
        true -> subtype_numeric(Sub, Super);
        false -> subtype_non_numeric(Sub, Super)
    end.

subtype_numeric(_, number) -> true;
subtype_numeric(float, float) -> true;
subtype_numeric(float, _) -> false;
subtype_numeric(_, float) -> false;
subtype_numeric(number, _) -> false;
subtype_numeric(SubInt, SuperInt) ->
    {Lo1, Hi1} = int_bounds(SubInt),
    {Lo2, Hi2} = int_bounds(SuperInt),
    bound_ge(Lo1, Lo2) andalso bound_le(Hi1, Hi2).

bound_ge(_, neg_inf) -> true;
bound_ge(neg_inf, _) -> false;
bound_ge(pos_inf, _) -> true;
bound_ge(_, pos_inf) -> false;
bound_ge(A, B) -> A >= B.

bound_le(_, pos_inf) -> true;
bound_le(pos_inf, _) -> false;
bound_le(neg_inf, _) -> true;
bound_le(_, neg_inf) -> false;
bound_le(A, B) -> A =< B.

subtype_non_numeric({atom_lit, B}, boolean) when is_boolean(B) -> true;
subtype_non_numeric(boolean, atom) -> true;
subtype_non_numeric({atom_lit, _}, atom) -> true;
subtype_non_numeric({binary, B1, U1}, {binary, B2, 0}) ->
    U1 =:= 0 andalso B1 =:= B2;
subtype_non_numeric({binary, B1, U1}, {binary, B2, U2}) ->
    B1 >= B2 andalso U1 rem U2 =:= 0 andalso (B1 - B2) rem U2 =:= 0;
subtype_non_numeric(nil, {list, _}) -> true;
subtype_non_numeric(nil, {improper_list, _, _}) -> true;
subtype_non_numeric({nonempty_list, E1}, {nonempty_list, E2}) ->
    consistent_subtype(E1, E2);
subtype_non_numeric({nonempty_list, E1}, {list, E2}) ->
    consistent_subtype(E1, E2);
subtype_non_numeric({list, E1}, {list, E2}) ->
    consistent_subtype(E1, E2);
subtype_non_numeric({improper_list, E1, T1}, {list, E2}) ->
    consistent_subtype(E1, E2) andalso consistent_subtype(T1, {list, E2});
subtype_non_numeric({improper_list, E1, any}, {nonempty_list, E2}) ->
    %% an unknown tail: gradual typing gives it the benefit of the doubt (a known tail would have to exclude [])
    consistent_subtype(E1, E2);
subtype_non_numeric({list, E1}, {improper_list, E2, _}) ->
    consistent_subtype(E1, E2);
subtype_non_numeric({nonempty_list, E1}, {improper_list, E2, _}) ->
    consistent_subtype(E1, E2);
subtype_non_numeric({improper_list, E1, T1}, {improper_list, E2, T2}) ->
    consistent_subtype(E1, E2) andalso consistent_subtype(T1, T2);
subtype_non_numeric({tuple, _}, any_tuple) -> true;
subtype_non_numeric({record, _, _}, any_tuple) -> true;
subtype_non_numeric({tuple, [{atom_lit, Name} | _]}, {record, Name, _}) -> true;
subtype_non_numeric({record, Name, _}, {tuple, [{atom_lit, Name} | _]}) -> true;
subtype_non_numeric({tuple, E1}, {tuple, E2}) when length(E1) =:= length(E2) ->
    lists:all(fun({A, B}) -> consistent_subtype(A, B) end, lists:zip(E1, E2));
subtype_non_numeric({record, Name, F1}, {record, Name, F2}) ->
    lists:all(
        fun({FieldName, SuperType}) ->
            SubType = proplists:get_value(FieldName, F1, any),
            consistent_subtype(SubType, SuperType)
        end,
        F2
    );
subtype_non_numeric({map, _}, any_map) -> true;
subtype_non_numeric(any_map, {map, _}) -> true;
subtype_non_numeric({map, SubFields}, {map, SuperFields}) ->
    subtype_map_fields(SubFields, SuperFields);
subtype_non_numeric({fun_type, _, _}, any_fun) -> true;
subtype_non_numeric({fun_any_args, _}, any_fun) -> true;
subtype_non_numeric({fun_type, _, Ret1}, {fun_any_args, Ret2}) ->
    consistent_subtype(Ret1, Ret2);
subtype_non_numeric({fun_any_args, Ret1}, {fun_any_args, Ret2}) ->
    consistent_subtype(Ret1, Ret2);
subtype_non_numeric({fun_type, A1, R1}, {fun_type, A2, R2}) when length(A1) =:= length(A2) ->
    consistent_subtype(R1, R2) andalso
        lists:all(fun({SubA, SuperA}) -> consistent_subtype(SuperA, SubA) end, lists:zip(A1, A2));
subtype_non_numeric({opaque, Mod, Name, Args1, _}, {opaque, Mod, Name, Args2, _})
  when length(Args1) =:= length(Args2) ->
    lists:all(fun({A, B}) -> consistent_subtype(A, B) end, lists:zip(Args1, Args2));
subtype_non_numeric(_, _) ->
    false.

subtype_map_fields(SubFields, SuperFields) ->
    ReqSuper = [{K, V} || {exact, K, V} <- SuperFields],
    AllSuper = [{K, V} || {_Kind, K, V} <- SuperFields],
    ExactSub = #{K => V || {exact, K, V} <- SubFields},
    ReqSatisfied = lists:all(
        fun({ReqK, ReqV}) ->
            case is_domain_key_type(ReqK) of
                true ->
                    lists:all(
                        fun({_Kind, SubK, SubV}) ->
                            case consistent_subtype(SubK, ReqK) of
                                true -> consistent_subtype(SubV, ReqV);
                                false -> true
                            end
                        end,
                        SubFields
                    );
                false ->
                    case maps:find(ReqK, ExactSub) of
                        {ok, SubV} -> consistent_subtype(SubV, ReqV);
                        error ->
                            %% In gradual typing, if a struct tag matches (__struct__),
                            %% unspecialized struct instances are compatible with declared struct fields
                            case ReqK of
                                {atom_lit, '__struct__'} -> false;
                                _ -> maps:is_key({atom_lit, '__struct__'}, ExactSub)
                            end
                    end
            end
        end,
        ReqSuper
    ),
    ValuesCompatible = lists:all(
        fun({_Kind, SubK, SubV}) ->
            MatchingSuper = [SuperV || {SuperK, SuperV} <- AllSuper, consistent_subtype(SubK, SuperK)],
            lists:all(fun(SuperV) -> consistent_subtype(SubV, SuperV) end, MatchingSuper)
        end,
        SubFields
    ),
    ReqSatisfied andalso ValuesCompatible.

is_domain_key_type(atom) -> true;
is_domain_key_type(binary) -> true;
is_domain_key_type({binary, _, _}) -> true;
is_domain_key_type(integer) -> true;
is_domain_key_type(number) -> true;
is_domain_key_type(any) -> true;
is_domain_key_type(_) -> false.

is_numeric(number) -> true;
is_numeric(float) -> true;
is_numeric(integer) -> true;
is_numeric(pos_integer) -> true;
is_numeric(non_neg_integer) -> true;
is_numeric(neg_integer) -> true;
is_numeric({int_lit, _}) -> true;
is_numeric({int_range, _, _}) -> true;
is_numeric(_) -> false.

meet_numeric(number, T) -> T;
meet_numeric(T, number) -> T;
meet_numeric(float, float) -> float;
meet_numeric(float, _) -> none;
meet_numeric(_, float) -> none;
meet_numeric(T1, T2) ->
    {Lo1, Hi1} = int_bounds(T1),
    {Lo2, Hi2} = int_bounds(T2),
    Lo = max_bound(Lo1, Lo2),
    Hi = min_bound(Hi1, Hi2),
    range_to_stype(Lo, Hi).

int_bounds(integer) -> {neg_inf, pos_inf};
int_bounds(pos_integer) -> {1, pos_inf};
int_bounds(non_neg_integer) -> {0, pos_inf};
int_bounds(neg_integer) -> {neg_inf, -1};
int_bounds({int_lit, I}) -> {I, I};
int_bounds({int_range, Lo, Hi}) -> {Lo, Hi}.

max_bound(neg_inf, B) -> B;
max_bound(A, neg_inf) -> A;
max_bound(pos_inf, _) -> pos_inf;
max_bound(_, pos_inf) -> pos_inf;
max_bound(A, B) -> erlang:max(A, B).

min_bound(pos_inf, B) -> B;
min_bound(A, pos_inf) -> A;
min_bound(neg_inf, _) -> neg_inf;
min_bound(_, neg_inf) -> neg_inf;
min_bound(A, B) -> erlang:min(A, B).

range_to_stype(pos_inf, _) -> none;
range_to_stype(_, neg_inf) -> none;
range_to_stype(Lo, Hi) when is_integer(Lo), is_integer(Hi), Lo > Hi -> none;
range_to_stype(Val, Val) when is_integer(Val) -> {int_lit, Val};
range_to_stype(neg_inf, pos_inf) -> integer;
range_to_stype(1, pos_inf) -> pos_integer;
range_to_stype(0, pos_inf) -> non_neg_integer;
range_to_stype(neg_inf, -1) -> neg_integer;
range_to_stype(Lo, Hi) -> {int_range, Lo, Hi}.

meet_non_numeric(atom, boolean) -> boolean;
meet_non_numeric(boolean, atom) -> boolean;
meet_non_numeric(atom, {atom_lit, _} = Lit) -> Lit;
meet_non_numeric({atom_lit, _} = Lit, atom) -> Lit;
meet_non_numeric(boolean, {atom_lit, B} = Lit) when is_boolean(B) -> Lit;
meet_non_numeric({atom_lit, B} = Lit, boolean) when is_boolean(B) -> Lit;
meet_non_numeric(boolean, {atom_lit, _}) -> none;
meet_non_numeric({atom_lit, _}, boolean) -> none;
meet_non_numeric({binary, B1, U1}, {binary, B2, U2}) ->
    meet_binary(B1, U1, B2, U2);
meet_non_numeric(any_tuple, {tuple, _} = T) -> T;
meet_non_numeric({tuple, _} = T, any_tuple) -> T;
meet_non_numeric({tuple, [Tag | _]}, {record, Name, _} = Record) ->
    meet_tuple_with_record(Tag, Name, Record);
meet_non_numeric({record, _, _} = Record, {tuple, [_ | _]} = Tuple) ->
    meet_non_numeric(Tuple, Record);
meet_non_numeric(any_tuple, {record, _, _} = R) -> R;
meet_non_numeric({record, _, _} = R, any_tuple) -> R;
meet_non_numeric({record, Name, F1}, {record, Name, F2}) ->
    meet_record_fields(Name, F1, F2);
meet_non_numeric({tuple, E1}, {tuple, E2}) when length(E1) =:= length(E2) ->
    Meets = [meet(A, B) || {A, B} <- lists:zip(E1, E2)],
    case lists:member(none, Meets) of
        true -> none;
        false -> {tuple, Meets}
    end;
meet_non_numeric({list, _}, nil) -> nil;
meet_non_numeric(nil, {list, _}) -> nil;
meet_non_numeric({list, E1}, {nonempty_list, E2}) ->
    case meet(E1, E2) of
        none -> none;
        M -> {nonempty_list, M}
    end;
meet_non_numeric({nonempty_list, E1}, {list, E2}) ->
    case meet(E1, E2) of
        none -> none;
        M -> {nonempty_list, M}
    end;
meet_non_numeric({nonempty_list, E1}, {nonempty_list, E2}) ->
    case meet(E1, E2) of
        none -> none;
        M -> {nonempty_list, M}
    end;
meet_non_numeric({list, E1}, {list, E2}) ->
    case meet(E1, E2) of
        none -> nil;
        M -> {list, M}
    end;
meet_non_numeric({improper_list, _, _}, nil) -> nil;
meet_non_numeric(nil, {improper_list, _, _}) -> nil;
meet_non_numeric({improper_list, E1, T1}, {list, E2}) ->
    meet_improper_with_list(E1, T1, E2, list);
meet_non_numeric({list, E2}, {improper_list, E1, T1}) ->
    meet_improper_with_list(E1, T1, E2, list);
meet_non_numeric({improper_list, E1, T1}, {nonempty_list, E2}) ->
    meet_improper_with_list(E1, T1, E2, nonempty_list);
meet_non_numeric({nonempty_list, E2}, {improper_list, E1, T1}) ->
    meet_improper_with_list(E1, T1, E2, nonempty_list);
meet_non_numeric({improper_list, _, _} = I, {improper_list, any, any}) -> I;
meet_non_numeric({improper_list, any, any}, {improper_list, _, _} = I) -> I;
meet_non_numeric({improper_list, E1, T1}, {improper_list, E2, T2}) ->
    meet_improper(E1, T1, E2, T2);
meet_non_numeric(any_map, {map, _} = M) -> M;
meet_non_numeric({map, _} = M, any_map) -> M;
meet_non_numeric({map, F1}, {map, F2}) ->
    meet_map_fields(F1, F2);
meet_non_numeric({fun_type, A1, R1}, {fun_type, A2, R2}) when length(A1) =:= length(A2) ->
    ArgMeets = [meet(X, Y) || {X, Y} <- lists:zip(A1, A2)],
    %% a function that never returns (`none`, `no_return()`) fits any return type: the bottom type is not a clash
    RetMeet = case {R1, R2} of
        {none, _} -> none;
        {_, none} -> none;
        _ -> meet(R1, R2)
    end,
    ReturnsClash = RetMeet =:= none andalso R1 =/= none andalso R2 =/= none,
    case lists:member(none, ArgMeets) orelse ReturnsClash of
        true -> none;
        false -> {fun_type, ArgMeets, RetMeet}
    end;
meet_non_numeric(any_fun, {fun_type, _, _} = F) -> F;
meet_non_numeric({fun_type, _, _} = F, any_fun) -> F;
meet_non_numeric(any_fun, {fun_any_args, _} = F) -> F;
meet_non_numeric({fun_any_args, _} = F, any_fun) -> F;
meet_non_numeric(_, _) ->
    none.

%% maybe_improper_list(E1, T1) intersected with a proper list of E2 (or a non-empty one). The chain has to end inside a
%% list, so the tail is T1 met with [E2]. That is exact for `list`. The type language has no non-empty improper
%% list, so for `nonempty_list` and a tail that may itself be a list the result also holds [] (a safe superset).
meet_improper_with_list(E1, T1, E2, Kind) ->
    case meet(E1, E2) of
        none ->
            case Kind of list -> nil; nonempty_list -> none end;
        E ->
            case meet(T1, {list, E2}) of
                none -> {Kind, E};
                nil -> {Kind, E};
                Tail -> {improper_list, E, Tail}
            end
    end.

%% Both chains end in the same place, or one of them runs on inside the other one's tail. Exact up to a nesting
%% depth (counted across the recursion, which goes back through meet/2); below it, a safe superset: a pair of
%% chains nested that deep has not been seen, and the cost grows with each level.
meet_improper(E1, T1, E2, T2) ->
    Depth = case get(prisma_meet_improper_depth) of undefined -> 0; D -> D end,
    case meet(E1, E2) of
        none ->
            nil;
        E ->
            meet_improper(E, E1, T1, E2, T2, Depth)
    end.

meet_improper(_E, E1, T1, E2, T2, Depth) when Depth >= ?MAX_IMPROPER_MEET_DEPTH ->
    {improper_list, join(E1, E2), join(T1, T2)};
meet_improper(E, E1, T1, E2, T2, Depth) ->
    case Depth =:= 0 andalso too_big(T1, T2) of
        true ->
            %% Two big unions of chains (what a parser that conses onto unknown tails infers): the exact meet costs more than
            %% it is worth (building the PPLT of OTP's `calendar` did not end), and the answer can be larger than its
            %% operands. The meet is included in each of them: the smaller one is a safe superset.
            smaller({improper_list, E1, T1}, {improper_list, E2, T2});
        false ->
            put(prisma_meet_improper_depth, Depth + 1),
            try
                Tails = [meet(T1, T2), meet_tail(T1, E2, T2), meet_tail(T2, E1, T1)],
                normalize_union([improper_chain(E, T) || T <- Tails])
            after
                put(prisma_meet_improper_depth, Depth)
            end
    end.

%% The meet of two unions is the meet of every pair of members, and the members of a union of structured types are structured
%% types with unions inside: past a number of pairs the exact answer is not worth it (the inference that builds parser-like
%% types did not end in `file_sorter`). The meet is included in each operand, so the smaller one is a safe superset. A union
%% of literals only is never cut: it is cheap and a spec may list a hundred of them.
too_many_pairs(Members, Other) ->
    Pairs = length(Members) * case Other of {union, Ms} -> length(Ms); _ -> 1 end,
    Pairs > ?MAX_MEET_PAIRS andalso not all_literals(Members) andalso not all_literals(case Other of {union, Os} -> Os; _ -> [Other] end).

all_literals(Ms) ->
    lists:all(fun({atom_lit, _}) -> true; ({int_lit, _}) -> true; (_) -> false end, Ms).

too_big(T1, T2) ->
    (is_union(T1) orelse is_union(T2)) andalso erts_debug:flat_size({T1, T2}) > ?MAX_IMPROPER_MEET_WORDS.

smaller(A, B) ->
    case erts_debug:flat_size(A) =< erts_debug:flat_size(B) of true -> A; false -> B end.

%% T met with the improper list [E | Tail] (the other chain, seen from inside this tail).
meet_tail({improper_list, E1, T1}, E2, T2) ->
    meet_improper(E1, T1, E2, T2);
meet_tail({union, Members}, E, Tail) ->
    normalize_union([meet_tail(M, E, Tail) || M <- Members]);
meet_tail(T, E, Tail) ->
    meet(T, {improper_list, E, Tail}).

%% A tuple is a value of a record type when its first element can be the record's name. The arity and the position of each
%% field are not known here: `{record, Name, Fields}` only lists the fields that the type mentions (`#r{}` lists none),
%% so nothing more can be checked without the record definition.
meet_tuple_with_record(Tag, Name, Record) ->
    case meet(Tag, {atom_lit, Name}) of
        none -> none;
        _ -> Record
    end.

meet_record_fields(Name, [], F2) -> {record, Name, F2};
meet_record_fields(Name, F1, []) -> {record, Name, F1};
meet_record_fields(Name, F1, F2) ->
    M1 = maps:from_list(F1),
    M2 = maps:from_list(F2),
    Common = [K || K <- maps:keys(M1), is_map_key(K, M2)],
    case lists:any(fun(K) -> meet(maps:get(K, M1), maps:get(K, M2)) =:= none end, Common) of
        true ->
            none;
        false ->
            Merged = maps:fold(
                fun(K, V2, Acc) ->
                    case maps:find(K, Acc) of
                        {ok, V1} -> Acc#{K => meet(V1, V2)};
                        error -> Acc#{K => V2}
                    end
                end,
                M1,
                M2
            ),
            {record, Name, lists:sort(maps:to_list(Merged))}
    end.

is_union({union, _}) -> true;
is_union(_) -> false.

%% Every way of choosing one member of each union element of a tuple, or `too_many` past 32.
tuple_combinations(Elems) ->
    Options = [case E of {union, Ms} -> Ms; _ -> [E] end || E <- Elems],
    case lists:foldl(fun(Os, N) -> N * length(Os) end, 1, Options) =< 32 of
        true -> combinations(Options);
        false -> too_many
    end.

combinations([]) -> [[]];
combinations([Options | Rest]) ->
    Tails = combinations(Rest),
    [[O | Tail] || O <- Options, Tail <- Tails].

improper_chain(E, none) -> {list, E};
improper_chain(E, Tail) -> {improper_list, E, Tail}.

meet_map_fields(F1, F2) ->
    Exact1 = #{K => V || {exact, K, V} <- F1},
    Exact2 = #{K => V || {exact, K, V} <- F2},
    CommonKeys = [K || K <- maps:keys(Exact1), maps:is_key(K, Exact2)],
    HasConflict = lists:any(
        fun(K) ->
            meet(maps:get(K, Exact1), maps:get(K, Exact2)) =:= none
        end,
        CommonKeys
    ),
    case HasConflict of
        true -> none;
        false -> {map, lists:usort(F1 ++ F2)}
    end.

%% @doc Substitutes type variables (`{var, Name}`) according to `Env`.
-spec substitute(stype(), #{atom() => stype()}) -> stype().
substitute(Type, Env) when map_size(Env) =:= 0 ->
    Type;
substitute({var, Name} = Var, Env) ->
    maps:get(Name, Env, Var);
substitute({tuple, Elems}, Env) ->
    {tuple, [substitute(E, Env) || E <- Elems]};
substitute({record, Name, Fields}, Env) ->
    {record, Name, [{F, substitute(T, Env)} || {F, T} <- Fields]};
substitute({list, Elem}, Env) ->
    {list, substitute(Elem, Env)};
substitute({nonempty_list, Elem}, Env) ->
    {nonempty_list, substitute(Elem, Env)};
substitute({improper_list, Elem, Tail}, Env) ->
    {improper_list, substitute(Elem, Env), substitute(Tail, Env)};
substitute({map, Fields}, Env) ->
    {map, [{Kind, substitute(K, Env), substitute(V, Env)} || {Kind, K, V} <- Fields]};
substitute({fun_any_args, Ret}, Env) ->
    {fun_any_args, substitute(Ret, Env)};
substitute({fun_type, Args, Ret}, Env) ->
    {fun_type, [substitute(A, Env) || A <- Args], substitute(Ret, Env)};
substitute({bounded_fun, Args, Ret, Constraints}, Env) ->
    Shadowed = maps:without(maps:keys(Constraints), Env),
    NewConstraints = maps:map(fun(_K, V) -> substitute(V, Env) end, Constraints),
    {bounded_fun, [substitute(A, Shadowed) || A <- Args], substitute(Ret, Shadowed), NewConstraints};
substitute({union, Members}, Env) ->
    normalize_union([substitute(M, Env) || M <- Members]);
substitute({local_type, Name, Args}, Env) ->
    {local_type, Name, [substitute(A, Env) || A <- Args]};
substitute({remote_type, Mod, Name, Args}, Env) ->
    {remote_type, Mod, Name, [substitute(A, Env) || A <- Args]};
substitute({opaque, Mod, Name, Args, Body}, Env) ->
    {opaque, Mod, Name, [substitute(A, Env) || A <- Args], substitute(Body, Env)};
substitute({recursive_ref, Key, Args}, Env) ->
    {recursive_ref, Key, [substitute(A, Env) || A <- Args]};
substitute(Other, _Env) ->
    Other.

%% @doc Replaces bounded type variables in a `bounded_fun` with their constraint types.
-spec unfold_bounded_fun(stype()) -> stype().
unfold_bounded_fun({bounded_fun, Args, Ret, Constraints}) ->
    ResolvedEnv = resolve_constraint_fixpoint(Constraints),
    {fun_type, [substitute(A, ResolvedEnv) || A <- Args], substitute(Ret, ResolvedEnv)};
unfold_bounded_fun(Other) ->
    Other.

%% @doc Expands local and remote user-defined types with cycle protection and opacity rules.
-spec expand(module(), module(), stype(), type_lookup_fun()) -> {ok, stype()} | {error, term()}.
expand(CallerMod, CurrentMod, Type, LookupFun) ->
    expand(CallerMod, CurrentMod, Type, LookupFun, #{}).

expand(CallerMod, CurrentMod, {local_type, Name, Args}, LookupFun, Visited) ->
    expand_remote(CallerMod, CurrentMod, Name, Args, LookupFun, Visited);
expand(CallerMod, _CurrentMod, {remote_type, TargetMod, Name, Args}, LookupFun, Visited) ->
    expand_remote(CallerMod, TargetMod, Name, Args, LookupFun, Visited);
expand(CallerMod, CurrentMod, {tuple, Elems}, LookupFun, Visited) ->
    case expand_list(CallerMod, CurrentMod, Elems, LookupFun, Visited) of
        {ok, Expanded} -> {ok, {tuple, Expanded}};
        Error -> Error
    end;
expand(CallerMod, CurrentMod, {list, Elem}, LookupFun, Visited) ->
    case expand(CallerMod, CurrentMod, Elem, LookupFun, Visited) of
        {ok, Expanded} -> {ok, {list, Expanded}};
        Error -> Error
    end;
expand(CallerMod, CurrentMod, {nonempty_list, Elem}, LookupFun, Visited) ->
    case expand(CallerMod, CurrentMod, Elem, LookupFun, Visited) of
        {ok, Expanded} -> {ok, {nonempty_list, Expanded}};
        Error -> Error
    end;
expand(CallerMod, CurrentMod, {improper_list, Elem, Tail}, LookupFun, Visited) ->
    case expand(CallerMod, CurrentMod, Elem, LookupFun, Visited) of
        {ok, ExpElem} ->
            case expand(CallerMod, CurrentMod, Tail, LookupFun, Visited) of
                {ok, ExpTail} -> {ok, {improper_list, ExpElem, ExpTail}};
                Error -> Error
            end;
        Error ->
            Error
    end;
expand(CallerMod, CurrentMod, {map, Fields}, LookupFun, Visited) ->
    expand_map_fields(CallerMod, CurrentMod, Fields, LookupFun, Visited, []);
expand(CallerMod, CurrentMod, {union, Members}, LookupFun, Visited) ->
    case expand_list(CallerMod, CurrentMod, Members, LookupFun, Visited) of
        {ok, Expanded} -> {ok, normalize_union(Expanded)};
        Error -> Error
    end;
expand(CallerMod, CurrentMod, {fun_type, Args, Ret}, LookupFun, Visited) ->
    case expand_list(CallerMod, CurrentMod, Args, LookupFun, Visited) of
        {ok, ExpArgs} ->
            case expand(CallerMod, CurrentMod, Ret, LookupFun, Visited) of
                {ok, ExpRet} -> {ok, {fun_type, ExpArgs, ExpRet}};
                Error -> Error
            end;
        Error ->
            Error
    end;
expand(CallerMod, CurrentMod, {bounded_fun, _, _, _} = Bounded, LookupFun, Visited) ->
    expand(CallerMod, CurrentMod, unfold_bounded_fun(Bounded), LookupFun, Visited);
expand(_CallerMod, _CurrentMod, Other, _LookupFun, _Visited) ->
    {ok, Other}.

expand_remote(CallerMod, TargetMod, Name, Args, LookupFun, Visited) ->
    case expand_list(CallerMod, CallerMod, Args, LookupFun, Visited) of
        {ok, ExpArgs} ->
            Key = {TargetMod, Name, length(ExpArgs)},
            case maps:is_key(Key, Visited) of
                true ->
                    {ok, {recursive_ref, Key, ExpArgs}};
                false ->
                    case LookupFun(Key) of
                        {ok, #type_decl{kind = Kind, params = Params, body = Body}} ->
                            Env = maps:from_list(lists:zip(Params, ExpArgs)),
                            Instantiated = substitute(Body, Env),
                            NextVisited = Visited#{Key => true},
                            case expand(CallerMod, TargetMod, Instantiated, LookupFun, NextVisited) of
                                {ok, ExpBody} when Kind =:= opaque, CallerMod =/= TargetMod ->
                                    {ok, {opaque, TargetMod, Name, ExpArgs, ExpBody}};
                                {ok, ExpBody} ->
                                    {ok, ExpBody};
                                Error ->
                                    Error
                            end;
                        error ->
                            builtin_remote_type(TargetMod, Name, ExpArgs, Key)
                    end
            end;
        Error ->
            Error
    end.

expand_list(CallerMod, CurrentMod, List, LookupFun, Visited) ->
    lists:foldr(
        fun
            (Item, {ok, Acc}) ->
                case expand(CallerMod, CurrentMod, Item, LookupFun, Visited) of
                    {ok, Exp} -> {ok, [Exp | Acc]};
                    Error -> Error
                end;
            (_Item, Error) ->
                Error
        end,
        {ok, []},
        List
    ).

expand_map_fields(_CallerMod, _CurrentMod, [], _LookupFun, _Visited, Acc) ->
    {ok, {map, lists:reverse(Acc)}};
expand_map_fields(CallerMod, CurrentMod, [{Kind, K, V} | Rest], LookupFun, Visited, Acc) ->
    case expand(CallerMod, CurrentMod, K, LookupFun, Visited) of
        {ok, ExpK} ->
            case expand(CallerMod, CurrentMod, V, LookupFun, Visited) of
                {ok, ExpV} ->
                    expand_map_fields(CallerMod, CurrentMod, Rest, LookupFun, Visited, [{Kind, ExpK, ExpV} | Acc]);
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

from_builtin(any, []) -> any;
from_builtin(term, []) -> any;
from_builtin(none, []) -> none;
from_builtin(no_return, []) -> none;
from_builtin(pid, []) -> pid;
from_builtin(port, []) -> port;
from_builtin(reference, []) -> reference;
from_builtin(float, []) -> float;
from_builtin(number, []) -> number;
from_builtin(integer, []) -> integer;
from_builtin(pos_integer, []) -> pos_integer;
from_builtin(non_neg_integer, []) -> non_neg_integer;
from_builtin(neg_integer, []) -> neg_integer;
from_builtin(byte, []) -> {int_range, 0, 255};
from_builtin(char, []) -> {int_range, 0, 16#10ffff};
from_builtin(arity, []) -> {int_range, 0, 255};
from_builtin(atom, []) -> atom;
from_builtin(module, []) -> atom;
from_builtin(node, []) -> atom;
from_builtin(boolean, []) -> boolean;
from_builtin(timeout, []) -> normalize_union([non_neg_integer, {atom_lit, infinity}]);
from_builtin(mfa, []) -> {tuple, [atom, atom, {int_range, 0, 255}]};
from_builtin(string, []) -> {list, {int_range, 0, 16#10ffff}};
from_builtin(nonempty_string, []) -> {nonempty_list, {int_range, 0, 16#10ffff}};
from_builtin(iodata, []) -> normalize_union([{list, any}, {binary, 0, 8}]);
from_builtin(iolist, []) -> {list, any};
from_builtin(identifier, []) -> normalize_union([pid, port, reference]);
from_builtin(function, []) -> any_fun;
from_builtin(Name, Args) -> {local_type, Name, [from_abstract(A) || A <- Args]}.

eval_bound({integer, _, Int}) -> Int;
eval_bound({char, _, Char}) -> Char;
eval_bound({op, _, '-', {integer, _, Int}}) -> -Int;
eval_bound({atom, _, inf}) -> pos_inf;
eval_bound(_) -> 0.

parse_record_field({type, _, field_type, [{atom, _, FieldName}, FieldType]}) ->
    {FieldName, from_abstract(FieldType)};
parse_record_field({typed_record_field, {record_field, _, {atom, _, FieldName}}, FieldType}) ->
    {FieldName, from_abstract(FieldType)};
parse_record_field({typed_record_field, {record_field, _, {atom, _, FieldName}, _Default}, FieldType}) ->
    {FieldName, from_abstract(FieldType)};
parse_record_field({record_field, _, {atom, _, FieldName}}) ->
    {FieldName, any};
parse_record_field({record_field, _, {atom, _, FieldName}, _Default}) ->
    {FieldName, any};
parse_record_field(_) ->
    {'_', any}.

parse_map_field({type, _, map_field_exact, [K, V]}) ->
    {exact, from_abstract(K), from_abstract(V)};
parse_map_field({type, _, map_field_assoc, [K, V]}) ->
    {assoc, from_abstract(K), from_abstract(V)};
parse_map_field(_) ->
    {assoc, any, any}.

parse_constraints(ConstraintsAst) when is_list(ConstraintsAst) ->
    lists:foldl(
        fun
            ({type, _, constraint, [{atom, _, is_subtype}, [{var, _, VarName}, TypeAst]]}, Acc) ->
                Acc#{VarName => from_abstract(TypeAst)};
            (_, Acc) ->
                Acc
        end,
        #{},
        ConstraintsAst
    );
parse_constraints(_) ->
    #{}.

resolve_constraint_fixpoint(Constraints) ->
    maps:map(
        fun(_Var, Type) ->
            substitute(Type, Constraints)
        end,
        Constraints
    ).

%% In no particular order: the caller sorts.
flatten_unions([], Acc) ->
    Acc;
flatten_unions([{union, Nested} | Rest], Acc) ->
    flatten_unions(Rest, flatten_unions(Nested, Acc));
flatten_unions([H | Rest], Acc) ->
    flatten_unions(Rest, [H | Acc]).

collapse_booleans(Types) ->
    HasTrue = lists:member({atom_lit, true}, Types),
    HasFalse = lists:member({atom_lit, false}, Types),
    HasBool = lists:member(boolean, Types),
    case (HasTrue andalso HasFalse) orelse HasBool of
        true ->
            Filtered = [T || T <- Types, T =/= {atom_lit, true}, T =/= {atom_lit, false}, T =/= boolean],
            [boolean | Filtered];
        false ->
            Types
    end.

absorb_subtypes([_] = Types) ->
    Types;
absorb_subtypes(Types) when length(Types) =< 24 ->
    absorb_pairwise(Types, Types);
absorb_subtypes(Types) ->
    %% Avoid O(N^2) pairwise checks on large unions (e.g., 256+ clause literal lookup tables):
    %% only test against members that can actually subsume another distinct type.
    Broad = [T || T <- Types, may_be_supertype(T)],
    case Broad of
        [] ->
            Types;
        _ when length(Broad) =< 24 ->
            absorb_pairwise(Types, Broad);
        _ ->
            Types
    end.

absorb_pairwise(Types, Candidates) ->
    lists:filter(fun(A) ->
        not lists:any(fun(B) ->
            A =/= B andalso is_strict_subtype(A, B)
        end, Candidates)
    end, Types).

may_be_supertype({atom_lit, _}) -> false;
may_be_supertype({int_lit, _}) -> false;
may_be_supertype({binary, _, 0}) -> false;
may_be_supertype(nil) -> false;
may_be_supertype({tuple, Elems}) -> lists:any(fun may_be_supertype/1, Elems);
may_be_supertype(_) -> true.

is_strict_subtype({var, _}, _) -> false;
is_strict_subtype(_, {var, _}) -> false;
is_strict_subtype({recursive_ref, _, _}, _) -> false;
is_strict_subtype(_, {recursive_ref, _, _}) -> false;
is_strict_subtype(any, _) -> false;
is_strict_subtype(_, any) -> true;
is_strict_subtype(A, B) ->
    case is_integer_type(A) andalso is_integer_type(B) of
        true ->
            {LoA, HiA} = int_bounds(A),
            {LoB, HiB} = int_bounds(B),
            case {LoA, HiA} =:= {LoB, HiB} of
                true ->
                    Canon = range_to_stype(LoA, HiA),
                    A =/= Canon andalso B =:= Canon;
                false ->
                    bound_ge(LoA, LoB) andalso bound_le(HiA, HiB)
            end;
        false ->
            consistent_subtype(A, B) andalso not consistent_subtype(B, A)
    end.

is_integer_type(integer) -> true;
is_integer_type(pos_integer) -> true;
is_integer_type(non_neg_integer) -> true;
is_integer_type(neg_integer) -> true;
is_integer_type({int_lit, _}) -> true;
is_integer_type({int_range, _, _}) -> true;
is_integer_type(_) -> false.

builtin_remote_type('Elixir.String', t, [], _Key) -> {ok, {binary, 0, 8}};
builtin_remote_type('Elixir.String', grapheme, [], _Key) -> {ok, {binary, 0, 8}};
builtin_remote_type('Elixir.String', codepoint, [], _Key) -> {ok, {binary, 0, 8}};
builtin_remote_type('Elixir.Keyword', t, [], _Key) -> {ok, {list, {tuple, [atom, any]}}};
builtin_remote_type('Elixir.Keyword', t, [ValType], _Key) -> {ok, {list, {tuple, [atom, ValType]}}};
builtin_remote_type('Elixir.Enum', t, [], _Key) -> {ok, any};
builtin_remote_type('Elixir.Range', t, [], _Key) ->
    {ok, {map, [
        {exact, {atom_lit, '__struct__'}, {atom_lit, 'Elixir.Range'}},
        {exact, {atom_lit, first}, integer},
        {exact, {atom_lit, last}, integer},
        {exact, {atom_lit, step}, integer}
    ]}};
builtin_remote_type('Elixir.Range', t, [First, Last], _Key) ->
    {ok, {map, [
        {exact, {atom_lit, '__struct__'}, {atom_lit, 'Elixir.Range'}},
        {exact, {atom_lit, first}, First},
        {exact, {atom_lit, last}, Last},
        {exact, {atom_lit, step}, integer}
    ]}};
builtin_remote_type('Elixir.MapSet', t, [], _Key) ->
    {ok, {map, [
        {exact, {atom_lit, '__struct__'}, {atom_lit, 'Elixir.MapSet'}},
        {assoc, any, any}
    ]}};
builtin_remote_type('Elixir.MapSet', t, [ValType], _Key) ->
    {ok, {map, [
        {exact, {atom_lit, '__struct__'}, {atom_lit, 'Elixir.MapSet'}},
        {assoc, any, ValType}
    ]}};
builtin_remote_type(_Mod, _Name, _Args, Key) ->
    {error, {undefined_type, Key}}.

%% @doc Pretty-prints a normalized `stype()` using auto-detected language syntax.
-spec format(stype()) -> binary().
format(Type) ->
    format(Type, #{}).

%% @doc Pretty-prints a normalized `stype()` with options (e.g. `#{lang => elixir | erlang}`).
-spec format(stype(), map()) -> binary().
format(Type, Opts) ->
    Lang = maps:get(lang, Opts, auto),
    EffectiveLang = case Lang of
        auto -> detect_lang(Type);
        L -> L
    end,
    iolist_to_binary(format_type(Type, EffectiveLang)).

%% @doc Strips the Elixir prefix (`Elixir.`) from module names when present.
-spec clean_module(term()) -> string().
clean_module(Mod) when is_atom(Mod) ->
    Bin = atom_to_binary(Mod, utf8),
    case Bin of
        <<"Elixir.", Rest/binary>> -> binary_to_list(Rest);
        _ -> atom_to_list(Mod)
    end;
clean_module(Other) ->
    lists:flatten(io_lib:format("~p", [Other])).

detect_lang(Type) ->
    case has_elixir_marker(Type) of
        true -> elixir;
        false -> erlang
    end.

has_elixir_marker({atom_lit, A}) ->
    is_elixir_module_atom(A);
has_elixir_marker({remote_type, Mod, _, _}) ->
    is_elixir_module_atom(Mod);
has_elixir_marker({tuple, Elems}) ->
    lists:any(fun has_elixir_marker/1, Elems);
has_elixir_marker({list, E}) ->
    has_elixir_marker(E);
has_elixir_marker({nonempty_list, E}) ->
    has_elixir_marker(E);
has_elixir_marker({improper_list, H, T}) ->
    has_elixir_marker(H) orelse has_elixir_marker(T);
has_elixir_marker({map, Fields}) ->
    lists:any(
        fun({_Kind, K, V}) ->
            has_elixir_marker(K) orelse has_elixir_marker(V)
        end,
        Fields
    );
has_elixir_marker({union, Members}) ->
    lists:any(fun has_elixir_marker/1, Members);
has_elixir_marker({fun_type, Args, Ret}) ->
    has_elixir_marker(Ret) orelse lists:any(fun has_elixir_marker/1, Args);
has_elixir_marker(_) ->
    false.

is_elixir_module_atom(A) when is_atom(A) ->
    case atom_to_binary(A, utf8) of
        <<"Elixir.", _/binary>> -> true;
        _ -> false
    end;
is_elixir_module_atom(_) ->
    false.

format_type(any, elixir) -> "term()";
format_type(any, erlang) -> "any()";
format_type(none, _) -> "none()";
format_type(atom, _) -> "atom()";
format_type(integer, _) -> "integer()";
format_type(pos_integer, _) -> "pos_integer()";
format_type(non_neg_integer, _) -> "non_neg_integer()";
format_type(neg_integer, _) -> "neg_integer()";
format_type(float, _) -> "float()";
format_type(number, _) -> "number()";
format_type(boolean, _) -> "boolean()";
format_type(nil, _) -> "nil";
format_type(pid, _) -> "pid()";
format_type(port, _) -> "port()";
format_type(reference, _) -> "reference()";
format_type(any_tuple, _) -> "tuple()";
format_type(any_map, _) -> "map()";
format_type(any_fun, _) -> "fun()";
format_type({atom_lit, nil}, _) -> "nil";
format_type({atom_lit, true}, _) -> "true";
format_type({atom_lit, false}, _) -> "false";
format_type({atom_lit, A}, elixir) ->
    case is_elixir_module_atom(A) of
        true ->
            clean_module(A);
        false ->
            AStr = atom_to_list(A),
            case is_simple_elixir_atom(AStr) of
                true -> [":", AStr];
                false -> [":\"", escape_quotes(AStr), "\""]
            end
    end;
format_type({atom_lit, A}, erlang) ->
    lists:flatten(io_lib:write_atom(A));
format_type({int_lit, I}, _) ->
    integer_to_list(I);
format_type({int_range, Lo, Hi}, _) ->
    LoStr = case Lo of neg_inf -> "-inf"; _ -> integer_to_list(Lo) end,
    HiStr = case Hi of pos_inf -> "inf"; _ -> integer_to_list(Hi) end,
    [LoStr, "..", HiStr];
format_type({binary, 0, 8}, elixir) ->
    "String.t()";
format_type({binary, 0, 8}, erlang) ->
    "binary()";
format_type({binary, 0, 1}, _) ->
    "bitstring()";
format_type({binary, B, U}, _) when B > 0, U =:= 0 ->
    ["<<_:", integer_to_list(B), ">>"];
format_type({binary, B, U}, _) when B > 0, U > 0 ->
    ["<<_:", integer_to_list(B), ", _:_*", integer_to_list(U), ">>"];
format_type({binary, 0, U}, _) when U > 0 ->
    ["<<_:_*", integer_to_list(U), ">>"];
format_type({binary, _, _}, _) ->
    "binary()";
format_type({tuple, Elems}, Lang) ->
    ["{", string:join([format_type(E, Lang) || E <- Elems], ", "), "}"];
format_type({list, E}, Lang) ->
    case is_keyword_elem(E, Lang) of
        {true, KeyValStrs} ->
            ["[", string:join(KeyValStrs, ", "), "]"];
        false ->
            ["[", format_type(E, Lang), "]"]
    end;
format_type({nonempty_list, E}, Lang) ->
    case is_keyword_elem(E, Lang) of
        {true, KeyValStrs} ->
            ["[", string:join(KeyValStrs, ", "), ", ...]"];
        false ->
            ["[", format_type(E, Lang), ", ...]"]
    end;
format_type({improper_list, H, T}, Lang) ->
    ["[", format_type(H, Lang), " | ", format_type(T, Lang), "]"];
format_type({map, Fields}, Lang) ->
    format_map(Fields, Lang);
format_type({union, Members}, Lang) ->
    string:join([format_type(M, Lang) || M <- Members], " | ");
format_type({fun_type, Args, Ret}, elixir) ->
    ArgsStr = string:join([format_type(A, elixir) || A <- Args], ", "),
    ["(", ArgsStr, " -> ", format_type(Ret, elixir), ")"];
format_type({fun_type, Args, Ret}, erlang) ->
    ArgsStr = string:join([format_type(A, erlang) || A <- Args], ", "),
    ["fun((", ArgsStr, ") -> ", format_type(Ret, erlang), ")"];
format_type({fun_any_args, Ret}, elixir) ->
    ["(... -> ", format_type(Ret, elixir), ")"];
format_type({fun_any_args, Ret}, erlang) ->
    ["fun((...) -> ", format_type(Ret, erlang), ")"];
format_type({record, Name, Fields}, Lang) ->
    ["#", atom_to_list(Name), "{", format_record_fields(Fields, Lang), "}"];
format_type({remote_type, Mod, Name, Args}, Lang) ->
    format_remote_type(Mod, Name, Args, Lang);
format_type({local_type, Name, Args}, Lang) ->
    ArgsStr = string:join([format_type(A, Lang) || A <- Args], ", "),
    [atom_to_list(Name), "(", ArgsStr, ")"];
format_type({opaque, Mod, Name, Args, _Body}, Lang) ->
    format_remote_type(Mod, Name, Args, Lang);
format_type({var, Name}, _) ->
    atom_to_list(Name);
format_type(Other, _) ->
    lists:flatten(io_lib:format("~p", [Other])).

is_keyword_elem({union, Members}, elixir) ->
    Pairs = [is_keyword_elem(M, elixir) || M <- Members],
    AllTrue = lists:all(fun(P) -> P =/= false end, Pairs),
    case AllTrue of
        true ->
            Items = lists:append([Elems || {true, Elems} <- Pairs]),
            {true, Items};
        false ->
            false
    end;
is_keyword_elem({tuple, [{atom_lit, K}, V]}, elixir) ->
    KStr = atom_to_list(K),
    case is_simple_elixir_atom(KStr) of
        true -> {true, [KStr ++ ": " ++ format_type(V, elixir)]};
        false -> false
    end;
is_keyword_elem(_, _) ->
    false.

format_map(Fields, elixir) ->
    case find_struct_mod(Fields) of
        {ok, StructMod, RestFields} ->
            CleanMod = clean_module(StructMod),
            case RestFields of
                [] -> ["%", CleanMod, "{}"];
                _ -> ["%", CleanMod, "{", format_elixir_map_fields(RestFields), "}"]
            end;
        none ->
            case Fields of
                [] -> "%{}";
                _ -> ["%{", format_elixir_map_fields(Fields), "}"]
            end
    end;
format_map(Fields, erlang) ->
    case Fields of
        [] -> "#{}";
        _ -> ["#{", format_erlang_map_fields(Fields), "}"]
    end.

find_struct_mod(Fields) ->
    StructMatches = [Mod || {_Kind, {atom_lit, '__struct__'}, {atom_lit, Mod}} <- Fields],
    case StructMatches of
        [Mod | _] ->
            Rest = [F || F <- Fields, element(2, F) =/= {atom_lit, '__struct__'}],
            {ok, Mod, Rest};
        [] ->
            none
    end.

format_elixir_map_fields(Fields) ->
    SortedFields = lists:sort(fun(F1, F2) -> element(2, F1) =< element(2, F2) end, Fields),
    Parts = lists:map(
        fun
            ({_Kind, {atom_lit, K}, V}) ->
                KStr = atom_to_list(K),
                case is_simple_elixir_atom(KStr) of
                    true -> [KStr, ": ", format_type(V, elixir)];
                    false -> [":\"", escape_quotes(KStr), "\" => ", format_type(V, elixir)]
                end;
            ({_Kind, K, V}) ->
                [format_type(K, elixir), " => ", format_type(V, elixir)]
        end,
        SortedFields
    ),
    string:join(Parts, ", ").

format_erlang_map_fields(Fields) ->
    SortedFields = lists:sort(fun(F1, F2) -> element(2, F1) =< element(2, F2) end, Fields),
    Parts = lists:map(
        fun({Kind, K, V}) ->
            Sep = case Kind of exact -> " := "; assoc -> " => " end,
            [format_type(K, erlang), Sep, format_type(V, erlang)]
        end,
        SortedFields
    ),
    string:join(Parts, ", ").

format_record_fields(Fields, Lang) ->
    Parts = [
        [atom_to_list(F), " = ", format_type(T, Lang)]
        || {F, T} <- Fields
    ],
    string:join(Parts, ", ").

format_remote_type('Elixir.String', t, [], elixir) ->
    "String.t()";
format_remote_type(Mod, Name, Args, elixir) ->
    CleanMod = clean_module(Mod),
    ArgsStr = string:join([format_type(A, elixir) || A <- Args], ", "),
    [CleanMod, ".", atom_to_list(Name), "(", ArgsStr, ")"];
format_remote_type(Mod, Name, Args, erlang) ->
    ArgsStr = string:join([format_type(A, erlang) || A <- Args], ", "),
    [atom_to_list(Mod), ":", atom_to_list(Name), "(", ArgsStr, ")"].

is_simple_elixir_atom([First | Rest])
  when (First >= $a andalso First =< $z) orelse First =:= $_ ->
    lists:all(
        fun(C) ->
            (C >= $a andalso C =< $z) orelse
            (C >= $A andalso C =< $Z) orelse
            (C >= $0 andalso C =< $9) orelse
            C =:= $_ orelse C =:= $@ orelse C =:= $? orelse C =:= $!
        end,
        Rest
    );
is_simple_elixir_atom(_) ->
    false.

escape_quotes(Str) ->
    lists:flatmap(
        fun
            ($") -> "\\\"";
            (C) -> [C]
        end,
        Str
    ).
