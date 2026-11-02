-module(spectra_gradual_tests).

-include_lib("eunit/include/eunit.hrl").
-include("spectra.hrl").

consistent_subtype_primitives_and_unions_test() ->
    ?assert(spectra_type:consistent_subtype(any, integer)),
    ?assert(spectra_type:consistent_subtype(integer, any)),
    ?assert(spectra_type:consistent_subtype(none, integer)),
    ?assertNot(spectra_type:consistent_subtype(integer, none)),

    ?assert(spectra_type:consistent_subtype(pos_integer, integer)),
    ?assert(spectra_type:consistent_subtype(pos_integer, non_neg_integer)),
    ?assert(spectra_type:consistent_subtype({int_lit, 5}, pos_integer)),
    ?assertNot(spectra_type:consistent_subtype({int_lit, 0}, pos_integer)),
    ?assertNot(spectra_type:consistent_subtype(integer, pos_integer)),
    ?assert(spectra_type:consistent_subtype({int_range, 2, 5}, {int_range, 1, 10})),
    ?assertNot(spectra_type:consistent_subtype({int_range, 0, 5}, pos_integer)),
    ?assert(spectra_type:consistent_subtype({int_range, 1, 5}, pos_integer)),

    %% Union subtyping: A | B <~ C requires BOTH A <~ C and B <~ C
    ?assert(spectra_type:consistent_subtype({union, [pos_integer, neg_integer]}, integer)),
    ?assertNot(spectra_type:consistent_subtype({union, [integer, atom]}, integer)),
    ?assert(spectra_type:consistent_subtype(integer, {union, [integer, atom]})).

consistent_subtype_maps_records_lists_and_opaques_test() ->
    %% Lists
    ?assert(spectra_type:consistent_subtype(nil, {list, integer})),
    ?assert(spectra_type:consistent_subtype({nonempty_list, pos_integer}, {list, integer})),
    ?assertNot(spectra_type:consistent_subtype({list, integer}, {nonempty_list, integer})),
    ?assertNot(spectra_type:consistent_subtype(nil, {nonempty_list, integer})),

    %% Maps with required (exact) and optional (assoc) keys
    ReqMap = {map, [
        {exact, {atom_lit, id}, integer},
        {assoc, {atom_lit, name}, {binary, 0, 8}}
    ]},
    ValidMap1 = {map, [
        {exact, {atom_lit, id}, pos_integer},
        {exact, {atom_lit, name}, {binary, 0, 8}}
    ]},
    ValidMap2 = {map, [
        {exact, {atom_lit, id}, {int_lit, 1}}
    ]},
    MissingReqKeyMap = {map, [
        {exact, {atom_lit, name}, {binary, 0, 8}}
    ]},
    WrongValTypeMap = {map, [
        {exact, {atom_lit, id}, atom}
    ]},
    ?assert(spectra_type:consistent_subtype(ValidMap1, ReqMap)),
    ?assert(spectra_type:consistent_subtype(ValidMap2, ReqMap)),
    ?assertNot(spectra_type:consistent_subtype(MissingReqKeyMap, ReqMap)),
    ?assertNot(spectra_type:consistent_subtype(WrongValTypeMap, ReqMap)),

    %% Records
    RecSuper = {record, user, [{id, integer}, {active, boolean}]},
    RecSubOk = {record, user, [{id, pos_integer}, {active, {atom_lit, true}}]},
    RecSubBad = {record, user, [{id, atom}, {active, boolean}]},
    ?assert(spectra_type:consistent_subtype(RecSubOk, RecSuper)),
    ?assertNot(spectra_type:consistent_subtype(RecSubBad, RecSuper)),

    %% Opaques
    Opaque = {opaque, mod_a, token, [], {binary, 0, 8}},
    ?assert(spectra_type:consistent_subtype(Opaque, Opaque)),
    ?assertNot(spectra_type:consistent_subtype({binary, 0, 8}, Opaque)),
    ?assertNot(spectra_type:consistent_subtype(Opaque, {binary, 0, 8})).

gradual_mode_catches_wider_unions_and_spec_body_test() ->
    Forms = [
        {attribute, 1, module, gradual_sample},
        {attribute, 2, export, [
            {strict_int, 1},
            {caller_with_union, 1},
            {bad_passthrough, 1},
            {good_passthrough, 1}
        ]},
        {attribute, 3, spec, {{strict_int, 1}, [
            {type, 3, 'fun', [{type, 3, product, [{type, 3, integer, []}]}, {type, 3, integer, []}]}
        ]}},
        {attribute, 4, spec, {{bad_passthrough, 1}, [
            {type, 4, 'fun', [
                {type, 4, product, [{type, 4, union, [{type, 4, integer, []}, {type, 4, atom, []}]}]},
                {type, 4, integer, []}
            ]}
        ]}},
        {attribute, 5, spec, {{good_passthrough, 1}, [
            {type, 5, 'fun', [
                {type, 5, product, [{type, 5, pos_integer, []}]},
                {type, 5, integer, []}
            ]}
        ]}},
        {function, 6, strict_int, 1, [
            {clause, 6, [{var, 6, 'X'}], [], [{op, 6, '+', {var, 6, 'X'}, {integer, 6, 1}}]}
        ]},
        {function, 7, caller_with_union, 1, [
            {clause, 7, [{var, 7, 'Flag'}], [], [
                {match, 8, {var, 8, 'Val'},
                    {'case', 8, {var, 8, 'Flag'}, [
                        {clause, 9, [{atom, 9, true}], [], [{integer, 9, 42}]},
                        {clause, 10, [{atom, 10, false}], [], [{atom, 10, not_int}]}
                    ]}
                },
                {call, 11, {atom, 11, strict_int}, [{var, 11, 'Val'}]}
            ]}
        ]},
        {function, 12, bad_passthrough, 1, [
            {clause, 12, [{var, 12, 'X'}], [], [{var, 12, 'X'}]}
        ]},
        {function, 13, good_passthrough, 1, [
            {clause, 13, [{var, 13, 'X'}], [], [{var, 13, 'X'}]}
        ]}
    ],
    {ok, gradual_sample, BeamBin} = compile:forms(Forms, [debug_info]),

    %% In discrepancy mode, caller_with_union and bad_passthrough CAN succeed -> 0 warnings
    {ok, DiscrepancyWarns} = spectra:analyze_beams([BeamBin], #{mode => discrepancy}),
    ?assertEqual([], DiscrepancyWarns),

    %% In gradual and hybrid modes, both caller_with_union and bad_passthrough fail gradual typing!
    {ok, GradualWarns} = spectra:analyze_beams([BeamBin], #{mode => gradual}),
    GradualMFAs = [{W#spectra_warning.kind, W#spectra_warning.mfa} || W <- GradualWarns],
    ?assert(lists:member({gradual_mismatch, {gradual_sample, caller_with_union, 1}}, GradualMFAs)),
    ?assert(lists:member({gradual_mismatch, {gradual_sample, bad_passthrough, 1}}, GradualMFAs)),
    ?assertNot(lists:keymember({gradual_sample, good_passthrough, 1}, 2, GradualMFAs)).

opacity_violation_detection_test() ->
    FormsA = [
        {attribute, 1, module, tok_mod},
        {attribute, 2, export_type, [{token, 0}]},
        {attribute, 3, opaque, {token, {type, 3, binary, []}, []}},
        {attribute, 4, export, [{consume, 1}]},
        {attribute, 5, spec, {{consume, 1}, [
            {type, 5, 'fun', [{type, 5, product, [{user_type, 5, token, []}]}, {type, 5, atom, []}]}
        ]}},
        {function, 6, consume, 1, [
            {clause, 6, [{var, 6, '_T'}], [], [{atom, 6, ok}]}
        ]}
    ],
    FormsB = [
        {attribute, 1, module, client_mod},
        {attribute, 2, export, [{forge_token, 0}]},
        {function, 3, forge_token, 0, [
            {clause, 3, [], [], [
                {call, 4, {remote, 4, {atom, 4, tok_mod}, {atom, 4, consume}}, [{bin, 4, []}]}
            ]}
        ]}
    ],
    {ok, tok_mod, BeamA} = compile:forms(FormsA, [debug_info]),
    {ok, client_mod, BeamB} = compile:forms(FormsB, [debug_info]),
    {ok, Warnings} = spectra:analyze_beams([BeamA, BeamB], #{mode => hybrid}),
    ?assertMatch([#spectra_warning{kind = opacity_violation, mfa = {client_mod, forge_token, 0}}], Warnings).

consistent_subtype_functions_binaries_and_bounds_test() ->
    ?assert(spectra_type:consistent_subtype({var, 'T'}, integer)),
    ?assert(spectra_type:consistent_subtype(integer, {var, 'T'})),
    ?assert(spectra_type:consistent_subtype(float, number)),
    ?assert(spectra_type:consistent_subtype(float, float)),
    ?assertNot(spectra_type:consistent_subtype(float, integer)),
    ?assertNot(spectra_type:consistent_subtype(integer, float)),
    ?assertNot(spectra_type:consistent_subtype(number, integer)),
    ?assert(spectra_type:consistent_subtype({atom_lit, true}, boolean)),
    ?assert(spectra_type:consistent_subtype(boolean, atom)),
    ?assert(spectra_type:consistent_subtype({atom_lit, hello}, atom)),
    ?assert(spectra_type:consistent_subtype({binary, 8, 8}, {binary, 0, 8})),
    ?assert(spectra_type:consistent_subtype({binary, 0, 8}, {binary, 0, 1})),
    ?assertNot(spectra_type:consistent_subtype({binary, 0, 1}, {binary, 0, 8})),
    ?assert(spectra_type:consistent_subtype(nil, {improper_list, integer, atom})),
    ?assert(spectra_type:consistent_subtype({improper_list, pos_integer, {atom_lit, ok}}, {improper_list, integer, atom})),
    ?assert(spectra_type:consistent_subtype({tuple, [integer]}, any_tuple)),
    ?assert(spectra_type:consistent_subtype({record, r, []}, any_tuple)),
    ?assert(spectra_type:consistent_subtype({tuple, [{atom_lit, r}, integer]}, {record, r, []})),
    ?assert(spectra_type:consistent_subtype({record, r, []}, {tuple, [{atom_lit, r}, integer]})),
    ?assert(spectra_type:consistent_subtype({tuple, [pos_integer]}, {tuple, [integer]})),
    ?assert(spectra_type:consistent_subtype({map, []}, any_map)),
    ?assert(spectra_type:consistent_subtype(any_map, {map, []})),
    ?assert(spectra_type:consistent_subtype({fun_type, [integer], atom}, any_fun)),
    ?assert(spectra_type:consistent_subtype({fun_any_args, atom}, any_fun)),
    ?assert(spectra_type:consistent_subtype({fun_type, [integer], {atom_lit, ok}}, {fun_any_args, atom})),
    ?assert(spectra_type:consistent_subtype({fun_any_args, {atom_lit, ok}}, {fun_any_args, atom})),
    %% Contravariant in arguments, covariant in return
    ?assert(spectra_type:consistent_subtype({fun_type, [number], pos_integer}, {fun_type, [integer], integer})),
    ?assertNot(spectra_type:consistent_subtype({fun_type, [pos_integer], integer}, {fun_type, [integer], integer})),
    ?assert(spectra_type:consistent_subtype(
        {opaque, m, t, [pos_integer], {binary, 0, 8}},
        {opaque, m, t, [integer], {binary, 0, 8}}
    )).
