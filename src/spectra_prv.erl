%% @doc Rebar3 provider plugin (`rebar3 spectra`).
-module(spectra_prv).

-export([
    init/1,
    do/1,
    format_error/1
]).

-define(PROVIDER, spectra).
-define(DEPS, [compile]).

%% @doc Registers the `spectra` provider with Rebar3.
-spec init(term()) -> {ok, term()}.
init(State) ->
    case code:ensure_loaded(providers) of
        {module, providers} ->
            Provider = providers:create([
                {name, ?PROVIDER},
                {module, ?MODULE},
                {bare, true},
                {deps, ?DEPS},
                {example, "rebar3 spectra"},
                {opts, []},
                {short_desc, "Run Spectra hybrid type and discrepancy analysis"},
                {desc, "Analyzes compiled BEAM files using Spectra's hybrid gradual and discrepancy checker."}
            ]),
            {ok, rebar_state:add_provider(State, Provider)};
        _ ->
            {ok, State}
    end.

%% @doc Executes the analysis over the Rebar3 project's compiled BEAM directories.
-spec do(term()) -> {ok, term()} | {error, string()}.
do(State) ->
    Apps = case rebar_state:current_app(State) of
        undefined -> rebar_state:project_apps(State);
        AppInfo -> [AppInfo]
    end,
    Root = rebar_state:dir(State),
    EbinDirs = [rebar_app_info:ebin_dir(App) || App <- Apps],
    case spectra:analyze_dirs(EbinDirs, #{project_root => Root}) of
        {ok, []} ->
            {ok, State};
        {ok, Warnings} ->
            lists:foreach(
                fun(W) ->
                    io:format("~ts~n", [spectra_checker:format_warning(W)])
                end,
                Warnings
            ),
            {error, format_error({warnings_found, length(Warnings)})};
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

%% @doc Formats provider errors for Rebar3 output.
-spec format_error(term()) -> iolist().
format_error({warnings_found, Count}) ->
    io_lib:format("Spectra found ~B type warning(s)", [Count]);
format_error(Reason) ->
    io_lib:format("Spectra error: ~p", [Reason]).
