#!/usr/bin/env bash
# Prove that every sentence in the docs reading a standing `status().fks_suspended` names what pgpm
# actually leaves it standing for (a transmute cutover's preserve drop that restore_incoming_fks has not
# re-added yet), measured from pgpm's own behaviour rather than assumed.
#
# WHY THIS GUARD EXISTS (issue #740). docs/reference.md's `status` entry said "`fks_suspended` is a
# transient state inside a regrain swap now, so a standing non-zero value means a swap died mid-flight".
# A plain `transmute(..., p_incoming_fks => 'preserve')`, registered paused as it is by default, leaves it
# at 1 across every maintenance tick with no regrain and no swap anywhere: the cutover dropped the key and
# only restore_incoming_fks re-adds it (maintain calls it, but maintain does nothing on a paused table).
# An operator reading the reference went looking for a dead swap instead of running the restore. The
# runbook's "(If instead `fks_suspended > 0`, a move is still in flight ...)" read it the same way, as
# something in progress to wait out.
#
# HOW. First the fact is MEASURED, on two preserve-converted tables built so their effects cannot cancel:
# one paused (the default), one not. After two ticks each, the unpaused one's FK is back and its
# fks_suspended is 0; the paused one's stays at 1 with its FK still absent and nothing but the cutover's
# drop, the transmute and obtain in its log (no regrain, no swap); restore_incoming_fks then brings it to
# 0. Then every sentence of the docs that reads a standing value of `fks_suspended` (it names the column
# and says non-zero, `> 0`, standing, transient, stuck, persists or remains) must name the cutover or
# restore_incoming_fks, and none may read it as a swap that died.
#   LIVENESS  both tables' FKs were dropped at the cutover; the unpaused tick did restore its FK (so the
#             paused table's standing value is the pause, not a restore that cannot run); the restore
#             cleared it; reference.md and runbook.md each read the value at least once when the full set
#             is scanned (a deleted statement is a failure, not a vacuous pass);
#   CONTROL   the pre-fix sentence is reported as wrong, and a planted right one is not.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   reference_fks_suspended_dead_swap -- docs/reference.md's pre-#740 reading put back
#
# Usage: doc_fks_suspended_meaning.sh <container> <db> [doc]
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
create table public.ev_p (id bigint primary key, payload text);
insert into public.ev_p select g, 'x' from generate_series(1, 20) g;
create table public.rx_p (rid int primary key, event_id bigint references public.ev_p (id));
insert into public.rx_p values (1, 5), (2, 7);
create table public.ev_u (id bigint primary key, payload text);
insert into public.ev_u select g, 'x' from generate_series(1, 30) g;
create table public.rx_u (rid int primary key, event_id bigint references public.ev_u (id));
insert into public.rx_u values (1, 9);
call pgpm.transmute('public.ev_p', 'id', 1000, p_incoming_fks => 'preserve');
call pgpm.transmute('public.ev_u', 'id', 1000, p_incoming_fks => 'preserve', p_paused => false);
SQL
then say FAIL "fixture: the two preserve conversions ran" ""; exit 1; fi

susp="select string_agg(s.parent::text || '=' || s.fks_suspended || '/' || c.paused, ',' order by s.parent::text)
        from pgpm.status() s join pgpm.config c on c.parent_table = s.parent"
fks="select (select count(*) from pg_constraint where conrelid = 'public.rx_p'::regclass and contype = 'f' and conparentid = 0)
       || ':' || (select count(*) from pg_constraint where conrelid = 'public.rx_u'::regclass and contype = 'f' and conparentid = 0)"
need "LIVENESS: both cutovers dropped their incoming FK (paused ev_p, live ev_u)" "$(v "$susp"):$(v "$fks")" "ev_p=1/true,ev_u=1/false:0:0"
for _ in 1 2; do
  q -d "$DB" -q -c "call pgpm.maintain('public.ev_p')" -c "call pgpm.maintain('public.ev_u')" >/dev/null 2>&1
done
need "LIVENESS: two ticks restored the unpaused table's FK, not the paused one's" "$(v "$susp"):$(v "$fks")" "ev_p=1/true,ev_u=0/false:0:1"
need "FACT: no regrain and no swap ran on the paused table (its whole log)" \
  "$(v "select string_agg(distinct action, ',' order by action) from pgpm.log where parent_table = 'public.ev_p'::regclass")" \
  "drop_incoming_fk,obtain,transmute"
need "FACT: restore_incoming_fks re-adds the paused table's FK" "$(v "select pgpm.restore_incoming_fks('public.ev_p')")" "1"
need "LIVENESS: and fks_suspended reads 0 for both" "$(v "$susp"):$(v "$fks")" "ev_p=0/true,ev_u=0/false:1:1"
q -q -c "drop database if exists $DB" >/dev/null 2>&1

python3 - "$ROOT" "$ONLY" <<'PY' || fail=1
import re, sys
root, only = sys.argv[1], sys.argv[2]
sys.path.insert(0, root + "/bench")
import doc_scan
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}")

COL = re.compile(r"(?<!\w)fks_suspended(?!\w)")
READS = re.compile(r"non-?zero|>\s*0|\bstanding\b|\bstands\b|\btransient\b|\bstuck\b|\bpersist|\bremains\b", re.I)
CAUSE = re.compile(r"\bcutover\b|restore_incoming_fks", re.I)
DEAD = re.compile(r"swap (?:has )?died|died mid-flight|dead swap", re.I)

def reads(s):
    return bool(COL.search(s.text) and READS.search(doc_scan.plain(s.text)))

def wrong(s):
    t = doc_scan.plain(s.text)
    return reads(s) and (not CAUSE.search(t) or bool(DEAD.search(t)))

bad = ("- `fks_suspended` / `fks_unvalidated` -- preserve-managed incoming FKs currently dropped (RI off) versus\n"
       "  re-added `NOT VALID` but blocked from full validation by pre-existing orphans. `fks_suspended` is a\n"
       "  transient state inside a regrain swap now, so a standing non-zero value means a swap died mid-flight.\n")
good = ("- `fks_suspended` -- a standing non-zero value is a `transmute` cutover's preserve drop that\n"
        "  `restore_incoming_fks` has not re-added yet.\n")
b = [s for s in doc_scan.sentences(bad) if wrong(s)]
g = [s for s in doc_scan.sentences(good) if wrong(s)]
gr = [s for s in doc_scan.sentences(good) if reads(s)]
ok = len(b) == 1 and not g and len(gr) == 1
say(ok, "CONTROL: the pre-fix reading is flagged, the right one is not",
    f"flagged {len(b)} of the wrong, {len(g)} of the right; right one read {len(gr)}")
fail |= not ok

docs = [only] if only else doc_scan.living_docs(root)
seen = {}
for d in docs:
    r = doc_scan.rel(root, d)
    for s in doc_scan.sentences(open(d).read(), r):
        if not reads(s):
            continue
        seen[r] = seen.get(r, 0) + 1
        ok = not wrong(s)
        say(ok, f"{r}:~{s.line}: a standing fks_suspended names the cutover",
            "it does" if ok else f"a paused preserve transmute leaves it standing, no swap: {s.text[:80]}")
        fail |= not ok

want = [doc_scan.rel(root, only)] if only else ["docs/reference.md", "docs/runbook.md"]
for r in want:
    ok = seen.get(r, 0) > 0
    say(ok, f"LIVENESS: {r} reads a standing fks_suspended", f"{seen.get(r, 0)} statement(s)")
    fail |= not ok
sys.exit(1 if fail else 0)
PY
exit "$fail"
