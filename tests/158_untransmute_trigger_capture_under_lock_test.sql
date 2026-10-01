-- Issue #666: untransmute captures the parent's triggers under its ACCESS EXCLUSIVE, not before it.
--
-- untransmute replays the parent's triggers onto the restored table, because the DETACH strips the clones
-- the monolith carried. It used to capture them BEFORE its explicit lock (#443's second gate), under only
-- the ACCESS SHARE of its first gate, and CREATE TRIGGER, ENABLE TRIGGER and DISABLE TRIGGER need only
-- SHARE ROW EXCLUSIVE, which ACCESS SHARE does not exclude. A trigger committed while the lock was queued
-- was on neither the capture nor the restored table, and a state changed then came back as it was before
-- the change. #593 closed the same race in transmute; this is its mirror.
--
-- The concurrent session is a dblink connection, as in tests/109 and 157: it takes ROW SHARE, the reversal
-- queues for ACCESS EXCLUSIVE behind it, and only once this session has seen that wait does it create one
-- trigger and disable the other, then commit. This session does not touch the table while the reversal
-- waits (a new ACCESS SHARE would queue behind the pending ACCESS EXCLUSIVE).
--
-- Asymmetric: tg158_a exists from the start and adds 1, the writer's tg158_b adds 10, and the writer
-- DISABLES tg158_a. A row written to the restored table therefore carries 10 exactly when both of the
-- writer's changes came through, 1 under the defect (the old capture: tg158_a enabled, no tg158_b), and
-- 11 or 0 under a half fix.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(10);

create table public.tg158 (id bigint primary key, n int not null default 0);
insert into public.tg158 (id) select g from generate_series(1, 5) g;
create function public.tg158_add1()  returns trigger language plpgsql as $$ begin new.n := new.n + 1;  return new; end $$;
create function public.tg158_add10() returns trigger language plpgsql as $$ begin new.n := new.n + 10; return new; end $$;
create trigger tg158_a before insert on public.tg158 for each row execute function public.tg158_add1();
call pgpm.transmute('public.tg158', 'id', 100::bigint, p_obtain => 2);   -- monolith [0, 100)

insert into public.tg158 (id) values (6);
select is((select n from public.tg158 where id = 6), 1,
  'LIVENESS: on the converted table a write fires tg158_a only (1)');

select dblink_connect('w158', 'dbname=' || current_database());
select dblink_exec('w158', $$set application_name = 'tg158_writer'$$);
select dblink_exec('w158', 'begin');
select dblink_exec('w158', 'lock table public.tg158 in row share mode');

select dblink_connect('u158', 'dbname=' || current_database());
select dblink_exec('u158', $$set application_name = 'tg158_untransmute'$$);
select dblink_exec('u158', $$set lock_timeout = '60s'$$);
select dblink_send_query('u158', $$select pgpm.untransmute('public.tg158')::text$$);

-- Poll for the WAIT, bounded at 30 s so a broken fixture fails rather than hangs.
-- pg_stat_activity is read once per transaction and then frozen (the documented snapshot; a DO block is
-- one transaction), so the loop clears it each turn (#713). It happened to work without that: pg_locks is
-- live, and the backend it joins was in the first snapshot with its application_name already set.
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                       where a.application_name = 'tg158_untransmute' and l.locktype = 'relation'
                         and l.relation = 'public.tg158'::regclass
                         and l.mode = 'AccessExclusiveLock' and not l.granted);
    perform pg_sleep(0.05);
  end loop;
end $$;
select is(
  (select count(*)::int from pg_locks l join pg_stat_activity a on a.pid = l.pid
    where a.application_name = 'tg158_untransmute' and l.locktype = 'relation'
      and l.relation = 'public.tg158'::regclass and l.mode = 'AccessExclusiveLock' and not l.granted),
  1, 'LIVENESS: untransmute passed its first gate and is queued for ACCESS EXCLUSIVE behind the writer');

-- The writer holds a lock the queued request conflicts with, so its SHARE ROW EXCLUSIVE goes ahead of it.
select dblink_exec('w158',
  'create trigger tg158_b before insert on public.tg158 for each row execute function public.tg158_add10()');
select dblink_exec('w158', 'alter table public.tg158 disable trigger tg158_a');
select is(
  (select count(*)::int from pg_locks l join pg_stat_activity a on a.pid = l.pid
    where a.application_name = 'tg158_untransmute' and l.locktype = 'relation'
      and l.relation = 'public.tg158'::regclass and l.mode = 'AccessExclusiveLock' and not l.granted),
  1, 'LIVENESS: and still queued after the writer''s trigger DDL, so it came after the old capture point');
select dblink_exec('w158', 'commit');
select is((select r from dblink_get_result('u158') as t(r text)), 'tg158',
  'untransmute completed once the writer committed');
select dblink_disconnect('u158');
select dblink_disconnect('w158');

select is((select relkind::text from pg_class where oid = 'public.tg158'::regclass), 'r',
  'LIVENESS: tg158 is a plain table again');
select is((select count(*)::int from pgpm.config where parent_table = 'public.tg158'::regclass), 0,
  'LIVENESS: and pgpm no longer manages it');

select is(
  (select array_agg(tgname::text order by tgname) from pg_trigger
    where tgrelid = 'public.tg158'::regclass and not tgisinternal),
  array['tg158_a', 'tg158_b'],
  'the restored table carries the original trigger AND the one created while the lock was queued');
select is(
  (select array_agg(tgname || ':' || tgenabled::text order by tgname) from pg_trigger
    where tgrelid = 'public.tg158'::regclass and not tgisinternal),
  array['tg158_a:D', 'tg158_b:O'],
  'each in the state it had when the reversal took its lock: tg158_a disabled, tg158_b enabled');

insert into public.tg158 (id) values (50);
select is((select n from public.tg158 where id = 50), 10,
  'a write to the restored table fires tg158_b and not tg158_a (10)');
select is((select array_agg(id || ':' || n order by id) from public.tg158 where id >= 6),
  array['6:1', '50:10'],
  'the rows written around the reversal carry exactly the values their triggers gave them');

select * from finish();
