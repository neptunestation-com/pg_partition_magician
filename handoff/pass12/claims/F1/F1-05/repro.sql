-- F1-05: _transmute_refuse_child_holders matches any label of the KIND (_is_fine_child_label), not of the
-- grid being registered, so an operator's own standalone table whose name only a YEARLY grid could give
-- (sales_p2023, a hand-made archive) refuses the transmute of `sales` on a MONTHLY grid, whose cells
-- (sales_pYYYY_MM) and fine regrain children (finer still) can never take that name. The refusal calls it
-- "an orphan left by an interrupted regrain" and tells the operator to `drop table` it: the remedy drops
-- the operator's rows to clear a collision that does not exist.
create extension if not exists pgtap;
select plan(4);
set timezone = 'UTC';

create table public.sales (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.sales select i, now() - i * interval '1 day' from generate_series(1, 20) i;
-- the operator's own archive of 2023, a plain table holding rows 7 and 8
create table public.sales_p2023 (id bigint not null, ts timestamptz not null);
insert into public.sales_p2023 values (7, '2023-03-01'), (8, '2023-09-01');

select ok(pgpm._part_name('sales', 'time', '1 mon', pgpm._ts_text('2023-01-01 00:00+00'), null, 'UTC') <> 'sales_p2023',
          'LIVENESS: a monthly cell is never named sales_p2023 (its label is YYYY_MM)');
select ok(pgpm._part_name('sales', 'time', '1 day', pgpm._ts_text('2023-01-01 00:00+00'), null, 'UTC') <> 'sales_p2023',
          'LIVENESS: nor is a finer (regrain) cell');

-- the conversion, at top level (it commits); its refusal, if any, is recorded rather than stopping the file
\set ON_ERROR_STOP 0
call pgpm.transmute('public.sales', 'ts', interval '1 month', p_obtain => 2);
\set ON_ERROR_STOP 1
select ok(exists (select 1 from pgpm.config where parent_table = 'public.sales'::regclass),
          'transmute converts sales on a monthly grid: no name it could ever create is held');
select is((select array_agg(id order by id) from public.sales_p2023), array[7, 8]::bigint[],
          'LIVENESS: the operator''s sales_p2023 still holds rows 7 and 8 (nothing was dropped)');
select * from finish();
