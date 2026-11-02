-module(spectra_lock_tests).

-include_lib("eunit/include/eunit.hrl").
-include("spectra.hrl").

parse_rebar_lock_test() ->
    RebarLockContent =
        "{\"1.2.0\",[\n"
        " {<<\"cowboy\">>,{pkg,<<\"cowboy\">>,<<\"2.10.0\">>},0},\n"
        " {<<\"cowlib\">>,{pkg,<<\"cowlib\">>,<<\"2.12.1\">>},1},\n"
        " {<<\"custom_git\">>,{git,\"https://example.com/repo.git\",{ref,\"abc1234\"}},0}\n"
        "]}.\n"
        "[\n"
        " {pkg_hash,[{<<\"cowboy\">>,<<\"deadbeef\">>}]}\n"
        "].\n",
    {ok, Deps} = spectra_lock:parse_rebar_lock(list_to_binary(RebarLockContent)),
    ?assertEqual(
        [
            #{name => <<"cowboy">>, version => <<"2.10.0">>, source => hex},
            #{name => <<"cowlib">>, version => <<"2.12.1">>, source => hex},
            #{name => <<"custom_git">>, version => <<"abc1234">>, source => git}
        ],
        Deps
    ).

parse_mix_lock_test() ->
    MixLockContent =
        "%{\n"
        "  \"cowboy\": {:hex, :cowboy, \"2.10.0\", \"hash1\", [:rebar3], [], \"hexpm\", \"hash2\"},\n"
        "  \"jason\": {:hex, :jason, \"1.4.1\", \"hash3\", [:mix], [], \"hexpm\", \"hash4\"},\n"
        "  \"my_git\": {:git, \"https://github.com/org/my_git.git\", \"9f8e7d6\", [branch: \"main\"]}\n"
        "}\n",
    {ok, Deps} = spectra_lock:parse_mix_lock(list_to_binary(MixLockContent)),
    ?assertEqual(
        [
            #{name => <<"cowboy">>, version => <<"2.10.0">>, source => hex},
            #{name => <<"jason">>, version => <<"1.4.1">>, source => hex},
            #{name => <<"my_git">>, version => <<"9f8e7d6">>, source => git}
        ],
        Deps
    ).

resolve_and_cache_project_plts_test() ->
    TmpProj = "/tmp/spectra_dev/tmp_lock_proj",
    TmpCache = "/tmp/spectra_dev/tmp_splt_cache",
    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache),

    DepEbin = filename:join([TmpProj, "_build", "default", "lib", "dep_lib", "ebin"]),
    AppEbin = filename:join([TmpProj, "_build", "default", "lib", "my_app", "ebin"]),
    ok = filelib:ensure_dir(filename:join(DepEbin, "dummy")),
    ok = filelib:ensure_dir(filename:join(AppEbin, "dummy")),

    %% Compile a dependency module into _build/default/lib/dep_lib/ebin/dep_lib.beam
    DepForms = [
        {attribute, 1, module, dep_lib},
        {attribute, 2, export, [{fetch_count, 1}]},
        {attribute, 3, spec, {{fetch_count, 1}, [
            {type, 3, 'fun', [{type, 3, product, [{type, 3, binary, []}]}, {type, 3, non_neg_integer, []}]}
        ]}},
        {function, 4, fetch_count, 1, [
            {clause, 4, [{var, 4, 'B'}], [], [{call, 4, {atom, 4, byte_size}, [{var, 4, 'B'}]}]}
        ]}
    ],
    {ok, dep_lib, DepBeam} = compile:forms(DepForms, [debug_info]),
    ok = file:write_file(filename:join(DepEbin, "dep_lib.beam"), DepBeam),

    %% Write rebar.lock referencing dep_lib 1.2.3
    LockText = "{\"1.2.0\", [{<<\"dep_lib\">>, {pkg, <<\"dep_lib\">>, <<\"1.2.3\">>}, 0}]}.\n",
    ok = file:write_file(filename:join(TmpProj, "rebar.lock"), LockText),

    %% First resolution builds dep_lib-1.2.3.splt and caches it in TmpCache
    {ok, ResolvedPlt1} = spectra_lock:resolve_project_plts(TmpProj, #{cache_dir => TmpCache}),
    ?assertEqual([dep_lib], spectra_plt:modules(ResolvedPlt1)),
    ExpectedCachePath = spectra_lock:cache_path(TmpCache, <<"dep_lib">>, <<"1.2.3">>),
    ?assert(filelib:is_regular(ExpectedCachePath)),

    %% Delete the _build beam to prove the second resolution loads from the .splt cache!
    ok = file:delete(filename:join(DepEbin, "dep_lib.beam")),
    {ok, ResolvedPlt2} = spectra_lock:resolve_project_plts(TmpProj, #{cache_dir => TmpCache}),
    ?assertEqual([dep_lib], spectra_plt:modules(ResolvedPlt2)),

    %% Compile an app module that calls dep_lib:fetch_count/1 with a wrong argument type (integer)
    AppForms = [
        {attribute, 1, module, my_app},
        {attribute, 2, export, [{broken_call, 0}]},
        {function, 3, broken_call, 0, [
            {clause, 3, [], [], [
                {call, 4, {remote, 4, {atom, 4, dep_lib}, {atom, 4, fetch_count}}, [{integer, 4, 999}]}
            ]}
        ]}
    ],
    {ok, my_app, AppBeam} = compile:forms(AppForms, [debug_info]),
    ok = file:write_file(filename:join(AppEbin, "my_app.beam"), AppBeam),

    {ok, Warnings} = spectra:analyze_dirs([AppEbin], #{
        project_root => TmpProj,
        cache_dir => TmpCache,
        mode => hybrid
    }),
    ?assertMatch([#spectra_warning{mfa = {my_app, broken_call, 0}} | _], Warnings),

    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache).

otp_plt_fetcher_and_mix_lock_discovery_test() ->
    TmpProj = "/tmp/spectra_dev/tmp_mix_lock_proj",
    TmpCache = "/tmp/spectra_dev/tmp_splt_cache2",
    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache),
    ok = filelib:ensure_dir(filename:join(TmpProj, "dummy")),

    ?assert(is_list(spectra_lock:default_cache_dir())),
    ?assertMatch({error, _}, spectra_lock:ensure_otp_plt(non_existent_otp_app_xyz, #{cache_dir => TmpCache})),
    {ok, OtpPlt1} = spectra_lock:ensure_otp_plt(compiler, #{cache_dir => TmpCache}),
    ?assert(lists:member(compile, spectra_plt:modules(OtpPlt1))),
    %% Second call loads from cache
    {ok, OtpPlt2} = spectra_lock:ensure_otp_plt(compiler, #{cache_dir => TmpCache}),
    ?assertEqual(spectra_plt:modules(OtpPlt1), spectra_plt:modules(OtpPlt2)),

    %% Write mix.lock and resolve using a custom fetcher
    MixLockPath = filename:join(TmpProj, "mix.lock"),
    MixLockText = "%{\n  \"jason\": {:hex, :jason, \"1.4.1\", \"h1\", [:mix], [], \"hexpm\", \"h2\"}\n}\n",
    ok = file:write_file(MixLockPath, MixLockText),
    ?assertEqual([#{name => <<"jason">>, version => <<"1.4.1">>, source => hex}], spectra_lock:discover_deps(TmpProj)),

    FakeJasonPlt = spectra_plt:new(<<"jason">>, <<"1.4.1">>),
    EncodedJason = spectra_plt:encode(FakeJasonPlt),
    Fetcher = fun(_OtpRel, <<"jason">>, <<"1.4.1">>) -> {ok, EncodedJason} end,

    {ok, Resolved} = spectra_lock:resolve_project_plts(TmpProj, #{
        cache_dir => TmpCache,
        fetcher => Fetcher
    }),
    ?assertMatch(#spectra_plt{}, Resolved),
    ?assert(filelib:is_regular(spectra_lock:cache_path(TmpCache, <<"jason">>, <<"1.4.1">>))),

    %% Extra rebar.lock variants and CLI helpers
    ExtraRebar = "[{<<\"a\">>,{pkg,a,\"1.0\",[]},0},{<<\"b\">>,{git,\"u\",{branch,\"main\"}},0},{<<\"c\">>,{git,\"u\",{tag,\"v1\"}},0}].",
    {ok, ExtraDeps} = spectra_lock:parse_rebar_lock(list_to_binary(ExtraRebar)),
    ?assertEqual(3, length(ExtraDeps)),

    ?assertEqual({["a.splt"], ["ebin"]}, spectra:parse_check_args(["--plt", "a.splt", "ebin"])),
    ?assert(is_list(lists:flatten(spectra_prv:format_error({warnings_found, 2})))),
    ?assert(is_list(lists:flatten(spectra_prv:format_error(custom_err)))),

    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache).

auto_separate_deps_from_project_apps_test() ->
    TmpProj = "/tmp/spectra_dev/tmp_auto_proj",
    TmpCache = "/tmp/spectra_dev/tmp_auto_cache",
    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache),

    DepEbin = filename:join([TmpProj, "_build", "dev", "lib", "noisy_dep", "ebin"]),
    OwnEbin = filename:join([TmpProj, "_build", "dev", "lib", "own_app", "ebin"]),
    ok = filelib:ensure_dir(filename:join(DepEbin, "dummy")),
    ok = filelib:ensure_dir(filename:join(OwnEbin, "dummy")),

    %% Dependency has an internal discrepancy (1 + bad_atom), which MUST NOT be reported
    %% when analyzing the project, while exporting a typed function `require_int/1`.
    DepForms = [
        {attribute, 1, module, noisy_dep},
        {attribute, 2, export, [{require_int, 1}, {internal_bug, 0}]},
        {attribute, 3, spec, {{require_int, 1}, [
            {type, 3, 'fun', [{type, 3, product, [{type, 3, integer, []}]}, {type, 3, integer, []}]}
        ]}},
        {function, 4, require_int, 1, [
            {clause, 4, [{var, 4, 'X'}], [], [{op, 4, '+', {var, 4, 'X'}, {integer, 4, 1}}]}
        ]},
        {function, 5, internal_bug, 0, [
            {clause, 5, [], [], [{op, 5, '+', {integer, 5, 1}, {atom, 5, dep_internal_error}}]}
        ]}
    ],
    {ok, noisy_dep, DepBeam} = compile:forms(DepForms, [debug_info]),
    ok = file:write_file(filename:join(DepEbin, "noisy_dep.beam"), DepBeam),

    %% Own app has a valid call to noisy_dep:require_int(42)
    OwnForms = [
        {attribute, 1, module, own_app},
        {attribute, 2, export, [{run, 0}]},
        {function, 3, run, 0, [
            {clause, 3, [], [], [
                {call, 4, {remote, 4, {atom, 4, noisy_dep}, {atom, 4, require_int}}, [{integer, 4, 42}]}
            ]}
        ]}
    ],
    {ok, own_app, OwnBeam} = compile:forms(OwnForms, [debug_info]),
    ok = file:write_file(filename:join(OwnEbin, "own_app.beam"), OwnBeam),

    MixLockText = "%{\n  \"noisy_dep\": {:hex, :noisy_dep, \"0.5.0\", \"h1\", [:mix], [], \"hexpm\", \"h2\"}\n}\n",
    ok = file:write_file(filename:join(TmpProj, "mix.lock"), MixLockText),

    %% discover_project_ebins must return ONLY own_app's ebin, excluding noisy_dep
    ProjectEbins = spectra_lock:discover_project_ebins(TmpProj, #{env => "dev"}),
    ?assertEqual([OwnEbin], ProjectEbins),

    %% analyze_project analyzes ONLY own_app against cached noisy_dep.splt -> 0 warnings!
    {ok, Warnings} = spectra:analyze_project(TmpProj, #{cache_dir => TmpCache, env => "dev"}),
    ?assertEqual([], Warnings),

    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache).

candidate_build_ebins_default_fallback_test() ->
    TmpProj = "/tmp/spectra_dev/tmp_fallback_proj",
    os:cmd("rm -rf " ++ TmpProj),
    DevEbin = filename:join([TmpProj, "_build", "dev", "lib", "my_dev_app", "ebin"]),
    ok = filelib:ensure_dir(filename:join(DevEbin, "dummy")),
    ?assertEqual([DevEbin], spectra_lock:discover_project_ebins(TmpProj, #{})),
    ?assertEqual({ok, []}, spectra:analyze_project(TmpProj)),
    os:cmd("rm -rf " ++ TmpProj).
