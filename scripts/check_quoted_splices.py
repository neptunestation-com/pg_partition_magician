#!/usr/bin/env python3
"""Enforce the `_q` marker on already-quoted SQL fragments. Run by CI (the `Quoted splices` lint job).

WHY THIS EXISTS (issue #409, from the #346 audit). Several functions here build a comma-joined SQL
fragment out of pieces that are already individually `quote_ident`'d, then splice the whole
already-quoted fragment into a larger dynamic query with a bare `%s`:

    select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q from pg_attribute ...
    execute format('insert into %I.%I (%s) select %s from ...', v_nsp, v_child, v_cols_q, v_cols_q, ...)

`%s` is CORRECT there and `%I` would be a bug -- `%I` over an already-quoted string double-quotes it
into garbage, and over a comma-joined list it would quote the commas into the identifier as
well. The problem was never the code; it was that the call site looked
identical either way. Nothing at `format(..., v_cols, ...)` distinguished "already quoted, `%s` on
purpose" from "raw identifier, someone forgot `%I`", so a later edit could swap one for the other in
any of these functions and nothing would look wrong in review.

The `_q` suffix makes the invariant visible where it is used. These two checks keep the suffix
honest in both directions, so that reading it is worth something:

  CHECK 1  a text variable assigned from an identifier-quoting expression MUST end in `_q`.
           Catches the fourth copy of the pattern arriving unmarked -- which is the specific way
           #409 expected this to go wrong.
  CHECK 2  a text variable ending in `_q` MUST be assigned from one. Catches the name outliving its
           value: a refactor that leaves the suffix behind on something no longer quoted is a worse
           outcome than never having marked it, because now the `%s` beside it reads as deliberate.

SCOPE, deliberately narrow. "Identifier-quoting" means the expression itself calls `quote_ident`, or
`format`s with a `%I` (or its positional form `%3$I`), or calls one of QUOTING_HELPERS. A fragment
assembled OUT of `_q` pieces --
`v_elig := format('%1$s >= %2$L', v_ctl_q, v_lo_lit)` -- is not required to be marked: it is a
predicate, not an identifier list, and its provenance is already legible in the `_q` names it is
built from. Widening this to "any pre-built SQL fragment" would put the suffix on nearly every local
in the file, at which point it marks nothing.

Only string locals (`text`, `varchar`, `bpchar`: TEXT_TYPES) are considered, which is why the declare
blocks are parsed at all: `v_child := format('%I.%I', v_nsp, p_child)::regclass` quotes identifiers on
its way to an OID, and an OID is not a fragment anyone can splice wrong. Every DECLARE section of a body
is read, a nested block's as well as the top level's (#1004: a quoted list declared in a nested block was
never typed, so never checked).
A local's type is its declared type with CONSTANT, COLLATE, NOT NULL and the initialiser set aside (#1096:
`text default ''` was typed as that whole text, so never judged), and an initialiser (`:=`, `=` or DEFAULT)
is an assignment like any other, for both checks. A body assignment is read wherever a statement starts,
not only at the start of a line (#1031: `if p then v := quote_ident(x); end if;` was never read).

Every one of these is read by VALUE, not by spelling (#1179): a body assignment is `:=` or `=`, a SELECT's
INTO is read wherever PL/pgSQL takes it (before the select list, after it, at the end, after RETURNING),
a call is a call however it is cased, spaced, quoted or schema-qualified (`QUOTE_IDENT (`, `pg_catalog.
format(`), a name is the name PL/pgSQL resolves (`V_COLS` is `v_cols`), and a type is the type it names
(`pg_catalog.text`, `"text"`, `varchar(200)`, `character varying`).

And every BODY and every way PL/pgSQL assigns is read (#1278, #1236): a body is every dollar-quoted string
of the file, whatever its tag (`$$`, `$fn$`), found by lexing the file rather than splitting it on `$$`; a
FOR or FOREACH loop's target is assigned the loop's values as an INTO's target is, and an EXECUTE's INTO
target the list of the dynamic statement it runs; and a body is lexed for `/* block */` comments as well as
`-- line` ones, and for an escape string's backslash (`E'it\\'s'` is one literal).

  ./scripts/check_quoted_splices.py            # check the module
  ./scripts/check_quoted_splices.py --selftest # prove the checks fail when their defect is present
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FILES = [
    "pgpm_core/install.sql",
    "pgpm_hypertable/install.sql",
    "pgpm_archive/install.sql",
]

# Functions that return an already-quoted fragment built from typed inputs. A call to one of these
# is as good as calling quote_ident directly, for CHECK 2's purposes. Adding an entry here is the
# moment a new trusted builder is introduced, which is exactly when it wants a reviewer's eye.
# archive._pq_from_relation (#1055) renders a regclass, whose output function quotes the names it emits, and
# %I/%L-quotes the range, so it is one of these too.
QUOTING_HELPERS = ["archive._pq_from_item", "archive._pq_from_relation", "pgpm._detach_cmd"]

# The floor. A parser that silently stops matching -- a formatting change, a new body delimiter --
# would otherwise report a clean run having examined nothing, which is the one result this script
# must never produce (same reasoning as bench/discriminate.sh's i=0 check).
MIN_QUOTED_ASSIGNMENTS = 12

# `%I`, and the positional form `%3$I` that this module uses wherever an identifier is repeated.
# Both are identifier quoting; missing the positional one would be a silent blind spot rather than
# a loud failure, which is the kind of gap this script exists to close. format() also takes a `-` flag
# and a width (`%-10I`, `%*I`, `%1$*2$I`) before the type, and the conversion is still `I` (#1179).
SPEC_I = re.compile(r"%(?:\d+\$)?-?(?:\d+|\*(?:\d+\$)?)?I")

# A PL/pgSQL identifier as it can be written: unquoted (any case, folded to lower case) or double-quoted
# (kept exactly, `""` an escaped quote). canonical() turns either spelling into the name PL/pgSQL resolves,
# so `V_COLS`, `v_cols` and `"v_cols"` are one local (#1179: the checks matched names, calls and types by
# their exact lower-case spelling).
IDENT = r'(?:[a-z_][a-z0-9_$]*|"(?:[^"]|"")+")'


def canonical(tok: str) -> str:
    tok = tok.strip()
    if tok.startswith('"') and tok.endswith('"') and len(tok) >= 2:
        return tok[1:-1].replace('""', '"')
    return tok.lower()


def call_pattern(name: str):
    """A call of the (possibly schema-qualified) function `name`, however it is spelled: any case
    unquoted, double-quoted exactly, with whitespace before the `(` or around a qualifying `.`, and
    qualified by `pg_catalog.` or not (the qualifier is simply not part of what is matched)."""
    parts = [r'(?:(?i:%s)|"%s")' % (re.escape(p), re.escape(p)) for p in name.split(".")]
    return re.compile(r'(?<![\w$"])' + r"\s*\.\s*".join(parts) + r"\s*\(")


QUOTE_IDENT_CALL = call_pattern("quote_ident")
FORMAT_CALL = call_pattern("format")
HELPER_CALLS = [call_pattern(h) for h in QUOTING_HELPERS]

# The types a quoted list can be held in and spliced from with `%s`, however they are spelled: `text`,
# `pg_catalog.text`, `"text"`, `varchar(200)`, `character varying`, `bpchar` (#1179: only the word `text`
# was typed). Two boundaries, both deliberate. An OID type (`regclass`) is not one: its value is not a
# fragment anyone can splice wrong. Nor is `name`: it is the RAW identifier's type throughout this module
# (`v_nsp name` beside every `%I`), its 63 bytes cannot hold a column list, and the expressions that fill
# one quote on the way to an OID (`pgpm._delta_seq(format('%I.%I', ...)::regclass)` returns a raw name),
# which judging the expression's text would misread as a quoted value.
TEXT_TYPES = {"text", "varchar", "character varying", "char", "character", "bpchar"}


def type_key(typ: str) -> str:
    """A declared type reduced to the type it names: typmods dropped, a `pg_catalog.` qualifier dropped,
    each part canonical() (so `"text"` and `TEXT` are text) and whitespace collapsed."""
    t = re.sub(r"\([^)]*\)", " ", typ)
    parts = [canonical(p) if p.strip().startswith('"') else " ".join(p.lower().split())
             for p in re.split(r"\s*\.\s*", t.strip())]
    if len(parts) == 2 and parts[0] == "pg_catalog":
        parts = parts[1:]
    if re.fullmatch(r'\s*(?:pg_catalog\s*\.\s*)?"char"\s*', t):
        return '"char"'          # the one-byte "char" is a different type from the unquoted char
    return ".".join(parts)


def block_comment_end(text: str, i: int) -> int:
    """The offset just past the block comment that opens at `i` (`/*`). Block comments NEST in PostgreSQL
    and in PL/pgSQL, which lexes with the core scanner, so `/* a /* b */ c */` is one comment; one left
    open runs to the end of the text."""
    depth, n = 0, len(text)
    while i < n:
        if text.startswith("/*", i):
            depth, i = depth + 1, i + 2
        elif text.startswith("*/", i):
            depth, i = depth - 1, i + 2
            if depth == 0:
                return i
        else:
            i += 1
    return n


def escape_string(text: str, i: int) -> bool:
    """The `'` at `i` opens an escape string (`E'...'`, `e'...'`), the one kind of literal whose backslash
    escapes the next character, a quote included: `E'it\\'s'` is one literal. The `E` must be a token of
    its own, not the last letter of a name. Every other literal keeps its backslashes as text
    (standard_conforming_strings), so `'C:\\'` ends at its second quote."""
    return (i > 0 and text[i - 1] in "eE"
            and not (i > 1 and re.match(r'[\w$"]', text[i - 2])))


def strip_noise(body: str) -> str:
    """Blank out comments and the contents of single-quoted strings, KEEPING `%I`.

    Blanking literals is what stops a `;` or a `,` inside one -- `', '`, or a whole dynamic
    statement -- from being read as a statement or select-list boundary, and stops the word
    `select` inside a dynamic statement from looking like a real one. `%I` survives because it is
    the signal: `format('d.%I = s.%I', ...)` quotes identifiers exactly as `quote_ident` does.

    Character-for-character length-preserving, so an offset into the result is an offset into the
    original and reported line numbers are real. `%%` inside a literal is format()'s escaped percent, so
    `'%%I'` is the text `%I`, not a conversion, and is blanked (#1179). A double-quoted identifier is
    copied as it stands, so a `'` inside one does not open a literal.

    Both kinds of comment are blanked, a `/* block */` as well as a `-- line` (#1236, B08-01): a `;`, a
    `begin` or an apostrophe left standing in a block comment ended an assignment early, cut a DECLARE
    section short or opened a literal, and a block comment before an assignment kept it from starting a
    statement, so it was never read. An escape string's backslash escapes the character after it (#1236,
    B08-02): read as a plain literal, `E'it\\'s'` closed at its escaped quote and the next quote opened a
    literal that blanked the code after it.
    """
    out = []
    i, n = 0, len(body)
    while i < n:
        c = body[i]
        if c == "/" and body.startswith("/*", i):
            end = block_comment_end(body, i)
            out.append(re.sub(r"[^\n]", " ", body[i:end]))
            i = end
        elif c == '"':
            j = i + 1
            while j < n:
                if body[j] == '"':
                    if j + 1 < n and body[j + 1] == '"':
                        j += 2
                        continue
                    break
                j += 1
            out.append(body[i:j + 1])
            i = j + 1
        elif c == "'":
            escapes = escape_string(body, i)
            out.append("'")
            i += 1
            while i < n:
                if escapes and body[i] == "\\" and i + 1 < n:   # E'...': a backslash escapes what follows
                    out.append(" " + ("\n" if body[i + 1] == "\n" else " "))
                    i += 2
                    continue
                if body[i] == "'":
                    if i + 1 < n and body[i + 1] == "'":   # '' escape inside a literal
                        out.append("  ")
                        i += 2
                        continue
                    out.append("'")
                    i += 1
                    break
                if body.startswith("%%", i):
                    out.append("  ")
                    i += 2
                    continue
                spec = SPEC_I.match(body, i)
                if spec:
                    out.append(spec.group(0))
                    i = spec.end()
                    continue
                out.append(" " if body[i] != "\n" else "\n")
                i += 1
        elif c == "-" and i + 1 < n and body[i + 1] == "-":
            while i < n and body[i] != "\n":
                out.append(" ")
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def split_top_level(text: str, sep: str) -> list:
    """Split on `sep` only where parenthesis depth is zero. Input must already be strip_noise'd."""
    parts, depth, cur, i, n = [], 0, [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if depth == 0 and text.startswith(sep, i):
            parts.append("".join(cur))
            cur = []
            i += len(sep)
            continue
        cur.append(c)
        i += 1
    parts.append("".join(cur))
    return parts


# A dollar quote's delimiter, `$$` or `$tag$`: the tag is an identifier with no `$` in it, PostgreSQL's own
# rule. It cannot continue a name, because `$` is legal inside an identifier (`a$b$` is a name), and a `$`
# followed by a digit is a parameter (`$1`), not a tag.
DOLLAR_QUOTE = re.compile(r"(?<![\w$])\$(?:[^\W\d][\w]*)?\$")


def bodies(text: str):
    """Yield (body_text, offset) for each dollar-quoted string at the top level of the file, which is every
    function body, procedure body and DO block, whatever its tag: `$$`, `$fn$`, `$body$` (#1278, F8-08).

    The file is LEXED, not split: comments, single-quoted literals (an escape string's backslashes
    included) and double-quoted identifiers are stepped over, so a `$$` written inside one of them opens
    nothing, and a body runs to the next occurrence of its OWN tag, so a `$q$` string nested in a `$$` body
    stays inside it. Splitting on the bare `$$` never read a body tagged anything else, and nothing outside
    this script holds every body to that tag. One left open runs to the end of the file.
    """
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "-" and text.startswith("--", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif c == "/" and text.startswith("/*", i):
            i = block_comment_end(text, i)
        elif c == "'":
            escapes = escape_string(text, i)
            i += 1
            while i < n:
                if escapes and text[i] == "\\":
                    i += 2
                elif text.startswith("''", i):
                    i += 2
                elif text[i] == "'":
                    i += 1
                    break
                else:
                    i += 1
        elif c == '"':
            i += 1
            while i < n:
                if text.startswith('""', i):
                    i += 2
                elif text[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
        elif c == "$" and DOLLAR_QUOTE.match(text, i):
            tag = DOLLAR_QUOTE.match(text, i).group(0)
            start = i + len(tag)
            end = text.find(tag, start)
            end = n if end < 0 else end
            yield text[start:end], start
            i = end + len(tag)
        else:
            i += 1


# Where a declaration's initialiser starts: PL/pgSQL takes `:=`, `=` and DEFAULT alike (#1096).
DECL_INIT = re.compile(r"(?is):=|=|\bdefault\b")
# A declaration's name and its type, CONSTANT set aside: `name [constant] type`.
DECL_HEAD = re.compile(r"(?is)\s*(?P<name>" + IDENT + r")\s+(?:constant\s+)?(?P<type>\S.*?)\s*\Z")


def declarations(body: str):
    """Yield (name, type, initialiser or None, offset of the initialiser) for every local of EVERY
    DECLARE section of the body.

    A nested `declare ... begin` block declares locals as real as the top-level ones, and reading only
    the first section left them untyped, so CHECK 1 never judged a quoted list declared there (issue
    #1004).

    The type is the declaration's TYPE, not the rest of its text (#1096). PL/pgSQL reads
    `name [constant] type [collate c] [not null] [{default | := | =} expr]`, and taking everything after
    the name typed `v text default ''` as "text default ''", `v text not null` as "text not null" and
    `v constant text` as "constant text", none of them `text`, so neither check ever judged them. The
    initialiser is returned as an assignment of its own (#1031, A1031-3): `v_cols text :=
    quote_ident(...)` gives v_cols its value exactly as a body assignment does.
    """
    for m in re.finditer(r"(?is)\bdeclare\b(.*?)\bbegin\b", body):
        pos = m.start(1)
        for decl in m.group(1).split(";"):
            start, pos = pos, pos + len(decl) + 1
            init = DECL_INIT.search(decl)
            head = decl[:init.start()] if init else decl
            head = re.sub(r"(?is)\bcollate\s+(?:\"[^\"]*\"|\S)+|\bnot\s+null\b", " ", head)
            d = DECL_HEAD.match(head)
            if d:
                expr = decl[init.end():].strip() if init else None
                yield (canonical(d.group("name")), type_key(d.group("type")), expr or None,
                       start + (init.end() if init else 0))


def declared_types(body: str) -> dict:
    """Map local name -> the set of types it is declared with (see declarations()). A name declared in
    more than one block keeps every type it is given: the checks ask whether it is ever a `text` local,
    and the assignments are not scoped to the block that declares them.
    """
    types = {}
    for name, typ, _, _ in declarations(body):
        types.setdefault(name, set()).add(typ)
    return types


def quotes_identifiers(expr: str) -> bool:
    """The expression itself applies identifier quoting (CHECK 1's trigger): it calls quote_ident, or
    formats with a `%I`, or calls a QUOTING_HELPERS function, in any spelling of the call (#1179)."""
    if QUOTE_IDENT_CALL.search(expr):
        return True
    if FORMAT_CALL.search(expr) and SPEC_I.search(expr):
        return True
    return any(h.search(expr) for h in HELPER_CALLS)


# A `_q` local named in an expression, in any spelling of its name.
Q_NAME = re.compile(r'(?i)(?<![\w$"])[a-z_][a-z0-9_$]*_q(?![\w$])|"(?:[^"]|"")*_q"')


def carries_quoting(expr: str) -> bool:
    """The expression's value is quoted, whether it did the quoting or inherited it (CHECK 2)."""
    return quotes_identifiers(expr) or Q_NAME.search(expr) is not None


# The INTO clause of a plpgsql statement: `into [strict] target [, target ...]`. PL/pgSQL takes it
# almost anywhere in a SELECT (`select list into v from`, `select into v list from`, `select list from t
# into v`) and after RETURNING (#1179: only the list-first form was read).
INTO = re.compile(r"(?is)(?<![\w$])into\s+(?:strict\s+)?"
                  r"(?P<targets>" + IDENT + r"(?:\s*,\s*" + IDENT + r")*)")
# Where a top-level select list ends.
LIST_END = re.compile(r"(?is)(?<![\w$])(?:from|where|group|having|window|order|limit|offset|union|"
                      r"intersect|except|fetch|for)(?![\w$])")


def depth0(text: str):
    """The set of offsets of `text` that are outside every parenthesis."""
    out, depth = set(), 0
    for i, c in enumerate(text):
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if depth == 0:
            out.add(i)
    return out


def select_into(clean: str):
    """Yield (target, expression, offset) for the INTO clause of every statement, in any of the places
    PL/pgSQL takes it: the value assigned is the list of the last top-level RETURNING or SELECT before the
    INTO (the INTO's own: the text before it can carry a block head with a query of its own, `for r in
    select ... loop select ... into v`), read with the INTO clause cut out. Statements are split on `;`,
    which strip_noise has left only between statements; a statement with neither a top-level SELECT nor
    a RETURNING before its INTO (EXECUTE, FETCH, INSERT INTO's own INTO) assigns nothing this check reads.
    """
    for st in re.finditer(r"[^;]+", clean):
        stmt = st.group(0)
        top = depth0(stmt)
        for m in INTO.finditer(stmt):
            if m.start() not in top:
                continue
            before = re.search(r"(?is)([a-z_]+)\s*\Z", stmt[:m.start()])
            if before and before.group(1).lower() in ("insert", "merge"):
                continue
            rest = stmt[:m.start()] + " " * (m.end() - m.start()) + stmt[m.end():]
            rtop = depth0(rest)
            heads = [k for k in re.finditer(
                r"(?is)(?<![\w$])(?:(?P<ret>returning)|select)(?![\w$])\s*(?:(?:distinct|all)(?![\w$]))?", rest)
                if k.start() in rtop and k.start() < m.start()]
            if not heads:
                break
            head = heads[-1]
            lst = rest[head.end():]
            if not head.group("ret"):
                ends = [k.start() for k in LIST_END.finditer(lst) if head.end() + k.start() in rtop]
                if ends:
                    lst = lst[:ends[0]]
            targets = [canonical(t) for t in split_top_level(m.group("targets"), ",") if t.strip()]
            exprs = [e.strip() for e in split_top_level(lst, ",")]
            if len(exprs) != len(targets):
                exprs = [lst] * len(targets)   # cannot pair them; judge each on the whole list
            for target, expr in zip(targets, exprs):
                yield target, expr, st.start() + m.start()
            break


# The head of a query's value list: a top-level SELECT (after any DISTINCT or ALL) or a RETURNING.
VALUE_HEAD = re.compile(
    r"(?is)(?<![\w$])(?:(?P<ret>returning)|select)(?![\w$])\s*(?:(?:distinct|all)(?![\w$]))?")
# The words a query can start with, as opposed to a cursor's name (`for r in cur loop`).
QUERY_START = re.compile(r"(?is)\s*(?:\(|(?:select|with|values|table|insert|update|delete|merge)(?![\w$]))")


def value_list(query: str) -> list:
    """The expressions a query (strip_noise'd) returns, in order: its RETURNING list when it has a top-level
    one, else the list of its first top-level SELECT, cut where the clause after it starts. A query with
    neither (VALUES, a parenthesised query) is judged whole, as one item."""
    top = depth0(query)
    heads = [k for k in VALUE_HEAD.finditer(query) if k.start() in top]
    rets = [k for k in heads if k.group("ret")]
    if not heads:
        return [query]
    head = rets[-1] if rets else heads[0]
    lst = query[head.end():]
    if not head.group("ret"):
        ends = [k.start() for k in LIST_END.finditer(lst) if head.end() + k.start() in top]
        if ends:
            lst = lst[:ends[0]]
    return [e.strip() for e in split_top_level(lst, ",")]


def paired(targets_text: str, values: list):
    """Pair each target of a comma-separated target list with the value it is given; when the counts differ
    the pairing is unknowable, so each target is judged on the whole list."""
    targets = [canonical(t) for t in split_top_level(targets_text, ",") if t.strip()]
    if len(values) != len(targets):
        values = [", ".join(values)] * len(targets)
    return zip(targets, values)


def top_keyword(text: str, start: int, words: str):
    """The first of `words` (a regex alternation) at parenthesis depth zero in text[start:], as a match, or
    None. Depth is counted from `start`, which must itself be at depth zero."""
    depth = 0
    pat = re.compile(r"(?is)(?<![\w$])(?:" + words + r")(?![\w$])")
    i = start
    while i < len(text):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0:
            m = pat.match(text, i)
            if m:
                return m
        i += 1
    return None


def literal_text(raw: str) -> str:
    """The text the string literals of an expression (raw, not strip_noise'd) spell, one level of quoting
    undone, joined by spaces: what an EXECUTE runs when its statement is written out, as a literal, a
    format() template or a concatenation of literals. The expression's code is dropped, so a value spliced
    in with `||` or `%s` is not part of the statement read."""
    out, i, n = [], 0, len(raw)
    while i < n:
        c = raw[i]
        if c == "'":
            escapes = escape_string(raw, i)
            i += 1
            buf = []
            while i < n:
                if escapes and raw[i] == "\\" and i + 1 < n:
                    buf.append(raw[i + 1])
                    i += 2
                elif raw.startswith("''", i):
                    buf.append("'")
                    i += 2
                elif raw[i] == "'":
                    i += 1
                    break
                else:
                    buf.append(raw[i])
                    i += 1
            out.append("".join(buf))
        elif c == "$" and DOLLAR_QUOTE.match(raw, i):
            tag = DOLLAR_QUOTE.match(raw, i).group(0)
            end = raw.find(tag, i + len(tag))
            end = n if end < 0 else end
            out.append(raw[i + len(tag):end])
            i = end + len(tag)
        else:
            i += 1
    return " ".join(out)


def dynamic_values(raw_expr: str) -> list:
    """The value list of the statement an EXECUTE's expression spells out (see literal_text()). A `%I` in a
    format() template quotes an identifier IN the dynamic statement, never in the value that comes back, so
    the template's own conversions are not read as quoting: only a quoting call the dynamic statement
    itself makes in its list (`execute 'select quote_ident(relname) from pg_class' into v`) is."""
    return value_list(strip_noise(literal_text(raw_expr)))


# The head of a FOR or FOREACH loop: its target list, then IN.
LOOP_HEAD = re.compile(r"(?is)(?<![\w$])(?P<kw>foreach|for)\s+(?P<targets>" + IDENT + r"(?:\s*,\s*" + IDENT
                       + r")*)\s+(?:slice\s+\d+\s+)?in(?![\w$])")


def loop_targets(clean: str, raw: str):
    """Yield (target, expression, offset) for the target of every FOR and FOREACH loop (#1278, F8-01).

    A loop's target is assigned exactly as an INTO's is: `for v in select quote_ident(attname) from ...
    loop` gives v each row's quoted name, and `foreach v in array a loop` each element of a. A query loop's
    targets are paired with its value list (value_list()), a `for ... in execute` loop's with the dynamic
    statement's (dynamic_values()), and a FOREACH's are judged on the array expression. An integer loop
    (`for i in 1..n`, `in reverse`) assigns an integer and a cursor loop (`for r in cur`) a record; neither
    is read.
    """
    for m in LOOP_HEAD.finditer(clean):
        end = top_keyword(clean, m.end(), "loop")
        if end is None:
            continue
        src = clean[m.end():end.start()]
        if m.group("kw").lower() == "foreach":
            values = [re.sub(r"(?is)^\s*array(?![\w$])", "", src).strip()]
        elif re.match(r"(?is)\s*reverse(?![\w$])", src) or ".." in src:
            continue
        elif re.match(r"(?is)\s*execute(?![\w$])", src):
            using = top_keyword(clean, m.end(), "using|loop")
            stop = using.start() if using else end.start()
            start = re.match(r"(?is)\s*execute", src).end() + m.end()
            values = dynamic_values(raw[start:stop])
        elif QUERY_START.match(src):
            values = value_list(src)
        else:
            continue
        for target, expr in paired(m.group("targets"), values):
            yield target, expr, m.start("targets")


EXECUTE = re.compile(r"(?is)(?<![\w$])execute(?![\w$])")


def execute_into(clean: str, raw: str):
    """Yield (target, expression, offset) for the INTO of every EXECUTE (#1278, F8-01): the target is given
    the value list of the dynamic statement (dynamic_values()). PL/pgSQL takes INTO and USING after the
    command string in either order; an EXECUTE ended by LOOP is a `for ... in execute` loop's, read by
    loop_targets(), and one with no INTO assigns nothing."""
    for st in re.finditer(r"[^;]+", clean):
        stmt, base = st.group(0), st.start()
        top = depth0(stmt)
        for e in EXECUTE.finditer(stmt):
            if e.start() not in top:
                continue
            first = top_keyword(stmt, e.end(), "into|using|loop")
            if first is None or first.group(0).lower() == "loop":
                continue
            into = first if first.group(0).lower() == "into" else top_keyword(stmt, first.end(), "into|loop")
            if into is None or into.group(0).lower() != "into":
                continue
            m = INTO.match(stmt, into.start())
            if not m:
                continue
            for target, expr in paired(m.group("targets"), dynamic_values(raw[base + e.end():base + first.start()])):
                yield target, expr, base + m.start()


# A plain assignment: `name :=` or `name =` (PL/pgSQL takes both, #1179) where a STATEMENT starts, which
# is the start of the body, after a `;`, or after the block keyword a statement can follow (`begin`,
# `then`, `else`, `loop`). Anchored there rather than at the start of a line (#1031, A1031-3 and F8-01):
# `if p then v := quote_ident(x); end if;` is a statement that does not begin its own line, and the line
# anchor never read it. `:=` also appears in named-notation arguments (`f(p_x := ...)`), after a `(` or a
# `,`, which is no statement start, and in DECLARE initialisers, which declarations() reads with the type
# between.
ASSIGN = re.compile(
    r"(?is)(?:\A|(?<=;)|(?<=\bbegin)|(?<=\bthen)|(?<=\belse)|(?<=\bloop))\s*"
    r"(?<![\w$])(?P<target>" + IDENT + r")\s*(?::=|=)\s*(?P<expr>[^;]+);")


def assignments(clean: str, raw: str = None):
    """Yield (target, expression, match_start) for every assignment: plain, SELECT INTO, a FOR or FOREACH
    loop's target, an EXECUTE's INTO, and a DECLARE initialiser.

    `raw` is the body before strip_noise (the same length, so an offset into one is an offset into the
    other); an EXECUTE's dynamic statement is read out of it, because strip_noise blanks it. The statement
    is read for the quoting calls IT makes in the list it returns (dynamic_values()); a %I in the template
    quotes an identifier in THAT statement, never in the value coming back through INTO.
    """
    raw = clean if raw is None else raw
    yield from select_into(clean)

    yield from loop_targets(clean, raw)

    yield from execute_into(clean, raw)

    for m in ASSIGN.finditer(clean):
        yield canonical(m.group("target")), m.group("expr"), m.start("target")

    for name, _, expr, pos in declarations(clean):
        if expr is not None:
            yield name, expr, pos


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def check_text(path_label: str, text: str):
    """Return (violations, quoted_assignment_count) for one file's text."""
    violations, quoted = [], 0
    for body, offset in bodies(text):
        clean = strip_noise(body)
        types = declared_types(clean)
        for target, expr, pos in assignments(clean, body):
            if not types.get(target, set()) & TEXT_TYPES:
                continue
            line = line_of(text, offset + pos)
            marked = target.endswith("_q")
            if quotes_identifiers(expr):
                quoted += 1
                if not marked:
                    violations.append(
                        f"{path_label}:{line}  {target} is assigned from an identifier-quoting "
                        f"expression but is not _q-suffixed")
            elif marked and not carries_quoting(expr):
                violations.append(
                    f"{path_label}:{line}  {target} is _q-suffixed but nothing in its assignment "
                    f"quotes an identifier")
    return violations, quoted


CLEAN_FIXTURE = """
create or replace function f() returns void language plpgsql as $$
declare v_nsp name; v_cols_q text; v_child regclass; v_elig text; v_ctl_q text; v_pair_q text;
begin
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q from pg_attribute;
  v_ctl_q := quote_ident('c');
  v_pair_q := format('%1$I = s.%1$I', 'k');
  v_child := format('%I.%I', v_nsp, 't')::regclass;
  v_elig := format('%1$s >= %2$L', v_ctl_q, 'x');
  execute format('insert into %I (%s) select %s', v_nsp, v_cols_q, v_cols_q);
end;
$$;
"""

UNMARKED_FIXTURE = CLEAN_FIXTURE.replace("v_cols_q", "v_cols")

# Issue #1004: the #409 shape again, but with the quoted list declared in a NESTED block of a body
# that has a top-level DECLARE of its own. Typing only the first `declare ... begin` left v_cols
# untyped, so CHECK 1 never looked at it. The marked twin must stay clean and still be counted, so
# reading nested blocks is shown to add sight rather than noise.
NESTED_FIXTURE = """
create or replace function g() returns bigint language plpgsql as $$
declare v_n bigint; v_nsp name;
begin
  declare v_cols text; v_rel regclass;
  begin
    select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols from pg_attribute;
    execute format('select count(*) from (select %s from %I.t) s', v_cols, v_nsp) into v_n;
  end;
  return v_n;
end;
$$;
"""
NESTED_MARKED_FIXTURE = NESTED_FIXTURE.replace("v_cols", "v_cols_q")
LYING_FIXTURE = CLEAN_FIXTURE.replace("v_elig text", "v_elig_q text").replace("v_elig :=", "v_elig_q :=")

# Review pass 10 and #1031: the #409 shape in the three places the parser did not read it. Each body
# assigns one quoted list, unmarked, and the marked twin of each must pass check 1 and still be counted
# (a twin that starts out as '' is check 2's business, judged below).
SHAPE_BODY = """
create or replace function h(p_on boolean) returns bigint language plpgsql as $$
declare v_nsp name := 'public'; {decl}; v_n bigint;
begin
  {stmt}
  execute format('select count(*) from (select %s from %I.t) s', v_cols, v_nsp) into v_n;
  return v_n;
end;
$$;
"""
SHAPES = {
    # #1096 (F8-04): the type is `text`, whatever follows it or precedes it in the declaration
    "declared `text default ''`": ("v_cols text default ''", "v_cols := quote_ident('c');"),
    "declared `text not null := ''`": ("v_cols text not null := ''", "v_cols := quote_ident('c');"),
    "declared `constant text`": ("v_cols constant text := quote_ident('c')", "null;"),
    # #1031 A1031-3 (G21): the DECLARE initialiser is an assignment, in either spelling
    "quoted in its DECLARE initialiser": ("v_cols text := quote_ident('c')", "null;"),
    "quoted in a DEFAULT initialiser": ("v_cols text default format('%I', 'c')", "null;"),
    # #1031 (F8-01): a statement that does not begin its own line
    "assigned in a one-line if": ("v_cols text", "if p_on then v_cols := quote_ident('c'); end if;"),
    # #1179 (F8-04): the same value in every other spelling PL/pgSQL accepts
    "assigned with `=`": ("v_cols text", "v_cols = quote_ident('c');"),
    "quoted by `quote_ident (`": ("v_cols text", "v_cols := quote_ident ('c');"),
    "quoted by `format (` with %I": ("v_cols text", "v_cols := format ('%I', 'c');"),
    "quoted by `QUOTE_IDENT(`": ("v_cols text", "v_cols := QUOTE_IDENT('c');"),
    "quoted by `pg_catalog.quote_ident(`": ("v_cols text", "v_cols := pg_catalog.quote_ident('c');"),
    "quoted by `FORMAT(` with a width `%-20I`": ("v_cols text", "v_cols := FORMAT('%-20I', 'c');"),
    "declared `varchar`": ("v_cols varchar", "v_cols := quote_ident('c');"),
    "declared `character varying(200)`": ("v_cols character varying(200)", "v_cols := quote_ident('c');"),
    "declared `pg_catalog.text`": ("v_cols pg_catalog.text", "v_cols := quote_ident('c');"),
    "declared `TEXT`": ("v_cols TEXT", "v_cols := quote_ident('c');"),
    "declared and assigned as `V_COLS`": ("V_COLS text", "V_COLS := quote_ident('c');"),
    "assigned by `select into v list`": ("v_cols text", "select into v_cols quote_ident('c');"),
    "assigned by `select list from t into v`": (
        "v_cols text", "select string_agg(quote_ident(attname), ', ') from pg_attribute into v_cols;"),
    "assigned by `returning list into v`": (
        "v_cols text", "update pg_temp.t set k = k returning quote_ident('c') into v_cols;"),
    "assigned by a SELECT INTO after a FOR loop's own query": (
        "v_cols text", "for v_n in select 1 loop select quote_ident('c') into v_cols; end loop;"),
    # #1278 (F8-01, F12-06): a FOR or FOREACH loop's target, and an EXECUTE's INTO, are assignments too
    "assigned as a FOR loop's target": (
        "v_cols text", "for v_cols in select string_agg(quote_ident(attname), ', ') from pg_attribute loop null; "
                       "end loop;"),
    "assigned as the second of a FOR loop's targets": (
        "v_cols text; v_i int", "for v_i, v_cols in select 1, quote_ident('c') loop null; end loop;"),
    "assigned as a FOR ... IN EXECUTE loop's target": (
        "v_cols text", "for v_cols in execute 'select quote_ident(''c'')' loop null; end loop;"),
    "assigned as a FOREACH loop's target": (
        "v_cols text", "foreach v_cols in array array[quote_ident('c')] loop null; end loop;"),
    "assigned by EXECUTE ... INTO": ("v_cols text", "execute 'select quote_ident(''c'')' into v_cols;"),
    "assigned by EXECUTE format() USING ... INTO": (
        "v_cols text", "execute format('select quote_ident($1) from %I.t', v_nsp) using 'c' into strict v_cols;"),
    # #1236 (B08-01, F12-03): a block comment is a comment, before an assignment or inside one
    "assigned behind a block comment": ("v_cols text", "/* the quoted list */ v_cols := quote_ident('c');"),
    "assigned with a `;` in a block comment": ("v_cols text", "v_cols := /* ; */ quote_ident('c');"),
    "assigned behind a nested block comment holding `;` and `'`": (
        "v_cols text", "/* a /* b */ it's; */ v_cols := quote_ident('c');"),
    # #1236 (B08-02, F12-05): an escape string's backslash escapes its quote, and only an escape string's does
    "assigned after an E'' string's escaped quote": ("v_cols text; v_x text", "v_x := E'it\\'s'; v_cols := quote_ident('c');"),
    "assigned after an e'' string ending in `\\\\`": ("v_cols text; v_x text", "v_x := e'a\\\\'; v_cols := quote_ident('c');"),
    "assigned after a plain string ending in a backslash": (
        "v_cols text; v_x text", "v_x := 'C:\\'; v_cols := quote_ident('c');"),
}


def shape_fixture(name: str, marked: bool) -> str:
    decl, stmt = SHAPES[name]
    src = SHAPE_BODY.format(decl=decl, stmt=stmt)
    return re.sub(r"(?i)\bv_cols\b", lambda m: m.group(0) + "_q", src) if marked else src


def selftest() -> int:
    """Prove both checks fail when their defect is present. A check only verified against correct
    code is not verified: it is green there whether or not it looks at anything."""
    failures = 0

    v, q = check_text("clean.sql", CLEAN_FIXTURE)
    if v:
        print("SELFTEST FAIL  the clean fixture reported violations:")
        for line in v:
            print("        " + line)
        failures += 1
    elif q != 3:
        print(f"SELFTEST FAIL  the clean fixture should have 3 quoting assignments, saw {q}")
        failures += 1
    else:
        print("SELFTEST PASS  clean fixture: no violations, all three quoting assignments seen "
              "(quote_ident, %I and the positional %1$I)")

    v, _ = check_text("unmarked.sql", UNMARKED_FIXTURE)
    if not any("not _q-suffixed" in x and "v_cols" in x for x in v):
        print("SELFTEST FAIL  check 1 did not catch an unmarked quote_ident'd fragment")
        failures += 1
    else:
        print("SELFTEST PASS  check 1 catches an unmarked quote_ident'd fragment")

    v, _ = check_text("nested.sql", NESTED_FIXTURE)
    if not any("not _q-suffixed" in x and "v_cols " in x for x in v):
        print("SELFTEST FAIL  check 1 did not catch an unmarked quote_ident'd fragment declared in a "
              "nested block (#1004)")
        failures += 1
    else:
        print("SELFTEST PASS  check 1 catches an unmarked quote_ident'd fragment declared in a nested block")

    v, q = check_text("nested_marked.sql", NESTED_MARKED_FIXTURE)
    if v or q != 1:
        print(f"SELFTEST FAIL  the marked nested-block fragment should be clean and counted once, saw "
              f"{q} quoting assignment(s) and {v}")
        failures += 1
    else:
        print("SELFTEST PASS  a marked fragment declared in a nested block is clean and counted")

    # v_elig_q is built with %L and %s off an already-_q variable, so it inherits quoting and must
    # NOT trip check 2. The lying case is the suffix on something with no quoting anywhere near it.
    v, _ = check_text("lying.sql", LYING_FIXTURE)
    if v:
        print("SELFTEST FAIL  a _q fragment built out of another _q fragment was wrongly flagged:")
        for line in v:
            print("        " + line)
        failures += 1
    else:
        print("SELFTEST PASS  check 2 accepts a _q fragment built out of another _q fragment")

    lying = CLEAN_FIXTURE.replace("v_elig text", "v_elig_q text") \
                         .replace("v_elig := format('%1$s >= %2$L', v_ctl_q, 'x');",
                                  "v_elig_q := 'literally nothing quoted here';")
    v, _ = check_text("lying2.sql", lying)
    if not any("nothing in its assignment" in x and "v_elig_q" in x for x in v):
        print("SELFTEST FAIL  check 2 did not catch a _q suffix on an unquoted value")
        failures += 1
    else:
        print("SELFTEST PASS  check 2 catches a _q suffix on an unquoted value")

    for name in SHAPES:
        v, _ = check_text("shape.sql", shape_fixture(name, False))
        mv, mq = check_text("shape_q.sql", shape_fixture(name, True))
        if not any("not _q-suffixed" in x and "v_cols " in x for x in v):
            print(f"SELFTEST FAIL  check 1 did not catch an unmarked quoted list {name}")
            failures += 1
        elif any("not _q-suffixed" in x for x in mv) or mq != 1:
            print(f"SELFTEST FAIL  the marked twin of a quoted list {name} should pass check 1 and be counted "
                  f"once, saw {mq} quoting assignment(s) and {mv}")
            failures += 1
        else:
            print(f"SELFTEST PASS  check 1 catches an unmarked quoted list {name}; its marked twin passes it")

    # #1278 (F8-08): every dollar-quoted body is read, whatever its tag, and a `$$` that is not a delimiter (in
    # a comment, in a literal) opens nothing; each with its marked twin clean and counted once
    for what, wrap in [
            ("a body tagged $fn$", lambda s: s.replace("$$", "$fn$")),
            ("a body tagged $body$ holding a `$$` in a nested $q$ string",
             lambda s: s.replace("$$", "$body$").replace("begin\n", "begin\n  v_n := length($q$ $$ $q$);\n", 1)),
            ("a body after `$$` in a line comment, a block comment and a literal",
             lambda s: "-- bodies are $$-quoted\n/* so is $$ this */\nselect 'one $$ two';\n" + s)]:
        v, _ = check_text("tag.sql", wrap(shape_fixture("assigned in a one-line if", False)))
        mv, mq = check_text("tag_q.sql", wrap(shape_fixture("assigned in a one-line if", True)))
        if not any("not _q-suffixed" in x and "v_cols " in x for x in v):
            print(f"SELFTEST FAIL  check 1 did not catch an unmarked quoted list in {what}")
            failures += 1
        elif mv or mq != 1:
            print(f"SELFTEST FAIL  the marked twin in {what} should be clean and counted once, saw {mq} quoting "
                  f"assignment(s) and {mv}")
            failures += 1
        else:
            print(f"SELFTEST PASS  check 1 catches an unmarked quoted list in {what}; its marked twin passes it")

    # #1278: reading an EXECUTE's dynamic statement must not read a template's own %I as the value's quoting:
    # `select %I from t` returns a column's value, not a quoted name
    v, q = check_text("exec_raw.sql", SHAPE_BODY.format(
        decl="v_cols_q text := quote_ident('c'); v_raw text", stmt="execute format('select %I from t', 'c') into v_raw;"
    ).replace("v_cols,", "v_cols_q,"))
    if v or q != 1:
        print(f"SELFTEST FAIL  an EXECUTE whose template quotes with %I should leave its unmarked INTO target alone, "
              f"saw {q} quoting assignment(s) and {v}")
        failures += 1
    else:
        print("SELFTEST PASS  an EXECUTE template's own %I is not read as quoting the value it returns")

    # #1096: check 2 reads the same declarations, so an unearned _q declared `text default ''` is judged
    lying_default = SHAPE_BODY.format(decl="v_cols_q text default ''",
                                      stmt="v_cols_q := 'nothing quoted here';").replace("v_cols,", "v_cols_q,")
    v, _ = check_text("lying_default.sql", lying_default)
    if not any("nothing in its assignment" in x and "v_cols_q" in x for x in v):
        print("SELFTEST FAIL  check 2 did not catch a _q suffix on an unquoted value declared `text default ''`")
        failures += 1
    else:
        print("SELFTEST PASS  check 2 catches a _q suffix on an unquoted value declared `text default ''`")

    # An initialiser is an assignment for check 2 as well: a _q local that starts out as '' holds nothing
    # quoted, exactly as `v_q := ''` in the body does
    lying_init = SHAPE_BODY.format(decl="v_cols_q text := ''", stmt="null;").replace("v_cols,", "v_cols_q,")
    v, _ = check_text("lying_init.sql", lying_init)
    if not any("nothing in its assignment" in x and "v_cols_q" in x for x in v):
        print("SELFTEST FAIL  check 2 did not judge a _q local's DECLARE initialiser")
        failures += 1
    else:
        print("SELFTEST PASS  check 2 judges a _q local's DECLARE initialiser")

    # A named-notation argument is not an assignment, though it sits in a statement after `then`: an
    # unmarked text local named as the argument must not be judged, while the statement beside it is
    named = SHAPE_BODY.format(decl="v_cols_q text; v_arg text",
                              stmt="if p_on then perform g(v_arg := quote_ident('c')); end if; "
                                   "v_cols_q := quote_ident('d');").replace("v_cols,", "v_cols_q,")
    v, q = check_text("named.sql", named)
    if v or q != 1:
        print(f"SELFTEST FAIL  a named-notation argument beside a marked assignment: expected no violation and "
              f"the assignment counted once, saw {q} quoting assignment(s) and {v}")
        failures += 1
    else:
        print("SELFTEST PASS  a named-notation argument is not read as an assignment")

    # #1179: `%%I` is format()'s escaped percent before an `I`, the text `%I`, not a conversion; and a SELECT
    # whose INTO comes first is read with the list it assigns, not the whole statement: the marked list beside
    # an unmarked local holding an unquoted value must leave the unmarked one alone
    v, q = check_text("pct.sql", SHAPE_BODY.format(decl="v_cols text", stmt="v_cols := format('%%I', 'c');"))
    v2, q2 = check_text("into_pair.sql", SHAPE_BODY.format(
        decl="v_cols_q text; v_plain text",
        stmt="select into v_cols_q, v_plain quote_ident('c'), 'raw' from pg_class;").replace("v_cols,", "v_cols_q,"))
    if v or q != 0 or v2 or q2 != 1:
        print(f"SELFTEST FAIL  `%%I` should quote nothing (saw {q}, {v}), and an INTO-first SELECT should pair each "
              f"target with its own item (saw {q2} quoting assignment(s) and {v2})")
        failures += 1
    else:
        print("SELFTEST PASS  `%%I` quotes nothing, and an INTO-first SELECT pairs each target with its own item")

    print()
    if failures:
        print("selftest: FAIL")
        return 1
    print("selftest: PASS (both checks fail against their own defect)")
    return 0


def main(argv) -> int:
    if "--selftest" in argv:
        return selftest()

    violations, quoted, missing = [], 0, []
    for rel in FILES:
        path = ROOT / rel
        if not path.is_file():
            missing.append(rel)
            continue
        v, q = check_text(rel, path.read_text())
        violations += v
        quoted += q

    for rel in missing:
        print(f"FAIL  {rel} is missing; it was never checked")
    for line in violations:
        print("FAIL  " + line)

    if quoted < MIN_QUOTED_ASSIGNMENTS:
        print(f"FAIL  only {quoted} identifier-quoting assignment(s) found across {len(FILES)} files, "
              f"expected at least {MIN_QUOTED_ASSIGNMENTS} -- the parser is no longer reading this "
              f"module, so a clean result here means nothing")
        return 1
    if violations or missing:
        return 1
    print(f"PASS  every already-quoted fragment is _q-marked, and every _q name is earned "
          f"({quoted} quoting assignments across {len(FILES)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
