-module(prisma_tests).

-include_lib("eunit/include/eunit.hrl").
-include("prisma.hrl").

extract_and_portable_plt_test() ->
    ?assertEqual(<<"0.1.0">>, prisma:version()),
    BeamFile = code:where_is_file("prisma.beam"),
    ?assert(is_list(BeamFile)),
    EbinDir = filename:dirname(BeamFile),

    {ok, Summary} = prisma_abstract:extract_beam(list_to_binary(BeamFile)),
    ?assertEqual(prisma, Summary#module_summary.module),
    ?assertEqual(erlang, Summary#module_summary.language),
    ?assertMatch({error, _}, prisma_abstract:extract_beam("/nonexistent/file.beam")),

    EmptyPlt = prisma_plt:new(),
    ?assertEqual([], prisma_plt:modules(EmptyPlt)),
    ?assertEqual(EmptyPlt, prisma_plt:merge([])),

    {ok, DirPlt} = prisma_plt:from_dir(EbinDir),
    ?assert( lists:member(prisma, prisma_plt:modules(DirPlt)) ),

    {ok, BeamsPlt} = prisma_plt:from_beams([BeamFile]),
    ?assertEqual([prisma], prisma_plt:modules(BeamsPlt)),
    ?assertMatch({error, {beam_extract_failed, _, _}}, prisma_plt:from_beams(["/bad.beam", BeamFile])),

    TmpPltFile = "/tmp/prisma_dev/test_out.splt",
    {ok, BuiltPlt} = prisma:build_plt([EbinDir], TmpPltFile),
    ?assert(lists:member(prisma, prisma_plt:modules(BuiltPlt))),
    ?assertMatch({ok, []}, prisma:analyze_dirs([EbinDir], #{plts => [TmpPltFile]})),
    ?assertMatch({ok, []}, prisma:analyze_dirs([BeamFile])),
    file:delete(TmpPltFile),

    ?assertMatch({error, _}, prisma_plt:load("/nonexistent.splt")),
    ?assertEqual({error, invalid_plt_magic}, prisma_plt:decode(<<"bad">>)),
    BadRecordBin = <<?PRISMA_PLT_MAGIC, (term_to_binary({not_a_plt}))/binary>>,
    ?assertEqual({error, invalid_plt_record}, prisma_plt:decode(BadRecordBin)).

elixir_module_detection_test() ->
    MixBeam = code:where_is_file("Elixir.Mix.Tasks.Prisma.beam"),
    ?assert(is_list(MixBeam)),
    {ok, Summary} = prisma_abstract:extract_beam(MixBeam),
    ?assertEqual('Elixir.Mix.Tasks.Prisma', Summary#module_summary.module),
    ?assertEqual(elixir, Summary#module_summary.language),
    ?assertEqual(elixir, prisma_abstract:detect_language(foo, {debug_info_v1, elixir_erl, none})),
    ?assertEqual(erlang, prisma_abstract:detect_language(foo, missing_chunk)).

gradual_spec_and_checker_compatibility_test() ->
    Forms = [
        {attribute, 1, module, sample_specs},
        {attribute, 2, export, [
            {broken, 0},
            {valid_bounded, 1},
            {ret_float, 0},
            {ret_range, 0},
            {ret_list, 0},
            {ret_nonempty_list, 0},
            {ret_map, 0},
            {ret_tuple, 0},
            {ret_union, 0}
        ]},
        {attribute, 3, spec, {{broken, 0}, [
            {type, 3, 'fun', [{type, 3, product, []}, {type, 3, integer, []}]}
        ]}},
        {attribute, 4, spec, {{valid_bounded, 1}, [
            {type, 4, bounded_fun, [
                {type, 4, 'fun', [{type, 4, product, [{var, 4, 'R'}]}, {var, 4, 'R'}]},
                [{type, 4, constraint, [{atom, 4, is_subtype}, [{var, 4, 'R'}, {type, 4, pos_integer, []}]]}]
            ]}
        ]}},
        {attribute, 5, spec, {{ret_float, 0}, [
            {type, 5, 'fun', [{type, 5, product, []}, {type, 5, number, []}]}
        ]}},
        {attribute, 6, spec, {{ret_range, 0}, [
            {type, 6, 'fun', [{type, 6, product, []}, {type, 6, range, [{integer, 6, 1}, {integer, 6, 10}]}]}
        ]}},
        {attribute, 7, spec, {{ret_list, 0}, [
            {type, 7, 'fun', [{type, 7, product, []}, {type, 7, list, [{type, 7, integer, []}]}]}
        ]}},
        {attribute, 8, spec, {{ret_nonempty_list, 0}, [
            {type, 8, 'fun', [{type, 8, product, []}, {type, 8, list, [{type, 8, integer, []}]}]}
        ]}},
        {attribute, 9, spec, {{ret_map, 0}, [
            {type, 9, 'fun', [{type, 9, product, []}, {type, 9, map, any}]}
        ]}},
        {attribute, 10, spec, {{ret_tuple, 0}, [
            {type, 10, 'fun', [{type, 10, product, []}, {type, 10, tuple, [{atom, 10, ok}, {type, 10, boolean, []}]}]}
        ]}},
        {attribute, 11, spec, {{ret_union, 0}, [
            {type, 11, 'fun', [{type, 11, product, []}, {type, 11, union, [{atom, 11, ok}, {atom, 11, error}]}]}
        ]}},
        {function, 12, broken, 0, [
            {clause, 12, [], [], [{atom, 12, not_an_integer}]}
        ]},
        {function, 13, valid_bounded, 1, [
            {clause, 13, [{var, 13, '_X'}], [], [{integer, 13, 10}]}
        ]},
        {function, 14, ret_float, 0, [
            {clause, 14, [], [], [{float, 14, 3.14}]}
        ]},
        {function, 15, ret_range, 0, [
            {clause, 15, [], [], [{integer, 15, 5}]}
        ]},
        {function, 16, ret_list, 0, [
            {clause, 16, [], [], [{nil, 16}]}
        ]},
        {function, 17, ret_nonempty_list, 0, [
            {clause, 17, [], [], [{cons, 17, {integer, 17, 1}, {nil, 17}}]}
        ]},
        {function, 18, ret_map, 0, [
            {clause, 18, [], [], [{map, 18, []}]}
        ]},
        {function, 19, ret_tuple, 0, [
            {clause, 19, [], [], [{tuple, 19, [{atom, 19, ok}, {atom, 19, true}]}]}
        ]},
        {function, 20, ret_union, 0, [
            {clause, 20, [], [], [{atom, 20, ok}]}
        ]}
    ],
    {ok, sample_specs, BeamBin} = compile:forms(Forms, [debug_info]),
    {ok, Warnings} = prisma:analyze_beams([BeamBin], #{}),
    ?assertMatch([#prisma_warning{kind = gradual_mismatch, mfa = {sample_specs, broken, 0}}], Warnings),
    Formatted = prisma_checker:format_warning(hd(Warnings)),
    ?assert(is_binary(Formatted)),

    {ok, Summary} = prisma_abstract:extract_beam(BeamBin),
    ?assertEqual([], prisma_checker:check_module(Summary, prisma_plt:new(), #{mode => discrepancy})),
    ?assertMatch([_], prisma_checker:check_module(Summary, prisma_plt:new())).

warning_formats_human_oneline_json_and_color_test() ->
    W1 = #prisma_warning{
        kind = gradual_mismatch,
        mfa = {'Elixir.Dymmer.Trace', trace, 3},
        line = 53,
        message = <<"Call to Dymmer.Trace:trace/3: arg #2 of type integer is not a gradual subtype of pos_integer">>,
        callee = {'Elixir.Dymmer.Trace', trace, 3},
        arg_idx = 2,
        expected = pos_integer,
        actual = integer,
        file = "/Users/manuel/dymmer/lib/trace.ex"
    },
    W2 = #prisma_warning{
        kind = gradual_mismatch,
        mfa = {'Elixir.DymmerWeb.Api', create, 2},
        line = 39,
        message = <<"Gradual spec mismatch">>,
        declared = {union, [{atom_lit, ok}, {atom_lit, error}]},
        actual = {tuple, [{atom_lit, error}, {binary, 0, 8}]}
    },

    %% Human without color
    HumanNoColor = prisma_checker:format_warnings([W1, W2], #{format => human, color => never}),
    ?assertNot(binary:match(HumanNoColor, <<"\e[">>) =/= nomatch),
    ?assert(binary:match(HumanNoColor, <<"Dymmer.Trace:trace/3 (line 53)">>) =/= nomatch),
    ?assert(binary:match(HumanNoColor, <<"/Users/manuel/dymmer/lib/trace.ex:53">>) =/= nomatch),
    ?assert(binary:match(HumanNoColor, <<"Expected:  pos_integer()">>) =/= nomatch),
    ?assert(binary:match(HumanNoColor, <<"Actual:    integer()">>) =/= nomatch),
    ?assert(binary:match(HumanNoColor, <<"Declared:  :ok | :error">>) =/= nomatch),

    %% Human with color
    HumanColor = prisma_checker:format_warnings([W1], #{format => human, color => always}),
    ?assert(binary:match(HumanColor, <<"\e[">>) =/= nomatch),
    ?assert(binary:match(HumanColor, <<"\e[2m\e[90m/Users/manuel/dymmer/lib/trace.ex:53\e[0m">>) =/= nomatch),

    %% Oneline
    OneLine = prisma_checker:format_warnings([W1, W2], #{format => oneline, color => never}),
    ?assert(binary:match(OneLine, <<"/Users/manuel/dymmer/lib/trace.ex:53: [gradual_mismatch] Dymmer.Trace:trace/3:">>) =/= nomatch),
    ?assert(binary:match(OneLine, <<"DymmerWeb.Api:39: [gradual_mismatch] DymmerWeb.Api:create/2:">>) =/= nomatch),

    %% JSON
    JsonBin = prisma_checker:format_warnings([W1, W2], #{format => json}),
    ?assert(binary:match(JsonBin, <<"\"kind\": \"gradual_mismatch\"">>) =/= nomatch),
    ?assert(binary:match(JsonBin, <<"\"module\": \"Dymmer.Trace\"">>) =/= nomatch),
    ?assert(binary:match(JsonBin, <<"\"file\": \"/Users/manuel/dymmer/lib/trace.ex\"">>) =/= nomatch),
    ?assert(binary:match(JsonBin, <<"\"expected\": \"pos_integer()\"">>) =/= nomatch),
    ?assert(binary:match(JsonBin, <<"\"actual\": \"integer()\"">>) =/= nomatch),

    %% CLI check options parsing
    ParsedOpts = prisma:parse_check_opts(["--format", "json", "--no-color", "--plt", "test.splt", "my_ebin"]),
    ?assertEqual(json, maps:get(format, ParsedOpts)),
    ?assertEqual(never, maps:get(color, ParsedOpts)),
    ?assertEqual(["test.splt"], maps:get(plts, ParsedOpts)),
    ?assertEqual(["my_ebin"], maps:get(targets, ParsedOpts)),

    %% Mix task parsing
    MixOpts = 'Elixir.Mix.Tasks.Prisma':parse_args([<<"--format">>, <<"oneline">>, <<"--no-color">>, <<"--mode">>, <<"gradual">>, <<"--plt">>, <<"extra.splt">>]),
    ?assertEqual(oneline, maps:get(format, MixOpts)),
    ?assertEqual(never, maps:get(color, MixOpts)),
    ?assertEqual(gradual, maps:get(mode, MixOpts)),
    ?assertEqual(["extra.splt"], maps:get(plts, MixOpts)),

    MixConfig = 'Elixir.Mix.Tasks.Prisma':parse_mix_config([
        {mode, gradual},
        {format, json},
        {oxbow, false},
        {color, never},
        {plts, [<<"mix.splt">>]}
    ]),
    ?assertEqual(gradual, maps:get(mode, MixConfig)),
    ?assertEqual(json, maps:get(format, MixConfig)),
    ?assertEqual(false, maps:get(oxbow, MixConfig)),
    ?assertEqual(never, maps:get(color, MixConfig)),
    ?assertEqual(["mix.splt"], maps:get(plts, MixConfig)),

    Attrs = 'Elixir.Mix.Tasks.Prisma':'__info__'(attributes),
    ?assert(lists:member({behaviour, ['Elixir.Mix.Task']}, Attrs)),
    ?assertMatch({shortdoc, [_]}, lists:keyfind(shortdoc, 1, Attrs)),
    ?assertEqual(false, 'Elixir.Mix.Tasks.Prisma':'__mix_recompile__?'()),

    %% Rebar3 provider parsing & formatting
    RebarCli = prisma_prv:parse_cli_args([
        {format, "oneline"},
        {format, json},
        {mode, "discrepancy"},
        {mode, gradual},
        {no_color, true},
        {color, true},
        no_color,
        color,
        {no_oxbow, true},
        {oxbow, true},
        no_oxbow,
        oxbow,
        {plt, "rebar.splt"},
        {plt, <<"rebar2.splt">>}
    ]),
    ?assertEqual(json, maps:get(format, RebarCli)),
    ?assertEqual(gradual, maps:get(mode, RebarCli)),
    ?assertEqual(always, maps:get(color, RebarCli)),
    ?assertEqual(true, maps:get(oxbow, RebarCli)),
    ?assertEqual(["rebar.splt", "rebar2.splt"], maps:get(plts, RebarCli)),

    RebarConfig = prisma_prv:parse_config_opts([
        {format, json},
        {format, "human"},
        {mode, gradual},
        {mode, "hybrid"},
        {color, always},
        {oxbow, true},
        {plts, ["cfg.splt"]},
        {plt, "extra_cfg.splt"}
    ]),
    ?assertEqual(human, maps:get(format, RebarConfig)),
    ?assertEqual(hybrid, maps:get(mode, RebarConfig)),
    ?assertEqual(always, maps:get(color, RebarConfig)),
    ?assertEqual(true, maps:get(oxbow, RebarConfig)),
    ?assertEqual(["cfg.splt", "extra_cfg.splt"], maps:get(plts, RebarConfig)),

    ?assert(is_list(prisma_prv:format_error({warnings_found, 4}))),
    ?assert(is_list(prisma_prv:format_error(some_failure))),
    case code:ensure_loaded(rebar_state) of
        {module, rebar_state} ->
            State0 = case erlang:function_exported(rebar_state, new, 0) of
                true -> rebar_state:new();
                false ->
                    case erlang:function_exported(rebar_state, new, 1) of
                        true -> rebar_state:new([]);
                        false -> rebar_state:new([], [], ".")
                    end
            end,
            ?assertMatch({ok, _}, prisma_prv:init(State0)),
            ?assertMatch({ok, _}, prisma_prv:do(State0));
        _ ->
            ?assertEqual({ok, dummy_state}, prisma_prv:init(dummy_state))
    end.
