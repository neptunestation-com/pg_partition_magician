#!/usr/bin/env bash
# Prove that each summary job main's ruleset requires (Lint summary, Test Summary, Perf summary) gates every
# other job of its workflow: it needs the job, and its verdict FAILS when that job did not succeed.
#
# WHY THIS GUARD EXISTS (issue #1381, F13-01 and F8-02). lint.yml's core-growth job runs
# scripts/core_growth.py --selftest, whose comment says a measure that has gone blind "fails here". It was
# added to lint.yml and never to the `summary` job's `needs` or its result checks, so a red selftest left
# the only lint check main requires green, printing "Every lint job passed." And test.sh's run_lint, held by
# bench/ci_runs_lint_jobs.sh to that same `needs` list, never ran it: that guard takes the summary's needs as
# the truth, so a job missing from them was missing from both and nothing compared either with the
# workflow's jobs. A summary's `needs` is a hand-kept copy of its workflow's job list, and this holds it to
# the list.
#
# HOW. Every .github/workflows/*.yml is parsed as YAML; a workflow with a job whose id is `summary` is a
# summarised one. In each, for every other job:
#   1. the job is in the summary's `needs`, unless this guard's EXCEPTIONS table names it (test.yml's
#      dbdev-cap, informational by decision, #765); an exception that names a job the workflow lacks, or a
#      job the summary does need, FAILS, so the table cannot go stale;
#   2. the summary runs whatever its needs did (`if: always()`): a summary skipped because a need failed
#      reports as passed to a required check;
#   3. the summary's `run:` steps, RUN (not read) with each `${{ needs.<id>.result }}` rendered, under
#      `bash -e` as GitHub runs a step: with every need `success` every step exits 0, and with any ONE need
#      `failure`, `cancelled` or `skipped` (the rest `success`) some step exits non-zero. A judge line that
#      is missing, that cannot fail, or that accepts a skipped need fails here. A `uses:` step, a `shell:`,
#      or an expression this guard cannot render FAILS rather than being guessed at.
#   LIVENESS  the three summaries main requires were found by name, they gate at least 13 jobs between
#             them, and the step runs numbered at least 40, so a clean result is not a scan of nothing;
#   CONTROL   on a planted workflow, a job missing from the needs, a needed job never judged, a judge
#             that cannot fail, a judge that passes a skipped need, a summary without `if: always()`, and
#             a stale or dangling exception each fail, and the planted workflow as written passes.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   lint_summary_misses_core_growth  -- core-growth out of lint.yml's summary needs and checks: pre-#1381
#   lint_summary_waits_unjudged      -- core-growth in the needs, its result check gone: the summary waits
#                                       for the job and passes whatever it did
#
# Usage: summary_gates_every_job.sh <container> <db> [workflow]
# With no third argument it reads this checkout's workflows; with one, THAT file replaces the workflow of
# the same top-level `name:` (a /repo/... path is mapped to this checkout), which is how
# bench/discriminate.sh points it at a mutant. Needs python3, PyYAML and bash on the host and nothing else;
# <container> and <db> are accepted so discriminate.sh can call it the way it calls every guard, and are
# not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="${3:-}"
WF="${WF/#\/repo\//$ROOT/}"
if [ -n "$WF" ] && [ ! -f "$WF" ]; then printf 'FAIL  %-62s %s\n' "the workflow under test exists" "$WF"; exit 1; fi

python3 - "$ROOT/.github/workflows" "$WF" <<'PY'
import copy, glob, os, re, subprocess, sys, tempfile
import yaml

fail = 0

def say(ok, what, detail=""):
    global fail
    if not ok:
        fail = 1
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}")

# A job a summary deliberately does not gate, by workflow file, with the reason. Each entry must name a job
# the workflow has and the summary does not need, so a stale entry fails instead of excusing a future job.
EXCEPTIONS = {
    "test.yml": {"dbdev-cap": "informational: reports the dbdev package's size against database.dev's "
                              "column and never fails (#765)"},
}
REQUIRED = {"Lint summary", "Test Summary", "Perf summary"}
BAD = ("failure", "cancelled", "skipped")
RESULT = re.compile(r"\$\{\{\s*needs\.([A-Za-z0-9_-]+)\.result\s*\}\}")
ALWAYS = re.compile(r"^\s*(\$\{\{\s*)?always\(\)(\s*\}\})?\s*$")


def run_steps(steps, results):
    """Run a summary's steps as GitHub would with these need results. Returns (job passed, why not)."""
    with tempfile.TemporaryDirectory() as d:
        for i, st in enumerate(steps):
            script = RESULT.sub(lambda m: results.get(m.group(1), ""), st["run"])
            p = subprocess.run(["bash", "-e", "-c", script], cwd=d, env={"PATH": os.environ["PATH"], "HOME": d},
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
            if p.returncode != 0:
                return False, f"step {i + 1} exit {p.returncode}"
    return True, ""


def check(wf, exceptions):
    """Violations of a summarised workflow, and the number of jobs gated and of step runs made."""
    v = []
    jobs = wf.get("jobs") or {}
    summ = jobs.get("summary") or {}
    needs = summ.get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    others = [j for j in jobs if j != "summary"]
    for j, why in exceptions.items():
        if j not in jobs:
            v.append(f"the exception for {j} names a job the workflow does not have")
        elif j in needs:
            v.append(f"the exception for {j} names a job the summary does need: drop the exception")
    for j in others:
        if j not in needs and j not in exceptions:
            v.append(f"job {j} is not in the summary's needs, so it can fail while the summary passes")
    for n in needs:
        if n not in jobs:
            v.append(f"the summary needs {n}, which the workflow does not define")
    if not ALWAYS.match(str(summ.get("if", ""))):
        v.append(f"the summary runs `if: {summ.get('if')}`, not always(): a failed need skips it, and a skipped "
                 "required check reports as passed")
    steps = summ.get("steps") or []
    runs = 0
    usable = bool(steps)
    if not steps:
        v.append("the summary has no steps")
    for st in steps:
        if "run" not in st or "uses" in st or "shell" in st:
            v.append(f"the summary has a step this guard cannot run as GitHub would ({sorted(st)})")
            usable = False
            continue
        left = re.findall(r"\$\{\{.*?\}\}", RESULT.sub("", st["run"]), re.S)
        if left:
            v.append(f"the summary's step has an expression this guard cannot render: {left[0]}")
            usable = False
    gated = 0
    if usable:
        ok, why = run_steps(steps, {n: "success" for n in needs})
        runs += 1
        if not ok:
            v.append(f"with every need `success` the summary fails ({why})")
        for n in needs:
            if n not in jobs:
                continue
            caught = True
            for bad in BAD:
                ok, _ = run_steps(steps, dict({k: "success" for k in needs}, **{n: bad}))
                runs += 1
                if ok:
                    v.append(f"with job {n} `{bad}` and every other need `success`, the summary passes")
                    caught = False
            gated += caught
    return v, gated, runs


# CONTROL: the checks on a planted workflow, before they are trusted with the real ones.
P_WF = {"name": "Planted", "jobs": {
    "alpha": {"steps": [{"run": "true"}]},
    "beta": {"steps": [{"run": "true"}]},
    "informational": {"steps": [{"run": "true"}]},
    "summary": {"name": "Planted summary", "needs": ["alpha", "beta"], "if": "always()", "steps": [{"run":
        '[ "${{ needs.alpha.result }}" = "success" ] || { echo "alpha failed"; exit 1; }\n'
        '[ "${{ needs.beta.result }}" = "success" ] || { echo "beta failed"; exit 1; }\n'
        'echo "Every job passed."\n'}]}}}
P_EXC = {"informational": "planted"}


def planted(edit=None, exc=None):
    w = copy.deepcopy(P_WF)
    if edit:
        edit(w["jobs"]["summary"])
    return w, P_EXC if exc is None else exc


def sub_run(old, new):
    def f(s):
        s["steps"][0]["run"] = s["steps"][0]["run"].replace(old, new)
    return f


def drop_need(s):
    s["needs"] = ["alpha"]


v, *_ = check(*planted())
say(not v, "CONTROL: the planted workflow as written passes", "; ".join(v) or "no violation")
variants = {
    "a job missing from the needs": planted(lambda s: (drop_need(s), sub_run(
        '[ "${{ needs.beta.result }}" = "success" ] || { echo "beta failed"; exit 1; }\n', "")(s))),
    "a needed job never judged": planted(sub_run(
        '[ "${{ needs.beta.result }}" = "success" ] || { echo "beta failed"; exit 1; }\n', "")),
    "a judge that cannot fail": planted(sub_run('echo "beta failed"; exit 1;', 'echo "beta failed";')),
    "a judge that passes a skipped need": planted(sub_run(
        '"${{ needs.beta.result }}" = "success"', '"${{ needs.beta.result }}" != "failure"')),
    "a summary without if: always()": planted(lambda s: s.pop("if")),
    "an exception for a job the summary needs": planted(exc={"informational": "planted", "beta": "planted"}),
    "an exception for a job the workflow lacks": planted(exc={"informational": "planted", "gamma": "planted"}),
    "an unexcepted job outside the needs": planted(exc={}),
}
caught = [k for k, (w, e) in variants.items() if check(w, e)[0]]
say(len(caught) == len(variants), "CONTROL: each planted divergence fails",
    f"{len(caught)} of {len(variants)}" + ("" if len(caught) == len(variants) else
                                            "; missed: " + ", ".join(k for k in variants if k not in caught)))

wfs = {}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml"))):
    wfs[os.path.basename(path)] = yaml.safe_load(open(path))
if sys.argv[2]:
    mutant = yaml.safe_load(open(sys.argv[2]))
    names = [f for f, w in wfs.items() if (w or {}).get("name") == (mutant or {}).get("name")]
    say(len(names) == 1, "the workflow under test replaces exactly one workflow by name",
        f"{(mutant or {}).get('name')!r}: {', '.join(names) or 'none'}")
    for f in names:
        wfs[f] = mutant
found, gated, runs, out = set(), 0, 0, []
for f, w in wfs.items():
    if "summary" not in ((w or {}).get("jobs") or {}):
        continue
    found.add(w["jobs"]["summary"].get("name"))
    v, g, r = check(w, EXCEPTIONS.get(f, {}))
    gated += g
    runs += r
    out += [f"{f}: {x}" for x in v]
for f in EXCEPTIONS:
    if f not in wfs or "summary" not in ((wfs[f] or {}).get("jobs") or {}):
        out.append(f"the exceptions name {f}, which is not a summarised workflow")
say(REQUIRED <= found, "LIVENESS: the three summaries main requires were found",
    ", ".join(sorted(x for x in found if x)) or "none")
say(gated >= 13, "LIVENESS: those summaries gate the jobs they need", f"{gated} jobs")
say(runs >= 40, "LIVENESS: the summaries' steps were run with rendered results", f"{runs} runs")
say(not out, "every summary gates every other job of its workflow", f"{len(out)} divergence(s)")
for line in out:
    print(f"      {line}")
sys.exit(fail)
PY
