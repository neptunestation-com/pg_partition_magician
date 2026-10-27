#!/usr/bin/env python3
"""A statement on a relation or function pgpm identified is locked by oid first, checked by its effect after, or
says why neither is needed. Run by CI (the `By-name statements` lint job) and by test.sh's lint track.

WHY THIS EXISTS (the schema-swap class: #1335 bullet 10, #1355, #1356, #1358, #1362, #1364, #1366, #1367, and the
pass-13 review record's call for a static exhaustiveness check). pgpm reaches the tables and functions it manages
by oid, but a statement names them: `format('alter table %s ...', p_parent)` renders the name the oid has at that
instant, `%I.%I` over a schema and a name read earlier renders an older one. The statement then waits for its
lock, and resolves the NAME again once granted. A lock pins a relation's own name, never its schema's (ALTER
SCHEMA ... RENAME takes no relation lock), so a schema renamed aside, with a namesake schema and object committed
in its place while the statement waited, is what the statement reaches: a stranger's partition detached, a
namesake's rows deleted or copied, an operator's function dropped. Three rounds of per-site fixes each closed the
sites one enumeration named and each was found incomplete by the next review; this check closes the class in the
text, so a new statement of the shape fails CI rather than a review pass.

THE RULE, over pgpm_core/install.sql, pgpm_core/uninstall.sql, pgpm_archive/install.sql and
pgpm_hypertable/install.sql. A BY-NAME STATEMENT is a format() call whose format string is a statement (it begins
with a SQL command word: select, insert, alter, drop, lock, ...; a format() inside a RAISE is a message and is not
one) that splices an OBJECT NAME:

  * a `%I.%I` pair (positional `%1$I.%2$I` too): a schema and a name read earlier;
  * a `%s` whose argument is an oid type rendered as text (`p_parent::text`, `v_oid::regclass::text`, a parameter
    or local declared regclass, regprocedure or regproc), or that follows a relation keyword (`table`, `only`,
    `from`, `into`, `join`, `update`, `on`, `function`, `routine`, `procedure`, `sequence`, `index`, `partition`,
    `truncate`, `analyze`, `exists`, `references`), which is where a `_q` local or a name local lands;

or an EXECUTE of a statement the unit does not spell out (`execute v_tdef`, `execute pgpm._index_ddl(...)`), unless
the local it executes is assigned from a by-name statement's format() in the same unit (judged there).

Each object it names must be one of:

  1. LOCKED BY OID before it, in the same unit: a call of pgpm._lock_oid, pgpm._lock_oid_or_raise or
     pgpm._lock_named_or_raise whose relation argument is the same expression (casts set aside: `p_parent` covers
     `p_parent::text`), or whose vouched schema and name arguments are the `%I.%I` pair; or the local a call of
     pgpm._from_hypertable_lock_copy (the copy, locked by oid) was assigned to. A lock by oid that this
     transaction holds means the statement waits for nothing of that relation, so it resolves the name it was
     rendered under.
  2. CHECKED BY ITS EFFECT after it: a call of pgpm._effect_or_raise or pgpm._con_effect_or_raise between the
     statement and the next by-name statement of the unit (the oid gone after a DROP, the rows deleted from it,
     the constraint on it). A statement that reached a namesake then raises, rolled back.
  3. MARKED: a `-- by-name-ok: <reason>` comment on a line the statement spans, or in the comment block just above it,
     saying why a wait cannot redirect it: the object was created by this transaction and no other session can
     see it; the statement takes no lock and waits for nothing; a lock by oid an earlier statement or the caller
     took holds it (say which); it is self-refusing (what fails, and why that rolls everything back); a read whose
     result cannot move rows; a message or remedy text nothing runs. The reason is the review; a mark with no
     reason fails.

LIMITS, stated rather than hidden. The check reads text, not control flow: a lock call earlier in the unit counts
even on another branch, and an effect call counts wherever it falls before the next by-name statement. A lock's
MODE is not compared with the statement's need. A statement whose name reaches it through a local assigned
elsewhere (`v_from_q`, a fragment built by another format()) is judged by its own placeholders, and the fragment
by its own (it is a statement when it begins with `(select`). The bodies of functions pgpm generates at run time
(the capture triggers' `$pgpm$` templates) are string literals here, and are not read. A static statement (no
format()) names only pgpm's own tables, and is not judged.

Usage:
  ./scripts/check_by_name_after_wait.py               # check the four modules
  ./scripts/check_by_name_after_wait.py <file.sql>... # check other copies (a mutant)
  ./scripts/check_by_name_after_wait.py --list        # every by-name statement and how it is covered
  ./scripts/check_by_name_after_wait.py --selftest    # prove each rule fails when its defect is present
"""
import bisect
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ['pgpm_core/install.sql', 'pgpm_core/uninstall.sql', 'pgpm_archive/install.sql',
         'pgpm_hypertable/install.sql']
MARK = 'by-name-ok:'
SQL_WORDS = {'select', 'insert', 'update', 'delete', 'alter', 'create', 'drop', 'lock', 'truncate', 'comment',
             'grant', 'revoke', 'analyze', 'vacuum', 'refresh', 'with', 'reindex', 'cluster', 'merge', 'copy',
             'call', 'table'}
REL_KEYWORDS = r'(?:table|only|from|into|join|update|on|function|routine|procedure|sequence|index|partition|' \
               r'truncate|analyze|exists|references)'
OID_TYPES = {'regclass', 'regprocedure', 'regproc'}
LOCK_FNS = {'_lock_oid': (3, 4), '_lock_oid_or_raise': None, '_lock_named_or_raise': (3, 4)}
LOCK_RET_FNS = ('_from_hypertable_lock_copy', '_resolve_child')
EFFECT_FNS = ('_effect_or_raise', '_con_effect_or_raise', '_refuse_foreign_read')
# a format() among the arguments of one of these is the text of a message, not a statement
MESSAGE_FNS = tuple(LOCK_FNS) + EFFECT_FNS + ('_nsp_held_or_raise', '_transmute_refuse_names_held')
SPEC_RE = re.compile(r'%(?:(\d+)\$)?-?(?:\d+|\*(?:\d+\$)?)?([sIL%])')
DOLLAR = re.compile(r'(?<![\w$])\$(?:[^\W\d]\w*)?\$')


# ---------------------------------------------------------------------------------------------------- lexing
def lex(text, start=0, end=None, top=False):
    """(masked, literals, comments): masked is text[start:end] with every comment and literal's CONTENT blanked
    (length kept, newlines kept, a literal's place shown by its delimiters), literals is [(a, b, value)] in body
    offsets (a..b the whole literal), comments is [(a, b)]. With top=True, a dollar-quoted string is not a literal
    but a body, and is reported as ('body', a, b) in literals instead (a..b its content)."""
    end = len(text) if end is None else end
    out, lits, coms, nested = [], [], [], []
    i = start
    while i < end:
        c = text[i]
        if c == '-' and text.startswith('--', i):
            j = text.find('\n', i, end)
            j = end if j < 0 else j
            coms.append((i - start, j - start))
            out.append(' ' * (j - i))
            i = j
        elif c == '/' and text.startswith('/*', i):
            depth, j = 0, i
            while j < end:
                if text.startswith('/*', j):
                    depth, j = depth + 1, j + 2
                elif text.startswith('*/', j):
                    depth, j = depth - 1, j + 2
                    if depth == 0:
                        break
                else:
                    j += 1
            coms.append((i - start, j - start))
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        elif c == '"':
            j = i + 1
            while j < end:
                if text[j] == '"':
                    if text.startswith('""', j):
                        j += 2
                        continue
                    break
                j += 1
            out.append(text[i:j + 1])
            i = j + 1
        elif c == "'":
            esc = i > 0 and text[i - 1] in 'eE' and not (i > 1 and re.match(r'[\w$"]', text[i - 2]))
            j, val = i + 1, []
            while j < end:
                if esc and text[j] == '\\' and j + 1 < end:
                    val.append(text[j + 1])
                    j += 2
                    continue
                if text[j] == "'":
                    if text.startswith("''", j):
                        val.append("'")
                        j += 2
                        continue
                    break
                val.append(text[j])
                j += 1
            j = min(j + 1, end)
            lits.append((i - start, j - start, ''.join(val)))
            out.append("'" + re.sub(r'[^\n]', ' ', text[i + 1:j - 1]) + ("'" if j - i > 1 else ''))
            i = j
        elif c == '$' and DOLLAR.match(text, i):
            tag = DOLLAR.match(text, i).group(0)
            k = text.find(tag, i + len(tag), end)
            k = end if k < 0 else k
            j = min(k + len(tag), end)
            if top:
                lits.append(('body', i + len(tag) - start, k - start))
                out.append(text[i:j])
            else:
                lits.append((i - start, j - start, text[i + len(tag):k]))
                nested.append((i - start, i + len(tag) - start, k - start))
                out.append("'" + re.sub(r'[^\n]', ' ', text[i + 1:j - 1]) + "'")
            i = j
        else:
            out.append(c)
            i += 1
    if top:
        return ''.join(out), lits, coms
    return ''.join(out), lits, coms, nested


def matching_paren(masked, op):
    depth = 0
    for i in range(op, len(masked)):
        if masked[i] == '(':
            depth += 1
        elif masked[i] == ')':
            depth -= 1
            if depth == 0:
                return i
    return None


def split_args(masked, a, b):
    """Top-level comma-separated pieces of masked[a:b] as (start, end) spans."""
    out, depth, s = [], 0, a
    for i in range(a, b):
        ch = masked[i]
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        elif ch == ',' and depth == 0:
            out.append((s, i))
            s = i + 1
    out.append((s, b))
    return out


def root(expr):
    """The expression an argument names, casts and parentheses set aside: `(p_parent)::text` is `p_parent`."""
    e = ' '.join(expr.split()).lower()
    while True:
        prev = e
        e = re.sub(r'\s*::\s*"?[a-z_][\w.]*"?(?:\[\])?\s*$', '', e).strip()
        if e.startswith('(') and matching_paren(e, 0) == len(e) - 1:
            e = e[1:-1].strip()
        if e == prev:
            return e


# ---------------------------------------------------------------------------------------------------- one unit
def param_types(header):
    """Map a function's parameter names to their types, from its header text."""
    out = {}
    m = re.search(r'\((.*)\)', header, re.S)
    if not m:
        return out
    depth, cur, parts = 0, [], []
    for ch in m.group(1):
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append(''.join(cur))
    for p in parts:
        w = re.sub(r'(?i)\b(?:in|out|inout|variadic)\s+', '', p.strip(), count=1).split()
        if len(w) >= 2:
            out[w[0].lower()] = w[1].lower().rstrip(',')
    return out


def local_types(masked):
    out = {}
    for m in re.finditer(r'(?is)\bdeclare\b(.*?)\bbegin\b', masked):
        for decl in m.group(1).split(';'):
            d = re.match(r'\s*([a-z_]\w*)\s+(?:constant\s+)?([a-z_][\w.]*)', decl, re.I)
            if d:
                out[d.group(1).lower()] = d.group(2).lower()
    return out


def calls(masked, names):
    """(name, start, [arg spans]) for each call of pgpm.<name>( or <name>( in masked."""
    out = []
    for m in re.finditer(r'(?<![\w$])(?:[a-z_]\w*\s*\.\s*)?(' + '|'.join(re.escape(n) for n in names) + r')\s*\(',
                         masked, re.I):
        op = m.end() - 1
        cp = matching_paren(masked, op)
        if cp is None:
            continue
        out.append((m.group(1).lower(), m.start(), split_args(masked, op + 1, cp)))
    return out


def in_message(masked, pos, message_spans):
    """The position lies in the text of a message: a RAISE, a row of pgpm.log, or the argument of a helper that
    takes one (p_what)."""
    semi = masked.rfind(';', 0, pos)
    if re.search(r'(?i)\braise\b|\binsert\s+into\s+pgpm\s*\.\s*log\b', masked[semi + 1:pos]):
        return True
    return any(a <= pos < b for a, b in message_spans)


def statements(body, masked, lits, types):
    """Every by-name statement of one body: dicts with start, end, objects [(kind, roots)], label."""
    lit_at = sorted((a, b, v) for a, b, v in lits if a != 'body')
    starts = [x[0] for x in lit_at]
    found = []
    fmt_assigned = set()
    message_spans = [(args[0][0], args[-1][1]) for _, _, args in calls(masked, list(MESSAGE_FNS))]
    for m in re.finditer(r'(?<![\w$.])(?:pg_catalog\s*\.\s*)?format\s*\(', masked, re.I):
        op = m.end() - 1
        cp = matching_paren(masked, op)
        if cp is None:
            continue
        args = split_args(masked, op + 1, cp)
        a0 = args[0]
        k = bisect.bisect_left(starts, a0[0])
        pieces = []
        while k < len(lit_at) and lit_at[k][0] < a0[1]:
            pieces.append(lit_at[k][2])
            k += 1
        if not pieces:
            continue
        fmt = ''.join(pieces)
        w = re.match(r'\s*\(?\s*([a-z]+)', fmt.lower())
        if not w or w.group(1) not in SQL_WORDS or in_message(masked, m.start(), message_spans):
            continue
        argtext = [body[a:b] for a, b in args]
        specs, nxt = [], 1
        for s in SPEC_RE.finditer(fmt):
            if s.group(2) == '%':
                continue
            if s.group(1):
                pos = int(s.group(1))
                nxt = pos + 1
            else:
                pos = nxt
                nxt += 1
            specs.append((s.start(), s.end(), s.group(2), pos))
        objs, in_pair = [], set()
        for x, y in zip(specs, specs[1:]):
            if x[2] == 'I' and y[2] == 'I' and fmt[x[1]:y[0]] == '.' and x[0] not in in_pair:
                if x[3] < len(argtext) and y[3] < len(argtext):
                    objs.append(('pair', (root(argtext[x[3]]), root(argtext[y[3]]))))
                in_pair.update({x[0], y[0]})
        for s in specs:
            if s[2] != 's' or s[3] >= len(argtext):
                continue
            arg = argtext[s[3]]
            r = root(arg)
            typed = re.search(r'(?i)::\s*(?:regclass|regprocedure|regproc)\b', arg) or types.get(r) in OID_TYPES
            before = fmt[:s[0]]
            keyword = re.search(r'(?i)\b' + REL_KEYWORDS + r'\s+(?:if\s+exists\s+)?$', before)
            if typed or keyword:
                objs.append(('rel', (r,)))
        if not objs:
            continue
        # the assignment target, when the statement is assigned to a local executed later
        t = re.search(r'(?i)([a-z_]\w*)\s*:=\s*$', masked[max(0, m.start() - 80):m.start()])
        if t:
            fmt_assigned.add(t.group(1).lower())
        found.append({'start': m.start(), 'end': cp + 1, 'objs': objs, 'fmt': fmt,
                      'creates': [o[1] for o in objs if o[0] == 'pair'][:1] if w.group(1) == 'create' else []})
    for m in re.finditer(r'(?i)\bexecute\s+(?!format\b|function\b|procedure\b)', masked):
        semi = masked.find(';', m.end())
        semi = len(masked) if semi < 0 else semi
        expr = masked[m.end():semi]
        expr = re.split(r'(?i)\b(?:into|using)\b', expr)[0]
        code = re.sub(r"'[^']*'", '', expr)
        idents = [x.lower() for x in re.findall(r'[a-z_][\w.]*', code, re.I)
                  if x.lower() not in ('strict',)]
        if not idents:
            continue                                          # literals only: a static statement
        if re.fullmatch(r'\s*([a-z_]\w*)\s*', expr, re.I) and expr.strip().lower() in fmt_assigned:
            continue                                          # judged at its format()
        if re.match(r"(?i)\s*'", expr) and all(x in ('case', 'when', 'then', 'else', 'end', 'quote_ident', 'v_was',
                                                     'none') for x in idents):
            continue
        found.append({'start': m.start(), 'end': semi, 'objs': [('opaque', (root(expr),))],
                      'fmt': 'execute ' + ' '.join(expr.split()), 'creates': []})
    found.sort(key=lambda d: d['start'])
    return found


def unit_name(header):
    m = re.search(r'(?i)(?:function|procedure)\s+([\w.]+)\s*\(', header)
    return m.group(1) if m else 'do-block'


def check_body(body, header, base, line_of, raw_lines, report):
    masked, lits, coms, nested = lex(body)
    bad = []
    for q, a, b in nested:                  # a function created inside this body (uninstall.sql's DO blocks)
        if re.search(r'(?i)\bas\s*$', masked[max(0, q - 40):q]):
            hstart = max(masked.rfind(';', 0, q), 0)
            bad += check_body(body[a:b], body[hstart:q], base + a, line_of, raw_lines, report)
    types = dict(param_types(header))
    types.update(local_types(masked))
    stmts = statements(body, masked, lits, types)
    if not stmts:
        return bad
    comment_text = {}
    for a, b in coms:                       # a mark counts only in a comment, never in a literal
        comment_text[line_of(base + a)] = comment_text.get(line_of(base + a), '') + body[a:b]
    locks = []
    for name, pos, args in calls(masked, list(LOCK_FNS)):
        argt = [root(body[a:b]) for a, b in args]
        cov = {('rel', (argt[0],))}
        pair = LOCK_FNS[name]
        if pair and len(argt) > pair[1]:
            cov.add(('pair', (argt[pair[0]], argt[pair[1]])))
        locks.append((pos, cov))
    for m in re.finditer(r'(?i)([a-z_]\w*)\s*:=\s*(?:[a-z_]\w*\s*\.\s*)?(?:' + '|'.join(LOCK_RET_FNS) + r')\s*\(', masked):
        locks.append((m.start(), {('rel', (m.group(1).lower(),))}))
    # a local assigned the expression a lock was taken by (`v_dest := pgpm._scratch_rel(...)` after a lock of
    # `pgpm._scratch_rel(...)`) names the relation locked
    for m in re.finditer(r'(?i)(?<![\w.])([a-z_]\w*)\s*:=\s*([^;]+);', masked):
        expr = root(body[m.start(2):m.end(2)])
        for pos, cov in list(locks):
            if pos < m.start() and ('rel', (expr,)) in cov:
                locks.append((m.start(), {('rel', (m.group(1).lower(),))}))
    # a schema and a name read off pg_class BY the oid of a relation already locked (`select n.nspname, c.relname into
    # v_nsp, v_rel from pg_class c join pg_namespace n ... where c.oid = v_copy` after a lock of v_copy): the name it
    # has under the lock, which pins it
    for m in re.finditer(r'(?is)\bselect\s+(?:\w+\.)?nspname\s*,\s*(?:\w+\.)?relname\s+into\s+(\w+)\s*,\s*(\w+)\s+'
                         r'from\s+pg_class\s+(\w+)\s+join\s+pg_namespace\s+\w+\s+on\s+[^;]*?\bwhere\s+\3\.oid\s*=\s*([^;]+?)\s*;',
                         masked):
        rel = root(body[m.start(4):m.end(4)])
        if any(pos < m.start() and ('rel', (rel,)) in cov for pos, cov in list(locks)):
            locks.append((m.start(), {('pair', (m.group(1).lower(), m.group(2).lower()))}))
    # a local assigned the relation a CREATE of this unit made (`v_parent := format('%I.%I', v_nsp, v_staging)::regclass`
    # after `create table %I.%I` of that pair): created by this transaction, which holds ACCESS EXCLUSIVE on it
    for st in stmts:
        for pair in st['creates']:
            for m in re.finditer(r'(?i)(?<![\w.])([a-z_]\w*)\s*:=\s*(?:to_regclass\s*\(\s*)?format\s*\(\s*\'%I\.%I\'\s*,'
                                 r'\s*([^,()]+?)\s*,\s*([^,()]+?)\s*\)(?:\s*::\s*regclass|\s*\))', masked):
                if m.start() > st['end'] and (root(m.group(2)), root(m.group(3))) == pair:
                    locks.append((m.start(), {('rel', (m.group(1).lower(),))}))
    effects = [pos for _, pos, _ in calls(masked, list(EFFECT_FNS))]
    for i, st in enumerate(stmts):
        nxt = stmts[i + 1]['start'] if i + 1 < len(stmts) else len(masked)
        effect = any(st['end'] <= p < nxt for p in effects)
        first, last = line_of(base + st['start']), line_of(base + st['end'] - 1)
        # the statement's own first line: the first code after the statement before it (or the block keyword
        # that opens it), so a mark on the line just above it is the statement's, never its neighbour's
        prev = max(masked.rfind(';', 0, st['start']),
                   max((m.end() - 1 for m in re.finditer(r'(?i)\b(?:begin|loop|then|else)\b', masked[:st['start']])),
                       default=-1))
        k = prev + 1
        while k < st['start'] and masked[k].isspace():
            k += 1
        lo = min(first, line_of(base + k))
        top = lo
        while top > 0 and raw_lines[top - 1].strip().startswith('--'):   # the comment block just above it
            top -= 1
        marks = [comment_text[k] for k in range(top, last + 1) if MARK in comment_text.get(k, '')]
        marked = bool(marks)
        reason_ok = all(c.split(MARK, 1)[1].strip() for c in marks)
        uncovered = []
        for obj in st['objs']:
            if effect:
                continue
            if any(p < st['start'] and obj in cov for p, cov in locks):
                continue
            uncovered.append(obj)
        how = 'effect' if effect else ('lock' if not uncovered else ('mark' if marked else 'NONE'))
        report.append((first + 1, how, unit_name(header), st['fmt'][:80].replace('\n', ' '),
                       [o[1] for o in st['objs']], lo + 1))
        if uncovered and not marked:
            bad.append((first + 1, 'by-name statement with no lock by oid before it, no effect check after it '
                                   'and no `-- by-name-ok:` reason: names ' +
                        ', '.join('.'.join(o[1]) for o in uncovered)))
        elif uncovered and not reason_ok:
            bad.append((first + 1, '`-- by-name-ok:` with no reason'))
    return bad


def check_text(text, report=None):
    """The violations in one file's text, as sorted (line, message) pairs."""
    report = [] if report is None else report
    raw_lines = text.split('\n')
    starts = [0]
    for ln in raw_lines[:-1]:
        starts.append(starts[-1] + len(ln) + 1)

    def line_of(pos):
        return bisect.bisect_right(starts, pos) - 1

    _, top, _ = lex(text, top=True)
    bad = []
    for item in top:
        if item[0] != 'body':
            continue
        _, a, b = item
        hstart = max(text.rfind(';', 0, a), 0)
        header = text[hstart:a]
        bad += check_body(text[a:b], header, a, line_of, raw_lines, report)
    return sorted(set(bad))


# ---------------------------------------------------------------------------------------------------- selftest
def unit(body, header='create or replace function pgpm.f(p_parent regclass, p_child regclass) returns void '
                      'language plpgsql as '):
    return header + '$$\ndeclare v_nsp name; v_rel name; v_oid oid;\nbegin\n' + body + '\nend;\n$$;\n'


SELFTEST_BAD = [
    # #1362: the swap's DETACH by names rendered before its wait
    ("regrain swap detach", "  execute format('alter table %s detach partition %s', p_parent::text, p_child::text);"),
    # #1364: transmute_abort's DROP of the bound, by name, nothing checked
    ("abort bound drop", "  execute format('alter table %s drop constraint if exists pgpm_monolith_bound', "
                         "p_parent::text);"),
    # a %I.%I pair read earlier
    ("pair", "  select n.nspname, c.relname into v_nsp, v_rel from pg_class c join pg_namespace n "
             "on n.oid = c.relnamespace where c.oid = p_parent;\n"
             "  execute format('drop table %I.%I', v_nsp, v_rel);"),
    # positional pair
    ("positional pair", "  execute format('alter table %1$I.%2$I owner to %3$I', v_nsp, v_rel, 'x');"),
    # an oid cast in place
    ("oid cast", "  execute format('drop function %s', v_oid::regprocedure::text);"),
    # a name local after a relation keyword
    ("keyword", "  execute format('select count(*) from %s', v_rel_q) into v_n;"),
    # a lock on ANOTHER relation does not cover this one
    ("lock elsewhere", "  perform pgpm._lock_oid_or_raise(p_child, 'access exclusive', true, 'x');\n"
                       "  execute format('truncate %s', p_parent::text);"),
    # a lock AFTER the statement does not cover it
    ("lock after", "  execute format('truncate %s', p_parent::text);\n"
                   "  perform pgpm._lock_oid_or_raise(p_parent, 'access exclusive', true, 'x');"),
    # an effect check after the NEXT statement covers only that one
    ("effect after next", "  execute format('drop table %s', p_child::text);\n"
                          "  execute format('drop table %s', p_parent::text);\n"
                          "  perform pgpm._effect_or_raise(true, p_parent, 'x');"),
    # an EXECUTE of a statement built elsewhere
    ("opaque", "  execute v_tdef;"),
    # a mark with no reason
    ("empty mark", "  execute format('analyze %s', p_parent::text);   -- by-name-ok:"),
    # a dollar-quoted format string
    ("dollar", "  execute format($q$delete from %s where true$q$, p_parent::text);"),
    # a mark in a string literal is not a mark
    ("mark in literal", "  execute format('analyze %s /* -- by-name-ok: no */', p_parent::text);"),
]
SELFTEST_GOOD = [
    ("locked first", "  perform pgpm._lock_oid_or_raise(p_parent, 'access exclusive', true, 'x');\n"
                     "  execute format('alter table %s detach partition %s', p_parent::text, p_parent::text);"),
    ("vouched pair", "  perform pgpm._lock_named_or_raise(p_parent, 'access share', true, v_nsp, v_rel, 'x');\n"
                     "  execute format('select 1 from %I.%I', v_nsp, v_rel);"),
    ("effect", "  execute format('drop function %s', v_oid::regprocedure::text);\n"
               "  perform pgpm._effect_or_raise(not exists (select 1 from pg_proc where oid = v_oid), v_oid, 'x');"),
    ("marked", "  -- by-name-ok: a relation this transaction created; no other session can see it\n"
               "  execute format('analyze %s', p_parent::text);"),
    ("marked inline", "  execute format('analyze %s',   -- by-name-ok: statistics only, a read that moves no row\n"
                      "                 p_parent::text);"),
    ("message", "  raise exception 'x: %', format('alter table %s attach partition %s', p_parent, p_child);"),
    ("literal", "  execute format('select %L::%s', 'x', 'int');"),
    ("pgpm table", "  execute format('select child_name from pgpm.part where parent_table = %L::regclass', "
                   "p_parent::text);"),
    ("static execute", "  execute 'drop table if exists pg_temp.x';"),
    ("judged at format", "  v_stmt := format('drop table %s', p_parent::text);   -- by-name-ok: test\n"
                         "  execute v_stmt;"),
    ("lock copy", "  v_copy := pgpm._from_hypertable_lock_copy(p_parent, 'x');\n"
                  "  execute format('insert into %s select 1', v_copy);"),
]


def selftest():
    failures = 0
    for name, body in SELFTEST_BAD:
        if not check_text(unit(body)):
            print('SELFTEST FAIL: the defect "%s" passed the check' % name)
            failures += 1
    for name, body in SELFTEST_GOOD:
        got = check_text(unit(body))
        if got:
            print('SELFTEST FAIL: the covered shape "%s" was refused: %s' % (name, got))
            failures += 1
    # the four modules must each hold by-name statements: a lexer that stopped reading them would pass empty
    for f in FILES:
        rep = []
        check_text(open(os.path.join(ROOT, f)).read(), rep)
        if not rep:
            print('SELFTEST FAIL: %s: no by-name statement found; the lexer has stopped reading it' % f)
            failures += 1
    if failures:
        return 1
    print('check_by_name_after_wait selftest: PASS (%d defect shapes refused, %d covered shapes accepted)'
          % (len(SELFTEST_BAD), len(SELFTEST_GOOD)))
    return 0


def main(argv):
    if '--selftest' in argv:
        return selftest()
    listing = '--list' in argv
    paths = [a for a in argv if not a.startswith('--')] or [os.path.join(ROOT, f) for f in FILES]
    bad_total = 0
    for p in paths:
        rep = []
        bad = check_text(open(p).read(), rep)
        label = os.path.relpath(p, ROOT) if p.startswith(ROOT) else p
        if listing:
            for line, how, name, fmt, objs, lo in rep:
                print('%s:%d: %-6s %s: %s | %s @%d' % (label, line, how, name, fmt, objs, lo))
        for line, msg in bad:
            print('%s:%d: %s' % (label, line, msg))
        bad_total += len(bad)
    if bad_total:
        print('FAIL: %d by-name statement(s) neither locked by oid, nor checked by effect, nor marked' % bad_total)
        return 1
    print('check_by_name_after_wait: PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
