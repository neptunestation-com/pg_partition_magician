-- forget_missing() logs where every archived chunk of the parent it forgets was written (issue #1164).
--
-- THE DEFECT. pgpm.forget_missing() deleted every pgpm.archive_ledger row of a parent whose relation is gone,
-- retired rows included, and its forget_missing log row carried no object key. A row retire() marked retired
-- (#1141) is the record of the only copy of its chunk's rows: its partition is gone and its object holds them. So
-- after the runbook's documented path for a table past its monolith (drop the table, run forget_missing()),
-- nothing in pgpm said where those rows were.
--
-- THE CONTRACT.
--   * The forget_missing log row of a parent that had ledger rows names every one of them in `method`: its range,
--     its object key (quote_literal'd, or `no object key` for a strategy that names none), and `retired` when
--     retire() had dropped its partition. pgpm.log is append-only, so that row outlives the ledger rows.
--   * The ledger rows themselves are still cleared: the parent's oid is dead and PostgreSQL reuses oids, and a
--     retired row left under it would read as a later table's retired range (skip_archive_retired_range) and
--     collide with its first chunk's (parent_table, lo).
--   * Nothing else changes: a parent with no ledger rows logs exactly the method it always did, and a live
--     managed table keeps its ledger rows, none of which appears in the forgotten parent's row.
--
-- ASYMMETRIC FIXTURES. The dropped parent t318.t has THREE chunks: [0, 100) keyed and retired, [100, 200) keyed and
-- not retired, [200, 300) with no key. The live parent t318.u has ONE keyed chunk. The second dropped parent
-- t318.w has none. Each check names the chunk.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(12);

create schema t318;

-- a strategy that names an object key by parent and lo, as a transport does, except for lo 200, which it
-- archives with no key (the shape of the 'none' strategy)
create function t318.strat(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language sql as $$
  select (p_hi, 1::bigint,
          case when p_lo = '200' then null else p_parent::text || '/' || p_lo end,
          'etag')::pgpm.archive_result $$;

-- t318.t: the table that is dropped by hand, with three archived chunks
create table t318.t (id bigint primary key, payload text not null);
insert into t318.t select g, 'old' || g from generate_series(1, 90) g;
call pgpm.transmute('t318.t', 'id', 100, p_retain => 100::bigint, p_paused => false);
insert into t318.t select g, 'mid' || g from generate_series(110, 120) g;
insert into t318.t select g, 'late' || g from generate_series(210, 215) g;
insert into t318.t values (450, 'frontier');
update pgpm.config set retain_batch = 0, archive_batch = 10 where parent_table = 't318.t'::regclass;
select pgpm.set_archive_fn('t318.t', 't318.strat(regclass,name,text,text)'::regprocedure);

-- t318.u: a live managed table with one archived chunk, which forget_missing must leave alone
create table t318.u (id bigint primary key, payload text not null);
insert into t318.u select g, 'u' || g from generate_series(1, 40) g;
call pgpm.transmute('t318.u', 'id', 100, p_retain => 100::bigint, p_paused => false);
insert into t318.u values (250, 'frontier');
update pgpm.config set retain_batch = 0, archive_batch = 10 where parent_table = 't318.u'::regclass;
select pgpm.set_archive_fn('t318.u', 't318.strat(regclass,name,text,text)'::regprocedure);

-- t318.w: a second table dropped by hand, never archived
create table t318.w (id bigint primary key);
insert into t318.w select g from generate_series(1, 10) g;
call pgpm.transmute('t318.w', 'id', 100, p_paused => false);

call pgpm.maintain('t318.t');
call pgpm.maintain('t318.u');

select child_name as t_mono from pgpm.part where parent_table = 't318.t'::regclass and lo = '0' \gset
select 't318.t'::regclass::oid as t_oid, 't318.u'::regclass::oid as u_oid, 't318.w'::regclass::oid as w_oid \gset

select ok(pgpm.retire('t318.t', :'t_mono'), 'LIVENESS: retire() dropped t318.t''s covered monolith [0, 100)');

select results_eq(
  $$ select lo, hi, s3_key, retired_at is not null from pgpm.archive_ledger
      where parent_table = 't318.t'::regclass order by lo $$,
  $$ values ('0', '100', 't318.t/0', true), ('100', '200', 't318.t/100', false), ('200', '300', null, false) $$,
  'LIVENESS: t318.t has three chunks: [0, 100) keyed and retired, [100, 200) keyed and live, [200, 300) keyless');

select results_eq(
  $$ select lo, hi, s3_key, retired_at is null from pgpm.archive_ledger where parent_table = 't318.u'::regclass $$,
  $$ values ('0', '100', 't318.u/0', true) $$,
  'LIVENESS: the live table t318.u has its one keyed chunk [0, 100)');

drop table t318.t;
drop table t318.w;

select ok(not exists (select 1 from pg_class where oid in (:t_oid, :w_oid)),
  'LIVENESS: t318.t and t318.w were dropped by hand (both oids gone)');

create table t318.report as select * from pgpm.forget_missing();

select results_eq(
  $$ select parent_oid from t318.report order by parent_oid $$,
  format('select unnest(array[%s, %s]::oid[]) order by 1', :t_oid, :w_oid),
  'LIVENESS: forget_missing() forgot exactly the two dropped parents, t318.t and t318.w');

-- the contract: the forget_missing row names every chunk of t318.t, key, range and retirement
select is(
  (select method from pgpm.log where action = 'forget_missing' and parent_table = :'t_oid'::oid::regclass),
  'relation was gone; pgpm state cleared. ARCHIVED CHUNKS, their pgpm.archive_ledger rows cleared '
  '(each chunk''s range, then the object its rows were written to): '
  '[0, 100) ''t318.t/0'' retired, [100, 200) ''t318.t/100'', [200, 300) no object key',
  'the forget_missing row for t318.t names its three chunks: [0, 100) t318.t/0 retired, [100, 200) t318.t/100, '
  '[200, 300) with no key');

select ok(
  (select method from pgpm.log where action = 'forget_missing' and parent_table = :'t_oid'::oid::regclass)
    like '%[0, 100) ''t318.t/0'' retired%',
  'in particular it names the object key t318.t/0 of the retired chunk [0, 100), the only copy of its rows');

select ok(
  (select method from pgpm.log where action = 'forget_missing' and parent_table = :'t_oid'::oid::regclass)
    not like '%t318.u%',
  'and nothing of the live table t318.u, whose chunk is not being forgotten');

select is(
  (select method from pgpm.log where action = 'forget_missing' and parent_table = :'w_oid'::oid::regclass),
  'relation was gone; pgpm state cleared',
  't318.w, which archived nothing, logs exactly the method a forgotten parent always logged');

-- the ledger rows still go: the oid is dead and recyclable
select is(
  (select count(*)::int from pgpm.archive_ledger where parent_table::oid = :t_oid), 0,
  'no ledger row is left under t318.t''s dead oid, retired or not, for a table that later lands on it to inherit');

select results_eq(
  $$ select lo, hi, s3_key, retired_at is null from pgpm.archive_ledger where parent_table = 't318.u'::regclass $$,
  $$ values ('0', '100', 't318.u/0', true) $$,
  'the live table t318.u keeps its chunk [0, 100) t318.u/0 as it was');

select is((select count(*)::int from pgpm.forget_missing()), 0,
  'forget_missing() is a no-op the second time: nothing is missing now');

select * from finish();
