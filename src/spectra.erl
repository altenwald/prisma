%% @doc Public API and CLI entrypoint for Spectra.
-module(spectra).

-include("spectra.hrl").

-export([
    init/1,
    main/1,
    version/0,
    build_plt/2,
    analyze_dirs/1,
    analyze_dirs/2,
    analyze_beams/2
]).

%% @doc Rebar3 plugin entrypoint.
-spec init(term()) -> {ok, term()}.
init(State) ->
    spectra_prv:init(State).

%% @doc Returns the current Spectra version.
-spec version() -> binary().
version() ->
    <<"0.1.0">>.

%% @doc Builds a portable `.splt` file from BEAM directories or files.
-spec build_plt([file:filename_all()], file:filename_all()) ->
    {ok, #spectra_plt{}} | {error, term()}.
build_plt(Inputs, OutputFile) ->
    Beams = expand_beams(Inputs),
    case spectra_plt:from_beams(Beams) of
        {ok, Plt} ->
            case spectra_plt:save(Plt, OutputFile) of
                ok -> {ok, Plt};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Analyzes all BEAM files in `Dirs`.
-spec analyze_dirs([file:filename_all()]) ->
    {ok, [#spectra_warning{}]} | {error, term()}.
analyze_dirs(Dirs) ->
    analyze_dirs(Dirs, #{}).

%% @doc Analyzes all BEAM files in `Dirs` with `Opts`.
-spec analyze_dirs([file:filename_all()], map()) ->
    {ok, [#spectra_warning{}]} | {error, term()}.
analyze_dirs(Dirs, Opts) ->
    Beams = expand_beams(Dirs),
    analyze_beams(Beams, Opts).

%% @doc Analyzes a list of BEAM paths or binaries with `Opts`.
-spec analyze_beams([file:filename_all() | binary()], map()) ->
    {ok, [#spectra_warning{}]} | {error, term()}.
analyze_beams(Beams, Opts) ->
    PltFiles = maps:get(plts, Opts, []),
    case load_plts(PltFiles) of
        {ok, DepsPlt} ->
            case spectra_plt:from_beams(Beams, Opts) of
                {ok, TargetPlt} ->
                    Warnings = spectra_checker:check_plt(TargetPlt, DepsPlt, Opts),
                    {ok, Warnings};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Escript CLI entrypoint.
-spec main([string()]) -> no_return().
main(["version"]) ->
    io:format("spectra ~s (OTP ~s)~n", [version(), erlang:system_info(otp_release)]),
    erlang:halt(0);
main(["build-plt", "--output", OutFile | Inputs]) when Inputs =/= [] ->
    case build_plt(Inputs, OutFile) of
        {ok, Plt} ->
            Mods = spectra_plt:modules(Plt),
            io:format("Built portable PLT ~s (~B modules)~n", [OutFile, length(Mods)]),
            erlang:halt(0);
        {error, Reason} ->
            io:format(standard_error, "Failed to build PLT: ~p~n", [Reason]),
            erlang:halt(1)
    end;
main(["check" | Rest]) ->
    {Plts, Targets} = parse_check_args(Rest, [], []),
    case analyze_dirs(Targets, #{plts => Plts}) of
        {ok, []} ->
            io:format("Spectra: 0 warnings found.~n"),
            erlang:halt(0);
        {ok, Warnings} ->
            lists:foreach(
                fun(W) ->
                    io:format("~ts~n", [spectra_checker:format_warning(W)])
                end,
                Warnings
            ),
            erlang:halt(1);
        {error, Reason} ->
            io:format(standard_error, "Spectra check failed: ~p~n", [Reason]),
            erlang:halt(1)
    end;
main(_) ->
    io:format(
        "Usage:~n"
        "  spectra version~n"
        "  spectra build-plt --output <file.splt> <ebin_or_beam...>~n"
        "  spectra check [--plt <file.splt>...] <ebin_or_beam...>~n"
    ),
    erlang:halt(1).

parse_check_args(["--plt", PltFile | Rest], Plts, Targets) ->
    parse_check_args(Rest, [PltFile | Plts], Targets);
parse_check_args([Target | Rest], Plts, Targets) ->
    parse_check_args(Rest, Plts, [Target | Targets]);
parse_check_args([], Plts, Targets) ->
    {lists:reverse(Plts), lists:reverse(Targets)}.

load_plts(PltFiles) ->
    lists:foldl(
        fun
            (File, {ok, Acc}) ->
                case spectra_plt:load(File) of
                    {ok, Plt} -> {ok, spectra_plt:merge(Acc, Plt)};
                    {error, Reason} -> {error, {plt_load_failed, File, Reason}}
                end;
            (_File, {error, _} = Err) ->
                Err
        end,
        {ok, spectra_plt:new()},
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
