title: regrain(), regrain_history() and a hand regrain_step copy and swap through a REPEATABLE READ caller's snapshot, dropping rows committed after it (pass 12 RC1)

Tier: 1

Age: old | Lens: operator error

Found in adversarial review pass 12 at `bd55f84021fc4173034d156a41bc91a3f882560d`, root-cause group RC1: F3-02, F3-04.

## F3-02

- finder: F3
- location: `pgpm_core/install.sql:8629`
- lens: operator error
- tier: 1
- scenario: regrain()/regrain_history() called in a REPEATABLE READ transaction copies the monolith through the caller's old snapshot, so a row another session committed after that snapshot (before capture was installed) is in no fine child and the swap drops it with the source (have {10,20}, want {10,20,500}); transmute/untransmute/from_hypertable refuse a stricter isolation (_refuse_strict_isolation) and regrain should refuse it too or copy under a fresh snapshot
- root cause (verifier): regrain()/regrain_history() do not refuse a REPEATABLE READ/SERIALIZABLE caller (no _refuse_strict_isolation, unlike transmute/untransmute/from_hypertable), so the copy reads the source through the caller's pre-call snapshot; a row committed after that snapshot but before the capture trigger exists is in no fine child and is dropped with the source at the swap (have {10,20}, want {10,20,500}). Silent committed-row loss; docs/reference.md contemplates 'a REPEATABLE READ caller of regrain' and documents no such refusal or loss. Not the #1256 mechanism (that is a wait cycle, not a copy through the caller's snapshot). Reproduced on pristine by the classifier with the finder's repro.sql unchanged; deterministic (dblink commit, no timing).

Reproduction: `repro.sql`, the finder's, run unchanged by the verifier.

```sql
-- F3-02: regrain() run from a REPEATABLE READ transaction copies the monolith through the caller's old snapshot,
-- so a row another session committed after that snapshot (and before the call installed change capture) is
-- in the source but in no fine child, and the swap drops the source with it. transmute, untransmute,
-- from_hypertable and the cutover all refuse a stricter isolation level up front (_refuse_strict_isolation);
-- regrain(), regrain_history() and regrain_step() do not, and docs/reference.md even contemplates "a REPEATABLE
-- READ caller of regrain". The fixture: 2 rows in the monolith before, 1 committed by another session after the
-- caller's snapshot; all three must be in the table afterwards.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(5);

create table public.f302 (id bigint primary key, payload text);
insert into public.f302 values (10, 'before-a'), (20, 'before-b');
call pgpm.transmute('public.f302', 'id', 1000);
select pgpm.obtain('public.f302');
insert into public.f302 values (5000, 'frontier');   -- the monolith [0, 1000) is now frozen

select is((select lo || '..' || hi from pgpm.part p where p.parent_table = 'public.f302'::regclass and p.attached
            order by lo::numeric limit 1), '0..1000', 'GUARD: the monolith is [0, 1000)');

begin isolation level repeatable read;
select count(*) from public.f302;   -- the caller's snapshot is taken here
-- another session commits a row into the monolith's range
select dblink_exec(format('dbname=%s user=%s', current_database(), current_user),
                   $$insert into public.f302 values (500, 'committed-after-snapshot')$$);
select is((select n from dblink(format('dbname=%s user=%s', current_database(), current_user),
                                 $$select count(*) from public.f302 where id = 500$$) as t(n bigint)),
          1::bigint, 'LIVENESS: (A) row 500 is committed and visible to a fresh session before regrain runs');
select is((select count(*) from public.f302 where id = 500), 0::bigint,
          'LIVENESS: (B) the caller''s REPEATABLE READ snapshot predates it');
do $$
begin
  perform pgpm.regrain_history('public.f302', '100');
  raise notice 'regrain_history ran under REPEATABLE READ';
exception when others then
  raise notice 'regrain_history refused: %', sqlerrm;
end $$;
commit;

select is((select array_agg(id order by id) from public.f302 where id < 1000), array[10, 20, 500]::bigint[],
          'every row of the monolith''s range is still in the table after regrain (10 and 20 before, 500 committed after the caller''s snapshot)');
select is((select payload from public.f302 where id = 500), 'committed-after-snapshot',
          'row 500 survives with its own payload');
select diag('swapped: ' || exists (select 1 from pgpm.log where parent_table = 'public.f302'::regclass
                                     and action = 'regrain' and method = 'copy_swap_drop'));
select * from finish();
```

## F3-04

- finder: F3
- location: `pgpm_core/install.sql:8500`
- lens: operator error
- tier: 1
- scenario: regrain_step's swap tick under REPEATABLE READ (an RR transaction, or default_transaction_isolation that maintain inherits) runs its residual reconcile and final delta count through the tick's start snapshot, so a writer that committed during the DETACH wait has its captured keys ignored and the source is dropped: a committed UPDATE of row 10 is reverted (have 10=orig, want 10=updated); regrain_step should refuse a stricter isolation level as transmute/untransmute/from_hypertable do (sibling of F3-02's regrain())
- root cause (verifier): regrain_step's swap does not refuse a stricter isolation level: its residual reconcile loop and _regrain_delta_count after the DETACH read pgpm's delta through the transaction's first (REPEATABLE READ) snapshot, so keys a writer captured while the DETACH waited on it are invisible, the count is 0, and the source is dropped with the writer's committed UPDATE unapplied (row 10 reverted to 'orig'). Reproduced unchanged on both trees, all three LIVENESS passing. Not documented: reference.md's regrain_step section states no isolation requirement, while _refuse_strict_isolation (transmute, from_hypertable) and untransmute's #443 check refuse exactly this for the same snapshot-after-wait reason; reachable by a hand step in an RR transaction or a database default_transaction_isolation that maintain's ticks inherit (narrowed there by the 200 ms lock_timeout, not closed). Tier 1: a committed write silently lost. Not #1256 (a wait cycle, not a stale snapshot).

Reproduction: `repro.sh`, the finder's, run unchanged by the verifier.

```bash
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
```

Acceptance: the reproduction(s) above fail on bd55f84021fc4173034d156a41bc91a3f882560d and must pass on the fixing commit; the fix carries a bench/ guard and a bench/mutations entry proven by ./test.sh discriminate.
