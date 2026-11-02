%% @doc Mix task (`mix spectra`) compiled directly as a BEAM module for Elixir projects.
%%
%% Automatically resolves `_build/<env>/lib/<app>/ebin` paths for the project's
%% own applications while caching locked dependencies as `.splt` files.
-module('Elixir.Mix.Tasks.Spectra').

-export([
    '__info__'/1,
    '__mix_recompile__?'/0,
    run/1,
    parse_args/1,
    resolve_ebin_dirs/1,
    resolve_ebin_dirs/2
]).

-spec '__info__'(atom()) -> term().
'__info__'(attributes) ->
    [{behaviour, ['Elixir.Mix.Task']}];
'__info__'(compile) ->
    [];
'__info__'(functions) ->
    module_info(functions);
'__info__'(macros) ->
    [];
'__info__'(md5) ->
    module_info(md5);
'__info__'(module) ->
    ?MODULE;
'__info__'(struct) ->
    nil;
'__info__'(_) ->
    [].

-spec '__mix_recompile__?'() -> boolean().
'__mix_recompile__?'() ->
    false.

%% @doc Runs Spectra analysis within an Elixir Mix project.
-spec run([binary() | string()]) -> ok.
run(RawArgs) ->
    case code:ensure_loaded('Elixir.Mix.Task') of
        {module, MixTask} ->
            _ = MixTask:run(<<"compile">>, []);
        _ ->
            ok
    end,
    SelfBeamDir = filename:dirname(code:which(?MODULE)),
    code:add_patha(SelfBeamDir),
    Opts = parse_args(RawArgs),
    Root = maps:get(root, Opts, "."),
    Dirs = resolve_ebin_dirs(maps:get(targets, Opts, []), Opts),
    Format = maps:get(format, Opts, human),
    case spectra:analyze_dirs(Dirs, Opts#{project_root => Root}) of
        {ok, []} ->
            case Format of
                json -> io:format("[]~n");
                _ ->
                    UseColor = spectra_checker:should_color(Opts),
                    Msg = spectra_checker:colorize("Spectra: 0 warnings found.", "\e[1;32m", UseColor),
                    io:format("~ts~n", [Msg])
            end,
            ok;
        {ok, Warnings} ->
            Formatted = spectra_checker:format_warnings(Warnings, Opts),
            io:format("~ts~n", [Formatted]),
            erlang:halt(1);
        {error, Reason} ->
            io:format(standard_error, "Spectra error: ~p~n", [Reason]),
            erlang:halt(1)
    end.

%% @doc Parses CLI arguments passed to `mix spectra`.
-spec parse_args([binary() | string()]) -> map().
parse_args(RawArgs) ->
    StrArgs = [unicode:characters_to_list(A) || A <- RawArgs],
    DefaultEnv = case os:getenv("MIX_ENV") of
        false -> "dev";
        EnvVal -> EnvVal
    end,
    parse_args_loop(StrArgs, #{mode => hybrid, env => DefaultEnv, plts => [], targets => [], format => human, color => auto}).

parse_args_loop(["--mode", ModeStr | Rest], Acc) ->
    Mode = parse_mode(ModeStr),
    parse_args_loop(Rest, Acc#{mode => Mode});
parse_args_loop(["--env", EnvStr | Rest], Acc) ->
    parse_args_loop(Rest, Acc#{env => EnvStr});
parse_args_loop(["--format", Fmt | Rest], Acc) ->
    parse_args_loop(Rest, Acc#{format => parse_format(Fmt)});
parse_args_loop(["--no-oxbow" | Rest], Acc) ->
    parse_args_loop(Rest, Acc#{oxbow => false});
parse_args_loop(["--oxbow" | Rest], Acc) ->
    parse_args_loop(Rest, Acc#{oxbow => true});
parse_args_loop(["--no-color" | Rest], Acc) ->
    parse_args_loop(Rest, Acc#{color => never});
parse_args_loop(["--color" | Rest], Acc) ->
    parse_args_loop(Rest, Acc#{color => always});
parse_args_loop(["--plt", PltPath | Rest], #{plts := Plts} = Acc) ->
    parse_args_loop(Rest, Acc#{plts => Plts ++ [PltPath]});
parse_args_loop([Target | Rest], #{targets := Targets} = Acc) ->
    parse_args_loop(Rest, Acc#{targets => Targets ++ [Target]});
parse_args_loop([], Acc) ->
    Acc.

parse_format("json") -> json;
parse_format("oneline") -> oneline;
parse_format("pretty") -> human;
parse_format("human") -> human;
parse_format(_) -> human.

parse_mode("gradual") -> gradual;
parse_mode("discrepancy") -> discrepancy;
parse_mode(_) -> hybrid.

%% @doc Resolves Mix `_build/<env>/lib/<app>/ebin` directories for the project's own apps.
-spec resolve_ebin_dirs([file:filename_all()]) -> [string()].
resolve_ebin_dirs(Targets) ->
    resolve_ebin_dirs(Targets, #{}).

%% @doc Resolves Mix `_build/<env>/lib/<app>/ebin` directories using `Opts`, excluding locked dependencies.
-spec resolve_ebin_dirs([file:filename_all()], map()) -> [string()].
resolve_ebin_dirs([_ | _] = ExplicitTargets, _Opts) ->
    [unicode:characters_to_list(T) || T <- ExplicitTargets];
resolve_ebin_dirs([], Opts) ->
    Root = unicode:characters_to_list(maps:get(root, Opts, ".")),
    spectra_lock:discover_project_ebins(Root, Opts).
