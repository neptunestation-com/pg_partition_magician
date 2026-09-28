-- A resumed transmute refuses a step or anchor whose grid the recorded bound is not on (issue #574).
--
-- A failure between transmute's phases leaves a claim in pgpm.transmute_inflight whose bound [lo, hi) was
-- computed on the FIRST attempt's grid, and the documented remedy is to re-run transmute, which resumes
-- from that bound (#275) in the zone it was computed in (#506). Nothing checked the step and anchor the
-- re-run was given. A re-run with another step reused the recorded bound and registered the new step, and
-- the recorded hi is not a boundary of the new grid: obtain skipped the new grid's cell that overlaps the
-- monolith and started one cell later, leaving a permanent hole right past the monolith's hi where every
-- write failed with "no partition of relation ... found for row".
--
-- The contract is the lattice, not the spelling: a resume is refused exactly when lo or hi is not a grid
-- boundary of (step, anchor) in the recorded zone. A step the bound IS flush with (10 -> 5 here) resumes
-- and builds a grid with no hole; one it is not (7, or anchor 5) is refused before anything is committed,
-- leaving the claim and its bound exactly as the first attempt left them.
--
-- The failing first conversion runs in a dblink session (a committing procedure cannot run inside
-- throws_ok, and pg_prove runs this file under ON_ERROR_STOP). It fails deterministically in the cutover:
-- this session holds ACCESS SHARE on the REFERENCING table, which the incoming-FK drop needs ACCESS
-- EXCLUSIVE on, while phases 1 and 2 touch only the table being converted and so commit the claim.
-- bench/transmute_resume_lattice.sh runs this file against a mutant with the refusal removed
-- (transmute_resume_any_step), so it is also required to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(19);

create table public.lat (id bigint primary key, body text);
insert into public.lat select g, 'row ' || g from generate_series(1, 15) g;   -- step 10 -> monolith [0, 20)
create table public.lat_ref (id int primary key, lat_id bigint references public.lat (id));
insert into public.lat_ref values (1, 3);

-- session A: phase 1 and 2 commit the bound and the claim, the cutover times out on lat_ref, A ends
select dblink_connect('a', 'dbname=' || current_database());
begin;
lock table public.lat_ref in access share mode;
select throws_ok(
  $$ select dblink_exec('a', $c$ call pgpm.transmute('public.lat', 'id', 10::bigint, p_obtain => 3,
                                                     p_incoming_fks => 'preserve', p_lock_timeout => '300ms') $c$) $$,
  '55P03', NULL,
  'LIVENESS: the step-10 conversion fails in the cutover, on the lock this session holds on the referencing table');
commit;
select dblink_disconnect('a');
select is((select lo || ' ' || hi from pgpm.transmute_inflight where parent_table = 'public.lat'::regclass), '0 20',
  'LIVENESS: the failed attempt left a claim with bound [0, 20), on the step-10 grid');
select is((select count(*)::int from pg_constraint where conrelid = 'public.lat'::regclass and conname = 'pgpm_monolith_bound'), 1,
  'LIVENESS: and the pgpm_monolith_bound CHECK on the table');
select is(pgpm._grid_floor('id', '7', '0', '20', 'UTC'), '14',
  'LIVENESS: 20 is not a boundary of the step-7 grid (it floors to 14), so a step-7 grid registered on this bound has a hole at [20, 21)');

-- the first attempt's session has ended (tests/101's stand-in: its backend's exit is asynchronous)
update pgpm.transmute_inflight set owner_pid = null, owner_backend_start = null
 where parent_table = 'public.lat'::regclass;

-- a re-run with another step, whose grid the bound is not on: refused up front
select throws_like(
  $$ call pgpm.transmute('public.lat', 'id', 7::bigint, p_obtain => 3, p_incoming_fks => 'preserve') $$,
  '%cannot resume the transmute of lat with step 7 and anchor 0%does not lie on that grid in UTC (floored to it, lo 0 is 0 and hi 20 is 14)%',
  'a resume whose step the recorded bound is not on is refused, naming the step and anchor');
select throws_like(
  $$ call pgpm.transmute('public.lat', 'id', 10::bigint, p_obtain => 3, p_incoming_fks => 'preserve', p_anchor => 5) $$,
  '%cannot resume the transmute of lat with step 10 and anchor 5%does not lie on that grid in UTC (floored to it, lo 0 is -5 and hi 20 is 15)%',
  'the same step with an anchor that moves the grid is refused too');
select is((select lo || ' ' || hi || ' ' || coalesce(owner_pid::text, 'no owner') from pgpm.transmute_inflight
            where parent_table = 'public.lat'::regclass), '0 20 no owner',
  'the refusals left the claim exactly as it was: same bound, not taken over');
select is((select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.lat'::regclass and conname = 'pgpm_monolith_bound'),
  $$CHECK (((id >= '0'::bigint) AND (id < '20'::bigint)))$$, 'and the recorded bound on the table');
select is((select relkind::text from pg_class where oid = 'public.lat'::regclass), 'r', 'the table is still a plain table');
select is((select count(*)::int from pgpm.config where parent_table = 'public.lat'::regclass), 0, 'nothing was registered');
select is((select count(*)::int from pgpm.log where parent_table = 'public.lat'::regclass and action = 'transmute_resume'), 0,
  'and nothing resumed');

-- a re-run with a step the bound IS flush with resumes, and its grid has no hole past the monolith
call pgpm.transmute('public.lat', 'id', 5::bigint, p_obtain => 3, p_incoming_fks => 'preserve');
select is((select relkind::text from pg_class where oid = 'public.lat'::regclass), 'p', 'LIVENESS: the step-5 re-run completed the conversion');
select is((select count(*)::int from pgpm.log where parent_table = 'public.lat'::regclass and action = 'transmute_resume'), 1,
  'LIVENESS: it RESUMED on the recorded bound');
select is((select partition_step from pgpm.config where parent_table = 'public.lat'::regclass), '5', 'and registered step 5');
select is((select string_agg('[' || lo || ',' || hi || ')', ' ' order by lo::numeric) from pgpm.part
            where parent_table = 'public.lat'::regclass and attached),
  '[0,20) [20,25) [25,30) [30,35)', 'the forward grid starts flush at the monolith''s hi: no hole past it');
insert into public.lat values (20, 'next id'), (27, 'later id');
select is((select string_agg(e.id || ' in ' || c.relname, ', ' order by e.id) from public.lat e join pg_class c on c.oid = e.tableoid
            where e.id in (20, 27)),
  '20 in lat_p0000000000000000020, 27 in lat_p0000000000000000025',
  'id 20, just past the monolith, and id 27 land in the partitions starting at 20 and 25');
select is((select string_agg(lat_id::text, ',') from public.lat_ref), '3', 'the referencing row survived the conversion');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.lat'::regclass), 0,
  'the completed conversion released the claim');
select is((select count(*)::int from pg_constraint c join pg_class k on k.oid = c.conrelid
            where c.conname = 'pgpm_monolith_bound' and k.relname like 'lat%'), 0,
  'and no pgpm_monolith_bound is left anywhere in the family');

select * from finish();
