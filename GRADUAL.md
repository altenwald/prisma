# Prisma's gradual check against Gradualizer

The same method as [`DISCREPANCIES.md`](DISCREPANCIES.md) (RabbitMQ at `5dacb85`, the 125 mutants, hyperfine), applied to the other half of Prisma: the gradual check
of `-spec` contracts (`gradual_mismatch` warnings, hybrid mode) against [Gradualizer](https://github.com/josefs/Gradualizer) (`23533d7`).
Eqwalizer is not compared: it asks for a different thing (everything annotated, no `dynamic()` left by default) and its warnings do not mean the same.

## 1. Summary

| | Prisma | Gradualizer |
| :--- | :--- | :--- |
| Seeded faults detected (125 mutants) | **125** (100%) | 68 (54%) |
| ... that only this tool sees | 57 | 0 |
| Type warnings on `rabbit` (234 modules) | 185 | 551 (+ 2 modules it crashed on) |
| Type warnings on 440 modules | 383 | 1,118 (+ 4 modules) |
| Warnings within 3 lines of one of the other tool | 52 of 185 | 53 of 551 |
| `rabbit`: wall / peak memory | 3.9 s / 614 MiB | 5.4 s / 189 MiB |
| 440 modules: wall / peak memory | 6.8 s / 905 MiB | 35.9 s / 236 MiB |

- Prisma finds every seeded fault and Gradualizer 54%, but Gradualizer says **three times as much** on real code and the two lists barely overlap. **No warning of Gradualizer's has been triaged**
  (1,118 of them); a sample of 14 was read (section 3), and none was a fault: they are strict readings and checks that Prisma does not make.
- Prisma is faster, 1.4x on `rabbit` and 5.3x on the 440 modules, and uses 3 to 4 times more memory.
- Prisma needs the PPLTs of OTP and of the dependencies to know their specs, Gradualizer reads them from the code path. Building them is a one-time cost (section 4).
- Gradualizer stops with an internal error in some modules (`badmatch` in `typechecker:expect_record_type`): 5 of 232 on `rabbit`, 10 of 436 on the 440 modules. A single run over a directory ends at
  the first one, so it was run module by module for the warnings, and in one VM with the crashes caught for the times.

## 2. Method

| Parameter | Specification |
| :--- | :--- |
| Hardware, OS, OTP | as in `DISCREPANCIES.md` (Apple M1, macOS, OTP 29) |
| Prisma | commit `40d802e`, hybrid mode through `prisma check`, with `--pplt` of OTP (16 applications, 599 modules) and of the dependencies |
| Gradualizer | `23533d7`, default options (specs only, no `--infer`), the dependencies on the code path (`-pa`). It does not compile with OTP 29 as it is: its warnings are errors and OTP 29 warns about `P1=P2` patterns; it was built with `ERL_COMPILER_OPTIONS='[nowarn_match_alias_pats]'`, the code untouched |
| Corpus | `rabbit` (234 modules) and 7 applications (440 modules), crash-free copies (symlinks) for the timed runs: 232 and 436 modules |
| Tools of the harness | `bench/adapters.py gradualizer`, `bench/run_mutants_gradualizer.py`, `bench/tools/` (the checkout, ignored by git) |

Without the dependencies on the path every remote type is "undefined" for Gradualizer (2,558 warnings on `rabbit`, almost all of that kind), and without PPLTs Prisma does not know the specs of OTP
or of other applications: both are given what the other one reads by itself. A detection is "a new warning inside the mutated function" (line and message), as before.

## 3. Correctness

### 3.1 Seeded faults

| Operator | Mutants | Prisma | Gradualizer | Dialyzer |
| :--- | :---: | :---: | :---: | :---: |
| `r1` spec return | 25 | **25** | 18 | 25 |
| `r2` argument vs spec | 25 | **25** | 19 | 24 |
| `r3` BIF argument | 25 | **25** | 7 | 24 |
| `r4` missing function | 25 | **25** | 16 | 25 |
| `r6` pattern vs spec | 25 | **25** | 8 | 25 |
| **all** | **125** | **125** | **68** | **123** |

Gradualizer sees nothing that Prisma does not. It gives 28 new warnings outside the mutated function (Prisma 0, Dialyzer 201). What it does not see follows what it checks: it only types the functions
that have a spec, so a BIF with a wrong argument in a function without one (`r3`) or a pattern against the return of an unspecified call (`r6`) go by.

### 3.2 What each says on RabbitMQ

| Corpus | Prisma (type warnings) | Gradualizer |
| :--- | :---: | :---: |
| `rabbit`, 234 modules | 185: 171 contract, 9 discrepancy, 5 dead code | 551 (+ 2 modules crashed) |
| 7 applications, 440 modules | 383: 337 contract, 35 dead code, 10 discrepancy, 1 undefined function | 1,118 (+ 4 modules crashed) |

Their lists agree on little (a warning within 3 lines of one of the other tool, in the same module): 52 of Prisma's 185 and 53 of Gradualizer's 551 on `rabbit`. The other kinds (oxbow, 80 on `rabbit`) have no counterpart.

**Gradualizer's warnings, a sample.** 14 of the 523 that have no Prisma warning nearby, chosen at random, were read. They are of two kinds, and none is a fault in the code:

- strict readings that Prisma tolerates by policy (a possibly empty list against a non-empty one, `undefined | binary()` against `vhost()`, `string()` against an `iolist()` of bytes);
- checks that Prisma does not make: Gradualizer propagates the expected type into every subexpression and reports a mismatch there, and checks calls into OTP and into other applications that Prisma
  only knows if it has their PPLT.

Whether some of the 523 are real faults that Prisma misses is **not known**: it needs reading them (a task of its own), and the mutants do not show such a gap.

### 3.3 Prisma's own false positives: what knowing OTP and the dependencies uncovered

With the PPLTs of OTP and of the dependencies Prisma knows many more specs, and gives 87 contract warnings it did not give without them. Reading them against the sources found **six false positives of
Prisma, fixed, each with a test** (`test/prisma_otp_specs_tests.erl`, the repros in `bench/repro/`):

| Cause | Example | Fix |
| :--- | :--- | :--- |
| a map literal `#{id => a, start => S}` typed with optional keys | `supervisor:start_child/2` (a child spec is rejected) | a literal key is a required field |
| `fun()` (a fun of unknown arity) not consistent with `fun((K, V) -> W)` | `maps:map/2` | `any_fun` fits a fun type |
| a binary known only as `binary()` against `<<_:8, _:_*8>>` or `<<_:_*16>>` | `binary:split/3`, `binary:decode_hex/1` | tolerated like the wide numeric types, when the two can overlap |
| a variable passed to a callee **without** a spec became the callee's inferred domain (`tuple \| none \| map`) | `maps:get/3` after `active_consumer(Cons0)` in `rabbit_fifo` | an unknown variable is not narrowed to a union that came from clauses |
| the return of a polymorphic callee with a type variable as map key: `#{Key := Value, _ => _}` read as "some key" | `maps:update/3` passed to `rabbit_pid_codec:recompose/1` | the result is just a map |
| `meet` of two binary types kept the weaker unit | after `byte_size(Bin)` | (fixed earlier, see `DISCREPANCIES.md`) |

What remains of the 87 is read as **true by contract** (the spec says less than the code: a call that passes `undefined | binary()` where `binary()` is asked, `lists:last/1` of a possibly empty list,
`unicode:characters_to_binary/1` passed on without looking at `{error, ...}`), with one known false positive of another kind: `os:list_env_vars/0` does not exist in OTP 29 and `rabbit_env` calls it guarded by
`erlang:function_exported(os, list_env_vars, 0)`; Prisma does not see the guard. The 9 `rabbit_misc:amqp_error/4` calls with `none` are the wrong spec already described in `DISCREPANCIES.md`.
`rand:uniform/1` with a `non_neg_integer()` (7 calls) is reported on purpose: `N - 1` with `N :: pos_integer()` is `non_neg_integer()` and tolerating it would hide the README example.
Not every one of the 87 was read: the ones read are those above.

## 4. Benchmark

`hyperfine 2.0.0 --metrics all`. Gradualizer ran in **one VM over the whole directory** with a crash caught per module (`bench/results/gr_vm.erl`): started once per module its time is almost
all VM start-up, and run over a directory at once it ends at the first internal error after 0.4 s, which is not a measure. Prisma ran `prisma check` with the PPLTs of OTP and of the dependencies.

| Metric | Prisma, `rabbit` | Gradualizer, `rabbit` | Prisma, 440 | Gradualizer, 440 |
| :--- | :---: | :---: | :---: | :---: |
| Wall time | **3.863 s** ± 0.154 | 5.428 s ± 0.023 | **6.782 s** ± 0.204 | 35.891 s ± 0.038 |
| CPU time | **4.009 s** | 5.690 s | **7.032 s** | 36.148 s |
| Peak memory | 613.7 MiB | **189.3 MiB** | 904.8 MiB | **235.5 MiB** |
| Instructions retired | **38.9 B** | 61.9 B | **70.5 B** | 422.5 B |

Prisma scales much better with the size of the corpus (1.8x the time for 1.9x the modules, against 6.6x for Gradualizer) and uses 3 to 4 times more memory.
Most of Prisma's 3.9 s on `rabbit` is loading the PPLTs (without them the same check takes 1.1 s and 296 MiB, but it knows no spec of OTP).

One-time costs of Prisma, which Gradualizer does not have because it reads the beams of OTP and of the dependencies each time:

| Step | Wall | Peak memory | File |
| :--- | :---: | :---: | :---: |
| `prisma build` of OTP (16 applications, 599 modules) | 7.6 s | 899 MiB | 3.0 MB |
| `prisma build` of `kernel` + `stdlib` only (202 modules) | 2.4 s | 419 MiB | 1.1 MB |
| `prisma build` of the 27 other dependencies of the corpus (644 modules) | 2.4 s | 348 MiB | n/a |

Building the PPLT of `kernel` and `stdlib` did not end in five minutes before this work: four modules (`calendar`, `uri_string`, `file_sorter`, `dist_util`) made the inference ask for meets that grew without
end. The fix is in `DISCREPANCIES.md` (section 6).

## 5. What is not known

- Whether some of Gradualizer's 551 + 1,118 warnings are real faults that Prisma misses. The mutants say there is no gap of the five kinds they inject; only reading the warnings would say more.
- Prisma's `rabbit` warnings with the PPLTs were read in part (section 3.3), not all.
- One corpus, one machine; Gradualizer without `--infer` and with its default specs prelude.
- Gradualizer was built with a compile option for OTP 29; an official build might behave differently, and its internal errors might be fixed upstream.
