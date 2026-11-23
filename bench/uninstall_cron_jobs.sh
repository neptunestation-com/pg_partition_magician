#!/usr/bin/env bash
# uninstall_cron_jobs.sh <container> <db> [uninstall.sql]
#
# Run pgpm_core/uninstall.sql against REAL pg_cron with two roles holding pgpm jobs, so bench/discriminate.sh can show
# the guard catches the defects its mutations put back (issues #1500 and #1496). pg_cron keeps a job per role that ran
# pgpm.schedule() and shows a role that is not a superuser only its own.
#   #1500: the script unscheduled by NAME, and cron.unschedule(name) looks the name up among the caller's own jobs, so a
#          superuser reaching a second role's 'pgpm' raised "could not find valid entry for job" and rolled back.
#   #1496: the table owner's uninstall (no superuser, as the README allows) removed pgpm while the administrator's
#          pgpm_detach job held a dispatched detach, left that job armed, and its next run took the partition out of
#          the table, nothing logged.
#
# pg_cron can only be created in the database cron.database_name names (postgres on the test images), where the perf
# track installs pgpm for every guard, so this guard brings up its OWN server from the container's image and runs there;
# <db> names it. The scripts under test are read out of <container> (the mutant's path is a path inside it).
#
# Parts (each a fresh install by the non-superuser owner, which owns schema pgpm and the table):
#   A  the owner and the superuser both scheduled; the superuser's tick dispatches a referenced partition's detach,
#      held uncommitted while the owner's uninstall starts. The uninstall waits for it at its vouch (SHARE on
#      pgpm.part), then reads it and REFUSES, nothing changed (schema, config, part rows, the mark, every job, the armed
#      command); refused again without --single-transaction, the owner's own jobs still there. Then the superuser's
#      uninstall completes and removes every role's pgpm job in this database (by username and jobname), and a pgpm job
#      of another database stays.
#   B  the owner alone scheduled, nothing retiring: its uninstall completes, removes its jobs, and WARNS that another
#      role's jobs are out of its sight.
#   C  the owner alone scheduled and its own tick dispatched the detach: it can vouch, and its uninstall completes,
#      removing its armed job.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), all of pgpm_core/uninstall.sql:
#   uninstall_unschedules_by_name           -- #1500 back: cron.unschedule(jobname). Part A's superuser uninstall.
#   uninstall_unschedules_every_database    -- the database scope dropped: another database's pgpm job goes. Part A.
#   uninstall_unvouched_unrefused           -- #1496 back: the refusal removed. Part A.
#   uninstall_vouch_unlocked                -- the refusal read without SHARE on pgpm.part: a dispatch committed while
#                                              the uninstall waited is read by nothing. Part A's wait and refusal.
#   uninstall_unschedules_before_refusal    -- the jobs removed in a block ahead of the refusal: without
#                                              --single-transaction the refused run took the owner's jobs. Part A.
#   uninstall_refuses_own_retirement        -- the over-wide fix: any retirement refuses a non-superuser, its own
#                                              dispatch too. Part C.
#   uninstall_unwarned_foreign_jobs         -- the WARNING removed. Part B.
#
# UNINSTALL_JOBS_INSTALL overrides the install's path inside <container>.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; UNINSTALL="${3:-/repo/pgpm_core/uninstall.sql}"
INSTALL="${UNINSTALL_JOBS_INSTALL:-/repo/pgpm_core/install.sql}"
G="pgpm_guard-$DB-$$"
OWNER=pgpm_g1500_owner
OTHER_DB=pgpm_g1500_other
fail=0
work=$(mktemp -d)
trap 'touch "$work/go"; wait 2>/dev/null; docker rm -f "$G" >/dev/null 2>&1; rm -rf "$work"' EXIT

check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-66s %s\n' "$1" "$2"
  else printf 'FAIL  %-66s %s (want %s)\n' "$1" "$2" "$3"; fail=1; fi
}
# <user> [psql args...]: one psql session on the guard's own server
g() { local u=$1; shift; docker exec -i -e PGOPTIONS=-cclient_min_messages=warning "$G" psql -U "$u" -X -qAt -d postgres "$@"; }
v() { g postgres -c "$1" 2>&1; }

# The scripts under test, out of the container the harness named. A path that is not there is NOT a catch.
if ! docker exec "$C" cat "$INSTALL" >"$work/i.sql" 2>/dev/null || [ ! -s "$work/i.sql" ]; then
  printf 'FAIL  %-66s %s\n' "fixture: the install under test was read" "$INSTALL"; exit 1
fi
if ! docker exec "$C" cat "$UNINSTALL" >"$work/u.sql" 2>/dev/null || [ ! -s "$work/u.sql" ]; then
  printf 'FAIL  %-66s %s\n' "fixture: the uninstall script under test exists" "$UNINSTALL"; exit 1
fi
img=$(docker inspect -f '{{.Config.Image}}' "$C" 2>/dev/null)
docker rm -f "$G" >/dev/null 2>&1
if [ -z "$img" ] || ! docker run -d --name "$G" -e POSTGRES_PASSWORD=postgres "$img" >/dev/null 2>"$work/run.err"; then
  printf 'FAIL  %-66s %s\n' "fixture: the guard's own server started" "${img:-no image}"; sed 's/^/      /' "$work/run.err"; exit 1
fi
up=""
for _ in $(seq 1 120); do   # over TCP: the image's init server listens on the socket alone, and is restarted
  if docker exec -e PGPASSWORD=postgres "$G" psql -h 127.0.0.1 -U postgres -Atc 'select 1' >/dev/null 2>&1; then up=1; break; fi
  sleep 0.5
done
if [ -z "$up" ]; then printf 'FAIL  %-66s %s\n' "fixture: the guard's own server accepts connections" "no"; exit 1; fi
docker cp "$work/i.sql" "$G:/tmp/i.sql" >/dev/null && docker cp "$work/u.sql" "$G:/tmp/u.sql" >/dev/null
if ! g postgres -v ON_ERROR_STOP=1 >/dev/null 2>"$work/setup.err" <<SQL
create extension pg_cron;
create role $OWNER login;
grant create on database postgres to $OWNER;
grant usage on schema cron to $OWNER;
grant execute on function cron.schedule_in_database(text, text, text, text, text, boolean) to $OWNER;
grant execute on function cron.alter_job(bigint, text, text, text, text, boolean) to $OWNER;   -- its own tick dispatches
create database $OTHER_DB;
SQL
then
  printf 'FAIL  %-66s %s\n' "fixture: pg_cron and the owner role were set up" "no"; sed 's/^/      /' "$work/setup.err" | head -5; exit 1
fi

# A fresh install by the owner, the table of #1496's reproduction (its first partition past retention and referenced,
# so its retirement is a dispatched concurrent detach), then pgpm.schedule() by each role named. Prints the
# first partition's name.
fixture() {
  v "select count(cron.unschedule(jobid)) from cron.job" >/dev/null
  v "drop schema if exists pgpm cascade; drop schema if exists t cascade" >/dev/null
  g "$OWNER" -v ON_ERROR_STOP=1 --single-transaction -f /tmp/i.sql >/dev/null 2>"$work/fx.err" &&
  g "$OWNER" -v ON_ERROR_STOP=1 >/dev/null 2>>"$work/fx.err" <<'SQL' || return 1
create schema t;
create table t.ra (id bigint primary key, payload text);
insert into t.ra values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('t.ra'::regclass, 'id', 10000::bigint, p_retain => 40000, p_paused => false);
select pgpm.extend_to('t.ra'::regclass, '60000');
insert into t.ra values (30001, 'other'), (50005, 'frontier');
create table t.ra_ref (id bigint primary key, p_id bigint references t.ra (id));
insert into t.ra_ref values (1, 50005);
SQL
  local r
  for r in "$@"; do g "$r" -v ON_ERROR_STOP=1 -c "select pgpm.schedule('0 0 1 1 *', '0 0 1 1 *')" >/dev/null 2>>"$work/fx.err" || return 1; done
  g "$OWNER" -c "select child_name from pgpm.part where parent_table = 't.ra'::regclass and lo = '0'"
}
jobs_here() { v "select coalesce(string_agg(username || ':' || jobname, ',' order by username, jobname), 'none')
                   from cron.job where jobname like 'pgpm%' and database = current_database()"; }
cmd_of() { v "select coalesce((select command from cron.job where username = '$1' and jobname = 'pgpm_detach'), 'no job')"; }
state() { # what a refusal must leave: the schema, the config row, the part rows by name, the mark
  if [ "$(v "select to_regnamespace('pgpm') is null")" = t ]; then echo "pgpm gone"; return; fi
  v "select format('pgpm=t config=%s parts=%s mark=%s',
            (select count(*) from pgpm.config where parent_table = 't.ra'::regclass),
            (select count(*) || ':' || md5(string_agg(child_name, ',' order by lo::numeric)) from pgpm.part where parent_table = 't.ra'::regclass),
            (select format('%s/%s/%s', retiring_at is not null, detach_dispatched_oid is not null, coalesce(retiring_by::text, '-'))
               from pgpm.part where parent_table = 't.ra'::regclass and lo = '0'))"
}
REFUSAL="uninstall refused, nothing changed: t.ra retiring %s, whose detach pgpm dispatched, or may have, to a pgpm_detach cron job, and role $OWNER cannot read every job that may hold it"
WARNED="role $OWNER is not a superuser, and pg_cron shows such a role only its own jobs, so this removed only role ${OWNER}'s pgpm jobs"
ALL6="$OWNER:pgpm,$OWNER:pgpm_detach,$OWNER:pgpm_obtain,postgres:pgpm,postgres:pgpm_detach,postgres:pgpm_obtain"

echo "--- A: the superuser's tick dispatched, the owner uninstalls, then the superuser does"
D=$(fixture "$OWNER" postgres)
if [ -z "$D" ]; then printf 'FAIL  %-66s %s\n' "fixture: part A's install, table and jobs" "no"; sed 's/^/      /' "$work/fx.err" | head -5; exit 1; fi
v "select cron.schedule_in_database('pgpm_elsewhere', '0 0 1 1 *', 'select 1', '$OTHER_DB')" >/dev/null
DETACH="alter table t.ra detach partition t.$D concurrently"
check "LIVENESS: both roles hold pgpm jobs in this database" "$(jobs_here)" "$ALL6"
check "LIVENESS: another database's pgpm job" \
  "$(v "select string_agg(username || ':' || jobname || '@' || database, ',') from cron.job where database <> current_database()")" \
  "postgres:pgpm_elsewhere@$OTHER_DB"
parts_before=$(state | sed 's/ mark=.*//')

# The administrator's tick, held uncommitted: retire() marks the partition and arms the jobs (a superuser's dispatch
# arms every role's pgpm_detach job it sees) in one transaction, which then waits for the go.
( printf "set application_name = 'g1500_admin';\nbegin;\nselect pgpm.retire('t.ra', '%s');\n" "$D"
  for _ in $(seq 1 600); do [ -e "$work/go" ] && break; sleep 0.1; done
  printf 'commit;\n' ) | docker exec -i "$G" psql -U postgres -d postgres -qtAX -v ON_ERROR_STOP=1 >"$work/admin.out" 2>&1 &
held=""
for _ in $(seq 1 200); do
  if [ "$(v "select count(*) from pg_stat_activity where application_name = 'g1500_admin' and state = 'idle in transaction'")" = 1 ] \
     && [ -s "$work/admin.out" ]; then held=1; break; fi
  sleep 0.1
done
check "LIVENESS: the superuser's retire() returned, its transaction open" "${held:-never}" 1
docker exec -i -e PGAPPNAME=g1500_uninst -e PGOPTIONS=-cclient_min_messages=warning "$G" \
  psql -U "$OWNER" -X -q -d postgres --single-transaction -v ON_ERROR_STOP=1 -f /tmp/u.sql >"$work/ua.out" 2>&1 &
upid=$!
waited=""
for _ in $(seq 1 200); do
  waited=$(v "select string_agg(coalesce(l.relation::regclass::text, l.locktype) || ' ' || l.mode, ',') from pg_locks l
                join pg_stat_activity a on a.pid = l.pid where a.application_name = 'g1500_uninst' and not l.granted")
  [ -n "$waited" ] && break
  kill -0 "$upid" 2>/dev/null || break
  sleep 0.1
done
check "the owner's uninstall waits for the dispatch at its vouch" "${waited:-never waited}" "pgpm.part ShareLock"
touch "$work/go"
wait "$upid"; urc=$?
rm -f "$work/go"
check "LIVENESS: the superuser's job holds the detach" "$(cmd_of postgres)" "$DETACH"
# shellcheck disable=SC2059  # the refusal's text is the format, the partition its one argument
check "the owner's uninstall is refused, naming the partition and its role" \
  "$urc $(grep -cF "$(printf "$REFUSAL" "$D")" "$work/ua.out") $(grep -c 'Run this script as a superuser\.' "$work/ua.out")" "3 1 1"
check "the refusal changed nothing: schema, config, part rows, the mark" "$(state)" "$parts_before mark=t/t/-"
check "the refusal changed nothing: every role's job" "$(jobs_here)" "$ALL6"
check "the refusal changed nothing: the superuser's job still armed" "$(cmd_of postgres)" "$DETACH"

# Without --single-transaction or ON_ERROR_STOP, as a client that carries on past an error runs it.
g "$OWNER" -f /tmp/u.sql >"$work/ua2.out" 2>&1
# shellcheck disable=SC2059
check "refused again with no transaction to roll back" "$(grep -cF "$(printf "$REFUSAL" "$D")" "$work/ua2.out")" 1
check "that refusal changed nothing either: every role's job" "$(jobs_here)" "$ALL6"
check "that refusal changed nothing either: schema, config, part rows, the mark" "$(state)" "$parts_before mark=t/t/-"

g postgres --single-transaction -v ON_ERROR_STOP=1 -f /tmp/u.sql >"$work/us.out" 2>&1; src=$?
check "the superuser's uninstall completes" "$src $(state)" "0 pgpm gone"
check "it removed every role's pgpm job in this database" "$(jobs_here)" "none"
check "it left another database's pgpm job" \
  "$(v "select coalesce(string_agg(username || ':' || jobname || '@' || database, ','), 'none') from cron.job")" \
  "postgres:pgpm_elsewhere@$OTHER_DB"
check "the superuser was not warned of jobs out of its sight" "$(grep -c 'is not a superuser' "$work/us.out")" 0
check "the table keeps the partition and its rows" \
  "$(v "select format('%s %s', (select array_agg(id order by id) from t.ra where id < 10000),
          exists (select 1 from pg_inherits where inhparent = 't.ra'::regclass and inhrelid = 't.$D'::regclass))")" "{1,2,3} t"

echo "--- B: the owner alone scheduled, nothing retiring"
D=$(fixture "$OWNER")
if [ -z "$D" ]; then printf 'FAIL  %-66s %s\n' "fixture: part B's install, table and jobs" "no"; sed 's/^/      /' "$work/fx.err" | head -5; exit 1; fi
check "LIVENESS: the owner holds its three jobs, nothing retiring" \
  "$(jobs_here) $(v "select count(*) from pgpm.part where retiring_at is not null")" "$OWNER:pgpm,$OWNER:pgpm_detach,$OWNER:pgpm_obtain 0"
g "$OWNER" --single-transaction -v ON_ERROR_STOP=1 -f /tmp/u.sql >"$work/ub.out" 2>&1; brc=$?
check "the owner's uninstall completes and removes its jobs" "$brc $(state) $(jobs_here)" "0 pgpm gone none"
check "it warns that another role's pgpm jobs are out of its sight" "$(grep -cF "$WARNED" "$work/ub.out")" 1

echo "--- C: the owner alone scheduled, and its own tick dispatched the detach"
D=$(fixture "$OWNER")
if [ -z "$D" ]; then printf 'FAIL  %-66s %s\n' "fixture: part C's install, table and jobs" "no"; sed 's/^/      /' "$work/fx.err" | head -5; exit 1; fi
g "$OWNER" -c "call pgpm.maintain('t.ra')" >/dev/null 2>&1
check "LIVENESS: the owner's own tick armed its job and recorded itself" \
  "$(cmd_of "$OWNER") $(state | sed 's/.* mark=//')" "alter table t.ra detach partition t.$D concurrently t/t/$OWNER"
g "$OWNER" --single-transaction -v ON_ERROR_STOP=1 -f /tmp/u.sql >"$work/uc.out" 2>&1; crc=$?
check "the owner can vouch for its own dispatch: its uninstall completes" "$crc $(state)" "0 pgpm gone"
check "and removes its armed job" "$(jobs_here)" "none"
if [ "$crc" != 0 ]; then sed 's/^/      /' "$work/uc.out" | head -3; fi

exit "$fail"
