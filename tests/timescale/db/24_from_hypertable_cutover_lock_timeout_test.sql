-- from_hypertable_cutover bounds its wait for the source's ACCESS EXCLUSIVE with p_lock_timeout (issue #665).
--
-- THE BUG. The cutover took `lock table <hypertable> in access exclusive mode` under whatever lock_timeout
-- the session had, which by default is none. Behind any long reader of the hypertable (an analytics query,
-- pg_dump, an idle-in-transaction session) the request queued, and a PENDING ACCESS EXCLUSIVE blocks every
-- later read and write of the table, so one unrelated query took the production table offline for its
-- whole life. transmute bounds the same wait (p_lock_timeout, default '5s', #309); the cutover now takes
-- the same parameter with the same default, applies it to its swap transaction, and passes it to the
-- handoff's transmute.
--
-- WHAT THIS FILE PINS. The lock behaviour needs a second session holding the table while the cutover
-- waits, and this track's image has no superuser for dblink, so that lives in
-- bench/hypertable_cutover_lock_timeout.sh with a mutation that puts the unbounded wait back. What is
-- assertable here is the parameter's own contract on a real hypertable: a bad value is refused UP FRONT,
-- before the pre-drain commits anything and before the index pre-builds spend their O(rows), in both the
-- cutover and the one-shot driver (whose copy would otherwise run to completion first), and a good value
-- converts normally.
--
-- WHY the refusal is pinned by its message. Each procedure here commits, and throws_like runs it inside a
-- function, where a procedure that does NOT refuse dies at its first COMMIT with 2D000 and rolls back
-- into the state a refusal leaves. The message is the only thing that separates the two.
--
-- Autocommit, disposable-db. from_hypertable_copy and _cutover are called as bare statements.
select plan(12);

create table public.hlt (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.hlt', 'ts', chunk_time_interval => interval '1 day');
create index hlt_v_idx on public.hlt (v);
insert into public.hlt select g, timestamptz '2026-09-01 00:00+00' + g * interval '1 hour', 'r' || g
  from generate_series(1, 45) g;

call pgpm.from_hypertable_copy('public.hlt', 'ts');
select is((select count(*)::int from public.hlt_pgpm_dest), 45, 'LIVENESS: the online copy holds all 45 rows');

set lock_timeout = '7s';

-- ============================ the cutover refuses a bad value up front ============================
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.hlt', 'ts', interval '1 day', p_lock_timeout => 'not-a-duration') $$,
  'pg_partition_magician: p_lock_timeout must be a valid lock_timeout value (got not-a-duration)%',
  'from_hypertable_cutover refuses a bad p_lock_timeout');
select is(
  (select count(*)::int from timescaledb_information.hypertables
    where hypertable_schema = 'public' and hypertable_name = 'hlt'),
  1, 'the source is still a hypertable after the refusal');
select is((select count(*)::int from public.hlt_pgpm_dest), 45, 'the copy is untouched');
select is(
  (select count(*)::int from pg_class c join pg_index i on i.indexrelid = c.oid
    where i.indrelid = 'public.hlt_pgpm_dest'::regclass and c.relname like '%\_pgpm\_new'),
  0, 'and no pre-built index is left on it');
select is(current_setting('lock_timeout'), '7s', 'the caller''s lock_timeout is unchanged by the refusal');

-- ============================ a good value converts normally ============================
call pgpm.from_hypertable_cutover('public.hlt', 'ts', interval '1 day', p_lock_timeout => '3s');

select is((select relkind::text from pg_class where oid = 'public.hlt'::regclass), 'p',
  'a valid p_lock_timeout cuts over: the table is pgpm-partitioned');
select is(
  (select string_agg(id::text || ':' || v, ',' order by id) from public.hlt),
  (select string_agg(g::text || ':r' || g, ',' order by g) from generate_series(1, 45) g),
  'every source row is there, by identity');
select is(current_setting('lock_timeout'), '7s', 'the caller''s lock_timeout is unchanged by the cutover');

-- ============================ the one-shot driver refuses before its copy ============================
create table public.hlt2 (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.hlt2', 'ts', chunk_time_interval => interval '1 day');
insert into public.hlt2 select g, timestamptz '2026-09-01 00:00+00' + g * interval '1 hour', 's' || g
  from generate_series(1, 30) g;

select throws_like(
  $$ call pgpm.from_hypertable('public.hlt2', 'ts', interval '1 day', p_lock_timeout => '5 parsecs') $$,
  'pg_partition_magician: p_lock_timeout must be a valid lock_timeout value (got 5 parsecs)%',
  'from_hypertable refuses a bad p_lock_timeout');
select is(to_regclass('public.hlt2_pgpm_dest'), NULL, 'before its copy built a destination');
select is(
  (select count(*)::int from timescaledb_information.hypertables
    where hypertable_schema = 'public' and hypertable_name = 'hlt2'),
  1, 'and the source is still a hypertable');

select * from finish();
