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
-module(prop_spectra_infer).

-include_lib("proper/include/proper.hrl").
-include("spectra.hrl").

-define(TAGS, [int, bool, atom, pair, cell, list, float]).
%% what the generated callee module accepts (its -spec is overloaded over these)
-define(CALLEE_TAGS, [int, bool, atom, pair, list]).
-define(RUNS, 25).

%% -------------------------------------------------------------------------
%% Program generator
%% -------------------------------------------------------------------------

program() ->
    ?LET(Callee, callee(),
         ?LET(Tags, [tag(), tag()],
              ?LET(Body, body([{callee, Callee}, {"A", lists:nth(1, Tags)}, {"B", lists:nth(2, Tags)}]),
                   {render(Body), render_callee(Callee), Tags}))).

tag() -> oneof(?TAGS).

render({Stmts, Last}) ->
    lists:flatten(["-module(MODNAME).\n-export([f/2]).\nf(A, B) ->\n", string:join(Stmts, ",\n"),
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
    CallStmts = case lists:keyfind(callee, 1, Env) of
        {callee, {Arity, Vecs}} ->
            [?LET(ArgTags, frequency([{4, oneof(Vecs)}, {1, vector(Arity, oneof(?CALLEE_TAGS))}]),
                  ?LET(Args, [expr(T, Env, 1) || T <- ArgTags],
                       {fmt("    ~s = CALLEE:g(~s)", [V, string:join(Args, ", ")]), int}))];
        false ->
            []
    end,
    FloatEq = ?LET({F, X, Y}, {expr(float, Env, 1), expr(int, Env, 1), expr(int, Env, 1)},
                   {fmt("    ~s = if\n        ~s == 0 -> ~s;\n        true -> ~s\n    end", [V, F, X, Y]), int}),
    oneof(NonBoolean ++ CallStmts ++ [CellCase, FloatEq] ++ [
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

samples([T1, T2]) -> vector(?RUNS, [value(T1), value(T2)]).

fmt(F, A) -> lists:flatten(io_lib:format(F, A)).

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
        {ok, Plt} = spectra_plt:from_beams([Beam]),
        #module_summary{functions = Funcs} = maps:get(Mod, Plt#spectra_plt.modules),
        {fun_type, Dom, Ret} = (maps:get({Mod, f, 2}, Funcs))#func_contract.inferred_type,
        {ok, Warnings} = spectra:analyze_beams([Beam, CalleeBeam], #{mode => discrepancy, oxbow => false}),
        Claims = [W || #spectra_warning{kind = K, mfa = {WMod, _, _}} = W <- Warnings, WMod =:= Mod,
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
            Refuted = [W || #spectra_warning{line = L} = W <- Claims, lists:member(L, Ran)],
            case {spectra_oracle:member(Result, Ret),
                  lists:all(fun({A, T}) -> spectra_oracle:member(A, T) end, lists:zip(Args, Dom)),
                  Refuted} of
                {true, true, []} -> run_all(Mod, Rest, Dom, Ret, Claims);
                {false, _, _} -> {refuted, {result_outside_inferred_type, Args, Result, Ret}};
                {_, false, _} -> {refuted, {argument_outside_inferred_domain, Args, Dom}};
                {_, _, _} -> {refuted, {warning_on_a_line_that_ran, Args, [{W#spectra_warning.kind,
                                                                            W#spectra_warning.line,
                                                                            W#spectra_warning.message}
                                                                           || W <- Refuted]}}
            end;
        crashed ->
            run_all(Mod, Rest, Dom, Ret, Claims)
    end.

%% -------------------------------------------------------------------------
%% Property
%% -------------------------------------------------------------------------

prop_inference_and_warnings_agree_with_execution() ->
    ?FORALL({Src, CalleeSrc, Tags}, program(),
        ?FORALL(Samples, samples(Tags),
            begin
                R = check(Src, CalleeSrc, Samples),
                ?WHENFAIL(io:format("~n~s~n~s~n~p~n", [Src, CalleeSrc, R]), R =:= ok)
            end)).
