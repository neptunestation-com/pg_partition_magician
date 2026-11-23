-- untransmute() is refused when a retirement of the table has a detach a pgpm_detach job this role cannot see may hold (#1489).
--
-- THE BUG. untransmute deletes every pgpm.part row of the parent, a retiring one included, and returns to idle each
-- pgpm_detach job still holding one of their detaches (#954). pg_cron keeps one job per role that ran
-- pgpm.schedule() and shows a non-superuser only its own (row security, username = current_user), so the table's
-- non-superuser owner reversing a table whose retirement the administrator's tick had dispatched idled only its own
-- job. The administrator's stayed armed with the detach, re-running it on every run, and nothing recorded the
-- retirement any more.
--
-- THE CONTRACT (_detach_job_vouched decides who can vouch, as for forget_missing).
--   PART A  the owner's untransmute of a table whose retirement the administrator dispatched is refused (P0001, the
--           message names the partition, the role and who to run it as), and nothing changed: the table is still
--           partitioned with its rows, its config, part rows and mark are as they were, and both jobs hold what they
--           held. A superuser's untransmute then reverses it and idles the administrator's job.
--   PART B  a mark this release made and never dispatched (the administrator's retire() found no job) is held by no
--           job: the owner's untransmute goes through.
--   PART C  the role whose own job alone holds the detach (retiring_by) can vouch: the owner's untransmute of its own
--           dispatch goes through, idles its job and leaves the administrator's, which holds another table's detach.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for cron.job
-- (with pg_cron's username column and its row-security policy) and cron.alter_job, as tests/397 does.
-- bench/untransmute_vouches_detach.sh runs it against the mutants; bench/untransmute_vouch_race.sh guards the second
-- asking under the lock, which needs a concurrent session.
--
-- ASYMMETRIC FIXTURES. Each part's table holds different payloads (A a b c, B k l, C u v w x), and the two jobs hold
-- different commands, so an assertion aimed at the wrong table or job cannot pass.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(35);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text,
                       username text not null default current_user);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pgpm_test399_owner') then
    create role pgpm_test399_owner nosuperuser nobypassrls;
  end if;
end $$;
grant usage on schema pgpm to pgpm_test399_owner;
grant all on all tables in schema pgpm to pgpm_test399_owner;
grant all on all sequences in schema pgpm to pgpm_test399_owner;
grant create, usage on schema public to pgpm_test399_owner;
grant usage on schema cron to pgpm_test399_owner;
grant select, update on cron.job to pgpm_test399_owner;
-- the owner's job and the administrator's; pg_cron's row security: a role sees only the jobs it scheduled
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test399_owner'),
                            (2, 'pgpm_detach', current_database(), 'select 1', 'postgres');
create policy pgpm_test399_own on cron.job using (username = current_user);
alter table cron.job enable row level security;
create function pg_temp.cmd(p_job bigint) returns text language sql as $$ select command from cron.job where jobid = p_job $$;
create function pg_temp.mark(p_child text) returns text language sql as $$
  select coalesce((select format('%s %s %s', retiring_at is not null, retiring_by, detach_dispatched_oid is not null)
                     from pgpm.part where child_name = p_child), 'no row')
$$;
create function pg_temp.payloads(p_rel regclass) returns text[] language plpgsql as $$
declare v text[];
begin
  execute format('select array_agg(payload order by ts) from %s', p_rel) into v;
  return v;
end $$;
-- the parent's pgpm state, whole: its config row and every part row with its mark, for "nothing changed"
create function pg_temp.state(p_parent regclass) returns text language sql as $$
  select format('%s | %s', (select row(c.*)::text from pgpm.config c where c.parent_table = p_parent),
                (select string_agg(row(p.*)::text, ' ; ' order by p.child_name) from pgpm.part p where p.parent_table = p_parent))
$$;
-- a 'time' table on 1-second cells with retain 0 and a preserved incoming key, owned by the owner: the first forward
-- cell lies past retention while every row still lives in the monolith, so untransmute's gate passes (tests/383)
create function pg_temp.mk(p_t text, p_payloads text[]) returns void language plpgsql as $$
declare i int; r regclass;
begin
  execute format('create table public.%I (ts timestamptz primary key, payload text)', p_t);
  for i in 1 .. array_length(p_payloads, 1) loop
    execute format('insert into public.%I values (now() - make_interval(secs => %s), %L)', p_t, 10 - i, p_payloads[i]);
  end loop;
  execute format('create table public.%I (id bigint primary key, t_ts timestamptz references public.%I (ts))', p_t || '_ref', p_t);
  execute format('insert into public.%I select 1, min(ts) from public.%I', p_t || '_ref', p_t);
end $$;
create function pg_temp.to_owner(p_parent regclass) returns void language plpgsql as $$
declare r regclass;
begin
  for r in select p_parent union all select c.conrelid::regclass from pg_constraint c where c.confrelid = p_parent and c.contype = 'f'
           union all select inhrelid::regclass from pg_inherits where inhparent = p_parent loop
    execute format('alter table %s owner to pgpm_test399_owner', r);
  end loop;
end $$;
select ok(not rolsuper and not rolbypassrls, 'LIVENESS: the owner is neither a superuser nor exempt from row security')
  from pg_roles where rolname = 'pgpm_test399_owner';

-- ==================== (A) the administrator's dispatch: the owner's untransmute is refused ====================
select pg_temp.mk('ta399', array['a', 'b', 'c']);
call pgpm.transmute('public.ta399', 'ts', '1 second'::interval, p_obtain => 4, p_retain => '0 seconds'::interval,
                    p_paused => true, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('public.ta399');
select pg_temp.to_owner('public.ta399');
select p.child_name as a_fwd from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table
 where p.parent_table = 'public.ta399'::regclass and p.child_oid is distinct from c.monolith_oid
 order by p.lo limit 1 \gset
select pg_sleep(greatest(0, extract(epoch from hi::timestamptz - clock_timestamp()) + 1.2)) from pgpm.part where child_name = :'a_fwd';
select is(pgpm.retire('public.ta399', :'a_fwd'), false, 'LIVENESS: (A) the administrator''s retire() of the forward cell takes the referenced path');
-- the owner's job has since taken another table's detach
update cron.job set command = 'alter table public.elsewhere399 detach partition public.elsewhere399_p1 concurrently' where jobid = 1;
select is(pg_temp.cmd(2), format('alter table public.ta399 detach partition public.%I concurrently', :'a_fwd'),
  'LIVENESS: (A) the administrator''s job holds the forward cell''s detach');
select is(pg_temp.mark(:'a_fwd'), 't postgres t', 'LIVENESS: (A) the mark records the administrator''s dispatch');
select pg_temp.state('public.ta399') as a_state \gset
set role pgpm_test399_owner;
select set_config('t399.a_seen', (select string_agg(format('%s:%s', username, command), ',') from cron.job), false);
do $$
begin
  perform pgpm.untransmute('public.ta399');
  perform set_config('t399.a', 'not refused', false);
exception when others then
  perform set_config('t399.a', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select is(current_setting('t399.a_seen'),
  'pgpm_test399_owner:alter table public.elsewhere399 detach partition public.elsewhere399_p1 concurrently',
  'LIVENESS: (A) the owner sees one job, its own, holding another table''s detach');
select ok(current_setting('t399.a') ~ ('^P0001 pg_partition_magician: untransmute refused, nothing changed: (public\.)?ta399 is retiring '
            || :'a_fwd' || ', whose detach pgpm dispatched to a pgpm_detach cron job, and role pgpm_test399_owner cannot read every job that may hold it '
            || '.*Run select pgpm\.untransmute\(''(public\.)?ta399''\); as role postgres or a superuser\.$'),
  'A: the owner''s untransmute() is refused, naming the partition, the role and the role to run it as');
select is((select relkind::text from pg_class where oid = 'public.ta399'::regclass), 'p', 'A: the table is still partitioned');
select is(pg_temp.payloads('public.ta399'), array['a', 'b', 'c'], 'A: with rows a, b, c');
select is(pg_temp.state('public.ta399'), :'a_state', 'A: its config and part rows are as they were');
select is(pg_temp.mark(:'a_fwd'), 't postgres t', 'A: the forward cell keeps the mark, the dispatch and its role');
select is(pg_temp.cmd(2), format('alter table public.ta399 detach partition public.%I concurrently', :'a_fwd'),
  'A: the administrator''s job still holds the detach');
select is(pg_temp.cmd(1), 'alter table public.elsewhere399 detach partition public.elsewhere399_p1 concurrently',
  'A: and the owner''s job keeps the other table''s detach');
select ok(not exists (select 1 from pgpm.log where action = 'untransmute'), 'A: and no untransmute is logged');
select lives_ok($$select pgpm.untransmute('public.ta399')$$, 'A: a superuser''s untransmute() goes through');
select is((select relkind::text from pg_class where oid = 'public.ta399'::regclass), 'r', 'A: the restored table is a plain table');
select is(pg_temp.payloads('public.ta399'), array['a', 'b', 'c'], 'A: holding rows a, b, c');
select is(pg_temp.cmd(2), 'select 1', 'A: and the administrator''s job is idle');
select is(pg_temp.cmd(1), 'alter table public.elsewhere399 detach partition public.elsewhere399_p1 concurrently',
  'A: the owner''s job, which held another table''s detach, keeps it (#954''s conditional disarm)');

-- ==================== (B) a mark never dispatched: no job holds it, the owner goes through ====================
update cron.job set command = 'alter table public.elsewhere399 detach partition public.elsewhere399_p2 concurrently' where jobid = 2;
select pg_temp.mk('tb399', array['k', 'l']);
call pgpm.transmute('public.tb399', 'ts', '1 second'::interval, p_obtain => 4, p_retain => '0 seconds'::interval,
                    p_paused => true, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('public.tb399');
select pg_temp.to_owner('public.tb399');
select p.child_name as b_fwd from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table
 where p.parent_table = 'public.tb399'::regclass and p.child_oid is distinct from c.monolith_oid
 order by p.lo limit 1 \gset
select pg_sleep(greatest(0, extract(epoch from hi::timestamptz - clock_timestamp()) + 1.2)) from pgpm.part where child_name = :'b_fwd';
-- no pgpm_detach job while the administrator's retire() runs (as before pgpm.schedule()): the mark is made, nothing armed
update cron.job set jobname = 'pgpm_detach_unscheduled';
select is(pgpm.retire('public.tb399', :'b_fwd'), false, 'LIVENESS: (B) the administrator''s retire() of the forward cell takes the referenced path');
update cron.job set jobname = 'pgpm_detach';
select is(pg_temp.mark(:'b_fwd'), 't postgres f', 'LIVENESS: (B) the mark is the administrator''s, and records no dispatch');
select is((select action from pgpm.log where parent_table = 'public.tb399'::regclass order by id desc limit 1), 'fail_retain_detach',
  'LIVENESS: (B) the dispatch found no job');
set role pgpm_test399_owner;
do $$
begin
  perform pgpm.untransmute('public.tb399');
  perform set_config('t399.b', 'not refused', false);
exception when others then
  perform set_config('t399.b', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select is(current_setting('t399.b'), 'not refused', 'B: the owner''s untransmute() goes through');
select is((select relkind::text from pg_class where oid = 'public.tb399'::regclass), 'r', 'B: the restored table is a plain table');
select is(pg_temp.payloads('public.tb399'), array['k', 'l'], 'B: holding rows k, l');
select is(pg_temp.mark(:'b_fwd'), 'no row', 'B: and the retirement is forgotten with the rest');
select is(pg_temp.cmd(2), 'alter table public.elsewhere399 detach partition public.elsewhere399_p2 concurrently',
  'B: the administrator''s job, holding another table''s detach, is as it was');
-- a refused B leaves its retirement in flight, which would take C's detach slot: reversed here, so C stands alone
do $$
begin
  if exists (select 1 from pgpm.config where parent_table = 'public.tb399'::regclass) then
    perform pgpm.untransmute('public.tb399');
  end if;
end $$;

-- ==================== (C) the owner's own dispatch: it can vouch, and goes through ====================
update cron.job set command = 'select 1' where jobid = 1;
update cron.job set command = 'alter table public.elsewhere399 detach partition public.elsewhere399_p3 concurrently' where jobid = 2;
select pg_temp.mk('tc399', array['u', 'v', 'w', 'x']);
call pgpm.transmute('public.tc399', 'ts', '1 second'::interval, p_obtain => 4, p_retain => '0 seconds'::interval,
                    p_paused => true, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('public.tc399');
select pg_temp.to_owner('public.tc399');
select p.child_name as c_fwd from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table
 where p.parent_table = 'public.tc399'::regclass and p.child_oid is distinct from c.monolith_oid
 order by p.lo limit 1 \gset
select pg_sleep(greatest(0, extract(epoch from hi::timestamptz - clock_timestamp()) + 1.2)) from pgpm.part where child_name = :'c_fwd';
set role pgpm_test399_owner;
select set_config('t399.c1', pgpm.retire('public.tc399', :'c_fwd')::text, false);
reset role;
select is(current_setting('t399.c1') || ' ' || pg_temp.cmd(1),
  format('false alter table public.tc399 detach partition public.%I concurrently', :'c_fwd'),
  'LIVENESS: (C) the owner''s retire() dispatches the detach through its own job');
select is(pg_temp.mark(:'c_fwd'), 't pgpm_test399_owner t', 'LIVENESS: (C) the mark records the owner''s dispatch');
set role pgpm_test399_owner;
do $$
begin
  perform pgpm.untransmute('public.tc399');
  perform set_config('t399.c', 'not refused', false);
exception when others then
  perform set_config('t399.c', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select is(current_setting('t399.c'), 'not refused', 'C: the owner''s untransmute() goes through');
select is((select relkind::text from pg_class where oid = 'public.tc399'::regclass), 'r', 'C: the restored table is a plain table');
select is(pg_temp.payloads('public.tc399'), array['u', 'v', 'w', 'x'], 'C: holding rows u, v, w, x');
select is(pg_temp.mark(:'c_fwd'), 'no row', 'C: and the retirement is forgotten with the rest');
select is(pg_temp.cmd(1), 'select 1', 'C: its own job is idle');
select is(pg_temp.cmd(2), 'alter table public.elsewhere399 detach partition public.elsewhere399_p3 concurrently',
  'C: and the administrator''s job, which never held this detach, is as it was');
select is((select array_agg(parent_table order by id) from pgpm.log where action = 'untransmute'),
  array['public.ta399'::regclass, 'public.tb399'::regclass, 'public.tc399'::regclass],
  'LIVENESS: each table''s reverse was logged once, A''s by the superuser''s call');

select * from finish();
