-- A preserved incoming key is put back against the table it was recorded for, by identity (issue #872,
-- bullets 2 and 3).
--
-- pgpm.dropped_fk records the managed parent and the referencing table by oid, and the key's text as
-- _fk_definition captured it, its REFERENCES schema-qualified as the parent was named THEN (#498). Every
-- replay used that text verbatim, so after the documented-safe ALTER TABLE <parent> SET SCHEMA, or a
-- RENAME, the re-add named the old label: a NAMESAKE holding it got the key (logged restore_incoming_fk,
-- RI against the managed table off), and with nothing there the re-add died 42P01 (regrain's swap then put
-- the key back nowhere). Now the definition is rendered at replay time against the relation the record
-- names by oid (pgpm._fk_readd_definition): the parent for restore_incoming_fks, the restored table for
-- untransmute.
--
-- And uninstall.sql's exemption for a key "re-added by hand" asked only that a key of that NAME be live on
-- the referencing table. A namesake against another table exempted the suspended record, uninstall did not
-- refuse, and the schema drop took the only record of the real key. The match is now the key's identity,
-- referencing table AND confrelid, the one _forget_dangling_fks adopts by (#832).
--
--   (A) suspended key, parent moved, a namesake takes the old qualified name: restore_incoming_fks
--   (B) suspended key, parent RENAMED, a namesake takes the old name: restore_incoming_fks
--   (C) restored key, parent moved, nothing at the old name: regrain's swap suspends and restores it
--   (D) restored key, parent moved AND renamed, a namesake at the old qualified name: untransmute
--   (E) suspended key, a namesake KEY against another table on the referencing table: uninstall refuses
--
-- ASYMMETRIC FIXTURES. Each managed table holds ids 1, 2 and 5; each namesake holds 999 alone, which the
-- managed table does not. A key against the namesake accepts a reference to 999 and refuses one to 2; a key
-- against the managed table does the opposite, so the two cannot be confused by any single write. The
-- referencing side asserted is always the TOP-LEVEL key (conparentid = 0): a key against a partitioned
-- table has a clone row per partition beside it.
--
-- bench/recorded_identity.sh runs this file, with tests/239, against the mutants that put each replay and
-- the exemption back to the name (restore_fk_replays_recorded_definition,
-- untransmute_fk_replays_recorded_definition, uninstall_fk_exempt_by_name), and each must FAIL there.
\if :{?uninstall}
\else
\set uninstall ../pgpm_core/uninstall.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(26);

-- the top-level key on a referencing table: its constraint name and what it references, by the current
-- qualified name (rendered here, not by search_path), or 'none'
create function pg_temp.key_on(p_rel regclass) returns text language sql as $$
  select coalesce(string_agg(k.conname || '->' || n.nspname || '.' || c.relname, ',' order by k.conname), 'none')
    from pg_constraint k join pg_class c on c.oid = k.confrelid join pg_namespace n on n.oid = c.relnamespace
   where k.conrelid = p_rel and k.contype = 'f' and k.conparentid = 0
$$;
create function pg_temp.refused(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when foreign_key_violation then
  return 'refused';
end $$;

-- ======================================================================================================
-- (A) suspended, moved, a namesake at the old qualified name
-- ======================================================================================================
create schema fa_old; create schema fa_new;
create table fa_old.ev (id bigint primary key, body text);
insert into fa_old.ev values (1, 'a'), (2, 'b'), (5, 'e');
create table fa_old.items (id int primary key, ev_id bigint constraint items_ev_fk references fa_old.ev (id));
insert into fa_old.items values (10, 1), (11, 5);
call pgpm.transmute('fa_old.ev', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
select 'fa_old.ev'::regclass::oid as a_parent \gset
alter table fa_old.ev set schema fa_new;
create table fa_old.ev (id bigint primary key);
insert into fa_old.ev values (999);

select ok((select restored_at is null and definition like '%REFERENCES fa_old.ev(id)%'
             from pgpm.dropped_fk where parent_table = :a_parent::oid::regclass),
  'LIVENESS: (A) the key is suspended, and its recorded text names fa_old.ev');
select is((select relkind::text from pg_class where oid = 'fa_old.ev'::regclass), 'r',
  'LIVENESS: (A) fa_old.ev now names an unrelated plain table, not the managed one');
select is(pgpm.restore_incoming_fks('fa_new.ev'), 1, 'A: restore_incoming_fks re-adds the key');
select is(pg_temp.key_on('fa_old.items'), 'items_ev_fk->fa_new.ev',
  'A: the key references the managed table where it is now, not the namesake at the recorded name');
select is(pg_temp.refused($$ insert into fa_old.items values (12, 999) $$) || '/'
          || pg_temp.refused($$ insert into fa_old.items values (13, 2) $$),
  'refused/accepted', 'A: and enforces the managed table''s keys (999 refused, 2 accepted)');

-- ======================================================================================================
-- (B) suspended, renamed, a namesake under the old name
-- ======================================================================================================
create schema fb;
create table fb.ev (id bigint primary key, body text);
insert into fb.ev values (1, 'a'), (2, 'b'), (5, 'e');
create table fb.items (id int primary key, ev_id bigint constraint items_ev_fk references fb.ev (id));
insert into fb.items values (10, 2);
call pgpm.transmute('fb.ev', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
alter table fb.ev rename to ev_renamed;
create table fb.ev (id bigint primary key);
insert into fb.ev values (999);

select ok((select restored_at is null and definition like '%REFERENCES fb.ev(id)%'
             from pgpm.dropped_fk where parent_table = 'fb.ev_renamed'::regclass),
  'LIVENESS: (B) the key is suspended, its text names fb.ev, and fb.ev is now another table');
select is(pgpm.restore_incoming_fks('fb.ev_renamed'), 1, 'B: restore_incoming_fks re-adds the key');
select is(pg_temp.key_on('fb.items'), 'items_ev_fk->fb.ev_renamed',
  'B: against the renamed managed table, not the namesake under its old name');
select is(pg_temp.refused($$ insert into fb.items values (12, 999) $$) || '/'
          || pg_temp.refused($$ insert into fb.items values (13, 5) $$),
  'refused/accepted', 'B: 999 refused, 5 accepted');

-- ======================================================================================================
-- (C) restored, moved, nothing at the old name: regrain's swap suspends and restores it
-- ======================================================================================================
create schema fc_old; create schema fc_new;
create table fc_old.ev (id bigint primary key, body text);
insert into fc_old.ev select g, 'r' || g from generate_series(1, 120) g;
create table fc_old.items (id int primary key, ev_id bigint constraint items_ev_fk references fc_old.ev (id));
insert into fc_old.items values (10, 3), (11, 117);
call pgpm.transmute('fc_old.ev', 'id', 100::bigint, p_obtain => 3, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('fc_old.ev');
insert into fc_old.ev values (250, 'frontier');   -- freezes the monolith [0, 200)
alter table fc_old.ev set schema fc_new;
select coalesce(max(id), 0) as c_mark from pgpm.log \gset

select is(pg_temp.key_on('fc_old.items'), 'items_ev_fk->fc_new.ev',
  'LIVENESS: (C) the key is live against the moved table before the regrain');
select ok(to_regclass('fc_old.ev') is null
          and (select definition like '%REFERENCES fc_old.ev(id)%' from pgpm.dropped_fk
                where parent_table = 'fc_new.ev'::regclass),
  'LIVENESS: (C) its recorded text names fc_old.ev, where nothing is now');
select is(pgpm.regrain('fc_new.ev', 'ev_p0000000000000000000_to_0000000000000000200', '50'), 4,
  'C: the moved table''s monolith regrains into four children');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'fc_new.ev'::regclass
            and id > :c_mark and action in ('suspend_incoming_fk', 'restore_incoming_fk', 'fail_restore_incoming_fk')),
  array['suspend_incoming_fk', 'restore_incoming_fk'],
  'C: the swap suspended the key and put it back, with no failure logged');
select is(pg_temp.key_on('fc_old.items'), 'items_ev_fk->fc_new.ev', 'C: the key is back against the managed table');
select is(pg_temp.refused($$ insert into fc_old.items values (12, 999) $$) || '/'
          || pg_temp.refused($$ insert into fc_old.items values (13, 118) $$),
  'refused/accepted', 'C: and enforces it (999 refused, 118 accepted)');

-- ======================================================================================================
-- (D) restored, moved and renamed, a namesake at the old qualified name: untransmute
-- ======================================================================================================
create schema fd_old; create schema fd_new;
create table fd_old.ev (id bigint primary key, body text);
insert into fd_old.ev values (1, 'a'), (2, 'b'), (5, 'e');
create table fd_old.items (id int primary key, ev_id bigint constraint items_ev_fk references fd_old.ev (id));
insert into fd_old.items values (10, 1);
call pgpm.transmute('fd_old.ev', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('fd_old.ev');
select monolith_oid as d_mono from pgpm.config where parent_table = 'fd_old.ev'::regclass \gset
alter table fd_old.ev set schema fd_new;
alter table fd_new.ev rename to ev2;
create table fd_old.ev (id bigint constraint ev_squat_pkey primary key);   -- its own key name: ev_pkey goes back
insert into fd_old.ev values (999);

select ok((select definition like '%REFERENCES fd_old.ev(id)%' from pgpm.dropped_fk
            where parent_table = 'fd_new.ev2'::regclass)
          and (select relkind::text from pg_class where oid = 'fd_old.ev'::regclass) = 'r'
          and (select relnamespace::regnamespace::text from pg_class where oid = :d_mono) = 'fd_old',
  'LIVENESS: (D) the recorded text names fd_old.ev, a namesake holds it, and the monolith is in fd_old');
select is(pgpm.untransmute('fd_new.ev2')::oid, :d_mono::oid, 'D: untransmute hands back the monolith');
select is((select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.oid = :d_mono), 'fd_new.ev2', 'LIVENESS: (D) as fd_new.ev2, where the managed table was');
select is(pg_temp.key_on('fd_old.items'), 'items_ev_fk->fd_new.ev2',
  'D: the key is re-added against the restored table, not the namesake at the recorded name');
select is(pg_temp.refused($$ insert into fd_old.items values (12, 999) $$) || '/'
          || pg_temp.refused($$ insert into fd_old.items values (13, 5) $$),
  'refused/accepted', 'D: 999 refused, 5 accepted');

-- ======================================================================================================
-- (E) uninstall: a namesake KEY against another table does not exempt the record
-- ======================================================================================================
create schema fe;
create table fe.orders (id bigint primary key, v text);
insert into fe.orders select g, 'o' || g from generate_series(1, 30) g;
create table fe.customers (id bigint primary key);
insert into fe.customers select g from generate_series(1, 5) g;
create table fe.lines (id bigint primary key,
                       order_id bigint constraint lines_order_id_fkey references fe.orders (id));
insert into fe.lines values (10, 1), (11, 2), (12, 3);
call pgpm.transmute('fe.orders', 'id', 10::bigint, p_incoming_fks => 'preserve');
alter table fe.lines add constraint lines_order_id_fkey foreign key (order_id) references fe.customers (id);
select is((select array_agg(parent_table::text || ':' || constraint_name || ':' || (restored_at is null)::text order by id)
             from pgpm.dropped_fk where restored_at is null),
  array['fe.orders:lines_order_id_fkey:true'],
  'LIVENESS: (E) the key against orders is the one suspended record, so it alone can make uninstall refuse');
select is(pg_temp.key_on('fe.lines'), 'lines_order_id_fkey->fe.customers',
  'LIVENESS: (E) lines holds a key of that name, against customers, and none against orders');

\set ON_ERROR_STOP 0
begin;
\ir :uninstall
rollback;
\set ON_ERROR_STOP 1

select is(:'LAST_ERROR_SQLSTATE'::text, 'P0001', 'E: uninstall refused with a raised exception');
select ok(:'LAST_ERROR_MESSAGE' ~ 'refusing to uninstall.*alter table fe\.lines add constraint lines_order_id_fkey FOREIGN KEY \(order_id\) REFERENCES fe\.orders\(id\)',
  'E: naming the key against orders it could not put back');
select is((select array_agg(constraint_name || ':' || (restored_at is null)::text) from pgpm.dropped_fk
            where parent_table = 'fe.orders'::regclass),
  array['lines_order_id_fkey:true'], 'E: and the record of that key survives');
select is(pg_temp.key_on('fe.lines'), 'lines_order_id_fkey->fe.customers', 'E: the namesake key is left as it was');

select * from finish();
