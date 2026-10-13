#!/bin/bash
# F13-03 (Tier 5): tests/101_transmute_claim_test.sql passes against a transmute whose claim names NO owner.
#
# The file's header: "A fresh conversion records a claim naming THIS session as its owner." The only
# assertion about a real conversion's claim is that it is gone afterwards (assertion 5, count = 0), which a
# claim recorded with no owner at all satisfies just as well. A claim with no owner reads as a dead
# session's (tests/101 itself pins `_session_alive(null, ...)` false), so the reaper and transmute_abort
# would undo a conversion that is still running. The mutant below records the claim with owner_pid and
# owner_backend_start null and changes nothing else; tests/101, read from $TREE, stays green on it.
set -u
MUT="${DB}_m101"
ADMIN="docker exec -i $CONTAINER psql -X -q -At -U postgres -d postgres"
MPSQL="docker exec -i $CONTAINER psql -X -q -U postgres -d $MUT"
WORK=$(mktemp -d)
cleanup() { $ADMIN -c "drop database if exists \"$MUT\"" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
fail=0

# the mutant: the claim's owner columns written as null
python3 - "$TREE/pgpm_core/install.sql" "$WORK/install_mutant.sql" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = "values (p_parent, v_nsp, v_rel, p_control_kind, v_lo_native, v_hi_native, v_tz, v_ctl_attnum,\n          pg_backend_pid(), v_own_start)"
new = "values (p_parent, v_nsp, v_rel, p_control_kind, v_lo_native, v_hi_native, v_tz, v_ctl_attnum,\n          null, null)"
n = s.count(old)
open(sys.argv[2], 'w').write(s.replace(old, new))
print(n)
PY
$ADMIN -c "drop database if exists \"$MUT\"" >/dev/null 2>&1
$ADMIN -c "create database \"$MUT\"" >/dev/null
$MPSQL -v ON_ERROR_STOP=1 -f - < "$WORK/install_mutant.sql" >/dev/null 2>&1 || { echo "not ok - fixture: mutant install failed"; exit 1; }

if $MPSQL -At -c "select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgpm' and p.proname = '_transmute'" | grep -q "v_ctl_attnum,$" \
   && $MPSQL -At -c "select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgpm' and p.proname = '_transmute'" | grep -A1 "v_ctl_attnum,$" | grep -q "null, null)"; then
  echo "ok - LIVENESS: the installed mutant's _transmute records its claim with owner_pid and owner_backend_start null"
else
  echo "not ok - LIVENESS: the mutation did not apply"; exit 1
fi

# the consequence the header's promise exists for: under the mutant, a claim held by a conversion that is
# still running (its session alive, holding the claim mid-phase) reads as a dead session's
$MPSQL -c "create extension if not exists dblink" >/dev/null
$MPSQL -c "create table public.live101 (id bigint primary key); insert into public.live101 select generate_series(1, 5)" >/dev/null
# record the claim exactly as the mutant's insert does, from a live second session
st=$($MPSQL -At -c "
  select dblink_connect('c', 'dbname=$MUT');
  select dblink_exec('c', \$q\$insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, owner_pid, owner_backend_start)
                             values ('public.live101'::regclass, 'public', 'live101', 'id', '0', '10', null, null)\$q\$);
  select coalesce(pgpm._session_alive(owner_pid, owner_backend_start)::text, 'null') from pgpm.transmute_inflight where rel = 'live101';
  select dblink_disconnect('c');" 2>&1 | grep -E '^(true|false|null)$' | head -1)
[ "$st" = "false" ] && echo "ok - LIVENESS: a claim recorded that way reads as a dead session's, although the session that wrote it is alive" \
  || echo "not ok - LIVENESS: claim liveness probe gave '$st'"
# leave the mutant database as the test expects to find it: no claim, no probe table
$MPSQL -c "delete from pgpm.transmute_inflight; drop table public.live101" >/dev/null

# the test under review, unchanged, against the mutant
out=$(cd "$TREE/tests" && $MPSQL -v ON_ERROR_STOP=1 -f - < 101_transmute_claim_test.sql 2>&1)
nok=$(echo "$out" | grep -cE '^[[:space:]]*not ok [0-9]+')
oks=$(echo "$out" | grep -cE '^[[:space:]]*ok [0-9]+ ')
[ "$oks" -ge 10 ] && echo "ok - LIVENESS: tests/101 ran all its assertions against the mutant ($oks ok)" || echo "not ok - LIVENESS: tests/101 did not run ($oks ok)"
if [ "$nok" = "0" ]; then
  echo "not ok - tests/101 stays green against a transmute whose claim names no owner (its header promises the claim names THIS session)"
  fail=1
else
  echo "ok - tests/101 fails against the mutant ($nok not ok)"
fi
exit $fail
