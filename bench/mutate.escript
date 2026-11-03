#!/usr/bin/env escript
%% Generates mutants of compiled Erlang modules: one injected fault each, in the abstract code, keeping every line number.
%%
%%   escript bench/mutate.escript <seed> <per-operator> <out-dir> <ebin-dir>...
%%
%% Writes <out-dir>/<id>/<Module>.beam and one JSON line per mutant in <out-dir>/mutants.jsonl:
%%   {id, operator, ebin, module, function, arity, first_line, last_line, line, description, compiler_warnings}
%% `compiler_warnings` are the warnings erlc gives inside the mutated function that it did not give for the original.
%%
%% Operators (each one a fault that cannot succeed under the contract, or under the Erlang BIF, whenever it runs):
%%   r1  a function whose -spec returns a simple type returns an atom instead
%%   r2  a call passes an atom where the callee's -spec asks for a simple type (integer(), binary(), ...)
%%   r3  a BIF gets an argument of the wrong type (length(foo))
%%   r4  a call to a function that does not exist, in a module of the corpus
%%   r6  `{Tag, X} = call(...)` with a Tag that the callee's -spec never returns
-mode(compile).

-define(ATOM, mutant_atom).

main([SeedS, PerOpS, OutDir | Ebins]) when Ebins =/= [] ->
    rand:seed(exsss, {list_to_integer(SeedS), 7, 11}),
    PerOp = list_to_integer(PerOpS),
    Mods = lists:flatmap(fun load_dir/1, Ebins),
    Specs = index_specs(Mods),
    io:format("modules: ~b, specs: ~b~n", [length(Mods), maps:size(Specs)]),
    Corpus = maps:from_list([{M, exports(Forms)} || #{module := M, forms := Forms} <- Mods]),
    ok = filelib:ensure_dir(filename:join(OutDir, "x")),
    {ok, Out} = file:open(filename:join(OutDir, "mutants.jsonl"), [write]),
    Counter = counters:new(1, []),
    lists:foreach(fun(Op) -> generate(Op, PerOp, Mods, Specs, Corpus, OutDir, Out, Counter) end,
                  [r1, r2, r3, r4, r6]),
    ok = file:close(Out),
    io:format("~b mutants in ~s~n", [counters:get(Counter, 1), OutDir]);
main(_) ->
    io:format("usage: mutate.escript <seed> <per-operator> <out-dir> <ebin-dir>...~n"),
    halt(1).

%% ------------------------------------------------------------------ loading

load_dir(Dir) ->
    lists:filtermap(fun(Beam) -> load(Dir, Beam) end, lists:sort(filelib:wildcard(filename:join(Dir, "*.beam")))).

load(Dir, Beam) ->
    case beam_lib:chunks(Beam, [debug_info]) of
        {ok, {Mod, [{debug_info, {debug_info_v1, Backend, Data}}]}} ->
            case catch Backend:debug_info(erlang_v1, Mod, Data, []) of
                {ok, Forms} -> {true, #{module => Mod, forms => Forms, ebin => Dir, beam => Beam}};
                _ -> false
            end;
        _ ->
            false
    end.

exports(Forms) -> lists:append([Es || {attribute, _, export, Es} <- Forms]).

index_specs(Mods) ->
    lists:foldl(
      fun(#{module := M, forms := Forms}, Acc) ->
              lists:foldl(
                fun({attribute, _, spec, {{F, A}, Clauses}}, A0) -> A0#{{M, F, A} => [fun_parts(C) || C <- Clauses]};
                   (_, A0) -> A0
                end, Acc, Forms)
      end, #{}, Mods).

%% {ArgTypes, ReturnType} of a spec clause, bounded or not
fun_parts({type, _, bounded_fun, [Fun, _Constraints]}) -> fun_parts(Fun);
fun_parts({type, _, 'fun', [{type, _, product, Args}, Ret]}) -> {Args, Ret};
fun_parts(_) -> {[], undefined}.

%% ------------------------------------------------------------------ site enumeration

generate(Op, PerOp, Mods, Specs, Corpus, OutDir, Out, Counter) ->
    io:format("~p sites: ~p~n", [Op, lists:sum([count(Op, Mod, Specs, Corpus) || Mod <- Mods])]),
    Pool = [{Mod, N} || Mod <- Mods, N <- lists:seq(0, count(Op, Mod, Specs, Corpus) - 1)],
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), P} || P <- Pool])],
    take(Op, PerOp, Shuffled, Specs, Corpus, OutDir, Out, Counter).

take(_Op, 0, _, _, _, _, _, _) -> ok;
take(_Op, _, [], _, _, _, _, _) -> ok;
take(Op, Left, [{Mod, N} | Rest], Specs, Corpus, OutDir, Out, Counter) ->
    case mutate(Op, Mod, N, Specs, Corpus) of
        {ok, Forms, Info} ->
            case emit(Op, Mod, Forms, Info, OutDir, Out, Counter) of
                true -> take(Op, Left - 1, Rest, Specs, Corpus, OutDir, Out, Counter);
                false -> take(Op, Left, Rest, Specs, Corpus, OutDir, Out, Counter)
            end;
        error ->
            take(Op, Left, Rest, Specs, Corpus, OutDir, Out, Counter)
    end.

emit(Op, #{module := M, forms := Orig, ebin := Ebin}, Forms, #{function := {F, A}} = Info, OutDir, Out, Counter) ->
    case {compile_warnings(Orig), compile(Forms)} of
        {{ok, OrigWarns}, {ok, Bin, Warns}} ->
            counters:add(Counter, 1, 1),
            Id = counters:get(Counter, 1),
            {First, Last} = function_range(Forms, F, A),
            New = [#{line => L, text => iolist_to_binary(io_lib:format("~p", [D]))}
                   || {L, D} <- Warns -- OrigWarns, L >= First, L =< Last],
            Dir = filename:join(OutDir, integer_to_list(Id)),
            ok = filelib:ensure_dir(filename:join(Dir, "x")),
            ok = file:write_file(filename:join(Dir, atom_to_list(M) ++ ".beam"), Bin),
            Line = json:encode(#{id => Id, operator => Op, ebin => unicode:characters_to_binary(Ebin),
                                 module => M, function => F, arity => A, first_line => First, last_line => Last,
                                 line => maps:get(line, Info), context => lists:usort(maps:get(ctx, Info, [])), description => unicode:characters_to_binary(maps:get(desc, Info)),
                                 compiler_warnings => New}),
            ok = file:write(Out, [Line, $\n]),
            true;
        _ ->
            false
    end.

compile(Forms) ->
    case compile:forms(Forms, [debug_info, binary, return_warnings, return_errors]) of
        {ok, _M, Bin, Ws} -> {ok, Bin, flat_warnings(Ws)};
        _ -> error
    end.

compile_warnings(Forms) ->
    case compile(Forms) of
        {ok, _, Ws} -> {ok, Ws};
        error -> error
    end.

flat_warnings(Ws) -> lists:append([[{line_num(L), D} || {L, _Mod, D} <- Items] || {_File, Items} <- Ws]).

line_num(L) -> case catch erl_anno:line(L) of N when is_integer(N) -> N; _ -> 0 end.

%% The range includes the -spec of the function: Dialyzer reports a spec that the code contradicts on the spec's line.
function_range(Forms, F, A) ->
    [Fun] = [Fn || {function, _, F1, A1, _} = Fn <- Forms, F1 =:= F, A1 =:= A],
    SpecLines = [line_of(Spec) || {attribute, _, spec, {{F1, A1}, _}} = Spec <- Forms, F1 =:= F, A1 =:= A],
    Lines = lines(Fun) ++ SpecLines,
    {lists:min(Lines), lists:max(Lines)}.

lines(Term) when is_tuple(Term), tuple_size(Term) >= 2, is_atom(element(1, Term)) ->
    Here = case catch erl_anno:line(element(2, Term)) of L when is_integer(L), L > 0 -> [L]; _ -> [] end,
    Here ++ lists:append([lines(E) || E <- tl(tuple_to_list(Term))]);
lines(Term) when is_tuple(Term) -> lists:append([lines(E) || E <- tuple_to_list(Term)]);
lines([H | T]) -> lines(H) ++ lines(T);
lines(_) -> [].

%% ------------------------------------------------------------------ the operators

count(Op, Mod, Specs, Corpus) ->
    case walk_forms(Op, Mod, Specs, Corpus, -1) of {_, #{count := C}} -> C end.

mutate(Op, Mod, Target, Specs, Corpus) ->
    case walk_forms(Op, Mod, Specs, Corpus, Target) of
        {Forms, #{info := Info}} -> {ok, Forms, Info};
        _ -> error
    end.

walk_forms(Op, #{module := M, forms := Forms}, Specs, Corpus, Target) ->
    St0 = #{op => Op, count => 0, target => Target, specs => Specs, corpus => Corpus, mod => M, ctx => []},
    {Forms1, St} = lists:mapfoldl(
        fun({function, _, F, A, _} = Fun, S) ->
                case Op of
                    r1 -> function_site(Fun, S#{func => {F, A}});
                    _ -> walk(Fun, S#{func => {F, A}})
                end;
           (Other, S) -> {Other, S}
        end, St0, Forms),
    {Forms1, St}.

%% r1: the whole function is the site
function_site({function, Anno, F, A, Clauses} = Fun, #{mod := M, specs := Specs} = St) ->
    case maps:find({M, F, A}, Specs) of
        {ok, [_ | _] = Parts} ->
            case lists:all(fun({_, Ret}) -> simple_value_type(Ret) end, Parts) of
                true -> site(Fun, St, fun() ->
                                              {Last, Line} = last_expr_line(hd(Clauses)),
                                              New = {function, Anno, F, A, [replace_last(C) || C <- Clauses]},
                                              {New, #{line => Line, function => {F, A},
                                                      desc => lists:flatten(io_lib:format("~p/~p returns an atom, its -spec says otherwise", [F, A])),
                                                      last => Last}}
                                      end);
                false -> {Fun, St}
            end;
        _ ->
            {Fun, St}
    end.

last_expr_line({clause, _, _, _, Body}) ->
    Last = lists:last(Body),
    {Last, line_of(Last)}.

replace_last({clause, A, Pats, Guards, Body}) ->
    Last = lists:last(Body),
    {clause, A, Pats, Guards, lists:droplast(Body) ++ [{atom, element(2, Last), ?ATOM}]}.

line_of(Node) -> case catch erl_anno:line(element(2, Node)) of L when is_integer(L) -> L; _ -> 0 end.

site(Node, #{count := C, target := T} = St, Make) ->
    St1 = St#{count := C + 1},
    case C =:= T of
        true -> {New, Info} = Make(), {New, St1#{info => Info#{ctx => maps:get(ctx, St)}}};
        false -> {Node, St1}
    end.

%% generic walk: every call and match is a candidate site, nested ones included
walk(Node, St) when is_tuple(Node) ->
    case node_site(Node, St) of
        {yes, Make} ->
            {Node1, St1} = site(Node, St, Make),
            case maps:is_key(info, St1) andalso maps:get(count, St1) - 1 =:= maps:get(target, St1) of
                true -> {Node1, St1};
                false -> descend(Node1, St1)
            end;
        no ->
            descend(Node, St)
    end;
walk(L, St) when is_list(L) ->
    lists:mapfoldl(fun walk/2, St, L);
walk(Other, St) ->
    {Other, St}.

descend({clause, A, Pats, Guards, Body}, St) ->
    {Pats1, S1} = walk(Pats, St),
    {Guards1, S2} = in_ctx(guard, fun(S) -> walk(Guards, S) end, S1),
    {Body1, S3} = walk(Body, S2),
    {{clause, A, Pats1, Guards1, Body1}, S3};
descend({'fun', A, {clauses, Clauses}}, St) ->
    {Clauses1, S1} = in_ctx('fun', fun(S) -> walk(Clauses, S) end, St),
    {{'fun', A, {clauses, Clauses1}}, S1};
descend({'try', A, Body, Of, Catch, After}, St) ->
    {Body1, S1} = in_ctx('try', fun(S) -> walk(Body, S) end, St),
    {Of1, S2} = walk(Of, S1),
    {Catch1, S3} = walk(Catch, S2),
    {After1, S4} = walk(After, S3),
    {{'try', A, Body1, Of1, Catch1, After1}, S4};
descend({record, A, Name, Fields}, St) ->
    {Fields1, S1} = in_ctx(record, fun(S) -> walk(Fields, S) end, St),
    {{record, A, Name, Fields1}, S1};
descend({record, A, Expr, Name, Fields}, St) ->
    {Expr1, S1} = walk(Expr, St),
    {Fields1, S2} = in_ctx(record, fun(S) -> walk(Fields, S) end, S1),
    {{record, A, Expr1, Name, Fields1}, S2};
descend(Node, St) when is_tuple(Node), tuple_size(Node) >= 3, is_atom(element(1, Node)) ->
    [Tag, Anno | Rest] = tuple_to_list(Node),
    {Rest1, St1} = lists:mapfoldl(fun walk/2, St, Rest),
    {list_to_tuple([Tag, Anno | Rest1]), St1};
descend(Node, St) when is_tuple(Node) ->
    {L1, St1} = lists:mapfoldl(fun walk/2, St, tuple_to_list(Node)),
    {list_to_tuple(L1), St1};
descend(Node, St) -> {Node, St}.

in_ctx(Ctx, Walk, #{ctx := Old} = St) ->
    {Result, St1} = Walk(St#{ctx := [Ctx | Old]}),
    {Result, St1#{ctx := Old}}.

node_site({call, A, Callee, Args} = Call, #{op := r2, specs := Specs, mod := M} = St) ->
    case callee_key(M, Callee, length(Args)) of
        {ok, Key} ->
            case maps:find(Key, Specs) of
                {ok, [_ | _] = Parts} ->
                    Idxs = [I || I <- lists:seq(1, length(Args)),
                                 lists:all(fun({Ts, _}) -> length(Ts) =:= length(Args) andalso simple_value_type(lists:nth(I, Ts)) end, Parts)],
                    case Idxs of
                        [] -> no;
                        _ ->
                            I = lists:nth(rand:uniform(length(Idxs)), Idxs),
                            {yes, fun() ->
                                          Arg = lists:nth(I, Args),
                                          NewArgs = lists:sublist(Args, I - 1) ++ [{atom, element(2, Arg), ?ATOM}] ++ lists:nthtail(I, Args),
                                          Line = line_of(Call),
                                          {{call, A, Callee, NewArgs},
                                           #{line => Line, function => fun_of(St),
                                             desc => lists:flatten(io_lib:format("argument ~p of ~s is an atom, its -spec says otherwise", [I, fmt_key(Key)]))}}
                                  end}
                    end;
                _ -> no
            end;
        error -> no
    end;
node_site({call, A, {atom, _, F} = Callee, Args} = Call, #{op := r3} = St) ->
    case bif_fault(F, length(Args)) of
        {ok, I, Lit} ->
            {yes, fun() ->
                          Arg = lists:nth(I, Args),
                          NewArgs = lists:sublist(Args, I - 1) ++ [setelement(2, Lit, element(2, Arg))] ++ lists:nthtail(I, Args),
                          {{call, A, Callee, NewArgs},
                           #{line => line_of(Call), function => fun_of(St),
                             desc => lists:flatten(io_lib:format("~p/~p gets ~p as argument ~p", [F, length(Args), element(1, Lit), I]))}}
                  end};
        error -> no
    end;
node_site({call, A, {remote, RA, {atom, _, Mod} = ModNode, {atom, _, F}}, Args} = Call, #{op := r4, corpus := Corpus} = St) ->
    case maps:find(Mod, Corpus) of
        {ok, Exports} ->
            case lists:member({F, length(Args)}, Exports) of
                true ->
                    {yes, fun() ->
                                  {{call, A, {remote, RA, ModNode, {atom, element(2, ModNode), mutant_missing_fn}}, Args},
                                   #{line => line_of(Call), function => fun_of(St),
                                     desc => lists:flatten(io_lib:format("~p:~p/~p does not exist", [Mod, F, length(Args)]))}}
                          end};
                false -> no
            end;
        error -> no
    end;
node_site({match, A, {tuple, TA, [{atom, AA, Tag} | Rest]}, {call, _, Callee, Args} = CallNode} = Match,
          #{op := r6, specs := Specs, mod := M} = St) ->
    case callee_key(M, Callee, length(Args)) of
        {ok, Key} ->
            case maps:find(Key, Specs) of
                {ok, [_ | _] = Parts} ->
                    Tags = lists:map(fun({_, Ret}) -> return_tags(Ret) end, Parts),
                    case lists:all(fun(T) -> T =/= error andalso lists:member(Tag, T) end, Tags) of
                        true ->
                            {yes, fun() ->
                                          {{match, A, {tuple, TA, [{atom, AA, mutant_tag} | Rest]}, CallNode},
                                           #{line => line_of(Match), function => fun_of(St),
                                             desc => lists:flatten(io_lib:format("{~p, _} = ~s never matches its -spec", [Tag, fmt_key(Key)]))}}
                                  end};
                        false -> no
                    end;
                _ -> no
            end;
        error -> no
    end;
node_site(_, _) ->
    no.

fun_of(#{func := FA}) -> FA.

callee_key(_M, {remote, _, {atom, _, Mod}, {atom, _, F}}, Arity) -> {ok, {Mod, F, Arity}};
callee_key(M, {atom, _, F}, Arity) ->
    case erl_internal:bif(F, Arity) of
        true -> error;
        false -> {ok, {M, F, Arity}}
    end;
callee_key(_, _, _) -> error.

fmt_key({M, F, A}) -> io_lib:format("~p:~p/~p", [M, F, A]).

%% the first element of every tuple the type can be, or error when it is anything else
return_tags({type, _, union, Members}) ->
    Tags = [return_tags(Mb) || Mb <- Members],
    case lists:member(error, Tags) of true -> error; false -> lists:append(Tags) end;
return_tags({type, _, tuple, [{atom, _, Tag} | _]}) -> [Tag];
return_tags({atom, _, Tag}) -> [Tag];
return_tags({ann_type, _, [_, T]}) -> return_tags(T);
return_tags({paren_type, _, [T]}) -> return_tags(T);
return_tags(_) -> error.

simple_value_type({type, _, T, []}) when T =:= integer; T =:= pos_integer; T =:= non_neg_integer; T =:= neg_integer;
                                         T =:= float; T =:= number; T =:= binary; T =:= boolean -> true;
simple_value_type({type, _, range, _}) -> true;
simple_value_type({type, _, tuple, _}) -> true;
simple_value_type({type, _, list, _}) -> true;
simple_value_type({type, _, nonempty_list, _}) -> true;
simple_value_type({type, _, map, _}) -> true;
simple_value_type({ann_type, _, [_, T]}) -> simple_value_type(T);
simple_value_type({paren_type, _, [T]}) -> simple_value_type(T);
simple_value_type(_) -> false.

%% BIF, arity -> argument that gets a value of the wrong type
bif_fault(length, 1) -> {ok, 1, {atom, 0, ?ATOM}};
bif_fault(hd, 1) -> {ok, 1, {atom, 0, ?ATOM}};
bif_fault(tl, 1) -> {ok, 1, {atom, 0, ?ATOM}};
bif_fault(byte_size, 1) -> {ok, 1, {atom, 0, ?ATOM}};
bif_fault(tuple_size, 1) -> {ok, 1, {atom, 0, ?ATOM}};
bif_fault(map_size, 1) -> {ok, 1, {atom, 0, ?ATOM}};
bif_fault(atom_to_list, 1) -> {ok, 1, {integer, 0, 1}};
bif_fault(list_to_atom, 1) -> {ok, 1, {integer, 0, 1}};
bif_fault(integer_to_list, 1) -> {ok, 1, {atom, 0, ?ATOM}};
bif_fault(list_to_binary, 1) -> {ok, 1, {atom, 0, ?ATOM}};
bif_fault(binary_to_list, 1) -> {ok, 1, {atom, 0, ?ATOM}};
bif_fault(_, _) -> error.
