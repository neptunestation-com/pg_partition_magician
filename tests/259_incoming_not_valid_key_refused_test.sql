-- Issue #902: an incoming foreign key the operator left NOT VALID is refused by transmute, not promoted.
--
-- _transmute_incoming_gate preserved any incoming key that referenced the reused key, without looking at
-- convalidated. The cutover recorded it, restore_incoming_fks re-added it NOT VALID like every other, and
-- maintain's validate_incoming_fks then VALIDATEd it: a key with no orphans was silently promoted to a
-- validated one, and a key over orphans the operator had deliberately tolerated failed and was re-scanned
-- every five minutes for good (fail_validate_incoming_fk). docs/runbook.md attributes every orphan behind
-- such a failure to the window pgpm opened ("the FK was valid when pgpm dropped it"), which was false for
-- these. The gate now refuses a NOT VALID incoming key up front, as the outgoing side refuses a NOT VALID
-- outgoing one: validating it first is the operator's call. The gate is asked in the preflight and again
-- in the cutover under its ACCESS EXCLUSIVE (#706), so one key covers both askings.
--
--   (A) 'preserve': two NOT VALID keys (one over an orphan, one clean) and one validated key. Refused
--       before anything is committed, naming exactly the two; the table, the keys and the orphan are as
--       they were, and nothing is validated. Then the operator's remedy (validate the clean one, drop the
--       dirty one) converts, and the two keys come back validated against the new parent.
--   (B) 'drop' takes the same path as 'preserve', and is refused the same way.
--   (C) a NOT VALID key added after the preflight is refused under the cutover's lock: the window's key
--       went on, the refusal names it alone, and the cutover's drop of the validated key rolled back.
--
-- The conversions run through dblink, as top-level CALLs whose phases can commit: a conversion that is NOT
-- refused really converts (and is then ticked the way maintain would), rather than dying at its first
-- COMMIT inside a pgTAP function and leaving the state a refusal leaves. bench/incoming_not_valid_refused.sh
-- runs this file against the mutant that drops the refusal (transmute_incoming_gate_accepts_not_valid).
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(23);

-- name:convalidated:referenced relation for every top-level key on the referencing tables of a part
create function pg_temp.keys_on(p_rels regclass[]) returns text language sql as $$
  select coalesce(string_agg(k.conname || ':' || k.convalidated::text || ':' || k.confrelid::regclass::text,
                             ', ' order by k.conname), 'none')
    from pg_constraint k
   where k.conrelid = any(p_rels) and k.contype = 'f' and k.conparentid = 0
$$;

select dblink_connect('t259', 'dbname=' || current_database());

-- ======================================================================================================
-- (A) 'preserve' refuses the two NOT VALID keys and names them; the validated one is not named
-- ======================================================================================================
create table public.t259a (id bigint primary key, body text);
insert into public.t259a values (1, 'a'), (2, 'b'), (5, 'e');
create table public.ref259a_dirty (cid int primary key, a_id bigint);
create table public.ref259a_clean (cid int primary key, a_id bigint);
create table public.ref259a_valid (cid int primary key, a_id bigint);
insert into public.ref259a_dirty values (10, 1), (11, 99);   -- 99: an orphan the operator tolerates
insert into public.ref259a_clean values (20, 2);
insert into public.ref259a_valid values (30, 5);
alter table public.ref259a_dirty add constraint ref259a_dirty_fk foreign key (a_id) references public.t259a (id) not valid;
alter table public.ref259a_clean add constraint ref259a_clean_fk foreign key (a_id) references public.t259a (id) not valid;
alter table public.ref259a_valid add constraint ref259a_valid_fk foreign key (a_id) references public.t259a (id);
create temp table orig259a as select 'public.t259a'::regclass::oid as oid;

select is(pg_temp.keys_on(array['public.ref259a_dirty', 'public.ref259a_clean', 'public.ref259a_valid']::regclass[]),
  'ref259a_clean_fk:false:t259a, ref259a_dirty_fk:false:t259a, ref259a_valid_fk:true:t259a',
  'A LIVENESS: two incoming keys are NOT VALID and one is validated, all against t259a');

select throws_like(
  $$ select dblink_exec('t259', 'call pgpm.transmute(''public.t259a'', ''id'', 10::bigint, p_obtain => 2, p_incoming_fks => ''preserve'')') $$,
  '%cannot transmute t259a -- its incoming foreign key(s) (ref259a_clean_fk on ref259a_clean, ref259a_dirty_fk on ref259a_dirty) are NOT VALID%',
  'A: transmute refuses the two NOT VALID incoming keys, naming exactly those two');

-- what maintain() does on its ticks, had the table been converted: restore, then validate
do $$ begin
  if exists (select 1 from pgpm.config where parent_table = 'public.t259a'::regclass) then
    perform pgpm.restore_incoming_fks('public.t259a');
  end if;
end $$;
do $$ begin
  if exists (select 1 from pgpm.config where parent_table = 'public.t259a'::regclass) then
    perform pgpm.validate_incoming_fks('public.t259a', p_respect_backoff => true);
  end if;
end $$;

select is((select relkind::text from pg_class where oid = (select oid from orig259a))
          || ':' || ('public.t259a'::regclass::oid = (select oid from orig259a))::text, 'r:true',
  'A: t259a is still the plain table it was');
select ok(not exists (select 1 from pgpm.config where parent_table = 'public.t259a'::regclass)
          and not exists (select 1 from pg_constraint
                           where conrelid = (select oid from orig259a) and conname = 'pgpm_monolith_bound'),
  'A: refused before anything was committed: no config row, no monolith bound');
select is(pg_temp.keys_on(array['public.ref259a_dirty', 'public.ref259a_clean', 'public.ref259a_valid']::regclass[]),
  'ref259a_clean_fk:false:t259a, ref259a_dirty_fk:false:t259a, ref259a_valid_fk:true:t259a',
  'A: every key is where it was, and the two NOT VALID keys are still NOT VALID');
select is((select array_agg(cid || '->' || a_id order by cid) from public.ref259a_dirty), array['10->1', '11->99'],
  'A LIVENESS: the tolerated orphan is still in the referencing table');
select ok(not exists (select 1 from pgpm.dropped_fk where constraint_name in ('ref259a_dirty_fk', 'ref259a_clean_fk', 'ref259a_valid_fk')),
  'A: no key was recorded as dropped');
select ok(not exists (select 1 from pgpm.log where action = 'fail_validate_incoming_fk'
                         and method like 'ref259a_dirty_fk:%'),
  'A: pgpm does not try (and fail, and retry every five minutes) to validate the key over the orphan');

-- the operator's remedy: validate the clean key, drop the one whose orphan they tolerate, re-run
select lives_ok($$ alter table public.ref259a_clean validate constraint ref259a_clean_fk $$,
  'A LIVENESS: the operator validates the clean key');
select lives_ok($$ alter table public.ref259a_dirty drop constraint ref259a_dirty_fk $$,
  'A LIVENESS: and drops the key over the orphan');
select lives_ok(
  $$ select dblink_exec('t259', 'call pgpm.transmute(''public.t259a'', ''id'', 10::bigint, p_obtain => 2, p_incoming_fks => ''preserve'')') $$,
  'A: with every incoming key validated, transmute converts t259a');
select is((select relkind::text from pg_class where oid = 'public.t259a'::regclass), 'p',
  'A LIVENESS: t259a is now the partitioned parent');
select is((select array_agg(constraint_name::text order by constraint_name) from pgpm.dropped_fk
            where parent_table = 'public.t259a'::regclass),
  array['ref259a_clean_fk', 'ref259a_valid_fk'], 'A: the cutover recorded exactly the two validated keys');
select is(pgpm.restore_incoming_fks('public.t259a'), 2, 'A: restore_incoming_fks re-adds both');
select is(pgpm.validate_incoming_fks('public.t259a', p_respect_backoff => true), 2, 'A: and both validate');
select is(pg_temp.keys_on(array['public.ref259a_dirty', 'public.ref259a_clean', 'public.ref259a_valid']::regclass[]),
  'ref259a_clean_fk:true:t259a, ref259a_valid_fk:true:t259a',
  'A: the two keys are back, validated, against the new parent; the dropped one stays dropped');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.t259a'::regclass
                         and action = 'fail_validate_incoming_fk'),
  'A: and no validation failed');

-- ======================================================================================================
-- (B) 'drop' is the same path, refused the same way
-- ======================================================================================================
create table public.t259b (id bigint primary key);
insert into public.t259b values (1), (3);
create table public.ref259b (cid int primary key, b_id bigint);
insert into public.ref259b values (40, 3);
alter table public.ref259b add constraint ref259b_fk foreign key (b_id) references public.t259b (id) not valid;

select throws_like(
  $$ select dblink_exec('t259', 'call pgpm.transmute(''public.t259b'', ''id'', 10::bigint, p_obtain => 2, p_incoming_fks => ''drop'')') $$,
  '%cannot transmute t259b -- its incoming foreign key(s) (ref259b_fk on ref259b) are NOT VALID%',
  'B: p_incoming_fks => ''drop'' refuses the NOT VALID key too');
select is((select relkind::text from pg_class where oid = 'public.t259b'::regclass) || ':'
          || pg_temp.keys_on(array['public.ref259b']::regclass[]), 'r:ref259b_fk:false:t259b',
  'B: t259b is the plain table and its key is still there, still NOT VALID');

-- ======================================================================================================
-- (C) a NOT VALID key added after the preflight is refused under the cutover's lock
-- ======================================================================================================
create table public.t259c (id bigint primary key);
insert into public.t259c values (1), (2), (7);
create table public.ref259c_old (cid int primary key, c_id bigint
  constraint ref259c_old_fk references public.t259c (id));
create table public.ref259c_late (cid int primary key, c_id bigint);
insert into public.ref259c_old values (50, 2);
insert into public.ref259c_late values (60, 7), (61, 404);
-- a rollback undoes an insert but not a nextval, so the refused cutover's window witnesses on this
create sequence public.w259c_seq;
create function public.t259c_inject() returns event_trigger language plpgsql as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    -- the staging CREATE TABLE: after the preflight's gate, before the cutover's lock and its second asking
    if r.command_tag = 'CREATE TABLE' and r.object_identity = 'public.t259c_pgpm_new'
       and not (select is_called from public.w259c_seq) then
      perform nextval('public.w259c_seq');
      alter table public.ref259c_late add constraint ref259c_late_fk foreign key (c_id)
        references public.t259c (id) not valid;
    end if;
  end loop;
end $$;
create event trigger t259c_inject on ddl_command_end when tag in ('CREATE TABLE')
  execute function public.t259c_inject();

select throws_like(
  $$ select dblink_exec('t259', 'call pgpm.transmute(''public.t259c'', ''id'', 10::bigint, p_obtain => 2, p_incoming_fks => ''preserve'')') $$,
  '%cannot transmute t259c -- its incoming foreign key(s) (ref259c_late_fk on ref259c_late) are NOT VALID%',
  'C: the cutover refuses the NOT VALID key added after the preflight, naming it alone');
drop event trigger t259c_inject;
select is((select last_value::int || ':' || is_called::text from public.w259c_seq), '1:true',
  'C LIVENESS: the window''s key went on once, inside the cutover');
select is(
  (select convalidated from pg_constraint where conrelid = 'public.t259c'::regclass and conname = 'pgpm_monolith_bound'),
  true, 'C LIVENESS: phases 1 and 2 committed: the refusal came from the cutover, leaving the resumable state');
select is((select relkind::text from pg_class where oid = 'public.t259c'::regclass) || ' / '
          || pg_temp.keys_on(array['public.ref259c_old', 'public.ref259c_late']::regclass[]),
  'r / ref259c_old_fk:true:t259c',
  'C: t259c is the plain table, its validated key is back in place (the drop rolled back), and the late key with it');

select dblink_disconnect('t259');
select * from finish();
