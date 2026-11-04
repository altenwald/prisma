-module(prisma_lock_tests).

-include_lib("eunit/include/eunit.hrl").
-include("prisma.hrl").

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
    {ok, Deps} = prisma_lock:parse_rebar_lock(list_to_binary(RebarLockContent)),
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
    {ok, Deps} = prisma_lock:parse_mix_lock(list_to_binary(MixLockContent)),
    ?assertEqual(
        [
            #{name => <<"cowboy">>, version => <<"2.10.0">>, source => hex},
            #{name => <<"jason">>, version => <<"1.4.1">>, source => hex},
            #{name => <<"my_git">>, version => <<"9f8e7d6">>, source => git}
        ],
        Deps
    ).

resolve_and_cache_project_pplts_test() ->
    TmpProj = "/tmp/prisma_dev/tmp_lock_proj",
    TmpCache = "/tmp/prisma_dev/tmp_pplt_cache",
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

    %% First resolution builds dep_lib-1.2.3.pplt and caches it in TmpCache
    {ok, ResolvedPplt1} = prisma_lock:resolve_project_pplts(TmpProj, #{cache_dir => TmpCache}),
    ?assertEqual([dep_lib], prisma_pplt:modules(ResolvedPplt1)),
    ExpectedCachePath = prisma_lock:cache_path(TmpCache, <<"dep_lib">>, <<"1.2.3">>),
    ?assert(filelib:is_regular(ExpectedCachePath)),

    %% Delete the _build beam to prove the second resolution loads from the .pplt cache!
    ok = file:delete(filename:join(DepEbin, "dep_lib.beam")),
    {ok, ResolvedPplt2} = prisma_lock:resolve_project_pplts(TmpProj, #{cache_dir => TmpCache}),
    ?assertEqual([dep_lib], prisma_pplt:modules(ResolvedPplt2)),

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

    {ok, Warnings} = prisma:analyze_dirs([AppEbin], #{
        project_root => TmpProj,
        cache_dir => TmpCache,
        mode => hybrid
    }),
    ?assertMatch([#prisma_warning{mfa = {my_app, broken_call, 0}} | _], Warnings),

    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache).

otp_pplt_and_mix_lock_discovery_test() ->
    TmpProj = "/tmp/prisma_dev/tmp_mix_lock_proj",
    TmpCache = "/tmp/prisma_dev/tmp_pplt_cache2",
    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache),
    ok = filelib:ensure_dir(filename:join(TmpProj, "dummy")),

    ?assert(is_list(prisma_lock:default_cache_dir())),
    ?assertMatch({error, {unknown_applications, [non_existent_otp_app_xyz]}}, prisma_lock:ensure_otp_pplt([non_existent_otp_app_xyz], #{cache_dir => TmpCache})),
    {ok, OtpPlt1} = prisma_lock:ensure_otp_pplt([compiler], #{cache_dir => TmpCache}),
    %% one file for the release that runs: otp_<release>.pplt
    ?assert(filelib:is_regular(filename:join(TmpCache, "otp_" ++ erlang:system_info(otp_release) ++ ".pplt"))),
    ?assert(lists:member(compile, prisma_pplt:modules(OtpPlt1))),
    %% Second call loads from cache
    {ok, OtpPlt2} = prisma_lock:ensure_otp_pplt([compiler], #{cache_dir => TmpCache}),
    ?assertEqual(prisma_pplt:modules(OtpPlt1), prisma_pplt:modules(OtpPlt2)),

    %% Write mix.lock; the dependency has nothing built and nothing shipped: it is simply left out
    MixLockPath = filename:join(TmpProj, "mix.lock"),
    MixLockText = "%{\n  \"jason\": {:hex, :jason, \"1.4.1\", \"h1\", [:mix], [], \"hexpm\", \"h2\"}\n}\n",
    ok = file:write_file(MixLockPath, MixLockText),
    ?assertEqual([#{name => <<"jason">>, version => <<"1.4.1">>, source => hex}], prisma_lock:discover_deps(TmpProj)),
    {ok, Resolved} = prisma_lock:resolve_project_pplts(TmpProj, #{cache_dir => TmpCache}),
    ?assertEqual([], prisma_pplt:modules(Resolved)),

    %% Extra rebar.lock variants and CLI helpers
    ExtraRebar = "[{<<\"a\">>,{pkg,a,\"1.0\",[]},0},{<<\"b\">>,{git,\"u\",{branch,\"main\"}},0},{<<\"c\">>,{git,\"u\",{tag,\"v1\"}},0}].",
    {ok, ExtraDeps} = prisma_lock:parse_rebar_lock(list_to_binary(ExtraRebar)),
    ?assertEqual(3, length(ExtraDeps)),

    ?assertEqual({["a.pplt"], ["ebin"]}, prisma:parse_check_args(["--pplt", "a.pplt", "ebin"])),
    ?assert(is_list(lists:flatten(prisma_prv:format_error({warnings_found, 2})))),
    ?assert(is_list(lists:flatten(prisma_prv:format_error(custom_err)))),

    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache).

auto_separate_deps_from_project_apps_test() ->
    TmpProj = "/tmp/prisma_dev/tmp_auto_proj",
    TmpCache = "/tmp/prisma_dev/tmp_auto_cache",
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
    ProjectEbins = prisma_lock:discover_project_ebins(TmpProj, #{env => "dev"}),
    ?assertEqual([OwnEbin], ProjectEbins),

    %% analyze_project analyzes ONLY own_app against cached noisy_dep.pplt -> 0 warnings!
    {ok, Warnings} = prisma:analyze_project(TmpProj, #{cache_dir => TmpCache, env => "dev"}),
    ?assertEqual([], Warnings),

    os:cmd("rm -rf " ++ TmpProj ++ " " ++ TmpCache).

candidate_build_ebins_default_fallback_test() ->
    TmpProj = "/tmp/prisma_dev/tmp_fallback_proj",
    os:cmd("rm -rf " ++ TmpProj),
    DevEbin = filename:join([TmpProj, "_build", "dev", "lib", "my_dev_app", "ebin"]),
    ok = filelib:ensure_dir(filename:join(DevEbin, "dummy")),
    ?assertEqual([DevEbin], prisma_lock:discover_project_ebins(TmpProj, #{})),
    ?assertEqual({ok, []}, prisma:analyze_project(TmpProj)),
    os:cmd("rm -rf " ++ TmpProj).


%% A library publishes its PPLT at the root of its package (`<app>_<vsn>.pplt`, any `*.pplt` is read): `deps/<app>/*.pplt`, and
%% `_build/*/lib/<app>/*.pplt` where rebar3 puts its dependencies. It is read without its beams and without building anything.
dep_lib_beam() ->
    Forms = [
        {attribute, 1, module, dep_lib},
        {attribute, 2, export, [{fetch_count, 1}]},
        {attribute, 3, spec, {{fetch_count, 1}, [
            {type, 3, 'fun', [{type, 3, product, [{type, 3, binary, []}]}, {type, 3, non_neg_integer, []}]}
        ]}},
        {function, 4, fetch_count, 1, [
            {clause, 4, [{var, 4, 'B'}], [], [{call, 4, {atom, 4, byte_size}, [{var, 4, 'B'}]}]}
        ]}
    ],
    {ok, dep_lib, Beam} = compile:forms(Forms, [debug_info]),
    Beam.

other_lib_beam() ->
    Forms = [{attribute, 1, module, other_lib}, {attribute, 2, export, [{f, 0}]},
             {function, 3, f, 0, [{clause, 3, [], [], [{atom, 3, ok}]}]}],
    {ok, other_lib, Beam} = compile:forms(Forms, [debug_info]),
    Beam.

lock_for_dep_lib(Proj) ->
    ok = filelib:ensure_dir(filename:join(Proj, "dummy")),
    ok = file:write_file(filename:join(Proj, "rebar.lock"),
                         "{\"1.2.0\", [{<<\"dep_lib\">>, {pkg, <<\"dep_lib\">>, <<\"1.2.3\">>}, 0}]}.\n").

shipped_pplt_is_used_before_building_test_() ->
    [{atom_to_list(Where), fun() -> shipped_pplt_case(Where) end} || Where <- [rebar3_build, mix_deps]].

shipped_pplt_case(Where) ->
    Proj = "/tmp/prisma_dev/tmp_shipped_proj_" ++ atom_to_list(Where),
    os:cmd("rm -rf " ++ Proj),
    LibDir = case Where of
        rebar3_build -> filename:join([Proj, "_build", "default", "lib", "dep_lib"]);
        mix_deps -> filename:join([Proj, "deps", "dep_lib"])
    end,
    ok = filelib:ensure_dir(filename:join(LibDir, "dummy")),
    {ok, Built} = prisma_pplt:from_beams([dep_lib_beam()], #{package => <<"dep_lib">>, package_vsn => <<"1.2.3">>}),
    ok = prisma_pplt:save(Built, filename:join(LibDir, "dep_lib_1.2.3.pplt")),
    lock_for_dep_lib(Proj),
    {ok, Resolved} = prisma_lock:resolve_project_pplts(Proj, #{}),
    ?assertEqual([dep_lib], prisma_pplt:modules(Resolved)),
    %% nothing was built: nothing new in _build
    ?assertEqual([], filelib:wildcard(filename:join([Proj, "_build", "*.pplt"]))),
    os:cmd("rm -rf " ++ Proj).

a_library_may_ship_several_pplts_with_any_name_test() ->
    Proj = "/tmp/prisma_dev/tmp_shipped_many",
    os:cmd("rm -rf " ++ Proj),
    LibDir = filename:join([Proj, "deps", "dep_lib"]),
    ok = filelib:ensure_dir(filename:join(LibDir, "dummy")),
    {ok, A} = prisma_pplt:from_beams([dep_lib_beam()], #{package => <<"dep_lib">>, package_vsn => <<"1.2.3">>}),
    {ok, B} = prisma_pplt:from_beams([other_lib_beam()], #{package => <<"dep_lib">>, package_vsn => <<"1.2.3">>}),
    ok = prisma_pplt:save(A, filename:join(LibDir, "dep_lib_1.2.3.pplt")),
    ok = prisma_pplt:save(B, filename:join(LibDir, "extras.pplt")),
    lock_for_dep_lib(Proj),
    {ok, Resolved} = prisma_lock:resolve_project_pplts(Proj, #{}),
    ?assertEqual([dep_lib, other_lib], lists:sort(prisma_pplt:modules(Resolved))),
    os:cmd("rm -rf " ++ Proj).

%% `priv/` is for what ends up in a release, not for the tools that check the code: a PPLT there is not looked for.
a_pplt_in_priv_is_not_read_test() ->
    Proj = "/tmp/prisma_dev/tmp_shipped_priv",
    os:cmd("rm -rf " ++ Proj),
    Priv = filename:join([Proj, "deps", "dep_lib", "priv"]),
    ok = filelib:ensure_dir(filename:join(Priv, "dummy")),
    {ok, A} = prisma_pplt:from_beams([dep_lib_beam()], #{package => <<"dep_lib">>, package_vsn => <<"1.2.3">>}),
    ok = prisma_pplt:save(A, filename:join(Priv, "dep_lib.pplt")),
    lock_for_dep_lib(Proj),
    ?assertEqual([], prisma_lock:shipped_pplts(Proj, <<"dep_lib">>)),
    {ok, Resolved} = prisma_lock:resolve_project_pplts(Proj, #{}),
    ?assertEqual([], prisma_pplt:modules(Resolved)),
    os:cmd("rm -rf " ++ Proj).

%% What Prisma has to build is kept in `_build/`, as `<app>_<vsn>.pplt`.
a_built_dependency_is_kept_in_build_test() ->
    Proj = "/tmp/prisma_dev/tmp_project_cache",
    os:cmd("rm -rf " ++ Proj),
    Ebin = filename:join([Proj, "_build", "default", "lib", "dep_lib", "ebin"]),
    ok = filelib:ensure_dir(filename:join(Ebin, "dummy")),
    ok = file:write_file(filename:join(Ebin, "dep_lib.beam"), dep_lib_beam()),
    lock_for_dep_lib(Proj),
    {ok, Resolved} = prisma_lock:resolve_project_pplts(Proj, #{}),
    ?assertEqual([dep_lib], prisma_pplt:modules(Resolved)),
    ?assertEqual(filename:join(Proj, "_build"), prisma_lock:project_cache_dir(Proj)),
    ?assert(filelib:is_regular(filename:join([Proj, "_build", "dep_lib_1.2.3.pplt"]))),
    os:cmd("rm -rf " ++ Proj).

the_elixir_pplt_has_its_own_file_test() ->
    Dir = "/tmp/prisma_dev/tmp_elixir_cache",
    os:cmd("rm -rf " ++ Dir),
    case code:lib_dir(elixir) of
        {error, _} ->
            ?assertEqual({error, no_elixir}, prisma_lock:ensure_elixir_pplt(#{cache_dir => Dir})),
            ?assertEqual(error, prisma_lock:elixir_cache_path(Dir));
        _ ->
            {ok, Path} = prisma_lock:elixir_cache_path(Dir),
            ?assertMatch("elixir_" ++ _, filename:basename(Path))
    end,
    os:cmd("rm -rf " ++ Dir).

the_otp_pplt_of_a_project_is_kept_in_build_test() ->
    Proj = "/tmp/prisma_dev/tmp_project_otp",
    os:cmd("rm -rf " ++ Proj),
    lock_for_dep_lib(Proj),
    {ok, Resolved} = prisma_lock:resolve_project_pplts(Proj, #{otp_apps => [compiler]}),
    ?assert(lists:member(compile, prisma_pplt:modules(Resolved))),
    ?assert(filelib:is_regular(filename:join([Proj, "_build", "otp_" ++ erlang:system_info(otp_release) ++ ".pplt"]))),
    os:cmd("rm -rf " ++ Proj).

%% Whoever uses a shipped `.pplt` checks that it serves: same OTP release or one of the two before, and not stale.

write_src(Dir, Body) ->
    ok = filelib:ensure_dir(filename:join([Dir, "src", "dummy"])),
    ok = file:write_file(filename:join([Dir, "src", "dep_lib.erl"]), Body).

source_hash_follows_the_sources_test() ->
    Dir = "/tmp/prisma_dev/tmp_hash",
    os:cmd("rm -rf " ++ Dir),
    ?assertEqual(undefined, prisma_lock:source_hash(Dir)),
    write_src(Dir, "-module(dep_lib).\n"),
    H1 = prisma_lock:source_hash(Dir),
    ?assert(is_binary(H1)),
    ?assertEqual(H1, prisma_lock:source_hash(Dir)),
    write_src(Dir, "-module(dep_lib).\n-export([f/0]).\n"),
    ?assertNotEqual(H1, prisma_lock:source_hash(Dir)),
    os:cmd("rm -rf " ++ Dir).

usable_checks_the_otp_release_test() ->
    Running = list_to_integer(erlang:system_info(otp_release)),
    Pplt = fun(Rel) -> (prisma_pplt:new(<<"dep_lib">>, <<"1.2.3">>))#prisma_pplt{otp_release = integer_to_binary(Rel)} end,
    Check = fun(Rel) -> prisma_lock:usable(Pplt(Rel), "/tmp/prisma_dev/no_such_project", <<"dep_lib">>) end,
    ?assertEqual(ok, Check(Running)),
    ?assertEqual(ok, Check(Running - 2)),
    ?assertMatch({error, {otp_release, _, _}}, Check(Running - 3)),
    ?assertMatch({error, {otp_release, _, _}}, Check(Running + 1)).

usable_checks_that_the_file_is_not_stale_test() ->
    Proj = "/tmp/prisma_dev/tmp_stale",
    os:cmd("rm -rf " ++ Proj),
    write_src(filename:join([Proj, "deps", "dep_lib"]), "-module(dep_lib).\n"),
    Hash = prisma_lock:source_hash(filename:join([Proj, "deps", "dep_lib"])),
    Made = fun(H) -> (prisma_pplt:new(<<"dep_lib">>, <<"1.2.3">>))#prisma_pplt{source_hash = H} end,
    ?assertEqual(ok, prisma_lock:usable(Made(Hash), Proj, <<"dep_lib">>)),
    ?assertEqual({error, stale}, prisma_lock:usable(Made(<<"0000">>), Proj, <<"dep_lib">>)),
    %% nothing to compare with: trusted
    ?assertEqual(ok, prisma_lock:usable(Made(undefined), Proj, <<"dep_lib">>)),
    ?assertEqual(ok, prisma_lock:usable(Made(Hash), Proj, <<"another_lib">>)),
    os:cmd("rm -rf " ++ Proj).

a_stale_shipped_pplt_is_left_out_and_the_dependency_is_built_test() ->
    Proj = "/tmp/prisma_dev/tmp_stale_build",
    os:cmd("rm -rf " ++ Proj),
    LibDir = filename:join([Proj, "deps", "dep_lib"]),
    write_src(LibDir, "-module(dep_lib).\n"),
    {ok, Old} = prisma_pplt:from_beams([other_lib_beam()], #{package => <<"dep_lib">>, package_vsn => <<"1.2.3">>,
                                                            source_hash => <<"out of date">>}),
    ok = prisma_pplt:save(Old, filename:join(LibDir, "dep_lib_1.2.3.pplt")),
    Ebin = filename:join([Proj, "_build", "default", "lib", "dep_lib", "ebin"]),
    ok = filelib:ensure_dir(filename:join(Ebin, "dummy")),
    ok = file:write_file(filename:join(Ebin, "dep_lib.beam"), dep_lib_beam()),
    lock_for_dep_lib(Proj),
    {ok, Resolved} = prisma_lock:resolve_project_pplts(Proj, #{}),
    %% the stale file said `other_lib`; what is there now is `dep_lib`
    ?assertEqual([dep_lib], prisma_pplt:modules(Resolved)),
    os:cmd("rm -rf " ++ Proj).

%% `prisma build`: after compiling, the `.pplt` of each application of the project is written at the root of the package.
build_project_writes_the_pplt_at_the_root_test() ->
    Proj = "/tmp/prisma_dev/tmp_build_project",
    os:cmd("rm -rf " ++ Proj),
    Ebin = filename:join(Proj, "ebin"),
    ok = filelib:ensure_dir(filename:join(Ebin, "dummy")),
    ok = file:write_file(filename:join(Ebin, "dep_lib.beam"), dep_lib_beam()),
    ok = file:write_file(filename:join(Ebin, "dep_lib.app"),
                         "{application, dep_lib, [{vsn, \"0.3.0\"}, {modules, [dep_lib]}, {applications, [kernel, stdlib]}]}.\n"),
    write_src(Proj, "-module(dep_lib).\n"),
    %% rebar3 links the application into _build/default/lib
    ok = filelib:ensure_dir(filename:join([Proj, "_build", "default", "lib", "dummy"])),
    ok = file:make_symlink("../../..", filename:join([Proj, "_build", "default", "lib", "dep_lib"])),
    ok = file:write_file(filename:join(Proj, "dep_lib_0.2.0.pplt"), <<"an older one">>),
    {ok, [Path]} = prisma:build_project(Proj, #{}),
    ?assertEqual(filename:join(Proj, "dep_lib_0.3.0.pplt"), Path),
    ?assertNot(filelib:is_regular(filename:join(Proj, "dep_lib_0.2.0.pplt"))),
    {ok, Pplt} = prisma_pplt:load(Path),
    ?assertEqual([dep_lib], prisma_pplt:modules(Pplt)),
    ?assertEqual(prisma_lock:source_hash(Proj), Pplt#prisma_pplt.source_hash),
    ?assertEqual({error, no_compiled_applications}, prisma:build_project("/tmp/prisma_dev/no_such_project", #{})),
    os:cmd("rm -rf " ++ Proj).

building_notice_is_one_plain_line_test() ->
    Line = lists:flatten(prisma_lock:building_notice("/p/_build/otp_29.pplt", 599)),
    ?assertEqual("prisma: building otp_29.pplt (599 modules)...\n", Line),
    %% no escape sequences: nothing for NO_COLOR to switch off
    ?assertEqual(nomatch, string:find(Line, "\e")).

rebar3_message_counts_errors_and_warnings_test() ->
    ?assertEqual("Prisma found 3 error(s) and 2 warning(s)", lists:flatten(prisma_prv:format_error({problems_found, 3, 2}))).
