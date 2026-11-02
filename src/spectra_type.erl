%% @doc Canonical type representation and manipulation for Spectra.
%%
%% Converts Erlang Abstract Format type ASTs into normalized algebraic terms
%% supporting polymorphism, bounded_fun constraints, remote types, opaques,
%% and cycle-safe recursive unfolding.
-module(spectra_type).

-include("spectra.hrl").

-export([
    from_abstract/1,
    from_type_attr/3,
    normalize_union/1,
    join/2,
    meet/2,
    substitute/2,
    unfold_bounded_fun/1,
    expand/4
]).

-export_type([
    stype/0,
    map_field/0,
    type_lookup_fun/0
]).

%% @typedoc Normalized type term stored in `.splt` files and used by the checker.
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
normalize_union(Types) ->
    Flattened = flatten_unions(Types),
    WithoutNone = [T || T <- Flattened, T =/= none],
    case lists:member(any, WithoutNone) of
        true ->
            any;
        false ->
            Unique = lists:usort(collapse_booleans(WithoutNone)),
            case Unique of
                [] -> none;
                [Single] -> Single;
                Many -> {union, Many}
            end
    end.

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
meet(Same, Same) -> Same;
meet({union, Members}, T2) ->
    normalize_union([meet(M, T2) || M <- Members]);
meet(T1, {union, Members}) ->
    normalize_union([meet(T1, M) || M <- Members]);
meet(T1, T2) ->
    case is_numeric(T1) andalso is_numeric(T2) of
        true -> meet_numeric(T1, T2);
        false -> meet_non_numeric(T1, T2)
    end.

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
    {binary, erlang:max(B1, B2), erlang:min(U1, U2)};
meet_non_numeric(any_tuple, {tuple, _} = T) -> T;
meet_non_numeric({tuple, _} = T, any_tuple) -> T;
meet_non_numeric(any_tuple, {record, _, _} = R) -> R;
meet_non_numeric({record, _, _} = R, any_tuple) -> R;
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
meet_non_numeric(any_map, {map, _} = M) -> M;
meet_non_numeric({map, _} = M, any_map) -> M;
meet_non_numeric({map, F1}, {map, F2}) ->
    meet_map_fields(F1, F2);
meet_non_numeric({fun_type, A1, R1}, {fun_type, A2, R2}) when length(A1) =:= length(A2) ->
    ArgMeets = [meet(X, Y) || {X, Y} <- lists:zip(A1, A2)],
    RetMeet = meet(R1, R2),
    case lists:member(none, ArgMeets) orelse RetMeet =:= none of
        true -> none;
        false -> {fun_type, ArgMeets, RetMeet}
    end;
meet_non_numeric(any_fun, {fun_type, _, _} = F) -> F;
meet_non_numeric({fun_type, _, _} = F, any_fun) -> F;
meet_non_numeric(any_fun, {fun_any_args, _} = F) -> F;
meet_non_numeric({fun_any_args, _} = F, any_fun) -> F;
meet_non_numeric(_, _) ->
    none.

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
                            {error, {undefined_type, Key}}
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
    {FieldName, from_abstract(FieldType)}.

parse_map_field({type, _, map_field_exact, [K, V]}) ->
    {exact, from_abstract(K), from_abstract(V)};
parse_map_field({type, _, map_field_assoc, [K, V]}) ->
    {assoc, from_abstract(K), from_abstract(V)}.

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

flatten_unions([]) ->
    [];
flatten_unions([{union, Nested} | Rest]) ->
    flatten_unions(Nested) ++ flatten_unions(Rest);
flatten_unions([H | Rest]) ->
    [H | flatten_unions(Rest)].

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
