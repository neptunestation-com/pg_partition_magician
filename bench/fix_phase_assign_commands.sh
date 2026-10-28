#!/usr/bin/env bash
# Prove that the fix-phase skill's commands for "the highest number in use" give the highest number, so a
# coordinator following .claude/skills/fix-phase/SKILL.md assigns fixers numbers nothing already uses.
#
# WHY THIS GUARD EXISTS (issue #1372, F13-02). The skill's command for the highest guard database was
# `grep -oE 'pgpm_perf[0-9]+' test.sh | sort -t f -k3 -n | tail -1`. `pgpm_perf406` holds one `f`, so split on
# it there is no field 3: every key is empty, `-n` compares nothing, and sort falls back to comparing whole
# lines, lexically. On a test.sh whose highest database was pgpm_perf406 it printed pgpm_perf99, and a
# coordinator assigning "the next" from there hands out databases test.sh already uses (land.sh renumbers a
# duplicate only at landing, so parallel fixers' guards collide all phase).
#
# HOW. Each assignment command is read out of the skill's own bullet (the first backticked span of the
# "Test file numbers." and "Guard database names." lines) and run, as written, in a scratch directory holding
# planted files, then in this checkout. The expected highest is computed here, numerically, from the same
# names, never by the command under test.
#   CONTROL   the planted test.sh holds pgpm_perf7, pgpm_perf99, pgpm_perf406 and pgpm_perf1000, whose lexical
#             and numeric maxima differ (pgpm_perf99 and pgpm_perf1000), so a command that sorts lexically
#             cannot pass; the planted tests/ holds 9_a.sql, 41_b.sql and 300_c.sql the same way
#   LIVENESS  each bullet's command was found and names the file it reads
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   fix_phase_guard_db_sorts_empty_key -- the skill's command sorts on field 3 again (pre-#1372)
#
# Usage: fix_phase_assign_commands.sh <container> <db> [SKILL.md]
# With no third argument it reads this checkout's skill; with one it reads THAT file, which is how
# bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this checkout). Needs bash,
# grep and sort on the host; <container> and <db> are accepted so discriminate.sh can call it the way it
# calls every guard, and are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${3:-$ROOT/.claude/skills/fix-phase/SKILL.md}"
SKILL="${SKILL/#\/repo\//$ROOT/}"
fail=0
ok()  { printf 'PASS  %-62s %s\n' "$1" "${2:-}"; }
bad() { printf 'FAIL  %-62s %s\n' "$1" "${2:-}"; fail=1; }
if [ ! -f "$SKILL" ]; then bad "fixture: the skill under test exists" "$SKILL"; exit 1; fi

cmd_of() { # <bullet label>: the first backticked span on the skill's line that carries the label
  grep -m1 -F -- "**$1**" "$SKILL" | grep -oE '`[^`]*`' | head -1 | tr -d '`'
}
GUARD_CMD=$(cmd_of "Guard database names.")
TEST_CMD=$(cmd_of "Test file numbers.")
if grep -q 'test\.sh' <<<"$GUARD_CMD"; then ok "LIVENESS: the guard database command was read" "$GUARD_CMD"
else bad "LIVENESS: the guard database command was read" "got '$GUARD_CMD'"; exit 1; fi
if grep -q 'tests/' <<<"$TEST_CMD"; then ok "LIVENESS: the test file number command was read" "$TEST_CMD"
else bad "LIVENESS: the test file number command was read" "got '$TEST_CMD'"; exit 1; fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tests"
printf '    "bench/a.sh pgpm_perf7"\n    "bench/b.sh pgpm_perf99"\n    "bench/c.sh pgpm_perf406"\n    "bench/d.sh pgpm_perf1000"\n    "bench/e.sh pgpm_perf13"\n' > "$work/test.sh"
: > "$work/tests/9_a.sql"; : > "$work/tests/41_b.sql"; : > "$work/tests/300_c.sql"; : > "$work/tests/77_d.sql"

got=$(cd "$work" && bash -c "$GUARD_CMD" 2>&1)
if [ "$got" = pgpm_perf1000 ]; then ok "CONTROL: on planted names the guard database command gives the highest" "$got"
else bad "CONTROL: on planted names the guard database command gives the highest" "got '$got', want pgpm_perf1000 (lexically last: pgpm_perf99)"; fi
got=$(cd "$work" && bash -c "$TEST_CMD" 2>&1)
if [ "$got" = 300 ]; then ok "CONTROL: on planted files the test file number command gives the highest" "$got"
else bad "CONTROL: on planted files the test file number command gives the highest" "got '$got', want 300"; fi

want=$(grep -oE 'pgpm_perf[0-9]+' "$ROOT/test.sh" | sed 's/^pgpm_perf//' | sort -n | tail -1)
got=$(cd "$ROOT" && bash -c "$GUARD_CMD" 2>&1)
if [ -n "$want" ] && [ "$got" = "pgpm_perf$want" ]; then ok "on this test.sh the guard database command gives the highest" "$got"
else bad "on this test.sh the guard database command gives the highest" "got '$got', want pgpm_perf$want"; fi
want=$(find "$ROOT/tests" -maxdepth 1 -name '[0-9]*' -exec basename {} \; | grep -oE '^[0-9]+' | sort -n | tail -1)
got=$(cd "$ROOT" && bash -c "$TEST_CMD" 2>&1)
if [ -n "$want" ] && [ "$got" = "$want" ]; then ok "on this tests/ the test file number command gives the highest" "$got"
else bad "on this tests/ the test file number command gives the highest" "got '$got', want $want"; fi

echo "fix_phase_assign_commands: $([ "$fail" = 0 ] && echo PASS || echo FAIL)"
exit "$fail"
