#!/usr/bin/env bash
# The scratch-relation lever's guard (issues #949, #950, #955; tracking issue #966).
#
# A relation pgpm makes for its own use is MINTED one way (the parent's owner and an owner-only ACL, in the
# transaction that creates it: pgpm._scratch_mint) and RESOLVED one way (from the record that transaction
# wrote, never from a name rendered from the parent's), and its owner follows the parent's on every tick
# (pgpm._scratch_owner_follow, with pgpm.hand_over_scratch as the documented step when a tick cannot). The
# conformance suite is two pgTAP files, each driven by the list of the scratch objects its half of pgpm
# creates, and each checking that list against what pgpm actually created, so a scratch relation added
# later fails as an omission rather than passing untested:
#   tests/267_scratch_relations_test.sql                      the core: the regrain delta, its capture
#                                                             function, a regrain's fine children, transmute's
#                                                             staging parent
#   tests/timescale/db/49_from_hypertable_scratch_relations_test.sql  pgpm_hypertable: the copy, the delta, the
#                                                             capture function and trigger, the key index;
#                                                             and uninstall.sql reading the record
# Each stage pairs its negative with a LIVENESS witness: the stranger role's default grant was in force (a
# table the session creates gets it), the operator's namesake existed with its rows before the step and the
# step ran (the copy completes once the name is free, the cutover migrates, untransmute hands the table back),
# the tick that should re-own did the work (it copied, the regrain swapped).
#
# This wrapper runs the half its third argument belongs to, so bench/discriminate.sh can point it at a mutant:
#   a copy of pgpm_core/install.sql      -> tests/267 against it, on the plain core image (pg_prove)
#   a copy of pgpm_hypertable/install.sql (it defines pgpm.from_hypertable_copy)
#                                        -> tests/timescale/db/49 against it, on the timescale image (psql)
#   a copy of pgpm_core/uninstall.sql    -> tests/timescale/db/49 reading it with \ir, on the timescale image
#   nothing                              -> the half the container can run: 49 where TimescaleDB is
#                                           available, 267 elsewhere (test.sh runs it from both tracks)
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each one site of the class:
#   core (perf track)
#     scratch_regrain_delta_minted_default_acl  the delta re-owned but its ACL never reset (#949 bullet 1)
#     scratch_regrain_capture_fn_tick_owner     the capture function left the tick role's
#     scratch_fine_child_minted_default_acl     a fine child reset only at its sub-range's end (#949 bullet 2)
#     scratch_regrain_owner_not_followed        no ownership check on a resuming tick (#950 bullet 2)
#     scratch_owner_refusal_swallowed           a tick that cannot re-own goes on to fail permission denied
#     regrain_capture_names_derived_fallback    the delta and function resolved by derived name when unrecorded
#     scratch_prepare_owner_not_followed        the next regrain's prepare drops the old owner's objects
#                                               without asking (#969 bullet 2)
#     scratch_cancel_owner_not_followed         regrain_cancel truncates the old owner's delta without asking
#     scratch_reclaim_owner_not_followed        retire's reclaim drops and empties them without asking
#     scratch_untransmute_owner_not_followed    untransmute drops them without asking
#     scratch_owner_refusal_not_42501           the hand-over refusal raised as P0001, past uninstall's handler
#   pgpm_hypertable (timescale track)
#     hypertable_copy_drops_dest_by_name        the copy drops <rel>_pgpm_dest by name (#955 bullet 1)
#     hypertable_copy_drops_delta_by_name       the copy drops <rel>_pgpm_delta by name (#955 bullet 1)
#     hypertable_copy_replaces_fn_by_name       the copy replaces <rel>_pgpm_delta_fn() by name
#     hypertable_copy_drops_trigger_by_name     the copy drops <rel>_pgpm_delta_trg by name
#     hypertable_dest_minted_default_acl        the copy keeps default privileges to the swap (#949 bullet 3)
#     hypertable_delta_minted_default_acl       the delta keeps default privileges
#     hypertable_delta_writers_ungranted        the delta reset but the hypertable's writers not granted
#     hypertable_drain_delta_step_by_name       \
#     hypertable_drain_delta_by_name             | each drain resolves the copy and the delta by name
#     hypertable_drain_appends_step_by_name      |
#     hypertable_drain_appends_by_name          /
#     hypertable_cutover_dest_by_name           the cutover swaps in whatever answers to <rel>_pgpm_dest
#     hypertable_cutover_delta_by_name          the cutover takes <rel>_pgpm_delta for its change log by name
#     hypertable_cutover_drops_fn_by_name       the cutover drops <rel>_pgpm_delta_fn() by the current name
#     hypertable_swap_keeps_scratch_record      the swap leaves the record naming the migrated table
#     uninstall_scratch_record_unread           uninstall.sql sweeps by the comments alone
#     hypertable_carried_ddl_by_name            the swap leaves out <rel>_pgpm_delta_fn's triggers by name
#                                               (#969 bullet 5)
#     hypertable_carried_ddl_record_unread      the swap does not read pgpm.scratch's record of the capture
#     hypertable_carry_capture_unrecorded       nor know a capture 0.6.0 minted by its proof
#
# Usage: scratch_relations.sh <container> <db> [module or uninstall script, a path inside the container]
# Every setup step runs under ON_ERROR_STOP with its exit read: a mutant that does not install, or fixtures
# that do not load, FAIL here, never pass. run_perf and run_timescale both run it against the real code, so a
# wrapper broken enough to fail against everything cannot read as discriminating.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUTANT="${3:-}"
CORE=/repo/pgpm_core/install.sql; HT=/repo/pgpm_hypertable/install.sql; UNINSTALL=/repo/pgpm_core/uninstall.sql
fail=0

has_ts() {
  [ "$(docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres -d postgres -tAc \
        "select count(*) from pg_available_extensions where name = 'timescaledb'" 2>/dev/null)" = 1 ]
}

MODE=""
if [ -n "$MUTANT" ]; then
  if ! docker exec "$C" test -r "$MUTANT"; then
    printf 'FAIL  %-58s %s\n' "the file under test exists" "$MUTANT"; exit 1
  elif docker exec "$C" grep -q '^create or replace procedure pgpm.from_hypertable_copy(' "$MUTANT"; then
    MODE=ts; HT="$MUTANT"
  elif docker exec "$C" grep -q '^-- Uninstall pg_partition_magician' "$MUTANT"; then
    MODE=ts; UNINSTALL="$MUTANT"
  else
    MODE=core; CORE="$MUTANT"
  fi
elif has_ts; then
  MODE=ts
else
  MODE=core
fi

if [ "$MODE" = core ]; then
  TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/267_scratch_relations_test.sql}"
  LABEL="core scratch relations: minted owner-only, resolved by record, owned like the parent"
  q() { docker exec "$C" psql -U postgres "$@"; }
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  if ! q -v ON_ERROR_STOP=1 -q -c "create database $DB" >/dev/null 2>&1 \
     || ! q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists pgtap;" >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "the scratch database was created, with pgtap" "$DB"; fail=1
  fi
  if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$CORE" >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "the core install under test installed" "$CORE"; fail=1
  fi
  if [ "$fail" = 0 ]; then
    out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1); rc=$?
    echo "$out" | grep -E '^not ok [0-9]+' | sed 's/^/    /' | head -20
    ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+( |$)')
    if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
    else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
    # pg_prove's exit covers a plan shortfall; this covers a run that never reached the database at all
    if [ "$ran" -eq 0 ]; then
      printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
      echo "$out" | tail -20 | sed 's/^/      /'; fail=1
    fi
  fi
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  exit "$fail"
fi

# The timescale half. The fleet image does not trust the local socket, so every psql call goes over TCP (see
# run_timescale), and it has no pg_prove, so the TAP is judged by the shared verdict block below.
TEST_FILE=/repo/tests/timescale/db/49_from_hypertable_scratch_relations_test.sql
LABEL="hypertable scratch relations: minted owner-only, resolved by record"
q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@"; }
q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
if ! q -d postgres -v ON_ERROR_STOP=1 -q -c "create database $DB" -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1 \
   || ! q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the scratch database was created, with timescaledb and pgtap" "$DB"; fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$CORE" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "$CORE"; fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the hypertable module under test installed" "$HT"; fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the timescale fixtures loaded" "tests/timescale/fixtures.sql"; fail=1
fi

if [ "$fail" = 0 ]; then
  # >>> pgTAP verdict: the same in every timescale wrapper; bench/wrapper_tap_verdicts.sh evaluates it.
  out=$(q -d "$DB" -tAq -v "uninstall=$UNINSTALL" -f "$TEST_FILE" 2>&1); rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+' | sed 's/^/    /' | head -20
  planned=$(echo "$out" | sed -nE 's/^1\.\.([0-9]+)$/\1/p' | head -1)
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+( |$)')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+( |$)')
  # pg_prove's verdict, which this runner has to apply itself. Three ways a file fails with no `not ok`,
  # each reported apart from assertions that ran and failed (discriminate.sh reads any non-zero exit as
  # "the guard caught the defect", so a harness that fails everything must say why): a raw ERROR:; a
  # psql exit other than 0, which is how a session that died part-way (FATAL, no ERROR:) shows, since it
  # never reaches finish() to print "# Looks like you planned" (#795); and a count of assertions
  # that is not the 1..N plan's, which a silently skipped assertion leaves (#601, #712).
  # A file that reached no assertion failed on its fixture, whatever stopped it, so its setup lines are
  # premises then and discriminate.sh's starved() does not read them as a catch (#1177).
  unreached=""; [ "$ran" -gt 0 ] || unreached="fixture: "
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "${unreached}the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ "$rc" != 0 ]; then
    printf 'FAIL  %-58s %s\n' "${unreached}psql ran the file to its end" "exit $rc"
    echo "$out" | grep -E 'FATAL:|connection' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ -z "$planned" ] || [ "$ran" != "$planned" ]; then
    printf 'FAIL  %-58s %s\n' "${unreached}the file ran every assertion it planned" "planned ${planned:-nothing}, $ran ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran, $bad failed"; fail=1
  fi
  # <<< pgTAP verdict
fi

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
