#!/usr/bin/env bash
# Prove that no sentence in the docs promises a DEFAULT partition, the net transmute does not lay down, and
# that the docs which describe the grid say there is none, measured from pgpm's own behaviour rather than
# assumed.
#
# WHY THIS GUARD EXISTS (issue #991). README.md's `transmute` bullet, the first description of the
# conversion an operator reads, said "a fresh `DEFAULT` is the safety net". The DEFAULT partition was
# removed in #288: transmute builds none, and a write past the forward grid is refused ("no partition of
# relation ... found for row"), as the same README's caveat, the guide and the reference all say. An operator
# who trusted the bullet wrote ahead of the grid (a bulk import, a far-future row) expecting it to be parked,
# and skipped sizing `obtain` or calling `extend_to`, the two things that actually stand between that write
# and a refusal.
#
# HOW. First the fact is MEASURED: a table holding ids 1..2500 is transmuted onto a 1000-wide id grid with
# p_obtain => 2. The converted parent has no DEFAULT partition (pg_partitioned_table.partdefid is 0 and no
# child carries a DEFAULT bound); a write one past the grid's ceiling is refused with 23514 'no partition of
# relation', and that row is not in the table; a write one below the ceiling is accepted; after
# `extend_to(parent, ceiling)` the refused value is accepted too. Then every sentence of the docs that names
# a DEFAULT partition (not `SET DEFAULT`, `BY DEFAULT` or `ALTER DEFAULT PRIVILEGES`) must not say pgpm
# creates, keeps or attaches one, call it a safety net, or say a write is parked, caught or absorbed in it,
# unless the sentence denies it ("no DEFAULT", "a DEFAULT would").
#   LIVENESS  the conversion really happened and really has its grid; a write inside the grid is accepted
#             (so the refusal is the grid's, not some other error's); README.md, guide.md and reference.md
#             each say, when the full set is scanned, that there is no DEFAULT (so a deleted statement is a
#             failure, not a vacuous pass);
#   CONTROL   the pre-fix bullet and two other wrong phrasings are reported, and the right ones are not.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   readme_transmute_fresh_default -- README.md's pre-#991 transmute bullet put back
#
# Usage: doc_transmute_no_default.sh <container> <db> [doc]
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
create table public.ev (id bigint primary key, v text);
insert into public.ev select g, 'history' from generate_series(1, 2500) g;
call pgpm.transmute('public.ev', 'id', 1000::bigint, p_obtain => 2);
-- one write, its outcome as data: 'accepted', or the SQLSTATE and message it was refused with
create function public.try_write(p_id bigint) returns text language plpgsql as $f$
begin
  insert into public.ev values (p_id, 'probe');
  return 'accepted';
exception when others then
  return sqlstate || ' ' || sqlerrm;
end $f$;
create table public.ceiling as
  with p as materialized (select hi from pgpm.part where parent_table = 'public.ev'::regclass)
  select max(hi::bigint) as hi from p;
SQL
then say FAIL "fixture: the table was transmuted" ""; exit 1; fi

need "LIVENESS: transmute converted public.ev to a partitioned table" \
  "$(v "select relkind from pg_class where oid = 'public.ev'::regclass")" "p"
ceil=$(v "select hi from public.ceiling")
if [[ "$ceil" =~ ^[0-9]+$ ]] && [ "$ceil" -gt 2500 ]; then
  say PASS "LIVENESS: the forward grid runs past the history" "ceiling $ceil"
else
  say FAIL "LIVENESS: the forward grid runs past the history" "got: $ceil"; exit 1
fi
need "FACT: the converted parent has no DEFAULT partition" \
  "$(v "select partdefid::int || ':' || (select count(*) from pg_inherits i join pg_class c on c.oid = i.inhrelid
         where i.inhparent = 'public.ev'::regclass and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT')
        from pg_partitioned_table where partrelid = 'public.ev'::regclass")" "0:0"
refused=$(v "select public.try_write($ceil)")
case "$refused" in
  "23514 no partition of relation"*) say PASS "FACT: a write one past the grid is refused, not parked" "id $ceil: ${refused:0:60}" ;;
  *) say FAIL "FACT: a write one past the grid is refused, not parked" "id $ceil: got: $refused"; exit 1 ;;
esac
need "FACT: the refused row is nowhere in the table" "$(v "select count(*) from public.ev where id = $ceil")" "0"
need "LIVENESS: a write one below the ceiling is accepted" "$(v "select public.try_write($ceil - 1)")" "accepted"
built=$(v "select pgpm.extend_to('public.ev', '$ceil')")
if [[ "$built" =~ ^[0-9]+$ ]] && [ "$built" -gt 0 ]; then
  say PASS "LIVENESS: extend_to built the grid out over the refused value" "$built partition(s)"
else
  say FAIL "LIVENESS: extend_to built the grid out over the refused value" "got: $built"; exit 1
fi
need "FACT: after extend_to the refused value is accepted" "$(v "select public.try_write($ceil)")" "accepted"
need "FACT: exactly the two accepted probes are in the table" \
  "$(v "select string_agg(id::text, ',' order by id) from public.ev where v = 'probe'")" "$((ceil - 1)),$ceil"
q -q -c "drop database if exists $DB" >/dev/null 2>&1

python3 - "$ROOT" "$ONLY" <<'PY' || fail=1
import re, sys
root, only = sys.argv[1], sys.argv[2]
sys.path.insert(0, root + "/bench")
import doc_scan
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}")

def flat(s):
    return re.sub(r"\s+", " ", doc_scan.plain(s).replace("`", ""))

# A DEFAULT partition, not a column default, an identity's BY DEFAULT, a foreign key's SET DEFAULT, or
# ALTER DEFAULT PRIVILEGES.
SUBJECT = re.compile(r"(?<!SET )(?<!BY )(?<!ALTER )\bDEFAULT\b(?! PRIVILEGES)")
PROMISE = re.compile(
    r"\bsafety net\b|\bbackstop\b"
    r"|\b(?:fresh|new|its own|empty) DEFAULT\b"
    r"|\b(?:creates?|creating|builds?|building|attach(?:es|ing)?|adds?|adding|lays? down|laying down"
    r"|keeps?|keeping|maintains?|maintaining)\b(?: (?:a|an|one|its own|the))?(?: (?:fresh|new|empty))? DEFAULT\b"
    r"|\b(?:parked|caught|absorbed|lands?|landing|routed|held)\b(?: \w+){0,3} (?:in|by|into) (?:a|an|the|its) DEFAULT\b"
    r"|\bthe DEFAULT (?:catches|absorbs|holds|takes|parks)\b", re.I)
DENIAL = re.compile(r"\bno (?:fresh |new )?DEFAULT\b|\bwithout (?:a |any )?DEFAULT\b|\bDEFAULT would\b"
                    r"|\bnever (?:creates?|builds?|attaches|adds|keeps)\b|\bnot (?:create|build|attach|add|keep)\b")
NONE = re.compile(r"\bno DEFAULT\b")

def about(s):
    return bool(SUBJECT.search(flat(s.text)))

def wrong(s):
    t = flat(s.text)
    return about(s) and bool(PROMISE.search(t)) and not DENIAL.search(t)

def denies(s):
    return about(s) and bool(NONE.search(flat(s.text)))

bad = ("- **`transmute`**: convert a live, unpartitioned table to partitioned **with no row movement**. The\n"
       "  original is renamed aside and attached intact as one bounded **monolith** child; a fresh `DEFAULT` is the\n"
       "  safety net. The cutover is one read-only scan plus a metadata flip.\n\n"
       "Alongside the monolith, transmute attaches a `DEFAULT` partition for anything off the grid.\n\n"
       "A write past the forward grid is parked in the `DEFAULT` until `obtain` catches up.\n")
good = ("- **`transmute`**: convert a live, unpartitioned table to partitioned **with no row movement**. The\n"
        "  original is renamed aside and attached intact as one bounded **monolith** child, and a forward grid of\n"
        "  real partitions is laid down ahead of it. There is no `DEFAULT` partition: a write past that grid is\n"
        "  refused, so `obtain`'s lookahead is the safety net, and `extend_to` builds the grid out ahead of a\n"
        "  write you know will land beyond it.\n\n"
        "That is deliberate: a refused write is loud and immediate, where a `DEFAULT` would absorb it silently and\n"
        "leave you a backlog to discover later.\n")
b = [s for s in doc_scan.sentences(bad) if wrong(s)]
g = [s for s in doc_scan.sentences(good) if wrong(s)]
gd = [s for s in doc_scan.sentences(good) if denies(s)]
ok = len(b) == 3 and not g and len(gd) == 1
say(ok, "CONTROL: the pre-fix bullet and two wrong phrasings are flagged",
    f"flagged {len(b)} of 3 wrong, {len(g)} of the right; denials read {len(gd)}")
fail |= not ok

docs = [only] if only else doc_scan.living_docs(root)
seen, said = {}, {}
for d in docs:
    r = doc_scan.rel(root, d)
    for s in doc_scan.sentences(open(d).read(), r):
        if not about(s):
            continue
        seen[r] = seen.get(r, 0) + 1
        if denies(s):
            said[r] = said.get(r, 0) + 1
        if wrong(s):
            say(False, f"{r}:~{s.line}: there is no DEFAULT partition",
                f"a write past the grid is refused: {flat(s.text)[:80]}")
            fail = 1
want = [doc_scan.rel(root, only)] if only else ["README.md", "docs/guide.md", "docs/reference.md"]
for r in want:
    ok = said.get(r, 0) > 0 if not only else seen.get(r, 0) > 0
    say(ok, f"LIVENESS: {r} says there is no DEFAULT",
        f"{said.get(r, 0)} of {seen.get(r, 0)} DEFAULT-partition statement(s)")
    fail |= not ok
if not fail:
    say(True, "every DEFAULT-partition statement agrees with transmute",
        f"{sum(seen.values())} statement(s) in {len(seen)} doc(s)")
sys.exit(1 if fail else 0)
PY
exit "$fail"
