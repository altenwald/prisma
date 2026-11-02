%% @doc Manages portable, path-independent Spectra PLT files (`.splt`).
%%
%% Supports building a PLT from BEAM files, encoding/decoding compressed
%% binaries, merging multiple PLTs in memory, and resolving remote/opaque types.
-module(spectra_plt).

-include("spectra.hrl").

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
    lookup_type/2,
    resolve_type/3,
    resolve_type/4,
    modules/1
]).

%% @doc Creates an empty `#spectra_plt{}` for the current OTP release.
-spec new() -> #spectra_plt{}.
new() ->
    new(undefined, undefined).

%% @doc Creates an empty `#spectra_plt{}` with package metadata.
-spec new(binary() | undefined, binary() | undefined) -> #spectra_plt{}.
new(Pkg, PkgVsn) ->
    OtpRel = list_to_binary(erlang:system_info(otp_release)),
    #spectra_plt{
        version = ?SPECTRA_PLT_VERSION,
        package = Pkg,
        package_vsn = PkgVsn,
        otp_release = OtpRel,
        modules = #{}
    }.

%% @doc Builds a `#spectra_plt{}` from all `.beam` files in `Dir`.
-spec from_dir(file:filename_all()) -> {ok, #spectra_plt{}} | {error, term()}.
from_dir(Dir) ->
    Pattern = filename:join(unicode:characters_to_list(Dir), "*.beam"),
    Beams = filelib:wildcard(Pattern),
    from_beams(Beams).

%% @doc Builds a `#spectra_plt{}` from a list of BEAM paths or binaries.
-spec from_beams([file:filename_all() | binary()]) -> {ok, #spectra_plt{}} | {error, term()}.
from_beams(Beams) ->
    from_beams(Beams, #{}).

%% @doc Builds a `#spectra_plt{}` from BEAM inputs and metadata options.
-spec from_beams([file:filename_all() | binary()], map()) ->
    {ok, #spectra_plt{}} | {error, term()}.
from_beams(Beams, Opts) ->
    Pkg = maps:get(package, Opts, undefined),
    PkgVsn = maps:get(package_vsn, Opts, undefined),
    BasePlt = new(Pkg, PkgVsn),
    lists:foldl(
        fun
            (Beam, {ok, #spectra_plt{modules = Mods} = Plt}) ->
                case spectra_abstract:extract_beam(Beam) of
                    {ok, #module_summary{module = Mod} = Summary} ->
                        {ok, Plt#spectra_plt{modules = Mods#{Mod => Summary}}};
                    {error, Reason} ->
                        {error, {beam_extract_failed, Beam, Reason}}
                end;
            (_Beam, {error, _} = Err) ->
                Err
        end,
        {ok, BasePlt},
        Beams
    ).

%% @doc Merges a list of `#spectra_plt{}` records into one.
-spec merge([#spectra_plt{}]) -> #spectra_plt{}.
merge([]) ->
    new();
merge([First | Rest]) ->
    lists:foldl(fun(Plt, Acc) -> merge(Acc, Plt) end, First, Rest).

%% @doc Merges two `#spectra_plt{}` records.
-spec merge(#spectra_plt{}, #spectra_plt{}) -> #spectra_plt{}.
merge(#spectra_plt{modules = M1} = Plt1, #spectra_plt{modules = M2}) ->
    Plt1#spectra_plt{modules = maps:merge(M1, M2)}.

%% @doc Serializes a `#spectra_plt{}` into a compressed binary with header magic.
-spec encode(#spectra_plt{}) -> binary().
encode(#spectra_plt{} = Plt) ->
    Payload = term_to_binary(Plt, [compressed, {minor_version, 2}]),
    <<?SPECTRA_PLT_MAGIC, Payload/binary>>.

%% @doc Decodes a `.splt` binary into a `#spectra_plt{}` record.
-spec decode(binary()) -> {ok, #spectra_plt{}} | {error, term()}.
decode(<<?SPECTRA_PLT_MAGIC, Payload/binary>>) ->
    try binary_to_term(Payload, [safe]) of
        #spectra_plt{} = Plt -> {ok, Plt};
        _ -> {error, invalid_plt_record}
    catch
        error:badarg ->
            try binary_to_term(Payload) of
                #spectra_plt{} = Plt -> {ok, Plt};
                _ -> {error, invalid_plt_record}
            catch
                _:Reason -> {error, {corrupt_plt, Reason}}
            end
    end;
decode(_) ->
    {error, invalid_plt_magic}.

%% @doc Writes a `#spectra_plt{}` to `FilePath`.
-spec save(#spectra_plt{}, file:filename_all()) -> ok | {error, term()}.
save(#spectra_plt{} = Plt, FilePath) ->
    ok = filelib:ensure_dir(FilePath),
    file:write_file(FilePath, encode(Plt)).

%% @doc Reads a `#spectra_plt{}` from `FilePath`.
-spec load(file:filename_all()) -> {ok, #spectra_plt{}} | {error, term()}.
load(FilePath) ->
    case file:read_file(FilePath) of
        {ok, Bin} -> decode(Bin);
        {error, Reason} -> {error, Reason}
    end.

%% @doc Looks up a function contract `{M, F, A}` in the PLT.
-spec lookup_mfa(mfa_key(), #spectra_plt{}) -> {ok, #func_contract{}} | error.
lookup_mfa({M, _F, _A} = MFA, #spectra_plt{modules = Mods}) ->
    case maps:find(M, Mods) of
        {ok, #module_summary{functions = Funcs}} ->
            maps:find(MFA, Funcs);
        error ->
            error
    end.

%% @doc Looks up a type declaration `{M, Name, Arity}` in the PLT.
-spec lookup_type(type_key(), #spectra_plt{}) -> {ok, #type_decl{}} | error.
lookup_type({M, _Name, _Arity} = Key, #spectra_plt{modules = Mods}) ->
    case maps:find(M, Mods) of
        {ok, #module_summary{types = Types}} ->
            maps:find(Key, Types);
        error ->
            error
    end.

%% @doc Expands local, remote, recursive, and opaque types in `Type` relative to `CallerMod`.
-spec resolve_type(module(), spectra_type:stype(), #spectra_plt{}) ->
    {ok, spectra_type:stype()} | {error, term()}.
resolve_type(CallerMod, Type, Plt) ->
    resolve_type(CallerMod, CallerMod, Type, Plt).

%% @doc Expands `Type` defined in `DefiningMod` as seen from `CallerMod`.
-spec resolve_type(module(), module(), spectra_type:stype(), #spectra_plt{}) ->
    {ok, spectra_type:stype()} | {error, term()}.
resolve_type(CallerMod, DefiningMod, Type, Plt) ->
    LookupFun = fun(Key) -> lookup_type(Key, Plt) end,
    spectra_type:expand(CallerMod, DefiningMod, Type, LookupFun).

%% @doc Returns the sorted list of modules stored in the PLT.
-spec modules(#spectra_plt{}) -> [module()].
modules(#spectra_plt{modules = Mods}) ->
    lists:sort(maps:keys(Mods)).
