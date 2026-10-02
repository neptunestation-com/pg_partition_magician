#!/usr/bin/env bash
# Prove that every pgpm.log action the operator docs tell an operator to alert on, in the SQL they tell
# them to type, is one pgpm actually writes, judged by the real check (scripts/check_living_docs.sh,
# check 6) over a scratch copy of what it reads.
#
# WHY THIS GUARD EXISTS (issue #742). Check 6 says every action the operator docs name must be written by
# some install.sql, because an alert on an action nothing writes can never fire. It read the reference's
# vocabulary table and "logged `x`" prose only, never the SQL: a phantom action in the runbook's
# `and action in ('fail_retain_detach', ...)` query, the very text an operator copies into an alert, was
# passed. The check now reads every single-quoted literal compared with `action` in the operator docs
# (`=`, `<>`, `!=`, `in (...)` over any number of lines), and this guard holds it to that.
#
# AND THE ACTION POSITION (issue #848). "Written" used to mean the quoted literal was on some non-comment
# install.sql line, so an alert on `action = 'copy_swap_drop'` passed: that literal is the METHOD regrain's
# swap logs under action 'regrain', and no pgpm.log row ever carries it as its action. Check 6 now reads
# the action each pgpm.log write names, and this guard holds it to that too.
#
# HOW. Each step copies the files check 6 reads (the three operator docs, the three install.sql files,
# extension.control and the checker itself) into a scratch tree and runs the checker there; only check
# 6's section of its output is read.
#   LIVENESS  check 6 PASSES on an unmodified copy of this tree, having read at least one action literal
#             from the docs' SQL, so a clean result is not a scan of nothing;
#   CONTROL   a phantom action planted in the first `action in (` list of the runbook makes check 6
#             FAIL, naming it: the instrument can fail at all, and on exactly the SQL form at issue;
#   CONTROL   a literal an install.sql writes only as a METHOD ('copy_swap_drop'), planted in the same
#             list, makes check 6 FAIL, naming it, after first showing that literal IS on a non-comment
#             install line (so a line match would have passed it): "written" means written as an action;
#   JUDGED    with a third argument, the copy with THAT document in place of its tree original must
#             PASS check 6. With none, the LIVENESS run is the judgment of the tree.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   runbook_phantom_alert_action -- the runbook's step-2 alert query names 'fail_retire_identity', an
#                                   action nothing writes (pgpm logs fail_retain_identity)
#   runbook_alert_on_method      -- the runbook's regrain query names 'copy_swap_drop', regrain's METHOD,
#                                   as an action, so it can never match a row
#
# Usage: doc_log_actions.sh <container> <db> [doc]
# A doc is docs/guide.md, docs/reference.md or docs/runbook.md, recognised by its file name or, for a
# mutant bench/discriminate.sh built (<mutation>.sql), by the mutation's MUTATION_SRC; a /repo/... path
# is mapped to this checkout. Needs bash and python3 on the host and nothing else; <container> and <db>
# are accepted so discriminate.sh can call it the way it calls every guard, and are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY="${3:-}"
fail=0
say() { printf '%s  %-58s %s\n' "$1" "$2" "$3"; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
OPERATOR_DOCS=(docs/guide.md docs/reference.md docs/runbook.md)

TARGET=""
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then say FAIL "the doc to judge exists" "$ONLY"; exit 1; fi
  base=$(basename "$ONLY")
  for d in "${OPERATOR_DOCS[@]}"; do [ "$(basename "$d")" = "$base" ] && TARGET="$d"; done
  if [ -z "$TARGET" ]; then
    TARGET=$(python3 - "$ROOT/bench/mutations" "${base%.*}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import mutate
print(mutate.MUTATION_SRC.get(sys.argv[2], ""))
PY
)
  fi
  case " ${OPERATOR_DOCS[*]} " in
    *" $TARGET "*) ;;
    *) say FAIL "the doc to judge is an operator doc check 6 reads" "$ONLY -> '${TARGET}'"; exit 1 ;;
  esac
fi

mk() {  # <dir>: the files check 6 reads, copied from this checkout
  mkdir -p "$1/scripts" "$1/docs" "$1/pgpm_core" "$1/pgpm_hypertable" "$1/pgpm_archive"
  cp "$ROOT/scripts/check_living_docs.sh" "$1/scripts/"
  for d in "${OPERATOR_DOCS[@]}"; do cp "$ROOT/$d" "$1/docs/"; done
  cp "$ROOT/pgpm_core/install.sql" "$ROOT/pgpm_core/extension.control" "$1/pgpm_core/"
  cp "$ROOT/pgpm_hypertable/install.sql" "$1/pgpm_hypertable/"
  cp "$ROOT/pgpm_archive/install.sql" "$1/pgpm_archive/"
}
check6() {  # <dir>: check 6's section of the checker's output, run in that copy
  bash "$1/scripts/check_living_docs.sh" 2>&1 | sed -n '/^== check 6/,$p'
}

# LIVENESS: the unmodified copy passes, and the SQL extractor read something.
mk "$work/clean"
out=$(check6 "$work/clean")
n_sql=$(sed -nE 's/^PASS .*, ([0-9]+) literal\(s\) in their SQL\).*/\1/p' <<<"$out")
if [ -n "$n_sql" ] && [ "$n_sql" -gt 0 ]; then
  say PASS "LIVENESS: check 6 passes this tree, reading the docs' SQL" "$n_sql action literal(s) read from SQL"
else
  say FAIL "LIVENESS: check 6 passes this tree, reading the docs' SQL" "$(grep -E '^(PASS|FAIL)' <<<"$out" | head -3 | tr '\n' ' ')"
  fail=1
fi

plant() {  # <runbook> <literal>: put '<literal>' first in the runbook's first `action in (` list
  PH="$2" python3 - "$1" <<'PY'
import os, re, sys
p = sys.argv[1]
t = open(p).read()
m = re.search(r"\baction\s+in\s*\(", t)
if not m:
    sys.exit(1)
open(p, "w").write(t[:m.end()] + "'" + os.environ["PH"] + "', " + t[m.end():])
PY
}

# CONTROL: a phantom in an `action in (` list must be named by a FAIL.
PH=fail_retain_phantom_control
if grep -qF "'$PH'" "$ROOT/pgpm_core/install.sql" "$ROOT/pgpm_hypertable/install.sql" "$ROOT/pgpm_archive/install.sql"; then
  say FAIL "CONTROL: the planted action is one no install.sql writes" "$PH is written"; exit 1
fi
mk "$work/control"
if plant "$work/control/docs/runbook.md" "$PH"; then
  out=$(check6 "$work/control")
  if grep -qE "^FAIL .*'$PH'" <<<"$out"; then
    say PASS "CONTROL: a phantom in a runbook action in (...) list fails" "named $PH"
  else
    say FAIL "CONTROL: a phantom in a runbook action in (...) list fails" "$(grep -E '^(PASS|FAIL)' <<<"$out" | head -3 | tr '\n' ' ')"
    fail=1
  fi
else
  say FAIL "CONTROL: planted a phantom in a runbook action in (...) list" "no 'action in (' in docs/runbook.md"
  fail=1
fi

# CONTROL (#848): a literal written only as a METHOD, named as an action, must be named by a FAIL. Its
# premise first: the literal is on a non-comment install line, written as the method of an action
# 'regrain' row, so a check that matched lines rather than the action position would pass it.
MH=copy_swap_drop
# (one grep, anchored at the INSERT so a comment cannot match: `grep -q` closing a pipe early reads as a
# failure under pipefail)
if grep -qE "^[[:space:]]*insert into pgpm\.log \(parent_table, action, .*method\) values \(p_parent, 'regrain', .*, '$MH'\);" \
     "$ROOT/pgpm_core/install.sql"; then
  say PASS "LIVENESS: install.sql writes '$MH', as the method of a regrain" "on a non-comment line"
else
  say FAIL "LIVENESS: install.sql writes '$MH', as the method of a regrain" "the regrain swap's log write moved; pick the method literal again"
  fail=1
fi
mk "$work/method"
if plant "$work/method/docs/runbook.md" "$MH"; then
  out=$(check6 "$work/method")
  if grep -qE "^FAIL .*'$MH'.*as an action" <<<"$out"; then
    say PASS "CONTROL: a method value named as an action fails" "named $MH"
  else
    say FAIL "CONTROL: a method value named as an action fails" "$(grep -E '^(PASS|FAIL)' <<<"$out" | head -3 | tr '\n' ' ')"
    fail=1
  fi
else
  say FAIL "CONTROL: planted a method value in a runbook action in (...) list" "no 'action in (' in docs/runbook.md"
  fail=1
fi

# JUDGED: the document under test in place of its tree original.
if [ -n "$ONLY" ]; then
  mk "$work/judged"
  cp "$ONLY" "$work/judged/$TARGET"
  out=$(check6 "$work/judged")
  if grep -qE '^PASS ' <<<"$out" && ! grep -qE '^FAIL ' <<<"$out"; then
    say PASS "every action $TARGET names is written by an install.sql" "$(grep -E '^PASS ' <<<"$out" | head -1 | cut -c7-90)"
  else
    say FAIL "every action $TARGET names is written by an install.sql" ""
    grep -E '^(FAIL|  )' <<<"$out" | sed 's/^/      /'
    fail=1
  fi
fi
exit "$fail"
