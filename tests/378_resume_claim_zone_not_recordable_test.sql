-- A resumed transmute does not register a grid zone pgpm never records: a claim an older install recorded in
-- localtime is refused, with transmute_abort as the remedy, rather than adopted (issue #1111, V-02).
--
-- #1086 made _canonical_tz refuse localtime, posixrules and Factory, so neither transmute nor set_partition_tz
-- records one of them now. But a resume adopts the zone its claim recorded (#506: the bound sits on that zone's
-- lattice), and it did so without asking: a claim a pre-#1086 install recorded from a session SET to localtime
-- (phase 1 committed, the conversion then failed) was resumed from a UTC session after the upgrade, and the
-- conversion registered config.partition_tz = 'localtime', a grid that moves with the host's setting. The claim's
-- zone is asked now, in the first transaction, so the refusal rolls the take-over back and leaves the claim and
-- its bound as they were.
--
-- The fixture builds that claim by hand, as the reaper's tests do (an abandoned conversion: no live owner, the
-- NOT VALID bound in place), its bound computed on the localtime lattice by pgpm's own grid functions, so the only
-- thing between it and a resume is its zone. A twin, ru378, carries the same claim recorded in UTC and must
-- resume, so the refusal is the zone's and not the hand-built claim's. bench/resume_claim_zone.sh runs this file
-- against the mutant that adopts the zone unasked again.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(8);

create table public.rz378 (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.rz378 select i, now() - i * interval '1 minute' from generate_series(1, 20) i;
create table public.ru378 (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.ru378 select i, now() - i * interval '1 minute' from generate_series(101, 113) i;

create function pg_temp.claim(p_rel regclass, p_tz text) returns void language plpgsql as $$
declare v_lo text; v_hi text;
begin
  v_lo := pgpm._grid_floor('time', '1 day', pgpm._ts_text('2000-01-01 00:00:00+00'),
                           pgpm._ts_text(now() - interval '2 hours'), p_tz);
  v_hi := pgpm._grid_next('time', '1 day', pgpm._grid_floor('time', '1 day', pgpm._ts_text('2000-01-01 00:00:00+00'),
                                                            pgpm._ts_text(now()), p_tz), p_tz);
  insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz, control_attnum)
  values (p_rel, 'public', (select relname from pg_class where oid = p_rel), 'time', v_lo, v_hi, p_tz, 2);
  execute format('alter table %s add constraint pgpm_monolith_bound check (ts >= %L::timestamptz and ts < %L::timestamptz) not valid',
                 p_rel, v_lo, v_hi);
end $$;
select pg_temp.claim('public.rz378', 'localtime');
select pg_temp.claim('public.ru378', 'UTC');

select ok(exists (select 1 from pg_timezone_names where name = 'localtime')
          and pgpm._canonical_tz('localtime') is null,
  'LIVENESS: this server lists localtime, and this install refuses to record it (#1086)');
select is((select partition_tz || ':' || coalesce(owner_pid::text, 'none') from pgpm.transmute_inflight
            where parent_table = 'public.rz378'::regclass), 'localtime:none',
  'LIVENESS: rz378 carries an abandoned claim recorded in localtime, as a pre-#1086 install left it');

select throws_like(
  $$ call pgpm.transmute('public.rz378', 'ts', interval '1 day', p_obtain => 1, p_paused => true) $$,
  'pg_partition_magician: cannot resume the transmute of rz378: the bound [%) an earlier attempt recorded was computed in the zone localtime, which is not a zone pgpm can record%transmute_abort(rz378)%',
  'the resume refuses the claim''s localtime zone, naming transmute_abort, rather than registering a grid that follows the host');
select is(
  (select partition_tz || ':' || coalesce(owner_pid::text, 'none') from pgpm.transmute_inflight
    where parent_table = 'public.rz378'::regclass)
  || '/' || (select count(*) from pgpm.config where parent_table = 'public.rz378'::regclass)
  || '/' || (select relkind::text from pg_class where oid = 'public.rz378'::regclass),
  'localtime:none/0/r', 'invariant: the claim is left as it was, and rz378 is still an unregistered plain table');

call pgpm.transmute('public.ru378', 'ts', interval '1 day', p_obtain => 1, p_paused => true);
select is((select partition_tz from pgpm.config where parent_table = 'public.ru378'::regclass)
          || '/' || (select count(*) from pgpm.log where parent_table = 'public.ru378'::regclass and action = 'transmute_resume'),
  'UTC/1', 'LIVENESS: the same hand-built claim recorded in UTC resumes and registers UTC');

-- the remedy the refusal names
select pgpm.transmute_abort('public.rz378');
call pgpm.transmute('public.rz378', 'ts', interval '1 day', p_obtain => 1, p_paused => true);
select is((select partition_tz from pgpm.config where parent_table = 'public.rz378'::regclass), 'UTC',
  'LIVENESS: after transmute_abort, a re-run from a UTC session converts rz378 on the UTC grid');
select is((select string_agg(id::text, ',' order by id) from public.rz378 where id in (1, 20)), '1,20',
  'LIVENESS: rz378 holds its rows through the parent');
select is((select count(*)::int from pgpm.config where partition_tz in ('localtime', 'posixrules', 'Factory')), 0,
  'no table is registered in a zone pgpm does not record');

select * from finish();
