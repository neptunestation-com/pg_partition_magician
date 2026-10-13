#!/usr/bin/env bash
# scripts/check_quoted_splices.py (CI's `Quoted splices` job) passes an install file carrying the #409 shape,
# an unmarked quote_ident'd column list spliced with %s, when the list reaches its text local as a FOR loop's
# target (for v_cols in select string_agg(quote_ident(attname), ', ') ... loop): select_into() needs an INTO and
# ASSIGN needs := or =, so the assignment PL/pgSQL makes is never read.
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
  $1
    execute format('select count(*) from (select %s from %s) s', v_cols, p_rel) into v_n;
  end loop;
  return v_n;
end;
\$\$;
SQL
}

# A: the same list assigned by SELECT INTO inside a loop: the lint must refuse it (proves the edit reaches the file the lint reads)
cp "$TREE/pgpm_core/install.sql" "$W/pgpm_core/install.sql"; body "for v_n in select 1 loop select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols from pg_attribute where attrelid = p_rel and attnum > 0;" >> "$W/pgpm_core/install.sql"
rc=$(lint)
if [ "$rc" != 0 ] && grep -q 'v_cols is assigned from an identifier-quoting expression but is not _q-suffixed' "$W/out"; then
  echo "ok - LIVENESS: (A) the unmarked quoted list v_cols is refused when assigned by SELECT INTO"
else echo "not ok - LIVENESS: (A) the lint did not refuse the plain #409 shape"; cat "$W/out"; fail=1; fi

# B: the same list assigned as the FOR loop's own target
cp "$TREE/pgpm_core/install.sql" "$W/pgpm_core/install.sql"; body "for v_cols in select string_agg(quote_ident(attname), ', ' order by attnum) from pg_attribute where attrelid = p_rel and attnum > 0 loop" >> "$W/pgpm_core/install.sql"
grep -q 'loop select string_agg' "$W/pgpm_core/install.sql" || true; grep -q 'for v_cols in select string_agg(quote_ident(attname)' "$W/pgpm_core/install.sql" && echo "ok - LIVENESS: (B) the edited install carries the same quoted list, assigned to v_cols as the FOR target"
rc=$(lint)
if [ "$rc" != 0 ] && grep -q 'v_cols is assigned from an identifier-quoting expression but is not _q-suffixed' "$W/out"; then
  echo "ok - the unmarked quoted list v_cols is refused as a FOR loop's target too"
else
  echo "not ok - the lint exits $rc and passes the unmarked quoted list v_cols assigned as a FOR loop's target"; cat "$W/out"; fail=1
fi
exit $fail
