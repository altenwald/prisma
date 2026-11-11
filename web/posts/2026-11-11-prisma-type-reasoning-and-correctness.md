id              : prisma-type-reasoning-and-correctness
date            : 2026-11-11
updated         : 2026-11-11
title           : How Prisma Reasons About Types and Verifies Correctness
subtitle        : Inside Prisma's hybrid type algebra, forward constraint inference, widening bounds, PropEr semantic proofs, and mutation benchmarks
author          : Manuel Rubio
category        : Type Systems
group           : internals
tags            : erlang, elixir, prisma, type-systems, gradual-typing, success-typing, proper, correctness, static-analysis, dialyzer
project         : prisma
repo            : https://github.com/altenwald/prisma
summary         : A technical deep dive into Prisma's type reasoning engine: how it combines forward success typing and gradual contract subtyping over a bounded lattice, and how correctness is verified with PropEr semantic oracles, 125 injected mutants, and RabbitMQ corpus triage.

After publishing [*Understanding Prisma PPLT*](/blog/understanding-prisma-pplt), two sharp questions quickly came up on Erlang Slack—asking less about packaging and caching, and more about the heart of any static analyzer: **what type reasoning does Prisma actually use, how does it ensure correctness, and does it handle modern OTP features like nominal types and native records?**

<!--more-->

Those are exactly the right questions. Portable `.pplt` caches only matter if the analysis built on top of them is sound, terminates on real OTP code, and avoids drowning developers in false alarms.

In this post, we look under the hood of Prisma's type system (`prisma_type`, `prisma_infer`, and `prisma_checker`), examine the three verification layers used to keep it honest—including a couple of real lattice bugs caught by property-based testing along the way—and openly lay out the gaps that are still on our roadmap.

---

## 1. Two Complementary Layers Over One Lattice

Prisma does not force you to choose between pure *success typing* (never complain unless failure is provable, leaving weak `-spec` violations silent) and strict *static typing* (reject every unannotated function or dynamic pattern). Instead, [`prisma_checker`](https://github.com/altenwald/prisma/blob/main/src/prisma_checker.erl) runs two distinct analyses over the same normalized type algebra, controlled via `--mode`:

1. **Discrepancy Mode (Success Typing):** Focused on proving runtime failures and unreachable code with **zero invented errors**.
2. **Gradual Mode (`-spec` / `@spec` Contracts):** Focused on verifying declared developer contracts against inferred function domains, bodies, and call sites.
3. **Hybrid Mode (default):** Runs both together, keeping their warning severities distinct.

This separation is intentional. A `discrepancy` or `unknown_function` means Prisma can demonstrate that the code will fail when reached. A `gradual_mismatch` means your code and your declared specification disagree. Dead clauses, ignored function parameters (`oxbow_code`), and missing functions swallowed by `try ... catch _:_` (`handled_undef`) are classified as warnings rather than silent omissions or fatal errors.

---

## 2. How Inference & Subtyping Work

### 2.1 Forward Constraint Inference (`prisma_infer`)

Unlike Dialyzer's global inter-procedural constraint solver over the entire call graph, Prisma performs **modular, forward, flow-sensitive inference** per function clause (`prisma_infer`), reading external callee signatures directly from merged `.pplt` summaries in memory.

Within a function body, Prisma tracks an environment mapping variables to `stype()` lattice values and refines them across:

* **Pattern matching & subtraction:** Patterns refine scrutinees (`case`, `receive`, function heads, `=`). When subtracting earlier `case` clauses for reachability (`dead_code`), a clause only subtracts from subsequent ones if it introduces no fresh pattern variables—preventing false dead-code claims when a variable-bearing pattern could fail to match at runtime.
* **Asymmetric short-circuit boolean logic:** `A andalso B` narrows the environment with the truthiness of `A` only when evaluating `B` (and types the expression as `false | B` rather than assuming `B` must be boolean); `A orelse B` merges only constraints guaranteed by both paths.
* **Guard refinement (`apply_guard_bif`):** Type test BIFs (`is_integer/1`, `is_binary/1`, `is_map/1`, `is_record/2,3`, `tuple_size/1`, `byte_size/1`), relational comparisons, and boolean combinations (`andalso`, `orelse`, `not`) refine variables in the branch environment. Relational comparisons like `X > 0` are handled carefully: on the BEAM, any atom or tuple compares greater than `0`, so `>` only narrows `X` when `X` is already known to be numeric.
* **Improper cells (`[H | T]`):** Unless the tail is known to be a proper list, `[H | T]` is typed as `improper_list(H, T)` rather than assuming a proper list—crucial for Erlang macros and binary/protocol parsers.
* **Environment-guarded & `try`-protected calls:** Branches gated by `erlang:function_exported/3` or `erlang:system_info(otp_release)` are evaluated against the host OTP release (un-taken branches are counted as unchecked notes rather than flagged as errors or dead code), and calls caught by `error:undef` are respected.

Whenever an expression depends on an unannotated dynamic value (`any`), a polymorphic type variable (`{var, Name}`), or an unresolved reference, Prisma propagates the uncertainty rather than guessing failure. Discrepancies fire only when `meet(Expected, Actual) =:= none` on a concrete, incompatible pair.

### 2.2 Gradual Contract Checking (`consistent_subtype/2`)

When checking `-spec` and `@spec` contracts, [`prisma_type:consistent_subtype/2`](https://github.com/altenwald/prisma/blob/main/src/prisma_type.erl) implements gradual subtyping (`Sub <~ Super`):

* `any`, type variables, and recursive references remain consistent with any type.
* Function types (`fun_type`) are **contravariant in arguments** and **covariant in return types**; overloaded `-spec` clauses are treated as whole argument vectors (not Cartesian products across arguments).
* **Map fields:** Literal keys in a map construction are required (`exact`, `:=`), whereas `#{K => V}` associations in specs are optional (`assoc`).
* **Opaque types:** `{opaque, Mod, Name, Args, Body}` stays structurally transparent inside `Mod` and opaque (`opacity_violation`) when inspected or constructed outside `Mod`.
* **Bitstrings & binaries:** `{binary, Base, Unit}` encodes exact size and stride (`Unit =:= 0` for fixed-width bitstrings like `<<_:8>>`, `Unit > 0` for `<<_:Base, _:_*Unit>>`), with exact Chinese-remainder `meet` calculation (`meet_binary`).

### 2.3 Bounded Fixpoints & Widening (`widen/1`)

A classic hazard of abstract interpretation over recursive Erlang functions—such as parsers building nested `[H | T]` structures in `stdlib`'s `calendar`, `uri_string`, or `file_sorter`—is unbounded type growth across fixpoint iterations.

Prisma enforces termination in two ways:
1. **`prisma_type:widen/1`:** Caps structural nesting past `?WIDEN_DEPTH` by generalizing inner compound terms to `any`, and collapses non-literal unions past `?WIDEN_MEMBERS`—while deliberately allowing **flat unions of atom/integer literals up to 1,024 members** so large protocol dispatch specs (like AMQP method tables) stay precise.
2. **Bounded meets (`too_many_pairs`, `too_big`):** When intersecting huge unions of nested improper lists exceeds memory thresholds (`?MAX_MEET_PAIRS` / `?MAX_IMPROPER_MEET_WORDS`), `meet/2` safely returns the smaller operand (a sound over-approximation of the intersection) rather than blowing up memory or runtime.

---

## 3. How Prisma Verifies Correctness

Prisma relies on **three complementary verification layers** rather than trusting unit tests alone.

### Layer 1: Semantic Property-Based Testing with PropEr (`18/18` Properties)

Inside [`test/prisma_oracle.erl`](https://github.com/altenwald/prisma/blob/main/test/prisma_oracle.erl), we define a denotational oracle `member(Term, Type)` that decides whether a concrete Erlang value belongs to a ground type (`⟦T⟧ = { v | member(v, T) }`).

Using this oracle, [`test/prop_prisma_type.erl`](https://github.com/altenwald/prisma/blob/main/test/prop_prisma_type.erl) tests **16 algebraic and lattice properties** directly against `prisma_type`:

* **Subtyping laws:** Reflexivity, soundness (`consistent_subtype(A, B) => member(V, B)`), and transitivity over chains `A ≲ B ≲ C`.
* **Join & Meet laws:** `join` upper-bound consistency and value preservation; `meet` soundness, common-value preservation, commutativity, idempotence, and lower-bound consistency.
* **Normalization & Widening:** Union normalization preserves members and is idempotent; `prisma_type:widen/1` is both sound (`T <~ widen(T)` and keeps all concrete values) and idempotent (`widen(widen(T)) =:= widen(T)`).

And [`test/prop_prisma_infer.erl`](https://github.com/altenwald/prisma/blob/main/test/prop_prisma_infer.erl) goes one step further with **execution-backed soundness (`prop_inference_and_warnings_agree_with_execution` and `prop_guard_narrowing_is_sound`)**: PropEr generates random Erlang modules (bindings, `case`, `try`, comprehensions, records, overloaded remote calls, and multi-clause compound guards over integers, floats, maps, binaries, lists, and tuples), compiles them with `cover`, and executes concrete inputs on the BEAM. Every test fails and shrinks if:
1. Any executed return value or accepted argument falls outside Prisma's inferred signature, or
2. Any `discrepancy` or `dead_code` warning points to a line that `cover` proved actually executed cleanly.

**Why semantic PBT matters in practice:** While expanding `prop_prisma_type` to stress integer ranges and fixed-width bitstrings, PropEr caught two subtle bugs immediately:
* When a union combined `{int_range, 1, pos_inf}` with `pos_integer` (identical bounds, different AST tags), `is_strict_subtype/2` considered each a strict subtype of the other and absorbed *both* down to `none`.
* `subtype_non_numeric/2` for `{binary, B1, U1}` vs `{binary, B2, 0}` accepted `U1 > 0` whenever `B1 >= B2` (claiming `<<_:8, _:_*8>>` was a subtype of exact `<<_:8>>`).

Fixing both turned all **18/18 PropEr properties** green (and added dedicated EUnit regressions, bringing the unit suite to **249/249 passing**).

### Layer 2: Mutation Testing on Real Code (125 Mutants)

Synthetic properties alone can miss real-world idioms, so we also measure recall and precision via fault injection on **RabbitMQ** (`5dacb85`), documented in [`DISCREPANCIES.md`](https://github.com/altenwald/prisma/blob/main/DISCREPANCIES.md) and [`GRADUAL.md`](https://github.com/altenwald/prisma/blob/main/GRADUAL.md). Five mutation operators inject 25 single faults each (125 mutants total):

| Operator | Fault Injected | Prisma | Dialyzer | Gradualizer |
| :--- | :--- | :---: | :---: | :---: |
| `r1` | Spec return mismatch | **25/25** | 25/25 | 18/25 |
| `r2` | Argument vs. spec | **25/25** | 24/25 | 19/25 |
| `r3` | Wrong BIF argument | **25/25** | 24/25 | 7/25 |
| `r4` | Call to missing function | **25/25** | 25/25 | 16/25 |
| `r6` | Pattern vs. spec return | **25/25** | 25/25 | 8/25 |
| **Total** | **125 seeded faults** | **125 (100%)** | **123 (98%)** | **68 (54%)** |

Equally important: across those 125 runs, Prisma emitted **0 new spurious warnings outside the mutated function** (compared to 201 for Dialyzer and 28 for Gradualizer).

### Layer 3: Large-Corpus Triage & Minimal Repros

On the unmodified RabbitMQ codebase (234 modules in `rabbit`, 440 modules across 7 applications totaling 438k+ lines):
* In `discrepancy` mode, initial runs exposed 44 false positives out of 51 findings on `rabbit`. Each one was triaged against the source, captured as a minimal reproduction in [`bench/repro/`](https://github.com/altenwald/prisma/blob/main/bench/repro/README.md), and fixed—bringing false positives on `rabbit` to **0** (with the remaining 5 warnings confirmed as genuine bugs in `-spec`s that Dialyzer leaves silent without `-Woverspecs`).
* With full OTP + dependency PPLTs loaded in `hybrid` mode, analyzing all 440 modules runs in **~6.8 s** (vs. **35.9 s** for Gradualizer) and surfaced 6 Prisma edge cases around maps, `fun()` arity, and polymorphic keys—each fixed and turned into a regression test in `test/prisma_otp_specs_tests.erl`.

---

## 4. Known Gaps & Honest Roadmap

A post about correctness is incomplete if it hides what the tool **does not** do yet. Based both on our own triage and on the exact questions raised by the community this week, here is what is currently open:

1. **Nominal Types (`-nominal`, EEP-69 / OTP 28+):**
   Prisma already parses `{attribute, _, nominal, ...}` into `#type_decl{kind = nominal}`, **but currently expands nominal types structurally**, meaning passing a `foot()` where a `meter()` is expected is not flagged yet. Enforcing nominal identity (`{nominal, Mod, Name, Args, Body}`) without breaking structural operations is a tracked priority.
2. **Native Records (`-record #name{}`, EEP-79 / OTP 29+):**
   Because OTP 29 native records are a distinct VM type rather than desugared tuples, they are **not yet supported**: `{attribute, _, native_record, ...}` and `-export_record` are not extracted, record expressions fall back to `any`, and `is_record(Term, Mod, Name)` (the 3-atom native form) currently triggers a false discrepancy expecting an integer tuple size. Both are actively queued for implementation and validation against OTP 29's `compiler`, `gpb`, and `erldist_filter`.
3. **Value-Correlated Spec Overloads:**
   Functions like `rabbit_ff_controller:run_callback/5` whose return type depends on the literal value of an earlier command argument across overloaded spec clauses still produce a known false positive.
4. **Wider Corpora & Formalizing the Core Algebra:**
   Our large-corpus metrics today cover Erlang (RabbitMQ); adding full benchmark evaluations on **`ra`** and a real-world **Elixir** codebase—along with a standalone `TYPESYSTEM.md` specification and a small Lean 4 / Rocq formalization of the core lattice—are on our backlog.

If you want to inspect the exact data, scripts, and reproduction cases yourself, see [`DISCREPANCIES.md`](https://github.com/altenwald/prisma/blob/main/DISCREPANCIES.md), [`GRADUAL.md`](https://github.com/altenwald/prisma/blob/main/GRADUAL.md), and run `rebar3 proper` right in the repository.
