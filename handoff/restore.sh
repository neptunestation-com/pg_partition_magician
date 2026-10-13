#!/usr/bin/env bash
# restore.sh [<work dir>]: restore the pass-12 fix-phase handoff on a new machine.
#
# Run it from inside the repository checkout (any branch, any path); it reads the bundle straight
# out of origin/chore/fix12-handoff, so nothing needs checking out. It restores the coordinator's
# memory into the directory Claude Code will read for this checkout, copies the fix-12 and pass-12
# scratch under <work dir> (default ~/.claude/handoff-fix12), and re-points every absolute path the
# scripts and briefs carry from the old machine. Idempotent: run it again after moving the checkout.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
git fetch -q origin chore/fix12-handoff
TMP=$(mktemp -d)
git archive origin/chore/fix12-handoff handoff | tar -x -C "$TMP"
B=$TMP/handoff

# Claude Code names a project's directory after the checkout path with every character that is not
# a letter or digit replaced by '-' (/Users/x/Work/pg_partition_magician -> -Users-x-Work-pg-partition-magician).
SLUG=$(printf '%s' "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')
MEM=$HOME/.claude/projects/$SLUG/memory
mkdir -p "$MEM"
for f in "$B"/memory/*.md; do
  [ -e "$MEM/$(basename "$f")" ] || cp "$f" "$MEM"/
done
cp "$B"/memory/MEMORY.md "$B"/memory/project_fix12_phase.md "$MEM"/

WORK=${1:-$HOME/.claude/handoff-fix12}
mkdir -p "$WORK"
rm -rf "$WORK/fix12" "$WORK/pass12"
cp -R "$B"/fix12 "$WORK"/fix12
cp -R "$B"/pass12 "$WORK"/pass12
cp "$B"/HANDOFF.md "$WORK"/HANDOFF.md

OLD_TMP=/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp
OLD_ROOT=/Users/davida.ventimiglia/Work/pg_partition_magician
grep -rl -e "$OLD_TMP" -e "$OLD_ROOT" "$WORK" | while read -r f; do
  python3 - "$f" "$OLD_TMP" "$WORK" "$OLD_ROOT" "$ROOT" <<'PY'
import sys
p, a, b, c, d = sys.argv[1:]
s = open(p, errors="surrogateescape").read()
open(p, "w", errors="surrogateescape").write(s.replace(a, b).replace(c, d))
PY
done
chmod +x "$WORK"/fix12/*.sh "$WORK"/pass12/tools/*.sh 2>/dev/null || true
rm -rf "$TMP"

echo "memory  -> $MEM ($(ls "$MEM" | wc -l | tr -d ' ') files; if Claude Code later creates a differently named directory under ~/.claude/projects, move these files into it)"
echo "scratch -> $WORK/fix12 (the fix phase's \$W) and $WORK/pass12 (the pass's claims); guide at $WORK/HANDOFF.md"
echo "next    -> start Claude Code in $ROOT and say: resume the pass-12 fix phase per $WORK/HANDOFF.md, continuing /fix-phase at step 2 with its per-PR table"
