#!/usr/bin/env bash
# Prove bench/discriminate.sh refuses to count a guard's failure as discrimination when the mutant it was
# handed does not even install, and that it runs EVERY mutation it lists.
#
# WHY THIS GUARD EXISTS (issue #601). discriminate.sh reads ANY non-zero exit of a guard run against its
# mutant as "the guard fails when the defect is present". A mutation whose replacement no longer compiles
# (an install.sql refactor leaves the pattern matching but the patched text invalid) then certified its
# guard as discriminating while the guard never ran a single assertion: its only failure was "the module
# under test installed", and many guards do not even say that much. That is the pass-for-the-wrong-reason
# discriminate.sh exists to rule out, one level up.
#
# The third half is #713's, one more level of the same: discriminate.sh read a guard's failure as a catch
# even when every failure it printed was a LIVENESS witness, i.e. when the mutant starved the fixture and
# the guard never reached the state its defect needs. The guards say themselves that such a failure is not
# evidence, and scripts/review/classify_claims.py applies exactly that rule to a reproduction; the
# instrument that certifies the guards did not.
#
# The second half came with the first. discriminate.sh read its listing on stdin, and `docker exec -i`
# (which most guards use) forwards stdin into the container, so the first guard to call it swallowed the
# rest of the listing: the loop ended early and reported PASS for the mutations it had reached. On main at
# 8c1be7c shard 4/4 counted "of 76 mutations" where the others counted 78, because throws_pinned.sh ate the
# last two lines; they belonged to other shards that day, which is luck, not a property.
#
# HOW. A scratch root holds the discriminate.sh under test, the tree's pgpm_core/install.sql, a stub
# mutation catalogue, and a stub guard that calls `docker exec -i` the way real guards do and then FAILS
# whatever it is given (so, to the old code, it "discriminates" everything). discriminate.sh is run on
# that root twice:
#   installable    two mutants, each install.sql plus a harmless comment -> discriminate must PASS having
#                  run BOTH and reported the stub guard failing on each (the first stub call must not eat
#                  the second line). This is also the LIVENESS of the case below: the harness runs end to
#                  end, and the install check does not refuse everything;
#   uninstallable  one mutant, install.sql plus a call to a function that does not exist
#                  -> discriminate must FAIL, and must NOT report the guard as failing on its defect.
# LIVENESS for the second: that mutant really does not install, checked here directly.
#   liveness       six installable mutants, one stub guard whose output depends on the mutant, in the two
#                  shapes guards print (a shell guard's `FAIL  <label>` lines; a pgTAP wrapper's indented
#                  `not ok N - <description>` lines plus its own roll-up FAIL line):
#                    shell_defect, tap_defect     a defect check failed, its LIVENESS witness held
#                    shell_mixed, tap_mixed       a LIVENESS witness AND a defect check failed
#                    shell_starved, tap_starved   every failure is a LIVENESS (or fixture:) witness
#                  -> the four with a failed defect check must be verified (the LIVENESS of this case: the
#                  rule reads both shapes and does not refuse everything), the two starved ones must NOT,
#                  and discriminate must FAIL saying the fixture starved.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   discriminate_counts_uninstallable -- discriminate.sh's install check removed, pre-#601 exactly
#   discriminate_list_on_stdin        -- the listing read on stdin again, with no read-count check
#   discriminate_counts_liveness_only -- the starved-fixture refusal removed, pre-#713 exactly
#
# Usage: discriminate_installs.sh <container> <db> [discriminate.sh]
# <db> names the scratch databases (the nested run's are <db>_<n> and <db>_<n>_install). A /repo/... path
# is mapped to this checkout, which is how discriminate.sh points it at a mutant of itself. Runs on the
# plain core image; files reach the container over stdin, so no mount is needed.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="${3:-$ROOT/bench/discriminate.sh}"
D="${D/#\/repo\//$ROOT/}"
fail=0
ok()  { printf 'PASS  %-58s %s\n' "$1" "$2"; }
bad() { printf 'FAIL  %-58s %s\n' "$1" "$2"; fail=1; }
if [ ! -f "$D" ]; then bad "the discriminate.sh under test exists" "$D"; exit 1; fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
R="$work/root"
mkdir -p "$R/bench/mutations" "$R/pgpm_core"
cp "$D" "$R/bench/discriminate.sh"
cp "$ROOT/pgpm_core/install.sql" "$R/pgpm_core/install.sql"
cat > "$R/bench/mutations/mutate.py" <<'PY'
import os, sys
case = os.environ["STUB_CASE"]
NAMES = {
    "installable": ["stub_installable_a", "stub_installable_b"],
    "uninstallable": ["stub_uninstallable"],
    "liveness": ["stub_shell_defect", "stub_tap_defect", "stub_shell_mixed", "stub_tap_mixed",
                 "stub_shell_starved", "stub_tap_starved"],
}
if sys.argv[1] == "--list":
    for name in NAMES[case]:
        guard = "bench/stub_liveness_guard.sh" if case == "liveness" else "bench/stub_guard.sh"
        print(f"{name}\t{guard}\ta stub mutant ({case})\tpgpm_core/install.sql")
    sys.exit(0)
name, src, out = sys.argv[1:4]
tail = ("\nselect pgpm.discriminate_installs_no_such_function();\n" if case == "uninstallable"
        else "\n-- a harmless line: this mutant installs\n")
open(out, "w").write(open(src).read() + tail)
PY
cat > "$R/bench/stub_guard.sh" <<'SH'
#!/usr/bin/env bash
# `docker exec -i`, as real guards call it: it forwards this script's stdin into the container.
docker exec -i "$1" psql -U postgres -qAtc 'select 1' >/dev/null 2>&1
echo "FAIL  stub: this guard fails whatever it is given"
exit 1
SH
# Each mutant's run, in the shape a real guard prints it. The defect and mixed runs are what a guard that
# caught its defect looks like; the starved runs are what one whose fixture never got there looks like,
# including the pgTAP wrapper's roll-up FAIL line, which restates the file's verdict and is not a check.
cat > "$R/bench/stub_liveness_guard.sh" <<'SH'
#!/usr/bin/env bash
case "$(basename "$3" .sql)" in
  stub_shell_defect)
    echo "PASS  LIVENESS: the fixture reached the state the defect needs"
    echo "FAIL  the property under test holds                          got 1, want 0" ;;
  stub_tap_defect)
    echo "    ok 1 - LIVENESS: the fixture reached the state the defect needs"
    echo "    not ok 2 - the property under test holds"
    echo "FAIL  the wrapped pgTAP file passes                            3 ran" ;;
  stub_shell_mixed)
    echo "FAIL  LIVENESS: one witness of two held                      no"
    echo "FAIL  the property under test holds                          got 1, want 0" ;;
  stub_tap_mixed)
    echo "    not ok 1 - LIVENESS: one witness of two held"
    echo "    not ok 3 - the property under test holds"
    echo "FAIL  the wrapped pgTAP file passes                            3 ran" ;;
  stub_shell_starved)
    echo "FAIL  LIVENESS: the fixture reached the state the defect needs  no"
    echo "FAIL  fixture: the second session connected                   no"
    echo "PASS  the property under test holds                          0" ;;
  stub_tap_starved)
    echo "    not ok 1 - LIVENESS: the fixture reached the state the defect needs"
    echo "    not ok 2 - fixture: the second session connected"
    echo "FAIL  the wrapped pgTAP file passes                            3 ran" ;;
  *) echo "FAIL  stub: an unexpected mutant $3"; exit 3 ;;
esac
exit 1
SH

run() {  # <case>: run the discriminate.sh under test on the scratch root
  STUB_CASE="$1" DISCRIMINATE_DB_PREFIX="${DB}_" bash "$R/bench/discriminate.sh" "$C" > "$work/$1.out" 2>&1
}

run installable; rc=$?
verified=$(grep -c '^PASS  bench/stub_guard.sh fails when the defect is present' "$work/installable.out")
# Two checks, not one: that BOTH listed mutants ran is the listing-on-stdin contract itself (a guard's
# `docker exec -i` swallowing the second line is that defect), so it is a defect check; that both were
# verified with exit 0 is what makes this case the LIVENESS of the others. One LIVENESS line for both read
# the swallowed listing as a starved fixture, which is what discriminate.sh now refuses to count (#713).
if grep -q '^--- stub_installable_a' "$work/installable.out" && grep -q '^--- stub_installable_b' "$work/installable.out"; then
  ok "every listed mutant ran: no guard swallowed the listing" "a and b"
else
  bad "every listed mutant ran: no guard swallowed the listing" "$(grep -c '^--- stub_installable_' "$work/installable.out") of 2"
  sed 's/^/      /' "$work/installable.out"
fi
if [ "$rc" = 0 ] && [ "$verified" = 2 ]; then
  ok "LIVENESS: both installable mutants were verified" "exit 0, $verified verified"
else
  bad "LIVENESS: both installable mutants were verified" "exit $rc, $verified of 2 verified"
fi

# The planted statement really is why that mutant cannot install, and the mutant is exactly what the
# nested run built (it leaves it under the scratch root's bench/results/mutants/).
m="$R/bench/results/mutants/stub_uninstallable.sql"
run uninstallable; rc=$?
docker exec -i "$C" psql -U postgres -q -c "drop database if exists ${DB}_probe" >/dev/null 2>&1
docker exec -i "$C" psql -U postgres -q -c "create database ${DB}_probe" >/dev/null 2>&1
err=$(docker exec -i "$C" psql -U postgres -d "${DB}_probe" -v ON_ERROR_STOP=1 -q --single-transaction -f - < "$m" 2>&1 >/dev/null)
docker exec -i "$C" psql -U postgres -q -c "drop database if exists ${DB}_probe" >/dev/null 2>&1
if [ -f "$m" ] && grep -q 'discriminate_installs_no_such_function' <<<"$err"; then
  ok "LIVENESS: the uninstallable mutant fails on the planted call" "$(grep -m1 -o 'ERROR:.*' <<<"$err" | cut -c1-60)"
else
  bad "LIVENESS: the uninstallable mutant fails on the planted call" "${err:-no error}"
fi
if [ "$rc" != 0 ] && ! grep -q '^PASS  bench/stub_guard.sh fails when the defect is present' "$work/uninstallable.out"; then
  ok "a guard failing on an uninstallable mutant is not verified" "exit $rc"
else
  bad "a guard failing on an uninstallable mutant is not verified" "exit $rc"
  sed 's/^/      /' "$work/uninstallable.out"
fi

# #713: a run whose every failure is a LIVENESS (or fixture:) witness is the fixture starving, not a catch.
run liveness; rc=$?
block() { awk -v n="--- $1" '$0 == n {f=1; next} /^--- / {f=0} f' "$work/liveness.out"; }
verified=0
for m in shell_defect tap_defect shell_mixed tap_mixed; do
  if block "stub_$m" | grep -q '^PASS  bench/stub_liveness_guard.sh fails when the defect is present'; then
    verified=$((verified + 1))
  fi
done
if [ "$verified" = 4 ]; then
  ok "LIVENESS: the four guards that failed a defect check were verified" "shell and pgTAP shapes"
else
  bad "LIVENESS: the four guards that failed a defect check were verified" "$verified of 4"
  sed 's/^/      /' "$work/liveness.out"
fi
# The starved mutants installed and their guard ran and printed its starved verdict (the nested run leaves
# each guard's log under the scratch root's bench/results/mutants/).
ran=0
for m in shell_starved tap_starved; do
  if grep -q '^--- stub_'"$m"'$' "$work/liveness.out" \
     && grep -qE '^(FAIL  |    not ok 1 - )LIVENESS: the fixture reached' "$R/bench/results/mutants/stub_$m.log"; then
    ran=$((ran + 1))
  fi
done
if [ "$ran" = 2 ]; then
  ok "LIVENESS: both starved mutants installed and their guard ran" "2 of 2"
else
  bad "LIVENESS: both starved mutants installed and their guard ran" "$ran of 2"
fi
refused=0
for m in shell_starved tap_starved; do
  if ! block "stub_$m" | grep -q '^PASS  bench/stub_liveness_guard.sh' \
     && block "stub_$m" | grep -q '^FAIL  bench/stub_liveness_guard.sh failed only LIVENESS witnesses'; then
    refused=$((refused + 1))
  fi
done
if [ "$rc" != 0 ] && [ "$refused" = 2 ]; then
  ok "a guard failing only LIVENESS witnesses is not verified" "exit $rc, $refused of 2 refused as starved"
else
  bad "a guard failing only LIVENESS witnesses is not verified" "exit $rc, $refused of 2 refused as starved"
  block stub_shell_starved | sed 's/^/      /'
  block stub_tap_starved | sed 's/^/      /'
fi
exit "$fail"
