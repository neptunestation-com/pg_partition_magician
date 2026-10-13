#!/usr/bin/env bash
# F8-05: bench/run.sh's CONSERVATION GATE (step 4f) judges the regrain by count: N0 = count(*) before, and
# count(*) where id < MONO_HI after, "every history row (id < B) must still be present". A regrain that loses one
# history row and invents another in the range keeps the count, and the gate reports CONSERVED. Both statements
# are read from $TREE/bench/run.sh and evaluated with run.sh's own comparison.
# Present = the gate accepts a history range that lost row 5 and gained a stranger.
set -u
fail=0
R="$TREE/bench/run.sh"
n0_line=$(grep -m1 -E '^N0=\$\(q "select count\(\*\) from bench\.events"\)' "$R")
after_line=$(grep -m1 -E '^ *REGRAIN_HIST_AFTER=\$\(q ' "$R")
cmp_line=$(grep -m1 -F 'if [ "$REGRAIN_HIST_AFTER" != "$N0" ]; then' "$R")
if [ -n "$n0_line" ] && [ -n "$after_line" ] && [ -n "$cmp_line" ]; then
  echo "ok - LIVENESS: (A) the gate's anchor, its re-count and its comparison were read from run.sh"
else
  echo "not ok - LIVENESS: (A) the gate's anchor, its re-count and its comparison were read from run.sh"; exit 1
fi
q() { $PSQL -v ON_ERROR_STOP=1 -tAq -c "$1"; }
q "create schema bench; create table bench.events (id bigint primary key, payload text);
   insert into bench.events select g, 'h' || g from generate_series(1, 10) g" >/dev/null
MONO_HI=100
eval "${n0_line%%#*}"
# the regrain under judgement: history row 5 lost, a stranger 50 invented inside [0, MONO_HI)
q "delete from bench.events where id = 5; insert into bench.events values (50, 'stranger')" >/dev/null
held=$(q "select string_agg(id::text, ',' order by id) from bench.events where id < $MONO_HI")
if [ "$held" = "1,2,3,4,6,7,8,9,10,50" ]; then echo "ok - LIVENESS: (B) the history lost row 5 and holds the stranger 50"
else echo "not ok - LIVENESS: (B) the history lost row 5 and holds the stranger 50 (got $held)"; fail=1; fi
eval "$(sed -E 's/^ +//' <<<"$after_line")"
if [ -n "${N0:-}" ] && [ -n "${REGRAIN_HIST_AFTER:-}" ]; then echo "ok - LIVENESS: (C) the gate evaluated here (before $N0, after $REGRAIN_HIST_AFTER)"
else echo "not ok - LIVENESS: (C) the gate evaluated here"; fail=1; fi
if [ "$REGRAIN_HIST_AFTER" != "$N0" ]; then
  echo "ok - the conservation gate reports the lost history row as a correctness defect"
else
  echo "not ok - the conservation gate reports the lost history row as a correctness defect (it reads CONSERVED: $N0 = $REGRAIN_HIST_AFTER)"
  fail=1
fi
exit "$fail"
