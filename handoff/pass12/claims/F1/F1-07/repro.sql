-- F1-07: reference.md says a naive `timestamp` key written as local wall time east of UTC works on an hourly
-- grid given `obtain` greater than the offset in hours. transmute's frontier-skew refusal (#457) reads that
-- column on the UTC clock and holds its newest value to now() + one step + one hour, so an Asia/Tokyo (+9)
-- application's current rows are refused as "a client with a wrong clock" on an hourly grid.
create extension if not exists pgtap;
select plan(3);
set timezone = 'UTC';
create table public.f1jp (id bigint not null, ts timestamp not null, primary key (id, ts));
insert into public.f1jp select i, (now() at time zone 'Asia/Tokyo') - i * interval '1 minute' from generate_series(1, 20) i;
select ok((select max(ts) from public.f1jp) > (now() at time zone 'UTC') + interval '8 hours',
          'LIVENESS: the newest row is Tokyo wall time now, about nine hours ahead of the UTC clock');
select ok((select max(ts) from public.f1jp) <= (now() at time zone 'Asia/Tokyo'),
          'LIVENESS: and no row is ahead of the writer''s own wall clock (no wrong clock anywhere)');
\set ON_ERROR_STOP 0
call pgpm.transmute('public.f1jp', 'ts', interval '1 hour', p_obtain => 12);
\set ON_ERROR_STOP 1
select ok(exists (select 1 from pgpm.config where parent_table = 'public.f1jp'::regclass),
          'transmute converts the Tokyo-wall-time table on an hourly grid with obtain 12 > the +9 offset, as reference.md describes');
select * from finish();
