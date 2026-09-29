#!/usr/bin/env bash
# gate.sh <lockdir> [--container NAME] -- <command ...>
#
# Serialise the fixers' harness runs on one machine. `./test.sh 15` and its siblings use fixed container
# names (pgpm_test-15, pgpm_test-archive, ...), so two fixers running them at once fail each other at
# `docker compose up` with "container name already in use". The gate is an mkdir mutex around the
# command, plus the precondition the mutex alone does not give: the fixed-name container must be GONE
# before the holder starts. In pass 3 five fixers' first gated runs failed at startup anyway, because
# the previous holder's `compose down` was still tearing the container down, or because one worktree ran
# outside the gate. So after taking the lock this waits (up to 5 minutes) for the container to disappear,
# and prints who held the lock and for how long to <lockdir>.log.
#
# Usage in a fixer brief:  scripts/review/gate.sh "$WORK/gate.lock" -- ./test.sh 15 --channel=psql
# The lock is released when the command exits, however it exits (trap on EXIT).
set -uo pipefail
LOCK="${1:?lockdir}"; shift
CONTAINER="pgpm_test-15"
while [ $# -gt 0 ]; do
  case "$1" in
    --container) CONTAINER=$2; shift 2;;
    --) shift; break;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "gate.sh: unknown option $1 (put the command after --)"; exit 2;;
  esac
done
[ $# -gt 0 ] || { echo "usage: gate.sh <lockdir> [--container NAME] -- <command ...>"; exit 2; }
LOG="$LOCK.log"
start=$(date +%s)
while ! mkdir "$LOCK" 2>/dev/null; do sleep 15; done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
waited=$(( $(date +%s) - start ))
# the previous holder's teardown may still be running: wait for the fixed-name container to be gone
for _ in $(seq 1 20); do
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" || break
  sleep 15
done
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  echo "gate: $CONTAINER is still present after 5 min; another run is holding it outside the gate" | tee -a "$LOG" >&2
  exit 7
fi
echo "gate: acquired after ${waited}s ($(date -u +%H:%M:%SZ)); holder: $$ $*" >> "$LOG"
"$@"; rc=$?
echo "gate: released ($(date -u +%H:%M:%SZ)) rc=$rc after $(( $(date +%s) - start - waited ))s: $*" >> "$LOG"
exit "$rc"
