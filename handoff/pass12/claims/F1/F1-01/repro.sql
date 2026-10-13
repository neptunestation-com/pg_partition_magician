-- F1-01: untransmute never asks _refuse_detach_pending, so a partition left pending a concurrent detach
-- (an operator's DETACH ... CONCURRENTLY whose session died in its wait phase) is outside the gate's view
-- and inside the parent's DROP: untransmute succeeds and the pending partition's rows are destroyed.
-- Expected (#1157, docs/reference.md untransmute): refuse, naming the partition and FINALIZE, change nothing.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(6);

create function pg_temp.f1_ids(p_name text) returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  if to_regclass(format('public.%I', p_name)) is null then return null; end if;
  execute format('select array_agg(id order by id) from public.%I', p_name) into v;
  return v;
end $f$;

create table public.f1pd (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.f1pd select i, now() - i * interval '1 hour' from generate_series(1, 20) i;
call pgpm.transmute('public.f1pd', 'ts', interval '1 day', p_obtain => 3);

select child_name as fwd, lo as fwd_lo from pgpm.part
 where parent_table = 'public.f1pd'::regclass
   and child_oid <> (select monolith_oid from pgpm.config where parent_table = 'public.f1pd'::regclass)
 order by lo::timestamptz desc limit 1 \gset
-- two rows written into the newest forward partition (2 there, 20 in the monolith)
insert into public.f1pd values (1001, :'fwd_lo'::timestamptz + interval '1 hour'),
                               (1002, :'fwd_lo'::timestamptz + interval '2 hours');

-- an operator's DETACH ... CONCURRENTLY of it, parked in its wait phase on a reader's vxid, then killed
select dblink_connect('f1x', 'dbname=' || current_database() || ' application_name=f1pd_reader');
select dblink_connect('f1d', 'dbname=' || current_database() || ' application_name=f1pd_detach');
select dblink_exec('f1x', 'begin isolation level repeatable read');
select * from dblink('f1x', 'select count(*) from public.f1pd') as t(n bigint);
select dblink_send_query('f1d', format('alter table public.f1pd detach partition public.%I concurrently', :'fwd'));
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity
                       where datname = current_database() and application_name = 'f1pd_detach'
                         and wait_event = 'virtualxid');
    perform pg_sleep(0.05);
  end loop;
end $$;
select pg_terminate_backend(pid) from pg_stat_activity
 where datname = current_database() and application_name = 'f1pd_detach';
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when not exists (select 1 from pg_stat_activity
                           where datname = current_database() and application_name = 'f1pd_detach');
    perform pg_sleep(0.05);
  end loop;
end $$;
select dblink_exec('f1x', 'commit');
select dblink_disconnect('f1x');
select dblink_disconnect('f1d');

select ok(exists (select 1 from pg_inherits where inhparent = 'public.f1pd'::regclass
                    and inhrelid = to_regclass(format('public.%I', :'fwd')) and inhdetachpending),
          'LIVENESS: the forward partition is pending detach under f1pd (its detacher killed in the wait)');
select is(pg_temp.f1_ids(:'fwd'), array[1001, 1002]::bigint[],
          'LIVENESS: the pending partition holds rows 1001 and 1002');
select is((select count(*)::int from public.f1pd where id in (1001, 1002)), 0,
          'LIVENESS: which are invisible through the parent, all the outside-rows gate reads');

-- the reverse, as an operator would call it; its outcome recorded rather than allowed to stop the file
create function pg_temp.f1_untransmute() returns text language plpgsql as $f$
begin
  perform pgpm.untransmute('public.f1pd');
  return 'returned';
exception when others then
  return 'raised: ' || sqlerrm;
end $f$;
select pg_temp.f1_untransmute() as u \gset

select ok(:'u' like 'raised:%pending a concurrent detach%',
          'untransmute refuses while a partition is pending a concurrent detach: ' || :'u');
select is(pg_temp.f1_ids(:'fwd'), array[1001, 1002]::bigint[],
          'rows 1001 and 1002 still exist (in the pending partition) after the untransmute call');
select is((select count(*)::int from pgpm.log where action = 'untransmute'), 0,
          'and no untransmute was logged over rows it destroyed');
select * from finish();
