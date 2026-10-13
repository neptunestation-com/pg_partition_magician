#!/usr/bin/env bash
# F8-02: scripts/check_archive_object_keys.py passes a second function that assembles an object key from the
# configured prefix when the prefix reaches the concatenation as an EXECUTE ... USING bind parameter
# (`execute 'select $1 || ''/'' || $2' into v_key using cfg.prefix, p_name`), although it refuses the same
# function written `v_key := cfg.prefix || '/' || p_name`. Its contract: "Exactly one function of
# pgpm_archive/install.sql assembles a prefix"; "Dynamic SQL is code". Present = the lint passes the USING form.
set -u
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
L="$TREE/scripts/check_archive_object_keys.py"
cp "$TREE/pgpm_archive/install.sql" "$W/clean.sql"
cp "$W/clean.sql" "$W/concat.sql"; cp "$W/clean.sql" "$W/using.sql"
cat >> "$W/concat.sql" <<'SQL'

create or replace function archive.f8_second_key(p_parent regclass, p_name text) returns text language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config limit 1;
  v_key := cfg.prefix || '/' || p_name;
  return v_key;
end;
$$;
SQL
cat >> "$W/using.sql" <<'SQL'

create or replace function archive.f8_second_key(p_parent regclass, p_name text) returns text language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config limit 1;
  execute 'select $1 || ''/'' || $2' into v_key using cfg.prefix, p_name;
  return v_key;
end;
$$;
SQL
out=$(python3 "$L" "$W/clean.sql" 2>&1); rc=$?
if [ "$rc" = 0 ]; then echo "ok - LIVENESS: (A) the lint passes the tree's unedited pgpm_archive/install.sql"
else echo "not ok - LIVENESS: (A) the lint passes the tree's unedited pgpm_archive/install.sql (exit $rc)"; fail=1; fi
out=$(python3 "$L" "$W/concat.sql" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q 'archive.f8_second_key' <<<"$out"; then
  echo "ok - LIVENESS: (B) the planted second key function is read: its || twin is refused as a second assembly"
else echo "not ok - LIVENESS: (B) the planted second key function is read: its || twin is refused (exit $rc)"; fail=1; fi
out=$(python3 "$L" "$W/using.sql" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q 'archive.f8_second_key' <<<"$out"; then
  echo "ok - the lint refuses a second key assembled from cfg.prefix passed to EXECUTE ... USING"
else
  echo "not ok - the lint refuses a second key assembled from cfg.prefix passed to EXECUTE ... USING (exit $rc: $(tail -1 <<<"$out" | cut -c1-80))"
  fail=1
fi
exit "$fail"
