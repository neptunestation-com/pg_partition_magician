#!/usr/bin/env bash
# Prove that no line of the docs says a `maintain` pass obtains, and that the docs which describe the two
# scheduled procedures say obtain is `maintain_obtain`'s, measured from pgpm's own behaviour rather than
# assumed.
#
# WHY THIS GUARD EXISTS (issue #1087). README.md's `maintain` bullet called it "the one procedure `pg_cron`
# calls (`obtain`, `retain`, optional auto-`regrain`)", and docs/runbook.md's retention entry annotated
# `call pgpm.maintain(...)` as "one pass: obtain, archive, retain". Obtain left maintain in #347: it is
# `maintain_obtain`'s, on its own `pgpm_obtain` job, and `maintain` does not obtain at all (the reference says
# so). An operator who scheduled or ran maintain alone to keep the grid ahead got no forward partitions, and
# with no DEFAULT partition the first write past the grid was refused.
#
# HOW. First the fact is MEASURED: a table holding ids 1..50 is transmuted onto a 100-wide id grid, unpaused,
# with obtain 2 and retain 150, so it has the monolith [0,100) and the forward cells 100 and 200. Ids 100..250
# are then written, which makes the cells 300 and 400 due and puts the monolith past the retention horizon.
# `call pgpm.maintain` drops the monolith (its retain step ran) and builds no cell; `call pgpm.maintain_all()`
# takes the table's turn and builds no cell either; `call pgpm.maintain_obtain` then builds exactly 300 and
# 400. Then every sentence of the docs, and every line of their fenced code, is read for a claim that
# `maintain` or `maintain_all` obtains: a verb (obtains, runs obtain, keeps the grid ahead, builds the
# forward partitions) or a short list of steps attributed to it, after a `(`, a `:` or a `--`, that names
# obtain. A line that also names `maintain_obtain` or the `pgpm_obtain` job, or negates the list
# (except, not, never, other than), is not such a claim.
#   LIVENESS  the conversion happened and is unpaused with the cells it was given; maintain's own steps did
#             their work (the drop), and maintain_all visited the table, so "built no cell" is not a tick that
#             did nothing; maintain_obtain builds exactly the two cells, so they were due all along;
#             README.md, guide.md, reference.md and runbook.md each name maintain and maintain_obtain
#             together, when the full set is scanned (so a deleted statement is a failure, not a vacuous pass);
#   CONTROL   the pre-fix README bullet, the pre-fix runbook line and a verb phrasing are reported, and the
#             fixed ones are not.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   readme_maintain_obtains -- README.md's pre-#1087 maintain bullet put back
#
# Usage: doc_maintain_does_not_obtain.sh <container> <db> [doc]
# With no third argument it scans ONBOARDING.md, README.md, pgpm_archive/README.md and docs/*.md (not
# docs/reviews/, which quotes findings verbatim); with one it scans THAT file only, which is how
# bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this checkout). The
# measurement always installs THIS checkout's pgpm_core/install.sql into a fresh <db> in <container>, fed
# from the host, so the container need not mount the repository.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY="${3:-}"
fail=0
say() { printf '%s  %-62s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i "$C" psql -U postgres -X "$@"; }
v() { q -d "$DB" -tAq -c "$1" 2>&1; }
need() {   # need <description> <have> <want>: a measured premise; the doc check means nothing without it
  if [ "$2" = "$3" ]; then say PASS "$1" "$2"; else say FAIL "$1" "got: $2, want: $3"; exit 1; fi
}
fact() {   # fact <description> <have> <want>: the measured behaviour the docs are held to
  if [ "$2" = "$3" ]; then say PASS "$1" "$2"; else say FAIL "$1" "got: $2, want: $3"; fail=1; fi
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

if ! q -d "$DB" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
create table public.ev (id bigint primary key, v int);
insert into public.ev select g, g from generate_series(1, 50) g;
call pgpm.transmute('public.ev', 'id', 100::bigint, p_obtain => 2, p_retain => 150, p_paused => false);
insert into public.ev select g, g from generate_series(100, 250) g;
SQL
then say FAIL "fixture: the table was transmuted" ""; exit 1; fi

# the cells' lower bounds, filtered by parent in a materialized CTE before any cast (#973)
cells() { v "with p as materialized (select lo from pgpm.part where parent_table = 'public.ev'::regclass)
              select string_agg(lo, ',' order by lo::numeric) from p"; }
need "LIVENESS: transmute converted public.ev, unpaused" \
  "$(v "select c.relkind::text || ':' || f.paused::text from pg_class c, pgpm.config f
         where c.oid = 'public.ev'::regclass and f.parent_table = 'public.ev'::regclass")" "p:false"
need "LIVENESS: the monolith and the two forward cells it was given" "$(cells)" "0,100,200"

st=$(v "call pgpm.maintain('public.ev')" | tail -1)
fact "FACT: maintain built no forward cell (it dropped the aged monolith)" "$(cells)" "100,200"
need "LIVENESS: maintain's own steps ran: the retain step dropped [0,100)" \
  "$(v "select string_agg(action || ':' || lo, ',' order by id) from pgpm.log
         where parent_table = 'public.ev'::regclass and action = 'retain_drop'")" "retain_drop:0"
case "$st" in
  *dropped=1*) say PASS "LIVENESS: maintain reported the drop" "$st" ;;
  *) say FAIL "LIVENESS: maintain reported the drop" "got: $st"; exit 1 ;;
esac

q -d "$DB" -q -c "call pgpm.maintain_all()" >/dev/null 2>&1
fact "FACT: maintain_all built no forward cell either" "$(cells)" "100,200"
need "LIVENESS: maintain_all took public.ev's turn" \
  "$(v "select sweep_turn_at is not null from pgpm.config where parent_table = 'public.ev'::regclass")" "t"

q -d "$DB" -q -c "call pgpm.maintain_obtain('public.ev')" >/dev/null 2>&1
need "LIVENESS: maintain_obtain builds exactly the due cells 300 and 400" "$(cells)" "100,200,300,400"
q -q -c "drop database if exists $DB" >/dev/null 2>&1
if [ "$fail" != 0 ]; then
  say FAIL "the docs' claim is measured against maintain itself" "maintain obtained; the doc check is moot"
  exit 1
fi

python3 - "$ROOT" "$ONLY" <<'PY' || fail=1
import re, sys
root, only = sys.argv[1], sys.argv[2]
sys.path.insert(0, root + "/bench")
import doc_scan
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}")

FENCE = re.compile(r"^\s*(```|~~~)")

def units(text, doc):
    """Every prose sentence, then every line of fenced code (a `--` comment on a call is a claim too)."""
    for s in doc_scan.sentences(text, doc):
        yield s.line, s.text
    fenced = False
    for n, raw in enumerate(text.split("\n"), 1):
        if FENCE.match(raw):
            fenced = not fenced
        elif fenced:
            yield n, raw

def flat(t):
    return re.sub(r"\s+", " ", doc_scan.plain(t).replace("`", ""))

# maintain or maintain_all, the procedure: never maintain_obtain(_all), never maintains/maintenance
MAINTAIN = re.compile(r"\b(?:pgpm\.)?maintain(?:_all)?\b(?!_)(?: ?\([^)]*\))?")
# obtain the step: not maintain_obtain, pgpm_obtain, p_obtain, config.obtain or obtain_every
OBTAIN = re.compile(r"(?<![._])\bobtain\b(?!_)")
SPLIT = re.compile(r"\bmaintain_obtain|\bpgpm_obtain\b")
NEG = re.compile(r"\b(?:not|never|no longer|except|other than|but|without|separate|unlike)\b", re.I)
VERB = re.compile(r"^\W{0,3}(?:(?:and )?(?:it|which) )?(?:itself |also |then |first )?(?:obtains\b|runs obtain\b|calls obtain\b"
                  r"|does (?:the )?obtain\b|keeps the (?:forward )?grid ahead"
                  r"|(?:builds|creates) (?:the )?(?:forward|future|next)|extends the (?:forward )?grid)", re.I)

def names_maintain(t):
    return bool(MAINTAIN.search(flat(t)))

def claims(t):
    t = flat(t)
    for m in MAINTAIN.finditer(t):
        rest = re.sub(r"^\s*;", "", t[m.end():])
        if VERB.search(rest):
            return True
        # a list of steps attributed to it: after a ( or : or -- in its own clause, up to the next ) or the end
        head = re.match(r"^[^.;]{0,100}", rest).group(0)
        for dm in re.finditer(r"\(|:|--", head):
            seg = re.match(r"[^)]*", rest[dm.end():]).group(0)
            if MAINTAIN.search(seg) or SPLIT.search(seg) or NEG.search(seg):
                continue
            items = [i for i in re.split(r",|/|\band\b|\bor\b|\(", seg) if i.strip()]
            if len(items) >= 2 and all(len(i.split()) <= 4 for i in items) and any(OBTAIN.search(i) for i in items):
                return True
    return False

def splits(t):
    return names_maintain(t) and bool(SPLIT.search(flat(t)))

bad = ["- **`maintain`**: the one procedure `pg_cron` calls (`obtain`, `retain`, optional auto-`regrain`).",
       "   call pgpm.maintain('public.events');       -- one pass: obtain, archive, retain (and auto-regrain)",
       "Schedule `maintain_all` and it obtains ahead of the frontier for every table."]
good = ["- **`maintain`** and **`maintain_obtain`**: the two procedures `pg_cron` calls. `maintain_obtain` runs "
        "`obtain`; `maintain` runs everything else (archive, `retain`, optional auto-`regrain`) and never obtains.",
        "   call pgpm.maintain('public.events');       -- one pass: archive, retain (and auto-regrain); obtain is maintain_obtain's",
        "The per-table `obtain` tick, separate from `maintain`: takes `ACCESS EXCLUSIVE` on the parent.",
        "| **`pgpm_core`** | The product itself: `transmute`/`obtain`/`retain`/`regrain`/`maintain`. | Always. |"]
b = [t for t in bad if claims(t)]
g = [t for t in good if claims(t)]
ok = len(b) == len(bad) and not g
say(ok, "CONTROL: the pre-fix lines and a verb phrasing are flagged",
    f"flagged {len(b)} of {len(bad)} wrong, {len(g)} of {len(good)} right")
fail |= not ok

docs = [only] if only else doc_scan.living_docs(root)
seen, said = {}, {}
for d in docs:
    r = doc_scan.rel(root, d)
    for line, t in units(open(d).read(), r):
        if not names_maintain(t):
            continue
        seen[r] = seen.get(r, 0) + 1
        if splits(t):
            said[r] = said.get(r, 0) + 1
        if claims(t):
            say(False, f"{r}:~{line}: maintain does not obtain",
                f"obtain is maintain_obtain's (the pgpm_obtain job): {flat(t).strip()[:80]}")
            fail = 1
want = [doc_scan.rel(root, only)] if only else ["README.md", "docs/guide.md", "docs/reference.md", "docs/runbook.md"]
for r in want:
    ok = said.get(r, 0) > 0 if not only else seen.get(r, 0) > 0
    say(ok, f"LIVENESS: {r} names maintain and maintain_obtain together" if not only
        else f"LIVENESS: {r} speaks of maintain",
        f"{said.get(r, 0)} of {seen.get(r, 0)} line(s) naming maintain")
    fail |= not ok
if not fail:
    say(True, "no line of the docs says a maintain pass obtains",
        f"{sum(seen.values())} line(s) naming maintain in {len(seen)} doc(s)")
sys.exit(1 if fail else 0)
PY
exit "$fail"
