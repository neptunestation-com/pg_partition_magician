-- F9-03: a one-step re-add that failed on an orphan is NOT parked: the next restore_incoming_fks (maintain's call,
-- p_ids null) re-adds (and so rescans) it at once, though the failure stamped validate_retry_after five minutes out.
\set ON_ERROR_STOP 1
create extension if not exists pgtap;
create table public.f9p (id bigint primary key, v text);
insert into public.f9p select g, 'x' from generate_series(1, 50) g;
create table public.f9r (rid int, pid bigint references public.f9p (id)) partition by range (rid);
create table public.f9r_1 partition of public.f9r for values from (0) to (1000);
insert into public.f9r values (1, 10);
call pgpm.transmute('public.f9p', 'id', 100, p_obtain => 1, p_incoming_fks => 'preserve');
-- an orphan written while the key is suspended: the one-step re-add (partitioned referencer, PostgreSQL < 18) fails on it
insert into public.f9r values (2, 999999);

select plan(5);
select ok(current_setting('server_version_num')::int < 180000, 'GUARD: PostgreSQL before 18 (one-step re-add path)');
select is(pgpm.restore_incoming_fks('public.f9p'), 0, 'LIVENESS: the first re-add fails on the orphan');
select ok((select validate_retry_after > clock_timestamp() + interval '4 minutes' and restored_at is null
             from pgpm.dropped_fk where parent_table = 'public.f9p'::regclass),
          'LIVENESS: the failure parked the key (validate_retry_after five minutes out, not restored)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.f9p'::regclass
             and action = 'fail_restore_incoming_fk' and method like '%retried in 5 minutes%'), 1,
          'LIVENESS: one fail_restore_incoming_fk row, promising a retry in 5 minutes');
-- the next tick's call, with no p_ids: the key is parked, so it must not be re-added (scanned) again
select pgpm.restore_incoming_fks('public.f9p');
select is((select count(*)::int from pgpm.log where parent_table = 'public.f9p'::regclass
             and action = 'fail_restore_incoming_fk'), 1,
          'a call within the park (p_ids null) does not attempt the parked re-add again');
select * from finish();
