#!/usr/bin/env bash
# Run tests/185 and 186 against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh can
# point them at a mutant (issues #706 and #732).
#
# WHY A WRAPPER. The two files are plain pgTAP files and the default matrix already runs them on every
# version and channel, so on correct code this script adds nothing. What it adds is the standing proof that
# they DISCRIMINATE. Each site they cover is a value read before the lock that protects it and trusted after
# it, and each window is one a single pgTAP file can open on cue: an event trigger on the conversion's own
# DDL makes the change after the old read and before the lock (committing it through a second session over
# dblink when the change has to commit on its own: a GRANT, an ALTER SEQUENCE), and a second dblink session
# holds pgpm.regrain_lock for the regrain sites. Each file pairs its verdicts with liveness witnesses of its
# own; pointing it at a mutant is what shows the verdicts would fail without the fix.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   transmute_grants_before_lock              -- the grants are read and replayed with the staging work again:
#                                                tests/185 (A)'s parent keeps the revoked SELECT and lacks both
#                                                window grants
#   transmute_incoming_gate_preflight_only    -- the cutover does not ask the incoming-key gate again:
#                                                tests/185 (B)'s key follows the rename onto the monolith
#   transmute_transition_refusal_preflight_only -- the transition-table refusal is not asked under the lock:
#                                                tests/185 (C) fails on the replay's raw error instead
#   transmute_key_shape_unchecked             -- the key and identity are not re-checked after the LIKE:
#                                                tests/185 (D) converts with the identity BY DEFAULT
#   regrain_janitor_without_lock              -- the janitor reads the cursor without pgpm.regrain_lock:
#                                                tests/185 (E)'s capture is torn down while the lock is held
#   regrain_reclaim_without_lock              -- reclaim reads and clears without pgpm.regrain_lock:
#                                                tests/185 (F)'s reclaim runs around the holder
#   transmute_identity_options_before_lock    -- the cutover keeps step 6's options: tests/186 (A)'s parent
#                                                has INCREMENT BY 1 and hands out 12, 13
#   identity_options_unlocked                 -- the options are re-read under the table lock but with no
#                                                lock on the sequence: tests/186's late ALTER SEQUENCE commits
#   untransmute_identity_options_before_lock  -- untransmute reads the options before its lock again:
#                                                tests/186 (B)'s restored table has INCREMENT BY 1
#
# Usage: reread_under_lock_remaining_tap.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has).
# REREAD_TEST_DIR overrides the directory holding the test files inside the container, for running
# from a worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
DIR="${REREAD_TEST_DIR:-/repo/tests}"
FILES="185_reread_under_lock_remaining_sites_test.sql 186_identity_options_under_sequence_lock_test.sql"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

for f in $FILES; do
  q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

  # A mutant that will not even install is NOT a pass, and not evidence either: say which happened.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-66s %s\n' "the module under test installed" "$INSTALL"
    fail=1; break
  fi

  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $DIR/$f" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit status covers a failed assertion and a file that died short of its plan. What it cannot
  # tell apart from a real failure is a run that never reached the database, and discriminate.sh reads a
  # non-zero exit as "the guard caught the defect", so the count is asserted separately.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-66s %s\n' "$f" "$ran ran"
  else printf 'FAIL  %-66s %s\n' "$f" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-66s %s\n' "$f: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
