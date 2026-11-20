#!/usr/bin/env bash
# The formal track: TLC over the custody spec (formal/README.md). The default configs must check clean, the
# as-shipped configs must keep their claims violated, and every retrodiction mutation must keep its recorded
# outcome (formal/mutations/mutate.py).
#
# Usage: formal/run.sh [--part=core|--part=live|--part=all]   (./test.sh formal [--part=...] calls this)
#
# Its own script, not a function in test.sh (#1444): .github/workflows/formal.yml takes two to four hours, and
# while the track's body lived in test.sh its path filter had to watch test.sh, so every ordinary harness edit
# started it. Now the workflow runs this file and watches formal/ alone.
set -euo pipefail
cd "$(dirname "$0")/.."
FORMAL_PART=all
for arg in "$@"; do
  case "$arg" in
    --part=core|--part=live|--part=all) FORMAL_PART="${arg#--part=}" ;;
    *) echo "usage: formal/run.sh [--part=core|live|all]" >&2; exit 2 ;;
  esac
done
f=formal/specs
clean="Custody CustodyFK CustodyLive"
out=$(mktemp -d "${TMPDIR:-/tmp}/pgpm_formal.XXXXXX")
case "$FORMAL_PART" in core) clean="Custody CustodyFK" ;; live) clean="CustodyLive" ;; esac
if [ "$FORMAL_PART" != live ]; then
  echo ">>> formal: the harness's own checks discriminate"
  python3 formal/mutations/mutate.py selftest
  echo ">>> formal: liveness witnesses (archive, drop, dispatch, overtaken read, custody all reachable)"
  python3 formal/mutations/mutate.py witness
fi
for c in $clean; do
  echo ">>> formal: $c.cfg must check clean"
  # A liveness config expected to pass checks its property once, at the end (#1444): the default checks it
  # periodically over the whole graph so far, about a fifth of CustodyLive's time, for an answer that only
  # matters when a violation exists. The verdict and state count are the same.
  extra=(); [ "$c" = CustodyLive ] && extra=(-lncheck final)
  formal/tlc.sh "$f" Custody.tla "$c.cfg" "${extra[@]}" > "$out/$c.out" 2>&1 || true
  if ! grep -q 'No error has been found' "$out/$c.out"; then
    tail -60 "$out/$c.out"; echo "FAIL: formal/specs/$c.cfg did not check clean"; exit 1
  fi
  grep -E 'Finished in' "$out/$c.out" | tail -1
  python3 formal/mutations/mutate.py scope "$c.cfg" "$out/$c.out"
done
if [ "$FORMAL_PART" = live ]; then rm -rf "$out"; echo; echo "All requested tests passed."; exit 0; fi
# config:invariant for every claim still on record (C1 closed by #1452)
asis="Custody-asisC2:DropOnlyCovered CustodyFK-asisC3:NoLostRow CustodyFK-asisC4:ResolveByRecord"
for c in $asis; do
  want=${c#*:}; c=${c%%:*}
  echo ">>> formal: $c.cfg must keep its claim's violation of $want"
  formal/tlc.sh "$f" Custody.tla "$c.cfg" > "$out/$c.out" 2>&1 || true
  if ! grep -q "Invariant $want is violated" "$out/$c.out"; then
    tail -60 "$out/$c.out"; echo "FAIL: formal/specs/$c.cfg no longer reports its claim ($want)"; exit 1
  fi
done
echo ">>> formal: retrodiction (every mutation's recorded outcome)"
python3 formal/mutations/mutate.py check
rm -rf "$out"
echo; echo "All requested tests passed."
