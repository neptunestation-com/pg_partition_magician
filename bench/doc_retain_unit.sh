#!/usr/bin/env bash
# Prove that every sentence in the docs stating the unit of an id grid's `retain` names the unit pgpm
# actually uses, measured from pgpm's own behaviour rather than assumed.
#
# WHY THIS GUARD EXISTS (issue #676). docs/runbook.md ("Storage is not dropping despite a retention
# policy") said `retain` is "a **count of intervals** for `id`". pgpm reads it as a count of IDS:
# _retain_boundary subtracts config.retain from the frontier as a raw id distance, and reference.md and
# guide.md both say so. An operator sizing retain from the runbook (retain => 2 on a 1000-wide grid,
# meaning "keep two partitions") keeps only the partition taking writes, and every older partition is
# dropped on the next tick. A wrong unit in prose is not an error anywhere, which is why it has to be
# checked rather than noticed.
#
# HOW. First the unit is MEASURED: an id grid of 1000-wide partitions with retain = 2 and a frontier of
# 9400 is retained once. A count of ids floors 9398 to 9000 and keeps only [9000,10000); a count of
# 1000-wide intervals floors 7400 to 7000 and keeps [7000,10000). The two leave different sets, so the
# fixture cannot read as either by accident. Then every sentence of the docs that names `retain` (or
# `p_retain`) and says "count of <unit>" must name that measured unit.
#   LIVENESS  retain() dropped partitions, the write partition's rows all survived, and the surviving
#             set is one of the two recognisable shapes, so the unit is a measurement and not a default;
#             each of runbook.md, guide.md and reference.md states the unit at least once when the full
#             set is scanned (a deleted statement is a failure, not a vacuous pass);
#   CONTROL   a planted sentence naming the other unit is reported as wrong, so the check can fail.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   runbook_retain_count_of_intervals -- docs/runbook.md's unit put back to "count of intervals" for `id`
#
# Usage: doc_retain_unit.sh <container> <db> [doc]
# With no third argument it scans ONBOARDING.md, README.md and docs/*.md (not docs/reviews/, which
# quotes findings verbatim); with one it scans THAT file only, which is how bench/discriminate.sh points
# it at a mutant (a /repo/... path is mapped to this checkout). The measurement always installs THIS
# checkout's pgpm_core/install.sql into a fresh <db> in <container>, fed from the host, so the container
# need not mount the repository.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY="${3:-}"
fail=0
say() { printf '%s  %-58s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i "$C" psql -U postgres -X "$@"; }
v() { q -d "$DB" -tAq -c "$1" 2>&1; }

DOCS=()
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then say FAIL "the doc to scan exists" "$ONLY"; exit 1; fi
  DOCS=("$ONLY")
else
  DOCS=("$ROOT/ONBOARDING.md" "$ROOT/README.md")
  for f in "$ROOT"/docs/*.md; do DOCS+=("$f"); done
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction <"$ROOT/pgpm_core/install.sql" >/dev/null 2>&1; then
  say FAIL "pgpm_core installed" "$ROOT/pgpm_core/install.sql"; exit 1
fi

q -d "$DB" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
create table public.ru (id bigint primary key, v text);
insert into public.ru select g, 'old' from generate_series(1, 5000) g;
call pgpm.transmute('public.ru', 'id', 1000::bigint, p_obtain => 2, p_retain => 2::bigint);
select pgpm.extend_to('public.ru', '9500', 10);
insert into public.ru select g, 'new' from generate_series(5001, 9400) g;
SQL
parts="select string_agg(lo || '-' || hi, ',' order by lo::numeric) from pgpm.part where parent_table = 'public.ru'::regclass"
before=$(v "$parts")
if [ "$before" = "0-6000,6000-7000,7000-8000,8000-9000,9000-10000" ]; then
  say PASS "LIVENESS: the id grid has the monolith and four partitions" "$before"
else
  say FAIL "LIVENESS: the id grid has the monolith and four partitions" "got: $before"; exit 1
fi
dropped=$(v "select pgpm.retain('public.ru')")
after=$(v "$parts")
if [[ "$dropped" =~ ^[0-9]+$ ]] && [ "$dropped" -gt 0 ]; then
  say PASS "LIVENESS: retain() with retain = 2 dropped partitions" "$dropped dropped, left $after"
else
  say FAIL "LIVENESS: retain() with retain = 2 dropped partitions" "got: $dropped, left $after"; exit 1
fi
live=$(v "select count(*) || ':' || min(id) || ':' || max(id) from public.ru where id >= 9000")
if [ "$live" = "401:9000:9400" ]; then
  say PASS "LIVENESS: the write partition's rows 9000..9400 all survived" "$live"
else
  say FAIL "LIVENESS: the write partition's rows 9000..9400 all survived" "got: $live"; exit 1
fi
case "$after" in
  "9000-10000")                     unit=ids; other=intervals ;;
  "7000-8000,8000-9000,9000-10000") unit=intervals; other=ids ;;
  *) say FAIL "LIVENESS: retain left a recognisable set" "got: $after"; exit 1 ;;
esac
say PASS "LIVENESS: pgpm reads an id grid's retain as a count of $unit" "left $after"
q -q -c "drop database if exists $DB" >/dev/null 2>&1

python3 - "$ROOT" "$unit" "$other" "${ONLY:+single}" "${DOCS[@]}" <<'PY' || fail=1
import os, re, sys
root, unit, other, single, docs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<58} {detail}")

# A statement is a sentence that names retain or p_retain as a word of its own (not retain_batch,
# retain_drop, ...) and says "count of <unit>", bold or not. Sentences end at . ! or ? followed by
# whitespace, and never cross a paragraph or a fenced block.
RETAIN = re.compile(r"(?<![\w])(?:p_)?retain(?![\w])", re.I)
COUNT = re.compile(r"count of\s+\**\s*([a-z]+)", re.I)

def statements(text):
    out, line = [], 1
    for para in re.split(r"(\n[ \t]*\n)", text):
        if para.strip() == "" or para.lstrip().startswith("```"):
            line += para.count("\n"); continue
        flat = re.sub(r"\s+", " ", para)
        start_line = line
        for sent in re.split(r"(?<=[.!?])\s+", flat):
            if RETAIN.search(sent):
                for m in COUNT.finditer(sent):
                    out.append((start_line, m.group(1).lower(), sent.strip()))
        line += para.count("\n")
    return out

ctl = [u for _, u, _ in statements(f"Watch it: `retain` is a **count of {other}** for `id`.\n")]
ok = ctl == [other] and other != unit
say(ok, "CONTROL: a planted wrong unit is reported as wrong", f"planted {other}, read {ctl}")
fail |= not ok

seen = {}
for d in docs:
    rel = os.path.relpath(d, root) if d.startswith(root + os.sep) else d
    for line, u, sent in statements(open(d).read()):
        seen.setdefault(rel, []).append(u)
        ok = u == unit
        say(ok, f"{rel}:~{line}: an id grid's retain is a count of {u}",
            "matches pgpm" if ok else f"pgpm counts {unit}: {sent[:90]}")
        fail |= not ok

want = [os.path.relpath(d, root) if d.startswith(root + os.sep) else d for d in docs] if single else ["docs/runbook.md", "docs/guide.md", "docs/reference.md"]
for rel in want:
    ok = rel in seen
    say(ok, f"LIVENESS: {rel} states the unit of an id grid's retain", f"{len(seen.get(rel, []))} statement(s)")
    fail |= not ok
sys.exit(1 if fail else 0)
PY
exit "$fail"
