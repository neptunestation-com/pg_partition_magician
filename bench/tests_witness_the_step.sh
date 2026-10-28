#!/usr/bin/env bash
# Prove that four pgTAP witnesses FAIL when the step they vouch for did not happen, by taking the step away
# and running the file: a witness that also holds without its step is not evidence of the step.
#
# WHY THIS GUARD EXISTS (issues #1377 and #1378, pass 13). Each of these witnessed its step with a predicate
# that was already true without it, the repo's oldest class (CLAUDE.md, "Assertions that pass for the wrong
# reason"):
#   tests/timescale/db/14  claimed the cutover's AUTOMATIC pre-drain drains a backlog above its threshold,
#             and asserted only the cutover's end state, which the under-lock reconcile produces alone
#             (correctness never depends on the pre-drain), plus a drain-key index nothing has built since #175;
#   tests/timescale/db/47  (B) witnessed 'its pre-drain applied' the update with the default p_drain_batch
#             5000, under which the pre-drain loop never calls the drain step (pgpm_dbatch's only site) for a
#             2-row delta, so the pgpm_dbatch survival beside it was vacuous;
#   tests/190 (E) witnessed 'those steps were copying' by one copy not attached, which the step BEFORE them
#             already made true, so later steps that did nothing at all passed 'do not ANALYZE it again';
#   tests/279 (3) read write_child and write_ceiling of progress() as scalar subqueries and asserted null,
#             which an EMPTY result also gives, so a progress() that lost the table passed.
#
# HOW. Per file, in fresh databases named <db> in <container>:
#   CONTROL   the file passes, every planned assertion ok, against the clean code;
#   DEFECT    the step taken away, the file runs to its end and reports a `not ok` IN THE SECTION whose
#             witness is under test (a premise line counts here: the subject is the witness itself):
#               ts14, ts47  the module's cutover with its tracked pre-drain skipped (`if p_predrain and
#                           v_track` made false), so the under-lock reconcile does all the work;
#               190         the file with pgpm.regrain_step wrapped so its third and later calls do nothing
#                           (planted before part E's probe function, as the issue's reproduction does);
#               279         the core's progress() returning no row for a table whose cell is detached by hand.
#   LIVENESS  each defect is shown present, by behaviour, under the defect and absent under the clean code:
#             a probe hypertable's cutover writes keys into its copy without the hypertable's lock (clean) or
#             only with it (defect); the wrapped steps 3 and 4 recorded themselves as no-ops; a probe table
#             with a hand-detached cell is reported by progress() (clean) or not (defect).
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each the file's pre-fix witness:
#   predrain_witnessed_by_end_state_ts14   -- tests/timescale/db/14's hp_auto section back to its end state
#   predrain_witnessed_by_end_state_ts47   -- tests/timescale/db/47 (B)'s online-write witness removed
#   later_steps_witnessed_before_them_190  -- tests/190 (E)'s witness back to count(not attached) = 1
#   detached_write_child_scalar_null_279   -- tests/279 (3) back to two scalar subqueries asserted null
#
# Usage: tests_witness_the_step.sh <container> <db> [test file]
# With no third argument it judges tests/190 and tests/279 on the plain core image. With one it judges THAT
# file in place of the one it stands for, recognised by its file name or, for a mutant bench/discriminate.sh
# built (<mutation>.sql), by the mutation's MUTATION_SRC; a /repo/... path is mapped to this checkout. The
# timescale files are judged only when named, on the timescale track's container, over TCP (see
# run_timescale). Every install and test is fed from the host over stdin. Needs python3 on the host.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ONLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
say() { printf '%s  %-58s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i "$C" psql -U postgres -X "$@"; }
work=$(mktemp -d)
cleanup() { q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

T190="tests/190_reverse_and_legibility_edges_test.sql"; F190="$ROOT/$T190"
T279="tests/279_progress_write_child_exists_test.sql"; F279="$ROOT/$T279"
TS14="tests/timescale/db/14_from_hypertable_online_drain_test.sql"; FTS14="$ROOT/$TS14"
TS47="tests/timescale/db/47_from_hypertable_scratch_tables_in_pg_temp_test.sql"; FTS47="$ROOT/$TS47"
SEL=" 190 279 "
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then say FAIL "GUARD: the test file to judge exists" "$ONLY"; exit 1; fi
  base=$(basename "$ONLY")
  src=$(python3 - "$ROOT/bench/mutations" "${base%.*}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import mutate
print(mutate.MUTATION_SRC.get(sys.argv[2], ""))
PY
)
  case "$base:$src" in
    "$(basename "$T190")":*|*:"$T190") SEL=" 190 "; F190="$ONLY" ;;
    "$(basename "$T279")":*|*:"$T279") SEL=" 279 "; F279="$ONLY" ;;
    "$(basename "$TS14")":*|*:"$TS14") SEL=" ts14 "; FTS14="$ONLY" ;;
    "$(basename "$TS47")":*|*:"$TS47") SEL=" ts47 "; FTS47="$ONLY" ;;
    *) say FAIL "GUARD: the file to judge is one of the files this guard knows" "$ONLY -> '${src}'"; exit 1 ;;
  esac
fi
sel() { [[ "$SEL" == *" $1 "* ]]; }
# The timescale track's image does not trust the local socket (see run_timescale): its files are judged over TCP.
if sel ts14 || sel ts47; then q() { docker exec -i -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres -X "$@"; }; fi
v() { q -d "$DB" -tAq -c "$1" </dev/null 2>&1; }
# vf <script>: a script over stdin, one statement at a time (a CALL that commits cannot run inside -c's one string)
vf() { q -d "$DB" -tAq -f - <<<"$1" 2>&1; }

# plant <src> <dst> <find> <replace>: <src> with <find> replaced exactly once, written to <dst>. A pattern that
# no longer matches exactly once is a FAILURE, never a silently unmutated copy (the discipline of mutate.py).
plant() {
  python3 - "$@" <<'PY'
import sys
src, dst, find, repl = sys.argv[1:5]
t = open(src).read()
n = t.count(find)
if n != 1:
    sys.exit(f"pattern matched {n} time(s), expected 1: {find.splitlines()[0]!r}")
open(dst, "w").write(t.replace(find, repl))
PY
}

# load <core install.sql> [<hypertable install.sql>]: a fresh <db> with pgtap, the core, and for the timescale
# files TimescaleDB, the module and tests/timescale/fixtures.sql.
load() {
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "create database $DB" </dev/null >"$work/install.log" 2>&1 || return 1
  q -d postgres -q -c "alter database $DB set client_min_messages = warning" </dev/null >>"$work/install.log" 2>&1 || return 1
  if [ -n "${2:-}" ]; then
    q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists timescaledb" </dev/null >>"$work/install.log" 2>&1 || return 1
  fi
  q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists pgtap" </dev/null >>"$work/install.log" 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f - <"$1" >>"$work/install.log" 2>&1 || return 1
  if [ -n "${2:-}" ]; then
    q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$2" >>"$work/install.log" 2>&1 &&
      q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$ROOT/tests/timescale/fixtures.sql" >>"$work/install.log" 2>&1 || return 1
  fi
}

# judge <label> <pass|fail> <test file> <section regex>: run the file in <db> and read its TAP. A DEFECT run
# must fail an assertion whose description matches the section's regex: that is the witness under test.
judge() {
  local label="$1" expect="$2" file="$3" section="$4" out rc planned oks notoks hit
  out=$(q -d "$DB" -tA -f - <"$file" 2>&1); rc=$?
  planned=$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' <<<"$out" | head -1)
  oks=$(grep -cE '^ok [0-9]+' <<<"$out")
  notoks=$(grep -cE '^not ok [0-9]+' <<<"$out")
  if [ "$rc" != 0 ] || [ -z "$planned" ] || [ $((oks + notoks)) != "$planned" ] || grep -qE '^ERROR:|^psql:.*ERROR:' <<<"$out"; then
    say FAIL "$label: the file ran to its end" "psql exit $rc, plan ${planned:-none}, $oks ok, $notoks not ok"
    grep -E 'ERROR|^not ok' <<<"$out" | head -5 | sed 's/^/      /'
    fail=1; return
  fi
  if [ "$expect" = pass ]; then
    if [ "$notoks" = 0 ]; then say PASS "$label" "$oks/$planned ok"
    else say FAIL "$label" "$notoks not ok of $planned"; grep -E '^not ok' <<<"$out" | sed 's/^/      /'; fail=1; fi
    return
  fi
  hit=$(grep -E '^not ok [0-9]+' <<<"$out" | grep -E "$section" | head -1)
  if [ -n "$hit" ]; then say PASS "$label" "$(cut -c1-70 <<<"$hit")"
  else
    say FAIL "$label" "$notoks not ok of $planned, none in the section: its witness holds without the step"
    fail=1
  fi
}

# expect_v <label> <expected> <sql>: a LIVENESS read of the database as it stands.
expect_v() {
  local got; got=$(v "$3")
  if [ "$got" = "$2" ]; then say PASS "LIVENESS: $1" "$got"
  else say FAIL "LIVENESS: $1" "expected $2, got: $got"; fail=1; fi
}

# ---- tests/timescale/db/14 and 47: the cutover's tracked pre-drain ---------------------------------------------
# The probe: a keyed hypertable, a tracked copy, 10 dirty keys, a cutover with batch 2; whether any key reached the
# copy while this backend did NOT hold the hypertable's ACCESS EXCLUSIVE lock, and how many keys did under it.
PREDRAIN_PROBE="select mk_keyed_hypertable('g14p', 20, '1 day', '4 days');
call pgpm.from_hypertable_copy('g14p', 'ts', p_track_changes => true);
create table g14p_src as select 'g14p'::regclass::oid as src;
create table g14p_writes (device_id bigint, locked boolean);
create function g14p_seen() returns trigger language plpgsql as \$\$ begin
  insert into g14p_writes values (new.device_id, exists (select 1 from pg_locks l where l.pid = pg_backend_pid()
    and l.relation = (select src from g14p_src) and l.mode = 'AccessExclusiveLock' and l.granted));
  return null; end \$\$;
create trigger g14p_seen after insert on g14p_pgpm_dest for each row execute function g14p_seen();
update g14p set temp = -1 where device_id <= 10;
call pgpm.from_hypertable_cutover('g14p', 'ts', interval '1 month', p_drain_batch => 2, p_paused => false);"
PREDRAIN_READ="select (count(*) filter (where not locked) > 0)::text || '|' || (count(distinct device_id) filter (where locked) = 10)::text from g14p_writes"
PREDRAIN_FIND="  if p_predrain and v_track then
"
for n in ts14 ts47; do
  sel "$n" || continue
  if [ "$n" = ts14 ]; then f="$FTS14"; t="$TS14"; section='pre-drain|under-lock pass|backlog'
  else f="$FTS47"; t="$TS47"; section='pre-drain applied|survive the tracked cutover'; fi
  if load "$ROOT/pgpm_core/install.sql" "$ROOT/pgpm_hypertable/install.sql"; then
    judge "CONTROL: $t passes against the clean module" pass "$f" .
    vf "$PREDRAIN_PROBE" >/dev/null
    expect_v "the clean cutover pre-drains keys into the copy online" "true|false" "$PREDRAIN_READ"
  else
    say FAIL "fixture: TimescaleDB, the core, the module and the fixtures loaded" "$(grep -m1 -E 'ERROR|FATAL' "$work/install.log")"; fail=1
  fi
  if plant "$ROOT/pgpm_hypertable/install.sql" "$work/no_predrain.sql" "$PREDRAIN_FIND" "  if false then
"; then
    if load "$ROOT/pgpm_core/install.sql" "$work/no_predrain.sql"; then
      judge "DEFECT: $t fails when the cutover does not pre-drain" fail "$f" "$section"
      vf "$PREDRAIN_PROBE" >/dev/null
      expect_v "with the pre-drain skipped every key reaches the copy under the lock" "false|true" "$PREDRAIN_READ"
    else
      say FAIL "fixture: the module with no tracked pre-drain loaded" "$(grep -m1 -E 'ERROR|FATAL' "$work/install.log")"; fail=1
    fi
  else
    say FAIL "fixture: planted the defect: the cutover skips its tracked pre-drain" "pgpm_hypertable/install.sql moved; fix the pattern"; fail=1
  fi
done

# ---- tests/190 (E): the later regrain steps did copy ----------------------------------------------------------
E_ANCHOR="create function public.t190_step_analyzes() returns boolean language plpgsql as \$\$
"
E_NOOP="create table public.t190g_noop (n int);
create sequence public.t190g_calls;
alter function pgpm.regrain_step(regclass, name, text, integer) rename to regrain_step_t190g;
create function pgpm.regrain_step(p_parent regclass, p_child name, p_target_step text default null, p_batch int default null)
returns text language plpgsql as \$f\$
begin
  if nextval('public.t190g_calls') <= 2 then
    return pgpm.regrain_step_t190g(p_parent, p_child, p_target_step, p_batch);
  end if;
  insert into public.t190g_noop values (currval('public.t190g_calls'));
  return 'noop';
end \$f\$;
"
if sel 190; then
  if load "$ROOT/pgpm_core/install.sql"; then
    judge "CONTROL: $T190 passes against the clean install" pass "$F190" .
  else
    say FAIL "fixture: the clean install loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
  fi
  if plant "$F190" "$work/t190_noop_steps.sql" "$E_ANCHOR" "$E_NOOP$E_ANCHOR"; then
    if load "$ROOT/pgpm_core/install.sql"; then
      judge "DEFECT: $T190 (E) fails when its later steps do nothing" fail "$work/t190_noop_steps.sql" '\(E\)|E: '
      expect_v "part E's third and fourth steps did nothing" "3,4" \
        "select coalesce(string_agg(n::text, ',' order by n), 'none') from public.t190g_noop"
    else
      say FAIL "fixture: the clean install loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  else
    say FAIL "fixture: planted the defect: steps 3 and on do nothing" "$T190 moved; fix the pattern"; fail=1
  fi
fi

# ---- tests/279 (3): progress() still reports the table whose cell was detached by hand ----------------------------
# The probe: a one-second grid; the attached cell under now() detached by hand, in a transaction rolled back; the
# rows progress() reports for the table then.
PROGRESS_PROBE="create table public.g14q (ts timestamptz not null, body text);
insert into public.g14q select now() - interval '1 hour', 'x';
call pgpm.transmute('public.g14q', 'ts', interval '1 second', 30, p_paused => false);"
PROGRESS_READ="begin;
select format('alter table public.g14q detach partition public.%I', p.child_name) from pgpm.part p
 where p.parent_table = 'public.g14q'::regclass and p.attached
   and p.lo::timestamptz <= now() and now() < p.hi::timestamptz \\gexec
select count(*) from pgpm.progress('public.g14q');
rollback;"
WC_FIND="      write_child := v_wc_name; write_ceiling := v_wc_hi;
"
if sel 279; then
  if load "$ROOT/pgpm_core/install.sql"; then
    judge "CONTROL: $T279 passes against the clean install" pass "$F279" .
    vf "$PROGRESS_PROBE" >/dev/null
    got=$(vf "$PROGRESS_READ" | grep -E '^[0-9]+$')
    if [ "$got" = 1 ]; then say PASS "LIVENESS: the clean progress() reports a table with a detached cell" "$got row"
    else say FAIL "LIVENESS: the clean progress() reports a table with a detached cell" "got: $got"; fail=1; fi
  else
    say FAIL "fixture: the clean install loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
  fi
  if plant "$ROOT/pgpm_core/install.sql" "$work/progress_loses_table.sql" "$WC_FIND" "      if v_wc_name is null and exists (select 1 from pgpm.part p where p.parent_table = r.parent_table and p.attached
                   and pgpm._part_detached_by_hand(r.parent_table, p.child_oid, p.retiring_at)) then
        continue;
      end if;
$WC_FIND"; then
    if load "$work/progress_loses_table.sql"; then
      judge "DEFECT: $T279 (3) fails when progress() loses the table" fail "$F279" 'hand-detached|nor its ceiling'
      vf "$PROGRESS_PROBE" >/dev/null
      got=$(vf "$PROGRESS_READ" | grep -E '^[0-9]+$')
      if [ "$got" = 0 ]; then say PASS "LIVENESS: the defect's progress() drops a table with a detached cell" "$got rows"
      else say FAIL "LIVENESS: the defect's progress() drops a table with a detached cell" "got: $got"; fail=1; fi
    else
      say FAIL "fixture: the install whose progress() loses the table loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  else
    say FAIL "fixture: planted the defect: progress() skips a table with a detached cell" "install.sql moved; fix the pattern"; fail=1
  fi
fi

if [ "$fail" = 0 ]; then say PASS "every judged witness fails without its step" "${SEL# }"
else say FAIL "every judged witness fails without its step" "${SEL# }"; fi
exit "$fail"
