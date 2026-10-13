#!/usr/bin/env bash
# Verifier's rebuild of F12-06. scripts/check_quoted_splices.py (CI's `Quoted splices` job) passes an install
# file carrying the #409 shape, an unmarked quote_ident'd column list spliced with %s, when the list reaches
# its text local as a FOR loop's target (for v_cols in select string_agg(quote_ident(attname), ...) loop).
# Change from the finder's: the FOR-target fixture's premise is witnessed by BEHAVIOUR (the function is
# created in the fresh database and run against a table with a column that needs quoting, so PL/pgSQL is
# shown to accept the shape and to put the QUOTED list into v_cols), not by grepping the edited file.
set -u
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/scripts" "$W/pgpm_core" "$W/pgpm_hypertable" "$W/pgpm_archive"
cp "$TREE/scripts/check_quoted_splices.py" "$W/scripts/"
for f in pgpm_core pgpm_hypertable pgpm_archive; do cp "$TREE/$f/install.sql" "$W/$f/install.sql"; done
fail=0
lint() { python3 "$W/scripts/check_quoted_splices.py" >"$W/out" 2>&1; echo $?; }

rc=$(lint)
if [ "$rc" = 0 ]; then echo "ok - GUARD: the lint passes the tree's install files as shipped"
else echo "not ok - GUARD: the lint fails the tree as shipped"; cat "$W/out"; fail=1; fi

body() {   # $1: function name, $2: the statement(s) that open the loop and assign v_cols
cat <<SQL

create or replace function $1(p_rel regclass) returns text language plpgsql as \$\$
declare v_cols text; v_n bigint; v_seen text;
begin
  $2
    execute format('select count(*) from (select %s from %s) s', v_cols, p_rel) into v_n;
    v_seen := v_cols;
  end loop;
  return v_seen;
end;
\$\$;
SQL
}
A_STMT="for v_n in select 1 loop select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols from pg_attribute where attrelid = p_rel and attnum > 0;"
B_STMT="for v_cols in select string_agg(quote_ident(attname), ', ' order by attnum) from pg_attribute where attrelid = p_rel and attnum > 0 loop"

# A (control): the same list assigned by SELECT INTO inside a loop is refused, so the edit reaches what the lint reads
cp "$TREE/pgpm_core/install.sql" "$W/pgpm_core/install.sql"; body pgpm.f12_cols "$A_STMT" >> "$W/pgpm_core/install.sql"
rc=$(lint)
if [ "$rc" != 0 ] && grep -q 'v_cols is assigned from an identifier-quoting expression but is not _q-suffixed' "$W/out"; then
  echo "ok - LIVENESS: (A) the unmarked quoted list v_cols is refused when assigned by SELECT INTO"
else echo "not ok - LIVENESS: (A) the lint did not refuse the plain #409 shape"; cat "$W/out"; fail=1; fi

# B premise, by behaviour: PL/pgSQL accepts the FOR-target shape and v_cols receives the QUOTED list
$PSQL -q -v ON_ERROR_STOP=1 >/dev/null 2>"$W/err" <<SQL
create table public.f12_t (id int, "Foo Bar" int);
insert into public.f12_t values (1, 2), (3, 4);
$(body public.f12_cols_for "$B_STMT")
SQL
got=$($PSQL -tAc "select public.f12_cols_for('public.f12_t')" 2>>"$W/err")
if [ "$got" = 'id, "Foo Bar"' ]; then
  echo "ok - LIVENESS: (B) PL/pgSQL runs the FOR-target shape and v_cols holds the already-quoted list id, \"Foo Bar\""
else echo "not ok - LIVENESS: (B) the FOR-target shape did not run or did not assign the quoted list (got '$got')"; cat "$W/err"; fail=1; fi

# B: the same function body appended to the install, the list assigned as the FOR loop's own target
cp "$TREE/pgpm_core/install.sql" "$W/pgpm_core/install.sql"; body pgpm.f12_cols "$B_STMT" >> "$W/pgpm_core/install.sql"
rc=$(lint)
if [ "$rc" != 0 ] && grep -q 'v_cols is assigned from an identifier-quoting expression but is not _q-suffixed' "$W/out"; then
  echo "ok - the unmarked quoted list v_cols is refused as a FOR loop's target too"
else
  echo "not ok - the lint exits $rc and passes the unmarked quoted list v_cols assigned as a FOR loop's target"; cat "$W/out"; fail=1
fi
exit $fail
