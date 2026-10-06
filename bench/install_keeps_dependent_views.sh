#!/usr/bin/env bash
# install_keeps_dependent_views.sh <container> <db> [install.sql]
#
# Re-running install.sql (the documented upgrade) keeps an operator's views over pgpm's set-returning
# functions, and refuses up front, changing nothing, when a function a view depends on has to change shape
# (issue #983). install.sql used to `drop function if exists` status(), progress(regclass),
# observe_window(regclass, interval), check_uuidv7 and check_text_time before creating them, on every run,
# so one view over pgpm.status() made every re-run fail at that drop.
#
# Two stages, against an ARBITRARY copy of pgpm_core/install.sql so bench/discriminate.sh can hand it a mutant:
#
#   A. tests/281_install_keeps_dependent_views_test.sql, which re-runs the install twice (with \ir, the file
#      handed to it as the psql variable `install`) under a view over each of the five functions, and
#      requires each view to be the relation it was, answering what it answered.
#   B. The refusal comes FIRST, which one pgTAP file cannot show (pg_prove stops the file at the first
#      error, and a run inside one transaction rolls back whatever ran before the refusal anyway). An older
#      observe_window with a view over it, and a marker the file removes early (pgpm.config.drain_adaptive,
#      dropped by the #288 lines near its top). install.sql is run with ON_ERROR_STOP and NO transaction
#      around it, the way an operator without --single-transaction runs it: it must stop with pgpm's
#      refusal naming the function and the view, and the marker, the view and pgpm.installed must be as they
#      were, so nothing in the file ran before it. LIVENESS witnesses that the marker is one the file does
#      remove, and that the run goes through once the view is gone.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   install_drops_surface_unconditionally -- the pre-fix shape: the five functions are dropped
#                                            unconditionally. Stage A dies at the first re-run, stage B
#                                            stops at PostgreSQL's raw dependency error, not pgpm's refusal.
#   surface_shape_ignores_result          -- the shape comparison forgets the result, so an older
#                                            observe_window whose arguments match is taken as replaceable:
#                                            nothing is refused up front, the file runs until CREATE OR
#                                            REPLACE rejects the result, and the marker is already gone.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/281_install_keeps_dependent_views_test.sql}"
DBR="${DB}_r"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }
qi() { docker exec -i "$C" psql -U postgres "$@"; }
v() { docker exec "$C" psql -U postgres -d "$DBR" -tAq -c "$1" 2>&1; }
check() {  # <label> <got> <want>
  if [ "$2" = "$3" ]; then printf 'PASS  %-70s\n' "$1"
  else printf 'FAIL  %-70s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

# ============================== A: the views survive two re-runs ==============================
q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-70s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set install=$INSTALL $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -|ERROR' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-70s %s\n' "re-running install.sql keeps the views over pgpm's functions" "$ran ran"
  else printf 'FAIL  %-70s %s\n' "re-running install.sql keeps the views over pgpm's functions" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-70s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi
q -q -c "drop database if exists $DB" >/dev/null 2>&1

# ============================== B: the refusal comes before anything else ==============================
q -q -c "drop database if exists $DBR" >/dev/null 2>&1
q -q -c "create database $DBR" >/dev/null 2>&1
if ! q -d "$DBR" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-70s %s\n' "the module under test installed (stage B)" "$INSTALL"
  fail=1
else
  # the setup must land, or every later line is judged against a state nobody built
  qi -d "$DBR" -v ON_ERROR_STOP=1 -q >/dev/null <<'SQL' || { printf 'FAIL  %-70s\n' "the stage B fixture was built"; fail=1; }
drop function pgpm.observe_window(regclass, interval);
create function pgpm.observe_window(p_parent regclass, p_since interval default '7 days')
returns table (parent_table regclass, drains bigint) language sql stable as $$ select p_parent, 0::bigint $$;
create view public.ow_old as select parent_table, drains from pgpm.observe_window('pgpm.config');
alter table pgpm.config add column drain_adaptive boolean;
SQL
  state() {
    v "select concat_ws(' | ',
         (select count(*) from pg_attribute where attrelid = 'pgpm.config'::regclass and attname = 'drain_adaptive' and not attisdropped),
         coalesce((select oid::text from pg_class where oid = to_regclass('public.ow_old')), 'no view'),
         (select count(*) from pgpm.installed),
         pg_get_function_result(to_regprocedure('pgpm.observe_window(regclass,interval)')))"
  }
  before=$(state)
  view_oid=$(v "select 'public.ow_old'::regclass::oid")
  check "LIVENESS: marker column, the view over the older observe_window, one install" \
    "$before" "1 | $view_oid | 1 | TABLE(parent_table regclass, drains bigint)"

  out=$(q -d "$DBR" -v ON_ERROR_STOP=1 -q -f "$INSTALL" 2>&1); rc=$?
  err=$(echo "$out" | grep -m1 'ERROR')
  echo "    first error: ${err:-none}"
  check "the re-run stops (ON_ERROR_STOP, no transaction around it)" "$([ "$rc" -ne 0 ] && echo stopped || echo "went through")" "stopped"
  check "with pgpm's refusal naming the function and the view" \
    "$(echo "$err" | grep -c 'cannot replace pgpm.observe_window(regclass,interval) (on which view public.ow_old depends) in place')" "1"
  check "and nothing in the file ran before it: marker, view and installed are as they were" "$(state)" "$before"

  v "drop view public.ow_old" >/dev/null
  out=$(q -d "$DBR" -v ON_ERROR_STOP=1 -q -f "$INSTALL" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || echo "$out" | grep -m1 ERROR | sed 's/^/    /'
  check "LIVENESS: with the view gone the run goes through, removing the marker and reshaping the function" \
    "$rc | $(state)" "0 | 0 | no view | 2 | TABLE(parent_table regclass, window_start timestamp with time zone, window_end timestamp with time zone, duration interval, log_rows bigint, rows_copied bigint, regrains bigint, retains bigint)"
fi
q -q -c "drop database if exists $DBR" >/dev/null 2>&1
exit "$fail"
