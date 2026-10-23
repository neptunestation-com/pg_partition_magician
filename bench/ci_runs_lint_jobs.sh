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
#   5. test.sh's `ci` block, RUN (not read), with $0 a stub script that passes every track except lint
#      and runs the lint track as test.sh's own code: run_lint() and the `if [ "$TRACK" = "lint" ]` block
#      out of the test.sh under test, with each lint_job_<id>() replaced by a stub that records its call
#      and, for the one job the run chooses, fails at its FIRST command and would pass at its last (every
#      tool run_lint asks for is a stub on PATH). With no job failing, the lint track called each needed
#      job exactly once and `ci` exits 0 printing `ci: PASS`; with any ONE job failing, `ci` exits non-zero
#      and prints a `ci: FAIL` line naming lint, never `ci: PASS`. So a job failing turns `ci` red through
#      run_lint's loop, its verdict and the lint track's exit, not just through `ci`'s own arm (#1382:
#      this check used to stub the whole lint track, and with run_lint's list and the job bodies read as
#      text, a run_lint whose loop called no job and reported each PASS passed it; #1280 before that: the
#      spelling of a "$0" lint command was accepted, so a `ci` that dropped the track's failure passed).
#      The block runs from a scratch directory, its TMPDIR there too, so nothing it calls by a relative
#      path is this checkout.
#   LIVENESS  lint.yml's summary needs at least 8 jobs, their `run:` steps hold at least 20 commands,
#             test.sh has at least 8 lint_job_ functions, its ci block called the stub for at least 8
#             tracks, and the lint track it ran called at least 8 job stubs, so a clean result is not a
#             scan of nothing and check 5 ran the real block and the real lint track;
#   CONTROL   on a planted workflow and test.sh, a dropped command, a command only in a comment, a
#             missing function, a stale function, a list missing a job, an unknown action version, a
#             changed action option, a `ci` that names the lint track only in an echo, a `ci` that runs
#             the lint track and drops its failure, a run_lint that calls no job, one that drops a job's
#             failure, one that runs a job without errexit, and a lint track that drops run_lint's status
#             each fail, and the planted pair as written passes, so each check can fail and none fails on
#             its own.
#
# Which jobs lint.yml has is not this guard's question: it takes the summary's `needs` as the list, and
# bench/summary_gates_every_job.sh holds that list to the workflow's jobs (#1381).
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   ci_lint_job_dropped     -- the track-filters job's function and its run_lint entry deleted: pre-#1183
#                              for that job, and the drift a job added to lint.yml and not to test.sh leaves
#   ci_skips_lint_track     -- `ci` no longer runs the lint track: pre-#1183's `ci`
#   ci_drops_lint_failure   -- `ci` runs the lint track and its failure arm records nothing, so it prints
#                              `ci: PASS` over a failed lint track (#1280)
#   run_lint_drops_job_failure -- run_lint's failure arm prints FAIL and records nothing, so the lint
#                              track passes with a job red (#1382)
#   run_lint_job_without_errexit -- run_lint runs each job in a child bash without -e, so a job whose
#                              first command fails and whose last passes is reported PASS (#1382)
#
# Usage: ci_runs_lint_jobs.sh <container> <db> [test.sh]
# With no third argument it reads this checkout's test.sh; with one it reads THAT file, which is how
# bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this checkout). Needs python3,
# PyYAML and bash on the host and nothing else; <container> and <db> are accepted so discriminate.sh can
# call it the way it calls every guard, and are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TS="${3:-$ROOT/test.sh}"
TS="${TS/#\/repo\//$ROOT/}"
if [ ! -f "$TS" ]; then printf 'FAIL  %-62s %s\n' "the test.sh under test exists" "$TS"; exit 1; fi

python3 - "$ROOT/.github/workflows/lint.yml" "$TS" <<'PY'
import os, re, shlex, subprocess, sys, tempfile
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
    """(run_lint's job list or None, {job id: [commands]})."""
    fns = {m.group(1).replace("_", "-"): commands(m.group(2))
           for m in re.finditer(r"^lint_job_(\w+)\(\) *\{\n(.*?)\n\}", ts, re.S | re.M)}
    jobs = None
    m = re.search(r"^run_lint\(\) *\{\n(.*?)\n\}", ts, re.S | re.M)
    if m:
        body = "\n".join(ln for ln in m.group(1).split("\n") if not ln.lstrip().startswith("#"))
        lst = re.search(r"\blocal lint_jobs=\((.*?)\)", body, re.S)
        jobs = lst.group(1).split() if lst else None
    return jobs, fns


# $0 for a run of test.sh's ci block: it records each track it is asked for, runs the lint track as the test.sh
# under test runs it (the script lint_script() builds, every tool it asks for a stub on PATH), and passes every
# other track, so the only thing that differs between two runs is which lint job, if any, failed.
CI_STUB = """#!/usr/bin/env bash
printf '%s\\n' "${1:-}" >> "$CI_STUB_LOG"
if [ "${1:-}" = lint ]; then PATH="$CI_STUB_TOOLS:$PATH" exec bash "$CI_STUB_LINT"; fi
exit 0
"""


def job_fn(job):
    return "lint_job_" + job.replace("-", "_")


def lint_script(ts, needs):
    """The lint track out of a test.sh, as a script: its run_lint() and its `lint` block, under test.sh's own
    `set -euo pipefail`, with each needed job's function a stub. Returns (script or None, tools, why not)."""
    rl = re.search(r"^run_lint\(\) *\{\n.*?\n\}$", ts, re.S | re.M)
    blk = re.search(r'^if \[ "\$TRACK" = "lint" \]; then\n.*?\n^fi$', ts, re.S | re.M)
    if not rl or not blk:
        return None, [], ("test.sh has no run_lint()" if not rl else
                          "test.sh has no `if [ \"$TRACK\" = \"lint\" ]; then ... fi` block")
    tools = sorted(set(re.findall(r'\btool="?([A-Za-z0-9_.+-]+)"?', rl.group(0))))
    # A stub records its call, then fails at its FIRST command when it is the chosen job; its last command
    # passes, so a job run without errexit (or in a condition) reads as passed.
    stubs = "".join(f"""{job_fn(j)}() {{
  printf '%s\\n' {shlex.quote(j)} >> "$LINT_JOB_LOG"
  if [ "${{LINT_FAIL_JOB:-}}" = {shlex.quote(j)} ]; then false; fi
  true
}}
""" for j in needs)
    return "set -euo pipefail\n" + stubs + rl.group(0) + "\nTRACK=lint\n" + blk.group(0) + "\n", tools, ""


def run_ci(block, lint, tools, fail_job):
    """Run a ci block with $0 the stub, the lint track `lint`, and `fail_job` (or none) failing. Returns (exit
    status, output lines, the tracks it called, the lint jobs the lint track called)."""
    with tempfile.TemporaryDirectory() as d:
        stub = os.path.join(d, "test.sh")
        with open(stub, "w") as f:
            f.write(CI_STUB)
        os.chmod(stub, 0o755)
        with open(os.path.join(d, "lint.sh"), "w") as f:
            f.write(lint)
        os.mkdir(os.path.join(d, "tools"))
        for t in tools:
            tp = os.path.join(d, "tools", t)
            with open(tp, "w") as f:
                f.write("#!/bin/sh\nexit 0\n")
            os.chmod(tp, 0o755)
        log, jobs = os.path.join(d, "tracks"), os.path.join(d, "jobs")
        open(log, "w").close()
        open(jobs, "w").close()
        env = dict(os.environ, TRACK="ci", TMPDIR=d, CI_STUB_LOG=log, CI_STUB_LINT=os.path.join(d, "lint.sh"),
                   CI_STUB_TOOLS=os.path.join(d, "tools"), LINT_JOB_LOG=jobs, LINT_FAIL_JOB=fail_job or "")
        try:
            p = subprocess.run(["bash", "-c", "set -euo pipefail\n" + block, stub], cwd=d, env=env,
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
            rc, out = p.returncode, (p.stdout + p.stderr).splitlines()
        except subprocess.TimeoutExpired:
            rc, out = None, ["(timed out)"]
        tracks = open(log).read().split()
        ran = open(jobs).read().split()
    return rc, out, tracks, ran


def ci_verdicts(ts, needs):
    """Violations of check 5, the tracks the ci block called and the lint jobs it ran, every job passing."""
    m = re.search(r'^if \[ "\$TRACK" = "ci" \]; then\n.*?\n^fi$', ts, re.S | re.M)
    if not m:
        return ["test.sh has no `if [ \"$TRACK\" = \"ci\" ]; then ... fi` block"], [], []
    lint, tools, why = lint_script(ts, needs)
    if lint is None:
        return [why], [], []
    v = []
    rc, out, ok_tracks, ok_ran = run_ci(m.group(0), lint, tools, None)
    if "lint" not in ok_tracks:
        v.append(f"test.sh's ci block never runs the lint track (it called the stub for: {' '.join(ok_tracks) or 'nothing'})")
    if rc != 0 or not any(ln.startswith("ci: PASS") for ln in out) or any(ln.startswith("ci: FAIL") for ln in out):
        v.append(f"with every track and lint job passing, test.sh's ci block does not exit 0 with `ci: PASS` "
                 f"(exit {rc}: {' | '.join(out[-3:])})")
    if "lint" in ok_tracks and sorted(ok_ran) != sorted(needs):
        v.append(f"the lint track did not call each lint job once (called: {' '.join(ok_ran) or 'none'}; "
                 f"needed: {' '.join(needs)})")
    for j in needs:
        rc, out, tracks, ran = run_ci(m.group(0), lint, tools, j)
        if "lint" in tracks and (rc in (0, None) or any(ln.startswith("ci: PASS") for ln in out)
                                 or not any(re.match(r"ci: FAIL\b.*\blint\b", ln) for ln in out)):
            v.append(f"with lint job {j} failing, test.sh's ci block does not fail naming lint (exit {rc}: "
                     f"{' | '.join(out[-3:])}), so it can report PASS over a red Lint summary")
    return v, ok_tracks, ok_ran


def check(lint, ts):
    """Violations of test.sh's lint track against lint.yml. Also returns (needs, run command count, fns,
    the tracks its ci block called, the lint jobs its lint track called)."""
    v = []
    jobs_yml = lint.get("jobs") or {}
    needs = (jobs_yml.get("summary") or {}).get("needs") or []
    jobs, fns = read_test_sh(ts)
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
    cv, ci_tracks, ci_ran = ci_verdicts(ts, needs)
    v += cv
    return v, needs, nrun, fns, ci_tracks, ci_ran


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
  local job fn tool failed=""
  for job in "${lint_jobs[@]}"; do
    fn="lint_job_${job//-/_}"
    tool="python3"
    if ! command -v "$tool" >/dev/null 2>&1; then echo "SKIPPED  $job"; continue; fi
    if bash -e -o pipefail -c "$(declare -f "$fn"); $fn"; then
      echo "PASS  lint.yml job $job"
    else
      echo "FAIL  lint.yml job $job"
      failed="$failed $job"
    fi
  done
  if [ -n "$failed" ]; then echo "lint track: FAIL --$failed"; return 1; fi
  echo "lint track: PASS"
}
if [ "$TRACK" = "lint" ]; then
  lint_rc=0; run_lint || lint_rc=$?
  exit "$lint_rc"
fi
if [ "$TRACK" = "ci" ]; then
  failed=""
  rc=0; "$0" lint || rc=$?
  [ "$rc" = 0 ] || failed="$failed lint"
  "$0" 15 || failed="$failed pg15"
  if [ -z "$failed" ]; then
    echo "ci: PASS"
    exit 0
  fi
  echo "ci: FAIL --$failed"
  exit 1
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
    "a `ci` that runs the lint track and drops its failure": (
        P_YML, P_TS.replace('[ "$rc" = 0 ] || failed="$failed lint"', '[ "$rc" = 0 ] || :')),
    "a run_lint that calls no job": (
        P_YML, P_TS.replace('if bash -e -o pipefail -c "$(declare -f "$fn"); $fn"; then', 'if true; then')),
    "a run_lint that drops a job's failure": (P_YML, P_TS.replace('      failed="$failed $job"\n', '')),
    "a run_lint that runs a job without errexit": (P_YML, P_TS.replace('bash -e -o pipefail -c', 'bash -o pipefail -c')),
    "a lint track that drops run_lint's status": (P_YML, P_TS.replace('exit "$lint_rc"', 'exit 0')),
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
v, needs, nrun, fns, ci_tracks, ci_ran = check(lint, ts)
say(len(needs) >= 8, "LIVENESS: lint.yml's Lint summary needs its lint jobs", f"{len(needs)} jobs")
say(nrun >= 20, "LIVENESS: those jobs' run steps hold the commands CI runs", f"{nrun} commands")
say(len(fns) >= 8, "LIVENESS: the scan reads test.sh's lint_job_ functions", f"{len(fns)} functions")
say(len(ci_tracks) >= 8, "LIVENESS: test.sh's ci block ran, calling the stub per track",
    " ".join(ci_tracks) or "no track")
say(len(ci_ran) >= 8, "LIVENESS: the lint track it ran called the lint job stubs", f"{len(ci_ran)} calls")
say(not v, "test.sh's ci runs every lint.yml job and fails when one fails",
    f"{len(needs)} jobs, {len(v)} divergence(s)")
for line in v:
    print(f"      {line}")
sys.exit(fail)
PY
