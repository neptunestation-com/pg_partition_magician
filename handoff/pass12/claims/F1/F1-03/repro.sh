#!/usr/bin/env bash
# F1-03: docs/reference.md's untransmute entry tells the operator to finish an interrupted concurrent detach
# with `ALTER TABLE <table> DETACH PARTITION <partition>`. Against a partition pending detach PostgreSQL
# refuses that statement (it is already pending; only DETACH PARTITION ... FINALIZE completes it), so the
# documented remedy fails and leaves the partition pending. The statement is read from $TREE, not pasted.
set -u
fail=0

# the documented remedy, read from the reference as written
stmt=$(tr '\n' ' ' < "$TREE/docs/reference.md" \
       | sed -n 's/.*finish an interrupted one with `\([^`]*\)`.*/\1/p' | head -1)
if [ -n "$stmt" ]; then
  echo "ok - fixture: the reference's remedy for an interrupted detach reads: $stmt"
else
  echo "not ok - fixture: could not find the untransmute entry's remedy for an interrupted detach"
  exit 1
fi

# a managed table with a forward partition left pending a concurrent detach (its detacher killed in the wait)
$PSQL -q -f - >/dev/null 2>&1 <<'SQL'
create extension if not exists dblink;
create table public.f1rd (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.f1rd select i, now() - i * interval '1 hour' from generate_series(1, 20) i;
call pgpm.transmute('public.f1rd', 'ts', interval '1 day', p_obtain => 3);
select child_name as fwd from pgpm.part
 where parent_table = 'public.f1rd'::regclass
   and child_oid <> (select monolith_oid from pgpm.config where parent_table = 'public.f1rd'::regclass)
 order by lo::timestamptz desc limit 1 \gset
create table public.f1rd_fwd as select :'fwd'::text as name;
select dblink_connect('f1x', 'dbname=' || current_database() || ' application_name=f1rd_reader');
select dblink_connect('f1d', 'dbname=' || current_database() || ' application_name=f1rd_detach');
select dblink_exec('f1x', 'begin isolation level repeatable read');
select * from dblink('f1x', 'select count(*) from public.f1rd') as t(n bigint);
select dblink_send_query('f1d', format('alter table public.f1rd detach partition public.%I concurrently', :'fwd'));
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where datname = current_database()
                       and application_name = 'f1rd_detach' and wait_event = 'virtualxid');
    perform pg_sleep(0.05);
  end loop;
end $$;
select pg_terminate_backend(pid) from pg_stat_activity
 where datname = current_database() and application_name = 'f1rd_detach';
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when not exists (select 1 from pg_stat_activity where datname = current_database()
                           and application_name = 'f1rd_detach');
    perform pg_sleep(0.05);
  end loop;
end $$;
select dblink_exec('f1x', 'commit');
select dblink_disconnect('f1x');
select dblink_disconnect('f1d');
SQL

fwd=$($PSQL -tAc "select name from public.f1rd_fwd")
pending=$($PSQL -tAc "select count(*) from pg_inherits where inhparent = 'public.f1rd'::regclass and inhdetachpending and inhrelid = to_regclass('public.' || quote_ident('$fwd'))")
if [ "$pending" = "1" ]; then
  echo "ok - LIVENESS: public.$fwd is pending a concurrent detach under public.f1rd, its detacher gone"
else
  echo "not ok - LIVENESS: public.$fwd is pending a concurrent detach under public.f1rd (got $pending)"
  exit 1
fi

# the operator types the documented remedy with the table and the partition filled in
run=${stmt//<table>/public.f1rd}
run=${run//<partition>/public.\"$fwd\"}
out=$($PSQL -tAc "$run" 2>&1); rc=$?
echo "# ran: $run -> rc=$rc $out"
if [ $rc -eq 0 ]; then
  echo "ok - the documented remedy runs"
else
  echo "not ok - the documented remedy runs (it fails: $out)"; fail=1
fi
still=$($PSQL -tAc "select count(*) from pg_inherits where inhparent = 'public.f1rd'::regclass and inhdetachpending")
if [ "$still" = "0" ]; then
  echo "ok - and leaves no partition of public.f1rd pending detach"
else
  echo "not ok - and leaves no partition of public.f1rd pending detach (still pending: $still)"; fail=1
fi
exit $fail
