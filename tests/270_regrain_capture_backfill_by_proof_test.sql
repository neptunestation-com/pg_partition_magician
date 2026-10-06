-- The upgrade records a regrain's capture only on proof that pgpm minted it (issue #969 bullets 3 and 7).
--
-- install.sql carries an upgrade block (#496) that records pgpm.config.regrain_delta_oid and
-- regrain_capture_fn_oid for every parent with nothing recorded, so a regrain in flight across the upgrade is
-- found by oid from then on. It found them by NAME alone, <rel>_pgpm_regrain_delta, and re-running
-- install.sql is the documented upgrade, on a fresh install too: an operator's own table under that name,
-- beside a parent that never regrained, was recorded as the parent's delta, and the next prepare DROPPED it
-- with its rows as "the previous regrain's", where without the re-run the same prepare refuses the namesake.
-- Now the pair is recorded only on proof that pgpm minted it: the capture function under its derived name, a
-- trigger function whose body inserts into exactly that relation, and the relation carrying the delta's
-- pgpm_seq identity column.
--
-- (A) NEGATIVE. Two parents that never regrained: n270a beside an operator's table under its delta's name
--     (3 rows), n270b beside an operator's table (2 rows) AND an operator's trigger function under its
--     capture function's name, which writes elsewhere. After the re-run neither is recorded, the prepare
--     refuses each table by name, and each table is the same relation with its rows.
-- (B) LIVENESS of the proof. p270c's completed regrain left its delta and capture function (no trigger, as a
--     completed run leaves them); p270d's regrain is in flight. Both have their anchors cleared, the state an
--     install from before #496 is in. After the re-run each is recorded by identity, p270c's next prepare
--     takes them for pgpm's own (it prepares, minting fresh ones), and p270d's run goes on copying.
-- bench/upgrade_in_place.sh carries the same contract against a degraded install and a real v0.6.0 one, and
-- is the guard bench/discriminate.sh points at the mutant (scratch_upgrade_adopts_namesake).
--
-- install.sql is read with \ir, relative to this file; the psql variable `install` overrides the path.
\if :{?install}
\else
\set install ../pgpm_core/install.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(14);

-- (A) the operator's namesakes beside parents that never regrained
create table public.n270a (id bigint primary key, payload text);
insert into public.n270a select g, 'a' || g from generate_series(1, 120) g;
call pgpm.transmute('public.n270a', 'id', 100);
select pgpm.obtain('public.n270a');
insert into public.n270a values (450, 'frontier');
create table public.n270a_pgpm_regrain_delta (note text);
insert into public.n270a_pgpm_regrain_delta values ('op-a1'), ('op-a2'), ('op-a3');

create table public.n270b (id bigint primary key, payload text);
insert into public.n270b select g, 'b' || g from generate_series(1, 140) g;
call pgpm.transmute('public.n270b', 'id', 100);
select pgpm.obtain('public.n270b');
insert into public.n270b values (450, 'frontier');
create table public.n270b_audit (id bigint);
create table public.n270b_pgpm_regrain_delta (id bigint, pgpm_seq bigint generated always as identity);
insert into public.n270b_pgpm_regrain_delta (id) values (7), (8);
create function public.n270b_pgpm_regrain_capture() returns trigger language plpgsql as $$
begin insert into public.n270b_audit (id) values (new.id); return new; end $$;

select 'public.n270a_pgpm_regrain_delta'::regclass::oid as a_tbl, 'public.n270b_pgpm_regrain_delta'::regclass::oid as b_tbl,
       'public.n270b_pgpm_regrain_capture()'::regprocedure::oid as b_fn \gset
select child_name as a_mono from pgpm.part where parent_table = 'public.n270a'::regclass and attached order by lo::numeric limit 1 \gset
select child_name as b_mono from pgpm.part where parent_table = 'public.n270b'::regclass and attached order by lo::numeric limit 1 \gset
select is((select string_agg((regrain_delta_oid is null and regrain_capture_fn_oid is null and regrain_cursor is null
                             and not exists (select 1 from pg_trigger t join pg_inherits i on i.inhrelid = t.tgrelid
                                              where i.inhparent = c.parent_table and t.tgname = 'pgpm_regrain_capture'))::text, ','
                             order by c.parent_table::text)
             from pgpm.config c where c.parent_table in ('public.n270a'::regclass, 'public.n270b'::regclass)),
  'true,true', 'LIVENESS: n270a and n270b never regrained: nothing recorded, no capture anywhere, the operator''s namesakes hold the names');

-- (B) pgpm's own capture, anchors cleared as before #496
create table public.p270c (id bigint primary key, payload text);
insert into public.p270c select g, 'c' || g from generate_series(1, 299) g;
call pgpm.transmute('public.p270c', 'id', 100, p_obtain => 3);
select pgpm.obtain('public.p270c');
insert into public.p270c select g, 'c' || g from generate_series(300, 450) g;
select pgpm.regrain('public.p270c', 'p270c_p0000000000000000300', '50');
create table public.p270d (id bigint primary key, payload text);
insert into public.p270d select g, 'd' || g from generate_series(1, 299) g;
call pgpm.transmute('public.p270d', 'id', 100, p_obtain => 3, p_regrain_batch => 40);
select pgpm.obtain('public.p270d');
insert into public.p270d values (450, 'frontier');
select pgpm.regrain_step('public.p270d', 'p270d_p0000000000000000000_to_0000000000000000300', '50');
select pgpm.regrain_step('public.p270d', 'p270d_p0000000000000000000_to_0000000000000000300', '50');
select regrain_delta_oid as c_delta, regrain_capture_fn_oid as c_fn from pgpm.config where parent_table = 'public.p270c'::regclass \gset
select regrain_delta_oid as d_delta, regrain_capture_fn_oid as d_fn from pgpm.config where parent_table = 'public.p270d'::regclass \gset
update pgpm.config set regrain_delta_oid = null, regrain_capture_fn_oid = null
 where parent_table in ('public.p270c'::regclass, 'public.p270d'::regclass);
select is((select (to_regclass('public.p270c_pgpm_regrain_delta')::oid = :'c_delta'::oid)::text || '/'
                  || (select regrain_cursor is null from pgpm.config where parent_table = 'public.p270c'::regclass)::text || '/'
                  || (to_regclass('public.p270d_pgpm_regrain_delta')::oid = :'d_delta'::oid)::text || '/'
                  || (select regrain_cursor from pgpm.config where parent_table = 'public.p270d'::regclass)),
  'true/true/true/0', 'LIVENESS: p270c''s completed regrain left its delta, p270d''s is in flight, both anchors cleared');

-- the upgrade
\ir :install
set client_min_messages = warning;

-- (A) after it
select is((select string_agg(coalesce(regrain_delta_oid::text, 'null') || '/' || coalesce(regrain_capture_fn_oid::text, 'null'), ','
                             order by parent_table::text)
             from pgpm.config where parent_table in ('public.n270a'::regclass, 'public.n270b'::regclass)),
  'null/null,null/null', 'the upgrade records no capture for a parent that never regrained, beside the operator''s namesakes');
select throws_like(format('select pgpm.regrain_step(%L, %L, %L)', 'public.n270a', :'a_mono', '50'),
  '%would mint its delta table as public.n270a_pgpm_regrain_delta, and that name is held by relation%',
  'n270a''s next prepare refuses the operator''s table by name, as on a fresh install');
select throws_like(format('select pgpm.regrain_step(%L, %L, %L)', 'public.n270b', :'b_mono', '50'),
  '%would mint its delta table as public.n270b_pgpm_regrain_delta, and that name is held by relation%',
  'n270b''s next prepare refuses the operator''s table by name, its function notwithstanding');
select is((select array_agg(to_jsonb(t) ->> 'note' order by to_jsonb(t) ->> 'note') from public.n270a_pgpm_regrain_delta t where t.tableoid = :'a_tbl'::oid),
  array['op-a1', 'op-a2', 'op-a3'], 'n270a''s namesake is the same relation, with its 3 rows');
select is((select array_agg(id order by id) from public.n270b_pgpm_regrain_delta where tableoid = :'b_tbl'::oid),
  array[7, 8]::bigint[], 'n270b''s namesake is the same relation, with its 2 rows');
select is((select oid from pg_proc where oid = :'b_fn'::oid), :'b_fn'::oid, 'n270b''s namesake function is the same function');

-- (B) after it
select is((select (regrain_delta_oid = :'c_delta'::oid)::text || '/' || (regrain_capture_fn_oid = :'c_fn'::oid)::text
             from pgpm.config where parent_table = 'public.p270c'::regclass),
  'true/true', 'the upgrade records p270c''s completed regrain''s delta and capture function, by identity');
select is((select (regrain_delta_oid = :'d_delta'::oid)::text || '/' || (regrain_capture_fn_oid = :'d_fn'::oid)::text
             from pgpm.config where parent_table = 'public.p270d'::regclass),
  'true/true', 'the upgrade records p270d''s in-flight delta and capture function, by identity');
select is(pgpm.regrain_step('public.p270c', (select child_name from pgpm.part where parent_table = 'public.p270c'::regclass
                                               and attached order by lo::numeric limit 1), '50'),
  'prepared', 'p270c''s next prepare takes the recorded pair for pgpm''s own and prepares');
select is((select count(*)::int from pg_class where oid = :'c_delta'::oid) || '/'
          || (select count(*)::int from pg_proc where oid = :'c_fn'::oid) || '/'
          || (select (regrain_delta_oid <> :'c_delta'::oid)::text from pgpm.config where parent_table = 'public.p270c'::regclass),
  '0/0/true', 'and replaced them with fresh ones');
select is(pgpm.regrain_step('public.p270d', 'p270d_p0000000000000000000_to_0000000000000000300', '50'), 'copied:9',
  'p270d''s run goes on copying from its recorded capture (the last 9 rows of its first sub-range)');
select is((select array_agg(id order by id) from public.p270d where id in (1, 50, 99, 299, 450)),
  array[1, 50, 99, 299, 450]::bigint[], 'and p270d''s rows are all there');

select * from finish();
