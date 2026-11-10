%% @doc Rebar3 provider for `rebar3 prisma lsp`.
-module(prisma_prv_lsp).

-export([
    init/1,
    do/1,
    format_error/1
]).

-define(PROVIDER, lsp).
-define(NAMESPACE, prisma).
-define(DEPS, []).

%% @doc Registers the `prisma lsp` provider with Rebar3.
-spec init(term()) -> {ok, term()}.
init(State) ->
    case code:ensure_loaded(providers) of
        {module, providers} ->
            Provider = providers:create([
                {namespace, ?NAMESPACE},
                {name, ?PROVIDER},
                {module, ?MODULE},
                {bare, true},
                {deps, ?DEPS},
                {example, "rebar3 prisma lsp"},
                {opts, []},
                {short_desc, "Start Prisma Language Server (LSP)"},
                {desc, "Starts the Prisma LSP server communicating over standard I/O for editor integration."}
            ]),
            {ok, rebar_state:add_provider(State, Provider)};
        _ ->
            {ok, State}
    end.

%% @doc Executes the LSP server.
-spec do(term()) -> {ok, term()} | {error, term()}.
do(State) ->
    prisma_lsp_server:start(),
    {ok, State}.

%% @doc Formats an error.
-spec format_error(term()) -> iolist().
format_error(Reason) ->
    io_lib:format("Prisma LSP error: ~p", [Reason]).
