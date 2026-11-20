-- Measurement 1 of docs/formal/phase3-design.md ("Measured before it is relied on"): does the sql_drop trigger
-- attribute pgpm's drops to pgpm and a test's drops to the test, including inside procedures that COMMIT, and is
-- pgpm.part's row for a dropped partition still there when the trigger fires (ResolveByRecord reads it)?
--
-- Two attributions are recorded for every drop and compared here:
--   by_query  the design note's first proposal: pg_stat_activity's top-level statement for pg_backend_pid()
--             begins `call pgpm.` or `select pgpm.`
--   by_pgpm   what the oracle relies on: a PL/pgSQL frame of schema pgpm (or archive) is on the call stack
--             (GET DIAGNOSTICS ... = PG_CONTEXT) when the trigger fires
-- Each case's row is selected by the dropped table's name, so a case whose drop never happened fails on a null.
create extension if not exists pgtap;

select plan(23);

create schema at;

create function at.mk(p_rel text) returns void language plpgsql as $$
begin
  execute format('create table %s (id bigint primary key, payload text)', p_rel);
  execute format('insert into %s select g, ''p'' || g from generate_series(1, 5) g', p_rel);
end $$;
create function at.fill(p_rel text) returns void language plpgsql as $$
begin
  execute format('insert into %s select g, ''p'' || g from generate_series(12, 89, 7) g', p_rel);
  execute format('insert into %s values (95, ''frontier'')', p_rel);
end $$;
-- one dropped table's attribution: by_pgpm, by_query, part_row, whether it ran after a COMMIT inside the statement
create function at.h(p_name text) returns text language sql as $$
  select string_agg(format('pgpm=%s query=%s part_row=%s after_commit=%s', by_pgpm, by_query, part_row,
                           xact_start > stmt_start), '; ' order by id)
    from pgpm_formal.drop_history where schema_name = 'at' and object_name = p_name;
$$;

select at.mk('at.r1'); call pgpm.transmute('at.r1', 'id', 10, p_retain => 30, p_obtain => 10); select at.fill('at.r1');
select at.mk('at.r2'); call pgpm.transmute('at.r2', 'id', 10, p_retain => 30, p_obtain => 10); select at.fill('at.r2');
select at.mk('at.r3'); call pgpm.transmute('at.r3', 'id', 10, p_retain => 30, p_obtain => 10); select at.fill('at.r3');
select at.mk('at.r4'); call pgpm.transmute('at.r4', 'id', 10, p_retain => 30, p_obtain => 10); select at.fill('at.r4');
select at.mk('at.r5'); call pgpm.transmute('at.r5', 'id', 10, p_retain => 30, p_obtain => 10); select at.fill('at.r5');
select at.mk('at.r6'); call pgpm.transmute('at.r6', 'id', 10, p_retain => 30, p_obtain => 10); select at.fill('at.r6');
select at.mk('at.r7'); call pgpm.transmute('at.r7', 'id', 10, p_retain => 30, p_obtain => 10); select at.fill('at.r7');
create table at.x1 (id int); create table at.x2 (id int); create table at.x3 (id int);
create table at.x4 (id int); create table at.x5 (id int);

-- 1. pgpm's drop from a top-level `select pgpm.retain(...)`
select pgpm.retain('at.r1');
select is(at.h('r1_p0000000000000000010'), 'pgpm=t query=t part_row=t after_commit=f',
  'retain() called as the statement: both attribute the drop to pgpm, and the partition''s pgpm.part row was there');

-- 2. pgpm's drop from `call pgpm.maintain(...)`, a procedure that COMMITs between its steps
select pgpm.resume('at.r2');
call pgpm.maintain('at.r2');
select is(at.h('r2_p0000000000000000010'), 'pgpm=t query=t part_row=t after_commit=t',
  'maintain() as a CALL: the drop ran after a COMMIT inside the procedure, and both still attribute it to pgpm');

-- 3. pgpm's drop from retain() wrapped in an assertion, as most test files call it
select is(pgpm.retain('at.r3'), 6, 'fixture: retain() drops the six aged partitions of at.r3');
select is(at.h('r3_p0000000000000000010'), 'pgpm=t query=f part_row=t after_commit=f',
  'retain() inside is(): the call stack attributes the drop to pgpm, the statement text does not');

-- 4. the test's own top-level DROP
drop table at.x1;
select is(at.h('x1'), 'pgpm=f query=f part_row=f after_commit=f',
  'the test''s DROP TABLE: neither attributes it to pgpm');

-- 5. the test's DROP inside its own procedure, after a COMMIT
create procedure at.p() language plpgsql as $$
begin
  commit;
  drop table at.x2;
end $$;
call at.p();
select is(at.h('x2'), 'pgpm=f query=f part_row=f after_commit=t',
  'the test''s DROP after a COMMIT in its own procedure: neither attributes it to pgpm');

-- 6. the test's DROP in a DO block that has just called pgpm
do $$
begin
  perform pgpm.obtain('at.r1');
  drop table at.x3;
end $$;
select is(at.h('x3'), 'pgpm=f query=f part_row=f after_commit=f',
  'the test''s DROP in a DO block after a pgpm call: neither attributes it to pgpm (pgpm''s frame has returned)');

-- 6b. pgpm's drops reached through the wrappers custody tests use: a DO block (tests/125 runs maintenance in a DO
-- loop), a DO block calling the committing procedure, and a pgTAP lives_ok()
do $$
begin
  perform pgpm.retain('at.r5');
end $$;
select is(at.h('r5_p0000000000000000010'), 'pgpm=t query=f part_row=t after_commit=f',
  'retain() in a DO block: the call stack attributes the drop to pgpm, the statement text does not');
select pgpm.resume('at.r7');
do $$
declare v_status text;
begin
  call pgpm.maintain('at.r7', v_status);
end $$;
select is(at.h('r7_p0000000000000000010'), 'pgpm=t query=f part_row=t after_commit=t',
  'maintain() called from a DO block: after its COMMIT, the call stack still attributes the drop to pgpm');
select lives_ok($$ select pgpm.retain('at.r6') $$, 'fixture: retain() inside lives_ok()');
select is(at.h('r6_p0000000000000000010'), 'pgpm=t query=f part_row=t after_commit=f',
  'retain() inside lives_ok(): the call stack attributes the drop to pgpm, the statement text does not');
select lives_ok($$ drop table at.x5 $$, 'fixture: the test''s DROP inside lives_ok()');
select is(at.h('x5'), 'pgpm=f query=f part_row=f after_commit=f',
  'the test''s DROP inside lives_ok(): neither attributes it to pgpm');

-- 7. a transaction block: pgpm drops, then the test drops, in one transaction. pg_stat_activity is snapshotted per
-- transaction (CLAUDE.md, tests/269), so the second read of the backend's own row still shows the first statement.
begin;
select pgpm.retain('at.r4');
drop table at.x4;
commit;
select is(at.h('r4_p0000000000000000010'), 'pgpm=t query=t part_row=t after_commit=f',
  'fixture: in the transaction block, pgpm''s drop is attributed to pgpm by both');
select is(at.h('x4'), 'pgpm=f query=t part_row=f after_commit=f',
  'in the same transaction, the test''s DROP is misattributed to pgpm by the statement text (a stale snapshot), not by the call stack');

-- 8. under SET ROLE: the trigger still records a drop by a role that cannot write the history itself
do $$ begin create role pgpm_fx_attr nologin; exception when duplicate_object then null; end $$;
grant usage, create on schema at to pgpm_fx_attr;
set role pgpm_fx_attr;
create table at.x6 (id int);
drop table at.x6;
reset role;
select is(at.h('x6'), 'pgpm=f query=f part_row=f after_commit=f',
  'a drop under SET ROLE to a role with no grant on the history is still recorded (SECURITY DEFINER)');

-- 9. regrain's swap drops its coarse source. Its pgpm.part row is deleted BEFORE the DROP, so at the trigger only
-- pgpm.config.monolith_oid names the monolith, and nothing in pgpm's catalog names a coarse child pgpm made itself:
-- the creation history (created by pgpm) is what records it.
create table at.rg (id bigint primary key, body text);
insert into at.rg select g, 'b' || g from generate_series(1, 50) g;
call pgpm.transmute('at.rg', 'id', 100, p_obtain => 3, p_paused => true);
insert into at.rg values (350, 'frontier');
select is(pgpm.regrain_history('at.rg', '50'), 2, 'fixture: the monolith [0, 100) is regrained into [0, 50) and [50, 100)');
select is(pgpm.regrain_history('at.rg', '10'), 5, 'fixture: [0, 50), a child regrain made, is regrained into five');
select is(
  (select string_agg(object_name || ' part_row=' || part_row || ' as ' || coalesce(recorded_as, '-') || ' pgpm=' || by_pgpm, '; ' order by id)
     from pgpm_formal.drop_history where schema_name = 'at' and object_name like 'rg\_p0%'),
  'rg_p0000000000000000000_to_0000000000000000100 part_row=false as pgpm.config monolith_oid pgpm=true; '
  || 'rg_p0000000000000000000_to_0000000000000000050 part_row=false as created by pgpm pgpm=true',
  'regrain''s swaps drop their sources with no pgpm.part row left; the monolith is named by config, the child by its creation');

-- 10. untransmute drops the partitioned parent: recorded through pgpm.config
create table at.ut (id bigint primary key, body text);
insert into at.ut select g, 'b' || g from generate_series(1, 20) g;
call pgpm.transmute('at.ut', 'id', 100, p_obtain => 2);
select pgpm.untransmute('at.ut');
select is(
  (select string_agg(object_name || ' recorded=' || recorded || ' pgpm=' || by_pgpm, '; ' order by id)
     from pgpm_formal.drop_history where schema_name = 'at' and object_name = 'ut'),
  'ut recorded=true pgpm=true',
  'untransmute''s drop of the partitioned parent is recorded through pgpm.config');

-- the whole record: no drop the test made is attributed to pgpm, and every drop pgpm made was of a relation it recorded
select is(
  (select array_agg(distinct object_name order by object_name) from pgpm_formal.drop_history
    where schema_name = 'at' and by_pgpm and object_name !~ '^(r[1-7]|rg|ut)'),
  null::text[], 'no drop of a table the test created is attributed to pgpm');
select is(
  (select array_agg(object_name order by object_name) from pgpm_formal.drop_history
    where schema_name = 'at' and by_pgpm and recorded is not true),
  null::text[], 'every drop attributed to pgpm was of a relation pgpm recorded');
select cmp_ok((select count(*) from pgpm_formal.drop_history where schema_name = 'at' and by_pgpm), '>=', 20::bigint,
  'LIVENESS: pgpm made at least 20 of the drops judged above');

select * from finish();
drop owned by pgpm_fx_attr;
drop role pgpm_fx_attr;
