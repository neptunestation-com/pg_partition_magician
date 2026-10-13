#!/bin/bash
# F16-03: tests/archive/db/08_archive_fn_s3_test.sql reads the NDJSON objects of its bigint-keyed tables back by
# LINE COUNT only (Part A: the monolith "round-trips exactly 5000 lines"; Part D: 50 lines), and never reads the
# two 5-row chunks back at all. This runs the file, read from $TREE, against a copy of pgpm_archive whose NDJSON
# strategy writes "id":1 on every line in place of the row's id (count, rows_archived and digest unchanged): the
# archive no longer says which row is which, and the file stays green.
set -u
fail=0
HERE=$(cd "$(dirname "$0")" && pwd)
MUT=$(mktemp)
python3 "$HERE/mutate.py" "$TREE/pgpm_archive/install.sql" > "$MUT" || { echo "not ok - GUARD: the mutation applied"; exit 1; }
echo "ok - GUARD: the mutation applied to pgpm_archive/install.sql"
if [ "$($PSQL -At -c "select to_regproc('public.mk_archive_config') is null")" = "t" ]; then
  $PSQL -q -v ON_ERROR_STOP=1 -f - < "$TREE/tests/archive/fixtures.sql" > /dev/null 2>&1 || { echo "not ok - fixture: archive fixtures load"; exit 1; }
fi
$PSQL -q -v ON_ERROR_STOP=1 -f - < "$MUT" > /dev/null 2>&1 || { echo "not ok - fixture: the mutant archive module installs over the tree's"; exit 1; }
rm -f "$MUT"
$PSQL -q -c "create extension if not exists pgtap" > /dev/null 2>&1

OUT=$($PSQL -At -f - < "$TREE/tests/archive/db/08_archive_fn_s3_test.sql" 2>&1)
NOK=$(printf '%s\n' "$OUT" | grep -c '^not ok')
OK=$(printf '%s\n' "$OUT" | grep -c '^ok ')
PLAN=$(printf '%s\n' "$OUT" | grep -m1 '^1\.\.' | sed 's/^1\.\.//')

# LIVENESS (A): the monolith's object, fetched back, holds 5000 lines whose ids are not the monolith's ids
IDS=$($PSQL -At -c "select count(distinct l::jsonb ->> 'id') || '/' || count(*) from pgpm.archive_ledger a,
  regexp_split_to_table((archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', a.s3_key, '', 'text/plain', '', 'minioadmin', 'minioadmin')).content, e'\n') l
  where a.parent_table = 'public.a8'::regclass and a.lo = '0' and l <> ''")
if [ "$IDS" = "1/5000" ]; then echo "ok - LIVENESS: (A) the monolith's object holds 5000 lines naming ONE id between them, not ids 1..5000"
else echo "not ok - LIVENESS: (A) the monolith's object holds 5000 lines naming one id between them (got distinct/lines '$IDS')"; fail=1; fi
# LIVENESS (B): the test file ran to its end
if [ -n "$PLAN" ] && [ $((OK + NOK)) -eq "$PLAN" ]; then echo "ok - LIVENESS: (B) tests/archive/db/08 ran all $PLAN assertions"
else echo "not ok - LIVENESS: (B) tests/archive/db/08 ran all its assertions (plan '$PLAN', ran $((OK + NOK)))"; fail=1; fi

if [ "$NOK" -gt 0 ]; then echo "ok - tests/archive/db/08 fails against an NDJSON strategy that loses every row's id ($NOK not ok)"
else echo "not ok - tests/archive/db/08 stays green ($OK/$PLAN) against an NDJSON strategy that writes id 1 on every line: it reads the objects back by line count, not by which rows"; fail=1; fi
exit $fail
