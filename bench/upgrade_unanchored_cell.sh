#!/usr/bin/env bash
# upgrade_unanchored_cell.sh <container> <db> [install.sql]
#
# Guard issue #981 across a REAL upgrade: a forward cell dropped by hand on an install from before
# pgpm.part.child_oid (#421) is rebuilt by the first obtain after the upgrade, and a forward cell RENAMED by
# hand there does not take obtain down. Run by CI (`./test.sh perf`, and `./test.sh discriminate` proves it
# catches its defects).
#
# THE DEFECT. The upgrade backfills child_oid through pg_inherits, by name. A cell dropped before the
# upgrade has no partition to resolve, so its row stays attached with a null child_oid, and the predicate
# that judges a row built (#908) read a null child_oid as present: obtain and extend_to never rebuilt the
# cell, nothing was logged, and forget_missing (which only clears rows whose PARENT is gone) never reached
# it. Every write into the range was refused, for good. tests/278 makes the same state by hand on a
# current install; this guard is the claim that the state is reachable and handled on the upgrade path
# that produces it.
#
# THE ORIGIN. v0.5.0 is the newest release whose install.sql has no pgpm.part.child_oid. Its install.sql IS
# the released artifact for the psql channel, so `git show v0.5.0:pgpm_core/install.sql` is the origin, fed
# to psql on stdin (the shape of bench/upgrade_from_release.sh, which fetches a missing tag the same way).
#
# WHAT IT ASSERTS:
#   0. PRECONDITION, loud: the origin artifact was obtained and installs, and has no child_oid column. A
#      guard that skipped here would be green having upgraded nothing.
#   1. LIVENESS: on the origin, the forward cell [2000, 3000) of ug_drop and [3000, 4000) of ug_ren were
#      built and accepted a write. After the hand DROP and RENAME and the upgrade, both rows are attached
#      with a null child_oid (the backfill could resolve neither), every other row was anchored, the dropped
#      partition is gone and the renamed one still holds its range.
#   2. ug_drop: one obtain forgets exactly the unanchored row (forget_dropped_partition, exact action, for
#      [2000, 3000) alone), rebuilds the cell, and the rebuilt row anchors, by oid, the partition whose
#      bound is [2000, 3000). A write into the range is accepted.
#   3. ug_ren: obtain completes, forgets nothing, and a write into [3000, 4000) lands in the renamed
#      partition, by identity. The positive half of 2 is what keeps this negative honest: the same obtain
#      code forgets an unanchored row when its relation cannot exist.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   unanchored_row_reads_built -- a null child_oid reads as built: the pre-fix shape. Assertion 2.
#   unanchored_row_reads_gone  -- a null child_oid reads as gone whatever the table holds: the renamed cell's
#                                 row is forgotten and obtain dies on the overlap. Assertion 3.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results"        # gitignored
ORIGIN_TAG="v0.5.0"
ORIGIN_PATH="pgpm_core/install.sql"
ORIGIN_SQL="$OUT/origin-$ORIGIN_TAG-unanchored.sql"
fail=0

q() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" psql -U postgres -d "$DB" -qtA -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
cleanup() { docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------- precondition: the origin
mkdir -p "$OUT"
if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$ORIGIN_TAG^{commit}" >/dev/null 2>&1; then
  echo "      tag $ORIGIN_TAG is not in this checkout (CI checks out shallow and without tags); fetching it"
  if ! out=$(git -C "$ROOT" fetch --no-tags --depth=1 origin tag "$ORIGIN_TAG" 2>&1); then
    echo "FAIL  fixture: could not fetch tag $ORIGIN_TAG; without the origin artifact this guard verifies nothing"
    printf '%s\n' "$out" | sed 's/^/      /'; exit 1
  fi
fi
if ! git -C "$ROOT" show "$ORIGIN_TAG:$ORIGIN_PATH" > "$ORIGIN_SQL" 2>/dev/null || [ ! -s "$ORIGIN_SQL" ]; then
  echo "FAIL  fixture: git show $ORIGIN_TAG:$ORIGIN_PATH produced nothing; without the origin artifact this guard verifies nothing"
  exit 1
fi

cleanup
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$C" \
       psql -U postgres -q -d "$DB" -v ON_ERROR_STOP=1 -f - < "$ORIGIN_SQL" >/dev/null 2>&1; then
  echo "FAIL  fixture: the $ORIGIN_TAG origin did not install"; cleanup; exit 1
fi
check "LIVENESS: the origin has no pgpm.part.child_oid" \
  "$(q "select count(*) from information_schema.columns where table_schema = 'pgpm' and table_name = 'part' and column_name = 'child_oid'")" "0"

# ---------------------------------------------------------------------------- on the origin
for t in ug_drop ug_ren; do
  q "create table public.$t (id bigint primary key, body text)" >/dev/null
  q "insert into public.$t select g, 'x' from generate_series(1, 500) g" >/dev/null
  q "call pgpm.transmute('public.$t', 'id', 1000::bigint, 4, p_paused => false)" >/dev/null
done
DROPPED=$(q "select child_name from pgpm.part where parent_table = 'public.ug_drop'::regclass and lo = '2000'")
RENAMED=$(q "select child_name from pgpm.part where parent_table = 'public.ug_ren'::regclass and lo = '3000'")
check "LIVENESS: the origin built [2000, 3000) and accepts a write into it" \
  "$(q "begin; insert into public.ug_drop values (2400, 'pre'); rollback;" | grep -c '^ERROR')/${DROPPED:+named}" "0/named"
check "LIVENESS: the origin built [3000, 4000) and accepts a write into it" \
  "$(q "begin; insert into public.ug_ren values (3400, 'pre'); rollback;" | grep -c '^ERROR')/${RENAMED:+named}" "0/named"
REN_OID=$(q "select 'public.$RENAMED'::regclass::oid")
q "drop table public.$DROPPED" >/dev/null
q "alter table public.$RENAMED rename to ug_ren_kept" >/dev/null

# ---------------------------------------------------------------------------- the upgrade
if ! docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
       psql -U postgres -q -d "$DB" -v ON_ERROR_STOP=1 -f "$INSTALL" >/tmp/upgrade_unanchored_cell.log 2>&1; then
  echo "FAIL  the upgrade (install.sql over $ORIGIN_TAG) did not complete"
  sed 's/^/      /' /tmp/upgrade_unanchored_cell.log | head -5; cleanup; exit 1
fi

check "LIVENESS: both rows survive the upgrade attached and unanchored" \
  "$(q "select string_agg(parent_table::text || ':' || lo || ':' || attached::text, ',' order by parent_table::text)
          from pgpm.part where child_oid is null")" "ug_drop:2000:true,ug_ren:3000:true"
check "LIVENESS: every other row was anchored by the backfill" \
  "$(q "select count(*) from pgpm.part where parent_table in ('public.ug_drop'::regclass, 'public.ug_ren'::regclass)
          and child_oid is null and lo not in ('2000', '3000')")" "0"
check "LIVENESS: the dropped partition is gone" "$(q "select to_regclass('public.$DROPPED') is null")" "t"
check "LIVENESS: the renamed partition still holds [3000, 4000)" \
  "$(q "select count(*) from pg_inherits where inhparent = 'public.ug_ren'::regclass and inhrelid = $REN_OID")" "1"

MARK=$(q "select coalesce(max(id), 0) from pgpm.log")

# ---------------------------------------------------------------------------- 2. the dropped cell
q "select pgpm.obtain('public.ug_drop')" >/dev/null
check "obtain forgot exactly the unanchored row of the dropped cell" \
  "$(q "select coalesce(string_agg(lo || '-' || hi, ',' order by lo::numeric), 'none') from pgpm.log
          where parent_table = 'public.ug_drop'::regclass and action = 'forget_dropped_partition' and id > $MARK")" "2000-3000"
check "the rebuilt row anchors the partition bounded [2000, 3000)" \
  "$(q "select count(*) from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid and i.inhparent = 'public.ug_drop'::regclass
          join pg_class c on c.oid = p.child_oid
         where p.parent_table = 'public.ug_drop'::regclass and p.lo = '2000' and p.attached
           and pg_get_expr(c.relpartbound, c.oid) = 'FOR VALUES FROM (''2000'') TO (''3000'')'")" "1"
check "a write into [2000, 3000) is accepted" \
  "$(q "insert into public.ug_drop values (2500, 'after')" | grep -c '^ERROR')" "0"

# ---------------------------------------------------------------------------- 3. the renamed cell
check "obtain completes over the renamed cell" \
  "$(q "select pgpm.obtain('public.ug_ren')" | grep -c '^ERROR')" "0"
check "obtain forgot nothing of the renamed cell's table" \
  "$(q "select count(*) from pgpm.log where parent_table = 'public.ug_ren'::regclass
          and action in ('forget_dropped_partition', 'forget_detached_partition') and id > $MARK")" "0"
q "insert into public.ug_ren values (3500, 'after')" >/dev/null
check "a write into [3000, 4000) lands in the renamed partition" \
  "$(q "select tableoid::oid = $REN_OID from public.ug_ren where id = 3500")" "t"

cleanup
exit "$fail"
