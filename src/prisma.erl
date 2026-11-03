%% @doc Public API and CLI entrypoint for Prisma.
-module(prisma).

-include("prisma.hrl").

-export([
    init/1,
    main/1,
    version/0,
    build/2,
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
        "  prisma build --output <file.pplt> <ebin_or_beam...>~n"
        "  prisma check [--format <human|pretty|oneline|json>] [--no-color] [--color] [--pplt <file.pplt>...] [<ebin_or_beam...>]~n"
    ),
    erlang:halt(1).

%% @doc Parses CLI options for `prisma check` into a map.
-spec parse_check_opts([string()]) -> map().
parse_check_opts(Args) ->
    parse_check_opts_loop(Args, #{pplts => [], targets => [], format => human, color => auto}).

parse_check_opts_loop(["--pplt", PpltFile | Rest], Acc) ->
    Pplts = maps:get(pplts, Acc),
    parse_check_opts_loop(Rest, Acc#{pplts => [PpltFile | Pplts]});
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
