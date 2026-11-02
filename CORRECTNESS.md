# Spectra correctness

How often Spectra is right, measured on real code and compared with other tools **inside the same category**.
Speed and memory live in [`BENCHMARK.md`](BENCHMARK.md); the harness is in [`bench/`](bench/README.md).

Status: first measurement (RabbitMQ) plus the first PropEr properties (type algebra). The inference-soundness properties and the seeded-fault (mutation) corpus are not written yet.

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
| `[H \| T]` used as a pair (`?MSG(Index, Header)` in `rabbit_fifo*`): the tail is typed as a list | 37 (`rabbit_fifo`, `_v3`, `_v7`, `_v8`) | **false positive**: reproduced; individual lines not all checked by hand |
| `orelse` / `andalso` with a non-boolean right operand | 2 (`rabbit_auth_backend_authn_state`, `mc_compat`) | **false positive**, reproduced |
| Overloaded `-spec` (`(.., blocking) -> ..; (.., non_blocking) -> ..`): only the first clause counts | 2 (`rabbit_khepri`), maybe 2 more | **false positive**, reproduced |
| Clause or guard that the declared `-spec` rules out (`rabbit_amqp_util`, `rabbit_definitions` x2, `rabbit_vhost_limit` x2) | 5 | **debatable**: true against the contract (defensive code), Dialyzer is silent |
| Not looked at yet (`rabbit_variable_queue`, `rabbit_peer_discovery`, `rabbit_fifo_index`, `rabbit_feature_flags`, `rabbit_ff_controller`) | 5 | pending |

So **at least 41 of 51 are false positives and none of the 51 is a confirmed real defect**. Spectra's promise of zero false
positives does not hold on this code yet, and the three causes above are good first candidates for regression tests.

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
| `known_bug_meet_keeps_common_values` | a value in A and B is in `meet(A, B)` | **fails, disabled** |

The one failure is a real incompleteness: `spectra_type:meet(improper_list(integer, integer), list(integer))` is `none`
although both contain `[]` and every proper list of integers. `none` is how the checker decides that two types are
disjoint, so any pair of types that goes through this path can be reported as "will fail". The property is kept in the file
under a name proper does not run, and should be renamed to `prop_*` when `meet/2` is fixed. (A first attempt to show it as a
false positive with a two-line module did not work out: Dialyzer also rejects that `-spec`, so it is not evidence.)

The three false-positive causes of the RabbitMQ triage (improper lists as pairs, non-boolean `andalso`/`orelse`, overloaded
specs) live in the inference and checker, not in the type algebra, so these properties do not see them: the next step is the
execution-based soundness property.

## Not yet measured

- Gradual contract mismatches (115 on `rabbit`) against Gradualizer: not installed where it can be found.
- Oxbow (80 on `rabbit`) against xref's unused locals: xref reports 0 because the compiler already warns on them, so the
  80 are mostly "ignored parameter" findings, which have no counterpart in the other tools.
- False negatives: needs the seeded-fault corpus.
- Dialyzer with a full PLT of the dependencies (this run lacks it, so it sees fewer calls).
