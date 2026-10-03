#!/usr/bin/env bash
# Guard that phase 3's cutover builds and configures the new parent BEFORE either rename (issue #344),
# so that work never adds to the outage. #275's split already keeps the one O(rows) scan out from under
# ACCESS EXCLUSIVE; this is the sibling guard for phase 3 itself, which is one transaction end to end --
# anything it does after the first rename is held under that lock until the whole procedure commits.
#
# NOT a concurrency probe. The whole point of this change is to make the critical section SHORTER, which
# makes it harder, not easier, to catch anything "in progress" -- the opposite problem transmute_lock.sh
# solves. There is nothing to observe live; the property is about STATEMENT ORDER inside one transaction,
# which is simple, deterministic SQL against the installed function's own source text, with zero flake
# risk: no timing, no concurrent session, no polling loop to starve what it measures.
#
# Usage: transmute_cutover_order.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected> (numeric position comparison: actual < expected)
  if [ "$2" -gt 0 ] && [ "$2" -lt "$3" ]; then printf 'PASS  %-62s %s < %s\n' "$1" "$2" "$3"
  else printf 'FAIL  %-62s got %s, want < %s (and > 0)\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

# Each position is that of a STATEMENT, never of the first occurrence of its phrase (#796). The source is
# also prose: its preamble discusses "the cutover's CREATE TABLE ... PARTITION BY RANGE" thousands of
# characters ahead of the cutover, so strpos() of 'partition by range' found that comment and the check
# passed with the real CREATE TABLE moved after both renames, the #344 defect this guard exists for. A
# statement is matched as the `execute format('...` that issues it, which a comment or a message string
# cannot be. regexp_instr() is 1-based and 0 means "not found": check()'s "> 0" requirement catches a
# statement that goes missing entirely instead of comparing 0 < 0, and the LIVENESS counts below catch
# one that is matched more than once, where "the first" would again be a guess.
SRC_QUERY="select lower(prosrc) from pg_proc where proname = '_transmute' and pronamespace = 'pgpm'::regnamespace"
CREATE_RE="execute format\\('create table [^']* partition by range "
RENAME_RE="execute format\\('alter table %s rename to "
RLS_RE="execute format\\('alter table %s enable row level security'"
# The policy replay is its own statement, in its own loop, and is anchored on its own (#845): with only the
# ENABLE ROW LEVEL SECURITY anchored, a copy whose CREATE POLICY loop sat after both renames, inside the
# outage, passed this guard under a PASS line that named the policies.
POLICY_RE="execute format\\('create policy %i on %s as "
# The pattern goes in dollar-quoted: it holds a single quote, and its backslashes must reach the regex.
stmt_pos()   { q "select regexp_instr(($SRC_QUERY), \$re\$$1\$re\$)"; }
stmt_count() { q "select regexp_count(($SRC_QUERY), \$re\$$1\$re\$)"; }
count_is() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-62s %s\n' "$1" "$2"
  else printf 'FAIL  %-62s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

count_is "LIVENESS: _transmute issues one CREATE TABLE ... PARTITION BY RANGE" "$(stmt_count "$CREATE_RE")" 1
count_is "LIVENESS: _transmute issues the two cutover renames" "$(stmt_count "$RENAME_RE")" 2
count_is "LIVENESS: _transmute issues one ENABLE ROW LEVEL SECURITY" "$(stmt_count "$RLS_RE")" 1
count_is "LIVENESS: _transmute issues one CREATE POLICY" "$(stmt_count "$POLICY_RE")" 1

RENAME_POS=$(stmt_pos "$RENAME_RE")
PARTITION_POS=$(stmt_pos "$CREATE_RE")
RLS_POS=$(stmt_pos "$RLS_RE")
POLICY_POS=$(stmt_pos "$POLICY_RE")

check "the new parent's CREATE TABLE runs before the first rename" "$PARTITION_POS" "$RENAME_POS"
check "the ENABLE ROW LEVEL SECURITY runs before the first rename" "$RLS_POS" "$RENAME_POS"   # grants follow the attach (#706)
check "the CREATE POLICY replay runs before the first rename" "$POLICY_POS" "$RENAME_POS"

exit "$fail"
