#!/usr/bin/env bash
# scripts/check_quoted_splices.py (CI's `Quoted splices` job) passes an install file carrying the #409 shape,
# an unmarked quote_ident'd column list spliced with %s, when an E-string with a backslash-escaped quote
# (E'it\'s') precedes it in the body: strip_noise does not know E-strings, ends the literal at the escaped
# quote, re-opens one at the next quote and blanks the code between, so the assignment is never read.
# Runs the TREE's script on a scratch copy of the tree's install files with one function appended.
set -u
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/scripts" "$W/pgpm_core" "$W/pgpm_hypertable" "$W/pgpm_archive"
cp "$TREE/scripts/check_quoted_splices.py" "$W/scripts/"
for f in pgpm_core pgpm_hypertable pgpm_archive; do cp "$TREE/$f/install.sql" "$W/$f/install.sql"; done
fail=0

lint() { python3 "$W/scripts/check_quoted_splices.py" >"$W/out" 2>&1; echo $?; }

# the tree as shipped is clean under the lint
rc=$(lint)
if [ "$rc" = 0 ]; then echo "ok - fixture: the lint passes the tree's install files as shipped"; else echo "not ok - fixture: the lint fails the tree as shipped"; cat "$W/out"; fail=1; fi

body() {   # $1: text placed before the assignment
cat <<SQL

create or replace function pgpm.f12_cols(p_rel regclass) returns bigint language plpgsql as \$\$
declare v_cols text; v_n bigint;
begin
  v_n := 0;
  raise notice $1;
  v_cols := quote_ident('id') || ', ' || quote_ident('payload');
  raise notice 'done';
  execute format('select count(*) from (select %s from %s) s', v_cols, p_rel) into v_n;
  return v_n;
end;
\$\$;
SQL
}

# A: the shape after a plain literal: the lint must refuse it (proves the edit reaches the file the lint reads)
cp "$TREE/pgpm_core/install.sql" "$W/pgpm_core/install.sql"; body "'plain'" >> "$W/pgpm_core/install.sql"
rc=$(lint)
if [ "$rc" != 0 ] && grep -q 'v_cols is assigned from an identifier-quoting expression but is not _q-suffixed' "$W/out"; then
  echo "ok - LIVENESS: (A) the unmarked quoted list v_cols is refused after a plain literal"
else echo "not ok - LIVENESS: (A) the lint did not refuse the plain #409 shape"; cat "$W/out"; fail=1; fi

# B: the same function, an E-string with an escaped quote before the assignment
cp "$TREE/pgpm_core/install.sql" "$W/pgpm_core/install.sql"; body "E'it\\'s'" >> "$W/pgpm_core/install.sql"
grep -q "v_cols := quote_ident('id')" "$W/pgpm_core/install.sql" && echo "ok - LIVENESS: (B) the edited install carries the same unmarked v_cols assignments"
rc=$(lint)
if [ "$rc" != 0 ] && grep -q 'v_cols is assigned from an identifier-quoting expression but is not _q-suffixed' "$W/out"; then
  echo "ok - the unmarked quoted list v_cols is refused after an E-string too"
else
  echo "not ok - the lint exits $rc and passes the unmarked quoted list v_cols after E'it\\'s'"; cat "$W/out"; fail=1
fi
exit $fail
