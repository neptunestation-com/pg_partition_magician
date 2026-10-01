#!/usr/bin/env bash
# Prove that no sentence in the docs tells the operator retention is dormant over an unregrained monolith,
# and that the docs which describe it say it drops whole, measured from pgpm's own behaviour rather than
# assumed.
#
# WHY THIS GUARD EXISTS (issue #741). README.md ("a translated drop_chunks retention stays dormant until you
# add a key and regrain the history (retain drops fine partitions, not the monolith)") and
# docs/reference.md's from_hypertable notes ("retention over the unregrained monolith is dormant until you
# regrain it ... a keyless migration ... will not reclaim disk until a key is added and the monolith is
# regrained") both said an unregrained keyless monolith is out of retention's reach. It is not: once its
# whole range is past the horizon, retain() drops it, whole, in one step, as the reference's own `retain`
# section and the guide say. An operator who trusted "dormant" lost the whole migrated history in one
# cliff they had been told could not happen.
#
# HOW. First the fact is MEASURED on a keyless table (no primary key, no unique index, so regrain is not
# available to it) transmuted into a coarse monolith [0,3000) holding 2500 rows, with retain 5000: the
# frontier is moved to 20000, so the monolith's whole range is past the horizon, and retain() runs once.
# It drops the monolith (a retain_drop row for exactly [0,3000), the relation gone, none of its rows left)
# and keeps the partition holding the frontier row. Then every sentence of the docs that speaks of
# retention (retain, retention, drop_chunks) over a monolith or coarse, unregrained history must not call
# it dormant or inert, say retain drops only fine partitions or "not the monolith", or say it will not
# reclaim disk.
#   LIVENESS  the table really is keyless and its history really is one unregrained coarse child before
#             retain(); the frontier row survived it; README.md, guide.md and reference.md each say, when
#             the full set is scanned, that the monolith drops whole (so a deleted statement is a failure,
#             not a vacuous pass);
#   CONTROL   the pre-fix sentences are reported as wrong, and a planted right one is not.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   reference_keyless_monolith_dormant -- docs/reference.md's pre-#741 from_hypertable caveat put back
#
# Usage: doc_monolith_retention.sh <container> <db> [doc]
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
create table public.kl (id bigint not null, v int);          -- keyless: no PK, no unique index
insert into public.kl select g, g from generate_series(1, 2500) g;
call pgpm.transmute('public.kl', 'id', 1000::bigint, p_retain => 5000::bigint, p_obtain => 2);
select pgpm.extend_to('public.kl', '20000');
insert into public.kl values (20000, 0);
create table public.mono as
  select child_oid from pgpm.part where parent_table = 'public.kl'::regclass and lo = '0';
SQL
then say FAIL "fixture: the keyless table was transmuted and grown" ""; exit 1; fi

need "LIVENESS: the table is keyless (regrain is not available to it)" \
  "$(v "select count(*) from pg_index where indrelid = 'public.kl'::regclass and indisunique")" "0"
need "LIVENESS: its history is one unregrained coarse child [0,3000)" \
  "$(v "select string_agg(lo || '-' || hi, ',') from pgpm.part where parent_table = 'public.kl'::regclass and lo::numeric < 3000")" "0-3000"
need "LIVENESS: status() reports the history unregrained" \
  "$(v "select history_unregrained from pgpm.status() where parent = 'public.kl'::regclass")" "t"
dropped=$(v "select pgpm.retain('public.kl')")
if [[ "$dropped" =~ ^[0-9]+$ ]] && [ "$dropped" -gt 0 ]; then
  say PASS "LIVENESS: retain() dropped partitions" "$dropped"
else
  say FAIL "LIVENESS: retain() dropped partitions" "got: $dropped"; exit 1
fi
need "FACT: retain() dropped the monolith [0,3000) in one step" \
  "$(v "select count(*) from pgpm.log where parent_table = 'public.kl'::regclass and action = 'retain_drop' and lo = '0' and hi = '3000'")" "1"
need "FACT: the monolith relation is gone, and all 2500 of its rows" \
  "$(v "select (select count(*) from pg_class where oid = (select child_oid from public.mono)) || ':' || (select count(*) from public.kl where id <= 2500)")" "0:0"
need "LIVENESS: the frontier row survived retain()" "$(v "select count(*) from public.kl where id = 20000")" "1"
q -q -c "drop database if exists $DB" >/dev/null 2>&1

python3 - "$ROOT" "$ONLY" <<'PY' || fail=1
import re, sys
root, only = sys.argv[1], sys.argv[2]
sys.path.insert(0, root + "/bench")
import doc_scan
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}")

SUBJECT = re.compile(r"\bmonolith\b|\bcoarse\b|un-?regrained", re.I)
RETAIN = re.compile(r"(?<![\w])(?:retain|retention|drop_chunks)(?![\w])", re.I)
DORMANT = re.compile(r"\bdormant\b|\binert\b|not the monolith|only drops (?:attached )?fine|will not reclaim"
                     r"|won't reclaim|out of retention's reach|\bis exempt\b|\bnever drops\b", re.I)
WHOLE = re.compile(r"\bnot exempt\b|drops? (?:it )?whole|drops like any other|\bin one step\b", re.I)

def about(s):
    t = doc_scan.plain(s.text)
    return bool(SUBJECT.search(t) and RETAIN.search(t))

def wrong(s):
    return about(s) and bool(DORMANT.search(doc_scan.plain(s.text)))

def whole(s):
    return about(s) and bool(WHOLE.search(doc_scan.plain(s.text)))

bad = ("One keyless caveat: a translated `drop_chunks` retention stays dormant until you add a key and `regrain` the\n"
       "history (`retain` drops fine partitions, not the monolith).\n\n"
       "- A carried-over `drop_chunks` retention policy is auto-translated into `pgpm`'s `retain`, but retention over\n"
       "  the unregrained **monolith is dormant** until you `regrain` it (`retain` only drops attached fine partitions),\n"
       "  and `regrain` is unavailable on a keyless monolith. So a keyless migration that relied on `drop_chunks` will\n"
       "  not reclaim disk until a key is added and the monolith is regrained.\n")
good = ("A translated `drop_chunks` retention covers the monolith too: `retain` drops it whole, in one step, once its\n"
        "entire range is past the horizon.\n")
b = [s for s in doc_scan.sentences(bad) if wrong(s)]
g = [s for s in doc_scan.sentences(good) if wrong(s)]
gw = [s for s in doc_scan.sentences(good) if whole(s)]
ok = len(b) == 3 and not g and len(gw) == 1
say(ok, "CONTROL: the pre-fix caveats are flagged, the right one is not",
    f"flagged {len(b)} of 3 wrong, {len(g)} of the right; right one read {len(gw)}")
fail |= not ok

docs = [only] if only else doc_scan.living_docs(root)
seen, said = {}, {}
for d in docs:
    r = doc_scan.rel(root, d)
    for s in doc_scan.sentences(open(d).read(), r):
        if not about(s):
            continue
        seen[r] = seen.get(r, 0) + 1
        if whole(s):
            said[r] = said.get(r, 0) + 1
        if wrong(s):
            say(False, f"{r}:~{s.line}: monolith retention is not dormant",
                f"retain() drops an unregrained monolith whole: {s.text[:80]}")
            fail = 1
want = [doc_scan.rel(root, only)] if only else ["README.md", "docs/guide.md", "docs/reference.md"]
for r in want:
    ok = said.get(r, 0) > 0 if not only else seen.get(r, 0) > 0
    say(ok, f"LIVENESS: {r} says the monolith drops whole",
        f"{said.get(r, 0)} of {seen.get(r, 0)} monolith-retention statement(s)")
    fail |= not ok
if not fail:
    say(True, "every monolith-retention statement agrees with retain()",
        f"{sum(seen.values())} statement(s) in {len(seen)} doc(s)")
sys.exit(1 if fail else 0)
PY
exit "$fail"
