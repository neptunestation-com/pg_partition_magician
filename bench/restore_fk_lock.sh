#!/usr/bin/env bash
# Guard restore_incoming_fks against blocking the MANAGED PARENT for O(referencing table) (issue #265).
# Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never last a
# duration coupled to data size.
#
# Re-adding a preserve-managed FK is ADD CONSTRAINT ... NOT VALID then VALIDATE. Before #265 both shared one
# transaction, so the ADD's SHARE ROW EXCLUSIVE on the referencing table AND the managed parent was held across
# the VALIDATE's scan: INSERT/UPDATE/DELETE on the parent (the table pgpm exists to keep online) blocked for
# O(referencing rows), measured at 224 ms against 4M rows and linear. The fix stops at NOT VALID and leaves
# the VALIDATE to a later tick, under locks that block no writes. Mutation restore_fk_inline_validate puts
# the inline VALIDATE back.
#
# WHAT THIS GUARD MEASURES: COUPLING, NOT A DURATION (#1456, #1408, #1066). It used to run probe INSERTs into
# the parent under a fixed 50 ms lock_timeout and require that none time out. That stood in for the bar with
# an absolute number checked against one machine: the fixed restore held 4.4 ms there, the mutant 222 ms. On
# a slow GitHub runner the FIXED restore's own hold reached 95 to 167 ms against the same fixture, one probe
# write timed out, and the guard failed correct code (#1456 lists five such runs, main's own among them). No
# duration says anything about coupling when the size never changes: 10 ms on one runner and 130 ms on another
# differ by the runner, not by the data.
#
# So the guard now asks #263's question directly, on whatever runner it is on. It restores the same key
# shape against TWO referencing tables, REF_SMALL rows and REF_ROWS rows (one sixteenth and the whole), and
# measures, per restore, how long the parent was blocked: the longest probe write whose interval overlapped
# that restore's window (no lock_timeout to stand in for it; 30 s only stops a wedged run). The restores are
# interleaved, ROUNDS per size, and each size keeps its QUIETEST round, since noise (a scheduler stall, a
# cgroup throttle, a checkpoint) only ever adds time. The claim is that the blocked span does not grow with
# the size: the large table's quietest round may exceed the small table's by less than half of what the
# extra rows cost to scan on this same runner, timed outside any lock with the query the VALIDATE runs
# (RI_Initial_Check's anti-join, with the work_mem it gives itself and, as SPI_prepare plans it, no parallel
# workers), also quickest of ROUNDS. A uniformly slow runner scales both sides: the fixed hold, which holds no
# scan, grows by nothing however slow the runner, and the mutant's grows by its VALIDATE of the extra 3.75M
# rows, which is that same scan and so about twice the bound.
#
# The premises, each a LIVENESS line, so a run that could not judge says so instead of passing:
#   the probe was writing before the first window began (a GATE: the probe announces itself and every
#     window starts after it, so its write span contains every window by construction, nothing is caught);
#   every window was overlapped by at least one write (else that round's blocked span is unobserved);
#   a CONTROL: a known 300 ms SHARE ROW EXCLUSIVE hold on the parent, which the probe must report as a
#     blocked write of at least 200 ms, or the instrument cannot see a hold at all and every verdict is empty;
#   the extra rows take at least 40 ms to scan here, or the bound is too small to sit above noise.
# Between rounds the key just restored is suspended again with pgpm.suspend_incoming_fks(), the inverse
# regrain's swap uses, and each restore names its key by id, so every round re-adds exactly one key.
#
# Measured on PG 17.12 (this machine; LOAD = the container held to 1 CPU with 3 busy loops inside it, a
# CPU-starved runner):
#                         blocked span, quickest   grew      bound (half the   verdict
#                         round: small / large               scan's growth)
#   fixed, idle           4.3-4.5 / 4.2-4.5 ms     -0.2-0.2  220-276 ms        PASS (4/4)
#   fixed, LOAD           4.0-4.6 / 4.5-4.9 ms     -0.1-0.9  1048-1056 ms      PASS (3/3)
#   restore_fk_inline_validate, idle
#                         56.5-58.6 / 462-493 ms   406-436   214-231 ms        FAIL (3/3)
#   restore_fk_inline_validate, LOAD
#                         212-213 / 1998-2111 ms   1785-1899 1001-1041 ms      FAIL (2/2)
# Under LOAD single rounds of the FIXED restore blocked the parent for 69 to 84 ms (1 to 5 rounds of 10 per
# run), each of which the old 50 ms count would have failed, and the old guard itself, run under the same LOAD
# against the same fixed code, failed 2 of 8 runs with CI's signature exactly (`got 1, want 0` on an 87.7 and
# a 91.4 ms restore). The quickest-round rule filters those stalls out. The mutant's growth is the scan
# itself (VALIDATE growth / calibration growth 0.89 to 0.95), so it clears the bound by 1.8x to 1.9x, idle or
# loaded: that margin is structural, not a property of the machine. Every mutant run passed all four
# LIVENESS lines, so discriminate.sh reads each FAIL as a catch.
#
# WHY THE PROBE DOES NOT WAIT FOR THE RESTORE (#416, kept). A plpgsql loop that polled pg_stat_activity
# for the restore and only then wrote missed the fixed restore's ~4 ms window intermittently, and its
# witness was set after the loop, so it could not fail. The gate above replaced it and stays. COMMIT after
# every probe attempt for the same reason as before: locks are held to transaction end and a DO block is
# ONE transaction, so a probe that does not commit pins its own ROW EXCLUSIVE and starves the ADD it is
# observing.
#
# Usage: restore_fk_lock.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to prove
# this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
PARENT_ROWS=${PARENT_ROWS:-200000}
REF_ROWS=${REF_ROWS:-4000000}        # the LARGE referencing table
REF_SMALL=${REF_SMALL:-250000}       # the SMALL one: one sixteenth, so the sizes differ by 3.75M rows
ROUNDS=${ROUNDS:-5}                  # restores per size; the verdict reads each size's quietest round
CONTROL_MS=300                       # the known hold the instrument must see
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-62s %s\n' "$1" "$2"
  else printf 'FAIL  %-62s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
# is <sql boolean>: true, false, or "unmeasured" when an operand is missing, never a psql error
is() { q "select coalesce(($1)::text, 'unmeasured')" 2>/dev/null || echo unmeasured; }

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

q "create table public.messages (id bigint primary key, body text)" >/dev/null
q "insert into public.messages select g, 'x' from generate_series(1, $PARENT_ROWS) g" >/dev/null
for k in s l; do
  n=$REF_SMALL; [ "$k" = l ] && n=$REF_ROWS
  q "create table public.reactions_$k (id bigint primary key,
       message_id bigint not null references public.messages(id), v text)" >/dev/null
  q "insert into public.reactions_$k select g, ((g % $PARENT_ROWS) + 1), 'r'
       from generate_series(1, $n) g" >/dev/null
done
# 'preserve' drops both incoming FKs at conversion and records them, so restore_incoming_fks has work to do.
# Everything stays in the monolith and the DEFAULT is empty, so its quiescence gates are already satisfied.
q "call pgpm.transmute('public.messages','id', $PARENT_ROWS::bigint,
     p_incoming_fks => 'preserve', p_paused => false)" >/dev/null
q "vacuum analyze public.messages" >/dev/null
q "vacuum analyze public.reactions_s" >/dev/null
q "vacuum analyze public.reactions_l" >/dev/null
declare -A ID   # each size's pgpm.dropped_fk row, which restore_incoming_fks is handed by id
for k in s l; do
  ID[$k]=$(q "select id from pgpm.dropped_fk where referencing_table = 'public.reactions_$k'::regclass")
done
# wr: one row per write attempt, as the INTERVAL it occupied. win: one row per measured window (the control,
# then each restore). cal: one row per timing of the scan a size-coupled hold would contain.
q "create table public.wr (t0 timestamptz, t1 timestamptz, timed_out boolean)" >/dev/null
q "create table public.win (seq int primary key, kind text, lo timestamptz, hi timestamptz,
     n text, readded boolean)" >/dev/null
q "create table public.cal (kind text, ms numeric)" >/dev/null
q "create table public.gate (x int)" >/dev/null
q "create table public.done (x int)" >/dev/null

# THE PROBE, started FIRST. COMMIT after every attempt: locks are held to transaction end and a DO block is
# ONE transaction, so a probe that does not commit pins its own ROW EXCLUSIVE on the parent and blocks the
# very ADD it is trying to observe, which makes the run prove nothing. Learned on bench/maintain_lock.sh.
# lock_timeout is a SAFETY BOUND, not the instrument: a write waits for as long as the parent is blocked and
# its interval says how long that was. 30 s only stops a wedged run from hanging the job.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$w\$
declare n int := 0; ok boolean; v_t0 timestamptz;
begin
  insert into public.gate values (1);
  commit;
  for i in 1 .. 2000000 loop
    exit when exists(select 1 from public.done);
    ok := true;
    v_t0 := clock_timestamp();
    begin
      set local lock_timeout = '30s';
      insert into public.messages (id, body) values ($PARENT_ROWS + n + 1, 'live write');
    exception when others then ok := false;
    end;
    n := n + 1;
    insert into public.wr (t0, t1, timed_out) values (v_t0, clock_timestamp(), not ok);
    commit;
  end loop;
end \$w\$;" >/dev/null 2>&1 &
PROBE=$!

gate=0
for _ in $(seq 1 600); do
  [ "$(q "select count(*) from public.gate")" != "0" ] && { gate=1; break; }
  sleep 0.1
done

# window <seq> <kind> <statement>: run the statement bracketed by its own interval. Separate -c arguments, so
# each is its own transaction and the window's lock hold is exactly the statement's.
window() {
  docker exec "$C" psql -U postgres -d "$DB" -qtA \
    -c "insert into public.win (seq, kind, lo) values ($1, '$2', clock_timestamp())" \
    -c "$3" \
    -c "update public.win set hi = clock_timestamp() where seq = $1" 2>&1
}

# THE CONTROL: a known CONTROL_MS hold of the lock the defect holds, on the parent. The probe must report a
# blocked write of most of it, or the instrument cannot see a hold at all and every verdict below is empty.
window 0 control "begin; lock table public.messages in share row exclusive mode;
                  select pg_sleep($CONTROL_MS / 1000.0); commit;" >/dev/null

# THE ROUNDS, sizes interleaved so a load that drifts over the run lands on both. Each round first times the
# scan a coupled hold would contain (the VALIDATE's own query, as it plans it), outside any lock, then
# suspends whatever key the last round restored (pgpm's own inverse, the one regrain's swap uses) and
# restores this size's key alone, by id.
seq=0
for _ in $(seq 1 "$ROUNDS"); do
  for k in s l; do
    seq=$((seq + 1))
    q "do \$c\$ declare v_t0 timestamptz; begin
         perform set_config('work_mem', current_setting('maintenance_work_mem'), true);
         perform set_config('max_parallel_workers_per_gather', '0', true);
         v_t0 := clock_timestamp();
         perform fk.message_id from only public.reactions_$k fk left join public.messages pk on pk.id = fk.message_id
          where pk.id is null and fk.message_id is not null;
         insert into public.cal values ('$k', extract(epoch from clock_timestamp() - v_t0) * 1000);
       end \$c\$" >/dev/null
    q "select pgpm.suspend_incoming_fks('public.messages', true)" >/dev/null
    out=$(window "$seq" "$k" "select pgpm.restore_incoming_fks('public.messages', array[${ID[$k]}]::bigint[])")
    q "update public.win set n = '$(tr -d '[:space:]' <<<"$out")',
         readded = exists(select 1 from pg_constraint where conrelid = 'public.reactions_$k'::regclass
                           and contype = 'f' and conparentid = 0)
       where seq = $seq" >/dev/null
  done
done
q "insert into public.done values (1)" >/dev/null
wait $PROBE

# blocked(w): the longest write attempt that overlapped window w, in ms. Intervals rather than start
# instants: the attempt that matters most began before the hold and waited it out.
BLK="select w.seq, w.kind, w.lo, w.hi, count(a.*) as n_over,
            coalesce(max(extract(epoch from a.t1 - a.t0) * 1000), 0) as ms
       from public.win w left join public.wr a on a.t0 <= w.hi and a.t1 >= w.lo
      group by w.seq, w.kind, w.lo, w.hi"
r1() { q "select coalesce(round(($1)::numeric, 1)::text, 'null')" 2>/dev/null || echo null; }
CTRL=$(r1 "select ms from ($BLK) b where kind = 'control'")
MIN_s=$(r1 "select min(ms) from ($BLK) b where kind = 's'")
MIN_l=$(r1 "select min(ms) from ($BLK) b where kind = 'l'")
CAL_s=$(r1 "select min(ms) from public.cal where kind = 's'")
CAL_l=$(r1 "select min(ms) from public.cal where kind = 'l'")
GROWTH=$(r1 "$MIN_l - $MIN_s")
SCAN_GROWTH=$(r1 "$CAL_l - $CAL_s")
BOUND=$(r1 "$SCAN_GROWTH / 2")
UNSEEN=$(q "select count(*) from ($BLK) b where n_over = 0")

check "LIVENESS: the probe was writing before the first window began" "$gate" "1"
check "LIVENESS: every window was overlapped by a probe write" "${UNSEEN:-?} unseen" "0 unseen"
printf '      control: longest wait %s ms against a %s ms hold (want at least %s)\n' "$CTRL" "$CONTROL_MS" "$((CONTROL_MS * 2 / 3))"
check "LIVENESS: the probe saw the control's hold as a blocked write" "$(is "$CTRL >= $CONTROL_MS * 2 / 3")" "true"
printf '      the anti-join scan, quickest of %s: small %s ms, large %s ms, so %s ms more (want at least 40)\n' \
  "$ROUNDS" "$CAL_s" "$CAL_l" "$SCAN_GROWTH"
check "LIVENESS: the extra referencing rows take a measurable time to scan" "$(is "$SCAN_GROWTH >= 40")" "true"
printf '      per round, blocked ms (window ms): %s\n' \
  "$(q "select string_agg(b.kind || ' ' || round(b.ms::numeric, 1) || ' (' || round(extract(epoch from b.hi - b.lo)::numeric * 1000, 1) || ')', ', ' order by b.seq) from ($BLK) b")"
check "the FK was re-added in every round" \
  "$(q "select count(*) filter (where readded and n = '1') || ' of ' || count(*) from public.win where kind <> 'control'")" \
  "$((2 * ROUNDS)) of $((2 * ROUNDS))"
printf '      blocked, quickest round: small %s ms, large %s ms, so it grew %s ms (want under %s, half the scan'"'"'s growth)\n' \
  "$MIN_s" "$MIN_l" "$GROWTH" "$BOUND"
check "the parent's blocked-write span does not grow with the referencing table" "$(is "$GROWTH < $BOUND")" "true"

exit "$fail"
