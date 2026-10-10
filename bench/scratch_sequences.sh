#!/usr/bin/env bash
# The scratch-relation lever's guard for the sequences a scratch relation owns (issue #974; the lever of #966).
#
# pgpm._scratch_mint gives a relation pgpm makes for its own use the parent's owner and an owner-only ACL in
# the transaction that creates it (bench/scratch_relations.sh guards that). A delta's `pgpm_seq bigint
# generated always as identity` column OWNS a sequence, born with the minting role's ALTER DEFAULT PRIVILEGES
# (on Supabase, `grant all on sequences to anon, authenticated`), and the mint reset the delta's ACL and not
# the sequence's: a role holding nothing on the managed table could setval it. On the regrain delta that made
# duplicate pgpm_seq values, one tick consumed a key it never applied, and the swap dropped rows with the
# source; on the hypertable delta the role read the change counter and could setval the drains' watermark.
# The conformance is two pgTAP files, each checking every sequence a recorded scratch relation owns, and the
# list of sequences the step created against that record, so a sequence a later scratch relation owns fails
# as an omission rather than passing untested:
#   tests/272_scratch_sequence_acl_test.sql                  the core: the regrain delta's pgpm_seq sequence,
#                                                            the stranger's setval refused, rows 60..89 kept
#                                                            through the swap, the sequence following a hand-over
#   tests/timescale/db/51_from_hypertable_scratch_sequence_acl_test.sql  pgpm_hypertable: the tracking delta's
#                                                            pgpm_seq sequence, unreadable and not settable by
#                                                            the stranger, the writer's capture and the cutover
# Each pairs its negatives with LIVENESS witnesses: the stranger's default grant is in force (a sequence the
# session creates gets it), the step created the sequence, the copy is part-way, the capture logged the writes,
# the regrain swapped or the hypertable migrated.
#
# This wrapper runs the half its third argument belongs to, so bench/discriminate.sh can point it at a mutant:
#   a copy of pgpm_core/install.sql      -> tests/272 against it, on the plain core image (pg_prove)
#   a copy of pgpm_hypertable/install.sql (it defines pgpm.from_hypertable_copy)
#                                        -> tests/timescale/db/51 against it, on the timescale image (psql)
#   nothing                              -> the half the container can run: 51 where TimescaleDB is
#                                           available, 272 elsewhere (test.sh runs it from both tracks)
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site of the class:
#   scratch_mint_sequence_default_acl      core (perf track): _scratch_mint resets the relation, not the
#                                          sequences it owns
#   hypertable_delta_sequence_default_acl  pgpm_hypertable (timescale track): the tracking delta minted as the
#                                          lever stood before #974, its sequence keeping the default privileges
#
# Usage: scratch_sequences.sh <container> <db> [module, a path inside the container]
# Every setup step runs under ON_ERROR_STOP with its exit read: a mutant that does not install, or fixtures
# that do not load, FAIL here, never pass. run_perf and run_timescale both run it against the real code, so a
# wrapper broken enough to fail against everything cannot read as discriminating.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUTANT="${3:-}"
CORE=/repo/pgpm_core/install.sql; HT=/repo/pgpm_hypertable/install.sql
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
  else
    MODE=core; CORE="$MUTANT"
  fi
elif has_ts; then
  MODE=ts
else
  MODE=core
fi

if [ "$MODE" = core ]; then
  TEST_FILE=/repo/tests/272_scratch_sequence_acl_test.sql
  LABEL="core scratch sequences: minted owner-only, the swap keeps every row"
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
TEST_FILE=/repo/tests/timescale/db/51_from_hypertable_scratch_sequence_acl_test.sql
LABEL="hypertable scratch sequences: minted owner-only"
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
  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=$?
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
