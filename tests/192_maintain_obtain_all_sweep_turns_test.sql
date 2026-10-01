-- Issue #634: maintain_obtain_all must sweep in maintain_all's turn order, and take turns the same way.
--
-- THE DEFECT. docs/reference.md says maintain_obtain_all calls maintain_obtain for every managed table "in
-- the same table order as maintain_all", and maintain_all visits the table whose turn is oldest first
-- (config.sweep_turn_at, nulls first, #579). maintain_obtain_all swept `order by parent_table` instead. Its
-- sweep is one top-level statement too, so statement_timeout runs across every table in it and the
-- query_canceled that ends it escapes maintain_obtain's `when others`: in a fixed order, a table whose obtain
-- overran the clock was first on every sweep and every table behind it was cut short on every sweep. obtain
-- is the step whose lateness refuses writes (there is no DEFAULT partition, #288).
--
-- THE FIX gives the obtain sweep maintain_all's order and its turn stamps: oldest sweep_turn_at first, the
-- sweep's first table stamped before it starts, every table stamped when its maintain_obtain returns, each
-- stamp through _config_try_lock (#662). One turn record serves both sweeps, so a table either sweep cut
-- short leads the next sweep of both.
--
-- Three parts:
--   A. The order. Three tables whose oid order (oa, oc, ob) differs from their turn order (ob never had a
--      turn, oc's is older than oa's): the sweep must obtain ob, then oc, then oa, and stamp each.
--   B. The stamp never stops the sweep. Another session holds oc's config row; the sweep still completes,
--      skips only oc's stamp, and stamps the others.
--   C. A table that overruns the shared clock on its own. sa (lower oid) has an obtain that cannot fit the
--      sweep's statement_timeout (an event trigger sleeps in its partition's CREATE TABLE); sb behind it
--      needs one partition. Sweep 1 must be cut in sa; sweep 2 must lead with sb and build its partition.
--      The event trigger counts its entries in a SEQUENCE, which a cancellation does not roll back, so "sa
--      was entered and cut short" is observed rather than inferred from nothing having happened.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(18);

create schema s192;
-- Is p's config row held by another transaction? NOWAIT, in a statement of its own (as tests/167).
create function s192.held(p regclass) returns boolean language plpgsql as $$
begin
  perform 1 from pgpm.config where parent_table = p for no key update nowait;
  return false;
exception when lock_not_available then
  return true;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- Part A: the order
-- ---------------------------------------------------------------------------------------------------
create table public.oa (id bigint primary key, v text);
insert into public.oa values (1, 'a');
create table public.oc (id bigint primary key, v text);
insert into public.oc values (1, 'c'), (2, 'c');
create table public.ob (id bigint primary key, v text);
insert into public.ob values (1, 'b'), (2, 'b'), (3, 'b');
call pgpm.transmute('public.oa', 'id', 1000, p_obtain => 3, p_paused => false);
call pgpm.transmute('public.oc', 'id', 1000, p_obtain => 3, p_paused => false);
call pgpm.transmute('public.ob', 'id', 1000, p_obtain => 3, p_paused => false);
call pgpm.maintain_obtain_all();
-- every table needs two more partitions this sweep; the turns are set by hand: every other managed table
-- (the suite's fixtures) has a recent turn, oa the most recent of the three, oc an older one, ob none
select pgpm.set_obtain('public.oa', 5);
select pgpm.set_obtain('public.oc', 5);
select pgpm.set_obtain('public.ob', 5);
update pgpm.config set sweep_turn_at = clock_timestamp()
 where parent_table not in ('public.oa'::regclass, 'public.oc'::regclass, 'public.ob'::regclass);
update pgpm.config set sweep_turn_at = clock_timestamp() - interval '1 hour' where parent_table = 'public.oa'::regclass;
update pgpm.config set sweep_turn_at = clock_timestamp() - interval '2 hours' where parent_table = 'public.oc'::regclass;
update pgpm.config set sweep_turn_at = null where parent_table = 'public.ob'::regclass;
select coalesce(max(id), 0) as mark from pgpm.log \gset
select clock_timestamp() as before_a \gset

select ok('public.oa'::regclass::oid < 'public.oc'::regclass::oid
          and 'public.oc'::regclass::oid < 'public.ob'::regclass::oid,
  'LIVENESS: the fixed order the sweep used to follow is oa, oc, ob');
select is(array(select parent_table::text from pgpm.config
                 where parent_table in ('public.oa'::regclass, 'public.oc'::regclass, 'public.ob'::regclass)
                 order by sweep_turn_at asc nulls first, parent_table),
  array['ob', 'oc', 'oa'],
  'LIVENESS: maintain_all''s order for these three is ob, oc, oa');

call pgpm.maintain_obtain_all();

select is(array(select parent_table::text from pgpm.log
                 where id > :mark and action = 'obtain'
                   and parent_table in ('public.oa'::regclass, 'public.oc'::regclass, 'public.ob'::regclass)
                 group by parent_table order by min(id)),
  array['ob', 'oc', 'oa'],
  'maintain_obtain_all obtains in maintain_all''s order: ob, then oc, then oa');
select is((select array_agg(parent_table::text || ':' || hi order by parent_table::text) from pgpm.part p
            where parent_table in ('public.oa'::regclass, 'public.oc'::regclass, 'public.ob'::regclass)
              and attached and hi::bigint = (select max(hi::bigint) from pgpm.part q
                                              where q.parent_table = p.parent_table and q.attached)),
  array['oa:6000', 'ob:6000', 'oc:6000'],
  'LIVENESS: every one of the three built its lookahead out to 6000 on that sweep');
select ok((select bool_and(sweep_turn_at > :'before_a'::timestamptz) from pgpm.config
            where parent_table in ('public.oa'::regclass, 'public.oc'::regclass, 'public.ob'::regclass)),
  'and stamped each one''s turn');
select is(array(select parent_table::text from pgpm.config
                 where parent_table in ('public.oa'::regclass, 'public.oc'::regclass, 'public.ob'::regclass)
                 order by sweep_turn_at),
  array['ob', 'oc', 'oa'],
  'in the order it visited them, so a sweep that is not cut short keeps the order');

-- ---------------------------------------------------------------------------------------------------
-- Part B: a held config row costs that table's stamp, not the sweep
-- ---------------------------------------------------------------------------------------------------
select dblink_connect('h192', 'dbname=' || current_database());
select sweep_turn_at as oc_turn from pgpm.config where parent_table = 'public.oc'::regclass \gset
select clock_timestamp() as before_b \gset
select dblink_exec('h192', 'begin');
select r from dblink('h192', 'select parent_table::text from pgpm.config where parent_table = ''public.oc''::regclass for no key update') as t(r text);
select ok(s192.held('public.oc') and not s192.held('public.oa') and not s192.held('public.ob'),
  'LIVENESS: another session holds oc''s config row, and not oa''s or ob''s');

set lock_timeout = '5s';   -- a stamp that waited would end as an error, not hang the suite
\set ON_ERROR_STOP 0
call pgpm.maintain_obtain_all();
\set ON_ERROR_STOP 1
reset lock_timeout;
select ok(s192.held('public.oc'), 'LIVENESS: the holder was still open when the sweep returned');
select ok((select bool_and(sweep_turn_at > :'before_b'::timestamptz) from pgpm.config
            where parent_table in ('public.oa'::regclass, 'public.ob'::regclass)),
  'the sweep completed and stamped oa and ob, on either side of the held row');
select is((select sweep_turn_at from pgpm.config where parent_table = 'public.oc'::regclass),
  :'oc_turn'::timestamptz,
  'and skipped only oc''s stamp');
select dblink_exec('h192', 'rollback');
select dblink_disconnect('h192');

-- ---------------------------------------------------------------------------------------------------
-- Part C: sa overruns the clock on its own, ahead of sb
-- ---------------------------------------------------------------------------------------------------
create table public.sa (id bigint primary key, v text);
insert into public.sa values (1, 'a');
create table public.sb (id bigint primary key, v text);
insert into public.sb values (1, 'b'), (2, 'b');
call pgpm.transmute('public.sa', 'id', 1000, p_obtain => 2, p_paused => false);
call pgpm.transmute('public.sb', 'id', 1000, p_obtain => 2, p_paused => false);
call pgpm.maintain_obtain_all();
select pgpm.set_obtain('public.sa', 3);
select pgpm.set_obtain('public.sb', 3);
-- every other table has had a turn; sa and sb have not, so sa (lower oid) leads sweep 1
update pgpm.config set sweep_turn_at = clock_timestamp()
 where parent_table not in ('public.sa'::regclass, 'public.sb'::regclass);
update pgpm.config set sweep_turn_at = null where parent_table in ('public.sa'::regclass, 'public.sb'::regclass);

create sequence s192.sa_entered;
create function s192.slow_sa() returns event_trigger language plpgsql as $$
begin
  if exists (select 1 from pg_event_trigger_ddl_commands() c join pg_inherits i on i.inhrelid = c.objid
              where c.command_tag = 'CREATE TABLE' and i.inhparent = 'public.sa'::regclass) then
    perform nextval('s192.sa_entered');
    perform pg_sleep(3);   -- sa's obtain never fits the sweep's 1.5 s
  end if;
end $$;
create event trigger s192_slow_sa on ddl_command_end when tag in ('CREATE TABLE') execute function s192.slow_sa();
select coalesce(max(id), 0) as mark_c from pgpm.log \gset

select ok('public.sa'::regclass::oid < 'public.sb'::regclass::oid,
  'LIVENESS: sa precedes sb in the fixed order');

set statement_timeout = '1500ms';
\set ON_ERROR_STOP 0
call pgpm.maintain_obtain_all();
\set ON_ERROR_STOP 1
reset statement_timeout;

select is((select last_value::int from s192.sa_entered), 1,
  'LIVENESS: sweep 1 entered sa''s obtain');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.sa'::regclass and lo = '3000'),
  'LIVENESS: and sa''s obtain overran the clock (its partition [3000, 4000) was rolled back)');
select ok(not exists (select 1 from pgpm.log where id > :mark_c and parent_table = 'public.sb'::regclass
                       and action = 'obtain'),
  'LIVENESS: sweep 1 never reached sb');

set statement_timeout = '1500ms';
\set ON_ERROR_STOP 0
call pgpm.maintain_obtain_all();
\set ON_ERROR_STOP 1
reset statement_timeout;

select ok(exists (select 1 from pgpm.part where parent_table = 'public.sb'::regclass
                   and attached and lo = '3000' and hi = '4000'),
  'sweep 2: sa, which had its turn as sweep 1''s first table, did not lead again; sb did, and built [3000, 4000)');
select is((select array_agg(lo order by id) from pgpm.log where id > :mark_c and parent_table = 'public.sb'::regclass
            and action = 'obtain'),
  array['3000'],
  'and logged that one obtain');
select is((select last_value::int from s192.sa_entered), 2,
  'LIVENESS: sa was not dropped from the sweep; sweep 2 still gave it a turn');

drop event trigger s192_slow_sa;
call pgpm.maintain_obtain_all();
select ok(exists (select 1 from pgpm.part where parent_table = 'public.sa'::regclass
                   and attached and lo = '3000' and hi = '4000'),
  'LIVENESS: with the delay gone, sa''s obtain builds the same partition, so the delay was all that stopped it');

select * from finish();
