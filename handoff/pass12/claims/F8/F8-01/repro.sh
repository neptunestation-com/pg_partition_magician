#!/usr/bin/env bash
# F8-01: scripts/check_quoted_splices.py passes a text local that holds quote_ident'd identifiers when the
# local is assigned as the target of FOR ... IN SELECT, although it refuses the same local assigned by
# SELECT ... INTO. CLAUDE.md: the lint "fails CI when a quote-derived text local lacks the suffix"; its
# docstring: "a SELECT's INTO is read wherever PL/pgSQL takes it". Present = the lint exits 0 on the FOR form.
set -u
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
mk() {  # <dir>: a copy of the lint and the three install files it reads
  mkdir -p "$1/scripts" "$1/pgpm_core" "$1/pgpm_hypertable" "$1/pgpm_archive"
  cp "$TREE/scripts/check_quoted_splices.py" "$1/scripts/"
  for m in pgpm_core pgpm_hypertable pgpm_archive; do cp "$TREE/$m/install.sql" "$1/$m/"; done
}
mk "$W/clean"; mk "$W/into"; mk "$W/for"

# The twin the lint already refuses: the quoted name reaches v_col through SELECT ... INTO.
cat >> "$W/into/pgpm_core/install.sql" <<'SQL'

create or replace function pgpm.f8_cols(p_rel regclass) returns void language plpgsql as $$
declare v_col text; v_list text := '';
begin
  select quote_ident(attname) into v_col from pg_attribute where attrelid = p_rel and attnum > 0 limit 1;
  v_list := v_list || v_col || ', ';
  execute format('select %s from %s', rtrim(v_list, ', '), p_rel);
end;
$$;
SQL
# The defect: the same quoted name reaches v_col as the target of FOR ... IN SELECT.
cat >> "$W/for/pgpm_core/install.sql" <<'SQL'

create or replace function pgpm.f8_cols(p_rel regclass) returns void language plpgsql as $$
declare v_col text; v_list text := '';
begin
  for v_col in select quote_ident(attname) from pg_attribute where attrelid = p_rel and attnum > 0 loop
    v_list := v_list || v_col || ', ';
  end loop;
  execute format('select %s from %s', rtrim(v_list, ', '), p_rel);
end;
$$;
SQL

out=$(python3 "$W/clean/scripts/check_quoted_splices.py" 2>&1); rc=$?
if [ "$rc" = 0 ]; then echo "ok - LIVENESS: (A) the lint passes the tree's unedited install files"
else echo "not ok - LIVENESS: (A) the lint passes the tree's unedited install files (exit $rc)"; echo "$out" | tail -3; fail=1; fi

out=$(python3 "$W/into/scripts/check_quoted_splices.py" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q 'v_col is assigned from an identifier-quoting expression but is not _q-suffixed' <<<"$out"; then
  echo "ok - LIVENESS: (B) the planted function is read: its SELECT INTO twin is refused for v_col"
else
  echo "not ok - LIVENESS: (B) the planted function is read: its SELECT INTO twin is refused for v_col (exit $rc)"; fail=1
fi

out=$(python3 "$W/for/scripts/check_quoted_splices.py" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q 'v_col' <<<"$out"; then
  echo "ok - the lint refuses an unmarked text local holding quote_ident output assigned by FOR ... IN SELECT"
else
  echo "not ok - the lint refuses an unmarked text local holding quote_ident output assigned by FOR ... IN SELECT (exit $rc: $(tail -1 <<<"$out" | cut -c1-90))"
  fail=1
fi
exit "$fail"
