#!/usr/bin/env bash
# Prove that every guard bench/discriminate.sh drives against a mutant is also run, by some track of
# test.sh, against the unmodified code.
#
# WHY THIS GUARD EXISTS (issue #917, F8-04). discriminate.sh reads ANY non-zero exit of a guard pointed at
# a mutant as "the guard caught its defect". A guard broken enough to fail against everything (pointed at
# a file that is not there: exit 1, "0 ran") therefore scores as catching every one of its mutations, and
# only a run against correct code tells the two apart. test.sh says so itself, at the archive guards ("a
# harness only ever pointed at mutants would be green in `discriminate` even if it were broken enough to
# fail against everything") and in run_timescale, and pairs nearly every guard with its clean-code run.
# Nine were left out of every track: write_block_identity, retire_identity_unreferenced,
# coverage_reset_identity, archive_identity_substitution and five hypertable_* wrappers, so they ran only
# against their mutants. Nothing checked the pairing, so the next guard could be left out the same way.
#
# HOW. The guards are the ones bench/mutations/mutate.py names in MUTATIONS, the list discriminate.sh
# itself drives, so a guard is in scope by WHAT IT IS rather than by a phrase in its header. test.sh is
# read as text, its full-line comments dropped (a guard named only in prose is not run), and inside each
# run_<track>() body a guard counts as run when it is an entry of run_perf's guard list (the data the perf
# track iterates) or the script a `bash` command line runs. A guard named in an echo, or in a
# commented-out call, is not run.
#   LIVENESS  MUTATIONS names at least 200 guards, so a clean result is not a scan of nothing;
#   LIVENESS  the scan credits a known guard of each shape it reads: tap_verdict.sh (perf's list),
#             hypertable_cutover_conservation.sh (run_timescale's bash call), archive_lz77_memory.sh
#             (run_archive's), so it can read every track the pairs live in;
#   CONTROL   on planted test.sh text, a guard named only in a comment, only in an echo, or in a
#             commented-out call is NOT run, and a list entry and a bash call (with and without `out=$(`)
#             are, so the check can fail at all and a stray mention cannot satisfy it.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   clean_run_perf_entry_dropped      -- write_block_identity.sh's perf-list entry deleted: pre-#917
#   clean_run_timescale_call_commented -- hypertable_late_appends.sh's run_timescale call commented out,
#                                        so only a comment names it
#
# Usage: guards_run_on_clean_code.sh <container> <db> [test.sh]
# With no third argument it reads this checkout's test.sh; with one it reads THAT file, which is how
# bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this checkout). Needs python3
# on the host and nothing else; <container> and <db> are accepted so discriminate.sh can call it the way
# it calls every guard, and are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TS="${3:-$ROOT/test.sh}"
TS="${TS/#\/repo\//$ROOT/}"
if [ ! -f "$TS" ]; then printf 'FAIL  %-62s %s\n' "the test.sh under test exists" "$TS"; exit 1; fi

python3 - "$ROOT" "$TS" <<'PY'
import re, sys
root, ts = sys.argv[1], sys.argv[2]
sys.path.insert(0, f"{root}/bench/mutations")
import mutate  # noqa: E402

fail = 0

def say(ok, what, detail):
    global fail
    if not ok:
        fail = 1
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}")

GUARD = r"(bench/[A-Za-z0-9_.-]+\.sh)"
# A bash command line running a guard: `bash "$(dirname "$0")/bench/x.sh" ...`, `bash bench/x.sh`, and
# the same inside `if`, `out=$(` or after `&&`. The token after `bash` is the script, whatever its prefix.
CALL = re.compile(r"(?:^|[\s;&|(])bash\s+\"?(?:\$\(dirname \"\$0\"\)/|\$ROOT/|\./)?" + GUARD)
ENTRY = re.compile(r"^\s*\"" + GUARD + r"(?:\s[^\"]*)?\"\s*$")

def run_guards(text):
    """{guard: track} for every guard a run_<track>() body runs, as the text stands."""
    run = {}
    for m in re.finditer(r"^run_(\w+)\(\) *\{(.*?)\n\}", text, re.S | re.M):
        track, in_list = m.group(1), False
        for line in m.group(2).splitlines():
            if line.lstrip().startswith("#"):
                continue
            if re.match(r"^\s*local guards=\(\s*$", line):
                in_list = True
                continue
            if in_list:
                if re.match(r"^\s*\)\s*$", line):
                    in_list = False
                    continue
                e = ENTRY.match(line)
                if e:
                    run.setdefault(e.group(1), track)
                continue
            for c in CALL.finditer(line):
                run.setdefault(c.group(1), track)
    return run

# CONTROL: the reader on planted text, before it is trusted with test.sh.
planted = '''run_alpha() {
  local guards=(
    "bench/in_list.sh pgpm_x"
    "bench/in_list_extra.sh pgpm_y /repo/pgpm_core/install.sql"
  )
  # bash "$(dirname "$0")/bench/only_comment.sh" c db || fail=1
  echo "--- bench/only_echo.sh ---"
  bash "$(dirname "$0")/bench/called.sh" c db || fail=1
  if out=$(bash "$(dirname "$0")/bench/called_in_subst.sh" c db 2>&1); then :; fi
}
run_beta() {
    # bash "$(dirname "$0")/bench/commented_call.sh" c db || fail=1
  if bash "$(dirname "$0")/bench/called_in_if.sh" c db; then :; fi
}
'''
got = run_guards(planted)
want_run = {"bench/in_list.sh", "bench/in_list_extra.sh", "bench/called.sh",
            "bench/called_in_subst.sh", "bench/called_in_if.sh"}
want_not = {"bench/only_comment.sh", "bench/only_echo.sh", "bench/commented_call.sh"}
say(want_run <= set(got), "CONTROL: a list entry and a bash call (bare, in if, in out=$()) are run",
    f"{len(want_run & set(got))} of {len(want_run)}")
say(not (want_not & set(got)), "CONTROL: a comment, an echo, a commented-out call are not run",
    ", ".join(sorted(want_not & set(got))) or "none credited")

guards = sorted({g for g, _, _ in mutate.MUTATIONS.values()})
say(len(guards) >= 200, "LIVENESS: MUTATIONS names the guards discriminate.sh drives",
    f"{len(guards)} guards, {len(mutate.MUTATIONS)} mutations")

run = run_guards(open(ts).read())
for g, tr in (("bench/tap_verdict.sh", "perf"),
              ("bench/hypertable_cutover_conservation.sh", "timescale"),
              ("bench/archive_lz77_memory.sh", "archive")):
    say(run.get(g) == tr, f"LIVENESS: the scan credits {g.split('/')[1]}", f"run_{run.get(g, 'none')}")

missing = [g for g in guards if g not in run]
say(not missing, "every guard with a mutation is run against the unmodified code",
    f"{len(guards) - len(missing)} of {len(guards)} run")
for g in missing:
    names = [n for n, (gg, _, _) in mutate.MUTATIONS.items() if gg == g]
    print(f"      run only against mutants: {g} ({', '.join(names)})")
sys.exit(fail)
PY
