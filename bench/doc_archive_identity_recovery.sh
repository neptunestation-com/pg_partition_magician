#!/usr/bin/env bash
# Prove that every sentence in the docs offering `forget_missing` as the way out of an identity wedge
# confines it to a parent that is gone, and that the docs give the repair that works on a live table,
# measured from pgpm's own behaviour rather than assumed.
#
# WHY THIS GUARD EXISTS (issue #739). docs/reference.md ("The archive step's identity check") told an
# operator facing a `fail_archive_identity` wedge to "clear the stale row with forget_missing". That
# function only ever clears a parent whose relation is gone, and `fail_archive_identity` is only ever
# logged for a live parent, so the advice cleared nothing and the wedge (at archive_batch 1, the table's
# whole archiving and retention) stayed. The runbook had the right repair all along: delete the
# `pgpm.part` row, and run forget_missing only when the parent itself is gone. A wrong recovery in prose
# is not an error anywhere, which is why it has to be checked rather than noticed.
#
# HOW. First the facts are MEASURED, on two managed tables built so their effects cannot cancel: a live
# parent whose aged partition is replaced by a restore from a dump (same name, same write-block trigger,
# new oid), and a second parent dropped without untransmute. The archive step refuses the restored
# partition with fail_archive_identity; forget_missing() then clears exactly the dropped parent and leaves
# the live one's stale row and its wedge in place; deleting that pgpm.part row is what clears the wedge,
# after which the archive step moves on and retain() drops the next partition. Then every sentence of the
# docs that names `forget_missing` inside a section about an identity wedge (fail_archive_identity,
# fail_retain_identity, fail_write_block_identity) must say, in itself or in its paragraph or list item,
# that the parent is gone.
#   LIVENESS  the wedge was reached on a live parent and held retention; forget_missing() did clear the
#             dropped parent (so "cleared nothing" on the live one is a measurement, not a no-op); the
#             delete was followed by real work (an archived chunk and a retain_drop of [20,30)); runbook.md
#             and reference.md each give the delete repair in their identity-wedge section;
#   CONTROL   a planted sentence carrying the pre-fix advice is reported as wrong, and a planted sentence
#             carrying the right one is not, so the check can fail and is not failing everything.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   reference_archive_identity_forget_missing -- docs/reference.md's pre-#739 recovery put back
#
# Usage: doc_archive_identity_recovery.sh <container> <db> [doc]
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

# The live parent: [0,20) is aged (frontier 55, retain 20), write-blocked, then replaced by a restore from
# a dump under the same name. The dropped parent: three partitions' worth of rows, so forget_missing has
# something of its own to clear.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
create table public.ai (id bigint primary key, payload text);
insert into public.ai values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.ai', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.ai', '60');
insert into public.ai values (25, 'd'), (55, 'frontier');
select pgpm.set_archive_fn('public.ai', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
create table public.gone (id bigint primary key);
insert into public.gone select generate_series(1, 30);
call pgpm.transmute('public.gone', 'id', 10::bigint);
create table public.gone_oid as select 'public.gone'::regclass::oid as oid;
drop table public.gone;
select child_name as old, child_oid as old_oid, lo as old_lo, hi as old_hi from pgpm.part
 where parent_table = 'public.ai'::regclass and lo = '0' \gset
create table public.stale as select :'old'::text as child_name, :old_oid::oid as child_oid;
select pgpm._enforce_write_blocks('public.ai');
alter table public.ai detach partition public.:"old";
create table public.ai_restored (like public.:"old" including all);
insert into public.ai_restored select * from public.:"old";
drop table public.:"old";
alter table public.ai_restored rename to :"old";
create trigger pgpm_write_block before insert or update or delete on public.:"old"
  for each row execute function pgpm._write_block_raise();
alter table public.:"old" enable always trigger pgpm_write_block;
alter table public.ai attach partition public.:"old" for values from (:old_lo) to (:old_hi);
SQL
then say FAIL "fixture: the two managed tables were built" ""; exit 1; fi

ident="select count(*) from pgpm.log where parent_table = 'public.ai'::regclass and action = 'fail_archive_identity' and lo = '0' and hi = '20'"
need "LIVENESS: the archive step archived nothing on the wedged parent" "$(v "select pgpm._archive_step('public.ai')")" "0"
need "LIVENESS: it refused [0,20) on identity (fail_archive_identity)" "$(v "$ident")" "1"
need "LIVENESS: the recorded relation is gone for good (cannot be put back)" \
  "$(v "select count(*) from pg_class where oid = (select child_oid from public.stale)")" "0"
need "LIVENESS: the wedge holds retention (retain() drops nothing)" "$(v "select pgpm.retain('public.ai')")" "0"
gone_parts=$(v "select count(*) from pgpm.part where parent_table::oid = (select oid from public.gone_oid)")
if [[ "$gone_parts" =~ ^[0-9]+$ ]] && [ "$gone_parts" -gt 0 ]; then
  say PASS "LIVENESS: the dropped parent left pgpm.part rows behind" "$gone_parts"
else
  say FAIL "LIVENESS: the dropped parent left pgpm.part rows behind" "got: $gone_parts"; exit 1
fi
need "LIVENESS: forget_missing() clears exactly the dropped parent" \
  "$(v "select string_agg((parent_oid = (select oid from public.gone_oid))::text || ':' || partitions_forgotten, ',') from pgpm.forget_missing()")" \
  "true:$gone_parts"
need "FACT: forget_missing() left the live parent's stale pgpm.part row" \
  "$(v "select count(*) from pgpm.part where parent_table = 'public.ai'::regclass and child_oid = (select child_oid from public.stale)")" "1"
v "select pgpm._archive_step('public.ai')" >/dev/null
need "FACT: and the wedge stands (a second fail_archive_identity)" "$(v "$ident")" "2"
need "FACT: deleting the pgpm.part row removes exactly that row" \
  "$(v "with d as (delete from pgpm.part where parent_table = 'public.ai'::regclass and child_name = (select child_name from public.stale) returning child_oid) select string_agg((child_oid = (select child_oid from public.stale))::text, ',') from d")" "true"
need "FACT: the archive step then moves on (archives a chunk)" "$(v "select pgpm._archive_step('public.ai') > 0")" "t"
need "FACT: with no new fail_archive_identity" "$(v "$ident")" "2"
v "select pgpm.retain('public.ai')" >/dev/null
need "LIVENESS: retention resumed: retain() dropped [20,30) and its row" \
  "$(v "select (select count(*) from pgpm.log where parent_table = 'public.ai'::regclass and action = 'retain_drop' and lo = '20' and hi = '30') || ':' || (select count(*) from public.ai where id = 25) || ':' || (select count(*) from public.ai where id = 55)")" \
  "1:0:1"
q -q -c "drop database if exists $DB" >/dev/null 2>&1

python3 - "$ROOT" "$ONLY" <<'PY' || fail=1
import re, sys
root, only = sys.argv[1], sys.argv[2]
sys.path.insert(0, root + "/bench")
import doc_scan
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}")

IDENT = re.compile(r"fail_(?:archive|retain|write_block)_identity")
FORGET = re.compile(r"(?<!\w)forget_missing(?!\w)")
# "the parent is gone", in the words the docs use for it.
GONE = re.compile(
    r"\bparent\b[^.;:]{0,40}?\b(?:is|was)\s+(?:itself\s+|already\s+)?(?:gone|dropped|absent)\b"
    r"|managed (?:table|relation)[^.;:]{0,40}?\b(?:gone|dropped)\b"
    r"|parent_missing|relation no longer exists|dropped without `?untransmute", re.I)
DELETE = re.compile(r"\bdelete\b[^.]{0,80}?pgpm\.part\b", re.I)

def wrong(s):
    """A sentence offering forget_missing in an identity-wedge section without confining it to a gone parent."""
    return bool(FORGET.search(s.text) and IDENT.search(s.section)
                and not GONE.search(doc_scan.plain(s.text)) and not GONE.search(doc_scan.plain(s.block)))

def offers(s):
    return bool(FORGET.search(s.text) and IDENT.search(s.section))

def repairs(s):
    return bool("fail_archive_identity" in s.section and DELETE.search(doc_scan.plain(s.text)))

bad = ("#### The archive step's identity check\n\nOn a mismatch it logs `fail_archive_identity`. Recovery is "
       "an operator decision -- put the intended relation back under that name, or clear the stale row with\n"
       "[`forget_missing`](#forget_missing). At `archive_batch`'s default of `1` it holds up the rest.\n")
good = ("#### The archive step's identity check\n\nOn a mismatch it logs `fail_archive_identity`. Recovery is "
        "an operator decision -- put the intended relation back under that name, or delete the `pgpm.part`\n"
        "row; [`forget_missing`](#forget_missing) clears it only once the parent itself is gone.\n")
b = [s for s in doc_scan.sentences(bad) if wrong(s)]
g = [s for s in doc_scan.sentences(good) if wrong(s)]
gr = [s for s in doc_scan.sentences(good) if repairs(s)]
ok = len(b) == 1 and not g and len(gr) == 1
say(ok, "CONTROL: the pre-fix advice is flagged, the right one is not",
    f"flagged {len(b)} of the wrong, {len(g)} of the right; right repair read {len(gr)}")
fail |= not ok

docs = [only] if only else doc_scan.living_docs(root)
offered, repaired = {}, {}
for d in docs:
    r = doc_scan.rel(root, d)
    for s in doc_scan.sentences(open(d).read(), r):
        if offers(s):
            offered[r] = offered.get(r, 0) + 1
            ok = not wrong(s)
            say(ok, f"{r}:~{s.line}: forget_missing confined to a gone parent",
                "it is" if ok else f"forget_missing clears nothing on a live parent: {s.text[:90]}")
            fail |= not ok
        if repairs(s):
            repaired[r] = repaired.get(r, 0) + 1

want = [doc_scan.rel(root, only)] if only else ["docs/runbook.md", "docs/reference.md"]
for r in want:
    n = repaired.get(r, 0) if not only else repaired.get(r, 0) + offered.get(r, 0)
    ok = n > 0
    say(ok, f"LIVENESS: {r} gives the identity-wedge repair", f"{repaired.get(r, 0)} delete repair(s), {offered.get(r, 0)} forget_missing mention(s)")
    fail |= not ok
sys.exit(1 if fail else 0)
PY
exit "$fail"
