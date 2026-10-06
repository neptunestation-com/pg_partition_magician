#!/usr/bin/env bash
# Run tests/274_text_time_collation_contraction_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant, then check the one acceptance
# a pgTAP file in the shared test database cannot reach: a database whose DEFAULT collation is "C". The
# pgTAP half runs through bench/grid_timezone.sh, selected by its GRID_TZ_TEST_FILE override (same fresh
# database, same install-must-succeed check, same "the assertions were reached at all" count); read that
# file's header for why a wrapper around a plain pgTAP file exists at all.
#
# What THIS file guards (issue #639, bullet 2): _check_text_time_collation is a proof over every one- and
# two-digit string of the alphabet behind the prefix, not a set of single-character probes, so a
# collation with a two-character contraction is refused: da-x-icu ('aa' is a-ring, after 'z') for hex
# and base32, cs-x-icu ('ch' after 'h') for base32 and Crockford, and a prefix 'c' contracting with a
# digit 'h'. Under the probes, transmute accepted a hex column on da-x-icu and PostgreSQL routed a row
# decoded 28 November into the December partition. tests/274 pairs each refusal with a witness that the
# collation misorders strings of that alphabet, and with positive controls (POSIX, ucs_basic, the en_US
# default, hex on cs-x-icu, and collate "C" converting and routing the contracted rows correctly).
#
# The second half: in a fresh database created with LC_COLLATE "C", a hex column on the "default"
# collation must be accepted (check_text_time samples it, transmute converts it, every id survives by
# identity), and a column there collated da-x-icu must still be refused, which shows the check ran in
# that database rather than being skipped.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   text_time_collation_probe_only  -- the pre-#639 check: three probe shapes per adjacent digit pair at
#                                      the declared width, which no two-character contraction disturbs,
#                                      so da-x-icu hex is accepted and transmute converts it again
#
# Usage: text_time_collation_proof.sh <container> <db> [install.sql]
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/274_text_time_collation_contraction_test.sql}" \
GRID_TZ_LABEL="a collation with a contraction is refused for text_time" \
  bash "$(dirname "$0")/grid_timezone.sh" "$C" "$DB" "$INSTALL" || fail=1

q() { docker exec "$C" psql -U postgres "$@"; }
v() { q -d "$DB" -tA -c "$1" 2>&1; }
check() { # label, expected, actual
  if [ "$3" = "$2" ]; then printf 'PASS  %-58s %s\n' "$1" "$3"
  else printf 'FAIL  %-58s expected %s, got %s\n' "$1" "$2" "$3"; fail=1; fi
}

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB template template0 locale_provider libc lc_collate 'C' lc_ctype 'C'" >/dev/null 2>&1
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed in the C database" "$INSTALL"
  fail=1
else
  check "LIVENESS: the database's default collation is C" "C" "$(v "select datcollate from pg_database where datname = current_database()")"
  q -d "$DB" -q -v ON_ERROR_STOP=1 -c "
    create table public.tt_dflt (id text primary key, body text);
    insert into public.tt_dflt
    select lpad(to_hex(floor(extract(epoch from now() - interval '13 months' + g * interval '1 day'))::bigint), 8, '0')
           || lpad(to_hex(g), 16, '0'), 'r' || g
      from generate_series(1, 390) g;
    create table public.tt_da (id text collate \"da-x-icu\" primary key, body text);
    insert into public.tt_da select id, body from public.tt_dflt;
    create table public.tt_ids as select id from public.tt_dflt;" >/dev/null 2>&1
  check "LIVENESS: the fixture column carries the default collation" "default" \
    "$(v "select co.collname from pg_attribute a join pg_collation co on co.oid = a.attcollation where a.attrelid = 'public.tt_dflt'::regclass and a.attname = 'id'")"
  check "check_text_time accepts hex on a C default collation" "t" \
    "$(v "select fraction >= 0.95 from pgpm.check_text_time('public.tt_dflt', 'id', '', 8, 16, 's', 1000, '0123456789abcdef')")"
  out=$(v "select * from pgpm.check_text_time('public.tt_da', 'id', '', 8, 16, 's', 1000, '0123456789abcdef')")
  if echo "$out" | grep -q 'has collation "da-x-icu", which does not order the text_time digit alphabet'; then
    printf 'PASS  %-58s %s\n' "da-x-icu is still refused in the C database" "refused"
  else
    printf 'FAIL  %-58s %s\n' "da-x-icu is still refused in the C database" "$(echo "$out" | head -1 | cut -c1-120)"
    fail=1
  fi
  q -d "$DB" -q -c "call pgpm.transmute('public.tt_dflt', 'id', interval '1 month', p_obtain => 2,
    p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's', p_tt_alphabet => '0123456789abcdef')" >/dev/null 2>&1
  check "transmute converts hex on a C default collation" "p" \
    "$(v "select relkind from pg_class where oid = 'public.tt_dflt'::regclass")"
  check "every id survived the conversion, by identity" "t" \
    "$(v "select (select array_agg(id order by id) from public.tt_dflt) = (select array_agg(id order by id) from public.tt_ids)")"
fi
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
