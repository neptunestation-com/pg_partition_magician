#!/usr/bin/env bash
# untransmute's refusal of a retirement it cannot vouch for is asked again under its ACCESS EXCLUSIVE (issue #1489).
#
# THE DEFECT. untransmute deletes every pgpm.part row of the parent and returns to idle only the pgpm_detach jobs the
# caller sees (#954); pg_cron shows a non-superuser only its own. So it refuses, before anything is read for the
# reverse, a retirement whose detach another role's job may hold (_refuse_unvouched_retirements, tests/399). Asked
# only there, a retirement the administrator's tick marks and dispatches while the owner's untransmute is past that
# question and waiting for its ACCESS EXCLUSIVE is read by nothing: the reverse forgets it and the administrator's job
# stays armed. retire() marks under SHARE UPDATE EXCLUSIVE on the partition, which untransmute's ACCESS EXCLUSIVE on
# the parent and its partitions waits out, so the second asking, under that lock, reads the committed mark.
#
# WHY A SHELL HARNESS. The contract needs two sessions: the administrator's retire() held open, uncommitted, while the
# owner's untransmute reaches its lock wait. The window is held STRUCTURALLY: the administrator's transaction stays
# open until this script, having seen the owner wait on a lock, lets it commit. Every observation is its own docker
# exec, so its own transaction, and holds nothing either session needs. pg_cron exists only in `postgres` on the
# harness images, so the database brings a stand-in for cron.job with pg_cron's username column and its row security,
# as tests/399 does.
#
# WITNESSES (a failure of only these says the race was never set up, not that the code is right or wrong):
#   LIVENESS: the administrator's retire() dispatched the detach and has not committed (its mark not yet visible)
#   LIVENESS: the owner's untransmute waited on a lock while that transaction was still open
#   LIVENESS: the administrator's retire() committed without an error
# THE CONTRACT:
#   the owner's untransmute was refused (the message pinned), and the table is still partitioned with rows a, b, c
#   the forward cell keeps its mark and the administrator's job still holds the detach
#   a superuser's untransmute then reverses it and idles the administrator's job
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   untransmute_unvouched_under_lock -- the second asking removed
#
# Usage: untransmute_vouch_race.sh <container> <db> [install.sql]
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
OWNER=pgpm_race1489_owner
fail=0
work=$(mktemp -d)
# the held transaction is let go and the sessions waited for whatever way this script ends
trap 'touch "$work/go"; wait 2>/dev/null; rm -rf "$work"' EXIT

q() { docker exec "$C" psql -U postgres "$@"; }
v() { docker exec -e PGOPTIONS=-cclient_min_messages=warning "$C" psql -U postgres -d "$DB" -qtAX -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-62s %s\n' "$1" "$2"
  else printf 'FAIL  %-62s %s (want %s)\n' "$1" "$2" "$3"; fail=1; fi
}

q -q -c "drop database if exists $DB" >/dev/null 2>&1
if ! q -v ON_ERROR_STOP=1 -q -c "create database $DB" >/dev/null 2>&1; then
  printf 'FAIL  %-62s %s\n' "fixture: the database was created" "$DB"; exit 1
fi
# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-62s %s\n' "the module under test installed" "$INSTALL"; exit 1
fi

if ! docker exec -i "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qX >/dev/null 2>"$work/setup.err" <<SQL
set client_min_messages = warning;
create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text,
                       username text not null default current_user);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as \$f\$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
\$f\$;
do \$d\$
begin
  if not exists (select 1 from pg_roles where rolname = '$OWNER') then
    create role $OWNER nosuperuser nobypassrls;
  end if;
end \$d\$;
grant usage on schema pgpm to $OWNER;
grant all on all tables in schema pgpm to $OWNER;
grant all on all sequences in schema pgpm to $OWNER;
grant create, usage on schema public to $OWNER;
grant usage on schema cron to $OWNER;
grant select, update on cron.job to $OWNER;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1', '$OWNER'),
                            (2, 'pgpm_detach', current_database(), 'select 1', 'postgres');
create policy race1489_own on cron.job using (username = current_user);
alter table cron.job enable row level security;
-- tests/383's table: 1-second cells, retain 0, a preserved incoming key, every row in the monolith
create table public.rr (ts timestamptz primary key, payload text);
insert into public.rr values (now() - interval '9 seconds', 'a'), (now() - interval '8 seconds', 'b'),
                             (now() - interval '7 seconds', 'c');
create table public.rr_ref (id bigint primary key, t_ts timestamptz references public.rr (ts));
insert into public.rr_ref select 1, min(ts) from public.rr;
call pgpm.transmute('public.rr', 'ts', '1 second'::interval, p_obtain => 4, p_retain => '0 seconds'::interval,
                    p_paused => true, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('public.rr');
do \$d\$
declare r regclass;
begin
  for r in select 'public.rr'::regclass union all select 'public.rr_ref'::regclass
           union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rr'::regclass loop
    execute format('alter table %s owner to $OWNER', r);
  end loop;
end \$d\$;
SQL
then
  printf 'FAIL  %-62s %s\n' "fixture: the table, the jobs and the owner were set up" "no"
  sed 's/^/      /' "$work/setup.err" | head -5; exit 1
fi
fwd=$(v "select p.child_name from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table
          where p.parent_table = 'public.rr'::regclass and p.child_oid is distinct from c.monolith_oid order by p.lo limit 1")
v "select pg_sleep(greatest(0, extract(epoch from hi::timestamptz - clock_timestamp()) + 1.2)) from pgpm.part where child_name = '$fwd'" >/dev/null
mark() { v "select coalesce((select format('%s %s %s', retiring_at is not null, retiring_by, detach_dispatched_oid is not null)
                                from pgpm.part where child_name = '$fwd'), 'no row')"; }
detach="alter table public.rr detach partition public.$fwd concurrently"

# --- session A: the administrator's tick, its retire() held open --------------------------------------------
( printf 'begin;\nselect pgpm.retire(%s, %s);\n' "'public.rr'" "'$fwd'"
  for _ in $(seq 1 600); do [ -e "$work/go" ] && break; sleep 0.1; done
  printf 'commit;\n' ) \
  | docker exec -i -e PGAPPNAME=race1489_admin "$C" psql -U postgres -d "$DB" -qtAX -v ON_ERROR_STOP=1 >"$work/admin.out" 2>&1 &

armed=""
for _ in $(seq 1 200); do
  if [ "$(v "select count(*) from pg_stat_activity where application_name = 'race1489_admin' and state = 'idle in transaction'")" = 1 ] \
     && grep -qx f "$work/admin.out"; then armed=1; break; fi
  sleep 0.1
done
check "LIVENESS: the administrator's retire() dispatched, uncommitted" "${armed:-never} $(mark)" "1 f  f"

# --- session B: the owner's untransmute, past its first asking and into its lock wait ------------------------
docker exec -e PGAPPNAME=race1489_owner "$C" psql -U postgres -d "$DB" -qtAX \
  -c "set role $OWNER" -c "select pgpm.untransmute('public.rr')" >"$work/owner.out" 2>&1 &
owner_pid=$!
waited=""
for _ in $(seq 1 200); do
  r=$(v "select (select count(*) from pg_stat_activity where application_name = 'race1489_owner' and wait_event_type = 'Lock')
             || '/' || (select count(*) from pg_stat_activity where application_name = 'race1489_admin' and state = 'idle in transaction')")
  if [ "$r" = "1/1" ]; then waited=1; break; fi
  sleep 0.1
done
check "LIVENESS: the owner's untransmute waited on a lock, A still open" "${waited:-never}" "1"

touch "$work/go"
for _ in $(seq 1 300); do kill -0 "$owner_pid" 2>/dev/null || break; sleep 0.1; done
wait

check "LIVENESS: the administrator's retire() committed, no error" "$(grep -c ERROR "$work/admin.out")/$(grep -cx f "$work/admin.out")" "0/1"
refused=$(grep -c "^ERROR:  pg_partition_magician: untransmute refused, nothing changed: rr is retiring $fwd, whose detach pgpm dispatched to a pgpm_detach cron job, and role $OWNER cannot read every job that may hold it .*Run select pgpm.untransmute('rr'); as a superuser\.$" "$work/owner.out")
check "the owner's untransmute was refused under the lock" "$refused" "1"
[ "$refused" = 1 ] || sed 's/^/      /' "$work/owner.out" | head -5
check "the table is still partitioned, with rows a, b, c" \
  "$(v "select relkind from pg_class where oid = 'public.rr'::regclass")/$(v "select string_agg(payload, ',' order by ts) from public.rr")" "p/a,b,c"
check "the forward cell keeps the administrator's mark" "$(mark)" "t postgres t"
check "the administrator's job still holds the detach" "$(v "select command from cron.job where jobid = 2")" "$detach"
check "a superuser's untransmute then reverses it" "$(v "select pgpm.untransmute('public.rr')")" "rr"
check "and idles the administrator's job" "$(v "select command from cron.job where jobid = 2")" "select 1"

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
