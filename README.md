<p align="center">
  <img src="assets/logo.png" alt="Prisma Logo" width="160">
</p>

# Prisma

> *"If a static analysis tool produces false positives, developers lose confidence and stop using it or disable the checks. When code is flagged as dead, you should be able to kill it with fire with absolute certainty."*  
> — **Fernando "Brujo" Benavides & Laura M. Castro** (*Detecting Oxbow Code in Erlang Codebases with the Highest Degree of Certainty*)

**Prisma** is a fast, hybrid static type analyzer for **Erlang** and **Elixir** that combines the sound pragmatism of **Success Typing**, the contract enforcement of **Gradual Typing**, and portable, modular **`.splt` (Prisma Persistent Lookup Table)** files.

---

## ⚡ The Core Problem & The SPLT Solution

One of the greatest points of friction when running static type analysis on the BEAM (such as with Dialyzer) is managing the PLT (*Persistent Lookup Table*):
- **Monolithic & Slow:** Building PLTs for large Erlang/OTP releases and third-party dependencies can take minutes or even hours.
- **Cache Invalidation:** A small change or rebuilding in a clean CI environment often triggers redundant, full-scale PLT re-analysis.

### The Prisma SPLT Architecture
Prisma introduces the portable, binary **`.splt`** format:
- **Modular & Granular:** Every dependency in `rebar.lock` or `mix.lock`, as well as base Erlang/OTP modules, is compiled into its own isolated `.splt` cache.
- **Zero Redundant Rebuilds:** If a dependency's package name and version have not changed, its `.splt` is loaded directly from the local cache.
- **Sub-Second Merging:** At analysis time, Prisma dynamically merges dependency `.splt` files in-memory in milliseconds, focusing analysis purely on your project's application code.
- **Prisma Hub Ready:** Built-in client support for fetching pre-compiled `.splt` files on-demand for Hex.pm packages and target OTP versions, eliminating the need to compile dependency PLTs locally.

---

## 🎯 Key Features

1. **Hybrid Type Checking Engine:**
   - **Success Typings (Discrepancy Mode):** Evaluates non-crashing execution paths to ensure zero false alarms when calling dynamically compatible functions.
   - **Gradual Subtyping (`~` & `≲`):** Enforces developer contracts (`@spec` and `-spec`), identifying mismatches between declared contracts and inferred types (e.g. recursive calls violating `pos_integer()`, unhandled error shapes, or improper map fields).
   - **Dead Code Detection:** Highlights unreachable branches and impossible clause guards (`when ...`) using abstract domain satisfaction.

2. **Native Multi-Language Support (BEAM Ecosystem):**
   - Direct support for Erlang Abstract Format and Elixir `Dbgi` / `elixir_v1` chunks.
   - Built-in recognition of Elixir constructs: structs (`%Mod{}`), keyword lists (`[key: val]`), atoms (`:ok`), strings (`String.t()`), and maps (`%{...}`).

3. **Modern Formats & ANSI Styling:**
   - **`human` / `pretty`** (default): Indented, colorized diagnostics highlighting exact discrepancies between declared and inferred types.
   - **`oneline`**: Compact `Module:Line: [kind] MFA: message` format ideal for editor linters (VS Code, Vim, Emacs) and CI log parsers.
   - **`json`**: Structured JSON output for automated pipelines, bot comments, and dashboard aggregators.
   - **Strict `NO_COLOR` Compliance:** Automatically respects the `NO_COLOR` environment variable or `--no-color` / `--color` flags.

---

## 🛠️ Usage

Prisma is designed to integrate seamlessly into both **Erlang** (via Rebar3) and **Elixir** (via Mix) workflows, as well as running as a standalone command-line executable.

---

### 1. Rebar3 Plugin (Erlang)

Add Prisma to your `rebar.config` under `project_plugins`:

```erlang
{project_plugins, [
    {prisma, "~> 0.1.0"}
]}.
```

Or reference the Git repository directly:

```erlang
{project_plugins, [
    {prisma, {git, "https://github.com/altenwald/prisma.git", {branch, "main"}}}
]}.
```

#### Running Analysis

Run `rebar3 prisma` inside your project:

```bash
# Basic check (automatically compiles and analyzes project apps against locked .splt deps)
rebar3 prisma

# Output format: human (default), oneline (for editor linters), or json (for CI)
rebar3 prisma --format oneline
rebar3 prisma --format json

# Analysis mode: hybrid (default), gradual, or discrepancy
rebar3 prisma --mode gradual
rebar3 prisma --mode discrepancy

# Color control
rebar3 prisma --no-color
rebar3 prisma --color

# Oxbow code detection (unused private functions and ignored parameters)
rebar3 prisma --no-oxbow
```

#### Project Configuration (`rebar.config`)

You can set project-wide defaults under the `{prisma, [...]}` key in `rebar.config`. CLI arguments override these settings:

```erlang
{prisma, [
    {mode, hybrid},         %% hybrid | gradual | discrepancy
    {format, human},        %% human | oneline | json
    {oxbow, true},          %% true | false (detect dead functions and ignored parameters)
    {color, auto},          %% auto | always | never
    {plts, ["custom.splt"]} %% optional extra .splt files to include
]}.
```

#### Exit Codes

- `0`: Analysis succeeded with 0 warnings.
- `1`: Type discrepancies, gradual contract mismatches, or oxbow code were detected.

---

### 2. Mix Task (Elixir)

Add Prisma to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:prisma, "~> 0.1.0", only: [:dev, :test], runtime: false}
  ]
end
```

Or reference the Git repository:

```elixir
def deps do
  [
    {:prisma, github: "altenwald/prisma", only: [:dev, :test], runtime: false}
  ]
end
```

#### Running Analysis

Run `mix prisma` inside your Elixir project:

```bash
# Basic check (automatically ensures compilation and analyzes your app)
mix prisma

# Output format: human (default), oneline (for editor diagnostics), or json (for CI tools)
mix prisma --format oneline
mix prisma --format json

# Analysis mode: hybrid (default), gradual, or discrepancy
mix prisma --mode gradual

# Color control
mix prisma --no-color
mix prisma --color

# Oxbow code detection
mix prisma --no-oxbow

# Target specific Mix environment (defaults to dev or $MIX_ENV)
mix prisma --env test
```

#### Project Configuration (`mix.exs`)

Configure project-level defaults directly in `mix.exs`:

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    prisma: [
      mode: :hybrid,        # :hybrid | :gradual | :discrepancy
      format: :human,       # :human | :oneline | :json
      oxbow: true,          # true | false
      color: :auto,         # :auto | :always | :never
      plts: []              # optional extra .splt paths
    ],
    deps: deps()
  ]
end
```

#### Built-in Task Documentation

Prisma integrates with Mix's help system. View options directly in your terminal:

```bash
mix help prisma
```

---

### 3. Standalone CLI Executable

You can also build and install Prisma as a standalone escript:

```bash
git clone https://github.com/altenwald/prisma.git
cd prisma
rebar3 escriptize
./_build/default/bin/prisma check
```

#### CLI Options

```bash
# Check current directory (auto-detects rebar.lock or mix.lock)
prisma check

# Formats
prisma check --format human
prisma check --format oneline
prisma check --format json

# Color control (also respects standard NO_COLOR environment variable)
prisma check --no-color
NO_COLOR=1 prisma check

# Analyze specific BEAM directories against a custom SPLT
prisma check --splt /path/to/project.splt _build/default/lib/*/ebin
```

---

## 📈 Benchmarks

Real-world benchmark on **RabbitMQ** (438,000+ lines of Erlang, 440 core modules tested with `hyperfine 2.0.0` on Apple M1, macOS, Erlang/OTP 29):

| Suite | Prisma Wall Time | Dialyzer Wall Time | Speedup | Peak RAM (Prisma vs Dialyzer) |
| :--- | :---: | :---: | :---: | :---: |
| **Broker Core** (`rabbit`, 245 modules) | **856.2 ms** | 8,781.6 ms | **10.3× faster** | **319.4 MiB** vs 372.5 MiB |
| **Full Core** (440 modules across 7 apps) | **3.922 s** | 20.722 s | **5.3× faster** | **441.0 MiB** vs **1,286.8 MiB** (2.9× less RAM) |

See the complete telemetry, CPU metrics, and reproduction instructions in [BENCHMARK.md](BENCHMARK.md).

---

## 🧪 Testing & Code Quality

Run the test suite and coverage analysis:

```bash
rebar3 eunit
rebar3 cover
```

---

## 📄 License

Prisma is licensed under the Apache 2.0 License.
