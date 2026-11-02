# Minimal reproductions of false positives

Each module is a few lines of valid Erlang that Spectra (`mode => discrepancy`) flags although it cannot fail.
Compile with `erlc +debug_info <files>` and analyze the `.beam` files with `spectra:analyze_dirs/2`.

| Files | Spectra says | Why it is wrong |
| :--- | :--- | :--- |
| `improper_list_and_andalso.erl` `b/1` | `tl(Cell)` is `[any()]`, call to `a/1` "does not match" (**fixed**) | the tail of a list cell may be any term (`[H \| T]` is also a pair) |
| `improper_list_and_andalso.erl` `d/0` | (**fixed**) "Clause pattern cannot match" | `A andalso B` returns `B` when `A` is true: it is not a boolean |
| `orelse_non_boolean.erl` `e/1` | (**fixed**) "`orelse` will fail" | only the left operand must be boolean; `X > 0 orelse {false, Reason}` is valid |
| `overloaded_spec_caller.erl` + `overloaded_spec_callee.erl` | `h(non_blocking)` "does not match expected blocking" | overloaded `-spec` clauses: only the first one is used across modules |
| `improper_cell_pattern.erl` | (**fixed**) `f/0` returns `none`, "No case/if clause can match", "guard cannot succeed" | `case [0 \| 0] of [H \| T] when is_integer(T) -> H + T end` returns `0`. Dialyzer only warns that the cons builds an improper list, it does not claim the `case` fails |
| `negative_literal.erl` | `f() -> -1` has return type `1`; `case f() of -1 -> ok end` "No case/if clause can match" | `infer_unop` (`src/spectra_infer.erl`) returns the operand's type for `-`, the sign was lost (fixed: `negate_type/1`) |
