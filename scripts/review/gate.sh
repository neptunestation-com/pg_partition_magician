#!/usr/bin/env bash
# gate.sh <lockdir> [--container NAME] -- <command ...>
#
# Serialise the fixers' harness runs on one machine. `./test.sh 15` and its siblings use fixed container
# names (pgpm_test-15, pgpm_test-archive, ...), so two fixers running them at once fail each other at
# `docker compose up` with "container name already in use". The gate is an mkdir mutex around the
# command, plus the precondition the mutex alone does not give: the fixed-name container must be GONE
# before the holder starts. In pass 3 five fixers' first gated runs failed at startup anyway, because
# the previous holder's `compose down` was still tearing the container down, or because one worktree ran
# outside the gate. So after taking the lock this waits (up to 2 minutes, GATE_WAIT_TURNS x 15 s) for the
# container to disappear.
#
# Two things pass 4 taught (#713). A FAILING `./test.sh 15` never reaches its `compose down`, so its
# container stays and every later holder gave up on it (exit 7) until a person removed it: now, when the
# container is still there after the wait and the gate's own log says the previous holder of THAT
# container failed, the gate removes it (nobody inside the gate is running: this holder has the lock).
# A container the log cannot explain (an idle harness someone started outside the gate) is still not
# removed; the gate says so and exits 7. And the container is inferred from the command when --container
# is not given (`./test.sh timescale` uses pgpm_test-timescale, `./test.sh 16` pgpm_test-16, the perf and
# discriminate tracks pgpm_test-17), so a gated timescale run no longer waits on pgpm_test-15.
#
# Usage in a fixer brief:  scripts/review/gate.sh "$WORK/gate.lock" -- ./test.sh 15 --channel=psql
# The lock is released when the command exits, however it exits (trap on EXIT). Holder, container,
# duration and exit status go to <lockdir>.log.
set -uo pipefail
LOCK="${1:?lockdir}"; shift
CONTAINER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --container) CONTAINER=$2; shift 2;;
    --) shift; break;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "gate.sh: unknown option $1 (put the command after --)"; exit 2;;
  esac
done
[ $# -gt 0 ] || { echo "usage: gate.sh <lockdir> [--container NAME] -- <command ...>"; exit 2; }

infer_container() { # <command ...>: the fixed-name container a ./test.sh invocation brings up
  local prev="" a
  for a in "$@"; do
    case "$prev" in
      *test.sh)
        case "$a" in
          timescale) echo pgpm_test-timescale; return;;
          archive) echo pgpm_test-archive; return;;
          perf|discriminate) echo pgpm_test-17; return;;
          locktrace|lockview) echo pgpm_test-locktrace; return;;
          1[5-8]) echo "pgpm_test-$a"; return;;
        esac;;
    esac
    prev=$a
  done
  echo pgpm_test-15
}
[ -n "$CONTAINER" ] || CONTAINER=$(infer_container "$@")

LOG="$LOCK.log"
present() { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; }
start=$(date +%s)
while ! mkdir "$LOCK" 2>/dev/null; do sleep 15; done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
waited=$(( $(date +%s) - start ))
# the previous holder's teardown may still be running: wait for the fixed-name container to be gone
# (GATE_WAIT_TURNS turns of 15 s, 8 by default: two minutes)
for _ in $(seq 1 "${GATE_WAIT_TURNS:-8}"); do
  present || break
  sleep 15
done
if present; then
  # The log's last release line for this container says how its previous gated holder ended. A non-zero
  # exit left the container behind (a red test.sh skips its compose down), so it is this holder's to
  # remove; a zero exit, or no line at all, means something outside the gate holds it, which is a person's call.
  last_rc=$(grep -F "[$CONTAINER]" "$LOG" 2>/dev/null | grep -oE ' rc=[0-9]+' | tail -1 | tr -dc '0-9')
  if [ -n "$last_rc" ] && [ "$last_rc" != 0 ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    echo "gate: removed $CONTAINER, left behind by the previous holder (rc=$last_rc) ($(date -u +%H:%M:%SZ))" | tee -a "$LOG" >&2
  else
    echo "gate: $CONTAINER is still present after 2 min and the gate's log does not explain it (previous holder rc=${last_rc:-none}); another run holds it outside the gate: wait for it or \`docker rm -f $CONTAINER\`" | tee -a "$LOG" >&2
    exit 7
  fi
fi
echo "gate: acquired after ${waited}s ($(date -u +%H:%M:%SZ)); holder: $$ [$CONTAINER] $*" >> "$LOG"
"$@"; rc=$?
echo "gate: released ($(date -u +%H:%M:%SZ)) rc=$rc [$CONTAINER] after $(( $(date +%s) - start - waited ))s: $*" >> "$LOG"
exit "$rc"
