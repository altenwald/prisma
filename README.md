<p align="center">
  <img src="assets/prisma.png" alt="Prisma Logo" width="160">
</p>

# Prisma

> *"If a static analysis tool produces false positives, developers lose confidence and stop using it or disable the checks. When code is flagged as dead, you should be able to kill it with fire with absolute certainty."*  
> — **Fernando "Brujo" Benavides & Laura M. Castro** (*Detecting Oxbow Code in Erlang Codebases with the Highest Degree of Certainty*)

**Prisma** is a fast, hybrid static type analyzer for **Erlang** and **Elixir** that combines the sound pragmatism of **Success Typing**, the contract enforcement of **Gradual Typing**, and portable, modular **`.pplt` (Prisma Persistent Lookup Table)** files.

---

## ⚡ The Core Problem & The PPLT Solution

One of the greatest points of friction when running static type analysis on the BEAM (such as with Dialyzer) is managing the PLT (*Persistent Lookup Table*):
- **Monolithic & Slow:** Building PLTs for large Erlang/OTP releases and third-party dependencies can take minutes or even hours.
- **Cache Invalidation:** A small change or rebuilding in a clean CI environment often triggers redundant, full-scale PLT re-analysis.

### The Prisma PPLT Architecture
Prisma introduces the portable, binary **`.pplt`** format:
- **Modular & Granular:** Every dependency in `rebar.lock` or `mix.lock`, as well as base Erlang/OTP modules, has its own isolated `.pplt`.
- **No server:** Prisma looks for the `.pplt` of each locked dependency, in this order: (1) the ones the **library ships at the root of its package**, `deps/<app>/*.pplt` (Mix) and `_build/*/lib/<app>/*.pplt` (where rebar3 puts its dependencies), whatever their names; (2) the one Prisma built before, `_build/<app>_<vsn>.pplt`; (3) a new one, built from the dependency's beams in `_build` and saved there. Nothing is downloaded and there is nothing to keep running.
- **One file per system:** `_build/otp_<release>.pplt` for the OTP applications and `_build/elixir_<version>.pplt` for Elixir. They are made with `prisma build` and passed with `--pplt` (the analysis of a project only builds them if it is asked to).
- **Zero Redundant Rebuilds:** If a dependency's package name and version have not changed, its `.pplt` is loaded directly from `_build/`.
- **Sub-Second Merging:** At analysis time, Prisma dynamically merges dependency `.pplt` files in-memory in milliseconds, focusing analysis purely on your project's application code.

### Publishing a `.pplt` with your library

**Please ship the `.pplt` in your package.** One command compiles the project and writes `<app>_<vsn>.pplt` at the root of each application, made from the beams that were just compiled (not in `priv/`, which is for what ends up in a release, not for checking tools):

```bash
rebar3 prisma build      # Erlang: compiles, then writes my_lib_1.2.3.pplt
mix prisma.build         # Elixir: the same
prisma build             # standalone: from what is already compiled in _build
```

It also leaves in `_build/` the `.pplt` of the dependencies that nobody shipped, which is what the checks use. Add the file to what you upload to Hex, and make the build part of publishing so that the file can never be from another version:

```elixir
# mix.exs
defp package, do: [files: ~w(lib mix.exs README* LICENSE* my_lib_*.pplt)]
defp aliases, do: ["hex.publish": ["prisma.build", "hex.publish"]]
```

```erlang
%% src/my_lib.app.src
{files, ["src", "include", "rebar.config", "README.md", "my_lib_*.pplt"]}
```

In rebar3, run `rebar3 prisma build` right before `rebar3 hex publish`.

The file carries a hash of the sources it was made from and the OTP release. Whoever uses your library **checks** it before trusting it, and leaves it out (with a message) and builds the dependency from its beams if:
- it is **out of date**: the sources of the dependency in `deps/` or `_build/` no longer match the hash (a file from the repository that was not made again, for example);
- it was made with an OTP release that is **too new or too old**: only the one that runs and the two before are used (the same window in which the VM can load a library's beams).

A library without its sources on disk cannot be compared, and its file is trusted. One or more files, with any names, are read from the root of the dependency.

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
# Basic check (automatically compiles and analyzes project apps against locked .pplt deps)
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
    {pplts, ["custom.pplt"]} %% optional extra .pplt files to include
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
      pplts: []              # optional extra .pplt paths
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

# Analysis mode
prisma check --mode discrepancy      # hybrid (default) | gradual | discrepancy

# Analyze specific BEAM directories against a custom PPLT
prisma check --pplt /path/to/project.pplt _build/default/lib/*/ebin

# Errors and warnings: warnings are listed too, but only errors fail the command
prisma check --no-warnings           # only errors
prisma check --warnings-as-errors    # warnings fail too
```

**Errors, warnings and notes.** An *error* is what Prisma proves fails when the code runs: a call or clause that cannot succeed (`discrepancy`), a call to a function that does not exist (`unknown_function`) and a contract that the code contradicts (`gradual_mismatch`). A *warning* is certain or handled but does not fail: dead code (a clause that can never match), an unused parameter (`oxbow_code`), and a call to a missing function inside a `try` that catches every error (`handled_undef`, which would hide a misspelled name for good). Warnings are written `[warning: kind]`. A *note* is something that was not checked, and is only counted (`prisma: N branches that depend on the system were not checked` on stderr). The exit status is not zero only for errors (and for warnings with `--warnings-as-errors`); the JSON output has a `severity` per item.

A call that the code protects itself is not reported. A `case` on what the system has (`erlang:function_exported/3`, `erlang:system_info(otp_release)` and comparisons over it) is decided on the system that runs the analysis: the branch it takes is checked like any other code, because it runs here; the ones it does not take are not checked (they would be judged with the API of this OTP, not the one they are written for) and are counted, and are not dead code either. If the condition cannot be decided (`code:ensure_loaded`, `os:type()`...), nothing that depends on the system is said in any branch. A call in a `try` that catches `error:undef` is not reported either.

---

## 📈 Benchmarks

Real-world benchmark on **RabbitMQ** (438,000+ lines of Erlang, 440 core modules tested with `hyperfine 2.0.0` on Apple M1, macOS, Erlang/OTP 29):

| Suite | Prisma Wall Time | Dialyzer Wall Time | Speedup | Peak RAM (Prisma vs Dialyzer) |
| :--- | :---: | :---: | :---: | :---: |
| **Broker Core** (`rabbit`, 234 modules) | **1.08 s** | 6.75 s | **6.3× faster** | **295.5 MiB** vs 405.1 MiB |
| **Full Core** (440 modules across 7 apps) | **3.02 s** | 17.27 s | **5.7× faster** | **536.0 MiB** vs **1,456.7 MiB** (2.7× less RAM) |

See the correctness review, the comparison with Dialyzer and the complete telemetry in [DISCREPANCIES.md](DISCREPANCIES.md), and the comparison of the gradual check with Gradualizer in [GRADUAL.md](GRADUAL.md).

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
