#!/usr/bin/env bash
# Guard regrain_step's swap against a scan-under-lock when the managed table has an outgoing
# foreign key (issue #348). Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never
# last a duration coupled to data size.
#
# A fine child is created via `like ... including constraints`, which never copies a FOREIGN KEY
# (no LIKE option does). Before the fix, that leaves every fine child with no outgoing FK at all,
# so the swap's ATTACH PARTITION forces PostgreSQL to validate the parent's outgoing FK for that
# partition from scratch -- an O(rows) scan of the CHILD, inside the ATTACH statement, under
# whatever lock the swap already holds on the managed parent. Measured directly (not by this
# probe, which can only detect a block, not time one): at this guard's default (CHILD_ROWS=
# 8,000,000), attaching that partition with its FK pre-validated took ~20 ms; the identical
# attach without pre-validating took ~532 ms for the same row count -- and that gap is O(rows),
# so it grows without bound on a bigger partition, which is exactly how this reached a
# production statement_timeout.
#
# The fix (mirroring the bound CHECK, which already gets this treatment) adds each of the
# parent's outgoing FKs to the fine child, NOT VALID, then VALIDATEs it immediately -- while the
# child is still empty, so the scan costs nothing. By the swap's ATTACH, PostgreSQL adopts the
# already-validated constraint instead of re-scanning.
#
# WHAT IT ASSERTS, AND AGAINST WHAT (#556, #1456). The consequence an operator sees is a plain INSERT
# into the MANAGED PARENT waiting while the swap runs. The probe writes with no lock_timeout to stand
# in for the bar (30 s only stops a wedged run) and records its LONGEST wait. That wait must stay under
# HALF of what the size-coupled work costs on THIS runner: the FK check of the copy (RI_Initial_Check's
# anti-join, which the unfixed ATTACH runs with the work_mem it gives itself and no parallel workers),
# timed outside any lock before the swap, the quickest of three. A hold that contains that scan cannot
# come in under half of it; a hold that holds no scan is a few metadata changes. A uniformly slow runner
# scales both sides, which a fixed number did not: this used to count writes timing out at a fixed 50 ms,
# the bar checked against one machine, the form that failed correct code on slow runners in
# bench/restore_fk_lock.sh (#1456). It has one size, not two as restore_fk_lock does, because its fixture
# costs an 8M-row copy; calibrating on the work itself is #1456's second option and is immune to a
# uniformly slow runner in the same way.
#
# #556: AN AUTOVACUUM WORKER, NOT THE RUNNER. This guard's six CI failures all read exactly `got 20,
# want 0`. Twenty 50 ms timeouts is one second, deadlock_timeout. The copy the setup fills is not a
# partition until the swap, so `vacuum analyze public.rofk` never reached it: it held CHILD_ROWS rows
# nobody had vacuumed, the next thing autovacuum picks. With a worker on it the swap's ATTACH waits for
# the copy's lock while ALREADY holding the parent's ACCESS EXCLUSIVE from the DETACH, until the
# deadlock check cancels the worker one second later. Reproduced here on correct code by making
# autovacuum eager and slow (autovacuum_naptime 1s, autovacuum_vacuum_cost_delay 20ms, cost_limit 20):
# the guard as it was failed with `got 20, want 0`, and the server logged "canceling autovacuum task
# ... while scanning block 53 of relation public.rofk_p0000000000000000000". Now the setup vacuums every
# unattached copy and waits out any worker already on the fixture, and the probe records how many workers
# were on it as the swap began, a premise, so a run confounded this way says so instead of failing as a
# defect. Under the same eager autovacuum: with the copy's vacuum, longest wait 10.0 ms and 0 workers;
# with it removed, 1013.5 ms and the premise FAILS (1 worker). In production maintain's 200 ms
# lock_timeout bounds the same wait to a skip_regrain, so this is the fixture's confound, not a defect
# this guard exists to catch.
#
# Measured on PG 17.12 (this machine; LOAD = the container held to 1 CPU with 3 busy loops inside it):
#                         longest write wait   bound (half the copy's   verdict
#                                              FK scan)
#   fixed, idle           9.9-12.4 ms          275.8-283.6 ms           PASS (3/3)
#   fixed, LOAD           9.8-87.4 ms          1196.1-1247.4 ms         PASS (3/3)
#   regrain_no_outgoing_fk, idle
#                         585.7-586.8 ms       279.4-279.9 ms           FAIL (2/2)
#   regrain_no_outgoing_fk, LOAD
#                         2607.8-2615.7 ms     1249.3-1343.7 ms         FAIL (2/2)
# Two of the three loaded fixed runs waited 86.3 and 87.4 ms, which the old 50 ms count would have failed:
# #1456's class is here too, it simply never surfaced on CI behind #556's louder second. The mutant's hold is
# the scan plus the swap's own few milliseconds, so it clears the bound by about 2x, idle or loaded. Every
# mutant run passed every LIVENESS line, so discriminate.sh reads its FAIL as a catch.
#
# The fixture is built so the swap has exactly ONE non-trivial fine child: transmute's own step
# is twice regrain's target step, so the coarse monolith covers two sub-ranges, all CHILD_ROWS
# rows landing in the first and nothing in the second. That keeps the swap's cost concentrated in
# one ATTACH statement (one continuous lock hold) rather than spread thin across many small ones,
# which is easier for a probe polling on a commit-per-iteration cadence to actually catch.
#
# Usage: regrain_outgoing_fk_lock.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead,
# to prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
REF_ROWS=${REF_ROWS:-1000}
CHILD_ROWS=${CHILD_ROWS:-8000000}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-52s %s\n' "$1" "$2"
  else printf 'FAIL  %-52s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
# is <sql boolean>: true, false, or "unmeasured" when an operand is missing, never a psql error
is() { q "select coalesce(($1)::text, 'unmeasured')" 2>/dev/null || echo unmeasured; }

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

q "create table public.rofk_ref (id int primary key)" >/dev/null
q "insert into public.rofk_ref select g from generate_series(1, $REF_ROWS) g" >/dev/null
q "create table public.rofk (id bigint primary key,
     ref_id int not null references public.rofk_ref(id), payload text)" >/dev/null
q "insert into public.rofk select g, ((g % $REF_ROWS) + 1), 'x' from generate_series(1, $CHILD_ROWS) g" >/dev/null
q "call pgpm.transmute('public.rofk','id', $((CHILD_ROWS * 2))::bigint, p_paused => false)" >/dev/null
q "insert into public.rofk values ($((CHILD_ROWS * 2 + 1)), 1, 'frontier')" >/dev/null   # freeze the monolith

# Pre-copy everything synchronously, stopping once the cursor reaches the coarse child's own hi
# (fully copied, not yet swapped) -- so the ONE call left to run is the swap itself. Re-fetches
# the coarse child's name every tick: regrain_step's first tick can RENAME it (#266), so a name
# cached before that rename goes stale. A setup that fails (it raises when the run never reaches the
# swap) is a FAIL, never a run that goes on to probe a swap that will not happen and pass on nothing.
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qtA -c "
do \$setup\$
declare s text; n int := 0; v_cursor text; v_hi text; v_child name;
begin
  select hi into v_hi from pgpm.part
   where parent_table = 'public.rofk'::regclass and attached and lo::numeric = 0;
  loop
    select regrain_cursor into v_cursor from pgpm.config where parent_table = 'public.rofk'::regclass;
    exit when v_cursor is not null and v_cursor::numeric >= v_hi::numeric;
    select child_name into v_child from pgpm.part
     where parent_table = 'public.rofk'::regclass and attached and lo::numeric = 0;
    s := pgpm.regrain_step('public.rofk'::regclass, v_child, '$CHILD_ROWS', $((CHILD_ROWS / 4)));
    n := n + 1;
    if n > 500 then raise exception 'regrain setup did not converge'; end if;
  end loop;
end \$setup\$;" >/dev/null; then
  printf 'FAIL  %-52s %s\n' "fixture: the regrain was pre-copied up to its swap" "setup raised (see above)"
  exit 1
fi

q "vacuum analyze public.rofk" >/dev/null
q "vacuum analyze public.rofk_ref" >/dev/null
# The COPIES too (#556). They are not partitions yet, so the vacuum of public.rofk above never reaches them,
# and the one the setup just filled holds CHILD_ROWS rows nobody has vacuumed: exactly what autovacuum picks
# next. A worker on it holds SHARE UPDATE EXCLUSIVE, the swap's ATTACH waits for it while already holding
# the parent's ACCESS EXCLUSIVE from the DETACH, and the wait ends only when the deadlock check cancels the
# worker, deadlock_timeout (1 s) later: every probe write in that second times out, 1000 / 50 = 20, the
# count all six CI failures reported. Vacuumed here, the copy leaves autovacuum nothing to do.
for t in $(q "select child_name from pgpm.part where parent_table = 'public.rofk'::regclass and not attached"); do
  q "vacuum analyze public.$t" >/dev/null
done
# and a worker that was already on one when that vacuum began is waited out, not raced: the swap starts with
# none on the fixture. 60 s at most; the probe records what it finds when the swap starts either way.
AVQ="select count(*) from pg_stat_activity where backend_type = 'autovacuum worker'
       and datname = current_database() and query like '%rofk%'"
for _ in $(seq 1 600); do [ "$(q "$AVQ")" = "0" ] && break; sleep 0.1; done
# THE CALIBRATION: what the size-coupled work costs on THIS runner. The defect's hold contains the FK check
# of the copy, the query ATTACH runs (as it plans it) when the copy carries no validated key of its own;
# timed here outside any lock, three times, the quickest kept.
COPY=$(q "select child_name from pgpm.part where parent_table = 'public.rofk'::regclass and not attached
           order by lo::numeric limit 1")
q "create table public.cal (ms numeric)" >/dev/null
for _ in 1 2 3; do
  q "do \$c\$ declare v_t0 timestamptz; begin
       perform set_config('work_mem', current_setting('maintenance_work_mem'), true);
       perform set_config('max_parallel_workers_per_gather', '0', true);
       v_t0 := clock_timestamp();
       perform fk.ref_id from only public.$COPY fk left join only public.rofk_ref pk on pk.id = fk.ref_id
        where pk.id is null and fk.ref_id is not null;
       insert into public.cal values (extract(epoch from clock_timestamp() - v_t0) * 1000);
     end \$c\$" >/dev/null
done
SCAN=$(q "select coalesce(round(min(ms), 1)::text, 'null') from public.cal")
q "create table public.probe (attempts int, timeouts int, saw boolean, av int, longest numeric)" >/dev/null
q "create table public.done (x int)" >/dev/null

# background: the swap tick, and only the swap tick -- the coarse child's name is looked up fresh
# right before the call, same as setup above.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$swap\$
declare v_child name;
begin
  select child_name into v_child from pgpm.part
   where parent_table = 'public.rofk'::regclass and attached and lo::numeric = 0;
  perform pgpm.regrain_step('public.rofk'::regclass, v_child, '$CHILD_ROWS', $((CHILD_ROWS / 4)));
end \$swap\$;" \
  -c "insert into public.done values (1)" >/tmp/rofk_bg.log 2>&1 &
BG=$!

# COMMIT after every attempt. Locks are held to transaction end and a DO block is ONE transaction, so
# a probe that just loops pins its own lock and blocks the very ATTACH it is trying to observe, which
# makes the run prove nothing. Learned on bench/maintain_lock.sh.
#
# pg_stat_activity is read once per transaction and then frozen (the documented snapshot). The COMMIT
# after every turn of the wait loop below therefore does double duty: it releases the probe's own lock
# (the point just made) AND ends the transaction, so the next turn reads a fresh view and the loop is a
# poll that can wait. Measured on PG 15 (#713): the same loop in one transaction never saw the tick start
# in 400 turns; with a COMMIT per turn it saw it on the second. Do not fold the loop into one transaction.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$p\$
declare n int := 0; t int := 0; saw boolean := false; av int; v_t0 timestamptz; mx numeric := 0;
begin
  -- saw is set where the poll finds the swap and nowhere else (#1379): set after the loop, it read true
  -- when the loop ran out of turns having seen nothing, the vacuous witness restore_fk_lock.sh retired.
  for i in 1 .. 2000000 loop
    if exists(select 1 from pg_stat_activity
               where datname = current_database() and pid <> pg_backend_pid()
                 and query like '%regrain_step%' and state = 'active') then
      saw := true;
      -- what was on the fixture as the swap began, read in the same snapshot that saw it (#556)
      select count(*) into av from pg_stat_activity where backend_type = 'autovacuum worker'
         and datname = current_database() and query like '%rofk%';
      exit;
    end if;
    commit;
  end loop;
  while not exists(select 1 from public.done) loop
    v_t0 := clock_timestamp();
    begin
      set local lock_timeout = '30s';
      insert into public.rofk (id, ref_id, payload) values ($((CHILD_ROWS * 4)) + n, 1, 'live write');
    exception when others then t := t + 1; end;
    mx := greatest(mx, extract(epoch from clock_timestamp() - v_t0) * 1000);
    n := n + 1;
    commit;
  end loop;
  insert into public.probe values (n, t, saw, av, mx);
end \$p\$;" >/dev/null 2>&1
wait $BG

check "LIVENESS: the probe overlapped a running swap"          "$(q "select saw::text from public.probe")"          "true"
check "LIVENESS: at least one write landed inside it"          "$(q "select (attempts > 0)::text from public.probe")" "true"
check "LIVENESS: no autovacuum worker was on the fixture as the swap began" "$(q "select coalesce(av::text, 'unread') from public.probe")" "0"
LONGEST=$(q "select coalesce(round(longest, 1)::text, 'null') from public.probe")
BOUND=$(q "select coalesce(round(${SCAN:-null} / 2, 1)::text, 'null')")
printf '      the FK scan of the copy, quickest of 3: %s ms (want at least 40); longest write wait %s ms over %s attempts (want under %s)\n' \
  "${SCAN:-null}" "${LONGEST:-null}" "$(q "select attempts from public.probe")" "${BOUND:-null}"
check "LIVENESS: the copy's FK scan takes a measurable time here" "$(is "${SCAN:-null} >= 40")" "true"
check "the swap blocks parent writes for under half that scan" "$(is "${LONGEST:-null} < ${BOUND:-null}")" "true"
# conparentid = 0 picks the top-level constraint. An FK referencing a PARTITIONED table also gets one
# pg_constraint row per partition of the referencING side, so an unfiltered count would report one
# per attached partition, not 1.
check "the outgoing FK is intact and adopted, not duplicated" "$(q "select count(*)::text from pg_constraint
       where confrelid = 'public.rofk_ref'::regclass and contype = 'f' and conparentid = 0")" "1"

exit "$fail"
