-- A resumed transmute refuses a control column other than the one its recorded bound constrains (issue #628).
--
-- A failure between transmute's phases leaves a claim in pgpm.transmute_inflight and a validated
-- pgpm_monolith_bound CHECK on the table, and the documented remedy is to re-run transmute, which resumes
-- from that bound (#275) in its zone (#506) on a grid it lies on (#574). The claim did not record the
-- control column. A re-run on ANOTHER column took the claim over, reused the bound, skipped phase 1
-- (a constraint by that name exists) and phase 2 (it is validated), and partitioned by the new column:
-- the CHECK is on the old column, so it does not imply the new partition bound, and the cutover's ATTACH
-- scanned the whole table under ACCESS EXCLUSIVE, the outage phases 1 and 2 exist to avoid (or failed
-- there, when the new column's values fall outside the old column's bound).
--
-- The contract is the column's identity, not its spelling: the claim records the control column's
-- attribute number, and a resume on a different column is refused before anything is committed, naming
-- both columns, while a resume on the SAME column resumes even after it was renamed (the CHECK follows
-- the column, so the zero-scan attach still holds).
--
-- Fixture: two bigint columns in the key, a = 1..15 and b = a + 2 = 3..17, so a step-10 conversion on a
-- records [0, 20) and b's values fall INSIDE that bound too: a re-run on b is not stopped by anything
-- but the refusal (without it the cutover would attach on b over a CHECK on a).
--
-- The failing first conversion runs in a dblink session (a committing procedure cannot run inside
-- throws_ok, and pg_prove runs this file under ON_ERROR_STOP). It fails deterministically in the cutover:
-- this session holds ACCESS SHARE on the REFERENCING table, which the incoming-FK drop needs ACCESS
-- EXCLUSIVE on, while phases 1 and 2 touch only the table being converted and so commit the claim.
-- bench/transmute_resume_control_column.sh runs this file against a mutant with the refusal removed
-- (transmute_resume_any_column), so it is also required to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(17);

create table public.ccol (a bigint not null, b bigint not null, body text, primary key (a, b));
insert into public.ccol select g, g + 2, 'row ' || g from generate_series(1, 15) g;   -- step 10 on a -> [0, 20)
create table public.ccol_ref (id int primary key, a bigint, b bigint, foreign key (a, b) references public.ccol);
insert into public.ccol_ref values (1, 3, 5);

-- session A: phase 1 and 2 commit the bound and the claim, the cutover times out on ccol_ref, A ends
select dblink_connect('a', 'dbname=' || current_database());
begin;
lock table public.ccol_ref in access share mode;
select throws_ok(
  $$ select dblink_exec('a', $c$ call pgpm.transmute('public.ccol', 'a', 10::bigint, p_obtain => 3,
                                                     p_incoming_fks => 'preserve', p_lock_timeout => '300ms') $c$) $$,
  '55P03', NULL,
  'LIVENESS: the conversion on a fails in the cutover, on the lock this session holds on the referencing table');
commit;
select dblink_disconnect('a');
select is((select lo || ' ' || hi from pgpm.transmute_inflight where parent_table = 'public.ccol'::regclass), '0 20',
  'LIVENESS: the failed attempt left a claim with bound [0, 20)');
select is((select convalidated::text || ' ' || pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.ccol'::regclass and conname = 'pgpm_monolith_bound'),
  $$true CHECK (((a >= '0'::bigint) AND (a < '20'::bigint)))$$,
  'LIVENESS: and a VALIDATED pgpm_monolith_bound CHECK on a, so a resume skips phases 1 and 2');
select is((select min(b) || ' ' || max(b) from public.ccol), '3 17',
  'LIVENESS: every b value lies inside [0, 20) too, so nothing but the refusal stops a re-run on b');

-- the first attempt's session has ended (tests/101's stand-in: its backend's exit is asynchronous)
update pgpm.transmute_inflight set owner_pid = null, owner_backend_start = null
 where parent_table = 'public.ccol'::regclass;

-- a re-run on the other column, with a step and anchor the bound IS on: refused up front, on the column
select throws_like(
  $$ call pgpm.transmute('public.ccol', 'b', 10::bigint, p_obtain => 3, p_incoming_fks => 'preserve') $$,
  '%cannot resume the transmute of ccol on b: the bound [0, 20) an earlier attempt recorded (and put in the pgpm_monolith_bound CHECK) is on a,%',
  'a resume on another control column is refused, naming both columns');
select is((select lo || ' ' || hi || ' ' || coalesce(owner_pid::text, 'no owner') from pgpm.transmute_inflight
            where parent_table = 'public.ccol'::regclass), '0 20 no owner',
  'the refusal left the claim exactly as it was: same bound, not taken over');
select is((select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.ccol'::regclass and conname = 'pgpm_monolith_bound'),
  $$CHECK (((a >= '0'::bigint) AND (a < '20'::bigint)))$$, 'and the recorded bound on the table');
select is((select relkind::text from pg_class where oid = 'public.ccol'::regclass), 'r', 'the table is still a plain table');
select is((select count(*)::int from pgpm.config where parent_table = 'public.ccol'::regclass), 0, 'nothing was registered');

-- the SAME column under a new name resumes: the claim anchors the column, not its spelling
alter table public.ccol rename column a to a_renamed;
call pgpm.transmute('public.ccol', 'a_renamed', 10::bigint, p_obtain => 3, p_incoming_fks => 'preserve');
select is((select relkind::text from pg_class where oid = 'public.ccol'::regclass), 'p',
  'LIVENESS: the re-run on the renamed column completed the conversion');
select is((select count(*)::int from pgpm.log where parent_table = 'public.ccol'::regclass and action = 'transmute_resume'), 1,
  'LIVENESS: it RESUMED on the recorded bound');
select is((select control_column::text from pgpm.config where parent_table = 'public.ccol'::regclass), 'a_renamed',
  'and registered the column the bound constrains');
select is((select string_agg('[' || lo || ',' || hi || ')', ' ' order by lo::numeric) from pgpm.part
            where parent_table = 'public.ccol'::regclass and attached),
  '[0,20) [20,30) [30,40) [40,50)', 'the monolith is the recorded bound, and the forward grid starts flush at its hi');
insert into public.ccol values (21, 1, 'next row');
select is((select c.relname::text from public.ccol e join pg_class c on c.oid = e.tableoid where e.a_renamed = 21),
  'ccol_p0000000000000000020', 'a row at 21 lands in the partition starting at 20: the grid is on a_renamed');
select is((select string_agg(a || ',' || b, ' ') from public.ccol_ref), '3,5', 'the referencing row survived the conversion');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.ccol'::regclass), 0,
  'the completed conversion released the claim');
select is((select count(*)::int from pg_constraint c join pg_class k on k.oid = c.conrelid
            where c.conname = 'pgpm_monolith_bound' and k.relname like 'ccol%'), 0,
  'and no pgpm_monolith_bound is left anywhere in the family');

select * from finish();
