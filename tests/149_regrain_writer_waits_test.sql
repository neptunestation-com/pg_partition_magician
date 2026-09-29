-- The synchronous pgpm.regrain() must not deadlock with a write into the table it is regraining (#580).
--
-- THE DEFECT. regrain() loops regrain_step in ONE transaction. Its first step installs the change-capture
-- trigger on the source child, and CREATE TRIGGER's SHARE ROW EXCLUSIVE lock on the source is then held
-- to the end of the call, however long the copy takes. A write into the source's range takes ROW
-- EXCLUSIVE on the PARENT first (granted: nothing conflicts with it there), then queues on the source
-- behind that SHARE ROW EXCLUSIVE, still holding the parent lock. The swap's DETACH then needs ACCESS
-- EXCLUSIVE on the parent and waits on the writer, which waits on regrain(): a lock-order cycle, and
-- PostgreSQL breaks it with 40P01, aborting either the application's write or the whole regrain() after
-- all its copying.
--
-- THE CONTRACT. A write issued while regrain() runs waits for the swap and then succeeds, landing in the
-- fine children; regrain() completes. regrain() now takes SHARE on the parent (ONLY the parent) before its
-- first step, so a writer queues at the parent holding nothing the swap needs, and the swap's upgrade to
-- ACCESS EXCLUSIVE goes ahead of it.
--
-- THE PROBE. Two dblink sessions, ordered by lock state, not by sleeps. R runs regrain() over a 300-way
-- split at 50 rows a batch, long enough to be observed mid-copy. Only once R is seen holding SHARE ROW
-- EXCLUSIVE on the source (capture installed, copy under way) does W send its write, and only once W is
-- seen waiting on a lock of this table while R is still running are the two collected. Those are the
-- liveness witnesses: without them, every assertion below also passes for a writer that arrived after
-- the swap had committed. The write is asymmetric (two rows in, one out) so a lost insert and a
-- resurrected delete cannot cancel, and each row is asserted by identity, down to which fine child
-- holds it. bench/regrain_writer_waits.sh runs this file against a mutant with the lock removed, and
-- `./test.sh discriminate` requires it to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(14);

-- ================================ the fixture ================================
-- 20000 rows in [1, 20000], converted at a 10000 step: the monolith is [0, 30000) and carries the
-- explicit _to_ name, so #266's transitional rename does not move it under the probes. The frontier at
-- 123456 freezes it.
create table public.rww (id bigint primary key, payload text);
insert into public.rww select g, 'o' from generate_series(1, 20000) g;
call pgpm.transmute('public.rww', 'id', 10000, p_regrain_batch => 50);
insert into public.rww values (123456, 'frontier');

select is((select child_name::text from pgpm.part where parent_table = 'public.rww'::regclass and attached
            order by lo::numeric limit 1),
          'rww_p0000000000000000000_to_0000000000000030000',
          'fixture: the monolith is the frozen coarse child [0, 30000)');
select 'public.rww_p0000000000000000000_to_0000000000000030000'::regclass::oid as src_oid,
       'public.rww'::regclass::oid as par_oid \gset

create table public.rww_outcome (who text primary key, state text, result text, msg text);

select dblink_connect('rww_r', 'dbname=' || current_database());
select pid as rpid from dblink('rww_r', 'select pg_backend_pid()') as t(pid int) \gset
select dblink_connect('rww_w', 'dbname=' || current_database());
select pid as wpid from dblink('rww_w', 'select pg_backend_pid()') as t(pid int) \gset
select set_config('rww.rpid', :'rpid', false), set_config('rww.wpid', :'wpid', false),
       set_config('rww.src', :'src_oid', false), set_config('rww.par', :'par_oid', false);

-- R: the operator's synchronous regrain, 300 sub-ranges of 100
select dblink_send_query('rww_r',
  $q$select pgpm.regrain('public.rww', 'rww_p0000000000000000000_to_0000000000000030000', '100')$q$);

-- Wait until R holds the capture trigger's lock on the source: its first step has run and it is copying.
-- Reads pg_locks for the OTHER backend only, so the wait takes no lock either session needs.
do $$
begin
  for i in 1 .. 6000 loop
    exit when exists (select 1 from pg_locks where pid = current_setting('rww.rpid')::int
                       and relation = current_setting('rww.src')::oid
                       and mode = 'ShareRowExclusiveLock' and granted);
    perform pg_sleep(0.005);
  end loop;
end $$;
select ok(exists (select 1 from pg_locks where pid = :rpid and relation = :src_oid
                   and mode = 'ShareRowExclusiveLock' and granted),
  'LIVENESS: regrain() holds SHARE ROW EXCLUSIVE on the source (capture installed) while it copies');

-- W: an ordinary application write into the source's range, two rows in and one out, in one transaction
select dblink_send_query('rww_w',
  $q$insert into public.rww values (25000, 'late'), (25001, 'late'); delete from public.rww where id = 7$q$);
do $$
begin
  for i in 1 .. 6000 loop
    exit when exists (select 1 from pg_locks where pid = current_setting('rww.wpid')::int and not granted
                       and relation in (current_setting('rww.src')::oid, current_setting('rww.par')::oid));
    perform pg_sleep(0.005);
  end loop;
end $$;
select ok(exists (select 1 from pg_locks where pid = :wpid and not granted and relation in (:src_oid, :par_oid)),
  'LIVENESS: the write is waiting on a lock of this table (the parent or the source)...');
select ok(exists (select 1 from pg_stat_activity where pid = :rpid and state = 'active'
                   and query like '%pgpm.regrain(%'),
  'LIVENESS: ...while regrain() is still running, so the write arrived before the swap committed');

-- Collect both sides, recording each one's SQLSTATE rather than dying on it.
do $$
declare v text;
begin
  begin
    select x into v from dblink_get_result('rww_r') as t(x text);
    insert into public.rww_outcome values ('regrain', '00000', v, null);
  exception when others then
    insert into public.rww_outcome values ('regrain', sqlstate, null, left(sqlerrm, 200));
  end;
  begin
    perform * from dblink_get_result('rww_w') as t(x text);
    insert into public.rww_outcome values ('writer', '00000', null, null);
  exception when others then
    insert into public.rww_outcome values ('writer', sqlstate, null, left(sqlerrm, 200));
  end;
end $$;
select dblink_disconnect('rww_r');
select dblink_disconnect('rww_w');

select is((select state || ' ' || coalesce(result, msg) from public.rww_outcome where who = 'regrain'), '00000 300',
  'regrain() completed (no 40P01) and returned its 300 fine children');
select is((select state || coalesce(' ' || msg, '') from public.rww_outcome where who = 'writer'), '00000',
  'the concurrent write completed: it waited for the swap instead of being aborted with 40P01');

-- ================================ which rows, and where ================================
select is((select payload from public.rww where id = 25000), 'late', 'the write''s first inserted row is present');
select is((select payload from public.rww where id = 25001), 'late', 'the write''s second inserted row is present');
select ok(not exists (select 1 from public.rww where id = 7), 'the write''s deleted row stays deleted');
select ok(exists (select 1 from public.rww where id = 6 and payload = 'o'), 'an untouched neighbour is unchanged');
select is((select count(*)::int from public.rww), 20002,
  'row count: 20000 original + 1 frontier + 2 inserted - 1 deleted');
select is((select tableoid::regclass::text from public.rww where id = 25000), 'rww_p0000000000000025000',
  'the late row landed in its fine child: the write ran after the swap, not into the dropped source');
select ok(to_regclass('public.rww_p0000000000000000000_to_0000000000000030000') is null,
  'the coarse source is gone');
select is((select count(*)::int from pgpm.part where parent_table = 'public.rww'::regclass and attached
            and lo::numeric >= 0 and hi::numeric <= 30000), 300,
  'the 300 fine children are attached in its place');

select * from finish();
