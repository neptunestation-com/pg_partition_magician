#!/usr/bin/env bash
# tests/formal/summarize.py's liveness rule, against an ARBITRARY copy of summarize.py (formal methods Phase 3 W5,
# docs/formal/phase3-design.md "Guards on the oracle"), so bench/discriminate.sh can require it to FAIL against
# summarize_zero_judged_passes: the rule that fails a track whose required invariant judged zero identities, taken out.
# Runs the copy's --selftest on the host; the container and database discriminate.sh hands every guard go unused.
# run_perf runs it against the real summarize.py, the clean-code half of the pair.
# Usage: formal_summarize_selftest.sh <container> <db> [tests/formal/summarize.py, a /repo path or a host path]
set -uo pipefail
: "${1:?container}" "${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${3:-/repo/tests/formal/summarize.py}"
case "$SRC" in /repo/*) SRC="$ROOT/${SRC#/repo/}" ;; esac
if python3 "$SRC" --selftest; then exit 0; fi
echo "FAIL  summarize.py --selftest (its not ok lines above)"
exit 1
