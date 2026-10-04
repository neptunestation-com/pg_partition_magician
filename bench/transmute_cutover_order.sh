#!/usr/bin/env bash
# Guard that phase 3's cutover builds and configures the new parent BEFORE either rename (issue #344),
# so that work never adds to the outage. #275's split already keeps the one O(rows) scan out from under
# ACCESS EXCLUSIVE; this is the sibling guard for phase 3 itself, which is one transaction end to end --
# anything it does after the first rename is held under that lock until the whole procedure commits.
#
# The policies are the exception, and the guard holds them to it (#897). Their text is captured before the
# renames, but pg_get_expr qualifies a reference to the outer row with the table's own name, so it can only
# be replayed once the new parent bears that name: created on the staging parent it failed raw ("missing
# FROM-clause entry"), or bound a subquery over the table to the oid the monolith takes. So the capture
# must run before the first rename (afterwards pg_get_expr would name the monolith) and the replay after
# the second. tests/250 (bench/transmute_self_naming_policy.sh) proves the behaviour; this proves the
# order, which the outage reasoning above would otherwise pull back ahead of the renames.
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
# The policies are anchored on their own statements (#845, #897): the capture that builds each CREATE
# POLICY as text naming the table, and the loop that executes them. The pre-#897 shape, which executed
# each CREATE POLICY straight onto the staging parent, has neither, so it fails the two LIVENESS counts.
POLICY_CAPTURE_RE="v_poldefs := v_poldefs \\|\\| format\\('create policy %i on %i\\.%i as "
POLICY_REPLAY_RE="foreach v_poldef in array v_poldefs loop\\s+execute v_poldef;"
# The pattern goes in dollar-quoted: it holds a single quote, and its backslashes must reach the regex.
stmt_pos()   { q "select regexp_instr(($SRC_QUERY), \$re\$$1\$re\$, 1, ${2:-1})"; }   # <re> [occurrence]
stmt_count() { q "select regexp_count(($SRC_QUERY), \$re\$$1\$re\$)"; }
count_is() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-62s %s\n' "$1" "$2"
  else printf 'FAIL  %-62s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

count_is "LIVENESS: _transmute issues one CREATE TABLE ... PARTITION BY RANGE" "$(stmt_count "$CREATE_RE")" 1
count_is "LIVENESS: _transmute issues the two cutover renames" "$(stmt_count "$RENAME_RE")" 2
count_is "LIVENESS: _transmute issues one ENABLE ROW LEVEL SECURITY" "$(stmt_count "$RLS_RE")" 1
count_is "LIVENESS: _transmute captures its policies as statements, once" "$(stmt_count "$POLICY_CAPTURE_RE")" 1
count_is "LIVENESS: _transmute replays the captured policies, once" "$(stmt_count "$POLICY_REPLAY_RE")" 1

RENAME_POS=$(stmt_pos "$RENAME_RE")
RENAME2_POS=$(stmt_pos "$RENAME_RE" 2)
PARTITION_POS=$(stmt_pos "$CREATE_RE")
RLS_POS=$(stmt_pos "$RLS_RE")
CAPTURE_POS=$(stmt_pos "$POLICY_CAPTURE_RE")
REPLAY_POS=$(stmt_pos "$POLICY_REPLAY_RE")

check "the new parent's CREATE TABLE runs before the first rename" "$PARTITION_POS" "$RENAME_POS"
check "the ENABLE ROW LEVEL SECURITY runs before the first rename" "$RLS_POS" "$RENAME_POS"   # grants follow the attach (#706)
check "the policies are captured before the first rename" "$CAPTURE_POS" "$RENAME_POS"
check "the second rename runs before the policy replay (#897)" "$RENAME2_POS" "$REPLAY_POS"

exit "$fail"
