#!/usr/bin/env bash
# Run tests/timescale/db/35_from_hypertable_naive_watermark_zone_test.sql and
# tests/timescale/db/36_from_hypertable_session_datestyle_test.sql against an ARBITRARY copy of
# pgpm_hypertable/install.sql, so bench/discriminate.sh can point them at a mutant (issues #791, #793).
#
# Both files are plain pgTAP and the timescale track runs them already; this wrapper is the standing proof
# that their assertions DISCRIMINATE. The subject is every time value from_hypertable carries from one
# statement into the literal of the next: the copy's chunk bounds, the append-only watermarks of the
# pre-drain, its step and the cutover, and the change reconcile's control range. Each must read back as the
# value it was, whatever the session's DateStyle and TimeZone say. The defect shows as a short copy or as
# the conservation check's refusal on a top-level CALL, a raw ERROR that this wrapper reports apart from the
# assertions it leaves failing. Each file runs in its own fresh database (the same name, dropped between).
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   hypertable_cutover_watermark_timestamptz -- the cutover holds its watermark in a timestamptz again,
#                                               so a naive one goes through the session TimeZone (#791)
#   hypertable_chunk_bounds_session_datestyle -- the copy splices its chunk bounds with a bare %L again,
#                                               in the session DateStyle (#793)
#   hypertable_ctl_text_session_datestyle   -- _from_hypertable_ctl_text renders in the session DateStyle,
#                                               which every drain and catch-up reads its bounds through
#
# Usage: hypertable_time_rendering.sh <container> <db> [pgpm_hypertable/install.sql]
# Runs on the TIMESCALE track's container (supabase/postgres + TimescaleDB), which is why its mutations sit
# in MUTATION_TRACK=timescale. That image does not trust the local socket, so every psql call goes over TCP
# (see run_timescale). run_timescale also runs it against the real install, so a harness broken enough to
# fail against everything cannot read as discriminating.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
fail=0

q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@"; }

# run_file <test file in the container> <label>
run_file() {
  local file="$1" label="$2" out ran bad ffail=0
  q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -d postgres -q -c "create database $DB" >/dev/null 2>&1
  q -d postgres -q -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"; fail=1; return
  fi
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "the module under test installed" "$HT"; fail=1; return
  fi
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "the timescale fixtures loaded" "tests/timescale/fixtures.sql"; fail=1; return
  fi
  out=$(q -d "$DB" -tAq -f "$file" 2>&1)
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+ -')
  # Two failure shapes, reported apart. A file that died early leaves a raw ERROR: and few or no
  # assertions, which must NOT read the same as assertions that ran and failed: discriminate.sh treats
  # any non-zero exit as "the guard caught the defect", so a harness broken enough to fail against
  # everything would otherwise be reported as proving the mutation. And a plan shortfall is a failure
  # too (#601), which this runner, unlike pg_prove, has to look for itself.
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "$label: the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | cut -c1-240 | sed 's/^/      /'
    ffail=1
  fi
  if echo "$out" | grep -qE '^# Looks like you planned'; then
    printf 'FAIL  %-58s %s\n' "$label: the file ran every assertion it planned" "$(echo "$out" | grep -E '^# Looks like you planned')"
    ffail=1
  fi
  if [ "$bad" = 0 ] && [ "$ffail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "$label" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "$label" "$ran ran, $bad failed"; ffail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "$label: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    ffail=1
  fi
  [ "$ffail" = 0 ] || fail=1
}

run_file /repo/tests/timescale/db/35_from_hypertable_naive_watermark_zone_test.sql \
  "a naive watermark never passes through the session zone"
run_file /repo/tests/timescale/db/36_from_hypertable_session_datestyle_test.sql \
  "bounds and watermarks are exact under DateStyle SQL"

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
