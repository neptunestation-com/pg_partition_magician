#!/usr/bin/env bash
# F8-05 (verifier's rebuild): bench/run.sh's CONSERVATION GATE (step 4f) promises "every history row (id < B)
# must still be present after the regrain swap" (bench/README.md: "asserts row conservation (every history row
# still present after the swap)"), but judges it by count: N0 = count(*) before transmute, count(*) where
# id < MONO_HI after. A regrain that loses one history row and invents another in the range keeps the count.
#
# The original grepped three exact lines of run.sh, so any fix that changed their spelling would fail its
# LIVENESS and the reproduction could never pass. This rebuild runs run.sh's OWN code by region instead:
# the pre-transmute anchor region (from the "# ---- 4. conversion" header up to the "call pgpm.transmute" line) and the whole
# 4f block (from "# 4f." to "# ---- 5."), with run.sh's q(), against a bench.events built from the tree's own
# bench/sql/00_schema.sql, and reads the gate's VERDICT variable REGRAIN_CONSERVED.
# Control: an untouched history must not be reported as lost (so a gate that always fails does not pass).
# Present = the gate does not set REGRAIN_CONSERVED=0 for a history that lost row 5 and holds a stranger 50.
set -u
fail=0
R="$TREE/bench/run.sh"
anchor=$(awk '/^# ---- 4\. conversion/{on=1} /call pgpm\.transmute/{on=0} on' "$R")
gate=$(awk '/^# 4f\. /{on=1} /^# ---- 5\. /{on=0} on' "$R")
if [ -n "$anchor" ] && grep -q REGRAIN_CONSERVED <<<"$gate"; then
  echo "ok - LIVENESS: (A) run.sh's pre-transmute anchor region and its 4f conservation gate were extracted"
else
  echo "not ok - LIVENESS: (A) run.sh's pre-transmute anchor region and its 4f conservation gate were extracted"; exit 1
fi
TO_OFF="set statement_timeout=0; set lock_timeout=0"
BENCH_DSN=""; BENCH_REGRAIN=1; BENCH_ID_STEP=10; MONO_HI=100
RESULTS=$(mktemp -d); trap 'rm -rf "$RESULTS"' EXIT
q() { $PSQL -v ON_ERROR_STOP=1 -tAq -c "$TO_OFF" -c "$1"; }
say() { :; }; pgss_reset() { :; }   # the region's instrumentation, not the gate
fixture() {
  q "drop schema if exists bench cascade" >/dev/null 2>&1
  $PSQL -v ON_ERROR_STOP=1 -q -f - >/dev/null < "$TREE/bench/sql/00_schema.sql" || { echo "not ok - GUARD: schema"; exit 1; }
  q "insert into bench.events (id, created_at, user_id, kind, payload)
     select g, '2026-01-01'::timestamptz + g * interval '1 hour', 1, 0, 'h' || g from generate_series(1, 10) g" >/dev/null
}
run_gate() {   # $1 = the regrain under judgement (SQL run between the anchor and the gate)
  ( set +u; N0=; REGRAIN_CONSERVED=
    eval "$anchor" >/dev/null 2>&1
    [ -n "$1" ] && q "$1" >/dev/null
    eval "$gate" >/dev/null 2>&1
    echo "${REGRAIN_CONSERVED:-unset}" )
}
# control: nothing lost
fixture
ctl=$(run_gate "")
if [ "$ctl" = 1 ] || [ "$ctl" = partial ]; then echo "ok - LIVENESS: (B) the gate ran and accepts an intact history (REGRAIN_CONSERVED=$ctl)"
else echo "not ok - LIVENESS: (B) the gate ran and accepts an intact history (REGRAIN_CONSERVED=$ctl)"; exit 1; fi
# the regrain under judgement: history row 5 lost, a stranger 50 invented inside [0, MONO_HI)
fixture
bad="delete from bench.events where id = 5;
     insert into bench.events (id, created_at, user_id, kind, payload) values (50, '2026-01-01', 1, 0, 'stranger')"
held=$(q "begin; $bad; select string_agg(id::text, ',' order by id) from bench.events where id < $MONO_HI; rollback" | tail -1)
if [ "$held" = "1,2,3,4,6,7,8,9,10,50" ]; then echo "ok - LIVENESS: (C) the judged history lost row 5 and holds the stranger 50"
else echo "not ok - LIVENESS: (C) the judged history lost row 5 and holds the stranger 50 (got $held)"; fail=1; fi
v=$(run_gate "$bad")
if [ "$v" = 0 ]; then
  echo "ok - the conservation gate reports the lost history row as a correctness defect (REGRAIN_CONSERVED=0)"
else
  echo "not ok - the conservation gate reports the lost history row as a correctness defect (REGRAIN_CONSERVED=$v: CONSERVED by count)"
  fail=1
fi
q "drop schema bench cascade" >/dev/null 2>&1
exit "$fail"
