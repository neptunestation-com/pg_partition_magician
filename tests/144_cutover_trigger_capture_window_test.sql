-- Issue #593: the cutover captured the table's row triggers at the very start of phase 3 (step 0b), under
-- no lock that excludes trigger DDL, and replayed only what it had captured after the rename. The staging
-- work between the two (CREATE TABLE ... LIKE, identity, grants, policies, comments) takes nothing
-- stronger than ACCESS SHARE on the table, and CREATE TRIGGER needs only SHARE ROW EXCLUSIVE, so a trigger
-- another session committed in that window never reached the new parent: step 7b dropped it from the
-- monolith with the triggers it had captured (or, when nothing had been captured, left it on the monolith
-- alone), and every row routed to a forward partition escaped it, silently. The capture now happens under
-- the table's ACCESS EXCLUSIVE, taken immediately before the incoming-FK drop and the renames, so nothing
-- can change the table's triggers between what is captured and what the rename carries.
--
-- The concurrent session lives in bench/cutover_trigger_window.sh. This file makes the same window
-- deterministic in one session: an event trigger fires on the cutover's own CREATE TABLE of the staging
-- parent, the first statement of the window, and creates a trigger on the live table there. That is a
-- trigger committed to the table after the old capture point and before the rename, by construction.
--
-- Asymmetric on purpose: one trigger exists before the conversion and adds 1, the one created in the
-- window adds 10, so the value a row ends up with says exactly which fired, and how often: 11 is both
-- once. Under the defect the window's trigger is dropped with the captured one's monolith original, so a
-- row carries 1 wherever it lands; a replay that left the monolith's originals in place would give 21 or 12
-- there. Every post-conversion claim is paired with a witness that the event trigger really fired, inside
-- the cutover, before the rename.
create extension if not exists pgtap;

select plan(9);

create table public.ev144 (id bigint primary key, n int not null default 0);
insert into public.ev144 (id) select g from generate_series(1, 15) g;
create function public.ev144_add1()  returns trigger language plpgsql as $$ begin new.n := new.n + 1;  return new; end $$;
create function public.ev144_add10() returns trigger language plpgsql as $$ begin new.n := new.n + 10; return new; end $$;
create trigger ev144_a_before before insert on public.ev144 for each row execute function public.ev144_add1();

-- The window: the staging parent's CREATE TABLE is the first statement after the old capture point.
-- relkind is recorded so the witness can say the live table was still the PLAIN table (not yet renamed
-- aside and replaced) when the trigger went on it.
create table public.ev144_window (staging text, live_relkind text);
create function public.ev144_inject() returns event_trigger language plpgsql as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands()
            where command_tag = 'CREATE TABLE' and object_identity = 'public.ev144_pgpm_new' loop
    if not exists (select 1 from public.ev144_window) then
      create trigger ev144_b_window before insert on public.ev144 for each row execute function public.ev144_add10();
      insert into public.ev144_window
        values (r.object_identity, (select relkind::text from pg_class where oid = 'public.ev144'::regclass));
    end if;
  end loop;
end $$;
create event trigger ev144_inject on ddl_command_end when tag in ('CREATE TABLE')
  execute function public.ev144_inject();

-- ============================================== before
insert into public.ev144 (id) values (16);
select is((select n from public.ev144 where id = 16), 1,
  'LIVENESS: before conversion a write fires only the pre-existing trigger (1)');

-- ============================================== transmute
call pgpm.transmute('public.ev144', 'id', 10::bigint, p_obtain => 2);
drop event trigger ev144_inject;

select is((select array_agg(staging || ':' || live_relkind) from public.ev144_window),
  array['public.ev144_pgpm_new:r'],
  'LIVENESS: the window trigger was created once, on the cutover''s staging CREATE TABLE, while ev144 was still the plain table');
select is((select relkind::text from pg_class where oid = 'public.ev144'::regclass), 'p',
  'LIVENESS: the table really was converted');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.ev144'::regclass and lo::bigint > 16),
  'LIVENESS: the conversion built a forward partition past the monolith');

select is(
  (select array_agg(tgname::text order by tgname) from pg_trigger
    where tgrelid = 'public.ev144'::regclass and not tgisinternal),
  array['ev144_a_before', 'ev144_b_window'],
  'the new parent carries the pre-existing trigger AND the one created in the cutover window');
select is(
  (select array_agg(t.tgname::text order by t.tgname) from pg_trigger t
    where not t.tgisinternal
      and t.tgrelid = (select format('%I.%I', 'public', child_name)::regclass from pgpm.part
                        where parent_table = 'public.ev144'::regclass order by lo::bigint limit 1)),
  array['ev144_a_before', 'ev144_b_window'],
  'the monolith carries each trigger once, as a clone of the parent''s (no original left beside it)');

-- A row into the monolith and one into a forward partition. The monolith covers [0, 20) here; 35 is
-- routed to a forward partition, which is the row that escaped the trigger under the defect.
insert into public.ev144 (id) values (17), (35);
select is((select n from public.ev144 where id = 17), 11,
  'a write routed to the monolith fires both triggers, once each (11)');
select is((select n from public.ev144 where id = 35), 11,
  'a write routed to a forward partition fires both triggers, once each (11)');
select is((select array_agg(id || ':' || n order by id) from public.ev144 where id >= 16),
  array['16:1', '17:11', '35:11'],
  'the rows written around the conversion carry exactly the values their triggers gave them');

select * from finish();
