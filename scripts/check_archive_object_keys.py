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
    that carries it can hand it on to the next function's parameter;
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
  * is assigned (`v := cfg.prefix`, `select prefix into v`, `v text default ...`), returned
    (`return cfg.prefix`) or selected out as a column (`for r in select prefix ...`, a SQL function's
    result), any of which would let the value travel under another name, or
  * is an argument of a call to anything this file does not define (`format`, `concat`, `coalesce`,
    `replace`, a pgpm_core function ...): a function this file defines is followed instead, through
    the parameter that receives it, since its own body is checked by the same rule.

Anything else is declaring it (`p_prefix text`), storing it (archive.configure's upsert), comparing it
or passing it along to a function of this file, and is not a key. The rule names no site and has no
exceptions; an allowlist is the thing that rots (CLAUDE.md, on `_q`).

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
pairs (`jsonb_each_text(to_jsonb(cfg))`), or a field name computed at run time (`j ->> ('pre' || 'fix')`).

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
# A relation name before `(` (a column list), not a call.
RELATION_BEFORE = {"into", "table", "update", "references", "from", "join"}
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
    within the literal (`'... in (' || x || ')'`), so a fragment cannot unbalance the rest of the file."""
    inner = [(k, t, tok[2] + ln - 1) for k, t, ln in lex(_literal_sql(tok[1])) if k != "DOLLAR"]
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
    """{name: [[param name or None, ...], ...]}: every function and procedure the file defines, with the
    parameter names of each overload in order."""
    defined = {}
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
            words = [t for t in p if t[0] == "ID"]
            while words and words[0][1] in PARAM_MODES:
                words.pop(0)
            # a name is followed by its type; a lone word is a nameless parameter's type
            names.append(words[0][1] if len(words) > 1 else None)
        defined.setdefault(toks[k + 1][1], []).append(names)
    return defined


def scan(src):
    """Returns (refs, assembly, claims, defined): the number of prefix references, {scope: [(line,
    why)]} for every assembling reference, the scopes that name archive.object_key_owner, and the
    functions the file defines.

    The prefix is followed, not spelled: a parameter of a function this file defines that receives a
    prefix at any call site carries the prefix inside that function, whatever it is named, and a scalar
    subquery that selects the prefix is a prefix reference where it stands. That takes a fixed point,
    since a parameter that carries it can hand it on to another function's parameter."""
    toks = executed_as_code(lex(src))
    defined = functions(toks)
    carriers = {}   # function name -> the parameter names that carry a prefix into it
    while True:
        refs, assembly, claims, found = _scan_once(toks, defined, carriers)
        grown = False
        for fn, names in found.items():
            if not names <= carriers.get(fn, set()):
                carriers.setdefault(fn, set()).update(names)
                grown = True
        if not grown:
            return refs, assembly, claims, set(defined)


def _scan_once(toks, defined, carriers):
    refs, assembly, claims, found = 0, {}, set(), {}
    scope, pending, body_tag = None, None, None
    parens = []                 # one dict per open parenthesis
    stmt = {"clause": None}     # the statement's own level, outside every parenthesis

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

    def judge(s, e, line, label):
        """Is the prefix reference spanning tokens s..e assembly? Records it, or records the parameter
        it is handed to when that is a parameter of a function this file defines.

        The reference is the whole value it stands for, so parentheses that only group it are part of
        it: `(cfg.prefix) || x` and `v := (to_jsonb(cfg) ->> 'prefix')` are judged at the parentheses."""
        depth = 0
        while tok(s - 1)[1] == "(" and tok(after_idx(e))[1] == ")" and len(parens) > depth \
                and parens[-1 - depth]["start"] == s - 1 and parens[-1 - depth]["callee"] is None \
                and not parens[-1 - depth]["subq"]:
            s, e, depth = s - 1, after_idx(e), depth + 1
        prev, nxt = tok(s - 1)[1], after(e)[1]
        level = parens[-1 - depth] if len(parens) > depth else stmt
        call = level.get("callee")
        named = None
        if prev in ("=>", ":=") and tok(s - 2)[0] == "ID" and tok(s - 3)[1] in ("(", ",") and call:
            named = tok(s - 2)[1]
        why = None
        if prev == "||" or nxt == "||":
            why = "concatenated with ||"
        elif (prev == ":=" and named is None) or nxt == "into" or (prev == "default" and call != "<header>") \
                or (prev == "=" and tok(s - 2)[0] == "ID" and tok(s - 3)[1] in STATEMENT_STARTS):
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
                for names in defined[call]:
                    target = named if named is not None else (
                        names[level["arg"]] if level["arg"] < len(names) else None)
                    if target is not None and target in names:
                        found.setdefault(call, set()).add(target)
            else:
                why = f"passed to {call}(), which this file does not define"
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
                stmt["clause"] = None
            elif body_tag == text:
                body_tag, scope = None, None
                stmt["clause"] = None
            continue
        if kind == "OP" and text == ";":
            if body_tag is None:
                pending = None
            stmt["clause"] = None

        # calls: what each open parenthesis belongs to, and which argument is being read
        if kind == "OP" and text == "(":
            callee = None
            if prev[0] == "ID" and prev[1] not in NOT_CALLS:
                before = tok(k - 2)[1]
                if before in ("function", "procedure"):
                    callee = "<header>"
                elif before not in RELATION_BEFORE:
                    callee = prev[1]
            parens.append({"callee": callee, "arg": 0, "subq": nxt[1] == "select", "clause": None,
                           "selects": False, "start": k})
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
                judge(k, k, line, label)
            continue

        if kind != "ID":
            continue
        if text in CLAUSE_WORDS:
            (parens[-1] if parens else stmt)["clause"] = text
        if text == CLAIM_TABLE and scope is not None:
            claims.add(scope)
        if not (PREFIX_NAME.match(text) or text in carriers.get(scope, ())):
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
            if not v or (needle and not any(needle in x for x in v)):
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
