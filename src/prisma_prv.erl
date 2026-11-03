%% @doc Rebar3 provider plugin (`rebar3 prisma`).
-module(prisma_prv).

-export([
    init/1,
    do/1,
    format_error/1,
    parse_cli_args/1,
    parse_config_opts/1
]).

-define(PROVIDER, prisma).
-define(DEPS, [compile]).
-define(OPTS, [
    {format, $f, "format", string, "Output format: human, oneline, json (default: human)"},
    {mode, $m, "mode", string, "Analysis mode: hybrid, gradual, discrepancy (default: hybrid)"},
    {no_color, undefined, "no-color", boolean, "Disable ANSI colors"},
    {color, undefined, "color", boolean, "Force ANSI colors"},
    {no_oxbow, undefined, "no-oxbow", boolean, "Disable oxbow code detection"},
    {oxbow, undefined, "oxbow", boolean, "Enable oxbow code detection"},
    {plt, undefined, "plt", string, "Path to .pplt file (can be specified multiple times)"}
]).

%% @doc Registers the `prisma` provider with Rebar3.
-spec init(term()) -> {ok, term()}.
init(State) ->
    case code:ensure_loaded(providers) of
        {module, providers} ->
            Provider = providers:create([
                {name, ?PROVIDER},
                {module, ?MODULE},
                {bare, true},
                {deps, ?DEPS},
                {example, "rebar3 prisma"},
                {opts, ?OPTS},
                {short_desc, "Run Prisma hybrid type and discrepancy analysis"},
                {desc, "Analyzes compiled BEAM files using Prisma's hybrid gradual and discrepancy checker."}
            ]),
            {ok, rebar_state:add_provider(State, Provider)};
        _ ->
            {ok, State}
    end.

%% @doc Executes the analysis over the Rebar3 project's compiled BEAM directories.
-spec do(term()) -> {ok, term()} | {error, iolist()}.
do(State) ->
    Root = rebar_state:dir(State),
    {ParsedOpts, Targets} = parse_opts(State),
    Apps = case rebar_state:current_app(State) of
        undefined -> rebar_state:project_apps(State);
        AppInfo -> [AppInfo]
    end,
    AppEbins = case is_list(Apps) of
        true -> lists:flatmap(fun safe_app_ebin/1, Apps);
        false -> []
    end,
    EbinDirs = resolve_ebins(AppEbins, Root, Targets),
    Opts = ParsedOpts#{project_root => Root},
    case prisma:analyze_dirs(EbinDirs, Opts) of
        {ok, []} ->
            case maps:get(format, Opts, human) of
                json ->
                    io:format("[]~n");
                _ ->
                    UseColor = prisma_checker:should_color(Opts),
                    Msg = prisma_checker:colorize("Prisma: 0 warnings found.", "\e[1;32m", UseColor),
                    io:format("~ts~n", [Msg])
            end,
            {ok, State};
        {ok, Warnings} ->
            Formatted = prisma_checker:format_warnings(Warnings, Opts),
            io:format("~ts~n", [Formatted]),
            {error, format_error({warnings_found, length(Warnings)})};
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

%% @doc Formats provider errors for Rebar3 output.
-spec format_error(term()) -> iolist().
format_error({warnings_found, Count}) ->
    io_lib:format("Prisma found ~B type warning(s)", [Count]);
format_error(Reason) ->
    io_lib:format("Prisma error: ~p", [Reason]).

%% @private Safely gets ebin dir for an app info record.
safe_app_ebin(App) ->
    try rebar_app_info:ebin_dir(App) of
        Dir when is_list(Dir) -> [Dir];
        _ -> []
    catch
        _:_ -> []
    end.

%% @private Parses configuration and CLI options from Rebar3 state.
parse_opts(State) ->
    ConfigOpts = try rebar_state:get(State, prisma, []) of
        List when is_list(List) -> parse_config_opts(List);
        _ -> #{}
    catch
        _:_ -> #{}
    end,
    {CliOpts, Targets} = try rebar_state:command_parsed_args(State) of
        {ParsedArgs, OtherArgs} when is_list(ParsedArgs) ->
            {parse_cli_args(ParsedArgs), OtherArgs};
        ParsedList when is_list(ParsedList) ->
            {parse_cli_args(ParsedList), []};
        _ ->
            {#{}, []}
    catch
        _:_ ->
            {#{}, []}
    end,
    Defaults = #{mode => hybrid, format => human, color => auto},
    Merged = maps:merge(Defaults, maps:merge(ConfigOpts, CliOpts)),
    FinalPlts = maps:get(plts, ConfigOpts, []) ++ maps:get(plts, CliOpts, []),
    {Merged#{plts => FinalPlts}, Targets}.

%% @doc Parses CLI options received from Rebar3.
-spec parse_cli_args([term()]) -> map().
parse_cli_args(Args) ->
    lists:foldl(
        fun
            ({format, Fmt}, Acc) -> Acc#{format => parse_format(Fmt)};
            ({mode, Mode}, Acc) -> Acc#{mode => parse_mode(Mode)};
            ({no_color, true}, Acc) -> Acc#{color => never};
            (no_color, Acc) -> Acc#{color => never};
            ({color, true}, Acc) -> Acc#{color => always};
            (color, Acc) -> Acc#{color => always};
            ({no_oxbow, true}, Acc) -> Acc#{oxbow => false};
            (no_oxbow, Acc) -> Acc#{oxbow => false};
            ({oxbow, true}, Acc) -> Acc#{oxbow => true};
            (oxbow, Acc) -> Acc#{oxbow => true};
            ({plt, PltPath}, #{plts := Plts} = Acc) -> Acc#{plts => Plts ++ [unicode:characters_to_list(PltPath)]};
            ({plt, PltPath}, Acc) -> Acc#{plts => [unicode:characters_to_list(PltPath)]};
            (_, Acc) -> Acc
        end,
        #{},
        Args
    ).

%% @doc Parses options configured under `{prisma, [...]}` in `rebar.config`.
-spec parse_config_opts([term()]) -> map().
parse_config_opts(Opts) ->
    lists:foldl(
        fun
            ({format, Fmt}, Acc) -> Acc#{format => parse_format(Fmt)};
            ({mode, Mode}, Acc) -> Acc#{mode => parse_mode(Mode)};
            ({color, Val}, Acc) when Val =:= always; Val =:= never; Val =:= auto -> Acc#{color => Val};
            ({oxbow, Val}, Acc) when is_boolean(Val) -> Acc#{oxbow => Val};
            ({plts, Plts}, Acc) when is_list(Plts) ->
                Acc#{plts => [unicode:characters_to_list(P) || P <- Plts]};
            ({plt, Plt}, #{plts := Plts} = Acc) ->
                Acc#{plts => Plts ++ [unicode:characters_to_list(Plt)]};
            ({plt, Plt}, Acc) ->
                Acc#{plts => [unicode:characters_to_list(Plt)]};
            (_, Acc) ->
                Acc
        end,
        #{},
        Opts
    ).

parse_format(json) -> json;
parse_format("json") -> json;
parse_format(<<"json">>) -> json;
parse_format(oneline) -> oneline;
parse_format("oneline") -> oneline;
parse_format(<<"oneline">>) -> oneline;
parse_format(_) -> human.

parse_mode(gradual) -> gradual;
parse_mode("gradual") -> gradual;
parse_mode(<<"gradual">>) -> gradual;
parse_mode(discrepancy) -> discrepancy;
parse_mode("discrepancy") -> discrepancy;
parse_mode(<<"discrepancy">>) -> discrepancy;
parse_mode(_) -> hybrid.

resolve_ebins(_AppEbins, _Root, [_|_] = Targets) ->
    [unicode:characters_to_list(T) || T <- Targets];
resolve_ebins([_|_] = AppEbins, _Root, []) ->
    [unicode:characters_to_list(D) || D <- AppEbins];
resolve_ebins([], Root, []) ->
    prisma_lock:discover_project_ebins(Root, #{}).
