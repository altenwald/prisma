-ifndef(SPECTRA_HRL).
-define(SPECTRA_HRL, true).

-define(SPECTRA_PLT_MAGIC, "SPECTRA_PLT_V1").
-define(SPECTRA_PLT_VERSION, 1).

-type mfa_key() :: {module(), atom(), arity()}.
-type type_key() :: {module(), atom(), arity()}.
-type analysis_mode() :: hybrid | gradual | discrepancy.
-type source_lang() :: erlang | elixir | beam.

-record(type_decl, {
    key :: type_key(),
    kind = type :: type | opaque | nominal,
    exported = false :: boolean(),
    params = [] :: [atom()],
    body :: spectra_type:stype()
}).

-record(spectra_warning, {
    kind :: gradual_mismatch | discrepancy | unknown_function | dead_code | oxbow_code | opacity_violation,
    mfa :: mfa_key(),
    line = 0 :: non_neg_integer(),
    message :: binary(),
    declared = undefined :: undefined | spectra_type:stype(),
    actual = undefined :: undefined | spectra_type:stype(),
    expected = undefined :: undefined | spectra_type:stype(),
    callee = undefined :: undefined | mfa_key(),
    arg_idx = undefined :: undefined | pos_integer()
}).

-type call_site() :: {non_neg_integer(), mfa_key(), [spectra_type:stype()]}.

-record(func_contract, {
    mfa :: mfa_key(),
    exported = false :: boolean(),
    declared_specs = [] :: [spectra_type:stype()],
    inferred_type = any :: spectra_type:stype(),
    calls = [] :: [mfa_key()],
    call_sites = [] :: [call_site()],
    local_warnings = [] :: [#spectra_warning{}],
    clauses = [] :: [term()],
    compiler_generated = false :: boolean(),
    line = 0 :: non_neg_integer()
}).

-record(module_summary, {
    module :: module(),
    language = erlang :: source_lang(),
    vsn :: term(),
    beam_md5 :: binary(),
    exports = [] :: [{atom(), arity()}],
    export_types = [] :: [{atom(), arity()}],
    types = #{} :: #{type_key() => #type_decl{}},
    functions = #{} :: #{mfa_key() => #func_contract{}}
}).

-record(spectra_plt, {
    version = ?SPECTRA_PLT_VERSION :: pos_integer(),
    package :: binary() | undefined,
    package_vsn :: binary() | undefined,
    otp_release :: binary(),
    modules = #{} :: #{module() => #module_summary{}}
}).

-endif.
