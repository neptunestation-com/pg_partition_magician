-- P1-01: pgpm._retirement_vouched answers from the mark alone. The PR says the one rule for "is this detached
-- relation still pgpm's" is the mark AND the record of pgpm's dispatch (_detach_dispatched, #705/#1259), and that
-- _part_built / _part_detached_by_hand ask it, so the write-block step, status(), progress(), obtain's cell walk and
-- the auto-regrain scan take a table detached by hand under a mark with no record for the operator's. In this tree
-- the function body is `select p_retiring_at is not null`: the record is never asked, a mark whose dispatch failed
-- (no pg_cron) still vouches, and the write-block step puts pgpm's block on the operator's table.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

create table public.p1v (id bigint primary key, payload text);
insert into public.p1v values (1, 'a'), (2, 'b');
call pgpm.transmute('public.p1v', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.p1v', '100');
insert into public.p1v values (25, 'own'), (35, 'failed'), (55, 'sibling'), (95, 'frontier');
select child_name as v_own,  child_oid as v_own_oid  from pgpm.part where parent_table = 'public.p1v'::regclass and lo = '20' \gset
select child_name as v_fail, child_oid as v_fail_oid from pgpm.part where parent_table = 'public.p1v'::regclass and lo = '30' \gset
select child_oid as v_sib_oid from pgpm.part where parent_table = 'public.p1v'::regclass and lo = '50' \gset

-- [20, 30): pgpm's own retirement, the mark and the record retire() writes together, its detach landed
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = child_oid, detach_dispatched_oid = child_oid
 where parent_table = 'public.p1v'::regclass and lo = '20';
-- [30, 40): the state a failed dispatch leaves (fail_retain_detach): the mark, no record; then the operator's DETACH
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = child_oid
 where parent_table = 'public.p1v'::regclass and lo = '30';
select format('alter table public.p1v detach partition public.%I', c) from unnest(array[:'v_own', :'v_fail']::name[]) c \gexec

select ok(not exists (select 1 from pg_inherits where inhparent = 'public.p1v'::regclass and inhrelid in (:v_own_oid, :v_fail_oid))
          and (select count(*) from pg_class where oid in (:v_own_oid, :v_fail_oid)) = 2
          and exists (select 1 from pgpm.part where parent_table = 'public.p1v'::regclass and lo = '20'
                       and retiring_at is not null and detach_dispatched_oid = :v_own_oid)
          and exists (select 1 from pgpm.part where parent_table = 'public.p1v'::regclass and lo = '30'
                       and retiring_at is not null and detach_dispatched_oid is null),
  'LIVENESS: [20, 30) (mark with its record) and [30, 40) (mark, no record) are detached and still exist');
select ok(pgpm._detach_dispatched('public.p1v', :'v_own', :v_own_oid)
          and not pgpm._detach_dispatched('public.p1v', :'v_fail', :v_fail_oid),
  'LIVENESS: _detach_dispatched vouches for [20, 30) alone');
select ok(not exists (select 1 from pg_trigger where tgrelid in (:v_own_oid, :v_fail_oid, :v_sib_oid) and tgname = 'pgpm_write_block'),
  'LIVENESS: none of the three carries a write block before the step');

select is((select array_agg(p.lo order by p.lo::int) from pgpm.part p
            where p.parent_table = 'public.p1v'::regclass and p.lo in ('20', '30', '50')
              and pgpm._retirement_vouched(p.parent_table, p.child_oid, p.retiring_at)),
  array['20'],
  '_retirement_vouched vouches for the mark with its record, [20, 30), not for the mark without one, [30, 40)');
select is((select array_agg(p.lo order by p.lo::int) from pgpm.part p
            where p.parent_table = 'public.p1v'::regclass and p.lo in ('20', '30', '50')
              and pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)),
  array['30'],
  '_part_detached_by_hand names [30, 40), the table detached under a mark pgpm recorded no dispatch for');

select pgpm._enforce_write_blocks('public.p1v');

select ok(exists (select 1 from pg_trigger where tgrelid = :v_sib_oid and tgname = 'pgpm_write_block'),
  'LIVENESS: the write-block step ran and blocked the attached sibling [50, 60)');
select is((select array_agg(p.lo order by p.lo::int) from pgpm.part p
            join pg_trigger t on t.tgrelid = p.child_oid and t.tgname = 'pgpm_write_block'
           where p.parent_table = 'public.p1v'::regclass and p.lo in ('20', '30', '50')),
  array['20', '50'],
  'the write-block step blocks pgpm''s own retirement [20, 30) and the sibling, not the operator''s table [30, 40)');

select * from finish();
