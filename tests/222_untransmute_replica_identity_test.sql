-- untransmute hands back the managed table's REPLICA IDENTITY, not the monolith's conversion-time one
-- (issue #815, bullet F1-06 of review pass 7).
--
-- After a transmute the parent is the table, so ALTER TABLE <t> REPLICA IDENTITY lands on the parent, and
-- PostgreSQL does not recurse it to partitions (the premise of #782). untransmute carried the parent's
-- grants, row security, owner, comments and publication memberships back onto the restored table (#667,
-- #710, #780) but not its replica identity, so the identity set since the conversion was lost with the
-- parent's DROP: a table set FULL since came back DEFAULT, publishing key-only before-images to its
-- subscribers, and one set DEFAULT came back FULL.
--
-- Seven tables, each a different transition, so no single wrong hand-back satisfies them all:
--   ra222  DEFAULT at the conversion, FULL since
--   rb222  FULL at the conversion, DEFAULT since
--   rc222  DEFAULT at the conversion, USING INDEX on a carried unique index since (its parent copy is
--          rc222_u_uidx_pgpm; the restored table's identity is the original rc222_u_uidx)
--   rd222  DEFAULT at the conversion, USING INDEX on a unique index made since (handed back under the name
--          the managed table gave it, #830)
--   re222  DEFAULT at the conversion, NOTHING since
--   rg222  USING INDEX on its key at the conversion, DEFAULT since (the key's index must stop being the
--          identity)
--   rh222  USING INDEX on its key at the conversion, USING INDEX on another index since (the same kind,
--          another index: a hand-back that compares only the kind keeps the wrong one)
-- bench/untransmute_replica_identity.sh runs this file against two mutants, so it is also required to FAIL
-- there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(16);

create table public.ra222 (k bigint primary key, v text);
create table public.rb222 (k bigint primary key, v text);
alter table public.rb222 replica identity full;
create table public.rc222 (k bigint primary key, u int not null, v text);
create unique index rc222_u_uidx on public.rc222 (u, k);
create table public.rd222 (k bigint primary key, x int not null, v text);
create table public.re222 (k bigint primary key, v text);
create table public.rg222 (k bigint primary key, v text);
alter table public.rg222 replica identity using index rg222_pkey;
create table public.rh222 (k bigint primary key, x int not null, v text);
alter table public.rh222 replica identity using index rh222_pkey;
insert into public.ra222 select g, 'a' || g from generate_series(1, 3) g;
insert into public.rb222 select g, 'b' || g from generate_series(1, 4) g;
insert into public.rc222 select g, g * 2, 'c' || g from generate_series(1, 5) g;
insert into public.rd222 select g, g * 3, 'd' || g from generate_series(1, 2) g;
insert into public.re222 select g, 'e' || g from generate_series(1, 6) g;
insert into public.rg222 select g, 'g' || g from generate_series(1, 3) g;
insert into public.rh222 select g, g * 5, 'h' || g from generate_series(1, 4) g;
select oid as rc_uidx from pg_class where relname = 'rc222_u_uidx' and relnamespace = 'public'::regnamespace \gset
select oid as rg_key from pg_class where relname = 'rg222_pkey' and relnamespace = 'public'::regnamespace \gset
select oid as rh_key from pg_class where relname = 'rh222_pkey' and relnamespace = 'public'::regnamespace \gset

call pgpm.transmute('public.ra222', 'k', 100::bigint, p_obtain => 2);
call pgpm.transmute('public.rb222', 'k', 100::bigint, p_obtain => 2);
call pgpm.transmute('public.rc222', 'k', 100::bigint, p_obtain => 2);
call pgpm.transmute('public.rd222', 'k', 100::bigint, p_obtain => 2);
call pgpm.transmute('public.re222', 'k', 100::bigint, p_obtain => 2);
call pgpm.transmute('public.rg222', 'k', 100::bigint, p_obtain => 2);
call pgpm.transmute('public.rh222', 'k', 100::bigint, p_obtain => 2);

-- the operator's changes, on the managed tables
alter table public.ra222 replica identity full;
alter table public.rb222 replica identity default;
alter table public.rc222 replica identity using index rc222_u_uidx_pgpm;
create unique index rd222_x_uidx on public.rd222 (x, k);
alter table public.rd222 replica identity using index rd222_x_uidx;
alter table public.re222 replica identity nothing;
alter table public.rg222 replica identity default;
create unique index rh222_x_uidx on public.rh222 (x, k);
alter table public.rh222 replica identity using index rh222_x_uidx;

-- the replica identity of a table as kind:index, the index named, or - for none
create function pg_temp.ri(p_rel regclass) returns text language sql stable as $$
  select c.relreplident::text || ':' || coalesce((select ic.relname::text from pg_index i join pg_class ic on ic.oid = i.indexrelid
                                                   where i.indrelid = c.oid and i.indisreplident), '-')
    from pg_class c where c.oid = p_rel $$;
create temporary table mon222 as
  select g.parent_table::text as t, pg_temp.ri(g.monolith_oid::regclass) as mon_ri, pg_temp.ri(g.parent_table) as parent_ri
    from pgpm.config g where g.parent_table::text like 'r_222';

select is((select array_agg(t || ' ' || parent_ri order by t) from mon222),
  array['ra222 f:-', 'rb222 d:-', 'rc222 i:rc222_u_uidx_pgpm', 'rd222 i:rd222_x_uidx', 're222 n:-', 'rg222 d:-', 'rh222 i:rh222_x_uidx'],
  'LIVENESS: the managed tables carry the identities set since the conversion');
select is((select array_agg(t || ' ' || left(mon_ri, 2) order by t) from mon222),
  array['ra222 d:', 'rb222 f:', 'rc222 d:', 'rd222 d:', 're222 d:', 'rg222 i:', 'rh222 i:'],
  'LIVENESS: their monoliths keep the conversion-time ones, so every table has a difference to hand back');
select is((select mon_ri from mon222 where t = 'rh222'), 'i:pgpm_key_' || :rh_key,
  'LIVENESS: rh222''s monolith identity is its key, renamed pgpm_key_<oid> by the conversion (#789)');

select is(pgpm.untransmute('public.ra222')::text, 'ra222', 'LIVENESS: ra222 is restored');
select is(pgpm.untransmute('public.rb222')::text, 'rb222', 'LIVENESS: rb222 is restored');
select is(pgpm.untransmute('public.rc222')::text, 'rc222', 'LIVENESS: rc222 is restored');
select is(pgpm.untransmute('public.rd222')::text, 'rd222', 'LIVENESS: rd222 is restored');
select is(pgpm.untransmute('public.re222')::text || pgpm.untransmute('public.rg222')::text || pgpm.untransmute('public.rh222')::text,
  're222rg222rh222', 'LIVENESS: re222, rg222 and rh222 are restored');

select is(pg_temp.ri('public.ra222'), 'f:-', 'ra222 comes back REPLICA IDENTITY FULL, as the managed table was');
select is(pg_temp.ri('public.rb222'), 'd:-', 'rb222 comes back DEFAULT, as the managed table was');
select is((select i.indexrelid from pg_index i where i.indrelid = 'public.rc222'::regclass and i.indisreplident), :rc_uidx::oid,
  'rc222''s identity is the original rc222_u_uidx, the index attached under the parent''s identity index');
select is(pg_temp.ri('public.rc222'), 'i:rc222_u_uidx', 'under its own name');
select is(pg_temp.ri('public.rd222'), 'i:rd222_x_uidx', 'rd222''s identity is the index made since, under the name the managed table gave it');
select is(pg_temp.ri('public.re222'), 'n:-', 're222 comes back REPLICA IDENTITY NOTHING');
select is(pg_temp.ri('public.rg222') || ' ' || (select indisreplident::text from pg_index where indexrelid = :rg_key),
  'd:- false', 'rg222 comes back DEFAULT, its key no longer the identity index');
select is(pg_temp.ri('public.rh222') || ' ' || (select indisreplident::text from pg_index where indexrelid = :rh_key),
  'i:rh222_x_uidx false', 'rh222''s identity is the other index the managed table named, not its key');

select * from finish();
