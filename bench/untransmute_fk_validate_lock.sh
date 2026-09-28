#!/usr/bin/env bash
# Guard untransmute against scanning a REFERENCING table under its ACCESS EXCLUSIVE (issue #577). Run by
# CI (`./test.sh perf`).
#
# THE BAR (issue #263's rule): a blocking lock may last milliseconds, but never a duration coupled to data
# size. untransmute is a function, so it is one transaction, and from its second gate on it holds ACCESS
# EXCLUSIVE on the parent, which becomes the restored table. It used to re-add each preserved incoming FK
# NOT VALID and then VALIDATE it in that same transaction: a full scan of the referencing table, every
# reader and writer of the restored table queued behind it, in what docs/reference.md calls a
# metadata-only reverse. The fix re-adds the key NOT VALID and leaves the VALIDATE to the operator, in a
# later transaction that blocks neither table.
#
# WHY NOT A POLLING PROBE. The issue's reproduction watches pg_locks from a second session, one sample per
# transaction, for the SHARE UPDATE EXCLUSIVE that only VALIDATE CONSTRAINT takes on the referencing
# table, and it works, but its verdict rides on catching a window. Two instruments here need no window at
# all, which is the repo's standing preference (a structural lever over a poll-then-race):
#
#   LOCKS HELD AT THE END OF THE CALL. The reverse runs inside an explicit transaction, and the session
#   reads its own pg_locks before COMMIT. Locks are held to transaction end, so the SHARE UPDATE EXCLUSIVE
#   on the referencing table is there exactly when a VALIDATE ran, and the ACCESS EXCLUSIVE on the restored
#   table beside it is what makes that "under the lock". No timing: the state persists until we look.
#
#   SCAN COUNTERS ACROSS THE CALL. pg_stat_all_tables for the referencing table, sampled before and after
#   from separate sessions. Counters flush at transaction end, and on PostgreSQL 15+ the flush after a
#   commit is not immediate, so the reverse's session ends with pg_stat_force_next_flush() and one more
#   statement: the flush lands when that session next goes idle, before the sample that follows it. The
#   referencing table has autovacuum off and a fresh VACUUM ANALYZE, so nothing else scans it in between.
#
# LIVENESS, paired with each negative:
#   - the counters see a VALIDATE at all: validate_incoming_fks, run before the reverse through the same
#     sampling, must move items' seq_tup_read by at least its row count. An instrument that could not see
#     that scan would report 0 for the reverse on broken code too.
#   - the reverse really held ACCESS EXCLUSIVE on the restored table, and really re-added the key in the
#     same transaction (the ADD's SHARE ROW EXCLUSIVE on items), before the "no SHARE UPDATE EXCLUSIVE".
#   - the key is back afterwards, by name, against the restored table.
#
# The mutation it is required to fail against (bench/mutations/mutate.py): untransmute_inline_validate,
# which puts the VALIDATE back after the NOT VALID re-add.
#
# Usage: untransmute_fk_validate_lock.sh <container> <db> [install.sql]
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
REF_ROWS=${REF_ROWS:-500000}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-72s %s\n' "$1" "$2"
  else printf 'FAIL  %-72s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
# One read of items' counters, from a fresh session: "<scans> <tuples read>".
counters() { q "select seq_scan + coalesce(idx_scan, 0), seq_tup_read + coalesce(idx_tup_fetch, 0)
                  from pg_stat_all_tables where relid = 'public.items'::regclass" | tr '|' ' '; }
# Run SQL in a session that forces its statistics out before it exits (see the header).
flushed() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1" \
              -c "select pg_stat_force_next_flush()" -c "select 1" >/dev/null; }

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-72s %s\n' "the module under test installed" "$INSTALL"; exit 1
fi

q "create table public.ev (id bigint primary key, body text)" >/dev/null
q "insert into public.ev select g, 'row ' || g from generate_series(1, 50) g" >/dev/null
q "create table public.items (id int primary key, ev_id bigint references public.ev (id))
     with (autovacuum_enabled = off)" >/dev/null
q "insert into public.items select g, 1 + g % 50 from generate_series(1, $REF_ROWS) g" >/dev/null
q "vacuum analyze public.items" >/dev/null
q "call pgpm.transmute('public.ev', 'id', 100::bigint, p_incoming_fks => 'preserve', p_paused => false)" >/dev/null
q "select pgpm.restore_incoming_fks('public.ev')" >/dev/null

# LIVENESS for the counters: they see a VALIDATE of items.
read -r s_a t_a <<<"$(counters)"
flushed "select pgpm.validate_incoming_fks('public.ev')"
read -r s_b t_b <<<"$(counters)"
check "LIVENESS: the counters see a VALIDATE's scan of items (tuples read >= $REF_ROWS)" \
  "$([ $((t_b - t_a)) -ge "$REF_ROWS" ] && echo true || echo false)" "true"
check "LIVENESS: the key is recorded restored and validated before the reverse" \
  "$(q "select restored_at is not null and validated_at is not null from pgpm.dropped_fk
         where parent_table = 'public.ev'::regclass and constraint_name = 'items_ev_id_fkey'")" "t"

# The reverse, in an explicit transaction that reads its own locks before COMMIT.
out=$(docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "begin" \
  -c "select 'ms=' || round(extract(epoch from clock_timestamp()) * 1000)" \
  -c "select 'ret=' || pgpm.untransmute('public.ev')::text" \
  -c "select 'ms=' || round(extract(epoch from clock_timestamp()) * 1000)" \
  -c "select 'ae=' || exists (select 1 from pg_locks where pid = pg_backend_pid() and locktype = 'relation'
               and relation = 'public.ev'::regclass and mode = 'AccessExclusiveLock' and granted)::text" \
  -c "select 'sre=' || exists (select 1 from pg_locks where pid = pg_backend_pid() and locktype = 'relation'
               and relation = 'public.items'::regclass and mode = 'ShareRowExclusiveLock' and granted)::text" \
  -c "select 'sue=' || exists (select 1 from pg_locks where pid = pg_backend_pid() and locktype = 'relation'
               and relation = 'public.items'::regclass and mode = 'ShareUpdateExclusiveLock')::text" \
  -c "commit" \
  -c "select pg_stat_force_next_flush()" -c "select 1" 2>&1)
field() { echo "$out" | sed -n "s/^$1=//p" | head -1; }
read -r s_c t_c <<<"$(counters)"
ms=$(echo "$out" | sed -n 's/^ms=//p' | tr '\n' ' ')
printf '      (the reverse took %s ms; items read by it: %s scan(s), %s tuple(s))\n' \
  "$(set -- $ms; echo $(( ${2:-0} - ${1:-0} )))" "$((s_c - s_b))" "$((t_c - t_b))"

check "LIVENESS: untransmute returned the restored table"                     "$(field ret)" "ev"
check "LIVENESS: its transaction held ACCESS EXCLUSIVE on the restored table"  "$(field ae)"  "true"
check "LIVENESS: and re-added the key on items in it (SHARE ROW EXCLUSIVE)"    "$(field sre)" "true"
check "no VALIDATE of items under that lock (no SHARE UPDATE EXCLUSIVE on it)" "$(field sue)" "false"
check "the reverse read no row of the referencing table"                      "$((t_c - t_b))" "0"
check "LIVENESS: items_ev_id_fkey is back against the restored ev" \
  "$(q "select confrelid::regclass::text from pg_constraint
         where conrelid = 'public.items'::regclass and conname = 'items_ev_id_fkey' and contype = 'f'")" "ev"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
