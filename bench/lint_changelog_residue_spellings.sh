#!/usr/bin/env bash
# Prove scripts/check_changelog_residue.py reads merge residue by what it IS and not by one spelling of it: two
# versions of one bullet kept side by side are refused when they are not word for word the same, and a stale
# tail glued after a bullet is refused when it is glued on unindented.
#
# WHY THIS GUARD EXISTS (review pass 13, #1387).
#   * F13-04: the check refused two versions of one bullet only when they were word for word identical (check 1
#     compares whole bullets, and the repeated-run check looks inside one bullet, never across two), so the case
#     its own docstring names, a PR that reworded its own entry between rounds and a keep-both resolution that
#     kept both, passed whenever the rounds differed by as much as a word: two contradicting promises, side by side.
#   * F8-07: bullets() continued a bullet only over lines starting with a space, so a stale tail glued on as an
#     UNINDENTED line, which Markdown renders as more of the same list item (a lazy continuation), was read as no
#     bullet at all, and its repeated 8-word run passed. Its sibling: a blank line ended a bullet, so the same tail
#     kept as an indented paragraph after one, which Markdown renders as the same list item's, passed too, and
#     so did one after a code block fenced inside the item.
# bench/changelog_no_merge_residue.sh judges the changelog by the check; this one judges the check, on residue
# planted in the REAL CHANGELOG.md of this checkout, so a mutant of the checker is judged by text it did not write.
#
# HOW. The residue is the real instance: #1161's bullet, and the stale second tail a keep-both merge glued after
# it before #1277 (the text of bench/mutations' changelog_1161_stale_tail), which says `set_regrain` REFUSES where
# the bullet says it warns. Each refusal sits beside a LIVENESS twin the check always refused (the bullet kept
# twice word for word; the tail glued on indented), and must NAME the planted bullet's line, so a refusal of
# something else beside it does not count; and the changelog itself must pass with its bullets read, so a check
# that refuses everything, or reads nothing, fails too.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each one clause of the fix:
#   changelog_residue_near_copy_unread  -- two bullets are compared for whole-text identity only again (#1387)
#   changelog_residue_lazy_line_unread  -- an unindented line after a bullet ends it again (#1387)
#   changelog_residue_paragraph_unread  -- a blank line ends a bullet again, so an indented paragraph after it,
#                                          the same list item's to Markdown, is no bullet's text (#1387)
#   changelog_residue_fence_ends_item   -- a code block fenced inside a bullet ends it again, so a paragraph
#                                          of the item after the block is no bullet's text (#1387)
#
# Usage: lint_changelog_residue_spellings.sh <container> <db> [checker.py]
# The container and database are accepted for the shape bench/discriminate.sh calls every guard with and are not
# used: the checks are static and run on the host. With no third argument the checker is taken from this checkout.
# A third argument is a copy of it (discriminate.sh hands it a mutant, under a .sql name, at a /repo/ path that is
# mapped to this checkout).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_C="${1:?container}"; _DB="${2:?db}"; UNDER="${3:-}"
UNDER="${UNDER/#\/repo\//$ROOT/}"
if [ -n "$UNDER" ] && [ ! -s "$UNDER" ]; then
  printf 'FAIL  %-62s %s\n' "GUARD: the checker under test is readable" "$UNDER"
  exit 1
fi

ROOT="$ROOT" UNDER="$UNDER" python3 - <<'PY'
import importlib.machinery
import importlib.util
import os
import sys

ROOT, UNDER = os.environ["ROOT"], os.environ["UNDER"]
fail = 0


def report(ok, label, detail=""):
    global fail
    print(f"{'PASS' if ok else 'FAIL'}  {label:<66} {detail}")
    fail |= not ok


path = UNDER or os.path.join(ROOT, "scripts/check_changelog_residue.py")
try:
    loader = importlib.machinery.SourceFileLoader("under_test", path)
    spec = importlib.util.spec_from_loader("under_test", loader)
    chk = importlib.util.module_from_spec(spec)
    loader.exec_module(chk)
    chk.check
except Exception as e:  # a mutant that is not Python verifies nothing
    report(False, "GUARD: the checker under test loads", f"{type(e).__name__}: {e}")
    sys.exit(1)
print(f"# check_changelog_residue: {path}")
CL = open(os.path.join(ROOT, "CHANGELOG.md")).read()

# #1161's bullet, found by its last two lines, and the stale tail pre-#1277 main carried after it
END = ("  `regrain_swap_no_prepare_budget`, `regrain_set_regrain_no_budget_warning`, `regrain_swap_no_measured_budget`,\n"
       "  `regrain_swap_incoming_fk_uncharged`.\n")
TAIL = ["and every copy kept. `regrain_step`'s prepare tick (before the source is renamed or anything copied) and",
        "`set_regrain` now refuse a run whose fine children above the retention horizon would take more than half of",
        "`max_locks_per_transaction x (max_connections + max_prepared_transactions)` at two slots each, and the swap",
        "measures what its second `ATTACH` cost, charges each incoming foreign key it re-adds, and refuses, rolled",
        "back whole with the copies kept, when the run's children would take more than half. Each message names the",
        "knob and how many children fit. Test `tests/315`; guard `bench/regrain_swap_lock_budget.sh`, mutations",
        "`regrain_swap_no_prepare_budget`, `regrain_swap_no_measured_budget`, `regrain_swap_incoming_fk_uncharged`."]
if CL.count(END) != 1 or "\n  and every copy kept. `regrain_step`'s prepare tick" not in CL:
    report(False, "fixture: CHANGELOG.md holds #1161's bullet, ending once as this guard knows it")
    sys.exit(1)
stop = CL.index(END) + len(END)
start = CL.rindex("\n- ", 0, stop) + 1
BULLET = CL[start:stop]
AT = CL.count("\n", 0, start) + 1                     # the line #1161's bullet starts on
SECTION = "## [0.6.0] - 2026-09-23\n\n"
if not BULLET.startswith("- **A regrain whose swap cannot fit") or CL.count(SECTION) != 1:
    report(False, "fixture: #1161's bullet and the [0.6.0] section are where this guard looks", BULLET[:40])
    sys.exit(1)


def line_of(text, piece):
    return text.count("\n", 0, text.index(piece)) + 1


def named(text, why, *lines):
    """The violations of text that say why and name every one of lines (identity, not a count)."""
    _, problems = chk.check(text, "CHANGELOG.md")
    return [p for p in problems if why in p and all(f"CHANGELOG.md:{n} " in p for n in lines)]


n0, p0 = chk.check(CL, "CHANGELOG.md")
report(not p0 and n0 >= 100, "LIVENESS: the checkout's CHANGELOG.md passes, its bullets read", f"{n0} bullets, {len(p0)} problem(s)")

# --- F13-04: two versions of one bullet, kept side by side ----------------------------------------------------------
twice = CL[:stop] + BULLET + CL[stop:]
report(bool(named(twice, "appears 2 times", AT, AT + BULLET.count("\n"))),
       "LIVENESS: #1161's bullet kept twice word for word is refused")
NEAR = "two versions of one bullet"
# the bullet's older round: its first half, then the version of the rest the stale tail is (the real instance)
OLDER = BULLET[:BULLET.index("  and every copy kept.")] + "".join(f"  {t}\n" for t in TAIL)
older = CL[:stop] + OLDER + CL[stop:]
report(bool(named(older, NEAR, AT, AT + BULLET.count("\n"))),
       "#1161's bullet beside its older round (set_regrain refuses) is refused", "#1387")
WORD = BULLET.replace("`set_regrain` warns about such a run", "`set_regrain` refuses such a run", 1)
if WORD == BULLET:
    report(False, "fixture: the word this guard rewords is in #1161's bullet")
    sys.exit(1)
word = CL[:stop] + WORD + CL[stop:]
report(bool(named(word, NEAR, AT, AT + BULLET.count("\n"))),
       "#1161's bullet beside a copy saying refuses for warns about is refused", "#1387")
apart = CL.replace(SECTION, SECTION + WORD, 1)
report(bool(named(apart, NEAR, AT, line_of(apart, SECTION) + 2)),
       "that copy, in a released section, is refused", "#1387")

# --- F8-07: a stale tail glued on as an unindented, lazy continuation line -------------------------------------------
indented = CL[:stop] + "".join(f"  {t}\n" for t in TAIL) + CL[stop:]
report(bool(named(indented, "repeats a run", AT)), "LIVENESS: the stale tail glued on indented (pre-#1277) is refused")
lazy = CL[:stop] + "".join(f"{t}\n" for t in TAIL) + CL[stop:]
n, _ = chk.check(lazy, "CHANGELOG.md")
report(n == n0, "LIVENESS: the stale tail unindented adds and loses no bullet", f"{n} bullets, {n0} before")
report(bool(named(lazy, "repeats a run", AT)), "the stale tail glued on unindented (a lazy continuation) is refused", "#1387")
first = CL[:stop] + TAIL[0] + "\n" + "".join(f"  {t}\n" for t in TAIL[1:]) + CL[stop:]
report(bool(named(first, "repeats a run", AT)), "the stale tail with only its first line unindented is refused", "#1387")
para = CL[:stop] + "\n" + "".join(f"  {t}\n" for t in TAIL) + CL[stop:]
n, _ = chk.check(para, "CHANGELOG.md")
report(n == n0, "LIVENESS: the stale tail as a paragraph adds and loses no bullet", f"{n} bullets, {n0} before")
report(bool(named(para, "repeats a run", AT)),
       "the stale tail as an indented paragraph after a blank line is refused", "#1387")
fence = CL[:stop] + "\n  ```text\n  a code block of the item\n  ```\n\n" + "".join(f"  {t}\n" for t in TAIL) + CL[stop:]
report(bool(named(fence, "repeats a run", AT)),
       "the stale tail as a paragraph after a code block in the item is refused", "#1387")
sys.exit(fail)
PY
