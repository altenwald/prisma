%% @doc Mix task (`mix prisma.build`): compiles the project and writes the `.pplt` that a library publishes.
-module('Elixir.Mix.Tasks.Prisma.Build').

-moduledoc """
Compiles the project and writes `<app>_<vsn>.pplt` at the root of each of its applications, made from the beams that were just
compiled (with the hash of the sources, so that whoever uses it can tell if it is stale). It also leaves in `_build/` the `.pplt` of the
dependencies that nobody shipped.

Add the file to what you upload to Hex (`files:` in `mix.exs`), and run this task before `mix hex.publish`.
""".

-export([
    '__info__'/1,
    '__mix_recompile__?'/0,
    run/1
]).

-spec '__info__'(atom()) -> term().
'__info__'(attributes) ->
    [
        {behaviour, ['Elixir.Mix.Task']},
        {shortdoc, [<<"Compiles and writes the .pplt of the project's applications">>]}
    ];
'__info__'(compile) -> [];
'__info__'(functions) -> module_info(functions);
'__info__'(macros) -> [];
'__info__'(md5) -> module_info(md5);
'__info__'(module) -> ?MODULE;
'__info__'(struct) -> nil;
'__info__'(_) -> [].

-spec '__mix_recompile__?'() -> boolean().
'__mix_recompile__?'() ->
    false.

%% @doc Compiles the project and writes its `.pplt`.
-spec run([binary() | string()]) -> ok.
run(_RawArgs) ->
    case code:ensure_loaded('Elixir.Mix.Task') of
        {module, MixTask} -> _ = MixTask:run(<<"compile">>, []);
        _ -> ok
    end,
    code:add_patha(filename:dirname(code:which(?MODULE))),
    case prisma:build_project(".", #{}) of
        {ok, Paths} ->
            [io:format("Built ~ts~n", [P]) || P <- Paths],
            ok;
        {error, Reason} ->
            io:format(standard_error, "Failed to build: ~p~n", [Reason]),
            erlang:halt(1)
    end.
