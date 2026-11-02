-module(spectra_infer_tests).

-include_lib("eunit/include/eunit.hrl").
-include("spectra.hrl").

type_meet_test() ->
    ?assertEqual(integer, spectra_type:meet(any, integer)),
    ?assertEqual(none, spectra_type:meet(none, integer)),
    ?assertEqual(pos_integer, spectra_type:meet(number, pos_integer)),
    ?assertEqual(pos_integer, spectra_type:meet(integer, pos_integer)),
    ?assertEqual({int_lit, 5}, spectra_type:meet(pos_integer, {int_lit, 5})),
    ?assertEqual(none, spectra_type:meet(pos_integer, {int_lit, -1})),
    ?assertEqual(none, spectra_type:meet(neg_integer, {int_lit, 0})),
    ?assertEqual({int_lit, 0}, spectra_type:meet(non_neg_integer, {int_lit, 0})),
    ?assertEqual({int_range, 5, 10}, spectra_type:meet({int_range, 1, 10}, {int_range, 5, 20})),
    ?assertEqual({int_lit, 5}, spectra_type:meet({int_range, 1, 5}, {int_range, 5, 10})),
    ?assertEqual(none, spectra_type:meet({int_range, 1, 4}, {int_range, 5, 10})),
    ?assertEqual({atom_lit, true}, spectra_type:meet(boolean, {atom_lit, true})),
    ?assertEqual(none, spectra_type:meet(boolean, {atom_lit, ok})),
    ?assertEqual({nonempty_list, integer}, spectra_type:meet({list, number}, {nonempty_list, integer})),
    ?assertEqual(nil, spectra_type:meet({list, integer}, {list, atom})),
    ?assertEqual(none, spectra_type:meet({nonempty_list, integer}, {nonempty_list, atom})),
    ?assertEqual(
        {tuple, [{atom_lit, ok}, integer]},
        spectra_type:meet({tuple, [atom, number]}, {tuple, [{atom_lit, ok}, integer]})
    ),
    ?assertEqual(none, spectra_type:meet({tuple, [atom]}, {tuple, [atom, integer]})),
    ?assertEqual(
        integer,
        spectra_type:meet({union, [integer, atom]}, {union, [number, {binary, 0, 8}]})
    ),
    ?assertEqual(
        {map, [{exact, {atom_lit, k}, integer}]},
        spectra_type:meet(any_map, {map, [{exact, {atom_lit, k}, integer}]})
    ),
    ?assertEqual(
        none,
        spectra_type:meet(
            {map, [{exact, {atom_lit, k}, integer}]},
            {map, [{exact, {atom_lit, k}, atom}]}
        )
    ),
    ?assertEqual(
        {fun_type, [integer], atom},
        spectra_type:meet({fun_type, [number], atom}, {fun_type, [integer], any})
    ).

success_type_inference_and_propagation_test() ->
    Forms = [
        {attribute, 1, module, infer_sample},
        {attribute, 2, export, [
            {add_one, 1},
            {classify, 1},
            {caller, 1},
            {guards_demo, 1}
        ]},
        {function, 3, add_one, 1, [
            {clause, 3, [{var, 3, 'X'}], [[{call, 3, {atom, 3, is_integer}, [{var, 3, 'X'}]}]], [
                {op, 4, '+', {var, 4, 'X'}, {integer, 4, 1}}
            ]}
        ]},
        {function, 5, classify, 1, [
            {clause, 5, [{integer, 5, 1}], [], [{atom, 5, one}]},
            {clause, 6, [{integer, 6, 2}], [], [{atom, 6, two}]}
        ]},
        {function, 7, caller, 1, [
            {clause, 7, [{var, 7, 'Y'}], [], [
                {call, 7, {atom, 7, add_one}, [{var, 7, 'Y'}]}
            ]}
        ]},
        {function, 8, guards_demo, 1, [
            {clause, 8, [{var, 8, 'N'}], [[
                {op, 8, 'andalso',
                    {call, 8, {atom, 8, is_integer}, [{var, 8, 'N'}]},
                    {op, 8, '>', {var, 8, 'N'}, {integer, 8, 0}}}
            ]], [
                {op, 8, 'div', {var, 8, 'N'}, {integer, 8, 2}}
            ]}
        ]}
    ],
    {ok, infer_sample, BeamBin} = compile:forms(Forms, [debug_info]),
    {ok, Summary} = spectra_abstract:extract_beam(BeamBin),
    Funcs = Summary#module_summary.functions,

    AddOne = maps:get({infer_sample, add_one, 1}, Funcs),
    ?assertEqual({fun_type, [integer], integer}, AddOne#func_contract.inferred_type),

    Classify = maps:get({infer_sample, classify, 1}, Funcs),
    ?assertEqual(
        {fun_type, [{union, [{int_lit, 1}, {int_lit, 2}]}], {union, [{atom_lit, one}, {atom_lit, two}]}},
        Classify#func_contract.inferred_type
    ),

    Caller = maps:get({infer_sample, caller, 1}, Funcs),
    ?assertEqual({fun_type, [integer], integer}, Caller#func_contract.inferred_type),

    GuardsDemo = maps:get({infer_sample, guards_demo, 1}, Funcs),
    ?assertEqual({fun_type, [pos_integer], integer}, GuardsDemo#func_contract.inferred_type).

discrepancy_detection_no_false_positives_test() ->
    Forms = [
        {attribute, 1, module, discrepancy_sample},
        {attribute, 2, export, [
            {double_int, 1},
            {optimistic_ok, 1},
            {bad_arith, 0},
            {bad_match, 0},
            {bad_local_call, 0},
            {redundant_case_branch, 0},
            {no_matching_case, 0},
            {bad_bif_call, 0},
            {bad_unop, 0},
            {bad_list_op, 0},
            {bad_map_update, 0}
        ]},
        {function, 3, double_int, 1, [
            {clause, 3, [{var, 3, 'X'}], [[{call, 3, {atom, 3, is_integer}, [{var, 3, 'X'}]}]], [
                {op, 3, '*', {var, 3, 'X'}, {integer, 3, 2}}
            ]}
        ]},
        {function, 4, optimistic_ok, 1, [
            {clause, 4, [{var, 4, 'Flag'}], [], [
                {match, 5, {var, 5, 'Res'},
                    {'case', 5, {var, 5, 'Flag'}, [
                        {clause, 6, [{atom, 6, true}], [], [{integer, 6, 10}]},
                        {clause, 7, [{atom, 7, false}], [], [{atom, 7, nope}]}
                    ]}
                },
                {call, 8, {atom, 8, double_int}, [{var, 8, 'Res'}]}
            ]}
        ]},
        {function, 9, bad_arith, 0, [
            {clause, 9, [], [], [
                {op, 10, '+', {integer, 10, 1}, {atom, 10, bad}}
            ]}
        ]},
        {function, 11, bad_match, 0, [
            {clause, 11, [], [], [
                {match, 12, {tuple, 12, [{atom, 12, ok}, {var, 12, 'V'}]}, {tuple, 12, [{atom, 12, error}, {atom, 12, reason}]}},
                {var, 12, 'V'}
            ]}
        ]},
        {function, 13, bad_local_call, 0, [
            {clause, 13, [], [], [
                {call, 14, {atom, 14, double_int}, [{atom, 14, definitely_not_int}]}
            ]}
        ]},
        {function, 15, redundant_case_branch, 0, [
            {clause, 15, [], [], [
                {'case', 16, {tuple, 16, [{atom, 16, ok}, {integer, 16, 42}]}, [
                    {clause, 17, [{tuple, 17, [{atom, 17, ok}, {var, 17, 'N'}]}], [], [{var, 17, 'N'}]},
                    {clause, 18, [{tuple, 18, [{atom, 18, error}, {var, 18, 'E'}]}], [], [{var, 18, 'E'}]}
                ]}
            ]}
        ]},
        {function, 19, no_matching_case, 0, [
            {clause, 19, [], [], [
                {'case', 20, {atom, 20, ok}, [
                    {clause, 21, [{atom, 21, error}], [], [{integer, 21, 0}]}
                ]}
            ]}
        ]},
        {function, 22, bad_bif_call, 0, [
            {clause, 22, [], [], [
                {call, 23, {atom, 23, length}, [{atom, 23, not_a_list}]}
            ]}
        ]},
        {function, 24, bad_unop, 0, [
            {clause, 24, [], [], [
                {op, 25, 'not', {integer, 25, 42}}
            ]}
        ]},
        {function, 26, bad_list_op, 0, [
            {clause, 26, [], [], [
                {op, 27, '++', {integer, 27, 42}, {nil, 27}}
            ]}
        ]},
        {function, 28, bad_map_update, 0, [
            {clause, 28, [], [], [
                {match, 29, {var, 29, 'M'}, {integer, 29, 10}},
                {map, 30, {var, 30, 'M'}, [{map_field_assoc, 30, {atom, 30, k}, {integer, 30, 1}}]}
            ]}
        ]}
    ],
    {ok, discrepancy_sample, BeamBin} = compile:forms(Forms, [debug_info]),
    {ok, Warnings} = spectra:analyze_beams([BeamBin], #{mode => discrepancy}),
    WarningMFAs = [{W#spectra_warning.kind, W#spectra_warning.mfa} || W <- Warnings],
    ?assert(lists:member({discrepancy, {discrepancy_sample, bad_arith, 0}}, WarningMFAs)),
    ?assert(lists:member({discrepancy, {discrepancy_sample, bad_match, 0}}, WarningMFAs)),
    ?assert(lists:member({discrepancy, {discrepancy_sample, bad_local_call, 0}}, WarningMFAs)),
    ?assert(lists:member({dead_code, {discrepancy_sample, redundant_case_branch, 0}}, WarningMFAs)),
    ?assert(lists:member({discrepancy, {discrepancy_sample, no_matching_case, 0}}, WarningMFAs)),
    ?assert(lists:member({discrepancy, {discrepancy_sample, bad_bif_call, 0}}, WarningMFAs)),
    ?assert(lists:member({discrepancy, {discrepancy_sample, bad_unop, 0}}, WarningMFAs)),
    ?assert(lists:member({discrepancy, {discrepancy_sample, bad_list_op, 0}}, WarningMFAs)),
    ?assert(lists:member({discrepancy, {discrepancy_sample, bad_map_update, 0}}, WarningMFAs)),
    ?assertNot(lists:keymember({discrepancy_sample, optimistic_ok, 1}, 2, WarningMFAs)).

cross_module_splt_discrepancy_test() ->
    DepForms = [
        {attribute, 1, module, dep_mod},
        {attribute, 2, export, [{parse_bin, 1}]},
        {function, 3, parse_bin, 1, [
            {clause, 3, [{var, 3, 'B'}], [[{call, 3, {atom, 3, is_binary}, [{var, 3, 'B'}]}]], [
                {call, 3, {atom, 3, byte_size}, [{var, 3, 'B'}]}
            ]}
        ]}
    ],
    CallerForms = [
        {attribute, 1, module, caller_mod},
        {attribute, 2, export, [{bad_remote, 0}, {good_remote, 0}]},
        {function, 3, bad_remote, 0, [
            {clause, 3, [], [], [
                {call, 4, {remote, 4, {atom, 4, dep_mod}, {atom, 4, parse_bin}}, [{integer, 4, 123}]}
            ]}
        ]},
        {function, 5, good_remote, 0, [
            {clause, 5, [], [], [
                {call, 6, {remote, 6, {atom, 6, dep_mod}, {atom, 6, parse_bin}}, [{bin, 6, []}]}
            ]}
        ]}
    ],
    {ok, dep_mod, DepBeam} = compile:forms(DepForms, [debug_info]),
    {ok, caller_mod, CallerBeam} = compile:forms(CallerForms, [debug_info]),
    TmpDepPlt = "/tmp/spectra_dev/dep_mod.splt",
    {ok, DepPlt} = spectra_plt:from_beams([DepBeam]),
    ok = spectra_plt:save(DepPlt, TmpDepPlt),

    {ok, Warnings} = spectra:analyze_beams([CallerBeam], #{plts => [TmpDepPlt], mode => discrepancy}),
    file:delete(TmpDepPlt),
    ?assertMatch([#spectra_warning{kind = discrepancy, mfa = {caller_mod, bad_remote, 0}}], Warnings).

additional_patterns_guards_and_bifs_test() ->
    ?assertEqual(float, spectra_type:meet(float, float)),
    ?assertEqual(none, spectra_type:meet(float, integer)),
    ?assertEqual({binary, 8, 1}, spectra_type:meet({binary, 0, 8}, {binary, 8, 1})),
    ?assertEqual({record, r, []}, spectra_type:meet(any_tuple, {record, r, []})),
    ?assertEqual({record, r, []}, spectra_type:meet({record, r, []}, any_tuple)),
    ?assertEqual({fun_type, [], ok}, spectra_type:meet(any_fun, {fun_type, [], ok})),
    ?assertEqual({fun_any_args, ok}, spectra_type:meet(any_fun, {fun_any_args, ok})),

    Forms = [
        {attribute, 1, module, extra_infer},
        {attribute, 2, export, [
            {patterns, 1},
            {guards, 1},
            {exprs, 1},
            {always_fails, 0}
        ]},
        {function, 3, patterns, 1, [
            {clause, 3, [{match, 3, {var, 3, 'Alias'}, {char, 3, $a}}], [], [{var, 3, 'Alias'}]},
            {clause, 4, [{op, 4, '-', {integer, 4, 5}}], [], [{string, 4, "neg"}]},
            {clause, 5, [{float, 5, 1.5}], [], [{string, 5, ""}]},
            {clause, 6, [{bin, 6, []}], [], [{char, 6, $b}]},
            {clause, 7, [{string, 7, "hi"}], [], [{atom, 7, str}]},
            {clause, 8, [{cons, 8, {var, 8, 'H'}, {var, 8, '_T'}}], [], [{var, 8, 'H'}]},
            {clause, 9, [{map, 9, [{map_field_exact, 9, {atom, 9, k}, {var, 9, 'V'}}]}], [], [{var, 9, 'V'}]}
        ]},
        {function, 10, guards, 1, [
            {clause, 10, [{var, 10, 'X'}], [[{call, 10, {atom, 10, is_float}, [{var, 10, 'X'}]}]], [{op, 10, '/', {var, 10, 'X'}, {float, 10, 2.0}}]},
            {clause, 11, [{var, 11, 'X'}], [[{call, 11, {atom, 11, is_boolean}, [{var, 11, 'X'}]}]], [{op, 11, 'andalso', {var, 11, 'X'}, {atom, 11, true}}]},
            {clause, 12, [{var, 12, 'X'}], [[{op, 12, 'orelse', {call, 12, {atom, 12, is_atom}, [{var, 12, 'X'}]}, {call, 12, {atom, 12, is_pid}, [{var, 12, 'X'}]}}]], [{var, 12, 'X'}]},
            {clause, 13, [{var, 13, 'X'}], [[{op, 13, '>=', {var, 13, 'X'}, {integer, 13, 0}}]], [{op, 13, '-', {var, 13, 'X'}}]},
            {clause, 14, [{var, 14, 'X'}], [[{op, 14, '<', {var, 14, 'X'}, {integer, 14, 0}}]], [{call, 14, {atom, 14, abs}, [{var, 14, 'X'}]}]},
            {clause, 15, [{var, 15, 'X'}], [[{op, 15, '=:=', {var, 15, 'X'}, {atom, 15, ok}}]], [{call, 15, {atom, 15, atom_to_binary}, [{var, 15, 'X'}]}]}
        ]},
        {function, 16, exprs, 1, [
            {clause, 16, [{var, 16, 'L'}], [[{call, 16, {atom, 16, is_list}, [{var, 16, 'L'}]}]], [
                {'block', 16, [
                    {match, 16, {var, 16, 'M'}, {map, 16, [{map_field_assoc, 16, {atom, 16, a}, {integer, 16, 1}}]}},
                    {'if', 16, [
                        {clause, 16, [], [[{call, 16, {atom, 16, is_map}, [{var, 16, 'M'}]}]], [
                            {op, 16, '++', {var, 16, 'L'}, {cons, 16, {integer, 16, 1}, {nil, 16}}}
                        ]}
                    ]}
                ]}
            ]}
        ]},
        {function, 17, always_fails, 0, [
            {clause, 17, [], [], [
                {call, 17, {remote, 17, {atom, 17, erlang}, {atom, 17, error}}, [{atom, 17, boom}]}
            ]}
        ]}
    ],
    {ok, extra_infer, BeamBin} = compile:forms(Forms, [debug_info]),
    {ok, Summary} = spectra_abstract:extract_beam(BeamBin),
    FailsContract = maps:get({extra_infer, always_fails, 0}, Summary#module_summary.functions),
    ?assertEqual({fun_type, [], none}, FailsContract#func_contract.inferred_type).
