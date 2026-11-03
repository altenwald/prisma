#!/usr/bin/env python3
"""Runs the analyzers over the mutants made by mutate.escript and counts what each one detects.

    run_mutants.py <mutants-dir> [--workers N]

For each mutant the mutated .beam replaces the original in a scratch copy of its ebin directory, and Prisma
(contracts on, oxbow off) and Dialyzer (default warnings) analyze that directory. A tool detects the mutant when it
gives, inside the mutated function, a warning that it did not give for the unmodified directory (module, line, kind).
erlc counts as a third tool, but only warnings that say the code fails (not unused variables, which the mutation causes).
"""
import collections, concurrent.futures as cf, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import adapters  # noqa: E402

COMPILER_FAILS = re.compile(r"failed|eval_failure|nomatch|never|no_clause|bad_")


def prisma(directory):
    out = subprocess.run([adapters.PRISMA, "check", "--format", "json", "--no-color", "--no-oxbow", directory],
                         capture_output=True, text=True)
    try:
        return [(w.get("module"), w.get("line", 0), w["kind"]) for w in json.loads(out.stdout or "[]")]
    except json.JSONDecodeError:
        return None


def dialyzer(directory):
    return [(w["module"], w["line"], w["category"]) for w in adapters.dialyzer([directory])]


TOOLS = {"prisma": prisma, "dialyzer": dialyzer}


def scratch_copy(ebin):
    tmp = tempfile.mkdtemp(prefix="mut-", dir=os.path.join(os.path.dirname(HERE), "bench", "results"))
    target = os.path.join(tmp, "ebin")
    shutil.copytree(ebin, target)
    return tmp, target


def analyze(mutant, mutants_dir, baselines):
    tmp, target = scratch_copy(mutant["ebin"])
    try:
        beam = f"{mutant['module']}.beam"
        shutil.copy(os.path.join(mutants_dir, str(mutant["id"]), beam), os.path.join(target, beam))
        result = {"id": mutant["id"], "operator": mutant["operator"], "module": mutant["module"],
                  "function": mutant["function"], "description": mutant["description"]}
        for name, run in TOOLS.items():
            ws = run(target)
            base = baselines[mutant["ebin"]][name]
            if ws is None:
                result[name] = None
                continue
            new = [w for w in ws if w not in base]
            inside = [w for w in new if w[0] == mutant["module"] and mutant["first_line"] <= w[1] <= mutant["last_line"]]
            result[name] = bool(inside)
            result[name + "_inside"] = inside
            result[name + "_collateral"] = len(new) - len(inside)
        result["erlc"] = any(COMPILER_FAILS.search(w["text"]) for w in mutant["compiler_warnings"])
        return result
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    mutants_dir = sys.argv[1]
    workers = int(sys.argv[sys.argv.index("--workers") + 1]) if "--workers" in sys.argv else 4
    mutants = [json.loads(line) for line in open(os.path.join(mutants_dir, "mutants.jsonl"))]
    baselines = {}
    for ebin in sorted({m["ebin"] for m in mutants}):
        baselines[ebin] = {name: set(run(ebin)) for name, run in TOOLS.items()}
        print(f"baseline {os.path.basename(os.path.dirname(ebin))}: " +
              ", ".join(f"{n} {len(b)}" for n, b in baselines[ebin].items()), flush=True)
    results = []
    with cf.ThreadPoolExecutor(workers) as pool:
        futures = [pool.submit(analyze, m, mutants_dir, baselines) for m in mutants]
        for i, f in enumerate(cf.as_completed(futures), 1):
            results.append(f.result())
            if i % 10 == 0:
                print(f"  {i}/{len(mutants)}", flush=True)
    results.sort(key=lambda r: r["id"])
    with open(os.path.join(mutants_dir, "results.jsonl"), "w") as out:
        for r in results:
            out.write(json.dumps(r) + "\n")
    summarize(results)


def summarize(results):
    ops = sorted({r["operator"] for r in results})
    tools = ["prisma", "dialyzer", "erlc"]
    print("\noperator  mutants  " + "  ".join(f"{t:>9}" for t in tools) + "   union  only-prisma  only-dialyzer")
    for op in ops + ["all"]:
        rs = [r for r in results if op == "all" or r["operator"] == op]
        hit = {t: sum(1 for r in rs if r.get(t)) for t in tools}
        union = sum(1 for r in rs if any(r.get(t) for t in tools))
        only_s = sum(1 for r in rs if r.get("prisma") and not r.get("dialyzer"))
        only_d = sum(1 for r in rs if r.get("dialyzer") and not r.get("prisma"))
        print(f"{op:8}  {len(rs):7}  " + "  ".join(f"{hit[t]:9}" for t in tools) + f"   {union:5}  {only_s:12}  {only_d:13}")
    collateral = collections.Counter()
    for r in results:
        for t in ("prisma", "dialyzer"):
            collateral[t] += r.get(t + "_collateral", 0)
    print("\nnew warnings outside the mutated function (collateral):", dict(collateral))


if __name__ == "__main__":
    main()
