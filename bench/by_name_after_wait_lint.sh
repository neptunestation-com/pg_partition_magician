#!/usr/bin/env bash
# Prove scripts/check_by_name_after_wait.py refuses a statement that names a relation or function pgpm identified by
# oid through a name rendered before the statement waits, with no lock by oid before it, no effect check after it and
# no `-- by-name-ok:` reason, and passes the modules as they are.
#
# WHY THIS GUARD EXISTS (the schema-swap class: #1335 bullet 10, #1355, #1356, #1358, #1362, #1364, #1366, #1367). Three
# per-family fixes (#1399, #1400, #1402) each closed the sites one enumeration named, and each review pass found the
# enumeration incomplete. The checker closes the class in the text; its own --selftest lives in the file it tests, so
# these fixtures are the guard's, and a mutant of the checker is judged by something it did not write.
#
# HOW. LIVENESS: the checker passes this checkout's four modules (a checker that refused everything would pass every
# defect check below). Each defect fixture is a function in a shape the class took, and must be refused; each clean
# fixture (locked by oid first, a vouched pair, its effect checked, a reason, a message, a read of pgpm's own table)
# must pass.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each a recogniser clause:
#   by_name_lint_lock_any_object        -- a lock by oid on any relation of the unit covers every statement
#   by_name_lint_effect_anywhere_after  -- an effect check anywhere after a statement covers it
#   by_name_lint_pairs_unread           -- a `%I.%I` pair is no object name
#   by_name_lint_mark_in_literal        -- a mark in a string literal is read as a reason
#
# Usage: by_name_after_wait_lint.sh <container> <db> [checker.py]
# The container and database are accepted for the shape bench/discriminate.sh calls every guard with and are not
# used: the check is static and runs on the host. A third argument is a copy of the checker (discriminate.sh hands it
# a mutant, under a .sql name, at a /repo/ path that is mapped to this checkout).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_C="${1:?container}"; _DB="${2:?db}"; UNDER="${3:-$ROOT/scripts/check_by_name_after_wait.py}"
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

unit() {   # a function body around $1
  printf 'create or replace function pgpm.f(p_parent regclass, p_child regclass) returns void language plpgsql as $$\ndeclare v_nsp name; v_rel name; v_oid oid;\nbegin\n%s\nend;\n$$;\n' "$1"
}
defect() {   # name, body
  unit "$2" > "$T/d.sql"
  if run "$T/d.sql"; then printf 'FAIL  %-62s %s\n' "refused: $1" "passed"; fail=1
  else printf 'PASS  %-62s %s\n' "refused: $1" "exit 1"; fi
}
clean() {
  unit "$2" > "$T/c.sql"
  if run "$T/c.sql"; then printf 'PASS  %-62s %s\n' "passed: $1" "exit 0"
  else printf 'FAIL  %-62s %s\n' "passed: $1" "refused"; fail=1; fi
}

defect "the swap's DETACH by names rendered before its wait (#1362)" \
"  execute format('alter table %s detach partition %s', p_parent::text, p_child::text);"
defect "a %I.%I pair read off the catalog with nothing locked" \
"  select n.nspname, c.relname into v_nsp, v_rel from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  execute format('drop table %I.%I', v_nsp, v_rel);"
defect "a positional pair" \
"  execute format('alter table %1\$I.%2\$I owner to %3\$I', v_nsp, v_rel, 'x');"
defect "a lock by oid on ANOTHER relation" \
"  perform pgpm._lock_oid_or_raise(p_child, 'access exclusive', true, 'x');
  execute format('truncate %s', p_parent::text);"
defect "an effect check after the NEXT statement" \
"  execute format('drop table %s', p_child::text);
  execute format('drop table %s', p_parent::text);
  perform pgpm._effect_or_raise(not exists (select 1 from pg_class where oid = p_parent), p_parent, 'x');"
defect "a mark inside the statement's string literal" \
"  execute format('analyze %s /* -- by-name-ok: none */', p_parent::text);"
defect "a statement built elsewhere and executed" \
"  execute v_tdef;"
defect "a function dropped by its oid's rendering, nothing checked (#1357's residue)" \
"  execute format('drop function %s', v_oid::regprocedure::text);"

clean "locked by oid first, named under the lock" \
"  perform pgpm._lock_oid_or_raise(p_parent, 'access exclusive', true, 'x');
  execute format('alter table %s detach partition %s', p_parent::text, p_parent::text);"
clean "a vouched pair" \
"  perform pgpm._lock_named_or_raise(p_parent, 'access share', true, v_nsp, v_rel, 'x');
  execute format('select 1 from %I.%I', v_nsp, v_rel);"
clean "checked by its effect at once" \
"  execute format('drop function %s', v_oid::regprocedure::text);
  perform pgpm._effect_or_raise(not exists (select 1 from pg_proc where oid = v_oid), v_oid, 'x');"
clean "a reason in the comment block above" \
"  -- by-name-ok: statistics only, a read that moves no row
  execute format('analyze %s', p_parent::text);"
clean "a message" \
"  raise exception 'x: %', format('alter table %s attach partition %s', p_parent, p_child);"
clean "a read of pgpm's own table" \
"  execute format('select child_name from pgpm.part where parent_table = %L::regclass', p_parent::text);"
exit "$fail"
