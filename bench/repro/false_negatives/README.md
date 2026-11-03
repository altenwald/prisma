# Faults Spectra does not report

`caller.erl` makes the same kind of fault in several places; `callee.erl` has `-spec g(integer()) -> ok.`.
Compile with `erlc +debug_info` and analyze both `.beam` files together. Spectra reports lines 5 and 19 only.

| Line | Fault | Reported? | Why (see CORRECTNESS.md) |
| :--- | :--- | :---: | :--- |
| 5  | `callee:g(oops)` in a plain body | yes | |
| 7  | `callee:g(oops)` inside an anonymous `fun` | **no** | calls inside `fun` bodies are not checked |
| 10 | `callee:g(oops)` inside `try ... of` | **no** | calls inside `try` are not checked |
| 14 | `#st{x = callee:g(oops)}` | **no** | calls inside a record field are not checked |
| 16 | `length(oops)` in a guard | **no** | BIF arguments are not checked in guards |
| 19 | `length(oops)` in a body | yes | |
| 21 | `callee:nonexistent(1)` | **no** | a call to a function that does not exist in a known module is not reported |
| 23 | `{ok, V} = callee:h()` when `h/0` returns `ok` | **no** | the return type of a call to another module is `any` |
