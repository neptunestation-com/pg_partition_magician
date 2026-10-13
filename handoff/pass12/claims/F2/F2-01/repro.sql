-- F2-01: _naive_grid_zone_off judges a naive key's recorded zone by whether its offset is CONSTANT over
-- 2000..2100, not whether it is ZERO, so a fixed-offset zone west of UTC (America/Phoenix, -07 always) is
-- called "on the clock". A date grid recorded in it (the state tests/324 plants for an install before #504)
-- is not refused a fixed-step regrain, and the regrain toward '1 day' drops the rows of the source's last day.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
create schema clkf2;
create table clkf2.clock (t timestamptz);
insert into clkf2.clock values ('2024-10-15 00:00:00+00');
create function clkf2.now() returns timestamptz language sql stable as $$ select t from clkf2.clock $$;
set search_path = clkf2, pg_catalog, public;
select plan(7);

-- two date grids, each with a frozen monthly monolith over [2024-08-01, 2024-11-01)
create table public.ph (id bigint, dt date not null, primary key (id, dt));
insert into public.ph select g, date '2024-08-01' + (g % 91) from generate_series(1, 91) g;   -- 2024-08-01 .. 2024-10-30
insert into public.ph values (9001, '2024-10-31'), (9002, '2024-10-31'), (9003, '2024-10-30');
create table public.ny (id bigint, dt date not null, primary key (id, dt));
insert into public.ny select g, date '2024-08-01' + (g % 91) from generate_series(1, 91) g;
call pgpm.transmute('public.ph', 'dt', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.ny', 'dt', interval '1 month', p_obtain => 1);
update clkf2.clock set t = '2025-03-15 00:00:00+00';
-- an install before #504 recorded the converting session's zone for a naive key (tests/324's own fixture)
update pgpm.config set partition_tz = 'America/Phoenix' where parent_table = 'public.ph'::regclass;
update pgpm.config set partition_tz = 'America/New_York' where parent_table = 'public.ny'::regclass;

create function pg_temp.attempt(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return 'completed';
exception when others then return sqlstate || ' ' || sqlerrm; end; $f$;

select child_name as ph_mono from pgpm.part where parent_table = 'public.ph'::regclass and lo = '2024-08-01 00:00:00+00' \gset
select child_name as ny_mono from pgpm.part where parent_table = 'public.ny'::regclass and lo = '2024-08-01 00:00:00+00' \gset

select is((select string_agg(parent_table::text || '=' || partition_tz || '/' || partition_step, ', ' order by parent_table::text)
             from pgpm.config),
  'ny=America/New_York/1 mon, ph=America/Phoenix/1 mon',
  'LIVENESS: both date grids carry the planted zone and a monthly step');
select is((select string_agg(id::text, ',' order by id) from public.ph where dt = '2024-10-31'), '9001,9002',
  'LIVENESS: rows 9001 and 9002 are dated 2024-10-31, the monolith''s last day');
select ok((select tableoid::regclass::text from public.ph where id = 9001) = :'ph_mono',
  'LIVENESS: they sit in the frozen monolith the regrain splits');
select ok(pgpm._naive_grid_zone_off('date'::regtype, 'America/New_York'),
  'LIVENESS: the zone check calls a daylight-saving zone off a date column''s clock');
select throws_like(format('select pgpm.regrain(%L, %L, %L)', 'public.ny', :'ny_mono', '1 day'),
  '%its grid is recorded in partition_tz America/New_York rather than UTC%',
  'LIVENESS: and the same regrain on the New York grid is refused before anything is copied');

-- the defect: America/Phoenix is not UTC (its offset is -07:00, never zero), yet it is not refused
select pg_temp.attempt(format('select pgpm.regrain(%L, %L, %L)', 'public.ph', :'ph_mono', '1 day')) as ph_outcome \gset
select is((select string_agg(id::text, ',' order by id) from public.ph where dt = '2024-10-31'), '9001,9002',
  'rows 9001 and 9002 (dated 2024-10-31) survive a fixed-step regrain of the Phoenix-recorded date grid (outcome: ' || :'ph_outcome' || ')');
select is((select string_agg(id::text, ',' order by id) from public.ph where id in (90, 9003)), '90,9003',
  'rows 90 and 9003 (dated 2024-10-30) survive too');
select * from finish();
