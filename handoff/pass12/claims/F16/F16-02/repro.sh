#!/bin/bash
# F16-02: tests/archive/db/16_archive_object_key_identity_test.sql (Part B) asserts the Parquet object at the
# [-10000, 0) key by SIZE only (neg_bytes > pos_bytes), though its header says the fixture is asymmetric "so a
# clobbered object cannot pass an identity check". This runs the file, read from $TREE, against a copy of
# pgpm_archive whose Parquet strategy encodes only the top 5% of the chunk's range (here 500 of the chunk's
# 1000 rows): the object at the key is then not the chunk's file, rows -1000..-501 are in no object, and the
# file stays green, because a 500-row file is still larger than the 10-row one.
set -u
fail=0
MUT=$(mktemp)
sed 's/from archive._pq_to_parquet_range_counted(p_parent, pcfg.control_column, v_lo_lit, v_hi_lit, p_compress) c;/from archive._pq_to_parquet_range_counted(p_parent, pcfg.control_column, (v_lo_lit::numeric + (v_hi_lit::numeric - v_lo_lit::numeric) * 0.95)::bigint::text, v_hi_lit, p_compress) c;/' \
  "$TREE/pgpm_archive/install.sql" > "$MUT"
if cmp -s "$MUT" "$TREE/pgpm_archive/install.sql"; then echo "not ok - GUARD: the mutation applied to pgpm_archive/install.sql"; exit 1; fi
echo "ok - GUARD: the mutation applied to pgpm_archive/install.sql"

# the archive track's fixtures (the vault stub, mk_archive_config), unless the harness already loaded them
if [ "$($PSQL -At -c "select to_regproc('public.mk_archive_config') is null")" = "t" ]; then
  $PSQL -q -v ON_ERROR_STOP=1 -f - < "$TREE/tests/archive/fixtures.sql" > /dev/null 2>&1 || { echo "not ok - fixture: archive fixtures load"; exit 1; }
fi
$PSQL -q -v ON_ERROR_STOP=1 -f - < "$MUT" > /dev/null 2>&1 || { echo "not ok - fixture: the mutant archive module installs over the tree's"; exit 1; }
rm -f "$MUT"
$PSQL -q -c "create extension if not exists pgtap" > /dev/null 2>&1

OUT=$($PSQL -At -f - < "$TREE/tests/archive/db/16_archive_object_key_identity_test.sql" 2>&1)
NOK=$(printf '%s\n' "$OUT" | grep -c '^not ok')
OK=$(printf '%s\n' "$OUT" | grep -c '^ok ')
PLAN=$(printf '%s\n' "$OUT" | grep -m1 '^1\.\.' | sed 's/^1\.\.//')

# LIVENESS (A): the mutant really lost rows: the ledger row of [-10000, 0) records fewer rows than the chunk held,
# and the object at its key is not the chunk's file.
LEDGER=$($PSQL -At -c "select rows_archived from pgpm.archive_ledger where parent_table = 'public.negkp'::regclass and lo = '-10000'")
if [ "$LEDGER" = "500" ]; then echo "ok - LIVENESS: (A) the mutant's Parquet strategy archived 500 of the chunk's 1000 rows ([-10000, 0) holds ids -1000..-1)"
else echo "not ok - LIVENESS: (A) the mutant's Parquet strategy archived 500 of the chunk's 1000 rows (got '$LEDGER')"; fail=1; fi
SAME=$($PSQL -At -c "select text_to_bytea((archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', s3_key, '', 'text/plain', '', 'minioadmin', 'minioadmin')).content) = archive._pq_to_parquet_range('public.negkp', 'id', '-10000', '0', false) from pgpm.archive_ledger where parent_table = 'public.negkp'::regclass and lo = '-10000'")
if [ "$SAME" = "f" ]; then echo "ok - LIVENESS: (A) the object at the [-10000, 0) key is not the Parquet file of the chunk's rows"
else echo "not ok - LIVENESS: (A) the object at the [-10000, 0) key is not the Parquet file of the chunk's rows (got '$SAME')"; fail=1; fi
# LIVENESS (B): the test file ran to its end
if [ -n "$PLAN" ] && [ $((OK + NOK)) -eq "$PLAN" ]; then echo "ok - LIVENESS: (B) tests/archive/db/16 ran all $PLAN assertions"
else echo "not ok - LIVENESS: (B) tests/archive/db/16 ran all its assertions (plan '$PLAN', ran $((OK + NOK)))"; fail=1; fi

# the defect: the file must fail against a Parquet strategy that uploaded the wrong rows under the chunk's key
if [ "$NOK" -gt 0 ]; then echo "ok - tests/archive/db/16 fails against a Parquet strategy that archived half the chunk ($NOK not ok)"
else echo "not ok - tests/archive/db/16 stays green ($OK/$PLAN) against a Parquet strategy that archived half the chunk: its Parquet half compares object sizes, not the chunk's file"; fail=1; fi
exit $fail
