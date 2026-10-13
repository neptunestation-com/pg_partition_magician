#!/bin/bash
# F3-04: regrain_step's swap tick run under REPEATABLE READ (a session or database default_transaction_isolation,
# which pg_cron's maintain inherits, or a hand step in an RR transaction) reconciles through the tick's
# statement-start snapshot. A writer that holds the source when the tick starts makes the swap's DETACH wait;
# it commits, its captured keys land in the delta, and the residual _regrain_reconcile loop and the final
# _regrain_delta_count(lo, hi) cannot see them, so the source is dropped and the fine child keeps the OLD row:
# a committed UPDATE reverted. Sibling of F3-02 (regrain()): neither path refuses a stricter isolation level,
# as transmute, untransmute and from_hypertable do. Fixture: rows 10 (updated by W) and 20 (untouched).
set -u
fail=0
q() { $PSQL -X -tA -v ON_ERROR_STOP=1 -c "$1"; }
q "create table public.f304 (id bigint primary key, payload text)" >/dev/null
q "insert into public.f304 select g, 'orig' from generate_series(1, 100) g" >/dev/null
q "create table public.f304_audit (what text)" >/dev/null
q "call pgpm.transmute('public.f304', 'id', 1000)" >/dev/null
q "select pgpm.obtain('public.f304')" >/dev/null
q "insert into public.f304 values (5000, 'frontier')" >/dev/null
# drive the run (READ COMMITTED, each tick its own transaction) until the cursor reaches hi: the next tick swaps
for i in $(seq 1 40); do
  child=$(q "select child_name from pgpm.part where parent_table = 'public.f304'::regclass and attached order by lo::numeric limit 1")
  cur=$(q "select coalesce(regrain_cursor, '') from pgpm.config where parent_table = 'public.f304'::regclass")
  [ "$cur" = "1000" ] && break
  q "select pgpm.regrain_step('public.f304', '$child', '100')" >/dev/null
done
cur=$(q "select coalesce(regrain_cursor, '') from pgpm.config where parent_table = 'public.f304'::regclass")
if [ "$cur" = "1000" ]; then echo "ok - LIVENESS: (A) the run is copied, cursor at hi 1000: the next tick is the swap"
else echo "not ok - LIVENESS: (A) the run never reached its swap (cursor '$cur')"; exit 1; fi
child=$(q "select child_name from pgpm.part where parent_table = 'public.f304'::regclass and attached order by lo::numeric limit 1")

# W: a writer that holds row 10 of the source across the start of the swap tick, then commits its update
$PSQL -X -q -v ON_ERROR_STOP=1 -c "begin; update public.f304 set payload = 'updated' where id = 10; insert into public.f304_audit values ('w-committed'); select pg_sleep(3); commit;" >/dev/null 2>&1 &
wpid=$!
sleep 1
# S: the swap tick under REPEATABLE READ, no lock_timeout (a hand step; maintain's 200 ms would only defer it)
sout=$($PSQL -X -tA -c "begin isolation level repeatable read;
  select 'iso=' || current_setting('transaction_isolation');
  select 'w_committed_at_start=' || exists (select 1 from public.f304_audit);
  select 'step=' || pgpm.regrain_step('public.f304', '$child', '100');
  commit;" 2>&1)
wait $wpid; west=$?
echo "$sout" | sed 's/^/# S: /'
if [ $west -eq 0 ] && [ "$(q "select count(*) from public.f304_audit where what = 'w-committed'")" = "1" ]; then
  echo "ok - LIVENESS: (B) W's update of row 10 committed"
else echo "not ok - LIVENESS: (B) W did not commit"; fail=1; fi
if echo "$sout" | grep -q 'iso=repeatable read' && echo "$sout" | grep -q 'w_committed_at_start=false'; then
  echo "ok - LIVENESS: (C) the swap tick ran in REPEATABLE READ with a snapshot taken before W committed"
else echo "not ok - LIVENESS: (C) the swap tick's snapshot did not predate W's commit"; fail=1; fi
echo "# swapped: $(q "select exists (select 1 from pgpm.log where parent_table = 'public.f304'::regclass and action = 'regrain' and method = 'copy_swap_drop')")"

got=$(q "select string_agg(id || '=' || payload, ',' order by id) from public.f304 where id in (10, 20)")
if [ "$got" = "10=updated,20=orig" ]; then echo "ok - row 10 keeps W's committed update and row 20 is untouched ($got)"
else echo "not ok - W's committed update of row 10 was reverted by the swap (have $got, want 10=updated,20=orig)"; fail=1; fi
exit $fail
