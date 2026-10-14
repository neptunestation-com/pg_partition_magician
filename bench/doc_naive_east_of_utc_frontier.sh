#!/usr/bin/env bash
# Prove that every paragraph of the docs telling an operator a naive column of local wall time east of UTC
# runs ahead of pgpm's frontier also says that transmute's frontier check refuses that lead past one
# partition step plus one hour, and that `p_force_frontier` is what converts such a table, measured from
# pgpm's own behaviour rather than assumed.
#
# WHY THIS GUARD EXISTS (issue #1275, F1-07). docs/reference.md's transmute entry said that an application
# writing local wall time east of UTC into a `timestamp` column "runs ahead of the frontier by its offset",
# and that the forward slack covers it on an hourly grid given `obtain` greater than the offset in hours.
# But transmute's frontier check (`pgpm._frontier_skew_limit`, now() + one step + one hour) reads the same
# column on the same clock, so an Asia/Tokyo table's current rows, nine hours ahead, are refused on an hourly
# grid as the work of a client with a wrong clock. An operator who followed the paragraph met that refusal
# with `p_obtain => 12` and no word in the paragraph of `p_force_frontier`, the override the refusal names,
# or of what it costs.
#
# HOW. First the facts are MEASURED, each conversion in its own fresh table with rows written as the zone's
# wall time now and back from it, so the newest row leads `now()` by the offset:
#   Asia/Tokyo (+9) on a '1 hour' grid with p_obtain => 12: refused, naming `p_force_frontier`, and the
#     table stays a plain table; the same call with `p_force_frontier => true` converts it, the monolith's
#     `hi` is the hour above the newest row, and a write an hour past Tokyo's wall clock lands in the forward
#     partition of that hour (so `obtain` greater than the offset does cover the lead once converted);
#   Etc/GMT-2 (+2) on a '1 hour' grid: converts without the override (the lead is inside step plus one hour);
#   Asia/Shanghai (+8) on a '6 hours' grid: refused; Asia/Bangkok (+7) on the same grid: converts;
#   Pacific/Kiritimati (+14, the farthest east) on a '1 day' grid with p_obtain => 1: converts.
# Then every paragraph of the docs that puts a column's wall time east of UTC ahead of the frontier must
# name `p_force_frontier` and the allowance (one partition step plus one hour).
#   LIVENESS  each table's newest row really leads `now()` by its offset (so a conversion that passes is
#             not passing on a lead that was never there), and the scanned docs hold at least one such
#             paragraph (so a deleted statement is a failure, not a vacuous pass);
#   CONTROL   the pre-fix paragraph is reported and the fixed one is not.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   reference_naive_east_of_utc_no_force -- docs/reference.md's pre-#1275 paragraph put back
#
# Usage: doc_naive_east_of_utc_frontier.sh <container> <db> [doc]
# With no third argument it scans ONBOARDING.md, README.md, pgpm_archive/README.md and docs/*.md; with one it
# scans THAT file only, which is how bench/discriminate.sh points it at a mutant (a /repo/... path is mapped
# to this checkout). The measurement always installs THIS checkout's pgpm_core/install.sql into a fresh <db>
# in <container>, fed from the host, so the container need not mount the repository.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY="${3:-}"
fail=0
say() { printf '%s  %-66s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i "$C" psql -U postgres -X "$@"; }
v() { q -d "$DB" -tAq -c "$1" 2>&1; }
need() {   # need <description> <have> <want>: a measured fact; the doc check means nothing without it
  if [ "$2" = "$3" ]; then say PASS "$1" "$2"; else say FAIL "$1" "got: $2, want: $3"; exit 1; fi
}

if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then say FAIL "the doc to scan exists" "$ONLY"; exit 1; fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction <"$ROOT/pgpm_core/install.sql" >/dev/null 2>&1; then
  say FAIL "pgpm_core installed" "$ROOT/pgpm_core/install.sql"; exit 1
fi

# mk <table> <zone>: 20 rows of that zone's wall time, the newest one minute before its clock now.
mk() {
  q -d "$DB" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<SQL
create table public.$1 (id bigint not null, ts timestamp not null, primary key (id, ts));
insert into public.$1 select i, (now() at time zone '$2') - i * interval '1 minute' from generate_series(1, 20) i;
SQL
}
# lead <table>: the newest row's lead over now() on the UTC clock, in whole minutes.
lead() { v "select floor(extract(epoch from max(ts) - (now() at time zone 'UTC')) / 60)::int from public.$1"; }
# conv <table> <step> <obtain> [force]: CALL transmute at top level (it commits); prints its exit and stderr.
conv() {
  local force=""; [ -n "${4:-}" ] && force=", p_force_frontier => true"
  q -d "$DB" -v ON_ERROR_STOP=1 -tAq -c "set timezone = 'UTC'" \
    -c "call pgpm.transmute('public.$1', 'ts', interval '$2', p_obtain => $3$force)" 2>&1
}
kind() { v "select relkind from pg_class where oid = 'public.$1'::regclass"; }
witness() {   # witness <table> <minimum lead in minutes> <zone>
  local m; m=$(lead "$1")
  if [[ "$m" =~ ^[0-9]+$ ]] && [ "$m" -ge "$2" ]; then
    say PASS "LIVENESS: $3's newest row leads now() by its offset" "$m min"
  else
    say FAIL "LIVENESS: $3's newest row leads now() by its offset" "got: $m min, want >= $2"; exit 1
  fi
}

# --- Asia/Tokyo, '1 hour', obtain 12: refused, then converted by p_force_frontier --------------------------
mk jp 'Asia/Tokyo'; witness jp 530 'Asia/Tokyo'
jp_oid=$(v "select 'public.jp'::regclass::oid")
out=$(conv jp '1 hour' 12)
case "$out" in
  *"re-run with p_force_frontier => true"*) say PASS "FACT: Tokyo on an hourly grid is refused by the frontier check" "${out:0:70}" ;;
  *) say FAIL "FACT: Tokyo on an hourly grid is refused by the frontier check" "got: ${out:0:160}"; fail=1 ;;
esac
need "FACT: the refused table is untouched (still a plain table)" "$(kind jp)" "r"
out=$(conv jp '1 hour' 12 force)
case "$out" in
  *"p_force_frontier accepted it"*) say PASS "FACT: p_force_frontier => true converts it" "${out:0:70}" ;;
  *) say FAIL "FACT: p_force_frontier => true converts it" "got: ${out:0:160}"; fail=1 ;;
esac
need "FACT: the Tokyo table is partitioned after the forced call" "$(kind jp)" "p"
# The monolith is the original table, attached by oid; its bound is what p_force_frontier accepted.
need "FACT: the monolith (the original table) ends at the hour above the newest row" \
  "$(v "with p as materialized (select hi from pgpm.part where parent_table = 'public.jp'::regclass
                                  and child_oid = $jp_oid)
        select count(*) || ':' || bool_and(hi::timestamp = date_trunc('hour', (select max(ts) from public.jp))
                                                           + interval '1 hour') from p")" "1:true"
q -d "$DB" -q -c "insert into public.jp values (100, (now() at time zone 'Asia/Tokyo') + interval '1 hour')" >/dev/null 2>&1
need "FACT: a write an hour past Tokyo's clock lands in that hour's forward partition" \
  "$(v "with p as materialized (select child_name, lo from pgpm.part where parent_table = 'public.jp'::regclass)
        select (select lo::timestamp from p where child_name = r.tableoid::regclass::text)
               = date_trunc('hour', r.ts) from public.jp r where r.id = 100")" "t"

# --- Etc/GMT-2 (+2), '1 hour': inside step plus one hour, converts without the override -------------------
mk p2 'Etc/GMT-2'; witness p2 100 'Etc/GMT-2'
conv p2 '1 hour' 3 >/dev/null
need "FACT: a +2 lead on an hourly grid converts without p_force_frontier" "$(kind p2)" "p"

# --- '6 hours': Asia/Shanghai (+8) refused, Asia/Bangkok (+7) converts -----------------------------------
mk cn 'Asia/Shanghai'; witness cn 470 'Asia/Shanghai'
out=$(conv cn '6 hours' 2)
case "$out" in
  *"re-run with p_force_frontier => true"*) need "FACT: a +8 lead on a six-hour grid is refused" "$(kind cn)" "r" ;;
  *) say FAIL "FACT: a +8 lead on a six-hour grid is refused" "got: ${out:0:160}"; fail=1 ;;
esac
mk th 'Asia/Bangkok'; witness th 410 'Asia/Bangkok'
conv th '6 hours' 2 >/dev/null
need "FACT: a +7 lead on a six-hour grid converts without p_force_frontier" "$(kind th)" "p"

# --- Pacific/Kiritimati (+14), '1 day', obtain 1: no zone reaches step plus one hour on a day grid ---------
mk ki 'Pacific/Kiritimati'; witness ki 830 'Pacific/Kiritimati'
conv ki '1 day' 1 >/dev/null
need "FACT: a +14 lead on a day grid converts without p_force_frontier" "$(kind ki)" "p"
q -q -c "drop database if exists $DB" >/dev/null 2>&1
[ "$fail" = 0 ] || exit 1

python3 - "$ROOT" "$ONLY" <<'PY' || fail=1
import re, sys
root, only = sys.argv[1], sys.argv[2]
sys.path.insert(0, root + "/bench")
import doc_scan
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<66} {detail}")

def flat(s):
    return re.sub(r"\s+", " ", doc_scan.plain(s).replace("`", ""))

# A paragraph that puts a column's wall time east of UTC ahead of pgpm's frontier.
SUBJECT = re.compile(r"\beast of UTC\b.*\bfrontier\b|\bfrontier\b.*\beast of UTC\b", re.I)
FORCE = re.compile(r"\bp_force_frontier\b")
ALLOWANCE = re.compile(r"\bone (?:partition )?step plus one hour\b", re.I)

def blocks(text, doc):
    seen, out = set(), []
    for s in doc_scan.sentences(text, doc):
        if s.block not in seen:
            seen.add(s.block)
            out.append(s)
    return out

def wrong(s):
    t = flat(s.block)
    return bool(SUBJECT.search(t)) and not (FORCE.search(t) and ALLOWANCE.search(t))

bad = ("A `timestamp` or `date` control column carries no zone. pgpm's write frontier for it is `now()` read on\n"
       "that same clock, so an application writing local wall time from a zone east of UTC runs ahead of the\n"
       "frontier by its offset; the forward slack `obtain x partition_step` covers that on a day or coarser grid\n"
       "with any `obtain` of at least 1, and on an hourly grid needs `obtain` greater than the offset in hours.\n")
good = (bad.rstrip("\n") + " `transmute`'s frontier check (see `p_force_frontier`) refuses a newest value more\n"
        "than one partition step plus one hour past `now()`, so on an hourly grid such a table converts only with\n"
        "`p_force_frontier => true`.\n")
b = [s for s in blocks(bad, "<bad>") if wrong(s)]
g = [s for s in blocks(good, "<good>") if wrong(s)]
ok = len(b) == 1 and not g
say(ok, "CONTROL: the pre-fix paragraph is flagged, the fixed one is not", f"flagged {len(b)} of 1 wrong, {len(g)} of 1 right")
fail |= not ok

docs = [only] if only else doc_scan.living_docs(root)
seen = {}
for d in docs:
    r = doc_scan.rel(root, d)
    for s in blocks(open(d).read(), r):
        if not SUBJECT.search(flat(s.block)):
            continue
        seen[r] = seen.get(r, 0) + 1
        if wrong(s):
            say(False, f"{r}:~{s.line}: transmute refuses that lead past step plus one hour",
                f"name p_force_frontier and the allowance: {flat(s.block)[:80]}")
            fail = 1
want = doc_scan.rel(root, only) if only else "docs/reference.md"
ok = seen.get(want, 0) > 0
say(ok, f"LIVENESS: {want} puts wall time east of UTC ahead of the frontier", f"{seen.get(want, 0)} paragraph(s)")
fail |= not ok
if not fail:
    say(True, "every east-of-UTC frontier paragraph names the refusal and override",
        f"{sum(seen.values())} paragraph(s) in {len(seen)} doc(s)")
sys.exit(1 if fail else 0)
PY
exit "$fail"
