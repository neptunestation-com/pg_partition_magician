-- F3-02: regrain() run from a REPEATABLE READ transaction copies the monolith through the caller's old snapshot,
-- so a row another session committed after that snapshot (and before the call installed change capture) is
-- in the source but in no fine child, and the swap drops the source with it. transmute, untransmute,
-- from_hypertable and the cutover all refuse a stricter isolation level up front (_refuse_strict_isolation);
-- regrain(), regrain_history() and regrain_step() do not, and docs/reference.md even contemplates "a REPEATABLE
-- READ caller of regrain". The fixture: 2 rows in the monolith before, 1 committed by another session after the
-- caller's snapshot; all three must be in the table afterwards.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(5);

create table public.f302 (id bigint primary key, payload text);
insert into public.f302 values (10, 'before-a'), (20, 'before-b');
call pgpm.transmute('public.f302', 'id', 1000);
select pgpm.obtain('public.f302');
insert into public.f302 values (5000, 'frontier');   -- the monolith [0, 1000) is now frozen

select is((select lo || '..' || hi from pgpm.part p where p.parent_table = 'public.f302'::regclass and p.attached
            order by lo::numeric limit 1), '0..1000', 'GUARD: the monolith is [0, 1000)');

begin isolation level repeatable read;
select count(*) from public.f302;   -- the caller's snapshot is taken here
-- another session commits a row into the monolith's range
select dblink_exec(format('dbname=%s user=%s', current_database(), current_user),
                   $$insert into public.f302 values (500, 'committed-after-snapshot')$$);
select is((select n from dblink(format('dbname=%s user=%s', current_database(), current_user),
                                 $$select count(*) from public.f302 where id = 500$$) as t(n bigint)),
          1::bigint, 'LIVENESS: (A) row 500 is committed and visible to a fresh session before regrain runs');
select is((select count(*) from public.f302 where id = 500), 0::bigint,
          'LIVENESS: (B) the caller''s REPEATABLE READ snapshot predates it');
do $$
begin
  perform pgpm.regrain_history('public.f302', '100');
  raise notice 'regrain_history ran under REPEATABLE READ';
exception when others then
  raise notice 'regrain_history refused: %', sqlerrm;
end $$;
commit;

select is((select array_agg(id order by id) from public.f302 where id < 1000), array[10, 20, 500]::bigint[],
          'every row of the monolith''s range is still in the table after regrain (10 and 20 before, 500 committed after the caller''s snapshot)');
select is((select payload from public.f302 where id = 500), 'committed-after-snapshot',
          'row 500 survives with its own payload');
select diag('swapped: ' || exists (select 1 from pgpm.log where parent_table = 'public.f302'::regclass
                                     and action = 'regrain' and method = 'copy_swap_drop'));
select * from finish();
