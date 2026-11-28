id              : prisma-0-2-11-elixir-ast-pplt-and-type-refinement
date            : 2026-11-28
updated         : 2026-11-28
title           : From v0.2.9 to v0.2.11: Guarded Refinement, Diagnostics UX, Nine Issues Fixed, and a PropEr Suite for Elixir
subtitle        : What changed between v0.2.9 and v0.2.11—from opaque-preserving guards and readable mismatch paths to closing #17–#25 and property-testing compiled Elixir ASTs
author          : Manuel Rubio
category        : Type Systems
group           : internals
tags            : erlang, elixir, prisma, type-systems, gradual-typing, pplt, proper, testing, diagnostics
project         : prisma
repo            : https://github.com/altenwald/prisma
summary         : Technical summary of Prisma v0.2.10 and v0.2.11, covering guard refinement, path-focused type mismatch diagnostics, nine resolved GitHub issues (#17–#25), and a new PropEr property suite that compiles and executes real Elixir modules.

In [*From v0.2.1 to v0.2.9*](/blog/prisma-0-2-9-type-engine-and-elixir), we focused on polymorphic `bounded_fun` specs, demand-driven specialization, and making PPLT builds fast on large Elixir projects.

Between **`v0.2.9`** and **`v0.2.11`**, the focus shifted to **type precision in guards**, **diagnostic readability**, **nine community-reported issues (`#17`–`#25`)**, and building a **property-based test suite (`prop_prisma_elixir`) that compiles and runs real Elixir code** against Prisma.

<!--more-->

---

## 1. `v0.2.10`: Guard Refinement, Opaque Preservation, and Focused Mismatch Paths

Two commits landed around `v0.2.10` to tighten precision and make large type mismatches readable:

* **Opaque preservation & guarded clause subtraction (`prisma_type` / `prisma_infer`):**
  * `prisma_type:meet/2` now preserves `@opaque` wrappers when narrowing against compatible types instead of stripping opacity prematurely.
  * Inequality guards (`=/=` and `/=`) against atom literals narrow union types cleanly, record unions are filtered by tag in pattern/guard refinement, and guarded clauses subtract only the covered portion when the guard is guaranteed to hold.
* **Path-focused mismatch diagnostics (`prisma_checker` / `prisma_type`):**
  * Large nested types (records, maps, tuples, unions) previously printed the entire structural expansion in `gradual_mismatch` messages. `prisma_checker` now narrows the reported mismatch down to the **failing path** and formats `recursive_ref` cleanly instead of dumping raw internal AST markers.

---

## 2. `v0.2.11`: Resolving Nine GitHub Issues (`#17`–`#25`)

`v0.2.11` addressed nine issues reported against real Elixir and Erlang projects. A huge thank-you to the community contributor who filed these sharp, reproducible reports (`#17`–`#25`, as well as several earlier issues)—that kind of detailed feedback from real-world usage is what turns edge cases into permanent test coverage. Looking at all nine issues together, they fell into three clear buckets:

### 2.1 Elixir `elixir_v1` AST & Struct Clause Ordering (`#17`, `#18`, `#19`, `#22`)

Because Prisma translates Elixir's `elixir_v1` debug info directly rather than relying on `abstract_code` (which strips macro context metadata), every Elixir special form or sugar not explicitly handled in `prisma_elixir:translate_expr/1` fell through to a fallback local call:

* **`#17` — Zero-argument remote calls vs. map field reads:** `{{'.', _, [Target, Field]}, _, []}` was unconditionally translated to `erlang:map_get(Field, Target)`. When `Target` was a module atom or alias (e.g., `Helper.val()`), it became a map read instead of a remote call `Helper:val()`. Module targets now emit `{remote, ...}` calls, while expression targets emit `erlang:map_get/2`.
* **`#18` — `try/after` and `receive`:** Neither special form was handled in `translate_expr/1`, so compiled Elixir `try/after` and `receive` blocks turned into phantom local calls (`Mod:'try'/1`, `Mod:'receive'/1`) and lost return-type inference. Both now translate to proper Erlang `try` and `receive` AST nodes.
* **`#22` — Bitstring segment `size(...)`:** `<<x::size(n)>>` emitted a phantom `erlang:size/1` call inside binary segments instead of extracting the size expression into the Erlang `bin_element` size slot.
* **`#19` — Struct clause before plain-map clauses:** A `%MyStruct{}` pattern is a map with `'__struct__' := MyStruct`, but `prisma_infer` treated it as covering `any_map`, causing subsequent reachable plain-map clauses (`%{k: v}` or `when is_map(v)`) to report false `dead_code`. Struct patterns no longer shadow plain-map clauses.

### 2.2 Overloaded Specs and BIF Discrepancy Deduplication (`#23`, `#24`)

* **`#23` — Overloaded `@spec`s in hybrid mode:** A function with multiple overloaded specs (e.g., `f(integer()) :: integer(); f(atom()) :: atom()`) could silently pass hybrid analysis even when its implementation returned a type outside every declared overload. `prisma_checker` now checks that the inferred return type is compatible with the union of declared overload return types.
* **`#24` — Duplicate `discrepancy` for `abs/1`:** When the OTP `.pplt` table was loaded, a single invalid `abs/1` call emitted two `discrepancy` warnings (one from `prisma_infer`'s BIF check and one from `prisma_checker`'s external-spec check). The duplicate is now deduplicated.

### 2.3 Mix Task & PPLT Integrity (`#20`, `#21`, `#25`)

* **`#20` — Stale dependency `.pplt` in the same Mix env:** Recompiling a dependency in the same Mix environment could reuse an incompatible `.pplt` file. `prisma_lock` now validates dependency source/BEAM fingerprints and invalidates stale tables cleanly.
* **`#21` — Unreadable implicit Elixir `.pplt`:** Just like `#11` previously fixed for explicit dependency `.pplt`s, an unreadable implicit Elixir `.pplt` silently dropped type information and turned real mismatches into clean passes. It now surfaces the error instead of failing open.
* **`#25` — OTP tables from Mix (`mix prisma`):** Added support for requesting and verifying OTP application tables directly from the Mix task configuration and CLI.

---

## 3. Closing the Gap: A PropEr Suite for Compiled Elixir (`prop_prisma_elixir`)

Looking at `#17`, `#18`, `#19`, and `#22` together made one pattern obvious: our existing PropEr suite (`prop_prisma_infer` and `prop_prisma_type`) generated Erlang forms, so gaps in `prisma_elixir`'s `elixir_v1` translation were only discovered when users hit them in the wild.

Right after `v0.2.11`, we added [`test/prop_prisma_elixir.erl`](https://github.com/altenwald/prisma/blob/main/test/prop_prisma_elixir.erl), which:

1. Compiles real Elixir modules in-memory with `'Elixir.Code':compile_string/1`.
2. Executes `Mod:run()` at runtime and analyzes the compiled `.beam`s with `prisma:analyze_beams/2`.
3. Asserts three invariants across Elixir constructs (`case`, `cond`, `with`, `for`, `try/after`, `receive/after`, `<<x::size(...)>>`, zero-arity remote calls vs. `m.k`, and struct-vs-map clauses) with both valid and intentionally incompatible `@spec`s:
   * Zero phantom calls (`Mod:'try'`, `'receive'`, `'for'`, `'with'`, `'cond'`, `erlang:size`).
   * Runtime return value is a member of `inferred_type` (`prisma_oracle:member/2`).
   * `gradual_mismatch` fires if and only if the `@spec` is incompatible, with no false `discrepancy` or `dead_code`.

On its very first runs, `prop_prisma_elixir` immediately uncovered two more gaps that are now fixed in `v0.2.11` (republished with `--replace`):

* **`cond`, `with`, and `for` in `prisma_elixir`:** All three were missing from `translate_expr/1` and emitted phantom local calls. `cond` now lowers to truthiness-preserving `case` chains, `with` to `case` chains with `else` handling, and `for` to `lc`/`bc` comprehensions (including `into:` and `reduce:` via `lists:foldl/3`).
* **`erlang:map_get/2` in `prisma_infer`:** Field reads like `m.k` translated to `erlang:map_get(:k, m)`, which lacked entries in `bif_signature/2` and `bif_return_type/4`, causing `m.k` to infer `any` and miss `@spec` mismatches. `map_get/2` now resolves the field type directly from `{map, Fields}` and map unions.

With those fixes in place, the test suite stands at **311/311 EUnit tests** and **19/19 PropEr properties** (including **100/100** cases in `prop_prisma_elixir`).

---

## 4. Still on the Roadmap

The three longer-term items from our earlier roadmap remain open:

1. **Nominal Types (`-nominal`, EEP-69 / OTP 28+):** Parsed as `kind = nominal`, still expanded structurally.
2. **Native Records (`-record #name{}`, EEP-79 / OTP 29+):** Not yet extracted or checked.
3. **Value-Correlated Spec Overloads & Formalization:** Dispatch correlations like `rabbit_ff_controller:run_callback/5` and the standalone `TYPESYSTEM.md` / Lean 4 / Rocq formalization.
