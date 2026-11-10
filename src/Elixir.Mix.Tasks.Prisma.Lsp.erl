%% @doc Mix task (`mix prisma.lsp`): starts the Prisma Language Server (LSP).
-module('Elixir.Mix.Tasks.Prisma.Lsp').

-moduledoc """
Starts the Prisma Language Server (LSP) communicating over standard I/O.

Integrates with editors such as VS Code, Zed, Emacs, and Neovim to provide
real-time static typing, discrepancy checking, and compilation diagnostics
for both Erlang and Elixir without executing runtime code or `-on_load` hooks.

## Usage

```bash
mix prisma.lsp
```
""".

-export([
    '__info__'/1,
    '__mix_recompile__?'/0,
    run/1
]).

-spec '__info__'(atom()) -> term().
'__info__'(attributes) ->
    [
        {behaviour, ['Elixir.Mix.Task']},
        {shortdoc, [<<"Starts the Prisma Language Server (LSP)">>]}
    ];
'__info__'(compile) -> [];
'__info__'(functions) -> module_info(functions);
'__info__'(macros) -> [];
'__info__'(md5) -> module_info(md5);
'__info__'(module) -> ?MODULE;
'__info__'(struct) -> nil;
'__info__'(_) -> [].

-spec '__mix_recompile__?'() -> boolean().
'__mix_recompile__?'() ->
    false.

%% @doc Runs the LSP server.
-spec run([binary() | string()]) -> no_return().
run(_RawArgs) ->
    prisma_lsp_server:start().
