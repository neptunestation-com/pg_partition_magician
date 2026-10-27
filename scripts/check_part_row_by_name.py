#!/usr/bin/env python3
"""A pgpm.part row's relation is resolved from its NAME in one place: pgpm._part_rel. Run by CI (the `Quoted
splices` lint job) and by test.sh's lint track.

WHY THIS EXISTS (issue #1365 and its PR's six rounds of verification). A pgpm.part row records its child by name
(child_name) and, since #421, by oid (child_oid). Every step that resolved the NAME to a relation (with
to_regclass, a ::regclass cast of a rendered name, or a pg_class join on relname) reached whatever held the name:
on a row with no recorded oid (an install older than #421) that was an operator's table under the same name,
attached to the parent over another range, and retire(), the write block and regrain() each dropped or blocked it.
The rounds closed one site at a time (retire()'s referenced path, the in-flight check, the backfill, _child_nsp,
retire()'s one-step path, the write block, the install pass, regrain's source); this check closes the class in the
text. pgpm._part_rel is the one resolver: by name for an anchored row (the identity checks compare that with
child_oid), and for an unanchored one only a relation that is not a partition of the parent over another range
than the row's.

THE RULE, over pgpm_core/install.sql, pgpm_core/uninstall.sql, pgpm_archive/install.sql and
pgpm_hypertable/install.sql: outside the body of pgpm._part_rel, nothing resolves a row's child name to a relation.
A child name is an identifier `child_name` or `p_child`, however qualified (`r.child_name`, `p.child_name`). A
resolution is any of:

  1. to_regclass(format('%I.%I', <schema>, <child name>)), in plain or in dynamic SQL (''%%I.%%I'');
  2. format('%I.%I', <schema>, <child name>)::regclass;
  3. a comparison of relname with a child name (`c.relname = p.child_name`, either side);
  4. DDL run on one: execute format('... %I.%I ...', <schema>, <child name>), which the server resolves by the name.

A site that resolves a child name on purpose says why, on the line the resolution starts or ends on, in a comment
that begins `part-row-by-name:` (a step that reports the stranger _part_rel withholds, a row that has no range to
check). The reason is the review; a site with no reason fails.

Usage:
  ./scripts/check_part_row_by_name.py               # check the four modules
  ./scripts/check_part_row_by_name.py <file.sql>... # check other copies (a mutant)
  ./scripts/check_part_row_by_name.py --selftest    # prove each rule fails when its defect is present
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ['pgpm_core/install.sql', 'pgpm_core/uninstall.sql', 'pgpm_archive/install.sql', 'pgpm_hypertable/install.sql']
MARK = 'part-row-by-name:'
RESOLVER_RE = re.compile(r'create or replace function pgpm\._part_rel\(.*?\n\$\$;', re.S)

CHILD = r'(?:\w+\.)?(?:child_name|p_child)\b'
# a stretch of one statement that opens no other format()/to_regclass() call
SAME = r"(?:(?!format\s*\(|to_regclass\s*\(|;).)*?"
FMT = r"format\s*\(\s*'+%+I\.%+I'+\s*,"
RULES = [
    ('to_regclass over a rendered child name', re.compile(r'to_regclass\s*\(\s*' + FMT + SAME + r',\s*' + CHILD + r'\s*\)', re.S | re.I)),
    ('a rendered child name cast to regclass', re.compile(FMT + SAME + r',\s*' + CHILD + r'\s*\)\s*::\s*regclass', re.S | re.I)),
    ('relname compared with a child name', re.compile(r'\brelname\s*=\s*' + CHILD + r'|' + CHILD + r'\s*=\s*(?:\w+\.)?relname\b', re.I)),
    ('DDL run on a rendered child name', re.compile(r"execute\s+format\s*\(\s*'(?:[^']|'')*%I\.%I(?:[^']|'')*'(?:\s*\|\|\s*'(?:[^']|'')*')*\s*,\s*[^,;]+,\s*" + CHILD, re.S | re.I)),
]


def check_text(text):
    """The unmarked resolutions in text, as (line, rule) pairs."""
    spans = [(m.start(), m.end()) for m in RESOLVER_RE.finditer(text)]
    lines = text.split('\n')
    starts = [0]
    for ln in lines[:-1]:
        starts.append(starts[-1] + len(ln) + 1)

    def line_of(pos):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo

    bad = []
    for name, rx in RULES:
        for m in rx.finditer(text):
            if any(a <= m.start() < b for a, b in spans):
                continue
            first, last = line_of(m.start()), line_of(m.end() - 1)
            # a match inside a comment is no code
            if lines[first].lstrip().startswith('--'):
                continue
            if any(MARK in lines[i] for i in range(first, last + 1)):
                continue
            bad.append((first + 1, name))
    return sorted(set(bad))


SELFTEST_BAD = [
    # the regrain source before round 7 (#1365): an unanchored row's name in its schema, no range
    "              else to_regclass(format('%I.%I', pgpm._child_nsp(p_parent, p_child), p_child)) end\n",
    # retire()'s referenced path before #1365
    "    select i.inhrelid into v_child\n      from pg_inherits i join pg_class c on c.oid = i.inhrelid\n     where i.inhparent = p_parent and c.relname = p_child;\n",
    # the write block's cast
    "  v_child := format('%I.%I', v_nsp, p_child)::regclass;\n",
    # dynamic SQL in a ledger reader
    "    'and to_regclass(format(''%%I.%%I'', pgpm._child_nsp(l.parent_table, l.child_name), l.child_name)) is null'\n",
    # relname on the right
    "      join pg_class k on p.child_name = k.relname\n",
    # DDL by the name, the write block's CREATE TRIGGER before round 7
    "  execute format(\n    'create trigger pgpm_write_block before insert on %I.%I'\n    || ' for each row execute function f()', v_nsp, p_child);\n",
    "        execute format('alter table %I.%I drop constraint %I', v_nsp, r.child_name, v_check);\n",
]
SELFTEST_OK = [
    # through the resolver
    "  v_now := pgpm._part_rel(p_parent, p_child);\n",
    # a reason on the line
    "  v_now := to_regclass(format('%I.%I', v_nsp, p_child));   -- part-row-by-name: reports the stranger\n",
    # a name rendered into a message, no resolution
    "    raise exception 'x %', format('%I.%I', v_nsp, p_child);\n",
    # another name than a child's
    "  v_taken := to_regclass(format('%I.%I', v_nsp, v_delta));\n",
    # DDL on the resolved relation
    "  execute format('alter table %s enable always trigger pgpm_write_block', v_child);\n",
    # a comment that quotes the old shape
    "  -- to_regclass(format('%I.%I', v_nsp, p_child)) was the old shape\n",
    # the resolver itself
    "create or replace function pgpm._part_rel(p_parent regclass, p_child name)\nreturns regclass language sql stable as $$\n"
    "  select to_regclass(format('%I.%I', pgpm._child_nsp(p_parent, p_child), p_child));\n$$;\n",
]


def selftest():
    ok = True
    for t in SELFTEST_BAD:
        if not check_text(t):
            print('FAIL  selftest: a resolution was not seen:\n' + t)
            ok = False
    for t in SELFTEST_OK:
        if check_text(t):
            print('FAIL  selftest: a clean line was refused:\n' + t)
            ok = False
    # and the real modules: a floor, so a recogniser that stopped matching cannot pass as a clean sweep
    marked = 0
    for f in FILES:
        p = os.path.join(ROOT, f)
        if os.path.exists(p):
            marked += open(p).read().count(MARK)
    if marked < 1:
        print('FAIL  selftest: no marked site in the modules, so the recogniser has nothing real to read')
        ok = False
    print('selftest: ' + ('PASS (every rule fails against its defect, and no clean shape is refused)' if ok else 'FAIL'))
    return 0 if ok else 1


def main(argv):
    if argv[1:] == ['--selftest']:
        return selftest()
    files = argv[1:] or [os.path.join(ROOT, f) for f in FILES]
    bad = []
    n = 0
    for f in files:
        text = open(f).read()
        n += 1
        for line, rule in check_text(text):
            bad.append((f, line, rule))
    if bad:
        for f, line, rule in bad:
            print('FAIL  %s:%d: %s outside pgpm._part_rel, with no `%s` reason' % (os.path.relpath(f, ROOT), line, rule, MARK))
        print('A pgpm.part row\'s relation is resolved from its name by pgpm._part_rel alone (#1365): route the site '
              'through it, or say on the line why it resolves the name itself.')
        return 1
    print('PASS  no pgpm.part row is resolved by its name outside pgpm._part_rel (%d file(s))' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
