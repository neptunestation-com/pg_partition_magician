-- F16-01: from_hypertable's up-front grid refusal (pgpm._time_unit_contract, asked by
-- pgpm._from_hypertable_check_arguments since #1118/#1138) tells the operator to "re-run transmute" and to
-- "call pgpm.transmute_abort(<hypertable>) first". On a hypertable that remedy does not exist: transmute
-- refuses the hypertable outright (it has inheritance children), and the call to re-run is from_hypertable.
-- The refusal itself is right; its remedy names the wrong procedure.
create extension if not exists timescaledb;
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(5);

create table public.f16d (d date not null, v int);
select create_hypertable('public.f16d', 'd', chunk_time_interval => interval '7 days') \g /dev/null
insert into public.f16d values (current_date - 9, 1), (current_date - 5, 2), (current_date - 1, 3);

create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok';
exception when others then return sqlerrm; end $$;

-- the operator's call with an anchor off 00:00 UTC on a date dimension; refused before the copy, as it should be
create temp table msg as select pg_temp.err($$ call pgpm.from_hypertable('public.f16d', 'd', interval '1 day',
  p_anchor => '2000-01-01 12:00:00+00') $$) as m;

select ok((select m like 'pg_partition_magician: cannot partition f16d on d with step 1 day and anchor %the column is a date%' from msg),
  'LIVENESS: from_hypertable refused the off-midnight anchor on the date dimension up front');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'f16d'), 1,
  'LIVENESS: the table is still a hypertable, so the operator is about to retry the hypertable path');

-- the remedy the message names, typed with a corrected anchor: transmute refuses a hypertable outright
select ok(pg_temp.err($$ call pgpm.transmute('public.f16d', 'd', interval '1 day', p_anchor => '2000-01-01 00:00:00+00') $$)
            like 'pg_partition_magician: f16d has inheritance children%transmute converts a standalone table only%',
  'LIVENESS: re-running transmute on this hypertable, as the message says, is refused (it is not the call to re-run)');

-- the defect checks: the remedy a from_hypertable refusal gives must name the call that works on a hypertable
select ok((select m not like '%re-run transmute%' from msg),
  'the refusal raised by from_hypertable does not tell the operator to re-run transmute on a hypertable');
select ok((select m not like '%transmute_abort%' from msg),
  'nor to call pgpm.transmute_abort on it first (from_hypertable never left a transmute bound to abort)');

select * from finish();
