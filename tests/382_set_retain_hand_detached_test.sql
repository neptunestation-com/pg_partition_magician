-- set_retain's would-drop guard skips a partition the operator DETACHed by hand (issue #1134).
--
-- THE GAP. set_retain refuses a tightening that would make the very next retain() tick drop a partition the old
-- value kept, and the reference says the refusal is "about what would actually drop". The guard read
-- pgpm.part.attached alone, and an operator's own DETACH PARTITION never touches that column, so a tightening whose
-- only newly reached partition was the operator's detached table was refused, naming that table as one the tick
-- "would drop", although retire() never drops it (#652: fail_retain_drop). The guard now asks
-- _part_detached_by_hand, as every maintain() step that acts on an attached row does.
--
-- THE FIXTURE is asymmetric: [20000, 30000) is detached by hand and [30000, 40000) is still attached, so the guard is
-- shown live (a deeper tightening that crosses the attached one is still refused) and the difference between the two
-- calls is the hand-detached row alone. bench/retain_edges_tap.sh runs this file against the mutant that drops the
-- check (set_retain_counts_hand_detached), so it is required to FAIL there.
set client_min_messages = warning;
select plan(9);

create table public.t382 (id bigint primary key, payload text);
insert into public.t382 select g, 'base' from generate_series(1, 15000) g;
select pgpm_formal.baseline('public.t382');   -- the invariant oracle's row ledger (docs/formal/phase3-design.md)
call pgpm.transmute('public.t382', 'id', 10000, p_retain => 30000, p_paused => false);
select pgpm.obtain('public.t382');
insert into public.t382 values (25000, 'kept-a'), (26000, 'kept-b'), (35000, 'sib'), (55000, 'frontier');
select pgpm_formal.wrote('public.t382', 'id in (25000, 26000, 35000, 55000)');
call pgpm.maintain('public.t382');   -- horizon 20000: drops the monolith [0, 20000), keeps the rest

select child_name as kept, child_oid as kept_oid from pgpm.part
 where parent_table = 'public.t382'::regclass and lo = '20000' \gset
select child_oid as sib_oid from pgpm.part where parent_table = 'public.t382'::regclass and lo = '30000' \gset
select pgpm_formal.operator_owns(format('public.%I', :'kept'));   -- detached by hand below and kept
-- the operator detaches [20000, 30000) to keep it
select format('alter table public.t382 detach partition public.%I', :'kept') \gexec

select is(pgpm._retain_boundary((select c from pgpm.config c where parent_table = 'public.t382'::regclass)), '20000',
  'LIVENESS: the current horizon is 20000, so [20000, 30000) and [30000, 40000) are both still kept');
select ok(not exists (select 1 from pg_inherits where inhparent = 'public.t382'::regclass and inhrelid = :'kept_oid'::oid)
          and exists (select 1 from pg_class where oid = :'kept_oid'::oid)
          and (select attached and retiring_at is null from pgpm.part where child_oid = :'kept_oid'::oid),
  'LIVENESS: [20000, 30000) is detached by hand: its table stands, it is not a partition, its row says attached with no retiring_at');
select throws_like($$select pgpm.set_retain('public.t382', '10000')$$,
  '%set_retain(t382, 10000) refused%would drop%t382_p%30000%',
  'GUARD: a tightening to 10000 (horizon 40000) is refused naming the attached [30000, 40000), not the detached table below it');

-- retain 20000 puts the horizon at 30000: the only partition it newly reaches is the operator's detached table
select lives_ok($$select pgpm.set_retain('public.t382', '20000')$$,
  'set_retain accepts a tightening whose only newly reached partition is one the operator detached by hand');
select is((select retain from pgpm.config where parent_table = 'public.t382'::regclass), '20000',
  'the new retain value is in force');

call pgpm.maintain('public.t382');

select is((select array_agg(lo order by id) from pgpm.log
            where parent_table = 'public.t382'::regclass and action = 'retain_drop'),
  array['0'],
  'the tightened tick drops nothing new: the only retain_drop is the monolith dropped before the change');
select is((select array_agg(lo order by id) from pgpm.log
            where parent_table = 'public.t382'::regclass and action = 'fail_retain_drop'),
  array['20000'],
  'LIVENESS: the tightened tick reached the detached table, and retire() refused it as the operator''s');
select results_eq(format('select id, payload from public.%I order by id', :'kept'),
  $$values (25000::bigint, 'kept-a'::text), (26000, 'kept-b')$$,
  'the operator''s detached table holds exactly its two rows after the tick');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.t382'::regclass and inhrelid = :'sib_oid'::oid),
  'the attached [30000, 40000) is still a partition after the tick');
select * from finish();
