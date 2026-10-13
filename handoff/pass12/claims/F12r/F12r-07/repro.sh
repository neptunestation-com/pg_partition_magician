#!/usr/bin/env bash
# F12r-07: scripts/check_archive_object_keys.py requires exactly one function of pgpm_archive/install.sql to
# assemble a key from the configured prefix (archive._owned_key), and counts a prefix reference as assembly
# when it touches ||, is assigned/returned/selected out, or is an argument of a call to a function the file does
# not define. A prefix handed to a FROM item is none of those to its lexer (a call after FROM reads as a
# relation name with a column list, and a VALUES row as a value list), so a second key assembled by renaming the
# prefix through a derived table passes with no violation:
#   return (select u.p || p_child from unnest(array[cfg.prefix]) as u(p));
#   return (select u.p || p_child from (values (cfg.prefix)) as u(p));
# Neither shape is in the docstring's "What this cannot see" list (dynamic SQL, a row read without the column's
# name). The lint should refuse both as it refuses `return cfg.prefix || p_child`.
# Env: TREE.
set -uo pipefail
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
LINT="$TREE/scripts/check_archive_object_keys.py"
fail=0
probe() { # <file> <statement>
  cp "$TREE/pgpm_archive/install.sql" "$1"
  printf '\ncreate or replace function archive._f12r_key(p_parent regclass, p_child name)\nreturns text language plpgsql as $f$\ndeclare cfg archive.config;\nbegin\n  select * into cfg from archive.config where parent_table = p_parent;\n  %s\nend $f$;\n' "$2" >> "$1"
}
out=$(python3 "$LINT" 2>&1); rc=$?
[ "$rc" = 0 ] && echo "ok - GUARD: the lint passes the module as it is (rc=0)" || echo "ok - GUARD: the lint already fails the module as it is (rc=$rc); the checks below look only at the appended function"
probe "$W/live.sql" "return cfg.prefix || p_child;"
out=$(python3 "$LINT" "$W/live.sql" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q "archive._f12r_key" <<<"$out"; then
  echo "ok - LIVENESS: the lint reads the appended function and refuses a second key assembled there with || (rc=$rc)"
else
  echo "not ok - LIVENESS: the lint did not refuse return cfg.prefix || p_child in the appended function (rc=$rc)"; fail=1
fi
n=0
for stmt in "return (select u.p || p_child from unnest(array[cfg.prefix]) as u(p));" \
            "return (select u.p || p_child from (values (cfg.prefix)) as u(p));"; do
  n=$((n + 1)); probe "$W/m$n.sql" "$stmt"
  out=$(python3 "$LINT" "$W/m$n.sql" 2>&1); rc=$?
  if [ "$rc" != 0 ] && grep -q "archive._f12r_key" <<<"$out"; then
    echo "ok - the lint refuses a second key assembled as: $stmt"
  else
    echo "not ok - the lint passes a second key assembled outside archive._owned_key as: $stmt (rc=$rc: $(tail -1 <<<"$out" | cut -c1-80))"
    fail=1
  fi
done
# a third shape: the docstring says a parameter of a function this file defines carries the prefix "whatever its
# name" once a call hands it one; a nameless parameter read as $1 is never followed
cp "$TREE/pgpm_archive/install.sql" "$W/m3.sql"
cat >> "$W/m3.sql" <<'SQL'

create or replace function archive._f12r_join(text, name)
returns text language sql immutable as $f$
  select $1 || $2
$f$;
create or replace function archive._f12r_key(p_parent regclass, p_child name)
returns text language plpgsql as $f$
declare cfg archive.config;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  return archive._f12r_join(cfg.prefix, p_child);
end $f$;
SQL
out=$(python3 "$LINT" "$W/m3.sql" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q "archive._f12r_join" <<<"$out"; then
  echo "ok - the lint refuses a second key assembled in a helper from its nameless parameter (\$1 || \$2)"
else
  echo "not ok - the lint passes a second key assembled in archive._f12r_join as \$1 || \$2, handed cfg.prefix by position (rc=$rc)"
  fail=1
fi
exit $fail
