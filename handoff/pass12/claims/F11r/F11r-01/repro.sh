#!/usr/bin/env bash
# The tree's own archive module fails the tree's own CI lint (scripts/check_archive_child_by_oid.py, run by
# .github/workflows/lint.yml and by test.sh), and so bench/lint_child_by_oid_inverse.sh fails on clean code:
# archive.to_s3 renders the control column's type as `v_ctl_typ::regtype::text` in a plpgsql assignment,
# which rule 1 of the checker refuses (a regtype rendered as text stands in an expression).
set -uo pipefail
: "${TREE:?TREE}"
fail=0
cd "$TREE"
# premise 1: the checker is alive and discriminates (its own selftest)
if python3 scripts/check_archive_child_by_oid.py --selftest >/tmp/f11r01_self.$$ 2>&1; then
  echo "ok - LIVENESS: the checker's selftest passes (it refuses what it should)"
else
  echo "not ok - LIVENESS: the checker's selftest passes"; tail -5 /tmp/f11r01_self.$$; fail=1
fi
# premise 2: the module holds archive.to_s3, the export the checker judges
if grep -q "create or replace function archive.to_s3(" pgpm_archive/install.sql; then
  echo "ok - LIVENESS: pgpm_archive/install.sql defines archive.to_s3"
else
  echo "not ok - LIVENESS: pgpm_archive/install.sql defines archive.to_s3"; fail=1
fi
# defect check 1: CI's lint step over the module (lint.yml: python3 scripts/check_archive_child_by_oid.py)
out=$(python3 scripts/check_archive_child_by_oid.py 2>&1); rc=$?
if [ "$rc" = 0 ]; then
  echo "ok - the tree's archive module passes the tree's check_archive_child_by_oid.py (CI's Lint job)"
else
  echo "not ok - the tree's archive module passes the tree's check_archive_child_by_oid.py (CI's Lint job)"
  echo "$out" | head -3 | sed 's/^/#   /'
  fail=1
fi
# defect check 2: the guard that proves the lint, run on clean code, is green
gout=$(bash bench/lint_child_by_oid_inverse.sh none none 2>&1); grc=$?
if [ "$grc" = 0 ]; then
  echo "ok - bench/lint_child_by_oid_inverse.sh passes on the tree's own checker and module"
else
  echo "not ok - bench/lint_child_by_oid_inverse.sh passes on the tree's own checker and module"
  echo "$gout" | grep '^FAIL' | sed 's/^/#   /'
  fail=1
fi
rm -f /tmp/f11r01_self.$$
exit "$fail"
