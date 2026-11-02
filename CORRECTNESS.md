# Spectra correctness

How often Spectra is right, measured on real code and compared with other tools **inside the same category**.
Speed and memory live in [`BENCHMARK.md`](BENCHMARK.md); the harness is in [`bench/`](bench/README.md).

Status: first measurement (RabbitMQ), PropEr properties for the type algebra and for inference soundness by execution. The seeded-fault (mutation) corpus is not written yet.

## Like-for-like: discrepancies

`spectra check` mixes four kinds of warning (discrepancy, gradual contract, dead code, oxbow), and Dialyzer only reports
the first one plus some dead code, so the full counts are not comparable. Here Spectra runs with
`mode => discrepancy, oxbow => false` through the API (the escript has no `--mode` option yet: it would read it as a path)
and Dialyzer with its default warnings and the erts/kernel/stdlib PLT.

Corpus: rabbitmq-server `5dacb85` (see `bench/corpus.config.json`).

| Corpus | Spectra (discrepancy mode) | Dialyzer | xref (undefined calls) |
| :--- | :--- | :--- | :--- |
| `rabbit` (234 modules) | **51**: 18 discrepancy, 33 dead code | **0** (40 "callback info not available" notes) | 0 |
| 7 applications (440 modules) | **101**: 35 discrepancy, 66 dead code | **0** (4 notes) | 7 |

RabbitMQ runs Dialyzer in its own CI, so zero is the expected answer. Every one of Spectra's 51 warnings on `rabbit` is
therefore either a false positive or something Dialyzer cannot see.

## Triage of the 51 warnings of `rabbit`

Full list and verdicts: [`bench/triage/rabbitmq-core.json`](bench/triage/rabbitmq-core.json). Each cause below has a
minimal reproduction in [`bench/repro/`](bench/repro/README.md).

| Cause | Warnings | Verdict |
| :--- | :---: | :--- |
| `[H \| T]` used as a pair (`?MSG(Index, Header)` in `rabbit_fifo*`): the tail is typed as a list | 37 (`rabbit_fifo`, `_v3`, `_v7`, `_v8`) | false positive, reproduced. **Fixed**: 51 -> 14 warnings, none new (see below) |
| `orelse` / `andalso` with a non-boolean right operand | 2 (`rabbit_auth_backend_authn_state`, `mc_compat`) | **false positive**, reproduced |
| Overloaded `-spec` (`(.., blocking) -> ..; (.., non_blocking) -> ..`): only the first clause counts | 2 (`rabbit_khepri`), maybe 2 more | **false positive**, reproduced |
| Clause or guard that the declared `-spec` rules out: `rabbit_amqp_util`, `rabbit_definitions` x2, `rabbit_fifo_index`, `rabbit_peer_discovery` | 5 | **true positive: the spec is wrong, the code is right** (details below) |
| Same, but dead by construction: `rabbit_vhost_limit` x2 | 2 | **true positive, intentional**: `get_limit/2` only returns `{ok, N}` for `N >= 0`, the code says "extra defensive". **No longer reported** after the comparison-with-0 fix (see *Precision lost*) |
| `Time == 0` with `Time` a float (`rabbit_variable_queue:update_rate/4`): `==` compares by value, `0.0 == 0` | 1 | false positive, found while triaging. **Fixed**: 8 -> 7, none new |

So **44 of the 51 were false positives and 7 were true** (below). None of the 51 is a bug in the code; five point at wrong `-spec`s. After the improper-cells fix
(37 warnings, all of `rabbit_fifo*`) the same run gives **14**, with none new: the two `andalso`/`orelse` ones, the overloaded
specs, the 5 that the declared `-spec` rules out and the 5 not looked at yet. Then the `andalso`/`orelse` fix took the two of
that cause (**12 left**), the overloaded-spec fix took four (**8**) and the float `==` fix one more: **7 left, all of them true, none new in any step**. On the 440 modules of the seven applications the same run went from
101 to **43**, triaged in the next sections: 0 false positives.

## The last 7 warnings of `rabbit`: all true

Each one was read against the source, its callers and its docs.

| Warning | What is true | Verdict |
| :--- | :--- | :--- |
| `rabbit_amqp_util:has_capability/2`, clause `(_, undefined)` | its only caller passes `desired_capabilities` of the AMQP `open` frame, a record field that is `undefined` when the peer omits it; the spec only allows `{array, symbol, [...]}` | **wrong spec** (the clause runs) |
| `rabbit_fifo_index:append/2`, clause `(undefined, _)` | `rabbit_fifo_v3:convert_msg/1` builds messages with a dummy index `undefined` (`$empty_msg`, `$prefix_msg`) and `take_next_msg/1` passes it to `append/2`; the spec says `integer()`, the sibling `delete/2` already says `integer() \| undefined` | **wrong spec** (the clause runs) |
| `rabbit_peer_discovery:select_node_to_join/1`, clause `([])` | `query_node_props/1` drops unavailable nodes; when the backend already selected a node (`NodeAlreadySelected`) and it is down, `CanUse` is `true` and `[]` is passed; the spec says `nonempty_list(...)` | **wrong spec** (the clause runs) |
| `rabbit_definitions:import_parsed/2` and `import_parsed_with_hashing/2`, clause `when is_list(Body0)` | the arity-1 siblings say `#{any() => any()} \| list()`, the arity-2 specs say `#{any() => any() \| list()}` (a map of lists); the code accepts a list in both | **wrong spec**, most likely a typo; nobody in the corpus passes a list to the arity-2 versions (exported API) |
| `rabbit_vhost_limit:is_over_connection_limit/1` and `would_exceed_queue_limit/2`, clause `{ok, Limit} when Limit < 0` | `get_limit/2` turns negatives into `undefined` and returns `{ok, N}` only for `N >= 0` | **dead on purpose**, the comments say so; not a bug |

The five spec defects are also confirmed by Dialyzer, but only with `-Woverspecs`/`-Wunderspecs` (they report, for example,
`has_capability` as "a subtype of the success typing `(_, 'undefined' | {'array', 'symbol', [any()]})`"), and there they are buried
in **942 spec-difference warnings** for the same `rabbit` ebin. Dialyzer's default warnings give none of them. Spectra reports exactly
the cases where a spec contradicts a *clause*, 7 out of those 942, and none of the 7 is noise. That is a different kind of
finding from the false positives above: **the first real results of Spectra on this code base are wrong specs**, low severity,
which nobody would find without it (or without reading 942 lines).

## The 43 warnings of the 440 modules

After the fixes above the run over the seven applications gives 43 warnings: the 5 wrong specs of `rabbit` already described and 38 in
`cuttlefish`, `cowlib`, `khepri` and `rabbit_common` (code in `rabbit` that calls into them). Four **false positives** turned up
while reading them (two causes, both Spectra bugs, both fixed below) and the rest are true:

| Where | Warnings | What is true |
| :--- | :---: | :--- |
| `cuttlefish_error:xlate/1` | 24 | `-spec xlate({atom(), term()} \| string())`, but 24 clauses take tuples of **3 or more** elements. `cuttlefish_mapping:155` returns `{error, {alias_not_a_string, Variable, Single}}` and `xlate({error, Details})` hands it on. Every 3+-tuple clause of the file is reported and no other: the spec (and the `error()` type) were not widened when the alias errors were added. **Wrong spec, certain.** |
| calls to `rabbit_misc:amqp_error/4`, in `rabbit_reader` (7) and `rabbit_channel` (2) | 9 | the 4th argument must be an `amqp_method_name()`; the calls pass `none`, which is the default of the record field (`method = none`), and `protocol_error/3` passes it too. The `amqp_error()` type has the same gap. **Wrong spec, certain.** |
| `rabbit_data_coercion:to_list_of_binaries/1` | 1 | its caller passes `get_scope(Payload)`, whose own spec is `binary() \| list()`; the binary clause runs. **Wrong spec, certain.** |
| `rabbit_date_time:parse_duration/1` | 1 | `-spec ... (string())` with an `is_binary` clause; the Elixir CLI command that calls it passes an option value (a binary in Elixir). **Wrong spec, probable** (not followed to the end). |
| `cuttlefish_unit:path/2` | 1 | clause for `undefined`; the recursion passes whatever value the config holds, and `undefined` is how cuttlefish marks an unset key. **Wrong spec, probable.** |
| `cow_date:pad_int/1` | 1 | `-spec pad_int(0..59)` but there is a clause for `60` (a leap second?). Nothing shows that 60 is passed. **Unproven.** |
| `khepri_sproc:to_standalone_fun/1` | 1 | the clause takes an already standalone fun; the spec says `fun()` and the only caller passes a plain fun. **Defensive.** |
| `cuttlefish_util:ceiling/1` (2), `cuttlefish_datatypes:from_string/2` (1) | 3 | **false positives**: `Neg < 0`, `Pos > 0`, `X >= 0` on a float. Fixed. |
| `ra_log:write_sparse/3` | 1 | **false positive**: `P == undefined orelse Range == undefined orelse ...`, fixed. |

Dialyzer, with `-Woverspecs`/`-Wunderspecs`, flags five of these functions, among **2229 spec-difference warnings** on the same 440 modules
(and `to_list_of_binaries` and `parse_duration` it does not flag at all); with its default warnings, none. So: Spectra's list is 38 long
and has no noise, but it is not a subset of what Dialyzer can say, and neither is the other way round.

### The two bugs, and the gap in the generator that hid them

- **Comparing with 0.** `X > 0` was read as "X is a positive integer". It also holds for `0.5` and, because numbers are smaller than
  every other term, for **any non-number**: `b > 0` is true. `X < 0` only holds for negative numbers (integers or floats). Now `>` and `>=`
  refine only a variable already known to be a number (to integer or float), and `<` always refines to a negative integer or float.
- **Joining the environments of `A orelse B`.** A variable constrained in only one branch kept that constraint, as if "not mentioned" meant
  "nothing" instead of "anything". Now only variables that every branch constrains keep a type.

The generator knew neither: it had no `X > 0` on floats or atoms, no guards joined by `orelse`, and no record patterns in the head (the variables
of a record pattern are the ones that are not in the environment). It has all three now. With both fixes reverted it fails in 88 tests, shrunk to
`V1 = b, if V1 > 0 -> 1; ...` ("`b > 0` cannot succeed"). Passes 1500 programs x 25 runs with them.

### Precision lost, so nobody finds it by surprise

The two `rabbit_vhost_limit` clauses (`{ok, Limit} when Limit < 0`, dead because `get_limit/2` only returns `{ok, N}` for `N >= 0`) are no
longer reported. They were found for the wrong reason: `N >= 0` used to make N a non-negative integer, which is false (an atom satisfies it). To
see that `{ok, N}` with `N >= 0` can never also satisfy `N < 0`, the type language would need "a float that is not negative", and it has none.
So the right answer is gone and the sound one is "cannot tell". Nothing else was lost in `rabbit` or in the 440 modules.

## Property-based tests: type algebra (PropEr)

`test/prop_spectra_type.erl`, run with `rebar3 as test proper -n 1000`. The oracle is semantic: `member(Term, Type)` decides
whether a concrete term belongs to a ground type, and generators build terms of a given type, so no human triage is needed.
Types are ground and free of `any` (maps, funs and records are not generated yet); lists include `maybe_improper_list`.

| Property | Meaning | Result (1000 runs) |
| :--- | :--- | :--- |
| `generators_agree_with_oracle` | the generators and the oracle describe the same sets (guards the test itself) | pass |
| `subtype_is_reflexive` | `A <~ A` | pass |
| `subtype_is_sound` | `A <~ B` implies every value of A is a value of B | pass |
| `widening_is_accepted` | if B contains A **by construction**, `A <~ B` holds (no false mismatch) | pass |
| `join_is_an_upper_bound` | both operands are included in their join | pass |
| `meet_is_sound` | a value in `meet(A, B)` is in B | pass |
| `normalize_union_keeps_members` / `_is_idempotent` | union normalization neither loses members nor changes on a second pass | pass |
| `meet_keeps_common_values` | a value in A and B is in `meet(A, B)` | pass (was the known bug below) |

That last property used to fail, and was kept disabled under a name PropEr does not run: `meet(improper_list(integer, integer),
list(integer))` was `none` although both contain `[]`. `none` is how the checker decides that two types are disjoint. It is fixed
together with the improper cells (next sections). One limit remains, by design: the type language has no *non-empty* improper
list, so the meet of `improper_list(E, T)` with a `nonempty_list` is exact only when the tail cannot itself be a list; otherwise it
is a safe superset that also holds `[]`. The properties therefore generate `improper_list` with non-list tails (the real case:
`[Index | Header]`), and that is documented in the generator.

The false-positive causes of the RabbitMQ triage live in the inference and checker, not in the type algebra, so these
properties do not see them. The next section does.

## Property-based tests: inference and warnings against execution (PropEr)

`test/prop_spectra_infer.erl`. PropEr generates small well-typed modules (one function `f/2`: a few bindings and `case`
expressions over integers, booleans, atoms, pairs, lists and `[H | T]` cells, each clause on its own line) and 25 argument
samples. The module is compiled, run under `cover`, and for every run that returns normally:

1. the arguments must be inside the inferred domain and the result inside the inferred return type (success typing: what
   really happens can never be outside what was inferred);
2. no `discrepancy` or `dead_code` warning may point at a line that has just run without crashing. Those warnings claim
   "this fails" or "this clause cannot match"; a line that ran refutes them.

A refutation is a **proven** false positive (or an unsound inference), and PropEr shrinks it to a minimal module. Three came out
in the first session, each in a few lines (all in [`bench/repro/`](bench/repro/README.md)):

| Shrunk program | What Spectra says | Truth |
| :--- | :--- | :--- |
| `case true andalso 0 of false -> 0; N when is_integer(N) -> N end` | "`andalso` will fail", "guard cannot succeed" | returns `0` (**fixed**) |
| `case [0 \| 0] of [H \| T] when is_integer(T) -> H + T end` | inferred return type `none` | returns `0` (**fixed**) |
| `f() -> -1.` and `case f() of -1 -> ok end` | `f/0` returns `1`; "no clause can match" | returns `-1` |

The third is the most basic of the three: **`infer_unop` kept the type of the operand for unary `-`, so every negative
literal was inferred as its absolute value**. It is **fixed** (`negate_type/1` in `src/spectra_infer.erl`, with unit tests in
`test/spectra_infer_tests.erl`) and the generator now produces negative literals. Measured on RabbitMQ (`rabbit`, discrepancy
mode) the fix changes nothing: the same 51 warnings before and after, so none of them came from this bug.

All three are fixed, and the property is now the plain `prop_inference_and_warnings_agree_with_execution`: it passes **1500
programs x 25 runs** with no construct left out. Run against the sources from before the last fix it fails in 7 cases, so it is
not passing because it went blind. The fragment is small: no maps, records, funs, `try`, binaries, calls between modules or specs.

## Overloaded `-spec` across modules: the fix

A call to a function with an overloaded `-spec` (`-spec f(a) -> ok; (b) -> ok.`) was checked against the **first clause only**, so
`f(b)` from another module was reported as "will fail" (`rabbit_feature_flags:is_enabled(Flag, non_blocking)`). Calls inside a
module were already fine, because their argument types are seeded with the union of the clauses.

Now each clause is one whole vector of argument types, and a call is accepted if **some** vector accepts all its arguments
(`spectra_checker:check_vectors/3`, for discrepancy and gradual checks alike). Not a per-position union: with `(integer(), boolean())`
and `(atom(), integer())`, the call `h(1, 1)` mixes the two clauses and is still reported (unit test). Measured on RabbitMQ:
**12 -> 8 warnings**, the four expected, none new.

### The generator now has callers, callees and specs

`prop_spectra_infer` generates a second module per program: `g/1` or `g/2` with an overloaded `-spec` (up to three clauses over
integers, booleans, atoms, pairs and lists), guards exclusive per type, each clause returning its own number. The caller module
calls it, 80% of the time with arguments of a clause of the spec and 20% with any types (those crash at run time, and a run that
crashes refutes nothing). Warnings are only taken from the caller module. Run against the checker from before the fix it fails in
**6 tests**, shrunk to a callee with two clauses and a call that fits the second.

### The generator also had a gap: floats

Triaging the last warning of `rabbit_variable_queue` found a bug the properties had not: `X == 0` with a float is true for `0.0`
(`==` compares numbers by value; `=:=` does not), and Spectra reported the guard as unreachable. The generator had no `/`, no floats and no
`==` in guards. It has them now, and with the fix reverted it finds the bug in 388 tests. `X =:= 0` on a float stays reported
(it really is dead), also covered by a unit test. The lesson is the usual one for generators: **a property is only as good as what it can
generate**, so every real finding that it missed becomes a new production in the generator.

## `andalso` / `orelse`: the fix

Only the **left** operand of `andalso` / `orelse` has to be a boolean; the value is the right operand (any term) when the left one
does not decide. Spectra read them as `and` / `or`: it reported "will fail" when the right operand was not a boolean, narrowed the
right operand's variable to `boolean` (also wrong), and typed the result as `boolean`. Now `A andalso B` is `false | B`, `A orelse B`
is `true | B` (narrowed by what A may be: `true andalso 0` is `0`, and a literal `true` on the left makes a `false ->` clause
really dead, which is reported), and the left operand is still checked. `and`, `or` and `xor` stay strict.

Measured on RabbitMQ (`rabbit`, discrepancy mode): **14 -> 12 warnings, exactly the two expected, none new.**

## Improper cells: the fix and what it costs

Four places treated every `[H | T]` as a proper list, and PropEr found a fifth on the way. Now:

- **Construction.** `[H | T]` is a proper list only when T is known to be one. A tail that is an integer, a map or *unknown* gives
  `improper_list(H, T)` (a first version that gave unknown tails the benefit of the doubt was refuted by PropEr within seconds:
  `case [4 | B] of [H | T] when is_integer(T) -> ...` with `B` unknown). A cons onto an improper list does not nest.
- **Patterns.** The tail variable gets the tail type of the scrutinee (unknown if the scrutinee is), not `list(any)`.
- **`tl/1`** returns the tail type of its argument; **`hd/1`, `tl/1`** take any non-empty list, proper or not (PropEr again: the old
  domain `nonempty_list(any)` was refuted by `[0 | 0]`).
- **`spectra_type`**: `meet` and subtyping between `improper_list` and `list` / `nonempty_list` / `nil` / `improper_list`.

Measured on RabbitMQ (`rabbit`, discrepancy mode): **51 -> 14 warnings; the 37 that disappear are exactly the `rabbit_fifo*` ones, and none is new.**

Costs and losses, so nobody finds them by surprise:

- **Precision.** `hd([])` is no longer reported (the type has no "non-empty improper list" to tell it from `hd([1 | 2])`); the Erlang
  compiler already warns about it. In exchange `tl(X) + 1` is no longer reported as `badarith`, which was a false positive.
- **Speed.** Building the `.splt` of OTP's `compiler` application went from ~0.65 s to ~1.0 s (more unions in the types). A full
  `spectra check` of `deps/rabbit` is unchanged (~1.2 s).
- **Depth.** The exact meet of two improper lists with list-able tails is cut at a nesting depth of 2 (counted across the recursion),
  then a safe superset; without the cut `compiler` took minutes.

## Not yet measured

- Gradual contract mismatches (115 on `rabbit`) against Gradualizer: not installed where it can be found.
- Oxbow (80 on `rabbit`) against xref's unused locals: xref reports 0 because the compiler already warns on them, so the
  80 are mostly "ignored parameter" findings, which have no counterpart in the other tools.
- False negatives: needs the seeded-fault corpus.
- Dialyzer with a full PLT of the dependencies (this run lacks it, so it sees fewer calls).
