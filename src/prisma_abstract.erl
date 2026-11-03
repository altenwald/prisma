%% @doc Extracts portable type and contract summaries from Erlang and Elixir BEAM files.
%%
%% Uses BEAM debug_info chunks and normalizes types via `prisma_type` without
%% storing absolute filesystem paths.
-module(prisma_abstract).

-include("prisma.hrl").

-export([
    extract_beam/1,
    extract_beam/2,
    specs_of_beam/1,
    detect_language/2,
    parse_abstract_forms/3,
    parse_abstract_forms/4
]).

%% @doc Extracts a `#module_summary{}` from a BEAM file path or binary.
-spec extract_beam(file:filename_all() | binary()) ->
    {ok, #module_summary{}} | {error, term()}.
extract_beam(BeamInput) ->
    extract_beam(BeamInput, #{}).

%% @doc Like `extract_beam/1`. `Opts` may carry `external_specs`, the `-spec`s of the other modules (`#{MFA => [stype()]}`),
%% so that the return type of a call to another module is known while this one is inferred.
-spec extract_beam(file:filename_all() | binary(), map()) -> {ok, #module_summary{}} | {error, term()}.
extract_beam(BeamInput, Opts) ->
    BeamPathOrBin = normalize_input(BeamInput),
    case beam_lib:md5(BeamPathOrBin) of
        {ok, {Module, Md5}} ->
            extract_chunks(BeamPathOrBin, Module, Md5, Opts);
        {error, beam_lib, Reason} ->
            {error, Reason}
    end.

normalize_input(Bin) when is_binary(Bin) ->
    case Bin of
        <<"FOR1", _/binary>> -> Bin;
        _ -> unicode:characters_to_list(Bin)
    end;
normalize_input(Path) when is_list(Path) ->
    Path.

extract_chunks(Beam, Module, Md5, Opts) ->
    ChunkNames = [exports, attributes, compile_info, debug_info],
    case beam_lib:chunks(Beam, ChunkNames, [allow_missing_chunks]) of
        {ok, {Module, Chunks}} ->
            Exports = proplists:get_value(exports, Chunks, []),
            Attrs = normalize_chunks_val(proplists:get_value(attributes, Chunks, [])),
            CompileInfo = normalize_chunks_val(proplists:get_value(compile_info, Chunks, [])),
            Dbgi = proplists:get_value(debug_info, Chunks, missing_chunk),
            Lang = detect_language(Module, Dbgi),
            Vsn = proplists:get_value(vsn, Attrs, []),
            ExportTypes = lists:append(proplists:get_all_values(export_type, Attrs)),
            SourceFile = extract_source_file(CompileInfo, Dbgi),
            BaseSummary = #module_summary{
                module = Module,
                language = Lang,
                vsn = Vsn,
                beam_md5 = Md5,
                exports = Exports,
                export_types = ExportTypes,
                file = SourceFile
            },
            enrich_from_debug_info(Beam, Module, Dbgi, Exports, BaseSummary, Opts);
        {error, beam_lib, Reason} ->
            {error, Reason}
    end.

extract_source_file(CompileInfo, Dbgi) ->
    case proplists:get_value(source, CompileInfo) of
        Src when is_list(Src), Src =/= "" ->
            filename:absname(Src);
        SrcBin when is_binary(SrcBin), SrcBin =/= <<>> ->
            filename:absname(unicode:characters_to_list(SrcBin));
        _ ->
            case Dbgi of
                {debug_info_v1, elixir_erl, {elixir_v1, #{file := FileBin}, _}}
                  when is_binary(FileBin), FileBin =/= <<>> ->
                    filename:absname(unicode:characters_to_list(FileBin));
                _ ->
                    undefined
            end
    end.

normalize_chunks_val(missing_chunk) -> [];
normalize_chunks_val(Val) when is_list(Val) -> Val;
normalize_chunks_val(_) -> [].

%% @doc Detects whether a BEAM module originated from Erlang or Elixir.
-spec detect_language(module(), term()) -> source_lang().
detect_language(_Module, {debug_info_v1, elixir_erl, _}) ->
    elixir;
detect_language(Module, Dbgi) ->
    case atom_to_binary(Module, utf8) of
        <<"Elixir.", _/binary>> -> elixir;
        _ ->
            case Dbgi of
                {debug_info_v1, erl_abstract_code, _} -> erlang;
                _ -> erlang
            end
    end.

enrich_from_debug_info(Beam, Module, Dbgi, Exports, Summary, Opts) ->
    case abstract_forms(Beam, Dbgi) of
        {ok, Forms} ->
            {ok, parse_abstract_forms(Forms, Exports, Summary, Opts)};
        error ->
            {ok, prisma_elixir:from_elixir_dbgi(Module, Dbgi, Exports, Summary)}
    end.

%% The abstract forms of a module. The debug_info chunk of an Erlang module already holds them, in the same form that
%% `beam_lib:chunks(Beam, [abstract_code])` returns; asking for `abstract_code` decodes the chunk again and rebuilds every
%% annotation (`erl_parse:anno_from_term` was a fifth of the time of building a PLT).
abstract_forms(_Beam, {debug_info_v1, erl_abstract_code, {Forms, _Opts}}) when is_list(Forms) ->
    {ok, Forms};
abstract_forms(Beam, _Dbgi) ->
    case beam_lib:chunks(Beam, [abstract_code]) of
        {ok, {_Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} -> {ok, Forms};
        _ -> error
    end.

%% @doc The `-spec`s of a BEAM file, `#{{M, F, A} => [stype()]}` (nothing if it has no abstract code).
-spec specs_of_beam(file:filename_all() | binary()) -> #{mfa_key() => [prisma_type:stype()]}.
specs_of_beam(BeamInput) ->
    Beam = normalize_input(BeamInput),
    case beam_lib:chunks(Beam, [debug_info], [allow_missing_chunks]) of
        {ok, {Mod, [{debug_info, Dbgi}]}} ->
            case abstract_forms(Beam, Dbgi) of
                {ok, Forms} -> specs_in(Mod, Forms);
                error -> #{}
            end;
        _ ->
            #{}
    end.

specs_in(Mod, Forms) ->
    lists:foldl(
        fun({attribute, _, spec, {{F, A}, Clauses}}, Acc) ->
                Acc#{{Mod, F, A} => [prisma_type:from_abstract(C) || C <- Clauses]};
           ({attribute, _, spec, {{M, F, A}, Clauses}}, Acc) ->
                Acc#{{M, F, A} => [prisma_type:from_abstract(C) || C <- Clauses]};
           (_, Acc) ->
                Acc
        end, #{}, Forms).

%% What the inference of a module may assume about the functions of the others: the return type their `-spec` declares
%% (the contract is the interface, not whatever their body happens to give). The arguments are left alone: they are checked
%% against the spec by the checker. A function without a spec, or whose spec returns anything, adds nothing.
external_contracts(Mod, ExternalSpecs) ->
    maps:fold(
        fun({M, _F, A} = Key, Specs, Acc) when M =/= Mod ->
                case prisma_infer:declared_return(Specs, A) of
                    any -> Acc;
                    Ret -> Acc#{Key => #func_contract{mfa = Key, declared_specs = Specs,
                                                      inferred_type = {fun_type, lists:duplicate(A, any), Ret}}}
                end;
           (_, _, Acc) ->
                Acc
        end, #{}, ExternalSpecs).

%% @doc Populates a `#module_summary{}` from Erlang Abstract Format forms.
-spec parse_abstract_forms([term()], [{atom(), arity()}], #module_summary{}) ->
    #module_summary{}.
parse_abstract_forms(Forms, Exports, Summary) ->
    parse_abstract_forms(Forms, Exports, Summary, #{}).

%% @doc Like `parse_abstract_forms/3`, with the options of `extract_beam/2`.
-spec parse_abstract_forms([term()], [{atom(), arity()}], #module_summary{}, map()) ->
    #module_summary{}.
parse_abstract_forms(Forms, Exports, #module_summary{module = Mod, export_types = AttrExpTypes} = Summary, Opts) ->
    ExportSet = maps:from_list([{FA, true} || FA <- Exports]),
    {RawTypes, FormExpTypes, Specs, InitialFuncs, ClausesByMFA, _GenSet} = lists:foldl(
        fun(Form, {TAcc, ETAcc, SAcc, FAcc, CAcc, GAcc}) ->
            case Form of
                {attribute, _Anno, compiler_generated, {F, A}} ->
                    {TAcc, ETAcc, SAcc, FAcc, CAcc, GAcc#{{Mod, F, A} => true}};
                {attribute, _Anno, export_type, ExpList} when is_list(ExpList) ->
                    {TAcc, ExpList ++ ETAcc, SAcc, FAcc, CAcc, GAcc};
                {attribute, _Anno, Kind, {_TypeName, _TypeDef, _TypeArgs} = TypeAttr}
                  when Kind =:= type; Kind =:= opaque; Kind =:= nominal ->
                    Decl = prisma_type:from_type_attr(Mod, Kind, TypeAttr),
                    Key = Decl#type_decl.key,
                    {TAcc#{Key => Decl}, ETAcc, SAcc, FAcc, CAcc, GAcc};
                {attribute, _Anno, spec, {{F, A}, SpecClauses}} ->
                    Key = {Mod, F, A},
                    NormSpecs = [prisma_type:from_abstract(S) || S <- SpecClauses],
                    {TAcc, ETAcc, SAcc#{Key => NormSpecs}, FAcc, CAcc, GAcc};
                {attribute, _Anno, spec, {{M, F, A}, SpecClauses}} ->
                    Key = {M, F, A},
                    NormSpecs = [prisma_type:from_abstract(S) || S <- SpecClauses],
                    {TAcc, ETAcc, SAcc#{Key => NormSpecs}, FAcc, CAcc, GAcc};
                {function, Anno, F, A, Clauses} ->
                    Key = {Mod, F, A},
                    Line = erl_anno:line(Anno),
                    Calls = extract_calls_from_clauses(Mod, Clauses),
                    InitType = {fun_type, lists:duplicate(A, any), any},
                    IsGen = maps:is_key(Key, GAcc) orelse F =:= module_info orelse F =:= behaviour_info,
                    Contract = #func_contract{
                        mfa = Key,
                        exported = maps:is_key({F, A}, ExportSet),
                        inferred_type = InitType,
                        calls = Calls,
                        clauses = Clauses,
                        compiler_generated = IsGen,
                        line = Line
                    },
                    {TAcc, ETAcc, SAcc, FAcc#{Key => Contract}, CAcc#{Key => {Line, Clauses}}, GAcc};
                _ ->
                    {TAcc, ETAcc, SAcc, FAcc, CAcc, GAcc}
            end
        end,
        {#{}, AttrExpTypes, #{}, #{}, #{}, #{}},
        Forms
    ),
    AllExpTypes = lists:usort(FormExpTypes),
    ExpTypeSet = maps:from_list([{TA, true} || TA <- AllExpTypes]),
    MarkedTypes = maps:map(
        fun({_M, TName, TArity}, Decl) ->
            Decl#type_decl{exported = maps:is_key({TName, TArity}, ExpTypeSet)}
        end,
        RawTypes
    ),
    WithSpecs = merge_specs_into_funcs(Mod, ExportSet, Specs, InitialFuncs),
    External = external_contracts(Mod, maps:get(external_specs, Opts, #{})),
    Inferred = prisma_infer:infer_module_functions(Mod, ClausesByMFA, maps:merge(External, WithSpecs)),
    InferredFuncs = maps:filter(fun({M, _, _}, _) -> M =:= Mod end, Inferred),
    ResolvedFile = case Summary#module_summary.file of
        undefined ->
            case [FPath || {attribute, _Anno, file, {FPath, _Line}} <- Forms, is_list(FPath), FPath =/= ""] of
                [FoundPath | _] -> filename:absname(FoundPath);
                [] -> undefined
            end;
        Existing ->
            Existing
    end,
    Summary#module_summary{
        export_types = AllExpTypes,
        types = MarkedTypes,
        functions = InferredFuncs,
        file = ResolvedFile
    }.

merge_specs_into_funcs(Mod, ExportSet, Specs, Funcs) ->
    maps:fold(
        fun({M, F, A} = Key, SpecClauses, Acc) when M =:= Mod ->
            case maps:find(Key, Acc) of
                {ok, Existing} ->
                    Acc#{Key => Existing#func_contract{declared_specs = SpecClauses}};
                error ->
                    Acc#{Key => #func_contract{
                        mfa = Key,
                        exported = maps:is_key({F, A}, ExportSet),
                        declared_specs = SpecClauses
                    }}
            end;
           (_OtherKey, _SpecClauses, Acc) ->
            Acc
        end,
        Funcs,
        Specs
    ).

extract_calls_from_clauses(CurrentMod, Clauses) ->
    Calls = lists:foldl(fun(C, Acc) -> collect_calls(CurrentMod, C, Acc) end, #{}, Clauses),
    lists:sort(maps:keys(Calls)).

collect_calls(Mod, {call, _Anno, {remote, _A2, {atom, _A3, M}, {atom, _A4, F}}, Args}, Acc) ->
    Acc1 = Acc#{{M, F, length(Args)} => true},
    collect_calls_list(Mod, Args, Acc1);
collect_calls(Mod, {call, _Anno, {atom, _A2, F}, Args}, Acc) ->
    Acc1 = Acc#{{Mod, F, length(Args)} => true},
    collect_calls_list(Mod, Args, Acc1);
collect_calls(Mod, {'fun', _Anno, {function, F, A}}, Acc) when is_atom(F), is_integer(A) ->
    Acc#{{Mod, F, A} => true};
collect_calls(_Mod, {'fun', _Anno, {function, {atom, _, M}, {atom, _, F}, {integer, _, A}}}, Acc) ->
    Acc#{{M, F, A} => true};
collect_calls(_Mod, {'fun', _Anno, {function, M, F, A}}, Acc) when is_atom(M), is_atom(F), is_integer(A) ->
    Acc#{{M, F, A} => true};
collect_calls(Mod, Tuple, Acc) when is_tuple(Tuple) ->
    collect_calls_list(Mod, tuple_to_list(Tuple), Acc);
collect_calls(Mod, List, Acc) when is_list(List) ->
    collect_calls_list(Mod, List, Acc);
collect_calls(_Mod, _Other, Acc) ->
    Acc.

collect_calls_list(Mod, Items, Acc) ->
    lists:foldl(fun(Item, A) -> collect_calls(Mod, Item, A) end, Acc, Items).
