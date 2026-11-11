%% Soundness of the inference and of the discrepancy warnings, checked by running the code.
%%
%% PropEr generates small, well-typed Erlang modules (one function, `f/2`, a few bindings and `case` expressions, each
%% clause on its own line) and samples of arguments. The module is compiled and executed, and for every run that returns
%% normally:
%%   * the arguments must belong to the inferred domain and the result to the inferred return type (success typing:
%%     what really happens can never be outside what was inferred);
%%   * no `discrepancy` or `dead_code` warning may point to a line that has just been executed. Those warnings claim
%%     "this call fails" or "this clause cannot match", and a line that ran without crashing refutes them. `cover`
%%     tells which lines ran.
%% Every refutation is a proven false positive, minimized by PropEr's shrinking.
-module(prop_prisma_infer).

-include_lib("proper/include/proper.hrl").
-include("prisma.hrl").

-define(TAGS, [int, bool, atom, pair, cell, list, float]).
%% what the generated callee module accepts (its -spec is overloaded over these)
-define(CALLEE_TAGS, [int, bool, atom, pair, list]).
-define(RUNS, 25).

%% -------------------------------------------------------------------------
%% Program generator
%% -------------------------------------------------------------------------

program() ->
    ?LET(Callee, callee(),
         ?LET({Tags, Rec}, {[tag(), tag()], boolean()},
              ?LET(Body, body([{callee, Callee}, {"A", lists:nth(1, Tags)}, {"B", lists:nth(2, Tags)}]),
                   {render(Body, Rec), render_callee(Callee), Tags, Rec}))).

tag() -> oneof(?TAGS).

%% With Rec the second argument is taken out of a record in the head, `#r{v = B}`: the variables of a record pattern are
%% not in the inference environment, which is where the environment joins of guards go wrong.
render({Stmts, Last}, Rec) ->
    Head = case Rec of
        true -> "f(A, #r{v = B})";
        false -> "f(A, B)"
    end,
    Decl = "-record(r, {v}).\n",
    lists:flatten(["-module(MODNAME).\n-export([f/2]).\n", Decl, Head, " ->\n", string:join(Stmts, ",\n"),
                   ",\n    ", Last, ".\n"]).

%% The module the generated code calls: g/1 or g/2 with an overloaded -spec, one clause per vector of argument types. Its
%% guards are exclusive per type and its clauses return their own number, so an argument outside every vector crashes
%% (function_clause) and a call inside one runs: a warning on a call that ran is refuted by the run, not by the spec.
callee() ->
    ?LET(Arity, oneof([1, 2]),
         ?LET(Vecs, resize(3, non_empty(list(vector(Arity, oneof(?CALLEE_TAGS))))),
              {Arity, lists:usort(Vecs)})).

render_callee({Arity, Vecs}) ->
    Vars = [fmt("X~b", [I]) || I <- lists:seq(1, Arity)],
    Spec = string:join([fmt("(~s) -> integer()", [string:join([spec_type(T) || T <- Vec], ", ")]) || Vec <- Vecs], "; "),
    Clauses = [fmt("g(~s) when ~s -> ~b",
                   [string:join(Vars, ", "), string:join([guard(T, V) || {T, V} <- lists:zip(Vec, Vars)], ", "), K])
               || {K, Vec} <- lists:zip(lists:seq(1, length(Vecs)), Vecs)],
    lists:flatten(["-module(CALLEE).\n-export([g/", integer_to_list(Arity), "]).\n-spec g", Spec, ".\n",
                   string:join(Clauses, ";\n"), ".\n"]).

spec_type(int) -> "integer()";
spec_type(bool) -> "boolean()";
spec_type(atom) -> "a | b | c";
spec_type(pair) -> "{integer(), integer()}";
spec_type(list) -> "[integer()]".

guard(int, V) -> fmt("is_integer(~s)", [V]);
guard(bool, V) -> fmt("is_boolean(~s)", [V]);
guard(atom, V) -> fmt("(~s =:= a orelse ~s =:= b orelse ~s =:= c)", [V, V, V]);
guard(pair, V) -> fmt("(is_tuple(~s) andalso tuple_size(~s) =:= 2)", [V, V]);
guard(list, V) -> fmt("is_list(~s)", [V]).

body(Env) ->
    ?LET(N, range(1, 4), body(N, Env, 1, [])).

body(0, Env, _K, Acc) ->
    Ints = [V || {V, int} <- Env],
    {lists:reverse(Acc), hd(Ints ++ ["0"])};
body(N, Env, K, Acc) ->
    V = "V" ++ integer_to_list(K),
    ?LET({Stmt, Tag}, stmt(V, K, Env),
         body(N - 1, [{V, Tag} | Env], K + 1, [Stmt | Acc])).

%% A statement binds V; the result is {Text, TagOfV}. Each `case` clause is on its own line.
stmt(V, K, Env) ->
    S = integer_to_list(K),
    NonBoolean = [
        ?LET({B, I}, {expr(bool, Env, 1), expr(int, Env, 1)},
             {fmt("    ~s = case ~s andalso ~s of\n        false -> 0;\n        N~s when is_integer(N~s) -> N~s\n    end",
                  [V, B, I, S, S, S]), int}),
        ?LET({B, I}, {expr(bool, Env, 1), expr(int, Env, 1)},
             {fmt("    ~s = case ~s orelse {false, ~s} of\n        true -> 1;\n        {false, N~s} -> N~s\n    end",
                  [V, B, I, S, S]), int})
    ],
    CellCase = ?LET(C, expr(cell, Env, 1),
                    {fmt("    ~s = case ~s of\n        [H~s | T~s] when is_integer(T~s) -> H~s + T~s\n    end",
                         [V, C, S, S, S, S, S]), int}),
    %% The same call in several places: plain, in a fun, in a comprehension, in a record field. A failure inside any of these
    %% propagates, so any argument types will do. Inside `try ... catch` a failure would be swallowed (and the run would look
    %% fine), so there the arguments always fit a clause of the spec.
    CallStmts = case lists:keyfind(callee, 1, Env) of
        {callee, {Arity, Vecs}} ->
            Shapes = ["    ~s = CALLEE:g(~s)",
                      "    ~s = (fun() -> CALLEE:g(~s) end)()",
                      "    ~s = hd([CALLEE:g(~s) || _ <- [1]])",
                      "    ~s = element(2, #r{v = CALLEE:g(~s)})",
                      %% the result goes into patterns that can match (the spec says integer())
                      "    ~s = case CALLEE:g(~s) of\n        1 -> 10;\n        R@ when is_integer(R@) -> R@\n    end"],
            [?LET({Shape, ArgTags}, {oneof(Shapes), frequency([{4, oneof(Vecs)}, {1, vector(Arity, oneof(?CALLEE_TAGS))}])},
                  ?LET(Args, [expr(T, Env, 1) || T <- ArgTags],
                       {unique_vars(fmt(Shape, [V, string:join(Args, ", ")]), V), int})),
             ?LET(ArgTags, oneof(Vecs),
                  ?LET(Args, [expr(T, Env, 1) || T <- ArgTags],
                       {fmt("    ~s = try CALLEE:g(~s) catch _:_ -> 0 end", [V, string:join(Args, ", ")]), int}))];
        false ->
            []
    end,
    FloatEq = ?LET({F, X, Y}, {expr(float, Env, 1), expr(int, Env, 1), expr(int, Env, 1)},
                   {fmt("    ~s = if\n        ~s == 0 -> ~s;\n        true -> ~s\n    end", [V, F, X, Y]), int}),
    %% BIFs in a guard, always on the right type: a guard that Prisma decides cannot succeed has to be really dead
    GuardBif = ?LET({L, P}, {expr(list, Env, 1), expr(pair, Env, 1)},
                    {fmt("    ~s = if\n        length(~s) > 1 -> 1;\n        tuple_size(~s) =:= 2 -> 2;\n        true -> 3\n    end", [V, L, P]), int}),
    VarNames = [N || {N, T} <- Env, is_list(N), is_atom(T)],
    IntVars = [N || {N, int} <- Env, is_list(N)],
    CompareFloat = ?LET({F, X, Y, Z}, {expr(float, Env, 1), expr(int, Env, 1), expr(int, Env, 1), expr(int, Env, 1)},
                        {fmt("    ~s = if\n        ~s < 0 -> ~s;\n        ~s > 0 -> ~s;\n        true -> ~s\n    end",
                             [V, F, X, F, Y, Z]), int}),
    %% X > 0 is true of every non-number, X < 0 of negative numbers only; X is any variable, whatever its type
    CompareAny = ?LET(X, elements(VarNames),
                      {fmt("    ~s = if\n        ~s > 0 -> 1;\n        ~s < 0 -> 2;\n        true -> 3\n    end", [V, X, X]), int}),
    OrelseGuard = case IntVars of
        [_, _ | _] ->
            [?LET({X, Y}, ?SUCHTHAT({P, Q}, {elements(IntVars), elements(IntVars)}, P =/= Q),
                  {fmt("    ~s = if\n        ~s == 0 orelse ~s == 0 -> case ~s of\n            5 -> 1;\n            _ -> 2\n        end;\n        true -> 0\n    end",
                       [V, X, Y, Y]), int})];
        _ ->
            []
    end,
    oneof(NonBoolean ++ CallStmts ++ OrelseGuard ++ [CellCase, FloatEq, CompareFloat, CompareAny, GuardBif] ++ [
        ?LET(T, tag(), ?LET(E, expr(T, Env, 2), {line(V, E), T})),
        ?LET({I, X, Y}, {expr(int, Env, 1), expr(int, Env, 1), expr(int, Env, 1)},
             {fmt("    ~s = case ~s of\n        0 -> ~s;\n        _ -> ~s\n    end", [V, I, X, Y]), int}),
        ?LET(L, expr(list, Env, 1),
             {fmt("    ~s = case ~s of\n        [] -> 0;\n        [H~s | _] -> H~s\n    end", [V, L, S, S]), int}),
        ?LET(P, expr(pair, Env, 1),
             {fmt("    ~s = case ~s of\n        {X~s, Y~s} when X~s > Y~s -> X~s;\n        {_, Y~s} -> Y~s\n    end",
                  [V, P, S, S, S, S, S, S, S]), int}),
        ?LET(At, expr(atom, Env, 0),
             {fmt("    ~s = case ~s of\n        a -> 1;\n        b -> 2;\n        c -> 3\n    end", [V, At]), int})
    ]).

line(V, E) -> fmt("    ~s = ~s", [V, E]).

expr(Tag, Env, D) ->
    Vars = [N || {N, T} <- Env, T =:= Tag],
    frequency([{3, leaf(Tag, Env)}]
              ++ [{3, elements(Vars)} || Vars =/= []]
              ++ [{2, compound(Tag, Env, D)} || D > 0]).

leaf(int, Env) -> ?LET(N, lowest(Env, 5), "(" ++ integer_to_list(N) ++ ")");
leaf(bool, _) -> oneof(["true", "false"]);
leaf(atom, _) -> oneof(["a", "b", "c"]);
leaf(pair, Env) -> ?LET({X, Y}, {lowest(Env, 5), lowest(Env, 5)}, fmt("{(~b), (~b)}", [X, Y]));
leaf(cell, Env) -> ?LET({X, Y}, {lowest(Env, 5), lowest(Env, 5)}, fmt("[(~b) | (~b)]", [X, Y]));
leaf(list, _) -> oneof(["[]", "[1, 2]"]);
leaf(float, _) -> oneof(["0.0", "1.5", "2.0"]).

lowest(_Env, Hi) -> range(-3, Hi).

compound(int, Env, D) ->
    oneof([
        ?LET({X, Y}, {expr(int, Env, D - 1), expr(int, Env, D - 1)}, fmt("(~s + ~s)", [X, Y])),
        ?LET(P, expr(pair, Env, D - 1), fmt("element(1, ~s)", [P])),
        ?LET(L, expr(list, Env, D - 1), fmt("length(~s)", [L])),
        ?LET(C, expr(cell, Env, D - 1), fmt("hd(~s)", [C])),
        ?LET(C, expr(cell, Env, D - 1), fmt("tl(~s)", [C]))
    ]);
compound(bool, Env, D) ->
    oneof([
        ?LET({X, Y}, {expr(int, Env, D - 1), expr(int, Env, D - 1)}, fmt("(~s > ~s)", [X, Y])),
        ?LET({X, Y}, {expr(bool, Env, D - 1), expr(bool, Env, D - 1)}, fmt("(~s andalso ~s)", [X, Y])),
        ?LET({X, Y}, {expr(bool, Env, D - 1), expr(bool, Env, D - 1)}, fmt("(~s orelse ~s)", [X, Y]))
    ]);
compound(atom, Env, _D) -> leaf(atom, Env);
compound(float, Env, D) ->
    ?LET({X, Y}, {expr(int, Env, D - 1), expr(int, Env, D - 1)}, fmt("(~s / ~s)", [X, Y]));
compound(pair, Env, D) ->
    ?LET({X, Y}, {expr(int, Env, D - 1), expr(int, Env, D - 1)}, fmt("{~s, ~s}", [X, Y]));
compound(cell, Env, D) ->
    ?LET({X, Y}, {expr(int, Env, D - 1), expr(int, Env, D - 1)}, fmt("[~s | ~s]", [X, Y]));
compound(list, Env, D) ->
    oneof([
        ?LET({X, Y}, {expr(int, Env, D - 1), expr(int, Env, D - 1)}, fmt("[~s, ~s]", [X, Y])),
        ?LET({X, L}, {expr(int, Env, D - 1), expr(list, Env, D - 1)}, fmt("[~s | ~s]", [X, L]))
    ]).

value(int) -> range(-3, 5);
value(bool) -> boolean();
value(atom) -> oneof([a, b, c]);
value(pair) -> {range(-3, 5), range(-3, 5)};
value(cell) -> ?LET({X, Y}, {range(-3, 5), range(-3, 5)}, [X | Y]);
value(list) -> resize(3, list(range(-3, 5)));
value(float) -> oneof([0.0, 0.5, 1.0, -1.5, 2.0]).

samples([T1, T2], Rec) ->
    vector(?RUNS, [value(T1), ?LET(V2, value(T2), case Rec of true -> {r, V2}; false -> V2 end)]).

fmt(F, A) -> lists:flatten(io_lib:format(F, A)).

%% A variable bound inside a `case` is unsafe afterwards, and a second statement that binds the same name would compare with it:
%% the `@` of a template is replaced by the name of the variable that the statement binds.
unique_vars(Line, V) -> lists:flatten(string:replace(Line, "@", V, all)).

%% -------------------------------------------------------------------------
%% Running the module
%% -------------------------------------------------------------------------

forms(Src) ->
    {ok, Toks, _} = erl_scan:string(Src, 1),
    split(Toks, [], []).

split([], [], Forms) -> lists:reverse(Forms);
split([{dot, _} = D | Rest], Acc, Forms) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([D | Acc])),
    split(Rest, [], [Form | Forms]);
split([T | Rest], Acc, Forms) -> split(Rest, [T | Acc], Forms).

%% ok | {refuted, Reason}
check(Src0, CalleeSrc0, Samples) ->
    Name = "pm" ++ integer_to_list(erlang:unique_integer([positive])),
    CalleeName = Name ++ "_c",
    Replace = fun(Text) ->
        lists:flatten(string:replace(lists:flatten(string:replace(Text, "MODNAME", Name, all)), "CALLEE", CalleeName, all))
    end,
    Src = Replace(Src0),
    CalleeSrc = Replace(CalleeSrc0),
    Compile = fun(N, Text) ->
        {ok, M, B} = compile:forms([{attribute, 1, file, {N ++ ".erl", 1}} | forms(Text)], [debug_info, binary]),
        {M, B}
    end,
    {Mod, Beam} = Compile(Name, Src),
    {CalleeMod, CalleeBeam} = Compile(CalleeName, CalleeSrc),
    Dir = filename:absname(filename:join(["_build", "test", "prop_infer"])),
    File = filename:join(Dir, Name ++ ".beam"),
    CalleeFile = filename:join(Dir, CalleeName ++ ".beam"),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, Beam),
    ok = file:write_file(CalleeFile, CalleeBeam),
    {module, CalleeMod} = code:load_abs(filename:rootname(CalleeFile)),
    try
        {ok, Pplt} = prisma_pplt:from_beams([Beam]),
        #module_summary{functions = Funcs} = maps:get(Mod, Pplt#prisma_pplt.modules),
        {fun_type, Dom, Ret} = (maps:get({Mod, f, 2}, Funcs))#func_contract.inferred_type,
        {ok, Warnings} = prisma:analyze_beams([Beam, CalleeBeam], #{mode => discrepancy, oxbow => false}),
        Claims = [W || #prisma_warning{kind = K, mfa = {WMod, _, _}} = W <- Warnings, WMod =:= Mod,
                       K =:= discrepancy orelse K =:= dead_code],
        _ = cover:start(),
        {ok, Mod} = cover:compile_beam(File),
        run_all(Mod, Samples, Dom, Ret, Claims)
    after
        _ = cover:stop(),
        code:purge(Mod),
        code:delete(Mod),
        code:purge(CalleeMod),
        code:delete(CalleeMod),
        file:delete(File),
        file:delete(CalleeFile)
    end.

run_all(_Mod, [], _Dom, _Ret, _Claims) -> ok;
run_all(Mod, [Args | Rest], Dom, Ret, Claims) ->
    cover:reset(Mod),
    case try {ok, apply(Mod, f, Args)} catch _:_ -> crashed end of
        {ok, Result} ->
            {ok, Lines} = cover:analyse(Mod, coverage, line),
            Ran = [L || {{_, L}, {1, 0}} <- Lines],
            Refuted = [W || #prisma_warning{line = L} = W <- Claims, lists:member(L, Ran)],
            case {prisma_oracle:member(Result, Ret),
                  lists:all(fun({A, T}) -> prisma_oracle:member(A, T) end, lists:zip(Args, Dom)),
                  Refuted} of
                {true, true, []} -> run_all(Mod, Rest, Dom, Ret, Claims);
                {false, _, _} -> {refuted, {result_outside_inferred_type, Args, Result, Ret}};
                {_, false, _} -> {refuted, {argument_outside_inferred_domain, Args, Dom}};
                {_, _, _} -> {refuted, {warning_on_a_line_that_ran, Args, [{W#prisma_warning.kind,
                                                                            W#prisma_warning.line,
                                                                            W#prisma_warning.message}
                                                                           || W <- Refuted]}}
            end;
        crashed ->
            run_all(Mod, Rest, Dom, Ret, Claims)
    end.

%% -------------------------------------------------------------------------
%% Property
%% -------------------------------------------------------------------------

prop_inference_and_warnings_agree_with_execution() ->
    ?FORALL({Src, CalleeSrc, Tags, Rec}, program(),
        ?FORALL(Samples, samples(Tags, Rec),
            begin
                R = check(Src, CalleeSrc, Samples),
                ?WHENFAIL(io:format("~n~s~n~s~n~p~n", [Src, CalleeSrc, R]), R =:= ok)
            end)).

%% Soundness of guard narrowing (is_* BIFs, boolean combinations, negated guards,
%% numeric bounds, maps and binaries) verified against BEAM execution and cover.
prop_guard_narrowing_is_sound() ->
    ?FORALL({ClausesSpec, CatchAll}, {resize(5, non_empty(list(guard_clause()))), boolean()},
        begin
            R = check_guard_program(ClausesSpec, CatchAll),
            ?WHENFAIL(io:format("~nGuard spec: ~p (catchall=~p)~nResult: ~p~n", [ClausesSpec, CatchAll, R]), R =:= ok)
        end).

guard_clause() ->
    oneof([
        {"is_integer(X) andalso X >= 0", "X + 1"},
        {"is_integer(X) andalso X < 0", "-X"},
        {"is_float(X)", "trunc(X)"},
        {"is_number(X) andalso not is_integer(X)", "round(X)"},
        {"is_binary(X)", "byte_size(X)"},
        {"is_map(X) andalso map_size(X) > 0", "map_size(X)"},
        {"is_map(X)", "map_size(X)"},
        {"is_list(X)", "length(X)"},
        {"is_tuple(X) andalso tuple_size(X) =:= 2", "tuple_size(X)"},
        {"is_boolean(X)", "case X of true -> 1; false -> 0 end"},
        {"is_atom(X) andalso not is_boolean(X)", "length(atom_to_list(X))"},
        {"X =:= ok orelse X =:= error", "length(atom_to_list(X))"}
    ]).

guard_samples() ->
    [[-3], [0], [5], [1.5], [-2.5], [<<>>], [<<"ok">>], [#{a => 1}], [#{}],
     [[]], [[1, 2]], [{1, 2}], [{a, b, c}], [true], [false], [ok], [error], [foo]].

check_guard_program(ClausesSpec, CatchAll) ->
    Name = "pg" ++ integer_to_list(erlang:unique_integer([positive])),
    Catch = case CatchAll of true -> ["h(_) -> 0"]; false -> [] end,
    RenderedClauses = [fmt("h(X) when ~s -> ~s", [G, B]) || {G, B} <- ClausesSpec] ++ Catch,
    Src = lists:flatten([
        "-module(", Name, ").\n-export([h/1]).\n",
        string:join(RenderedClauses, ";\n"), ".\n"
    ]),
    {ok, Mod, Beam} = compile:forms([{attribute, 1, file, {Name ++ ".erl", 1}} | forms(Src)], [debug_info, binary]),
    Dir = filename:absname(filename:join(["_build", "test", "prop_infer"])),
    File = filename:join(Dir, Name ++ ".beam"),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, Beam),
    try
        {ok, Pplt} = prisma_pplt:from_beams([Beam]),
        #module_summary{functions = Funcs} = maps:get(Mod, Pplt#prisma_pplt.modules),
        {fun_type, [Dom1], Ret} = (maps:get({Mod, h, 1}, Funcs))#func_contract.inferred_type,
        {ok, Warnings} = prisma:analyze_beams([Beam], #{mode => discrepancy, oxbow => false}),
        Claims = [W || #prisma_warning{kind = K, mfa = {WMod, _, _}} = W <- Warnings,
                       WMod =:= Mod,
                       K =:= discrepancy orelse K =:= dead_code],
        _ = cover:start(),
        {ok, Mod} = cover:compile_beam(File),
        run_guard_samples(Mod, guard_samples(), Dom1, Ret, Claims)
    after
        _ = cover:stop(),
        code:purge(Mod),
        code:delete(Mod),
        file:delete(File)
    end.

run_guard_samples(_Mod, [], _Dom1, _Ret, _Claims) -> ok;
run_guard_samples(Mod, [[Arg] | Rest], Dom1, Ret, Claims) ->
    cover:reset(Mod),
    case try {ok, Mod:h(Arg)} catch _:_ -> crashed end of
        {ok, Result} ->
            {ok, Lines} = cover:analyse(Mod, coverage, line),
            Ran = [L || {{_, L}, {1, 0}} <- Lines],
            Refuted = [W || #prisma_warning{line = L} = W <- Claims, lists:member(L, Ran)],
            case {prisma_oracle:member(Result, Ret),
                  prisma_oracle:member(Arg, Dom1),
                  Refuted} of
                {true, true, []} -> run_guard_samples(Mod, Rest, Dom1, Ret, Claims);
                {false, _, _} -> {refuted, {guard_result_outside_inferred_type, Arg, Result, Ret}};
                {_, false, _} -> {refuted, {guard_arg_outside_inferred_domain, Arg, Dom1}};
                {_, _, _} -> {refuted, {guard_warning_on_line_that_ran, Arg, Refuted}}
            end;
        crashed ->
            run_guard_samples(Mod, Rest, Dom1, Ret, Claims)
    end.
