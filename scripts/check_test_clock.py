#!/usr/bin/env python3
"""A test that converts a table and then names a partition by its months pins the clock it was written in. Run by
CI (the `Test clock` lint job) and by test.sh's lint track.

WHY THIS EXISTS (#1425). transmute's first partition runs from the table's oldest row to the month after now(), so
its name (`b_p2026_01_to_2026_11`) and its bound are a function of the month the test runs in. tests/317 and
tests/334 spelled the October 2026 answer out as literals and passed all month; on 1 November they failed on main
with nothing changed, and every PR's CI went red with them. A month-dependent test is green for the month it was
written in and wrong for every other, so nothing short of a calendar can catch it by running it.

THE RULE, over tests/**/*.sql. A file IN SCOPE calls pgpm.transmute AND holds a month-step catch-up name literal
(`_pYYYY_MM_to_YYYY_MM`). Each one must either:

  1. PIN THE CLOCK: define a `<schema>.now()` shim and run a transmute call under it, with a
     `set search_path = <schema>, ...` after which no other `set search_path` or `reset search_path` comes before
     the call. pgpm reads now() unqualified, so the shim stands in for the wall clock during the call (tests/311,
     324, 342 are the precedent); or
  2. be MARKED: a `-- clock-ok: <reason>` comment saying why its literals do not come from the clock (they are
     _part_name's output over explicit bounds, say). The reason is the review; a mark with no reason fails.

LIMITS, stated rather than hidden. The check reads text, not control flow, and it asks for ONE pinned transmute,
not every one: it cannot tell a time-grid call from an id-grid one (tests/317 converts an id-grid table unpinned,
correctly), so a file with two time-grid calls and one of them unpinned passes. A literal counts whichever statement
it sits in. A test that derives its expected names from now() (tests/124's refusal messages, tests/138)
holds no literal and is out of scope, which is the other correct way to write one. Only month-step names are
matched: a day- or id-grid literal is not.

Usage:
  ./scripts/check_test_clock.py              # check tests/**/*.sql
  ./scripts/check_test_clock.py <file.sql>.. # check other copies (a mutant)
  ./scripts/check_test_clock.py --selftest   # prove each rule fails when its defect is present
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

CATCHUP = re.compile(r'_p20\d\d_\d\d_to_20\d\d_\d\d\b')
TRANSMUTE = re.compile(r'\bpgpm\.transmute\s*\(', re.I)
SHIM = re.compile(r'\bcreate\s+(?:or\s+replace\s+)?function\s+("?)(\w+)\1\s*\.\s*now\s*\(\s*\)', re.I)
# every change of search_path, in order: a `set` naming its first schema, or a `reset` (group 3)
PATH = re.compile(r'^\s*(?:set\s+(?:local\s+)?search_path\s*(?:=|to)\s*("?)(\w+)\1|(reset)\s+search_path)', re.I | re.M)
MARK = re.compile(r'--\s*clock-ok:(.*)$', re.I | re.M)

# A floor on how much of the tree is in scope, so a scanner that has stopped matching fails here rather than
# reporting a clean sweep: 317, 324, 334 and 342 pin their clocks and 124 is marked.
MIN_IN_SCOPE = 5


def check_text(name, text):
    """Return a list of problems for one file (empty when it holds, or is out of scope)."""
    lit = CATCHUP.search(text)
    call = TRANSMUTE.search(text)
    marks = [m.group(1).strip() for m in MARK.finditer(text)]
    if not (lit and call):
        if marks:
            return [f'{name}: carries a `-- clock-ok:` mark but is out of scope (no transmute call with a '
                    f'month-step name literal); drop the stale mark']
        return []
    if marks:
        if any(marks):
            return []
        return [f'{name}: `-- clock-ok:` mark gives no reason']
    shims = {m.group(2).lower() for m in SHIM.finditer(text)}
    line = text.count('\n', 0, lit.start()) + 1
    if not shims:
        return [f'{name}:{line}: names {lit.group(0)!r} after a transmute but never pins now(); define a '
                f'<schema>.now() shim and set search_path to it around the call, or mark `-- clock-ok: <reason>`']
    paths = [(m.start(), None if m.group(3) else m.group(2).lower()) for m in PATH.finditer(text)]
    for c in TRANSMUTE.finditer(text):
        before = [first for at, first in paths if at < c.start()]
        if before and before[-1] in shims:
            return []
    return [f'{name}: defines {", ".join(sorted(s + ".now()" for s in shims))} but no transmute runs under a '
            f'`set search_path = <that schema>, ...`, so every call reads the wall clock']


def in_scope(text):
    return bool(CATCHUP.search(text) and TRANSMUTE.search(text))


def default_files():
    return sorted(p for p in (ROOT / 'tests').rglob('*.sql'))


def selftest():
    # The pre-fix shape of tests/317 (#1425): an October literal after an unpinned transmute.
    unpinned = """
create schema t317;
call pgpm.transmute('t317.b', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select is((select child_name from pgpm.part where parent_table = 't317.b'::regclass order by lo limit 1),
  'b_p2026_01_to_2026_11', 'the monolith');
"""
    shim = "create function t317_clock.now() returns timestamptz language sql immutable as $$ select timestamptz '2026-10-15 12:00:00+00' $$;\n"
    pinned = shim + unpinned.replace("call pgpm", "set search_path = t317_clock, pg_catalog, public;\ncall pgpm", 1)
    # a shim nobody puts on the path is no pin
    shim_off_path = shim + unpinned
    # a path set only AFTER the call pins nothing for it
    path_after = shim + unpinned + "set search_path = t317_clock, pg_catalog, public;\n"
    # a path naming some other schema first
    path_other = shim + unpinned.replace("call pgpm", "set search_path = t317, pg_catalog, public;\ncall pgpm", 1)
    # the quoted, `to` and `local` spellings pin too
    quoted = ('create function "clk".now() returns timestamptz language sql as $$ select now() $$;\n'
              + unpinned.replace("call pgpm", 'set local search_path to "clk", pg_catalog;\ncall pgpm', 1))
    # a reset between the set and the call drops the pin
    reset_between = shim + unpinned.replace("call pgpm", "set search_path = t317_clock, pg_catalog, public;\nreset search_path;\ncall pgpm", 1)
    # an unpinned id-grid call first, then the pinned one (the fixed tests/317)
    id_first = shim + "call pgpm.transmute('t317.a', 'id', 100);\n" + pinned
    marked = "-- clock-ok: the literal is _part_name's output over explicit bounds\n" + unpinned
    mark_no_reason = "-- clock-ok:\n" + unpinned
    # out of scope: a literal with no transmute (tests/42), a transmute with no literal (tests/138)
    no_call = "select is(pgpm._part_name('events','time','1 mon','2015-03-01','2026-07-01','UTC')::text, 'events_p2015_03_to_2026_07', '');\n"
    no_literal = "call pgpm.transmute('t.x', 'ts', interval '1 month');\nselect is(1, 1, '');\n"
    stale_mark = "-- clock-ok: was needed once\n" + no_literal
    cases = [
        ('unpinned (pre-fix 317)', unpinned, False),
        ('pinned (fixed 317)', pinned, True),
        ('shim off the path', shim_off_path, False),
        ('path set after the call', path_after, False),
        ('path names another schema', path_other, False),
        ('reset between set and call', reset_between, False),
        ('unpinned id-grid call, then a pinned one', id_first, True),
        ('quoted / to / local spelling', quoted, True),
        ('marked with a reason', marked, True),
        ('mark with no reason', mark_no_reason, False),
        ('literal, no transmute', no_call, True),
        ('transmute, no literal', no_literal, True),
        ('stale mark', stale_mark, False),
    ]
    bad = 0
    for label, text, want_ok in cases:
        got_ok = not check_text(label, text)
        flag = 'ok' if got_ok == want_ok else 'WRONG'
        if got_ok != want_ok:
            bad += 1
        print(f'  {flag:5} {label}: {"passes" if got_ok else "fails"} (want {"pass" if want_ok else "fail"})')
    n = sum(in_scope(p.read_text()) for p in default_files())
    if n < MIN_IN_SCOPE:
        print(f'  WRONG the tree holds {n} in-scope tests, fewer than {MIN_IN_SCOPE}: the scanner has gone blind')
        bad += 1
    else:
        print(f'  ok    LIVENESS: {n} in-scope tests in the tree (floor {MIN_IN_SCOPE})')
    if bad:
        print(f'selftest FAILED: {bad} case(s) wrong')
        return 1
    print('selftest passed')
    return 0


def main(argv):
    if argv[1:2] == ['--selftest']:
        return selftest()
    files = [pathlib.Path(a) for a in argv[1:]] or default_files()
    problems = []
    for p in files:
        problems += check_text(str(p.relative_to(ROOT) if p.is_absolute() and ROOT in p.parents else p),
                               p.read_text())
    for msg in problems:
        print(msg)
    if problems:
        print(f'test clock check FAILED: {len(problems)} problem(s)')
        return 1
    print(f'test clock check passed ({len(files)} files)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
