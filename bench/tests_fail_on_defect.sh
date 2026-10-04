#!/usr/bin/env bash
# Prove that seven pgTAP files FAIL against the defect each exists to catch, by putting the defect back and
# running the file: a test that also passes against broken code is not evidence of anything.
#
# WHY THIS GUARD EXISTS (issues #743 and #744). Each of these files passed against the very defect it
# names, the repo's oldest class (CLAUDE.md, "Assertions that pass for the wrong reason"):
#   tests/18  pinned the orphaned-child refusal by SQLSTATE alone, and in its own fixture the one-step
#             monolith's name IS the planted orphan's name, so with the orphan guard deleted transmute was
#             still refused with P0001, by the monolith-name guard, and the file passed;
#   tests/90  asserted _radix_decode's alphabet-length refusal with throws_ok(sql, NULL, NULL) on a digit
#             outside the alphabet, which raises the invalid-digit 22P02 with or without that check;
#   tests/11  took their "before" row count AFTER fixtures/demo.sql had already run the migration and
#   tests/12  compared the table's count with it in the next statement: count = count.
# And issue #919: tests/92 promised 'identity, not just cardinality' for the rows its regrain moved and
#   asserted count(*) = 250 over ids 1..2500, which a swap that loses row 2500 and invents 2499 satisfies.
#   tests/88  (issue #881) claimed text_time's #325 drought immunity for cuid, and tests/91 for ULID and
#   tests/91  KSUID, but asserted only that a partition covers now() and that a row at now() is accepted.
#             Both hold with text_time dropped from _frontier_native's greatest(decoded, now()), because
#             transmute's monolith takes its upper bound from its OWN inline greatest() and so covers now()
#             by itself on the day of the transmute (tests/85 explains it for uuidv7); only
#             bench/frontier_drought.sh caught that mutant.
#
# HOW. Per file, the same two runs, in fresh databases named <db> in <container>:
#   CONTROL   the file passes, every planned assertion ok, against the clean pgpm (and fixtures);
#   DEFECT    the file reports at least one `not ok` (and runs to its end) against the defect:
#               tests/18  this checkout's install.sql with the orphan guard's two raises made unreachable;
#               tests/90  the same with _radix_decode's alphabet-length check made unreachable;
#               tests/11, tests/12  the clean install and fixtures, with two seeded rows ('evt 1', 'evt 2')
#                         replaced by strangers under the same ids AFTER the migration: rows lost and
#                         rows added that cancel in a count, so only an identity check can see them;
#               tests/92  this checkout's install.sql whose regrain swap, after the source is dropped,
#                         rewrites the highest copied key in the cell by one (2500 becomes 2499): one row
#                         lost and one row invented, same count;
#               tests/88, tests/91  this checkout's install.sql with text_time dropped from
#                         _frontier_native's clock blend (uuidv7 keeps it), the pre-#325 shape for that
#                         kind alone.
#   LIVENESS  each defect is shown present before its file is judged: the mutant install lets an orphan
#             through to a different refusal (and the clean one names the orphan), the mutant decodes a
#             digit under a 5-character alphabet at radix 10 (the clean one refuses it), and the edited
#             tables hold the seeded count without 'evt 1' and 'evt 2'; for tests/92, read after the file
#             has run (the defect fires inside its regrain), the swap happened once, 2500 is gone, 2499 is
#             there and the table still holds 251 rows; and a stale text_time table's frontier under the
#             mutant is its 11-month-old data maximum with no partition built past the monolith (under the
#             clean install: at or past now(), with one). A defect that was never planted
#             would make the file's failure meaningless and its pass vacuous.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each the file's pre-fix text:
#   orphan_refusal_sqlstate_only       -- tests/18's refusal back to throws_ok(..., 'P0001', null, desc)
#   radix_length_refusal_unpinned      -- tests/90's refusal back to throws_ok on '5' with NULL, NULL
#   id_conservation_after_migration    -- tests/11's count back to a snapshot taken after the migration
#   uuid_conservation_after_migration  -- tests/12's, likewise
#   regrain_survivors_by_count         -- tests/92's identity check back to count(*) = 250 over 1..2500
#   text_time_drought_coverage_only    -- tests/88's drought checks back to "a partition covers now()"
#   text_time_drought_coverage_only_ulid_ksuid -- tests/91's, likewise
#
# Usage: tests_fail_on_defect.sh <container> <db> [test file]
# With no third argument it judges all seven files in this checkout. With one it judges THAT file in place
# of the one it stands for, recognised by its file name or, for a mutant bench/discriminate.sh built
# (<mutation>.sql), by the mutation's MUTATION_SRC; a /repo/... path is mapped to this checkout. Every
# install and test is fed from the host over stdin, so the container need not mount the repository; it
# needs pgtap (the plain core image has it). Needs python3 on the host.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ONLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
say() { printf '%s  %-58s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i "$C" psql -U postgres -X "$@"; }
v() { q -d "$DB" -tAq -c "$1" </dev/null 2>&1; }
work=$(mktemp -d)
cleanup() { q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

T18="tests/18_orphan_child_guard_test.sql"
T90="tests/90_text_time_alphabet_codec_test.sql"
T11="tests/11_id_kind_test.sql"
T12="tests/12_uuidv7_kind_test.sql"
T92="tests/92_regrain_outgoing_fk_test.sql"
T88="tests/88_text_time_transmute_test.sql"
T91="tests/91_text_time_ulid_ksuid_transmute_test.sql"
F18="$ROOT/$T18"; F90="$ROOT/$T90"; F11="$ROOT/$T11"; F12="$ROOT/$T12"; F92="$ROOT/$T92"; F88="$ROOT/$T88"; F91="$ROOT/$T91"
SEL=" 18 90 11 12 92 88 91 "

if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then say FAIL "the test file to judge exists" "$ONLY"; exit 1; fi
  base=$(basename "$ONLY")
  src=$(python3 - "$ROOT/bench/mutations" "${base%.*}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import mutate
print(mutate.MUTATION_SRC.get(sys.argv[2], ""))
PY
)
  case "$base:$src" in
    "$(basename "$T18")":*|*:"$T18") SEL=" 18 "; F18="$ONLY" ;;
    "$(basename "$T90")":*|*:"$T90") SEL=" 90 "; F90="$ONLY" ;;
    "$(basename "$T11")":*|*:"$T11") SEL=" 11 "; F11="$ONLY" ;;
    "$(basename "$T12")":*|*:"$T12") SEL=" 12 "; F12="$ONLY" ;;
    "$(basename "$T92")":*|*:"$T92") SEL=" 92 "; F92="$ONLY" ;;
    "$(basename "$T88")":*|*:"$T88") SEL=" 88 "; F88="$ONLY" ;;
    "$(basename "$T91")":*|*:"$T91") SEL=" 91 "; F91="$ONLY" ;;
    *) say FAIL "the file to judge is one of the seven this guard knows" "$ONLY -> '${src}'"; exit 1 ;;
  esac
fi
sel() { [[ "$SEL" == *" $1 "* ]]; }

fresh() {  # a fresh <db> with pgtap
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "create database $DB" </dev/null >/dev/null 2>&1 &&
    q -d "$DB" -q -c "create extension if not exists pgtap" </dev/null >/dev/null 2>&1
}
install() {  # <install.sql text to load>
  q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f - <"$1" >"$work/install.log" 2>&1
}

# plant <name> <find> <replace> [<find> <replace> ...]: this checkout's install.sql with each <find>
# replaced exactly once, written to $work/<name>.sql. A pattern that no longer matches exactly once is a
# FAILURE, never a silently unmutated copy (the discipline of mutate.py).
plant() {
  local name="$1"; shift
  python3 - "$ROOT/pgpm_core/install.sql" "$work/$name.sql" "$@" <<'PY'
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
t = open(src).read()
for find, repl in zip(pairs[::2], pairs[1::2]):
    n = t.count(find)
    if n != 1:
        sys.exit(f"pattern matched {n} time(s), expected 1: {find.splitlines()[0]!r}")
    t = t.replace(find, repl)
open(dst, "w").write(t)
PY
}

# judge <label> <expect: pass|fail> <test file>: run the file in <db> and read its TAP.
judge() {
  local label="$1" expect="$2" file="$3" out rc planned oks notoks
  out=$(q -d "$DB" -v ON_ERROR_STOP=1 -tA -f - <"$file" 2>&1); rc=$?
  planned=$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' <<<"$out" | head -1)
  oks=$(grep -cE '^ok [0-9]+' <<<"$out")
  notoks=$(grep -cE '^not ok [0-9]+' <<<"$out")
  if [ "$rc" != 0 ] || [ -z "$planned" ] || [ $((oks + notoks)) != "$planned" ]; then
    say FAIL "$label: the file ran to its end" "psql exit $rc, plan ${planned:-none}, $oks ok, $notoks not ok"
    grep -E 'ERROR|^not ok' <<<"$out" | head -5 | sed 's/^/      /'
    fail=1; return
  fi
  if [ "$expect" = pass ]; then
    if [ "$notoks" = 0 ]; then say PASS "$label" "$oks/$planned ok"
    else
      say FAIL "$label" "$notoks not ok of $planned"
      grep -E '^not ok' <<<"$out" | sed 's/^/      /'; fail=1
    fi
  else
    if [ "$notoks" -gt 0 ]; then
      say PASS "$label" "$(grep -E '^not ok' <<<"$out" | head -1 | cut -c1-70)"
    else
      say FAIL "$label" "all $planned ok against the defect: the file passes for the wrong reason"; fail=1
    fi
  fi
}

# ---- tests/18: the orphaned-child guard --------------------------------------------------------------
# The probe: a table with a planted orphan in a fixture of its own; reports the refusal's message.
ORPHAN_PROBE="create table public.og_probe (id bigint generated by default as identity primary key, payload text);
insert into public.og_probe (payload) select 'x' from generate_series(1, 300);
create table public.og_probe_p0000000000000000000 (like public.og_probe);
do \$\$ begin
  call pgpm.transmute('public.og_probe', 'id', 100000);
  raise notice 'PROBE accepted';
exception when others then raise notice 'PROBE % %', sqlstate, sqlerrm; end \$\$;
drop table public.og_probe_p0000000000000000000; drop table public.og_probe;"
ORPHAN_MSG="standalone table matching this parent's partition naming"
if sel 18; then
  if fresh && install "$ROOT/pgpm_core/install.sql"; then
    probe=$(q -d "$DB" -q -f - <<<"$ORPHAN_PROBE" 2>&1 | grep -o 'PROBE .*' | head -1)
    if [[ "$probe" == "PROBE P0001 "*"$ORPHAN_MSG"* ]]; then
      say PASS "LIVENESS: the clean install refuses the probe's orphan by name" "${probe:0:70}"
    else
      say FAIL "LIVENESS: the clean install refuses the probe's orphan by name" "${probe:-no PROBE line}"; fail=1
    fi
    judge "CONTROL: $T18 passes against the clean install" pass "$F18"
  else
    say FAIL "the clean install loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
  fi
  if plant no_orphan_guard \
       "    if v_orphan is not null and v_orphan_kind = 'r' then
" "    if false then
" \
       "    elsif v_orphan is not null then
" "    elsif false then
"; then
    if fresh && install "$work/no_orphan_guard.sql"; then
      probe=$(q -d "$DB" -q -f - <<<"$ORPHAN_PROBE" 2>&1 | grep -o 'PROBE .*' | head -1)
      if [[ "$probe" == "PROBE P0001 "* && "$probe" != *"$ORPHAN_MSG"* ]]; then
        say PASS "LIVENESS: with no orphan guard another P0001 refuses it" "${probe:0:70}"
      else
        say FAIL "LIVENESS: with no orphan guard another P0001 refuses it" "${probe:-no PROBE line}"; fail=1
      fi
      judge "DEFECT: $T18 fails with the orphan guard gone" fail "$F18"
    else
      say FAIL "the install with no orphan guard loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  else
    say FAIL "planted the defect: the orphan guard's two raises" "install.sql moved; fix the pattern"; fail=1
  fi
fi

# ---- tests/90: _radix_decode's alphabet-length check -------------------------------------------------
RADIX_PROBE="select pgpm._radix_decode('3', 10, '01234')"
if sel 90; then
  if fresh && install "$ROOT/pgpm_core/install.sql"; then
    got=$(v "$RADIX_PROBE")
    if [[ "$got" == *"alphabet 01234 has length 5, which does not match radix 10"* ]]; then
      say PASS "LIVENESS: the clean _radix_decode refuses the short alphabet" "length check raised"
    else
      say FAIL "LIVENESS: the clean _radix_decode refuses the short alphabet" "got: $got"; fail=1
    fi
    judge "CONTROL: $T90 passes against the clean install" pass "$F90"
  else
    say FAIL "the clean install loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
  fi
  if plant no_length_check \
       "declare v_alphabet text; v_c text; v_d int; v_acc numeric := 0;
begin
  if p_alphabet is not null then
    if length(p_alphabet) <> p_radix then
" "declare v_alphabet text; v_c text; v_d int; v_acc numeric := 0;
begin
  if p_alphabet is not null then
    if false then
"; then
    if fresh && install "$work/no_length_check.sql"; then
      got=$(v "$RADIX_PROBE")
      if [ "$got" = 3 ]; then
        say PASS "LIVENESS: with no length check '3' decodes under it" "got 3"
      else
        say FAIL "LIVENESS: with no length check '3' decodes under it" "got: $got"; fail=1
      fi
      judge "DEFECT: $T90 fails with the length check gone" fail "$F90"
    else
      say FAIL "the install with no length check loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  else
    say FAIL "planted the defect: _radix_decode's length check" "install.sql moved; fix the pattern"; fail=1
  fi
fi

# ---- tests/11 and tests/12: row conservation across the demo migration ------------------------------
if sel 11 || sel 12; then
  if fresh && install "$ROOT/pgpm_core/install.sql" &&
     q -d postgres -q -c "alter database $DB set poc.seed_count = 8000; alter database $DB set poc.events_count = 4000;" </dev/null >/dev/null 2>&1 &&
     q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$ROOT/fixtures/demo.sql" >"$work/fixtures.log" 2>&1; then
    sel 11 && judge "CONTROL: $T11 passes on the demo fixtures" pass "$F11"
    sel 12 && judge "CONTROL: $T12 passes on the demo fixtures" pass "$F12"
    for t in events_id events_uuid; do
      if [ "$t" = events_id ]; then sel 11 || continue; else sel 12 || continue; fi
      before=$(v "select count(*) from public.$t")
      # Two seeded rows lost after the migration, two strangers in their place under the same ids.
      v "with d as (delete from public.$t where payload in ('evt 1', 'evt 2') returning id)
         insert into public.$t (id, payload) select id, 'not seeded' from d" >/dev/null
      after=$(v "select count(*) || ':' || count(*) filter (where payload in ('evt 1', 'evt 2'))
                       || ':' || count(*) filter (where payload = 'not seeded') from public.$t")
      if [ "$before" = 4000 ] && [ "$after" = "4000:0:2" ]; then
        say PASS "LIVENESS: $t lost 'evt 1' and 'evt 2', count unchanged" "4000 rows, 0 seeded of the two, 2 strangers"
      else
        say FAIL "LIVENESS: $t lost 'evt 1' and 'evt 2', count unchanged" "before $before, after count:seeded:strangers $after"; fail=1
      fi
    done
    sel 11 && judge "DEFECT: $T11 fails with two seeded rows replaced" fail "$F11"
    sel 12 && judge "DEFECT: $T12 fails with two seeded rows replaced" fail "$F12"
  else
    say FAIL "the clean install and fixtures/demo.sql loaded" "$(cat "$work/install.log" "$work/fixtures.log" 2>/dev/null | grep -m1 ERROR)"; fail=1
  fi
fi

# ---- tests/92: the rows regrain's swap moved, by identity ---------------------------------------------
# The defect fires inside the file's own regrain, so its liveness is read from the database the file left.
SWAP_LOG="insert into pgpm.log (parent_table, action, lo, hi, rows, method) values (p_parent, 'regrain', v_lo, v_hi, v_made, 'copy_swap_drop');
"
if sel 92; then
  if fresh && install "$ROOT/pgpm_core/install.sql"; then
    judge "CONTROL: $T92 passes against the clean install" pass "$F92"
  else
    say FAIL "the clean install loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
  fi
  if plant swap_rewrites_key "  $SWAP_LOG" \
       "  execute format('update %s set %I = %I - 1 where %I = (select max(%I) from %s where %I < %L)',
    p_parent, cfg.control_column, cfg.control_column, cfg.control_column, cfg.control_column, p_parent,
    cfg.control_column, v_hi);
  $SWAP_LOG"; then
    if fresh && install "$work/swap_rewrites_key.sql"; then
      judge "DEFECT: $T92 fails when the swap loses 2500 and invents 2499" fail "$F92"
      got=$(v "select (select count(*) from pgpm.log where parent_table = 'public.ofk92'::regclass
                         and action = 'regrain' and method = 'copy_swap_drop')
                   || ':' || exists (select 1 from public.ofk92 where id = 2500)
                   || ':' || exists (select 1 from public.ofk92 where id = 2499)
                   || ':' || (select count(*) from public.ofk92)")
      if [ "$got" = "1:false:true:251" ]; then
        say PASS "LIVENESS: the swap ran once, lost 2500, invented 2499" "swaps:has2500:has2499:rows $got"
      else
        say FAIL "LIVENESS: the swap ran once, lost 2500, invented 2499" "swaps:has2500:has2499:rows $got"; fail=1
      fi
    else
      say FAIL "the install whose swap rewrites a key loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  else
    say FAIL "planted the defect: a key rewrite after regrain's swap" "install.sql moved; fix the pattern"; fail=1
  fi
fi

# ---- tests/88 and tests/91: text_time's #325 drought immunity ----------------------------------------
# The probe: a cuid table backfilled 13 and 11 months stale, monthly step, p_obtain => 2 (tests/88's own
# fixture), one maintenance tick, then "<frontier is stale>/<a partition starts at or past the monolith's
# hi>". The clean install reads false/true; the mutant must read true/false, or its DEFECT run judges a
# defect that was never planted.
TT_PROBE="create table public.tt_probe (id text primary key, body text);
insert into public.tt_probe values
  (pgpm._ts_to_text_time(now() - interval '13 months', 'c', 8, 36, 'ms'), 'oldest'),
  (pgpm._ts_to_text_time(now() - interval '11 months', 'c', 8, 36, 'ms'), 'newest');
call pgpm.transmute('public.tt_probe', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
select pgpm.resume('public.tt_probe');
call pgpm.maintain('public.tt_probe');
select 'PROBE ' || (pgpm._frontier_native('public.tt_probe')::timestamptz < now() - interval '10 months')::text
       || '/' || exists (select 1 from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table
                          join pgpm.part m on m.parent_table = c.parent_table and m.child_oid = c.monolith_oid
                         where p.parent_table = 'public.tt_probe'::regclass and p.attached
                           and p.lo::timestamptz >= m.hi::timestamptz)::text;"
tt_probe() { q -d "$DB" -tAq -f - <<<"$TT_PROBE" 2>&1 | grep -o 'PROBE .*' | head -1; }
# judge_on <install.sql> <label> <expect> <test file>: judge the file in a fresh <db> holding that install.
judge_on() {
  if fresh && install "$1"; then judge "$2" "$3" "$4"
  else say FAIL "$2: the install loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1; fi
}
if sel 88 || sel 91; then
  if fresh && install "$ROOT/pgpm_core/install.sql"; then
    probe=$(tt_probe)
    if [ "$probe" = "PROBE false/true" ]; then
      say PASS "LIVENESS: the clean text_time frontier is now(), grid grows" "$probe"
    else
      say FAIL "LIVENESS: the clean text_time frontier is now(), grid grows" "${probe:-no PROBE line}"; fail=1
    fi
    sel 88 && judge_on "$ROOT/pgpm_core/install.sql" "CONTROL: $T88 passes against the clean install" pass "$F88"
    sel 91 && judge_on "$ROOT/pgpm_core/install.sql" "CONTROL: $T91 passes against the clean install" pass "$F91"
  else
    say FAIL "the clean install loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
  fi
  if plant text_time_frontier_data_only \
       "  if cfg.control_kind in ('uuidv7', 'text_time') then
    return pgpm._ts_text(greatest(v_decoded::timestamptz, now()));
" "  if cfg.control_kind in ('uuidv7') then
    return pgpm._ts_text(greatest(v_decoded::timestamptz, now()));
"; then
    if fresh && install "$work/text_time_frontier_data_only.sql"; then
      probe=$(tt_probe)
      if [ "$probe" = "PROBE true/false" ]; then
        say PASS "LIVENESS: the mutant text_time frontier is the stale max" "$probe"
      else
        say FAIL "LIVENESS: the mutant text_time frontier is the stale max" "${probe:-no PROBE line}"; fail=1
      fi
      sel 88 && judge_on "$work/text_time_frontier_data_only.sql" "DEFECT: $T88 fails with text_time's clock blend gone" fail "$F88"
      sel 91 && judge_on "$work/text_time_frontier_data_only.sql" "DEFECT: $T91 fails with text_time's clock blend gone" fail "$F91"
    else
      say FAIL "the install with text_time's clock blend gone loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  else
    say FAIL "planted the defect: _frontier_native's text_time blend" "install.sql moved; fix the pattern"; fail=1
  fi
fi

if [ "$fail" = 0 ]; then say PASS "every judged test file fails against its defect" "${SEL# }"
else say FAIL "every judged test file fails against its defect" "${SEL# }"; fi
exit "$fail"
