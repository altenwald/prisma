%% @doc Tests for Prisma LSP server, IO transport, and static diagnostics.
-module(prisma_lsp_tests).

-include_lib("eunit/include/eunit.hrl").
-include("prisma.hrl").

%%% ============================================================================
%%% LSP Diagnostics Tests
%%% ============================================================================

erlang_syntax_error_diagnostic_test() ->
    BadCode = <<"-module(bad_syntax).\n-export([f/0]).\nf( -> ok.\n">>,
    Pplt = prisma_pplt:new(),
    Diags = prisma_lsp_diagnostics:analyze(<<"file:///tmp/bad_syntax.erl">>, <<"erlang">>, BadCode, Pplt),
    ?assert(length(Diags) >= 1),
    [First | _] = Diags,
    ?assertEqual(1, maps:get(<<"severity">>, First)),
    ?assertEqual(<<"Compiler">>, maps:get(<<"source">>, First)),
    Range = maps:get(<<"range">>, First),
    Start = maps:get(<<"start">>, Range),
    ?assertEqual(2, maps:get(<<"line">>, Start)).

erlang_spec_mismatch_diagnostic_test() ->
    MismatchCode = <<"-module(mismatch).\n-export([f/1]).\n-spec f(integer()) -> boolean().\nf(X) -> X + 1.\n">>,
    Pplt = prisma_pplt:new(),
    Diags = prisma_lsp_diagnostics:analyze(<<"file:///tmp/mismatch.erl">>, <<"erlang">>, MismatchCode, Pplt),
    PrismaDiags = [D || D <- Diags, maps:get(<<"source">>, D) =:= <<"Prisma">>],
    ?assert(length(PrismaDiags) >= 1),
    [Diag | _] = PrismaDiags,
    ?assertMatch(#{<<"severity">> := 1}, Diag),
    Msg = maps:get(<<"message">>, Diag),
    ?assert(binary:match(Msg, <<"Gradual spec mismatch">>) =/= nomatch).

elixir_syntax_error_diagnostic_test() ->
    case prisma_lsp_diagnostics:ensure_elixir() of
        ok ->
            BadElixir = <<"defmodule BadElixir do\n  def add(a, b\nend\n">>,
            Pplt = prisma_pplt:new(),
            Diags = prisma_lsp_diagnostics:analyze(<<"file:///tmp/bad_elixir.ex">>, <<"elixir">>, BadElixir, Pplt),
            ?assert(length(Diags) >= 1),
            [First | _] = Diags,
            ?assertEqual(1, maps:get(<<"severity">>, First)),
            ?assertEqual(<<"Compiler">>, maps:get(<<"source">>, First));
        {error, not_found} ->
            ok
    end.

elixir_spec_mismatch_diagnostic_test() ->
    case prisma_lsp_diagnostics:ensure_elixir() of
        ok ->
            ElixirCode = <<"defmodule SpecMismatch do\n  @spec add(integer(), integer()) :: boolean()\n  def add(a, b) do\n    a + b\n  end\nend\n">>,
            Pplt = prisma_pplt:new(),
            Diags = prisma_lsp_diagnostics:analyze(<<"file:///tmp/spec_mismatch.ex">>, <<"elixir">>, ElixirCode, Pplt),
            PrismaDiags = [D || D <- Diags, maps:get(<<"source">>, D) =:= <<"Prisma">>],
            ?assert(length(PrismaDiags) >= 1),
            [Diag | _] = PrismaDiags,
            Msg = maps:get(<<"message">>, Diag),
            ?assert(binary:match(Msg, <<"Gradual spec mismatch">>) =/= nomatch);
        {error, not_found} ->
            ok
    end.

%%% ============================================================================
%%% LSP Framing & Transport Tests
%%% ============================================================================

lsp_frame_parsing_test() ->
    Payload = <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}">>,
    Len = byte_size(Payload),
    Frame = iolist_to_binary([io_lib:format("Content-Length: ~B\r\n\r\n", [Len]), Payload]),
    {ok, Msg, Rest} = prisma_lsp_io:read_msg(Frame),
    ?assertEqual(<<>>, Rest),
    ?assertEqual(1, maps:get(<<"id">>, Msg)),
    ?assertEqual(<<"initialize">>, maps:get(<<"method">>, Msg)).

lsp_server_dispatch_initialize_test() ->
    State0 = prisma_lsp_server:init_state(#{}),
    Params = #{<<"rootUri">> => <<"file:///tmp/test_project">>},
    State1 = prisma_lsp_server:dispatch(<<"initialize">>, 10, Params, State0),
    ?assertNotEqual(undefined, State1).

lsp_server_dispatch_did_open_change_close_test() ->
    State0 = prisma_lsp_server:init_state(#{}),
    Uri = <<"file:///tmp/sample.erl">>,
    Code1 = <<"-module(sample).\n-export([ok/0]).\nok() -> ok.\n">>,
    OpenParams = #{
        <<"textDocument">> => #{
            <<"uri">> => Uri,
            <<"languageId">> => <<"erlang">>,
            <<"version">> => 1,
            <<"text">> => Code1
        }
    },
    State1 = prisma_lsp_server:dispatch(<<"textDocument/didOpen">>, undefined, OpenParams, State0),
    ChangeParams = #{
        <<"textDocument">> => #{<<"uri">> => Uri, <<"version">> => 2},
        <<"contentChanges">> => [#{<<"text">> => <<"-module(sample).\n">>}]
    },
    State2 = prisma_lsp_server:dispatch(<<"textDocument/didChange">>, undefined, ChangeParams, State1),
    CloseParams = #{<<"textDocument">> => #{<<"uri">> => Uri}},
    State3 = prisma_lsp_server:dispatch(<<"textDocument/didClose">>, undefined, CloseParams, State2),
    ?assertNotEqual(undefined, State3).

lsp_server_dispatch_shutdown_test() ->
    State0 = prisma_lsp_server:init_state(#{}),
    State1 = prisma_lsp_server:dispatch(<<"shutdown">>, 99, #{}, State0),
    ?assertEqual(State0, State1).
