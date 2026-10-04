-- transmute refuses a table that other objects name by its oid, and untransmute a parent that they do
-- (issue #779).
--
-- A view's query, a materialized view's, a rule's action, a SQL-standard function body (BEGIN ATOMIC) and a
-- policy's expression are stored as parse trees that name each relation by oid. The cutover renames the
-- original table, and with it that oid, into the monolith partition, so every one of them followed it:
-- `create view v as select * from t` read the monolith alone after the conversion and silently missed every
-- row routed to a forward partition. They are now refused, all named at once, before anything is committed,
-- and again under the cutover's ACCESS EXCLUSIVE; untransmute, which drops the parent, refuses the same
-- objects over the parent rather than failing raw on its DROP (or, for a rule on the parent, dropping it).
--
-- Fixtures, asymmetric on purpose:
--   (A) dv205 carries seven objects that name it by oid (two views, one of them on no column at all, a
--       materialized view, a BEGIN ATOMIC function, a policy on another table, a rule on another table and a
--       rule on dv205 itself) and two that must NOT be named: dv205's own self-referencing policy, which the
--       cutover carries by re-parsing it, and a view over an unrelated table. The refusal names exactly the
--       seven; nothing is committed; with the seven dropped the same call converts, and a view re-created
--       over the converted table sees the forward partition's row as well as the monolith's;
--   (B) a view over dw205 created INSIDE the cutover, after the preflight and before its lock (an event
--       trigger on the staging CREATE TABLE, through dblink so the phases can commit), is refused by the
--       cutover, leaving the resumable phase-2 state; the re-run resumes and converts;
--   (C) du205, converted, then a view and a rule over the PARENT: untransmute refuses naming both, then the
--       rule alone once the view is gone (the rule is the case the DROP would have taken silently); a view
--       over the monolith partition is not named, and after the reverse it reads the restored table whole.
-- Each refusal is pinned by its message (throws_like): a committing procedure that does NOT refuse dies at
-- its first COMMIT inside pgTAP with 2D000, which an unpinned assertion would accept.
-- bench/transmute_oid_bound_dependants.sh runs this file against the mutations that put each refusal back
-- (bench/mutations/mutate.py), so it is also required to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(30);

set client_min_messages = warning;

-- ====================================================================================================
-- (A) the preflight names every object bound to the table's oid, and only those
-- ====================================================================================================
create table public.dv205 (k int8 primary key, v text);
insert into public.dv205 select g, 'r' || g from generate_series(1, 10) g;   -- step 100: monolith [0, 100)
create table public.ot205 (id int8);
create table public.src205 (k int8);
create table public.audit205 (k int8);
create view public.dv205_v as select k, v from public.dv205;
create view public.dv205_v2 as select count(*) as n from public.dv205;
create materialized view public.dv205_mv as select k from public.dv205;
create function public.dv205_n() returns bigint language sql begin atomic select count(*) from public.dv205; end;
create policy ot205_p on public.ot205 using (exists (select 1 from public.dv205 d where d.k = ot205.id));
create rule src205_r as on insert to public.src205 do also insert into public.dv205 values (new.k, 'src');
create rule dv205_r as on insert to public.dv205 do also insert into public.audit205 values (new.k);
-- and the two that are not refused
create policy dv205_self on public.dv205 using (exists (select 1 from public.dv205 d2 where d2.k = 1));
create view public.x205_v as select id from public.ot205;

select is((select count(distinct d.classid::text || ':' || d.objid)::int from pg_depend d
            where d.refclassid = 'pg_class'::regclass and d.refobjid = 'public.dv205'::regclass
              and d.classid in ('pg_rewrite'::regclass, 'pg_proc'::regclass, 'pg_policy'::regclass)),
  8, 'A LIVENESS: eight objects depend on dv205 (the seven to refuse, and its own policy)');
select throws_like($$ call pgpm.transmute('public.dv205', 'k', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: cannot transmute dv205 -- the object(s) (function dv205_n(), materialized view dv205_mv, policy ot205_p on ot205, rule dv205_r on dv205, rule src205_r on src205, view dv205_v, view dv205_v2) name it by its oid,%',
  'A: the refusal names exactly the seven objects bound to the oid, and not dv205''s own policy or x205_v');
select is((select relkind::text from pg_class where oid = 'public.dv205'::regclass), 'r', 'A: dv205 is still a plain table');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.dv205'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.dv205'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.dv205'::regclass),
  'A: no bound, no claim and no config row were committed');
select lives_ok($$ insert into public.dv205 values (5000, 'past') $$, 'A: dv205 still takes a write past any bound');
delete from public.dv205 where k = 5000;
delete from public.audit205;

drop view public.dv205_v;
drop view public.dv205_v2;
drop materialized view public.dv205_mv;
drop function public.dv205_n();
drop policy ot205_p on public.ot205;
drop rule src205_r on public.src205;
drop rule dv205_r on public.dv205;
call pgpm.transmute('public.dv205', 'k', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.dv205'::regclass), 'p',
  'A LIVENESS: with the seven dropped, the same call converts dv205 (its own policy and x205_v did not stop it)');
-- The carried copy is created after the renames (#897), so its subquery binds to the parent. It used to be
-- created on the staging parent before them, bound to the original oid, and the cutover's re-check had to
-- exempt it; the monolith partition's copy is its own, and still names the monolith.
select is((select array_agg(distinct d.refobjid) from pg_depend d join pg_policy p on p.oid = d.objid
            where d.classid = 'pg_policy'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype = 'n'
              and p.polrelid = 'public.dv205'::regclass and p.polname = 'dv205_self'),
  array['public.dv205'::regclass::oid],
  'A: the parent''s carried copy of dv205_self reads the parent, not the original oid the monolith took (#897)');
insert into public.dv205 values (150, 'forward'), (11, 'mono');
select isnt((select tableoid from public.dv205 where k = 150), (select monolith_oid from pgpm.config where parent_table = 'public.dv205'::regclass),
  'A LIVENESS: k = 150 landed in a forward partition, not the monolith');
select is((select tableoid from public.dv205 where k = 11), (select monolith_oid from pgpm.config where parent_table = 'public.dv205'::regclass),
  'A LIVENESS: k = 11 landed in the monolith');
create view public.dv205_v as select k, v from public.dv205;
select is((select array_agg(k order by k) from public.dv205_v),
  array[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 150]::int8[],
  'A: a view re-created over the converted table returns the monolith''s rows and the forward partition''s k = 150');

-- ====================================================================================================
-- (B) a view created after the preflight is refused by the cutover, under its lock
-- ====================================================================================================
create table public.dw205 (k int8 primary key, v text);
insert into public.dw205 select g, 'w' || g from generate_series(1, 5) g;
create sequence public.w205_seq;   -- a refused cutover rolls the view back, but not a nextval
create function public.t205_inject() returns event_trigger language plpgsql as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    if r.command_tag = 'CREATE TABLE' and r.object_identity = 'public.dw205_pgpm_new'
       and not (select is_called from public.w205_seq) then
      perform nextval('public.w205_seq');
      create view public.dw205_late as select k from public.dw205;
    end if;
  end loop;
end $$;
create event trigger t205_inject on ddl_command_end when tag in ('CREATE TABLE') execute function public.t205_inject();

select is((select relkind::text from pg_class where oid = 'public.dw205'::regclass)
          || ':' || (select count(*)::int from pg_depend where refobjid = 'public.dw205'::regclass
                      and classid = 'pg_rewrite'::regclass)::text,
  'r:0', 'B LIVENESS: dw205 is a plain table with no view over it when transmute starts, so the preflight passes');
select dblink_connect('t205', 'dbname=' || current_database());
select throws_like(
  $$ select dblink_exec('t205', 'call pgpm.transmute(''public.dw205'', ''k'', 100::bigint, p_obtain => 2)') $$,
  '%pg_partition_magician: cannot transmute dw205 -- the object(s) (view dw205_late) name it by its oid,%',
  'B: the cutover refuses the view created after the preflight');
select is((select last_value::int || ':' || is_called::text from public.w205_seq), '1:true',
  'B LIVENESS: the window''s view went on once, inside the cutover');
select is((select relkind::text from pg_class where oid = 'public.dw205'::regclass), 'r', 'B: dw205 is still the plain table');
select is(to_regclass('public.dw205_late'), null, 'B: and the view went with the cutover''s rollback');
select is(
  (select convalidated from pg_constraint where conrelid = 'public.dw205'::regclass and conname = 'pgpm_monolith_bound'),
  true, 'B: phases 1 and 2 committed and stand: the refusal came from the cutover, leaving the resumable state');
select lives_ok(
  $$ select dblink_exec('t205', 'call pgpm.transmute(''public.dw205'', ''k'', 100::bigint, p_obtain => 2)') $$,
  'B LIVENESS: the re-run, with no view created this time, converts dw205');
select dblink_disconnect('t205');
drop event trigger t205_inject;
select is((select relkind::text from pg_class where oid = 'public.dw205'::regclass), 'p', 'B LIVENESS: dw205 is partitioned');
select is((select count(*)::int from pgpm.log where parent_table = 'public.dw205'::regclass and action = 'transmute_resume'), 1,
  'B LIVENESS: the re-run RESUMED on the bound the refused run committed');
select is((select array_agg(k order by k) from public.dw205), array[1, 2, 3, 4, 5]::int8[], 'B: the rows are intact');

-- ====================================================================================================
-- (C) untransmute refuses objects over the parent, and only those
-- ====================================================================================================
create table public.du205 (k int8 primary key, v text);
insert into public.du205 select g, 'u' || g from generate_series(1, 6) g;
call pgpm.transmute('public.du205', 'k', 100::bigint, p_obtain => 2);
select monolith_oid::regclass::text as du_mono from pgpm.config where parent_table = 'public.du205'::regclass \gset
create view public.du205_v as select k from public.du205;
create rule du205_r as on insert to public.du205 do also insert into public.audit205 values (new.k);
create view public.du205_mono_v as select k from :du_mono;   -- over the monolith partition: not refused
insert into public.du205 values (7, 'u7');
select is((select array_agg(k order by k) from public.audit205), array[7]::int8[],
  'C LIVENESS: the rule on the parent fires for a write through it');
select throws_like($$ select pgpm.untransmute('public.du205') $$,
  'pg_partition_magician: cannot untransmute du205 -- the object(s) (rule du205_r on du205, view du205_v) name the partitioned table by its oid,%',
  'C: untransmute refuses the view and the rule over the parent, naming both and not the monolith''s view');
select is((select relkind::text from pg_class where oid = 'public.du205'::regclass), 'p', 'C: du205 is still partitioned');
select ok(exists (select 1 from pgpm.config where parent_table = 'public.du205'::regclass), 'C: and still managed');
drop view public.du205_v;
select throws_like($$ select pgpm.untransmute('public.du205') $$,
  'pg_partition_magician: cannot untransmute du205 -- the object(s) (rule du205_r on du205) name the partitioned table by its oid,%',
  'C: with the view gone, the rule alone is refused (the DROP would have taken it without a word)');
select ok(exists (select 1 from pg_rewrite where rulename = 'du205_r' and ev_class = 'public.du205'::regclass),
  'C: the rule is still on the parent');
drop rule du205_r on public.du205;
select lives_ok($$ select pgpm.untransmute('public.du205') $$, 'C LIVENESS: with both gone, untransmute reverses du205');
select is((select relkind::text from pg_class where oid = 'public.du205'::regclass), 'r', 'C LIVENESS: du205 is the plain table again');
select is((select array_agg(k order by k) from public.du205_mono_v), array[1, 2, 3, 4, 5, 6, 7]::int8[],
  'C: the view over the monolith now reads the restored table, every row');
select is((select array_agg(k order by k) from public.du205), array[1, 2, 3, 4, 5, 6, 7]::int8[], 'C: the rows are intact');

select * from finish();
