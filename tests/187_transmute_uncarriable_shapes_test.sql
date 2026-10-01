-- transmute refuses, up front, three shapes its cutover cannot convert (issue #730).
--
-- The cutover builds the new parent with CREATE TABLE ... LIKE INCLUDING CONSTRAINTS ... PARTITION BY RANGE
-- (control) and attaches the original table under it. Three shapes passed every up-front refusal and died
-- there instead, raw, after phases 1 and 2 had committed the validated, write-rejecting pgpm_monolith_bound
-- and the claim, so the table rejected every write past hi until an abort or the sweep, and every retry
-- failed the same way:
--   a NOT VALID CHECK (LIKE gives the parent a validated copy, and the ATTACH refuses the table under it:
--     "conflicts with NOT VALID constraint on child table"); on 18, a NOT VALID NOT NULL does the same;
--   a CHECK ... NO INHERIT ("cannot add NO INHERIT constraint to partitioned table");
--   a GENERATED control column ("cannot use generated column in partition key").
-- Each is now refused before anything is committed, naming the constraint or the column.
--
-- Fixtures, asymmetric on purpose:
--   (A) nvc: one NOT VALID CHECK beside a valid one; refused naming only the NOT VALID one; nothing
--       committed; once it is validated the same call converts, and the CHECK binds a forward partition;
--   (B) nic: one NO INHERIT CHECK beside an inheritable one; refused naming only the NO INHERIT one;
--       converts once it is re-created inheritable, which then binds a forward partition;
--   (C) gcc: a stored generated control column is refused, naming it; the same table converts on the plain
--       column it is computed from, its generated column carried (no false refusal of a generated column
--       that is not the control column);
--   (D) rsm: no false refusal of pgpm's own bound. A resume after phase 1 committed and phase 2 did not
--       finds pgpm_monolith_bound NOT VALID; the state is built by hand exactly as phase 1 leaves it (the
--       bound added NOT VALID, the claim recorded, its session gone), and the re-run resumes and converts;
--   (E) on 18 only, a NOT VALID NOT NULL constraint is refused the same way (skipped before 18, which has no
--       such constraint).
-- Each refusal is pinned by its message (throws_like): a committing procedure that does NOT refuse dies at
-- its first COMMIT inside pgTAP with 2D000, which an unpinned assertion would accept.
-- bench/transmute_uncarriable_shapes.sh runs this file against three mutants, each with one refusal removed
-- (transmute_carries_not_valid_check, transmute_carries_no_inherit_check, transmute_generated_control),
-- so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(34);

set timezone = 'UTC';

-- (A) a NOT VALID CHECK
create table public.nvc (id bigint primary key, amt int not null, qty int not null);
insert into public.nvc select g, g, g from generate_series(1, 250) g;   -- step 100: monolith [0, 300)
alter table public.nvc add constraint nvc_amt_pos check (amt > 0) not valid;
alter table public.nvc add constraint nvc_qty_pos check (qty > 0);
select is((select string_agg(conname || '=' || convalidated, ' ' order by conname) from pg_constraint
            where conrelid = 'public.nvc'::regclass and contype = 'c'),
  'nvc_amt_pos=false nvc_qty_pos=true',
  'A LIVENESS: nvc carries one NOT VALID CHECK (nvc_amt_pos) beside a valid one');
select throws_like($$ call pgpm.transmute('public.nvc', 'id', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: cannot transmute nvc -- its constraint(s) (nvc_amt_pos) are NOT VALID,%',
  'A: the NOT VALID CHECK is refused, naming it and only it');
select is((select relkind::text from pg_class where oid = 'public.nvc'::regclass), 'r', 'A: nvc is still a plain table');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.nvc'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.nvc'::regclass),
  'A: no bound and no claim were committed');
select lives_ok($$ insert into public.nvc values (5000, 1, 1) $$, 'A: nvc still takes a write past any bound');
delete from public.nvc where id = 5000;
alter table public.nvc validate constraint nvc_amt_pos;
call pgpm.transmute('public.nvc', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.nvc'::regclass), 'p',
  'A LIVENESS: with the constraint validated the same call converts nvc');
select lives_ok($$ insert into public.nvc values (310, 7, 7) $$, 'A LIVENESS: a valid row is accepted past the monolith');
select isnt((select tableoid from public.nvc where id = 310), (select monolith_oid from pgpm.config where parent_table = 'public.nvc'::regclass),
  'A LIVENESS: and it landed in a forward partition, not the monolith');
select throws_like($$ insert into public.nvc values (320, -1, 7) $$,
  '%violates check constraint "nvc_amt_pos"%',
  'A: nvc_amt_pos binds that forward partition too');

-- (B) a CHECK ... NO INHERIT
create table public.nic (id bigint primary key, amt int not null, qty int not null);
insert into public.nic select g, g, g from generate_series(1, 150) g;   -- step 100: monolith [0, 200)
alter table public.nic add constraint nic_amt_pos check (amt > 0) no inherit;
alter table public.nic add constraint nic_qty_pos check (qty > 0);
select is((select string_agg(conname || '=' || connoinherit, ' ' order by conname) from pg_constraint
            where conrelid = 'public.nic'::regclass and contype = 'c'),
  'nic_amt_pos=true nic_qty_pos=false',
  'B LIVENESS: nic carries one NO INHERIT CHECK (nic_amt_pos) beside an inheritable one');
select throws_like($$ call pgpm.transmute('public.nic', 'id', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: cannot transmute nic -- its CHECK constraint(s) (nic_amt_pos) are NO INHERIT,%',
  'B: the NO INHERIT CHECK is refused, naming it and only it');
select is((select relkind::text from pg_class where oid = 'public.nic'::regclass), 'r', 'B: nic is still a plain table');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.nic'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.nic'::regclass),
  'B: no bound and no claim were committed');
select lives_ok($$ insert into public.nic values (5000, 1, 1) $$, 'B: nic still takes a write past any bound');
delete from public.nic where id = 5000;
alter table public.nic drop constraint nic_amt_pos;
alter table public.nic add constraint nic_amt_pos check (amt > 0);
call pgpm.transmute('public.nic', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.nic'::regclass), 'p',
  'B LIVENESS: with the constraint inheritable the same call converts nic');
select lives_ok($$ insert into public.nic values (210, 7, 7) $$, 'B LIVENESS: a valid row is accepted past the monolith');
select isnt((select tableoid from public.nic where id = 210), (select monolith_oid from pgpm.config where parent_table = 'public.nic'::regclass),
  'B LIVENESS: and it landed in a forward partition, not the monolith');
select throws_like($$ insert into public.nic values (220, -1, 7) $$,
  '%violates check constraint "nic_amt_pos"%',
  'B: nic_amt_pos binds that forward partition too');

-- (C) a generated control column
create table public.gcc (id bigint not null, created_at timestamptz not null,
                         d date not null generated always as ((created_at at time zone 'UTC')::date) stored);
-- keyless, so no key refusal (a key has to include the control column) can stand in for the one under test
insert into public.gcc (id, created_at) select g, now() - (g || ' days')::interval from generate_series(1, 40) g;
select is((select string_agg(attname || '=' || attgenerated::text, ' ' order by attnum) from pg_attribute
            where attrelid = 'public.gcc'::regclass and attnum > 0 and attgenerated <> ''),
  'd=s', 'C LIVENESS: gcc.d is a stored generated column, and the only one');
select throws_like($$ call pgpm.transmute('public.gcc', 'd', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician: cannot partition gcc on d -- it is a generated column,%',
  'C: the generated control column is refused, naming it');
select is((select relkind::text from pg_class where oid = 'public.gcc'::regclass), 'r', 'C: gcc is still a plain table');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.gcc'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.gcc'::regclass),
  'C: no bound and no claim were committed');
select lives_ok($$ insert into public.gcc (id, created_at) values (5000, now() + interval '400 days') $$,
  'C: gcc still takes a write past any bound');
delete from public.gcc where id = 5000;
call pgpm.transmute('public.gcc', 'created_at', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.gcc'::regclass), 'p',
  'C LIVENESS: the same table converts on the plain column d is computed from');
select is((select attgenerated::text from pg_attribute where attrelid = 'public.gcc'::regclass and attname = 'd'), 's',
  'C: and its generated column is carried onto the parent, still generated');
insert into public.gcc (id, created_at) values (41, now() + interval '20 days');
select is((select d from public.gcc where id = 41), ((now() + interval '20 days') at time zone 'UTC')::date,
  'C: a row written after the conversion has d computed for it');

-- (D) pgpm's own NOT VALID bound is not refused: a resume after phase 1 committed and phase 2 did not
create table public.rsm (id bigint primary key, amt int not null);
insert into public.rsm select g, g from generate_series(1, 150) g;   -- step 100: monolith [0, 200)
alter table public.rsm add constraint pgpm_monolith_bound check (id >= '0' and id < '200') not valid;
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz, control_attnum,
                                     owner_pid, owner_backend_start)
values ('public.rsm'::regclass, 'public', 'rsm', 'id', '0', '200', 'UTC',
        (select attnum from pg_attribute where attrelid = 'public.rsm'::regclass and attname = 'id'), null, null);
select is((select convalidated::text from pg_constraint where conrelid = 'public.rsm'::regclass and conname = 'pgpm_monolith_bound'),
  'false', 'D LIVENESS: rsm carries pgpm''s own bound NOT VALID, with a claim whose session is gone');
call pgpm.transmute('public.rsm', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.rsm'::regclass), 'p',
  'D: the re-run is not refused for pgpm''s own NOT VALID bound, and converts rsm');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rsm'::regclass and action = 'transmute_resume'), 1,
  'D LIVENESS: it RESUMED on the recorded bound');
select is((select lo || ' ' || hi from pgpm.part where parent_table = 'public.rsm'::regclass
            and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.rsm'::regclass)),
  '0 200', 'D: the monolith is attached on the recorded bound [0, 200)');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.rsm'::regclass),
  'D: and the claim is gone');

-- (E) on 18, a NOT VALID NOT NULL constraint takes the same path as a NOT VALID CHECK
create table public.nvn (id bigint primary key, amt int);
insert into public.nvn select g, g from generate_series(1, 50) g;
select current_setting('server_version_num')::int >= 180000 as pg18 \gset
\if :pg18
alter table public.nvn add constraint nvn_amt_nn not null amt not valid;
\endif
select case when :'pg18'::boolean
            then throws_like($$ call pgpm.transmute('public.nvn', 'id', 100::bigint, p_obtain => 2) $$,
                   'pg_partition_magician: cannot transmute nvn -- its constraint(s) (nvn_amt_nn) are NOT VALID,%',
                   'E: a NOT VALID NOT NULL constraint is refused, naming it')
            else skip('a NOT VALID NOT NULL constraint exists from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
            then ok(not exists (select 1 from pg_constraint where conrelid = 'public.nvn'::regclass and conname = 'pgpm_monolith_bound')
                    and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.nvn'::regclass),
                    'E: no bound and no claim were committed')
            else skip('a NOT VALID NOT NULL constraint exists from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
            then is((select relkind::text from pg_class where oid = 'public.nvn'::regclass), 'r', 'E: nvn is still a plain table')
            else skip('a NOT VALID NOT NULL constraint exists from PostgreSQL 18', 1) end;

select * from finish();
