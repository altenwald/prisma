%% @doc Static analysis diagnostics for Erlang and Elixir files in the Language Server.
%%
%% Analyzes documents statically without loading bytecode into memory or executing
%% module code, preventing `-on_load` or other side-effects from firing.
-module(prisma_lsp_diagnostics).

-include("prisma.hrl").

-export([
    analyze/4,
    uri_to_path/1,
    ensure_elixir/0
]).

%% @doc Analyzes a document identified by `Uri` with optional `Text` content and language id.
-spec analyze(binary(), binary(), binary() | undefined, #prisma_pplt{}) -> [map()].
analyze(Uri, LangId, TextOpt, Pplt) ->
    Path = uri_to_path(Uri),
    case detect_language(Path, LangId) of
        erlang ->
            analyze_erlang(Path, TextOpt, Pplt);
        elixir ->
            analyze_elixir(Path, TextOpt, Pplt);
        unknown ->
            []
    end.

%% @doc Converts an LSP file URI to a filesystem path.
-spec uri_to_path(binary()) -> string().
uri_to_path(<<"file://localhost", Rest/binary>>) ->
    unicode:characters_to_list(Rest);
uri_to_path(<<"file://", Rest/binary>>) ->
    unicode:characters_to_list(Rest);
uri_to_path(Other) ->
    unicode:characters_to_list(Other).

detect_language(Path, LangId) ->
    Ext = filename:extension(Path),
    case {Ext, LangId} of
        {".erl", _} -> erlang;
        {".hrl", _} -> erlang;
        {_, <<"erlang">>} -> erlang;
        {".ex", _} -> elixir;
        {".exs", _} -> elixir;
        {_, <<"elixir">>} -> elixir;
        _ -> unknown
    end.

%%% ============================================================================
%%% Erlang Static Analysis (100% in-memory AST, no code loading)
%%% ============================================================================

analyze_erlang(Path, TextOpt, Pplt) ->
    Includes = resolve_erlang_includes(Path),
    case read_source(Path, TextOpt) of
        {ok, SourceBin} ->
            TmpFile = scratch_file_path(Path),
            try
                ok = file:write_file(TmpFile, SourceBin),
                case epp:parse_file(TmpFile, Includes, []) of
                    {ok, Forms} ->
                        CompileErrs = validate_compile_forms(Forms),
                        PrismaWarns = analyze_erlang_prisma(Forms, Path, Pplt),
                        CompileErrs ++ PrismaWarns;
                    {error, Reason} ->
                        [format_diag(1, 1, 1, 80, 1, <<"Compiler">>, list_to_binary(io_lib:format("Parse error: ~p", [Reason])))]
                end
            catch
                _:Err ->
                    [format_diag(1, 1, 1, 80, 1, <<"Prisma">>, list_to_binary(io_lib:format("Analysis error: ~p", [Err])))]
            after
                _ = file:delete(TmpFile)
            end;
        {error, Reason} ->
            [format_diag(1, 1, 1, 80, 1, <<"Prisma">>, list_to_binary(io_lib:format("Cannot read file ~s: ~p", [Path, Reason])))]
    end.

validate_compile_forms(Forms) ->
    case compile:forms(Forms, [return_errors, return_warnings, basic_validation]) of
        {ok, _Mod, Warnings} ->
            format_compile_messages(2, Warnings);
        {error, Errors, Warnings} ->
            format_compile_messages(1, Errors) ++ format_compile_messages(2, Warnings)
    end.

format_compile_messages(Severity, FileMsgs) ->
    lists:flatmap(
        fun({_File, List}) ->
            lists:map(
                fun({Pos, Mod, Desc}) ->
                    {Line, Col} = anno_to_pos(Pos),
                    Msg = list_to_binary(Mod:format_error(Desc)),
                    format_diag(Line, Col, Line, Col + 10, Severity, <<"Compiler">>, Msg)
                end,
                List
            )
        end,
        FileMsgs
    ).

analyze_erlang_prisma(Forms, Path, Pplt) ->
    Mod = extract_module_name(Forms, Path),
    Exports = extract_exports(Forms),
    Summary0 = #module_summary{
        module = Mod,
        language = erlang,
        exports = Exports,
        file = Path
    },
    try
        Summary = prisma_abstract:parse_abstract_forms(Forms, Exports, Summary0),
        Warnings = prisma_checker:check_module(Summary, Pplt, #{mode => hybrid}),
        lists:map(fun warning_to_diagnostic/1, Warnings)
    catch
        Class:Err:Stack ->
            prisma_lsp_io:log("Elixir analysis exception: ~p:~p~n~p", [Class, Err, Stack]),
            []
    end.

extract_module_name(Forms, Path) ->
    case [M || {attribute, _, module, M} <- Forms] of
        [Mod | _] -> Mod;
        [] -> list_to_atom(filename:rootname(filename:basename(Path)))
    end.

extract_exports(Forms) ->
    lists:append([L || {attribute, _, export, L} <- Forms]).

resolve_erlang_includes(Path) ->
    Dir = filename:dirname(Path),
    AppDir = filename:join(Dir, ".."),
    [
        Dir,
        filename:join(Dir, "include"),
        filename:join(AppDir, "include"),
        AppDir
    ] ++ filelib:wildcard(filename:join([AppDir, "_build", "*", "lib", "*", "include"])).

scratch_file_path(Path) ->
    Dir = filename:dirname(Path),
    Base = filename:basename(Path),
    Rand = integer_to_list(erlang:unique_integer([positive])),
    filename:join(Dir, ".prisma_lsp_tmp_" ++ Rand ++ "_" ++ Base).

%%% ============================================================================
%%% Elixir Static Analysis (Pure AST, no bytecode loading or -on_load execution)
%%% ============================================================================

analyze_elixir(Path, TextOpt, Pplt) ->
    case ensure_elixir() of
        ok ->
            case read_source(Path, TextOpt) of
                {ok, SourceBin} ->
                    analyze_elixir_source(SourceBin, Path, Pplt);
                {error, Reason} ->
                    [format_diag(1, 1, 1, 80, 1, <<"Prisma">>, list_to_binary(io_lib:format("Cannot read file: ~p", [Reason])))]
            end;
        {error, not_found} ->
            [format_diag(
                1, 1, 1, 80, 3, <<"Prisma">>,
                <<"Elixir runtime not found. To analyze Elixir files, install Elixir or start with 'mix prisma.lsp'.">>
            )]
    end.

analyze_elixir_source(SourceBin, Path, Pplt) ->
    Opts = [{columns, true}, {token_metadata, true}],
    case 'Elixir.Code':string_to_quoted(SourceBin, Opts) of
        {error, {Meta, Prefix, Token}} ->
            Line = proplists:get_value(line, Meta, 1),
            Col = proplists:get_value(column, Meta, 1),
            EndLine = proplists:get_value(end_line, Meta, Line),
            EndCol = proplists:get_value(end_column, Meta, Col + 5),
            Msg = iolist_to_binary([Prefix, Token]),
            [format_diag(Line, Col, EndLine, EndCol, 1, <<"Compiler">>, Msg)];
        {ok, QuotedAst} ->
            analyze_elixir_ast(QuotedAst, Path, Pplt)
    end.

analyze_elixir_ast(QuotedAst, Path, Pplt) ->
    case extract_elixir_modules(QuotedAst) of
        [] ->
            [];
        Modules ->
            lists:flatmap(
                fun({ModName, AstExprs}) ->
                    analyze_elixir_module_ast(ModName, AstExprs, Path, Pplt)
                end,
                Modules
            )
    end.

analyze_elixir_module_ast(ModName, Exprs, Path, Pplt) ->
    {Defs, Specs, Exports} = extract_elixir_defs_and_specs(Exprs),
    SpecForms = [translate_elixir_spec(S) || S <- Specs],
    try
        Forms = prisma_elixir:to_abstract_forms(ModName, #{definitions => Defs}, SpecForms),
        Summary0 = #module_summary{
            module = ModName,
            language = elixir,
            exports = Exports,
            file = Path
        },
        Summary = prisma_abstract:parse_abstract_forms(Forms, Exports, Summary0),
        Warnings = prisma_checker:check_module(Summary, Pplt, #{mode => hybrid}),
        lists:map(fun warning_to_diagnostic/1, Warnings)
    catch
        _:_ ->
            []
    end.

extract_elixir_modules(QuotedAst) ->
    find_defmodules(QuotedAst, []).

find_defmodules({defmodule, _Meta, [{Kind, _, Parts}, [{do, Block}]]}, Acc) when Kind =:= '__aliases__' ->
    ModName = 'Elixir.Module':concat(Parts),
    Exprs = unwrap_block(Block),
    [{ModName, Exprs} | Acc];
find_defmodules({defmodule, _Meta, [ModAtom, [{do, Block}]]}, Acc) when is_atom(ModAtom) ->
    Exprs = unwrap_block(Block),
    [{ModAtom, Exprs} | Acc];
find_defmodules(List, Acc) when is_list(List) ->
    lists:foldl(fun(Elem, InAcc) -> find_defmodules(Elem, InAcc) end, Acc, List);
find_defmodules(Tuple, Acc) when is_tuple(Tuple) ->
    find_defmodules(tuple_to_list(Tuple), Acc);
find_defmodules(_Other, Acc) ->
    Acc.

unwrap_block({'__block__', _Meta, Exprs}) when is_list(Exprs) ->
    Exprs;
unwrap_block(Single) ->
    [Single].

extract_elixir_defs_and_specs(Exprs) ->
    lists:foldr(
        fun(Expr, {DefsAcc, SpecsAcc, ExpAcc}) ->
            case Expr of
                {'@', _Meta, [{spec, _SpecMeta, [SpecAst]}]} ->
                    {DefsAcc, [SpecAst | SpecsAcc], ExpAcc};
                {Kind, Meta, [{'when', _WhenMeta, [{Name, _NameMeta, Args}, Guards]}, [{do, Body}]]}
                  when Kind =:= def; Kind =:= defp ->
                    Arity = safe_args_len(Args),
                    Clause = {Meta, safe_args_list(Args), [Guards], Body},
                    Def = {{Name, Arity}, Kind, Meta, [Clause]},
                    NewExp = case Kind of def -> [{Name, Arity} | ExpAcc]; _ -> ExpAcc end,
                    {[Def | DefsAcc], SpecsAcc, NewExp};
                {Kind, Meta, [{Name, _NameMeta, Args}, [{do, Body}]]}
                  when Kind =:= def; Kind =:= defp ->
                    Arity = safe_args_len(Args),
                    Clause = {Meta, safe_args_list(Args), [], Body},
                    Def = {{Name, Arity}, Kind, Meta, [Clause]},
                    NewExp = case Kind of def -> [{Name, Arity} | ExpAcc]; _ -> ExpAcc end,
                    {[Def | DefsAcc], SpecsAcc, NewExp};
                _ ->
                    {DefsAcc, SpecsAcc, ExpAcc}
            end
        end,
        {[], [], []},
        Exprs
    ).

safe_args_len(nil) -> 0;
safe_args_len(L) when is_list(L) -> length(L);
safe_args_len(_) -> 0.

safe_args_list(nil) -> [];
safe_args_list(L) when is_list(L) -> L;
safe_args_list(_) -> [].

translate_elixir_spec({'::', Meta, [{Fun, _FunMeta, Args}, RetType]}) when is_atom(Fun) ->
    Line = proplists:get_value(line, Meta, 1),
    Anno = erl_anno:new(Line),
    ArgTypes = [translate_spec_type(A, Line) || A <- safe_args_list(Args)],
    RetForm = translate_spec_type(RetType, Line),
    FunType = {type, Anno, 'fun', [{type, Anno, product, ArgTypes}, RetForm]},
    {attribute, Anno, spec, {{Fun, length(ArgTypes)}, [FunType]}};
translate_elixir_spec(_) ->
    Anno = erl_anno:new(1),
    {attribute, Anno, spec, {{unknown, 0}, [{type, Anno, 'fun', [{type, Anno, product, []}, {type, Anno, any, []}]}]}}.

translate_spec_type({TypeAtom, Meta, []}, _FallbackLine) when is_atom(TypeAtom) ->
    Line = proplists:get_value(line, Meta, 1),
    Anno = erl_anno:new(Line),
    {type, Anno, normalize_elixir_type(TypeAtom), []};
translate_spec_type({TypeAtom, Meta, Args}, _FallbackLine) when is_atom(TypeAtom), is_list(Args) ->
    Line = proplists:get_value(line, Meta, 1),
    Anno = erl_anno:new(Line),
    SubTypes = [translate_spec_type(A, Line) || A <- Args],
    {type, Anno, normalize_elixir_type(TypeAtom), SubTypes};
translate_spec_type({{{'.', _, [ModAst, TypeAtom]}, Meta, Args}}, Line) when is_atom(TypeAtom) ->
    Anno = erl_anno:new(proplists:get_value(line, Meta, Line)),
    Mod = case ModAst of
        {'__aliases__', _, Parts} -> 'Elixir.Module':concat(Parts);
        Atom when is_atom(Atom) -> Atom;
        _ -> erlang
    end,
    SubTypes = [translate_spec_type(A, Line) || A <- safe_args_list(Args)],
    {remote_type, Anno, [{atom, Anno, Mod}, {atom, Anno, TypeAtom}, SubTypes]};
translate_spec_type({{'.', _, [ModAst, TypeAtom]}, Meta, Args}, Line) when is_atom(TypeAtom) ->
    Anno = erl_anno:new(proplists:get_value(line, Meta, Line)),
    Mod = case ModAst of
        {'__aliases__', _, Parts} -> 'Elixir.Module':concat(Parts);
        Atom when is_atom(Atom) -> Atom;
        _ -> erlang
    end,
    SubTypes = [translate_spec_type(A, Line) || A <- safe_args_list(Args)],
    {remote_type, Anno, [{atom, Anno, Mod}, {atom, Anno, TypeAtom}, SubTypes]};
translate_spec_type(Atom, Line) when is_atom(Atom) ->
    Anno = erl_anno:new(Line),
    {atom, Anno, Atom};
translate_spec_type(Int, Line) when is_integer(Int) ->
    Anno = erl_anno:new(Line),
    {integer, Anno, Int};
translate_spec_type(_Other, Line) ->
    Anno = erl_anno:new(Line),
    {type, Anno, any, []}.

normalize_elixir_type(boolean) -> boolean;
normalize_elixir_type(integer) -> integer;
normalize_elixir_type(float) -> float;
normalize_elixir_type(number) -> number;
normalize_elixir_type(atom) -> atom;
normalize_elixir_type(binary) -> binary;
normalize_elixir_type(string) -> string;
normalize_elixir_type(list) -> list;
normalize_elixir_type(map) -> map;
normalize_elixir_type(term) -> any;
normalize_elixir_type(any) -> any;
normalize_elixir_type(none) -> none;
normalize_elixir_type(Other) -> Other.

%%% ============================================================================
%%% Elixir Runtime Auto-Discovery
%%% ============================================================================

%% @doc Ensures the Elixir application is available and started.
-spec ensure_elixir() -> ok | {error, not_found}.
ensure_elixir() ->
    case code:which('Elixir.Code') of
        non_existing ->
            try_load_elixir();
        _ ->
            _ = application:ensure_all_started(elixir),
            ok
    end.

try_load_elixir() ->
    case os:find_executable("elixir") of
        false ->
            {error, not_found};
        Exe ->
            Cmd = Exe ++ " -e \"IO.puts(:code.lib_dir(:elixir))\"",
            case os:cmd(Cmd) of
                [] ->
                    {error, not_found};
                Output ->
                    LibElixir = string:trim(Output),
                    BaseDir = filename:dirname(LibElixir),
                    Ebins = filelib:wildcard(filename:join([BaseDir, "*", "ebin"])),
                    code:add_pathsz(Ebins),
                    _ = application:ensure_all_started(elixir),
                    case code:which('Elixir.Code') of
                        non_existing -> {error, not_found};
                        _ -> ok
                    end
            end
    end.

%%% ============================================================================
%%% Diagnostics conversion helpers
%%% ============================================================================

warning_to_diagnostic(#prisma_warning{line = Line, kind = Kind, message = Msg}) ->
    Severity = case prisma_checker:severity(Kind) of
        error -> 1;
        warning -> 2;
        note -> 3
    end,
    EffectiveLine = case Line of
        0 -> 1;
        _ -> Line
    end,
    format_diag(EffectiveLine, 1, EffectiveLine, 80, Severity, <<"Prisma">>, Msg).

format_diag(StartLine, StartCol, EndLine, EndCol, Severity, Source, Message) ->
    #{
        <<"range">> => #{
            <<"start">> => #{
                <<"line">> => erlang:max(0, StartLine - 1),
                <<"character">> => erlang:max(0, StartCol - 1)
            },
            <<"end">> => #{
                <<"line">> => erlang:max(0, EndLine - 1),
                <<"character">> => erlang:max(0, EndCol - 1)
            }
        },
        <<"severity">> => Severity,
        <<"source">> => Source,
        <<"message">> => Message
    }.

read_source(_Path, Text) when is_binary(Text), byte_size(Text) > 0 ->
    {ok, Text};
read_source(Path, _) ->
    file:read_file(Path).

anno_to_pos(Anno) when is_integer(Anno) ->
    {Anno, 1};
anno_to_pos({Line, Col}) when is_integer(Line), is_integer(Col) ->
    {Line, Col};
anno_to_pos(Anno) ->
    case erl_anno:is_anno(Anno) of
        true ->
            Line = erl_anno:line(Anno),
            Col = erl_anno:column(Anno),
            {Line, case Col of undefined -> 1; _ -> Col end};
        false ->
            {1, 1}
    end.
