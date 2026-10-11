#!/usr/bin/env bash
# retire_pending_detach.sh <container> <db> [install.sql]
#
# Guard issue #705's pending-detach site at retire() and its unlocked read (bullet 3) against an ARBITRARY copy
# of pgpm_core/install.sql, so that bench/discriminate.sh can show it catches the defects its mutations put back.
#
# THE DEFECTS. retire()'s #652 refusal asked pg_inherits whether the child was still a partition of the parent
# without asking inhdetachpending, so a partition an operator's interrupted DETACH ... CONCURRENTLY left pending
# (no retiring_at) was taken for attached: write-blocked already, it was DROPPED by the next pgpm.maintain(parent)
# tick, rows and all, and with an incoming FK its detach was adopted as pgpm's own retirement (retiring_at) and the
# table dropped once the detach was finished. A mark so adopted, or one whose dispatch failed, outlived the fix: on
# a pending or detached partition it read as pgpm's own retirement. A mark now vouches only with the record of
# pgpm's own dispatch (pgpm.part.detach_dispatched_oid), which only fixed code writes; nothing an older install
# wrote (its retain_detach rows, the job's command, pg_cron's run history) can tell the two apart, so the upgrade
# from such an install disowns every mark on a pending or detached partition. And the refusals were read before
# any lock on the child, so a detach whose first transaction committed while retire() waited later on lost its
# table.
#
# TWO PHASES.
#   TAP      tests/327_retire_pending_detach_test.sql, the acceptance test (parts A to M and R), in <db>.
#   UPGRADE  a REAL re-run of the install under test over itself, the shape of bench/upgrade_in_place.sh, in
#            <db>_pre and <db>_cur. Each gets pgpm's own retirement of a referenced partition, dispatched (the
#            pgpm_detach job a stand-in cron.job, as tests/194 has) and interrupted in its wait, so pending under a
#            mark with its dispatch recorded. <db>_pre is degraded to an install older than the record, as
#            upgrade_in_place.sh degrades: the column dropped; the re-run adds it back empty and must disown the
#            mark, disarm the job and log retain_disown once. <db>_cur keeps it, and the re-run must leave the mark
#            and the armed job alone (the control, so a re-run that disowns everything cannot pass).
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   retire_pending_detach_counts_attached  -- a pending partition counts as attached again. TAP parts A, B.
#   retire_pending_detach_trusts_stamp     -- retire() trusts a mark on a pending partition with no dispatch
#                                             record. TAP part D.
#   detach_reap_trusts_stamp               -- _detach_reap finishes the detach under such a mark. TAP part E.
#   retire_trusts_detached_mark            -- retire() honours a mark on a detached partition with no dispatch
#                                             record. TAP part G.
#   retain_recall_trusts_detached_mark     -- the recall re-attaches a detached partition under such a mark. TAP
#                                             part J.
#   upgrade_pass_skips_pending             -- the install's pass never disowns a mark on a pending partition. TAP
#                                             part C, and the UPGRADE phase.
#   upgrade_pass_trusts_detached_mark      -- the install's pass never disowns a mark on a detached partition. TAP
#                                             parts H and K to M.
#   upgrade_pass_skips_unanchored          -- the pass does not reach a row with no recorded oid. TAP part H.
#   dispatch_witness_reads_log             -- a retain_detach row vouches for a mark, as an older install wrote one
#                                             for an adopted detach too. TAP parts K to M, and the UPGRADE phase.
#   dispatch_witness_reads_cron_history    -- round 3's witness: the retain_detach row, overruled only by a run
#                                             history it can read under the parent's current name. TAP parts K
#                                             (no history), L (unreadable) and M (parent renamed).
#   retire_pending_detach_adopted_mark_trusted -- every disown off at once (retire's two, the reap's, the pass):
#                                             each V-01, which no one of them restores alone. TAP parts C, D, E, G,
#                                             H and K to M, and the UPGRADE phase.
#   retire_checks_before_lock              -- retire() asks the catalog with no lock on the partition. TAP part R.
#
# Runs on the plain core image (pgtap, dblink and pg_prove; second sessions are dblink connections, parked by a
# held snapshot and polled server-side, not timed by sleeps). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/327_retire_pending_detach_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }
v() { q -d "$1" -tAq -c "$2" 2>&1 | tail -1; }
check() { # <description> <got> <want>
  if [ "$2" = "$3" ]; then printf 'PASS  %-74s %s\n' "$1" "$2"
  else printf 'FAIL  %-74s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

fresh() { # <db>: a fresh database with the install under test; 0 when it installed
  q -q -c "drop database if exists $1" >/dev/null 2>&1
  q -q -c "create database $1" >/dev/null 2>&1
  q -d "$1" -q -c "create extension if not exists pgtap; create extension if not exists dblink;" >/dev/null 2>&1
  q -d "$1" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1
}

# ---------------------------------------------------------------- TAP
if ! fresh "$DB"; then
  # A mutant that will not even install is NOT a pass: say which happened.
  printf 'FAIL  %-74s %s\n' "the module under test installed" "$INSTALL"
  fail=1
else
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-74s %s\n' "retire() leaves a partition pending detach alone" "$ran ran"
  else printf 'FAIL  %-74s %s\n' "retire() leaves a partition pending detach alone" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-74s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi
q -q -c "drop database if exists $DB" >/dev/null 2>&1

# ---------------------------------------------------------------- UPGRADE
# The state, in <db>: [100, 200) of public.up holds 111, 112 and 113 and is referenced through public.up_ref;
# retire() stamps it and arms the stand-in job with its detach; that detach is parked in its wait phase and
# killed. Prints nothing; the checks read the state back.
state() {
  docker exec -i "$C" psql -U postgres -d "$1" -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
set client_min_messages = warning;
create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');
create table public.up (id bigint primary key, payload text);
insert into public.up values (111, 'u1'), (112, 'u2'), (113, 'u3');
call pgpm.transmute('public.up', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.up values (600, 'frontier');
create table public.up_ref (id bigint primary key, up_id bigint references public.up (id));
insert into public.up_ref values (1, 600);
update pgpm.config set retain_batch = 1 where parent_table = 'public.up'::regclass;
call pgpm.maintain('public.up');
select dblink_connect('r', 'dbname=' || current_database() || ' application_name=up_reader');
select dblink_connect('d', 'dbname=' || current_database() || ' application_name=up_detach');
select dblink_exec('r', 'begin isolation level repeatable read');
select * from dblink('r', 'select count(*) from public.up') as t(n bigint);
select dblink_send_query('d', (select command from cron.job where jobname = 'pgpm_detach'));
do $$ begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where datname = current_database()
                       and application_name = 'up_detach' and wait_event = 'virtualxid');
    perform pg_sleep(0.05);
  end loop;
end $$;
select pg_terminate_backend(pid) from pg_stat_activity where datname = current_database() and application_name = 'up_detach';
do $$ begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when not exists (select 1 from pg_stat_activity where datname = current_database() and application_name = 'up_detach');
    perform pg_sleep(0.05);
  end loop;
end $$;
select dblink_exec('r', 'commit');
SQL
}
P="(select child_name from pgpm.part where parent_table = 'public.up'::regclass and lo = '100')"
STAMPED="select (select retiring_at is not null from pgpm.part where parent_table = 'public.up'::regclass and lo = '100')"
ARMED="select (select command from cron.job where jobname = 'pgpm_detach') = pgpm._detach_cmd('public.up', 'public', $P)"
PENDING="select exists (select 1 from pg_inherits where inhparent = 'public.up'::regclass and inhdetachpending and inhrelid = to_regclass('public.' || quote_ident($P)))"
DISOWNED="select count(*) from pgpm.log where parent_table = 'public.up'::regclass and action = 'retain_disown' and lo = '100' and method like '%pending a concurrent detach under a retirement mark for which pgpm recorded no dispatch%'"

for kind in pre cur; do
  udb="${DB}_${kind}"
  if ! fresh "$udb"; then
    printf 'FAIL  %-74s %s\n' "fixture: UPGRADE $kind: the module under test installed" "$INSTALL"; fail=1; continue
  fi
  state "$udb"
  check "LIVENESS: UPGRADE $kind: [100, 200) is pending under a retirement mark" \
    "$(v "$udb" "$STAMPED") $(v "$udb" "$PENDING")" "t t"
  check "LIVENESS: UPGRADE $kind: the pgpm_detach job is armed with its detach" "$(v "$udb" "$ARMED")" "t"
  check "LIVENESS: UPGRADE $kind: and the dispatch is recorded, by the partition's oid" \
    "$(v "$udb" "select detach_dispatched_oid = child_oid from pgpm.part where parent_table = 'public.up'::regclass and lo = '100'")" "t"
  if [ "$kind" = pre ]; then
    # an install older than the dispatch record: it has no pgpm.part.detach_dispatched_oid
    q -d "$udb" -q -c "alter table pgpm.part drop column detach_dispatched_oid cascade" >/dev/null 2>&1
    check "fixture: UPGRADE pre: the install reads as older than the dispatch record" \
      "$(v "$udb" "select not exists (select 1 from pg_attribute where attrelid = 'pgpm.part'::regclass and attname = 'detach_dispatched_oid' and not attisdropped)")" "t"
  fi
  if ! q -d "$udb" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-74s %s\n' "fixture: UPGRADE $kind: the re-run of the install completed" "$INSTALL"; fail=1
  elif [ "$kind" = pre ]; then
    check "UPGRADE pre: the mark is disowned" "$(v "$udb" "$STAMPED")" "f"
    check "UPGRADE pre: the job is disarmed" "$(v "$udb" "select command from cron.job where jobname = 'pgpm_detach'")" "select 1"
    check "UPGRADE pre: logged once, retain_disown" "$(v "$udb" "$DISOWNED")" "1"
  else
    check "UPGRADE cur: pgpm's own retirement keeps its mark" "$(v "$udb" "$STAMPED")" "t"
    check "UPGRADE cur: and its armed job" "$(v "$udb" "$ARMED")" "t"
    check "UPGRADE cur: nothing is disowned" "$(v "$udb" "$DISOWNED")" "0"
  fi
  check "UPGRADE $kind: [100, 200) still holds rows 111, 112 and 113" \
    "$(v "$udb" "select array_agg(id order by id)::text from public.$(v "$udb" "select quote_ident(child_name) from pgpm.part where parent_table = 'public.up'::regclass and lo = '100'")")" "{111,112,113}"
  q -q -c "drop database if exists $udb" >/dev/null 2>&1
done

exit "$fail"
