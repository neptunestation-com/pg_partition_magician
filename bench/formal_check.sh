# shellcheck shell=bash
# The invariant oracle at a custody guard's observation points (formal methods Phase 3 W4,
# docs/formal/phase3-design.md "Wiring", item 2). Sourced, never run. The guards that drive retention or archiving
# with real concurrency, and only those (the design note lists them and why), call:
#
#   formal_install <container> <db>          once the guard's database has pgpm (and, for a guard that runs a
#                                            custody file, right after it installs tests/formal/oracle.sql itself)
#   formal_check <container> <db> <label>    at an observation point: AFTER the window the guard measures has closed,
#                                            in a session of its own, never inside a transaction the guard observes
#
# REPORT MODE. formal_check prints one line, prefixed ORACLE (never PASS or FAIL, so neither the guard's verdict nor
# bench/discriminate.sh's reading of it changes), and writes the oracle's rows to
# ${PGPM_ORACLE_LOG:-oracle-log}/bench/<guard>.<label>.oracle in tests/formal/report.sql's format. It returns 0
# whatever the oracle says; an oracle that raised says so on its line (`oracle ERROR`).
#
# PGPM_FORMAL_BENCH=0 runs the guard as if the oracle were absent: formal_check does nothing, and formal_install drops
# the oracle's two event triggers instead of installing it (a guard whose custody file calls pgpm_formal.baseline()
# still needs the schema; the triggers are what take locks: an AccessShare on pgpm.part and pgpm.config at every DDL,
# the hazard W2 flagged). That is the lock comparison W4 ran for every guard that calls these.

FORMAL_BENCH="${PGPM_FORMAL_BENCH:-1}"
FORMAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

formal_install() {  # <container> <db>
  if [ "$FORMAL_BENCH" = 1 ]; then
    docker exec -e PGOPTIONS='-c client_min_messages=warning' "$1" psql -U postgres -d "$2" -v ON_ERROR_STOP=1 -q \
      -f /repo/tests/formal/oracle.sql >/dev/null 2>&1 || echo "ORACLE  the oracle did not install in $2"
  else
    docker exec "$1" psql -U postgres -d "$2" -q -c "drop event trigger if exists pgpm_formal_sql_drop;
      drop event trigger if exists pgpm_formal_ddl;" >/dev/null 2>&1 || true
  fi
}

formal_check() {  # <container> <db> <label>
  [ "$FORMAL_BENCH" = 1 ] || return 0
  local guard dir out rc=0
  guard=$(basename "$0" .sh)
  dir="${PGPM_ORACLE_LOG:-$FORMAL_ROOT/oracle-log}/bench"
  mkdir -p "$dir"
  out="$dir/$guard.$3.oracle"
  docker exec "$1" psql -U postgres -d "$2" -qAt -F "$(printf '\t')" -v ON_ERROR_STOP=1 -v file="bench/$guard:$3" \
    -v scope= -v load_store=0 -f /repo/tests/formal/report.sql </dev/null >"$out" 2>"$out.err" || rc=$?
  if [ "$rc" != 0 ]; then
    printf 'E\t%s\tthe oracle session exited %s: %s\n' "bench/$guard:$3" "$rc" "$(tr '\t\n' '  ' <"$out.err" | cut -c1-600)" >>"$out"
  fi
  rm -f "$out.err"
  awk -F'\t' -v label="$guard:$3" '
    $1 == "V" { v[$3]++; nv++ }  $1 == "E" { ne++ }  $1 == "J" { j[$3] = $6 }
    END {
      line = sprintf("ORACLE  %-50s %d violation(s)", label, nv)
      for (k in v) line = line sprintf(" %s=%d", k, v[k])
      line = line sprintf("; judged NoLostRow %d, ResolveByRecord %d, NoWedge %d identities", j["NoLostRow"], j["ResolveByRecord"], j["NoWedge"])
      if (ne > 0) line = line sprintf("; oracle ERROR (%d)", ne)
      print line
    }' "$out"
}
