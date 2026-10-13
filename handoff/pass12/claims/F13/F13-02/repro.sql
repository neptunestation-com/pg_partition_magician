-- F13-02: transmute on a time-kind control whose OLDEST value is -infinity dies with a raw error from
-- _grid_floor ("cannot convert infinity to integer" / "cannot subtract infinite timestamps"), where the
-- same column's +infinity NEWEST value is refused in pgpm's own words with the remedy (reference.md: no
-- partition can hold it; delete or correct the rows and re-run), and a numeric id's -Infinity minimum is
-- refused too (#895). A -infinity row has no partition either: the monolith's lo would have to lie below it.
-- Nothing is committed in either case; the defect is the refusal the operator gets.
set timezone = 'UTC';
create extension if not exists pgtap;
select plan(5);

-- LIVENESS: the pgpm refusal exists for the +infinity newest value on the same shape of table
create table public.pinf (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.pinf values (1, now() - interval '2 days'), (2, 'infinity');
select throws_like($$ call pgpm.transmute('public.pinf', 'ts', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician:%infinity%',
  'LIVENESS: an infinity newest value is refused by pgpm, naming it');

create table public.ninf (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.ninf values (1, '-infinity'), (2, now() - interval '1 day');
select is((select min(ts)::text from public.ninf), '-infinity', 'LIVENESS: ninf''s oldest value is -infinity');
select throws_like($$ call pgpm.transmute('public.ninf', 'ts', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician:%',
  'a -infinity oldest value on a timestamptz control is refused by pgpm, not by a raw _grid_floor error');

create table public.ndinf (id bigint, d date not null, primary key (id, d));
insert into public.ndinf values (1, '-infinity'), (2, current_date);
select throws_like($$ call pgpm.transmute('public.ndinf', 'd', interval '1 day', p_obtain => 2) $$,
  'pg_partition_magician:%',
  'a -infinity oldest value on a date control is refused by pgpm, not by a raw _grid_floor error');
select is((select string_agg(relkind::text, ',' order by relname) from pg_class where oid in ('public.ninf'::regclass, 'public.ndinf'::regclass)),
  'r,r', 'GUARD: both tables are left plain (nothing committed either way)');
select * from finish();
