-module(spectra_elixir_tests).

-include_lib("eunit/include/eunit.hrl").
-include("spectra.hrl").

elixir_builtin_remote_types_test() ->
    %% String.t() -> binary(), Keyword.t(integer()) -> [{atom(), integer()}]
    StringTAst = {remote_type, 1, [{atom, 1, 'Elixir.String'}, {atom, 1, t}, []]},
    KeywordTAst = {remote_type, 1, [{atom, 1, 'Elixir.Keyword'}, {atom, 1, t}, [{type, 1, integer, []}]]},
    RangeTAst = {remote_type, 1, [{atom, 1, 'Elixir.Range'}, {atom, 1, t}, []]},

    Plt = spectra_plt:new(),
    ?assertEqual(
        {ok, {binary, 0, 8}},
        spectra_plt:resolve_type('Elixir.MyApp', spectra_type:from_abstract(StringTAst), Plt)
    ),
    ?assertEqual(
        {ok, {list, {tuple, [atom, integer]}}},
        spectra_plt:resolve_type('Elixir.MyApp', spectra_type:from_abstract(KeywordTAst), Plt)
    ),
    ?assertMatch(
        {ok, {map, [{exact, {atom_lit, '__struct__'}, {atom_lit, 'Elixir.Range'}} | _]}},
        spectra_plt:resolve_type('Elixir.MyApp', spectra_type:from_abstract(RangeTAst), Plt)
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
    Summary = spectra_elixir:from_elixir_dbgi(Mod, ElixirDbgi, Exports, #module_summary{
        module = Mod,
        language = elixir,
        exports = Exports
    }),
    ?assertEqual(elixir, Summary#module_summary.language),
    ?assert(maps:is_key({Mod, t, 0}, Summary#module_summary.types)),

    Plt = (spectra_plt:new())#spectra_plt{modules = #{Mod => Summary}},
    Warnings = spectra_checker:check_module(Summary, Plt, #{mode => hybrid}),
    WarnMFAs = [{W#spectra_warning.kind, W#spectra_warning.mfa} || W <- Warnings],
    ?assert(lists:member({gradual_mismatch, {Mod, broken_id, 1}}, WarnMFAs)),
    ?assert(lists:member({gradual_mismatch, {Mod, bad_call, 0}}, WarnMFAs)).

mix_task_ebin_resolution_test() ->
    TmpRoot = "/tmp/spectra_dev/fake_mix_proj",
    DevApp1 = filename:join([TmpRoot, "_build", "dev", "lib", "app_one", "ebin"]),
    DevApp2 = filename:join([TmpRoot, "_build", "dev", "lib", "app_two", "ebin"]),
    TestApp = filename:join([TmpRoot, "_build", "test", "lib", "app_one", "ebin"]),
    ok = filelib:ensure_dir(filename:join(DevApp1, "dummy")),
    ok = filelib:ensure_dir(filename:join(DevApp2, "dummy")),
    ok = filelib:ensure_dir(filename:join(TestApp, "dummy")),

    DevDirs = 'Elixir.Mix.Tasks.Spectra':resolve_ebin_dirs([], #{root => TmpRoot, env => "dev"}),
    ?assertEqual(lists:sort([DevApp1, DevApp2]), lists:sort(DevDirs)),

    TestDirs = 'Elixir.Mix.Tasks.Spectra':resolve_ebin_dirs([], #{root => TmpRoot, env => "test"}),
    ?assertEqual([TestApp], TestDirs),

    Parsed = 'Elixir.Mix.Tasks.Spectra':parse_args([
        <<"--mode">>, <<"gradual">>,
        <<"--env">>, <<"test">>,
        <<"--plt">>, <<"base.splt">>,
        <<"custom/ebin">>
    ]),
    ?assertEqual(gradual, maps:get(mode, Parsed)),
    ?assertEqual("test", maps:get(env, Parsed)),
    ?assertEqual(["base.splt"], maps:get(plts, Parsed)),
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
    Summary = spectra_elixir:from_elixir_dbgi(Mod, Dbgi, [{process, 2}], #module_summary{
        module = Mod,
        language = elixir,
        exports = [{process, 2}]
    }),
    ?assert(maps:is_key({Mod, t, 0}, Summary#module_summary.types)),
    ?assert(maps:is_key({Mod, process, 2}, Summary#module_summary.functions)),

    FallbackSummary = spectra_elixir:from_elixir_dbgi(Mod, invalid_dbgi, [{foo, 1}], #module_summary{
        module = Mod,
        language = elixir,
        exports = [{foo, 1}]
    }),
    ?assert(maps:is_key({Mod, foo, 1}, FallbackSummary#module_summary.functions)).

mix_task_run_and_flags_test() ->
    ?assertEqual(false, 'Elixir.Mix.Tasks.Spectra':'__mix_recompile__?'()),
    ?assertEqual(["custom/dir"], 'Elixir.Mix.Tasks.Spectra':resolve_ebin_dirs(["custom/dir"])),
    Parsed = 'Elixir.Mix.Tasks.Spectra':parse_args([<<"--mode">>, <<"discrepancy">>]),
    ?assertEqual(discrepancy, maps:get(mode, Parsed)),
    BeamFile = code:where_is_file("spectra.beam"),
    EbinDir = filename:dirname(BeamFile),
    ?assertEqual(ok, 'Elixir.Mix.Tasks.Spectra':run([list_to_binary(EbinDir)])).

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
    Summary = spectra_elixir:from_elixir_dbgi(Mod, Dbgi, [{update_response, 2}], #module_summary{
        module = Mod,
        language = elixir,
        exports = [{update_response, 2}]
    }),
    ?assert(maps:is_key({Mod, update_response, 2}, Summary#module_summary.functions)).
