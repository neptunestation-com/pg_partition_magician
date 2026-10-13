#!/usr/bin/env bash
# F8-03: bench/run_fh.sh (the from_hypertable at-scale harness) calls pgpm.from_hypertable_cutover with a
# named argument p_regrain_batch, which the procedure does not have (its batch is p_drain_batch), so the call
# cannot resolve and the harness (set -e, ON_ERROR_STOP) dies after the copy phase, every run. The call is read
# from $TREE/bench/run_fh.sh, its shell variables replaced with the values the harness's defaults give them.
# Present = the call as written fails to resolve ("procedure ... does not exist").
set -u
fail=0
line=$(grep -m1 -E '^q "call pgpm\.from_hypertable_cutover\(' "$TREE/bench/run_fh.sh")
if [ -n "$line" ]; then echo "ok - LIVENESS: (A) run_fh.sh's cutover call was read from the tree"
else echo "not ok - LIVENESS: (A) run_fh.sh's cutover call was read from the tree"; exit 1; fi
call=$(sed -E 's/^q "//; s/" >\/dev\/null.*$//' <<<"$line")
call=${call//\$BENCH_FH_INTERVAL/1 month}
call=${call//\$BENCH_OBTAIN/4}
call=${call//\$BENCH_DRAIN_BATCH/50000}
call=${call//\$PREDRAIN/true}
$PSQL -q -c "create schema bench; create table bench.events (id bigint, created_at timestamptz not null, payload text)" >/dev/null 2>&1
n=$($PSQL -tAc "select count(*) from pg_proc where oid = 'pgpm.from_hypertable_cutover'::regproc and prokind = 'p'" 2>&1)
if [ "$n" = 1 ]; then echo "ok - LIVENESS: (B) pgpm.from_hypertable_cutover is installed, one procedure"
else echo "not ok - LIVENESS: (B) pgpm.from_hypertable_cutover is installed, one procedure (got: $n)"; fail=1; fi
# The same call with its batch named as the procedure names it resolves (it then fails on the plain table,
# which is not a hypertable): the fixture can tell an unresolvable call from one that runs.
fixed=${call//p_regrain_batch/p_drain_batch}
out=$($PSQL -tAc "$fixed" 2>&1)
if grep -q 'pg_partition_magician:' <<<"$out"; then
  echo "ok - LIVENESS: (C) the call with p_drain_batch resolves and runs its body (refusing the plain table: $(head -1 <<<"$out" | cut -c1-70))"
else
  echo "not ok - LIVENESS: (C) the call with p_drain_batch resolves and runs its body: $(head -1 <<<"$out" | cut -c1-100)"; fail=1
fi
out=$($PSQL -tAc "$call" 2>&1)
if grep -q 'procedure pgpm.from_hypertable_cutover(.*) does not exist' <<<"$out"; then
  echo "not ok - run_fh.sh's cutover call resolves to pgpm.from_hypertable_cutover: $(head -1 <<<"$out" | cut -c1-140)"
  fail=1
else
  echo "ok - run_fh.sh's cutover call resolves to pgpm.from_hypertable_cutover"
fi
exit "$fail"
