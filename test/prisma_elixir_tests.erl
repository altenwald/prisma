-module(prisma_elixir_tests).

-include_lib("eunit/include/eunit.hrl").
-include("prisma.hrl").

elixir_builtin_remote_types_test() ->
    %% String.t() -> binary(), Keyword.t(integer()) -> [{atom(), integer()}]
    StringTAst = {remote_type, 1, [{atom, 1, 'Elixir.String'}, {atom, 1, t}, []]},
    KeywordTAst = {remote_type, 1, [{atom, 1, 'Elixir.Keyword'}, {atom, 1, t}, [{type, 1, integer, []}]]},
    RangeTAst = {remote_type, 1, [{atom, 1, 'Elixir.Range'}, {atom, 1, t}, []]},

    Pplt = prisma_pplt:new(),
    ?assertEqual(
        {ok, {binary, 0, 8}},
        prisma_pplt:resolve_type('Elixir.MyApp', prisma_type:from_abstract(StringTAst), Pplt)
    ),
    ?assertEqual(
        {ok, {list, {tuple, [atom, integer]}}},
        prisma_pplt:resolve_type('Elixir.MyApp', prisma_type:from_abstract(KeywordTAst), Pplt)
    ),
    ?assertMatch(
        {ok, {map, [{exact, {atom_lit, '__struct__'}, {atom_lit, 'Elixir.Range'}} | _]}},
        prisma_pplt:resolve_type('Elixir.MyApp', prisma_type:from_abstract(RangeTAst), Pplt)
    ).

elixir_v1_dbgi_struct_and_ast_extraction_test() ->
    Mod = 'Elixir.MyApp.Accounts.User',
    %% Simulate an Elixir v1 debug_info chunk with defstruct, @type t, @spec, and def clauses
    StructMeta = [
        #{field => '__struct__', required => true},
        #{field => id, required => true},
        #{field => name, required => false}
    ],
    SpecsForms = [
        {attribute, 1, export_type, [{t, 0}]},
        {attribute, 5, type, {t,
            {type, 5, map, [
                {type, 5, map_field_exact, [{atom, 5, '__struct__'}, {atom, 5, Mod}]},
                {type, 5, map_field_exact, [{atom, 5, id}, {type, 5, pos_integer, []}]},
                {type, 5, map_field_exact, [{atom, 5, name}, {remote_type, 5, [{atom, 5, 'Elixir.String'}, {atom, 5, t}, []]}]}
            ]},
            []
        }},
        {attribute, 10, spec, {{new, 2}, [
            {type, 10, 'fun', [
                {type, 10, product, [
                    {type, 10, pos_integer, []},
                    {remote_type, 10, [{atom, 10, 'Elixir.String'}, {atom, 10, t}, []]}
                ]},
                {user_type, 10, t, []}
            ]}
        ]}},
        {attribute, 18, spec, {{broken_id, 1}, [
            {type, 18, 'fun', [
                {type, 18, product, [{user_type, 18, t, []}]},
                {type, 18, pos_integer, []}
            ]}
        ]}}
    ],
    Definitions = [
        %% def new(id, name) when is_integer(id) and id > 0 do %User{id: id, name: name} end
        {{new, 2}, def, [{line, 11}], [
            {[{line, 11}],
             [{id, [{line, 11}], nil}, {name, [{line, 11}], nil}],
             [{{'.', [{line, 11}], [erlang, 'andalso']}, [{line, 11}], [
                 {{'.', [{line, 11}], [erlang, is_integer]}, [{line, 11}], [{id, [{line, 11}], nil}]},
                 {{'.', [{line, 11}], [erlang, '>']}, [{line, 11}], [{id, [{line, 11}], nil}, 0]}
             ]}],
             {'%', [{line, 12}], [Mod, {'%{}', [{line, 12}], [{id, {id, [{line, 12}], nil}}, {name, {name, [{line, 12}], nil}}]}]}}
        ]},
        %% def broken_id(%User{id: id}), do: :not_an_id
        {{broken_id, 1}, def, [{line, 19}], [
            {[{line, 19}],
             [{'%', [{line, 19}], [Mod, {'%{}', [{line, 19}], [{id, {id, [{line, 19}], nil}}]}]}],
             [],
             not_an_id}
        ]},
        %% def bad_call(), do: new(-5, "Alice")
        {{bad_call, 0}, def, [{line, 23}], [
            {[{line, 23}], [], [], {new, [{line, 24}], [-5, <<"Alice">>]}}
        ]}
    ],
    ElixirDbgi = {debug_info_v1, elixir_erl, {elixir_v1, #{
        module => Mod,
        struct => StructMeta,
        definitions => Definitions
    }, SpecsForms}},

    Exports = [{new, 2}, {broken_id, 1}, {bad_call, 0}, {'__struct__', 0}, {'__struct__', 1}],
    Summary = prisma_elixir:from_elixir_dbgi(Mod, ElixirDbgi, Exports, #module_summary{
        module = Mod,
        language = elixir,
        exports = Exports
    }),
    ?assertEqual(elixir, Summary#module_summary.language),
    ?assert(maps:is_key({Mod, t, 0}, Summary#module_summary.types)),

    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    Warnings = prisma_checker:check_module(Summary, Pplt, #{mode => hybrid}),
    WarnMFAs = [{W#prisma_warning.kind, W#prisma_warning.mfa} || W <- Warnings],
    ?assert(lists:member({gradual_mismatch, {Mod, broken_id, 1}}, WarnMFAs)),
    ?assert(lists:member({discrepancy, {Mod, bad_call, 0}}, WarnMFAs)),
    ?assertNot(lists:member({gradual_mismatch, {Mod, bad_call, 0}}, WarnMFAs)).

mix_task_ebin_resolution_test() ->
    TmpRoot = "/tmp/prisma_dev/fake_mix_proj",
    DevApp1 = filename:join([TmpRoot, "_build", "dev", "lib", "app_one", "ebin"]),
    DevApp2 = filename:join([TmpRoot, "_build", "dev", "lib", "app_two", "ebin"]),
    TestApp = filename:join([TmpRoot, "_build", "test", "lib", "app_one", "ebin"]),
    ok = filelib:ensure_dir(filename:join(DevApp1, "dummy")),
    ok = filelib:ensure_dir(filename:join(DevApp2, "dummy")),
    ok = filelib:ensure_dir(filename:join(TestApp, "dummy")),

    DevDirs = 'Elixir.Mix.Tasks.Prisma':resolve_ebin_dirs([], #{root => TmpRoot, env => "dev"}),
    ?assertEqual(lists:sort([DevApp1, DevApp2]), lists:sort(DevDirs)),

    TestDirs = 'Elixir.Mix.Tasks.Prisma':resolve_ebin_dirs([], #{root => TmpRoot, env => "test"}),
    ?assertEqual([TestApp], TestDirs),

    Parsed = 'Elixir.Mix.Tasks.Prisma':parse_args([
        <<"--mode">>, <<"gradual">>,
        <<"--env">>, <<"test">>,
        <<"--pplt">>, <<"base.pplt">>,
        <<"custom/ebin">>
    ]),
    ?assertEqual(gradual, maps:get(mode, Parsed)),
    ?assertEqual("test", maps:get(env, Parsed)),
    ?assertEqual(["base.pplt"], maps:get(pplts, Parsed)),
    ?assertEqual(["custom/ebin"], maps:get(targets, Parsed)),

    os:cmd("rm -rf " ++ TmpRoot).

elixir_synthesized_struct_and_rich_ast_test() ->
    Mod = 'Elixir.MyApp.Order',
    %% Struct without explicit @type t() in SpecsForms -> synthesizes t/0 automatically
    StructMeta = [
        #{field => '__struct__', required => true},
        #{field => total, required => true},
        {items, []}
    ],
    Definitions = [
        {{process, 2}, def, [{line, 5}], [
            {[{line, 5}],
             [
                 {'=', [{line, 5}], [
                     {'_', [{line, 5}], nil},
                     {'^', [{line, 5}], [{pinned, [{line, 5}], 'Elixir'}]}
                 ]},
                 {[{'|', [{line, 5}], [{head, [{line, 5}], nil}, [1, 2.5, <<"bin">>]]}], {ok, {'{}', [{line, 5}], [a, b, c]}}}
             ],
             [],
             {'__block__', [{line, 6}], [
                 {'=', [{line, 6}], [
                     {'%{}', [{line, 6}], [{k, {val, [{line, 6}], nil}}]},
                     {'%{}', [{line, 6}], [{k, 10}]}
                 ]},
                 {'=', [{line, 7}], [
                     {s, [{line, 7}], nil},
                     {'%', [{line, 7}], [{'__aliases__', [{line, 7}], ['MyApp', 'Order']}, {'%{}', [{line, 7}], [{total, 100}]}]}
                 ]},
                 {'%{}', [{line, 8}], [{'|', [{line, 8}], [{s, [{line, 8}], nil}, [{total, 200}]]}]},
                 {'case', [{line, 9}], [
                     {val, [{line, 9}], nil},
                     [{do, [
                         {'->', [{line, 10}], [[{'when', [{line, 10}], [{x, [{line, 10}], nil}, {{'.', [{line, 10}], [erlang, '>']}, [{line, 10}], [{x, [{line, 10}], nil}, 0]}]}],
                             {{'.', [{line, 10}], [erlang, '-']}, [{line, 10}], [{x, [{line, 10}], nil}]}
                         ]},
                         {'->', [{line, 11}], [[{'_', [{line, 11}], nil}],
                             {{'.', [{line, 11}], [erlang, 'not']}, [{line, 11}], [false]}
                         ]}
                     ]}]
                 ]},
                 {{'.', [{line, 12}], [erlang, max]}, [{line, 12}], [1, 2]},
                 {{'.', [{line, 13}], ['Elixir.Enum', count]}, [{line, 13}], [[[1 | [2]]]]}
             ]}}
        ]}
    ],
    Dbgi = {debug_info_v1, elixir_erl, {elixir_v1, #{
        module => Mod,
        struct => StructMeta,
        definitions => Definitions
    }, []}},
    Summary = prisma_elixir:from_elixir_dbgi(Mod, Dbgi, [{process, 2}], #module_summary{
        module = Mod,
        language = elixir,
        exports = [{process, 2}]
    }),
    ?assert(maps:is_key({Mod, t, 0}, Summary#module_summary.types)),
    ?assert(maps:is_key({Mod, process, 2}, Summary#module_summary.functions)),

    FallbackSummary = prisma_elixir:from_elixir_dbgi(Mod, invalid_dbgi, [{foo, 1}], #module_summary{
        module = Mod,
        language = elixir,
        exports = [{foo, 1}]
    }),
    ?assert(maps:is_key({Mod, foo, 1}, FallbackSummary#module_summary.functions)).

mix_task_run_and_flags_test() ->
    ?assertEqual(false, 'Elixir.Mix.Tasks.Prisma':'__mix_recompile__?'()),
    ?assertEqual(["custom/dir"], 'Elixir.Mix.Tasks.Prisma':resolve_ebin_dirs(["custom/dir"])),
    Parsed = 'Elixir.Mix.Tasks.Prisma':parse_args([<<"--mode">>, <<"discrepancy">>]),
    ?assertEqual(discrepancy, maps:get(mode, Parsed)),
    BeamFile = code:where_is_file("prisma.beam"),
    EbinDir = filename:dirname(BeamFile),
    ?assertEqual(ok, 'Elixir.Mix.Tasks.Prisma':run([list_to_binary(EbinDir)])).

elixir_struct_update_and_complex_clauses_test() ->
    Mod = 'Elixir.Dymmer.Sample',
    Definitions = [
        {{update_response, 2}, def, [{line, 140}], [
            {[{line, 140}],
             [
                 {response, [{version, 0}, {line, 140}, {column, 10}], nil},
                 {domains, [{version, 1}, {line, 140}, {column, 20}], nil}
             ],
             [],
             {'%', [{line, 142}], [
                 'Elixir.Dymmer.Response',
                 {'%{}', [{line, 142}, {column, 20}], [
                     {'|', [{line, 142}, {column, 26}], [
                         {response, [{version, 0}, {line, 142}, {column, 17}], nil},
                         [{responseData,
                             {'%{}', [{line, 142}, {column, 42}], [
                                 {domains, {domains, [{version, 1}, {line, 142}, {column, 53}], nil}}
                             ]}
                         }]
                     ]}
                 ]}
             ]}}
        ]}
    ],
    Dbgi = {debug_info_v1, elixir_erl, {elixir_v1, #{
        module => Mod,
        struct => nil,
        definitions => Definitions
    }, []}},
    Summary = prisma_elixir:from_elixir_dbgi(Mod, Dbgi, [{update_response, 2}], #module_summary{
        module = Mod,
        language = elixir,
        exports = [{update_response, 2}]
    }),
    ?assert(maps:is_key({Mod, update_response, 2}, Summary#module_summary.functions)).

elixir_ssa_versioning_and_wildcard_struct_test() ->
    Mod = 'Elixir.Sample.Ssa',
    Definitions = [
        %% def complete(state, result) do state = %{state | refreshing: nil}; state end
        {{complete, 2}, def, [{line, 10}], [
            {[{line, 10}],
             [
                 {state, [{version, 0}, {line, 10}], nil},
                 {result, [{version, 1}, {line, 10}], nil}
             ],
             [],
             {'__block__', [{line, 11}], [
                 {'=', [{line, 11}], [
                     {state, [{version, 2}, {line, 11}], nil},
                     {'%{}', [{line, 11}], [
                         {'|', [{line, 11}], [
                             {state, [{version, 0}, {line, 11}], nil},
                             [{refreshing, nil}]
                         ]}
                     ]}
                 ]},
                 {state, [{version, 2}, {line, 12}], nil}
             ]}}
        ]},
        %% def handle_any_struct(%_{} = item), do: item
        {{handle_any_struct, 1}, def, [{line, 20}], [
            {[{line, 20}],
             [
                 {'=', [{line, 20}], [
                     {'%', [{line, 20}], [{'_', [{line, 20}], nil}, {'%{}', [{line, 20}], []}]},
                     {item, [{version, 0}, {line, 20}], nil}
                 ]}
             ],
             [],
             {item, [{version, 0}, {line, 20}], nil}}
        ]},
        %% def __mix_recompile__?(), do: case false do false -> true; true -> false end
        {{'__mix_recompile__?', 0}, def, [{line, 30}], [
            {[{line, 30}], [], [],
             {'case', [{line, 30}], [
                 false,
                 [{do, [
                     {'->', [{line, 30}], [[false], true]},
                     {'->', [{line, 30}], [[true], false]}
                 ]}]
             ]}}
        ]}
    ],
    Dbgi = {debug_info_v1, elixir_erl, {elixir_v1, #{
        module => Mod,
        struct => nil,
        definitions => Definitions
    }, []}},
    Exports = [{complete, 2}, {handle_any_struct, 1}, {'__mix_recompile__?', 0}],
    Summary = prisma_elixir:from_elixir_dbgi(Mod, Dbgi, Exports, #module_summary{
        module = Mod,
        language = elixir,
        exports = Exports
    }),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    Warnings = prisma_checker:check_module(Summary, Pplt, #{mode => hybrid}),
    ?assertEqual([], Warnings),
    {ok, CompleteContract} = prisma_pplt:lookup_mfa({Mod, complete, 2}, Pplt),
    ?assertMatch({fun_type, [any, any], _}, CompleteContract#func_contract.inferred_type),
    {ok, AnyStructContract} = prisma_pplt:lookup_mfa({Mod, handle_any_struct, 1}, Pplt),
    ?assertMatch({fun_type, [{map, [{exact, {atom_lit, '__struct__'}, any}]}], _}, AnyStructContract#func_contract.inferred_type).

elixir_cond_default_branch_test() ->
    Mod = 'Elixir.PrismaRepro',
    ClauseAnno = [{generated, true}, {location, {5, 12}}],
    Expr = {'case', {3, 5},
        {op, {4, 9}, '==', {var, {4, 7}, '_x@1'}, {integer, {4, 9}, 1}},
        [
            {clause, {4, 14}, [{atom, {4, 14}, true}], [], [{atom, {4, 14}, one}]},
            {clause, {5, 12}, [{atom, {5, 12}, false}], [], [
                {'case', {5, 12}, {atom, {5, 12}, true}, [
                    {clause, {5, 12}, [{atom, {5, 12}, true}], [], [{atom, {5, 12}, other}]},
                    {clause, ClauseAnno, [{atom, ClauseAnno, false}], [], [
                        {call, {5, 12}, {remote, {5, 12}, {atom, {5, 12}, erlang}, {atom, {5, 12}, error}}, [{atom, {5, 12}, cond_clause}]}
                    ]}
                ]}
            ]}
        ]
    },
    Function = {function, {2, 7}, a, 1, [{clause, {2, 7}, [{var, {2, 9}, '_x@1'}], [], [Expr]}]},
    Forms = [Function],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{a, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    Warnings = prisma_checker:check_module(Summary, Pplt, #{mode => hybrid}),
    ?assertEqual([], Warnings).

elixir_struct_update_preserves_struct_test() ->
    Mod = 'Elixir.MyApp.Partial',
    StructMeta = [
        #{field => '__struct__', required => true},
        #{field => id, required => true},
        #{field => name, required => false}
    ],
    SpecsForms = [
        {attribute, 1, export_type, [{t, 0}]},
        {attribute, 5, type, {t,
            {type, 5, map, [
                {type, 5, map_field_exact, [{atom, 5, '__struct__'}, {atom, 5, Mod}]},
                {type, 5, map_field_exact, [{atom, 5, id}, {type, 5, pos_integer, []}]},
                {type, 5, map_field_exact, [{atom, 5, name}, {type, 5, binary, []}]}
            ]},
            []
        }},
        {attribute, 10, spec, {{rename, 2}, [
            {type, 10, 'fun', [
                {type, 10, product, [{user_type, 10, t, []}, {type, 10, binary, []}]},
                {user_type, 10, t, []}
            ]}
        ]}}
    ],
    Definitions = [
        {{rename, 2}, def, [{line, 11}], [
            {[{line, 11}],
             [{'%', [{line, 11}], [Mod, {'%{}', [{line, 11}], []}]}, {name, [{line, 11}], nil}],
             [],
             {'%', [{line, 12}], [Mod, {'%{}', [{line, 12}], [{'|', [{line, 12}], [
                 {partial, [{line, 12}], nil},
                 [{name, {name, [{line, 12}], nil}}]
             ]}]}]}}
        ]}
    ],
    %% Rewrite first arg pattern to bind `partial` variable in struct pattern:
    %% %Mod{} = partial -> {'=', ..., [{'%', ..., [Mod, {'%{}', ..., []}]}, {partial, ..., nil}]}
    Pat = {'=', [{line, 11}], [
        {'%', [{line, 11}], [Mod, {'%{}', [{line, 11}], []}]},
        {partial, [{line, 11}], nil}
    ]},
    [{{rename, 2}, def, Meta, [{CMeta, [_, NameVar], Guards, Body}]}] = Definitions,
    Dbgi = {debug_info_v1, elixir_erl, {elixir_v1, #{
        module => Mod,
        struct => StructMeta,
        definitions => [{{rename, 2}, def, Meta, [{CMeta, [Pat, NameVar], Guards, Body}]}]
    }, SpecsForms}},
    Exports = [{rename, 2}],
    Summary = prisma_elixir:from_elixir_dbgi(Mod, Dbgi, Exports, #module_summary{
        module = Mod,
        language = elixir,
        exports = Exports
    }),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    Warnings = prisma_checker:check_module(Summary, Pplt, #{mode => hybrid}),
    ?assertEqual([], Warnings).

elixir_defmacro_tracks_private_helpers_test() ->
    Mod = 'Elixir.MyApp.Macros',
    Definitions = [
        {{halt, 1}, defmacro, [{line, 5}], [
            {[{line, 5}], [{call, [{line, 5}], nil}], [],
             {build_context, [{line, 6}], [{call, [{line, 6}], nil}]}}
        ]},
        {{build_context, 1}, defp, [{line, 10}], [
            {[{line, 10}], [{x, [{line, 10}], nil}], [], {x, [{line, 10}], nil}}
        ]}
    ],
    Dbgi = {debug_info_v1, elixir_erl, {elixir_v1, #{
        module => Mod,
        definitions => Definitions
    }, []}},
    Exports = [{'MACRO-halt', 2}],
    Summary = prisma_elixir:from_elixir_dbgi(Mod, Dbgi, Exports, #module_summary{
        module = Mod,
        language = elixir,
        exports = Exports
    }),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

elixir_remote_type_return_and_nested_tuple_union_test() ->
    StringDecl = #type_decl{
        key = {'Elixir.String', t, 0},
        kind = type,
        exported = true,
        params = [],
        body = {binary, 0, 8}
    },
    ExternalTypes = #{{'Elixir.String', t, 0} => StringDecl},
    LookupFun = fun(Key) -> maps:find(Key, ExternalTypes) end,
    Spec = [{fun_type, [any], {remote_type, 'Elixir.String', t, []}}],
    ?assertEqual(
        {binary, 0, 8},
        prisma_infer:declared_return(Spec, 1, [any], 'Elixir.String.Chars', LookupFun)
    ),
    Sub = {tuple, [{atom_lit, reference}, {tuple, [{union, [{atom_lit, decimal}, {atom_lit, hexadecimal}]}, integer]}]},
    Super = {union, [
        {tuple, [{atom_lit, reference}, {tuple, [{atom_lit, decimal}, integer]}]},
        {tuple, [{atom_lit, reference}, {tuple, [{atom_lit, entity}, {binary, 0, 8}]}]},
        {tuple, [{atom_lit, reference}, {tuple, [{atom_lit, hexadecimal}, integer]}]}
    ]},
    ?assert(prisma_type:consistent_subtype(Sub, Super)).

map_domain_union_key_subtyping_test() ->
    Super = {map, [{exact, {union, [{tuple, [{binary, 0, 8}, {binary, 0, 8}]}, {binary, 0, 8}]}, {binary, 0, 8}}]},
    ?assert(prisma_type:consistent_subtype({map, []}, Super)),
    ?assert(prisma_type:consistent_subtype({map, [{assoc, {binary, 0, 8}, {binary, 0, 8}}]}, Super)).

multi_spec_clause_filtering_test() ->
    Mod = 'Elixir.MyApp.MultiSpec',
    ClientType = {type, 1, map, [{type, 1, map_field_exact, [{atom, 1, '__struct__'}, {atom, 1, 'Elixir.Tesla.Client'}]}]},
    Forms = [
        {attribute, 1, spec, {{req, 2}, [
            {type, 1, 'fun', [{type, 1, product, [ClientType, {type, 1, binary, []}]}, {type, 1, binary, []}]}
        ]}},
        {attribute, 2, spec, {{delete, 2}, [
            {type, 2, 'fun', [{type, 2, product, [ClientType, {type, 2, binary, []}]}, {type, 2, binary, []}]},
            {type, 2, 'fun', [{type, 2, product, [{type, 2, binary, []}, {type, 2, list, [{type, 2, atom, []}]}]}, {type, 2, binary, []}]}
        ]}},
        {function, 3, req, 2, [
            {clause, 3, [{var, 3, '_c'}, {var, 3, 'u'}], [], [{var, 3, 'u'}]}
        ]},
        {function, 4, delete, 2, [
            {clause, 4,
             [{match, 4, {map, 4, [{map_field_exact, 4, {atom, 4, '__struct__'}, {atom, 4, 'Elixir.Tesla.Client'}}]}, {var, 4, 'c'}} , {var, 4, 'url'}],
             [],
             [{call, 4, {atom, 4, req}, [{var, 4, 'c'}, {var, 4, 'url'}]}]},
            {clause, 5,
             [{var, 5, 'url'}, {var, 5, 'opts'}],
             [[{call, 5, {remote, 5, {atom, 5, erlang}, {atom, 5, is_list}}, [{var, 5, 'opts'}]}]],
             [{var, 5, 'url'}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{delete, 2}, {req, 2}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

guarded_case_and_nil_narrowing_test() ->
    Mod = 'Elixir.MyApp.Narrowing',
    Forms = [
        {attribute, 1, spec, {{or_else_int, 1}, [
            {type, 1, 'fun', [{type, 1, product, [{type, 1, union, [{type, 1, non_neg_integer, []}, {atom, 1, nil}]}]}, {type, 1, integer, []}]}
        ]}},
        {function, 2, or_else_int, 1, [
            {clause, 2, [{var, 2, 'x'}], [], [
                {'case', 2, {var, 2, 'x'}, [
                    {clause, 2, [{var, 2, 'y'}],
                     [[{op, 2, 'orelse', {op, 2, '=:=', {var, 2, 'y'}, {atom, 2, false}}, {op, 2, '=:=', {var, 2, 'y'}, {atom, 2, nil}}}]],
                     [{integer, 2, 0}]},
                    {clause, 2, [{var, 2, 'z'}], [], [{var, 2, 'z'}]}
                ]}
            ]}
        ]},
        {attribute, 5, spec, {{require_int, 1}, [
            {type, 5, 'fun', [{type, 5, product, [{type, 5, integer, []}]}, {type, 5, boolean, []}]}
        ]}},
        {function, 6, require_int, 1, [
            {clause, 6, [{var, 6, '_'}], [], [{atom, 6, true}]}
        ]},
        {attribute, 8, spec, {{nil_or_check, 1}, [
            {type, 8, 'fun', [{type, 8, product, [{type, 8, union, [{type, 8, integer, []}, {atom, 8, nil}]}]}, {type, 8, boolean, []}]}
        ]}},
        {function, 9, nil_or_check, 1, [
            {clause, 9, [{var, 9, 'v'}], [], [
                {'case', 9, {op, 9, '==', {var, 9, 'v'}, {atom, 9, nil}}, [
                    {clause, 9, [{atom, 9, false}], [], [{call, 9, {atom, 9, require_int}, [{var, 9, 'v'}]}]},
                    {clause, 9, [{atom, 9, true}], [], [{atom, 9, true}]}
                ]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{or_else_int, 1}, {require_int, 1}, {nil_or_check, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

clause_arg_subtraction_with_struct_test() ->
    Mod = 'Elixir.MyApp.ClauseSub',
    HostMod = 'Elixir.MyApp.Host',
    HostDecl = #type_decl{
        key = {HostMod, t, 0},
        kind = type,
        exported = true,
        params = [],
        body = {map, [
            {exact, {atom_lit, '__struct__'}, {atom_lit, HostMod}},
            {exact, {atom_lit, missing_field}, {remote_type, 'Elixir.Unknown', t, []}}
        ]}
    },
    HostType = {remote_type, 1, [{atom, 1, HostMod}, {atom, 1, t}, []]},
    TargetType = {type, 1, union, [{atom, 1, daemon}, {atom, 1, disabled}, {atom, 1, ssh}]},
    NonDaemonType = {type, 1, union, [{atom, 1, disabled}, {atom, 1, ssh}]},
    Forms = [
        {attribute, 2, spec, {{release, 1}, [
            {type, 2, 'fun', [{type, 2, product, [NonDaemonType]}, {atom, 2, ok}]}
        ]}},
        {function, 3, release, 1, [
            {clause, 3, [{var, 3, '_'}], [], [{atom, 3, ok}]}
        ]},
        {attribute, 5, spec, {{change, 2}, [
            {type, 5, 'fun', [{type, 5, product, [HostType, TargetType]}, {atom, 5, ok}]}
        ]}},
        {function, 6, change, 2, [
            {clause, 6,
             [{match, 6, {map, 6, [{map_field_exact, 6, {atom, 6, '__struct__'}, {atom, 6, HostMod}}]}, {var, 6, '_h'}}, {atom, 6, daemon}],
             [],
             [{atom, 6, ok}]},
            {clause, 7,
             [{var, 7, '_h'}, {var, 7, 't'}],
             [],
             [{call, 7, {atom, 7, release}, [{var, 7, 't'}]}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(
        Forms,
        [{change, 2}, {release, 1}],
        #module_summary{module = Mod, language = elixir},
        #{external_types => #{{HostMod, t, 0} => HostDecl}}
    ),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

cons_pattern_does_not_cover_nil_test() ->
    Mod = 'Elixir.MyApp.ConsNil',
    ListOrNil = {type, 1, union, [{nil, 1}, {type, 1, nonempty_list, [{type, 1, atom, []}]}]},
    Panel = {type, 1, union, [{atom, 1, a}, {atom, 1, b}]},
    Forms = [
        {attribute, 2, spec, {{dispatch, 2}, [
            {type, 2, 'fun', [{type, 2, product, [ListOrNil, Panel]}, {atom, 2, ok}]}
        ]}},
        {function, 3, dispatch, 2, [
            {clause, 3, [{var, 3, 'errs'}, {var, 3, 'panel'}], [], [
                {'case', 3, {tuple, 3, [{var, 3, 'errs'}, {var, 3, 'panel'}]}, [
                    {clause, 4,
                     [{tuple, 4, [{match, 4, {cons, 4, {var, 4, '_'}, {var, 4, '_'}}, {var, 4, '_e'}}, {var, 4, '_p'}]}],
                     [],
                     [{atom, 4, ok}]},
                    {clause, 5,
                     [{tuple, 5, [{nil, 5}, {atom, 5, a}]}],
                     [],
                     [{atom, 5, ok}]},
                    {clause, 6,
                     [{tuple, 6, [{nil, 6}, {atom, 6, b}]}],
                     [],
                     [{atom, 6, ok}]}
                ]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{dispatch, 2}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

nonlinear_repeated_var_clause_test() ->
    Mod = 'Elixir.MyApp.NonLinear',
    ConnType = {type, 1, union, [{atom, 1, ssh}, {atom, 1, disabled}]},
    HostType = {type, 1, map, [{type, 1, map_field_exact, [{atom, 1, connection}, ConnType]}]},
    Forms = [
        {attribute, 2, spec, {{change, 2}, [
            {type, 2, 'fun', [{type, 2, product, [HostType, ConnType]}, {atom, 2, ok}]}
        ]}},
        {function, 3, change, 2, [
            {clause, 3,
             [{map, 3, [{map_field_exact, 3, {atom, 3, connection}, {var, 3, 'same'}}]}, {var, 3, 'same'}],
             [],
             [{atom, 3, ok}]},
            {clause, 4,
             [{map, 4, []}, {atom, 4, ssh}],
             [],
             [{atom, 4, ok}]},
            {clause, 5,
             [{map, 5, []}, {atom, 5, disabled}],
             [],
             [{atom, 5, ok}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{change, 2}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

recursive_type_tuple_pattern_test() ->
    Mod = 'Elixir.MyApp.RecTuple',
    Forms = [
        {attribute, 1, type, {t, {type, 1, union, [
            {atom, 1, int},
            {type, 1, tuple, [{atom, 1, array}, {user_type, 1, t, []}]},
            {type, 1, tuple, [{atom, 1, param}, {type, 1, atom, []}]}
        ]}, []}},
        {attribute, 2, spec, {{dump, 1}, [
            {type, 2, 'fun', [{type, 2, product, [{user_type, 2, t, []}]}, {atom, 2, ok}]}
        ]}},
        {function, 3, dump, 1, [
            {clause, 3, [{tuple, 3, [{atom, 3, array}, {match, 3, {tuple, 3, [{atom, 3, param}, {var, 3, '_'}]}, {var, 3, '_t'}}]}], [], [{atom, 3, ok}]},
            {clause, 4, [{var, 4, '_'}], [], [{atom, 4, ok}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{dump, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

heterogeneous_cons_pattern_preserves_tail_elems_test() ->
    Mod = 'Elixir.MyApp.ConsElems',
    Forms = [
        {function, 2, parse_access, 1, [
            {clause, 2,
             [{match, 2,
               {cons, 2, {tuple, 2, [{var, 2, 'v'}, {var, 2, 'ctx'}]}, {cons, 2, {var, 2, 'field'}, {nil, 2}}},
               {var, 2, '_expr'}}],
             [[{op, 2, 'andalso',
                {call, 2, {remote, 2, {atom, 2, erlang}, {atom, 2, is_atom}}, [{var, 2, 'v'}]},
                {call, 2, {remote, 2, {atom, 2, erlang}, {atom, 2, is_atom}}, [{var, 2, 'field'}]}}]],
             [{atom, 2, ok}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{parse_access, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

elixir_multi_when_guard_is_disjunction_test() ->
    Meta = [{line, 5}],
    ElixirInfo = #{
        module => 'Elixir.MyApp.MultiWhen',
        file => <<"lib/multi_when.ex">>,
        attributes => [],
        definitions => [
            {{escape, 1}, def, Meta, [
                {Meta, [{x, Meta, nil}],
                 [
                     {is_list, Meta, [{x, Meta, nil}]},
                     {is_tuple, Meta, [{x, Meta, nil}]}
                 ],
                 ok}
            ]}
        ]
    },
    Dbgi = {debug_info_v1, elixir_erl, {elixir_v1, ElixirInfo, []}},
    Summary = prisma_elixir:from_elixir_dbgi(
        'Elixir.MyApp.MultiWhen',
        Dbgi,
        [{escape, 1}],
        #module_summary{module = 'Elixir.MyApp.MultiWhen', language = elixir}
    ),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{'Elixir.MyApp.MultiWhen' => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

open_map_update_stays_compatible_with_struct_test() ->
    Mod = 'Elixir.MyApp.MapUpdate',
    QueryType = {type, 1, map, [
        {type, 1, map_field_exact, [{atom, 1, '__struct__'}, {atom, 1, 'Elixir.MyApp.Query'}]},
        {type, 1, map_field_exact, [{atom, 1, prefix}, {type, 1, term, []}]}
    ]},
    Forms = [
        {attribute, 2, spec, {{plan, 1}, [
            {type, 2, 'fun', [{type, 2, product, [QueryType]}, {atom, 2, ok}]}
        ]}},
        {function, 3, plan, 1, [
            {clause, 3, [{var, 3, '_q'}], [], [{atom, 3, ok}]}
        ]},
        {function, 5, plan_subquery, 1, [
            {clause, 5, [{map, 5, [{map_field_exact, 5, {atom, 5, query}, {var, 5, 'inner'}}]}], [], [
                {call, 6, {atom, 6, plan}, [
                    {map, 6, {var, 6, 'inner'}, [{map_field_exact, 6, {atom, 6, prefix}, {atom, 6, nil}}]}
                ]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{plan, 1}, {plan_subquery, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

elixir_andand_truthy_lhs_no_dead_code_test() ->
    Mod = 'Elixir.MyApp.AndAnd',
    Forms = [
        {attribute, 2, spec, {{warn_true, 0}, [{type, 2, 'fun', [{type, 2, product, []}, {atom, 2, ok}]}]}},
        {function, 3, warn_true, 0, [{clause, 3, [], [], [{atom, 3, ok}]}]},
        {attribute, 5, spec, {{check, 1}, [{type, 5, 'fun', [{type, 5, product, [{type, 5, boolean, []}]}, {type, 5, boolean, []}]}]}},
        {function, 6, check, 1, [
            {clause, 6, [{var, 6, 'b'}], [], [
                {'case', 7, {call, 7, {atom, 7, warn_true}, []}, [
                    {clause, 7, [{var, 7, 'x@1@Elixir.Kernel'}],
                     [[{op, 7, 'orelse',
                        {op, 7, '=:=', {var, 7, 'x@1@Elixir.Kernel'}, {atom, 7, false}},
                        {op, 7, '=:=', {var, 7, 'x@1@Elixir.Kernel'}, {atom, 7, nil}}}]],
                     [{var, 7, 'x@1@Elixir.Kernel'}]},
                    {clause, 7, [{var, 7, '_'}], [], [{var, 7, 'b'}]}
                ]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{warn_true, 0}, {check, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

elixir_in_and_io_warn_boolean_test() ->
    Mod = 'Elixir.MyApp.InWarn',
    Forms = [
        {attribute, 2, spec, {{check_in, 2}, [{type, 2, 'fun', [{type, 2, product, [{type, 2, term, []}, {type, 2, list, []}]}, {type, 2, boolean, []}]}]}},
        {function, 3, check_in, 2, [
            {clause, 3, [{var, 3, 'v'}, {var, 3, 'xs'}], [], [
                {'case', 4, {call, 4, {remote, 4, {atom, 4, 'Elixir.IO'}, {atom, 4, warn}}, [{atom, 4, msg}]}, [
                    {clause, 4, [{var, 4, 'x@1@Elixir.Kernel'}],
                     [[{op, 4, 'orelse',
                        {op, 4, '=:=', {var, 4, 'x@1@Elixir.Kernel'}, {atom, 4, false}},
                        {op, 4, '=:=', {var, 4, 'x@1@Elixir.Kernel'}, {atom, 4, nil}}}]],
                     [{var, 4, 'x@1@Elixir.Kernel'}]},
                    {clause, 4, [{var, 4, '_'}], [], [
                        {call, 4, {remote, 4, {atom, 4, 'Elixir.Enum'}, {atom, 4, '__in__'}}, [{var, 4, 'v'}, {var, 4, 'xs'}]}
                    ]}
                ]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{check_in, 2}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

elixir_if_assignment_narrows_var_test() ->
    Mod = 'Elixir.MyApp.IfAssign',
    Forms = [
        {attribute, 2, spec, {{get_pid, 0}, [{type, 2, 'fun', [{type, 2, product, []}, {type, 2, union, [{type, 2, pid, []}, {atom, 2, nil}]}]}]}},
        {function, 3, get_pid, 0, [{clause, 3, [], [], [{atom, 3, nil}]}]},
        {attribute, 5, spec, {{use_pid, 1}, [{type, 5, 'fun', [{type, 5, product, [{type, 5, pid, []}]}, {type, 5, pid, []}]}]}},
        {function, 6, use_pid, 1, [{clause, 6, [{var, 6, 'p'}], [], [{var, 6, 'p'}]}]},
        {attribute, 8, spec, {{check, 0}, [{type, 8, 'fun', [{type, 8, product, []}, {type, 8, union, [{type, 8, pid, []}, {atom, 8, down}]}]}]}},
        {function, 9, check, 0, [
            {clause, 9, [], [], [
                {'case', 10, {match, 10, {var, 10, 'pid'}, {call, 10, {atom, 10, get_pid}, []}}, [
                    {clause, 10, [{var, 10, 'x@1'}],
                     [[{op, 10, 'orelse',
                        {op, 10, '=:=', {var, 10, 'x@1'}, {atom, 10, false}},
                        {op, 10, '=:=', {var, 10, 'x@1'}, {atom, 10, nil}}}]],
                     [{atom, 10, down}]},
                    {clause, 10, [{var, 10, '_'}], [], [
                        {call, 10, {atom, 10, use_pid}, [{var, 10, 'pid'}]}
                    ]}
                ]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{get_pid, 0}, {use_pid, 1}, {check, 0}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

local_function_shadows_bif_test() ->
    Mod = 'Elixir.ReproLocalFunctions',
    Forms = [
        {function, 2, element, 2, [
            {clause, 2, [{var, 2, 'text'}, {var, 2, '_suffix'}],
             [[{call, 2, {remote, 2, {atom, 2, erlang}, {atom, 2, is_binary}}, [{var, 2, 'text'}]}]],
             [{tuple, 2, [{atom, 2, ok}, {var, 2, 'text'}]}]}
        ]},
        {function, 3, size, 1, [
            {clause, 3, [{var, 3, '_value'}], [], [{tuple, 3, [{integer, 3, 1}, {integer, 3, 2}]}]}
        ]},
        {function, 5, element_result, 0, [
            {clause, 5, [], [], [
                {match, 6, {tuple, 6, [{atom, 6, ok}, {var, 6, 'text'}]},
                 {call, 6, {atom, 6, element}, [{bin, 6, [{bin_element, 6, {string, 6, "ok"}, default, default}]},
                                                {bin, 6, []}]}},
                {var, 7, 'text'}
            ]}
        ]},
        {function, 10, size_result, 0, [
            {clause, 10, [], [], [
                {match, 11, {tuple, 11, [{var, 11, 'first'}, {var, 11, 'second'}]},
                 {call, 11, {atom, 11, size}, [{atom, 11, input}]}},
                {op, 12, '+', {var, 12, 'first'}, {var, 12, 'second'}}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(
        Forms,
        [{element, 2}, {size, 1}, {element_result, 0}, {size_result, 0}],
        #module_summary{module = Mod, language = elixir},
        #{}
    ),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

try_after_and_receive_return_contracts_test() ->
    Mod = 'Elixir.ReproControlFlow',
    Forms = [
        {attribute, 2, spec, {{in_try, 0}, [{type, 2, 'fun', [{type, 2, product, []}, {type, 2, integer, []}]}]}},
        {function, 3, in_try, 0, [
            {clause, 3, [], [], [
                {'try', 4, [{atom, 4, wrong}], [], [], [{atom, 4, ok}]}
            ]}
        ]},
        {attribute, 10, spec, {{in_receive, 0}, [{type, 10, 'fun', [{type, 10, product, []}, {type, 10, integer, []}]}]}},
        {function, 11, in_receive, 0, [
            {clause, 11, [], [], [
                {'receive', 12,
                 [{clause, 13, [{atom, 13, go}], [], [{atom, 13, wrong}]}],
                 {integer, 15, 0},
                 [{atom, 15, wrong}]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(
        Forms,
        [{in_try, 0}, {in_receive, 0}],
        #module_summary{module = Mod, language = elixir},
        #{}
    ),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    Warnings = prisma_checker:check_module(Summary, Pplt, #{mode => hybrid}),
    ?assertEqual(2, length(Warnings)),
    ?assert(lists:all(fun(#prisma_warning{kind = gradual_mismatch}) -> true; (_) -> false end, Warnings)).

behaviour_callback_return_mismatch_test() ->
    BehMod = 'Elixir.ReproBehaviour',
    BehForms = [
        {attribute, 2, callback, {{process, 1}, [{type, 2, 'fun', [{type, 2, product, [{type, 2, integer, []}]}, {type, 2, integer, []}]}]}}
    ],
    BehSummary = prisma_abstract:parse_abstract_forms(BehForms, [], #module_summary{module = BehMod, language = elixir}, #{}),
    ImplMod = 'Elixir.ReproImplementation',
    ImplForms = [
        {attribute, 5, behaviour, BehMod},
        {function, 7, process, 1, [{clause, 7, [{var, 7, '_value'}], [], [{atom, 7, wrong}]}]}
    ],
    ImplSummary = prisma_abstract:parse_abstract_forms(ImplForms, [{process, 1}], #module_summary{module = ImplMod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{BehMod => BehSummary, ImplMod => ImplSummary}},
    Warnings = prisma_checker:check_module(ImplSummary, Pplt, #{mode => hybrid}),
    ?assertMatch([#prisma_warning{kind = gradual_mismatch, mfa = {ImplMod, process, 1}}], Warnings).

cross_module_inferred_return_order_independent_test() ->
    CallerMod = 'Elixir.ReproAlphaCallerOrder',
    SourceMod = 'Elixir.ReproOmegaSourceOrder',
    CallerForms = [
        {attribute, 1, file, {"caller.ex", 1}},
        {attribute, 1, module, CallerMod},
        {attribute, 1, export, [{value, 0}]},
        {attribute, 2, spec, {{value, 0}, [{type, 2, 'fun', [{type, 2, product, []}, {type, 2, integer, []}]}]}},
        {function, 3, value, 0, [{clause, 3, [], [], [{call, 3, {remote, 3, {atom, 3, SourceMod}, {atom, 3, value}}, []}]}]}
    ],
    SourceForms = [
        {attribute, 1, file, {"source.ex", 1}},
        {attribute, 1, module, SourceMod},
        {attribute, 1, export, [{value, 0}]},
        {function, 2, value, 0, [{clause, 2, [], [], [{atom, 2, wrong}]}]}
    ],
    {ok, CallerMod, CallerBin} = compile:forms(CallerForms, [binary, debug_info]),
    {ok, SourceMod, SourceBin} = compile:forms(SourceForms, [binary, debug_info]),
    TmpDir = "/tmp/prisma_order_test_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    CallerBeam = filename:join(TmpDir, atom_to_list(CallerMod) ++ ".beam"),
    SourceBeam = filename:join(TmpDir, atom_to_list(SourceMod) ++ ".beam"),
    ok = file:write_file(CallerBeam, CallerBin),
    ok = file:write_file(SourceBeam, SourceBin),
    try
        Opts = #{mode => hybrid, oxbow => false},
        {ok, Res1} = prisma:analyze_beams([CallerBeam, SourceBeam], Opts),
        {ok, Res2} = prisma:analyze_beams([SourceBeam, CallerBeam], Opts),
        ?assertMatch([#prisma_warning{kind = gradual_mismatch, mfa = {CallerMod, value, 0}}], Res1),
        ?assertMatch([#prisma_warning{kind = gradual_mismatch, mfa = {CallerMod, value, 0}}], Res2)
    after
        _ = file:delete(CallerBeam),
        _ = file:delete(SourceBeam),
        _ = file:del_dir(TmpDir)
    end.

%% Regression test for #1 (reported by @houllette): exhaustive cond does not emit dead_code.
exhaustive_cond_no_dead_code_test() ->
    Mod = 'Elixir.ReproConditional',
    Forms = [
        {attribute, 2, spec, {{classify, 1}, [{type, 2, 'fun', [{type, 2, product, [{type, 2, integer, []}]},
            {type, 2, union, [{atom, 2, zero}, {atom, 2, one}, {atom, 2, other}]}]}]}},
        {function, 3, classify, 1, [
            {clause, 3, [{var, 3, 'value'}], [], [
                {'case', 4, {op, 5, '==', {var, 5, 'value'}, {integer, 5, 0}}, [
                    {clause, 5, [{atom, 5, false}], [], [
                        {'case', 6, {op, 6, '==', {var, 6, 'value'}, {integer, 6, 1}}, [
                            {clause, 6, [{atom, 6, false}], [], [
                                {'case', erl_anno:set_generated(true, 7), {atom, 7, true}, [
                                    {clause, 7, [{atom, 7, false}], [], [{atom, 7, nil}]},
                                    {clause, 7, [{atom, 7, true}], [], [{atom, 7, other}]}
                                ]}
                            ]},
                            {clause, 6, [{atom, 6, true}], [], [{atom, 6, one}]}
                        ]}
                    ]},
                    {clause, 5, [{atom, 5, true}], [], [{atom, 5, zero}]}
                ]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{classify, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

%% Regression test for #2 (reported by @houllette): struct update preserves unchanged fields.
struct_update_preserves_fields_test() ->
    BoxMod = 'Elixir.ReproBox',
    BoxForms = [
        {attribute, 3, type, {t, {type, 3, map, [
            {type, 3, map_field_exact, {atom, 3, '__struct__'}, {atom, 3, BoxMod}},
            {type, 3, map_field_exact, {atom, 3, amount}, {type, 3, integer, []}},
            {type, 3, map_field_exact, {atom, 3, unit}, {type, 3, atom, []}}
        ]}, []}},
        {attribute, 3, export_type, [{t, 0}]}
    ],
    BoxSummary = prisma_abstract:parse_abstract_forms(BoxForms, [], #module_summary{module = BoxMod, language = elixir}, #{}),
    UpdMod = 'Elixir.ReproUpdate',
    UpdForms = [
        {attribute, 6, spec, {{set, 2}, [{type, 6, 'fun', [
            {type, 6, product, [{remote_type, 6, [{atom, 6, BoxMod}, {atom, 6, t}, []]}, {type, 6, integer, []}]},
            {remote_type, 6, [{atom, 6, BoxMod}, {atom, 6, t}, []]}
        ]}]}},
        {function, 7, set, 2, [
            {clause, 7, [{map, 7, [{map_field_exact, 7, {atom, 7, '__struct__'}, {atom, 7, BoxMod}}]}, {var, 7, 'amount'}], [], [
                {map, 7, {map, 7, [{map_field_exact, 7, {atom, 7, '__struct__'}, {atom, 7, BoxMod}}]}, [
                    {map_field_exact, 7, {atom, 7, amount}, {var, 7, 'amount'}}
                ]}
            ]}
        ]}
    ],
    UpdSummary = prisma_abstract:parse_abstract_forms(UpdForms, [{set, 2}], #module_summary{module = UpdMod, language = elixir},
        #{external_types => BoxSummary#module_summary.types}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{BoxMod => BoxSummary, UpdMod => UpdSummary}},
    ?assertEqual([], prisma_checker:check_module(UpdSummary, Pplt, #{mode => hybrid})).

%% Regression test for #9 (reported by @houllette): float guard retains float() through abs/1 and multiplication.
float_guard_abs_mul_preserves_float_test() ->
    FloatMod = 'Elixir.Float',
    FloatForms = [
        {attribute, 1, spec, {{round, 2}, [{type, 1, 'fun', [
            {type, 1, product, [{type, 1, float, []}, {type, 1, non_neg_integer, []}]},
            {type, 1, float, []}
        ]}]}}
    ],
    FloatSummary = prisma_abstract:parse_abstract_forms(FloatForms, [], #module_summary{module = FloatMod, language = elixir}, #{}),
    Mod = 'Elixir.ReproFloat',
    Forms = [
        {function, 2, percentage, 1, [
            {clause, 2, [{var, 2, 'value'}],
             [[{call, 2, {remote, 2, {atom, 2, erlang}, {atom, 2, is_float}}, [{var, 2, 'value'}]}]],
             [{call, 3, {remote, 3, {atom, 3, FloatMod}, {atom, 3, round}},
               [{op, 3, '*', {call, 3, {remote, 3, {atom, 3, erlang}, {atom, 3, abs}}, [{var, 3, 'value'}]}, {integer, 3, 100}},
                {integer, 3, 1}]}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{percentage, 1}], #module_summary{module = Mod, language = elixir},
        #{external_specs => #{{FloatMod, round, 2} => (maps:get({FloatMod, round, 2}, FloatSummary#module_summary.functions))#func_contract.declared_specs}}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{FloatMod => FloatSummary, Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

%% Regression test for #10 (reported by @houllette): deconstructing an external opaque type reports opacity_violation.
opaque_deconstruction_outside_module_test() ->
    BoxMod = 'Elixir.ReproOpaqueBox',
    BoxForms = [
        {attribute, 2, opaque, {t, {type, 2, tuple, [{atom, 2, box}, {type, 2, integer, []}]}, []}},
        {attribute, 2, export_type, [{t, 0}]},
        {attribute, 3, spec, {{new, 1}, [{type, 3, 'fun', [
            {type, 3, product, [{type, 3, integer, []}]},
            {user_type, 3, t, []}
        ]}]}}
    ],
    BoxSummary = prisma_abstract:parse_abstract_forms(BoxForms, [{new, 1}], #module_summary{module = BoxMod, language = elixir}, #{}),
    ConsMod = 'Elixir.ReproOpaqueConsumer',
    NewSpec = (maps:get({BoxMod, new, 1}, BoxSummary#module_summary.functions))#func_contract.declared_specs,
    ConsForms = [
        {attribute, 6, spec, {{value, 0}, [{type, 6, 'fun', [{type, 6, product, []}, {type, 6, integer, []}]}]}},
        {function, 7, value, 0, [
            {clause, 7, [], [], [
                {match, 8, {tuple, 8, [{atom, 8, box}, {var, 8, 'val'}]},
                 {call, 8, {remote, 8, {atom, 8, BoxMod}, {atom, 8, new}}, [{integer, 8, 1}]}},
                {var, 9, 'val'}
            ]}
        ]}
    ],
    ConsSummary = prisma_abstract:parse_abstract_forms(ConsForms, [{value, 0}], #module_summary{module = ConsMod, language = elixir},
        #{external_specs => #{{BoxMod, new, 1} => NewSpec}, external_types => BoxSummary#module_summary.types}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{BoxMod => BoxSummary, ConsMod => ConsSummary}},
    Warnings = prisma_checker:check_module(ConsSummary, Pplt, #{mode => hybrid}),
    ?assertMatch([#prisma_warning{kind = opacity_violation, mfa = {ConsMod, value, 0}}], Warnings).

%% Regression test for #13 (reported by @nikolauska): compiler-generated string interpolation clause does not emit dead_code.
string_interpolation_no_dead_code_test() ->
    Mod = 'Elixir.ReproInterpolation',
    GenAnno = erl_anno:set_generated(true, 3),
    Forms = [
        {attribute, 2, spec, {{label, 1}, [{type, 2, 'fun', [{type, 2, product, [{type, 2, integer, []}]}, {type, 2, binary, []}]}]}},
        {function, 3, label, 1, [
            {clause, 3, [{var, 3, 'size'}],
             [[{call, 3, {remote, 3, {atom, 3, erlang}, {atom, 3, is_integer}}, [{var, 3, 'size'}]}]],
             [{'case', GenAnno, {var, 3, 'size'}, [
                 {clause, GenAnno, [{var, 3, 'x'}],
                  [[{call, GenAnno, {remote, GenAnno, {atom, GenAnno, erlang}, {atom, GenAnno, is_binary}}, [{var, 3, 'x'}]}]],
                  [{var, 3, 'x'}]},
                 {clause, GenAnno, [{var, 3, 'x'}], [],
                  [{call, 3, {remote, 3, {atom, 3, 'Elixir.String.Chars'}, {atom, 3, to_string}}, [{var, 3, 'x'}]}]}
             ]}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{label, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

%% Regression test for #14 (reported by @nikolauska): repeated-variable pattern across arguments is not unused.
oxbow_repeated_variable_pattern_test() ->
    Mod = 'Elixir.ReproSameArg',
    Forms = [
        {function, 3, changed, 2, [
            {clause, 3, [{var, 3, 'old'}, {var, 3, 'new'}], [], [
                {call, 3, {atom, 3, compare}, [{var, 3, 'old'}, {var, 3, 'new'}]}
            ]}
        ]},
        {function, 5, compare, 2, [
            {clause, 5, [{atom, 5, nil}, {var, 5, '_new'}], [], [{atom, 5, false}]},
            {clause, 6, [{var, 6, '_same@1'}, {var, 6, '_same@1'}], [], [{atom, 6, false}]},
            {clause, 7, [{var, 7, '_old'}, {var, 7, '_new'}], [], [{atom, 7, true}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{changed, 2}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid, oxbow => true})).

%% Regression test for #15 (reported by @nikolauska): tuple shape guard retains exact tuple type from spec.
tuple_shape_guard_preserves_spec_test() ->
    Mod = 'Elixir.ReproTupleGuard',
    SourceT = {type, 2, union, [
        {atom, 2, local},
        {type, 2, tuple, [{atom, 2, remote}, {type, 2, binary, []}]}
    ]},
    Forms = [
        {attribute, 2, type, {source, SourceT, []}},
        {attribute, 8, spec, {{path, 1}, [{type, 8, 'fun', [{type, 8, product, [{user_type, 8, source, []}]}, {type, 8, binary, []}]}]}},
        {function, 9, path, 1, [
            {clause, 9, [{var, 9, 'source'}],
             [[{op, 9, 'orelse',
                {op, 9, '==', {var, 9, 'source'}, {atom, 9, local}},
                {op, 9, 'andalso',
                 {call, 9, {remote, 9, {atom, 9, erlang}, {atom, 9, is_tuple}}, [{var, 9, 'source'}]},
                 {op, 9, 'andalso',
                  {op, 9, '==', {call, 9, {remote, 9, {atom, 9, erlang}, {atom, 9, tuple_size}}, [{var, 9, 'source'}]}, {integer, 9, 2}},
                  {op, 9, 'andalso',
                   {op, 9, '==', {call, 9, {remote, 9, {atom, 9, erlang}, {atom, 9, element}}, [{integer, 9, 1}, {var, 9, 'source'}]}, {atom, 9, remote}},
                   {call, 9, {remote, 9, {atom, 9, erlang}, {atom, 9, is_binary}},
                    [{call, 9, {remote, 9, {atom, 9, erlang}, {atom, 9, element}}, [{integer, 9, 2}, {var, 9, 'source'}]}]}}}}}
             ]],
             [{call, 9, {atom, 9, prefix}, [{var, 9, 'source'}]}]}
        ]},
        {attribute, 11, spec, {{prefix, 1}, [{type, 11, 'fun', [{type, 11, product, [{user_type, 11, source, []}]}, {type, 11, binary, []}]}]}},
        {function, 12, prefix, 1, [
            {clause, 12, [{atom, 12, local}], [], [{bin, 12, []}]},
            {clause, 13, [{tuple, 13, [{atom, 13, remote}, {var, 13, 'host'}]}], [], [{var, 13, 'host'}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{path, 1}, {prefix, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

%% Regression test for #16 (reported by @nikolauska): hybrid mode does not duplicate discrepancy + gradual_mismatch for the same call arg.
hybrid_dedup_discrepancy_and_gradual_test() ->
    Mod = 'Elixir.ReproDuplicate',
    Forms = [
        {attribute, 2, spec, {{only_binary, 1}, [{type, 2, 'fun', [{type, 2, product, [{type, 2, binary, []}]}, {atom, 2, ok}]}]}},
        {function, 3, only_binary, 1, [
            {clause, 3, [{var, 3, 'value'}],
             [[{call, 3, {remote, 3, {atom, 3, erlang}, {atom, 3, is_binary}}, [{var, 3, 'value'}]}]],
             [{atom, 3, ok}]}
        ]},
        {attribute, 5, spec, {{call, 1}, [{type, 5, 'fun', [{type, 5, product, [{type, 5, map, any}]}, {atom, 5, ok}]}]}},
        {function, 6, call, 1, [
            {clause, 6, [{map, 6, []}], [], [
                {call, 6, {atom, 6, only_binary}, [{map, 6, []}]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{only_binary, 1}, {call, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    Warnings = prisma_checker:check_module(Summary, Pplt, #{mode => hybrid}),
    ?assertMatch([#prisma_warning{kind = discrepancy, mfa = {Mod, call, 1}, callee = {Mod, only_binary, 1}, arg_idx = 1}], Warnings).

open_map_struct_supertype_unproven_gap_test() ->
    %% Ecto.Schema.t()-style open map `%{atom() => term(), __struct__: atom()}` returned against `%MyStruct{}`
    EctoMod = 'Elixir.FakeChangeset',
    EctoForms = [
        {attribute, 1, spec, {{apply_action, 1}, [{type, 1, 'fun', [
            {type, 1, product, [{type, 1, any, []}]},
            {type, 1, map, [
                {type, 1, map_field_exact, {atom, 1, '__struct__'}, {type, 1, atom, []}},
                {type, 1, map_field_assoc, {type, 1, atom, []}, {type, 1, any, []}}
            ]}
        ]}]}}
    ],
    EctoSummary = prisma_abstract:parse_abstract_forms(EctoForms, [], #module_summary{module = EctoMod, language = elixir}, #{}),
    ApplySpec = (maps:get({EctoMod, apply_action, 1}, EctoSummary#module_summary.functions))#func_contract.declared_specs,
    Mod = 'Elixir.MyHostConfig',
    Forms = [
        {attribute, 2, spec, {{make, 1}, [{type, 2, 'fun', [
            {type, 2, product, [{type, 2, any, []}]},
            {type, 2, map, [
                {type, 2, map_field_exact, {atom, 2, '__struct__'}, {atom, 2, Mod}},
                {type, 2, map_field_exact, {atom, 2, name}, {type, 2, binary, []}}
            ]}
        ]}]}},
        {function, 3, make, 1, [
            {clause, 3, [{var, 3, 'cs'}], [], [
                {call, 3, {remote, 3, {atom, 3, EctoMod}, {atom, 3, apply_action}}, [{var, 3, 'cs'}]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{make, 1}], #module_summary{module = Mod, language = elixir},
        #{external_specs => #{{EctoMod, apply_action, 1} => ApplySpec}}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{EctoMod => EctoSummary, Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

external_macro_compiler_generated_with_elixir_def_context_test() ->
    Mod = 'Elixir.FakeRateLimit',
    DefMeta = [{context, elixir_def}, {line, 1}, {context, 'Elixir.Hammer.ETS'}],
    Map = #{
        module => Mod,
        file => <<"lib/fake_rate_limit.ex">>,
        attributes => [],
        struct => nil,
        definitions => [
            {{inc, 2}, def, DefMeta, [
                {[{line, 1}],
                 [{key, [{line, 1}], 'Elixir.Hammer.ETS'}, {scale, [{line, 1}], 'Elixir.Hammer.ETS'}],
                 [],
                 {ok, [{line, 1}], []}}
            ]}
        ]
    },
    SpecsForms = [
        {attribute, 1, spec, {{inc, 2}, [{type, 1, 'fun', [
            {type, 1, product, [{type, 1, binary, []}, {type, 1, pos_integer, []}]},
            {type, 1, integer, []}
        ]}]}}
    ],
    Summary = prisma_elixir:from_elixir_dbgi(
        Mod,
        {debug_info_v1, elixir_erl, {elixir_v1, Map, SpecsForms}},
        [{inc, 2}],
        #module_summary{module = Mod, language = elixir},
        #{}
    ),
    FC = maps:get({Mod, inc, 2}, Summary#module_summary.functions),
    ?assertEqual(true, FC#func_contract.compiler_generated),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => hybrid})).

dynamic_struct_pattern_var_test() ->
    Mod = 'Elixir.DynamicStructPat',
    StructMod = 'Elixir.SomeError',
    Map = #{
        module => Mod,
        file => <<"lib/dyn_struct.ex">>,
        attributes => [],
        struct => nil,
        definitions => [
            {{handle, 1}, def, [{line, 1}], [
                {[{line, 1}],
                 [{'=', [{line, 1}], [
                     {'%', [{line, 1}], [{mod, [{line, 1}], nil}, {'%{}', [{line, 1}], []}]},
                     {s, [{line, 1}], nil}
                 ]}],
                 [[{'=:=', [{line, 1}], [{mod, [{line, 1}], nil}, StructMod]}]],
                 {take_err, [{line, 1}], [{s, [{line, 1}], nil}]}}
            ]},
            {{take_err, 1}, defp, [{line, 2}], [
                {[{line, 2}],
                 [{'%', [{line, 2}], [StructMod, {'%{}', [{line, 2}], []}]}],
                 [],
                 {ok, [{line, 2}], []}}
            ]}
        ]
    },
    Summary = prisma_elixir:from_elixir_dbgi(
        Mod,
        {debug_info_v1, elixir_erl, {elixir_v1, Map, []}},
        [{handle, 1}],
        #module_summary{module = Mod, language = elixir},
        #{}
    ),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Summary}},
    ?assertEqual([], prisma_checker:check_module(Summary, Pplt, #{mode => discrepancy})).

defmacrop_not_flagged_as_oxbow_test() ->
    Mod = 'Elixir.MacroOxbowTest',
    Map = #{
        module => Mod,
        file => <<"lib/macro_oxbow.ex">>,
        attributes => [],
        struct => nil,
        definitions => [
            {{is_pos, 1}, defmacrop, [{line, 1}], [
                {[{line, 1}],
                 [{x, [{line, 1}], nil}],
                 [],
                 {x, [{line, 1}], nil}}
            ]}
        ]
    },
    Summary = prisma_elixir:from_elixir_dbgi(
        Mod,
        {debug_info_v1, elixir_erl, {elixir_v1, Map, []}},
        [],
        #module_summary{module = Mod, language = elixir},
        #{}
    ),
    ?assertEqual([], prisma_oxbow:check_module(Summary)).

zero_arity_remote_call_not_map_get_test() ->
    SrcMod = 'Elixir.ZeroArgSource',
    CallerMod = 'Elixir.ZeroArgCaller',
    SrcMap = #{
        module => SrcMod,
        file => <<"lib/zero_arg.ex">>,
        attributes => [],
        struct => nil,
        definitions => [
            {{value, 0}, def, [{line, 1}], [{[{line, 1}], [], [], ok}]}
        ]
    },
    CallerMap = #{
        module => CallerMod,
        file => <<"lib/zero_arg_caller.ex">>,
        attributes => [],
        struct => nil,
        definitions => [
            {{good, 0}, def, [{line, 2}], [
                {[{line, 2}], [], [], {{'.', [{line, 2}], [SrcMod, value]}, [{line, 2}], []}}
            ]},
            {{bad, 0}, def, [{line, 3}], [
                {[{line, 3}], [], [], {{'.', [{line, 3}], [SrcMod, value]}, [{line, 3}], []}}
            ]}
        ]
    },
    SrcSpecs = [
        {attribute, 1, spec, {{value, 0}, [{type, 1, 'fun', [{type, 1, product, []}, {atom, 1, ok}]}]}}
    ],
    Specs = [
        {attribute, 2, spec, {{good, 0}, [{type, 2, 'fun', [{type, 2, product, []}, {atom, 2, ok}]}]}},
        {attribute, 3, spec, {{bad, 0}, [{type, 3, 'fun', [{type, 3, product, []}, {type, 3, integer, []}]}]}}
    ],
    SrcSum = prisma_elixir:from_elixir_dbgi(SrcMod, {debug_info_v1, elixir_erl, {elixir_v1, SrcMap, SrcSpecs}},
        [{value, 0}], #module_summary{module = SrcMod, language = elixir}, #{}),
    ExtSpecs = #{{SrcMod, value, 0} => [{fun_type, [], {atom_lit, ok}}]},
    CallerSum = prisma_elixir:from_elixir_dbgi(CallerMod, {debug_info_v1, elixir_erl, {elixir_v1, CallerMap, Specs}},
        [{good, 0}, {bad, 0}], #module_summary{module = CallerMod, language = elixir}, #{external_specs => ExtSpecs}),
    Pplt = prisma_pplt:merge([
        (prisma_pplt:new())#prisma_pplt{modules = #{SrcMod => SrcSum}},
        (prisma_pplt:new())#prisma_pplt{modules = #{CallerMod => CallerSum}}
    ]),
    Ws = prisma_checker:check_module(CallerSum, Pplt, #{mode => hybrid}),
    ?assertMatch([#prisma_warning{kind = gradual_mismatch, mfa = {CallerMod, bad, 0}}], Ws).

elixir_try_and_receive_return_checks_test() ->
    Mod = 'Elixir.TryRecvRet',
    Map = #{
        module => Mod,
        file => <<"lib/try_recv.ex">>,
        attributes => [],
        struct => nil,
        definitions => [
            {{cleanup, 0}, def, [{line, 1}], [
                {[{line, 1}], [], [], {'try', [{line, 1}], [[{do, wrong}, {'after', ok}]]}}
            ]},
            {{wait, 0}, def, [{line, 2}], [
                {[{line, 2}], [], [], {'receive', [{line, 2}], [[
                    {do, [{'->', [{line, 2}], [[go], wrong]}]},
                    {'after', [{'->', [{line, 2}], [[0], wrong]}]}
                ]]}}
            ]}
        ]
    },
    Specs = [
        {attribute, 1, spec, {{cleanup, 0}, [{type, 1, 'fun', [{type, 1, product, []}, {type, 1, integer, []}]}]}},
        {attribute, 2, spec, {{wait, 0}, [{type, 2, 'fun', [{type, 2, product, []}, {type, 2, integer, []}]}]}}
    ],
    Sum = prisma_elixir:from_elixir_dbgi(Mod, {debug_info_v1, elixir_erl, {elixir_v1, Map, Specs}},
        [{cleanup, 0}, {wait, 0}], #module_summary{module = Mod, language = elixir}, #{}),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Sum}},
    Ws = prisma_checker:check_module(Sum, Pplt, #{mode => hybrid}),
    ?assertEqual(2, length([W || W <- Ws, W#prisma_warning.kind =:= gradual_mismatch])).

elixir_bitstring_size_not_erlang_size_test() ->
    Mod = 'Elixir.BitSizePack',
    Map = #{
        module => Mod,
        file => <<"lib/bit_size.ex">>,
        attributes => [],
        struct => nil,
        definitions => [
            {{width, 0}, def, [{line, 1}], [{[{line, 1}], [], [], 8}]},
            {{byte, 1}, def, [{line, 2}], [
                {[{line, 2}], [{x, [{line, 2}], nil}], [],
                 {'<<>>', [{line, 2}], [
                     {'::', [{line, 2}], [
                         {x, [{line, 2}], nil},
                         {'-', [{line, 2}], [{integer, [], nil}, {size, [], [{width, [{line, 2}], []}]}]}
                     ]}
                 ]}}
            ]}
        ]
    },
    Sum = prisma_elixir:from_elixir_dbgi(Mod, {debug_info_v1, elixir_erl, {elixir_v1, Map, []}},
        [{width, 0}, {byte, 1}], #module_summary{module = Mod, language = elixir}, #{}),
    FC = maps:get({Mod, byte, 1}, Sum#module_summary.functions),
    ?assertNot(lists:member({erlang, size, 1}, FC#func_contract.calls)),
    Pplt = (prisma_pplt:new())#prisma_pplt{modules = #{Mod => Sum}},
    ?assertEqual([], prisma_checker:check_module(Sum, Pplt, #{mode => hybrid})).

mix_config_and_args_otp_apps_test() ->
    ?assertEqual(#{otp_apps => [stdlib, crypto]},
                 'Elixir.Mix.Tasks.Prisma':parse_mix_config([{otp_apps, [stdlib, crypto]}])),
    ?assertMatch(#{otp_apps := [stdlib]},
                 'Elixir.Mix.Tasks.Prisma':parse_args([<<"--otp-app">>, <<"stdlib">>])).
