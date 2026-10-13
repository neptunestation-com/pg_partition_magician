#!/usr/bin/env bash
# bench/doc_log_actions.sh, run with no third argument, judges the tree by ONE line, and that line is
# labelled "LIVENESS: check 6 passes this tree". So a tree whose runbook alerts on an action nothing writes
# (the defect the guard exists for) fails only a LIVENESS-prefixed line, which bench/discriminate.sh's
# starved() (and scripts/review/classify_claims.py) read as a starved fixture, not as the guard's catch.
# The guard is run from $TREE, in a scratch root holding only the files it reads, with a phantom planted.
set -uo pipefail
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bench" "$W/scripts" "$W/docs" "$W/pgpm_core" "$W/pgpm_hypertable" "$W/pgpm_archive"
cp "$TREE/bench/doc_log_actions.sh" "$W/bench/"
cp "$TREE/scripts/check_living_docs.sh" "$W/scripts/"
for d in guide reference runbook; do cp "$TREE/docs/$d.md" "$W/docs/"; done
cp "$TREE/pgpm_core/install.sql" "$TREE/pgpm_core/extension.control" "$W/pgpm_core/"
cp "$TREE/pgpm_hypertable/install.sql" "$W/pgpm_hypertable/"
cp "$TREE/pgpm_archive/install.sql" "$W/pgpm_archive/"
PH=fail_retain_phantom_f7_02
python3 - "$W/docs/runbook.md" "$PH" <<'PY'
import re, sys
p, ph = sys.argv[1], sys.argv[2]
t = open(p).read()
m = re.search(r"\baction\s+in\s*\(", t)
if not m: sys.exit(1)
open(p, "w").write(t[:m.end()] + "'" + ph + "', " + t[m.end():])
PY
planted=$?
if [ "$planted" = 0 ] && grep -qF "'$PH'" "$W/docs/runbook.md"; then echo "ok - LIVENESS: the phantom action is planted in the runbook's action in (...) list"
else echo "not ok - LIVENESS: the phantom action is planted in the runbook's action in (...) list"; exit 1; fi
c6=$(bash "$W/scripts/check_living_docs.sh" 2>&1 | sed -n '/^== check 6/,$p')
if grep -qE "^FAIL .*'$PH'" <<<"$c6"; then echo "ok - LIVENESS: check 6 itself fails on the planted runbook, naming the phantom"
else echo "not ok - LIVENESS: check 6 itself fails on the planted runbook, naming the phantom"; exit 1; fi
bash "$W/bench/doc_log_actions.sh" c db > "$W/guard.log" 2>&1 </dev/null; rc=$?
sed 's/^/# guard: /' "$W/guard.log"
if [ "$rc" != 0 ]; then echo "ok - LIVENESS: the guard (no third argument) exits non-zero on the planted tree"
else echo "not ok - LIVENESS: the guard (no third argument) exits non-zero on the planted tree"; exit 1; fi
starved_fn=$(sed -n '/^starved() {/,/^}/p' "$TREE/bench/discriminate.sh")
if [ -n "$starved_fn" ]; then echo "ok - GUARD: starved() read out of bench/discriminate.sh"; else echo "not ok - GUARD: starved() read out of bench/discriminate.sh"; exit 1; fi
eval "$starved_fn"
if starved "$W/guard.log"; then
  echo "not ok - the guard's failure on a phantom alert action is read as a catch, not as a starved fixture"
  grep '^FAIL' "$W/guard.log" | sed 's/^/#   its only failure: /'
  exit 1
fi
echo "ok - the guard's failure on a phantom alert action is read as a catch, not as a starved fixture"
