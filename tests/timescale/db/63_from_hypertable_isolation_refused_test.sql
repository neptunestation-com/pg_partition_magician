-- from_hypertable and from_hypertable_cutover refuse an isolation level stricter than READ COMMITTED up front,
-- before the copy and before the swap (issue #1105, the hypertable side).
--
-- THE DEFECT. transmute refuses a transaction or a session default_transaction_isolation stricter than READ
-- COMMITTED, because its cutover asks its up-front checks again after waiting for another transaction to
-- commit and needs a snapshot taken after that wait. from_hypertable reaches transmute only through
-- from_hypertable_cutover's handoff, after the swap has dropped the hypertable, put the plain copy under its
-- name and committed. With the refusal in transmute alone, a REPEATABLE READ session's from_hypertable
-- swapped, committed, and was refused only at the handoff: the hypertable gone, the table plain and
-- unregistered. Both entry points now ask the same refusal first.
--
-- THE INSTRUMENT. The refused calls run in a dblink session (r63) whose default_transaction_isolation is
-- REPEATABLE READ, as a top-level CALL whose phases can commit, so a mutant that does not refuse really
-- copies and swaps and the state assertions see it. The calls that convert run in a second dblink session
-- (c63) left at READ COMMITTED. Both connect to the container's bridge address, as tests/timescale/db/57
-- explains (this image trusts only loopback, and dblink needs a password off it).
--
-- ASYMMETRIC FIXTURE.
--   (A) a63, 60 devices: from_hypertable under REPEATABLE READ; refused before its copy (no copy recorded,
--       still a hypertable, its rows by identity); then converted from READ COMMITTED.
--   (B) b63, 45 devices: copied from READ COMMITTED first, then from_hypertable_cutover under REPEATABLE
--       READ; refused before its swap (still a hypertable, its copy still recorded, not registered); then
--       cut over from READ COMMITTED.
-- bench/hypertable_isolation_refused.sh runs this file against the mutants that drop each entry point's
-- refusal (from_hypertable_isolation_unchecked, from_hypertable_cutover_isolation_unchecked), so it is
-- required to FAIL there.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t63.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(12);

select mk_keyed_hypertable('a63', 60, '1 day', '4 days');
select mk_keyed_hypertable('b63', 45, '1 day', '4 days');
call pgpm.from_hypertable_copy('b63'::regclass, 'ts');

select dblink_connect('r63', current_setting('t63.connstr')) \g /dev/null
select dblink_connect('c63', current_setting('t63.connstr')) \g /dev/null
select dblink_exec('r63', 'set default_transaction_isolation = ''repeatable read''') \g /dev/null

select is((select s from dblink('r63', 'select current_setting(''transaction_isolation'') || ''/'' || current_setting(''default_transaction_isolation'')') as x(s text))
          || ' ' || (select s from dblink('c63', 'select current_setting(''transaction_isolation'')') as x(s text)),
  'repeatable read/repeatable read read committed',
  'LIVENESS: r63''s transactions are REPEATABLE READ, by its default, and c63''s READ COMMITTED');

-- ====================================================================================================
-- (A) from_hypertable, refused before its copy
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('r63', 'call pgpm.from_hypertable(''a63''::regclass, ''ts'', interval ''1 month'')') $$,
  'pg_partition_magician: from_hypertable(a63) must run in READ COMMITTED transactions (this one is repeatable read, %',
  '(A) from_hypertable refuses a REPEATABLE READ session up front, in pgpm''s words');
select is((select count(*)::int from timescaledb_information.hypertables
            where hypertable_schema = 'public' and hypertable_name = 'a63'), 1,
  '(A) a63 is still a hypertable');
select ok(pgpm._from_hypertable_scratch('a63'::regclass, 'hypertable_dest') is null
          and not exists (select 1 from pgpm.scratch where parent_oid = 'a63'::regclass::oid),
  '(A) nothing was copied: no copy recorded for a63');
select is((select array_agg(device_id order by device_id) from a63), (select array_agg(g::bigint order by g) from generate_series(1, 60) g),
  '(A) a63 holds its 60 devices, by identity');
select lives_ok($$ select dblink_exec('c63', 'call pgpm.from_hypertable(''a63''::regclass, ''ts'', interval ''1 month'')') $$,
  'LIVENESS: (A) the same call from a READ COMMITTED session converts a63');
select ok((select relkind::text from pg_class where oid = 'public.a63'::regclass) = 'p'
          and exists (select 1 from pgpm.config where parent_table = 'public.a63'::regclass),
  'LIVENESS: (A) a63 is a registered partitioned parent now');

-- ====================================================================================================
-- (B) from_hypertable_cutover, refused before its swap
-- ====================================================================================================
select ok(pgpm._from_hypertable_scratch('b63'::regclass, 'hypertable_dest') is not null,
  'LIVENESS: (B) b63''s copy was made and recorded, from READ COMMITTED');
select throws_like(
  $$ select dblink_exec('r63', 'call pgpm.from_hypertable_cutover(''b63''::regclass, ''ts'', interval ''1 month'')') $$,
  'pg_partition_magician: from_hypertable_cutover(b63) must run in READ COMMITTED transactions (this one is repeatable read, %',
  '(B) from_hypertable_cutover refuses a REPEATABLE READ session up front, in pgpm''s words');
select ok((select count(*)::int from timescaledb_information.hypertables
            where hypertable_schema = 'public' and hypertable_name = 'b63') = 1
          and pgpm._from_hypertable_scratch('b63'::regclass, 'hypertable_dest') is not null
          and not exists (select 1 from pgpm.config where parent_table = 'public.b63'::regclass),
  '(B) nothing was swapped: b63 is still a hypertable, its copy still recorded, nothing registered');
select lives_ok($$ select dblink_exec('c63', 'call pgpm.from_hypertable_cutover(''b63''::regclass, ''ts'', interval ''1 month'')') $$,
  'LIVENESS: (B) the same cutover from a READ COMMITTED session swaps and converts b63');
select is((select array_agg(device_id order by device_id) from b63), (select array_agg(g::bigint order by g) from generate_series(1, 45) g),
  '(B) b63, converted, holds its 45 devices, by identity');

select dblink_disconnect('r63') \g /dev/null
select dblink_disconnect('c63') \g /dev/null
select * from finish();
