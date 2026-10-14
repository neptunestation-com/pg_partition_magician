#!/usr/bin/env python3
"""Refuse merge residue in CHANGELOG.md: a bullet twice, or a bullet carrying a stale copy of its own text.

WHY THIS EXISTS (issue #1277). CHANGELOG.md is a list file every fix PR adds to, and a conflict in it is
resolved by keeping both sides (scripts/review/keep_both.py at landing, or by hand). When the two sides are
two versions of the SAME bullet (a PR that reworded its own entry between rounds, a branch rebased over an
older copy of itself), keeping both leaves the bullet twice, or leaves the older version's tail glued after
the newer one. Review pass 12 found five bullets present twice word for word in the Unreleased section, and
#1161's bullet carrying a second, stale tail that said `set_regrain` REFUSES a run past the lock budget, where
the code, the bullet's own first half and docs/reference.md say it warns and stores the target. A reader of
the changelog then has two contradicting promises for one fix, and nothing failed.

WHAT IS REFUSED, in every section of the file (a released section is held to it too, so the check does not
go blind the day `[Unreleased]` is cut into a version):
  1. a bullet whose whole text (whitespace folded) is another bullet's in the same file;
  2. a bullet in which a run of RUN consecutive words occurs twice, the second time not overlapping the
     first: a stale tail repeats a sentence fragment of the version it trails;
  3. a bullet whose parentheses, outside code spans and double-quoted text, do not balance: a residue
     fragment that begins mid-parenthesis (a lone "`COMMIT`).") leaves one more ")" than "(".
RUN = 8 was measured: the file as fixed holds no repeated 8-word run in any bullet, while a run of 6 or 5
recurs legitimately in a dozen long bullets ("the hypertable's own primary key or ..."), and every residue
pass 12 and its fix phase left behind repeats one of 8 or more.

`--selftest` re-breaks a copy of a small changelog each way and requires each check to fail against it,
after the unbroken copy passes; scripts/check_living_docs.sh runs both.

Usage: check_changelog_residue.py [--selftest] [CHANGELOG.md]
"""
import re
import sys
from collections import defaultdict

RUN = 8


def bullets(text):
    """Yield (section heading, first line number, [lines]) for every top-level bullet."""
    section, cur, out = "", None, []
    fenced = False
    for n, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            cur = None
            continue
        if fenced:
            continue
        if line.startswith("#"):
            section, cur = line.lstrip("#").strip(), None
        elif line.startswith("- ") or line.startswith("* "):
            cur = [section, n, [line[2:]]]
            out.append(cur)
        elif cur is not None and line.startswith(" ") and line.strip():
            cur[2].append(line.strip())
        else:
            cur = None
    return out


def words(lines):
    return " ".join(lines).split()


def repeated_run(w):
    first = {}
    for j in range(len(w) - RUN + 1):
        g = tuple(w[j:j + RUN])
        if g in first and j - first[g] >= RUN:
            return " ".join(g)
        first.setdefault(g, j)
    return None


def parens(lines):
    t = " ".join(lines)
    t = re.sub(r"`[^`]*`", "X", t)
    t = re.sub(r'"[^"]*"', "Q", t)
    return t.count("("), t.count(")")


def check(text, name):
    problems = []
    bs = bullets(text)
    whole = defaultdict(list)
    for sec, n, ls in bs:
        whole[" ".join(words(ls))].append((sec, n))
    for body, where in whole.items():
        if len(where) > 1:
            at = ", ".join(f"{name}:{n} ({sec})" for sec, n in where)
            problems.append(f"{at}: the same bullet appears {len(where)} times: {body[:90]}")
    for sec, n, ls in bs:
        r = repeated_run(words(ls))
        if r:
            problems.append(f"{name}:{n} ({sec}): the bullet repeats a run of its own text, a stale tail "
                            f"of another version of it: \"{r}\"")
        o, c = parens(ls)
        if o != c:
            problems.append(f"{name}:{n} ({sec}): the bullet's parentheses do not balance ({o} open, {c} "
                            f"close), a fragment of another version of it: {' '.join(ls)[:90]}")
    return len(bs), problems


SAMPLE = """# Changelog

## [Unreleased]

- **A regrain whose swap cannot fit in half the lock table is refused** (#1). The prepare tick refuses a run
  whose fine children would take more than half of the lock table; `set_regrain` warns about such a run (a
  `WARNING` and a log row) and stores the target. Test `tests/1`; mutation `m_one`.

- **`untransmute` refuses while a partition is pending a concurrent detach** (#2). It now refuses, naming every
  pending partition and the remedy (let the detach finish, or `FINALIZE` it). Test `tests/2`.

## [0.1.0] - 2026-01-01

- **A released fix** (#0). Its text, once.
"""


def selftest():
    rc = 0
    n, p = check(SAMPLE, "<sample>")
    if n != 3 or p:
        print(f"selftest: FAIL  the unbroken sample should pass with 3 bullets: read {n}, problems {p}")
        return 1
    print("selftest: ok    the unbroken sample passes (3 bullets)")
    two = ("- **`untransmute` refuses while a partition is pending a concurrent detach** (#2). It now refuses, "
           "naming every\n  pending partition and the remedy (let the detach finish, or `FINALIZE` it). Test "
           "`tests/2`.\n")
    breaks = [
        ("a bullet kept twice", SAMPLE.replace("## [0.1.0]", two + "\n## [0.1.0]"), "appears 2 times"),
        ("a bullet kept twice across sections", SAMPLE + two, "appears 2 times"),
        ("a stale tail after the newer version",
         SAMPLE.replace("Test `tests/1`; mutation `m_one`.\n",
                        "Test `tests/1`; mutation `m_one`.\n  whose fine children would take more than half of the "
                        "lock table; and `set_regrain`\n  now refuse it. Test `tests/1`.\n"), "repeats a run"),
        ("a fragment opening mid-parenthesis",
         SAMPLE.replace("Test `tests/2`.\n", "Test `tests/2`.\n  `COMMIT`).\n"), "do not balance"),
    ]
    for label, broken, needle in breaks:
        if broken == SAMPLE:
            print(f"selftest: FAIL  re-break '{label}' did not apply: the sample moved")
            rc = 1
            continue
        _, p = check(broken, "<sample>")
        if not any(needle in x for x in p):
            print(f"selftest: FAIL  {label} PASSED (or failed for another reason): {p}")
            rc = 1
        else:
            print(f"selftest: ok    {label} fails, naming '{needle}'")
    print("selftest: PASS" if rc == 0 else "selftest: FAIL")
    return rc


def main(argv):
    if argv and argv[0] == "--selftest":
        return selftest()
    path = argv[0] if argv else "CHANGELOG.md"
    with open(path) as fh:
        text = fh.read()
    n, problems = check(text, path)
    if n == 0:
        print(f"FAIL  {path}: read no bullets at all, so this check is looking at nothing")
        return 1
    for p in problems:
        print(f"FAIL  {p}")
    if problems:
        return 1
    print(f"PASS  {path}: {n} bullets, none twice, none carrying a stale copy of its own text")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
