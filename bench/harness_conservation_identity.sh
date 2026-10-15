#!/usr/bin/env bash
# Prove that the at-scale harnesses' conservation gates judge the rows they protect by identity: a run that
# loses one row and invents another, or rewrites one in place, is reported as the correctness defect it is,
# not as conserved.
#
# WHY THIS GUARD EXISTS (issue #1282, F8-05). bench/run.sh's step 4f promises "every history row (id < B)
# must still be present after the regrain swap" (bench/README.md: "every history row still present after
# the swap"), but compared count(*) before transmute with count(*) where id < B after, so a swap that lost
# row 5 and held a stranger row 50 reported CONSERVED. bench/run_fh.sh's step 4d had the same gate over its
# immutable cohort (users 49001..50000, which bench/README.md says the harness "asserts ... is unchanged
# across the migration"). Both now take a digest of the rows with the count (the sum of a 64-bit hash of
# each whole row) before the conversion and require both to match after.
#
# HOW. Each harness's OWN code is run, by region, with its q() pointed at <db>: run.sh's pre-transmute
# anchor region (from "# ---- 4. conversion" to the transmute call) and its whole 4f block (to
# "# ---- 5."), and run_fh.sh's pre-convert anchor region (from "# ---- 4. convert" to "convert_start=")
# and its 4d block (to "HT_LEFT="). bench.events is built from bench/sql/00_schema.sql (run_fh.sh's own
# schema needs TimescaleDB; the columns are the same) and the change under judgement is made between the
# anchor and the gate. The gate's verdict is read from its own variable (REGRAIN_CONSERVED, CONS).
#   run.sh, history ids 1..10, MONO_HI 100: lost row 5 + a stranger 50 => REGRAIN_CONSERVED=0; row 7's
#     payload rewritten => 0.
#   run_fh.sh, cohort ids 1..6 (user 49001), others 7..10 (user 7): lost cohort row 5 + a stranger cohort row
#     50 => CONS=fail; cohort row 3's payload rewritten => fail; a NON-cohort row deleted (the workload's
#     own churn) => ok, so the gate judges the cohort and not the whole table.
#   LIVENESS  each region was found; each gate ran and accepts an untouched table (REGRAIN_CONSERVED 1 or
#             partial, CONS ok), so a gate that always fails cannot pass; and each judged table really
#             holds the same number of rows as before and the changed ids, so the identity case is the one
#             a count cannot see.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   run_conservation_by_count -- run.sh's 4f compares the counts only (pre-#1282)
#   fh_conservation_by_count  -- run_fh.sh's 4d compares the counts only (pre-#1282)
#
# Usage: harness_conservation_identity.sh <container> <db> [harness]
# With no third argument it judges this checkout's run.sh and run_fh.sh; with one it judges THAT file in
# place of whichever of the two it is (told apart by content), which is how bench/discriminate.sh points it
# at a mutant (a /repo/... path is mapped to this checkout). bench/sql/00_schema.sql is fed from the host.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/bench/run.sh"; RUN_FH="$ROOT/bench/run_fh.sh"
MUT="${3:-}"
if [ -n "$MUT" ]; then
  MUT="${MUT/#\/repo\//$ROOT/}"
  if grep -q '^# 4f\. ' "$MUT" 2>/dev/null; then RUN="$MUT"
  elif grep -q '^# 4d\. conservation' "$MUT" 2>/dev/null; then RUN_FH="$MUT"
  else printf 'FAIL  %-62s %s\n' "fixture: the harness to judge is run.sh or run_fh.sh" "$MUT"; exit 1; fi
fi
fail=0
say_() { if [ "$1" = ok ]; then printf 'PASS  %-62s %s\n' "$2" "${3:-}"; else printf 'FAIL  %-62s %s\n' "$2" "${3:-}"; fail=1; fi; }

P=(docker exec -i "$C" psql -U postgres)
"${P[@]}" -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
if ! "${P[@]}" -d postgres -q -c "create database $DB" >/dev/null 2>&1 ||
   ! "${P[@]}" -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f - < "$ROOT/pgpm_core/install.sql" >/dev/null 2>&1; then
  say_ no "fixture: pgpm installs into $DB" "in $C"; exit 1
fi

# The harnesses' helpers, as the regions use them: q() into <db> with the harness's own timeouts, and the
# instrumentation the regions call (not what they judge) as no-ops.
TO_OFF="set statement_timeout=0; set lock_timeout=0"
q() { "${P[@]}" -d "$DB" -v ON_ERROR_STOP=1 -tAq -c "$TO_OFF" -c "$1"; }
say() { :; }; pgss_reset() { :; }
RESULTS=$(mktemp -d); trap 'rm -rf "$RESULTS"; "${P[@]}" -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1' EXIT
# shellcheck disable=SC2034  # the harness settings the regions read, through eval
declare BENCH_DSN="" BENCH_REGRAIN=1 BENCH_ID_STEP=10 MONO_HI=100 ANCHOR_USER_LO=49001 BENCH_TRACK_CHANGES=1

fixture() {   # $1 = the user_id rule for each id, as SQL over g
  q "drop schema if exists bench cascade" >/dev/null 2>&1
  "${P[@]}" -d "$DB" -v ON_ERROR_STOP=1 -q -f - < "$ROOT/bench/sql/00_schema.sql" >/dev/null 2>&1 \
    || { say_ no "fixture: bench/sql/00_schema.sql builds bench.events"; exit 1; }
  q "insert into bench.events (id, created_at, user_id, kind, payload)
     select g, '2026-01-01'::timestamptz + g * interval '1 hour', $1, 0, 'h' || g from generate_series(1, 10) g" >/dev/null
}
ids() { q "select count(*) || ':' || string_agg(id::text, ',' order by id) from bench.events where $1"; }

# run_gate <anchor> <gate> <verdict variable> <change SQL>: the anchor region, the change, the gate region,
# in a subshell; prints the verdict.
run_gate() {
  # shellcheck disable=SC2034  # the anchors and verdicts the regions set, read back through eval
  ( set +u; N0=; REGRAIN_CONSERVED=; ANCHOR0=; CONS=
    eval "$1" >/dev/null 2>&1
    [ -n "$4" ] && q "$4" >/dev/null
    eval "$2" >/dev/null 2>&1
    eval "echo \"\${$3:-unset}\"" )
}

# ---- run.sh: the history rows id < MONO_HI across the regrain swap
anchor=$(awk '/^# ---- 4\. conversion/{on=1} /call pgpm\.transmute/{on=0} on' "$RUN")
gate=$(awk '/^# 4f\. /{on=1} /^# ---- 5\. /{on=0} on' "$RUN")
if [ -n "$anchor" ] && grep -q REGRAIN_CONSERVED <<<"$gate"; then
  say_ ok "LIVENESS: run.sh's anchor region and 4f gate were found"
  fixture 1
  v=$(run_gate "$anchor" "$gate" REGRAIN_CONSERVED "")
  if [ "$v" = 1 ] || [ "$v" = partial ]; then say_ ok "LIVENESS: run.sh's gate accepts an untouched history" "REGRAIN_CONSERVED=$v"
  else say_ no "LIVENESS: run.sh's gate accepts an untouched history" "REGRAIN_CONSERVED=$v"; fi

  swap="delete from bench.events where id = 5;
        insert into bench.events (id, created_at, user_id, kind, payload) values (50, '2026-01-01', 1, 0, 'stranger')"
  fixture 1
  v=$(run_gate "$anchor" "$gate" REGRAIN_CONSERVED "$swap")
  held=$(ids "id < $MONO_HI")
  if [ "$held" = "10:1,2,3,4,6,7,8,9,10,50" ]; then say_ ok "LIVENESS: run.sh's judged history lost 5, holds 50, count 10"
  else say_ no "LIVENESS: run.sh's judged history lost 5, holds 50, count 10" "got $held"; fi
  if [ "$v" = 0 ]; then say_ ok "run.sh's gate fails a history that lost row 5 for a stranger 50" "REGRAIN_CONSERVED=$v"
  else say_ no "run.sh's gate fails a history that lost row 5 for a stranger 50" "REGRAIN_CONSERVED=$v (conserved by count)"; fi

  fixture 1
  v=$(run_gate "$anchor" "$gate" REGRAIN_CONSERVED "update bench.events set payload = 'rewritten' where id = 7")
  if [ "$v" = 0 ]; then say_ ok "run.sh's gate fails a history whose row 7 was rewritten" "REGRAIN_CONSERVED=$v"
  else say_ no "run.sh's gate fails a history whose row 7 was rewritten" "REGRAIN_CONSERVED=$v"; fi
else
  say_ no "LIVENESS: run.sh's anchor region and 4f gate were found" "$RUN"
fi

# ---- run_fh.sh: the immutable cohort (user_id >= 49001) across the online migration
anchor=$(awk '/^# ---- 4\. convert/{on=1} /^convert_start=/{on=0} on' "$RUN_FH")
gate=$(awk '/^# 4d\. conservation/{on=1} /^HT_LEFT=/{on=0} on' "$RUN_FH")
cohort="case when g <= 6 then 49001 else 7 end"
if [ -n "$anchor" ] && grep -q 'CONS=' <<<"$gate"; then
  say_ ok "LIVENESS: run_fh.sh's anchor region and 4d gate were found"
  fixture "$cohort"
  v=$(run_gate "$anchor" "$gate" CONS "")
  if [ "$v" = ok ]; then say_ ok "LIVENESS: run_fh.sh's gate accepts an untouched cohort" "CONS=$v"
  else say_ no "LIVENESS: run_fh.sh's gate accepts an untouched cohort" "CONS=$v"; fi

  swap="delete from bench.events where id = 5;
        insert into bench.events (id, created_at, user_id, kind, payload) values (50, '2026-01-01', 49001, 0, 'stranger')"
  fixture "$cohort"
  v=$(run_gate "$anchor" "$gate" CONS "$swap")
  held=$(ids "user_id >= $ANCHOR_USER_LO")
  if [ "$held" = "6:1,2,3,4,6,50" ]; then say_ ok "LIVENESS: run_fh.sh's judged cohort lost 5, holds 50, count 6"
  else say_ no "LIVENESS: run_fh.sh's judged cohort lost 5, holds 50, count 6" "got $held"; fi
  if [ "$v" = fail ]; then say_ ok "run_fh.sh's gate fails a cohort that lost row 5 for a stranger 50" "CONS=$v"
  else say_ no "run_fh.sh's gate fails a cohort that lost row 5 for a stranger 50" "CONS=$v (conserved by count)"; fi

  fixture "$cohort"
  v=$(run_gate "$anchor" "$gate" CONS "update bench.events set payload = 'rewritten' where id = 3")
  if [ "$v" = fail ]; then say_ ok "run_fh.sh's gate fails a cohort whose row 3 was rewritten" "CONS=$v"
  else say_ no "run_fh.sh's gate fails a cohort whose row 3 was rewritten" "CONS=$v"; fi

  fixture "$cohort"
  v=$(run_gate "$anchor" "$gate" CONS "delete from bench.events where id = 8")
  if [ "$v" = ok ]; then say_ ok "run_fh.sh's gate accepts the workload's churn outside the cohort" "CONS=$v (row 8, user 7, deleted)"
  else say_ no "run_fh.sh's gate accepts the workload's churn outside the cohort" "CONS=$v (row 8, user 7, deleted)"; fi
else
  say_ no "LIVENESS: run_fh.sh's anchor region and 4d gate were found" "$RUN_FH"
fi

q "drop schema if exists bench cascade" >/dev/null 2>&1
echo "harness_conservation_identity: $([ "$fail" = 0 ] && echo PASS || echo FAIL)"
exit "$fail"
