#!/usr/bin/env bash
# Prove tests/timescale/db/05 (the keyless append-only catch-up) FAILS against a migration that lost one
# copied row and holds another twice, by putting that state in and running the file.
#
# WHY THIS GUARD EXISTS (issue #996). The file judged the catch-up by counts: count(*) = 245 and 5 rows with
# device_id >= 1000. A keyless migrated table that lost one copied row and held another copied row twice keeps
# both counts, so the file passed against it. pgpm's own #653 fingerprint runs before the swap and cannot see a
# loss after it, so only the file stood between such a migration and a green track. It now compares the
# migrated table to a snapshot of the source taken right before the cutover, as a bag (a keyless table may hold
# a row twice).
#
# HOW. Each run in a fresh <db> in <container> (the timescale track's fleet image: TimescaleDB, pgtap, the core,
# pgpm_hypertable and tests/timescale/fixtures.sql):
#   CONTROL   the file passes, every planned assertion ok, as written;
#   DEFECT    the file reports at least one `not ok` (and runs to its end) with two statements spliced in right
#             after its call of pgpm.from_hypertable_cutover: one copied row (device_id < 1000) deleted, another
#             copied row inserted a second time;
#   LIVENESS  the defect was really planted: read after the DEFECT run against a copy of the source the splice
#             took just before the cutover, the migrated table is partitioned, holds the source's 245 rows by
#             count, and differs from the source by exactly one row each way (EXCEPT ALL 1 and 1).
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   hypertable_catchup_rows_by_count -- tests/timescale/db/05 back to its pre-#996 text: counts, no snapshot
#
# Usage: hypertable_catchup_identity.sh <container> <db> [test file]
# The third argument is the test file to judge in place of tests/timescale/db/05 (bench/discriminate.sh hands
# it the mutant, a /repo/... path, which this maps to this checkout). Files reach the container over stdin or
# `docker exec sh -c cat`, so a mutant outside the mounted tree works too. Runs on the TIMESCALE track, which is
# why the mutation sits in MUTATION_TRACK=timescale; run_timescale also runs it once against the clean file.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${3:-$ROOT/tests/timescale/db/05_from_hypertable_catchup_test.sql}"
SRC="${SRC/#\/repo\//$ROOT/}"
fail=0
CD="/tmp/hypertable_catchup_identity_$DB"
work=$(mktemp -d)

q() { docker exec -i -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres -X "$@"; }
cleanup() {
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  docker exec "$C" rm -rf "$CD" </dev/null >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

if [ ! -f "$SRC" ]; then printf 'FAIL  %-58s %s\n' "the test file to judge exists" "$SRC"; exit 1; fi

# fresh: a new <db> with TimescaleDB, pgtap, the core, the module and the fixtures. Exit 0 when all loaded.
fresh() {
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "create database $DB" </dev/null >/dev/null 2>&1 &&
    q -d postgres -q -c "alter database $DB set client_min_messages = warning" </dev/null >/dev/null 2>&1 &&
    q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" </dev/null >/dev/null 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f - <"$ROOT/pgpm_core/install.sql" >/dev/null 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$ROOT/pgpm_hypertable/install.sql" >/dev/null 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$ROOT/tests/timescale/fixtures.sql" >/dev/null 2>&1
}

# The DEFECT copy of the file: a snapshot of the source right before the cutover (for the LIVENESS read), and
# after it one copied row lost and another held twice. The splice point must match exactly once.
if ! python3 - "$SRC" "$work/defect.sql" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(keepends=True)
hits = [i for i, l in enumerate(lines) if l.startswith("call pgpm.from_hypertable_cutover('hp_d1',")]
if len(hits) != 1:
    sys.exit(f"the cutover call matched {len(hits)} time(s), expected 1")
i = hits[0]
lines[i:i + 1] = [
    "create table hci_source_snap as select * from hp_d1;\n",
    lines[i],
    "delete from hp_d1 where ctid = (select ctid from hp_d1 where device_id < 1000 order by ts limit 1);\n",
    "insert into hp_d1 select * from hp_d1 where device_id < 1000 order by ts desc limit 1;\n",
]
open(dst, "w").write("".join(lines))
PY
then
  printf 'FAIL  %-58s %s\n' "planted the defect: the splice after the cutover" "the file moved; fix the splice"
  exit 1
fi
docker exec "$C" mkdir -p "$CD" </dev/null
docker exec -i "$C" sh -c "cat > $CD/control.sql" <"$SRC"
docker exec -i "$C" sh -c "cat > $CD/defect.sql" <"$work/defect.sql"

tap_verdict() {
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
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ "$rc" != 0 ]; then
    printf 'FAIL  %-58s %s\n' "psql ran the file to its end" "exit $rc"
    echo "$out" | grep -E 'FATAL:|connection' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ -z "$planned" ] || [ "$ran" != "$planned" ]; then
    printf 'FAIL  %-58s %s\n' "the file ran every assertion it planned" "planned ${planned:-nothing}, $ran ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran, $bad failed"; fail=1
  fi
  # <<< pgTAP verdict
}

# CONTROL: the file as written passes.
if fresh; then
  TEST_FILE="$CD/control.sql"; LABEL="CONTROL: the catch-up file passes on the clean module"
  tap_verdict
else
  printf 'FAIL  %-58s %s\n' "CONTROL: the extensions, core, module and fixtures loaded" "$DB"; fail=1
fi

# DEFECT: the same file, with one copied row lost and another held twice after the cutover, must fail; and
# only for that reason, so the verdict is read apart from the shared block's own fail flag.
if fresh; then
  saved=$fail; fail=0
  TEST_FILE="$CD/defect.sql"; LABEL="the defect run is clean (expected FAIL below)"
  tap_verdict >"$work/defect.verdict"
  dfail=$fail; fail=$saved
  grep -E '^    not ok' "$work/defect.verdict"
  if [ "$dfail" = 1 ] && [ "$bad" -gt 0 ] && [ -n "$planned" ] && [ "$ran" = "$planned" ] && [ "$rc" = 0 ] \
     && ! grep -q 'the file ran without a raw error' "$work/defect.verdict"; then
    printf 'PASS  %-58s %s\n' "DEFECT: the file fails on one row lost, one held twice" "$bad of $ran not ok"
  else
    printf 'FAIL  %-58s %s\n' "DEFECT: the file fails on one row lost, one held twice" \
      "$bad of $ran not ok (plan ${planned:-none}, psql exit $rc): it passes for the wrong reason"
    grep -E '^FAIL' "$work/defect.verdict" | sed 's/^/      /'
    fail=1
  fi
  witness=$(q -d "$DB" -tAc "
    select (select relkind::text from pg_class where oid = 'hp_d1'::regclass)
      || '/' || (select count(*) from (select * from hci_source_snap except all select * from hp_d1) a)
      || '/' || (select count(*) from (select * from hp_d1 except all select * from hci_source_snap) b)
      || '/' || (select count(*) from hp_d1) || '/' || (select count(*) from hci_source_snap)" </dev/null 2>&1 | tail -1)
  if [ "$witness" = "p/1/1/245/245" ]; then
    printf 'PASS  %-58s %s\n' "LIVENESS: migrated, 245 rows, one lost and one twice" "kind/lost/extra/rows/source $witness"
  else
    printf 'FAIL  %-58s %s\n' "LIVENESS: migrated, 245 rows, one lost and one twice" "kind/lost/extra/rows/source $witness"
    fail=1
  fi
else
  printf 'FAIL  %-58s %s\n' "DEFECT: the extensions, core, module and fixtures loaded" "$DB"; fail=1
fi

exit "$fail"
