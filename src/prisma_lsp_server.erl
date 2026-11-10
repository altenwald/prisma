%% @doc Language Server Protocol (LSP) Server for Erlang and Elixir.
%%
%% Communicates via JSON-RPC 2.0 over standard I/O, emitting compilation and
%% Prisma type/contract diagnostics while keeping stdout clean for LSP frames.
-module(prisma_lsp_server).

-include("prisma.hrl").

-export([
    start/0,
    start/1,
    init_state/1,
    dispatch/4
]).

-record(state, {
    root_uri = undefined :: binary() | undefined,
    root_path = undefined :: string() | undefined,
    docs = #{} :: #{binary() => #{text => binary(), version => integer(), lang => binary()}},
    pplt :: #prisma_pplt{}
}).

%% @doc Creates an initial server state with given Pplt or defaults.
-spec init_state(map()) -> #state{}.
init_state(Opts) ->
    Pplt = maps:get(pplt, Opts, prisma_pplt:new()),
    #state{pplt = Pplt}.

%% @doc Starts the LSP server.
-spec start() -> no_return().
start() ->
    start(#{}).

%% @doc Starts the LSP server with initial options.
-spec start(map()) -> no_return().
start(_Opts) ->
    ok = prisma_lsp_io:init(),
    prisma_lsp_io:log("Starting Prisma Language Server v~s...", [prisma:version()]),
    Pplt = load_initial_pplt("."),
    State = #state{
        pplt = Pplt
    },
    loop(State, <<>>).

%%% ============================================================================
%%% Server loop
%%% ============================================================================

loop(State, Buffer) ->
    case prisma_lsp_io:read_msg(Buffer) of
        {ok, Msg, Remaining} ->
            NewState = handle_msg(Msg, State),
            loop(NewState, Remaining);
        eof ->
            prisma_lsp_io:log("Input stream closed (EOF). Terminating."),
            erlang:halt(0);
        {error, Reason} ->
            prisma_lsp_io:log("LSP transport error: ~p", [Reason]),
            loop(State, <<>>)
    end.

handle_msg(#{<<"method">> := Method} = Msg, State) ->
    Id = maps:get(<<"id">>, Msg, undefined),
    Params = maps:get(<<"params">>, Msg, #{}),
    dispatch(Method, Id, Params, State);
handle_msg(Msg, State) ->
    prisma_lsp_io:log("Unhandled message without method: ~p", [Msg]),
    State.

dispatch(<<"initialize">>, Id, Params, State) ->
    RootUri = maps:get(<<"rootUri">>, Params, undefined),
    RootPath = case RootUri of
        Bin when is_binary(Bin) -> prisma_lsp_diagnostics:uri_to_path(Bin);
        _ -> "."
    end,
    Pplt = load_initial_pplt(RootPath),
    Result = #{
        <<"capabilities">> => #{
            <<"textDocumentSync">> => #{
                <<"openClose">> => true,
                <<"change">> => 1, %% Full document sync
                <<"save">> => #{<<"includeText">> => true}
            }
        },
        <<"serverInfo">> => #{
            <<"name">> => <<"prisma_ls">>,
            <<"version">> => prisma:version()
        }
    },
    prisma_lsp_io:send_response(Id, Result),
    State#state{root_uri = RootUri, root_path = RootPath, pplt = Pplt};

dispatch(<<"initialized">>, _Id, _Params, State) ->
    prisma_lsp_io:log("Client initialized connection."),
    State;

dispatch(<<"shutdown">>, Id, _Params, State) ->
    prisma_lsp_io:log("Client requested shutdown."),
    prisma_lsp_io:send_response(Id, null),
    State;

dispatch(<<"exit">>, _Id, _Params, _State) ->
    prisma_lsp_io:log("Client sent exit. Halting."),
    erlang:halt(0);

dispatch(<<"textDocument/didOpen">>, _Id, Params, State) ->
    Doc = maps:get(<<"textDocument">>, Params, #{}),
    Uri = maps:get(<<"uri">>, Doc, <<>>),
    LangId = maps:get(<<"languageId">>, Doc, <<>>),
    Text = maps:get(<<"text">>, Doc, <<>>),
    Vsn = maps:get(<<"version">>, Doc, 0),
    NewDocs = maps:put(Uri, #{text => Text, version => Vsn, lang => LangId}, State#state.docs),
    publish_diagnostics(Uri, LangId, Text, State#state.pplt),
    State#state{docs = NewDocs};

dispatch(<<"textDocument/didChange">>, _Id, Params, State) ->
    Doc = maps:get(<<"textDocument">>, Params, #{}),
    Uri = maps:get(<<"uri">>, Doc, <<>>),
    Vsn = maps:get(<<"version">>, Doc, 0),
    Changes = maps:get(<<"contentChanges">>, Params, []),
    DocInfo = maps:get(Uri, State#state.docs, #{lang => <<>>}),
    LangId = maps:get(lang, DocInfo, <<>>),
    Text = case Changes of
        [#{<<"text">> := FullText} | _] -> FullText;
        _ -> maps:get(text, DocInfo, <<>>)
    end,
    NewDocs = maps:put(Uri, DocInfo#{text => Text, version => Vsn}, State#state.docs),
    publish_diagnostics(Uri, LangId, Text, State#state.pplt),
    State#state{docs = NewDocs};

dispatch(<<"textDocument/didSave">>, _Id, Params, State) ->
    Doc = maps:get(<<"textDocument">>, Params, #{}),
    Uri = maps:get(<<"uri">>, Doc, <<>>),
    DocInfo = maps:get(Uri, State#state.docs, #{lang => <<>>}),
    LangId = maps:get(lang, DocInfo, <<>>),
    TextOpt = maps:get(<<"text">>, Params, maps:get(text, DocInfo, undefined)),
    publish_diagnostics(Uri, LangId, TextOpt, State#state.pplt),
    State;

dispatch(<<"textDocument/didClose">>, _Id, Params, State) ->
    Doc = maps:get(<<"textDocument">>, Params, #{}),
    Uri = maps:get(<<"uri">>, Doc, <<>>),
    NewDocs = maps:remove(Uri, State#state.docs),
    %% Clear diagnostics on close
    prisma_lsp_io:send_notification(<<"textDocument/publishDiagnostics">>, #{
        <<"uri">> => Uri,
        <<"diagnostics">> => []
    }),
    State#state{docs = NewDocs};

dispatch(Method, Id, _Params, State) ->
    prisma_lsp_io:log("Ignored unhandled method: ~ts", [Method]),
    case Id of
        undefined ->
            ok;
        _ ->
            %% Return method not found (-32601) for unhandled requests
            prisma_lsp_io:send_response(Id, -32601, <<"Method not found: ", Method/binary>>)
    end,
    State.

publish_diagnostics(Uri, LangId, TextOpt, Pplt) ->
    Diags = prisma_lsp_diagnostics:analyze(Uri, LangId, TextOpt, Pplt),
    prisma_lsp_io:send_notification(<<"textDocument/publishDiagnostics">>, #{
        <<"uri">> => Uri,
        <<"diagnostics">> => Diags
    }).

load_initial_pplt(RootPath) ->
    case filelib:wildcard(filename:join([RootPath, "_build", "*", "*.pplt"])) of
        [] ->
            prisma_pplt:new();
        [First | _] = Files ->
            prisma_lsp_io:log("Discovered ~B .pplt files in project, loading ~s...", [length(Files), First]),
            case prisma_pplt:load(First) of
                {ok, P} -> P;
                _ -> prisma_pplt:new()
            end
    end.
