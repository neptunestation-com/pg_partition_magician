\set ON_ERROR_STOP on
set client_min_messages = warning;
create function pg_temp.attempt(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return 'completed'; exception when others then return sqlstate || ' ' || left(sqlerrm, 140); end; $f$;
select 'R zone_off_tokyo=' || pgpm._naive_grid_zone_off('date'::regtype, 'Asia/Tokyo');
select 'R zone_off_phoenix=' || pgpm._naive_grid_zone_off('timestamp'::regtype, 'America/Phoenix');
select 'R zone_off_ny=' || pgpm._naive_grid_zone_off('date'::regtype, 'America/New_York');
select 'R zone_off_utc=' || pgpm._naive_grid_zone_off('date'::regtype, 'UTC');
create table public.z (id bigint, dt date not null, primary key (id, dt));
insert into public.z select g, date '2024-08-01' + (g % 45) from generate_series(1, 55) g;
call pgpm.transmute('public.z', 'dt', interval '3 months', p_obtain => 1);
-- the state an install before #504 left: the converting session's zone recorded for a naive key
update pgpm.config set partition_tz = 'Asia/Tokyo' where parent_table = 'public.z'::regclass;
select 'R set_regrain_day=' || pg_temp.attempt($$select pgpm.set_regrain('public.z', '1 day')$$);
select 'R regrain_to=' || coalesce((select regrain_to from pgpm.config where parent_table = 'public.z'::regclass), 'null');
