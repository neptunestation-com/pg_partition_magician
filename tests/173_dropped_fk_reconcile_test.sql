-- A pgpm.dropped_fk record is reconciled with the catalog before pgpm acts on it (issue #658).
--
-- A preserve-managed incoming key is recorded in pgpm.dropped_fk by the referencing table's oid, and
-- nothing tied the record to that table afterwards. Once the application dropped the referencing table
-- (ordinary DDL) its regclass rendered as a bare oid, so untransmute's `alter table <referencing> drop
-- constraint` died with 42601 on every attempt and the table could not be reversed at all; regrain's swap
-- died the same way in suspend_incoming_fks, so the monolith could never be regrained. A restored key
-- dropped by hand wedged both too ("constraint ... does not exist"), and restore_incoming_fks /
-- validate_incoming_fks logged a failure for such a record on every tick for good.
--
-- The contract: every path that acts on the records first forgets the ones the catalog no longer
-- backs (the referencing table is gone, or a key recorded as live on it is not there), logging each as
-- forget_incoming_fk, and then proceeds with the rest. A key that is legitimately SUSPENDED (recorded
-- dropped, its table still present) is not forgotten: it is re-added as before.
--
-- Four sections, one per path, each asymmetric: one retired key beside one surviving key, so the forget
-- has to name the right one and the survivor has to come through by name.
create extension if not exists pgtap;
select plan(36);

create schema dfk658;

-- ======================================================================================================
-- (A) untransmute after a referencing table was dropped
-- ======================================================================================================
create table dfk658.ev (id bigint primary key, body text);
insert into dfk658.ev select g, 'b' || g from generate_series(1, 5) g;
create table dfk658.gone (rid bigint primary key, id bigint constraint gone_fk references dfk658.ev);
insert into dfk658.gone values (1, 1), (2, 2);
create table dfk658.kept (rid bigint primary key, id bigint constraint kept_fk references dfk658.ev);
insert into dfk658.kept values (7, 3);

call pgpm.transmute('dfk658.ev', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
select is(pgpm.restore_incoming_fks('dfk658.ev'), 2, 'LIVENESS: (A) both preserved keys were re-added on the parent');

create table dfk658.ids as
  select 'dfk658.ev'::regclass::oid as par, (select tableoid::oid from dfk658.ev limit 1) as mon;
drop table dfk658.gone;

select ok(exists (select 1 from pgpm.dropped_fk d
                   where d.parent_table = 'dfk658.ev'::regclass and d.constraint_name = 'gone_fk'
                     and d.restored_at is not null
                     and not exists (select 1 from pg_class c where c.oid = d.referencing_table)),
  'LIVENESS: (A) pgpm still records gone_fk as live, on a referencing table that no longer exists');

select lives_ok($$ select pgpm.untransmute('dfk658.ev') $$,
  '(A) untransmute reverses the table after one of its referencing tables was dropped');
select is((select relkind::text from pg_class where oid = 'dfk658.ev'::regclass), 'r',
  '(A) dfk658.ev is an ordinary table again');
select is('dfk658.ev'::regclass::oid, (select mon from dfk658.ids),
  '(A) and it is the monolith, not a copy');
select is((select array_agg(id order by id) from dfk658.ev), array[1, 2, 3, 4, 5]::bigint[],
  '(A) every row is in it');
select is((select array_agg(confrelid::regclass::text) from pg_constraint
            where conrelid = 'dfk658.kept'::regclass and conname = 'kept_fk' and contype = 'f'),
  array['dfk658.ev'],
  '(A) the surviving key kept_fk is back on dfk658.kept, against the restored table');
select is((select array_agg(split_part(method, ':', 1) order by id) from pgpm.log
            where parent_table::oid = (select par from dfk658.ids) and action = 'forget_incoming_fk'),
  array['gone_fk'],
  '(A) the reverse forgot gone_fk, and only gone_fk, as forget_incoming_fk');

-- ======================================================================================================
-- (B) untransmute after a restored key was dropped by hand
-- ======================================================================================================
create table dfk658.hv (id bigint primary key, body text);
insert into dfk658.hv select g, 'h' || g from generate_series(1, 4) g;
create table dfk658.hand (rid bigint primary key, id bigint constraint hand_fk references dfk658.hv);
insert into dfk658.hand values (1, 1);
create table dfk658.hkeep (rid bigint primary key, id bigint constraint hkeep_fk references dfk658.hv);
insert into dfk658.hkeep values (1, 2), (2, 4);

call pgpm.transmute('dfk658.hv', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
select is(pgpm.restore_incoming_fks('dfk658.hv'), 2, 'LIVENESS: (B) both preserved keys were re-added on the parent');
create table dfk658.hids as select 'dfk658.hv'::regclass::oid as par;
alter table dfk658.hand drop constraint hand_fk;
select ok(exists (select 1 from pgpm.dropped_fk
                   where parent_table = 'dfk658.hv'::regclass and constraint_name = 'hand_fk'
                     and restored_at is not null)
          and not exists (select 1 from pg_constraint where conrelid = 'dfk658.hand'::regclass and conname = 'hand_fk'),
  'LIVENESS: (B) pgpm still records hand_fk as live, and the operator has dropped it');

select lives_ok($$ select pgpm.untransmute('dfk658.hv') $$,
  '(B) untransmute reverses the table after a restored key was dropped by hand');
select is((select relkind::text from pg_class where oid = 'dfk658.hv'::regclass), 'r',
  '(B) dfk658.hv is an ordinary table again');
select is((select array_agg(conname::text) from pg_constraint
            where conrelid = 'dfk658.hand'::regclass and contype = 'f'), null,
  '(B) the key the operator dropped is not put back');
select is((select array_agg(confrelid::regclass::text) from pg_constraint
            where conrelid = 'dfk658.hkeep'::regclass and conname = 'hkeep_fk' and contype = 'f'),
  array['dfk658.hv'],
  '(B) the surviving key hkeep_fk is back on dfk658.hkeep, against the restored table');
select is((select array_agg(split_part(method, ':', 1) order by id) from pgpm.log
            where parent_table::oid = (select par from dfk658.hids) and action = 'forget_incoming_fk'),
  array['hand_fk'],
  '(B) the reverse forgot hand_fk, and only hand_fk, as forget_incoming_fk');

-- ======================================================================================================
-- (C) regrain's swap (suspend_incoming_fks) after a referencing table was dropped
-- ======================================================================================================
create table dfk658.rg (id bigint primary key, body text);
insert into dfk658.rg select g * 10, 'r' || g from generate_series(1, 250) g;   -- monolith [0, 3000)
create table dfk658.rg_gone (rid bigint primary key, id bigint constraint rg_gone_fk references dfk658.rg);
create table dfk658.rg_kept (rid bigint primary key, id bigint constraint rg_kept_fk references dfk658.rg);
insert into dfk658.rg_kept values (1, 10), (2, 2500);
call pgpm.transmute('dfk658.rg', 'id', 1000::bigint, p_obtain => 30, p_incoming_fks => 'preserve');
insert into dfk658.rg values (20000, 'frontier');   -- freeze the monolith
select is(pgpm.restore_incoming_fks('dfk658.rg'), 2, 'LIVENESS: (C) both preserved keys were re-added on the parent');
drop table dfk658.rg_gone;
select ok(exists (select 1 from pgpm.dropped_fk d
                   where d.parent_table = 'dfk658.rg'::regclass and d.constraint_name = 'rg_gone_fk'
                     and d.restored_at is not null
                     and not exists (select 1 from pg_class c where c.oid = d.referencing_table)),
  'LIVENESS: (C) pgpm still records rg_gone_fk as live, on a referencing table that no longer exists');

select lives_ok($$ select pgpm.regrain('dfk658.rg',
                     (select child_name from pgpm.part where parent_table = 'dfk658.rg'::regclass
                       order by lo::numeric limit 1), '100') $$,
  '(C) the monolith regrains to its swap after one of its referencing tables was dropped');
select is((select count(*)::int from pgpm.part where parent_table = 'dfk658.rg'::regclass
            and attached and lo::numeric < 3000), 30,
  '(C) the monolith [0, 3000) is thirty fine partitions now');
select is((select array_agg(method order by id) from pgpm.log
            where parent_table = 'dfk658.rg'::regclass and action = 'suspend_incoming_fk'),
  array['rg_kept_fk'],
  '(C) the swap suspended the surviving key and only it, the step the dangling record used to kill');
select is((select array_agg(confrelid::regclass::text) from pg_constraint
            where conrelid = 'dfk658.rg_kept'::regclass and conname = 'rg_kept_fk' and contype = 'f'),
  array['dfk658.rg'],
  '(C) rg_kept_fk is back on dfk658.rg_kept after the swap');
select is((select array_agg(constraint_name::text order by id) from pgpm.dropped_fk
            where parent_table = 'dfk658.rg'::regclass and restored_at is not null),
  array['rg_kept_fk'],
  '(C) pgpm records rg_kept_fk as live and no longer records rg_gone_fk at all');
select is((select array_agg(split_part(method, ':', 1) order by id) from pgpm.log
            where parent_table = 'dfk658.rg'::regclass and action = 'forget_incoming_fk'),
  array['rg_gone_fk'],
  '(C) the swap forgot rg_gone_fk, and only rg_gone_fk, as forget_incoming_fk');

-- ======================================================================================================
-- (D) restore_incoming_fks: a SUSPENDED record whose referencing table was dropped
-- ======================================================================================================
create table dfk658.rs (id bigint primary key, body text);
insert into dfk658.rs select g, 's' || g from generate_series(1, 6) g;
create table dfk658.rs_gone (rid bigint primary key, id bigint constraint rs_gone_fk references dfk658.rs);
create table dfk658.rs_kept (rid bigint primary key, id bigint constraint rs_kept_fk references dfk658.rs);
insert into dfk658.rs_kept values (1, 5);
call pgpm.transmute('dfk658.rs', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
drop table dfk658.rs_gone;
select is((select array_agg(constraint_name::text order by constraint_name) from pgpm.dropped_fk
            where parent_table = 'dfk658.rs'::regclass and restored_at is null),
  array['rs_gone_fk', 'rs_kept_fk'],
  'LIVENESS: (D) both keys are recorded suspended, one of them on a table that no longer exists');
select ok(not exists (select 1 from pg_constraint where conrelid = 'dfk658.rs_kept'::regclass and conname = 'rs_kept_fk'),
  'LIVENESS: (D) rs_kept_fk is really absent from its table, so the reconcile sees a missing key it must keep');

select is(pgpm.restore_incoming_fks('dfk658.rs'), 1, '(D) restore_incoming_fks re-adds the one key it can');
select is((select array_agg(confrelid::regclass::text) from pg_constraint
            where conrelid = 'dfk658.rs_kept'::regclass and conname = 'rs_kept_fk' and contype = 'f'),
  array['dfk658.rs'],
  '(D) the suspended key rs_kept_fk was not forgotten: it is back on dfk658.rs_kept');
select is((select array_agg(method order by id) from pgpm.log
            where parent_table = 'dfk658.rs'::regclass and action = 'fail_restore_incoming_fk'),
  null, '(D) no fail_restore_incoming_fk for the retired table''s key');
select is((select array_agg(split_part(method, ':', 1) order by id) from pgpm.log
            where parent_table = 'dfk658.rs'::regclass and action = 'forget_incoming_fk'),
  array['rs_gone_fk'],
  '(D) restore forgot rs_gone_fk, and only rs_gone_fk, as forget_incoming_fk');
select is((select array_agg(constraint_name::text order by id) from pgpm.dropped_fk
            where parent_table = 'dfk658.rs'::regclass),
  array['rs_kept_fk'], '(D) the record left is rs_kept_fk''s');

-- ======================================================================================================
-- (E) validate_incoming_fks: a re-added, unvalidated record whose referencing table was dropped
-- ======================================================================================================
create table dfk658.vs (id bigint primary key, body text);
insert into dfk658.vs select g, 'v' || g from generate_series(1, 3) g;
create table dfk658.vs_gone (rid bigint primary key, id bigint constraint vs_gone_fk references dfk658.vs);
insert into dfk658.vs_gone values (1, 1);
create table dfk658.vs_kept (rid bigint primary key, id bigint constraint vs_kept_fk references dfk658.vs);
insert into dfk658.vs_kept values (1, 2), (2, 3);
call pgpm.transmute('dfk658.vs', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
select is(pgpm.restore_incoming_fks('dfk658.vs'), 2, 'LIVENESS: (E) both keys were re-added NOT VALID');
drop table dfk658.vs_gone;
select is((select array_agg(constraint_name::text order by constraint_name) from pgpm.dropped_fk
            where parent_table = 'dfk658.vs'::regclass and restored_at is not null and validated_at is null),
  array['vs_gone_fk', 'vs_kept_fk'],
  'LIVENESS: (E) both are recorded awaiting validation, one of them on a table that no longer exists');

select is(pgpm.validate_incoming_fks('dfk658.vs'), 1, '(E) validate_incoming_fks validates the one key it can');
select is((select convalidated from pg_constraint
            where conrelid = 'dfk658.vs_kept'::regclass and conname = 'vs_kept_fk' and contype = 'f'),
  true, '(E) vs_kept_fk is validated');
select is((select array_agg(method order by id) from pgpm.log
            where parent_table = 'dfk658.vs'::regclass and action = 'fail_validate_incoming_fk'),
  null, '(E) no fail_validate_incoming_fk for the retired table''s key');
select is((select array_agg(split_part(method, ':', 1) order by id) from pgpm.log
            where parent_table = 'dfk658.vs'::regclass and action = 'forget_incoming_fk'),
  array['vs_gone_fk'],
  '(E) validate forgot vs_gone_fk, and only vs_gone_fk, as forget_incoming_fk');

select * from finish();
