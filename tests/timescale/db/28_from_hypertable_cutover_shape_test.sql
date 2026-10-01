-- from_hypertable_cutover refuses to swap a copy whose shape is no longer the source's (issue #738).
--
-- THE BUG. from_hypertable_copy fixes the destination's shape once, by CREATE TABLE ... LIKE, and the
-- documented two-phase flow lets the workload (and its migrations) run on until the cutover. The cutover
-- read its column list and its conservation fingerprint from the SOURCE only, so it never noticed that the
-- copy had a different shape, and the swap renamed the stale copy into place: a column dropped after the
-- copy came back holding its old values, a default changed after the copy reverted, a CHECK added after
-- the copy was gone. Silently: no error, no log row. It now compares the two (columns with their type,
-- NOT NULL, collation and default; CHECK constraints; column order) and refuses, naming every difference.
--
-- WHAT THIS FILE PINS: DDL run before the cutover is called, which the check made up front refuses before
-- the pre-drain or the index pre-builds do anything. DDL that lands WHILE the cutover prepares, after that
-- check and before the lock, needs a second session; bench/hypertable_cutover_shape.sh drives it, runs this
-- file too, and is what the mutations are proven against. One assertion here (D, a column added since the
-- copy) is what separates the up-front check from the one under the lock: without the up-front check the
-- pre-lock reads of the copy (the pre-drain, the conservation baseline) die raw on the missing column
-- before the lock is ever reached.
--
-- WHY each refusal is pinned by its message. The cutover commits, and throws_like runs it inside a function,
-- where a cutover that does NOT refuse dies at its first COMMIT with 2D000 and rolls back into the state a
-- refusal leaves. The message, naming the difference, is the only thing that separates the two.
--
-- Autocommit, disposable-db. from_hypertable_copy and _cutover are called as bare statements.
select plan(16);

-- Four hypertables, one per kind of DDL, each copied and then changed on the source only. Each has rows
-- whose values the change would matter to: a non-null ssn, a v on the old default, a v the new CHECK allows.
create or replace function mk28(p_name text) returns void language plpgsql as $$
begin
  execute format('create table public.%I (id bigint not null, ts timestamptz not null, v text default ''old'',
                  ssn text, primary key (id, ts))', p_name);
  perform create_hypertable(format('public.%I', p_name), 'ts', chunk_time_interval => interval '1 day');
  execute format('insert into public.%I (id, ts, ssn) select g, timestamptz ''2026-09-01 00:00+00'' + g * interval ''5 hours'',
                  ''secret'' || g from generate_series(1, 12) g', p_name);
end $$;
do $$ begin perform mk28('s28a'); perform mk28('s28b'); perform mk28('s28c'); perform mk28('s28d'); end $$;
call pgpm.from_hypertable_copy('public.s28a', 'ts');
call pgpm.from_hypertable_copy('public.s28b', 'ts');
call pgpm.from_hypertable_copy('public.s28c', 'ts');
call pgpm.from_hypertable_copy('public.s28d', 'ts');
select is(
  (select string_agg(id || ':' || v || ':' || ssn, ',' order by id) from public.s28a_pgpm_dest where id <= 2)
    || ' ' || (select count(*) from public.s28d_pgpm_dest),
  '1:old:secret1,2:old:secret2 12', 'LIVENESS: the copies hold the rows, with their ssn and the old default');

-- The online window: each source changes shape, its copy does not.
alter table public.s28a drop column ssn;
alter table public.s28b alter column v set default 'new';
alter table public.s28c add constraint s28c_v_chk check (v <> 'forbidden');
alter table public.s28d add column note text default 'n/a';
select is(
  (select string_agg(attrelid::regclass || '.' || attname, ',' order by attrelid::regclass::text, attname) from pg_attribute
    where attrelid in ('public.s28a'::regclass, 'public.s28d'::regclass) and attnum > 0 and not attisdropped)
    || ' ' || (select pg_get_expr(adbin, adrelid) from pg_attrdef
                where adrelid = 'public.s28b'::regclass and adnum = (select attnum from pg_attribute
                                                                         where attrelid = 'public.s28b'::regclass and attname = 'v'))
    || ' ' || (select count(*) from pg_constraint where conrelid = 'public.s28c'::regclass and conname = 's28c_v_chk'),
  's28a.id,s28a.ts,s28a.v,s28d.id,s28d.note,s28d.ssn,s28d.ts,s28d.v ''new''::text 1',
  'LIVENESS: each source has changed shape (ssn dropped, default new, CHECK added, note added)');

-- ============================ A: a column dropped from the source ============================
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.s28a', 'ts', interval '1 day') $$,
  'pg_partition_magician: from_hypertable_cutover(s28a) refusing to swap: the copy s28a_pgpm_dest no longer has the source''s shape: column ssn is on the copy but no longer on the source. %',
  'A: a column dropped from the source since the copy is refused, by name');

-- ============================ B: a default changed on the source ============================
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.s28b', 'ts', interval '1 day') $$,
  'pg_partition_magician: from_hypertable_cutover(s28b) refusing to swap: the copy s28b_pgpm_dest no longer has the source''s shape: column v has default ''new''::text on the source but default ''old''::text on the copy. %',
  'B: a default changed on the source since the copy is refused, naming both defaults');

-- ============================ C: a CHECK added to the source ============================
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.s28c', 'ts', interval '1 day') $$,
  'pg_partition_magician: from_hypertable_cutover(s28c) refusing to swap: the copy s28c_pgpm_dest no longer has the source''s shape: CHECK s28c_v_chk (CHECK ((v <> ''forbidden''::text))) is on the source but not on the copy. %',
  'C: a CHECK added to the source since the copy is refused, naming the constraint');

-- ============================ D: a column added to the source ============================
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.s28d', 'ts', interval '1 day') $$,
  'pg_partition_magician: from_hypertable_cutover(s28d) refusing to swap: the copy s28d_pgpm_dest no longer has the source''s shape: column note is on the source but not on the copy. %',
  'D: a column added to the source since the copy is refused by name, not by a raw error on the missing column');

-- ============================ nothing was dropped ============================
select is(
  (select string_agg(hypertable_name::text, ',' order by hypertable_name) from timescaledb_information.hypertables
    where hypertable_schema = 'public' and hypertable_name::text like 's28_'),
  's28a,s28b,s28c,s28d', 'every source is still a hypertable after its refusal');
select is(
  (select string_agg(id || ':' || v, ',' order by id) from public.s28a),
  (select string_agg(g || ':old', ',' order by g) from generate_series(1, 12) g),
  'the source keeps every row, by identity');
select is(
  (select string_agg(c.relname::text, ',' order by c.relname) from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relname::text like 's28__pgpm_dest'),
  's28a_pgpm_dest,s28b_pgpm_dest,s28c_pgpm_dest,s28d_pgpm_dest', 'every copy is still there');
select is(
  (select count(*)::int from pg_class c join pg_index i on i.indexrelid = c.oid
    where i.indrelid in ('public.s28a_pgpm_dest'::regclass, 'public.s28d_pgpm_dest'::regclass)
      and c.relname like '%\_pgpm\_new'),
  0, 'and no pre-built index is left on one');

-- ============================ the remedy: a fresh copy, then the cutover ============================
call pgpm.from_hypertable_copy('public.s28a', 'ts');
call pgpm.from_hypertable_cutover('public.s28a', 'ts', interval '1 day', p_paused => false);
call pgpm.from_hypertable_copy('public.s28b', 'ts');
call pgpm.from_hypertable_cutover('public.s28b', 'ts', interval '1 day', p_paused => false);
call pgpm.from_hypertable_copy('public.s28c', 'ts');
call pgpm.from_hypertable_cutover('public.s28c', 'ts', interval '1 day', p_paused => false);

select is(
  (select string_agg(relname::text || ':' || relkind::text, ',' order by relname) from pg_class
    where oid in ('public.s28a'::regclass, 'public.s28b'::regclass, 'public.s28c'::regclass)),
  's28a:p,s28b:p,s28c:p', 'LIVENESS: after a fresh copy each cutover converts the table');
select is(
  (select string_agg(attname::text, ',' order by attnum) from pg_attribute
    where attrelid = 'public.s28a'::regclass and attnum > 0 and not attisdropped),
  'id,ts,v', 'A: the migrated table has no ssn column: the drop was not reverted');
select is(
  (select string_agg(id || ':' || v, ',' order by id) from public.s28a),
  (select string_agg(g || ':old', ',' order by g) from generate_series(1, 12) g),
  'A: and every row, by identity');
insert into public.s28b (id, ts) values (100, timestamptz '2026-09-02 07:00+00');
select is((select v from public.s28b where id = 100), 'new',
  'B: the migrated table takes the new default: the change was not reverted');
select throws_ok(
  $$ insert into public.s28c (id, ts, v) values (100, timestamptz '2026-09-02 07:00+00', 'forbidden') $$,
  '23514', NULL, 'C: the migrated table enforces the new CHECK: it was not dropped');
insert into public.s28c (id, ts, v) values (101, timestamptz '2026-09-02 08:00+00', 'allowed');
select is((select v from public.s28c where id = 101), 'allowed',
  'C: and accepts a row the CHECK allows (the refusal above is the CHECK, not the insert)');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
