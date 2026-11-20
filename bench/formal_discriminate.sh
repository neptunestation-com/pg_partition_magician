#!/usr/bin/env bash
# The invariant oracle as a guard (formal methods Phase 3 W5, docs/formal/phase3-design.md "Guards on the oracle"):
# run custody pgTAP files over an install of pgpm, then ask pgpm_formal.check() whether ONE invariant held, and
# turn its report into a verdict that bench/discriminate.sh can require to FAIL against a mutant.
#
#   bench/formal_discriminate.sh <container> <db> <core install.sql> <invariant> <file> [<file> ...]
#   bench/formal_discriminate.sh --archive <net> <container> <db> <archive install.sql> <invariant> <file> ...
#
# <core install.sql> (or, with --archive, the pgpm_archive install.sql over the real core) is a path inside the
# container, which mounts this repository at /repo: /repo/pgpm_core/install.sql for the clean-code run, the mutant
# discriminate.sh built otherwise. Each file runs in its own clone of a template holding pgtap, that install, the demo
# fixtures (the archive track's fixtures with --archive) and tests/formal/oracle.sql, as tests/formal/run_custody.sh
# runs it; then tests/formal/report.sql runs in the file's database, as test.sh's oracle_report runs it. With
# --archive the retired chunks' objects are read from MinIO on <net> and loaded into the report (tests/formal/
# load_store.py, needing .venv-verify's pyarrow), so ArchiveNoClobber judges what the bucket holds.
#
# THE VERDICT IS THE ORACLE'S, NEVER THE FILE'S. Under a mutant the file's own assertions may fail too, and that is
# not what this guard is for: a file whose assertions fail is reported on an `info` line, and its `not ok` lines stay
# in the file's .tap under bench/results/formal, out of this guard's output, so neither discriminate.sh's starved()
# rule nor a reader takes them for this guard's checks. What fails:
#   FAIL  <invariant> violated in <file>: <identity>     check() names it and no expect() in the file declared it
#   FAIL  LIVENESS: <invariant> judged no identity ...   the oracle looked at nothing of the invariant in that file
#   FAIL  LIVENESS: the oracle raised in <file> ...      check() raised, or the report's session failed
# The LIVENESS lines are premises (discriminate.sh reads a run that failed only those as a starved fixture): a
# check() that judged zero identities reports nothing for the same reason a probe that saw nothing does, so it is
# never a pass. Exit status 1 when any FAIL line was printed.
set -uo pipefail

ARCHIVE=""
NET=""
if [ "${1:-}" = --archive ]; then ARCHIVE=1; NET="${2:?--archive <net>}"; shift 2; fi
C="${1:?usage: formal_discriminate.sh [--archive <net>] <container> <db> <install.sql> <invariant> <file>...}"
DB="${2:?db}"
INSTALL="${3:?install.sql (a path in the container)}"
INV="${4:?invariant}"
shift 4
[ "$#" -gt 0 ] || { echo "FAIL  GUARD: no custody file named"; exit 1; }
case "$INV" in
  NoLostRow|NoDuplicateRow|DropOnlyCovered|ArchiveNoClobber|ResolveByRecord|NoWedge) ;;
  *) echo "FAIL  GUARD: unknown invariant $INV"; exit 1 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results/formal/$DB"      # gitignored
rm -rf "$OUT"; mkdir -p "$OUT"
FILE_TIMEOUT="${FORMAL_FILE_TIMEOUT:-900}"   # a mutant can hang a file (W4: tests/345); it is cancelled, then judged

q() { docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$C" psql -U postgres -d "${QDB:-postgres}" -v ON_ERROR_STOP=1 -qtA "$@"; }

tmpl="${DB}_tmpl"
q -c "drop database if exists $tmpl" >/dev/null
q -c "create database $tmpl" >/dev/null
if [ -n "$ARCHIVE" ]; then
  QDB="$tmpl" q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null &&
  QDB="$tmpl" q -f /repo/tests/archive/fixtures.sql >/dev/null &&
  QDB="$tmpl" q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null &&
  QDB="$tmpl" q -f "$INSTALL" >/dev/null &&
  QDB="$tmpl" q -f /repo/tests/formal/oracle.sql >/dev/null
else
  QDB="$tmpl" q -c "create extension if not exists pgtap" >/dev/null &&
  QDB="$tmpl" q --single-transaction -f "$INSTALL" >/dev/null &&
  QDB="$tmpl" q -c "alter database \"$tmpl\" set poc.seed_count = 8000; alter database \"$tmpl\" set poc.events_count = 4000;" >/dev/null &&
  QDB="$tmpl" q -f /repo/fixtures/demo.sql >/dev/null &&
  QDB="$tmpl" q -f /repo/tests/formal/oracle.sql >/dev/null
fi
# shellcheck disable=SC2181   # the chain above is one step
if [ "$?" != 0 ]; then
  echo "FAIL  GUARD: the template ($INSTALL, the fixtures and the oracle) did not build"
  q -c "drop database if exists $tmpl" >/dev/null 2>&1
  exit 1
fi

fails=0
n=0
for f in "$@"; do
  n=$((n + 1)); b=$(basename "$f" .sql); fdb="${DB}_$n"
  q -c "drop database if exists $fdb" >/dev/null
  q -c "create database $fdb template $tmpl" >/dev/null
  if timeout "$FILE_TIMEOUT" docker exec "$C" pg_prove -v -U postgres -d "$fdb" "/repo/$f" >"$OUT/$b.tap" 2>&1; then
    own="PASS"
  else
    own="FAIL ($(grep -cE '^[[:space:]]*not ok' "$OUT/$b.tap" || true) not ok; exit status or plan in $OUT/$b.tap)"
  fi
  # cancel whatever a timed-out file left running in its database, so the report is not queued behind it
  q -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$fdb' and pid <> pg_backend_pid()" >/dev/null 2>&1
  rep="$OUT/$b.oracle"
  stage=/dev/null
  if [ -n "$ARCHIVE" ]; then
    stage="$OUT/$b.stage"
    if ! QDB="$fdb" q -F "$(printf '\t')" -f /repo/tests/formal/store_keys.sql 2>"$OUT/$b.keys.err" \
         | "$ROOT/.venv-verify/bin/python" "$ROOT/tests/formal/load_store.py" "$NET" curlimages/curl >"$stage" 2>>"$OUT/$b.keys.err"; then
      : >"$stage"
      printf 'E\t%s\tthe bucket was not read: %s\n' "$f" "$(tr '\t\n' '  ' <"$OUT/$b.keys.err" | cut -c1-400)" >"$rep.keys"
    fi
  fi
  rc=0
  QDB="$fdb" q -F "$(printf '\t')" -v file="$f" -v scope= -v load_store="${ARCHIVE:-0}" \
    -f /repo/tests/formal/report.sql <"$stage" >"$rep" 2>"$rep.err" || rc=$?
  [ -f "$rep.keys" ] && cat "$rep.keys" >>"$rep"
  if [ "$rc" != 0 ]; then printf 'E\t%s\tthe report session exited %s: %s\n' "$f" "$rc" "$(tr '\t\n' '  ' <"$rep.err" | cut -c1-400)" >>"$rep"; fi
  q -c "drop database if exists $fdb" >/dev/null 2>&1

  echo "info  $f: its own assertions $own (not this guard's verdict)"
  if grep -q '^E' "$rep"; then
    printf 'FAIL  LIVENESS: the oracle raised in %s: %s\n' "$f" "$(grep -m1 '^E' "$rep" | cut -f3- | cut -c1-300)"
    fails=$((fails + 1)); continue
  fi
  ids=$(awk -F'\t' -v inv="$INV" '$1 == "J" && $3 == inv { print ($4 == "t" ? $6 : 0) }' "$rep")
  if [ -z "$ids" ] || [ "$ids" = 0 ]; then
    printf 'FAIL  LIVENESS: %s judged no identity in %s (%s), so its silence there says nothing\n' "$INV" "$f" \
      "$(awk -F'\t' -v inv="$INV" '$1 == "J" && $3 == inv { print ($8 == "" ? "no note" : $8) }' "$rep")"
    fails=$((fails + 1)); continue
  fi
  nv=$(awk -F'\t' -v inv="$INV" '$1 == "V" && $3 == inv' "$rep" | wc -l)
  if [ "$nv" -gt 0 ]; then
    awk -F'\t' -v inv="$INV" -v f="$f" '$1 == "V" && $3 == inv && k++ < 5 {
      printf "FAIL  %s violated in %s: %s  (%s; %s)\n", inv, f, $5, $4, substr($6, 1, 300) }' "$rep"
    [ "$nv" -gt 5 ] && echo "      ... $((nv - 5)) more $INV violation(s) in $rep"
    fails=$((fails + 1))
  else
    printf 'ok    %s held in %s over %s identities\n' "$INV" "$f" "$ids"
  fi
done
q -c "drop database if exists $tmpl" >/dev/null 2>&1
if [ "$fails" -gt 0 ]; then
  echo "formal_discriminate: FAIL ($INV: $fails of $n file(s); reports in $OUT)"
  exit 1
fi
echo "formal_discriminate: PASS ($INV held over $n file(s), each judging at least one identity)"
