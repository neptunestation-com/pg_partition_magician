#!/usr/bin/env bash
# Prove that `./test.sh ci` runs every job .github/workflows/lint.yml's required Lint summary needs, each
# with the commands CI runs for it.
#
# WHY THIS GUARD EXISTS (issue #1183, F8-11). `./test.sh ci` said it ran "everything the CI workflows run"
# and printed "ci: PASS (every track CI runs)", and CLAUDE.md prescribes it as the pre-push check, but it
# ran the test tracks only: none of lint.yml's ten jobs (the track filters, the minifier and review-tooling
# self-tests, shellcheck, the SQL syntax check, markdownlint, and the source lints). So it reported PASS
# over a tree whose required Lint summary was red. test.sh now has a `lint` track that `ci` runs first,
# with one lint_job_<id>() function per lint.yml job. A hand-copied list of what CI runs drifts behind
# it (the class scripts/check_track_filters.py exists for), so this holds the copy to the workflow.
#
# HOW. lint.yml is parsed as YAML (the real one, always); test.sh is read as text (this checkout's, or
# the file named by the third argument). Commands are compared as shell words: a `run:` block or a
# function body is split into commands at newlines outside quotes (a backslash-newline joins), full-line
# comments dropped, each command split as the shell would, whitespace inside a word collapsed so an awk
# program indented differently still matches. Then:
#   1. run_lint's job list is exactly the summary's `needs`, no job missing, none extra, none twice;
#   2. every needed job has its lint_job_<id>() function, and no function names a job lint.yml lacks;
#   3. every command of every `run:` step of a job appears in its function, in order;
#   4. every `uses:` step other than the checkout is an action in the table below, with exactly the
#      `with:` options the table records, and some command of the function carries the local words the
#      table names (the tool, at the version the action pins); an action or an option the table does not
#      know FAILS, so a bumped action is a revisit of its local equivalent, not a silent divergence;
#   5. test.sh's `ci` block runs the lint track ("$0" lint, outside a comment and an echo).
#   LIVENESS  lint.yml's summary needs at least 8 jobs, their `run:` steps hold at least 20 commands, and
#             test.sh has at least 8 lint_job_ functions, so a clean result is not a scan of nothing;
#   CONTROL   on a planted workflow and test.sh, a dropped command, a command only in a comment, a
#             missing function, a stale function, a list missing a job, an unknown action version, a
#             changed action option and a `ci` that names the lint track only in an echo each fail, and
#             the planted pair as written passes, so each check can fail and none fails on its own.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   ci_lint_job_dropped  -- the track-filters job's function and its run_lint entry deleted: pre-#1183 for
#                           that job, and the drift a job added to lint.yml and not to test.sh leaves
#   ci_skips_lint_track  -- `ci` no longer runs the lint track: pre-#1183's `ci`
#
# Usage: ci_runs_lint_jobs.sh <container> <db> [test.sh]
# With no third argument it reads this checkout's test.sh; with one it reads THAT file, which is how
# bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this checkout). Needs python3
# and PyYAML on the host and nothing else; <container> and <db> are accepted so discriminate.sh can call
# it the way it calls every guard, and are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TS="${3:-$ROOT/test.sh}"
TS="${TS/#\/repo\//$ROOT/}"
if [ ! -f "$TS" ]; then printf 'FAIL  %-62s %s\n' "the test.sh under test exists" "$TS"; exit 1; fi

python3 - "$ROOT/.github/workflows/lint.yml" "$TS" <<'PY'
import re, shlex, sys
import yaml

fail = 0

def say(ok, what, detail=""):
    global fail
    if not ok:
        fail = 1
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}")

# An action CI runs, and the words its local equivalent in test.sh must carry: the action's exact
# `with:` options, and the words some command of the job's function must contain (each a substring of
# one of its words). A version bump or an option change is not in the table, so it fails until the
# local equivalent has been looked at again.
USES_LOCAL = {
    "DavidAnson/markdownlint-cli2-action@v16": (
        {"globs": "**/*.md\n!frozen/postgresql_online_partition_migration_summary.md\n"},
        ["markdownlint-cli2@0.13.0", "frozen/postgresql_online_partition_migration_summary"]),
    "ludeeus/action-shellcheck@master": (
        {"scandir": ".", "severity": "warning"},
        ["shellcheck", "--severity=warning", "*.sh"]),
}
CHECKOUT = re.compile(r"^actions/checkout@")


def commands(text):
    """Shell commands of a block, each a tuple of words, full-line comments dropped."""
    text = "\n".join(ln for ln in text.split("\n") if not ln.lstrip().startswith("#"))
    out, cur, q, i = [], [], None, 0
    while i < len(text):
        c = text[i]
        if q is None:
            if c == "\\" and i + 1 < len(text):
                cur.append(" " if text[i + 1] == "\n" else text[i:i + 2])
                i += 2
                continue
            if c in "'\"":
                q = c
            elif c == "\n":
                out.append("".join(cur))
                cur = []
                i += 1
                continue
        elif q == "'" and c == "'":
            q = None
        elif q == '"':
            if c == "\\" and i + 1 < len(text):
                cur.append(text[i:i + 2])
                i += 2
                continue
            if c == '"':
                q = None
        cur.append(c)
        i += 1
    out.append("".join(cur))
    cmds = []
    for cmd in out:
        if cmd.strip():
            words = shlex.split(cmd, comments=True)
            if words:
                cmds.append(tuple(" ".join(w.split()) for w in words))
    return cmds


def in_order(want, have):
    """The first of `want` not found in `have` in order, or None."""
    it = iter(have)
    for w in want:
        if not any(h == w for h in it):
            return w
    return None


def read_test_sh(ts):
    """(run_lint's job list or None, {job id: [commands]}, ci block runs the lint track)."""
    fns = {m.group(1).replace("_", "-"): commands(m.group(2))
           for m in re.finditer(r"^lint_job_(\w+)\(\) *\{\n(.*?)\n\}", ts, re.S | re.M)}
    jobs = None
    m = re.search(r"^run_lint\(\) *\{\n(.*?)\n\}", ts, re.S | re.M)
    if m:
        body = "\n".join(ln for ln in m.group(1).split("\n") if not ln.lstrip().startswith("#"))
        lst = re.search(r"\blocal lint_jobs=\((.*?)\)", body, re.S)
        jobs = lst.group(1).split() if lst else None
    runs_lint = False
    m = re.search(r'^if \[ "\$TRACK" = "ci" \]; then\n(.*?)\n^fi$', ts, re.S | re.M)
    if m:
        for cmd in commands(m.group(1)):
            # the words of a command that runs this script's lint track, not one that prints or names it
            if cmd[0] not in ("echo", "printf") and any(
                    w == "$0" and k + 1 < len(cmd) and cmd[k + 1] == "lint" for k, w in enumerate(cmd)):
                runs_lint = True
    return jobs, fns, runs_lint


def check(lint, ts):
    """Violations of test.sh's lint track against lint.yml. Also returns (needs, run command count, fns)."""
    v = []
    jobs_yml = lint.get("jobs") or {}
    needs = (jobs_yml.get("summary") or {}).get("needs") or []
    jobs, fns, runs_lint = read_test_sh(ts)
    if jobs is None:
        v.append("test.sh has no run_lint() with a `local lint_jobs=(...)` list")
        jobs = []
    for j in needs:
        if j not in jobs:
            v.append(f"lint.yml job {j}: not in run_lint's job list, so the lint track never runs it")
    for j in jobs:
        if j not in needs:
            v.append(f"run_lint lists {j}, which lint.yml's summary does not need")
        if jobs.count(j) > 1:
            v.append(f"run_lint lists {j} more than once")
    for j in fns:
        if j not in needs:
            v.append(f"test.sh has lint_job_{j.replace('-', '_')}() for {j}, which lint.yml's summary does not need")
    nrun = 0
    for j in needs:
        if j not in fns:
            v.append(f"lint.yml job {j}: test.sh has no lint_job_{j.replace('-', '_')}()")
            continue
        have = fns[j]
        want = []
        for step in (jobs_yml.get(j) or {}).get("steps") or []:
            if "uses" in step:
                u = step["uses"]
                if CHECKOUT.match(u):
                    continue
                if u not in USES_LOCAL:
                    v.append(f"lint.yml job {j}: uses {u}, which has no local equivalent in this guard's table")
                    continue
                opts, words = USES_LOCAL[u]
                if (step.get("with") or {}) != opts:
                    v.append(f"lint.yml job {j}: {u} runs with {step.get('with')}, not the options its local "
                             f"equivalent was written for ({opts})")
                if not any(all(any(w in word for word in cmd) for w in words) for cmd in have):
                    v.append(f"lint.yml job {j}: no command of its function carries {words}, {u}'s local equivalent")
            if "run" in step:
                want += commands(step["run"])
        nrun += len(want)
        miss = in_order(want, have)
        if miss is not None:
            v.append(f"lint.yml job {j}: CI runs `{' '.join(miss)}`, which its function does not, in order")
    if not runs_lint:
        v.append("test.sh's ci block does not run the lint track (\"$0\" lint)")
    return v, needs, nrun, fns


# CONTROL: the checks on a planted pair, before they are trusted with the real one.
P_YML = {"jobs": {
    "alpha": {"steps": [{"uses": "actions/checkout@v4"},
                        {"run": "tools/alpha.py --selftest\n# a comment\ntools/alpha.py\n"}]},
    "beta": {"steps": [{"uses": "actions/checkout@v4"},
                       {"uses": "ludeeus/action-shellcheck@master",
                        "with": {"scandir": ".", "severity": "warning"}},
                       {"run": "awk '\n  /x/ { n++ }\n  END { print n }\n' some.sql\n"}]},
    "summary": {"needs": ["alpha", "beta"]}}}
P_TS = '''lint_job_alpha() {
  tools/alpha.py --selftest
  tools/alpha.py
}
lint_job_beta() {
  # the action, locally
  ls -z '*.sh' | xargs -0 shellcheck --severity=warning
  awk '
      /x/ { n++ }
      END { print n }
  ' some.sql
}
run_lint() {
  local lint_jobs=(
    alpha
    beta
  )
}
if [ "$TRACK" = "ci" ]; then
  rc=0; "$0" lint || rc=$?
fi
'''
import copy
v, *_ = check(P_YML, P_TS)
say(not v, "CONTROL: the planted pair as written passes", "; ".join(v) or "no violation")
variants = {
    "a dropped command": (P_YML, P_TS.replace("  tools/alpha.py\n}", "}")),
    "a command only in a comment": (P_YML, P_TS.replace("  tools/alpha.py\n}", "  # tools/alpha.py\n}")),
    "a missing function": (P_YML, re.sub(r"lint_job_alpha\(\) \{.*?\n\}\n", "", P_TS, flags=re.S)),
    "a stale function": (P_YML, P_TS + "lint_job_gamma() {\n  true\n}\n"),
    "a list missing a job": (P_YML, P_TS.replace("    beta\n", "")),
    "a list naming an extra job": (P_YML, P_TS.replace("    beta\n", "    beta\n    gamma\n")),
    "an awk program changed": (P_YML, P_TS.replace("{ n++ }", "{ n += 2 }")),
    "a `ci` that only echoes the lint track": (P_YML, P_TS.replace('rc=0; "$0" lint || rc=$?', 'echo "$0" lint')),
}
y = copy.deepcopy(P_YML)
y["jobs"]["beta"]["steps"][1]["uses"] = "ludeeus/action-shellcheck@v9"
variants["an action at a version the table does not know"] = (y, P_TS)
y = copy.deepcopy(P_YML)
y["jobs"]["beta"]["steps"][1]["with"]["severity"] = "style"
variants["an action option changed"] = (y, P_TS)
y = copy.deepcopy(P_YML)
y["jobs"]["alpha"]["steps"][1]["run"] += "tools/alpha.py --strict\n"
variants["a command CI added"] = (y, P_TS)
caught = [k for k, (yy, tt) in variants.items() if check(yy, tt)[0]]
say(len(caught) == len(variants), "CONTROL: each planted divergence fails",
    f"{len(caught)} of {len(variants)}" + ("" if len(caught) == len(variants) else
                                            "; missed: " + ", ".join(k for k in variants if k not in caught)))

lint = yaml.safe_load(open(sys.argv[1]))
ts = open(sys.argv[2]).read()
v, needs, nrun, fns = check(lint, ts)
say(len(needs) >= 8, "LIVENESS: lint.yml's Lint summary needs its lint jobs", f"{len(needs)} jobs")
say(nrun >= 20, "LIVENESS: those jobs' run steps hold the commands CI runs", f"{nrun} commands")
say(len(fns) >= 8, "LIVENESS: the scan reads test.sh's lint_job_ functions", f"{len(fns)} functions")
say(not v, "test.sh's ci runs every lint.yml job, as CI runs it",
    f"{len(needs)} jobs, {len(v)} divergence(s)")
for line in v:
    print(f"      {line}")
sys.exit(fail)
PY
