%% @doc Mix task (`mix spectra`) compiled directly as a BEAM module for Elixir projects.
-module('Elixir.Mix.Tasks.Spectra').

-export([
    '__mix_recompile__?'/0,
    run/1
]).

-spec '__mix_recompile__?'() -> boolean().
'__mix_recompile__?'() ->
    false.

%% @doc Runs Spectra analysis within an Elixir Mix project.
-spec run([binary()]) -> ok.
run(Args) ->
    case code:ensure_loaded('Elixir.Mix.Task') of
        {module, MixTask} ->
            _ = MixTask:run(<<"compile">>, []);
        _ ->
            ok
    end,
    Dirs = resolve_elixir_ebin_dirs(Args),
    case spectra:analyze_dirs(Dirs) of
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

resolve_elixir_ebin_dirs([]) ->
    case code:ensure_loaded('Elixir.Mix.Project') of
        {module, MixProject} ->
            BuildPath = MixProject:compile_path(),
            [unicode:characters_to_list(BuildPath)];
        _ ->
            filelib:wildcard("_build/*/lib/*/ebin")
    end;
resolve_elixir_ebin_dirs(Args) ->
    [unicode:characters_to_list(A) || A <- Args].
