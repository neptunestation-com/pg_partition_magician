-- regrain's change capture writes its delta by the oid the prepare tick recorded (issue #1051).
--
-- Since #496 every reader of the regrain delta (the reconcile, the swap gate, the swap, regrain_cancel,
-- uninstall) resolves it by pgpm.config.regrain_delta_oid, and docs/reference.md says the trigger "keeps
-- writing the delta it was given". But the capture function _regrain_capture_install minted carried
-- `insert into <nsp>.<rel>_pgpm_regrain_delta` in its body, so renaming the recorded delta mid-regrain
-- refused EVERY write into the regraining source (42P01) for the life of the regrain, nothing was captured,
-- and a table the operator then created under the freed name took the captured keys, which the reconcile
-- and the swap never read. It is the core sibling of #1037 bullet 1 (the hypertable capture, PR #1049).
--
-- ASYMMETRIC FIXTURE. Three parents, each with a regrain in flight on its frozen monolith.
--   a288 (1000 rows + 2): copied to the swap's doorstep, then its recorded delta is RENAMED; three writes
--     land (update 7, delete 8, insert 9500); the operator creates a table of the delta's shape under the
--     name it gave up; a fourth write lands (insert 9600). The renamed delta must hold exactly those keys,
--     the operator's table none, and the swap must honour all four, by row.
--   b288 (600 rows + 2), the control: its delta keeps its name and takes one write (update 5).
--   c288 (300 rows + 2): its recorded delta is DROPPED; a write is refused by pgpm's own 42P01 naming the
--     remedy (not a syntax error at the bare oid the capture now carries), and the remedy works: the next
--     tick restarts the run and re-mints capture, after which the same write is captured.
-- Every negative is paired with a witness that its condition was present: the minted name really is free
-- (and then really is taken), the row really was already copied, the operator's table really accepts a row
-- of the capture's shape. bench/regrain_capture_delta_by_record.sh runs this file against the mutant that
-- puts the by-name insert back (regrain_capture_delta_insert_by_name), so it is required to FAIL there.
create extension if not exists pgtap;
select plan(28);

-- copy a regrain to the swap's doorstep: the cursor at hi, the next tick the swap. regrain_step commits
-- nothing itself, so a loop in one function is fine; nothing here reads the counters this repo warns about.
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

create table public.a288 (id bigint primary key, payload text);
insert into public.a288 select g, 'orig' from generate_series(1, 1000) g;
insert into public.a288 values (199999, 'widen');
call pgpm.transmute('public.a288', 'id', 100000);
select pgpm.obtain('public.a288');
insert into public.a288 values (350000, 'frontier');   -- the frontier leaves the monolith: it is frozen

create table public.b288 (id bigint primary key, payload text);
insert into public.b288 select g, 'orig' from generate_series(1, 600) g;
insert into public.b288 values (199999, 'widen');
call pgpm.transmute('public.b288', 'id', 100000);
select pgpm.obtain('public.b288');
insert into public.b288 values (350000, 'frontier');

select is(pgpm.regrain_step('public.a288', 'a288_p0000000000000000000_to_0000000000000200000', '20000', 5000)
          || ',' || pgpm.regrain_step('public.b288', 'b288_p0000000000000000000_to_0000000000000200000', '20000', 5000),
  'prepared,prepared', 'LIVENESS: tick 1 prepares each regrain: capture is installed on each source');
select is((select string_agg(regrain_delta_oid::regclass::text, ',' order by parent_table::text) from pgpm.config
            where parent_table in ('public.a288'::regclass, 'public.b288'::regclass)),
  'a288_pgpm_regrain_delta,b288_pgpm_regrain_delta',
  'LIVENESS: each prepare recorded the delta it minted, by oid, under its own name');

select pg_temp.to_doorstep('public.a288', 'a288_p0000000000000000000_to_0000000000000200000');
select pg_temp.to_doorstep('public.b288', 'b288_p0000000000000000000_to_0000000000000200000');
select is((select string_agg(payload, ',' order by id) from public.a288_p0000000000000000000 where id in (7, 8)),
  'orig,orig', 'LIVENESS: rows 7 and 8 are already copied, so only capture can carry what follows to the swap');

-- ==================== (A) the operator renames a288's recorded delta mid-regrain ====================
alter table public.a288_pgpm_regrain_delta rename to a288_renamed_delta;
select is((select delta from pgpm._regrain_capture_names('public.a288')), 'a288_renamed_delta',
  'LIVENESS: pgpm''s readers find the renamed delta by its recorded oid');
select ok(to_regclass('public.a288_pgpm_regrain_delta') is null,
  'LIVENESS: nothing holds the name the delta was minted under');

select lives_ok($$update public.a288 set payload = 'updated' where id = 7$$,
  'an UPDATE of the regraining source succeeds after its recorded delta is renamed');
select lives_ok($$delete from public.a288 where id = 8$$,
  'a DELETE from the regraining source succeeds after its recorded delta is renamed');
select lives_ok($$insert into public.a288 values (9500, 'inserted')$$,
  'an INSERT into the regraining source succeeds after its recorded delta is renamed');
update public.b288 set payload = 'b-updated' where id = 5;

-- the operator then takes the name the delta gave up, for a table of the capture's shape
create table public.a288_pgpm_regrain_delta (id bigint);
insert into public.a288_pgpm_regrain_delta values (-1);
select is((select string_agg(id::text, ',') from public.a288_pgpm_regrain_delta), '-1',
  'LIVENESS: the operator''s table under the freed name accepts a row of the capture''s shape');
delete from public.a288_pgpm_regrain_delta;
select lives_ok($$insert into public.a288 values (9600, 'after-squat')$$,
  'a write into the source succeeds after another table takes the name the delta gave up');

select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.a288_renamed_delta),
  '7,7,8,9500,9600', 'every write after the rename is captured in the recorded (renamed) delta, by key');
select is((select count(*)::int from public.a288_pgpm_regrain_delta), 0,
  'and none in the operator''s table under the name the delta gave up');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.b288_pgpm_regrain_delta),
  '5,5', 'the control: b288''s capture, its delta never renamed, logs its write');
select is(pgpm._regrain_delta_count('public.a288'), 5::bigint,
  'the swap gate counts the renamed delta''s 5 captured keys as pending');

-- the swap reconciles each capture by the delta it recorded
select matches(pg_temp.to_swap('public.a288', 'a288_p0000000000000000000_to_0000000000000200000'),
  '^swapped:', 'a288''s regrain swaps');
select matches(pg_temp.to_swap('public.b288', 'b288_p0000000000000000000_to_0000000000000200000'),
  '^swapped:', 'b288''s regrain swaps');
select ok(to_regclass('public.a288_p0000000000000000000_to_0000000000000200000') is null
          and to_regclass('public.b288_p0000000000000000000_to_0000000000000200000') is null,
  'LIVENESS: each source is gone, so the rows below come from the attached copies and the reconcile');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.a288
            where id in (6, 7, 8, 9, 9500, 9600)),
  '6=orig,7=updated,9=orig,9500=inserted,9600=after-squat',
  'a288 holds every write made after the rename: 7 updated, 8 deleted, 9500 and 9600 inserted');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.b288 where id in (4, 5, 6)),
  '4=orig,5=b-updated,6=orig', 'the control: b288 holds its update');
select is((select count(*)::int from public.a288_renamed_delta), 0,
  'the swap consumed the renamed delta it read by oid');
select is((select regrain_delta_oid from pgpm.config where parent_table = 'public.a288'::regclass),
  'public.a288_renamed_delta'::regclass::oid, 'and the record still names the renamed delta');
select ok(to_regclass('public.a288_pgpm_regrain_delta') is not null
          and (select count(*) from public.a288_pgpm_regrain_delta) = 0,
  'the operator''s table under the freed name survives the swap, empty');

-- ==================== (C) a recorded delta dropped by hand ====================
create table public.c288 (id bigint primary key, payload text);
insert into public.c288 select g, 'orig' from generate_series(1, 300) g;
insert into public.c288 values (199999, 'widen');
call pgpm.transmute('public.c288', 'id', 100000);
select pgpm.obtain('public.c288');
insert into public.c288 values (350000, 'frontier');
select is(pgpm.regrain_step('public.c288', 'c288_p0000000000000000000_to_0000000000000200000', '20000', 5000),
  'prepared', 'LIVENESS: c288''s prepare installs capture');
update public.c288 set payload = 'c-updated' where id = 3;
select is((select string_agg(id::text, ',' order by pgpm_seq) from public.c288_pgpm_regrain_delta), '3,3',
  'LIVENESS: c288''s capture logs a write into its delta before the delta is dropped');
drop table public.c288_pgpm_regrain_delta;
select throws_like($$update public.c288 set payload = 'refused' where id = 4$$,
  'pg_partition_magician: the regrain change capture of public.c288 has lost the delta table the prepare tick recorded%The next pgpm.regrain_step tick%restarts the regrain%',
  'a write into a source whose recorded delta is gone is refused by pgpm, naming the remedy');
select matches(pgpm.regrain_step('public.c288', 'c288_p0000000000000000000_to_0000000000000200000', '20000', 5000),
  '^restarted:', 'the remedy the refusal names works: the next tick restarts the regrain');
update public.c288 set payload = 'c-after' where id = 4;
select is((select regrain_delta_oid::regclass::text from pgpm.config where parent_table = 'public.c288'::regclass),
  'c288_pgpm_regrain_delta', 'the restart re-minted the delta and recorded it');
select is((select string_agg(id::text, ',' order by pgpm_seq) from public.c288_pgpm_regrain_delta),
  '4,4', 'and the write it refused before is captured there');

select * from finish();
