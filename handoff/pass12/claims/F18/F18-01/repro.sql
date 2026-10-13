-- F18-01: untransmute does not refuse while a partition is pending a concurrent detach.
-- pgpm._refuse_detach_pending exists (install.sql ~12085) and untransmute's own comments and
-- CHANGELOG #1157 say it is asked twice, but nothing calls it: untransmute's gate reads only through the
-- parent, where the pending partition's rows are invisible, so the reverse goes through and the DROP of
-- the parent takes the pending partition and its rows with it, logging a plain 'untransmute'.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(10);

create function pg_temp.f18_ids(p_name text) returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  if to_regclass(format('public.%I', p_name)) is null then return null; end if;
  execute format('select array_agg(id order by id) from public.%I', p_name) into v;
  return v;
end $f$;

create table public.f18a (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.f18a select i, now() - i * interval '1 hour' from generate_series(1, 20) i;
call pgpm.transmute('public.f18a', 'ts', interval '1 day', p_obtain => 3);

-- the newest forward partition, with two rows of its own (asymmetric against the monolith's twenty)
select child_name as fwd, lo as fwd_lo from pgpm.part
 where parent_table = 'public.f18a'::regclass
   and child_oid <> (select monolith_oid from pgpm.config where parent_table = 'public.f18a'::regclass)
 order by lo::timestamptz desc limit 1 \gset
insert into public.f18a values (1001, :'fwd_lo'::timestamptz + interval '1 hour'),
                               (1002, :'fwd_lo'::timestamptz + interval '2 hours');

-- an operator's DETACH ... CONCURRENTLY parked in its wait phase behind a repeatable-read reader, then killed
select dblink_connect('f18x', 'dbname=' || current_database() || ' application_name=f18_reader');
select dblink_connect('f18d', 'dbname=' || current_database() || ' application_name=f18_detach');
select dblink_exec('f18x', 'begin isolation level repeatable read');
select * from dblink('f18x', 'select count(*) from public.f18a') as t(n bigint);
select dblink_send_query('f18d', format('alter table public.f18a detach partition public.%I concurrently', :'fwd'));
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity
                       where datname = current_database() and application_name = 'f18_detach'
                         and wait_event = 'virtualxid');
    perform pg_sleep(0.05);
  end loop;
end $$;
select is((select count(*)::int from pg_stat_activity
            where datname = current_database() and application_name = 'f18_detach' and wait_event = 'virtualxid'),
          1, 'LIVENESS: the detach reached its wait phase (its pending flag is committed)');
select pg_terminate_backend(pid) from pg_stat_activity
 where datname = current_database() and application_name = 'f18_detach';
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when not exists (select 1 from pg_stat_activity
                           where datname = current_database() and application_name = 'f18_detach');
    perform pg_sleep(0.05);
  end loop;
end $$;
select dblink_exec('f18x', 'commit');
select dblink_disconnect('f18x');
select dblink_disconnect('f18d');

select ok(exists (select 1 from pg_inherits where inhparent = 'public.f18a'::regclass
                    and inhrelid = to_regclass(format('public.%I', :'fwd')) and inhdetachpending),
          'LIVENESS: the forward partition is pending detach under f18a');
select is((select count(*)::int from pg_stat_activity
            where datname = current_database() and application_name = 'f18_detach'),
          0, 'LIVENESS: its detacher is gone: an abandoned detach, not a live one');
select is(pg_temp.f18_ids(:'fwd'), array[1001, 1002]::bigint[],
          'LIVENESS: the pending partition holds rows 1001 and 1002');
select is((select count(*)::int from public.f18a where id in (1001, 1002)), 0,
          'LIVENESS: which the parent no longer shows, so the outside-rows gate cannot see them');

-- the defect: untransmute must refuse, naming the pending partition and the FINALIZE remedy
select throws_like(
  $$ select pgpm.untransmute('public.f18a') $$,
  '%' || :'fwd' || '%pending a concurrent detach%DETACH PARTITION%FINALIZE%',
  'untransmute refuses while a partition is pending a concurrent detach');
select is(pg_temp.f18_ids(:'fwd'), array[1001, 1002]::bigint[],
          'rows 1001 and 1002 are still in the pending partition (the relation still exists)');
select is((select relkind::text from pg_class where oid = to_regclass('public.f18a')), 'p',
          'f18a is still the partitioned table');
select is((select count(*)::int from pgpm.config where parent_table = to_regclass('public.f18a')), 1,
          'pgpm still manages it');
select is((select count(*)::int from pgpm.log
            where parent_table = to_regclass('public.f18a') and action = 'untransmute'),
          0, 'and no untransmute was logged');
select * from finish();
