#!/usr/bin/env python3
"""Runs Gradualizer over the mutants made by mutate.escript and joins the result with the one of run_mutants.py.

    BENCH_LIBS=dir1:dir2 run_mutants_gradualizer.py <mutants-dir> [--workers N]

Gradualizer checks one module at a time here (see adapters.gradualizer): the mutated beam alone, with the dependencies on the
code path, against the same module unmutated. It detects the mutant when it gives, inside the mutated function, a warning
(line, message) that it did not give for the unmodified module. The mutants where it crashes are counted apart.
"""
import collections, concurrent.futures as cf, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import adapters  # noqa: E402

_cache = {}


def baseline(ebin, module):
    key = (ebin, module)
    if key not in _cache:
        _cache[key] = list(adapters.gradualizer([os.path.join(ebin, module + ".beam")]))
    return _cache[key]


def keyed(ws):
    return {(w["category"], w["line"], w["message"]) for w in ws}


def analyze(mutant, mutants_dir):
    beam = os.path.join(mutants_dir, str(mutant["id"]), mutant["module"] + ".beam")
    base = keyed(baseline(mutant["ebin"], mutant["module"]))
    ws = list(adapters.gradualizer([beam]))
    new = [w for w in ws if (w["category"], w["line"], w["message"]) not in base]
    inside = [w for w in new if w["category"] == "contract" and mutant["first_line"] <= w["line"] <= mutant["last_line"]]
    crashed = any(w["category"] == "crash" for w in ws) and not any(w["category"] == "crash" for w in baseline(mutant["ebin"], mutant["module"]))
    return {"id": mutant["id"], "gradualizer": bool(inside), "gradualizer_inside": [[w["line"], w["message"]] for w in inside],
            "gradualizer_crash": crashed,
            "gradualizer_collateral": len([w for w in new if w["category"] == "contract"]) - len(inside)}


def main():
    mutants_dir = sys.argv[1]
    workers = int(sys.argv[sys.argv.index("--workers") + 1]) if "--workers" in sys.argv else 4
    mutants = [json.loads(line) for line in open(os.path.join(mutants_dir, "mutants.jsonl"))]
    with cf.ThreadPoolExecutor(workers) as pool:
        results = list(pool.map(lambda m: analyze(m, mutants_dir), mutants))
    by_id = {r["id"]: r for r in results}
    joined = [json.loads(line) for line in open(os.path.join(mutants_dir, "results.jsonl"))]
    for r in joined:
        r.update(by_id[r["id"]])
    with open(os.path.join(mutants_dir, "results-gradualizer.jsonl"), "w") as out:
        for r in joined:
            out.write(json.dumps(r) + "\n")
    ops = sorted({r["operator"] for r in joined})
    print("operator  mutants   prisma  gradualizer  dialyzer   only-prisma  only-gradualizer  crashes")
    for op in ops + ["all"]:
        rs = [r for r in joined if op == "all" or r["operator"] == op]
        c = collections.Counter()
        for r in rs:
            c["p"] += bool(r.get("prisma")); c["g"] += r["gradualizer"]; c["d"] += bool(r.get("dialyzer"))
            c["pg"] += bool(r.get("prisma")) and not r["gradualizer"]
            c["gp"] += r["gradualizer"] and not r.get("prisma")
            c["x"] += r["gradualizer_crash"]
        print(f"{op:8}  {len(rs):7}  {c['p']:7}  {c['g']:11}  {c['d']:8}  {c['pg']:11}  {c['gp']:16}  {c['x']:7}")
    print("\nnew warnings outside the mutated function (collateral):", sum(r["gradualizer_collateral"] for r in joined))


if __name__ == "__main__":
    main()
