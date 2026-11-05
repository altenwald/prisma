%% @doc Manages portable, path-independent Prisma PPLT files (`.pplt`).
%%
%% Supports building a PPLT from BEAM files, encoding/decoding compressed
%% binaries, merging multiple PPLTs in memory, and resolving remote/opaque types.
-module(prisma_pplt).

-include("prisma.hrl").

-export([
    new/0,
    new/2,
    from_beams/1,
    from_beams/2,
    from_dir/1,
    merge/1,
    merge/2,
    save/2,
    load/1,
    encode/1,
    decode/1,
    lookup_mfa/2,
    lookup_module/2,
    declared_specs/1,
    lookup_type/2,
    resolve_type/3,
    resolve_type/4,
    modules/1
]).

%% @doc Creates an empty `#prisma_pplt{}` for the current OTP release.
-spec new() -> #prisma_pplt{}.
new() ->
    new(undefined, undefined).

%% @doc Creates an empty `#prisma_pplt{}` with package metadata.
-spec new(binary() | undefined, binary() | undefined) -> #prisma_pplt{}.
new(Pkg, PkgVsn) ->
    OtpRel = list_to_binary(erlang:system_info(otp_release)),
    #prisma_pplt{
        version = ?PRISMA_PPLT_VERSION,
        package = Pkg,
        package_vsn = PkgVsn,
        otp_release = OtpRel,
        source_hash = undefined,
        modules = #{}
    }.

%% @doc Builds a `#prisma_pplt{}` from all `.beam` files in `Dir`.
-spec from_dir(file:filename_all()) -> {ok, #prisma_pplt{}} | {error, term()}.
from_dir(Dir) ->
    Pattern = filename:join(unicode:characters_to_list(Dir), "*.beam"),
    Beams = filelib:wildcard(Pattern),
    from_beams(Beams).

%% @doc Builds a `#prisma_pplt{}` from a list of BEAM paths or binaries.
-spec from_beams([file:filename_all() | binary()]) -> {ok, #prisma_pplt{}} | {error, term()}.
from_beams(Beams) ->
    from_beams(Beams, #{}).

%% @doc Builds a `#prisma_pplt{}` from BEAM inputs and metadata options.
-spec from_beams([file:filename_all() | binary()], map()) ->
    {ok, #prisma_pplt{}} | {error, term()}.
from_beams(Beams, Opts0) ->
    Pkg = maps:get(package, Opts0, undefined),
    PkgVsn = maps:get(package_vsn, Opts0, undefined),
    BasePplt = (new(Pkg, PkgVsn))#prisma_pplt{source_hash = maps:get(source_hash, Opts0, undefined)},
    %% first the -specs of every module, so that each one is inferred knowing what the others declare
    Specs = lists:foldl(fun(Beam, Acc) -> maps:merge(Acc, prisma_abstract:specs_of_beam(Beam)) end,
                        maps:get(external_specs, Opts0, #{}), Beams),
    Opts = Opts0#{external_specs => Specs},
    {Result, _} = lists:foldl(
        fun
            (Beam, {{ok, #prisma_pplt{modules = Mods} = Pplt}, CurOpts}) ->
                case prisma_abstract:extract_beam(Beam, CurOpts) of
                    {ok, #module_summary{module = Mod, functions = Funcs} = Summary} ->
                        NewContracts = maps:from_list([{{Mod, F, A}, C} || {{_, F, A}, C} <- maps:to_list(Funcs)]),
                        CurExt = maps:get(external_specs, CurOpts, #{}),
                        UpdatedExt = maps:merge(CurExt, NewContracts),
                        {{ok, Pplt#prisma_pplt{modules = Mods#{Mod => Summary}}}, CurOpts#{external_specs => UpdatedExt}};
                    {error, Reason} ->
                        {{error, {beam_extract_failed, Beam, Reason}}, CurOpts}
                end;
            (_Beam, {{error, _} = Err, CurOpts}) ->
                {Err, CurOpts}
        end,
        {{ok, BasePplt}, Opts},
        Beams
    ),
    Result.

%% @doc Merges a list of `#prisma_pplt{}` records into one.
-spec merge([#prisma_pplt{}]) -> #prisma_pplt{}.
merge([]) ->
    new();
merge([First | Rest]) ->
    lists:foldl(fun(Pplt, Acc) -> merge(Acc, Pplt) end, First, Rest).

%% @doc Merges two `#prisma_pplt{}` records.
-spec merge(#prisma_pplt{}, #prisma_pplt{}) -> #prisma_pplt{}.
merge(#prisma_pplt{modules = M1} = Pplt1, #prisma_pplt{modules = M2}) ->
    Pplt1#prisma_pplt{modules = maps:merge(M1, M2)}.

%% @doc Serializes a `#prisma_pplt{}` into a compressed binary with header magic.
-spec encode(#prisma_pplt{}) -> binary().
encode(#prisma_pplt{modules = Modules} = Pplt) ->
    Lean = Pplt#prisma_pplt{modules = maps:map(fun(_Mod, Summary) -> without_code(Summary) end, Modules)},
    Payload = term_to_binary(Lean, [compressed, {minor_version, 2}]),
    <<?PRISMA_PPLT_MAGIC, Payload/binary>>.

%% What is saved are the contracts. The abstract code of every function (`clauses`) is only needed while the module itself is
%% inferred and by the oxbow detector, which runs on the modules being analyzed and never on a dependency loaded from a .pplt:
%% in the file it was most of the size and of the time spent writing and reading it.
without_code(#module_summary{functions = Funcs} = Summary) ->
    Summary#module_summary{functions = maps:map(fun(_MFA, #func_contract{} = FC) -> FC#func_contract{clauses = []};
                                                   (_MFA, Other) -> Other
                                                end, Funcs)}.

%% @doc Decodes a `.pplt` binary into a `#prisma_pplt{}` record.
-spec decode(binary()) -> {ok, #prisma_pplt{}} | {error, term()}.
decode(<<?PRISMA_PPLT_MAGIC, Payload/binary>>) ->
    try binary_to_term(Payload, [safe]) of
        #prisma_pplt{} = Pplt -> {ok, upgrade_pplt(Pplt)};
        _ -> {error, invalid_pplt_record}
    catch
        error:badarg ->
            try binary_to_term(Payload) of
                #prisma_pplt{} = Pplt -> {ok, upgrade_pplt(Pplt)};
                _ -> {error, invalid_pplt_record}
            catch
                _:Reason -> {error, {corrupt_pplt, Reason}}
            end
    end;
decode(_) ->
    {error, invalid_pplt_magic}.

upgrade_pplt(#prisma_pplt{modules = Mods} = Pplt) ->
    NewMods = maps:map(
        fun(_M, Summary0) ->
            Summary = upgrade_module_summary(Summary0),
            Funcs = Summary#module_summary.functions,
            case is_map(Funcs) of
                true ->
                    NewFuncs = maps:map(fun(_MFA, FC) -> upgrade_func_contract(FC) end, Funcs),
                    Summary#module_summary{functions = NewFuncs};
                false ->
                    Summary
            end
        end,
        Mods
    ),
    Pplt#prisma_pplt{modules = NewMods}.

upgrade_module_summary(#module_summary{} = MS) ->
    MS;
upgrade_module_summary({module_summary, Mod, Lang, Vsn, Md5, Exports, ExpTypes, Types, Funcs}) ->
    #module_summary{
        module = Mod,
        language = Lang,
        vsn = Vsn,
        beam_md5 = Md5,
        exports = Exports,
        export_types = ExpTypes,
        types = Types,
        functions = Funcs,
        file = undefined
    };
upgrade_module_summary(Other) ->
    Other.

upgrade_func_contract(#func_contract{} = FC) ->
    FC;
upgrade_func_contract({func_contract, MFA, Exp, Specs, Inferred, Calls, Sites, Warns, Line}) ->
    #func_contract{
        mfa = MFA,
        exported = Exp,
        declared_specs = Specs,
        inferred_type = Inferred,
        calls = Calls,
        call_sites = Sites,
        local_warnings = Warns,
        clauses = [],
        compiler_generated = false,
        line = Line
    };
upgrade_func_contract({func_contract, MFA, Exp, Specs, Inferred, Calls, Sites, Warns, Clauses, Line}) ->
    #func_contract{
        mfa = MFA,
        exported = Exp,
        declared_specs = Specs,
        inferred_type = Inferred,
        calls = Calls,
        call_sites = Sites,
        local_warnings = Warns,
        clauses = Clauses,
        compiler_generated = false,
        line = Line
    };
upgrade_func_contract(Other) ->
    Other.

%% @doc Writes a `#prisma_pplt{}` to `FilePath`.
-spec save(#prisma_pplt{}, file:filename_all()) -> ok | {error, term()}.
save(#prisma_pplt{} = Pplt, FilePath) ->
    ok = filelib:ensure_dir(FilePath),
    file:write_file(FilePath, encode(Pplt)).

%% @doc Reads a `#prisma_pplt{}` from `FilePath`.
-spec load(file:filename_all()) -> {ok, #prisma_pplt{}} | {error, term()}.
load(FilePath) ->
    case file:read_file(FilePath) of
        {ok, Bin} -> decode(Bin);
        {error, Reason} -> {error, Reason}
    end.

%% @doc The declared `-spec`s of every function in the PPLT, `#{{M, F, A} => [stype()]}`.
-spec declared_specs(#prisma_pplt{}) -> #{mfa_key() => [prisma_type:stype()]}.
declared_specs(#prisma_pplt{modules = Mods}) ->
    maps:fold(
        fun(_Mod, #module_summary{functions = Funcs}, Acc) ->
                maps:fold(
                    fun(Key, #func_contract{declared_specs = [_ | _] = Specs}, A) -> A#{Key => Specs};
                       (_, _, A) -> A
                    end, Acc, Funcs)
        end, #{}, Mods).

%% @doc Looks up what is known about module `Mod` in the PPLT.
-spec lookup_module(module(), #prisma_pplt{}) -> {ok, #module_summary{}} | error.
lookup_module(Mod, #prisma_pplt{modules = Mods}) ->
    maps:find(Mod, Mods).

%% @doc Looks up a function contract `{M, F, A}` in the PPLT.
-spec lookup_mfa(mfa_key(), #prisma_pplt{}) -> {ok, #func_contract{}} | error.
lookup_mfa({M, _F, _A} = MFA, #prisma_pplt{modules = Mods}) ->
    case maps:find(M, Mods) of
        {ok, #module_summary{functions = Funcs}} ->
            case maps:find(MFA, Funcs) of
                {ok, FC} -> {ok, upgrade_func_contract(FC)};
                error -> error
            end;
        error ->
            error
    end.

%% @doc Looks up a type declaration `{M, Name, Arity}` in the PPLT.
-spec lookup_type(type_key(), #prisma_pplt{}) -> {ok, #type_decl{}} | error.
lookup_type({M, _Name, _Arity} = Key, #prisma_pplt{modules = Mods}) ->
    case maps:find(M, Mods) of
        {ok, #module_summary{types = Types}} ->
            maps:find(Key, Types);
        error ->
            error
    end.

%% @doc Expands local, remote, recursive, and opaque types in `Type` relative to `CallerMod`.
-spec resolve_type(module(), prisma_type:stype(), #prisma_pplt{}) ->
    {ok, prisma_type:stype()} | {error, term()}.
resolve_type(CallerMod, Type, Pplt) ->
    resolve_type(CallerMod, CallerMod, Type, Pplt).

%% @doc Expands `Type` defined in `DefiningMod` as seen from `CallerMod`.
-spec resolve_type(module(), module(), prisma_type:stype(), #prisma_pplt{}) ->
    {ok, prisma_type:stype()} | {error, term()}.
resolve_type(CallerMod, DefiningMod, Type, Pplt) ->
    LookupFun = fun(Key) -> lookup_type(Key, Pplt) end,
    prisma_type:expand(CallerMod, DefiningMod, Type, LookupFun).

%% @doc Returns the sorted list of modules stored in the PPLT.
-spec modules(#prisma_pplt{}) -> [module()].
modules(#prisma_pplt{modules = Mods}) ->
    lists:sort(maps:keys(Mods)).
