-module(spectra_type_tests).

-include_lib("eunit/include/eunit.hrl").
-include("spectra.hrl").

primitive_and_literal_types_test() ->
    ?assertEqual(any, spectra_type:from_abstract({type, 1, any, []})),
    ?assertEqual(any, spectra_type:from_abstract({type, 1, term, []})),
    ?assertEqual(none, spectra_type:from_abstract({type, 1, none, []})),
    ?assertEqual(none, spectra_type:from_abstract({type, 1, no_return, []})),
    ?assertEqual(integer, spectra_type:from_abstract({type, 1, integer, []})),
    ?assertEqual(pos_integer, spectra_type:from_abstract({type, 1, pos_integer, []})),
    ?assertEqual(non_neg_integer, spectra_type:from_abstract({type, 1, non_neg_integer, []})),
    ?assertEqual(neg_integer, spectra_type:from_abstract({type, 1, neg_integer, []})),
    ?assertEqual(float, spectra_type:from_abstract({type, 1, float, []})),
    ?assertEqual(number, spectra_type:from_abstract({type, 1, number, []})),
    ?assertEqual(atom, spectra_type:from_abstract({type, 1, atom, []})),
    ?assertEqual(atom, spectra_type:from_abstract({type, 1, module, []})),
    ?assertEqual(atom, spectra_type:from_abstract({type, 1, node, []})),
    ?assertEqual(boolean, spectra_type:from_abstract({type, 1, boolean, []})),
    ?assertEqual(pid, spectra_type:from_abstract({type, 1, pid, []})),
    ?assertEqual(port, spectra_type:from_abstract({type, 1, port, []})),
    ?assertEqual(reference, spectra_type:from_abstract({type, 1, reference, []})),
    ?assertEqual({int_range, 0, 255}, spectra_type:from_abstract({type, 1, byte, []})),
    ?assertEqual({int_range, 0, 255}, spectra_type:from_abstract({type, 1, arity, []})),
    ?assertEqual({int_range, 0, 16#10ffff}, spectra_type:from_abstract({type, 1, char, []})),
    ?assertEqual({union, [non_neg_integer, {atom_lit, infinity}]}, spectra_type:from_abstract({type, 1, timeout, []})),
    ?assertEqual({tuple, [atom, atom, {int_range, 0, 255}]}, spectra_type:from_abstract({type, 1, mfa, []})),
    ?assertEqual({list, {int_range, 0, 16#10ffff}}, spectra_type:from_abstract({type, 1, string, []})),
    ?assertEqual({nonempty_list, {int_range, 0, 16#10ffff}}, spectra_type:from_abstract({type, 1, nonempty_string, []})),
    ?assertEqual({union, [{list, any}, {binary, 0, 8}]}, spectra_type:from_abstract({type, 1, iodata, []})),
    ?assertEqual({list, any}, spectra_type:from_abstract({type, 1, iolist, []})),
    ?assertEqual({union, [pid, port, reference]}, spectra_type:from_abstract({type, 1, identifier, []})),
    ?assertEqual(any_fun, spectra_type:from_abstract({type, 1, function, []})),
    ?assertEqual({local_type, custom_t, [integer]}, spectra_type:from_abstract({type, 1, custom_t, [{type, 1, integer, []}]})),
    ?assertEqual({int_lit, 42}, spectra_type:from_abstract({integer, 1, 42})),
    ?assertEqual({int_lit, -7}, spectra_type:from_abstract({op, 1, '-', {integer, 1, 7}})),
    ?assertEqual({int_lit, $a}, spectra_type:from_abstract({char, 1, $a})),
    ?assertEqual({atom_lit, ok}, spectra_type:from_abstract({atom, 1, ok})),
    ?assertEqual(
        integer,
        spectra_type:from_abstract({ann_type, 1, [{var, 1, 'X'}, {paren_type, 1, [{type, 1, integer, []}]}]})
    ),
    ?assertEqual(
        {int_range, -5, pos_inf},
        spectra_type:from_abstract({type, 1, range, [{op, 1, '-', {integer, 1, 5}}, {atom, 1, inf}]})
    ),
    ?assertEqual(
        {int_range, $a, 0},
        spectra_type:from_abstract({type, 1, range, [{char, 1, $a}, {atom, 1, unknown}]})
    ),
    ?assertEqual({binary, 0, 8}, spectra_type:from_abstract({type, 1, binary, []})),
    ?assertEqual({binary, 0, 1}, spectra_type:from_abstract({type, 1, bitstring, []})),
    ?assertEqual({binary, 8, 8}, spectra_type:from_abstract({type, 1, nonempty_binary, []})),
    ?assertEqual({binary, 1, 1}, spectra_type:from_abstract({type, 1, nonempty_bitstring, []})),
    ?assertEqual({binary, 16, 8}, spectra_type:from_abstract({type, 1, binary, [{integer, 1, 16}, {integer, 1, 8}]})),
    ?assertEqual(any, spectra_type:from_abstract(unknown_ast)).

composite_types_test() ->
    ?assertEqual(any_tuple, spectra_type:from_abstract({type, 1, tuple, any})),
    ?assertEqual(
        {tuple, [{atom_lit, ok}, integer]},
        spectra_type:from_abstract({type, 1, tuple, [{atom, 1, ok}, {type, 1, integer, []}]})
    ),
    RecAst = {type, 1, record, [
        {atom, 1, user},
        {type, 1, field_type, [{atom, 1, id}, {type, 1, integer, []}]}
    ]},
    ?assertEqual({record, user, [{id, integer}]}, spectra_type:from_abstract(RecAst)),
    ?assertEqual(nil, spectra_type:from_abstract({type, 1, nil, []})),
    ?assertEqual({list, any}, spectra_type:from_abstract({type, 1, list, []})),
    ?assertEqual({list, integer}, spectra_type:from_abstract({type, 1, list, [{type, 1, integer, []}]})),
    ?assertEqual({nonempty_list, any}, spectra_type:from_abstract({type, 1, nonempty_list, []})),
    ?assertEqual({nonempty_list, atom}, spectra_type:from_abstract({type, 1, nonempty_list, [{type, 1, atom, []}]})),
    ?assertEqual({improper_list, any, any}, spectra_type:from_abstract({type, 1, maybe_improper_list, []})),
    ?assertEqual(
        {improper_list, integer, nil},
        spectra_type:from_abstract({type, 1, maybe_improper_list, [{type, 1, integer, []}, {type, 1, nil, []}]})
    ),
    ?assertEqual(
        {improper_list, atom, {binary, 0, 8}},
        spectra_type:from_abstract({type, 1, nonempty_improper_list, [{type, 1, atom, []}, {type, 1, binary, []}]})
    ),
    ?assertEqual(any_fun, spectra_type:from_abstract({type, 1, 'fun', []})),
    ?assertEqual(
        {fun_any_args, atom},
        spectra_type:from_abstract({type, 1, 'fun', [{type, 1, any}, {type, 1, atom, []}]})
    ),
    ?assertEqual(any_map, spectra_type:from_abstract({type, 1, map, any})),
    MapAst = {type, 1, map, [
        {type, 1, map_field_exact, [{atom, 1, id}, {type, 1, integer, []}]},
        {type, 1, map_field_assoc, [{atom, 1, name}, {type, 1, binary, []}]}
    ]},
    ?assertEqual(
        {map, [
            {exact, {atom_lit, id}, integer},
            {assoc, {atom_lit, name}, {binary, 0, 8}}
        ]},
        spectra_type:from_abstract(MapAst)
    ).

union_normalization_test() ->
    UnionAst = {type, 1, union, [
        {atom, 1, true},
        {atom, 1, false}
    ]},
    ?assertEqual(boolean, spectra_type:from_abstract(UnionAst)),
    ?assertEqual(none, spectra_type:normalize_union([none])),
    ?assertEqual(integer, spectra_type:normalize_union([integer, none])),
    NestedUnion = {type, 1, union, [
        {type, 1, integer, []},
        {type, 1, union, [{type, 1, atom, []}, {type, 1, integer, []}]},
        {type, 1, none, []}
    ]},
    ?assertEqual({union, [atom, integer]}, spectra_type:from_abstract(NestedUnion)),
    AnyUnion = {type, 1, union, [{type, 1, integer, []}, {type, 1, any, []}]},
    ?assertEqual(any, spectra_type:from_abstract(AnyUnion)).

polymorphic_substitute_and_bounded_fun_test() ->
    PolyFunAst = {type, 1, 'fun', [
        {type, 1, product, [{var, 1, 'T'}]},
        {var, 1, 'T'}
    ]},
    ?assertEqual(
        {fun_type, [{var, 'T'}], {var, 'T'}},
        spectra_type:from_abstract(PolyFunAst)
    ),
    EmptyBoundedAst = {type, 1, bounded_fun, [PolyFunAst, [invalid_constraint]]},
    ?assertEqual({fun_type, [{var, 'T'}], {var, 'T'}}, spectra_type:from_abstract(EmptyBoundedAst)),
    BoundedAst = {type, 1, bounded_fun, [
        {type, 1, 'fun', [
            {type, 1, product, [{var, 1, 'Key'}, {var, 1, '_'}]},
            {var, 1, 'Val'}
        ]},
        [
            {type, 1, constraint, [
                {atom, 1, is_subtype},
                [{var, 1, 'Key'}, {type, 1, atom, []}]
            ]},
            {type, 1, constraint, [
                {atom, 1, is_subtype},
                [{var, 1, 'Val'}, {type, 1, integer, []}]
            ]}
        ]
    ]},
    Bounded = spectra_type:from_abstract(BoundedAst),
    ?assertEqual(
        {bounded_fun, [{var, 'Key'}, any], {var, 'Val'}, #{'Key' => atom, 'Val' => integer}},
        Bounded
    ),
    ?assertEqual(
        {fun_type, [atom, any], integer},
        spectra_type:unfold_bounded_fun(Bounded)
    ),
    ?assertEqual(integer, spectra_type:unfold_bounded_fun(integer)),

    Env = #{'A' => integer, 'B' => atom},
    ?assertEqual({var, 'A'}, spectra_type:substitute({var, 'A'}, #{})),
    ?assertEqual({record, r, [{f, integer}]}, spectra_type:substitute({record, r, [{f, {var, 'A'}}]}, Env)),
    ?assertEqual({list, integer}, spectra_type:substitute({list, {var, 'A'}}, Env)),
    ?assertEqual({nonempty_list, atom}, spectra_type:substitute({nonempty_list, {var, 'B'}}, Env)),
    ?assertEqual({improper_list, integer, atom}, spectra_type:substitute({improper_list, {var, 'A'}, {var, 'B'}}, Env)),
    ?assertEqual({map, [{exact, atom, integer}]}, spectra_type:substitute({map, [{exact, {var, 'B'}, {var, 'A'}}]}, Env)),
    ?assertEqual({fun_any_args, integer}, spectra_type:substitute({fun_any_args, {var, 'A'}}, Env)),
    ?assertEqual({fun_type, [integer], atom}, spectra_type:substitute({fun_type, [{var, 'A'}], {var, 'B'}}, Env)),
    ?assertEqual(
        {bounded_fun, [{var, 'A'}], atom, #{'A' => integer}},
        spectra_type:substitute({bounded_fun, [{var, 'A'}], {var, 'B'}, #{'A' => {var, 'A'}}}, Env)
    ),
    ?assertEqual({local_type, t, [integer]}, spectra_type:substitute({local_type, t, [{var, 'A'}]}, Env)),
    ?assertEqual({remote_type, m, t, [atom]}, spectra_type:substitute({remote_type, m, t, [{var, 'B'}]}, Env)),
    ?assertEqual({opaque, m, t, [integer], atom}, spectra_type:substitute({opaque, m, t, [{var, 'A'}], {var, 'B'}}, Env)),
    ?assertEqual({recursive_ref, {m, t, 1}, [integer]}, spectra_type:substitute({recursive_ref, {m, t, 1}, [{var, 'A'}]}, Env)).

remote_opaque_and_recursive_types_in_splt_test() ->
    FormsA = [
        {attribute, 1, module, mod_a},
        {attribute, 2, export_type, [{user_id, 0}, {secret_token, 0}, {tree, 1}]},
        {attribute, 3, type, {internal_tag, {atom, 3, internal}, []}},
        {attribute, 4, type, {user_id, {type, 4, pos_integer, []}, []}},
        {attribute, 5, opaque, {secret_token, {type, 5, binary, []}, []}},
        {attribute, 6, type, {tree,
            {type, 6, union, [
                {atom, 6, leaf},
                {type, 6, tuple, [
                    {atom, 6, node},
                    {var, 6, 'T'},
                    {user_type, 6, tree, [{var, 6, 'T'}]},
                    {user_type, 6, tree, [{var, 6, 'T'}]}
                ]}
            ]},
            [{var, 6, 'T'}]
        }},
        {attribute, 7, export, [{make_token, 1}]},
        {attribute, 8, spec, {{make_token, 1}, [
            {type, 8, 'fun', [
                {type, 8, product, [{user_type, 8, user_id, []}]},
                {user_type, 8, secret_token, []}
            ]}
        ]}},
        {function, 9, make_token, 1, [
            {clause, 9, [{var, 9, '_Id'}], [], [{bin, 9, []}]}
        ]}
    ],
    FormsB = [
        {attribute, 1, module, mod_b},
        {attribute, 2, export, [{verify, 2}]},
        {attribute, 3, spec, {{verify, 2}, [
            {type, 3, 'fun', [
                {type, 3, product, [
                    {remote_type, 3, [{atom, 3, mod_a}, {atom, 3, secret_token}, []]},
                    {remote_type, 3, [{atom, 3, mod_a}, {atom, 3, tree}, [{type, 3, integer, []}]]}
                ]},
                {type, 3, boolean, []}
            ]}
        ]}},
        {function, 4, verify, 2, [
            {clause, 4, [{var, 4, '_Tok'}, {var, 4, '_Tree'}], [], [{atom, 4, true}]}
        ]}
    ],
    {ok, mod_a, BeamA} = compile:forms(FormsA, [debug_info]),
    {ok, mod_b, BeamB} = compile:forms(FormsB, [debug_info]),

    {ok, PltA} = spectra_plt:from_beams([BeamA], #{package => <<"pkg_a">>, package_vsn => <<"1.0.0">>}),
    {ok, PltB} = spectra_plt:from_beams([BeamB], #{package => <<"pkg_b">>, package_vsn => <<"1.0.0">>}),
    MergedPlt = spectra_plt:merge([PltA, PltB]),

    {ok, InternalDecl} = spectra_plt:lookup_type({mod_a, internal_tag, 0}, MergedPlt),
    ?assertEqual(false, InternalDecl#type_decl.exported),
    {ok, OpaqueDecl} = spectra_plt:lookup_type({mod_a, secret_token, 0}, MergedPlt),
    ?assertEqual(true, OpaqueDecl#type_decl.exported),
    ?assertEqual(opaque, OpaqueDecl#type_decl.kind),
    ?assertEqual(error, spectra_plt:lookup_type({unknown_mod, t, 0}, MergedPlt)),

    ?assertEqual(
        {ok, {binary, 0, 8}},
        spectra_plt:resolve_type(mod_a, {local_type, secret_token, []}, MergedPlt)
    ),
    ?assertEqual(
        {ok, {opaque, mod_a, secret_token, [], {binary, 0, 8}}},
        spectra_plt:resolve_type(mod_b, {remote_type, mod_a, secret_token, []}, MergedPlt)
    ),

    {ok, ExpandedTree} = spectra_plt:resolve_type(
        mod_b,
        {remote_type, mod_a, tree, [integer]},
        MergedPlt
    ),
    ?assertEqual(
        {union, [
            {atom_lit, leaf},
            {tuple, [
                {atom_lit, node},
                integer,
                {recursive_ref, {mod_a, tree, 1}, [integer]},
                {recursive_ref, {mod_a, tree, 1}, [integer]}
            ]}
        ]},
        ExpandedTree
    ),

    %% Expand nested composite types containing remote types
    ComplexType = {fun_type,
        [{list, {local_type, user_id, []}}, {nonempty_list, {local_type, user_id, []}}],
        {map, [{exact, {atom_lit, id}, {improper_list, {local_type, user_id, []}, nil}}]}
    },
    ?assertEqual(
        {ok, {fun_type,
            [{list, pos_integer}, {nonempty_list, pos_integer}],
            {map, [{exact, {atom_lit, id}, {improper_list, pos_integer, nil}}]}
        }},
        spectra_plt:resolve_type(mod_a, ComplexType, MergedPlt)
    ),
    ?assertEqual(
        {error, {undefined_type, {mod_a, missing_type, 0}}},
        spectra_plt:resolve_type(mod_a, {local_type, missing_type, []}, MergedPlt)
    ).

type_format_elixir_and_erlang_test() ->
    ElixirStruct = {map, [
        {exact, {atom_lit, '__struct__'}, {atom_lit, 'Elixir.MyApp.User'}},
        {exact, {atom_lit, id}, {binary, 0, 8}},
        {exact, {atom_lit, age}, pos_integer}
    ]},
    ?assertEqual(<<"%MyApp.User{age: pos_integer(), id: String.t()}">>, spectra_type:format(ElixirStruct, #{lang => elixir})),

    ElixirMap = {map, [
        {exact, {atom_lit, key}, {atom_lit, value}}
    ]},
    ?assertEqual(<<"%{key: :value}">>, spectra_type:format(ElixirMap, #{lang => elixir})),

    ErlangMap = {map, [
        {exact, {atom_lit, key}, integer}
    ]},
    ?assertEqual(<<"#{key := integer()}">>, spectra_type:format(ErlangMap, #{lang => erlang})),

    ElixirTuple = {tuple, [{atom_lit, ok}, {int_lit, 42}]},
    ?assertEqual(<<"{:ok, 42}">>, spectra_type:format(ElixirTuple, #{lang => elixir})),

    ElixirKeyword = {list, {tuple, [{atom_lit, timeout}, non_neg_integer]}},
    ?assertEqual(<<"[timeout: non_neg_integer()]">>, spectra_type:format(ElixirKeyword, #{lang => elixir})),

    ElixirUnion = {union, [{tuple, [{atom_lit, ok}, any]}, {tuple, [{atom_lit, error}, {atom_lit, not_found}]}]},
    ?assertEqual(<<"{:ok, term()} | {:error, :not_found}">>, spectra_type:format(ElixirUnion, #{lang => elixir})),

    ElixirFun = {fun_type, [integer, {binary, 0, 8}], boolean},
    ?assertEqual(<<"(integer(), String.t() -> boolean())">>, spectra_type:format(ElixirFun, #{lang => elixir})),

    ?assertEqual("MyApp.User", spectra_type:clean_module('Elixir.MyApp.User')),
    ?assertEqual("my_erlang_mod", spectra_type:clean_module(my_erlang_mod)).

%% normalize_union/1 is called on very short lists all the time: the shortcuts must give exactly what the general path gives.

normalize_union_shortcuts_agree_with_the_general_path_test() ->
    General = fun(Ts) ->
        Flat = lists:flatten([case T of {union, Ms} -> Ms; _ -> [T] end || T <- Ts]),
        spectra_type:normalize_union(Flat ++ [none])   %% the extra `none` keeps it off the shortcuts
    end,
    Samples = [any, none, boolean, integer, {atom_lit, true}, {atom_lit, false}, {atom_lit, a}, {int_lit, 1},
               {list, integer}, {union, [integer, atom]}, {union, [{atom_lit, true}, {atom_lit, false}]},
               {union, [{union, [integer, float]}, atom]}],
    [?assertEqual(General([T]), spectra_type:normalize_union([T])) || T <- Samples],
    [?assertEqual(General([A, B]), spectra_type:normalize_union([A, B])) || A <- Samples, B <- Samples],
    ?assertEqual(integer, spectra_type:normalize_union([integer, integer])),
    ?assertEqual(boolean, spectra_type:normalize_union([{atom_lit, true}, {atom_lit, false}])),
    ?assertEqual(none, spectra_type:normalize_union([])).

%% widen/1 bounds what is inferred (depth and members of a union) by replacing the excess with `any`: always a superset.

widen_leaves_small_types_alone_test_() ->
    Small = [any, none, integer, {int_lit, 3}, {atom_lit, ok}, boolean,
             {union, [{atom_lit, ok}, {tuple, [{atom_lit, error}, atom]}]},
             {list, {tuple, [integer, {list, atom}]}},
             {map, [{exact, {atom_lit, k}, integer}]},
             {fun_type, [integer], {union, [{atom_lit, a}, {atom_lit, b}]}},
             {improper_list, integer, atom}],
    [?_assertEqual(T, spectra_type:widen(T)) || T <- Small].

widen_cuts_deep_types_test() ->
    Deep = {tuple, [{tuple, [{tuple, [{tuple, [{tuple, [integer]}]}]}]}]},
    W = spectra_type:widen(Deep),
    ?assertEqual({tuple, [{tuple, [{tuple, [{tuple, [any]}]}]}]}, W),
    %% a union is not a level: the members of a union at the same depth keep theirs
    ?assertEqual({union, [{atom_lit, a}, {list, {list, {list, {list, any}}}}]},
                 spectra_type:widen({union, [{atom_lit, a}, {list, {list, {list, {list, {list, integer}}}}}]})).

widen_collapses_unions_with_too_many_members_test() ->
    Atoms = [{atom_lit, list_to_atom("a" ++ integer_to_list(N))} || N <- lists:seq(1, 30)],
    ?assertEqual(atom, spectra_type:widen({union, Atoms})),
    Ints = [{int_lit, N} || N <- lists:seq(1, 30)],
    ?assertEqual(integer, spectra_type:widen({union, Ints})),
    Tuples = [{tuple, [{atom_lit, list_to_atom("t" ++ integer_to_list(N))}, integer]} || N <- lists:seq(1, 30)],
    ?assertEqual(any, spectra_type:widen({union, Tuples})),
    %% a few atoms are kept as they are
    Few = [{atom_lit, a}, {atom_lit, b}, {atom_lit, c}],
    ?assertEqual({union, Few}, spectra_type:widen({union, Few})).

%% A tuple whose element is a union is a union of tuples: {ok, a | b} fits {ok, a} | {ok, b}.

tuple_with_a_union_element_fits_a_union_of_tuples_test_() ->
    Sub = {tuple, [{atom_lit, ok}, {union, [{atom_lit, a}, {atom_lit, b}, {atom_lit, c}]}, binary_type()]},
    Super = {union, [{tuple, [{atom_lit, ok}, {atom_lit, a}, binary_type()]},
                     {tuple, [{atom_lit, ok}, {union, [{atom_lit, b}, {atom_lit, c}]}, binary_type()]}]},
    [?_assert(spectra_type:consistent_subtype(Sub, Super)),
     %% not when one of the combinations is missing
     ?_assertNot(spectra_type:consistent_subtype(
                   {tuple, [{atom_lit, ok}, {union, [{atom_lit, a}, {atom_lit, z}]}, binary_type()]}, Super)),
     %% two unions in one tuple: every combination has to fit
     ?_assert(spectra_type:consistent_subtype(
                {tuple, [{union, [{atom_lit, x}, {atom_lit, y}]}, {union, [{atom_lit, a}, {atom_lit, b}]}]},
                {union, [{tuple, [{atom_lit, x}, atom]}, {tuple, [{atom_lit, y}, atom]}]})),
     ?_assertNot(spectra_type:consistent_subtype(
                   {tuple, [{union, [{atom_lit, x}, {atom_lit, y}]}, atom]},
                   {union, [{tuple, [{atom_lit, x}, atom]}, {tuple, [{atom_lit, w}, atom]}]}))].

binary_type() -> {binary, 0, 8}.
