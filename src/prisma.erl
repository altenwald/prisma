%% @doc Public API and CLI entrypoint for Prisma.
-module(prisma).

-include("prisma.hrl").

-export([
    init/1,
    main/1,
    version/0,
    build_plt/2,
    analyze_project/1,
    analyze_project/2,
    analyze_dirs/1,
    analyze_dirs/2,
    analyze_beams/2,
    parse_check_args/1,
    parse_check_opts/1
]).

%% @doc Rebar3 plugin entrypoint.
-spec init(term()) -> {ok, term()}.
init(State) ->
    prisma_prv:init(State).

%% @doc Returns the current Prisma version.
-spec version() -> binary().
version() ->
    <<"0.1.0">>.

%% @doc Builds a portable `.pplt` file from BEAM directories or files.
-spec build_plt([file:filename_all()], file:filename_all()) ->
    {ok, #prisma_plt{}} | {error, term()}.
build_plt(Inputs, OutputFile) ->
    Beams = expand_beams(Inputs),
    case prisma_plt:from_beams(Beams) of
        {ok, Plt} ->
            case prisma_plt:save(Plt, OutputFile) of
                ok -> {ok, Plt};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

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
    PltFiles = maps:get(plts, Opts, []),
    case load_plts(PltFiles) of
        {ok, ExplicitPlt} ->
            LockPlt = resolve_lock_plt(Opts),
            DepsPlt = prisma_plt:merge(ExplicitPlt, LockPlt),
            case prisma_plt:from_beams(Beams, Opts#{external_specs => prisma_plt:declared_specs(DepsPlt)}) of
                {ok, TargetPlt} ->
                    Warnings = prisma_checker:check_plt(TargetPlt, DepsPlt, Opts),
                    {ok, Warnings};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

resolve_lock_plt(Opts) ->
    case maps:find(project_root, Opts) of
        {ok, Root} ->
            case prisma_lock:resolve_project_plts(Root, Opts) of
                {ok, Plt} -> Plt;
                _ -> prisma_plt:new()
            end;
        error ->
            prisma_plt:new()
    end.

%% @doc Escript CLI entrypoint.
-spec main([string()]) -> no_return().
main(["version"]) ->
    io:format("prisma ~s (OTP ~s)~n", [version(), erlang:system_info(otp_release)]),
    erlang:halt(0);
main(["build-plt", "--output", OutFile | Inputs]) when Inputs =/= [] ->
    case build_plt(Inputs, OutFile) of
        {ok, Plt} ->
            Mods = prisma_plt:modules(Plt),
            io:format("Built portable PLT ~s (~B modules)~n", [OutFile, length(Mods)]),
            erlang:halt(0);
        {error, Reason} ->
            io:format(standard_error, "Failed to build PLT: ~p~n", [Reason]),
            erlang:halt(1)
    end;
main(["check" | Rest]) ->
    Opts = parse_check_opts(Rest),
    Targets = maps:get(targets, Opts, []),
    Format = maps:get(format, Opts, human),
    Result = case Targets of
        [] -> analyze_project(".", Opts);
        _ -> analyze_dirs(Targets, Opts#{project_root => "."})
    end,
    case Result of
        {ok, []} ->
            case Format of
                json -> io:format("[]~n");
                _ ->
                    UseColor = prisma_checker:should_color(Opts),
                    Msg = prisma_checker:colorize("Prisma: 0 warnings found.", "\e[1;32m", UseColor),
                    io:format("~ts~n", [Msg])
            end,
            erlang:halt(0);
        {ok, Warnings} ->
            Formatted = prisma_checker:format_warnings(Warnings, Opts),
            io:format("~ts~n", [Formatted]),
            erlang:halt(1);
        {error, Reason} ->
            io:format(standard_error, "Prisma check failed: ~p~n", [Reason]),
            erlang:halt(1)
    end;
main(_) ->
    io:format(
        "Usage:~n"
        "  prisma version~n"
        "  prisma build-plt --output <file.pplt> <ebin_or_beam...>~n"
        "  prisma check [--format <human|pretty|oneline|json>] [--no-color] [--color] [--plt <file.pplt>...] [<ebin_or_beam...>]~n"
    ),
    erlang:halt(1).

%% @doc Parses CLI options for `prisma check` into a map.
-spec parse_check_opts([string()]) -> map().
parse_check_opts(Args) ->
    parse_check_opts_loop(Args, #{plts => [], targets => [], format => human, color => auto}).

parse_check_opts_loop(["--plt", PltFile | Rest], Acc) ->
    Plts = maps:get(plts, Acc),
    parse_check_opts_loop(Rest, Acc#{plts => [PltFile | Plts]});
parse_check_opts_loop(["--format", Fmt | Rest], Acc) ->
    parse_check_opts_loop(Rest, Acc#{format => parse_format(Fmt)});
parse_check_opts_loop(["--no-oxbow" | Rest], Acc) ->
    parse_check_opts_loop(Rest, Acc#{oxbow => false});
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
    Plts = lists:reverse(maps:get(plts, Acc)),
    Targets = lists:reverse(maps:get(targets, Acc)),
    Acc#{plts => Plts, targets => Targets}.

parse_format("json") -> json;
parse_format("oneline") -> oneline;
parse_format("pretty") -> human;
parse_format("human") -> human;
parse_format(_) -> human.

%% @doc Parses CLI arguments for `prisma check` into `{Plts, Targets}` tuple.
-spec parse_check_args([string()]) -> {[string()], [string()]}.
parse_check_args(Args) ->
    Opts = parse_check_opts(Args),
    {maps:get(plts, Opts), maps:get(targets, Opts)}.

load_plts(PltFiles) ->
    lists:foldl(
        fun
            (File, {ok, Acc}) ->
                case prisma_plt:load(File) of
                    {ok, Plt} -> {ok, prisma_plt:merge(Acc, Plt)};
                    {error, Reason} -> {error, {plt_load_failed, File, Reason}}
                end;
            (_File, {error, _} = Err) ->
                Err
        end,
        {ok, prisma_plt:new()},
        PltFiles
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
