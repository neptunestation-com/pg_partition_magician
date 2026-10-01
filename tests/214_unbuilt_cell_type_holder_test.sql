-- fail_obtain_name names the TYPE that holds an unbuilt cell's name (issue #790).
--
-- When a type (an enum, a domain, a range type) holds a forward cell's plain name, _obtain_name (#707)
-- leaves that cell unbuilt and both of its callers, obtain and extend_to, log fail_obtain_name through
-- _log_unbuilt_cell (#710). That function resolved the holder through to_regclass only, which sees
-- relations, so for a type the holder clause was null and format() rendered it as nothing: the method
-- read "its name public.x is held by " and stopped, against docs/reference.md's "`method` names what
-- holds it". The fix names a type holder with _type_squatter's noun (the one transmute's refusals use).
--
-- Fixture, asymmetric on purpose: four forward cells for obtain, three of them held by three different
-- kinds of holder (an enum, a domain, and a view, the relation case the fix must not disturb) and one
-- free; then a fifth cell, held by a range type, for extend_to, the second caller. Each method is pinned
-- EXACTLY, so a holder clause that names the wrong kind, the wrong object or nothing fails, and the
-- liveness rows say the cells really were left unbuilt (and the free one really was built), so the
-- methods are not read off a run that never reached _log_unbuilt_cell.
-- bench/unbuilt_cell_type_holder.sh runs this file against the mutant unbuilt_cell_type_holder_unnamed
-- (the pre-fix holder clause), so it is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(8);

create table public.t214 (id bigint primary key, payload text);
insert into public.t214 values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.t214', 'id', 10::bigint, p_obtain => 0, p_paused => false);
select is(
  (select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part where parent_table = 'public.t214'::regclass),
  array['0-20'],
  'fixture: the conversion built the monolith [0, 20) alone, so every forward cell is still to build');

-- the holders, each under the plain name _part_name gives its cell
select pgpm._part_name('t214', 'id', '10', '20', '30', 'UTC') as c20,
       pgpm._part_name('t214', 'id', '10', '40', '50', 'UTC') as c40,
       pgpm._part_name('t214', 'id', '10', '50', '60', 'UTC') as c50,
       pgpm._part_name('t214', 'id', '10', '60', '70', 'UTC') as c60 \gset
select format('create type public.%I as enum (''x'')', :'c20') \gexec
select format('create domain public.%I as int', :'c40') \gexec
select format('create view public.%I as select 1 as one', :'c50') \gexec
select format('create type public.%I as range (subtype = int4)', :'c60') \gexec

select pgpm.set_obtain('public.t214', 4);
call pgpm.maintain_obtain('public.t214');

select is(
  (select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part where parent_table = 'public.t214'::regclass),
  array['0-20', '30-40'],
  'LIVENESS: obtain built the free cell [30, 40) and left the three held ones ([20, 30), [40, 50), [50, 60)) unbuilt');
select is(
  (select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
    where parent_table = 'public.t214'::regclass and action = 'fail_obtain_name'),
  array['20-30', '40-50', '50-60'],
  'LIVENESS: obtain logged fail_obtain_name for exactly the three held cells, once each');

select is(
  (select method from pgpm.log where parent_table = 'public.t214'::regclass and action = 'fail_obtain_name' and lo = '20'),
  format('left unbuilt, so writes into it are refused: its name public.%s is held by an enum type public.%s'
         ' (a partition''s row type takes its name, so no type may hold it)', :'c20', :'c20'),
  'an enum holding the cell''s name is named in fail_obtain_name''s method, as an enum type');
select is(
  (select method from pgpm.log where parent_table = 'public.t214'::regclass and action = 'fail_obtain_name' and lo = '40'),
  format('left unbuilt, so writes into it are refused: its name public.%s is held by a domain public.%s'
         ' (a partition''s row type takes its name, so no type may hold it)', :'c40', :'c40'),
  'a domain holding the cell''s name is named as a domain');
select is(
  (select method from pgpm.log where parent_table = 'public.t214'::regclass and action = 'fail_obtain_name' and lo = '50'),
  format('left unbuilt, so writes into it are refused: its name public.%s is held by view %s,'
         ' which is not a partition of this table', :'c50', :'c50'),
  'a relation holding the cell''s name is still named as that relation (the view), exactly as before');

-- the second caller: extend_to meets the range type over [60, 70)
select pgpm.extend_to('public.t214', '65');
select is(
  (select array_agg(lo || '-' || hi order by id) from pgpm.log
    where parent_table = 'public.t214'::regclass and action = 'fail_obtain_name' and lo = '60'),
  array['60-70'],
  'LIVENESS: extend_to left [60, 70) unbuilt and logged it once');
select is(
  (select method from pgpm.log where parent_table = 'public.t214'::regclass and action = 'fail_obtain_name' and lo = '60'),
  format('left unbuilt, so writes into it are refused: its name public.%s is held by a range type public.%s'
         ' (a partition''s row type takes its name, so no type may hold it)', :'c60', :'c60'),
  'extend_to names the range type holding the cell''s name');

select * from finish();
