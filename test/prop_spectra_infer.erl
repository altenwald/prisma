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

-define(TAGS, [int, bool, atom, pair, cell, list]).
-define(RUNS, 25).

%% -------------------------------------------------------------------------
%% Program generator
%% -------------------------------------------------------------------------

program() ->
    ?LET(Tags, [tag(), tag()],
         ?LET(Body, body([{"A", lists:nth(1, Tags)}, {"B", lists:nth(2, Tags)}]),
              {render(Body), Tags})).

tag() -> oneof(?TAGS).

render({Stmts, Last}) ->
    lists:flatten(["-module(MODNAME).\n-export([f/2]).\nf(A, B) ->\n", string:join(Stmts, ",\n"),
                   ",\n    ", Last, ".\n"]).

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
    oneof(NonBoolean ++ [CellCase] ++ [
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
leaf(list, _) -> oneof(["[]", "[1, 2]"]).

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
value(list) -> resize(3, list(range(-3, 5))).

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
check(Src0, Samples) ->
    Name = "pm" ++ integer_to_list(erlang:unique_integer([positive])),
    Src = lists:flatten(string:replace(Src0, "MODNAME", Name, all)),
    {ok, Mod, Beam} = compile:forms([{attribute, 1, file, {Name ++ ".erl", 1}} | forms(Src)], [debug_info, binary]),
    Dir = filename:absname(filename:join(["_build", "test", "prop_infer"])),
    File = filename:join(Dir, Name ++ ".beam"),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, Beam),
    try
        {ok, Plt} = spectra_plt:from_beams([Beam]),
        #module_summary{functions = Funcs} = maps:get(Mod, Plt#spectra_plt.modules),
        {fun_type, Dom, Ret} = (maps:get({Mod, f, 2}, Funcs))#func_contract.inferred_type,
        {ok, Warnings} = spectra:analyze_beams([Beam], #{mode => discrepancy, oxbow => false}),
        Claims = [W || #spectra_warning{kind = K} = W <- Warnings, K =:= discrepancy orelse K =:= dead_code],
        _ = cover:start(),
        {ok, Mod} = cover:compile_beam(File),
        run_all(Mod, Samples, Dom, Ret, Claims)
    after
        _ = cover:stop(),
        code:purge(Mod),
        code:delete(Mod),
        file:delete(File)
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
    ?FORALL({Src, Tags}, program(),
        ?FORALL(Samples, samples(Tags),
            begin
                R = check(Src, Samples),
                ?WHENFAIL(io:format("~n~s~n~p~n", [Src, R]), R =:= ok)
            end)).
