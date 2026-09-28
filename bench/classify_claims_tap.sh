#!/usr/bin/env bash
# Prove scripts/review/classify_claims.py reads a reproduction's TAP the way its contract says, end to end:
# real psql output from a real container through the real Harness.run and classify().
#
# WHY THIS GUARD EXISTS (issue #600). The classifier decides which findings of a review pass are counted,
# and three misreadings each dropped or kept the wrong claims while its self-test stayed green:
#   (a) a failing pgTAP assertion WITHOUT a description (psql prints ` not ok 2 +`, exit 0) read as
#       passing, because only `not ok <n> - <description>` lines were counted: a true reproduction was
#       classified not_reproduced, and a defect still present at closure read as closed;
#   (b) a repro.sh was judged by its exit code alone, so one whose ONLY failing check was its `LIVENESS:`
#       premise was a candidate instead of invalid_repro (repro.sql already got this right);
#   (c) the premise pattern matched bare words, case-insensitively and without the colon, so an
#       unprefixed DEFECT check described "guard trigger is gone ..." read as a premise and a real
#       reproduction was classified invalid_repro and never counted.
#
# HOW. Each case is a claim directory run through Harness.run twice (review, pristine) and classify(),
# with no install, in fresh databases named after <db>. Every defect case is paired with a LIVENESS
# case that holds the premise the defect case needs: psql really printed the undescribed `not ok` and
# exited 0; a described failing check really is a candidate; a repro.sql failing only its LIVENESS
# check really is invalid_repro; a repro.sh failing a DEFECT check really is a candidate; a failing
# `GUARD:` check alone really is invalid_repro. So no case can pass because the harness did nothing.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per misreading:
#   classify_tap_needs_description -- (a): only `not ok <n> - <desc>` lines are failures again
#   classify_sh_exit_code_only     -- (b): a repro.sh is judged by its exit code alone again
#   classify_premise_bare_word     -- (c): the premise pattern matches bare words again
#
# Usage: classify_claims_tap.sh <container> <db> [classify_claims.py]
# The container needs pgtap (the plain core image has it). A /repo/... path is mapped to this checkout,
# which is how bench/discriminate.sh points it at a mutant. Needs python3 on the host.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${3:-$ROOT/scripts/review/classify_claims.py}"
CC="${CC/#\/repo\//$ROOT/}"
if [ ! -f "$CC" ]; then printf 'FAIL  %-58s %s\n' "the classifier under test exists" "$CC"; exit 1; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

python3 - "$CC" "$C" "$DB" "$work" "$ROOT" <<'PY'
import importlib.machinery, importlib.util, os, sys
cc_path, container, db, work, root = sys.argv[1:6]
# Loaded by path, whatever the file is called: discriminate.sh names its mutants *.sql.
loader = importlib.machinery.SourceFileLoader("classify_claims_under_test", cc_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
cc = importlib.util.module_from_spec(spec)
loader.exec_module(cc)
h = cc.Harness(container)
fail = 0

def say(ok, what, detail):
    global fail
    print(f"{'PASS' if ok else 'FAIL'}  {what:<58} {detail}")
    fail |= not ok

PGTAP = "create extension if not exists pgtap;\nselect no_plan();\nselect ok(true, 'LIVENESS: the fixture ran');\n"
CASES = {
    # (a) an undescribed failing assertion, and the same assertion described
    "a1": ("repro.sql", PGTAP + "select is(1, 2);\n"),
    "a2": ("repro.sql", PGTAP + "select is(1, 2, 'the same failing check, with a description');\n"),
    # (b) a repro.sh failing only its premise, one failing its defect check, and the repro.sql premise case
    "b1": ("repro.sh", "echo 'ok - fixture: the scratch table exists'\n"
                       "echo 'not ok - LIVENESS: the tick never reached the partition'\nexit 1\n"),
    "b2": ("repro.sh", "echo 'ok - LIVENESS: the tick reached the partition'\n"
                       "echo 'not ok - the partition lost a row'\nexit 1\n"),
    "b3": ("repro.sql", "create extension if not exists pgtap;\nselect no_plan();\n"
                        "select ok(false, 'LIVENESS: the fixture never ran');\n"),
    # (c) an unprefixed defect check that starts with a premise WORD, and a real GUARD: premise failing
    "c1": ("repro.sql", PGTAP + "select ok(false, 'guard trigger is gone from the restored table');\n"),
    "c2": ("repro.sql", PGTAP + "select ok(false, 'GUARD: the trigger was installed before the swap');\n"),
}
res = {}
for key, (name, text) in CASES.items():
    d = os.path.join(work, key)
    os.makedirs(d)
    with open(os.path.join(d, name), "w") as fh:
        fh.write(text)
    claim = {"id": f"{db}_{key}", "install": [], "fixtures": False, "dir": d, "repro": name, "repro_used": name}
    r = h.run(root, claim, "r")
    p = h.run(root, claim, "p")
    res[key] = (cc.classify(r, p), r)

a1_cls, a1 = res["a1"]
printed = any(l.strip().startswith("not ok 2") and " - " not in l for l in a1.get("tail", "").splitlines())
say(printed and a1.get("exit") == 0, "LIVENESS: psql printed an undescribed `not ok 2`, exit 0", f"printed={printed} exit={a1.get('exit')}")
say(res["a2"][0] == "candidate", "LIVENESS: a described failing check is a candidate", res["a2"][0])
say(a1_cls == "candidate", "(a) an undescribed failing assertion is a candidate", a1_cls)

say(res["b3"][0] == "invalid_repro", "LIVENESS: a repro.sql failing only LIVENESS: is invalid_repro", res["b3"][0])
say(res["b2"][0] == "candidate", "LIVENESS: a repro.sh failing its defect check is a candidate", res["b2"][0])
ran = "not ok - LIVENESS: the tick never reached" in res["b1"][1].get("tail", "")
say(ran, "LIVENESS: the repro.sh ran and echoed its premise failure", f"echoed={ran}")
say(res["b1"][0] == "invalid_repro", "(b) a repro.sh failing only LIVENESS: is invalid_repro", res["b1"][0])

say(res["c2"][0] == "invalid_repro", "LIVENESS: a failing GUARD: premise alone is invalid_repro", res["c2"][0])
c1_printed = "not ok 2 - guard trigger is gone" in res["c1"][1].get("tail", "")
say(c1_printed, "LIVENESS: psql printed `not ok 2 - guard trigger ...`", f"printed={c1_printed}")
say(res["c1"][0] == "candidate", "(c) an unprefixed check starting 'guard' is a candidate", res["c1"][0])
sys.exit(1 if fail else 0)
PY
