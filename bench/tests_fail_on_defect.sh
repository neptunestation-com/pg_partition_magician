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
    # pass 9 G18: tests/247, 178, 140 and 77, defined with their defects at the end of this file
    247_transmute_non_finite_id_key_test.sql:*|*:tests/247_transmute_non_finite_id_key_test.sql) SEL=" 247 "; F247="$ONLY" ;;
    178_transmute_time_future_maximum_test.sql:*|*:tests/178_transmute_time_future_maximum_test.sql) SEL=" 178 "; F178="$ONLY" ;;
    140_transmute_reap_identity_test.sql:*|*:tests/140_transmute_reap_identity_test.sql) SEL=" 140 "; F140="$ONLY" ;;
    77_retain_incoming_fk_test.sql:*|*:tests/77_retain_incoming_fk_test.sql) SEL=" 77 "; F77="$ONLY" ;;
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

# pass 9 G18 ------------------------------------------------------------------------------------------------
# Issues #994, #995 and #1002: four more files that counted where their own comments promised to name.
#   tests/247 and tests/178 asserted "each conversion logged its own transmute" as one count(*) summed over
#             every converted table, which a log naming one table twice and another never satisfies;
#   tests/140 asserted "rn_old kept every row it had" as count(*) = 22 under a header promising asymmetric
#             fixtures, which a reap that rewrites one row's id satisfies;
#   tests/77  asserted "still attached, and still holds its rows" (fixture 1, mid-retirement) and "left
#             INTACT and attached, not half-retired" (the NO ACTION crossing) by counting pg_inherits rows
#             under the partition's NAME, reading none of its rows, which a retire() that empties the
#             partition satisfies.
# The defects, each this checkout's install.sql with one site changed:
#   transmute_logs_first_parent    every transmute's log row names the first parent ever logged (in a fresh
#                                  database, the file's first conversion), so later conversions log nothing
#                                  of their own: tests/247 and tests/178;
#   reap_rewrites_lowest_id        _transmute_reap, after dropping a table's bound, rewrites its lowest id
#                                  to its negation (rn_old's id 1 reads back as -1): tests/140;
#   retire_empties_at_dispatch     retire() deletes the partition's rows as it dispatches the detach;
#   retire_empties_refused_crossing a crossing refused under NO ACTION first deletes the partition's rows
#                                  that nothing references (all but the crossing key).
# One defect per tests/77 site, each in its own install, so each site's mutation is judged alone: a single
# install carrying both would leave the other site failing under either mutation and prove nothing.
# LIVENESS: for tests/247, 178 and 140 the defect fires inside the file and is read from the database it
# leaves; tests/77 drops its fixtures, so each retire() defect is shown by a probe of its own (a 500-row
# table with an incoming FK, monolith [0, 600)), against the clean install and against the defect.
# The mutations (bench/mutations/mutate.py), each the site's pre-fix text:
#   transmute_log_summed_count_247, transmute_log_summed_count_178, reap_kept_rows_by_count,
#   retiring_partition_attachment_only, crossing_refusal_attachment_only.
T247="tests/247_transmute_non_finite_id_key_test.sql"
T178="tests/178_transmute_time_future_maximum_test.sql"
T140="tests/140_transmute_reap_identity_test.sql"
T77="tests/77_retain_incoming_fk_test.sql"
F247="${F247:-$ROOT/$T247}"; F178="${F178:-$ROOT/$T178}"; F140="${F140:-$ROOT/$T140}"; F77="${F77:-$ROOT/$T77}"
[ -z "$ONLY" ] && SEL="${SEL}247 178 140 77 "

# expect_v <label> <want> <sql>: a LIVENESS read of the database the last run left.
expect_v() {
  local got; got=$(v "$3")
  if [ "$got" = "$2" ]; then say PASS "LIVENESS: $1" "$got"
  else say FAIL "LIVENESS: $1" "want $2, got: $got"; fail=1; fi
}

# ---- tests/247 and tests/178: one transmute log row per converted table, by name ----------------------------
if sel 247 || sel 178; then
  sel 247 && judge_on "$ROOT/pgpm_core/install.sql" "CONTROL: $T247 passes against the clean install" pass "$F247"
  sel 178 && judge_on "$ROOT/pgpm_core/install.sql" "CONTROL: $T178 passes against the clean install" pass "$F178"
  if plant transmute_logs_first_parent \
       "  insert into pgpm.log (parent_table, action) values (v_parent, 'transmute');
" "  insert into pgpm.log (parent_table, action)
    values (coalesce((select l.parent_table from pgpm.log l where l.action = 'transmute' order by l.id limit 1),
                     v_parent), 'transmute');
"; then
    TLOG="select (select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.config)
                 || ' | ' || (select string_agg(parent_table::text, ',' order by id) from pgpm.log where action = 'transmute')"
    if sel 247; then
      judge_on "$work/transmute_logs_first_parent.sql" "DEFECT: $T247 fails, t247_int logged as t247_nan" fail "$F247"
      expect_v "both converted, both transmutes logged as t247_nan" "t247_int,t247_nan | t247_nan,t247_nan" "$TLOG"
    fi
    if sel 178; then
      judge_on "$work/transmute_logs_first_parent.sql" "DEFECT: $T178 fails, all four logged as nb" fail "$F178"
      expect_v "four converted, all four transmutes logged as nb" "fd,ff,nb,nc | nb,nb,nb,nb" "$TLOG"
    fi
  else
    say FAIL "planted the defect: transmute's log row names the first parent" "install.sql moved; fix the pattern"; fail=1
  fi
fi

# ---- tests/140: the rows rn_old kept across the reap, by id ------------------------------------------------
if sel 140; then
  judge_on "$ROOT/pgpm_core/install.sql" "CONTROL: $T140 passes against the clean install" pass "$F140"
  if plant reap_rewrites_lowest_id \
       "      execute format('alter table %s drop constraint if exists pgpm_monolith_bound', r.parent_table::text);
" "      execute format('alter table %s drop constraint if exists pgpm_monolith_bound', r.parent_table::text);
      execute format('update %1\$s set id = -id where ctid = (select ctid from %1\$s order by id limit 1)',
                     r.parent_table::text);
"; then
    judge_on "$work/reap_rewrites_lowest_id.sql" "DEFECT: $T140 fails when the reap rewrites id 1 to -1" fail "$F140"
    expect_v "the reap rewrote rn_old's id 1 to -1, kept 22 rows, dropped the bound" "f:t:22:0" \
      "select (select bool_or(id = 1)::text from public.rn_old)::char || ':' || (select bool_or(id = -1)::text from public.rn_old)::char
              || ':' || (select count(*) from public.rn_old) || ':' || (select count(*) from pg_constraint
                where conrelid = 'public.rn_old'::regclass and conname = 'pgpm_monolith_bound')"
  else
    say FAIL "planted the defect: the reap rewrites the lowest id" "install.sql moved; fix the pattern"; fail=1
  fi
fi

# ---- tests/77: a retiring or refused partition still holds its rows, by id ---------------------------------
# The probe: a 500-row table, monolith [0, 600), the frontier at 1100 (horizon 800), and a referencing table
# pointing at <ref>: 1100 (live, so retire() dispatches the detach) or 42 (inside the partition, so the NO
# ACTION crossing refuses). Reports retire()'s verdict and the partition's rows by identity.
rt_probe() {  # <ref>
  q -d "$DB" -tAq -f - <<SQL 2>&1 | grep -o 'PROBE .*' | head -1
create table public.rt_probe (id bigint generated by default as identity primary key, payload text);
insert into public.rt_probe (payload) select 'x' from generate_series(1, 500);
call pgpm.transmute('public.rt_probe', 'id', 100, p_retain => 300);
select pgpm.obtain('public.rt_probe');
insert into public.rt_probe (id, payload) values (1100, 'frontier');
create table public.rt_probe_ref (id bigint primary key, p_id bigint not null references public.rt_probe(id));
insert into public.rt_probe_ref values (1, $1);
select child_name as rt_doomed from pgpm.part where parent_table = 'public.rt_probe'::regclass and lo = '0' \gset
select (not pgpm.retire('public.rt_probe', :'rt_doomed'))::text as rt_deferred \gset
select 'PROBE ' || :'rt_deferred'
       || '/' || coalesce((select string_agg(action, ',' order by id) from pgpm.log
                            where parent_table = 'public.rt_probe'::regclass
                              and action in ('retain_drop', 'retain_detach', 'fail_retain_detach', 'retain_crossing',
                                             'fail_retain_crossing', 'fail_retain_drop')), '')
       || '/' || coalesce((select array_agg(id order by id) from public.rt_probe
                            where tableoid = to_regclass(format('public.%I', :'rt_doomed')) and id in (1, 42, 500))::text, '{}')
       || '/' || (select count(*) from public.rt_probe where tableoid = to_regclass(format('public.%I', :'rt_doomed')));
SQL
}
# probe_on <install.sql> <ref> <label> <want>
probe_on() {
  local got
  if fresh && install "$1"; then
    got=$(rt_probe "$2")
    if [ "$got" = "PROBE $4" ]; then say PASS "LIVENESS: $3" "$got"
    else say FAIL "LIVENESS: $3" "want PROBE $4, got: ${got:-no PROBE line}"; fail=1; fi
  else say FAIL "LIVENESS: $3: the install loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1; fi
}
if sel 77; then
  probe_on "$ROOT/pgpm_core/install.sql" 1100 "the clean retire() dispatches and keeps the rows" \
    "true/fail_retain_detach/{1,42,500}/500"
  probe_on "$ROOT/pgpm_core/install.sql" 42 "the clean crossing refusal keeps the rows" \
    "true/fail_retain_crossing/{1,42,500}/500"
  judge_on "$ROOT/pgpm_core/install.sql" "CONTROL: $T77 passes against the clean install" pass "$F77"
  if plant retire_empties_at_dispatch \
       "      v_reason := pgpm._dispatch_detach(p_parent, v_child);
" "      perform pgpm._remove_write_block(p_parent, p_child);
      execute format('delete from %s', v_child);
      perform pgpm._install_write_block(p_parent, p_child);
      v_reason := pgpm._dispatch_detach(p_parent, v_child);
"; then
    probe_on "$work/retire_empties_at_dispatch.sql" 1100 "the defect's retire() dispatches with the rows gone" \
      "true/fail_retain_detach/{}/0"
    judge_on "$work/retire_empties_at_dispatch.sql" "DEFECT: $T77 fails when retire() empties at dispatch" fail "$F77"
  else
    say FAIL "planted the defect: retire() empties the partition at dispatch" "install.sql moved; fix the pattern"; fail=1
  fi
  if plant retire_empties_refused_crossing \
       "        exception when others then
          insert into pgpm.log (parent_table, action, lo, hi, method)
            values (p_parent, 'fail_retain_crossing', r.lo, r.hi, left(sqlerrm, 200));
" "        exception when others then
          perform pgpm._remove_write_block(p_parent, p_child);
          execute format('delete from %s where not (%I = any (%L::text[]::%s[]))',
            v_child, cfg.control_column, v_cross, v_coltype);
          perform pgpm._install_write_block(p_parent, p_child);
          insert into pgpm.log (parent_table, action, lo, hi, method)
            values (p_parent, 'fail_retain_crossing', r.lo, r.hi, left(sqlerrm, 200));
"; then
    probe_on "$work/retire_empties_refused_crossing.sql" 42 "the defect's refusal leaves only the crossing row" \
      "true/fail_retain_crossing/{42}/1"
    judge_on "$work/retire_empties_refused_crossing.sql" "DEFECT: $T77 fails when a refused crossing half-retires" fail "$F77"
  else
    say FAIL "planted the defect: a refused crossing deletes the unreferenced rows" "install.sql moved; fix the pattern"; fail=1
  fi
fi

if [ "$fail" = 0 ]; then say PASS "every judged test file fails against its defect" "${SEL# }"
else say FAIL "every judged test file fails against its defect" "${SEL# }"; fi
exit "$fail"
