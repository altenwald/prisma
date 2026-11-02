%% @doc Parses `rebar.lock` and `mix.lock` files and manages the local `.splt` cache.
%%
%% Resolves locked dependencies and OTP base applications into cached `.splt`
%% files indexed by OTP release, package name, and version.
-module(spectra_lock).

-include("spectra.hrl").

-export([
    parse_rebar_lock/1,
    parse_mix_lock/1,
    discover_deps/1,
    default_cache_dir/0,
    cache_path/3,
    otp_cache_path/2,
    ensure_otp_plt/2,
    resolve_project_plts/2,
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

%% @doc Returns the default directory for storing cached `.splt` files.
-spec default_cache_dir() -> string().
default_cache_dir() ->
    case os:getenv("SPECTRA_CACHE_DIR") of
        false -> filename:basedir(user_cache, "spectra");
        EnvDir -> EnvDir
    end.

%% @doc Returns the `.splt` cache file path for a package and version on the current OTP release.
-spec cache_path(file:filename_all(), binary(), binary()) -> string().
cache_path(CacheDir, Name, Version) ->
    OtpRel = erlang:system_info(otp_release),
    FileName = binary_to_list(<<Name/binary, "-", Version/binary, ".splt">>),
    filename:join([unicode:characters_to_list(CacheDir), "otp-" ++ OtpRel, "hex", FileName]).

%% @doc Returns the `.splt` cache file path for an OTP application on the current OTP release.
-spec otp_cache_path(file:filename_all(), atom()) -> string().
otp_cache_path(CacheDir, OtpApp) ->
    OtpRel = erlang:system_info(otp_release),
    FileName = atom_to_list(OtpApp) ++ ".splt",
    filename:join([unicode:characters_to_list(CacheDir), "otp-" ++ OtpRel, "otp", FileName]).

%% @doc Loads or builds and caches the `.splt` for an OTP application (e.g. `stdlib`).
-spec ensure_otp_plt(atom(), map()) -> {ok, #spectra_plt{}} | {error, term()}.
ensure_otp_plt(OtpApp, Opts) ->
    CacheDir = maps:get(cache_dir, Opts, default_cache_dir()),
    Path = otp_cache_path(CacheDir, OtpApp),
    case filelib:is_regular(Path) of
        true ->
            spectra_plt:load(Path);
        false ->
            case code:lib_dir(OtpApp) of
                {error, Reason} ->
                    {error, Reason};
                LibDir ->
                    EbinDir = filename:join(LibDir, "ebin"),
                    PkgName = atom_to_binary(OtpApp, utf8),
                    OtpRel = list_to_binary(erlang:system_info(otp_release)),
                    Beams = filelib:wildcard(filename:join(EbinDir, "*.beam")),
                    case spectra_plt:from_beams(Beams, #{package => PkgName, package_vsn => OtpRel}) of
                        {ok, Plt} ->
                            _ = spectra_plt:save(Plt, Path),
                            {ok, Plt};
                        Error ->
                            Error
                    end
            end
    end.

%% @doc Resolves, builds/fetches, caches, and merges `.splt` files for a project's locked dependencies.
-spec resolve_project_plts(file:filename_all(), map()) ->
    {ok, #spectra_plt{}} | {error, term()}.
resolve_project_plts(ProjectRoot, Opts) ->
    CacheDir = maps:get(cache_dir, Opts, default_cache_dir()),
    OtpApps = maps:get(otp_apps, Opts, []),
    Deps = discover_deps(ProjectRoot),
    OtpPlts = lists:filtermap(
        fun(App) ->
            case ensure_otp_plt(App, Opts) of
                {ok, Plt} -> {true, Plt};
                _ -> false
            end
        end,
        OtpApps
    ),
    DepPlts = lists:filtermap(
        fun(#{name := Name, version := Vsn}) ->
            case resolve_single_dep(ProjectRoot, CacheDir, Name, Vsn, Opts) of
                {ok, Plt} -> {true, Plt};
                _ -> false
            end
        end,
        Deps
    ),
    {ok, spectra_plt:merge(OtpPlts ++ DepPlts)}.

resolve_single_dep(ProjectRoot, CacheDir, Name, Vsn, Opts) ->
    Path = cache_path(CacheDir, Name, Vsn),
    case filelib:is_regular(Path) of
        true ->
            spectra_plt:load(Path);
        false ->
            case try_remote_fetcher(Name, Vsn, Path, Opts) of
                {ok, Plt} ->
                    {ok, Plt};
                error ->
                    build_and_cache_local_dep(ProjectRoot, Path, Name, Vsn)
            end
    end.

try_remote_fetcher(Name, Vsn, CachePath, Opts) ->
    case maps:find(fetcher, Opts) of
        {ok, FetcherFun} when is_function(FetcherFun, 3) ->
            OtpRel = list_to_binary(erlang:system_info(otp_release)),
            case FetcherFun(OtpRel, Name, Vsn) of
                {ok, #spectra_plt{} = Plt} ->
                    _ = spectra_plt:save(Plt, CachePath),
                    {ok, Plt};
                {ok, Bin} when is_binary(Bin) ->
                    case spectra_plt:decode(Bin) of
                        {ok, Plt} ->
                            _ = spectra_plt:save(Plt, CachePath),
                            {ok, Plt};
                        _ ->
                            error
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    end.

build_and_cache_local_dep(ProjectRoot, CachePath, Name, Vsn) ->
    Root = unicode:characters_to_list(ProjectRoot),
    NameStr = binary_to_list(Name),
    Pattern = filename:join([Root, "_build", "*", "lib", NameStr, "ebin", "*.beam"]),
    case filelib:wildcard(Pattern) of
        [] ->
            error;
        Beams ->
            case spectra_plt:from_beams(Beams, #{package => Name, package_vsn => Vsn}) of
                {ok, Plt} ->
                    _ = spectra_plt:save(Plt, CachePath),
                    {ok, Plt};
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
    DepNames = maps:from_list([{binary_to_list(Name), true} || #{name := Name} <- Deps]),
    CandidateEbins = candidate_build_ebins(Root, Opts),
    lists:filter(
        fun(EbinPath) ->
            AppDir = filename:dirname(EbinPath),
            AppName = filename:basename(AppDir),
            not maps:is_key(AppName, DepNames)
        end,
        CandidateEbins
    ).

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
