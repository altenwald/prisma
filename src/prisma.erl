%% @doc Public API and CLI entrypoint for Prisma.
-module(prisma).

-include("prisma.hrl").

-export([
    init/1,
    main/1,
    version/0,
    build/2,
    build_project/2,
    analyze_project/1,
    analyze_project/2,
    analyze_dirs/1,
    analyze_dirs/2,
    analyze_beams/2,
    parse_check_args/1,
    parse_check_opts/1,
    lsp/0,
    start_lsp/0
]).

%% @doc Rebar3 plugin entrypoint.
-spec init(term()) -> {ok, term()}.
init(State) ->
    prisma_prv:init(State).

%% @doc Returns the current Prisma version.
-spec version() -> binary().
version() ->
    <<"0.2.0">>.

%% @doc Builds a portable `.pplt` file from BEAM directories or files.
-spec build([file:filename_all()], file:filename_all()) ->
    {ok, #prisma_pplt{}} | {error, term()}.
build(Inputs, OutputFile) ->
    Beams = expand_beams(Inputs),
    case prisma_pplt:from_beams(Beams) of
        {ok, Pplt} ->
            case prisma_pplt:save(Pplt, OutputFile) of
                ok -> {ok, Pplt};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc What the `build` task does, once the project is compiled: writes `<app>_<vsn>.pplt` at the root of each application of the
%% project (the file a library publishes with its package), made from the beams that were just compiled and with the hash of its sources, and
%% leaves in `_build/` the `.pplt` of the dependencies that the checks need (the ones nobody shipped).
-spec build_project(file:filename_all(), map()) -> {ok, [string()]} | {error, term()}.
build_project(ProjectRoot, Opts) ->
    Ebins = prisma_lock:discover_project_ebins(ProjectRoot, Opts),
    case Ebins of
        [] ->
            {error, no_compiled_applications};
        _ ->
            Results = [build_app_pplt(Ebin, ProjectRoot) || Ebin <- Ebins],
            case [E || {error, _} = E <- Results] of
                [] ->
                    _ = prisma_lock:resolve_project_pplts(ProjectRoot, maps:with([cache_dir, otp_apps, elixir], Opts)),
                    {ok, [Path || {ok, Path} <- Results]};
                [Error | _] ->
                    Error
            end
    end.

build_app_pplt(Ebin, ProjectRoot) ->
    AppLink = filename:dirname(Ebin),
    App = filename:basename(AppLink),
    case app_vsn(Ebin, App) of
        {ok, Vsn} ->
            AppDir = real_app_dir(AppLink, ProjectRoot),
            Beams = filelib:wildcard(filename:join(Ebin, "*.beam")),
            Meta = #{package => list_to_binary(App), package_vsn => list_to_binary(Vsn),
                     source_hash => prisma_lock:source_hash(AppDir)},
            case prisma_pplt:from_beams(Beams, Meta) of
                {ok, Pplt} ->
                    Path = filename:join(AppDir, App ++ "_" ++ Vsn ++ ".pplt"),
                    %% one file per application: an older one would be read as well, and it is stale
                    [file:delete(Old) || Old <- filelib:wildcard(filename:join(AppDir, App ++ "_*.pplt")), Old =/= Path],
                    case prisma_pplt:save(Pplt, Path) of
                        ok -> {ok, Path};
                        {error, Reason} -> {error, {write_failed, Path, Reason}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        error ->
            {error, {no_version, App}}
    end.

app_vsn(Ebin, App) ->
    case file:consult(filename:join(Ebin, App ++ ".app")) of
        {ok, [{application, _, Props}]} ->
            case proplists:get_value(vsn, Props) of
                Vsn when is_list(Vsn) -> {ok, Vsn};
                _ -> error
            end;
        _ ->
            error
    end.

normalize(Path) ->
    Parts = lists:foldl(
        fun("..", [_ | Up]) -> Up;
           (".", Acc) -> Acc;
           (Part, Acc) -> [Part | Acc]
        end, [], filename:split(Path)),
    filename:join(lists:reverse(Parts)).

%% The root of the package of an application of the project. rebar3 links the directories of the application into
%% `_build/<profile>/lib/<app>` (`src`, `include`, ...), Mix links `priv`, and either may link the whole directory: the root is where the links
%% point. A project with a single application and no link to follow is its own root.
real_app_dir(AppLink, ProjectRoot) ->
    Candidates = [AppLink | [filename:join(AppLink, Sub) || Sub <- ["src", "include", "lib", "priv"]]],
    case [Dir || C <- Candidates, {ok, Target} <- [file:read_link_all(C)],
                 Dir <- [link_root(C, AppLink, Target)]] of
        [Root | _] -> Root;
        [] ->
            Root0 = unicode:characters_to_list(ProjectRoot),
            case filelib:is_dir(filename:join(Root0, "src")) orelse filelib:is_dir(filename:join(Root0, "lib")) of
                true -> normalize(filename:absname(Root0));
                false -> AppLink
            end
    end.

link_root(AppLink, AppLink, Target) ->
    normalize(filename:absname(Target, filename:dirname(AppLink)));
link_root(Link, _AppLink, Target) ->
    filename:dirname(normalize(filename:absname(Target, filename:dirname(Link)))).

%% @doc Analyzes only the project's own applications in `ProjectRoot`, caching locked dependencies as `.pplt` files.
-spec analyze_project(file:filename_all()) ->
    {ok, [#prisma_warning{}]} | {error, term()}.
analyze_project(ProjectRoot) ->
    analyze_project(ProjectRoot, #{}).

%% @doc Analyzes only the project's own applications in `ProjectRoot` with `Opts`.
-spec analyze_project(file:filename_all(), map()) ->
    {ok, [#prisma_warning{}]} | {error, term()}.
analyze_project(ProjectRoot, Opts) ->
    ProjectEbins = prisma_lock:discover_project_ebins(ProjectRoot, Opts),
    analyze_dirs(ProjectEbins, Opts#{project_root => ProjectRoot}).

%% @doc Analyzes all BEAM files in `Dirs`.
-spec analyze_dirs([file:filename_all()]) ->
    {ok, [#prisma_warning{}]} | {error, term()}.
analyze_dirs(Dirs) ->
    analyze_dirs(Dirs, #{}).

%% @doc Analyzes all BEAM files in `Dirs` with `Opts`.
-spec analyze_dirs([file:filename_all()], map()) ->
    {ok, [#prisma_warning{}]} | {error, term()}.
analyze_dirs(Dirs, Opts) ->
    Beams = expand_beams(Dirs),
    analyze_beams(Beams, Opts).

%% @doc Analyzes a list of BEAM paths or binaries with `Opts`.
-spec analyze_beams([file:filename_all() | binary()], map()) ->
    {ok, [#prisma_warning{}]} | {error, term()}.
analyze_beams(Beams, Opts) ->
    PpltFiles = maps:get(pplts, Opts, []),
    case load_pplts(PpltFiles) of
        {ok, ExplicitPplt} ->
            LockPplt = resolve_lock_pplt(Opts),
            DepsPplt = prisma_pplt:merge(ExplicitPplt, LockPplt),
            case prisma_pplt:from_beams(Beams, Opts#{external_specs => prisma_pplt:declared_specs(DepsPplt)}) of
                {ok, TargetPplt} ->
                    Warnings = prisma_checker:check_pplt(TargetPplt, DepsPplt, Opts),
                    {ok, Warnings};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

resolve_lock_pplt(Opts) ->
    case maps:find(project_root, Opts) of
        {ok, Root} ->
            case prisma_lock:resolve_project_pplts(Root, Opts) of
                {ok, Pplt} -> Pplt;
                _ -> prisma_pplt:new()
            end;
        error ->
            prisma_pplt:new()
    end.

%% @doc Escript CLI entrypoint.
-spec main([string()]) -> no_return().
main(["version"]) ->
    io:format("prisma ~s (OTP ~s)~n", [version(), erlang:system_info(otp_release)]),
    erlang:halt(0);
main(["build"]) ->
    case build_project(".", #{}) of
        {ok, Paths} ->
            [io:format("Built ~ts~n", [P]) || P <- Paths],
            erlang:halt(0);
        {error, Reason} ->
            io:format(standard_error, "Failed to build: ~p~n", [Reason]),
            erlang:halt(1)
    end;
main(["build", "--output", OutFile | Inputs]) when Inputs =/= [] ->
    case build(Inputs, OutFile) of
        {ok, Pplt} ->
            Mods = prisma_pplt:modules(Pplt),
            io:format("Built PPLT ~s (~B modules)~n", [OutFile, length(Mods)]),
            erlang:halt(0);
        {error, Reason} ->
            io:format(standard_error, "Failed to build PPLT: ~p~n", [Reason]),
            erlang:halt(1)
    end;
main(["check" | Rest]) ->
    Opts = parse_check_opts(Rest),
    case maps:find(error, Opts) of
        {ok, {bad_mode, Bad}} ->
            io:format(standard_error, "Unknown mode ~ts (hybrid, gradual or discrepancy)~n", [Bad]),
            erlang:halt(2);
        error ->
            ok
    end,
    Targets = maps:get(targets, Opts, []),
    Result = case Targets of
        [] -> analyze_project(".", Opts);
        _ -> analyze_dirs(Targets, Opts#{project_root => "."})
    end,
    case Result of
        {ok, Warnings} ->
            Report = prisma_checker:report(Warnings, Opts),
            io:put_chars(maps:get(output, Report)),
            case maps:get(unchecked, Report) of
                0 -> ok;
                N -> io:format(standard_error, "prisma: ~B branches that depend on the system were not checked~n", [N])
            end,
            erlang:halt(case maps:get(failed, Report) of true -> 1; false -> 0 end);
        {error, Reason} ->
            io:format(standard_error, "Prisma check failed: ~p~n", [Reason]),
            erlang:halt(1)
    end;
main(["lsp" | _]) ->
    start_lsp();
main(["server" | _]) ->
    start_lsp();
main(_) ->
    io:format(
        "Usage:~n"
        "  prisma version~n"
        "  prisma lsp~n"
        "  prisma build~n"
        "  prisma build --output <file.pplt> <ebin_or_beam...>~n"
        "  prisma check [--mode <hybrid|gradual|discrepancy>] [--format <human|pretty|oneline|json>] [--no-color] [--color] [--no-warnings] [--warnings-as-errors] [--pplt <file.pplt>...] [<ebin_or_beam...>]~n"
    ),
    erlang:halt(1).

%% @doc Starts the Prisma Language Server (LSP).
-spec lsp() -> no_return().
lsp() ->
    start_lsp().

-spec start_lsp() -> no_return().
start_lsp() ->
    prisma_lsp_server:start().

%% @doc Parses CLI options for `prisma check` into a map.
-spec parse_check_opts([string()]) -> map().
parse_check_opts(Args) ->
    parse_check_opts_loop(Args, #{pplts => [], targets => [], format => human, color => auto}).

parse_check_opts_loop(["--pplt", PpltFile | Rest], Acc) ->
    Pplts = maps:get(pplts, Acc),
    parse_check_opts_loop(Rest, Acc#{pplts => [PpltFile | Pplts]});
parse_check_opts_loop(["--mode", Mode | Rest], Acc) ->
    case Mode of
        "discrepancy" -> parse_check_opts_loop(Rest, Acc#{mode => discrepancy});
        "gradual" -> parse_check_opts_loop(Rest, Acc#{mode => gradual});
        "hybrid" -> parse_check_opts_loop(Rest, Acc#{mode => hybrid});
        _ -> parse_check_opts_loop(Rest, Acc#{error => {bad_mode, Mode}})
    end;
parse_check_opts_loop(["--format", Fmt | Rest], Acc) ->
    parse_check_opts_loop(Rest, Acc#{format => parse_format(Fmt)});
parse_check_opts_loop(["--no-oxbow" | Rest], Acc) ->
    parse_check_opts_loop(Rest, Acc#{oxbow => false});
parse_check_opts_loop(["--no-warnings" | Rest], Acc) ->
    parse_check_opts_loop(Rest, Acc#{no_warnings => true});
parse_check_opts_loop(["--warnings-as-errors" | Rest], Acc) ->
    parse_check_opts_loop(Rest, Acc#{warnings_as_errors => true});
parse_check_opts_loop(["--oxbow" | Rest], Acc) ->
    parse_check_opts_loop(Rest, Acc#{oxbow => true});
parse_check_opts_loop(["--no-color" | Rest], Acc) ->
    parse_check_opts_loop(Rest, Acc#{color => never});
parse_check_opts_loop(["--color" | Rest], Acc) ->
    parse_check_opts_loop(Rest, Acc#{color => always});
parse_check_opts_loop([Target | Rest], Acc) ->
    Targets = maps:get(targets, Acc),
    parse_check_opts_loop(Rest, Acc#{targets => [Target | Targets]});
parse_check_opts_loop([], Acc) ->
    Pplts = lists:reverse(maps:get(pplts, Acc)),
    Targets = lists:reverse(maps:get(targets, Acc)),
    Acc#{pplts => Pplts, targets => Targets}.

parse_format("json") -> json;
parse_format("oneline") -> oneline;
parse_format("pretty") -> human;
parse_format("human") -> human;
parse_format(_) -> human.

%% @doc Parses CLI arguments for `prisma check` into `{Pplts, Targets}` tuple.
-spec parse_check_args([string()]) -> {[string()], [string()]}.
parse_check_args(Args) ->
    Opts = parse_check_opts(Args),
    {maps:get(pplts, Opts), maps:get(targets, Opts)}.

load_pplts(PpltFiles) ->
    lists:foldl(
        fun
            (File, {ok, Acc}) ->
                case prisma_pplt:load(File) of
                    {ok, Pplt} -> {ok, prisma_pplt:merge(Acc, Pplt)};
                    {error, Reason} -> {error, {pplt_load_failed, File, Reason}}
                end;
            (_File, {error, _} = Err) ->
                Err
        end,
        {ok, prisma_pplt:new()},
        PpltFiles
    ).

expand_beams(Inputs) ->
    lists:flatmap(
        fun(Input) ->
            Path = unicode:characters_to_list(Input),
            case filelib:is_dir(Path) of
                true -> filelib:wildcard(filename:join(Path, "*.beam"));
                false -> [Path]
            end
        end,
        Inputs
    ).
