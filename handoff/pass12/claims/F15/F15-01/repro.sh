#!/usr/bin/env bash
# F15-01: tests/72 stays green against a transmute that replays the table's row-level-security policy
# TO PUBLIC instead of to the roles it names.
#
# tests/72's header says every assertion is behavioural, "what a role can SEE when it queries the parent".
# It only ever asks the role the policy names (t72_reader, 400 rows of tenant 1). It never asks a role the
# policy does NOT name, so a policy widened to PUBLIC on the new parent (every other role, t72_writer
# included, now reads tenant 1's rows where it read none) passes all fifteen assertions. The fixture is also
# symmetric (2000 rows over 5 tenants, 400 each), so the one count it takes cannot tell tenant 1 from another.
#
# The mutant: the first policy-replay site in pgpm_core/install.sql (transmute's capture of the policies)
# renders every policy's roles as `public`. Built from $TREE's own install.sql, installed into a database of
# this script's own, tests/72 read from $TREE and run there. Present: tests/72 reports no `not ok` against the
# mutant. Absent (tests/72 asserts what a role outside the policy sees): it fails there.
set -u
C="${CONTAINER:-pgpm_test-15}"
MDB="${DB}_f15m72"
WORK="$(mktemp -d)"
trap 'docker exec "$C" psql -U postgres -qc "drop database if exists $MDB" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
fail=0

perl -0pe "s/case when polroles = '\{0\}'::oid\[\] then 'public'/case when true then 'public'/" \
  "$TREE/pgpm_core/install.sql" > "$WORK/mutant.sql"
nd=$(diff "$TREE/pgpm_core/install.sql" "$WORK/mutant.sql" | grep -c '^>')
if [ "$nd" = "1" ]; then echo "ok - GUARD: the mutant differs from the tree's install.sql in exactly one line (the roles of the first policy replay)";
else echo "not ok - GUARD: the mutation did not apply as one line (changed lines: $nd)"; exit 1; fi

docker exec "$C" psql -U postgres -qc "drop database if exists $MDB" -c "create database $MDB" >/dev/null 2>&1
if docker exec -i "$C" psql -U postgres -d "$MDB" -q -v ON_ERROR_STOP=1 -f - < "$WORK/mutant.sql" >/dev/null 2>&1; then
  echo "ok - fixture: the mutant installs"
else echo "not ok - fixture: the mutant did not install"; exit 1; fi

out=$(docker exec -i "$C" psql -U postgres -d "$MDB" -tAq -f - < "$TREE/tests/72_transmute_attributes_test.sql" 2>&1)
nok=$(printf '%s\n' "$out" | grep -c '^ok ')
nnot=$(printf '%s\n' "$out" | grep -c '^not ok')
if [ "$nok" -ge 10 ]; then echo "ok - LIVENESS: tests/72 ran against the mutant ($nok ok, $nnot not ok)";
else echo "not ok - LIVENESS: tests/72 did not run against the mutant ($nok ok)"; printf '%s\n' "$out" | tail -5; exit 1; fi

# the mutant really widens the policy: on the parent tests/72 converted, the policy is TO PUBLIC, and
# t72_writer, which the policy does not name, reads tenant 1's rows
roles=$(docker exec "$C" psql -U postgres -d "$MDB" -tAc "select polroles::regrole[]::text from pg_policy where polrelid = 'public.ev72'::regclass and polname = 'tenant_iso'")
wsees=$(docker exec "$C" psql -U postgres -d "$MDB" -tA -c "set role t72_writer" -c "select string_agg(distinct tenant::text, ',') || ':' || count(*) from public.ev72" | tail -1)
if [ "$roles" = "{-}" ] && [ "$wsees" = "1:402" ]; then
  echo "ok - LIVENESS: under the mutant the parent's tenant_iso policy is TO PUBLIC ($roles) and t72_writer, which it does not name, reads tenant 1's 402 rows"
else
  echo "not ok - LIVENESS: the mutant did not widen the policy (roles $roles, t72_writer reads $wsees)"; exit 1
fi

if [ "$nnot" -eq 0 ]; then
  echo "not ok - tests/72 passes all its assertions against a transmute that replays tenant_iso TO PUBLIC (t72_writer reads tenant 1's rows where the table it converted showed it none)"
  fail=1
else
  echo "ok - tests/72 fails against the mutant ($nnot not ok)"
fi
exit $fail
