#!/usr/bin/env python3
"""Every archive object key is assembled in ONE function, the one that claims it. Run by CI (the
`Archive object keys` lint job).

WHY THIS EXISTS (issue #872, bullet 5; the class of #551, #711 and #822). pgpm_archive writes objects
from four functions (the two archive_fn transports and the two synchronous exports), and the key each
one PUTs used to be assembled in two places: archive._object_key for the automatic chunks and
archive._child_object_key for the exports. #822 gave the first an owner (archive.object_key_owner,
so a relation that takes a dropped one's name gets its oid in the key instead of PUTting over the
dropped one's only copy) and left the second keyed by name alone, so the exports kept the defect the
chunks had lost. Each fix closed the site it was found at; the next reading found the class at the
next site. The lever is one function that assembles every key and takes the claim in the same breath
(archive._owned_key), and this check is what keeps it one: a key assembled anywhere else fails CI
before it can PUT over anything.

WHAT COUNTS AS ASSEMBLING A KEY. Every key starts with the configured prefix, archive.config.prefix,
and the check follows that value rather than a spelling of it (#914: the rule this replaces knew the
prefix only by the names `prefix` and `p_prefix` beside `||`, so a scalar subquery or a helper whose
parameter had another name assembled a second key it passed). A PREFIX REFERENCE is

  * the column, however qualified and however quoted (`prefix`, `cfg.prefix`, `excluded.prefix`,
    `cfg."prefix"`, `archive.config.prefix`), or `p_prefix`. Identifiers are compared as the names they
    denote, not as spelled (#1094: the lexer kept a double-quoted part's quotes, so `cfg."prefix"`, the
    same column, was no prefix reference at all and a second key built from it passed);
  * a parameter of a function this file defines, whatever its name, when some call in the file hands
    that parameter a prefix reference (by position or by name). That is a fixed point: a parameter
    that carries it can hand it on to the next function's parameter. The parameter is the value, not
    one spelling of it (#1279: a helper handed the prefix by position and reading it as `$1`, the only
    name a nameless parameter has, assembled a second key this check passed): its name, its name
    behind the function's (`_join.p_base`) and its number (`$n`) are all it. A `$n` inside a literal
    EXECUTE runs is that EXECUTE's USING argument, not the function's parameter;
  * a scalar subquery that selects one (`(select prefix from archive.config where ...)`), where the
    subquery stands;
  * the column read out of a row value by its name (#1181: `(to_jsonb(cfg) ->> 'prefix') || p_child`, the
    same configured prefix as `cfg.prefix`, assembled a second key this check passed). A literal that names
    the column as data (`'prefix'`, a path `'{prefix}'`, a jsonpath `'$.prefix'`) is a prefix reference, and
    the reference is the whole read: `j ->> 'prefix'` and the other field operators (`->`, `#>`, `#>>`)
    from the value they read on, `j['prefix']`, and a `json[b]_extract_path[_text](j, 'prefix')` call. A
    literal naming the column is read as the column wherever it stands, so `format('%s', 'prefix')` is
    refused as `format('%s', cfg.prefix)` is; a message names it as an argument of RAISE, or another way.

A reference is the whole value it stands for: parentheses that only group it (`(cfg.prefix) || x`), a cast
or a field read after it, and the parenthesised row a field is selected from (`(cfg).prefix`) are part of it.

Dynamic SQL is code (#1001: `execute 'select prefix from archive.config ...' into v` read the prefix
inside a literal the lexer kept opaque, so a second key built from `v` passed). Every single-quoted
literal in an EXECUTE's command (up to its INTO, USING or LOOP, format() arguments included) is lexed as
the SQL it is, in place, and so is every literal assigned to a local that some EXECUTE of the same body
runs by name (`v_sql := '...'; execute v_sql`). Every other literal stays one opaque token: `raise notice
'cfg.prefix || x'` and the `'uploads=&prefix='` of a query string are text, not code.

A prefix reference is ASSEMBLY when it

  * touches `||` on either side,
  * is assigned (`v := cfg.prefix`, `v text = cfg.prefix` in a DECLARE, `select prefix into v`,
    `v text default ...`), returned (`return cfg.prefix`) or selected out as a column (`for r in select
    prefix ...`, a SQL function's result), any of which would let the value travel under another name,
  * is an argument of a call to anything this file does not define (`format`, `concat`, `coalesce`,
    `replace`, `unnest`, a pgpm_core function ...), in a FROM clause as anywhere else: a function this
    file defines is followed instead, through the parameter that receives it, since its own body is
    checked by the same rule. That takes a body this check reads, a dollar-quoted one: a function
    defined with a single-quoted body (`as 'select $1 || $2'`) or a SQL-standard one (`return ...`,
    `begin atomic`) is not followed, and handing it the prefix is assembly; or
  * stands anywhere WHAT A PREFIX MAY DO does not name.

WHAT A PREFIX MAY DO (#1279). The first three rules each name a way the value gets out, and each pass
of review found the next way: bound to an EXECUTE as a USING argument (`execute 'select $1 || $2' using
cfg.prefix, p_name`), or renamed by a FROM item (`from unnest(array[cfg.prefix]) as u(p)`, `from (values
(cfg.prefix)) as u(p)`, `from (select prefix as p from archive.config) c`), each a second key this
check passed. So the last rule is the inverse one: a prefix reference that is not assembly by the first
three rules is assembly anyway, UNLESS it is

  * declared (`p_prefix text`, a column's definition, a function's header), or the target of an
    assignment or the label of a named argument (`p_prefix => x`);
  * handed whole, as one argument, to a function this file defines (`archive._owned_key(p_parent,
    cfg.prefix, ...)`), which is how it reaches the one function that assembles;
  * compared or tested: it touches a comparison operator (`=`, `<>`, `<`, `~`, ...), is followed by IS,
    IN, LIKE, BETWEEN or one of their NOT forms, or follows LIKE, IS [NOT] DISTINCT FROM, EXISTS, or a
    comparison's ANY, ALL or SOME (`x = any (...)`). `prefix = excluded.prefix` in an upsert's SET is
    this too, and so is any `col = <prefix>` of an UPDATE's;
  * stored or named as a column: an item of an INSERT's column list or of a row of its VALUES
    (archive.configure's upsert), or of the column list of a key (`primary key (...)`, `unique (...)`,
    `references t (...)`, `on conflict (...)`);
  * reported: an argument of a RAISE; or
  * the select item of a subquery, which is then the reference, judged where it stands by this list.

A bare literal naming the column (`'prefix'` standing alone, not a field read through it) keeps to the
first three rules, since a name as data stands where a value cannot (a list of column names). So does a
statement outside any body that only defines (ALTER, COMMENT, GRANT, REVOKE, DROP), where the column
stands however the definition needs. Everything else at top level is judged as a body is. The rule names
no site and has no exceptions; an allowlist is the thing that rots (CLAUDE.md, on `_q`).

THE CHECK. Exactly one function of pgpm_archive/install.sql assembles a prefix, and that function
references archive.object_key_owner, the claim. Two assembling functions fail (the shape main had
before #872: _object_key and _child_object_key each built their own), as does assembly in a DO block
or at top level, an assembling function that never claims, and no assembly at all (a lexer that has
stopped seeing the file must not report a clean sweep of nothing).

What this cannot see, and tests/archive/db/39 does: a key built with no prefix at all, or a PUT that
ignores the key it was given. That file takes every path that writes an object through a namesake and
asserts the first relation's object survives by key and content, and its Part 0 enumerates every S3
write the installed module makes and requires the key each one gets to come from a key helper. Nor does
this see dynamic SQL whose text is not a literal it can read where EXECUTE runs it: a statement selected
INTO a local, returned by another function, or spelled in pieces that only name the prefix once
concatenated (`'select pre' || 'fix'`). And it cannot see a row read without the column's name: a field
picked by position or out of the row's text (`split_part(cfg::text, ',', 2)`), a row walked as key-value
pairs (`jsonb_each_text(to_jsonb(cfg))`), a column renamed by a table alias's column list (`from
archive.config as c(a, b)`), or a field name computed at run time (`j ->> ('pre' || 'fix')`).
Nor does it read a body that is not dollar-quoted as a body: a single-quoted one is one opaque literal, so
a prefix it reads from archive.config itself is not seen at all, and a SQL-standard one is top-level text
in which its parameters are not followed. (A prefix HANDED to such a function is refused where it is
handed.) And what a prefix may do is judged by the tokens beside it, not by types: a prefix stored (an
INSERT, a SET) in a table other than archive.config and read back under that column's name is not
followed, nor is one raised and read back out of the error (GET STACKED DIAGNOSTICS).

  ./scripts/check_archive_object_keys.py              # check pgpm_archive/install.sql
  ./scripts/check_archive_object_keys.py <file.sql>   # check another copy (a mutant, an old release)
  ./scripts/check_archive_object_keys.py --selftest   # prove each check fails when its defect is present
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = "pgpm_archive/install.sql"

# The names a key prefix goes by in this file: the column and the parameter that carries it, matched on
# the canonical() token, so behind any qualifier, quoted or not, and however many parts it has.
PREFIX_NAME = re.compile(r'^(?:(?:[a-z_][a-z0-9_$]*|"(?:[^"]|"")*")\.)*(?:p_)?prefix$')
CLAIM_TABLE = "archive.object_key_owner"
# A prefix reference followed by one of these is a declaration (a parameter, a column, a local).
TYPE_WORDS = {"text", "varchar", "character", "name"}
# Words that open a parenthesis without being a call.
NOT_CALLS = {
    "values", "in", "select", "and", "or", "not", "when", "then", "else", "as", "on", "over", "filter",
    "using", "returning", "exists", "any", "all", "row", "conflict", "set", "if", "elsif", "while",
    "case", "where", "with", "by", "return", "is", "from", "join", "into", "table", "array", "do",
    "update", "references", "primary", "key", "unique", "check", "default", "perform", "query",
}
# A relation name before `(` (a column list), not a call. FROM and JOIN are not here (#1279): a name
# before `(` in a FROM clause is a function called there, and what it is handed is an argument.
RELATION_BEFORE = {"into", "table", "update", "references"}
# Parameter modes, before a parameter's name.
PARAM_MODES = {"in", "out", "inout", "variadic"}
# The words that open a clause of a statement; a prefix read while the clause is `select` is a column.
CLAUSE_WORDS = {"select", "from", "where", "into", "values", "set", "group", "order", "having",
                "returning", "limit", "offset", "union", "intersect", "except"}
# What may follow a select-list item that is more than the item itself (a comparison, a test).
NOT_BARE = {"is", "like", "ilike", "in", "not", "between", "similar", "and", "or", "collate", "isnull",
            "notnull", "escape", "over", "filter", "within", "at"}
# The tokens a plpgsql statement can start after, for `x = value` read as an assignment.
STATEMENT_STARTS = {";", "begin", "then", "else", "loop", "declare"}
# What a prefix may touch and be compared rather than carried (WHAT A PREFIX MAY DO): a comparison
# operator on either side, as the lexer splits it, or one of these words after it or before it.
COMPARISON_OPS = {"=", "<>", "!=", "<", ">", "<=", ">=", "~", "!"}
TESTED_BY = {"is", "in", "like", "ilike", "between", "similar", "not", "isnull", "notnull"}
TESTED_AFTER = {"like", "ilike", "exists"}
# ... or one of these when a comparison operator stands before it (`x = any (...)`): alone, ALL is also
# `select all` and `union all`, which test nothing.
QUANTIFIERS = {"any", "all", "some"}
# The first word of a statement that only defines. Outside any body a prefix may stand in one however
# the definition needs (`alter table ... alter column prefix set default ...`).
DEFINING_VERBS = {"alter", "comment", "grant", "revoke", "drop"}
# The floor: fewer prefix references than this and the lexer is no longer reading the module.
MIN_PREFIX_REFS = 8
# A literal that names the column as data, the way a row value is read by field name (#1181): the key
# `'prefix'`, a text[] path `'{prefix}'`, a jsonpath `'$.prefix'`, the name double-quoted or not. A JSON key
# is case-sensitive, so `'Prefix'` names another field and is not one.
NAMES_COLUMN = re.compile(r'(?:(?:strict|lax)\s+)?(?:\$\s*\.\s*)?(\{\s*)?("?)prefix\2(?(1)\s*\})')
# The operators that read a field out of a json, jsonb or hstore value, as the lexer splits them.
FIELD_OPS = (("-", ">", ">"), ("#", ">", ">"), ("-", ">"), ("#", ">"))
# The functions that read a field out of a json or jsonb value by a path of names given after the first
# argument: the call is the reference, judged where it closes.
EXTRACT_FUNCS = {"jsonb_extract_path_text", "json_extract_path_text", "jsonb_extract_path", "json_extract_path"}
# Every word the scanner reads as a keyword; a lone double-quoted one is an identifier and stays quoted.
KEYWORDS = NOT_CALLS | RELATION_BEFORE | PARAM_MODES | CLAUSE_WORDS | NOT_BARE | STATEMENT_STARTS | {
    "function", "procedure", "create", "replace", "execute", "loop", "distinct", "e"}

IDENT = re.compile(r'(?:[A-Za-z_][A-Za-z0-9_$]*|"(?:[^"]|"")*")(?:\.(?:[A-Za-z_][A-Za-z0-9_$]*|"(?:[^"]|"")*"|\*))*')
IDENT_PART = re.compile(r'[A-Za-z_][A-Za-z0-9_$]*|"(?:[^"]|"")*"|\*')
PLAIN = re.compile(r"[a-z_][a-z0-9_$]*")


def canonical(ident):
    """An identifier as the name it denotes (#1094): each part case-folded when bare and unquoted when
    double-quoted, so `cfg."prefix"` is `cfg.prefix`, the same column, and not a spelling the checker
    passes. A quoted part that would not read back as the same name bare keeps its quotes: `"Prefix"` is
    another column, and `"a.b"` one name, not a qualified one. So does a lone quoted word the scanner
    reads as a keyword (`"select"` is a column, not a clause)."""
    parts = []
    for p in IDENT_PART.findall(ident):
        if p.startswith('"'):
            inner = p[1:-1].replace('""', '"')
            p = inner if PLAIN.fullmatch(inner) else p
        else:
            p = p.lower()
        parts.append(p)
    if len(parts) == 1 and parts[0] in KEYWORDS and ident.startswith('"'):
        return ident
    return ".".join(parts)


def lex(src):
    """Tokens of a SQL file as (kind, text, line), comments dropped and every string literal one STR
    token, so nothing inside a comment or a literal is ever read as code (an E-string's text keeps its
    `E`, for executed_as_code to unescape). Dollar-quote delimiters are DOLLAR tokens and what they
    enclose is lexed as code: in this module a $$ body is a function body.
    """
    toks, i, n, line = [], 0, len(src), 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c.isspace():
            i += 1
            continue
        if src.startswith("--", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            line += src.count("\n", i, j)
            i = j
            continue
        if c == "'":
            # An E'...' string takes backslash escapes; its `e` was lexed as an identifier just before.
            estr = bool(toks) and toks[-1][0] == "ID" and toks[-1][1].lower() == "e" and i > 0 and src[i - 1] in "eE"
            if estr:
                toks.pop()
            j, start = i + 1, line
            while j < n:
                if estr and src[j] == "\\":
                    j += 2
                    continue
                if src[j] == "'":
                    if j + 1 < n and src[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            line += src.count("\n", i, j + 1)
            toks.append(("STR", ("E" if estr else "") + src[i:j + 1], start))
            i = j + 1
            continue
        if c == "$":
            m = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$", src[i:])
            if m:
                toks.append(("DOLLAR", m.group(0), line))
                i += len(m.group(0))
                continue
            m = re.match(r"\$\d+", src[i:])
            if m:
                toks.append(("PARAM", m.group(0), line))
                i += len(m.group(0))
                continue
        m = IDENT.match(src, i)
        if m:
            toks.append(("ID", canonical(m.group(0)), line))
            i = m.end()
            continue
        for op in ("||", ":=", "::", "<>", ">=", "<=", "=>", "!="):
            if src.startswith(op, i):
                toks.append(("OP", op, line))
                i += len(op)
                break
        else:
            toks.append(("OP", c, line))
            i += 1
    return toks


# What ends an EXECUTE's command expression, at its own parenthesis depth.
EXEC_END = {"into", "using", "loop"}


def _literal_sql(text):
    """The text a STR token holds, unquoted: '' is a quote, and an E-string's backslash escapes apply."""
    if text[:1] == "E":
        inner = re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text[2:-1],
                       flags=re.S)
    else:
        inner = text[1:-1]
    return inner.replace("''", "'")


def names_column(tok):
    """Is this STR token the prefix column's name as data (NAMES_COLUMN), a field read out of a row?"""
    return tok[0] == "STR" and NAMES_COLUMN.fullmatch(_literal_sql(tok[1]).strip()) is not None


def _relex(tok):
    """A STR token's text lexed as code, on the literal's own lines. Dollar quotes inside it are dropped
    (they must not open or close the enclosing body), and so are its parentheses when they do not balance
    within the literal (`'... in (' || x || ')'`), so a fragment cannot unbalance the rest of the file.
    A `$n` in it is a BIND token, the EXECUTE's nth USING argument, and not a PARAM, the nth parameter of
    the function around it (#1279)."""
    inner = [("BIND" if k == "PARAM" else k, t, tok[2] + ln - 1)
             for k, t, ln in lex(_literal_sql(tok[1])) if k != "DOLLAR"]
    depth, balanced = 0, True
    for _, t, _ in inner:
        depth += (t == "(") - (t == ")")
        balanced = balanced and depth >= 0
    if depth or not balanced:
        inner = [x for x in inner if x[1] not in ("(", ")")]
    return inner


def executed_as_code(toks):
    """The tokens with every literal EXECUTE runs replaced by its own tokens (#1001): each STR in an
    EXECUTE's command up to its INTO, USING or LOOP, and each STR assigned to a local that an EXECUTE of
    the same dollar-quoted body runs by name. Everything else is returned as it was."""
    def tok(i):
        return toks[i] if 0 <= i < len(toks) else ("", "", 0)

    spans, tag, start = [], None, 0
    for k, (kind, text, _) in enumerate(toks):
        if kind == "DOLLAR":
            if tag is None:
                tag, start = text, k + 1
            elif text == tag:
                spans.append((start, k))
                tag = None
    code = set()
    for a, b in spans:
        run = {tok(k + 1)[1] for k in range(a, b)
               if toks[k] == ("ID", "execute", toks[k][2]) and tok(k + 1)[0] == "ID"
               and tok(k + 2)[1] in EXEC_END | {";"}}
        for k in range(a, b):
            kind, text, _ = toks[k]
            if kind != "ID":
                continue
            if text == "execute":
                depth, j = 0, k + 1
                while j < b:
                    t = toks[j]
                    if t[1] == "(":
                        depth += 1
                    elif t[1] == ")":
                        depth -= 1
                    elif depth <= 0 and (t[1] == ";" or (t[0] == "ID" and t[1] in EXEC_END)):
                        break
                    if t[0] == "STR":
                        code.add(j)
                    j += 1
            elif text in run and tok(k - 1)[1] in STATEMENT_STARTS:
                j = k + 1
                while j < b and toks[j][1] != ";":
                    if toks[j][0] == "STR":
                        code.add(j)
                    j += 1
    out = []
    for k, t in enumerate(toks):
        out.extend(_relex(t) if k in code else [t])
    return out


def functions(toks):
    """({name: [[(param name or None, mode), ...], ...]}, unread): every function and procedure the file
    defines with a body this check reads, with the parameters of each overload in order, each with its mode
    (`in` when none is written); and the names it defines with a body it does not read.

    A body is read when it is dollar-quoted, the way scopes are found. One that is not (a single-quoted `as
    '...'`, a SQL-standard `return ...` or `begin atomic`) cannot be followed into, so a name with such an
    overload is in `unread` and not in the dictionary: a prefix handed to it is handed out of sight (#1279)."""
    defined, unread = {}, set()
    for k in range(1, len(toks) - 2):
        if not (toks[k][1] in ("function", "procedure") and toks[k - 1][1] in ("create", "replace")
                and toks[k + 1][0] == "ID" and toks[k + 2][1] == "("):
            continue
        params, cur, depth, j = [], [], 0, k + 3
        while j < len(toks):
            text = toks[j][1]
            if text == "(":
                depth += 1
            elif text == ")":
                if depth == 0:
                    break
                depth -= 1
            if text == "," and depth == 0:
                params.append(cur)
                cur = []
            else:
                cur.append(toks[j])
            j += 1
        if cur:
            params.append(cur)
        names = []
        for p in params:
            words, mode = [t for t in p if t[0] == "ID"], "in"
            while words and words[0][1] in PARAM_MODES:
                mode = words.pop(0)[1]
            # a name is followed by its type; a lone word is a nameless parameter's type
            names.append((words[0][1] if len(words) > 1 else None, mode))
        while j < len(toks) and toks[j][0] != "DOLLAR" and toks[j][1] != ";":
            j += 1
        if j < len(toks) and toks[j][0] == "DOLLAR":
            defined.setdefault(toks[k + 1][1], []).append(names)
        else:
            unread.add(toks[k + 1][1])
    return {fn: overloads for fn, overloads in defined.items() if fn not in unread}, unread


def receivers(params, arg, named):
    """Every spelling one overload's body can read an argument by (#1279), given the argument's position
    in the call, or the name it is passed under: the receiving parameter's name when it has one, and its
    number. A call's arguments are the input parameters in order, so an OUT parameter takes no position.
    `$n` counts every parameter in a plpgsql body and the input ones alone in a SQL body, and the body's
    language is not read, so both numbers are returned. An argument past the last parameter belongs to a
    trailing VARIADIC one."""
    inputs = [(pos, name) for pos, (name, mode) in enumerate(params) if mode != "out"]
    if named is not None:
        hit = [i for i, (_, name) in enumerate(inputs) if name == named]
    elif arg < len(inputs):
        hit = [arg]
    else:
        hit = [len(inputs) - 1] if inputs and params[inputs[-1][0]][1] == "variadic" else []
    spellings = set()
    for i in hit:
        pos, name = inputs[i]
        spellings |= {f"${i + 1}", f"${pos + 1}"}
        if name is not None:
            spellings.add(name)
    return spellings


def scan(src):
    """Returns (refs, assembly, claims, defined): the number of prefix references, {scope: [(line,
    why)]} for every assembling reference, the scopes that name archive.object_key_owner, and the
    functions the file defines.

    The prefix is followed, not spelled: a parameter of a function this file defines that receives a
    prefix at any call site carries the prefix inside that function, whatever it is named, and a scalar
    subquery that selects the prefix is a prefix reference where it stands. That takes a fixed point,
    since a parameter that carries it can hand it on to another function's parameter."""
    toks = executed_as_code(lex(src))
    defined, unread = functions(toks)
    carriers = {}   # function name -> every spelling (name, $n) of the parameters that carry a prefix into it
    for fn, overloads in defined.items():
        for params in overloads:    # a parameter named for the prefix is the prefix under its number too
            for name in sorted({n for n, mode in params if n and mode != "out" and PREFIX_NAME.match(n)}):
                carriers.setdefault(fn, set()).update(receivers(params, 0, name))
    while True:
        refs, assembly, claims, found = _scan_once(toks, defined, carriers, unread)
        grown = False
        for fn, names in found.items():
            if not names <= carriers.get(fn, set()):
                carriers.setdefault(fn, set()).update(names)
                grown = True
        if not grown:
            return refs, assembly, claims, set(defined) | unread


def _scan_once(toks, defined, carriers, unread=frozenset()):
    refs, assembly, claims, found = 0, {}, set(), {}
    scope, pending, body_tag = None, None, None
    parens = []                 # one dict per open parenthesis
    # the statement's own level, outside every parenthesis: its clause, whether it is an INSERT's VALUES,
    # its first word, and whether it stands in a DECLARE section
    stmt = {"clause": None, "insert": False, "verb": None, "declare": False}

    def new_statement(declare=None):
        stmt.update(clause=None, insert=False, verb=None)
        if declare is not None:
            stmt["declare"] = declare

    def tok(i):
        return toks[i] if 0 <= i < len(toks) else ("", "", 0)

    def match(i, step):
        """The index of the bracket matching the one at i, scanning forward (step 1) or back (step -1)."""
        pair = {"(": ")", "[": "]", ")": "(", "]": "["}
        here, there, depth = tok(i)[1], pair[tok(i)[1]], 0
        while 0 <= i < len(toks):
            depth += (tok(i)[1] == here) - (tok(i)[1] == there)
            if depth == 0:
                return i
            i += step
        return i

    def field_op(i, ending):
        """The length of a field-reading operator (FIELD_OPS) starting at i, or ending at i, or 0."""
        for op in FIELD_OPS:
            first = i - len(op) + 1 if ending else i
            if tuple(tok(first + j)[1] for j in range(len(op))) == op and all(
                    tok(first + j)[0] == "OP" for j in range(len(op))):
                return len(op)
        return 0

    def operand_start(i):
        """The first token of the operand that ends at i: a call or a parenthesised value with its
        brackets, and whatever it continues (a cast's type, a field selection `(cfg).f`, a subscript, a
        field read `j -> 'k'`) back to the value it starts from."""
        while True:
            t = tok(i)[1]
            if t == ")":
                i = match(i, -1)
                if tok(i - 1)[0] == "ID" and tok(i - 1)[1] not in NOT_CALLS:
                    i -= 1
            elif t == "]":
                i = match(i, -1) - 1
                continue
            if tok(i - 1)[1] in ("::", "."):
                i -= 2
            elif field_op(i - 1, True):
                i -= 1 + field_op(i - 1, True)
            else:
                return i

    def after_idx(i):
        """The index of the token after the expression ending at i, past what continues it: `::type`
        casts, subscripts and field reads (`->> 'k'`, `#>> '{k}'`)."""
        i += 1
        while True:
            if tok(i)[1] == "::":
                i += 2
            elif tok(i)[1] == "[":
                i = match(i, 1) + 1
            elif field_op(i, False):
                i += field_op(i, False)
                i = (match(i, 1) if tok(i)[1] in ("(", "[") else i) + 1
            else:
                return i

    def after(i):
        """The token after the expression ending at i (after_idx)."""
        return tok(after_idx(i))

    def carried(text):
        """Is this identifier a parameter that carries the prefix into the function being read: its name, or
        its name behind the function's own (`_join.p_base`, how a body names a parameter past a column)?"""
        names = carriers.get(scope, ())
        owner, _, name = text.rpartition(".")
        return text in names or (name in names and scope is not None and owner == scope.rpartition(".")[2])

    def assigned_by_equals(s, level):
        """Is the `=` before s a plpgsql assignment and not a comparison: the statement `v = x;` or
        `v[1] = x;`, or a DECLARE's `v text = x;` (the first `=` of a declaration that is not a cursor's)?"""
        i = s - 2
        if level is stmt and stmt["declare"]:
            while tok(i)[1] not in STATEMENT_STARTS | {""}:
                if tok(i)[1] in ("=", ":=", "default", "cursor"):
                    return False
                i -= 1
            return True
        while tok(i)[1] == "]":
            i = match(i, -1) - 1
        return tok(i)[0] == "ID" and tok(i - 1)[1] in STATEMENT_STARTS

    def compared(s, e):
        """Does the reference s..e touch a comparison (COMPARISON_OPS, TESTED_BY, TESTED_AFTER)? An
        operator that reads a field (`->`, `#>>`) ends in `>` and is not one."""
        before, behind = tok(s - 1), after(e)
        return ((before[0] == "OP" and before[1] in COMPARISON_OPS and not field_op(s - 1, True))
                or (before[1] == "*" and tok(s - 2)[1] == "~")          # `~*`, as the lexer splits it
                or (before[1] == "from" and tok(s - 2)[1] == "distinct")        # IS [NOT] DISTINCT FROM
                or (before[0] == "ID" and before[1] in TESTED_AFTER)
                or (before[0] == "ID" and before[1] in QUANTIFIERS and tok(s - 2)[0] == "OP"
                    and tok(s - 2)[1] in COMPARISON_OPS)
                or (behind[0] == "OP" and behind[1] in COMPARISON_OPS)
                or (behind[0] == "ID" and behind[1] in TESTED_BY))

    def judge(s, e, line, label, value=True):
        """Is the prefix reference spanning tokens s..e assembly? Records it, or records the parameter
        it is handed to when that is a parameter of a function this file defines.

        The reference is the whole value it stands for, so parentheses that only group it are part of
        it: `(cfg.prefix) || x` and `v := (to_jsonb(cfg) ->> 'prefix')` are judged at the parentheses.
        `value` is False for a bare literal naming the column, a name and not the value, which the
        inverse rule (WHAT A PREFIX MAY DO) leaves to the rules before it."""
        depth = 0
        while tok(s - 1)[1] == "(" and tok(after_idx(e))[1] == ")" and len(parens) > depth \
                and parens[-1 - depth]["start"] == s - 1 and parens[-1 - depth]["callee"] is None \
                and not parens[-1 - depth]["subq"] and not parens[-1 - depth]["stored"]:
            s, e, depth = s - 1, after_idx(e), depth + 1
        prev, nxt = tok(s - 1)[1], after(e)[1]
        level = parens[-1 - depth] if len(parens) > depth else stmt
        call = level.get("callee")
        named = None
        if prev in ("=>", ":=") and tok(s - 2)[0] == "ID" and tok(s - 3)[1] in ("(", ",") and call:
            named = tok(s - 2)[1]
        whole = (named is not None or prev in ("(", ",")) and nxt in (",", ")")
        why = None
        if prev == "||" or nxt == "||":
            why = "concatenated with ||"
        elif (prev == ":=" and named is None) or nxt == "into" or (prev == "default" and call != "<header>") \
                or (prev == "=" and assigned_by_equals(s, level)):
            why = "assigned to another name"
        elif prev == "return":
            why = "returned, which would let the value travel under another name"
        elif level.get("clause") == "select" and prev in ("select", "distinct", ",") \
                and (nxt in (",", ")", ";", "", "from", "as", "where", "union", "limit", "order", "group")
                     or (after(e)[0] == "ID" and nxt not in NOT_BARE)):
            if level.get("subq"):
                level["selects"] = True      # the subquery is the reference; judged where it closes
                return
            why = "selected out as a value, which would let it travel under another name"
        elif call is not None and call != "<header>":
            if call in defined:
                for params in defined[call]:
                    found.setdefault(call, set()).update(receivers(params, level["arg"], named))
            elif call in unread:
                why = f"passed to {call}(), whose body is not dollar-quoted, so this check cannot follow it there"
            else:
                why = f"passed to {call}(), which this file does not define"
        # the inverse rule (#1279): what none of the above judged is assembly unless it stands in one of the
        # ways WHAT A PREFIX MAY DO names, or in a statement outside any body that only defines
        may = (call == "<header>"                                       # declared, in a function's header
               or (call in defined and whole)                           # handed whole to a function of this file
               or compared(s, e)                                        # compared or tested
               or (level.get("stored") and whole)                       # a column or a value of an INSERT
               or (level is stmt and stmt["verb"] == "raise")           # reported
               or (body_tag is None and stmt["verb"] in DEFINING_VERBS))
        if why is None and value and not may:
            why = (f"standing between `{prev[:24]}` and `{nxt[:24]}`, where it is neither compared, stored, "
                   f"reported nor handed whole to a function of this file, so the value could travel on under "
                   f"another name")
        if why:
            where = scope if scope is not None else "top level"
            assembly.setdefault(where, []).append((line, f"{label} {why}"))

    for k, (kind, text, line) in enumerate(toks):
        prev, nxt = tok(k - 1), tok(k + 1)

        # scopes: a function from its header to the end of its body, a DO block likewise
        if kind == "ID" and text in ("function", "procedure") and prev[1] in ("create", "replace") and nxt[0] == "ID":
            pending = nxt[1]
        elif kind == "ID" and text == "do" and nxt[0] == "DOLLAR" and body_tag is None:
            pending = f"DO block at line {line}"
        if kind == "DOLLAR":
            if body_tag is None and pending is not None:
                body_tag, scope, pending = text, pending, None
                new_statement(declare=False)
            elif body_tag == text:
                body_tag, scope = None, None
                new_statement(declare=False)
            continue
        if kind == "OP" and text == ";":
            if body_tag is None:
                pending = None
            new_statement()

        # calls: what each open parenthesis belongs to, and which argument is being read
        if kind == "OP" and text == "(":
            callee = None
            if prev[0] == "ID" and prev[1] not in NOT_CALLS:
                before = tok(k - 2)[1]
                if before in ("function", "procedure"):
                    callee = "<header>"
                elif before not in RELATION_BEFORE:
                    callee = prev[1]
            # where a value is stored and goes no further, or a column is only named: an INSERT's column
            # list, a row of its VALUES, the column list of a key, of the table a foreign key references or
            # of an upsert's conflict target
            around = parens[-1] if parens else stmt
            stored = callee is None and (
                (prev[0] == "ID" and tok(k - 2)[1] in ("into", "references"))
                or prev[1] in ("key", "unique", "conflict")
                or (prev[1] in ("values", ",") and around.get("clause") == "values" and around.get("insert")))
            parens.append({"callee": callee, "arg": 0, "subq": nxt[1] == "select", "clause": None,
                           "selects": False, "start": k, "stored": stored})
            continue
        if kind == "OP" and text == ")":
            if parens:
                closed = parens.pop()
                if closed["selects"] and closed["callee"] is not None:
                    judge(closed["start"] - 1, k, toks[closed["start"]][2],
                          f"{closed['callee']}() reading the prefix by name")
                elif closed["selects"]:
                    judge(closed["start"], k, toks[closed["start"]][2], "a subquery selecting the prefix")
            continue
        if kind == "OP" and text == "," and parens:
            parens[-1]["arg"] += 1
            continue

        # the column named as data (#1181): a field read out of a row value, `to_jsonb(cfg) ->> 'prefix'`,
        # `row_to_json(cfg) -> 'prefix'`, `j['prefix']`, `jsonb_extract_path_text(j, 'prefix')`, is the
        # prefix, and the reference is the whole read
        if kind == "STR" and names_column(toks[k]):
            refs += 1
            level = parens[-1] if parens else stmt
            label = f"the prefix read by name ({text})"
            if level.get("callee") in EXTRACT_FUNCS and level["arg"] >= 1:
                level["selects"] = True      # the call is the reference; judged where it closes
            elif prev[1] == "[" and nxt[1] == "]":
                judge(operand_start(k - 2), k + 1, line, label)
            elif field_op(k - 1, True):
                judge(operand_start(k - 1 - field_op(k - 1, True)), k, line, label)
            else:
                judge(k, k, line, label, value=False)
            continue

        # a parameter read by its number (#1279): `$1` in the body of a function handed the prefix first
        if kind == "PARAM" and text in carriers.get(scope, ()):
            refs += 1
            judge(k, k, line, f"{text} (a parameter that carries the prefix)")
            continue

        if kind != "ID":
            continue
        if not parens:
            # the DECLARE section a statement of a body may stand in (a DECLARE opens one where a statement
            # could start, not inside the text of some other statement), and the statement's first word
            if body_tag is not None and (text == "begin" or (text == "declare" and (
                    prev[0] == "DOLLAR" or prev[1] in STATEMENT_STARTS | {">"}))):
                stmt["declare"] = text == "declare"
            if body_tag is not None and text in STATEMENT_STARTS:
                stmt["verb"] = None
            elif stmt["verb"] is None:
                stmt["verb"] = text
        if text in CLAUSE_WORDS:
            around = parens[-1] if parens else stmt
            around["insert"] = text == "values" and around.get("clause") == "into"
            around["clause"] = text
        if text == CLAIM_TABLE and scope is not None:
            claims.add(scope)
        if not (PREFIX_NAME.match(text) or carried(text)):
            continue
        refs += 1
        if nxt[1] in TYPE_WORDS or nxt[1] in ("=>", ":="):
            continue  # a declaration, the label of a named argument, or the target of an assignment
        # a field selected out of a parenthesised row, `(cfg).prefix`, is a reference from the row on
        judge(operand_start(k - 2) if prev[1] == "." else k, k, line, text)
    return refs, assembly, claims, found


def check_text(name, src):
    """Violations (a list of strings) and the assembling function's name, or None."""
    refs, assembly, claims, _ = scan(src)
    v = []
    if refs < MIN_PREFIX_REFS:
        v.append(f"{name}: only {refs} prefix reference(s) found, expected at least {MIN_PREFIX_REFS}; the "
                 f"lexer is no longer reading this module, so a clean result would mean nothing")
        return v, None
    if not assembly:
        v.append(f"{name}: no function assembles a key prefix at all; the lexer is not seeing the key "
                 f"function, so a clean result would mean nothing")
        return v, None
    if len(assembly) > 1:
        v.append(f"{name}: an object key is assembled in {len(assembly)} places, not one; every key must "
                 f"come from the one function that claims it in {CLAIM_TABLE}:")
        for where, uses in sorted(assembly.items()):
            for line, why in uses:
                v.append(f"    {where} (line {line}): {why}")
        return v, None
    (owner, uses), = assembly.items()
    if owner == "top level" or owner.startswith("DO block"):
        v.append(f"{name}: an object key is assembled at {owner} (line {uses[0][0]}), outside any function")
        return v, None
    if owner not in claims:
        v.append(f"{name}: {owner} assembles every object key but never names {CLAIM_TABLE}, so nothing "
                 f"claims a key before it is PUT")
        return v, None
    return v, owner


# ------------------------------------------------------------------------------------------------
# selftest fixtures

# The shape the lever leaves: one assembling function that claims, two entry points, four callers,
# archive.configure's upsert, and decoys in a comment, a literal and an E-string.
CLEAN = r"""
create table if not exists archive.config (
  parent_table regclass primary key,
  prefix       text not null default 'events/'
);
create or replace function archive.configure(p_parent regclass, p_prefix text default 'events/') returns void
language plpgsql as $$
begin
  insert into archive.config (parent_table, prefix) values (p_parent, p_prefix)
  on conflict (parent_table) do update set prefix = excluded.prefix;
end;
$$;
-- a comment saying cfg.prefix || 'x' is not code
create or replace function archive._owned_key(p_parent regclass, p_prefix text, p_child name, p_tail text)
returns text language plpgsql as $$
declare v_base_q text; v_owner oid;
begin
  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(coalesce(p_child, c.relname)) into v_base_q
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  insert into archive.object_key_owner (key_base, parent_oid) values (v_base_q, p_parent::oid)
    on conflict (key_base) do nothing returning parent_oid into v_owner;
  return v_base_q || p_tail;
end;
$$;
create or replace function archive._object_key(p_parent regclass, p_prefix text, p_kind text, p_lo text, p_ext text)
returns text language sql as $$
  select archive._owned_key(p_parent, p_prefix, null, '_' || archive._object_stem(p_kind, p_lo) || p_ext);
$$;
create or replace function archive._child_object_key(p_parent regclass, p_prefix text, p_child name, p_ext text)
returns text language sql as $$
  select archive._owned_key(p_parent, p_prefix, p_child, p_ext);
$$;
create or replace function archive.to_s3(p_parent regclass, p_child name) returns void language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  v_key := archive._child_object_key(p_parent, cfg.prefix, p_child, '.ndjson');
  perform archive._s3_abort_uploads_at(v_key, 'uploads=&prefix=' || v_key);
  raise notice 'not code: %', 'cfg.prefix || p_child';
  raise notice e'not code either: \' cfg.prefix || p_child';
end;
$$;
"""

# Real instance: main before #872 (32c705b), the two key functions verbatim in their essentials.
# _object_key claims and _child_object_key does not, and each assembles its own key.
PRE_FIX = r"""
create table if not exists archive.config (parent_table regclass primary key, prefix text not null default 'events/');
create or replace function archive.configure(p_parent regclass, p_prefix text default 'events/') returns void
language plpgsql as $$
begin
  insert into archive.config (parent_table, prefix) values (p_parent, p_prefix)
  on conflict (parent_table) do update set prefix = excluded.prefix;
end;
$$;
create or replace function archive._object_key(p_parent regclass, p_prefix text, p_kind text, p_lo text, p_ext text)
returns text language plpgsql as $$
declare v_base_q text; v_owner oid;
begin
  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
    into v_base_q
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = p_parent;
  insert into archive.object_key_owner (key_base, parent_oid) values (v_base_q, p_parent::oid)
    on conflict (key_base) do nothing
    returning parent_oid into v_owner;
  return v_base_q || '_' || archive._object_stem(p_kind, p_lo) || p_ext;
end;
$$;
create or replace function archive._child_object_key(p_parent regclass, p_prefix text, p_child name, p_ext text)
returns text language sql stable as $$
  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(p_child) || p_ext
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = p_parent;
$$;
create or replace function archive.to_s3(p_parent regclass, p_child name) returns void language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  v_key := archive._child_object_key(p_parent, cfg.prefix, p_child, '.ndjson');
end;
$$;
"""


def with_extra(body):
    return CLEAN + body


FORMAT_SECOND = with_extra(r"""
create or replace function archive.to_s3_parquet(p_parent regclass, p_child name) returns void language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  v_key := format('%s%I.%I.parquet', cfg.prefix, 'public', p_child);
end;
$$;
""")

ASSIGN_SECOND = with_extra(r"""
create or replace function archive.to_s3_parquet(p_parent regclass, p_child name) returns void language plpgsql as $$
declare cfg archive.config; v_pfx text; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  v_pfx := cfg.prefix;
  v_key := v_pfx || p_child || '.parquet';
end;
$$;
""")

CONCAT_SECOND = with_extra(r"""
create or replace function archive._encode_upload_parquet(p_parent regclass) returns text language plpgsql as $$
declare cfg archive.config;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  return concat(cfg.prefix, p_parent::text, '.parquet');
end;
$$;
""")

INLINE_CALLER = with_extra(r"""
create or replace function archive._encode_upload_ndjson_single(p_parent regclass, p_lo text) returns text language plpgsql as $$
declare cfg archive.config; v_nsp name; v_rel name; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  v_key := cfg.prefix || quote_ident(v_nsp) || '.' || quote_ident(v_rel) || '_' || p_lo || '.ndjson';
  return v_key;
end;
$$;
""")

DO_BLOCK = with_extra(r"""
do $$
declare r record;
begin
  for r in select * from archive.config loop
    perform archive.s3_signed_request('PUT', r.prefix || 'marker');
  end loop;
end $$;
""")

# Real instances: review pass 8 (F8-05), each a second assembly the token-adjacency rule passed.
# A scalar subquery: `prefix` sits between select and from, the `||` follows the closing parenthesis.
SUBQUERY_SECOND = with_extra(r"""
create or replace function archive._f8_export_key(p_parent regclass, p_child name) returns text
language sql stable as $$
  select (select prefix from archive.config where parent_table = p_parent)
         || quote_ident(n.nspname) || $q$.$q$ || quote_ident(p_child) || $q$.ndjson$q$
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
$$;
""")

# A function this file defines, handed cfg.prefix through a parameter named p_base.
RENAMED_CARRIER = with_extra(r"""
create or replace function archive._f8_join(p_base text, p_parent regclass, p_child name) returns text
language sql stable as $$
  select p_base || quote_ident(n.nspname) || $q$.$q$ || quote_ident(p_child) || $q$.ndjson$q$
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
$$;
create or replace function archive._f8_export_key2(p_parent regclass, p_child name) returns text
language plpgsql stable as $$
declare cfg archive.config;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  return archive._f8_join(cfg.prefix, p_parent, p_child);
end;
$$;
""")

# The same, two carriers deep and by name: the fixed point has to go round twice.
CARRIED_TWICE = with_extra(r"""
create or replace function archive._join2(p_root text, p_child name) returns text language sql as $$
  select p_root || quote_ident(p_child);
$$;
create or replace function archive._join1(p_base text, p_child name) returns text language sql as $$
  select archive._join2(p_child => p_child, p_root => p_base);
$$;
create or replace function archive._export_key3(p_parent regclass, p_child name) returns text language sql as $$
  select archive._join1((select c.prefix from archive.config c where c.parent_table = p_parent), p_child);
$$;
""")

RETURNED = with_extra(r"""
create or replace function archive._prefix_of(p_parent regclass) returns text language plpgsql as $$
declare cfg archive.config;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  return cfg.prefix;
end;
$$;
""")

SELECTED_OUT = with_extra(r"""
create or replace function archive._sweep_keys() returns setof text language plpgsql as $$
declare r record;
begin
  for r in select parent_table, prefix as base from archive.config loop
    return next r.base || r.parent_table::text;
  end loop;
end;
$$;
""")

# Carried and still clean: a helper of this file that takes the prefix under another name and only hands
# it to the key function, and a subquery handed straight to it. Following must not mean refusing.
CARRIED_CLEAN = with_extra(r"""
create or replace function archive._export_key(p_parent regclass, p_base text, p_child name) returns text
language sql as $$
  select archive._child_object_key(p_parent, p_base, p_child, '.ndjson');
$$;
create or replace function archive.to_s3_manifest(p_parent regclass, p_child name) returns text language sql as $$
  select archive._export_key(p_parent, (select prefix from archive.config where parent_table = p_parent), p_child);
$$;
""")

# Real instance: review pass 9 (F8-02, issue #1001). The prefix read by dynamic SQL: the literal EXECUTE
# runs is code, and the pre-#1001 lexer read it as one opaque string, so `prefix` was never seen at all.
EXECUTED_SECOND = with_extra(r"""
create or replace function archive.f8_second_key(p_parent regclass, p_child name) returns text
language plpgsql as $$
declare v_base text;
begin
  execute 'select prefix from archive.config where parent_table = $1' into v_base using p_parent;
  return v_base || quote_ident(p_child) || '.ndjson';
end;
$$;
""")

# The same statement held in a local first, and the column named by a format() argument: both literals
# reach EXECUTE, so both are code.
EXECUTED_VIA_LOCAL = with_extra(r"""
create or replace function archive._sql_key(p_parent regclass, p_child name) returns text
language plpgsql as $$
declare v_sql text; v_base text;
begin
  v_sql := 'select prefix from archive.config where parent_table = $1';
  execute v_sql into v_base using p_parent;
  return v_base || quote_ident(p_child);
end;
$$;
""")

EXECUTED_FORMAT_ARG = with_extra(r"""
create or replace function archive._fmt_key(p_parent regclass, p_child name) returns text
language plpgsql as $$
declare v_base text;
begin
  execute format('select %I from archive.config where parent_table = $1', 'prefix') into v_base using p_parent;
  return v_base || quote_ident(p_child);
end;
$$;
""")

# Dynamic SQL that reads the config but not the prefix, and a literal naming the prefix that is NOT
# executed: reading executed literals as code must not turn either into a key.
EXECUTED_CLEAN = with_extra(r"""
create or replace function archive._bucket_of(p_parent regclass) returns boolean
language plpgsql as $$
declare v_b text; v_sql text;
begin
  execute 'select bucket from archive.config where parent_table = $1' into v_b using p_parent;
  v_sql := 'select ''unrelated'' where $1 is not null';
  execute v_sql using v_b;
  for v_b in execute format('select %I from archive.config', 'bucket') loop
    raise notice 'prefix read: %', 'cfg.prefix || p_child';
  end loop;
  return v_b is not null;
end;
$$;
""")

# Executed fragments that are not whole statements. A dollar quote inside one must not end the body it
# sits in (the owner's claim, after it, would be read at top level and the owner judged as never
# claiming), and a parenthesis it closes but did not open must not close the format( around it (the
# prefix argument after it would be judged outside any call, and the second key missed).
OWNER_EXECUTES_DOLLAR = CLEAN.replace("""  insert into archive.object_key_owner""",
                                      """  execute 'select $$' || p_tail || '$$';
  insert into archive.object_key_owner""")
UNPAIRED_PAREN_SECOND = with_extra(r"""
create or replace function archive._split_key(p_parent regclass) returns text language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  execute format('select %L' || ')', cfg.prefix) into v_key;
  return v_key;
end;
$$;
""")

# Real instance: review pass 10 (F8-02, issue #1094). The column double-quoted, then behind a quoted
# qualifier, then qualified by schema and table: each is the same column, and a second key built from it
# is a second key. "Prefix" is ANOTHER column (a quoted name keeps its case), so building from it is not.
QUOTED_COLUMN_SECOND = with_extra(r"""
create or replace function archive.to_s3_parquet(p_parent regclass, p_child name) returns void language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  v_key := cfg."prefix" || quote_ident(p_child) || '.parquet';
end;
$$;
""")
QUOTED_QUALIFIER_SECOND = with_extra(r"""
create or replace function archive._quoted_cfg_key(p_parent regclass, p_child name) returns text language plpgsql as $$
declare "Cfg" archive.config;
begin
  select * into "Cfg" from archive.config where parent_table = p_parent;
  return "Cfg".prefix || quote_ident(p_child);
end;
$$;
""")
SCHEMA_QUALIFIED_SECOND = with_extra(r"""
create or replace function archive._qualified_key(p_parent regclass, p_child name) returns text language sql as $$
  select archive.config.prefix || quote_ident(p_child) from archive.config where parent_table = p_parent;
$$;
""")
OTHER_COLUMN_QUOTED = with_extra(r"""
create or replace function archive._other_column(p_parent regclass, p_child name) returns text language plpgsql as $$
declare cfg record;
begin
  select 'x' as "Prefix" into cfg;
  return cfg."Prefix" || quote_ident(p_child);
end;
$$;
""")

# Real instance: review pass 11 (F8-06, issue #1181). The same configured prefix read out of the config row
# as JSON, by the column's name in a literal: to_jsonb, row_to_json and jsonb_extract_path_text, each the
# whole value a second key is built from. The read is the reference, wherever its parentheses put it.
def _row_read_second(fn, expr):
    return with_extra(f"""
create or replace function {fn}(p_parent regclass, p_child name) returns void language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  v_key := {expr} || p_child || '.parquet';
end;
$$;
""")


TO_JSONB_SECOND = _row_read_second("archive._jsonb_key", "(to_jsonb(cfg) ->> 'prefix')")
ROW_TO_JSON_SECOND = _row_read_second("archive._json_key", "(row_to_json(cfg) ->> 'prefix')")
EXTRACT_PATH_SECOND = _row_read_second("archive._path_key", "jsonb_extract_path_text(to_jsonb(cfg), 'prefix')")
TEXT_PATH_SECOND = _row_read_second("archive._text_path_key", "(row_to_json(cfg)::jsonb #>> '{prefix}')")
# Parentheses that only group a reference are part of it, for the column as much as for a read by name, and
# a field selected out of a parenthesised row is the column too.
PARENTHESISED_SECOND = _row_read_second("archive._paren_key", "(cfg.prefix)")
FIELD_SELECTED_SECOND = with_extra(r"""
create or replace function archive._field_key(p_parent regclass, p_child name) returns text language plpgsql as $$
declare cfg archive.config; v_base text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  v_base := (cfg).prefix;
  return v_base || quote_ident(p_child);
end;
$$;
""")
# Read by name and handed only to the key function, and the name in a message or a test: following the read
# must not mean refusing it, and "Prefix" (a JSON key is case-sensitive) names another field.
ROW_READ_CLEAN = with_extra(r"""
create or replace function archive.to_s3_jsonl(p_parent regclass, p_child name) returns text language plpgsql as $$
declare cfg archive.config;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if (to_jsonb(cfg) ->> 'prefix') is null or (to_jsonb(cfg) ->> 'Prefix') is not null then
    raise exception 'archive.config has no % for %', 'prefix', p_parent;
  end if;
  return archive._child_object_key(p_parent, (to_jsonb(cfg) ->> 'prefix'), p_child,
                                   coalesce(to_jsonb(cfg) ->> 'Prefix', '') || '.jsonl');
end;
$$;
""")

# Real instances: review pass 12 (F8-02 and F12r-07, issue #1279). The prefix bound to an EXECUTE as a USING
# argument, and renamed through a FROM item (a function called there, a VALUES row, a derived table): each
# stood where none of the rules named a way out, so the second key built from what it became passed.
def _standing_second(fn, body):
    return with_extra(f"""
create or replace function {fn}(p_parent regclass, p_child name) returns text language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  {body}
end;
$$;
""")


USING_SECOND = _standing_second("archive.f8_second_key",
                                "execute 'select $1 || ''/'' || $2' into v_key using cfg.prefix, p_child;\n"
                                "  return v_key;")
FROM_UNNEST_SECOND = _standing_second("archive._f12r_unnest_key",
                                      "return (select u.p || p_child from unnest(array[cfg.prefix]) as u(p));")
FROM_VALUES_SECOND = _standing_second("archive._f12r_values_key",
                                      "return (select u.p || p_child from (values (cfg.prefix)) as u(p));")
DERIVED_TABLE_SECOND = _standing_second(
    "archive._derived_key",
    "return (select c.p || p_child from (select prefix as p from archive.config where parent_table = p_parent) c);")
# The prefix handed by position to a helper of this file that has no name to read it by: `$1` is the
# parameter, and so is the number of a parameter that has a name.
POSITIONAL_SECOND = with_extra(r"""
create or replace function archive._f12r_join(text, name) returns text language sql immutable as $f$
  select $1 || $2
$f$;
create or replace function archive._f12r_key(p_parent regclass, p_child name) returns text language plpgsql as $f$
declare cfg archive.config;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  return archive._f12r_join(cfg.prefix, p_child);
end $f$;
""")
NUMBER_OF_NAMED_SECOND = with_extra(r"""
create or replace function archive._num_join(p_child name, p_base text) returns text language sql as $$
  select $2 || quote_ident($1);
$$;
create or replace function archive._num_key(p_parent regclass, p_child name) returns text language sql as $$
  select archive._num_join(p_base => c.prefix, p_child => p_child) from archive.config c where c.parent_table = p_parent;
$$;
""")
# A function of this file called in a FROM clause is a call: the prefix it is handed is followed into its
# parameter, so the helper that assembles is the one named, and one that only hands it on stays clean.
FROM_HELPER_SECOND = with_extra(r"""
create or replace function archive._rows_key(p_base text, p_child name) returns setof text language sql as $$
  select p_base || quote_ident(p_child);
$$;
create or replace function archive._rows_caller(p_parent regclass, p_child name) returns text language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  perform 1 from archive._rows_key(cfg.prefix, p_child) r;
  return null;
end;
$$;
""")
# The same `$1 || $2` in a single-quoted body: text this check does not read, so not a function the prefix
# can be handed to and followed into. Handing it there is the way out.
UNREAD_BODY_SECOND = with_extra(r"""
create or replace function archive._quoted_join(text, name) returns text language sql as 'select $1 || $2';
create or replace function archive._quoted_key(p_parent regclass, p_child name) returns text language sql as $$
  select archive._quoted_join(c.prefix, p_child) from archive.config c where c.parent_table = p_parent;
$$;
""")
# Everything a prefix may do, and still one key function: handed whole (by position, by name, by number, in
# a FROM clause), compared and tested, stored by an upsert, reported by RAISE. And a `$1` in the text an
# EXECUTE runs is its USING argument, not the first parameter of the function, which here carries the prefix.
STANDING_CLEAN = with_extra(r"""
create or replace function archive._pass_on(text, regclass, regclass) returns text language sql as $$
  select archive._child_object_key($2, $1, $3, '.ndjson');
$$;
create or replace function archive._pass_rows(p_base text, p_parent regclass, p_child regclass) returns setof text
language plpgsql as $$
declare v_n bigint;
begin
  execute 'select count(*) from pg_class where oid = $1 or relname = $2' into v_n using p_parent, p_child::text;
  return next archive._pass_on(p_base, p_parent, p_child);
end;
$$;
create or replace function archive.to_s3_checked(p_parent regclass, p_child regclass) returns text
language plpgsql as $$
declare cfg archive.config; v_same boolean = false; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if cfg.prefix is null or cfg.prefix = '' or cfg.prefix not like '%/' or 'events/' <> cfg.prefix then
    raise exception 'archive.config has the prefix % for %, which is no directory', cfg.prefix, p_parent;
  end if;
  v_same := exists (select 1 from archive.config c where c.prefix = cfg.prefix and c.parent_table <> p_parent);
  insert into archive.config (parent_table, prefix) values (p_child, cfg.prefix)
  on conflict (parent_table) do update set prefix = excluded.prefix where archive.config.prefix <> excluded.prefix;
  select k into v_key from archive._pass_rows(cfg.prefix, p_parent, p_child) k;
  return archive._child_object_key(p_ext => '.ndjson', p_prefix => cfg.prefix, p_parent => p_parent, p_child => p_child);
end;
$$;
""")

NO_CLAIM = CLEAN.replace("""  insert into archive.object_key_owner (key_base, parent_oid) values (v_base_q, p_parent::oid)
    on conflict (key_base) do nothing returning parent_oid into v_owner;
""", "")

NO_ASSEMBLY = CLEAN.replace("select p_prefix || quote_ident(n.nspname)", "select quote_ident(n.nspname)")


def selftest():
    failures = 0

    def expect(label, src, ok, needle=None, owner=None):
        nonlocal failures
        v, got_owner = check_text(label, src)
        if ok:
            if v or (owner and got_owner != owner):
                print(f"SELFTEST FAIL  {label}: expected a clean result owned by {owner}, got {got_owner}:")
                for x in v:
                    print("        " + x)
                failures += 1
            else:
                print(f"SELFTEST PASS  {label}: clean, every key assembled in {got_owner}")
        else:
            needles = (needle,) if isinstance(needle, str) else (needle or ())
            if not v or not any(all(n in x for n in needles) for x in v):
                print(f"SELFTEST FAIL  {label}: expected a violation mentioning {needle!r}, got {v}")
                failures += 1
            else:
                print(f"SELFTEST PASS  {label}: refused ({v[0].split(': ', 1)[1][:90]}...)")

    expect("clean", CLEAN, True, owner="archive._owned_key")
    expect("pre-#872 main (two key functions)", PRE_FIX, False, "archive._child_object_key")
    expect("a second assembly through format()", FORMAT_SECOND, False, "passed to format()")
    expect("a second assembly through an assigned copy", ASSIGN_SECOND, False, "assigned to another name")
    expect("a second assembly through concat()", CONCAT_SECOND, False, "passed to concat()")
    expect("a caller building its own key inline", INLINE_CALLER, False, "archive._encode_upload_ndjson_single")
    expect("a key assembled in a DO block", DO_BLOCK, False, "DO block")
    expect("F8-05: a second assembly through a scalar subquery", SUBQUERY_SECOND, False,
           "archive._f8_export_key (line")
    expect("F8-05: a second assembly in a helper whose parameter is not named prefix", RENAMED_CARRIER,
           False, "archive._f8_join (line")
    expect("a second assembly two carriers deep, by name", CARRIED_TWICE, False, "archive._join2 (line")
    expect("the prefix returned out of a function", RETURNED, False, "returned")
    expect("the prefix selected out as a column", SELECTED_OUT, False, "selected out")
    expect("the prefix carried under other names to the key function only", CARRIED_CLEAN, True,
           owner="archive._owned_key")
    expect("F8-02: a second assembly reading the prefix through EXECUTE '<select prefix ...>'",
           EXECUTED_SECOND, False, "archive.f8_second_key (line")
    expect("a second assembly reading the prefix through a local that EXECUTE runs", EXECUTED_VIA_LOCAL,
           False, "archive._sql_key (line")
    expect("a second assembly naming the prefix in a format() argument EXECUTE runs", EXECUTED_FORMAT_ARG,
           False, "archive._fmt_key (line")
    expect("dynamic SQL that reads the config but not the prefix", EXECUTED_CLEAN, True,
           owner="archive._owned_key")
    expect("a dollar quote inside an executed literal does not end the owner's body", OWNER_EXECUTES_DOLLAR,
           True, owner="archive._owned_key")
    expect("an unpaired parenthesis in an executed literal does not hide the format() around it",
           UNPAIRED_PAREN_SECOND, False, "archive._split_key (line")
    expect("F8-02: a second assembly from the double-quoted column cfg.\"prefix\"", QUOTED_COLUMN_SECOND,
           False, "archive.to_s3_parquet (line")
    expect("a second assembly from the column behind a quoted qualifier", QUOTED_QUALIFIER_SECOND, False,
           "archive._quoted_cfg_key (line")
    expect("a second assembly from the column qualified by schema and table", SCHEMA_QUALIFIED_SECOND, False,
           "archive._qualified_key (line")
    expect("a quoted \"Prefix\" is another column, not the prefix", OTHER_COLUMN_QUOTED, True,
           owner="archive._owned_key")
    expect("F8-06: a second assembly from to_jsonb(cfg) ->> 'prefix'", TO_JSONB_SECOND, False,
           "archive._jsonb_key (line")
    expect("F8-06: a second assembly from row_to_json(cfg) ->> 'prefix'", ROW_TO_JSON_SECOND, False,
           "archive._json_key (line")
    expect("F8-06: a second assembly from jsonb_extract_path_text(to_jsonb(cfg), 'prefix')", EXTRACT_PATH_SECOND,
           False, "archive._path_key (line")
    expect("a second assembly from the text path #>> '{prefix}'", TEXT_PATH_SECOND, False,
           "archive._text_path_key (line")
    expect("a second assembly from the parenthesised column (cfg.prefix)", PARENTHESISED_SECOND, False,
           "archive._paren_key (line")
    expect("a second assembly from the field selected out of a row, (cfg).prefix", FIELD_SELECTED_SECOND, False,
           "archive._field_key (line")
    expect("the prefix read by name and handed only to the key function", ROW_READ_CLEAN, True,
           owner="archive._owned_key")
    expect("F8-02: a second assembly from the prefix bound as an EXECUTE ... USING argument", USING_SECOND, False,
           ("archive.f8_second_key (line", "): cfg.prefix standing between `using`"))
    expect("F12r-07: a second assembly from the prefix renamed by unnest() in a FROM clause", FROM_UNNEST_SECOND,
           False, ("archive._f12r_unnest_key (line", "): cfg.prefix passed to unnest()"))
    expect("F12r-07: a second assembly from the prefix renamed by a VALUES row in a FROM clause",
           FROM_VALUES_SECOND, False, ("archive._f12r_values_key (line", "): cfg.prefix standing between `values`"))
    expect("a second assembly from the prefix renamed by a derived table", DERIVED_TABLE_SECOND, False,
           ("archive._derived_key (line", "): a subquery selecting the prefix standing between `from`"))
    expect("F12r-07: a second assembly in a helper from its nameless parameter, $1 || $2", POSITIONAL_SECOND,
           False, ("archive._f12r_join (line", "): $1"))
    expect("a second assembly from a named parameter read by its number", NUMBER_OF_NAMED_SECOND, False,
           ("archive._num_join (line", "): $2"))
    expect("a second assembly in a helper of this file called in a FROM clause", FROM_HELPER_SECOND, False,
           ("archive._rows_key (line", "): p_base"))
    expect("the prefix handed to a helper of this file whose body is single-quoted", UNREAD_BODY_SECOND, False,
           ("archive._quoted_key (line", "): c.prefix passed to archive._quoted_join(), whose body is not dollar-quoted"))
    expect("the prefix handed whole, compared, stored and reported, and a $1 that is a USING argument",
           STANDING_CLEAN, True, owner="archive._owned_key")
    expect("the one assembling function never claims", NO_CLAIM, False, "never names archive.object_key_owner")
    expect("no assembly visible at all", NO_ASSEMBLY, False, "no function assembles")

    # the decoys in CLEAN must not have been read as code: a lexer that leaked them would have
    # reported a second scope (top level or to_s3) and the clean case above would have failed, but
    # say so directly, since that is the property a regex-only rewrite would lose first
    _, assembly, _, _ = scan(CLEAN)
    if set(assembly) != {"archive._owned_key"}:
        print(f"SELFTEST FAIL  comment, literal and E-string decoys were read as code: {sorted(assembly)}")
        failures += 1
    else:
        print("SELFTEST PASS  comment, literal and E-string decoys are not read as code")

    if failures:
        print(f"SELFTEST: {failures} failure(s)")
        return 1
    print("SELFTEST: all checks discriminate")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    rel = argv[0] if argv else TARGET
    path = Path(rel) if argv else ROOT / rel
    if not path.is_file():
        print(f"FAIL  {rel} is missing; it was never checked")
        return 1
    v, owner = check_text(rel, path.read_text())
    for line in v:
        print("FAIL  " + line)
    if v:
        return 1
    refs, _, _, _ = scan(path.read_text())
    print(f"PASS  every object key in {rel} is assembled in {owner}, which claims it in {CLAIM_TABLE} "
          f"({refs} prefix references read)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
