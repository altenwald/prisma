%% @doc Prisma Hub server, REST API router, and HTML dashboard for Hex.pm `.pplt` files.
%%
%% Verifies packages against Hex.pm, builds `.pplt` artifacts on demand (synchronously
%% or in background workers), tracks demand rankings, and serves `.pplt` binaries.
-module(prisma_hub).

-behaviour(gen_server).

-include("prisma.hrl").

-export([
    start_link/1,
    stop/1,
    request_plt/4,
    get_plt/4,
    top_demanded/2,
    handle_request/4,
    local_fetcher/1,
    render_dashboard/1,
    pplt_storage_path/4
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-record(state, {
    storage_dir :: string(),
    hex_checker :: fun((binary(), binary()) -> ok | {error, term()}),
    builder :: fun((binary(), binary(), binary()) -> {ok, #prisma_plt{}} | {error, term()}),
    async_build = true :: boolean(),
    entries = #{} :: #{{binary(), binary(), binary()} => map()}
}).

%% @doc Starts a `prisma_hub` server process with `Opts`.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% @doc Stops the `prisma_hub` server process.
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

%% @doc Requests generation or lookup of a package `.pplt` for `{Otp, Pkg, Vsn}`.
-spec request_plt(pid(), binary(), binary(), binary()) ->
    {ok, ready | building | failed, map()} | {error, term()}.
request_plt(Pid, Otp, Pkg, Vsn) ->
    gen_server:call(Pid, {request_plt, Otp, Pkg, Vsn}, 30000).

%% @doc Retrieves the `.pplt` binary for `{Otp, Pkg, Vsn}` or triggers generation if absent.
-spec get_plt(pid(), binary(), binary(), binary()) ->
    {ok, ready, binary()} | {ok, building | failed, binary()} | {error, term()}.
get_plt(Pid, Otp, Pkg, Vsn) ->
    case request_plt(Pid, Otp, Pkg, Vsn) of
        {ok, ready, #{path := Path}} ->
            case file:read_file(Path) of
                {ok, Bin} -> {ok, ready, Bin};
                {error, Reason} -> {error, Reason}
            end;
        {ok, Status, _Entry} ->
            {ok, Status, <<>>};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Returns the top `Limit` most requested `.pplt` entries ordered by hit count.
-spec top_demanded(pid(), pos_integer()) -> [map()].
top_demanded(Pid, Limit) ->
    gen_server:call(Pid, {top_demanded, Limit}).

%% @doc Returns a fetcher function compatible with `prisma_lock:resolve_project_plts/2`.
-spec local_fetcher(pid()) -> fun((binary(), binary(), binary()) -> {ok, binary()} | error).
local_fetcher(Pid) ->
    fun(OtpRel, Pkg, Vsn) ->
        case get_plt(Pid, OtpRel, Pkg, Vsn) of
            {ok, ready, Bin} -> {ok, Bin};
            _ -> error
        end
    end.

%% @doc Handles an HTTP-style request (`Method`, `Path`, `Params`) against `Pid`.
-spec handle_request(pid(), 'GET' | 'POST', binary(), map()) ->
    {pos_integer(), [{binary(), binary()}], binary()}.
handle_request(Pid, 'GET', <<"/">>, _Params) ->
    Top = top_demanded(Pid, 25),
    Html = render_dashboard(Top),
    {200, [{<<"content-type">>, <<"text/html; charset=utf-8">>}], Html};
handle_request(Pid, 'GET', <<"/api/v1/top">>, _Params) ->
    Top = top_demanded(Pid, 50),
    Json = encode_top_json(Top),
    {200, [{<<"content-type">>, <<"application/json">>}], Json};
handle_request(Pid, 'POST', <<"/api/v1/plts/request">>, Params) ->
    Otp = maps:get(<<"otp">>, Params, <<>>),
    Pkg = maps:get(<<"package">>, Params, <<>>),
    Vsn = maps:get(<<"version">>, Params, <<>>),
    case Otp =/= <<>> andalso Pkg =/= <<>> andalso Vsn =/= <<>> of
        false ->
            {400, [{<<"content-type">>, <<"application/json">>}], <<"{\"error\":\"missing_parameters\"}">>};
        true ->
            case request_plt(Pid, Otp, Pkg, Vsn) of
                {ok, ready, Entry} ->
                    {200, [{<<"content-type">>, <<"application/json">>}], encode_entry_json(Entry)};
                {ok, building, Entry} ->
                    {202, [{<<"content-type">>, <<"application/json">>}], encode_entry_json(Entry)};
                {ok, failed, Entry} ->
                    {500, [{<<"content-type">>, <<"application/json">>}], encode_entry_json(Entry)};
                {error, not_found_in_hex} ->
                    {404, [{<<"content-type">>, <<"application/json">>}], <<"{\"error\":\"not_found_in_hex\"}">>};
                {error, _} ->
                    {500, [{<<"content-type">>, <<"application/json">>}], <<"{\"error\":\"build_failed\"}">>}
            end
    end;
handle_request(Pid, 'GET', <<"/api/v1/plts/", Rest/binary>>, _Params) ->
    case parse_plt_route(Rest) of
        {ok, Otp, Pkg, Vsn} ->
            case get_plt(Pid, Otp, Pkg, Vsn) of
                {ok, ready, Bin} ->
                    {200, [{<<"content-type">>, <<"application/octet-stream">>}], Bin};
                {ok, building, _} ->
                    {202, [{<<"content-type">>, <<"application/json">>}], <<"{\"status\":\"building\"}">>};
                {error, not_found_in_hex} ->
                    {404, [{<<"content-type">>, <<"application/json">>}], <<"{\"error\":\"not_found_in_hex\"}">>};
                _ ->
                    {500, [{<<"content-type">>, <<"application/json">>}], <<"{\"error\":\"unavailable\"}">>}
            end;
        error ->
            {404, [{<<"content-type">>, <<"application/json">>}], <<"{\"error\":\"not_found\"}">>}
    end;
handle_request(_Pid, _Method, _Path, _Params) ->
    {404, [{<<"content-type">>, <<"application/json">>}], <<"{\"error\":\"not_found\"}">>}.

parse_plt_route(Route) ->
    case binary:split(Route, <<"/">>, [global]) of
        [Otp, Pkg, VsnFile] ->
            case binary:split(VsnFile, <<".pplt">>) of
                [Vsn, <<>>] when Otp =/= <<>>, Pkg =/= <<>>, Vsn =/= <<>> ->
                    {ok, Otp, Pkg, Vsn};
                _ ->
                    error
            end;
        _ ->
            error
    end.

%% @doc Computes the filesystem storage path for a Hub `.pplt` artifact.
-spec pplt_storage_path(file:filename_all(), binary(), binary(), binary()) -> string().
pplt_storage_path(StorageDir, Otp, Pkg, Vsn) ->
    File = binary_to_list(<<Pkg/binary, "-", Vsn/binary, ".pplt">>),
    filename:join([unicode:characters_to_list(StorageDir), "otp-" ++ binary_to_list(Otp), File]).

%% @doc Renders the HTML dashboard with the request form and most demanded PLTs table.
-spec render_dashboard([map()]) -> binary().
render_dashboard(TopEntries) ->
    Rows = [render_row(E) || E <- TopEntries],
    iolist_to_binary([
        <<"<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">">>,
        <<"<title>Prisma Hub - Modular BEAM PLTs</title></head><body>">>,
        <<"<h1>Prisma Hub</h1>">>,
        <<"<p>On-demand portable <code>.pplt</code> generator and cache for Hex.pm packages.</p>">>,
        <<"<form method=\"POST\" action=\"/api/v1/plts/request\">">>,
        <<"<input name=\"otp\" placeholder=\"OTP (e.g. 29)\" required>">>,
        <<"<input name=\"package\" placeholder=\"Hex Package (e.g. cowboy)\" required>">>,
        <<"<input name=\"version\" placeholder=\"Version (e.g. 2.10.0)\" required>">>,
        <<"<button type=\"submit\">Request .pplt</button></form>">>,
        <<"<h2>Most Demanded PLTs</h2>">>,
        <<"<table><thead><tr><th>OTP</th><th>Package</th><th>Version</th><th>Status</th><th>Hits</th><th>Download</th></tr></thead><tbody>">>,
        Rows,
        <<"</tbody></table></body></html>">>
    ]).

render_row(#{otp := Otp, package := Pkg, version := Vsn, status := Status, hits := Hits}) ->
    StatusBin = atom_to_binary(Status, utf8),
    HitsBin = integer_to_binary(Hits),
    Url = <<"/api/v1/plts/", Otp/binary, "/", Pkg/binary, "/", Vsn/binary, ".pplt">>,
    [
        <<"<tr><td>">>, Otp, <<"</td><td>">>, Pkg, <<"</td><td>">>, Vsn,
        <<"</td><td>">>, StatusBin, <<"</td><td>">>, HitsBin,
        <<"</td><td><a href=\"">>, Url, <<"\">.pplt</a></td></tr>">>
    ].

encode_top_json(Entries) ->
    Items = lists:join(<<",">>, [encode_entry_json(E) || E <- Entries]),
    iolist_to_binary([<<"[">>, Items, <<"]">>]).

encode_entry_json(#{otp := Otp, package := Pkg, version := Vsn, status := Status, hits := Hits}) ->
    iolist_to_binary([
        <<"{\"otp\":\"">>, Otp,
        <<"\",\"package\":\"">>, Pkg,
        <<"\",\"version\":\"">>, Vsn,
        <<"\",\"status\":\"">>, atom_to_binary(Status, utf8),
        <<"\",\"hits\":">>, integer_to_binary(Hits),
        <<"}">>
    ]).

init(Opts) ->
    StorageDir = unicode:characters_to_list(maps:get(storage_dir, Opts, "/tmp/prisma_hub")),
    HexChecker = maps:get(hex_checker, Opts, fun default_hex_check/2),
    Builder = maps:get(builder, Opts, fun default_plt_builder/3),
    Async = maps:get(async_build, Opts, true),
    {ok, #state{
        storage_dir = StorageDir,
        hex_checker = HexChecker,
        builder = Builder,
        async_build = Async,
        entries = #{}
    }}.

handle_call({request_plt, Otp, Pkg, Vsn}, _From, #state{entries = Entries} = State) ->
    Key = {Otp, Pkg, Vsn},
    case maps:find(Key, Entries) of
        {ok, #{hits := Hits, status := Status} = Existing} ->
            Updated = Existing#{hits => Hits + 1},
            {reply, {ok, Status, Updated}, State#state{entries = Entries#{Key => Updated}}};
        error ->
            handle_new_plt_request(Key, State)
    end;
handle_call({top_demanded, Limit}, _From, #state{entries = Entries} = State) ->
    Sorted = lists:sort(
        fun(#{hits := H1, package := P1, version := V1}, #{hits := H2, package := P2, version := V2}) ->
            {H1, P2, V2} >= {H2, P1, V1}
        end,
        maps:values(Entries)
    ),
    {reply, lists:sublist(Sorted, Limit), State};
handle_call(_Req, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({build_complete, Key, {ok, Path, ModCount}}, #state{entries = Entries} = State) ->
    case maps:find(Key, Entries) of
        {ok, Entry} ->
            Updated = Entry#{status => ready, path => Path, modules_count => ModCount},
            {noreply, State#state{entries = Entries#{Key => Updated}}};
        error ->
            {noreply, State}
    end;
handle_info({build_complete, Key, {error, _Reason}}, #state{entries = Entries} = State) ->
    case maps:find(Key, Entries) of
        {ok, Entry} ->
            Updated = Entry#{status => failed},
            {noreply, State#state{entries = Entries#{Key => Updated}}};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

handle_new_plt_request({Otp, Pkg, Vsn} = Key, #state{
    storage_dir = StorageDir,
    hex_checker = HexChecker,
    builder = Builder,
    async_build = Async,
    entries = Entries
} = State) ->
    case HexChecker(Pkg, Vsn) of
        ok ->
            Path = pplt_storage_path(StorageDir, Otp, Pkg, Vsn),
            BaseEntry = #{
                otp => Otp,
                package => Pkg,
                version => Vsn,
                hits => 1,
                status => building,
                path => Path,
                modules_count => 0
            },
            case Async of
                true ->
                    Self = self(),
                    spawn(fun() ->
                        Res = execute_build(Builder, Otp, Pkg, Vsn, Path),
                        Self ! {build_complete, Key, Res}
                    end),
                    {reply, {ok, building, BaseEntry}, State#state{entries = Entries#{Key => BaseEntry}}};
                false ->
                    case execute_build(Builder, Otp, Pkg, Vsn, Path) of
                        {ok, SavedPath, ModCount} ->
                            ReadyEntry = BaseEntry#{status => ready, path => SavedPath, modules_count => ModCount},
                            {reply, {ok, ready, ReadyEntry}, State#state{entries = Entries#{Key => ReadyEntry}}};
                        {error, Reason} ->
                            {reply, {error, Reason}, State}
                    end
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

execute_build(Builder, Otp, Pkg, Vsn, Path) ->
    case Builder(Otp, Pkg, Vsn) of
        {ok, #prisma_plt{} = Plt} ->
            case prisma_plt:save(Plt, Path) of
                ok ->
                    {ok, Path, length(prisma_plt:modules(Plt))};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

default_hex_check(Pkg, Vsn) when is_binary(Pkg), is_binary(Vsn) ->
    Url = "https://hex.pm/api/packages/" ++ binary_to_list(Pkg) ++ "/releases/" ++ binary_to_list(Vsn),
    case httpc:request(get, {Url, [{"user-agent", "prisma-hub/0.1.0"}]}, [{timeout, 5000}], []) of
        {ok, {{_, 200, _}, _, _}} -> ok;
        {ok, {{_, 404, _}, _, _}} -> {error, not_found_in_hex};
        {error, Reason} -> {error, Reason};
        _ -> {error, hex_unreachable}
    end.

default_plt_builder(Otp, Pkg, Vsn) ->
    Plt = (prisma_plt:new(Pkg, Vsn))#prisma_plt{otp_release = Otp},
    {ok, Plt}.
