#!/usr/bin/env bash
# F12r-04: decisions_queue.parse() skips every line that does not start with the three characters "- D", so a
# BLOCKING entry written by hand as Markdown renders it the same (indented "  - D04 | ...", a "* D04" bullet,
# or a lower-case "- d04" id) is neither refused (exit 2) nor read: `pending` exits 0 and stop_check.py, which
# reads the queue through parse(), finds no blocking decision and lets the loop continue. The docstring says a
# BLOCKING entry is "written `BLOCKING` so a grep and stop_check.py find it" and README.md that "the scripts
# refuse a line that does not have this shape"; the selftest's own hand-edit case is "lenient toward stopping".
# Env: TREE.
set -uo pipefail
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
DQ="$TREE/scripts/review/decisions_queue.py"
fail=0
python3 "$DQ" "$W/base.md" init >/dev/null
python3 "$DQ" "$W/base.md" add --kind default --text "refuse over warn" --loop 12 >/dev/null
# liveness: a well-formed hand-written BLOCKING line in the same file blocks
cp "$W/base.md" "$W/ok.md"; echo "- D02 | 2026-10-12 | BLOCKING | cut release v0.7.0 | issue - | PR - | open" >> "$W/ok.md"
python3 "$DQ" "$W/ok.md" pending >/dev/null; rc=$?
[ "$rc" = 1 ] && echo "ok - LIVENESS: a hand-written BLOCKING entry of the exact shape makes pending exit 1" \
             || { echo "not ok - LIVENESS: the exact-shape entry did not block (rc=$rc)"; fail=1; }
n=0
for line in "  - D02 | 2026-10-12 | BLOCKING | cut release v0.7.0 | issue - | PR - | open" \
            "* D02 | 2026-10-12 | BLOCKING | cut release v0.7.0 | issue - | PR - | open" \
            "- d02 | 2026-10-12 | BLOCKING | cut release v0.7.0 | issue - | PR - | open"; do
  n=$((n + 1)); f="$W/v$n.md"; cp "$W/base.md" "$f"; echo "$line" >> "$f"
  grep -q "BLOCKING" "$f" && echo "ok - LIVENESS: variant $n holds an open BLOCKING entry a grep finds: '${line:0:24}...'" \
                         || { echo "not ok - LIVENESS: variant $n has no BLOCKING text"; fail=1; }
  python3 "$DQ" "$f" pending >/dev/null 2>&1; rc=$?
  if [ "$rc" = 1 ] || [ "$rc" = 2 ]; then echo "ok - variant $n: pending blocks or refuses the file (rc=$rc)"
  else echo "not ok - variant $n: pending exits $rc, reading no pending BLOCKING decision and refusing nothing"; fail=1; fi
  v=$(python3 - "$TREE" "$f" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "review"))
import decisions_queue
try:
    print(len(decisions_queue.pending_blocking(decisions_queue.parse(decisions_queue.load(sys.argv[2])))))
except decisions_queue.QueueError:
    print("refused")
PY
)
  if [ "$v" = "1" ] || [ "$v" = "refused" ]; then echo "ok - variant $n: the parse stop_check.py uses sees it ($v)"
  else echo "not ok - variant $n: the parse stop_check.py uses sees $v pending BLOCKING entries"; fail=1; fi
done
exit $fail
