-- regrain's change capture writes its delta only under a lock that pins the delta to the name it uses (issue
-- #1057, bullet 3).
--
-- THE DEFECT. #1051 made the capture function _regrain_capture_install mints reach the delta by the oid the
-- prepare tick recorded, with a fast path: while the minted name still led to the recorded oid, the static
-- `insert into <rel>_pgpm_regrain_delta` ran. The check was a to_regclass, which takes no lock, and the
-- insert then looked the name up AGAIN, after queueing on the delta's lock. So a writer arriving while an
-- operator's transaction held the delta to rename it passed the check (the rename was not yet committed),
-- queued, and once the rename committed its insert resolved the minted name to whatever held it then: a
-- table the operator had created under the freed name in the same transaction took the keys (a misdirected
-- capture, which the reconcile never reads, so the swap reverted the committed write), and with no such
-- table the write was refused with 42P01. docs/reference.md: "a delta you rename or move mid-regrain goes on
-- taking every change, and a table you create under the name it gave up takes none."
--
-- THE LEVER, deterministic, not timed. A second session (dblink, the operator) renames the recorded delta
-- and then, in the same transaction, waits until it sees the writer queued on the delta's lock; only then
-- does it create its table under the freed name (or not) and commit. The writer (a third session) is sent
-- only once the operator is seen holding ACCESS EXCLUSIVE on the delta. So every writer here passed the
-- capture's name check before the rename committed and was waiting on the delta when it did: the window
-- the defect needs, every time, with no sleep deciding it.
--
-- ASYMMETRIC FIXTURE. Four parents, each with a regrain in flight on its frozen monolith, copied to the
-- swap's doorstep so only capture carries a write to the swap.
--   a290 (1000 rows): rename + a table under the freed name; the owner's write updates row 7.
--   c290 (400 rows):  rename only; the owner's write deletes row 8 and inserts 9500.
--   d290 (300 rows):  rename + a table under the freed name, and the writer is a role that may write d290
--                     (so pgpm grants it INSERT on the delta) but holds nothing on the operator's table:
--                     its write updates row 3.
--   b290 (600 rows):  the control, its delta left alone, takes one write (update 5).
-- Each delta's keys are asserted by identity, each table under a freed name is asserted empty, and each
-- swap by the rows it leaves. bench/regrain_capture_delta_held.sh runs this file against the mutant that
-- puts the unlocked fast path back (regrain_capture_fast_path_unlocked), so it is required to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(34);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't290_writer') then create role t290_writer nologin; end if;
end $$;

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
create table public.a290 (id bigint primary key, payload text);
insert into public.a290 select g, 'orig' from generate_series(1, 1000) g;
insert into public.a290 values (199999, 'widen');
call pgpm.transmute('public.a290', 'id', 100000);
select pgpm.obtain('public.a290');
insert into public.a290 values (350000, 'frontier');   -- the frontier leaves the monolith: it is frozen

create table public.b290 (id bigint primary key, payload text);
insert into public.b290 select g, 'orig' from generate_series(1, 600) g;
insert into public.b290 values (199999, 'widen');
call pgpm.transmute('public.b290', 'id', 100000);
select pgpm.obtain('public.b290');
insert into public.b290 values (350000, 'frontier');   -- the frontier leaves the monolith: it is frozen

create table public.c290 (id bigint primary key, payload text);
insert into public.c290 select g, 'orig' from generate_series(1, 400) g;
insert into public.c290 values (199999, 'widen');
call pgpm.transmute('public.c290', 'id', 100000);
select pgpm.obtain('public.c290');
insert into public.c290 values (350000, 'frontier');   -- the frontier leaves the monolith: it is frozen

create table public.d290 (id bigint primary key, payload text);
insert into public.d290 select g, 'orig' from generate_series(1, 300) g;
insert into public.d290 values (199999, 'widen');
call pgpm.transmute('public.d290', 'id', 100000);
select pgpm.obtain('public.d290');
insert into public.d290 values (350000, 'frontier');   -- the frontier leaves the monolith: it is frozen
grant select, update on public.d290 to t290_writer;   -- before the prepare, so its grant pass covers the delta

select is(pgpm.regrain_step('public.a290', 'a290_p0000000000000000000_to_0000000000000200000', '20000', 5000)
          || ',' || pgpm.regrain_step('public.b290', 'b290_p0000000000000000000_to_0000000000000200000', '20000', 5000)
          || ',' || pgpm.regrain_step('public.c290', 'c290_p0000000000000000000_to_0000000000000200000', '20000', 5000)
          || ',' || pgpm.regrain_step('public.d290', 'd290_p0000000000000000000_to_0000000000000200000', '20000', 5000),
  'prepared,prepared,prepared,prepared', 'LIVENESS: tick 1 prepares each regrain: capture is installed on each source');
select pg_temp.to_doorstep('public.a290', 'a290_p0000000000000000000_to_0000000000000200000');
select pg_temp.to_doorstep('public.b290', 'b290_p0000000000000000000_to_0000000000000200000');
select pg_temp.to_doorstep('public.c290', 'c290_p0000000000000000000_to_0000000000000200000');
select pg_temp.to_doorstep('public.d290', 'd290_p0000000000000000000_to_0000000000000200000');
select is((select string_agg(regrain_delta_oid::regclass::text, ',' order by parent_table::text) from pgpm.config
            where parent_table in ('public.a290'::regclass, 'public.b290'::regclass, 'public.c290'::regclass, 'public.d290'::regclass)),
  'a290_pgpm_regrain_delta,b290_pgpm_regrain_delta,c290_pgpm_regrain_delta,d290_pgpm_regrain_delta',
  'LIVENESS: each prepare recorded the delta it minted, by oid, under its own name');
select is((select string_agg(payload, ',') from (
             select payload from public.a290_p0000000000000000000 where id = 7 union all
             select payload from public.c290_p0000000000000000000 where id = 8 union all
             select payload from public.d290_p0000000000000000000 where id = 3) s),
  'orig,orig,orig', 'LIVENESS: rows a290/7, c290/8 and d290/3 are already copied, so only capture carries their writes to the swap');
select ok(has_table_privilege('t290_writer', 'public.d290_pgpm_regrain_delta', 'INSERT'),
  'LIVENESS: the writer role holds INSERT on d290''s delta (pgpm''s grant pass)');

-- The recorded oids, before anything is renamed, so every later read is by identity.
create table public.r290_delta (parent text primary key, delta oid);
insert into public.r290_delta
  select c.relname, cfg.regrain_delta_oid from pgpm.config cfg join pg_class c on c.oid = cfg.parent_table
   where c.relname in ('a290', 'b290', 'c290', 'd290');
-- What the operator saw before committing, written in its own transaction (so it commits with the rename).
create table public.r290_seen (parent text primary key, writer_pid int);
create table public.r290_outcome (parent text, who text, state text, msg text, primary key (parent, who));

-- One race: the operator renames <parent>'s recorded delta and holds it; the writer is sent once that lock is
-- seen granted; the operator commits (creating a table under the freed name if p_take_name) only once it has
-- seen the writer queued on the delta. Both outcomes are recorded with their SQLSTATE, never died on. Each
-- side sends ONE statement (a DO block where the write is two), because dblink_get_result returns the first
-- result of a multi-statement string and an error in a later one would go unread.
create function pg_temp.race(p_parent text, p_take_name boolean, p_writer_sql text, p_role name default null) returns void language plpgsql as $f$
declare
  v_delta oid := (select delta from public.r290_delta where parent = p_parent);
  v_wpid int; v_opid int; v_held boolean := false;
begin
  perform dblink_connect('r290_op', 'dbname=' || current_database());
  perform dblink_connect('r290_w', 'dbname=' || current_database());
  select pid into v_opid from dblink('r290_op', 'select pg_backend_pid()') as t(pid int);
  select pid into v_wpid from dblink('r290_w', 'select pg_backend_pid()') as t(pid int);
  if p_role is not null then
    perform dblink_exec('r290_w', format('set role %I', p_role));
  end if;
  perform dblink_send_query('r290_op', format($op$
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
      insert into public.r290_seen values (%5$L, %3$s);
      if %6$L then
        create table public.%1$I (id bigint);
      end if;
    end $x$
    $op$, p_parent || '_pgpm_regrain_delta', p_parent || '_renamed_delta', v_wpid, v_delta, p_parent, p_take_name));
  for i in 1 .. 4000 loop
    v_held := exists (select 1 from pg_locks where pid = v_opid and relation = v_delta
                       and mode = 'AccessExclusiveLock' and granted);
    exit when v_held;
    perform pg_sleep(0.005);
  end loop;
  if v_held then
    perform dblink_send_query('r290_w', p_writer_sql);
  end if;
  begin
    perform * from dblink_get_result('r290_op') as t(x text);
    insert into public.r290_outcome values (p_parent, 'operator', '00000', null);
  exception when others then
    insert into public.r290_outcome values (p_parent, 'operator', sqlstate, left(sqlerrm, 200));
  end;
  if v_held then
    begin
      perform * from dblink_get_result('r290_w') as t(x text);
      insert into public.r290_outcome values (p_parent, 'writer', '00000', null);
    exception when others then
      insert into public.r290_outcome values (p_parent, 'writer', sqlstate, left(sqlerrm, 200));
    end;
  else
    insert into public.r290_outcome values (p_parent, 'writer', 'never sent', 'the operator was never seen holding the delta');
  end if;
  perform dblink_disconnect('r290_op');
  perform dblink_disconnect('r290_w');
end $f$;

select pg_temp.race('a290', true,  $w$update public.a290 set payload = 'updated' where id = 7$w$);
select pg_temp.race('c290', false,
  $w$do $d$ begin delete from public.c290 where id = 8; insert into public.c290 values (9500, 'inserted'); end $d$$w$);
select pg_temp.race('d290', true,  $w$update public.d290 set payload = 'd-updated' where id = 3$w$, 't290_writer');
update public.b290 set payload = 'b-updated' where id = 5;

-- ==================== the witnesses: each race happened as the defect needs it ====================
select is((select string_agg(s.parent || ':' || (s.writer_pid is not null)::text, ',' order by s.parent) from public.r290_seen s),
  'a290:true,c290:true,d290:true',
  'LIVENESS: in each race the operator saw the writer queued on the delta before it committed');
select is((select string_agg(o.parent || ':' || o.state || coalesce(' ' || o.msg, ''), ',' order by o.parent)
             from public.r290_outcome o where o.who = 'operator'),
  'a290:00000,c290:00000,d290:00000', 'GUARD: each operator''s rename (and take of the name) committed');
select is((select string_agg(d.parent || '=' || c.relname, ',' order by d.parent)
             from public.r290_delta d join pg_class c on c.oid = d.delta),
  'a290=a290_renamed_delta,b290=b290_pgpm_regrain_delta,c290=c290_renamed_delta,d290=d290_renamed_delta',
  'LIVENESS: each recorded delta is the same relation, renamed where an operator renamed it');
select ok(to_regclass('public.a290_pgpm_regrain_delta') is not null
          and to_regclass('public.a290_pgpm_regrain_delta') <> (select delta from public.r290_delta where parent = 'a290')::regclass
          and to_regclass('public.d290_pgpm_regrain_delta') is not null
          and to_regclass('public.d290_pgpm_regrain_delta') <> (select delta from public.r290_delta where parent = 'd290')::regclass,
  'LIVENESS: a table of the operator''s now holds each name a290''s and d290''s delta gave up');
select ok(to_regclass('public.c290_pgpm_regrain_delta') is null,
  'LIVENESS: nothing holds the name c290''s delta gave up');
select ok(not has_table_privilege('t290_writer', 'public.d290_pgpm_regrain_delta', 'INSERT'),
  'LIVENESS: the writer role holds nothing on the operator''s table under d290''s freed name');

-- ==================== the contract: every write goes on, into the recorded delta ====================
select is((select state || coalesce(' ' || msg, '') from public.r290_outcome where parent = 'a290' and who = 'writer'),
  '00000', 'a290: the write that queued behind the rename and the take of its name succeeds');
select is((select state || coalesce(' ' || msg, '') from public.r290_outcome where parent = 'c290' and who = 'writer'),
  '00000', 'c290: the write that queued behind the rename succeeds (not 42P01)');
select is((select state || coalesce(' ' || msg, '') from public.r290_outcome where parent = 'd290' and who = 'writer'),
  '00000', 'd290: the write of a role with no rights on the operator''s table succeeds (not 42501)');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.a290_renamed_delta), '7,7',
  'a290: the update''s keys are captured in the recorded (renamed) delta');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.c290_renamed_delta), '8,9500',
  'c290: the delete''s and the insert''s keys are captured in the recorded (renamed) delta');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.d290_renamed_delta), '3,3',
  'd290: the update''s keys are captured in the recorded (renamed) delta');
select is((select coalesce(string_agg(id::text, ','), '') from public.a290_pgpm_regrain_delta), '',
  'a290: the operator''s table under the freed name takes none');
select is((select coalesce(string_agg(id::text, ','), '') from public.d290_pgpm_regrain_delta), '',
  'd290: the operator''s table under the freed name takes none');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.b290_pgpm_regrain_delta), '5,5',
  'the control: b290''s capture, its delta left alone, logs its write');

-- the operator's table does take a row of the capture's shape: the empties above are not a refusal
insert into public.a290_pgpm_regrain_delta values (-1);
select ok(exists (select 1 from public.a290_pgpm_regrain_delta where id = -1),
  'LIVENESS: the operator''s table under a290''s freed name accepts a row of the capture''s shape');
delete from public.a290_pgpm_regrain_delta where id = -1;

-- ==================== the swap honours every captured write, by row ====================
select is(pgpm._regrain_delta_count('public.a290') || ',' || pgpm._regrain_delta_count('public.c290')
          || ',' || pgpm._regrain_delta_count('public.d290'), '2,2,2',
  'the swap gate counts each renamed delta''s captured keys as pending');
select matches(pg_temp.to_swap('public.a290', 'a290_p0000000000000000000_to_0000000000000200000'), '^swapped:', 'a290''s regrain swaps');
select matches(pg_temp.to_swap('public.b290', 'b290_p0000000000000000000_to_0000000000000200000'), '^swapped:', 'b290''s regrain swaps');
select matches(pg_temp.to_swap('public.c290', 'c290_p0000000000000000000_to_0000000000000200000'), '^swapped:', 'c290''s regrain swaps');
select matches(pg_temp.to_swap('public.d290', 'd290_p0000000000000000000_to_0000000000000200000'), '^swapped:', 'd290''s regrain swaps');
select ok(to_regclass('public.a290_p0000000000000000000_to_0000000000000200000') is null
          and to_regclass('public.b290_p0000000000000000000_to_0000000000000200000') is null
          and to_regclass('public.c290_p0000000000000000000_to_0000000000000200000') is null
          and to_regclass('public.d290_p0000000000000000000_to_0000000000000200000') is null,
  'LIVENESS: each source is gone, so the rows below come from the attached copies and the reconcile');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.a290 where id in (6, 7, 8)),
  '6=orig,7=updated,8=orig', 'a290 keeps the committed update of row 7 after the swap');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.c290 where id in (7, 8, 9, 9500)),
  '7=orig,9=orig,9500=inserted', 'c290 keeps the delete of row 8 and the insert of 9500 after the swap');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.d290 where id in (2, 3, 4)),
  '2=orig,3=d-updated,4=orig', 'd290 keeps the role''s committed update of row 3 after the swap');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.b290 where id in (4, 5, 6)),
  '4=orig,5=b-updated,6=orig', 'the control: b290 keeps its update');
select is((select string_agg(c.relname, ',' order by c.relname) from public.r290_delta d join pg_class c on c.oid = d.delta),
  'a290_renamed_delta,b290_pgpm_regrain_delta,c290_renamed_delta,d290_renamed_delta',
  'each recorded delta, read by oid, is still there after its swap');
select is((select count(*)::int from public.a290_renamed_delta) + (select count(*)::int from public.c290_renamed_delta)
          + (select count(*)::int from public.d290_renamed_delta), 0,
  'and each swap consumed the keys its renamed delta held');
select ok(to_regclass('public.a290_pgpm_regrain_delta') is not null and to_regclass('public.d290_pgpm_regrain_delta') is not null,
  'the operator''s tables under the freed names survive the swaps');
select is((select count(*)::int from public.a290_pgpm_regrain_delta) + (select count(*)::int from public.d290_pgpm_regrain_delta), 0,
  'and are still empty');

drop owned by t290_writer;
drop role t290_writer;

select * from finish();
