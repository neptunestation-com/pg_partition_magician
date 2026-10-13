#!/usr/bin/env bash
# F12r-08: scripts/check_archive_child_by_oid.py states, under rule 1, "nothing is cast to regclass from a
# parenthesised expression (`(v_nsp || '.' || v_rel)::regclass`)": a relation found by a name built at run time.
# The check matches that by spelling: a `)` token, then `::`, then the token `regclass`. The same cast spelled
# `::pg_catalog.regclass`, `CAST(... AS regclass)` or the call form `regclass(...)` (both of which the docstring
# itself names as casts for the rendered-name rule) passes with no violation. The lint should refuse all three as
# it refuses `(...)::regclass`.
# Env: TREE.
set -uo pipefail
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
LINT="$TREE/scripts/check_archive_child_by_oid.py"
fail=0
probe() { # <file> <expression>
  cp "$TREE/pgpm_archive/install.sql" "$1"
  printf '\ncreate or replace function archive._f12r_probe(p_nsp text, p_name text)\nreturns oid language sql stable as $f$\n  select %s::oid\n$f$;\n' "$2" >> "$1"
}
probe "$W/live.sql" "(quote_ident(p_nsp) || '.' || quote_ident(p_name))::regclass"
out=$(python3 "$LINT" "$W/live.sql" 2>&1)
if grep -q "archive._f12r_probe.*cast to regclass" <<<"$out"; then
  echo "ok - LIVENESS: the lint reads the appended function and refuses (...)::regclass there"
else
  echo "not ok - LIVENESS: the lint did not refuse (...)::regclass in the appended function"; fail=1
fi
n=0
for expr in "(quote_ident(p_nsp) || '.' || quote_ident(p_name))::pg_catalog.regclass" \
            "cast(quote_ident(p_nsp) || '.' || quote_ident(p_name) as regclass)" \
            "regclass(quote_ident(p_nsp) || '.' || quote_ident(p_name))"; do
  n=$((n + 1)); probe "$W/m$n.sql" "$expr"
  out=$(python3 "$LINT" "$W/m$n.sql" 2>&1)
  if grep -q "archive._f12r_probe" <<<"$out"; then
    echo "ok - the lint refuses a relation found by a name built at run time as: $expr"
  else
    echo "not ok - the lint names no violation in archive._f12r_probe, which casts a name built at run time to regclass as: $expr"
    fail=1
  fi
done
exit $fail
