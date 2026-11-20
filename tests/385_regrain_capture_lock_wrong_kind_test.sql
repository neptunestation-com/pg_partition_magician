-- regrain's change capture follows its delta when the name it queued on is given to a relation LOCK TABLE refuses
-- (issue #1061, the core capture).
--
-- THE GAP. The capture function _regrain_capture_install mints writes its delta only while it holds it (#1057): it
-- takes ROW EXCLUSIVE through the name it is about to use and uses the name only if, once the lock is held, it still
-- leads to the recorded oid. A lock refused because the name had moved (42P01, 3F000, 42501) was caught and the
-- writer went on to the delta by its oid. But LOCK TABLE re-resolves the name after its wait, and when the operator
-- renamed the delta and gave the freed name to a MATERIALIZED VIEW or a SEQUENCE, the lock landed there and raised
-- wrong_object_type (42809, "cannot lock relation ..."), which nothing caught: the queued write DIED instead of
-- writing the delta where it now is, as docs/reference.md says it does. Both of the capture's locks had the gap:
-- the fast path's static LOCK on the minted name, and the loop's dynamic LOCK on the name rendered from the oid.
--
-- THE LEVER is tests/290's, deterministic, not timed: a second session (dblink, the operator) renames the delta and,
-- in the same transaction, waits until it sees the writer (a third session) queued on the delta's lock; only then
-- does it give the freed name to its relation and commit. The writer is sent only once the operator is seen
-- holding ACCESS EXCLUSIVE on the delta.
--
-- ASYMMETRIC FIXTURE. Four parents, each with a regrain in flight on its frozen monolith, copied to the swap's
-- doorstep so only capture carries a write to the swap.
--   e385 (500 rows): the fast path; a materialized view takes the freed name; the write updates row 7.
--   f385 (400 rows): the fast path; a sequence takes the freed name; the write deletes row 8 and inserts 9500.
--   g385 (300 rows): the loop; the delta was already renamed aside (committed), so the writer skips the fast path,
--                    renders the delta's current name and queues on it; the operator renames it again and puts a
--                    materialized view under the name the writer rendered; the write updates row 3.
--   h385 (200 rows): the control, its delta left alone, takes one write (update 5).
-- bench/regrain_capture_lock_wrong_kind.sh runs this file against the mutants that take 42809 out of either
-- handler, so it is required to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(22);

create function pg_temp.to_doorstep(p_parent regclass, p_child name) returns void language plpgsql as $f$
declare s text; n int := 0; v_cur text;
begin
  loop
    select regrain_cursor into v_cur from pgpm.config where parent_table = p_parent;
    exit when v_cur is not null and v_cur::numeric >= 200000;
    s := pgpm.regrain_step(p_parent, p_child, '20000', 5000);
    n := n + 1; if n > 100 then raise exception 'no convergence (last %)', s; end if;
  end loop;
end $f$;
create function pg_temp.to_swap(p_parent regclass, p_child name) returns text language plpgsql as $f$
declare s text; n int := 0;
begin
  loop
    s := pgpm.regrain_step(p_parent, p_child, '20000', 5000);
    exit when s like 'swapped:%';
    n := n + 1; if n > 60 then raise exception 'no swap (last %)', s; end if;
  end loop;
  return s;
end $f$;
create function pg_temp.mk(p_rel text, p_rows int) returns void language plpgsql as $f$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_rel);
  execute format('insert into public.%I select g, ''orig'' from generate_series(1, %s) g', p_rel, p_rows);
  execute format('insert into public.%I values (199999, ''widen'')', p_rel);
end $f$;
select pg_temp.mk('e385', 500);
select pg_temp.mk('f385', 400);
select pg_temp.mk('g385', 300);
select pg_temp.mk('h385', 200);
call pgpm.transmute('public.e385', 'id', 100000);
call pgpm.transmute('public.f385', 'id', 100000);
call pgpm.transmute('public.g385', 'id', 100000);
call pgpm.transmute('public.h385', 'id', 100000);
select pgpm.obtain(p) from unnest(array['public.e385', 'public.f385', 'public.g385', 'public.h385']::regclass[]) p;
insert into public.e385 values (350000, 'frontier');   -- the frontier leaves each monolith: it is frozen
insert into public.f385 values (350000, 'frontier');
insert into public.g385 values (350000, 'frontier');
insert into public.h385 values (350000, 'frontier');

select is(pgpm.regrain_step('public.e385', 'e385_p0000000000000000000_to_0000000000000200000', '20000', 5000)
          || ',' || pgpm.regrain_step('public.f385', 'f385_p0000000000000000000_to_0000000000000200000', '20000', 5000)
          || ',' || pgpm.regrain_step('public.g385', 'g385_p0000000000000000000_to_0000000000000200000', '20000', 5000)
          || ',' || pgpm.regrain_step('public.h385', 'h385_p0000000000000000000_to_0000000000000200000', '20000', 5000),
  'prepared,prepared,prepared,prepared', 'LIVENESS: tick 1 prepares each regrain: capture is installed on each source');
select pg_temp.to_doorstep('public.e385', 'e385_p0000000000000000000_to_0000000000000200000');
select pg_temp.to_doorstep('public.f385', 'f385_p0000000000000000000_to_0000000000000200000');
select pg_temp.to_doorstep('public.g385', 'g385_p0000000000000000000_to_0000000000000200000');
select pg_temp.to_doorstep('public.h385', 'h385_p0000000000000000000_to_0000000000000200000');
select is((select string_agg(payload, ',') from (
             select payload from public.e385_p0000000000000000000 where id = 7 union all
             select payload from public.f385_p0000000000000000000 where id = 8 union all
             select payload from public.g385_p0000000000000000000 where id = 3) s),
  'orig,orig,orig', 'LIVENESS: rows e385/7, f385/8 and g385/3 are already copied, so only capture carries their writes to the swap');

-- The recorded oids, before anything is renamed, so every later read is by identity.
create table public.r385_delta (parent text primary key, delta oid);
insert into public.r385_delta
  select c.relname, cfg.regrain_delta_oid from pgpm.config cfg join pg_class c on c.oid = cfg.parent_table
   where c.relname in ('e385', 'f385', 'g385', 'h385');
-- g385's delta is renamed aside first, committed: its writer finds the minted name gone and takes the loop
alter table public.g385_pgpm_regrain_delta rename to g385_aside;
create table public.r385_seen (parent text primary key, writer_pid int);
create table public.r385_outcome (parent text, who text, state text, msg text, primary key (parent, who));

-- One race: the operator renames the delta from p_from to p_to and holds it; the writer is sent once that lock is
-- seen granted; the operator runs p_take (which gives p_from to a relation of its own) and commits only once it has
-- seen the writer queued on the delta. Both outcomes are recorded with their SQLSTATE, never died on.
create function pg_temp.race(p_parent text, p_from text, p_to text, p_take text, p_writer_sql text) returns void language plpgsql as $f$
declare
  v_delta oid := (select delta from public.r385_delta where parent = p_parent);
  v_wpid int; v_opid int; v_held boolean := false;
begin
  perform dblink_connect('r385_op', 'dbname=' || current_database());
  perform dblink_connect('r385_w', 'dbname=' || current_database());
  select pid into v_opid from dblink('r385_op', 'select pg_backend_pid()') as t(pid int);
  select pid into v_wpid from dblink('r385_w', 'select pg_backend_pid()') as t(pid int);
  perform dblink_send_query('r385_op', format($op$
    do $x$
    begin
      alter table public.%1$I rename to %2$I;
      for i in 1 .. 4000 loop
        exit when exists (select 1 from pg_locks where pid = %3$s and relation = %4$s and not granted);
        perform pg_sleep(0.005);
      end loop;
      if not exists (select 1 from pg_locks where pid = %3$s and relation = %4$s and not granted) then
        raise exception 'the writer never queued on the delta';
      end if;
      insert into public.r385_seen values (%5$L, %3$s);
      execute %6$L;
    end $x$
    $op$, p_from, p_to, v_wpid, v_delta, p_parent, p_take));
  for i in 1 .. 4000 loop
    v_held := exists (select 1 from pg_locks where pid = v_opid and relation = v_delta
                       and mode = 'AccessExclusiveLock' and granted);
    exit when v_held;
    perform pg_sleep(0.005);
  end loop;
  if v_held then
    perform dblink_send_query('r385_w', p_writer_sql);
  end if;
  begin
    perform * from dblink_get_result('r385_op') as t(x text);
    insert into public.r385_outcome values (p_parent, 'operator', '00000', null);
  exception when others then
    insert into public.r385_outcome values (p_parent, 'operator', sqlstate, left(sqlerrm, 200));
  end;
  if v_held then
    begin
      perform * from dblink_get_result('r385_w') as t(x text);
      insert into public.r385_outcome values (p_parent, 'writer', '00000', null);
    exception when others then
      insert into public.r385_outcome values (p_parent, 'writer', sqlstate, left(sqlerrm, 200));
    end;
  else
    insert into public.r385_outcome values (p_parent, 'writer', 'never sent', 'the operator was never seen holding the delta');
  end if;
  perform dblink_disconnect('r385_op');
  perform dblink_disconnect('r385_w');
end $f$;

select pg_temp.race('e385', 'e385_pgpm_regrain_delta', 'e385_moved',
  'create materialized view public.e385_pgpm_regrain_delta as select 1::bigint as id',
  $w$update public.e385 set payload = 'e-updated' where id = 7$w$);
select pg_temp.race('f385', 'f385_pgpm_regrain_delta', 'f385_moved',
  'create sequence public.f385_pgpm_regrain_delta',
  $w$do $d$ begin delete from public.f385 where id = 8; insert into public.f385 values (9500, 'inserted'); end $d$$w$);
select pg_temp.race('g385', 'g385_aside', 'g385_moved',
  'create materialized view public.g385_aside as select 1::bigint as id',
  $w$update public.g385 set payload = 'g-updated' where id = 3$w$);
update public.h385 set payload = 'h-updated' where id = 5;

-- ==================== the witnesses: each race happened as the defect needs it ====================
select is((select string_agg(s.parent || ':' || (s.writer_pid is not null)::text, ',' order by s.parent) from public.r385_seen s),
  'e385:true,f385:true,g385:true',
  'LIVENESS: in each race the operator saw the writer queued on the delta before it committed');
select is((select string_agg(o.parent || ':' || o.state || coalesce(' ' || o.msg, ''), ',' order by o.parent)
             from public.r385_outcome o where o.who = 'operator'),
  'e385:00000,f385:00000,g385:00000', 'LIVENESS: each operator''s rename and take of the name committed');
select is((select string_agg(d.parent || '=' || c.relname, ',' order by d.parent)
             from public.r385_delta d join pg_class c on c.oid = d.delta),
  'e385=e385_moved,f385=f385_moved,g385=g385_moved,h385=h385_pgpm_regrain_delta',
  'LIVENESS: each recorded delta is the same relation, renamed where an operator renamed it');
select is((select string_agg(c.relname || ':' || c.relkind::text, ',' order by c.relname) from pg_class c
            where c.oid in (to_regclass('public.e385_pgpm_regrain_delta'), to_regclass('public.f385_pgpm_regrain_delta'),
                            to_regclass('public.g385_aside'))),
  'e385_pgpm_regrain_delta:m,f385_pgpm_regrain_delta:S,g385_aside:m',
  'LIVENESS: a materialized view or a sequence now holds each name a writer queued on');
select throws_ok($$lock table only public.e385_pgpm_regrain_delta in row exclusive mode$$, '42809', null,
  'LIVENESS: LOCK TABLE refuses the materialized view under the freed name with 42809');

-- ==================== the contract: every write goes on, into the recorded delta ====================
select is((select state || coalesce(' ' || msg, '') from public.r385_outcome where parent = 'e385' and who = 'writer'),
  '00000', 'e385: the write that queued behind the rename succeeds when a materialized view takes the name (not 42809)');
select is((select state || coalesce(' ' || msg, '') from public.r385_outcome where parent = 'f385' and who = 'writer'),
  '00000', 'f385: the write that queued behind the rename succeeds when a sequence takes the name (not 42809)');
select is((select state || coalesce(' ' || msg, '') from public.r385_outcome where parent = 'g385' and who = 'writer'),
  '00000', 'g385: the loop''s write succeeds when a materialized view takes the name it rendered (not 42809)');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.e385_moved), '7,7',
  'e385: the update''s keys are captured in the recorded (renamed) delta');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.f385_moved), '8,9500',
  'f385: the delete''s and the insert''s keys are captured in the recorded (renamed) delta');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.g385_moved), '3,3',
  'g385: the update''s keys are captured in the recorded (twice renamed) delta');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.h385_pgpm_regrain_delta), '5,5',
  'the control: h385''s capture, its delta left alone, logs its write');

-- ==================== the swap honours every captured write, by row ====================
select matches(pg_temp.to_swap('public.e385', 'e385_p0000000000000000000_to_0000000000000200000'), '^swapped:', 'e385''s regrain swaps');
select matches(pg_temp.to_swap('public.f385', 'f385_p0000000000000000000_to_0000000000000200000'), '^swapped:', 'f385''s regrain swaps');
select matches(pg_temp.to_swap('public.g385', 'g385_p0000000000000000000_to_0000000000000200000'), '^swapped:', 'g385''s regrain swaps');
select matches(pg_temp.to_swap('public.h385', 'h385_p0000000000000000000_to_0000000000000200000'), '^swapped:', 'h385''s regrain swaps');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.e385 where id in (6, 7, 8)),
  '6=orig,7=e-updated,8=orig', 'e385 keeps the committed update of row 7 after the swap');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.f385 where id in (7, 8, 9, 9500)),
  '7=orig,9=orig,9500=inserted', 'f385 keeps the delete of row 8 and the insert of 9500 after the swap');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.g385 where id in (2, 3, 4)),
  '2=orig,3=g-updated,4=orig', 'g385 keeps the committed update of row 3 after the swap');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.h385 where id in (4, 5, 6)),
  '4=orig,5=h-updated,6=orig', 'the control: h385 keeps its update');

select * from finish();
