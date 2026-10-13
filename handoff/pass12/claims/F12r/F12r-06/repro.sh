#!/usr/bin/env bash
# F12r-06: scripts/check_archive_child_by_oid.py rule 1 ("No relation is found by its name", the INVERSE rule since
# #1154) knows a relation's name only as a name COLUMN token or a cast-made regclass/regtype rendered as text. A
# function that finds a relation by the same name read as data out of the pg_class row passes it with no
# violation: `where to_jsonb(c) ->> 'relname' = p_name` (the #1181 shape its sibling lint,
# check_archive_object_keys.py, now refuses for the prefix), or by pg_identify_object()'s rendered `identity`.
# Neither spelling is in the docstring's "What this cannot see" list. The lint should refuse both as it refuses
# `c.relname = p_name`.
# Env: TREE.
set -uo pipefail
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
LINT="$TREE/scripts/check_archive_child_by_oid.py"
fail=0
probe() { # <file> <predicate>: append a function finding a relation by name with <predicate>
  cp "$TREE/pgpm_archive/install.sql" "$1"
  printf '\ncreate or replace function archive._f12r_probe(p_parent regclass, p_name text)\nreturns oid language sql stable as $f$\n  select c.oid from pg_class c where c.relnamespace = p_parent::oid and %s\n$f$;\n' "$2" >> "$1"
}
probe "$W/live.sql" "c.relname = p_name"
out=$(python3 "$LINT" "$W/live.sql" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q "archive._f12r_probe" <<<"$out"; then
  echo "ok - LIVENESS: the lint reads the appended function and refuses c.relname = p_name there (rc=$rc)"
else
  echo "not ok - LIVENESS: the lint did not refuse the plain relname lookup in the appended function (rc=$rc)"; fail=1
fi
n=0
for pred in "to_jsonb(c) ->> 'relname' = p_name" \
            "(pg_identify_object('pg_class'::regclass, c.oid, 0)).identity = p_name"; do
  n=$((n + 1)); probe "$W/m$n.sql" "$pred"
  out=$(python3 "$LINT" "$W/m$n.sql" 2>&1); rc=$?
  if grep -q "archive._f12r_probe" <<<"$out"; then
    echo "ok - the lint refuses a relation found by its name as: $pred"
  else
    echo "not ok - the lint names no violation in archive._f12r_probe, which finds a relation by its name as: $pred (rc=$rc; any failure it reports is elsewhere in the file)"
    fail=1
  fi
done
# a third spelling: the name stands ALONE in the statement's own select list (where rule 1 lets it stand) and an
# INTERSECT compares it with the name looked for
cp "$TREE/pgpm_archive/install.sql" "$W/m3.sql"
cat >> "$W/m3.sql" <<'SQL'

create or replace function archive._f12r_probe(p_parent regclass, p_name text)
returns oid language plpgsql stable as $f$
declare v_name name; v_oid oid;
begin
  select c.relname, c.oid into v_name, v_oid from pg_class c
  intersect select p_name::name, c2.oid from pg_class c2;
  return v_oid;
end $f$;
SQL
out=$(python3 "$LINT" "$W/m3.sql" 2>&1); rc=$?
if grep -q "archive._f12r_probe" <<<"$out"; then
  echo "ok - the lint refuses a relation found by its name through an INTERSECT with the name looked for"
else
  echo "not ok - the lint names no violation in archive._f12r_probe, which finds a relation by its name through INTERSECT (select c.relname, c.oid ... intersect select p_name::name, c2.oid ...) (rc=$rc)"
  fail=1
fi
exit $fail
