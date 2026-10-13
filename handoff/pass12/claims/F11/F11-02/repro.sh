#!/usr/bin/env bash
# F11-02: bench/ci_runs_lint_jobs.sh certifies that `./test.sh ci` "runs" the lint track by finding a command
# `"$0" lint` in the ci block, and never asks whether ci FAILS when that track fails. A test.sh whose ci runs the
# lint track and then drops its failure (the `*) ci_failed="$ci_failed lint"` arm emptied) prints
# "ci: PASS" over a red Lint summary, which is issue #1183's symptom, and the guard passes it.
# The mutant is built here from $TREE/test.sh; its ci block's lint handling is RUN with $0 stubbed to a script
# whose lint track fails, beside the tree's own, so the LIVENESS lines show the mutant really carries the defect.
set -uo pipefail
: "${TREE:?}"
fail=0
say() { if [ "$1" = 0 ]; then echo "ok - $2"; else echo "not ok - $2"; fail=1; fi; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

ARM='    *) ci_failed="$ci_failed lint" ;;'
grep -qxF "$ARM" "$TREE/test.sh"
say $? "fixture: the tree's ci block records a failed lint track in ci_failed"
cp "$TREE/test.sh" "$work/test.sh"
python3 - "$work/test.sh" "$ARM" <<'PY'
import sys
p, arm = sys.argv[1], sys.argv[2]
s = open(p).read()
assert s.count(arm + "\n") == 1
open(p, "w").write(s.replace(arm + "\n", "    *) ;;\n"))
PY
say $? "fixture: the mutant test.sh was written"

# run the lint part of a ci block (from `ci_failed=""` to `rm -f "$lint_skips"`) with $0 = a stub whose lint fails
cat > "$work/stub.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = lint ] && exit 1
exit 0
SH
chmod +x "$work/stub.sh"
lint_part() {
  local snip
  snip=$(awk '/^if \[ "\$TRACK" = "ci" \]; then/{f=1;next} f&&/^  rm -f "\$lint_skips"/{print;exit} f{print}' "$1")
  bash -c "$snip"'
echo "ci_failed=[$ci_failed]"' "$work/stub.sh" 2>/dev/null | tail -1
}
tree_v=$(lint_part "$TREE/test.sh"); mut_v=$(lint_part "$work/test.sh")
[ "$tree_v" = "ci_failed=[ lint]" ]
say $? "LIVENESS: the tree's ci reads a failed lint track as a failure ($tree_v)"
[ "$mut_v" = "ci_failed=[]" ]
say $? "LIVENESS: the mutant's ci runs the same lint track and reads its failure as nothing ($mut_v)"

out=$(bash "$TREE/bench/ci_runs_lint_jobs.sh" unused unused "$work/test.sh" 2>&1); rc=$?
grep -q '^PASS  LIVENESS: the scan reads test.sh' <<<"$out"
say $? "LIVENESS: the guard scanned the mutant test.sh"
[ "$rc" != 0 ]
say $? "ci_runs_lint_jobs.sh refuses a test.sh whose ci drops the lint track's failure (guard exit $rc: $(grep -E '^(PASS|FAIL)  test.sh' <<<"$out" | tr -s ' '))"
exit "$fail"
