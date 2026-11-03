-module(prisma_hub_tests).

-include_lib("eunit/include/eunit.hrl").
-include("prisma.hrl").

hub_lifecycle_and_most_demanded_ranking_test() ->
    StorageDir = "/tmp/prisma_dev/tmp_hub_storage",
    os:cmd("rm -rf " ++ StorageDir),

    %% Mock Hex verifier: cowboy 2.10.0 and jason 1.4.1 exist, unknown_pkg does not
    HexChecker = fun
        (<<"cowboy">>, <<"2.10.0">>) -> ok;
        (<<"jason">>, <<"1.4.1">>) -> ok;
        (_, _) -> {error, not_found_in_hex}
    end,

    %% Mock builder: generates a valid #prisma_plt{} for the requested package
    Builder = fun(OtpRel, Pkg, Vsn) ->
        Plt = (prisma_plt:new(Pkg, Vsn))#prisma_plt{otp_release = OtpRel},
        {ok, Plt}
    end,

    {ok,Pid} = prisma_hub:start_link(#{
        storage_dir => StorageDir,
        hex_checker => HexChecker,
        builder => Builder,
        async_build => false
    }),

    %% 1. Requesting a non-existent Hex package returns 404
    ?assertMatch(
        {404, _, _},
        prisma_hub:handle_request(Pid, 'POST', <<"/api/v1/plts/request">>, #{
            <<"otp">> => <<"29">>,
            <<"package">> => <<"unknown_pkg">>,
            <<"version">> => <<"0.0.1">>
        })
    ),

    %% 2. Requesting cowboy 2.10.0 (3 times) and jason 1.4.1 (1 time)
    ?assertMatch(
        {200, _, _},
        prisma_hub:handle_request(Pid, 'POST', <<"/api/v1/plts/request">>, #{
            <<"otp">> => <<"29">>,
            <<"package">> => <<"cowboy">>,
            <<"version">> => <<"2.10.0">>
        })
    ),
    ?assertMatch(
        {200, _, _},
        prisma_hub:handle_request(Pid, 'GET', <<"/api/v1/plts/29/cowboy/2.10.0.splt">>, #{})
    ),
    {200, _, SpltBin} = prisma_hub:handle_request(Pid, 'GET', <<"/api/v1/plts/29/cowboy/2.10.0.splt">>, #{}),
    ?assertMatch({ok, #prisma_plt{package = <<"cowboy">>, package_vsn = <<"2.10.0">>}}, prisma_plt:decode(SpltBin)),

    ?assertMatch(
        {200, _, _},
        prisma_hub:handle_request(Pid, 'POST', <<"/api/v1/plts/request">>, #{
            <<"otp">> => <<"29">>,
            <<"package">> => <<"jason">>,
            <<"version">> => <<"1.4.1">>
        })
    ),

    %% 3. Top demanded PLTs ranking has cowboy first (3 hits) and jason second (1 hit)
    Top = prisma_hub:top_demanded(Pid, 10),
    ?assertMatch(
        [
            #{otp := <<"29">>, package := <<"cowboy">>, version := <<"2.10.0">>, hits := 3, status := ready},
            #{otp := <<"29">>, package := <<"jason">>, version := <<"1.4.1">>, hits := 1, status := ready}
        ],
        Top
    ),

    %% 4. Web dashboard renders HTML with the form and top demanded packages
    {200, HtmlHeaders, HtmlBody} = prisma_hub:handle_request(Pid, 'GET', <<"/">>, #{}),
    ?assertEqual(<<"text/html; charset=utf-8">>, proplists:get_value(<<"content-type">>, HtmlHeaders)),
    ?assertNotEqual(nomatch, binary:match(HtmlBody, <<"Prisma Hub">>)),
    ?assertNotEqual(nomatch, binary:match(HtmlBody, <<"cowboy">>)),
    ?assertNotEqual(nomatch, binary:match(HtmlBody, <<"2.10.0">>)),

    %% 5. Client fetcher integrates with prisma_lock
    Fetcher = prisma_hub:local_fetcher(Pid),
    ?assertMatch({ok, <<?PRISMA_PLT_MAGIC, _/binary>>}, Fetcher(<<"29">>, <<"cowboy">>, <<"2.10.0">>)),
    ?assertEqual(error, Fetcher(<<"29">>, <<"unknown_pkg">>, <<"0.0.1">>)),

    prisma_hub:stop(Pid),
    os:cmd("rm -rf " ++ StorageDir).

async_build_and_api_routes_test() ->
    StorageDir = "/tmp/prisma_dev/tmp_hub_storage_async",
    os:cmd("rm -rf " ++ StorageDir),

    HexChecker = fun
        (<<"ranch">>, <<"1.8.0">>) -> ok;
        (<<"broken_pkg">>, <<"1.0.0">>) -> ok;
        (_, _) -> {error, not_found_in_hex}
    end,
    Builder = fun
        (OtpRel, <<"ranch">> = Pkg, Vsn) ->
            Plt = (prisma_plt:new(Pkg, Vsn))#prisma_plt{otp_release = OtpRel},
            {ok, Plt};
        (_OtpRel, <<"broken_pkg">>, _Vsn) ->
            {error, compile_failed}
    end,

    {ok, Pid} = prisma_hub:start_link(#{
        storage_dir => StorageDir,
        hex_checker => HexChecker,
        builder => Builder,
        async_build => true
    }),

    %% Missing params -> 400
    ?assertMatch({400, _, _}, prisma_hub:handle_request(Pid, 'POST', <<"/api/v1/plts/request">>, #{})),
    %% Unknown routes -> 404
    ?assertMatch({404, _, _}, prisma_hub:handle_request(Pid, 'GET', <<"/unknown">>, #{})),
    ?assertMatch({404, _, _}, prisma_hub:handle_request(Pid, 'GET', <<"/api/v1/plts/bad_route">>, #{})),
    ?assertMatch({404, _, _}, prisma_hub:handle_request(Pid, 'GET', <<"/api/v1/plts/29/nope/1.0.0.splt">>, #{})),

    %% Async request returns 202 building initially
    ?assertMatch(
        {202, _, _},
        prisma_hub:handle_request(Pid, 'POST', <<"/api/v1/plts/request">>, #{
            <<"otp">> => <<"29">>,
            <<"package">> => <<"ranch">>,
            <<"version">> => <<"1.8.0">>
        })
    ),
    timer:sleep(50),
    ?assertMatch(
        {200, _, _},
        prisma_hub:handle_request(Pid, 'GET', <<"/api/v1/plts/29/ranch/1.8.0.splt">>, #{})
    ),

    %% Broken package build transitions to failed (500 on subsequent request)
    ?assertMatch(
        {202, _, _},
        prisma_hub:handle_request(Pid, 'POST', <<"/api/v1/plts/request">>, #{
            <<"otp">> => <<"29">>,
            <<"package">> => <<"broken_pkg">>,
            <<"version">> => <<"1.0.0">>
        })
    ),
    timer:sleep(50),
    ?assertMatch(
        {500, _, _},
        prisma_hub:handle_request(Pid, 'POST', <<"/api/v1/plts/request">>, #{
            <<"otp">> => <<"29">>,
            <<"package">> => <<"broken_pkg">>,
            <<"version">> => <<"1.0.0">>
        })
    ),

    %% GET /api/v1/top returns JSON list
    {200, JsonHeaders, JsonBody} = prisma_hub:handle_request(Pid, 'GET', <<"/api/v1/top">>, #{}),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, JsonHeaders)),
    ?assertNotEqual(nomatch, binary:match(JsonBody, <<"\"package\":\"ranch\"">>)),

    gen_server:cast(Pid, ignored_cast),
    Pid ! ignored_info,
    ?assertEqual({error, bad_request}, gen_server:call(Pid, unknown_call)),

    prisma_hub:stop(Pid),
    os:cmd("rm -rf " ++ StorageDir).
