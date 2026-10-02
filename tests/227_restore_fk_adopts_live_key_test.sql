-- A suspended pgpm.dropped_fk record whose key the operator has re-added by hand is reconciled (issue #832).
--
-- A preserve-managed incoming key is dropped by the cutover and recorded with restored_at null until
-- restore_incoming_fks puts it back. Re-adding it by hand is a remedy pgpm itself names (docs/guide.md and
-- uninstall.sql's refusal: "re-add it by hand"), and _forget_dangling_fks reconciled only the opposite case,
-- a record marked live whose key is gone. So the record went on saying "suspended" over a live key:
-- restore_incoming_fks re-added it blindly and logged fail_restore_incoming_fk ("already exists") on every
-- call, and untransmute, whose pre-drop loop drops only restored records, left the key standing on the
-- parent and died raw with 23503 at the DETACH.
--
-- The contract: before acting on the records, every path that shares the reconcile records a SUSPENDED key
-- that is live again under its recorded identity (its referencing table, its name, a foreign key against
-- this parent) as restored, logging adopt_incoming_fk, validated or not as the live key is. A key that
-- merely shares the name (on the same referencing table, against another table) is NOT adopted: the re-add
-- still fails on it, honestly, because the name really is taken.
--
-- Two sections, one per entry point, each asymmetric: an adopted key beside a key pgpm restores itself (and,
-- in A, beside a namesake impostor), so the adoption has to name the right key and the others have to come
-- through by name.
create extension if not exists pgtap;
select plan(24);

create schema fk832;

-- ======================================================================================================
-- (A) restore_incoming_fks, then validate_incoming_fks, then untransmute
-- ======================================================================================================
create table fk832.rp (id bigint primary key, body text);
insert into fk832.rp select g, 'r' || g from generate_series(1, 6) g;
create table fk832.rq (id bigint primary key);                       -- the impostor's target
insert into fk832.rq values (5);
create table fk832.rc (rid bigint primary key, id bigint constraint rc_fk references fk832.rp);
insert into fk832.rc values (1, 1), (2, 2);
create table fk832.rd (rid bigint primary key, id bigint constraint rd_fk references fk832.rp);
insert into fk832.rd values (1, 3);
create table fk832.re (rid bigint primary key, id bigint constraint re_fk references fk832.rp);
insert into fk832.re values (1, 5);

call pgpm.transmute('fk832.rp', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
create table fk832.rids as select 'fk832.rp'::regclass::oid as par;

select is((select array_agg(constraint_name::text order by constraint_name) from pgpm.dropped_fk
            where parent_table = 'fk832.rp'::regclass and restored_at is null),
  array['rc_fk', 'rd_fk', 're_fk'],
  'LIVENESS: (A) the cutover recorded all three keys as suspended');
select is((select count(*)::int from pg_constraint
            where conname in ('rc_fk', 'rd_fk', 're_fk') and contype = 'f'), 0,
  'LIVENESS: (A) and none of them is on its referencing table');

-- the operator puts rc_fk back by hand, NOT VALID, against the converted parent; and re_fk's name is
-- taken on re by a key against another table
alter table fk832.rc add constraint rc_fk foreign key (id) references fk832.rp not valid;
alter table fk832.re add constraint re_fk foreign key (id) references fk832.rq;
select ok(exists (select 1 from pg_constraint where conrelid = 'fk832.rc'::regclass and conname = 'rc_fk'
                   and contype = 'f' and confrelid = 'fk832.rp'::regclass and not convalidated)
          and exists (select 1 from pg_constraint where conrelid = 'fk832.re'::regclass and conname = 're_fk'
                       and contype = 'f' and confrelid = 'fk832.rq'::regclass),
  'LIVENESS: (A) rc_fk is live again against rp, and re_fk names a key against rq');

select is(pgpm.restore_incoming_fks('fk832.rp'), 1, '(A) the first restore re-adds one key');
select is(pgpm.restore_incoming_fks('fk832.rp'), 0, '(A) the second re-adds none');

select is((select array_agg(split_part(method, ':', 1) order by id) from pgpm.log
            where parent_table = 'fk832.rp'::regclass and action = 'adopt_incoming_fk'),
  array['rc_fk'],
  '(A) rc_fk, and only rc_fk, was adopted, once, as adopt_incoming_fk');
select is((select array_agg(method order by id) from pgpm.log
            where parent_table = 'fk832.rp'::regclass and action = 'restore_incoming_fk'),
  array['rd_fk'],
  '(A) pgpm re-added rd_fk itself, and only rd_fk');
select is((select array_agg(split_part(method, ':', 1) order by id) from pgpm.log
            where parent_table = 'fk832.rp'::regclass and action = 'fail_restore_incoming_fk'),
  array['re_fk', 're_fk'],
  '(A) the re-add failed on the namesake re_fk on each call, and never on rc_fk');
select is((select array_agg(format('%s:%s:%s', constraint_name, restored_at is not null, validated_at is not null)
                            order by constraint_name)
             from pgpm.dropped_fk where parent_table = 'fk832.rp'::regclass),
  array['rc_fk:t:f', 'rd_fk:t:f', 're_fk:f:f'],
  '(A) rc_fk is recorded restored and unvalidated, as the live key is; re_fk is still suspended');

select is(pgpm.validate_incoming_fks('fk832.rp'), 2, '(A) validate_incoming_fks validates two keys');
select is((select array_agg(method order by method) from pgpm.log
            where parent_table = 'fk832.rp'::regclass and action = 'validate_incoming_fk'),
  array['rc_fk', 'rd_fk'],
  '(A) and they are the adopted rc_fk and the restored rd_fk');

-- the impostor goes; the next restore brings re_fk back, so the reverse has every record live
alter table fk832.re drop constraint re_fk;
select is(pgpm.restore_incoming_fks('fk832.rp'), 1, 'LIVENESS: (A) re_fk is re-added once its name is free');

select lives_ok($$ select pgpm.untransmute('fk832.rp') $$,
  '(A) untransmute reverses the table with the adopted key on it');
select is((select relkind::text from pg_class where oid = 'fk832.rp'::regclass), 'r',
  '(A) fk832.rp is an ordinary table again');
select is((select array_agg(format('%s:%s', conname, confrelid::regclass) order by conname) from pg_constraint
            where conrelid in ('fk832.rc'::regclass, 'fk832.rd'::regclass, 'fk832.re'::regclass) and contype = 'f'),
  array['rc_fk:fk832.rp', 'rd_fk:fk832.rp', 're_fk:fk832.rp'],
  '(A) each of the three keys is on its own table once, against the restored table');
select is((select array_agg(id order by id) from fk832.rp), array[1, 2, 3, 4, 5, 6]::bigint[],
  '(A) every row is in it');

-- ======================================================================================================
-- (B) untransmute straight after the hand re-add, with no restore in between
-- ======================================================================================================
create table fk832.up (id bigint primary key, body text);
insert into fk832.up select g, 'u' || g from generate_series(1, 4) g;
create table fk832.uc (rid bigint primary key, id bigint constraint uc_fk references fk832.up);
insert into fk832.uc values (1, 1), (2, 4);
create table fk832.ud (rid bigint primary key, id bigint constraint ud_fk references fk832.up);
insert into fk832.ud values (1, 2);

call pgpm.transmute('fk832.up', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
create table fk832.uids as select 'fk832.up'::regclass::oid as par;
alter table fk832.uc add constraint uc_fk foreign key (id) references fk832.up;
select ok(exists (select 1 from pgpm.dropped_fk where parent_table = 'fk832.up'::regclass
                   and constraint_name = 'uc_fk' and restored_at is null)
          and exists (select 1 from pg_constraint where conrelid = 'fk832.uc'::regclass and conname = 'uc_fk'
                       and contype = 'f' and confrelid = 'fk832.up'::regclass),
  'LIVENESS: (B) uc_fk is recorded suspended and is live again against up');
select ok(exists (select 1 from pgpm.dropped_fk where parent_table = 'fk832.up'::regclass
                   and constraint_name = 'ud_fk' and restored_at is null)
          and not exists (select 1 from pg_constraint where conrelid = 'fk832.ud'::regclass and conname = 'ud_fk'),
  'LIVENESS: (B) ud_fk is recorded suspended and is absent');

select lives_ok($$ select pgpm.untransmute('fk832.up') $$,
  '(B) untransmute reverses the table with a hand re-added key still recorded suspended');
select is((select relkind::text from pg_class where oid = 'fk832.up'::regclass), 'r',
  '(B) fk832.up is an ordinary table again');
select is((select array_agg(format('%s:%s', conname, confrelid::regclass) order by conname) from pg_constraint
            where conrelid in ('fk832.uc'::regclass, 'fk832.ud'::regclass) and contype = 'f'),
  array['uc_fk:fk832.up', 'ud_fk:fk832.up'],
  '(B) both keys are on their tables once, against the restored table');
select is((select array_agg(split_part(method, ':', 1) order by id) from pgpm.log
            where parent_table::oid = (select par from fk832.uids) and action = 'adopt_incoming_fk'),
  array['uc_fk'],
  '(B) the reverse adopted uc_fk, and only uc_fk');
select is((select array_agg(id order by id) from fk832.up), array[1, 2, 3, 4]::bigint[],
  '(B) every row is in it');
select throws_ok($$ insert into fk832.uc values (3, 99) $$, '23503', NULL,
  '(B) and the re-added uc_fk enforces against the restored table');

select * from finish();
