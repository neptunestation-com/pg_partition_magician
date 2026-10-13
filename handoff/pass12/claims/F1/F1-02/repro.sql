-- F1-02: restore_incoming_fks parks a failed one-step re-add (a partitioned referencer before PG 18) by
-- setting dropped_fk.validate_retry_after five minutes out, but nothing reads that column on the restore
-- path: the next unscoped call (maintain's, every tick) re-adds again, rescanning the referencing table under
-- SHARE ROW EXCLUSIVE on the managed table, and fails on the same orphan. docs/reference.md
-- (restore_incoming_fks, pgpm.dropped_fk.validate_retry_after) promises "not retried before then".
-- Runs on PostgreSQL 15 to 17 (where a partitioned referencer takes the one-step re-add).
create extension if not exists pgtap;
select plan(6);

select ok(current_setting('server_version_num')::int < 180000,
          'GUARD: PostgreSQL before 18, where a partitioned referencer''s key is re-added in one step');

create table public.f1p (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.f1p select i, now() - i * interval '1 hour' from generate_series(1, 20) i;
create table public.f1r (rid bigint not null, pid bigint, pts timestamptz,
                         constraint f1r_fk foreign key (pid, pts) references public.f1p (id, ts))
  partition by range (rid);
create table public.f1r_a partition of public.f1r for values from (0) to (1000);
insert into public.f1r select i, id, ts from public.f1p, generate_series(1, 1) i where id <= 2;
call pgpm.transmute('public.f1p', 'ts', interval '1 day', p_obtain => 3, p_incoming_fks => 'preserve');

-- an orphan written while the key is suspended
insert into public.f1r values (500, 999999, now());

select pgpm.restore_incoming_fks('public.f1p'::regclass) as first_call \gset
select is((select array_agg(method order by id) from pgpm.log
            where action = 'fail_restore_incoming_fk')::text like '%f1r_fk: retried in 5 minutes%', true,
          'LIVENESS: the first call tried the one-step re-add of f1r_fk and failed it on the orphan');
select ok((select validate_retry_after > clock_timestamp() + interval '4 minutes'
             from pgpm.dropped_fk where constraint_name = 'f1r_fk' and restored_at is null),
          'LIVENESS: and parked f1r_fk: validate_retry_after is about five minutes out');
select ok(exists (select 1 from public.f1r where pid = 999999),
          'LIVENESS: the orphan is still there, so a retry would scan and fail again');

-- the next unscoped call, as maintain makes on the next tick, well inside the five minutes
select pgpm.restore_incoming_fks('public.f1p'::regclass) as second_call \gset
select is((select count(*)::int from pgpm.log where action = 'fail_restore_incoming_fk'
             and method like 'f1r_fk:%'), 1,
          'the parked key is not retried by an unscoped call before validate_retry_after (one failed attempt logged, not two)');
select is((select count(*)::int from pgpm.log where action = 'restore_incoming_fk'), 0,
          'and nothing was re-added');
select * from finish();
