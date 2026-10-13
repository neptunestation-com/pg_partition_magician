-- F9-06: _naive_grid_zone_off reads a CONSTANT non-zero offset (Asia/Tokyo) as on the column's clock, so a date grid
-- an install before #504 registered in the session's zone Asia/Tokyo is neither refused by set_regrain toward a day
-- nor by the prepare tick, though its first daily fine cell encodes as an empty date range.
\set ON_ERROR_STOP 1
create extension if not exists pgtap;
set timezone = 'UTC';
create table public.f9t (id bigint generated always as identity, d date not null, primary key (id, d));
insert into public.f9t (d) select date '2025-01-05' + g from generate_series(0, 60) g;
create table public.f9n (id bigint generated always as identity, d date not null, primary key (id, d));
insert into public.f9n (d) select date '2025-01-05' + g from generate_series(0, 60) g;
call pgpm.transmute('public.f9t', 'd', interval '1 month');
call pgpm.transmute('public.f9n', 'd', interval '1 month');
-- the OLDER-INSTALL state (#504): the grid recorded in the converting session's zone, every monthly bound at that
-- zone's midnight on the 1st (the catalog's date bounds are the same dates either way)
update pgpm.config set partition_tz = 'Asia/Tokyo' where parent_table = 'public.f9t'::regclass;
update pgpm.part set lo = pgpm._ts_text(lo::timestamptz - interval '9 hours'),
                     hi = pgpm._ts_text(hi::timestamptz - interval '9 hours')
 where parent_table = 'public.f9t'::regclass;
update pgpm.config set partition_tz = 'America/New_York' where parent_table = 'public.f9n'::regclass;
update pgpm.part set lo = pgpm._ts_text((lo::timestamptz at time zone 'UTC') at time zone 'America/New_York'),
                     hi = pgpm._ts_text((hi::timestamptz at time zone 'UTC') at time zone 'America/New_York')
 where parent_table = 'public.f9n'::regclass;

select plan(5);
select throws_like($$select pgpm.set_regrain('public.f9n', '1 day')$$, '%recorded in partition_tz%',
                   'LIVENESS: the same older-install grid in America/New_York is refused toward a day step');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.f9t'::regclass and lo = '2024-12-31 15:00:00+00'),
          'LIVENESS: the Tokyo grid''s monolith starts at Tokyo midnight, 2024-12-31 15:00 UTC');
-- its first daily fine cell as regrain_step cuts it: [source lo, next 00:00 UTC on the anchor's lattice)
select ok((pgpm._encode('time', '2024-12-31 15:00:00+00', null, null, null, null, null, null, null, 'Asia/Tokyo')::date
           = pgpm._encode('time', pgpm._grid_next('time', '1 day',
                                     pgpm._grid_floor('time', '1 day', c.partition_anchor, '2024-12-31 15:00:00+00', 'Asia/Tokyo'),
                                     'Asia/Tokyo'), null, null, null, null, null, null, null, 'Asia/Tokyo')::date),
          'LIVENESS: the Tokyo grid''s first daily fine cell encodes as an empty date range (both bounds 2025-01-01)')
  from pgpm.config c where c.parent_table = 'public.f9t'::regclass;
select throws_like($$select pgpm.set_regrain('public.f9t', '1 day')$$, '%recorded in partition_tz%',
                   'set_regrain refuses a day step on a date grid recorded in Asia/Tokyo rather than UTC');
select ok(not pgpm._naive_grid_zone_off('date'::regtype, 'UTC') and not pgpm._naive_grid_zone_off('date'::regtype, 'Etc/UTC'),
          'LIVENESS: UTC by another name is on the clock');
select * from finish();
