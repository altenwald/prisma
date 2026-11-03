# bench/

Measurements of Spectra on real code. Speed and memory: `../BENCHMARK.md`. Warnings and correctness: `../CORRECTNESS.md`.

- `corpus.config.json`: pinned corpora (repository, commit, ebin directories).
- `adapters.py`: runs one analyzer and prints its warnings as normalized JSON (see its docstring for the categories).
  Tools: `spectra`, `dialyzer`, `xref-unused`, `xref-undefined`. Tools are only ever compared inside a category.
- `triage/<corpus>.json`: one manual verdict per warning (`real`, `false_positive`, `debatable`), so a re-run only asks about new ones.
- `corpus/` and `results/`: checkouts and raw output, ignored by git.

```bash
rebar3 escriptize
python3 bench/adapters.py spectra _build/default/lib/spectra/ebin
```

Property tests (type algebra): `rebar3 as test proper -n 1000`.

Mutation testing (false negatives):

```bash
escript bench/mutate.escript 1 25 bench/results/mut-main <ebin-dir>...   # seed, mutants per operator, output, ebins
python3 bench/run_mutants.py bench/results/mut-main --workers 5
```
