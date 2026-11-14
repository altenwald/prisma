-module(prisma_oxbow_tests).

-include_lib("eunit/include/eunit.hrl").
-include("prisma.hrl").

unused_private_function_detection_test() ->
    %% Forms corresponding to:
    %% -module(test_oxbow_unused).
    %% -export([main/0]).
    %% main() -> alive().
    %% alive() -> ok.
    %% dead1() -> dead2().
    %% dead2() -> ok.
    Forms = [
        {attribute, 1, module, test_oxbow_unused},
        {attribute, 2, export, [{main, 0}]},
        {function, 3, main, 0, [
            {clause, 3, [], [], [{call, 3, {atom, 3, alive}, []}]}
        ]},
        {function, 4, alive, 0, [
            {clause, 4, [], [], [{atom, 4, ok}]}
        ]},
        {function, 5, dead1, 0, [
            {clause, 5, [], [], [{call, 5, {atom, 5, dead2}, []}]}
        ]},
        {function, 6, dead2, 0, [
            {clause, 6, [], [], [{atom, 6, ok}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{main, 0}], #module_summary{module = test_oxbow_unused}),
    Warns = prisma_oxbow:check_module(Summary),
    ?assertEqual(2, length(Warns)),
    [W1, W2] = lists:sort(fun(A, B) -> A#prisma_warning.line =< B#prisma_warning.line end, Warns),

    ?assertEqual(oxbow_code, W1#prisma_warning.kind),
    ?assertEqual({test_oxbow_unused, dead1, 0}, W1#prisma_warning.mfa),
    ?assertEqual(5, W1#prisma_warning.line),
    ?assert(binary:match(W1#prisma_warning.message, <<"dead1/0 is never called">>) =/= nomatch),

    ?assertEqual(oxbow_code, W2#prisma_warning.kind),
    ?assertEqual({test_oxbow_unused, dead2, 0}, W2#prisma_warning.mfa),
    ?assertEqual(6, W2#prisma_warning.line),
    ?assert(binary:match(W2#prisma_warning.message, <<"dead2/0 is never called">>) =/= nomatch).

fun_capture_reachability_test() ->
    %% An unexported function referenced via `fun helper/1` in an exported function
    %% is reachable and must NOT be flagged as oxbow.
    Forms = [
        {attribute, 1, module, test_fun_reach},
        {attribute, 2, export, [{runner, 0}]},
        {function, 3, runner, 0, [
            {clause, 3, [], [], [
                {call, 3, {remote, 3, {atom, 3, lists}, {atom, 3, map}}, [
                    {'fun', 3, {function, helper, 1}},
                    {nil, 3}
                ]}
            ]}
        ]},
        {function, 4, helper, 1, [
            {clause, 4, [{var, 4, 'X'}], [], [{var, 4, 'X'}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{runner, 0}], #module_summary{module = test_fun_reach}),
    Warns = prisma_oxbow:check_module(Summary),
    ?assertEqual([], Warns).

unused_ignored_parameter_test() ->
    %% Forms corresponding to:
    %% -module(test_oxbow_params).
    %% -export([entry/1]).
    %% entry(Val) -> private_worker(Val, unused_arg).
    %% private_worker(Active, _Ignored) -> Active + 1.
    Forms = [
        {attribute, 1, module, test_oxbow_params},
        {attribute, 2, export, [{entry, 1}]},
        {function, 3, entry, 1, [
            {clause, 3, [{var, 3, 'Val'}], [], [
                {call, 3, {atom, 3, private_worker}, [{var, 3, 'Val'}, {atom, 3, unused_arg}]}
            ]}
        ]},
        {function, 4, private_worker, 2, [
            {clause, 4, [{var, 4, 'Active'}, {var, 4, '_Ignored'}], [], [
                {op, 4, '+', [{var, 4, 'Active'}, {integer, 4, 1}]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{entry, 1}], #module_summary{module = test_oxbow_params}),
    Warns = prisma_oxbow:check_module(Summary),
    ?assertEqual(1, length(Warns)),
    [W] = Warns,
    ?assertEqual(oxbow_code, W#prisma_warning.kind),
    ?assertEqual({test_oxbow_params, private_worker, 2}, W#prisma_warning.mfa),
    ?assertEqual(2, W#prisma_warning.arg_idx),
    ?assert(binary:match(W#prisma_warning.message, <<"argument #2 is ignored across all clauses">>) =/= nomatch).

used_underscore_param_not_flagged_test() ->
    %% An argument named `_Used` that is actually referenced in body must NOT be flagged.
    Forms = [
        {attribute, 1, module, test_oxbow_used_var},
        {attribute, 2, export, [{run, 0}]},
        {function, 3, run, 0, [
            {clause, 3, [], [], [{call, 3, {atom, 3, sub}, [{integer, 3, 42}]}]}
        ]},
        {function, 4, sub, 1, [
            {clause, 4, [{var, 4, '_Used'}], [], [{var, 4, '_Used'}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{run, 0}], #module_summary{module = test_oxbow_used_var}),
    Warns = prisma_oxbow:check_module(Summary),
    ?assertEqual([], Warns).

compiler_generated_and_exported_exemptions_test() ->
    %% Exported functions and compiler generated (__*) functions must never have their
    %% parameters or definitions falsely accused of being oxbow code.
    Forms = [
        {attribute, 1, module, test_oxbow_exempt},
        {attribute, 2, export, [{public_api, 2}]},
        {function, 3, public_api, 2, [
            {clause, 3, [{var, 3, 'Active'}, {var, 3, '_IgnoredPublic'}], [], [{var, 3, 'Active'}]}
        ]},
        {function, 4, '__info__', 1, [
            {clause, 4, [{var, 4, '_'}], [], [{atom, 4, ok}]}
        ]},
        {function, 5, module_info, 0, [
            {clause, 5, [], [], [{atom, 5, ok}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{public_api, 2}], #module_summary{module = test_oxbow_exempt}),
    Warns = prisma_oxbow:check_module(Summary),
    ?assertEqual([], Warns).

oxbow_disable_option_test() ->
    Forms = [
        {attribute, 1, module, test_oxbow_opt},
        {attribute, 2, export, [{entry, 0}]},
        {function, 3, entry, 0, [{clause, 3, [], [], [{atom, 3, ok}]}]},
        {function, 4, dead, 0, [{clause, 4, [], [], [{atom, 4, ok}]}]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{entry, 0}], #module_summary{module = test_oxbow_opt}),
    Pplt = prisma_pplt:new(),
    WithOxbow = prisma_checker:check_module(Summary, Pplt, #{oxbow => true}),
    ?assertEqual(1, length(WithOxbow)),
    WithoutOxbow = prisma_checker:check_module(Summary, Pplt, #{oxbow => false}),
    ?assertEqual([], WithoutOxbow).

fun_capture_fixed_arity_param_not_flagged_test() ->
    %% Private function passed via fun_ref (&check_environment/3) has fixed arity
    %% imposed by the callback/hook contract and must not flag ignored params.
    Forms = [
        {attribute, 1, module, test_oxbow_capture_param},
        {attribute, 2, export, [{on_mount, 1}]},
        {function, 3, on_mount, 1, [
            {clause, 3, [{var, 3, 'Socket'}], [], [
                {call, 4, {remote, 4, {atom, 4, 'Elixir.Phoenix.LiveView'}, {atom, 4, attach_hook}}, [
                    {var, 4, 'Socket'},
                    {atom, 4, hook_name},
                    {atom, 4, handle_params},
                    {'fun', 4, {function, check_environment, 3}}
                ]}
            ]}
        ]},
        {function, 8, check_environment, 3, [
            {clause, 8, [{var, 8, 'Params'}, {var, 8, '_Url'}, {var, 8, 'Socket'}], [], [
                {tuple, 8, [{atom, 8, cont}, {var, 8, 'Socket'}, {var, 8, 'Params'}]}
            ]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{on_mount, 1}], #module_summary{module = test_oxbow_capture_param}),
    ?assertEqual([], prisma_oxbow:check_module(Summary)).

macro_plug_call_fixed_arity_param_not_flagged_test() ->
    %% Private plug function called from a macro-generated pipeline (line 1 / @Elixir.Plug.Builder)
    %% has fixed arity 2 and must not flag ignored _opts.
    Forms = [
        {attribute, 1, module, test_oxbow_plug_param},
        {attribute, 2, export, [{phoenix_controller_pipeline, 2}]},
        {function, 1, phoenix_controller_pipeline, 2, [
            {clause, 1, [{var, 1, 'conn@0@Elixir.Plug.Builder'}, {var, 1, '_action'}], [], [
                {call, 1, {atom, 1, no_store}, [{var, 1, 'conn@0@Elixir.Plug.Builder'}, {nil, 1}]}
            ]}
        ]},
        {function, 12, no_store, 2, [
            {clause, 12, [{var, 12, 'Conn'}, {var, 12, '_Opts'}], [], [{var, 12, 'Conn'}]}
        ]}
    ],
    Summary = prisma_abstract:parse_abstract_forms(Forms, [{phoenix_controller_pipeline, 2}], #module_summary{module = test_oxbow_plug_param}),
    ?assertEqual([], prisma_oxbow:check_module(Summary)).
