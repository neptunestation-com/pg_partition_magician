#!/usr/bin/env bash
# F8-08: scripts/check_quoted_splices.py reads only bodies delimited by a bare $$ (bodies() splits the file on
# "$$"), so a function whose body carries any other dollar tag ($fn$) is never read: an unmarked text local holding
# quote_ident output there passes the lint, and the 12-assignment floor does not notice one function going dark.
# The same function under $$ is refused. Present = the lint passes the $fn$ copy.
set -u
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
mk() { mkdir -p "$1/scripts" "$1/pgpm_core" "$1/pgpm_hypertable" "$1/pgpm_archive"
  cp "$TREE/scripts/check_quoted_splices.py" "$1/scripts/"
  for m in pgpm_core pgpm_hypertable pgpm_archive; do cp "$TREE/$m/install.sql" "$1/$m/"; done; }
mk "$W/clean"; mk "$W/dd"; mk "$W/tag"
body='declare v_cols text;
begin
  select string_agg(quote_ident(attname), '"'"', '"'"') into v_cols from pg_attribute where attrelid = p_rel and attnum > 0;
  execute format('"'"'select %s from %s'"'"', v_cols, p_rel);
end;'
printf '\ncreate or replace function pgpm.f8_cols(p_rel regclass) returns void language plpgsql as $$\n%s\n$$;\n' "$body" >> "$W/dd/pgpm_core/install.sql"
printf '\ncreate or replace function pgpm.f8_cols(p_rel regclass) returns void language plpgsql as $fn$\n%s\n$fn$;\n' "$body" >> "$W/tag/pgpm_core/install.sql"
python3 "$W/clean/scripts/check_quoted_splices.py" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then echo "ok - LIVENESS: (A) the lint passes the tree's unedited install files"
else echo "not ok - LIVENESS: (A) the lint passes the tree's unedited install files (exit $rc)"; fail=1; fi
out=$(python3 "$W/dd/scripts/check_quoted_splices.py" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q 'v_cols is assigned from an identifier-quoting expression' <<<"$out"; then
  echo "ok - LIVENESS: (B) the planted function under \$\$ is refused for its unmarked v_cols"
else echo "not ok - LIVENESS: (B) the planted function under \$\$ is refused for its unmarked v_cols (exit $rc)"; fail=1; fi
out=$(python3 "$W/tag/scripts/check_quoted_splices.py" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q 'v_cols' <<<"$out"; then
  echo "ok - the lint refuses the same unmarked v_cols in a body tagged \$fn\$"
else
  echo "not ok - the lint refuses the same unmarked v_cols in a body tagged \$fn\$ (exit $rc: $(tail -1 <<<"$out" | cut -c1-80))"; fail=1
fi
exit "$fail"
