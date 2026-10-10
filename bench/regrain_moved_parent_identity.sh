#!/usr/bin/env bash
# regrain_moved_parent_identity.sh <container> <db> [install.sql]
#
# Guard the regrain family's resolution of its two relations after ALTER TABLE <parent> SET SCHEMA
# (issues #768 F3-04 and F3-12, #555 F3-11). The parent moves, its partitions and the regrain's delta stay
# where they were, and pgpm tracks the parent by oid; every regrain site used to look the source and the
# delta up as <the parent's CURRENT schema>.<name>, so after the move auto-regrain failed every tick, a
# cancel emptied an unrelated same-named table and left the real delta full, and re-running install.sql
# no longer found an in-flight source to put its TRUNCATE guard back on. The fix resolves the source by
# pgpm.part.child_oid (pgpm._regrain_child_rel) and the delta by pgpm.config.regrain_delta_oid (the schema
# _regrain_capture_names returns), each in its own schema.
#
# TWO HALVES:
#   1. tests/237_regrain_moved_parent_identity_test.sql, run against the install under test: a regrain
#      moved mid-flight and one moved before it began run to the swap with their writes intact, and
#      regrain_cancel, the janitor and retire's reclaim reach the source and the delta where they are,
#      leaving an unrelated <parent>_pgpm_regrain_delta in the new schema alone. Its LIVENESS lines prove
#      each fixture reached the state.
#   2. The #650 upgrade block (F3-12), which a pgTAP file cannot reach because it lives in install.sql
#      itself: an in-flight source whose parent was moved, its TRUNCATE guard dropped by hand, gets the
#      guard back when install.sql is re-run, and on nothing else. LIVENESS first: the regrain is in flight
#      (capture on the source, cursor set) and the source really has no guard.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each one site of the class put
# back to the parent's schema:
#   regrain_step_source_parent_schema    -- regrain_step reads the source in the parent's schema (half 1, A, B)
#   regrain_cancel_delta_parent_schema   -- regrain_cancel truncates the delta in the parent's schema (half 1, C)
#   regrain_upgrade_guard_parent_schema  -- the #650 upgrade block joins the source by name in the parent's
#                                           schema (half 2)
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/237_regrain_moved_parent_identity_test.sql}"
SRC=ug_p0000000000000000000_to_0000000000000000300
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }
v() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-62s %s\n' "$1" "$2"
  else printf 'FAIL  %-62s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-62s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  # ---- half 1: the pgTAP file
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-62s %s\n' "a moved parent's regrain finds its source and delta" "$ran ran"
  else printf 'FAIL  %-62s %s\n' "a moved parent's regrain finds its source and delta" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-62s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi

  # ---- half 2: the #650 upgrade block
  if ! docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$C" psql -U postgres -d "$DB" -qtA \
         -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 <<'SQL'
create schema ugh;
create table public.ug (id bigint primary key, payload text);
insert into public.ug select g, 'a' || g from generate_series(1, 200) g;
call pgpm.transmute('public.ug', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => true);
select pgpm.obtain('public.ug');
insert into public.ug values (450, 'frontier');
select pgpm.regrain_step('public.ug', 'ug_p0000000000000000000_to_0000000000000000300', '50', 500);   -- prepare
alter table public.ug set schema ugh;
drop trigger pgpm_regrain_truncate_guard on public.ug_p0000000000000000000_to_0000000000000000300;
SQL
  then
    printf 'FAIL  %-62s\n' "fixture: an in-flight regrain of a moved parent, its guard dropped"
    fail=1
  else
    check "LIVENESS: in flight (capture on the source, cursor at lo), no guard" \
      "$(v "select exists (select 1 from pg_trigger where tgname = 'pgpm_regrain_capture' and tgrelid = 'public.$SRC'::regclass)
                || ':' || (select regrain_cursor from pgpm.config where parent_table = 'ugh.ug'::regclass)
                || ':' || exists (select 1 from pg_trigger where tgname = 'pgpm_regrain_truncate_guard'
                                     and tgrelid = 'public.$SRC'::regclass)")" \
      "true:0:false"
    if docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" psql -U postgres -d "$DB" -q \
         -v ON_ERROR_STOP=1 -f "$INSTALL" >/dev/null 2>&1; then
      printf 'PASS  %-62s\n' "LIVENESS: install.sql re-ran (the upgrade path)"
      # identity, not a count: the guard on THIS source, ENABLE ALWAYS, and on no other relation of the
      # parent (its forward partitions stay bare); 'none' rather than an empty string, so a query that
      # errors cannot read as "no guard anywhere". Schema-qualified by hand: regclass::text drops a schema
      # on the search_path, and the schema is the point.
      check "re-running install.sql puts the guard back on the moved parent's source" \
        "$(v "select coalesce(string_agg(n.nspname || '.' || c.relname || ':' || t.tgenabled::text, ',' order by c.relname), 'none')
                from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
               where t.tgname = 'pgpm_regrain_truncate_guard'
                 and t.tgrelid in (select child_oid from pgpm.part where parent_table = 'ugh.ug'::regclass)")" \
        "public.$SRC:A"
    else
      printf 'FAIL  %-62s\n' "LIVENESS: install.sql re-ran (the upgrade path)"
      fail=1
    fi
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
