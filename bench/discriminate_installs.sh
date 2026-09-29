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
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   discriminate_counts_uninstallable -- discriminate.sh's install check removed, pre-#601 exactly
#   discriminate_list_on_stdin        -- the listing read on stdin again, with no read-count check
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
if sys.argv[1] == "--list":
    for name in (["stub_installable_a", "stub_installable_b"] if case == "installable" else ["stub_uninstallable"]):
        print(f"{name}\tbench/stub_guard.sh\ta stub mutant ({case})\tpgpm_core/install.sql")
    sys.exit(0)
name, src, out = sys.argv[1:4]
tail = ("\n-- a harmless line: this mutant installs\n" if case == "installable"
        else "\nselect pgpm.discriminate_installs_no_such_function();\n")
open(out, "w").write(open(src).read() + tail)
PY
cat > "$R/bench/stub_guard.sh" <<'SH'
#!/usr/bin/env bash
# `docker exec -i`, as real guards call it: it forwards this script's stdin into the container.
docker exec -i "$1" psql -U postgres -qAtc 'select 1' >/dev/null 2>&1
echo "FAIL  stub: this guard fails whatever it is given"
exit 1
SH

run() {  # <case>: run the discriminate.sh under test on the scratch root
  STUB_CASE="$1" DISCRIMINATE_DB_PREFIX="${DB}_" bash "$R/bench/discriminate.sh" "$C" > "$work/$1.out" 2>&1
}

run installable; rc=$?
verified=$(grep -c '^PASS  bench/stub_guard.sh fails when the defect is present' "$work/installable.out")
if [ "$rc" = 0 ] && [ "$verified" = 2 ] && grep -q '^--- stub_installable_a' "$work/installable.out" \
   && grep -q '^--- stub_installable_b' "$work/installable.out"; then
  ok "LIVENESS: both installable mutants ran and were verified" "exit 0, $verified verified"
else
  bad "LIVENESS: both installable mutants ran and were verified" "exit $rc, $verified of 2 verified"
  sed 's/^/      /' "$work/installable.out"
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
exit "$fail"
