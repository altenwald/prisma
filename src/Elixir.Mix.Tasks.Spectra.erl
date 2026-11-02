%% @doc Mix task (`mix spectra`) compiled directly as a BEAM module for Elixir projects.
%%
%% Automatically resolves `_build/<env>/lib/*/ebin` paths and supports `--mode`,
%% `--env`, and `--plt` flags.
-module('Elixir.Mix.Tasks.Spectra').

-export([
    '__mix_recompile__?'/0,
    run/1,
    parse_args/1,
    resolve_ebin_dirs/1,
    resolve_ebin_dirs/2
]).

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
    Opts = parse_args(RawArgs),
    Dirs = resolve_ebin_dirs(maps:get(targets, Opts, []), Opts),
    case spectra:analyze_dirs(Dirs, Opts) of
        {ok, []} ->
            io:format("Spectra: 0 warnings found.~n"),
            ok;
        {ok, Warnings} ->
            lists:foreach(
                fun(W) ->
                    io:format("~ts~n", [spectra_checker:format_warning(W)])
                end,
                Warnings
            ),
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
    parse_args_loop(StrArgs, #{mode => hybrid, env => DefaultEnv, plts => [], targets => []}).

parse_args_loop(["--mode", ModeStr | Rest], Acc) ->
    Mode = parse_mode(ModeStr),
    parse_args_loop(Rest, Acc#{mode => Mode});
parse_args_loop(["--env", EnvStr | Rest], Acc) ->
    parse_args_loop(Rest, Acc#{env => EnvStr});
parse_args_loop(["--plt", PltPath | Rest], #{plts := Plts} = Acc) ->
    parse_args_loop(Rest, Acc#{plts => Plts ++ [PltPath]});
parse_args_loop([Target | Rest], #{targets := Targets} = Acc) ->
    parse_args_loop(Rest, Acc#{targets => Targets ++ [Target]});
parse_args_loop([], Acc) ->
    Acc.

parse_mode("gradual") -> gradual;
parse_mode("discrepancy") -> discrepancy;
parse_mode(_) -> hybrid.

%% @doc Resolves Mix `_build/<env>/lib/*/ebin` directories for the current project.
-spec resolve_ebin_dirs([file:filename_all()]) -> [string()].
resolve_ebin_dirs(Targets) ->
    resolve_ebin_dirs(Targets, #{}).

%% @doc Resolves Mix `_build/<env>/lib/*/ebin` directories using `Opts`.
-spec resolve_ebin_dirs([file:filename_all()], map()) -> [string()].
resolve_ebin_dirs([_ | _] = ExplicitTargets, _Opts) ->
    [unicode:characters_to_list(T) || T <- ExplicitTargets];
resolve_ebin_dirs([], Opts) ->
    Root = unicode:characters_to_list(maps:get(root, Opts, ".")),
    Env = unicode:characters_to_list(maps:get(env, Opts, "dev")),
    case maps:is_key(root, Opts) of
        false ->
            case code:ensure_loaded('Elixir.Mix.Project') of
                {module, MixProject} ->
                    BuildPath = unicode:characters_to_list(MixProject:build_path()),
                    filelib:wildcard(filename:join([BuildPath, "lib", "*", "ebin"]));
                _ ->
                    wildcard_mix_ebins(Root, Env)
            end;
        true ->
            wildcard_mix_ebins(Root, Env)
    end.

wildcard_mix_ebins(Root, Env) ->
    EnvDirs = filelib:wildcard(filename:join([Root, "_build", Env, "lib", "*", "ebin"])),
    case EnvDirs of
        [_ | _] -> EnvDirs;
        [] -> filelib:wildcard(filename:join([Root, "_build", "*", "lib", "*", "ebin"]))
    end.
