#!/usr/bin/env bash
# Guard the regrain swap against validating an outgoing foreign key by scanning a copy under its lock
# (issue #898). Run by CI (`./test.sh perf`).
#
# THE BAR. regrain_step gives each copy its own validated copy of every outgoing foreign key the parent has
# while the copy is still empty (#348), so that the swap's ATTACH PARTITION adopts the key instead of
# validating it, and docs/reference.md promises the swap never validates one under its lock. The drift check
# (_regrain_shape_drift) compared columns and CHECKs only, so a key added to the parent after a copy was made
# was not drift: the copy reached the swap without it, and ATTACH cloned the key onto it and validated it by
# scanning the copy while the swap's DETACH held ACCESS EXCLUSIVE on the parent, for a duration that grows
# with the partition. The fix makes such a key drift: the run restarts and every copy is made again, born with
# the key, so the swap adopts it.
#
# THE INSTRUMENT. pg_stat_all_tables.seq_scan of every copy the swap attaches, sampled before and after the
# swap tick from separate sessions. Counters flush at transaction end, and on PostgreSQL 15+ the flush after
# a commit is not immediate, so every tick runs in a session that ends with pg_stat_force_next_flush() and one
# more statement (the shape of bench/untransmute_fk_validate_lock.sh). A copy has no index on the key's
# column, so validating the key can only seq-scan it. The issue's reproduction measured the same counter on
# the copy made BEFORE the key, by oid; the fix discards that copy, so this guard measures every copy the swap
# actually attaches, and asserts that the one over [0, 50) is not the copy made before the key.
#
# LIVENESS, paired with each negative:
#   - the copy over [0, 50) was made, and filled, before the parent had the key (the defect's precondition);
#   - the measured tick is the swap: no copy_swap_drop before it, exactly one after, and every copy measured
#     is attached after it, by oid;
#   - the instrument sees a scan of a copy at all: after the swap, one count(*) over the [0, 50) child moves
#     its seq_scan by exactly one through the same sampling. An instrument that could not see it would read
#     "no scan" on broken code too.
#
# The mutation it is required to fail against (bench/mutations/mutate.py): regrain_fk_drift_ignored, which
# takes the outgoing keys out of _regrain_shape_drift's comparison, the pre-#898 shape.
#
# Usage: regrain_fk_drift_swap_scan.sh <container> <db> [install.sql]
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -X -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-78s %s\n' "$1" "$2"
  else printf 'FAIL  %-78s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
# Run SQL in a session that forces its statistics out before it exits (see the header).
flushed() { docker exec "$C" psql -U postgres -d "$DB" -X -qtA -c "$1" \
              -c "select pg_stat_force_next_flush()" -c "select 1" >/dev/null 2>&1; }
# "<oid>:<seq_scan>" for each copy in a space-separated oid list, in that order, from a fresh session.
scans() { q "select string_agg(t.relid::oid || ':' || t.seq_scan, ' ' order by o.ord)
               from unnest('{$1}'::oid[]) with ordinality o(oid, ord)
               join pg_stat_all_tables t on t.relid = o.oid"; }
swaps() { q "select count(*) from pgpm.log where parent_table = 'public.rgf898'::regclass
               and action = 'regrain' and method = 'copy_swap_drop'"; }

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-78s %s\n' "the module under test installed" "$INSTALL"; exit 1
fi

q "create table public.ref898 (id int primary key); insert into public.ref898 select generate_series(1, 300)" >/dev/null
q "create table public.rgf898 (id bigint primary key, ref_id int, note text)" >/dev/null
q "insert into public.rgf898 select g, g, 'old' || g from generate_series(1, 200) g" >/dev/null
q "call pgpm.transmute('public.rgf898', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false)" >/dev/null 2>&1
q "select pgpm.obtain('public.rgf898')" >/dev/null 2>&1
q "insert into public.rgf898 values (450, null, 'frontier')" >/dev/null
q "select pgpm.set_regrain('public.rgf898', '50')" >/dev/null 2>&1
flushed "call pgpm.maintain('public.rgf898')"   # prepare
flushed "call pgpm.maintain('public.rgf898')"   # copy [0, 50)
c0=$(q "select child_oid from pgpm.part where parent_table = 'public.rgf898'::regclass
         and not attached and lo = '0' and hi = '50'")
check "LIVENESS: the copy over [0, 50) was made and filled, with no foreign key" \
  "$(q "select count(*) from pgpm.log where parent_table = 'public.rgf898'::regclass and action = 'regrain_copy'
          and lo = '0' and hi = '50' and rows = 49")/$( [ -n "$c0" ] && q "select count(*) from pg_constraint
          where conrelid = $c0 and contype = 'f'")" "1/0"

q "alter table public.rgf898 add constraint rgf898_ref_fk foreign key (ref_id) references public.ref898 (id)" >/dev/null

# Tick until every sub-range has been copied (the cursor at the source's end), so the next tick is the swap.
for _ in $(seq 1 20); do
  [ "$(q "select regrain_cursor from pgpm.config where parent_table = 'public.rgf898'::regclass")" = 300 ] && break
  flushed "call pgpm.maintain('public.rgf898')"
done
copies=$(q "select string_agg(child_oid::text, ',' order by lo::numeric) from pgpm.part
             where parent_table = 'public.rgf898'::regclass and not attached")
first=$(q "select child_oid from pgpm.part where parent_table = 'public.rgf898'::regclass
            and not attached and lo = '0' and hi = '50'")
check "LIVENESS: the run reached the swap with its copies made (cursor at the end, 6 copies)" \
  "$(q "select regrain_cursor from pgpm.config where parent_table = 'public.rgf898'::regclass")/$(q "select count(*)
      from pgpm.part where parent_table = 'public.rgf898'::regclass and not attached")" "300/6"
check "LIVENESS: no swap has happened before the measured tick" "$(swaps)" "0"

before=$(scans "$copies")
flushed "call pgpm.maintain('public.rgf898')"   # the swap
after=$(scans "$copies")

check "LIVENESS: the measured tick is the swap (copy_swap_drop logged once)" "$(swaps)" "1"
check "LIVENESS: every copy measured is attached after it, by oid" \
  "$(q "select count(*) filter (where relispartition) || '/' || count(*) from pg_class
          where oid = any('{$copies}'::oid[])")" "6/6"
check "LIVENESS: every copy measured was sampled on both sides of the swap" \
  "$(wc -w <<<"$before" | tr -d ' ')/$(wc -w <<<"$after" | tr -d ' ')" "6/6"
check "the copy the swap attached over [0, 50) is not the one made before the key" \
  "$([ -n "$first" ] && [ "$first" != "$c0" ] && echo true || echo false)" "true"
check "the swap scanned no copy to validate the foreign key added mid-regrain (oid:seq_scan)" "$after" "$before"
check "every child the swap attached carries the parent's key as a clone of it" \
  "$(q "select count(*) from pg_constraint k join pg_constraint p on p.oid = k.conparentid
          where k.conrelid = any('{$copies}'::oid[]) and k.contype = 'f' and p.conrelid = 'public.rgf898'::regclass
            and p.conname = 'rgf898_ref_fk'")" "6"

# LIVENESS for the instrument: a scan of the [0, 50) child through the same sampling moves its counter by one.
if [ -n "$first" ]; then
  s_a=$(q "select seq_scan from pg_stat_all_tables where relid = $first")
  flushed "select count(*) from only $(q "select $first::regclass")"
  s_b=$(q "select seq_scan from pg_stat_all_tables where relid = $first")
  check "LIVENESS: the instrument sees one scan of the [0, 50) child (seq_scan delta)" \
    "$(( ${s_b:-0} - ${s_a:-0} ))" "1"
else
  check "LIVENESS: the instrument sees one scan of the [0, 50) child (seq_scan delta)" "no child" "1"
fi

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
