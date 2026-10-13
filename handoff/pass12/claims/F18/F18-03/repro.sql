-- F18-03: restore_incoming_fks parks a failed one-step re-add (validate_retry_after, #633) but never reads
-- the column: its loop selects every record with restored_at null, so maintain's unscoped call (p_ids null)
-- re-attempts the validating re-add, which is the whole referencing-table scan under SHARE ROW EXCLUSIVE on
-- the managed table, on every tick. docs/reference.md (restore_incoming_fks) promises "at most every five
-- minutes while the orphan stands, not on every tick". PostgreSQL 15 to 17, partitioned referencing table.
create extension if not exists pgtap;
select plan(8);

create table public.f18p (id bigint primary key, ts timestamptz not null default now());
insert into public.f18p select i from generate_series(1, 50) i;
create table public.f18r (id bigint not null, pid bigint not null references public.f18p (id))
  partition by range (id);
create table public.f18r_a partition of public.f18r for values from (0) to (1000);
insert into public.f18r values (1, 1), (2, 2);
call pgpm.transmute('public.f18p', 'id', 1000::bigint, p_obtain => 2, p_incoming_fks => 'preserve');

select ok(not exists (select 1 from pg_constraint where conrelid = 'public.f18r'::regclass and contype = 'f'),
          'LIVENESS: the cutover dropped the incoming key off f18r');
select is((select count(*)::int from pgpm.dropped_fk where parent_table = 'public.f18p'::regclass and restored_at is null),
          1, 'LIVENESS: and recorded it, unrestored');
-- an orphan written while the key is off, so the one-step validating re-add fails on it
insert into public.f18r values (3, 999999);

select is(pgpm.restore_incoming_fks('public.f18p'), 0,
          'LIVENESS: the first unscoped call re-adds nothing (the one-step re-add fails on the orphan)');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.f18p'::regclass and action = 'fail_restore_incoming_fk'),
          1, 'LIVENESS: which it logged once, as fail_restore_incoming_fk');
select ok((select validate_retry_after > clock_timestamp() from pgpm.dropped_fk
            where parent_table = 'public.f18p'::regclass),
          'LIVENESS: and parked the key: validate_retry_after is in the future');

-- the defect: maintain's next unscoped call, inside the park, must not attempt (and log) the scan again
select is(pgpm.restore_incoming_fks('public.f18p'), 0,
          'a second unscoped call inside the park re-adds nothing');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.f18p'::regclass and action = 'fail_restore_incoming_fk'),
          1, 'and did not attempt the parked re-add again: still exactly one fail_restore_incoming_fk row');
-- the documented route that does retry at once: naming the key in p_ids
select is((select count(*)::int from pgpm.log where parent_table = 'public.f18p'::regclass
             and action = 'fail_restore_incoming_fk'
             and method like '%retried in 5 minutes (at once if named in p_ids)%'),
          1, 'the one log row names the p_ids route as the way to retry at once');
select * from finish();
