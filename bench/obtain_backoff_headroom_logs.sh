#!/usr/bin/env bash
# obtain_backoff_headroom_logs.sh <container> <db> [guard script]
#
# Prove that two runs of bench/obtain_backoff_headroom.sh at once each print THEIR OWN install and insert
# errors (issue #962, bullet A962-2). The guard used to write its logs to fixed host paths
# (/tmp/obh_install.log, /tmp/obh_insert.log), so a run that failed printed whichever run wrote the file
# last: two concurrent runs on distinct databases printed the OTHER run's install error in 52 of 60 pairs.
# discriminate.sh, a perf run and a second shard on one host are such runs.
#
# HOW, deterministically rather than by racing. Both runs are given an install path that does not exist,
# each its own (/nonexistent_obh_logs_A and _B), so each fails at the install and prints its log; the path
# in the printed error says whose log it was. A stand-in `docker` first on PATH runs the real one and, for
# the install call alone (the one naming a marker path), waits at a barrier until BOTH runs' installs have
# written their errors before returning. So both logs are written before either run reads its own: with one
# shared file, the reads see a single error and at least one run prints the other's path, every time; with
# a file per run, neither can.
#   LIVENESS  each run reached the install-failure diagnostic; and the barrier was met by both (the two
#             installs really overlapped, so a shared file had its chance to be clobbered).
#   DEFECT    each run's printed log names its own install path and not the other's; and the script's
#             code (comments aside) names no fixed path under /tmp, which covers the insert log too.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   obtain_backoff_headroom_shared_logs -- the guard's logs back at /tmp/obh_install.log and
#                                          /tmp/obh_insert.log, the pre-#962 shape
#
# The third argument is the script to judge (default bench/obtain_backoff_headroom.sh); a /repo/... path, as
# bench/discriminate.sh passes a mutant, is mapped to this checkout. Runs on the plain core image.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="${3:-$ROOT/bench/obtain_backoff_headroom.sh}"; G="${G/#\/repo\//$ROOT/}"
fail=0
say() { printf '%s  %-62s %s\n' "$1" "$2" "$3"; }
check() { # <label> <ok: 0|1> <detail>
  if [ "$2" = 1 ]; then say PASS "$1" "$3"; else say FAIL "$1" "$3"; fail=1; fi
}
if [ ! -f "$G" ]; then say FAIL "GUARD: the script to judge exists" "$G"; exit 1; fi
REAL_DOCKER=$(command -v docker) || { say FAIL "GUARD: docker is on PATH" "not found"; exit 1; }

work=$(mktemp -d)
cleanup() {
  for s in a b; do docker exec "$C" psql -U postgres -q -c "drop database if exists ${DB}_$s" >/dev/null 2>&1; done
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/bin" "$work/bar"
# The stand-in docker. A call naming a marker path is the install: run it, record that it wrote, and wait
# (at most 30 s) for the other run's install to have written too. Every other call is the real docker.
cat >"$work/bin/docker" <<EOF
#!/usr/bin/env bash
"$REAL_DOCKER" "\$@"; rc=\$?
for a in "\$@"; do
  case "\$a" in
    /nonexistent_obh_logs_[AB])
      touch "$work/bar/\${a##*_}"
      for _ in \$(seq 1 300); do
        [ -e "$work/bar/A" ] && [ -e "$work/bar/B" ] && { touch "$work/bar/met_\${a##*_}"; break; }
        sleep 0.1
      done ;;
  esac
done
exit \$rc
EOF
chmod +x "$work/bin/docker"

PATH="$work/bin:$PATH" bash "$G" "$C" "${DB}_a" /nonexistent_obh_logs_A >"$work/a.out" 2>&1 &
pa=$!
PATH="$work/bin:$PATH" bash "$G" "$C" "${DB}_b" /nonexistent_obh_logs_B >"$work/b.out" 2>&1 &
pb=$!
wait "$pa" "$pb"

reached=0
for s in A B; do
  f="$work/$(tr AB ab <<<"$s").out"
  grep -q '^FAIL  install did not complete' "$f" && reached=$((reached + 1))
done
check "LIVENESS: both runs reached the install-failure diagnostic" "$([ "$reached" = 2 ] && echo 1)" "$reached of 2"
check "LIVENESS: both installs had written before either run read its log" \
  "$([ -e "$work/bar/met_A" ] && [ -e "$work/bar/met_B" ] && echo 1)" "$(ls "$work/bar" | tr '\n' ' ')"
for s in A B; do
  o=$(tr AB BA <<<"$s"); f="$work/$(tr AB ab <<<"$s").out"
  check "run $s printed its own install error, not run $o's" \
    "$(grep -q "nonexistent_obh_logs_$s" "$f" && ! grep -q "nonexistent_obh_logs_$o" "$f" && echo 1)" \
    "$(grep -m1 -o 'nonexistent_obh_logs_[AB][^ ]*' "$f" | head -1)"
done
fixed=$(grep -nE '/tmp/' "$G" | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1 | tr '\n' ' ')
check "the script names no fixed path under /tmp" "$([ -z "$fixed" ] && echo 1)" "${fixed:+on line(s) }${fixed:-none}"

exit "$fail"
