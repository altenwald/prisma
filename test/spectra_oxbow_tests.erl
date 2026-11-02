-module(spectra_oxbow_tests).

-include_lib("eunit/include/eunit.hrl").
-include("spectra.hrl").

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
    Summary = spectra_abstract:parse_abstract_forms(Forms, [{main, 0}], #module_summary{module = test_oxbow_unused}),
    Warns = spectra_oxbow:check_module(Summary),
    ?assertEqual(2, length(Warns)),
    [W1, W2] = lists:sort(fun(A, B) -> A#spectra_warning.line =< B#spectra_warning.line end, Warns),

    ?assertEqual(oxbow_code, W1#spectra_warning.kind),
    ?assertEqual({test_oxbow_unused, dead1, 0}, W1#spectra_warning.mfa),
    ?assertEqual(5, W1#spectra_warning.line),
    ?assert(binary:match(W1#spectra_warning.message, <<"dead1/0 is never called">>) =/= nomatch),

    ?assertEqual(oxbow_code, W2#spectra_warning.kind),
    ?assertEqual({test_oxbow_unused, dead2, 0}, W2#spectra_warning.mfa),
    ?assertEqual(6, W2#spectra_warning.line),
    ?assert(binary:match(W2#spectra_warning.message, <<"dead2/0 is never called">>) =/= nomatch).

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
    Summary = spectra_abstract:parse_abstract_forms(Forms, [{runner, 0}], #module_summary{module = test_fun_reach}),
    Warns = spectra_oxbow:check_module(Summary),
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
    Summary = spectra_abstract:parse_abstract_forms(Forms, [{entry, 1}], #module_summary{module = test_oxbow_params}),
    Warns = spectra_oxbow:check_module(Summary),
    ?assertEqual(1, length(Warns)),
    [W] = Warns,
    ?assertEqual(oxbow_code, W#spectra_warning.kind),
    ?assertEqual({test_oxbow_params, private_worker, 2}, W#spectra_warning.mfa),
    ?assertEqual(2, W#spectra_warning.arg_idx),
    ?assert(binary:match(W#spectra_warning.message, <<"argument #2 is ignored across all clauses">>) =/= nomatch).

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
    Summary = spectra_abstract:parse_abstract_forms(Forms, [{run, 0}], #module_summary{module = test_oxbow_used_var}),
    Warns = spectra_oxbow:check_module(Summary),
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
    Summary = spectra_abstract:parse_abstract_forms(Forms, [{public_api, 2}], #module_summary{module = test_oxbow_exempt}),
    Warns = spectra_oxbow:check_module(Summary),
    ?assertEqual([], Warns).

oxbow_disable_option_test() ->
    Forms = [
        {attribute, 1, module, test_oxbow_opt},
        {attribute, 2, export, [{entry, 0}]},
        {function, 3, entry, 0, [{clause, 3, [], [], [{atom, 3, ok}]}]},
        {function, 4, dead, 0, [{clause, 4, [], [], [{atom, 4, ok}]}]}
    ],
    Summary = spectra_abstract:parse_abstract_forms(Forms, [{entry, 0}], #module_summary{module = test_oxbow_opt}),
    Plt = spectra_plt:new(),
    WithOxbow = spectra_checker:check_module(Summary, Plt, #{oxbow => true}),
    ?assertEqual(1, length(WithOxbow)),
    WithoutOxbow = spectra_checker:check_module(Summary, Plt, #{oxbow => false}),
    ?assertEqual([], WithoutOxbow).
