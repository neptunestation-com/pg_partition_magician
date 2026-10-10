#!/usr/bin/env bash
# Guard issue #650: a regrain in flight across an upgrade gets the #449 TRUNCATE guard, from install.sql
# itself and from the regrain's own next tick.
# Run by CI (`./test.sh perf`, and `./test.sh discriminate` proves it catches both mutations below).
#
# THE DEFECT. The guard (a BEFORE TRUNCATE statement trigger on the source child, tests/119) was
# installed by regrain_step's prepare tick alone, and prepare runs only when the capture row trigger is
# ABSENT. A regrain begun under 0.6.0 (whose prepare installed capture and no guard; #449 is newer)
# therefore resumed after the upgrade with capture up and no guard, and stayed that way to its swap:
# re-running install.sql added none, and no tick re-prepared. A TRUNCATE of the source went through, the
# delta saw nothing (TRUNCATE fires no row trigger), and the swap attached copies of every truncated row.
#
# WHY A SHELL HARNESS. The first lever is install.sql's upgrade path, and install.sql cannot be re-run
# from inside a pgTAP file. tests/169 covers the second lever (the resuming tick) on its own; this guard
# covers both, in the order an operator meets them.
#
# WHAT IT ASSERTS:
#   1. LIVENESS WITNESSES: the regrain really is in flight (prepared, then a copy batch that moved rows)
#      and the source really is in 0.6.0's state (capture, no guard) before the upgrade. Every later
#      assertion is "the guard is back", and all of them pass trivially against a fixture that never
#      removed it.
#   2. After re-running install.sql, BEFORE ANY TICK: the guard is on the in-flight source, ENABLE
#      ALWAYS, and on nothing else (identity, not a count: the idle parent's children and the copies stay
#      bare), and a TRUNCATE of the source is refused with the #449 message while the source keeps every
#      row. This is what `regrain_truncate_guard_no_upgrade` breaks.
#   3. A second re-run leaves the guard alone (same oid): the upgrade step is idempotent.
#   4. The guard dropped again, the next tick is a RESUME (copied:N, no regrain_restart row) and it puts
#      the guard back; the TRUNCATE is refused again. This is what `regrain_truncate_guard_no_resume`
#      breaks.
#   5. LIVENESS: the regrain still swaps, and afterwards the parent holds exactly the rows it should, by
#      identity: every seeded id less the two deleted mid-regrain (an asymmetric fixture, so a lost delete
#      and a resurrected one cannot cancel), and no guard remains anywhere.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   regrain_truncate_guard_no_upgrade  -- install.sql's upgrade loop installs nothing (assertion 2)
#   regrain_truncate_guard_no_resume   -- the resuming tick no longer ensures the guard (assertion 4)
#
# Usage: regrain_truncate_guard_upgrade.sh <container> <db> [install.sql]
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0
SRC=gu_p0000000000000000000_to_0000000000000003000

q()  { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
run() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
          psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "$1"; }
install() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
              psql -U postgres -q -d "$DB" -v ON_ERROR_STOP=1 -f "$INSTALL" >/dev/null; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-62s %s\n' "$1" "$2"
  else printf 'FAIL  %-62s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
tick() { q "select pgpm.regrain_step('public.gu', (select child_name from pgpm.part where parent_table = 'public.gu'::regclass and attached order by lo::numeric limit 1), '100', 50)"; }
# 'none' rather than an empty string for no guard, so a query that errors (and prints nothing) cannot read
# as "no guard anywhere"
guards() { q "select coalesce(string_agg(tgrelid::regclass::text || ':' || tgenabled::text, ',' order by tgrelid::regclass::text), 'none') from pg_trigger where tgname = 'pgpm_regrain_truncate_guard'"; }
src_ids() { q "select md5(string_agg(id::text, ',' order by id)) from public.$SRC"; }
truncate_refused() { # prints yes when the TRUNCATE of the source raised the #449 refusal
  local out
  out=$(docker exec "$C" psql -U postgres -d "$DB" -qtA -c "truncate public.$SRC" 2>&1)
  if printf '%s' "$out" | grep -q "cannot TRUNCATE public.$SRC -- a regrain is in flight on it"; then echo yes
  else echo "no ($out)"; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! install; then echo "FAIL  the module under test installed ($INSTALL)"; exit 1; fi

# gu: the parent whose regrain is in flight across the upgrade. gi: an idle managed parent, never
# regrained, whose children must NOT get a guard (the upgrade step is scoped to in-flight sources).
run "create table public.gu (id bigint primary key, payload text);
     insert into public.gu select g*10, 'x' from generate_series(1, 250) g;
     create table public.gi (id bigint primary key, payload text);
     insert into public.gi select g*10, 'x' from generate_series(1, 90) g;" >/dev/null
run "call pgpm.transmute('public.gu', 'id', 1000)" >/dev/null
run "call pgpm.transmute('public.gi', 'id', 1000)" >/dev/null
run "insert into public.gu values (20000, 'frontier'); insert into public.gi values (20000, 'frontier')" >/dev/null
SEED=$(q "select md5(string_agg((g*10)::text, ',' order by g)) from generate_series(1, 250) g")

# ---------------------------------------------------------------- 1. the regrain in flight, as 0.6.0 left it
check "LIVENESS: the prepare tick ran" "$(tick)" "prepared"
check "LIVENESS: a copy batch moved rows (ids 10..90)" "$(tick)" "copied:9"
run "drop trigger pgpm_regrain_truncate_guard on public.$SRC" >/dev/null
check "LIVENESS: the source carries capture and no guard (0.6.0's state)" \
  "$(q "select string_agg(tgname::text, ',' order by tgname) from pg_trigger where tgrelid = 'public.$SRC'::regclass and tgname like 'pgpm_regrain%'")" \
  "pgpm_regrain_capture"
check "LIVENESS: no guard anywhere before the upgrade" "$(guards)" "none"

# ---------------------------------------------------------------- 2. the upgrade itself installs it
if ! install; then echo "FAIL  install.sql re-ran over the in-flight regrain"; fail=1; fi
check "the upgrade put the guard on the in-flight source, and only there" "$(guards)" "$SRC:A"
check "a TRUNCATE before any tick is refused" "$(truncate_refused)" "yes"
check "and the source kept every row (ids 10..2500)" "$(src_ids)" "$SEED"
G1=$(q "select oid from pg_trigger where tgrelid = 'public.$SRC'::regclass and tgname = 'pgpm_regrain_truncate_guard'")

# ---------------------------------------------------------------- 3. idempotent
if ! install; then echo "FAIL  install.sql re-ran a second time"; fail=1; fi
check "a second upgrade leaves the present guard alone (same oid)" \
  "$(q "select oid from pg_trigger where tgrelid = 'public.$SRC'::regclass and tgname = 'pgpm_regrain_truncate_guard'")" "${G1:-none}"

# ---------------------------------------------------------------- 4. the resuming tick installs it too
run "drop trigger pgpm_regrain_truncate_guard on public.$SRC" >/dev/null
check "LIVENESS: the guard is gone again before the resume tick" "$(guards)" "none"
check "the next tick RESUMES (copies ids 100..190)" "$(tick)" "copied:10"
check "LIVENESS: the resume restarted nothing" \
  "$(q "select count(*) from pgpm.log where parent_table = 'public.gu'::regclass and action = 'regrain_restart'")" "0"
check "the resume tick put the guard back on the source, and only there" "$(guards)" "$SRC:A"
check "a TRUNCATE after the resume is refused" "$(truncate_refused)" "yes"
check "and the source kept every row (ids 10..2500)" "$(src_ids)" "$SEED"

# ---------------------------------------------------------------- 5. the regrain still completes, losing nothing
run "delete from public.gu where id in (20, 150)" >/dev/null
for _ in $(seq 1 80); do
  s=$(tick)
  case "$s" in swapped:*) break;; esac
done
check "LIVENESS: the swap ran" \
  "$(q "select count(*) from pgpm.log where parent_table = 'public.gu'::regclass and action = 'regrain' and method = 'copy_swap_drop'")" "1"
check "the parent holds ids 10..2500 less exactly 20 and 150" \
  "$(q "select md5(string_agg(id::text, ',' order by id)) from public.gu where id < 3000")" \
  "$(q "select md5(string_agg((g*10)::text, ',' order by g)) from generate_series(1, 250) g where g not in (2, 15)")"
check "no guard remains after the swap" "$(guards)" "none"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
