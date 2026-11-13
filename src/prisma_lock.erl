%% @doc Parses `rebar.lock` and `mix.lock` files and finds the `.pplt` of each locked dependency.
%%
%% There is no server to ask. For every dependency of the lock, in this order:
%%   1. the `.pplt` files that the library ships at the root of its package, `deps/<app>/*.pplt` (Mix, any name; the
%%      convention is `<app>_<vsn>.pplt`) and `_build/*/lib/<app>/*.pplt` (where rebar3 puts the dependencies);
%%   2. the one Prisma built before, `_build/<app>_<vsn>.pplt`;
%%   3. a new one, built from the dependency's beams in `_build` and saved there.
%% The base systems have one file each: `_build/otp_<release>.pplt` and `_build/elixir_<version>.pplt`.
-module(prisma_lock).

-include("prisma.hrl").

-export([
    parse_rebar_lock/1,
    parse_mix_lock/1,
    discover_deps/1,
    default_cache_dir/0,
    project_cache_dir/1,
    shipped_pplts/2,
    source_hash/1,
    building_notice/2,
    usable/3,
    cache_path/3,
    otp_cache_path/1,
    ensure_otp_pplt/2,
    elixir_cache_path/1,
    ensure_elixir_pplt/1,
    resolve_project_pplts/2,
    discover_project_ebins/2
]).

-export_type([dep_entry/0]).

-type dep_entry() :: #{
    name := binary(),
    version := binary(),
    source := hex | git
}.

%% @doc Parses a `rebar.lock` file path or binary content.
-spec parse_rebar_lock(file:filename_all() | binary()) ->
    {ok, [dep_entry()]} | {error, term()}.
parse_rebar_lock(Input) ->
    case read_content(Input) of
        {ok, Bin} ->
            parse_rebar_terms(unicode:characters_to_list(Bin));
        {error, Reason} ->
            {error, Reason}
    end.

parse_rebar_terms(Str) ->
    case erl_scan:string(Str) of
        {ok, Tokens, _} ->
            case parse_first_term(Tokens) of
                {ok, {_Vsn, LockList}} when is_list(LockList) ->
                    Deps = lists:filtermap(fun extract_rebar_entry/1, LockList),
                    {ok, sort_deps(Deps)};
                {ok, LockList} when is_list(LockList) ->
                    Deps = lists:filtermap(fun extract_rebar_entry/1, LockList),
                    {ok, sort_deps(Deps)};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, ErrorInfo, _} ->
            {error, ErrorInfo}
    end.

parse_first_term(Tokens) ->
    FirstTermTokens = take_until_dot(Tokens, []),
    erl_parse:parse_term(FirstTermTokens).

take_until_dot([{dot, _} = Dot | _], Acc) ->
    lists:reverse([Dot | Acc]);
take_until_dot([Tok | Rest], Acc) ->
    take_until_dot(Rest, [Tok | Acc]);
take_until_dot([], Acc) ->
    lists:reverse(Acc).

extract_rebar_entry({Name, {pkg, PkgName, Vsn}, _Level}) ->
    {true, #{name => to_bin(PkgName, Name), version => to_bin(Vsn, Vsn), source => hex}};
extract_rebar_entry({Name, {pkg, PkgName, Vsn, _}, _Level}) ->
    {true, #{name => to_bin(PkgName, Name), version => to_bin(Vsn, Vsn), source => hex}};
extract_rebar_entry({Name, {pkg, PkgName, Vsn}, _Level, _Opts}) ->
    {true, #{name => to_bin(PkgName, Name), version => to_bin(Vsn, Vsn), source => hex}};
extract_rebar_entry({Name, {git, _Url, {ref, Ref}}, _Level}) ->
    {true, #{name => to_bin(Name, Name), version => to_bin(Ref, Ref), source => git}};
extract_rebar_entry({Name, {git, _Url, {branch, Branch}}, _Level}) ->
    {true, #{name => to_bin(Name, Name), version => to_bin(Branch, Branch), source => git}};
extract_rebar_entry({Name, {git, _Url, {tag, Tag}}, _Level}) ->
    {true, #{name => to_bin(Name, Name), version => to_bin(Tag, Tag), source => git}};
extract_rebar_entry(_) ->
    false.

to_bin(B, _) when is_binary(B) -> B;
to_bin(L, _) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A, _) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(_, Fallback) when is_binary(Fallback) -> Fallback.

%% @doc Parses an Elixir `mix.lock` file path or binary content.
-spec parse_mix_lock(file:filename_all() | binary()) ->
    {ok, [dep_entry()]} | {error, term()}.
parse_mix_lock(Input) ->
    case read_content(Input) of
        {ok, Bin} ->
            Lines = binary:split(Bin, [<<"\r\n">>, <<"\n">>], [global]),
            Deps = lists:filtermap(fun parse_mix_line/1, Lines),
            {ok, sort_deps(Deps)};
        {error, Reason} ->
            {error, Reason}
    end.

parse_mix_line(Line) ->
    HexPattern = "^\\s*\"([^\"]+)\"\\s*:\\s*\\{:hex,\\s*:([a-zA-Z0-9_]+),\\s*\"([^\"]+)\"",
    GitPattern = "^\\s*\"([^\"]+)\"\\s*:\\s*\\{:git,\\s*\"[^\"]+\",\\s*\"([^\"]+)\"",
    case re:run(Line, HexPattern, [{capture, [1, 2, 3], binary}]) of
        {match, [_Key, Pkg, Vsn]} ->
            {true, #{name => Pkg, version => Vsn, source => hex}};
        nomatch ->
            case re:run(Line, GitPattern, [{capture, [1, 2], binary}]) of
                {match, [Name, Ref]} ->
                    {true, #{name => Name, version => Ref, source => git}};
                nomatch ->
                    false
            end
    end.

%% @doc Discovers locked dependencies from `rebar.lock` and/or `mix.lock` in `ProjectRoot`.
-spec discover_deps(file:filename_all()) -> [dep_entry()].
discover_deps(ProjectRoot) ->
    Root = unicode:characters_to_list(ProjectRoot),
    RebarLock = filename:join(Root, "rebar.lock"),
    MixLock = filename:join(Root, "mix.lock"),
    RebarDeps = case filelib:is_regular(RebarLock) of
        true ->
            case parse_rebar_lock(RebarLock) of
                {ok, D1} -> D1;
                _ -> []
            end;
        false ->
            []
    end,
    MixDeps = case filelib:is_regular(MixLock) of
        true ->
            case parse_mix_lock(MixLock) of
                {ok, D2} -> D2;
                _ -> []
            end;
        false ->
            []
    end,
    sort_deps(RebarDeps ++ MixDeps).

%% @doc Returns the default directory for storing cached `.pplt` files.
-spec default_cache_dir() -> string().
default_cache_dir() ->
    case os:getenv("PRISMA_CACHE_DIR") of
        false -> filename:basedir(user_cache, "prisma");
        EnvDir -> EnvDir
    end.

%% @doc The `.pplt` of a package and version that Prisma builds: `<dir>/<name>_<version>.pplt`.
-spec cache_path(file:filename_all(), binary(), binary()) -> string().
cache_path(CacheDir, Name, Version) ->
    FileName = binary_to_list(<<Name/binary, "_", Version/binary, ".pplt">>),
    filename:join(unicode:characters_to_list(CacheDir), FileName).

%% @doc Where what Prisma builds is kept: the `_build` directory of the project, next to `rebar.lock` / `mix.lock`.
-spec project_cache_dir(file:filename_all()) -> string().
project_cache_dir(ProjectRoot) ->
    filename:join(unicode:characters_to_list(ProjectRoot), "_build").

%% @doc The `.pplt` files that a library ships at the root of its package: `deps/<app>/*.pplt`, and `_build/*/lib/<app>/*.pplt`
%% (where rebar3 puts its dependencies). `priv/` is not used: it is for what ends up in a release, not for checking tools.
-spec shipped_pplts(file:filename_all(), binary()) -> [string()].
shipped_pplts(ProjectRoot, Name) ->
    Root = unicode:characters_to_list(ProjectRoot),
    App = binary_to_list(Name),
    Found = filelib:wildcard(filename:join([Root, "deps", App, "*.pplt"])) ++
            filelib:wildcard(filename:join([Root, "_build", "*", "lib", App, "*.pplt"])),
    lists:usort([F || F <- Found, filelib:is_regular(F)]).

%% @doc The line that tells, on stderr, that a PPLT is being built (the first `check` of a project may build several and would
%% look hung): plain text, no colors and no progress bar, so `NO_COLOR`, CI logs and the JSON on stdout are not affected.
-spec building_notice(file:filename_all(), non_neg_integer()) -> iolist().
building_notice(Path, Modules) ->
    io_lib:format("prisma: building ~ts (~B modules)...~n", [filename:basename(unicode:characters_to_list(Path)), Modules]).

notice(Path, Modules) ->
    io:put_chars(standard_error, building_notice(Path, Modules)).

%% @doc A hash of the sources of an application directory (`src/**/*.erl|hrl`, `include/**/*.hrl`, `lib/**/*.ex`, by relative path),
%% or `undefined` if it has none. It goes into the `.pplt` when it is made, and tells whoever uses it that the file no longer matches the
%% code. The beams cannot be compared: a dependency is compiled again by whoever uses it, and the beam of the same source is not the same
%% with another compiler.
-spec source_hash(file:filename_all()) -> binary() | undefined.
source_hash(AppDir) ->
    Dir = unicode:characters_to_list(AppDir),
    Files = lists:sort(
        filelib:wildcard("src/**/*.{erl,hrl}", Dir) ++
        filelib:wildcard("include/**/*.hrl", Dir) ++
        filelib:wildcard("lib/**/*.ex", Dir)
    ),
    case Files of
        [] ->
            undefined;
        _ ->
            Parts = [[Rel, 0, case file:read_file(filename:join(Dir, Rel)) of {ok, B} -> B; _ -> <<>> end, 0] || Rel <- Files],
            binary:encode_hex(erlang:md5(iolist_to_binary(Parts)), lowercase)
    end.

%% @doc Whether a `.pplt` shipped with a dependency can be trusted for the Erlang that is running and for the code that is there:
%%   * made with the same OTP release, or one of the two before (the beams of a library cannot be loaded from a newer one, nor from
%%     one more than two releases older: a `.pplt` outside that window is too old or too new);
%%   * not stale: if the sources of the dependency are on disk, their hash is the one in the file.
%% `ok`, or `{error, Reason}` with the reason to tell the user.
-spec usable(#prisma_pplt{}, file:filename_all(), binary()) -> ok | {error, term()}.
usable(#prisma_pplt{otp_release = Made, source_hash = Hash}, ProjectRoot, Name) ->
    case otp_in_window(Made) of
        false ->
            {error, {otp_release, binary_to_list(Made), erlang:system_info(otp_release)}};
        true ->
            case current_source_hash(ProjectRoot, Name) of
                undefined -> ok;
                _ when Hash =:= undefined -> ok;
                Hash -> ok;
                _Other -> {error, stale}
            end
    end.

otp_in_window(Made) ->
    try
        Running = list_to_integer(erlang:system_info(otp_release)),
        M = binary_to_integer(Made),
        M =< Running andalso Running - M =< 2
    catch
        _:_ -> true
    end.

current_source_hash(ProjectRoot, Name) ->
    Root = unicode:characters_to_list(ProjectRoot),
    App = binary_to_list(Name),
    Dirs = filelib:wildcard(filename:join([Root, "deps", App])) ++ filelib:wildcard(filename:join([Root, "_build", "*", "lib", App])),
    case [H || D <- Dirs, H <- [source_hash(D)], H =/= undefined] of
        [First | _] -> First;
        [] -> undefined
    end.

%% @doc `<dir>/otp_<release>.pplt`: the PPLT of the OTP applications, one file for the release that is running.
-spec otp_cache_path(file:filename_all()) -> string().
otp_cache_path(CacheDir) ->
    filename:join(unicode:characters_to_list(CacheDir), "otp_" ++ erlang:system_info(otp_release) ++ ".pplt").

%% @doc Loads the PPLT of OTP, or builds it from the beams of the applications and saves it. The applications are
%% `otp_apps`; a file that is already there is used as it is. Analysing a project adds it only if `otp_apps` is given.
-spec ensure_otp_pplt([atom()], map()) -> {ok, #prisma_pplt{}} | {error, term()}.
ensure_otp_pplt(OtpApps, Opts) ->
    CacheDir = maps:get(cache_dir, Opts, default_cache_dir()),
    Path = otp_cache_path(CacheDir),
    case filelib:is_regular(Path) of
        true ->
            prisma_pplt:load(Path);
        false ->
            build_system_pplt(OtpApps, Path, <<"otp">>, list_to_binary(erlang:system_info(otp_release)))
    end.

%% @doc `<dir>/elixir_<version>.pplt`, for the Elixir that is running (none if there is no Elixir).
-spec elixir_cache_path(file:filename_all()) -> {ok, string()} | error.
elixir_cache_path(CacheDir) ->
    case elixir_version() of
        {ok, Vsn} -> {ok, filename:join(unicode:characters_to_list(CacheDir), "elixir_" ++ Vsn ++ ".pplt")};
        error -> error
    end.

%% @doc Loads the PPLT of Elixir, or builds it from the beams of the `elixir` application and saves it.
-spec ensure_elixir_pplt(map()) -> {ok, #prisma_pplt{}} | {error, term()}.
ensure_elixir_pplt(Opts) ->
    CacheDir = maps:get(cache_dir, Opts, default_cache_dir()),
    case elixir_cache_path(CacheDir) of
        error ->
            case lists:sort(filelib:wildcard(filename:join(unicode:characters_to_list(CacheDir), "elixir_*.pplt"))) of
                [Cached | _] -> prisma_pplt:load(Cached);
                [] -> {error, no_elixir}
            end;
        {ok, Path} ->
            case filelib:is_regular(Path) of
                true ->
                    prisma_pplt:load(Path);
                false ->
                    {ok, Vsn} = elixir_version(),
                    build_system_pplt([elixir], Path, <<"elixir">>, list_to_binary(Vsn))
            end
    end.

elixir_version() ->
    case application:get_key(elixir, vsn) of
        {ok, Vsn} ->
            {ok, Vsn};
        undefined ->
            case code:lib_dir(elixir) of
                {error, _} ->
                    error;
                Dir ->
                    case file:consult(filename:join([Dir, "ebin", "elixir.app"])) of
                        {ok, [{application, elixir, Props}]} -> {ok, proplists:get_value(vsn, Props, "unknown")};
                        _ -> error
                    end
            end
    end.

build_system_pplt(Apps, Path, Package, Vsn) ->
    Dirs = [{App, code:lib_dir(App)} || App <- Apps],
    case [App || {App, {error, _}} <- Dirs] of
        [] ->
            Beams = lists:append([filelib:wildcard(filename:join([Dir, "ebin", "*.beam"])) || {_, Dir} <- Dirs]),
            notice(Path, length(Beams)),
            case prisma_pplt:from_beams(Beams, #{package => Package, package_vsn => Vsn}) of
                {ok, Pplt} ->
                    _ = prisma_pplt:save(Pplt, Path),
                    {ok, Pplt};
                Error ->
                    Error
            end;
        Missing ->
            {error, {unknown_applications, Missing}}
    end.

%% @doc Resolves, builds/fetches, caches, and merges `.pplt` files for a project's locked dependencies.
-spec resolve_project_pplts(file:filename_all(), map()) ->
    {ok, #prisma_pplt{}} | {error, term()}.
resolve_project_pplts(ProjectRoot, Opts) ->
    CacheDir = maps:get(cache_dir, Opts, project_cache_dir(ProjectRoot)),
    SysOpts = Opts#{cache_dir => CacheDir},
    Deps = discover_deps(ProjectRoot),
    OtpApps = maps:get(otp_apps, Opts, []),
    Otp = case OtpApps of
        [] -> [];
        _ -> [P || {ok, P} <- [ensure_otp_pplt(OtpApps, SysOpts)]]
    end,
    ElixirFlag = case maps:find(elixir, Opts) of
        {ok, Val} -> Val;
        error -> filelib:is_regular(filename:join(unicode:characters_to_list(ProjectRoot), "mix.exs"))
    end,
    Elixir = case ElixirFlag of
        true -> [P || {ok, P} <- [ensure_elixir_pplt(SysOpts)]];
        false -> []
    end,
    DepPplts = lists:append(
        [resolve_single_dep(ProjectRoot, CacheDir, Name, Vsn) || #{name := Name, version := Vsn} <- Deps]
    ),
    {ok, prisma_pplt:merge(Otp ++ Elixir ++ DepPplts)}.

resolve_single_dep(ProjectRoot, CacheDir, Name, Vsn) ->
    case usable_shipped(ProjectRoot, Name) of
        [_ | _] = Shipped ->
            Shipped;
        [] ->
            Path = cache_path(CacheDir, Name, Vsn),
            Result = case filelib:is_regular(Path) of
                true -> prisma_pplt:load(Path);
                false -> build_and_cache_local_dep(ProjectRoot, Path, Name, Vsn)
            end,
            [P || {ok, P} <- [Result]]
    end.

%% The shipped files that load and are usable; one that is not is left out, with the reason, and the dependency is built from its beams.
usable_shipped(ProjectRoot, Name) ->
    lists:filtermap(
        fun(File) ->
            case prisma_pplt:load(File) of
                {ok, Pplt} ->
                    case usable(Pplt, ProjectRoot, Name) of
                        ok ->
                            {true, Pplt};
                        {error, Why} ->
                            io:format(standard_error, "prisma: ignoring ~ts: ~ts~n", [File, why(Why)]),
                            false
                    end;
                {error, Why} ->
                    io:format(standard_error, "prisma: ignoring ~ts: ~p~n", [File, Why]),
                    false
            end
        end,
        shipped_pplts(ProjectRoot, Name)
    ).

why(stale) -> "it does not match the sources of the dependency (it is out of date)";
why({otp_release, Made, Running}) ->
    io_lib:format("it was made with OTP ~s and this is OTP ~s (only the same release or the two before are used)", [Made, Running]).

build_and_cache_local_dep(ProjectRoot, CachePath, Name, Vsn) ->
    Root = unicode:characters_to_list(ProjectRoot),
    NameStr = binary_to_list(Name),
    Pattern = filename:join([Root, "_build", "*", "lib", NameStr, "ebin", "*.beam"]),
    case filelib:wildcard(Pattern) of
        [] ->
            error;
        Beams ->
            notice(CachePath, length(Beams)),
            case prisma_pplt:from_beams(Beams, #{package => Name, package_vsn => Vsn}) of
                {ok, Pplt} ->
                    _ = prisma_pplt:save(Pplt, CachePath),
                    {ok, Pplt};
                _ ->
                    error
            end
    end.

read_content(Bin) when is_binary(Bin) ->
    case is_lock_content(Bin) of
        true -> {ok, Bin};
        false -> file:read_file(unicode:characters_to_list(Bin))
    end;
read_content(Path) when is_list(Path) ->
    file:read_file(Path).

is_lock_content(<<"%{", _/binary>>) -> true;
is_lock_content(<<"{", _/binary>>) -> true;
is_lock_content(<<"[", _/binary>>) -> true;
is_lock_content(_) -> false.

sort_deps(Deps) ->
    ByName = maps:from_list([{maps:get(name, D), D} || D <- Deps]),
    [maps:get(K, ByName) || K <- lists:sort(maps:keys(ByName))].

%% @doc Discovers `_build/<env>/lib/<app>/ebin` directories belonging to the project itself,
%% excluding all external dependencies listed in `rebar.lock` or `mix.lock`.
-spec discover_project_ebins(file:filename_all(), map()) -> [string()].
discover_project_ebins(ProjectRoot, Opts) ->
    Root = unicode:characters_to_list(ProjectRoot),
    Deps = discover_deps(Root),
    LockDepNames = maps:from_list([{binary_to_list(Name), true} || #{name := Name} <- Deps]),
    DirDepNames = maps:from_list([{filename:basename(D), true} || D <- filelib:wildcard(filename:join([Root, "deps", "*"]))]),
    DepNames = maps:merge(LockDepNames, DirDepNames),
    CandidateEbins = candidate_build_ebins(Root, Opts),
    ProjectApp = detect_project_app_name(Root),
    lists:filter(
        fun(EbinPath) ->
            AppDir = filename:dirname(EbinPath),
            AppName = filename:basename(AppDir),
            case ProjectApp of
                {ok, PApp} -> AppName =:= PApp;
                undefined -> not maps:is_key(AppName, DepNames)
            end
        end,
        CandidateEbins
    ).

detect_project_app_name(Root) ->
    MixExs = filename:join(Root, "mix.exs"),
    case file:read_file(MixExs) of
        {ok, Bin} ->
            case re:run(Bin, "app:\\s*:([a-zA-Z0-9_]+)", [{capture, [1], list}]) of
                {match, [AppName]} -> {ok, AppName};
                nomatch -> undefined
            end;
        _ ->
            case filelib:wildcard(filename:join([Root, "src", "*.app.src"])) of
                [AppSrc | _] ->
                    {ok, filename:basename(AppSrc, ".app.src")};
                [] ->
                    undefined
            end
    end.

candidate_build_ebins(Root, Opts) ->
    case maps:find(env, Opts) of
        {ok, Env} ->
            EnvStr = unicode:characters_to_list(Env),
            EnvDirs = filelib:wildcard(filename:join([Root, "_build", EnvStr, "lib", "*", "ebin"])),
            case EnvDirs of
                [_ | _] -> EnvDirs;
                [] -> filelib:wildcard(filename:join([Root, "_build", "*", "lib", "*", "ebin"]))
            end;
        error ->
            DefaultDirs = filelib:wildcard(filename:join([Root, "_build", "default", "lib", "*", "ebin"])),
            case DefaultDirs of
                [_ | _] ->
                    DefaultDirs;
                [] ->
                    DevDirs = filelib:wildcard(filename:join([Root, "_build", "dev", "lib", "*", "ebin"])),
                    case DevDirs of
                        [_ | _] -> DevDirs;
                        [] -> filelib:wildcard(filename:join([Root, "_build", "*", "lib", "*", "ebin"]))
                    end
            end
    end.
