#!/usr/bin/env bash
# Prove that the docs' foreign-key VALIDATE step names the function that validates, and that the symptom
# they give for a managed table dropped without untransmute is the reason pgpm's ticks actually log, both
# measured from pgpm's own behaviour rather than assumed.
#
# WHY THIS GUARD EXISTS (issues #910 and #911).
#   #910: docs/runbook.md's "Prevent" step after a preserve conversion read
#         `select pgpm.restore_incoming_fks('public.events');   -- then again next tick for the VALIDATE`.
#         restore_incoming_fks re-adds the key NOT VALID and stops there; a second call finds nothing to
#         re-add and returns 0, and the conversion registers the table paused, so no tick validates it
#         either. validate_incoming_fks is the call that validates. An operator following the runbook left
#         the key NOT VALID.
#   #911: the runbook's "A managed table was dropped without `untransmute`" entry said the skip_obtain /
#         skip_write_block / skip_retain rows all give `syntax error at or near "<number>"` as the reason.
#         Since #296 pgpm._frontier_native refuses first, with "managed table with oid N no longer exists
#         (dropped without pgpm.untransmute) ...", so a search of pgpm.log for the documented text finds
#         nothing. A command or a quoted message in prose is not an error anywhere, which is why it has to
#         be checked rather than noticed.
#
# HOW. First the facts are MEASURED.
#   FK:      a preserve conversion, registered paused (the default), of a table one foreign key references.
#            restore_incoming_fks re-adds the key (returns 1, NOT VALID); a maintenance tick leaves it NOT
#            VALID; a second restore_incoming_fks returns 0 and leaves it NOT VALID; validate_incoming_fks
#            returns 1 and the key is valid. So restore_incoming_fks is measured NOT to validate and
#            validate_incoming_fks to validate.
#   DROPPED: an unpaused id-grid table is dropped with DROP TABLE and ticked by maintain and
#            maintain_obtain; the skip_obtain, skip_write_block and skip_retain rows logged against its oid
#            are the reasons a dropped table produces.
# Then the docs are read against them.
#   FK:      no fenced code line calling restore_incoming_fks may carry a `--` comment about validating
#            (validate_incoming_fks is the function measured to validate). Fenced code is read here because
#            the remedy an operator copies IS the code line, which bench/doc_scan.py skips. Prose is not held
#            to it, on purpose: for a PARTITIONED referencing table, which cannot hold a NOT VALID key,
#            restore_incoming_fks does re-add the key validated in one step, and reference.md says so.
#   DROPPED: every prose sentence that names skip_obtain, skip_write_block or skip_retain in a dropped-
#            MANAGED-table context (its section heading or its paragraph says "dropped without", DROP TABLE,
#            parent_missing or "no longer exists"; the bare word "dropped" is not enough, since retention
#            prose says partitions are dropped) and quotes a message (a backticked span with a space, no `=`
#            and not all upper case, so `parent_missing = true` and a lock mode such as `SHARE UPDATE
#            EXCLUSIVE` are not read as messages) must quote text the ticks logged, a `<placeholder>` or a
#            number standing for any number.
#   LIVENESS  every measured step above did what it says (the FK was dropped at the cutover, re-added NOT
#             VALID, left NOT VALID by the tick and the second restore, validated by validate_incoming_fks;
#             the dropped table's three skip actions were all logged); the runbook (or the one doc given)
#             has a code line calling restore_incoming_fks and one calling validate_incoming_fks, and quotes
#             a dropped-table skip reason, so a deleted statement is a failure, not a vacuous pass;
#   CONTROL   each pre-fix text is reported as wrong, and a planted right one is not; retention prose that
#             names skip_retain beside dropped partitions and quotes a lock mode is not read as a symptom.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   runbook_fk_validate_by_restore       -- the runbook's Prevent step names restore_incoming_fks again
#                                           "for the VALIDATE" (pre-#910)
#   runbook_dropped_table_syntax_symptom -- the runbook's dropped-table symptom quotes
#                                           `syntax error at or near "<number>"` (pre-#911)
#
# Usage: doc_remedy_and_symptom.sh <container> <db> [doc]
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
say() { printf '%s  %-66s %s\n' "$1" "$2" "$3"; }
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

# --- FK: which of the two functions validates a preserve-managed key ------------------------------------
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
create table public.ev (id bigint primary key, payload text);
insert into public.ev select g, 'x' from generate_series(1, 40) g;
create table public.rx (rid int primary key, event_id bigint not null,
                        constraint rx_event_fk foreign key (event_id) references public.ev (id));
insert into public.rx values (1, 5), (2, 7), (3, 7);
call pgpm.transmute('public.ev', 'id', 1000, p_incoming_fks => 'preserve');
SQL
then say FAIL "fixture: the paused preserve conversion ran" ""; exit 1; fi

fk="select coalesce((select convalidated::text from pg_constraint
                     where conrelid = 'public.rx'::regclass and conname = 'rx_event_fk'), 'absent')"
need "LIVENESS: the conversion registered paused and dropped rx_event_fk" \
  "$(v "select paused::text from pgpm.config where parent_table = 'public.ev'::regclass"):$(v "$fk")" "true:absent"
need "LIVENESS: the first restore_incoming_fks re-added it NOT VALID" \
  "$(v "select pgpm.restore_incoming_fks('public.ev')"):$(v "$fk")" "1:false"
q -d "$DB" -q -c "call pgpm.maintain('public.ev')" >/dev/null 2>&1
need "FACT: a tick on the paused table leaves it NOT VALID" "$(v "$fk")" "false"
need "FACT: restore_incoming_fks again returns 0 and leaves it NOT VALID" \
  "$(v "select pgpm.restore_incoming_fks('public.ev')"):$(v "$fk")" "0:false"
need "FACT: validate_incoming_fks validates it" \
  "$(v "select pgpm.validate_incoming_fks('public.ev')"):$(v "$fk")" "1:true"

# --- DROPPED: the reasons a dropped managed table's ticks log -------------------------------------------
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
create table public.gone (id bigint primary key);
insert into public.gone select generate_series(1, 25);
call pgpm.transmute('public.gone', 'id', 10::bigint, p_obtain => 2, p_retain => 30::bigint, p_paused => false);
SQL
then say FAIL "fixture: the unpaused id-grid conversion ran" ""; exit 1; fi
poid=$(v "select 'public.gone'::regclass::oid")
q -d "$DB" -q -c "drop table public.gone" >/dev/null 2>&1
q -d "$DB" -q -c "call pgpm.maintain($poid::oid::regclass)" >/dev/null 2>&1
q -d "$DB" -q -c "call pgpm.maintain_obtain($poid::oid::regclass)" >/dev/null 2>&1
skips="from pgpm.log where parent_table::oid = $poid and action in ('skip_obtain', 'skip_write_block', 'skip_retain')"
need "LIVENESS: the dropped table's ticks logged all three skip actions" \
  "$(v "select string_agg(distinct action, ',' order by action) $skips")" "skip_obtain,skip_retain,skip_write_block"
reasons=$(v "select string_agg(distinct method, E'\n') $skips")
if [ -z "$reasons" ]; then say FAIL "LIVENESS: the skip rows carry a reason" "none"; exit 1; fi
say PASS "LIVENESS: the skip rows carry a reason" "$(printf '%s' "$reasons" | head -1 | cut -c1-70)"
q -q -c "drop database if exists $DB" >/dev/null 2>&1

python3 - "$ROOT" "$ONLY" "$reasons" <<'PY' || fail=1
import re, sys
root, only, reasons = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, root + "/bench")
import doc_scan
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<66} {detail}")

# ---- FK: the function that validates, as measured above ----
NONVALIDATOR = "restore_incoming_fks"   # measured: re-adds NOT VALID, never validates
VALIDATOR = "validate_incoming_fks"     # measured: validates
VALIDATES = re.compile(r"validat", re.I)  # "NOT VALID" is a state, not a claim of validating
FENCE = re.compile(r"^\s*(```|~~~)")

def code_lines(text):
    out, fenced = [], False
    for n, raw in enumerate(text.split("\n"), 1):
        if FENCE.match(raw):
            fenced = not fenced
            continue
        if fenced:
            out.append((n, raw))
    return out

def code_wrong(raw):
    code, _, comment = raw.partition("--")
    return bool(re.search(NONVALIDATOR + r"\s*\(", code) and VALIDATES.search(comment))

# ---- DROPPED: the reasons measured above ----
SKIPS = re.compile(r"(?<!\w)skip_(?:obtain|write_block|retain)(?!\w)")
# A managed table dropped without untransmute, not any paragraph with "dropped" in it: retention prose says
# partitions are dropped, and #939's retain paragraph names skip_retain beside one (a false positive here).
CONTEXT = re.compile(r"dropped without|drop table|parent_missing|no longer exists", re.I)
TICKS = re.compile(r"`([^`]+)`")

def norm(t):
    return re.sub(r"\d+", "N", re.sub(r"<[^>]+>", "N", t)).strip()

measured = [norm(r) for r in reasons.split("\n") if r.strip()]

def dropped_spans(s):
    if not (SKIPS.search(s.text) and CONTEXT.search(s.heading + " " + s.block)):
        return []
    # A quoted message has a space in it; an SQL condition (`parent_missing = true`) is not a message, and
    # neither is an all-upper-case span (a lock mode, `SHARE UPDATE EXCLUSIVE`, or an SQL keyword run).
    return [t for t in TICKS.findall(s.text)
            if re.search(r"\s", t) and "=" not in t and not re.fullmatch(r"[A-Z][A-Z ]*", t.strip())]

def span_ok(span):
    return any(norm(span) in m for m in measured)

# ---- CONTROLS ----
bad_fk = "```sql\nselect pgpm.restore_incoming_fks('public.events');   -- then again next tick for the VALIDATE\n```\n"
good_fk = ("```sql\nselect pgpm.restore_incoming_fks('public.events');   -- re-adds the key NOT VALID\n"
           "select pgpm.validate_incoming_fks('public.events');  -- then validates it\n```\n")
b = sum(code_wrong(r) for _, r in code_lines(bad_fk))
g = sum(code_wrong(r) for _, r in code_lines(good_fk))
ok = b == 1 and g == 0
say(ok, "CONTROL: a restore 'for the VALIDATE' is flagged, the right pair is not",
    f"flagged {b} of 1 wrong, {g} of the right")
fail |= not ok

head = "## A managed table was dropped without `untransmute`\n\n"
bad_sym = head + ("**Symptom.** `pgpm.log` fills with `skip_obtain` / `skip_write_block` / `skip_retain` every tick, "
                  "all giving `syntax error at or near \"<number>\"` as the reason.\n")
good_sym = head + ("**Symptom.** `pgpm.log` fills with `skip_obtain` / `skip_write_block` / `skip_retain` every tick, "
                   "all giving `managed table with oid <oid> no longer exists (dropped without pgpm.untransmute)` "
                   "as the reason.\n")
bs = [sp for s in doc_scan.sentences(bad_sym) for sp in dropped_spans(s)]
gs = [sp for s in doc_scan.sentences(good_sym) for sp in dropped_spans(s)]
ok = len(bs) == 1 and not span_ok(bs[0]) and len(gs) == 1 and span_ok(gs[0])
say(ok, "CONTROL: the pre-fix symptom is flagged, the measured one is not",
    f"read {len(bs)} wrong span(s), {len(gs)} right span(s)")
fail |= not ok
# Retention prose names skip_retain beside partitions that were dropped, and quotes a lock mode: that is
# not a dropped managed table's symptom, and reading it as one is the false positive #939's paragraph hit.
retain_prose = ("## retain\n\nWhere `retire` would raise for one partition (a lock timeout installing its write block, "
                "say, while a `VACUUM` of that partition holds `SHARE UPDATE EXCLUSIVE` on it), `retain` logs "
                "`skip_retain` with the message in `method`, and goes on: the partitions dropped before and after it "
                "stay dropped.\n")
rs = [sp for s in doc_scan.sentences(retain_prose) for sp in dropped_spans(s)]
ok = rs == []
say(ok, "CONTROL: retention prose naming skip_retain is not read as a symptom", f"read {rs}")
fail |= not ok

# ---- THE DOCS ----
docs = [only] if only else doc_scan.living_docs(root)
want = doc_scan.rel(root, only) if only else "docs/runbook.md"
calls = {NONVALIDATOR: 0, VALIDATOR: 0}
quoted = 0
for d in docs:
    r = doc_scan.rel(root, d)
    text = open(d).read()
    for n, raw in code_lines(text):
        if r == want:
            for f in calls:
                if re.search(f + r"\s*\(", raw.partition("--")[0]):
                    calls[f] += 1
        if code_wrong(raw):
            say(False, f"{r}:{n}: a code line has {NONVALIDATOR} validate",
                f"it re-adds NOT VALID only; {VALIDATOR} validates: {raw.strip()[:70]}")
            fail = 1
    for s in doc_scan.sentences(text, r):
        for sp in dropped_spans(s):
            if r == want:
                quoted += 1
            ok = span_ok(sp)
            say(ok, f"{r}:~{s.line}: a dropped table's skip reason is what pgpm logs",
                "it is" if ok else f"the ticks log {measured[0][:60]!r}, not {sp[:40]!r}")
            fail |= not ok

for f in (NONVALIDATOR, VALIDATOR):
    ok = calls[f] > 0
    say(ok, f"LIVENESS: {want} has a code line calling {f}", f"{calls[f]} line(s)")
    fail |= not ok
ok = quoted > 0
say(ok, f"LIVENESS: {want} quotes a dropped table's skip reason", f"{quoted} span(s)")
fail |= not ok
if not fail:
    say(True, "every FK VALIDATE step and dropped-table symptom matches pgpm", "")
sys.exit(1 if fail else 0)
PY
exit "$fail"
