#!/usr/bin/env bash
# Prove every perf guard actually catches the defect it exists for. Run by CI (`./test.sh discriminate`).
#
# WHY THIS EXISTS. A green guard is not evidence. It is green when the defect is absent, and equally
# green when the guard never observed anything at all -- and this repo has shipped the second kind six
# times: scan counters that read 0 because they were sampled inside the transaction that produced them;
# a lock probe that sampled after the window closed and saw no locks, so "no ACCESS EXCLUSIVE held"
# passed on broken code; a probe that held a lock of its own and starved the tick it was measuring, so
# nothing took a strong lock and the reader assertion passed against a tick that did nothing; a log
# match on `drain%` that also matched `drain_skip`, which is exactly what a starved tick writes.
#
# Each of those was caught by hand, once, by running the guard against pre-fix code. That evidence lived
# in a commit message and decayed immediately. This makes it a standing check: for every mutation in
# bench/mutations/, build a copy of install.sql with the defect back in, run the guard against it, and
# require the guard to FAIL. A guard that stays green on its own mutant is not testing anything.
#
# Usage: discriminate.sh [--track=NAME] <container> [<archive container>]
# The second container is only needed for mutations scoped to pgpm_archive/install.sql or to a file under
# tests/archive/ (which require the archive track's own image -- pgsql-http isn't in the plain core image); a mutation
# whose src needs it, with no such container supplied, is a FAILURE of this check, not a skip --
# same principle as a stale pattern: a guard this script never actually ran is unverified.
#
# --track selects which mutations to run, defaulting to `perf` -- the ones every machine can run.
# `--track=locktrace` runs the eBPF trace guard's mutation instead, against the privileged container
# passed as <container> (see bench/mutations/mutate.py's MUTATION_TRACK for why that track is
# separate rather than simply skipped when eBPF is unavailable). The tracks are disjoint, so every
# mutation is run by exactly one of them and none is silently left out.
#
# A MUTANT THAT DOES NOT INSTALL VERIFIES NOTHING (#601). A guard run against a mutant install.sql that
# will not even load fails for a reason that has nothing to do with what it asserts, and this script used
# to count that failure as discrimination: a mutation whose patched text stopped compiling certified its
# guard while the guard never reached an assertion. So every mutant of an install.sql is installed here
# first, the way its module is installed (prerequisites first) in a fresh scratch database, and one that
# does not install FAILS this check with the error, whatever its guard then does (the guard still runs, so
# its log shows how far it got). The unmutated source is installed the same way once per run, so an environment that cannot install anything reads as that
# and not as a broken mutation. Mutants of other files (a test file, a script) have no install step;
# their guards carry their own controls. bench/discriminate_installs.sh proves this check refuses.
#
# A GUARD THAT FAILED ONLY ITS LIVENESS WITNESSES VERIFIES NOTHING EITHER (#713). A LIVENESS witness says
# the fixture reached the state the defect needs; when the only checks a guard fails against its mutant are
# witnesses like that, the mutant starved the fixture and the guard never got to assert anything about the
# defect. That is the rule the guards print themselves ("a failure is only evidence against the code when
# the setup it depends on held") and the one scripts/review/classify_claims.py applies to a reproduction,
# so it is applied here with the classifier's prefixes: a run whose every failure is `LIVENESS:`, `GUARD:`
# or `fixture:` FAILS this check as a starved fixture, while one witness failing beside a failed defect
# check still counts. See starved() for how failures are read; bench/discriminate_installs.sh proves it.
#
# DISCRIMINATE_DB_PREFIX (default pgpm_mut) names the scratch databases, <prefix><n> and
# <prefix><n>_install; bench/discriminate_installs.sh sets it so its nested runs share nothing with this one.
set -uo pipefail
TRACK="perf"
SHARD_I=1
SHARD_N=1
LIST_ONLY=""
while :; do
  case "${1:-}" in
    --track=*) TRACK="${1#--track=}"; shift ;;
    # --shard=I/N: run the I-th of N interleaved slices of the mutation list (1-based), so CI can spread
    # the list over N runners. mutate.py prints the list heaviest first (its MUTATION_COST), so the
    # interleave spreads the long probes over the shards rather than leaving them where the catalogue
    # put them. The mutation's index in the FULL list still names its database, so shards never
    # collide, and a shard that selects nothing FAILS (the i=0 rule below, per shard).
    --shard=*) SHARD_I="${1#--shard=}"; SHARD_N="${SHARD_I#*/}"; SHARD_I="${SHARD_I%/*}"; shift ;;
    --list) LIST_ONLY=1; shift ;;
    *) break ;;
  esac
done
if ! [[ "$SHARD_I" =~ ^[0-9]+$ && "$SHARD_N" =~ ^[0-9]+$ ]] || [ "$SHARD_I" -lt 1 ] || [ "$SHARD_I" -gt "$SHARD_N" ]; then
  echo "discriminate: --shard=I/N needs 1 <= I <= N"; exit 2
fi
C="${1:?container}"
CA="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results/mutants"       # gitignored
mkdir -p "$OUT"
fail=0
i=0
DBP="${DISCRIMINATE_DB_PREFIX:-pgpm_mut}"
baseline_ok=" "      # the install.sql sources whose UNMUTATED copy installed in this run, space-delimited

# installs <container> <src> <file> <db> <log>: install <file> into a fresh <db> the way <src>'s module is
# installed, prerequisites first, then drop <db>. Exit 0 when every step succeeded. Files reach psql over
# stdin, so this needs no mount.
installs() {
  local c="$1" src="$2" file="$3" idb="$4" log="$5" rc=0
  local q=(docker exec -i "$c" psql -U postgres)
  # The fleet image the timescale track runs on does not trust the local socket (see run_timescale).
  case "$src" in pgpm_hypertable/*) q=(docker exec -i -e PGPASSWORD=postgres "$c" psql -h 127.0.0.1 -U postgres) ;; esac
  "${q[@]}" -d postgres -q -c "drop database if exists $idb" >/dev/null 2>&1
  {
    "${q[@]}" -d postgres -q -c "create database $idb" &&
    case "$src" in
      pgpm_archive/install.sql)
        "${q[@]}" -d "$idb" -v ON_ERROR_STOP=1 -q -c "create extension if not exists http; create extension if not exists pgcrypto;" &&
        "${q[@]}" -d "$idb" -v ON_ERROR_STOP=1 -q --single-transaction -f - < "$ROOT/pgpm_core/install.sql" &&
        "${q[@]}" -d "$idb" -v ON_ERROR_STOP=1 -q -f - < "$file" ;;
      pgpm_hypertable/install.sql)
        # The module installs on the plain core image too (its TimescaleDB checks run at call time, and the
        # perf track's hypertable guards bring stand-in views), so the extension is created only where the
        # image ships it: the fleet image of the timescale track. Without this the perf track's copy of
        # every hypertable mutation read as "does not install" and the shard failed (#563 met #601).
        "${q[@]}" -d "$idb" -v ON_ERROR_STOP=1 -q -c "do \$\$ begin
            if exists (select 1 from pg_available_extensions where name = 'timescaledb') then
              create extension if not exists timescaledb;
            end if;
          end \$\$;" &&
        "${q[@]}" -d "$idb" -v ON_ERROR_STOP=1 -q --single-transaction -f - < "$ROOT/pgpm_core/install.sql" &&
        "${q[@]}" -d "$idb" -v ON_ERROR_STOP=1 -q -f - < "$file" ;;
      *)
        "${q[@]}" -d "$idb" -v ON_ERROR_STOP=1 -q --single-transaction -f - < "$file" ;;
    esac
  } >"$log" 2>&1 || rc=1
  "${q[@]}" -d postgres -q -c "drop database if exists $idb" >/dev/null 2>&1
  return "$rc"
} </dev/null   # `docker exec -i` forwards stdin; the -f steps redirect their own, the rest get nothing

# starved <guard log>: exit 0 when the guard printed at least one failure and EVERY one is a premise witness
# (#713, see the header). The failures are its pgTAP `not ok` lines when it printed any (indented or not,
# numbered or not, as classify_claims.py reads them): a wrapper's own `FAIL  <what>  N ran` line restates
# the file's verdict and is not a check of its own, so the assertions behind it decide. Otherwise they are
# its `FAIL  <label>` lines. An undescribed `not ok` names no premise, so it counts as a defect check, and a
# guard that failed without printing any failure line is not read as starved (the classifier's rule too).
starved() {
  local tap='^[[:space:]]*not ok([^[:alnum:]_]|$)' descs
  if grep -qE "$tap" "$1"; then
    descs=$(grep -E "$tap" "$1" | sed -E 's/^[[:space:]]*not ok[[:space:]]*[0-9]*[[:space:]]*(-[[:space:]]*)?//')
  else
    descs=$(grep -E '^FAIL[[:space:]]' "$1" | sed -E 's/^FAIL[[:space:]]+//')
  fi
  [ -n "$descs" ] && ! grep -qvE '^(LIVENESS|GUARD|fixture):' <<<"$descs"
}

# Materialise the listing BEFORE the loop rather than piping it straight in. `done < <(cmd)` discards
# cmd's exit status, so a mutate.py that refused to list anything -- an unknown track, a track whose
# last mutation was removed -- would be indistinguishable from a track that simply had no work, and
# the loop would fall straight through to "PASS (0 guard(s) verified)". A green check that ran
# nothing is the one output this script must never produce.
LIST="$OUT/mutations-$TRACK.tsv"
if ! python3 "$ROOT/bench/mutations/mutate.py" --list "--track=$TRACK" > "$LIST"; then
  printf 'FAIL  could not list mutations for track %s (see above); nothing was verified\n' "$TRACK"
  exit 1
fi

ran=0
# The listing is read on fd 3, never stdin, and every guard runs with stdin from /dev/null. `docker exec -i`
# forwards its stdin into the container, so a guard (or a step here) that calls it inherited the rest of
# the listing and swallowed it: the loop then ended early and reported PASS for the mutations it had run.
# On main at 8c1be7c that is how shard 4/4 counted "of 76 mutations" while the others counted 78
# (throws_pinned.sh's `docker exec -i` ate the last two lines). The count check after the loop backs this.
listed=$(grep -c . "$LIST")
while IFS=$'\t' read -r name guard why src <&3; do
  i=$((i + 1))
  if (( (i - 1) % SHARD_N != SHARD_I - 1 )); then continue; fi
  ran=$((ran + 1))
  if [ -n "$LIST_ONLY" ]; then printf '%s\t%s\t%s\n' "$name" "$guard" "$src"; continue; fi
  db="$DBP$i"
  printf '\n--- %s\n    breaks: %s\n    src: %s\n    defect: %s\n' "$name" "$guard" "$src" "$why"

  case "$src" in
    # A test file of the archive track runs where its module does (#1093: tests/archive/db/08's mutant).
    pgpm_archive/install.sql|tests/archive/*) target_c="$CA" ;;
    *) target_c="$C" ;;
  esac
  if [ -z "$target_c" ]; then
    printf 'FAIL  no container supplied for src %s; guard %s is unverified\n' "$src" "$guard"
    fail=1; continue
  fi

  # A stale pattern must not quietly yield an unmutated copy: mutate.py exits non-zero instead, and a
  # mutant we could not build is a failure of this check, not a skip.
  if ! python3 "$ROOT/bench/mutations/mutate.py" "$name" "$ROOT/$src" "$OUT/$name.sql"; then
    printf 'FAIL  could not build the mutant (see above); guard %s is unverified\n' "$guard"
    fail=1; continue
  fi

  # Only a mutant that installs can verify its guard (#601; see the header). The unmutated source first,
  # once per run, so a failure below is the mutation's and not the environment's.
  installed=1
  case "$src" in
    */install.sql)
      if [[ "$baseline_ok" != *" $src "* ]]; then
        if installs "$target_c" "$src" "$ROOT/$src" "${db}_install" "$OUT/baseline.install.log"; then
          baseline_ok="$baseline_ok$src "
        else
          printf 'FAIL  the UNMUTATED %s does not install in %s; guard %s is unverified\n' "$src" "$target_c" "$guard"
          grep -m3 'ERROR' "$OUT/baseline.install.log" | sed 's/^/      /'
          fail=1; continue
        fi
      fi
      installs "$target_c" "$src" "$OUT/$name.sql" "${db}_install" "$OUT/$name.install.log" || installed=0
      ;;
  esac

  # The repo is bind-mounted at /repo, so the mutant is reachable by the same relative path inside.
  if bash "$ROOT/$guard" "$target_c" "$db" "/repo/bench/results/mutants/$name.sql" >"$OUT/$name.log" 2>&1 </dev/null; then
    guard_rc=0
  else
    guard_rc=1
  fi
  if [ "$installed" = 0 ]; then
    # Whatever the guard did: a failure against a mutant that never loaded says nothing about what the
    # guard asserts, and a pass would be stranger still. Neither verifies it.
    printf 'FAIL  the mutant does not install, so %s (exit %s) is unverified: its result has nothing to do with what it asserts\n' "$guard" "$guard_rc"
    grep -m3 'ERROR' "$OUT/$name.install.log" | sed 's/^/      /'
    grep '^FAIL' "$OUT/$name.log" | sed 's/^/      guard: /'
    fail=1
  elif [ "$guard_rc" = 0 ]; then
    printf 'FAIL  %s PASSED against its own defect: it does not discriminate\n' "$guard"
    sed 's/^/      /' "$OUT/$name.log"
    fail=1
  elif starved "$OUT/$name.log"; then
    # Its failures are printed after a marker, so that none of them reads as a failure of whatever runs this.
    printf 'FAIL  %s failed only LIVENESS witnesses against its mutant: the fixture starved and never reached the defect, so the guard is unverified\n' "$guard"
    grep -E '^[[:space:]]*not ok|^FAIL' "$OUT/$name.log" | sed 's/^[[:space:]]*/      guard: /'
    fail=1
  else
    printf 'PASS  %s fails when the defect is present\n' "$guard"
    grep '^FAIL' "$OUT/$name.log" | sed 's/^/      /'
  fi
  docker exec "$target_c" psql -U postgres -q -c "drop database if exists $db" >/dev/null 2>&1
done 3< "$LIST"
if [ -n "$LIST_ONLY" ]; then
  if [ "$ran" = 0 ]; then
    printf 'FAIL  track %s shard %s/%s selects no mutation; a slice that runs nothing verifies nothing
' "$TRACK" "$SHARD_I" "$SHARD_N" >&2
    exit 1
  fi
  exit 0
fi

echo
# Belt and braces with the listing check above: whatever the reason, finishing having run nothing is
# a failure, not a pass. This script's whole claim is "these guards were run against their defects
# and failed"; with i=0 it has no such evidence for anything.
if [ "$ran" = 0 ]; then
  printf 'FAIL  track %s shard %s/%s ran no mutations at all; every guard it covers is unverified\n' "$TRACK" "$SHARD_I" "$SHARD_N"
  fail=1
fi
# Every listed line was read. A loop that stopped early (its input swallowed, see above) has no evidence
# for the mutations it never reached, whichever shard they belonged to.
if [ "$i" != "$listed" ]; then
  printf 'FAIL  read %s of the %s listed mutations; the rest were never run and their guards are unverified\n' "$i" "$listed"
  fail=1
fi
if [ "$fail" = 0 ]; then echo "discriminate: PASS ($ran guard(s) verified against their defects; shard ${SHARD_I}/${SHARD_N} of ${i} mutations)"
else echo "discriminate: FAIL"; fi
exit "$fail"
