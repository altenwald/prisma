# Prisma's discrepancy analyzer against Dialyzer

How often the discrepancy analyzer (`mode => discrepancy`, success typing) is right, how it compares with Dialyzer **inside the same category of
warning**, and what that costs in time, CPU and memory. Corpus: RabbitMQ. Harness: [`bench/`](bench/README.md).

The gradual (`-spec` contract) and oxbow checks are a different analyzer with different tools to compare against; they appear here only where they
change the cost of the discrepancy analysis (section 6) or explain a number.

## 1. Summary

| | Prisma (discrepancy) | Dialyzer |
| :--- | :--- | :--- |
| Warnings on `rabbit` (234 modules) | **5**, all true (wrong `-spec`s) | **0** (40 notes) |
| Warnings on 7 applications (440 modules) | **45**, all true or defensive | **0** (4 notes) |
| Seeded faults detected (125 mutants) | **125** | 123 |
| New warnings outside the mutated function | **0** | 201 |
| `rabbit`, wall / CPU / peak memory | 1.08 s / 1.25 s / 296 MiB | 6.7 s / 26.0 s / 405 MiB |
| 440 modules, wall / CPU / peak memory | 3.0 s / 3.2 s / 536 MiB | 17.3 s / 67.5 s / 1,457 MiB |

Three things to keep in mind when reading it:

- RabbitMQ runs Dialyzer in its own CI, so zero warnings from Dialyzer is the expected answer. Every warning Prisma gives there is a false positive or
  something Dialyzer cannot see. The first run gave 51 and 44 of them were false positives; the work below is what took them to zero.
- The correctness work cost speed. Over the same code the analysis is **55% slower** than at the start (0.71 s to 1.08 s, user CPU +60%, memory +1% to +11%),
  and no feature was added that Dialyzer lacks to explain it: it is the price of looking inside more constructs and of trusting declared `-spec`s (section 6).
- Everything is one corpus on one machine. A second corpus (Elixir, a different style of Erlang) has not been measured.

## 2. Method and environment

| Parameter | Specification |
| :--- | :--- |
| Hardware | Apple MacBook Pro (`MacBookPro17,1`), Apple M1 (8 cores), 16 GB |
| OS | macOS 27.0.1 (`Darwin arm64`) |
| Erlang/OTP | 29 (`erts-17.1.1`, JIT) |
| Benchmark tool | [`hyperfine 2.0.0`](https://github.com/sharkdp/hyperfine) with `--metrics all`, 1 warm-up, 5 runs (3 for the 440 modules) |
| Corpus | [rabbitmq-server `5dacb85`](https://github.com/rabbitmq/rabbitmq-server/commit/5dacb8531807bc4162ce36b210d50bc85b15801e) (`bench/corpus.config.json`): `rabbit` (234 modules) and 7 applications (`rabbit`, `rabbit_common`, `ra`, `khepri`, `cuttlefish`, `ranch`, `cowlib`: 440 modules) |
| Prisma | commit `464afae`, discrepancy mode through the API (`mode => discrepancy, oxbow => false`: the escript has no `--mode` option yet, task #15) |
| Dialyzer | OTP 29, `--no_check_plt`, default warnings, base PLT of `erts`, `kernel`, `stdlib` |
| xref | undefined calls and unused locals, with the dependencies on the code path |

Tools are only compared inside a category. `prisma check` mixes four kinds of warning (discrepancy, gradual contract, dead code, oxbow) and Dialyzer
reports the first plus some dead code, so the full counts of the two are not comparable. `bench/adapters.py` normalizes each tool's output.

## 3. Correctness

### 3.1 What each tool says

| Corpus | Prisma (discrepancy mode) | Dialyzer | xref (undefined calls) |
| :--- | :--- | :--- | :--- |
| `rabbit` (234 modules) | **5**: 5 dead code | **0** (40 "callback info not available" notes) | 0 |
| 7 applications (440 modules) | **45**: 10 discrepancy, 35 dead code | **0** (4 notes) | 7 |

At the start (same corpus, same mode) the numbers were **51** and **101**.

### 3.2 The false positives, how each was found, and the fix

Every false positive has a minimal reproduction in [`bench/repro/`](bench/repro/README.md) and a test.

| Cause | Found by | Warnings | Fix |
| :--- | :--- | :---: | :--- |
| `[H \| T]` typed as a proper list when it is used as a pair (`?MSG(Index, Header)`) | triage | 37 | an improper cell is `improper_list(H, T)` unless T is known to be a list; `tl/hd`, patterns and `meet` follow |
| `orelse` / `andalso` with a non-boolean right operand | triage | 2 | only the left operand must be boolean; `A andalso B` is `false \| B` |
| overloaded `-spec` across modules: only the first clause counted | triage | 4 | each clause is a whole vector of argument types; a call is accepted if some vector fits |
| `Time == 0` with a float (`==` compares by value) | triage | 1 | `==` is value comparison |
| `X > 0` read as "X is a positive integer" (also true for `0.5` and for any non-number) | triage of the 440 | 3 | `>` and `>=` refine only a variable already known to be a number |
| joining the environments of `A orelse B` kept a constraint from one branch | triage of the 440 | 1 | only variables that every branch constrains keep a type |
| `-1` inferred as `1` (unary minus kept the operand's type) | PropEr | 0 on RabbitMQ | `negate_type/1` |
| `case true andalso 0 of ...`, `case [0 \| 0] of [H \| T] when is_integer(T) -> ...` | PropEr | 0 on RabbitMQ | see above |
| a `fun` typed as `any_fun` clashed with a declared `fun((A) -> B)` | Prisma analyzing itself | 2 | a `fun` stays `any` |
| `{amqp_error, _, _, _}` disjoint from `#amqp_error{}` | RabbitMQ after looking inside `catch` | several | a tuple whose tag is the record's name is a value of the record type |
| unresolved names (`t()`, `other:t()`, opaque, type variable) treated as impossible | Prisma analyzing itself | — | unknown, not impossible |
| `Checksum -> ok; _ -> error` read as a catch-all, so `error` vanished | contract triage | — | only patterns without variables, or with only new variables, subtract in a `case` |
| `any + 1` typed `number` | contract triage | — | an unknown operand gives `any` |
| a function that never returns clashed with a callback type | contract triage | 1 | `none` fits any return in a function-type meet |
| `widen/1` collapsed a union of more than 16 literals to `atom()` (`lookup_method_name/1`, over a hundred method names) | contract triage | 1 | a flat union of literals is kept up to 1024 members |
| a tuple pattern bound its variables from every tuple of the union, not only the matching tag | contract triage | 1 | each alternative is bound on its own and the results are joined |
| `meet(binary(), bitstring())` kept the weaker unit, so `byte_size(Bin)` turned a binary into a bitstring | found after the previous one | 1 | the meet of `<<_:B, _:_*U>>` is the sizes both allow |
| a map pattern against an unknown type claimed the map had only the pattern's keys | contract triage | 41 | it binds a plain `map()` |

One false positive remains known: `rabbit_ff_controller:run_callback/5`, whose `-spec` is overloaded by the value of `Command`. Its code is right, but the return fits neither
overload alone; telling it needs the correlation between the parameter and the spec's clause, which Prisma does not follow.

### 3.3 The true warnings: wrong specs

Each was read against the source, its callers and its docs. None is a bug in the code; they are `-spec`s that contradict a clause that does run.

| Where | What is true |
| :--- | :--- |
| `rabbit_amqp_util:has_capability/2`, clause `(_, undefined)` | its only caller passes a record field that is `undefined` when the peer omits it; the spec only allows `{array, symbol, [...]}` |
| `rabbit_fifo_index:append/2`, clause `(undefined, _)` | `rabbit_fifo_v3:convert_msg/1` builds messages with a dummy index `undefined`; the spec says `integer()` (the sibling `delete/2` already says `integer() \| undefined`) |
| `rabbit_peer_discovery:select_node_to_join/1`, clause `([])` | when the backend already selected a node and it is down, `[]` is passed; the spec says `nonempty_list(...)` |
| `rabbit_definitions:import_parsed/2`, `import_parsed_with_hashing/2` | the arity-1 siblings accept a list, the arity-2 specs say a map of lists; the code accepts a list in both |
| `cuttlefish_error:xlate/1` (24 clauses) | the spec takes 2-tuples and 24 clauses take tuples of 3 or more; the spec was not widened when the alias errors were added |
| `rabbit_misc:amqp_error/4` calls in `rabbit_reader` (7) and `rabbit_channel` (2) | the 4th argument must be an `amqp_method_name()` and the calls pass `none`, the default of the record field |
| `rabbit_data_coercion:to_list_of_binaries/1`, `rabbit_date_time:parse_duration/1`, `cuttlefish_unit:path/2` | a clause the spec leaves out is reachable (certain, certain, probable) |
| `cow_date:pad_int/1`, `khepri_sproc:to_standalone_fun/1`, `rabbit_vhost_limit` (2 clauses) | unproven, defensive, and dead on purpose (the comments say so) |

Dialyzer confirms five of these only with `-Woverspecs` / `-Wunderspecs`, buried in **942 spec-difference warnings** for `rabbit` and **2,229** for the 440 modules;
its default warnings give none. Prisma reports exactly the cases where a spec contradicts a *clause*. The lists are not subsets of each other.

### 3.4 Property-based tests (PropEr)

The oracle is semantic, so no human triage is needed. `rebar3 proper`, 10 properties, all passing.

- **Type algebra** (`test/prop_prisma_type.erl`): `member(Term, Type)` decides whether a concrete term belongs to a ground type, generators build terms of a type. Subtyping is
  reflexive and sound, widening is accepted, `join` is an upper bound, `meet` is sound and keeps common values, union normalization keeps members and is idempotent.
  One limit by design: the type language has no non-empty improper list, so the meet of `improper_list(E, T)` with a `nonempty_list` is a safe superset.
- **Inference and warnings against execution** (`test/prop_prisma_infer.erl`): PropEr generates small well-typed modules (bindings, `case`, integers, floats, booleans,
  atoms, pairs, lists, `[H | T]` cells, overloaded specs, calls from a plain body, a `fun`, a comprehension, a record field and a `try`), compiles and runs them on 25
  samples. The arguments and result must be inside the inferred types, and no `discrepancy` or `dead_code` warning may point at a line that ran without crashing: a line that ran refutes
  a warning that says "this fails". It passes 1,500 programs x 25 runs. Against the sources before each fix it fails (7 to 388 cases), so it does not pass because it went blind.
- **A property is as good as what it generates.** Every real finding the generator missed became a production in it: floats and `==`, comparisons with 0, guards joined
  by `orelse`, record patterns in heads, callers and callees with specs.
- **Self-analysis:** a test analyzes Prisma's own beams and requires 0 warnings. It caught three false positives that the generators did not.

### 3.5 False negatives: mutation testing

`bench/mutate.escript` injects **one** fault in the abstract code of a compiled module (keeping every line number); `bench/run_mutants.py` puts the mutant in a copy of
the application's `ebin`, runs the tools, and counts a fault as **detected** when the tool gives, inside the mutated function, a warning it did not give for the unmodified
directory (keyed by module, line, kind and, for Prisma, the type found). `erlc` is counted only for warnings that say the code fails.

| Operator | Fault |
| :--- | :--- |
| `r1` | a function whose `-spec` returns a simple type returns an atom |
| `r2` | a call passes an atom where the callee's `-spec` asks for a simple type |
| `r3` | a BIF gets an argument of the wrong type (`length(foo)`, `byte_size(foo)`...) |
| `r4` | a call to a function that does not exist, in a module of the corpus |
| `r6` | `{Tag, X} = f(...)` with a `Tag` that the `-spec` of `f` never returns |

Sample: seed 1, up to 25 mutants per operator over `ra`, `khepri`, `cuttlefish`, `cowlib` and `ranch` (144 modules): **125 mutants**.

| Operator | Mutants | Prisma at the start | Prisma now | Dialyzer | erlc |
| :--- | :---: | :---: | :---: | :---: | :---: |
| `r1` spec return | 25 | 25 | **25** | 25 | 0 |
| `r2` argument vs spec | 25 | 21 | **25** | 24 | 0 |
| `r3` BIF argument | 25 | 6 | **25** | 24 | 23 |
| `r4` missing function | 25 | 0 | **25** | 25 | 0 |
| `r6` pattern vs spec | 25 | 0 | **25** | 25 | 0 |
| **all** | **125** | **52 (42%)** | **125 (100%)** | **123 (98%)** | **23 (18%)** |

Prisma alone sees two that Dialyzer does not (a call in the generated `conf_parse`, a `byte_size` in `cow_qpack`); Dialyzer alone sees none.

At the start Prisma missed most of what Dialyzer found, and the misses followed one thing: where the fault is. Four gaps, closed one at a time (reproductions in
[`bench/repro/false_negatives/`](bench/repro/false_negatives/README.md)); the same 125 mutants after each:

| Fix | Prisma |
| :--- | :---: |
| before | 52 / 125 |
| 1. look inside `fun`, `try`, `catch`, `receive`, comprehensions, records and binaries | 57 |
| 2. BIFs with arguments of the wrong type inside guards (each test of a guard is checked, even if another alternative saves the clause) | 74 |
| 3. calls to a function that does not exist (`unknown_function`), and calls inside the target of another call | 100 |
| 4. the return type of a call comes from the callee's `-spec` (other modules and the same one) | 124 |
| 5. measurement fix: a line that already warned, now for another type, is a new finding | **125** |

The last miss was not Prisma's. `cuttlefish_unit:generate_config/3` already had a true warning on the line of its return in the unmodified code (`{error, atom(), any()}` is not
`[any()]`); the mutation changed the type to `mutant_atom` and Prisma said so, on the same line and of the same kind, so a comparison on (module, line, kind) took it for the old one.

**A failure is reported where it is and only there.** Dialyzer names every function above the faulty one ("no local return"), without saying why. Prisma must not copy that:
callers trust the declared `-spec` of a callee over what was inferred from its body. Measured on the 125 mutants, the new warnings *outside* the mutated function are **0 for
Prisma and 201 for Dialyzer** (they were 6 for Prisma before gap 4). A unit test covers a fault three calls deep, with specs on the callers and calls from a fun, a try and a comprehension.

What the sample does not say: 125 mutants of five kinds injected on purpose are not the distribution of real bugs; "must fail" is by contract or by BIF, so a mutant on code that is never
reached still counts; and Dialyzer ran with its default warnings and the erts/kernel/stdlib PLT. The first version of the runner looked for warnings between the first and last line
of the function and missed Dialyzer's invalid-spec warnings, which sit on the `-spec` line; it was caught by looking at the mutants one by one before the big batch.

### 3.6 Precision lost, and limits

- `hd([])` is no longer reported: the type has no "non-empty improper list" to tell it from `hd([1 | 2])` (the compiler already warns about it). In exchange `tl(X) + 1` is no longer a false `badarith`.
- Two `rabbit_vhost_limit` clauses (`{ok, Limit} when Limit < 0`, dead on purpose) are no longer reported: seeing them needs "a float that is not negative", which the type language lacks. The sound answer is "cannot tell".
- What a `fun`, `try`, `receive` or comprehension binds does not reach the code after it (patterns inside bind to `any`, the result is `any`): faults that depend on those values are missed.
- The exact meet of two improper lists with list-able tails is cut at depth 2 and then a safe superset (without the cut the PLT of OTP's `compiler` took minutes).
- In the gradual check, a value known only by a wide type (`integer()`, `number()`, `[T]`) against a narrower contract (`non_neg_integer()`, `pos_integer()`, `[T, ...]`) is a gap in what is proven, not a contradiction, and is not reported (`prisma_checker:accepts/2`). Literals, floats, atoms, `[]` for a non-empty list and `N - 1` with `N :: pos_integer()` for `pos_integer()` still are.

## 4. Where Prisma and Dialyzer differ

| | Prisma | Dialyzer |
| :--- | :--- | :--- |
| Method | success typing per function plus modular `.pplt` summaries; callers trust the callee's declared `-spec` | whole-program success typing over a monolithic PLT |
| Reports a fault | only in the function that has it | in every function above it ("no local return") |
| Spec vs clause | reported by default (5 on `rabbit`) | only with `-Woverspecs` / `-Wunderspecs`, among 942 |
| Missing function in a known module | `unknown_function` | "unknown functions" list, no per-call location |
| Cold start | none: the `.pplt` of each package is built once per version | base PLT: 13.2 s, 44.7 s of CPU, 768 MiB |
| Seeded faults | 125 / 125 | 123 / 125 |

## 5. Benchmark

All figures: `hyperfine 2.0.0 --metrics all --ignore-failure`, mean of the runs, other applications running on the machine (variance in the tables).

```bash
hyperfine --metrics all --runs 5 --warmup 1 --ignore-failure \
  -n "Prisma (discrepancy)" "bench/discrepancy.sh /path/to/deps/rabbit/ebin" \
  -n "Dialyzer"             "dialyzer --no_check_plt /path/to/deps/rabbit/ebin"
```

### `rabbit` (234 modules)

| Metric | Prisma (discrepancy) | Prisma (all kinds) | Dialyzer |
| :--- | :---: | :---: | :---: |
| Wall time | **1.076 s** ± 0.025 | 1.180 s ± 0.066 | 6.745 s ± 0.206 (**6.3x**) |
| CPU time | **1.251 s** | 1.364 s | 25.991 s (**20.8x**) |
| User / system | 1.005 s / 245 ms | 1.107 s / 257 ms | 23.799 s / 2.192 s |
| Peak memory | **295.5 MiB** ± 8.2 | 287.8 MiB ± 19.8 | 405.1 MiB ± 9.8 (1.4x) |
| Instructions retired | 11.4 B | 12.1 B | 176.1 B (15.4x) |

### 440 modules (7 applications)

| Metric | Prisma (discrepancy) | Prisma (all kinds) | Dialyzer |
| :--- | :---: | :---: | :---: |
| Wall time | **3.020 s** ± 0.106 | 3.376 s ± 0.098 | 17.274 s ± 0.454 (**5.7x**) |
| CPU time | **3.247 s** | 3.569 s | 67.548 s (**20.8x**) |
| User / system | 2.827 s / 420 ms | 3.140 s / 430 ms | 61.703 s / 5.845 s |
| Peak memory | **536.0 MiB** ± 3.2 | 546.1 MiB ± 29.4 | 1,456.7 MiB ± 30.1 (2.7x) |
| Instructions retired | 33.7 B | 36.4 B | 467.2 B (13.9x) |

### Cold start

Dialyzer needs a PLT of the OTP base applications before it can check anything (`dialyzer --build_plt --apps erts kernel stdlib`): **13.2 s**, 44.7 s of CPU, 768 MiB on this machine.
Prisma builds the `.pplt` of a package once per version and loads it on demand.

| Step | Wall | Peak memory | Warnings (all kinds) |
| :--- | :---: | :---: | :---: |
| `build-plt` of the 6 dependency apps of `rabbit` (206 modules, 441 KiB file) | 1.45 s | 344 MiB | n/a |
| `check rabbit` without `--plt` | 1.2 - 1.4 s | 333 - 342 MiB | 177 |
| `check rabbit` with the dependencies' `.pplt` | 1.7 s | 343 - 379 MiB | 221 |

The cache is not free (it adds about 0.4 s) and it changes the result: the extra 44 warnings are calls into the dependencies, checked against their real specs. The "no cold start" of Prisma is
only true when dependencies are not analyzed. Dialyzer was run without the PLT of the dependencies, as above; a run with a full PLT is pending.

Also observed once, not reproduced: `prisma check` over the 100 modules of OTP `stdlib` took 3 min 34 s (207 s of CPU).

## 6. What the correctness work cost

Same corpus, same machine and harness (`rabbit`, discrepancy mode, 5 runs), start of the correctness work (`14226fd`) against now:

| | start | now | |
| :--- | :---: | :---: | :---: |
| Wall time | 0.71 s | 1.08 s | +55% |
| User CPU | 0.62 s | 1.00 s | +60% |
| System CPU | 0.25 s | 0.25 s | equal |
| Peak memory | 281 MB | 284 - 313 MB | +1% to +11% |
| `build-plt` of the 6 dependency apps | 3.9 s, 2.4 MB, 331 MiB | 1.45 s, 441 KiB, 344 MiB | faster, smaller |
| `.pplt` of OTP `compiler` (60 modules) | 0.51 s, 2,065 KiB | ~0.40 s, ~360 KiB | faster, smaller |

The analysis is slower because it does more (it looks inside `fun`, `try`, `receive` and comprehensions, trusts declared specs, subtracts patterns in every `case`, bounds types with `widen/1`); the PLT is smaller
because it no longer keeps the abstract code of each function.

**A performance mistake, how it was found, and what changed.** The fix for improper cells made the inferred type of some recursive functions grow with every pass of the inference.
It was missed because the measurement was `check` on `deps/rabbit` and the PLT of OTP's `compiler`, not the PLT of RabbitMQ's dependencies: building that one went from 3.9 s to 235 s
and the operating system killed the process for its memory. A bisection found one module (`rabbit_binary_parser`) at **48,900 million words once written out** from 9,000 in memory, a factor
of 113,000: Erlang shares equal sub-terms in memory, and `term_to_binary` and any recursion over the type expand them as if it were a tree. Fixes: the members of a union of proper lists
make one `nonempty_list` (a cons distributed over K clauses gave K, K², K³ members); inferred types are bounded by `prisma_type:widen/1` (nesting beyond four levels, and unions of
more than 16 members, become `any`; flat literals up to 1,024); the `.pplt` no longer stores `func_contract.clauses`; `normalize_union/1` has shortcuts for the lists of one or two types
it nearly always gets. Written out and in memory now match on the 440 modules (10 / 10 million words, factor 1.0).

Optimizations tried since, with measurements:

| Idea | Result |
| :--- | :--- |
| hash-consing (a map from id to type) | not built: the types are about 1.8 MB of a 67 MB process, and a perfect table would shrink them 3 to 4 times; type algebra is 13% of the profile; `widen/1` already bounds the explosion |
| caching `declared_return` per callee | no gain (1.479 s to 1.475 s, noise) and it was reverted: eprof counted 1M cheap calls |
| taking the abstract forms from the `debug_info` chunk already read instead of decoding the module again as `abstract_code` (twice per module) | **-8.2%** wall time, identical warnings (`erl_parse:anno_from_term` was 19% of own time in fprof) |
| not re-inferring functions whose callees did not change between passes | not done, task #21 |

The profile (fprof on `rabbit_common`, own time): `prisma_infer` 26%, `erl_parse` 19% before the change above, `lists` 17%, `prisma_type` 13%, `maps` 9.5%.

## 7. Not yet measured, and what is left

- **Gradual contract mismatches** (92 on `rabbit`, 221 on the 440 modules) against Gradualizer and Eqwalizer (tasks #12 and #17). Of the 55 that the return-type-from-spec change added to the hybrid mode,
  all were read: 40 are true by contract (the spec says less than the code), 14 are no longer reported, 1 is the known false positive above.
- **Oxbow** (80 on `rabbit`) against xref's unused locals: xref reports 0 because the compiler already warns on them, so most of the 80 are "ignored parameter" findings with no counterpart.
- **Dialyzer with a full PLT of the dependencies**: this run lacks it, so Dialyzer sees fewer calls.
- **A second corpus**, to know whether the 5 / 45 warnings and 125 / 125 mutants generalize.
- **Speed**: the 55% slowdown (task #21) and the `--mode` option of the escript (task #15).
