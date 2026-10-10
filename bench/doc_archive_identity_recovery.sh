#!/usr/bin/env bash
# Prove that every sentence in the docs offering `forget_missing` as the way out of an identity wedge
# confines it to a parent that is gone, that the docs give the repair that works on a live table
# (`adopt_partition` for a partition restored and still attached, and deleting its `pgpm.part` row only
# once its relation is detached or gone), and that each repair does what the docs say, measured from
# pgpm's own behaviour rather than assumed.
#
# WHY THIS GUARD EXISTS (issue #739). docs/reference.md ("The archive step's identity check") told an
# operator facing a `fail_archive_identity` wedge to "clear the stale row with forget_missing". That
# function only ever clears a parent whose relation is gone, and `fail_archive_identity` is only ever
# logged for a live parent, so the advice cleared nothing and the wedge (at archive_batch 1, the table's
# whole archiving and retention) stayed. A wrong recovery in prose is not an error anywhere, which is why
# it has to be checked rather than noticed.
#
# AND WHY IT FOLLOWS adopt_partition (issue #1141, bullet 3). The repair this guard first measured was
# deleting the stale `pgpm.part` row while the restored partition stayed attached. That clears the wedge
# and nothing else (#1082): the partition is then recorded by nothing, so its rows outlive retention for
# good. The guard did not see it, because it looked only at the rows of the NEXT partition (ids 25 and
# 55), and its doc check accepted any sentence deleting a pgpm.part row, so a doc giving the pre-#1082
# advice passed. It now measures the documented repair and names the rows that must be gone.
#
# HOW. First the facts are MEASURED, on four managed tables built so their effects cannot cancel. Three
# live parents each have their aged [0,20) replaced by a restore from a dump (same name, same write-block
# trigger, new oid), and the archive step refuses each with fail_archive_identity; a fourth parent is
# dropped without untransmute. forget_missing() clears exactly the dropped parent and leaves the live
# one's stale row and its wedge in place. Then each live parent takes one repair:
#   ai  adopt_partition, the repair for a restored partition left attached: the wedge clears and
#       retention retires the restored rows themselves (1, 2, 15) as well as the next partition's (25),
#       keeping exactly 55;
#   bi  detach, then delete the pgpm.part row, the repair for a relation pgpm should not manage: the wedge
#       clears, retention moves on (27 goes, 57 stays), and the detached relation keeps 4 and 13;
#   ci  delete the pgpm.part row with the partition still attached, the repair the docs forbid: retention
#       moves past [20,30) while 6 and 11 stay in the table for good. Measured so the doc rule below
#       rests on behaviour.
# Then the docs. Every sentence that names `forget_missing` inside a section about an identity wedge
# (fail_archive_identity, fail_retain_identity, fail_write_block_identity) must say, in itself or in its
# paragraph or list item, that the parent is gone; every sentence there that deletes a `pgpm.part` row
# must, in itself, confine that to a relation detached or gone; and runbook.md's and reference.md's
# identity-wedge sections must name `adopt_partition`.
#   LIVENESS  the wedge was reached on each live parent and held retention on the first; forget_missing()
#             did clear the dropped parent (so "cleared nothing" on the live one is a measurement, not a
#             no-op); adopt_partition accepted the restored relation; runbook.md and reference.md each give
#             an identity-wedge repair;
#   CONTROL   planted sections carrying the pre-#739 advice and the pre-#1082 advice (delete the row of a
#             partition still attached, adopt_partition never named) are reported as wrong by each check
#             they break, and a planted section carrying the right repairs is not, so each check can fail
#             and is not failing everything.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   reference_archive_identity_forget_missing -- docs/reference.md's pre-#739 recovery put back
#   adopt_partition_deletes_stale_row         -- adopt_partition deletes the stale row instead of
#                                               re-anchoring it (the pre-#1082 repair): the wedge clears and
#                                               retention moves on, so only the rows of ai named after the
#                                               repair (1, 2, 15 still there) catch it
#   runbook_identity_wedge_delete_repair      -- docs/runbook.md's pre-#1082 repair put back: its
#                                               identity-wedge section never names adopt_partition
#   reference_identity_wedge_delete_attached  -- docs/reference.md has the stale row of a relation pgpm
#                                               should not manage deleted without detaching it first
#
# Usage: doc_archive_identity_recovery.sh <container> <db> [mutant]
# A mutant is a copy of pgpm_core/install.sql or of a doc, told apart by content (a /repo/... path is mapped
# to this checkout). With no mutant, or an install.sql one, it scans ONBOARDING.md, README.md,
# pgpm_archive/README.md and docs/*.md (not docs/reviews/, which quotes findings verbatim); with a doc it
# scans THAT file only, which is how bench/discriminate.sh points it at a doc mutant. The measurement
# installs this checkout's pgpm_core/install.sql (or the install.sql mutant) into a fresh <db> in
# <container>, fed from the host, so the container need not mount the repository.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MUT="${3:-}"
CORE="$ROOT/pgpm_core/install.sql"
ONLY=""
fail=0
say() { printf '%s  %-62s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i "$C" psql -U postgres -X "$@"; }
v() { q -d "$DB" -tAq -c "$1" 2>&1; }
need() {   # need <description> <have> <want>: a measured premise; the doc check means nothing without it
  if [ "$2" = "$3" ]; then say PASS "$1" "$2"; else say FAIL "$1" "got: $2, want: $3"; exit 1; fi
}
check() {  # check <description> <have> <want>: a measured fact; every one is reported, then the run fails
  if [ "$2" = "$3" ]; then say PASS "$1" "$2"; else say FAIL "$1" "got: $2, want: $3"; fail=1; fi
}

if [ -n "$MUT" ]; then
  MUT="${MUT/#\/repo\//$ROOT/}"
  if [ ! -f "$MUT" ]; then say FAIL "the mutant to run exists" "$MUT"; exit 1; fi
  if grep -q 'create table if not exists pgpm.config' "$MUT"; then CORE="$MUT"; else ONLY="$MUT"; fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction <"$CORE" >/dev/null 2>&1; then
  say FAIL "pgpm_core installed" "$CORE"; exit 1
fi

# Three live parents, [0,20) of each aged (retain 20 under frontiers 55, 57 and 58), write-blocked, then
# replaced by a restore from a dump under the same name. The dropped parent: three partitions' worth of
# rows, so forget_missing has something of its own to clear.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
create table public.stale (parent regclass, child_name text, child_oid oid);
create function public.restore_from_dump(p regclass) returns void language plpgsql as $f$
declare v_old text; v_oid oid; v_lo text; v_hi text;
begin
  select child_name, child_oid, lo, hi into strict v_old, v_oid, v_lo, v_hi
    from pgpm.part where parent_table = p and lo = '0';
  insert into public.stale values (p, v_old, v_oid);
  perform pgpm._enforce_write_blocks(p);
  execute format('alter table %s detach partition public.%I', p, v_old);
  execute format('create table public.restored (like public.%I including all)', v_old);
  execute format('insert into public.restored select * from public.%I', v_old);
  execute format('drop table public.%I', v_old);
  execute format('alter table public.restored rename to %I', v_old);
  execute format('create trigger pgpm_write_block before insert or update or delete on public.%I '
                 'for each row execute function pgpm._write_block_raise()', v_old);
  execute format('alter table public.%I enable always trigger pgpm_write_block', v_old);
  execute format('alter table %s attach partition public.%I for values from (%s) to (%s)', p, v_old, v_lo, v_hi);
end $f$;
create table public.ai (id bigint primary key, payload text);
insert into public.ai values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.ai', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.ai', '60');
insert into public.ai values (25, 'd'), (55, 'frontier');
create table public.bi (id bigint primary key, payload text);
insert into public.bi values (4, 'e'), (13, 'f');
call pgpm.transmute('public.bi', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.bi', '60');
insert into public.bi values (27, 'g'), (57, 'frontier');
create table public.ci (id bigint primary key, payload text);
insert into public.ci values (6, 'h'), (11, 'i');
call pgpm.transmute('public.ci', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.ci', '60');
insert into public.ci values (22, 'j'), (28, 'k'), (58, 'frontier');
select pgpm.set_archive_fn(t, 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure)
  from unnest(array['public.ai', 'public.bi', 'public.ci']::regclass[]) t;
create table public.gone (id bigint primary key);
insert into public.gone select generate_series(1, 30);
call pgpm.transmute('public.gone', 'id', 10::bigint);
create table public.gone_oid as select 'public.gone'::regclass::oid as oid;
drop table public.gone;
select public.restore_from_dump(t) from unnest(array['public.ai', 'public.bi', 'public.ci']::regclass[]) t;
SQL
then say FAIL "fixture: the four managed tables were built" ""; exit 1; fi

ident() {  # ident <parent>: the query counting fail_archive_identity rows for the parent's restored [0,20)
  echo "select count(*) from pgpm.log where parent_table = '$1'::regclass and action = 'fail_archive_identity' and lo = '0' and hi = '20'"
}
ids() {    # ids <relation>: the ids the relation holds, in order
  v "select coalesce(string_agg(id::text, ',' order by id), 'none') from $1"
}
restored() {  # restored <parent>: the quoted name of the parent's restored [0,20)
  v "select quote_ident(child_name) from public.stale where parent = '$1'::regclass"
}
tick3() { for _ in 1 2 3; do v "call pgpm.maintain('$1')" >/dev/null; done; }

need "LIVENESS: the archive step archived nothing on the wedged parent" "$(v "select pgpm._archive_step('public.ai')")" "0"
need "LIVENESS: it refused [0,20) on identity (fail_archive_identity)" "$(v "$(ident public.ai)")" "1"
need "LIVENESS: the recorded relations are gone for good (cannot be put back)" \
  "$(v "select count(*) from pg_class where oid in (select child_oid from public.stale)")" "0"
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
  "$(v "select count(*) from pgpm.part p join public.stale s on s.parent = p.parent_table and s.child_oid = p.child_oid where p.parent_table = 'public.ai'::regclass")" "1"
v "select pgpm._archive_step('public.ai')" >/dev/null
need "FACT: and the wedge stands (a second fail_archive_identity)" "$(v "$(ident public.ai)")" "2"

# ai: adopt_partition, the documented repair for the partition restored and still attached.
need "LIVENESS: adopt_partition accepted ai's restored partition" \
  "$(v "select pgpm.adopt_partition('public.ai', 'public.$(restored public.ai)') is not null")" "t"
check "FACT: the archive step then moves on (archives a chunk)" "$(v "select pgpm._archive_step('public.ai') > 0")" "t"
check "FACT: with no new fail_archive_identity" "$(v "$(ident public.ai)")" "2"
tick3 public.ai
check "FACT: retention retired the restored 1, 2, 15 and then 25; 55 stays" "$(ids public.ai)" "55"
check "FACT: retain_drop logged for the restored [0,20) and for [20,30)" \
  "$(v "select string_agg(lo || '-' || hi, ',' order by lo::int) from pgpm.log where parent_table = 'public.ai'::regclass and action = 'retain_drop'")" \
  "0-20,20-30"

# bi: detach first, then delete the row, the repair for a relation pgpm should not manage.
v "select pgpm._archive_step('public.bi')" >/dev/null
need "LIVENESS: bi's restored [0,20) is refused on identity" "$(v "$(ident public.bi)")" "1"
bi_old=$(restored public.bi)
v "alter table public.bi detach partition public.$bi_old" >/dev/null
check "FACT: deleting the detached partition's row removes exactly that row" \
  "$(v "with d as (delete from pgpm.part p using public.stale s where p.parent_table = 'public.bi'::regclass and s.parent = p.parent_table and p.child_name = s.child_name returning p.child_oid = s.child_oid as same) select string_agg(same::text, ',') from d")" \
  "true"
tick3 public.bi
check "FACT: with no new fail_archive_identity on bi" "$(v "$(ident public.bi)")" "1"
check "FACT: bi's retention moved on: 27 retired, 57 stays" "$(ids public.bi)" "57"
check "FACT: the detached relation keeps its 4 and 13, outside pgpm" "$(ids "public.$bi_old")" "4,13"

# ci: delete the row while the partition stays attached, the repair the docs forbid.
v "select pgpm._archive_step('public.ci')" >/dev/null
need "LIVENESS: ci's restored [0,20) is refused on identity" "$(v "$(ident public.ci)")" "1"
v "delete from pgpm.part p using public.stale s where p.parent_table = 'public.ci'::regclass and s.parent = p.parent_table and p.child_name = s.child_name" >/dev/null
tick3 public.ci
check "FACT: on ci the deleted row lets retention past [20,30)" \
  "$(v "select count(*) from pgpm.log where parent_table = 'public.ci'::regclass and action = 'retain_drop' and lo = '20' and hi = '30'")" "1"
check "FACT: while the attached partition's 6 and 11 stay for good" "$(ids public.ci)" "6,11,58"
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
ADOPT = re.compile(r"(?<!\w)adopt_partition(?!\w)")
# "the parent is gone", in the words the docs use for it.
GONE = re.compile(
    r"\bparent\b[^.;:]{0,40}?\b(?:is|was)\s+(?:itself\s+|already\s+)?(?:gone|dropped|absent)\b"
    r"|managed (?:table|relation)[^.;:]{0,40}?\b(?:gone|dropped)\b"
    r"|parent_missing|relation no longer exists|dropped without `?untransmute", re.I)
DELETE = re.compile(r"\bdelete\b[^.]{0,80}?pgpm\.part\b", re.I)
# A pgpm.part delete confined to a relation no longer attached: detached first, or gone. Measured above:
# the row deleted after a detach lets retention move on and leaves the relation's rows to the operator,
# while the row deleted under a partition still attached leaves that partition's rows in the table for
# good. "the parent is gone" is not this (a gone parent is forget_missing's case, not a deletion's).
DETACHED = re.compile(r"\bdetach\w*|\b(?:it|relation|partition)\s+(?:is|was)\s+(?:gone|dropped)\b", re.I)

def wrong(s):
    """A sentence offering forget_missing in an identity-wedge section without confining it to a gone parent."""
    return bool(FORGET.search(s.text) and IDENT.search(s.section)
                and not GONE.search(doc_scan.plain(s.text)) and not GONE.search(doc_scan.plain(s.block)))

def offers(s):
    return bool(FORGET.search(s.text) and IDENT.search(s.section))

def repairs(s):
    return bool("fail_archive_identity" in s.section and DELETE.search(doc_scan.plain(s.text)))

def deletes(s):
    return bool(IDENT.search(s.section) and DELETE.search(doc_scan.plain(s.text)))

def deletes_attached(s):
    """A sentence in an identity-wedge section deleting a pgpm.part row without confining it to a relation
    detached or gone: on a partition left attached that is the repair that orphans its rows (#1082)."""
    return deletes(s) and not DETACHED.search(doc_scan.plain(s.text))

def adopts(s):
    return bool(IDENT.search(s.section) and ADOPT.search(s.text))

H = "#### The archive step's identity check\n\nOn a mismatch it logs `fail_archive_identity`. "
bad = (H + "Recovery is an operator decision -- put the intended relation back under that name, or clear the "
       "stale row with\n[`forget_missing`](#forget_missing). At `archive_batch`'s default of `1` it holds up the rest.\n")
bad1082 = (H + "When the partition was restored from a dump under its own name and is still attached to the table,\n"
           "the repair is to delete the stale `pgpm.part` row, after which the archive step moves on.\n")
good = (H + "When the partition was restored from a dump under its own name and is still attached, record it with\n"
        "`pgpm.adopt_partition`. When it is not one pgpm should manage, detach it and then delete the `pgpm.part`\n"
        "row; [`forget_missing`](#forget_missing) clears it only once the parent itself is gone.\n")
def count(text, f):
    return len([s for s in doc_scan.sentences(text) if f(s)])
seen = {
    "forget_missing flagged (pre-#739, right)": (count(bad, wrong), count(good, wrong)),
    "attached delete flagged (pre-#1082, right)": (count(bad1082, deletes_attached), count(good, deletes_attached)),
    "adopt_partition named (pre-#1082, right)": (count(bad1082, adopts), count(good, adopts)),
    "repair read (pre-#1082, right)": (count(bad1082, repairs), count(good, repairs)),
}
ok = seen == {
    "forget_missing flagged (pre-#739, right)": (1, 0),
    "attached delete flagged (pre-#1082, right)": (1, 0),
    "adopt_partition named (pre-#1082, right)": (0, 1),
    "repair read (pre-#1082, right)": (1, 1),
}
say(ok, "CONTROL: the pre-fix advice is flagged, the right one is not",
    "; ".join(f"{k} {a}/{b}" for k, (a, b) in seen.items()))
fail |= not ok

docs = [only] if only else doc_scan.living_docs(root)
offered, repaired, adopted = {}, {}, {}
for d in docs:
    r = doc_scan.rel(root, d)
    for s in doc_scan.sentences(open(d).read(), r):
        if offers(s):
            offered[r] = offered.get(r, 0) + 1
            ok = not wrong(s)
            say(ok, f"{r}:~{s.line}: forget_missing confined to a gone parent",
                "it is" if ok else f"forget_missing clears nothing on a live parent: {s.text[:90]}")
            fail |= not ok
        if deletes(s):
            ok = not deletes_attached(s)
            say(ok, f"{r}:~{s.line}: a pgpm.part delete only once detached or gone",
                "it is" if ok else f"deleting the row of an attached partition orphans its rows: {s.text[:90]}")
            fail |= not ok
        if repairs(s):
            repaired[r] = repaired.get(r, 0) + 1
        if adopts(s):
            adopted[r] = adopted.get(r, 0) + 1

want = [doc_scan.rel(root, only)] if only else ["docs/runbook.md", "docs/reference.md"]
for r in want:
    n = repaired.get(r, 0) if not only else repaired.get(r, 0) + offered.get(r, 0)
    ok = n > 0
    say(ok, f"LIVENESS: {r} gives the identity-wedge repair", f"{repaired.get(r, 0)} delete repair(s), {offered.get(r, 0)} forget_missing mention(s)")
    fail |= not ok
    ok = adopted.get(r, 0) > 0
    say(ok, f"{r}: its identity-wedge repair names adopt_partition",
        f"{adopted.get(r, 0)} sentence(s)" if ok else "it never does: the restored partition is left to the delete repair")
    fail |= not ok
sys.exit(1 if fail else 0)
PY
exit "$fail"
