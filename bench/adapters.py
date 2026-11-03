#!/usr/bin/env python3
"""Runs one analyzer over BEAM directories and prints its warnings as normalized JSON.

    BENCH_LIBS=dir1:dir2 (xref only: extra code path, e.g. the dependencies) adapters.py <prisma|prisma-discrepancy|dialyzer|gradualizer|xref-unused|xref-undefined> <ebin_dir>...

Every warning becomes {"tool", "category", "module", "function", "line", "file", "message"} so that
tools can be compared per category (never across categories). Categories:
  discrepancy  a call or clause that cannot succeed          (prisma, dialyzer, gradualizer)
  contract     declared spec and inferred type disagree      (prisma, dialyzer, gradualizer)
  dead_code    unreachable clause or branch                  (prisma, dialyzer, gradualizer)
  unused       private function nobody calls                 (prisma oxbow, dialyzer, xref)
  undefined    call to a function that does not exist        (prisma, xref)
"""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRISMA = os.path.join(ROOT, "_build/default/bin/prisma")

PRISMA_KINDS = {
    "discrepancy": "discrepancy",
    "gradual_mismatch": "contract",
    "dead_code": "dead_code",
    "oxbow_code": "unused",
    "unknown_function": "undefined",
    "opacity_violation": "contract",
}

PRISMA_EBIN = os.path.join(ROOT, "_build/default/lib/prisma/ebin")
API = """{ok, W} = prisma:analyze_dirs(init:get_plain_arguments(), #{mode => discrepancy, oxbow => false}),
io:format("~ts", [prisma_checker:format_warnings(W, #{format => json, color => never})]), halt()."""

def prisma(dirs, discrepancy_only=False):
    # The escript has no --mode (it would be read as a path), so the discrepancy-only run goes through the API.
    if discrepancy_only:
        cmd = ["erl", "-noshell", "-pa", PRISMA_EBIN, "-eval", API, "-extra", *dirs]
    else:
        # BENCH_PPLTS=a.pplt:b.pplt gives it the contracts of OTP and of the dependencies (what Gradualizer reads from the code path)
        plts = [x for p in os.environ.get("BENCH_PPLTS", "").split(":") if p for x in ("--pplt", p)]
        cmd = [PRISMA, "check", "--format", "json", "--no-color", *plts, *dirs]
    out = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    for w in json.loads(out.stdout or "[]"):
        yield dict(tool="prisma-discrepancy" if discrepancy_only else "prisma", category=PRISMA_KINDS.get(w["kind"], w["kind"]),
                   module=w.get("module"), function=w.get("function"), line=w.get("line", 0),
                   file=w.get("file"), message=w.get("message"))

GRADUALIZER = os.path.join(ROOT, "bench/tools/gradualizer/bin/gradualizer")

def gradualizer(dirs):
    """Gradualizer, one module at a time: an internal error in one module (a `badmatch` in typechecker:expect_record_type)
    ends the whole run, so a single invocation over a directory stops after the first module that crashes it.
    A module that crashes it is reported as category `crash` (it was not checked). It also needs the types of everything a
    module mentions on the code path: without the dependencies every remote type is "undefined" (2558 warnings on `rabbit`,
    mostly that). BENCH_LIBS=dir1:dir2 adds them."""
    libs = [x for d in os.environ.get("BENCH_LIBS", "").split(":") if d for x in ("-pa", d)]
    beams = sorted(b for d in dirs for b in ([d] if os.path.isfile(d) else
                   [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".beam")]))
    for beam in beams:
        out = subprocess.run([GRADUALIZER, "--no_color", "--fmt_location", "brief", *libs, "--", beam],
                             capture_output=True, text=True)
        module = os.path.basename(beam)[:-5]
        if "in function  typechecker:" in out.stdout + out.stderr or "Task reported error" in out.stdout:
            yield dict(tool="gradualizer", category="crash", module=module, function=None, line=0, file=beam,
                       message="internal error: the module was not (fully) checked")
        blocks = re.split(r"\n(?=\S+\.beam:\d+:\d+: )", out.stdout)
        for b in blocks:
            m = re.match(r"(\S+?\.beam):(\d+):(\d+): (.*)", b, re.S)
            if not m:
                continue
            msg = " ".join(m.group(4).split())[:300]
            yield dict(tool="gradualizer", category="contract", module=module, function=None,
                       line=int(m.group(2)), file=m.group(1), message=msg)

DIALYZER_RULES = [
    (r"Callback info about .* is not available", "note"),
    (r"Function (\S+)/\d+ will never be called|is unused", "unused"),
    (r"can never match|will never be executed|Guard test .* can never succeed|clause", "dead_code"),
    (r"Invalid type specification|contract|spec", "contract"),
    (r"Unknown function|Call to missing", "undefined"),
]

def dialyzer(dirs):
    out = subprocess.run(["dialyzer", "--no_check_plt", *dirs], capture_output=True, text=True)
    blocks = re.split(r"\n(?=\S+\.erl:\d+)", out.stdout)
    for b in blocks:
        m = re.match(r"(\S+?\.erl):(\d+)(?::\d+)?:\s*(.*)", b, re.S)
        if not m:
            continue
        msg = " ".join(m.group(3).split())[:300]
        cat = next((c for pat, c in DIALYZER_RULES if re.search(pat, msg)), "discrepancy")
        yield dict(tool="dialyzer", category=cat, module=os.path.basename(m.group(1))[:-4], function=None,
                   line=int(m.group(2)), file=m.group(1), message=msg)

XREF = r"""
{ok, _} = xref:start(s), xref:set_default(s, [{warnings, false}, {verbose, false}]),
ok = xref:set_library_path(s, code:get_path()),
[{ok, _} = xref:add_directory(s, D) || D <- init:get_plain_arguments()],
{ok, R} = xref:analyze(s, %s),
F = fun({M, N, A}) -> io_lib:format("~w:~w/~w", [M, N, A]) end,
lists:foreach(fun({C, T}) -> io:format("~s\t~s~n", [F(C), F(T)]);
                 ({_,_,_} = X) -> io:format("~s~n", [F(X)]) end, R), halt().
"""

def xref(query, category):
    def run(dirs):
        libs = [x for d in os.environ.get("BENCH_LIBS", "").split(":") if d for x in ("-pa", d)]
        out = subprocess.run(["erl", "-noshell", *libs, "-eval", XREF % query, "-extra", *dirs],
                             capture_output=True, text=True)
        for line in out.stdout.splitlines():
            caller, _, callee = line.partition("\t")
            m, _, rest = caller.partition(":")
            yield dict(tool="xref", category=category, module=m, function=rest.rsplit("/", 1)[0],
                       line=0, file=None, message=line.replace("\t", " -> "))
    return run

TOOLS = {
    "prisma": prisma,
    "prisma-discrepancy": lambda dirs: prisma(dirs, discrepancy_only=True),
    "dialyzer": dialyzer,
    "gradualizer": gradualizer,
    "xref-unused": xref("locals_not_used", "unused"),
    "xref-undefined": xref("undefined_function_calls", "undefined"),
}

if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in TOOLS:
        sys.exit(__doc__)
    json.dump(list(TOOLS[sys.argv[1]](sys.argv[2:])), sys.stdout, indent=1)
    print()
