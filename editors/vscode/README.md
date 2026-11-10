# Prisma Language Server Extension for VS Code / Cursor

Provides real-time static typing, spec verification, and discrepancy diagnostics for **Erlang** and **Elixir** using [Prisma](https://github.com/altenwald/prisma).

## Features

- **Static in-memory analysis**: Validates syntax and types without loading bytecode into memory or executing `-on_load` / module initialization code.
- **Equal Erlang & Elixir support**: Native diagnostics for `.erl`, `.hrl`, `.ex`, and `.exs`.
- **Zero background clutter**: Direct stdio communication without spinning up hidden heavy runtime servers.

## Configuration

In `settings.json`:

```json
{
  "prisma.serverPath": "prisma",
  "prisma.serverArguments": ["lsp"]
}
```

Or using Rebar3 / Mix directly:

```json
{
  "prisma.serverPath": "mix",
  "prisma.serverArguments": ["prisma.lsp"]
}
```
