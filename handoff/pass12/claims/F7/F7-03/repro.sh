#!/usr/bin/env bash
# bench/lock_trace.sh (discriminate track locktrace) checks "the probe attached and is delivering events"
# and exits 1 right after it when the probe never became READY. That check is a premise (no probe, no
# observation), but it carries no LIVENESS:/GUARD:/fixture: prefix, so a run whose probe never attached
# (a starved fixture: nothing was traced) is read by bench/discriminate.sh's starved() as a CATCH of the
# mutant. The label and the guard's own check() are read from $TREE and rendered the way the guard prints.
set -uo pipefail
G="$TREE/bench/lock_trace.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
label=$(grep -oE 'check "the probe attached[^"]*"' "$G" | head -1 | sed -E 's/^check "(.*)"$/\1/')
if [ -n "$label" ]; then echo "ok - LIVENESS: lock_trace.sh carries the probe-attach check: $label"
else echo "not ok - LIVENESS: lock_trace.sh carries the probe-attach check"; exit 1; fi
n=$(grep -n 'check "the probe attached' "$G" | head -1 | cut -d: -f1)
if sed -n "$n,$((n + 6))p" "$G" | grep -q 'exit 1'; then
  echo "ok - LIVENESS: a failed probe-attach check ends the guard at once (its only FAIL line)"
else echo "not ok - LIVENESS: a failed probe-attach check ends the guard at once"; exit 1; fi
check_fn=$(sed -n '/^check() {/,/^}/p' "$G")
starved_fn=$(sed -n '/^starved() {/,/^}/p' "$TREE/bench/discriminate.sh")
if [ -n "$check_fn" ] && [ -n "$starved_fn" ]; then echo "ok - GUARD: check() and starved() read from the tree"
else echo "not ok - GUARD: check() and starved() read from the tree"; exit 1; fi
eval "$check_fn"; eval "$starved_fn"
fail=0; check "$label" "false" "true" > "$W/run.log"
printf 'FAIL  LIVENESS: a planted witness   got false, want true\n' > "$W/ctl.log"
if starved "$W/ctl.log"; then echo "ok - LIVENESS: starved() refuses a run that failed only a prefixed premise"
else echo "not ok - LIVENESS: starved() refuses a run that failed only a prefixed premise"; exit 1; fi
sed 's/^/# rendered: /' "$W/run.log"
if starved "$W/run.log"; then
  echo "ok - a run whose probe never attached is refused as a starved fixture"
else
  echo "not ok - a run whose probe never attached is certified as a catch of the mutant"; exit 1
fi
