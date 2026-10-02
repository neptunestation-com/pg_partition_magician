#!/usr/bin/env bash
# Prove every timescale wrapper guard calls its pgTAP file failed whenever pg_prove would, by reading each
# wrapper's verdict block out of the script and running it, as written, against real pgTAP output.
#
# WHY THIS GUARD EXISTS (issues #795 and #712). The eleven pgTAP wrappers of the timescale track (the
# bench/hypertable_*.sh that run a tests/timescale/db file, and bench/uninstall_hypertable_capture.sh) run
# their file with `psql -tAq` and judge its TAP themselves, because the fleet image has no pg_prove. Eight of them noticed a plan shortfall only through finish()'s
# "# Looks like you planned" line and ignored psql's exit status, so a file whose session died part-way
# (FATAL, a lost connection, no ERROR:) never reached finish() and was PASSED after 1 of 3 planned
# assertions (#795). Three more (late_appends, cutover_identity, replica_capture) had no shortfall check at
# all, so a file whose third assertion ran over zero rows was PASSED after 2 of 3 (#712). The verdict is now
# one shape in all of them: the assertions that ran are counted against the 1..N plan line, and any psql
# exit other than 0 fails the file, alongside the raw ERROR: check they already had.
#
# HOW. Each wrapper's block between `# >>> pgTAP verdict` and `# <<< pgTAP verdict` (the psql call that
# runs the file included, so the exit status it captures is the wrapper's own) is evaluated with TEST_FILE
# set to each of these files, run in <container>:
#   clean            plan(2), two passing assertions                          -> the wrapper must PASS it
#   failed           plan(2), one failing assertion                            -> FAIL
#   shortfall        plan(3), the third assertion over an empty table (#712)   -> FAIL
#   lost_midfile     plan(3), the session terminated after the first (#795)    -> FAIL
#   lost_after_plan  plan(1), one passing assertion, finish(), then terminated -> FAIL (psql exits 2)
#   error            plan(2), a statement that errors between assertions       -> FAIL
# LIVENESS: each fixture really has its shape (the shortfall prints pgTAP's line and exits 0, the lost ones
# print no such line and exit non-zero); pg_prove, the reference, PASSES the clean file and FAILS every other;
# every wrapper this guard knows has exactly one block; and each evaluated block printed its own verdict line,
# so a block that died before judging cannot read as either answer.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each a pre-fix verdict:
#   wrapper_verdict_reads_finish_only  -- hypertable_index_names.sh back to the #795 shape: the shortfall
#                                         read from finish()'s line, psql's exit ignored
#   wrapper_verdict_no_shortfall_check -- hypertable_late_appends.sh back to the #712 shape: no shortfall
#                                         check at all, psql's exit ignored
#   wrapper_verdict_ignores_exit       -- hypertable_cutover_identity.sh with only the exit check gone
#
# Usage: wrapper_tap_verdicts.sh <container> <db> [wrapper script]
# With no third argument it judges every wrapper in this checkout. With one it judges THAT script in place
# of the wrapper it stands for, recognised by its file name or, for a mutant bench/discriminate.sh built
# (<mutation>.sql), by the mutation's MUTATION_SRC; a /repo/... path is mapped to this checkout. The
# container needs pgtap and pg_prove (the plain core image has both); fixtures reach it over stdin.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ONLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok()  { printf 'PASS  %-66s %s\n' "$1" "$2"; }
bad() { printf 'FAIL  %-66s %s\n' "$1" "$2"; fail=1; }
qp() { docker exec -i "$C" psql -U postgres -X "$@"; }
CD="/tmp/wrapper_tap_verdicts_$DB"
work=$(mktemp -d)
cleanup() {
  qp -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  docker exec "$C" rm -rf "$CD" </dev/null >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

# The wrappers, by name: each must carry exactly one verdict block. A wrapper added later that runs a
# timescale file the same way is found by the scan below and judged too.
WRAPPERS=" hypertable_cutover_conservation hypertable_cutover_identity hypertable_cutover_identity_options"
WRAPPERS+=" hypertable_cutover_shape hypertable_derived_names hypertable_empty_copy_watermark"
WRAPPERS+=" hypertable_exclusion_refusal hypertable_index_names hypertable_late_appends"
WRAPPERS+=" hypertable_replica_capture uninstall_hypertable_capture "
KNOWN=11
for f in "$ROOT"/bench/*.sh; do
  n=$(basename "$f" .sh)
  [ "$n" = wrapper_tap_verdicts ] && continue
  if grep -qF -- '-f "$TEST_FILE"' "$f" && [[ "$WRAPPERS" != *" $n "* ]]; then WRAPPERS+="$n "; fi
done
ONLY_NAME=""
script_of() { if [ "$1" = "$ONLY_NAME" ]; then echo "$ONLY"; else echo "$ROOT/bench/$1.sh"; fi; }

if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then bad "the wrapper to judge exists" "$ONLY"; exit 1; fi
  base=$(basename "$ONLY")
  src=$(python3 - "$ROOT/bench/mutations" "${base%.*}" <<'PY2'
import sys
sys.path.insert(0, sys.argv[1])
import mutate
print(mutate.MUTATION_SRC.get(sys.argv[2], ""))
PY2
)
  for n in $WRAPPERS; do
    if [ "$base" = "$n.sh" ] || [ "$src" = "bench/$n.sh" ]; then ONLY_NAME="$n"; fi
  done
  if [ -z "$ONLY_NAME" ]; then bad "the script to judge is a wrapper this guard knows" "$ONLY -> '${src}'"; exit 1; fi
  WRAPPERS=" $ONLY_NAME "
fi

cat > "$work/clean.sql" <<'SQL'
create extension if not exists pgtap;
select plan(2);
select ok(true, 'one');
select ok(true, 'two');
select * from finish();
SQL
cat > "$work/failed.sql" <<'SQL'
create extension if not exists pgtap;
select plan(2);
select ok(true, 'one');
select ok(false, 'two fails');
select * from finish();
SQL
cat > "$work/shortfall.sql" <<'SQL'
create extension if not exists pgtap;
create temp table wrapper_tap_verdict_rows (x int);
select plan(3);
select ok(true, 'one');
select ok(true, 'two');
select ok(x > 0, 'three: over the rows of an empty table, so it never runs') from wrapper_tap_verdict_rows;
select * from finish();
SQL
cat > "$work/lost_midfile.sql" <<'SQL'
create extension if not exists pgtap;
select plan(3);
select ok(true, 'one');
select pg_terminate_backend(pg_backend_pid());
select ok(true, 'two');
select ok(true, 'three');
select * from finish();
SQL
cat > "$work/lost_after_plan.sql" <<'SQL'
create extension if not exists pgtap;
select plan(1);
select ok(true, 'one');
select * from finish();
select pg_terminate_backend(pg_backend_pid());
SQL
cat > "$work/error.sql" <<'SQL'
create extension if not exists pgtap;
select plan(2);
select ok(true, 'one');
select 1 / 0;
select ok(true, 'two');
select * from finish();
SQL
FIXTURES="clean failed shortfall lost_midfile lost_after_plan error"

qp -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
qp -d postgres -q -c "create database $DB" </dev/null >/dev/null 2>&1
qp -d "$DB" -q -c "create extension if not exists pgtap" </dev/null >/dev/null 2>&1
docker exec "$C" mkdir -p "$CD" </dev/null
for f in $FIXTURES; do
  docker exec -i "$C" sh -c "cat > $CD/$f.sql" < "$work/$f.sql"
  # exactly how a wrapper runs its file: -tAq, no ON_ERROR_STOP, stderr folded in
  docker exec "$C" psql -U postgres -X -d "$DB" -tAq -f "$CD/$f.sql" > "$work/$f.out" 2>&1 </dev/null
  echo $? > "$work/$f.rc"
done

# ---- LIVENESS: the fixtures have the shapes they are named for ------------------------------------------
shape() { # <fixture> -> "rc=<rc> plan=<n> ok=<n> looks=<0|1> fatal=<0|1>"
  local o="$work/$1.out"
  printf 'rc=%s plan=%s ok=%s looks=%s fatal=%s' "$(cat "$work/$1.rc")" \
    "$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' "$o" | head -1)" "$(grep -cE '^ok [0-9]+' "$o")" \
    "$(grep -c '^# Looks like you planned' "$o")" "$(grep -c 'FATAL:' "$o")"
}
expect_shape() { # <fixture> <shape glob> <what>
  local s; s=$(shape "$1")
  # shellcheck disable=SC2053  # the right side is a glob on purpose
  if [[ "$s" == $2 ]]; then ok "LIVENESS: the $1 file $3" "$s"; else bad "LIVENESS: the $1 file $3" "$s"; fi
}
expect_shape clean           'rc=0 plan=2 ok=2 looks=0 fatal=0'     "runs both of its two planned assertions"
expect_shape shortfall       'rc=0 plan=3 ok=2 looks=1 fatal=0'     "runs 2 of 3, pgTAP says so, psql exits 0"
expect_shape lost_midfile    'rc=[1-9]* plan=3 ok=1 looks=0 fatal=*' "runs 1 of 3 and dies before finish()"
expect_shape lost_after_plan 'rc=[1-9]* plan=1 ok=1 looks=0 fatal=*' "runs its plan and then loses its session"
if grep -qE '^not ok 2' "$work/failed.out"; then ok "LIVENESS: the failed file fails its second assertion" "not ok 2"
else bad "LIVENESS: the failed file fails its second assertion" "$(tr '\n' ' ' < "$work/failed.out" | cut -c1-60)"; fi
if grep -qE '^ERROR:|^psql:.*ERROR:' "$work/error.out"; then ok "LIVENESS: the error file raises a raw error" "ERROR:"
else bad "LIVENESS: the error file raises a raw error" "$(tr '\n' ' ' < "$work/error.out" | cut -c1-60)"; fi
for f in $FIXTURES; do
  docker exec "$C" pg_prove -U postgres -d "$DB" "$CD/$f.sql" </dev/null >/dev/null 2>&1; rc=$?
  if [ "$f" = clean ]; then
    if [ "$rc" = 0 ]; then ok "LIVENESS: pg_prove passes the clean file" "exit 0"
    else bad "LIVENESS: pg_prove passes the clean file" "exit $rc"; fi
  elif [ "$rc" != 0 ]; then ok "LIVENESS: pg_prove fails the $f file" "exit $rc"
  else bad "LIVENESS: pg_prove fails the $f file" "it passed"; fi
done

# ---- each wrapper's verdict, as written, against each fixture ---------------------------------------------
# q is the wrapper's own psql helper, pointed at this container; the block's call runs the fixture.
q() { docker exec "$C" psql -U postgres -X "$@" </dev/null; }
judged=0
for n in $WRAPPERS; do
  s=$(script_of "$n")
  if [ ! -f "$s" ]; then bad "LIVENESS: the wrapper $n exists" "$s"; continue; fi
  nb=$(grep -c '^ *# >>> pgTAP verdict' "$s"); ne=$(grep -c '^ *# <<< pgTAP verdict' "$s")
  if [ "$nb" != 1 ] || [ "$ne" != 1 ]; then
    bad "LIVENESS: $n carries exactly one verdict block" "$nb begin, $ne end marker(s)"; continue
  fi
  block=$(awk '/^ *# >>> pgTAP verdict/ {f=1} f {print} /^ *# <<< pgTAP verdict/ {exit}' "$s")
  if ! grep -qF -- '-f "$TEST_FILE"' <<<"$block"; then
    bad "LIVENESS: $n's verdict block runs the file itself" "no psql call on \$TEST_FILE"; continue
  fi
  for f in $FIXTURES; do
    want=FAIL; [ "$f" = clean ] && want=PASS
    # shellcheck disable=SC2034  # TEST_FILE, LABEL and UNINSTALL are read by the evaluated block
    vout=$( (TEST_FILE="$CD/$f.sql"; LABEL="the wrapped file passes"; UNINSTALL=/dev/null; fail=0
             eval "$block"; exit "$fail") 2>&1 ); vrc=$?
    if ! grep -qE '^(PASS|FAIL)  the wrapped file passes ' <<<"$vout"; then
      bad "$n: its verdict block reached its verdict on the $f file" "$(tr '\n' ' ' <<<"$vout" | cut -c1-60)"
      continue
    fi
    if [ "$vrc" = 0 ]; then got=PASS; else got=FAIL; fi
    if [ "$got" = "$want" ]; then ok "$n calls the $f file $want" "$got"
    else bad "$n calls the $f file $want" "$got"; sed 's/^/      /' <<<"$vout" | head -8; fi
    judged=$((judged + 1))
  done
done
want_judged=6; [ -z "$ONLY" ] && want_judged=$((KNOWN * 6))
if [ "$judged" -lt "$want_judged" ]; then
  bad "LIVENESS: every wrapper was judged on every fixture" "$judged of at least $want_judged"
fi
exit "$fail"
