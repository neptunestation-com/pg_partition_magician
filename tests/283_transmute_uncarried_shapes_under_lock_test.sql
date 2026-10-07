-- Issue #766 (bullet 3): the three shapes #730 refuses up front, a NOT VALID CHECK, a CHECK ... NO INHERIT and
-- a GENERATED control column, are refused again in the cutover, under the lock that keeps them out.
--
-- They were asked in the preflight only. A shape committed after it, while phases 1 and 2 had let go of the
-- table, reached the cutover: the staging LIKE gave the parent a validated copy of a NOT VALID CHECK and the
-- ATTACH refused the table under it ("conflicts with NOT VALID constraint on child table"), the LIKE itself
-- refused a NO INHERIT CHECK ("cannot add NO INHERIT constraint to partitioned table"), and PARTITION BY
-- RANGE refused a generated column ("cannot use generated column in partition key"). Each was a raw error
-- after phases 1 and 2 had committed the write-rejecting bound and the claim, naming neither pgpm nor the
-- remedy. The cutover now takes the table's ACCESS SHARE before its staging LIKE (the lock the LIKE takes
-- anyway, and one every statement that adds any of the three has to wait for) and asks again under it; a
-- shape committed since the preflight is refused in the preflight's words, which rolls the cutover back to
-- the resumable phase-2 state.
--
-- Each window is opened the way tests/185 opens its own: an event trigger on phase 1's ADD of
-- pgpm_monolith_bound (after the preflight, in the transaction that commits the bound) makes the change, in
-- the transmuting session, so it commits with phase 1. The transmute runs over dblink, as a top-level CALL
-- whose phases can commit. Fixtures, asymmetric on purpose:
--   (A) t283a: a NOT VALID CHECK arrives beside a valid one that was there from the start; refused naming
--       only the newcomer; validated, the re-run converts and the CHECK binds a forward partition;
--   (B) t283b: a NO INHERIT CHECK arrives beside an inheritable one; refused naming only the newcomer;
--       re-created inheritable, the re-run converts;
--   (C) t283c: the control column is dropped and re-added as a stored generated column; refused naming it.
-- Every refusal is pinned by its message (throws_like), and each is paired with witnesses that the window
-- opened once, that its change committed, and that phases 1 and 2 had committed before the refusal.
-- bench/transmute_uncarried_shapes_under_lock.sh runs this file against the mutants that drop the cutover's
-- second asking (transmute_uncarried_constraints_preflight_only, transmute_generated_control_preflight_only).
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(25);

set timezone = 'UTC';

create table public.t283a (id bigint primary key, amt int not null, qty int not null,
                           constraint t283a_qty_pos check (qty > 0));
insert into public.t283a select g, g, g from generate_series(1, 150) g;   -- step 100: monolith [0, 200)
create table public.t283b (id bigint primary key, amt int not null, qty int not null,
                           constraint t283b_qty_pos check (qty > 0));
insert into public.t283b select g, g, g from generate_series(1, 250) g;   -- step 100: monolith [0, 300)
-- keyless, so no key refusal (a key has to include the control column) can stand in for the one under test
create table public.t283c (id bigint not null, created_at timestamptz not null, d date not null);
insert into public.t283c select g, now() - (g || ' days')::interval, (now() - (g || ' days')::interval)::date
  from generate_series(1, 40) g;

-- a refusal rolls the cutover back but not a nextval, so each window witnesses on its own sequence
create sequence public.w283a_seq;
create sequence public.w283b_seq;
create sequence public.w283c_seq;

create function public.t283_inject() returns event_trigger language plpgsql as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    -- phase 1's ADD of the bound: after the preflight, committed with the bound. Once each. By objid, not
    -- by a name cast: the cutover's rename is an ALTER TABLE too, and the name is gone by its end.
    if r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t283a'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w283a_seq) then
      perform nextval('public.w283a_seq');
      alter table public.t283a add constraint t283a_amt_pos check (amt > 0) not valid;
    elsif r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t283b'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w283b_seq) then
      perform nextval('public.w283b_seq');
      alter table public.t283b add constraint t283b_amt_pos check (amt > 0) no inherit;
    elsif r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t283c'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w283c_seq) then
      perform nextval('public.w283c_seq');
      -- the only way a column becomes generated: drop it (and the bound over it) and add it back as one
      alter table public.t283c drop column d cascade;
      alter table public.t283c add column d date generated always as ((created_at at time zone 'UTC')::date) stored;
    end if;
  end loop;
end $$;
create event trigger t283_inject on ddl_command_end when tag in ('ALTER TABLE') execute function public.t283_inject();

select dblink_connect('t283', 'dbname=' || current_database());

-- ====================================================================================================
-- (A) a NOT VALID CHECK committed after the preflight
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t283', 'call pgpm.transmute(''public.t283a'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'pg_partition_magician: cannot transmute t283a -- its constraint(s) (t283a_amt_pos) are NOT VALID,%',
  '(A) the cutover refuses the NOT VALID CHECK committed after the preflight, naming it and only it, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w283a_seq), '1:true',
  'LIVENESS: (A) the window added the CHECK once, inside phase 1');
select is((select string_agg(conname || '=' || convalidated, ' ' order by conname) from pg_constraint
            where conrelid = 'public.t283a'::regclass and contype = 'c'),
  'pgpm_monolith_bound=true t283a_amt_pos=false t283a_qty_pos=true',
  'LIVENESS: (A) the NOT VALID CHECK committed with phase 1, and phase 2 validated the bound before the cutover');
select is((select relkind::text from pg_class where oid = 'public.t283a'::regclass), 'r',
  '(A) t283a is still the plain table');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t283a'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t283a'::regclass),
  '(A) the claim stands and nothing was registered: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t283', 'alter table public.t283a validate constraint t283a_amt_pos') $$,
  'LIVENESS: (A) the operator takes the remedy the refusal names, VALIDATE CONSTRAINT');
select lives_ok(
  $$ select dblink_exec('t283', 'call pgpm.transmute(''public.t283a'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(A) the re-run resumes and converts t283a');
select is((select relkind::text from pg_class where oid = 'public.t283a'::regclass), 'p',
  'LIVENESS: (A) t283a is partitioned now');
select lives_ok($$ insert into public.t283a values (210, 7, 7) $$, 'LIVENESS: (A) a valid row is accepted past the monolith');
select isnt((select tableoid from public.t283a where id = 210),
            (select monolith_oid from pgpm.config where parent_table = 'public.t283a'::regclass),
  'LIVENESS: (A) and it landed in a forward partition, not the monolith');
select throws_like($$ insert into public.t283a values (220, -1, 7) $$, '%violates check constraint "t283a_amt_pos"%',
  '(A) t283a_amt_pos binds that forward partition too');
select is((select array_agg(id order by id) from public.t283a where id > 140), array[141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 210]::bigint[],
  '(A) the rows are the ones written, and the refused one is not among them');

-- ====================================================================================================
-- (B) a CHECK ... NO INHERIT committed after the preflight
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t283', 'call pgpm.transmute(''public.t283b'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'pg_partition_magician: cannot transmute t283b -- its CHECK constraint(s) (t283b_amt_pos) are NO INHERIT,%',
  '(B) the cutover refuses the NO INHERIT CHECK committed after the preflight, naming it and only it, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w283b_seq), '1:true',
  'LIVENESS: (B) the window added the CHECK once, inside phase 1');
select is((select string_agg(conname || '=' || connoinherit || '/' || convalidated, ' ' order by conname) from pg_constraint
            where conrelid = 'public.t283b'::regclass and contype = 'c'),
  'pgpm_monolith_bound=false/true t283b_amt_pos=true/true t283b_qty_pos=false/true',
  'LIVENESS: (B) the NO INHERIT CHECK committed with phase 1, and phase 2 validated the bound before the cutover');
select is((select relkind::text from pg_class where oid = 'public.t283b'::regclass), 'r',
  '(B) t283b is still the plain table');
select lives_ok($$ select dblink_exec('t283', 'alter table public.t283b drop constraint t283b_amt_pos; '
                                       || 'alter table public.t283b add constraint t283b_amt_pos check (amt > 0)') $$,
  'LIVENESS: (B) the operator takes the remedy the refusal names, re-creating the CHECK without NO INHERIT');
select lives_ok(
  $$ select dblink_exec('t283', 'call pgpm.transmute(''public.t283b'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(B) the re-run resumes and converts t283b');
select is((select relkind::text from pg_class where oid = 'public.t283b'::regclass), 'p',
  'LIVENESS: (B) t283b is partitioned now');
select throws_like($$ insert into public.t283b values (320, -1, 7) $$, '%violates check constraint "t283b_amt_pos"%',
  '(B) t283b_amt_pos binds a forward partition');

-- ====================================================================================================
-- (C) the control column made a GENERATED one after the preflight
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t283', 'call pgpm.transmute(''public.t283c'', ''d'', interval ''1 month'', p_obtain => 2)') $$,
  'pg_partition_magician: cannot partition t283c on d -- it is a generated column,%',
  '(C) the cutover refuses the control column made generated after the preflight, naming it, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w283c_seq), '1:true',
  'LIVENESS: (C) the window re-made the column once, inside phase 1');
select is((select attgenerated::text from pg_attribute where attrelid = 'public.t283c'::regclass and attname = 'd'), 's',
  'LIVENESS: (C) d is a stored generated column now, committed with phase 1');
select is((select relkind::text from pg_class where oid = 'public.t283c'::regclass), 'r',
  '(C) t283c is still the plain table');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t283c'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t283c'::regclass),
  '(C) the claim stands and nothing was registered: the cutover rolled back whole');

select dblink_disconnect('t283');
drop event trigger t283_inject;
select * from finish();
