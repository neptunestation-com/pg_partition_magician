-- The transmute reaper and transmute_abort find a half-converted table by its oid, not its name (issue #575).
--
-- A conversion that fails between transmute's phases leaves a write-rejecting pgpm_monolith_bound CHECK on
-- the table and a claim in pgpm.transmute_inflight recording it. The claim is keyed by the table's oid
-- (parent_table) and also carries the schema and name the table had when it was claimed (nsp, rel). The
-- reaper decided "the relation itself is gone" from nsp/rel, so a table renamed or moved to another schema
-- after its conversion failed read as gone: the reaper deleted the claim and left the bound, rejecting every
-- write outside [lo, hi) with nothing anywhere left recording it. transmute_abort, called by the table's new
-- name, found the claim by oid and then altered the OLD name, which no longer exists.
--
-- Fixtures, asymmetric on purpose: three abandoned conversions reach the reaper, one renamed (rn -> rn_old),
-- one moved to another schema (mv -> elsewhere.mv), one really dropped (gone). The first two must have their
-- bound dropped and a transmute_reap logged under their oid; the third, whose relation is genuinely gone,
-- must only be forgotten. A fourth (ab), renamed, is aborted by hand by its new name before the sweep.
--
-- The failing conversions run in a dblink session (a committing procedure cannot run inside throws_ok, and
-- pg_prove runs this file under ON_ERROR_STOP); each fails in phase 2 on a row dated past any bound, which
-- another session commits after the conversion read the table's maximum (phase2_stray, below). The
-- claims' owner is cleared rather than polled for (tests/101's stand-in for a session that has ended).
-- bench/transmute_reap_identity.sh runs this file against a mutant that resolves the table by name again
-- (transmute_reap_by_name), so it is also required to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(25);

-- phase2_stray(rel, row_sql, call_sql, tz): make call_sql fail in phase 2 on a stray row, deterministically
-- (#668). transmute now reads the table's maximum and refuses or covers a future-dated row before phase 1,
-- so a stray already in the table no longer reaches VALIDATE. One that is committed AFTER that read does:
-- session pw inserts row_sql and holds it uncommitted (its ROW EXCLUSIVE lock blocks phase 1's ADD), session
-- pa starts call_sql, which reads the maximum without seeing the row and then waits on phase 1's ACCESS
-- EXCLUSIVE; once pa is seen waiting, pw commits, the ADD ... NOT VALID proceeds without checking existing
-- rows, and phase 2's VALIDATE finds the row. Returns whether pa was seen waiting when pw committed (the
-- ordering witness: nothing of phase 1 had run yet, so VALIDATE could only come after the commit) and the
-- error pa's CALL ended with. The poll reads pg_locks only, which takes no lock on the table.
create function pg_temp.phase2_stray(p_rel regclass, p_row_sql text, p_call_sql text, p_tz text default 'UTC',
                                     out waited boolean, out err_state text, out err_msg text)
language plpgsql as $f$
declare v_pid int;
begin
  perform dblink_connect('pw', 'dbname=' || current_database());
  perform dblink_exec('pw', 'begin');
  perform dblink_exec('pw', p_row_sql);
  perform dblink_connect('pa', 'dbname=' || current_database());
  perform dblink_exec('pa', format('set timezone = %L', p_tz));
  select pid into v_pid from dblink('pa', 'select pg_backend_pid()') as t(pid int);
  perform dblink_send_query('pa', p_call_sql);
  waited := false;
  err_state := 'none';
  err_msg := 'the CALL did not fail';
  for i in 1 .. 400 loop
    if exists (select 1 from pg_locks where pid = v_pid and relation = p_rel
                  and mode = 'AccessExclusiveLock' and not granted) then
      waited := true;
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
  perform dblink_exec('pw', 'commit');
  begin
    perform * from dblink_get_result('pa') as t(r text);
  exception when others then
    err_state := sqlstate;
    err_msg := sqlerrm;
  end;
  perform dblink_disconnect('pa');
  perform dblink_disconnect('pw');
end
$f$;

set timezone = 'UTC';
create schema elsewhere;
create table public.rn (id bigint, ts timestamptz not null, primary key (ts, id));
create table public.mv (id bigint, ts timestamptz not null, primary key (ts, id));
create table public.gone (id bigint, ts timestamptz not null, primary key (ts, id));
create table public.ab (id bigint, ts timestamptz not null, primary key (ts, id));
insert into public.rn select g, now() - (g || ' days')::interval from generate_series(1, 20) g;
insert into public.mv select g, now() - (g || ' days')::interval from generate_series(1, 12) g;
insert into public.gone select g, now() - (g || ' days')::interval from generate_series(1, 5) g;
insert into public.ab select g, now() - (g || ' days')::interval from generate_series(1, 7) g;

select * from pg_temp.phase2_stray('public.rn', $$insert into public.rn values (100, now() + interval '3 months')$$,
  $$call pgpm.transmute('public.rn', 'ts', interval '1 day')$$) \gset rn_
select * from pg_temp.phase2_stray('public.mv', $$insert into public.mv values (100, now() + interval '3 months')$$,
  $$call pgpm.transmute('public.mv', 'ts', interval '1 day')$$) \gset mv_
select * from pg_temp.phase2_stray('public.gone', $$insert into public.gone values (100, now() + interval '3 months')$$,
  $$call pgpm.transmute('public.gone', 'ts', interval '1 day')$$) \gset gone_
select * from pg_temp.phase2_stray('public.ab', $$insert into public.ab values (100, now() + interval '3 months')$$,
  $$call pgpm.transmute('public.ab', 'ts', interval '1 day')$$) \gset ab_
select is(array[:'rn_waited', :'mv_waited', :'gone_waited', :'ab_waited']::boolean[], array[true, true, true, true],
  'LIVENESS: each stray''s writer committed while its conversion waited on phase 1''s lock, before any VALIDATE');
select is(:'rn_err_state' || ': ' || :'rn_err_msg', '23514: check constraint "pgpm_monolith_bound" of relation "rn" is violated by some row',
  'LIVENESS: rn''s conversion fails in phase 2');
select is(:'mv_err_state' || ': ' || :'mv_err_msg', '23514: check constraint "pgpm_monolith_bound" of relation "mv" is violated by some row',
  'LIVENESS: mv''s conversion fails in phase 2');
select is(:'gone_err_state' || ': ' || :'gone_err_msg', '23514: check constraint "pgpm_monolith_bound" of relation "gone" is violated by some row',
  'LIVENESS: gone''s conversion fails in phase 2');
select is(:'ab_err_state' || ': ' || :'ab_err_msg', '23514: check constraint "pgpm_monolith_bound" of relation "ab" is violated by some row',
  'LIVENESS: ab''s conversion fails in phase 2');
select is((select string_agg(t, ',') from (select 'rn' from public.rn r join pgpm.transmute_inflight i on i.parent_table = 'public.rn'::regclass where r.id = 100 and r.ts >= i.hi::timestamptz
                                            union all select 'mv' from public.mv r join pgpm.transmute_inflight i on i.parent_table = 'public.mv'::regclass where r.id = 100 and r.ts >= i.hi::timestamptz
                                            union all select 'gone' from public.gone r join pgpm.transmute_inflight i on i.parent_table = 'public.gone'::regclass where r.id = 100 and r.ts >= i.hi::timestamptz
                                            union all select 'ab' from public.ab r join pgpm.transmute_inflight i on i.parent_table = 'public.ab'::regclass where r.id = 100 and r.ts >= i.hi::timestamptz) w(t)),
  'rn,mv,gone,ab',
  'LIVENESS: each table holds its committed stray, id 100, past the hi its claim recorded (the bound was computed without it)');

select 'public.rn'::regclass::oid as rn_oid, 'public.mv'::regclass::oid as mv_oid,
       'public.gone'::regclass::oid as gone_oid, 'public.ab'::regclass::oid as ab_oid \gset
select is((select string_agg(rel::text, ',' order by rel) from pgpm.transmute_inflight where parent_table::oid in (:'rn_oid'::oid, :'mv_oid'::oid, :'gone_oid'::oid, :'ab_oid'::oid)), 'ab,gone,mv,rn',
  'LIVENESS: each failed conversion left its claim');
select is((select string_agg(k.relname::text, ',' order by k.relname) from pg_constraint c join pg_class k on k.oid = c.conrelid
            where c.conname = 'pgpm_monolith_bound' and c.conrelid in (:'rn_oid'::oid, :'mv_oid'::oid, :'gone_oid'::oid, :'ab_oid'::oid)), 'ab,gone,mv,rn',
  'LIVENESS: and its pgpm_monolith_bound CHECK');
update pgpm.transmute_inflight set owner_pid = null, owner_backend_start = null where parent_table::oid in (:'rn_oid'::oid, :'mv_oid'::oid, :'gone_oid'::oid, :'ab_oid'::oid);

-- the operator renames one, moves one, drops one; the table itself (same oid) is still there for two of them
alter table public.rn rename to rn_old;
alter table public.mv set schema elsewhere;
drop table public.gone;
alter table public.ab rename to ab_renamed;
select is((select 'public.rn_old'::regclass::oid), :'rn_oid'::oid, 'LIVENESS: rn_old is the same relation rn was');
select is((select 'elsewhere.mv'::regclass::oid), :'mv_oid'::oid, 'LIVENESS: elsewhere.mv is the same relation public.mv was');
select throws_ok($$ insert into public.rn_old values (200, now() + interval '2 days') $$, '23514', NULL,
  'LIVENESS: before the sweep, the bound on rn_old rejects a write two days out');

-- the operator aborts the renamed ab by its new name, before any sweep
select lives_ok($$ select pgpm.transmute_abort('public.ab_renamed') $$,
  'transmute_abort by the table''s new name runs');
select is((select count(*)::int from pg_constraint where conrelid = :'ab_oid'::oid and conname = 'pgpm_monolith_bound'), 0,
  'and drops the bound from that table');
select is((select string_agg(parent_table::oid::text, ',') from pgpm.log where action = 'transmute_abort' and parent_table::oid in (:'rn_oid'::oid, :'mv_oid'::oid, :'gone_oid'::oid, :'ab_oid'::oid)), :'ab_oid'::oid::text,
  'transmute_abort is logged under ab''s oid');
select lives_ok($$ insert into public.ab_renamed values (200, now() + interval '2 days') $$,
  'ab_renamed accepts a write past the old bound again');

select cmp_ok(pgpm._transmute_reap(), '>=', 3, 'LIVENESS: the sweep acted, on at least the three abandoned conversions left here');
select is((select count(*)::int from pg_constraint where conrelid = :'rn_oid'::oid and conname = 'pgpm_monolith_bound'), 0,
  'the reaper dropped the bound from the renamed table');
select is((select count(*)::int from pg_constraint where conrelid = :'mv_oid'::oid and conname = 'pgpm_monolith_bound'), 0,
  'and from the table moved to another schema');
select is((select string_agg(parent_table::oid::text, ',' order by parent_table::oid) from pgpm.log where action = 'transmute_reap' and parent_table::oid in (:'rn_oid'::oid, :'mv_oid'::oid, :'gone_oid'::oid, :'ab_oid'::oid)),
  (select string_agg(o::text, ',' order by o) from unnest(array[:'rn_oid'::oid, :'mv_oid'::oid]) o),
  'of these four, transmute_reap is logged for exactly the renamed and the moved one, under their oid');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table::oid = :'gone_oid'::oid), 0,
  'the dropped table''s claim is forgotten');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table::oid in (:'rn_oid'::oid, :'mv_oid'::oid, :'gone_oid'::oid, :'ab_oid'::oid)), 0, 'no claim of these four is left');
select lives_ok($$ insert into public.rn_old values (200, now() + interval '2 days') $$,
  'rn_old accepts a write past the old bound again');
select lives_ok($$ insert into elsewhere.mv values (200, now() + interval '2 days') $$,
  'and so does elsewhere.mv');
select is((select string_agg(x, ',') from (select 'rn_old ' || id from public.rn_old where id = 200
                                           union all select 'mv ' || id from elsewhere.mv where id = 200) w(x)),
  'rn_old 200,mv 200', 'and both writes are there, by identity');
select is((select count(*)::int from public.rn_old), 22, 'rn_old kept every row it had, and the new one');


select * from finish();
