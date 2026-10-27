#!/usr/bin/env bash
# Prove scripts/check_part_row_by_name.py refuses a pgpm.part row's relation resolved by its NAME outside
# pgpm._part_rel, in each spelling the rounds of #1365's verification found, and passes the modules as they are.
#
# WHY THIS GUARD EXISTS (issue #1365, PR #1392 round 7). Six rounds each found one more step that resolved a row's
# child name to a relation (to_regclass over a rendered name, a ::regclass cast of one, a relname join, DDL run on
# one) and, for a row with no recorded oid, took an operator's table under that name and dropped or blocked it.
# Round 7 routed every site through pgpm._part_rel and added the lint so the next one fails CI. The lint's own
# --selftest lives in the file it tests; these fixtures are the guard's, so a mutant of the lint is judged by
# something it did not write.
#
# HOW. LIVENESS: the checker passes this checkout's four modules (a checker that refuses everything would pass
# every defect check below). Each defect fixture is a real pre-round-7 site in the spelling it had, and each must
# be refused; each clean fixture (through the resolver, a reason on the line, a message, another name) must pass.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   part_row_lint_child_name_only -- the lint recognises a child name only as `child_name`, never `p_child`
#
# Usage: part_row_by_name_lint.sh <container> <db> [checker.py]
# The container and database are accepted for the shape bench/discriminate.sh calls every guard with and are not
# used: the check is static and runs on the host. A third argument is a copy of the checker (discriminate.sh hands
# it a mutant, under a .sql name, at a /repo/ path that is mapped to this checkout).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_C="${1:?container}"; _DB="${2:?db}"; UNDER="${3:-$ROOT/scripts/check_part_row_by_name.py}"
UNDER="${UNDER/#\/repo\//$ROOT/}"
if [ ! -s "$UNDER" ]; then
  printf 'FAIL  %-62s %s\n' "GUARD: the checker under test is readable" "$UNDER"
  exit 1
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

run() { python3 "$UNDER" "$@" >/dev/null 2>&1; }

if run "$ROOT/pgpm_core/install.sql" "$ROOT/pgpm_core/uninstall.sql" "$ROOT/pgpm_archive/install.sql" "$ROOT/pgpm_hypertable/install.sql"; then
  printf 'PASS  %-62s %s\n' "LIVENESS: the checker passes this checkout's modules" "4 files"
else
  printf 'FAIL  %-62s %s\n' "LIVENESS: the checker passes this checkout's modules" "it refused them"
  fail=1
fi

defect() {   # name, sql
  printf '%s' "$2" > "$T/d.sql"
  if run "$T/d.sql"; then printf 'FAIL  %-62s %s\n' "refused: $1" "passed"; fail=1
  else printf 'PASS  %-62s %s\n' "refused: $1" "exit 1"; fi
}
clean() {
  printf '%s' "$2" > "$T/c.sql"
  if run "$T/c.sql"; then printf 'PASS  %-62s %s\n' "passed: $1" "exit 0"
  else printf 'FAIL  %-62s %s\n' "passed: $1" "refused"; fail=1; fi
}

defect "regrain's source by p_child (round 6)" \
"              else to_regclass(format('%I.%I', pgpm._child_nsp(p_parent, p_child), p_child)) end
"
defect "retire()'s referenced path, relname = p_child (#1365)" \
"    select i.inhrelid into v_child
      from pg_inherits i join pg_class c on c.oid = i.inhrelid
     where i.inhparent = p_parent and c.relname = p_child;
"
defect "the write block's cast of p_child" \
"  v_child := format('%I.%I', v_nsp, p_child)::regclass;
"
defect "the write block's CREATE TRIGGER on p_child" \
"  execute format(
    'create trigger pgpm_write_block before insert on %I.%I'
    || ' for each row execute function f()', v_nsp, p_child);
"
defect "a loop's r.child_name" \
"      v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));
"
defect "dynamic SQL over l.child_name" \
"    'and to_regclass(format(''%%I.%%I'', pgpm._child_nsp(l.parent_table, l.child_name), l.child_name)) is null'
"
clean "through the resolver" \
"  v_now := pgpm._part_rel(p_parent, p_child);
"
clean "a reason on the line" \
"  v_now := to_regclass(format('%I.%I', v_nsp, p_child));   -- part-row-by-name: names the stranger
"
clean "a message" \
"    raise exception 'x %', format('%I.%I', v_nsp, p_child);
"
clean "another name than a child's" \
"  v_taken := to_regclass(format('%I.%I', v_nsp, v_delta));
"
exit "$fail"
