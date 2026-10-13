-- P1-02: docs/reference.md (adopt_partition, refusal list) says a p_child "renamed, or whose name another
-- relation took, while the call waited for its lock" is refused and "the call names the partition as it is
-- now, to be called again with that name". The round-2 check keeps that only for the squatter case: a plain
-- rename committed while the call waits makes LOCK TABLE's re-resolution fail with PostgreSQL's
-- `relation "public.x" does not exist` (42P01), naming the OLD name as non-existent and not the current one,
-- for a regclass the caller just resolved. Nothing is recorded (the lock guarantee holds); the refusal is the
-- wrong one. READ COMMITTED throughout; the order is set by the lock queue and witnessed in pg_locks.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(6);

create table public.p102 (id bigint primary key, payload text);
insert into public.p102 values (150, 'a');
call pgpm.transmute('public.p102', 'id', 100::bigint, p_obtain => 1, p_paused => false);
create table public.p102_w partition of public.p102 for values from (1200) to (1300);
insert into public.p102 values (1234, 'w'), (1256, 'w');
select 'public.p102_w'::regclass::oid as w_oid \gset
create function pg_temp.p102_waits(p_pid int, p_rel oid) returns boolean language plpgsql as $$
begin
  for i in 1..500 loop
    if exists (select 1 from pg_locks l where l.pid = p_pid and not l.granted and l.locktype = 'relation' and l.relation = p_rel) then
      return true;
    end if;
    perform pg_sleep(0.01);
  end loop;
  return false;
end $$;
select dblink_connect('ea', 'dbname=' || current_database()) as ea \gset
select dblink_connect('eb', 'dbname=' || current_database()) as eb \gset
select pid as ea_pid from dblink('ea', 'select pg_backend_pid()') as t(pid int) \gset
select dblink_exec('eb', 'begin') as eb_begin \gset
select dblink_exec('eb', 'alter table public.p102_w rename to p102_w_now') as eb_rename \gset
select dblink_exec('ea', 'begin isolation level read committed') as ea_begin \gset
select dblink_send_query('ea', $$select pgpm.adopt_partition('public.p102', 'public.p102_w')$$) as sent \gset
select ok(pg_temp.p102_waits(:ea_pid, :w_oid),
  'LIVENESS: adopt_partition passed its first check and waits behind the rename for w''s lock');
select dblink_exec('eb', 'commit') as eb_commit \gset
select count(*) as drained from dblink_get_result('ea', false) as t(x text) \gset
select dblink_error_message('ea') as msg \gset
select count(*) as drained2 from dblink_get_result('ea', false) as t(x text) \gset
select dblink_exec('ea', 'commit') as ea_commit \gset
select ok(:'msg' <> 'OK', 'LIVENESS: the call refused rather than recording w');
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :w_oid), null,
  'GUARD: nothing is recorded for w');
select ok((select relname from pg_class where oid = :w_oid) = 'p102_w_now'
          and exists (select 1 from pg_inherits where inhparent = 'public.p102'::regclass and inhrelid = :w_oid),
  'LIVENESS: the rename committed and w is still attached as p102_w_now');
select ok(:'msg' like 'ERROR:  pg_partition_magician:%',
  'the refusal is pgpm''s, not PostgreSQL''s "relation does not exist" for a regclass the caller resolved');
select ok(:'msg' like '%p102_w_now%',
  'the refusal names the partition as it is now (p102_w_now), as docs/reference.md says it does');
select dblink_disconnect('ea') as ea_gone \gset
select dblink_disconnect('eb') as eb_gone \gset
select * from finish();
