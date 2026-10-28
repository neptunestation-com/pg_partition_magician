#!/usr/bin/env bash
# Prove that the overlap witness each lock guard's probe records ("LIVENESS: the probe overlapped a running
# tick", "... a running swap", "... a running retirement", "... caught the validation scan in progress") can
# FAIL: it reads false when the work it waits for never ran, and true when it did.
#
# WHY THIS GUARD EXISTS (issue #1379, F7-01 and F8-04). Each probe is a server-side DO block that polls
# (pg_stat_activity, or pg_locks) for the step under test and only then starts its reads or writes. Two of
# them recorded the witness AFTER the poll loop, unconditionally:
#
#     for i in 1 .. 2000000 loop exit when exists(...); commit; end loop;
#     saw := true;
#
# so the witness read true whether the loop exited because it saw the work or because it ran out of turns
# having seen nothing, and the LIVENESS line that exists to refuse a run where the probe never overlapped
# the step could not fail. That is the vacuous shape bench/restore_fk_lock.sh retired under #416; its
# siblings bench/maintain_lock.sh and bench/regrain_outgoing_fk_lock.sh kept it. The witness is now set
# where the poll finds the work (`saw := true; exit;`), as bench/retire_detach_lock.sh and
# bench/transmute_lock.sh already did.
#
# HOW. For each listed guard, its OWN probe block is read out of its source (from `do \$p\$` to
# `end \$p\$;`, the shell's escapes undone, a `$((...))` expansion read as 0, the poll's bound lowered from
# 2,000,000 to 50 so a probe that sees nothing gives up in moments) and run twice in a fresh database whose
# public.done already holds its row, so the read or write loop after the poll ends at once:
#   quiet    nothing runs the step: the witness must read false. This is the contract.
#   busy     a marker session does what the poll looks for (a query naming the step, or a SHARE UPDATE
#            EXCLUSIVE lock on a relation named tl) while the block runs: the witness must read true. This
#            is the instrument's liveness: a block that never records true would pass `quiet` vacuously.
# The probe table is created from the guard's own `create table public.probe (...)`.
#
# The inventory is checked too: every bench/*.sh whose `do \$p\$` block records a row in public.probe is
# listed here, so a new probe of this shape cannot be added unjudged.
#
# WHAT IT ASSERTS, per listed guard.
#   LIVENESS  the block was read out of the guard and its bound lowered; with the step running, the
#             witness reads true.
#   CONTRACT  with nothing running, the block ran to its end and its witness reads false.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   probe_witness_unconditional_maintain -- bench/maintain_lock.sh's probe sets saw := true after its
#                                           poll again, the pre-#1379 shape
#   probe_witness_unconditional_rofk     -- bench/regrain_outgoing_fk_lock.sh's, the same
#
# Usage: probe_overlap_witness.sh <container> <db> [guard script]
# With no third argument it judges this checkout. With one it judges THAT file in place of the guard it
# stands for, recognised by its file name or, for a mutant bench/discriminate.sh built (<mutation>.sql), by
# the mutation's MUTATION_SRC; a /repo/... path is mapped to this checkout.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ONLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="pgpm_probe_overlap_marker"
fail=0
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-78s %s\n' "$1" "$2"
  else printf 'FAIL  %-78s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
q() { docker exec -i "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 "$@" 2>&1; }

# <guard>|<the marker session's statements, `;;` between them>|<the witness, read from public.probe>
PROBES='
maintain_lock|select pg_sleep(60), $$maintain_all$$|select saw_tick::text from public.probe
regrain_outgoing_fk_lock|select pg_sleep(60), $$regrain_step$$|select saw::text from public.probe
retire_detach_lock|select pg_sleep(60), $$pgpm.retire$$|select saw::text from public.probe
transmute_lock|begin;;lock table public.tl in share update exclusive mode;;select pg_sleep(60)|select caught::text from public.probe
'

# ---- which file stands in for which ------------------------------------------------------------------
ONLY_NAME=""
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then check "GUARD: the file to judge exists" "no" "yes"; exit 1; fi
  base=$(basename "$ONLY")
  src=$(python3 - "$ROOT/bench/mutations" "${base%.*}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import mutate
print(mutate.MUTATION_SRC.get(sys.argv[2], ""))
PY
)
  while IFS='|' read -r g _ _; do
    [ -z "$g" ] && continue
    if [ "$base" = "$g.sh" ] || [ "$src" = "bench/$g.sh" ]; then ONLY_NAME="$g"; fi
  done <<<"$PROBES"
  if [ -z "$ONLY_NAME" ]; then check "GUARD: the file to judge stands for a listed probe guard" "$ONLY -> '$src'" "listed"; exit 1; fi
fi
script_of() { if [ "$1" = "$ONLY_NAME" ]; then echo "$ONLY"; else echo "$ROOT/bench/$1.sh"; fi; }

# ---- the inventory: every probe of this shape is listed ----------------------------------------------
unlisted=""
for f in "$ROOT"/bench/*.sh; do
  n=$(basename "$f" .sh)
  grep -qE '^do \\\$p\\\$$' "$f" && grep -q 'insert into public\.probe' "$f" || continue
  grep -q "^$n|" <<<"$PROBES" || unlisted+="$n "
done
check "GUARD: every bench probe recording into public.probe is listed here" "${unlisted:-none}" "none"

# block <script>: the probe's DO block as psql would receive it, its poll bound lowered to 50.
block() {
  awk '/^do \\\$p\\\$$/ {on = 1} on {print} on && /^end \\\$p\\\$;/ {exit}' "$1" \
    | sed -e 's/\\\$/$/g' -e 's/^\(end \$p\$;\).*$/\1/' -e 's/\$((\([^)]*\)))/0/g' \
          -e 's/for i in 1 \.\. 2000000 loop/for i in 1 .. 50 loop/'
}
# marker_wait <state>: wait until the marker session is (running) or is gone (gone); 20 s at most.
marker_wait() {
  local want="$1" n
  for _ in $(seq 1 100); do
    n=$(docker exec "$C" psql -U postgres -d "$DB" -qtA -c "select count(*) from pg_stat_activity
          where application_name = '$APP' and state = 'active'" 2>/dev/null)
    if [ "$want" = running ] && [ "$n" = 1 ]; then return 0; fi
    if [ "$want" = gone ] && [ "$n" = 0 ]; then return 0; fi
    sleep 0.2
  done
  return 1
}

# The list is read on fd 3: `docker exec -i` forwards stdin, and would swallow the rest of it.
while IFS='|' read -r g marker witness <&3; do
  [ -z "$g" ] && continue
  s=$(script_of "$g")
  b=$(block "$s")
  ddl=$(grep -oE 'create table (if not exists )?public\.probe \([^)]*\)' "$s" | head -1)
  if [ -z "$b" ] || ! grep -q 'for i in 1 \.\. 50 loop' <<<"$b" || ! grep -q '^end \$p\$;$' <<<"$b" \
     || ! grep -q 'insert into public\.probe' <<<"$b" || [ -z "$ddl" ]; then
    check "LIVENESS: $g: its probe block and probe table were read, the poll bound lowered" "no" "yes"
    continue
  fi
  check "LIVENESS: $g: its probe block and probe table were read, the poll bound lowered" "yes" "yes"

  for run in quiet busy; do
    docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
    docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
    q -c "$ddl; create table public.done (x int); insert into public.done values (1);
          create table public.tl (id int)" >/dev/null
    BG=""
    if [ "$run" = busy ]; then
      args=()
      while IFS= read -r stmt; do [ -n "$stmt" ] && args+=(-c "$stmt"); done < <(sed 's/;;/\n/g' <<<"$marker")
      docker exec -e PGAPPNAME="$APP" "$C" psql -U postgres -d "$DB" -qtA "${args[@]}" </dev/null >/dev/null 2>&1 &
      BG=$!
      if ! marker_wait running; then
        check "LIVENESS: $g: the marker session is running the step" "no" "yes"
        kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; continue
      fi
    fi
    out=$(printf '%s\n' "$b" | q -f -); rc=$?
    got=$(q -c "$witness")
    if [ -n "$BG" ]; then
      docker exec "$C" psql -U postgres -d "$DB" -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity
             where application_name = '$APP'" >/dev/null 2>&1
      wait "$BG" 2>/dev/null
      marker_wait gone || true
    fi
    if [ "$rc" != 0 ]; then
      check "LIVENESS: $g: the probe block ran to its end ($run)" "rc $rc: ${out:0:80}" "rc 0"; continue
    fi
    if [ "$run" = busy ]; then
      check "LIVENESS: $g: with the step running, the probe's overlap witness reads true" "$got" "true"
    else
      check "$g: with nothing running, the probe's overlap witness reads false" "$got" "false"
    fi
  done
done 3<<<"$PROBES"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
