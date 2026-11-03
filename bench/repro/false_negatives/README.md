# Faults Spectra does not report

`caller.erl` makes the same kind of fault in several places; `callee.erl` has `-spec g(integer()) -> ok.`.
Compile with `erlc +debug_info` and analyze both `.beam` files together. Spectra now reports every one of these lines (at the start it reported 5 and 19 only: see CORRECTNESS.md).

| Line | Fault | Reported? | Why (see CORRECTNESS.md) |
| :--- | :--- | :---: | :--- |
| 5  | `callee:g(oops)` in a plain body | yes | |
| 7  | `callee:g(oops)` inside an anonymous `fun` | fixed | calls inside `fun` bodies are not checked |
| 10 | `callee:g(oops)` inside `try ... of` | fixed | calls inside `try` are not checked |
| 14 | `#st{x = callee:g(oops)}` | fixed | calls inside a record field are not checked |
| 16 | `length(oops)` in a guard | fixed | BIF arguments are not checked in guards |
| 19 | `length(oops)` in a body | yes | |
| 21 | `callee:nonexistent(1)` | fixed | a call to a function that does not exist in a known module is not reported |
| 23 | `{ok, V} = callee:h()` when `h/0` returns `ok` | fixed | the return type of a call to another module is `any` |
