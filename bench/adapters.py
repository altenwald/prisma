#!/usr/bin/env python3
"""Runs one analyzer over BEAM directories and prints its warnings as normalized JSON.

    BENCH_LIBS=dir1:dir2 (xref only: extra code path, e.g. the dependencies) adapters.py <spectra|spectra-discrepancy|dialyzer|xref-unused|xref-undefined> <ebin_dir>...

Every warning becomes {"tool", "category", "module", "function", "line", "file", "message"} so that
tools can be compared per category (never across categories). Categories:
  discrepancy  a call or clause that cannot succeed          (spectra, dialyzer)
  contract     declared spec and inferred type disagree      (spectra, dialyzer)
  dead_code    unreachable clause or branch                  (spectra, dialyzer)
  unused       private function nobody calls                 (spectra oxbow, dialyzer, xref)
  undefined    call to a function that does not exist        (spectra, xref)
"""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPECTRA = os.path.join(ROOT, "_build/default/bin/spectra")

SPECTRA_KINDS = {
    "discrepancy": "discrepancy",
    "gradual_mismatch": "contract",
    "dead_code": "dead_code",
    "oxbow_code": "unused",
    "unknown_function": "undefined",
    "opacity_violation": "contract",
}

SPECTRA_EBIN = os.path.join(ROOT, "_build/default/lib/spectra/ebin")
API = """{ok, W} = spectra:analyze_dirs(init:get_plain_arguments(), #{mode => discrepancy, oxbow => false}),
io:format("~ts", [spectra_checker:format_warnings(W, #{format => json, color => never})]), halt()."""

def spectra(dirs, discrepancy_only=False):
    # The escript has no --mode (it would be read as a path), so the discrepancy-only run goes through the API.
    if discrepancy_only:
        cmd = ["erl", "-noshell", "-pa", SPECTRA_EBIN, "-eval", API, "-extra", *dirs]
    else:
        cmd = [SPECTRA, "check", "--format", "json", "--no-color", *dirs]
    out = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    for w in json.loads(out.stdout or "[]"):
        yield dict(tool="spectra-discrepancy" if discrepancy_only else "spectra", category=SPECTRA_KINDS.get(w["kind"], w["kind"]),
                   module=w.get("module"), function=w.get("function"), line=w.get("line", 0),
                   file=w.get("file"), message=w.get("message"))

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
    "spectra": spectra,
    "spectra-discrepancy": lambda dirs: spectra(dirs, discrepancy_only=True),
    "dialyzer": dialyzer,
    "xref-unused": xref("locals_not_used", "unused"),
    "xref-undefined": xref("undefined_function_calls", "undefined"),
}

if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in TOOLS:
        sys.exit(__doc__)
    json.dump(list(TOOLS[sys.argv[1]](sys.argv[2:])), sys.stdout, indent=1)
    print()
