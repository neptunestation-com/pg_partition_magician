#!/usr/bin/env python3
"""A pgpm.part row's relation is resolved from its NAME in one place: pgpm._part_rel. Run by CI (the `Quoted
splices` lint job) and by test.sh's lint track.

WHY THIS EXISTS (issue #1365 and its PR's rounds of verification). A pgpm.part row records its child by name
(child_name) and, since #421, by oid (child_oid). Every step that resolved the NAME to a relation (with
to_regclass, a ::regclass cast of a rendered name, a pg_class join on relname, or a statement run on the rendered
name) reached whatever held the name: on a row with no recorded oid (an install older than #421) that was an
operator's table under the same name, attached to the parent over another range, and retire(), the write block and
regrain() each dropped or blocked it. The rounds closed one site at a time; this check closes the class in the
text. pgpm._part_rel is the one resolver: by name for an anchored row (the identity checks compare that with
child_oid), and for an unanchored one only a relation that is not a partition of the parent, at any level, over
another range than the row's.

THE RULE, over pgpm_core/install.sql, pgpm_core/uninstall.sql, pgpm_archive/install.sql and
pgpm_hypertable/install.sql: outside the body of pgpm._part_rel, nothing resolves a row's child name to a relation.

A CHILD NAME is an identifier `child_name` (however qualified: `r.child_name`, `p.child_name`) or `p_child`, and a
local of the same function that holds one: assigned it whole (`v_name := r.child_name`, through a cast or as the
first argument of coalesce()), or selected into it (`select p.child_name into v_name`, `select a, child_name into
v_a, v_name`, the item matched to its INTO target by position).

A RESOLUTION is any of:
  1. a format() call whose format string renders `<schema>.<child name>` (two identifier specifiers joined by a
     dot, `%I.%I` or positional `%1$I.%2$I`, the child name the argument the second one takes, at any position in
     the argument list) when the string is a bare qualified name (`%I.%I` alone: what to_regclass, a ::regclass
     cast or a later statement resolves) or a statement (it begins with a SQL command word: select, alter,
     create, drop, lock, ...). A string that begins with other words renders a message, and is not one;
  2. the same in dynamic SQL, doubled quotes (`to_regclass(format(''%%I.%%I'', ...))`);
  3. a name joined by hand: `'.' || quote_ident(<child name>)`;
  4. a comparison of relname with a child name (`c.relname = p.child_name`, either side).

A site that resolves a child name on purpose says why, on a line the resolution spans, in a comment that begins
`part-row-by-name:` (a step that reports the stranger _part_rel withholds, a message, a copy minted under the name).
The reason is the review; a site with no reason fails.

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
UNIT_RE = re.compile(r'(?im)^create or replace (?:function|procedure)\b')
BASE_CHILD = r'(?:\w+\.)?(?:child_name|p_child)'
SQL_WORDS = ('select', 'insert', 'update', 'delete', 'alter', 'create', 'drop', 'lock', 'truncate', 'comment',
             'grant', 'revoke', 'analyze', 'vacuum', 'refresh', 'with', 'reindex', 'cluster')
SPEC_RE = re.compile(r'%(?:(\d+)\$)?-?(?:\d+|\*(?:\d+\$)?)?([sIL%])')


def child_names(unit):
    """The child names of one function: the base identifiers and the locals that hold one."""
    names = {'child_name', 'p_child'}
    base = r'(?:\w+\.)?(?:%s)' % '|'.join(sorted(names))
    changed = True
    while changed:
        changed = False
        alts = '|'.join(re.escape(n) for n in sorted(names))
        whole = r'(?:\w+\.)?(?:%s)\b(?:\s*::\s*\w+)?' % alts
        # v := <child name>;  v := coalesce(<child name>, ...)
        for m in re.finditer(r'(?im)\b(\w+)\s*:=\s*(?:coalesce\s*\(\s*)?(' + whole + r')\s*[;,)]', unit):
            if m.group(1).lower() not in names:
                names.add(m.group(1).lower())
                changed = True
        # select <items> into <targets>
        for m in re.finditer(r'(?is)\bselect\s+(.*?)\s+into\s+(?:strict\s+)?(.*?)\s+(?:from|where|;)', unit):
            items = split_top(m.group(1))
            targets = [t.strip().lower() for t in split_top(m.group(2))]
            for i, it in enumerate(items):
                if re.fullmatch(whole + r'(?:\s+(?:as\s+)?\w+)?', it.strip(), re.I) and i < len(targets):
                    t = targets[i]
                    if re.fullmatch(r'\w+', t) and t not in names:
                        names.add(t)
                        changed = True
    return names


def split_top(s):
    """Split on commas outside parentheses and quotes."""
    out, depth, cur, q = [], 0, [], False
    i = 0
    while i < len(s):
        ch = s[i]
        if q:
            cur.append(ch)
            if ch == "'":
                if i + 1 < len(s) and s[i + 1] == "'":
                    cur.append("'")
                    i += 1
                else:
                    q = False
        elif ch == "'":
            q = True
            cur.append(ch)
        elif ch == '(':
            depth += 1
            cur.append(ch)
        elif ch == ')':
            depth -= 1
            cur.append(ch)
        elif ch == ',' and depth == 0:
            out.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    out.append(''.join(cur))
    return out


def call_args(text, open_paren):
    """The argument text of the call whose '(' is at open_paren, and the index just past its ')'."""
    depth, q, i = 0, False, open_paren
    while i < len(text):
        ch = text[i]
        if q:
            if ch == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    i += 1
                else:
                    q = False
        elif ch == "'":
            q = True
        elif ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:i], i + 1
        elif ch == ';' and depth <= 1:
            return None, i
        i += 1
    return None, i


def literal_text(expr):
    """The text of the string literals an expression concatenates, or None when it has none."""
    parts = re.findall(r"'((?:[^']|'')*)'", expr)
    if not parts:
        return None
    return ''.join(p.replace("''", "'") for p in parts)


def qualified_child_args(fmt):
    """The 1-based argument positions the second identifier of each `%I.%I` pair in fmt takes."""
    specs, nxt = [], 1
    for m in SPEC_RE.finditer(fmt):
        if m.group(2) == '%':
            continue
        if m.group(1):
            pos = int(m.group(1))
            nxt = pos + 1
        else:
            pos = nxt
            nxt += 1
        specs.append((m.start(), m.end(), m.group(2), pos))
    out = []
    for a, b in zip(specs, specs[1:]):
        if a[2] == 'I' and b[2] == 'I' and fmt[a[1]:b[0]] == '.':
            out.append(b[3])
    return out


def is_resolution_string(fmt):
    f = fmt.strip()
    if re.fullmatch(r'(?:%(?:\d+\$)?I\.)%(?:\d+\$)?I', f):
        return True
    w = re.match(r'[a-z]+', f.lower())
    return bool(w) and w.group(0) in SQL_WORDS


def check_unit(unit, base_line, lines, resolver_spans, offset):
    names = child_names(unit)
    alts = '|'.join(re.escape(n) for n in sorted(names))
    child_re = re.compile(r'^\s*(?:\w+\.)?(?:%s)\b(?:\s*::\s*\w+)?\s*$' % alts, re.I)
    found = []
    # rule 1: format() renders <schema>.<child name> as a name or a statement
    for m in re.finditer(r'(?<![\w.])format\s*\(', unit, re.I):
        args_text, end = call_args(unit, m.end() - 1)
        if args_text is None:
            continue
        args = split_top(args_text)
        fmt = literal_text(args[0])
        if fmt is None or not is_resolution_string(fmt):
            continue
        for pos in qualified_child_args(fmt):
            if pos < len(args) and child_re.match(args[pos]):
                found.append((m.start(), end, 'a rendered child name resolved (format)'))
    # rule 2: dynamic SQL, doubled quotes
    for m in re.finditer(r"to_regclass\s*\(\s*format\s*\(\s*''%%I\.%%I''\s*,(?:(?!format\s*\(|;).)*?,\s*(?:\w+\.)?(?:"
                         + alts + r")\s*\)", unit, re.S | re.I):
        found.append((m.start(), m.end(), 'a rendered child name resolved (dynamic SQL)'))
    # rule 3: a name joined by hand
    for m in re.finditer(r"'\.'\s*\|\|\s*quote_ident\s*\(\s*(?:\w+\.)?(?:" + alts + r")\s*\)", unit, re.I):
        found.append((m.start(), m.end(), "a child name joined to a schema by hand ('.' || quote_ident)"))
    # rule 4: relname compared with a child name
    for m in re.finditer(r'\brelname\s*=\s*(?:\w+\.)?(?:' + alts + r')\b|(?:\w+\.)?(?:' + alts
                         + r')\s*=\s*(?:\w+\.)?relname\b', unit, re.I):
        found.append((m.start(), m.end(), 'relname compared with a child name'))
    bad = []
    for a, b, rule in found:
        ga, gb = offset + a, offset + b
        if any(x <= ga < y for x, y in resolver_spans):
            continue
        first, last = line_of(lines, ga), line_of(lines, gb - 1)
        if lines[0][first].lstrip().startswith('--'):
            continue
        if any(MARK in lines[0][i] for i in range(first, last + 1)):
            continue
        bad.append((first + 1, rule))
    return bad


def line_of(lines, pos):
    starts = lines[1]
    lo, hi = 0, len(starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if starts[mid] <= pos:
            lo = mid
        else:
            hi = mid - 1
    return lo


def strip_comments(text):
    """The text with each -- comment blanked (same length), outside string literals, so code is read, not prose."""
    out, i, q = list(text), 0, False
    while i < len(text):
        ch = text[i]
        if q:
            if ch == "'":
                q = False
        elif ch == "'":
            q = True
        elif ch == '-' and text.startswith('--', i):
            j = text.find('\n', i)
            j = len(text) if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        elif ch == '\n':
            q = False   # a quote never spans a line in these modules' code; resynchronise on a stray one
        i += 1
    return ''.join(out)


def check_text(text):
    """The unmarked resolutions in text, as (line, rule) pairs."""
    raw_lines = text.split('\n')
    starts = [0]
    for ln in raw_lines[:-1]:
        starts.append(starts[-1] + len(ln) + 1)
    lines = (raw_lines, starts)
    code = strip_comments(text)
    spans = [(m.start(), m.end()) for m in RESOLVER_RE.finditer(text)]
    bounds = [m.start() for m in UNIT_RE.finditer(code)] + [len(code)]
    units = [(0, bounds[0])] + list(zip(bounds, bounds[1:]))
    bad = []
    for a, b in units:
        bad += check_unit(code[a:b], line_of(lines, a), lines, spans, a)
    return sorted(set(bad))


SELFTEST_BAD = [
    # the regrain source before round 7 (#1365)
    "              else to_regclass(format('%I.%I', pgpm._child_nsp(p_parent, p_child), p_child)) end\n",
    # retire()'s referenced path before #1365
    "    select i.inhrelid into v_child\n      from pg_inherits i join pg_class c on c.oid = i.inhrelid\n     where i.inhparent = p_parent and c.relname = p_child;\n",
    # the write block's cast
    "  v_child := format('%I.%I', v_nsp, p_child)::regclass;\n",
    # dynamic SQL in a ledger reader
    "    'and to_regclass(format(''%%I.%%I'', pgpm._child_nsp(l.parent_table, l.child_name), l.child_name)) is null'\n",
    # relname on the right
    "      join pg_class k on p.child_name = k.relname\n",
    # DDL by the name
    "  execute format(\n    'create trigger pgpm_write_block before insert on %I.%I'\n    || ' for each row execute function f()', v_nsp, p_child);\n",
    # round 7's misses: the pair at a later argument position (_next_archive_chunk, _retain_recall's ATTACH)
    "  execute format('select %s from %I.%I t where t.%I > %L order by t.%I asc limit 1',\n"
    "                 v_cval_q, v_nsp, p_child, cfg.control_column, v_probe_hi_col, cfg.control_column)\n    into v_next;\n",
    "      execute format('alter table %s attach partition %I.%I for values from (%L) to (%L)',\n"
    "                     p_parent::text, v_nsp, r.child_name, v_lo, v_hi);\n",
    # positional specifiers
    "  v_now := to_regclass(format('%1$I.%2$I', v_nsp, p_child));\n",
    "  v_child := format('%1$I.%2$I', v_nsp, p_child)::regclass;\n",
    # a name joined by hand
    "  v_now := to_regclass(quote_ident(v_nsp) || '.' || quote_ident(r.child_name));\n",
    "  v_child := (quote_ident(v_nsp) || '.' || quote_ident(p_child))::regclass;\n",
    # the child name through a local
    "  v_name := r.child_name;\n  v_now := to_regclass(format('%I.%I', v_nsp, v_name));\n",
    "  v_name := p_child;\n    select i.inhrelid into v_child\n      from pg_inherits i join pg_class c on c.oid = i.inhrelid\n"
    "     where i.inhparent = p_parent and c.relname = v_name;\n",
    "    select p.child_name into v_sub_name from pgpm.part p where p.parent_table = p_parent;\n"
    "    v_sub_now := to_regclass(format('%I.%I', v_sub_nsp, v_sub_name));\n",
    # a statement held in a local, run later
    "  v_sql := format('drop table if exists %I.%I', v_nsp, p_child);\n  execute v_sql;\n",
]
SELFTEST_OK = [
    "  v_now := pgpm._part_rel(p_parent, p_child);\n",
    "  v_now := to_regclass(format('%I.%I', v_nsp, p_child));   -- part-row-by-name: reports the stranger\n",
    # a message
    "    raise exception 'x %', format('retire() found %I.%I detached', v_nsp, p_child);\n",
    "      values (p_parent, 'retain_disown', format('%I.%I is oid %s now', v_nsp, p_child, v_oid));\n",
    # another name than a child's
    "  v_taken := to_regclass(format('%I.%I', v_nsp, v_delta));\n",
    "  execute format('select %s from %I.%I t', v_cols_q, v_nsp, v_rel);\n",
    # a comment that quotes the old shape
    "  -- to_regclass(format('%I.%I', v_nsp, p_child)) was the old shape\n",
    # DDL on the resolved relation
    "  execute format('alter table %s enable always trigger pgpm_write_block', v_child);\n",
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
            print('FAIL  selftest: a clean shape was refused:\n' + t)
            ok = False
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
    for f in files:
        for line, rule in check_text(open(f).read()):
            bad.append((f, line, rule))
    if bad:
        for f, line, rule in bad:
            print('FAIL  %s:%d: %s outside pgpm._part_rel, with no `%s` reason' % (os.path.relpath(f, ROOT), line, rule, MARK))
        print('A pgpm.part row\'s relation is resolved from its name by pgpm._part_rel alone (#1365): route the site '
              'through it, or say on the line why it resolves the name itself.')
        return 1
    print('PASS  no pgpm.part row is resolved by its name outside pgpm._part_rel (%d file(s))' % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
