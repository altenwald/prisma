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

%% Unary minus must negate the type of its operand (it used to keep the operand's type, so `-1` was inferred as `1`).

inferred_return(Src) ->
    Text = "-module(unop_sample).\n-export([f/1]).\n" ++ Src,
    {ok, Toks, _} = erl_scan:string(Text),
    Forms = split_forms(Toks, [], []),
    {ok, unop_sample, Beam} = compile:forms(Forms, [debug_info, binary]),
    {ok, Plt} = spectra_plt:from_beams([Beam]),
    #module_summary{functions = Funcs} = maps:get(unop_sample, Plt#spectra_plt.modules),
    {fun_type, _Args, Ret} = (maps:get({unop_sample, f, 1}, Funcs))#func_contract.inferred_type,
    Ret.

split_forms([], [], Acc) -> lists:reverse(Acc);
split_forms([{dot, _} = Dot | Rest], Cur, Acc) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([Dot | Cur])),
    split_forms(Rest, [], [Form | Acc]);
split_forms([Tok | Rest], Cur, Acc) -> split_forms(Rest, [Tok | Cur], Acc).

unary_minus_negates_literals_test() ->
    ?assertEqual({int_lit, -1}, inferred_return("f(_) -> -1.")),
    ?assertEqual({int_lit, 1}, inferred_return("f(_) -> - -1.")),
    ?assertEqual({int_lit, 0}, inferred_return("f(_) -> -0.")),
    ?assertEqual(float, inferred_return("f(_) -> -1.5.")),
    ?assertEqual({int_lit, 3}, inferred_return("f(_) -> +3.")).

unary_minus_on_each_branch_test() ->
    Ret = inferred_return("f(B) -> case B of true -> -1; false -> -2 end."),
    ?assert(spectra_oracle:member(-1, Ret)),
    ?assert(spectra_oracle:member(-2, Ret)),
    ?assertNot(spectra_oracle:member(1, Ret)),
    ?assertNot(spectra_oracle:member(2, Ret)).

negative_literal_clauses_are_reachable_test() ->
    Text = "-module(unop_reach).\n-export([f/0, g/0]).\nf() -> -1.\ng() -> case f() of -1 -> ok end.\n",
    {ok, Toks, _} = erl_scan:string(Text),
    {ok, unop_reach, Beam} = compile:forms(split_forms(Toks, [], []), [debug_info, binary]),
    ?assertEqual({ok, []}, spectra:analyze_beams([Beam], #{mode => discrepancy, oxbow => false})).

negate_type_test_() ->
    [
        ?_assertEqual({int_lit, -5}, spectra_infer:negate_type({int_lit, 5})),
        ?_assertEqual({int_range, -10, -2}, spectra_infer:negate_type({int_range, 2, 10})),
        ?_assertEqual({int_range, -3, pos_inf}, spectra_infer:negate_type({int_range, neg_inf, 3})),
        ?_assertEqual({int_range, neg_inf, 3}, spectra_infer:negate_type({int_range, -3, pos_inf})),
        ?_assertEqual(neg_integer, spectra_infer:negate_type(pos_integer)),
        ?_assertEqual(pos_integer, spectra_infer:negate_type(neg_integer)),
        ?_assertEqual({int_range, neg_inf, 0}, spectra_infer:negate_type(non_neg_integer)),
        ?_assertEqual(integer, spectra_infer:negate_type(integer)),
        ?_assertEqual(float, spectra_infer:negate_type(float)),
        ?_assertEqual(number, spectra_infer:negate_type(number)),
        ?_assertEqual(none, spectra_infer:negate_type(none)),
        ?_assertEqual(
            [{int_lit, -2}, {int_lit, -1}],
            begin
                {union, Ms} = spectra_type:normalize_union([spectra_infer:negate_type(T) || T <- [{int_lit, 2}, {int_lit, 1}]]),
                lists:sort(Ms)
            end
        )
    ].

%% Improper list cells: `[H | T]` whose tail is not a list is not a proper list.

improper_sample(Src) ->
    Text = "-module(cell_sample).\n-export([f/1]).\n" ++ Src,
    {ok, Toks, _} = erl_scan:string(Text),
    {ok, cell_sample, Beam} = compile:forms(split_forms(Toks, [], []), [debug_info, binary]),
    Beam.

cell_warnings(Src) ->
    {ok, Ws} = spectra:analyze_beams([improper_sample(Src)], #{mode => discrepancy, oxbow => false}),
    [{K, L} || #spectra_warning{kind = K, line = L} <- Ws].

cell_with_integer_tail_is_not_a_proper_list_test() ->
    Ret = inferred_return("f(_) -> [1 | 2]."),
    ?assertNot(spectra_oracle:member([1 | 2], {list, any}) andalso spectra_oracle:member(Ret, {list, any})),
    ?assert(spectra_oracle:member([1 | 2], Ret)),
    ?assertNot(spectra_oracle:member(foo, Ret)).

cell_with_list_tail_stays_a_proper_list_test() ->
    ?assertEqual({nonempty_list, {int_lit, 1}}, inferred_return("f(_) -> [1 | [1]].")),
    ?assertMatch({nonempty_list, _}, inferred_return("f(_) -> [1, 2, 3].")).

pattern_on_improper_cell_is_reachable_test() ->
    ?assertEqual([], cell_warnings("f(_) ->\n    case [0 | 0] of\n        [H | T] when is_integer(T) -> H + T\n    end.\n")),
    ?assertEqual([], cell_warnings("f(C) ->\n    case C of\n        [H | T] when is_integer(T) -> H + T;\n        _ -> 0\n    end.\n")).

tail_of_unknown_term_is_unknown_test() ->
    %% tl/1 of an unknown term may be anything: passing it where an integer is needed is not a failure
    ?assertEqual([], cell_warnings("f(C) -> g(tl(C)).\ng(N) when is_integer(N) -> N.\n")),
    ?assertEqual([], cell_warnings("f(C) -> tl(C) + 1.\n")).

type_algebra_improper_vs_list_test_() ->
    Impr = {improper_list, integer, integer},
    [
        ?_assertEqual(nil, spectra_type:meet(Impr, nil)),
        ?_assertEqual(nil, spectra_type:meet(nil, Impr)),
        ?_assertEqual({list, integer}, spectra_type:meet(Impr, {list, integer})),
        ?_assertEqual({list, integer}, spectra_type:meet({list, integer}, Impr)),
        ?_assertNotEqual(none, spectra_type:meet(Impr, {nonempty_list, integer})),
        ?_assertEqual(nil, spectra_type:meet(Impr, {list, atom})),
        ?_assertEqual(none, spectra_type:meet(Impr, {nonempty_list, atom})),
        ?_assert(spectra_type:consistent_subtype({list, integer}, Impr)),
        ?_assert(spectra_type:consistent_subtype({nonempty_list, integer}, Impr)),
        ?_assertNot(spectra_type:consistent_subtype(Impr, {list, integer})),
        ?_assert(spectra_type:consistent_subtype({improper_list, integer, any}, {list, integer}))
    ].

cons_chain_does_not_nest_test() ->
    %% [1, 2, 3 | T] with an unknown T is one maybe-improper list, not improper lists inside improper lists
    ?assertMatch({improper_list, _, any}, inferred_return("f(T) -> [1, 2, 3 | T].")),
    {improper_list, Elem, any} = inferred_return("f(T) -> [1, 2, 3 | T]."),
    ?assertNot(is_tuple(Elem) andalso element(1, Elem) =:= improper_list),
    ?assert(spectra_oracle:member(1, Elem) andalso spectra_oracle:member(3, Elem)).

unknown_tail_is_not_assumed_to_be_a_list_test() ->
    %% [H | T] with T unknown: T may be anything, so a clause that needs an integer tail is reachable
    ?assertEqual([], cell_warnings("f(T) ->\n    case [1 | T] of\n        [H | N] when is_integer(N) -> H + N;\n        _ -> 0\n    end.\n")).

%% `andalso` / `orelse`: only the left operand has to be a boolean; the result is the right operand when the left one
%% does not decide. (They used to be read as `and` / `or`, so a non-boolean right operand "failed".)

short_circuit_warnings(Src) ->
    {ok, Ws} = spectra:analyze_beams([improper_sample(Src)], #{mode => discrepancy, oxbow => false}),
    [{K, L} || #spectra_warning{kind = K, line = L} <- Ws].

andalso_orelse_accept_a_non_boolean_right_operand_test() ->
    ?assertEqual([], short_circuit_warnings("f(X) -> X > 0 orelse {false, \"negative\"}.\n")),
    ?assertEqual([], short_circuit_warnings("f(B) -> B andalso 1.\n")),
    ?assertEqual([], short_circuit_warnings("f(B) ->\n    case B andalso 0 of\n        false -> 0;\n        N when is_integer(N) -> N\n    end.\n")),
    %% with a literal `true` on the left the `false` clause really is dead
    ?assertMatch([{dead_code, 5}], short_circuit_warnings("f(_) ->\n    case true andalso 0 of\n        false -> 0;\n        N when is_integer(N) -> N\n    end.\n")),
    ?assertEqual([], short_circuit_warnings("f(B) ->\n    case B orelse {false, 3} of\n        true -> 1;\n        {false, N} -> N\n    end.\n")).

andalso_orelse_result_is_the_right_operand_or_the_deciding_boolean_test() ->
    AndRet = inferred_return("f(B) -> B andalso 1."),
    ?assert(spectra_oracle:member(false, AndRet)),
    ?assert(spectra_oracle:member(1, AndRet)),
    ?assertNot(spectra_oracle:member(true, AndRet)),
    ?assertNot(spectra_oracle:member(2, AndRet)),
    OrRet = inferred_return("f(B) -> B orelse {false, 3}."),
    ?assert(spectra_oracle:member(true, OrRet)),
    ?assert(spectra_oracle:member({false, 3}, OrRet)),
    ?assertNot(spectra_oracle:member(false, OrRet)),
    %% both operands boolean: still a boolean
    ?assertEqual(boolean, inferred_return("f(A) when is_boolean(A) -> A andalso (A =:= true).")).

andalso_orelse_with_a_known_left_operand_test() ->
    ?assertEqual({int_lit, 0}, inferred_return("f(_) -> true andalso 0.")),
    ?assertEqual({atom_lit, false}, inferred_return("f(_) -> false andalso 0.")),
    ?assertEqual({atom_lit, true}, inferred_return("f(_) -> true orelse 0.")),
    ?assertEqual({int_lit, 0}, inferred_return("f(_) -> false orelse 0.")).

andalso_orelse_still_need_a_boolean_on_the_left_test() ->
    ?assertMatch([{discrepancy, 5}], short_circuit_warnings("f(_) ->\n    ok,\n    1 andalso true.\n")),
    ?assertMatch([{discrepancy, 5}], short_circuit_warnings("f(_) ->\n    ok,\n    foo orelse true.\n")).

and_or_xor_stay_strict_test() ->
    ?assertMatch([{discrepancy, 5}], short_circuit_warnings("f(_) ->\n    ok,\n    true and 0.\n")),
    ?assertMatch([{discrepancy, 5}], short_circuit_warnings("f(_) ->\n    ok,\n    false or foo.\n")).

%% Overloaded -spec across modules: a call is fine when SOME clause accepts it, taking each clause as one whole
%% vector of arguments (it used to look at the first clause only).

two_module_warnings(CallerSrc, CalleeSrc, Mode) ->
    Compile = fun(Name, Src) ->
        {ok, Toks, _} = erl_scan:string("-module(" ++ Name ++ ").\n" ++ Src),
        {ok, _, Beam} = compile:forms(split_forms(Toks, [], []), [debug_info, binary]),
        Beam
    end,
    {ok, Ws} = spectra:analyze_beams([Compile("ov_caller", CallerSrc), Compile("ov_callee", CalleeSrc)],
                                     #{mode => Mode, oxbow => false}),
    [{K, L} || #spectra_warning{kind = K, line = L} <- Ws].

overloaded_callee() ->
    "-export([g/1, h/2]).\n"
    "-spec g(blocking) -> ok; (non_blocking) -> ok.\n"
    "g(_) -> ok.\n"
    "-spec h(integer(), boolean()) -> ok; (atom(), integer()) -> ok.\n"
    "h(_, _) -> ok.\n".

overloaded_spec_accepts_any_clause_test() ->
    Caller = "-export([f/0]).\nf() ->\n    ov_callee:g(non_blocking),\n    ov_callee:g(blocking),\n    ov_callee:h(1, true),\n    ov_callee:h(a, 1).\n",
    ?assertEqual([], two_module_warnings(Caller, overloaded_callee(), discrepancy)),
    ?assertEqual([], two_module_warnings(Caller, overloaded_callee(), gradual)).

overloaded_spec_clauses_are_whole_vectors_test() ->
    %% (1, 1) mixes the first position of one clause with the second of the other: no clause accepts it
    Caller = "-export([f/0]).\nf() ->\n    ov_callee:h(1, 1).\n",
    ?assertMatch([{discrepancy, 4}], two_module_warnings(Caller, overloaded_callee(), discrepancy)),
    ?assertMatch([{_, 4}], two_module_warnings(Caller, overloaded_callee(), gradual)).

overloaded_spec_still_rejects_what_no_clause_accepts_test() ->
    Caller = "-export([f/0]).\nf() ->\n    ov_callee:g(neither).\n",
    ?assertMatch([{discrepancy, 4}], two_module_warnings(Caller, overloaded_callee(), discrepancy)),
    ?assertMatch([{_, 4}], two_module_warnings(Caller, overloaded_callee(), gradual)).

%% `==` compares numbers by value (0.0 == 0), `=:=` does not: a float can satisfy `X == 0` but never `X =:= 0`.

float_equals_integer_in_a_guard_test() ->
    ?assertEqual([], short_circuit_warnings("f(X) ->\n    T = X / 2,\n    if\n        T == 0 -> zero;\n        true -> other\n    end.\n")),
    ?assertEqual([], short_circuit_warnings("f(N) when is_integer(N), N == 0 -> zero;\nf(_) -> other.\n")),
    ?assertEqual([], short_circuit_warnings("f(N) when is_float(N), N == 0 -> zero;\nf(_) -> other.\n")).

exact_equality_still_separates_float_and_integer_test() ->
    %% `=:=` between a float and an integer can never be true: this one really is dead
    ?assertMatch([{dead_code, 6}], short_circuit_warnings("f(X) ->\n    T = X / 2,\n    if\n        T =:= 0 -> zero;\n        true -> other\n    end.\n")).

%% Comparing with 0: `X > 0` holds for 0.5 and for any non-number (term order: numbers < atoms < ...), `X < 0` only for
%% negative numbers. The guard used to make X an integer. And the environments of an `orelse` guard are joined: a
%% variable constrained in only one branch is unconstrained afterwards.

plain_warnings(Src) ->
    Text = "-module(cmp_sample).\n" ++ Src,
    {ok, Toks, _} = erl_scan:string(Text),
    {ok, cmp_sample, Beam} = compile:forms(split_forms(Toks, [], []), [debug_info, binary]),
    {ok, Ws} = spectra:analyze_beams([Beam], #{mode => discrepancy, oxbow => false}),
    [{K, L} || #spectra_warning{kind = K, line = L} <- Ws].

comparison_with_zero_keeps_floats_test() ->
    ?assertEqual([], plain_warnings("-export([f/1]).\nf(X) when is_float(X) ->\n    case X - 1 of\n        Neg when Neg < 0 -> a;\n        Pos when Pos > 0 -> b;\n        _ -> c\n    end.\n")),
    ?assertEqual([], plain_warnings("-export([f/1]).\nf(P) when is_float(P), P >= 0, P =< 1 -> P;\nf(_) -> other.\n")).

comparison_with_zero_accepts_non_numbers_test() ->
    %% every term that is not a number is greater than 0
    ?assertEqual([], plain_warnings("-export([g/0]).\nf(X) when X > 0 -> pos;\nf(_) -> other.\ng() -> f(a).\n")),
    ?assertEqual([], plain_warnings("-export([g/0]).\nf(X) when X >= 0 -> pos;\nf(_) -> other.\ng() -> f(foo).\n")).

comparison_with_zero_still_refines_numbers_test() ->
    %% an integer cannot be both positive and negative
    ?assertMatch([{dead_code, 3} | _], plain_warnings("-export([f/1]).\nf(N) when is_integer(N), N > 0, N < 0 -> x;\nf(_) -> y.\n")).

orelse_guard_joins_environments_test() ->
    %% Range comes out of a record pattern: it is not in the environment, and constrained in only one branch
    Src = "-export([f/2]).\n-record(st, {range}).\n"
          "f(P, #st{range = Range}) when P == undefined orelse Range == undefined orelse P == 1 ->\n"
          "    case Range of\n        undefined -> a;\n        {_, _} -> b\n    end;\n"
          "f(_, _) -> c.\n",
    ?assertEqual([], plain_warnings(Src)).

%% Calls inside fun, try, catch, receive, comprehensions, records and binaries must be checked like any other call.

nested_callee() ->
    "-export([g/1]).\n-spec g(integer()) -> ok.\ng(_) -> ok.\n".

nested_hits(Body) ->
    Caller = "-export([f/0]).\n-record(st, {x}).\nf() ->\n" ++ Body ++ ".\n",
    %% line 5 is the first line of the body
    [L || {discrepancy, L} <- two_module_warnings(Caller, nested_callee(), discrepancy)].

call_inside_an_anonymous_fun_test() ->
    ?assertEqual([5], nested_hits("    F = fun(_) -> ov_callee:g(oops) end,\n    F(1)")),
    ?assertEqual([5], nested_hits("    lists:foreach(fun(X) when is_integer(X) -> ov_callee:g(oops) end, [1])")),
    ?assertEqual([5], nested_hits("    F = fun Loop(0) -> ov_callee:g(oops); Loop(N) -> Loop(N - 1) end,\n    F(1)")).

call_inside_try_test() ->
    ?assertEqual([5], nested_hits("    try ov_callee:g(oops) of\n        ok -> a\n    catch _:_ -> b\n    end")),
    ?assertEqual([6], nested_hits("    try ok of\n        ok -> ov_callee:g(oops)\n    catch _:_ -> b\n    end")),
    ?assertEqual([7], nested_hits("    try ok\n    catch\n        _:_ -> ov_callee:g(oops)\n    end")),
    ?assertEqual([8], nested_hits("    try ok\n    catch _:_ -> b\n    after\n        ov_callee:g(oops)\n    end")).

call_inside_catch_and_receive_test() ->
    ?assertEqual([5], nested_hits("    catch ov_callee:g(oops)")),
    ?assertEqual([6], nested_hits("    receive\n        _ -> ov_callee:g(oops)\n    after 0 -> ok\n    end")),
    ?assertEqual([8], nested_hits("    receive\n        _ -> ok\n    after 0 ->\n        ov_callee:g(oops)\n    end")).

call_inside_a_comprehension_test() ->
    ?assertEqual([5], nested_hits("    [ov_callee:g(oops) || _ <- [1]]")),
    ?assertEqual([5], nested_hits("    [X || X <- [ov_callee:g(oops)]]")),
    ?assertEqual([5], nested_hits("    [X || X <- [1], ov_callee:g(oops) =:= ok]")),
    ?assertEqual([5], nested_hits("    << <<X>> || X <- [ov_callee:g(oops)] >>")).

call_inside_a_record_and_a_binary_test() ->
    ?assertEqual([5], nested_hits("    #st{x = ov_callee:g(oops)}")),
    ?assertEqual([6], nested_hits("    R = #st{x = 1},\n    R#st{x = ov_callee:g(oops)}")),
    ?assertEqual([6], nested_hits("    R = #st{x = 1},\n    {R#st.x, ov_callee:g(oops)}")),
    ?assertEqual([5], nested_hits("    <<(ov_callee:g(oops)):8>>")).

nested_constructs_report_nothing_when_correct_test() ->
    Body = "    F = fun(X) -> ov_callee:g(X) end,\n    [ov_callee:g(Y) || Y <- [1, 2], is_integer(Y)],\n"
           "    try ov_callee:g(1) of ok -> ok catch _:_ -> ov_callee:g(2) after ov_callee:g(3) end,\n"
           "    #st{x = ov_callee:g(4)},\n    F(5)",
    ?assertEqual([], nested_hits(Body)).

variables_bound_inside_do_not_leak_test() ->
    %% X is bound inside the fun and the comprehension only: the X outside is a different one
    Body = "    F = fun(X) -> X + 1 end,\n    _ = [Y || Y <- [a, b]],\n    X = oops,\n    Y = 1,\n    {F(1), X, Y}",
    ?assertEqual([], nested_hits(Body)).

%% A tuple whose first element is the record's name and whose size is the record's is a value of that record type.

record_callee() ->
    "-export([g/1]).\n-record(r, {a :: integer(), b :: atom()}).\n-spec g(#r{}) -> ok.\ng(_) -> ok.\n".

record_hits(Body) ->
    Caller = "-export([f/0]).\nf() ->\n" ++ Body ++ ".\n",
    [L || {discrepancy, L} <- two_module_warnings(Caller, record_callee(), discrepancy)].

tuple_with_the_record_tag_fits_the_record_test() ->
    ?assertEqual([], record_hits("    ov_callee:g({r, 1, a})")),
    ?assertEqual([], record_hits("    try ok catch\n        exit:{r, _, _} = E -> ov_callee:g(E)\n    end")).

tuple_that_cannot_be_the_record_is_still_rejected_test() ->
    ?assertEqual([4], record_hits("    ov_callee:g({other, 1, a})")),
    ?assertEqual([4], record_hits("    ov_callee:g(not_a_tuple)")),
    ?assertEqual([4], record_hits("    ov_callee:g([r, 1, a])")).

meet_of_a_tuple_and_a_record_test_() ->
    Rec = {record, r, [{a, integer}, {b, atom}]},
    [?_assertEqual(Rec, spectra_type:meet({tuple, [{atom_lit, r}, integer, atom]}, Rec)),
     ?_assertEqual(Rec, spectra_type:meet(Rec, {tuple, [{atom_lit, r}, any, any]})),
     ?_assertEqual(none, spectra_type:meet({tuple, [{atom_lit, s}, integer, atom]}, Rec)),
     %% arity and field types are not checked: a spec only lists some of the fields
     ?_assertEqual(Rec, spectra_type:meet({tuple, [{atom_lit, r}, integer]}, Rec)),
     ?_assertEqual({record, r, []}, spectra_type:meet({tuple, [{atom_lit, r}, atom, atom]}, {record, r, []}))].

%% A BIF with arguments of the wrong type inside a guard makes the guard fail, so the clause can never match.

guard_bif_dead_clause_test() ->
    ?assert(lists:member({dead_code, 3}, plain_warnings("-export([f/1]).\nf(X) when length(oops) > X -> yes;\nf(_) -> no.\n"))),
    ?assert(lists:member({dead_code, 3}, plain_warnings("-export([f/1]).\nf(X) when byte_size(oops) > 0, is_integer(X) -> yes;\nf(_) -> no.\n"))),
    ?assert(lists:member({dead_code, 3}, plain_warnings("-export([f/1]).\nf(M) when map_size(oops) =:= 0 -> yes;\nf(_) -> no.\n"))),
    ?assert(lists:member({dead_code, 3}, plain_warnings("-export([f/1]).\nf(X) when X > 0 andalso length(oops) > 1 -> yes;\nf(_) -> no.\n"))),
    %% and in a case clause
    ?assert(lists:member({dead_code, 5}, plain_warnings("-export([f/1]).\nf(X) ->\n    case X of\n        _ when hd(oops) =:= 1 -> a;\n        _ -> b\n    end.\n"))).

guard_bif_with_a_known_type_still_fine_test() ->
    Src = "-export([f/1, g/1, h/1, i/1]).\n"
          "f(L) when length(L) > 0 -> a;\nf(_) -> b.\n"
          "g(M) when is_map(M), map_size(M) =:= 0 -> a;\ng(_) -> b.\n"
          "h(X) when is_integer(X), X > 0, abs(X) < 10 -> a;\nh(_) -> b.\n"
          "i(B) when byte_size(B) >= 4; is_list(B) -> a;\ni(_) -> b.\n",
    ?assertEqual([], plain_warnings(Src)).

guard_with_an_alternative_that_fits_is_not_dead_test() ->
    %% the first alternative fails whenever it is evaluated, the second one does not: that test is reported, the clause is not dead
    ?assertEqual([{discrepancy, 3}], plain_warnings("-export([f/1]).\nf(X) when length(oops) > 0; is_integer(X) -> yes;\nf(_) -> no.\n")).

comparison_with_an_impossible_operand_is_impossible_test() ->
    ?assertMatch([{dead_code, _} | _], plain_warnings("-export([f/1]).\nf(X) when length(oops) < length(X) -> a;\nf(_) -> b.\n")).

%% A guard test that fails whenever it is evaluated is reported even when another alternative of the guard can still hold
%% (the macros of khepri: `Path =:= [] orelse hd(Path) ...`): the clause is not dead, that test is.

failing_guard_test_inside_an_alternative_test() ->
    Src = "-export([f/1]).\n"
          "f(P) when P =:= [] orelse hd(oops) =:= a -> yes;\nf(_) -> no.\n",
    ?assertMatch([{discrepancy, 3}], plain_warnings(Src)),
    Src2 = "-export([f/1]).\n"
           "f(P) when is_list(P) andalso (P =:= [] orelse hd(oops) > 1) -> yes;\nf(_) -> no.\n",
    ?assertMatch([{discrepancy, 3}], plain_warnings(Src2)),
    %% in a case clause too
    Src3 = "-export([f/1]).\nf(P) ->\n    case P of\n        _ when P =:= [] orelse length(oops) > 1 -> a;\n        _ -> b\n    end.\n",
    ?assertMatch([{discrepancy, 5}], plain_warnings(Src3)).

guards_with_fitting_tests_report_nothing_test() ->
    Src = "-export([f/1, g/1]).\n"
          "f(P) when P =:= [] orelse hd(P) =:= a -> yes;\nf(_) -> no.\n"
          "g(P) when is_list(P) andalso (P =:= [] orelse length(P) > 1) -> yes;\ng(_) -> no.\n",
    ?assertEqual([], plain_warnings(Src)).

%% A failure is reported where it is, and only there. The functions that call the one that fails, however many levels up, are not
%% named: Dialyzer's "no local return" cascade (a warning in every caller, without saying why) is exactly what Spectra must not do.

failure_is_reported_only_where_it_is_test() ->
    Src = "-export([top/0, other/1]).\n"
          "-spec top() -> integer().\n"
          "top() -> mid() + 1.\n"
          "-spec mid() -> integer().\n"
          "mid() ->\n"
          "    X = low(),\n"
          "    case X of\n"
          "        1 -> a;\n"
          "        _ -> b\n"
          "    end,\n"
          "    X.\n"
          "low() -> length(oops).\n"
          "other(L) ->\n"
          "    F = fun() -> low() end,\n"
          "    try F() of\n"
          "        N when N > 0 -> N\n"
          "    catch _:_ -> 0\n"
          "    end,\n"
          "    [low() || _ <- L],\n"
          "    {low(), mid(), top()}.\n",
    %% line 13 is `low() -> length(oops).`: the only line that is wrong
    ?assertEqual([{discrepancy, 13}], plain_warnings(Src)).

a_failing_call_in_a_guard_or_a_nested_construct_does_not_name_its_callers_test() ->
    Src = "-export([f/1, g/1]).\n"
          "f(P) when P =:= [] orelse hd(oops) > 1 -> yes;\n"
          "f(_) -> no.\n"
          "g(X) -> f(X) =:= yes.\n",
    %% only the guard test of f/1 is named, not g/1 which calls it
    ?assertEqual([{discrepancy, 3}], plain_warnings(Src)).

%% A call to a function that does not exist in a module Spectra knows is reported; a module it does not know says nothing.

missing_callee() ->
    "-export([g/1]).\n-spec g(integer()) -> ok.\ng(_) -> ok.\nhidden() -> ok.\n".

missing_hits(Body, Mode) ->
    Caller = "-export([f/0]).\nf() ->\n" ++ Body ++ ".\n",
    [L || {unknown_function, L} <- two_module_warnings(Caller, missing_callee(), Mode)].

call_to_a_function_that_does_not_exist_test() ->
    ?assertEqual([4], missing_hits("    ov_callee:nonexistent(1)", discrepancy)),
    ?assertEqual([4], missing_hits("    ov_callee:nonexistent(1)", hybrid)),
    %% wrong arity: g/1 exists, g/2 does not
    ?assertEqual([4], missing_hits("    ov_callee:g(1, 2)", discrepancy)),
    %% not exported but defined: left alone (a module may export everything with a compile attribute)
    ?assertEqual([], missing_hits("    ov_callee:hidden()", discrepancy)).

call_to_a_function_that_exists_is_fine_test() ->
    ?assertEqual([], missing_hits("    ov_callee:g(1)", discrepancy)),
    %% what the compiler adds without it being in the code
    ?assertEqual([], missing_hits("    ov_callee:module_info(),\n    ov_callee:module_info(exports),\n    ov_callee:behaviour_info(callbacks)", discrepancy)).

call_to_a_module_that_is_not_known_says_nothing_test() ->
    ?assertEqual([], missing_hits("    not_a_module_of_the_plt:anything(1),\n    erlang:anything_at_all(2)", discrepancy)).

missing_function_is_reported_inside_nested_constructs_test() ->
    ?assertEqual([4], missing_hits("    F = fun() -> ov_callee:nonexistent(1) end,\n    F()", discrepancy)),
    ?assertEqual([5], missing_hits("    try ok of\n        ok -> ov_callee:nonexistent(1)\n    catch _:_ -> b\n    end", discrepancy)).

%% A saved .splt only needs contracts, not the code of every function.

saved_plt_keeps_contracts_and_drops_the_code_test() ->
    Text = "-module(plt_lean).\n-export([f/1]).\n-spec f(integer()) -> integer().\nf(X) -> X + 1.\n",
    {ok, Toks, _} = erl_scan:string(Text),
    {ok, plt_lean, Beam} = compile:forms(split_forms(Toks, [], []), [debug_info, binary]),
    {ok, Plt} = spectra_plt:from_beams([Beam]),
    #module_summary{functions = Before} = maps:get(plt_lean, Plt#spectra_plt.modules),
    ?assertMatch(#func_contract{clauses = [_ | _]}, maps:get({plt_lean, f, 1}, Before)),
    {ok, Loaded} = spectra_plt:decode(spectra_plt:encode(Plt)),
    #module_summary{functions = After} = maps:get(plt_lean, Loaded#spectra_plt.modules),
    #func_contract{clauses = [], declared_specs = Specs, inferred_type = Inferred, exported = true} = maps:get({plt_lean, f, 1}, After),
    #func_contract{declared_specs = Specs0, inferred_type = Inferred0} = maps:get({plt_lean, f, 1}, Before),
    ?assertEqual(Specs0, Specs),
    ?assertEqual(Inferred0, Inferred).

%% A list built by a recursive function with many clauses must not make its type grow with every pass of the inference:
%% `[H | f(...)]` where f(...) is `nil | nonempty_list(...)` is one more `nonempty_list`, not one per member of the tail.
%% (A first version distributed the cons over the members of the tail: 48,000 million words once written out.)

union_members({union, Ms}) -> length(Ms);
union_members(_) -> 1.

recursive_list_building_keeps_the_type_small_test() ->
    Clauses = ["f(" ++ integer_to_list(N) ++ ") -> [" ++ [$a + N] ++ " | f(" ++ integer_to_list(N - 1) ++ ")]"
               || N <- lists:seq(1, 12)],
    Src = "f(0) -> [];\n" ++ string:join(Clauses, ";\n") ++ ".\n",
    Ret = inferred_return(Src),
    ?assert(union_members(Ret) =< 3),
    ?assert(erts_debug:flat_size(Ret) < 2000).

mutually_recursive_list_builders_keep_the_type_small_test() ->
    A = ["a(" ++ integer_to_list(N) ++ ") -> [{x, " ++ integer_to_list(N) ++ "} | a(" ++ integer_to_list(N - 1) ++ ")]"
         || N <- lists:seq(1, 8)] ++ ["a(9) -> [{arr, b(1)} | a(8)]"],
    B = ["b(" ++ integer_to_list(N) ++ ") -> [{y, " ++ integer_to_list(N) ++ "} | b(" ++ integer_to_list(N - 1) ++ ")]"
         || N <- lists:seq(1, 8)] ++ ["b(9) -> [{tab, a(1)} | b(8)]"],
    Src = "a(0) -> [];\n" ++ string:join(A, ";\n") ++ ".\nb(0) -> [];\n" ++ string:join(B, ";\n") ++ ".\n"
          ++ "f(X) -> {a(X), b(X)}.\n",
    Ret = inferred_return(Src),
    ?assert(erts_debug:flat_size(Ret) < 20000).

union_tail_with_a_non_list_member_still_gives_an_improper_list_test() ->
    %% g/1 returns [] or an integer: `[H | g()]` may be a proper list or an improper one
    Ret = inferred_return("f(X) -> [a | g(X)].\ng(0) -> [];\ng(_) -> 1.\n"),
    ?assert(spectra_oracle:member([a], Ret)),
    ?assert(spectra_oracle:member([a | 1], Ret)),
    ?assertNot(spectra_oracle:member([a | foo], Ret)).

%% The target of a call is an expression too: `(m:f()):g()`, `m:(f())()` and `(f())(X)` hold calls that must be checked.

call_inside_the_target_of_another_call_test() ->
    ?assertEqual([4], missing_hits("    (ov_callee:nonexistent(1)):run(2)", discrepancy)),
    ?assertEqual([4], missing_hits("    ov_callee:(ov_callee:nonexistent(1))(2)", discrepancy)),
    ?assertEqual([4], missing_hits("    (ov_callee:nonexistent(1))(2)", discrepancy)),
    ?assertEqual([4], missing_hits("    (fun(X) -> X end)(ov_callee:nonexistent(1))", discrepancy)).

a_dynamic_target_that_is_correct_says_nothing_test() ->
    ?assertEqual([], missing_hits("    M = ov_callee,\n    M:g(1),\n    (ov_callee:g(1)):anything(2)", discrepancy)).

%% The return type of a call to another module comes from that module's -spec, so a pattern that the spec says can never match is reported.

return_callee() ->
    "-export([f/0, g/1, h/0, t/0]).\n"
    "-spec f() -> ok | {error, atom()}.\nf() -> ok.\n"
    "-spec g(integer()) -> {ok, integer()} | {error, term()}.\ng(_) -> {ok, 1}.\n"
    "h() -> ok.\n"
    "-spec t() -> term().\nt() -> ok.\n".

return_hits(Body) ->
    Caller = "-export([f/0]).\nf() ->\n" ++ Body ++ ".\n",
    two_module_warnings(Caller, return_callee(), discrepancy).

pattern_that_the_spec_of_the_callee_rules_out_test() ->
    ?assertEqual([{discrepancy, 4}], return_hits("    {ok, V} = ov_callee:f(),\n    V")),
    ?assertEqual([{discrepancy, 4}], return_hits("    {okk, V} = ov_callee:g(1),\n    V")),
    ?assertEqual([{discrepancy, 4}], return_hits("    {ok, _, _} = ov_callee:g(1)")).

pattern_that_the_spec_of_the_callee_allows_test() ->
    ?assertEqual([], return_hits("    ok = ov_callee:f()")),
    ?assertEqual([], return_hits("    {error, E} = ov_callee:f(),\n    E")),
    ?assertEqual([], return_hits("    {ok, V} = ov_callee:g(1),\n    V")),
    ?assertEqual([], return_hits("    {error, _} = ov_callee:g(1)")).

case_clause_that_the_spec_of_the_callee_rules_out_test() ->
    Body = "    case ov_callee:g(1) of\n        {ok, V} -> V;\n        {error, _} -> 0;\n        {oops, _} -> 1\n    end",
    ?assertEqual([{dead_code, 7}], return_hits(Body) ),
    %% no clause can match at all
    Warnings = return_hits("    case ov_callee:f() of\n        {ok, _} -> 1;\n        {nope, _} -> 2\n    end"),
    ?assert(lists:member({discrepancy, 4}, Warnings)),
    ?assert(lists:member({dead_code, 5}, Warnings)),
    ?assert(lists:member({dead_code, 6}, Warnings)).

callee_without_a_useful_spec_says_nothing_test() ->
    %% no -spec, and -spec ... -> term()
    ?assertEqual([], return_hits("    {ok, V} = ov_callee:h(),\n    V")),
    ?assertEqual([], return_hits("    {ok, V} = ov_callee:t(),\n    V")).

the_result_of_a_remote_call_only_names_the_caller_test() ->
    Caller = "-export([top/0]).\n"
             "top() -> mid() + 1.\n"
             "mid() ->\n"
             "    {ok, V} = ov_callee:f(),\n"
             "    V.\n",
    ?assertEqual([{discrepancy, 5}], two_module_warnings(Caller, return_callee(), discrepancy)).

spec_of_a_dependency_loaded_from_a_plt_is_used_test() ->
    Compile = fun(Name, Src) ->
        {ok, Toks, _} = erl_scan:string("-module(" ++ Name ++ ").\n" ++ Src),
        {ok, _, Beam} = compile:forms(split_forms(Toks, [], []), [debug_info, binary]),
        Beam
    end,
    CalleeBeam = Compile("ov_callee", return_callee()),
    {ok, DepPlt} = spectra_plt:from_beams([CalleeBeam]),
    File = "ext_specs_test.splt",
    ok = file:write_file(File, spectra_plt:encode(DepPlt)),
    try
        Caller = Compile("ov_caller", "-export([f/0]).\nf() ->\n    {ok, V} = ov_callee:f(),\n    V.\n"),
        {ok, Ws} = spectra:analyze_beams([Caller], #{plts => [File], mode => discrepancy, oxbow => false}),
        ?assertEqual([{discrepancy, 4}], [{K, L} || #spectra_warning{kind = K, line = L} <- Ws])
    after
        file:delete(File)
    end.

%% A declared return type that names a type of the other module (`-type t() :: ...`, `-spec f() -> t()`) cannot be resolved while the caller
%% is inferred: it is unknown, not impossible. (Spectra's own code showed it: `unfold_bounded_fun/1` returns `stype()`.)

named_type_callee() ->
    "-export([f/0, g/0]).\n-type t() :: {ok, integer()} | error.\n"
    "-spec f() -> t().\nf() -> error.\n"
    "-spec g() -> {ok, t()} | {error, term()}.\ng() -> {error, x}.\n".

named_hits(Body) ->
    Caller = "-export([f/0]).\nf() ->\n" ++ Body ++ ".\n",
    two_module_warnings(Caller, named_type_callee(), discrepancy).

return_type_that_names_a_type_of_the_callee_is_unknown_test() ->
    ?assertEqual([], named_hits("    case ov_callee:f() of\n        {ok, V} -> V;\n        error -> 0\n    end")),
    ?assertEqual([], named_hits("    {ok, {ok, V}} = ov_callee:g(),\n    V")),
    ?assertEqual([], named_hits("    {ok, T} = ov_callee:g(),\n    T")),
    %% what is spelled out in the spec is still known
    ?assertEqual([{discrepancy, 4}], named_hits("    {nope, T} = ov_callee:g(),\n    T")).

%% After a clause without a guard, what it matches is no longer in the type of the scrutinee for the clauses that follow:
%% `case f() of ok -> {ok, 1}; Err -> Err end` returns `{ok, 1} | {error, _}`, not `ok` as well.

case_negation_callee() ->
    "-export([f/0, g/0]).\n"
    "-spec f() -> ok | {error, atom()}.\nf() -> ok.\n"
    "-spec g() -> ok | {error, atom()} | {badrpc, term()}.\ng() -> ok.\n".

case_ret(Body) ->
    Caller = "-export([f/0]).\nf() ->\n" ++ Body ++ ".\n",
    Compile = fun(Name, Src) ->
        {ok, Toks, _} = erl_scan:string("-module(" ++ Name ++ ").\n" ++ Src),
        {ok, _, Beam} = compile:forms(split_forms(Toks, [], []), [debug_info, binary]),
        Beam
    end,
    {ok, Plt} = spectra_plt:from_beams([Compile("ov_caller", Caller), Compile("ov_callee", case_negation_callee())]),
    #module_summary{functions = Funcs} = maps:get(ov_caller, Plt#spectra_plt.modules),
    {fun_type, [], Ret} = (maps:get({ov_caller, f, 0}, Funcs))#func_contract.inferred_type,
    Ret.

variable_clause_after_a_covering_clause_is_precise_test() ->
    Ret = case_ret("    case ov_callee:f() of\n        ok -> {ok, 1};\n        Err -> Err\n    end"),
    ?assert(spectra_oracle:member({ok, 1}, Ret)),
    ?assert(spectra_oracle:member({error, x}, Ret)),
    ?assertNot(spectra_oracle:member(ok, Ret)).

several_covering_clauses_are_subtracted_test() ->
    Ret = case_ret("    case ov_callee:g() of\n        ok -> 1;\n        {error, _} -> 2;\n        Other -> Other\n    end"),
    ?assert(spectra_oracle:member(1, Ret)),
    ?assert(spectra_oracle:member(2, Ret)),
    ?assert(spectra_oracle:member({badrpc, x}, Ret)),
    ?assertNot(spectra_oracle:member(ok, Ret)),
    ?assertNot(spectra_oracle:member({error, x}, Ret)).

a_clause_with_a_guard_subtracts_nothing_test() ->
    Ret = case_ret("    case ov_callee:f() of\n        ok when 1 > 2 -> 1;\n        Other -> Other\n    end"),
    ?assert(spectra_oracle:member(ok, Ret)),
    ?assert(spectra_oracle:member({error, x}, Ret)).

a_clause_that_covers_only_part_subtracts_only_that_part_test() ->
    Ret = case_ret("    case ov_callee:g() of\n        {error, not_found} -> 1;\n        Other -> Other\n    end"),
    %% {error, atom()} is not covered by {error, not_found}: it stays
    ?assert(spectra_oracle:member({error, other}, Ret)),
    ?assert(spectra_oracle:member(ok, Ret)).

catch_all_after_exhaustive_clauses_stays_quiet_test() ->
    ?assertEqual([], two_module_warnings("-export([f/0]).\nf() ->\n    case ov_callee:f() of\n        ok -> 1;\n        {error, _} -> 2;\n        _ -> 3\n    end.\n",
                                         case_negation_callee(), discrepancy)).

%% A variable in a pattern may be new (a catch-all) or already bound (an equality test): the code does not say, so only patterns without
%% variables take their values out of the type that is left. (`case X of Checksum -> ok; _ -> error end` made `error` disappear.)

a_variable_that_is_already_bound_is_not_a_catch_all_test() ->
    Ret = inferred_return("f(X) ->\n    Y = 1,\n    case X of\n        Y -> ok;\n        _ -> error\n    end.\n"),
    ?assert(spectra_oracle:member(ok, Ret)),
    ?assert(spectra_oracle:member(error, Ret)),
    %% and as the head of a function: Checksum is compared, not bound
    Ret2 = inferred_return("f(Checksum) -> g(Checksum, 5).\ng(Checksum, Computed) ->\n    case Computed of\n        Checksum -> ok;\n        _ -> error\n    end.\n"),
    ?assert(spectra_oracle:member(ok, Ret2)),
    ?assert(spectra_oracle:member(error, Ret2)).

a_pattern_with_a_variable_subtracts_nothing_test() ->
    Ret = case_ret("    case ov_callee:g() of\n        {error, E} -> E;\n        Other -> Other\n    end"),
    %% {error, E} might be an equality test on E: nothing is taken out, `{error, _}` stays possible in the second clause
    ?assert(spectra_oracle:member({error, x}, Ret)),
    ?assert(spectra_oracle:member(ok, Ret)).

%% A BIF that is not in the table gives `any`, and `9 + any` is `number`: it may be a float, so it does not fit `non_neg_integer()`.
%% The BIFs that always return integers are known.

integer_returning_bifs_test() ->
    lists:foreach(
        fun(Expr) ->
            Ret = inferred_return("f(D) -> 9 + " ++ Expr ++ ".\n"),
            ?assert({Expr, spectra_oracle:member(10, Ret)} =:= {Expr, true}),
            ?assert({Expr, spectra_oracle:member(1.5, Ret)} =:= {Expr, false})
        end,
        ["iolist_size(D)", "erlang:external_size(D)", "erlang:phash2(D)", "erlang:phash2(D, 100)", "size(D)"]).

%% The sign survives addition and multiplication: 9 + size is positive, not just an integer.

arithmetic_keeps_the_sign_test_() ->
    Infer = fun(Src) -> inferred_return("f(N) when is_integer(N), N >= 0 -> " ++ Src ++ ".\n") end,
    Is = fun(Type, V) -> spectra_oracle:member(V, Type) end,
    [?_assert(Is(Infer("9 + iolist_size(N)"), 9)),
     ?_assertNot(Is(Infer("9 + iolist_size(N)"), 0)),          %% positive
     ?_assertNot(Is(Infer("9 + iolist_size(N)"), -1)),
     ?_assert(Is(Infer("iolist_size(N) + N"), 0)),              %% two non-negative: may be 0
     ?_assertNot(Is(Infer("iolist_size(N) + N"), -1)),
     ?_assertNot(Is(Infer("iolist_size(N) * 3"), -3)),
     ?_assert(Is(Infer("iolist_size(N) - 1"), -1)),             %% a subtraction can go below 0
     ?_assert(Is(Infer("N - N"), -5))].

time_bifs_are_not_assumed_to_be_non_negative_test() ->
    %% erlang:system_time/0 may be negative: it stays `any`, so a declared non_neg_integer() is not contradicted
    Ret = inferred_return("f(_) -> erlang:system_time(millisecond).\n"),
    ?assertEqual(any, Ret).

%% Inside a module too, a call goes by what the callee's -spec declares: `{ok, V} = g()` when g/0 is `ok | {error, _}`, and a callee whose body
%% contradicts its spec does not make its callers wrong.

own_module_contracts_test() ->
    Spec = "-export([f/0, h/0]).\n-spec g() -> ok | {error, atom()}.\ng() -> ok.\n",
    ?assertEqual([{discrepancy, 6}], plain_warnings(Spec ++ "f() ->\n    {ok, V} = g(),\n    V.\nh() -> ok.\n")),
    ?assertEqual([{discrepancy, 6}], plain_warnings(Spec ++ "f() ->\n    {ok, V} = cmp_sample:g(),\n    V.\nh() -> ok.\n")),
    ?assertEqual([], plain_warnings(Spec ++ "f() ->\n    {error, E} = g(),\n    E.\nh() -> ok.\n")).

a_callee_that_contradicts_its_spec_does_not_make_callers_wrong_test() ->
    Src = "-export([top/0]).\n"
          "-spec g() -> integer().\n"
          "g() -> oops.\n"                  %% line 4 of the file: the only wrong function
          "-spec f() -> integer().\n"
          "f() -> g() + 1.\n"
          "top() -> {f(), g()}.\n",
    ?assertEqual([{gradual_mismatch, 4}], gradual_warnings(Src)).

gradual_warnings(Src) ->
    Text = "-module(cmp_sample).\n" ++ Src,
    {ok, Toks, _} = erl_scan:string(Text),
    {ok, cmp_sample, Beam} = compile:forms(split_forms(Toks, [], []), [debug_info, binary]),
    {ok, Ws} = spectra:analyze_beams([Beam], #{oxbow => false}),
    [{K, L} || #spectra_warning{kind = K, line = L} <- Ws].

%% A variable in a pattern is a catch-all when it is new, and an equality test when it is already bound. The environment knows which ones are bound,
%% so a pattern with only new variables takes its values out of what is left of the scrutinee (`{ok, State} -> ...; Err -> Err`).

fresh_callee() ->
    "-export([f/0, g/0]).\n"
    "-spec f() -> {ok, integer()} | {error, atom()}.\nf() -> {ok, 1}.\n"
    "-spec g() -> ok.\ng() -> ok.\n".

fresh_ret(Body) ->
    Caller = "-export([f/0]).\n-record(r, {v}).\nf() ->\n" ++ Body ++ ".\n",
    Compile = fun(Name, Src) ->
        {ok, Toks, _} = erl_scan:string("-module(" ++ Name ++ ").\n" ++ Src),
        {ok, _, Beam} = compile:forms(split_forms(Toks, [], []), [debug_info, binary]),
        Beam
    end,
    {ok, Plt} = spectra_plt:from_beams([Compile("ov_caller", Caller), Compile("ov_callee", fresh_callee())]),
    #module_summary{functions = Funcs} = maps:get(ov_caller, Plt#spectra_plt.modules),
    {fun_type, [], Ret} = (maps:get({ov_caller, f, 0}, Funcs))#func_contract.inferred_type,
    Ret.

new_variables_take_their_values_out_test() ->
    Ret = fresh_ret("    case ov_callee:f() of\n        {ok, State} -> {done, State};\n        Err -> Err\n    end"),
    ?assert(spectra_oracle:member({done, 1}, Ret)),
    ?assert(spectra_oracle:member({error, x}, Ret)),
    ?assertNot(spectra_oracle:member({ok, 1}, Ret)).

a_variable_bound_by_a_record_pattern_is_not_new_test() ->
    %% X comes out of the record: `X ->` compares, it does not catch everything
    Ret = fresh_ret("    R = #r{v = ok},\n    #r{v = X} = R,\n    case ov_callee:g() of\n        X -> matched;\n        _ -> other\n    end"),
    ?assert(spectra_oracle:member(matched, Ret)),
    ?assert(spectra_oracle:member(other, Ret)).

a_variable_bound_in_the_head_is_not_new_test() ->
    Ret = inferred_return("f(Y) ->\n    case Y of\n        {ok, Z} -> Z;\n        Z -> {other, Z}\n    end.\n"),
    %% Z is new in both clauses: the second one only sees what the first did not take
    ?assert(spectra_oracle:member({other, 5}, Ret)),
    ?assert(spectra_oracle:member(1, Ret)).

arithmetic_on_something_unknown_is_unknown_test() ->
    ?assertEqual(any, inferred_return("f(X) -> X + 1.\n")),
    ?assertEqual(integer, inferred_return("f(X) when is_integer(X) -> X + 1.\n")),
    ?assertEqual(float, inferred_return("f(X) -> X + 1.5.\n")).

%% A function that never returns (`no_return()`, `none`) is a valid callback for any return type: its return is the bottom type, not a clash.

never_returning_callee() ->
    "-export([mk/0, use/1]).\n"
    "-spec mk() -> fun((_, _) -> no_return()).\nmk() -> fun(_, _) -> erlang:error(boom) end.\n"
    "-spec use(fun((atom(), term()) -> ok)) -> ok.\nuse(F) -> F(a, b).\n".

a_function_that_never_returns_is_a_callback_for_anything_test() ->
    Caller = "-export([f/0]).\nf() ->\n    ov_callee:use(ov_callee:mk()).\n",
    ?assertEqual([], two_module_warnings(Caller, never_returning_callee(), discrepancy)),
    ?assertEqual([], two_module_warnings(Caller, never_returning_callee(), hybrid)).

meet_of_fun_types_whose_return_never_comes_back_test_() ->
    Never = {fun_type, [any, any], none},
    Wants = {fun_type, [atom, any], {atom_lit, ok}},
    [?_assertNotEqual(none, spectra_type:meet(Never, Wants)),
     ?_assertNotEqual(none, spectra_type:meet(Wants, Never)),
     %% still disjoint when the arguments are, or the arity differs
     ?_assertEqual(none, spectra_type:meet({fun_type, [integer], none}, {fun_type, [atom], {atom_lit, ok}})),
     ?_assertEqual(none, spectra_type:meet({fun_type, [any], none}, {fun_type, [any, any], {atom_lit, ok}}))].
