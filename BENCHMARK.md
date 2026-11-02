# Spectra vs Dialyzer Benchmark: RabbitMQ

This document details the comparative performance benchmark between **Spectra** and **Dialyzer** conducted on the **RabbitMQ** codebase.

---

## 🖥️ Benchmark Environment

| Parameter | Specification |
| :--- | :--- |
| **Hardware** | Apple MacBook Pro (`MacBookPro17,1`) |
| **Processor** | Apple M1 (8 cores: 4 performance + 4 efficiency) |
| **Memory** | 16 GB Unified LPDDR4X RAM |
| **Operating System** | macOS 27.0.1 (`Darwin arm64`) |
| **Erlang/OTP Runtime** | Erlang/OTP 29 (`erts-17.1.1`, 64-bit, SMP, JIT enabled) |
| **Elixir Runtime** | Elixir 1.20.4 |
| **Benchmarking Tool** | [`hyperfine 2.0.0`](https://github.com/sharkdp/hyperfine) with `--metrics all` |

---

## 📦 Software Under Test

### Target Application: RabbitMQ Server Monorepo
* **Repository**: [`https://github.com/rabbitmq/rabbitmq-server`](https://github.com/rabbitmq/rabbitmq-server)
* **Target Commit**: [`5dacb8531807bc4162ce36b210d50bc85b15801e`](https://github.com/rabbitmq/rabbitmq-server/commit/5dacb8531807bc4162ce36b210d50bc85b15801e) (`main` branch)
* **Codebase Scale**: 1,310 Erlang modules, 438,156 lines of code (LoC)

### Static Analyzers Compared
1. **Spectra `0.1.0`** (Commit [`c403769`](https://github.com/altenwald/spectra/commit/c403769)): Standalone binary built via `rebar3 escriptize`.
2. **Dialyzer (Erlang/OTP 29 built-in)**: Pre-warmed with base PLT for `erts`, `kernel`, and `stdlib`. Ran with `--no_check_plt`.

---

## 🔬 Benchmark Methodology

All benchmarks were conducted using `hyperfine 2.0.0` with:
- Dedicated warm-up runs (`--warmup 1`) to prime filesystem caches and kernel page tables.
- Multiple measured executions (`--runs 3` to `--runs 5`) to ensure statistical confidence.
- Kernel-level telemetry via `--metrics all` capturing wall-clock time, user CPU time, system CPU time, peak resident set size (RSS memory), CPU cycles, and retired instruction counts.
- Exit code filtering via `--ignore-failure` to allow both analyzers to report all discovered discrepancies without interrupting execution.

---

## 📊 Benchmark Results

### Benchmark 1: Core Broker (`rabbit`, 245 BEAM modules)

Analysis performed exclusively on RabbitMQ's primary broker server application (`deps/rabbit/ebin`).

#### Command
```bash
hyperfine --metrics all --runs 5 --warmup 1 --ignore-failure \
  -n "Spectra"  "spectra check /path/to/rabbitmq-server/deps/rabbit/ebin" \
  -n "Dialyzer" "dialyzer --no_check_plt /path/to/rabbitmq-server/deps/rabbit/ebin"
```

#### Results Summary

| Metric | Spectra | Dialyzer | Relative Performance |
| :--- | :---: | :---: | :--- |
| **Wall-Clock Time** (mean ± σ) | **856.2 ms** ± 48.7 ms | **8,781.6 ms** ± 894.5 ms | **Spectra is 10.3× faster** |
| **Wall-Clock Range** (min … max) | 819.3 ms … 924.1 ms | 7,613.0 ms … 9,529.7 ms | Dialyzer has higher variance |
| **Total CPU Time** | **1.011 s** | **28.420 s** | **Dialyzer uses 28.1× more CPU time** |
| **User CPU Time** | **740.9 ms** | **25,734.4 ms** | 34.7× more compute cycles in Dialyzer |
| **System CPU Time** | **270.1 ms** | **2,686.0 ms** | 10.0× more kernel syscall overhead |
| **Peak Memory (RSS)** | **319.4 MiB** | **372.5 MiB** | Spectra saves 53.1 MiB RAM (+16.6%) |
| **CPU Cycles** | **2.96 B** | **74.5 B** | Dialyzer consumed 25.1× more CPU cycles |
| **Instructions Retired** | **7.59 B** | **177.5 B** | Dialyzer executed 23.4× more instructions |

---

### Benchmark 2: Core Monorepo Apps (440 BEAM modules)

Analysis performed across RabbitMQ's primary ecosystem applications:
- `rabbit` (Broker server)
- `rabbit_common` (Common libraries and records)
- `ra` (Raft consensus engine)
- `khepri` (Hierarchical tree database engine)
- `cuttlefish` (Configuration schema parser)
- `ranch` (Socket acceptor pool)
- `cowlib` (HTTP/WebSocket support library)

#### Command
```bash
hyperfine --metrics all --runs 3 --warmup 1 --ignore-failure \
  -n "Spectra (440 modules)"  "spectra check $(ls -d /path/to/rabbitmq-server/deps/{rabbit,rabbit_common,ra,khepri,cuttlefish,ranch,cowlib}/ebin)" \
  -n "Dialyzer (440 modules)" "dialyzer --no_check_plt $(ls -d /path/to/rabbitmq-server/deps/{rabbit,rabbit_common,ra,khepri,cuttlefish,ranch,cowlib}/ebin)"
```

#### Results Summary

| Metric | Spectra (440 modules) | Dialyzer (440 modules) | Relative Performance |
| :--- | :---: | :---: | :--- |
| **Wall-Clock Time** (mean ± σ) | **3.922 s** ± 0.112 s | **20.722 s** ± 0.461 s | **Spectra is 5.3× faster** |
| **Wall-Clock Range** (min … max) | 3.799 s … 4.018 s | 20.223 s … 21.132 s | Low standard deviation across runs |
| **Total CPU Time** | **4.046 s** | **75.648 s** | **Dialyzer uses 18.7× more CPU time** |
| **User CPU Time** | **3.544 s** | **68.279 s** | 19.3× more compute time in Dialyzer |
| **System CPU Time** | **501.7 ms** | **7,368.8 ms** | 14.7× more kernel overhead |
| **Peak Memory (RSS)** | **441.0 MiB** | **1,286.8 MiB (~1.3 GB)** | **Dialyzer uses 2.9× more peak memory** |
| **CPU Cycles** | **12.1 B** | **196.4 B** | Dialyzer consumed 16.2× more CPU cycles |
| **Instructions Retired** | **41.2 B** | **470.6 B** | Dialyzer executed 11.4× more instructions |

---

## ⏱️ Cold-Start Penalty Consideration

Dialyzer requires a pre-built Persistent Lookup Table (PLT) containing Erlang/OTP base applications (`erts`, `kernel`, `stdlib`) prior to running any project analysis:

```bash
dialyzer --build_plt --apps erts kernel stdlib
```

On this benchmark hardware, building Dialyzer's minimal base PLT required **13.80 seconds** of dedicated compute time before any RabbitMQ module could be checked.

| Analyzer | Cold-Start Setup | Project Analysis (440 mods) | Total Cold-Start Time |
| :--- | :---: | :---: | :---: |
| **Spectra** | **0.00 s** (Modular `.splt` loading on-demand) | **3.92 s** | **3.92 s** |
| **Dialyzer** | **13.80 s** (Monolithic PLT creation) | **20.72 s** | **34.52 s** |

In continuous integration (CI) environments running clean, non-cached containers, **Spectra is 8.8× faster from cold clone to complete verification**.

---

## 📌 Key Insights

1. **Sub-Second Feedback Loop**: For individual applications containing hundreds of modules (such as `rabbit` with 245 modules), Spectra delivers complete results in **856 milliseconds**, enabling true save-time editor feedback compared to Dialyzer's ~9 seconds.
2. **CPU Efficiency**: Dialyzer expended **75.6 seconds of cumulative core time** on the 440-module suite due to recursive fixpoint refinements over whole-program control-flow graphs. Spectra completed equivalent success and gradual verification in **4.0 seconds of CPU time** (an 18.7× reduction in compute overhead).
3. **Memory Footprint**: Spectra capped its memory utilization at **441 MiB** during the 440-module analysis, whereas Dialyzer scaled up to **1,286.8 MiB (~1.3 GB)**, making Spectra significantly safer for memory-constrained CI runners and containerized developer workstations.
