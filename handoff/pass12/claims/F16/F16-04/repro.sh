#!/bin/bash
# F16-04: tests/archive/db/44_archive_extension_resolution_test.sql Part B says the objects the ticks write under
# `search_path = app` are "read back by identity under the default one", but its two Parquet tick objects are
# only checked to begin with PAR1. This runs the file, read from $TREE, against a copy of pgpm_archive whose
# Parquet strategy PUTs only those four bytes (the ledger still records every row): the file stays green.
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

OUT=$($PSQL -At -f - < "$TREE/tests/archive/db/44_archive_extension_resolution_test.sql" 2>&1)
NOK=$(printf '%s\n' "$OUT" | grep -c '^not ok')
OK=$(printf '%s\n' "$OUT" | grep -c '^ok ')
PLAN=$(printf '%s\n' "$OUT" | grep -m1 '^1\.\.' | sed 's/^1\.\.//')

# LIVENESS (A): the p44 objects the ticks wrote are four bytes each while the ledger records 1200 and 5 rows
GOT=$($PSQL -At -c "select string_agg(a.rows_archived || ':' || octet_length(text_to_bytea((archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', a.s3_key, '', 'text/plain', '', 'minioadmin', 'minioadmin')).content)), ',' order by a.lo::numeric)
  from pgpm.archive_ledger a where a.parent_table = 'public.p44'::regclass")
if [ "$GOT" = "1200:4,5:4" ]; then echo "ok - LIVENESS: (A) the ledger records 1200 and 5 rows for p44's chunks, and each object at their keys is 4 bytes"
else echo "not ok - LIVENESS: (A) the p44 objects are 4 bytes against 1200 and 5 rows ledgered (got '$GOT')"; fail=1; fi
if [ -n "$PLAN" ] && [ $((OK + NOK)) -eq "$PLAN" ]; then echo "ok - LIVENESS: (B) tests/archive/db/44 ran all $PLAN assertions"
else echo "not ok - LIVENESS: (B) tests/archive/db/44 ran all its assertions (plan '$PLAN', ran $((OK + NOK)))"; fail=1; fi

if [ "$NOK" -gt 0 ]; then echo "ok - tests/archive/db/44 fails against a Parquet strategy that uploads only PAR1 ($NOK not ok)"
else echo "not ok - tests/archive/db/44 stays green ($OK/$PLAN) against a Parquet strategy that uploads only the magic PAR1 for 1205 ledgered rows: its Parquet tick objects are checked by prefix, not by identity"; fail=1; fi
exit $fail
