#!/usr/bin/env bash
# Guard obtain() at an `int` id column's type ceiling (issue #578). Run by CI (`./test.sh perf`, and
# `./test.sh discriminate` proves it catches its defect).
#
# THE DEFECT. obtain()'s grid-ceiling guard (#299) trapped errors from _encode only, and _encode is a
# passthrough for `id`: it cannot know the column is int4. So on an int column whose frontier is within
# obtain steps of 2^31-1, the lookahead's first inexpressible upper bound raised from CREATE TABLE ...
# PARTITION OF itself, aborting the whole obtain and rolling back every partition it had built before
# that candidate. maintain_obtain caught it and logged skip_obtain, every tick, forever: the grid froze
# and a write of an id that DOES have an expressible partition was refused until an operator ran
# extend_to by hand. The documented behaviour at the ceiling is to EXIT with whatever was built.
#
# WHY A SHELL HARNESS, GIVEN tests/146 ALREADY PROVES THE LOGIC. That file drives each tick through a
# DO block in one session. This drives the production entry point, pgpm.maintain_obtain_all() (what
# the pgpm_obtain cron job calls), across THREE separate sessions and transactions, and it is what
# bench/discriminate.sh can run against the mutant that puts the encode-only check back: the mutation
# apparatus only drives guards under bench/.
#
# WHAT IT ASSERTS, and why each one is load-bearing:
#
#   1. LIVENESS: transmute built the grid (the fixture is live), and the 30-step lookahead from the
#      frontier cell really does cross 2^31-1, so every tick below meets the ceiling. Without that the
#      "no skip_obtain" assertions would pass on a tick that never reached the defect.
#   2. Tick 1 did the work: the obtain row for the LAST expressible cell [2147470000, 2147480000) is in
#      pgpm.log, and nothing past it was built. A tick that built nothing (backed off, paused, not run)
#      cannot satisfy this, so the negatives after it are not vacuous.
#   3. Per tick: no skip_obtain row for the table, no back-off, and a write of a tick-specific id lands
#      BY IDENTITY in the partition obtain built for [2147400000, 2147410000), not merely "did not raise".
#
# Usage: obtain_int_ceiling.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q()   { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
run() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
          psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-72s %s\n' "$1" "$2"
  else printf 'FAIL  %-72s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 -f "$INSTALL" >"$LOG" 2>&1; then
  echo "FAIL  install did not complete"; sed 's/^/      /' "$LOG"; exit 1
fi

run "create table public.oic (id int primary key, payload text)" >/dev/null
run "insert into public.oic values (2147000000, 'first')" >/dev/null
run "call pgpm.transmute('public.oic', 'id', 10000, p_paused => false)" >/dev/null

check "LIVENESS: transmute built the grid to 2147310000" \
  "$(q "select max(hi::numeric) from pgpm.part where parent_table = 'public.oic'::regclass and attached")" \
  "2147310000"

run "insert into public.oic values (2147300000, 'frontier moves')" >/dev/null
check "LIVENESS: the lookahead from the frontier cell crosses 2^31-1" \
  "$(q "select 2147300000::numeric + ((select obtain from pgpm.config where parent_table = 'public.oic'::regclass) + 1) * 10000 > 2147483647")" \
  "t"

for tick in 1 2 3; do
  run "call pgpm.maintain_obtain_all()" >/dev/null

  if [ "$tick" = 1 ]; then
    check "tick 1 did the work: obtain logged the last expressible cell" \
      "$(q "select count(*) from pgpm.log where parent_table = 'public.oic'::regclass
             and action = 'obtain' and lo = '2147470000' and hi = '2147480000'")" \
      "1"
    check "tick 1: the grid tops out at 2147480000, the last int-expressible bound" \
      "$(q "select max(hi::numeric) from pgpm.part where parent_table = 'public.oic'::regclass and attached")" \
      "2147480000"
  fi

  check "tick $tick: no skip_obtain logged for the table" \
    "$(q "select count(*) from pgpm.log where parent_table = 'public.oic'::regclass and action = 'skip_obtain'")" \
    "0"
  check "tick $tick: no obtain back-off started" \
    "$(q "select obtain_retry_after is null from pgpm.config where parent_table = 'public.oic'::regclass")" \
    "t"

  if run "insert into public.oic values (2147400000 + $tick, 'tick $tick')" >"$LOG" 2>&1; then
    check "tick $tick: id 2147400000+$tick lands in the partition for [2147400000, 2147410000)" \
      "$(q "select coalesce((select tableoid from public.oic where id = 2147400000 + $tick)
                   = (select child_oid from pgpm.part where parent_table = 'public.oic'::regclass
                       and attached and lo = '2147400000'), false)")" \
      "t"
  else
    check "tick $tick: id 2147400000+$tick lands in the partition for [2147400000, 2147410000)" \
      "rejected: $(tail -1 "$LOG" | cut -c1-70)" "t"
  fi
done

exit "$fail"
