# Spectra

> *"If a static analysis tool produces false positives, developers lose confidence and stop using it or disable the checks. When code is flagged as dead, you should be able to kill it with fire with absolute certainty."*  
> — **Fernando "Brujo" Benavides & Laura M. Castro** (*Detecting Oxbow Code in Erlang Codebases with the Highest Degree of Certainty*)

**Spectra** is a fast, hybrid static type analyzer for **Erlang** and **Elixir** that combines the sound pragmatism of **Success Typing**, the contract enforcement of **Gradual Typing**, and portable, modular **`.splt` (Spectra Persistent Lookup Table)** files.

---

## ⚡ The Core Problem & The SPLT Solution

One of the greatest points of friction when running static type analysis on the BEAM (such as with Dialyzer) is managing the PLT (*Persistent Lookup Table*):
- **Monolithic & Slow:** Building PLTs for large Erlang/OTP releases and third-party dependencies can take minutes or even hours.
- **Cache Invalidation:** A small change or rebuilding in a clean CI environment often triggers redundant, full-scale PLT re-analysis.

### The Spectra SPLT Architecture
Spectra introduces the portable, binary **`.splt`** format:
- **Modular & Granular:** Every dependency in `rebar.lock` or `mix.lock`, as well as base Erlang/OTP modules, is compiled into its own isolated `.splt` cache.
- **Zero Redundant Rebuilds:** If a dependency's package name and version have not changed, its `.splt` is loaded directly from the local cache.
- **Sub-Second Merging:** At analysis time, Spectra dynamically merges dependency `.splt` files in-memory in milliseconds, focusing analysis purely on your project's application code.
- **Spectra Hub Ready:** Built-in client support for fetching pre-compiled `.splt` files on-demand for Hex.pm packages and target OTP versions, eliminating the need to compile dependency PLTs locally.

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

## 🚀 Installation & Building

Spectra is built with **Rebar3**:

```bash
git clone https://github.com/altenwald/spectra.git
cd spectra
rebar3 compile
rebar3 eunit
rebar3 escriptize
```

The resulting standalone executable will be located at:
```bash
./_build/default/bin/spectra
```

---

## 🛠️ Usage

### Running Spectra CLI

Check the current project (automatically detects `rebar.lock` or `mix.lock` and isolates application code from dependencies):

```bash
spectra check
```

#### Output Formats

```bash
# Pretty multiline output with ANSI colors (default)
spectra check --format human

# Compact one-line format for IDEs and linters
spectra check --format oneline

# Structured JSON output for CI pipelines
spectra check --format json
```

#### Color Control

```bash
# Explicitly disable colors
spectra check --no-color

# Or use the standard NO_COLOR environment variable
NO_COLOR=1 spectra check
```

#### Analyzing Specific Paths or Custom SPLTs

```bash
# Analyze specific ebin directories against a custom SPLT
spectra check --splt /path/to/project.splt _build/default/lib/*/ebin
```

### Running as a Rebar3 Plugin (Erlang)

Add Spectra to your `rebar.config` as a project plugin:

```erlang
{project_plugins, [
    {spectra, "~> 0.1.0"}
]}.
```

Run analysis:

```bash
rebar3 spectra
rebar3 spectra --format oneline
rebar3 spectra --format json
```

Optional project-level defaults in `rebar.config`:

```erlang
{spectra, [
    {mode, hybrid},      %% hybrid | gradual | discrepancy
    {format, human},     %% human | oneline | json
    {oxbow, true},       %% detect dead functions and ignored parameters
    {color, auto}        %% auto | always | never
]}.
```

### Running as a Mix Dependency (Elixir)

Add Spectra to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:spectra, "~> 0.1.0", only: [:dev, :test], runtime: false}
  ]
end
```

Run analysis:

```bash
mix spectra
mix spectra --format oneline
mix spectra --format json
```

Optional project-level defaults in `mix.exs`:

```elixir
def project do
  [
    ...,
    spectra: [
      mode: :hybrid,     # :hybrid | :gradual | :discrepancy
      format: :human,    # :human | :oneline | :json
      oxbow: true,       # detect dead functions and ignored parameters
      color: :auto       # :auto | :always | :never
    ]
  ]
end
```

---

## 🧪 Testing & Code Quality

Run the test suite and coverage analysis:

```bash
rebar3 eunit
rebar3 cover
```

---

## 📄 License

Spectra is licensed under the Apache 2.0 License.
