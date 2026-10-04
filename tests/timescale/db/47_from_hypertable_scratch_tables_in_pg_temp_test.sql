-- from_hypertable's scratch tables live in pg_temp and are named there, never through the search_path
-- (issue #894).
--
-- The tracked drain step materialises each batch's keys in a temp table pgpm_dbatch, and the keyed
-- append-only cutover materialises its tail in a temp table pgpm_htail, both ON COMMIT DROP. Each was
-- dropped first by an UNQUALIFIED `drop table if exists`, and every fresh transaction starts with no temp
-- table of that name, so the name fell through the search_path to the operator's own table and dropped it
-- with its rows: the first drain batch took a public.pgpm_dbatch, the cutover a public.pgpm_htail. The
-- reads were unqualified too, so a search_path that names pg_temp AFTER a schema holding a table of that
-- name read the operator's table as the batch (consuming the real batch's keys without applying them) or
-- as the tail (inserting the operator's rows into the destination). Every drop, create, analyze and read
-- of a scratch table now names pg_temp.
--
-- ASYMMETRIC FIXTURES. The operator's public.pgpm_dbatch holds two rows and public.pgpm_htail three, so
-- neither can be mistaken for the other, and each is asserted by identity after every phase that runs
-- the scratch table's code. LIVENESS: every phase is shown to have done the work that reaches the scratch
-- table (the drain applied the named changes, the cutover took the appended tail), by identity of rows.
--
-- (A) the drain step, a function, as the issue's reproduction calls it.
-- (B) the drain procedure (one transaction per batch) and a tracked cutover's pre-drain.
-- (C) the keyed append-only cutover's own catch-up (p_predrain => false), the pgpm_htail site.
-- (D) search_path = g3_ops, public, pg_temp: the operator's tables sit FIRST, with the scratch tables'
--     own column shapes, so an unqualified read would resolve to them rather than error.
-- bench/hypertable_scratch_tables_in_pg_temp.sh runs this file against the mutations that put each
-- unqualified site back. Autocommit, disposable-db: every committing procedure is a top-level CALL, and
-- run_timescale fails the track on any `ERROR:` line.
select plan(20);

create table public.pgpm_dbatch (note text primary key);
insert into public.pgpm_dbatch values ('operator dbatch A'), ('operator dbatch B');
create table public.pgpm_htail (note text primary key);
insert into public.pgpm_htail values ('operator htail X'), ('operator htail Y'), ('operator htail Z');

-- the operator's rows of <schema>.<name> by one column, or '(table dropped)'
create function g3_notes(p_rel text, p_col name default 'note') returns text language plpgsql as $$
declare v text;
begin
  if to_regclass(p_rel) is null then return '(table dropped)'; end if;
  execute format('select string_agg(%1$I::text, '','' order by %1$I) from %2$s', p_col, p_rel) into v;
  return v;
end $$;

-- ==================== (A) the drain step ====================
create table public.g3_a (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.g3_a', 'ts', chunk_time_interval => interval '1 day');
insert into public.g3_a
select g, date_trunc('hour', now()) - interval '3 days' + g * interval '1 hour', 'a' || g from generate_series(1, 6) g;
call pgpm.from_hypertable_copy('public.g3_a', 'ts', p_track_changes => true);
update public.g3_a set v = 'a2-new' where id = 2;
delete from public.g3_a where id = 5;
select is((select array_agg(id || ':' || v order by id) from public.g3_a_pgpm_dest),
  array['1:a1', '2:a2', '3:a3', '4:a4', '5:a5', '6:a6'],
  'LIVENESS: the destination does not yet hold the update to id 2 or the delete of id 5');
select is(pgpm.from_hypertable_drain_delta_step('public.g3_a', 'ts', 5000), 2::bigint,
  'LIVENESS: the drain step reconciled the batch of 2 keys');
select is((select array_agg(id || ':' || v order by id) from public.g3_a_pgpm_dest),
  array['1:a1', '2:a2-new', '3:a3', '4:a4', '6:a6'],
  'LIVENESS: the step applied exactly the update and the delete');
select is(g3_notes('public.pgpm_dbatch'), 'operator dbatch A,operator dbatch B',
  'the operator''s own public.pgpm_dbatch and its 2 rows survive the drain step');

-- ==================== (B) the drain procedure and a tracked cutover's pre-drain ====================
update public.g3_a set v = 'a3-new' where id = 3;
insert into public.g3_a values (7, date_trunc('hour', now()) - interval '3 days' + interval '7 hours', 'a7');
call pgpm.from_hypertable_drain_delta('public.g3_a', 'ts');
select is((select array_agg(id || ':' || v order by id) from public.g3_a_pgpm_dest),
  array['1:a1', '2:a2-new', '3:a3-new', '4:a4', '6:a6', '7:a7'],
  'LIVENESS: the drain procedure applied the update to id 3 and the insert of id 7');
select is(g3_notes('public.pgpm_dbatch'), 'operator dbatch A,operator dbatch B',
  'the operator''s public.pgpm_dbatch and its 2 rows survive the drain procedure');
update public.g3_a set v = 'a4-new' where id = 4;
call pgpm.from_hypertable_cutover('public.g3_a', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public.g3_a'::regclass), 'p',
  'LIVENESS: the tracked cutover converted the table');
select is((select array_agg(id || ':' || v order by id) from public.g3_a),
  array['1:a1', '2:a2-new', '3:a3-new', '4:a4-new', '6:a6', '7:a7'],
  'LIVENESS: with the update its pre-drain applied');
select is(g3_notes('public.pgpm_dbatch'), 'operator dbatch A,operator dbatch B',
  'the operator''s public.pgpm_dbatch and its 2 rows survive the tracked cutover');

-- ==================== (C) the keyed append-only cutover's catch-up ====================
create table public.g3_c (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.g3_c', 'ts', chunk_time_interval => interval '1 day');
insert into public.g3_c
select g, date_trunc('hour', now()) - interval '3 days' + g * interval '1 hour', 'c' || g from generate_series(1, 4) g;
call pgpm.from_hypertable_copy('public.g3_c', 'ts');
insert into public.g3_c
select g, date_trunc('hour', now()) - interval '3 days' + g * interval '1 hour', 'c' || g from generate_series(5, 7) g;
select is((select array_agg(id order by id) from public.g3_c_pgpm_dest), array[1, 2, 3, 4]::bigint[],
  'LIVENESS: the destination lacks the 3 rows appended past the copy');
call pgpm.from_hypertable_cutover('public.g3_c', 'ts', interval '1 day', p_predrain => false);
select is((select relkind::text from pg_class where oid = 'public.g3_c'::regclass), 'p',
  'LIVENESS: the append-only cutover converted the table');
select is((select array_agg(id || ':' || v order by id) from public.g3_c),
  (select array_agg(g || ':c' || g order by g) from generate_series(1, 7) g),
  'LIVENESS: its catch-up took the 3 appended rows through its tail');
select is(g3_notes('public.pgpm_htail'), 'operator htail X,operator htail Y,operator htail Z',
  'the operator''s own public.pgpm_htail and its 3 rows survive the cutover');
select is(g3_notes('public.pgpm_dbatch'), 'operator dbatch A,operator dbatch B',
  'and public.pgpm_dbatch is untouched by it');

-- ==================== (D) pg_temp named last on the search_path ====================
create schema g3_ops;
-- the operator's tables, shaped like the scratch tables so an unqualified read would resolve to them
create table g3_ops.pgpm_dbatch (id bigint, ts timestamptz);
insert into g3_ops.pgpm_dbatch values (1, date_trunc('hour', now()) - interval '3 days' + interval '1 hour');
create table g3_ops.pgpm_htail (id bigint, ts timestamptz, v text);
insert into g3_ops.pgpm_htail
values (100, date_trunc('hour', now()) - interval '3 days' + interval '9 hours', 'operator row'),
       (101, date_trunc('hour', now()) - interval '3 days' + interval '10 hours', 'operator row');

create table public.g3_d (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.g3_d', 'ts', chunk_time_interval => interval '1 day');
insert into public.g3_d
select g, date_trunc('hour', now()) - interval '3 days' + g * interval '1 hour', 'd' || g from generate_series(1, 3) g;
call pgpm.from_hypertable_copy('public.g3_d', 'ts', p_track_changes => true);
update public.g3_d set v = 'd2-new' where id = 2;

create table public.g3_e (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.g3_e', 'ts', chunk_time_interval => interval '1 day');
insert into public.g3_e
select g, date_trunc('hour', now()) - interval '3 days' + g * interval '1 hour', 'e' || g from generate_series(1, 3) g;
call pgpm.from_hypertable_copy('public.g3_e', 'ts');
insert into public.g3_e
select g, date_trunc('hour', now()) - interval '3 days' + g * interval '1 hour', 'e' || g from generate_series(4, 5) g;

set search_path = g3_ops, public, pg_temp;
select is(pgpm.from_hypertable_drain_delta_step('public.g3_d', 'ts', 5000), 1::bigint,
  'LIVENESS: under the search_path that names pg_temp last, the drain step reconciled its 1 key');
select is((select array_agg(id || ':' || v order by id) from public.g3_d_pgpm_dest),
  array['1:d1', '2:d2-new', '3:d3'],
  'the step applied its own batch (the update to id 2), not the keys of the operator''s g3_ops.pgpm_dbatch');
select is(g3_notes('g3_ops.pgpm_dbatch', 'id'), '1',
  'the operator''s g3_ops.pgpm_dbatch and its row survive the step');
call pgpm.from_hypertable_cutover('public.g3_e', 'ts', interval '1 day', p_predrain => false);
select is((select relkind::text from pg_class where oid = 'public.g3_e'::regclass), 'p',
  'under that search_path the append-only cutover converts the table');
select is((select array_agg(id || ':' || v order by id) from public.g3_e),
  (select array_agg(g || ':e' || g order by g) from generate_series(1, 5) g),
  'with exactly the source''s 5 rows, none of the operator''s g3_ops.pgpm_htail');
select is(g3_notes('g3_ops.pgpm_htail', 'id'), '100,101',
  'and the operator''s g3_ops.pgpm_htail keeps both its rows');
reset search_path;

select * from finish();
