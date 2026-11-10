%% @doc LSP JSON-RPC transport over standard input/output.
-module(prisma_lsp_io).

-export([
    init/0,
    read_msg/1,
    send_msg/1,
    send_response/2,
    send_response/3,
    send_notification/2,
    log/1,
    log/2
]).

%% @doc Configures standard_io for raw binary byte streams without encoding distortion.
-spec init() -> ok.
init() ->
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    ok.

%% @doc Reads an LSP frame from the current binary buffer or standard_io.
%% Returns `{ok, DecodedJson, RemainingBuffer}` or `eof` or `{error, Reason}`.
-spec read_msg(binary()) -> {ok, map(), binary()} | eof | {error, term()}.
read_msg(Buffer) ->
    case parse_frame(Buffer) of
        {ok, Msg, Rest} ->
            {ok, Msg, Rest};
        need_more ->
            case io:get_chars(standard_io, '', 4096) of
                eof ->
                    eof;
                {error, Reason} ->
                    {error, Reason};
                Chunk when is_binary(Chunk) ->
                    read_msg(<<Buffer/binary, Chunk/binary>>)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Sends a JSON-RPC message map over standard_io.
-spec send_msg(map()) -> ok.
send_msg(Msg) when is_map(Msg) ->
    MsgWithVersion = Msg#{<<"jsonrpc">> => <<"2.0">>},
    Payload = iolist_to_binary(json:encode(MsgWithVersion)),
    Len = byte_size(Payload),
    Header = io_lib:format("Content-Length: ~B\r\n\r\n", [Len]),
    io:put_chars(standard_io, [Header, Payload]),
    ok.

%% @doc Sends a successful JSON-RPC response with `Id` and `Result`.
-spec send_response(term(), term()) -> ok.
send_response(Id, Result) ->
    send_msg(#{<<"id">> => Id, <<"result">> => Result}).

%% @doc Sends an error JSON-RPC response.
-spec send_response(term(), integer(), binary()) -> ok.
send_response(Id, Code, Message) ->
    send_msg(#{
        <<"id">> => Id,
        <<"error">> => #{
            <<"code">> => Code,
            <<"message">> => Message
        }
    }).

%% @doc Sends a JSON-RPC notification (no `id`).
-spec send_notification(binary(), map()) -> ok.
send_notification(Method, Params) when is_binary(Method), is_map(Params) ->
    send_msg(#{
        <<"method">> => Method,
        <<"params">> => Params
    }).

%% @doc Logs a debug message to standard_error (never stdout).
-spec log(string()) -> ok.
log(Format) ->
    log(Format, []).

-spec log(string(), [term()]) -> ok.
log(Format, Args) ->
    io:format(standard_error, "[prisma_ls] " ++ Format ++ "~n", Args).

%%% ============================================================================
%%% Internal frame parsing
%%% ============================================================================

parse_frame(Buffer) ->
    case binary:split(Buffer, <<"\r\n\r\n">>) of
        [Headers, Rest] ->
            Lines = binary:split(Headers, <<"\r\n">>, [global]),
            case extract_content_length(Lines) of
                {ok, Len} ->
                    case byte_size(Rest) >= Len of
                        true ->
                            <<Payload:Len/binary, Next/binary>> = Rest,
                            try json:decode(Payload) of
                                Decoded when is_map(Decoded) ->
                                    {ok, Decoded, Next};
                                Other ->
                                    {error, {invalid_json_payload, Other}}
                            catch
                                _:Err ->
                                    {error, {json_decode_failed, Err}}
                            end;
                        false ->
                            need_more
                    end;
                error ->
                    {error, missing_content_length}
            end;
        _ ->
            need_more
    end.

extract_content_length([]) ->
    error;
extract_content_length([Line | Rest]) ->
    Lower = string:lowercase(Line),
    case Lower of
        <<"content-length:", Val/binary>> ->
            {ok, binary_to_integer(string:trim(Val))};
        _ ->
            extract_content_length(Rest)
    end.
