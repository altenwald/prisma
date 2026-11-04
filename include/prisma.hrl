-ifndef(PRISMA_HRL).
-define(PRISMA_HRL, true).

-define(PRISMA_PPLT_MAGIC, "PRISMA_PPLT_V1").
-define(PRISMA_PPLT_VERSION, 1).

-type mfa_key() :: {module(), atom(), arity()}.
-type type_key() :: {module(), atom(), arity()}.
-type analysis_mode() :: hybrid | gradual | discrepancy.
-type source_lang() :: erlang | elixir | beam.

-record(type_decl, {
    key :: type_key(),
    kind = type :: type | opaque | nominal,
    exported = false :: boolean(),
    params = [] :: [atom()],
    body :: prisma_type:stype()
}).

-record(prisma_warning, {
    kind :: gradual_mismatch | discrepancy | unknown_function | handled_undef | dead_code | oxbow_code | opacity_violation,
    mfa :: mfa_key(),
    line = 0 :: non_neg_integer(),
    message :: binary(),
    declared = undefined :: undefined | prisma_type:stype(),
    actual = undefined :: undefined | prisma_type:stype(),
    expected = undefined :: undefined | prisma_type:stype(),
    callee = undefined :: undefined | mfa_key(),
    arg_idx = undefined :: undefined | pos_integer(),
    file = undefined :: undefined | string()
}).

%% A call site: line, callee and the types of the arguments; a fourth element says how the code protects the call:
%%   environment   it is in a branch that depends on what the running system has (function_exported, system_info...)
%%   undef_handled it is in a `try` that catches `error:undef`
%%   any_handled   it is in a `try` (or `catch`) that catches every error
-type call_site() :: {non_neg_integer(), mfa_key(), [prisma_type:stype()]}
                   | {non_neg_integer(), mfa_key(), [prisma_type:stype()], environment | undef_handled | any_handled}.

-record(func_contract, {
    mfa :: mfa_key(),
    exported = false :: boolean(),
    declared_specs = [] :: [prisma_type:stype()],
    inferred_type = any :: prisma_type:stype(),
    calls = [] :: [mfa_key()],
    call_sites = [] :: [call_site()],
    local_warnings = [] :: [#prisma_warning{}],
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
    functions = #{} :: #{mfa_key() => #func_contract{}},
    file = undefined :: undefined | string()
}).

-record(prisma_pplt, {
    version = ?PRISMA_PPLT_VERSION :: pos_integer(),
    package :: binary() | undefined,
    package_vsn :: binary() | undefined,
    otp_release :: binary(),
    %% md5 of the sources of the package (see prisma_lock:source_hash/1): tells a consumer that the file is stale
    source_hash :: binary() | undefined,
    modules = #{} :: #{module() => #module_summary{}}
}).

-endif.
