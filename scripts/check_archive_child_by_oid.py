#!/usr/bin/env python3
"""After archive._resolve_child, the archive module takes the child by the oid it returned, never by its name
again. Run by CI (the `Archive object keys` lint job) and, on the module under test, by
bench/archive_key_by_resolved_oid.sh.

WHY THIS EXISTS (issue #1064, the fifth hop of one class). The synchronous exports take their child as a NAME.
archive._resolve_child resolves it in the parent's schema, in one snapshot (#1062), holds it under ACCESS SHARE
(#1030) and returns its regclass; everything after that must go by the regclass. Each hop of the class was a
lookup that went by the name again after the resolution: the read by `%I.%I` (#1030), the Parquet read by a schema
and name taken earlier (#1055), the schema name read in one statement and the child in the next (#1062), and then
archive._owned_key, which the exports handed the NAME and which looked the relation up again in the parent's
CURRENT schema, for the key base and for the claim. The hold is on the child only, so ALTER TABLE <parent> SET
SCHEMA between the hold and that lookup keyed and claimed the resolved relation's rows as the destination schema's
namesake, and the namesake's own later export PUT over the only copy. Each fix closed the site it was found at;
this check closes the class in the module's text, so the next by-name lookup fails CI rather than a verification.

THE RULES, over pgpm_archive/install.sql, every one of them outside the body of archive._resolve_child (the one
place a child is resolved by name) and none of them naming any other site but the one that compares rendered
names to refuse (rule 1's last paragraph):

  1. No relation is found by its name. A relation's name is a name column (pg_class's `relname`, and the same
     name as the catalog views and information_schema call it: `tablename`, `table_name`, `viewname`,
     `matviewname`, `sequencename`, `sequence_name`), however qualified or quoted, and a regclass a cast made
     (`x::regclass`, CAST(x AS regclass), regclass(x)) rendered as text: cast on to a text type
     (`c.oid::regclass::text`, after any grouping or by CAST ... AS text), handed to a call that takes it as text
     (format(), concat(), to_json() ...), concatenated with ||, or regclassout() of anything (#1180: `where
     c.oid::regclass::text = v_rel` finds a relation by its rendered name with no name column in sight). The
     rule is the INVERSE of a list of forbidden places, because each list gained a spelling per round (#1154: a
     simple CASE in an ORDER BY, `order by case c.relname when k.relname then 0 else 1 end limit 1`, has no
     operator token and was in no clause the list named). A name may stand in exactly two places, read off a
     row found otherwise: ALONE as an item of the select list of a statement's own query (not a subquery's: an
     outer query can filter on what a subquery projects under any name, P1-02 of #1150's verification), under
     its own name, or alone as an argument of a RAISE; in either, also as a bare argument of quote_ident(),
     format() or json_build_object() that is the whole item. Casts and grouping parentheses go with it
     (`(c.relname)::text` alone is still alone). Anywhere else is refused: a WHERE, ON, HAVING, USING, ORDER BY
     or GROUP BY clause, a CASE, an operator or a call in a select item (which a positional ORDER BY can sort
     by), an alias, a plpgsql expression. No NATURAL JOIN, which compares same-named columns without naming
     one. A local a name is selected INTO (item for target) may not be compared, stand in a lookup clause, go to
     format(), to_regclass() or regclassin(), or be cast to regclass. And nothing is cast to regclass from a
     parenthesised expression (`(v_nsp || '.' || v_rel)::regclass`).
     One place compares rendered names on purpose: archive._refuse_foreign_read (#1055) renders the relations
     this backend holds after a read and refuses the read when one is a namesake of the relation it was by. Its
     rendered names reach only that refusal, so a rendered regclass is not refused in its body (its name columns
     are), and its rendering is the witness that the check of rendered names is reading (a floor below).
  2. A child name only goes to the resolver, or into a message. In every function with a `name`-typed
     parameter p_child, each use of p_child is a bare argument of archive._resolve_child, of a RAISE, or of
     json_build_object (the null-argument refusal renders it as JSON). Anything else (handing it to another
     function of this file, comparing it, casting it, splicing it with format() or ||, binding it with USING)
     fails: that is how a child name reaches the catalog again, and it is what archive.to_s3 did when it handed
     p_child to archive._child_object_key.
  3. to_regclass() and regclassin() read only a literal: the module's own fixed names
     (pg_temp.archive_pq_snapshot), never a name computed at run time.

Dynamic SQL is code: every literal an EXECUTE runs is lexed as the SQL it is, by the lexer of
scripts/check_archive_object_keys.py (one lexer for the module's two static checks), so `execute 'select ... where
relname = $1' using p_child` fails rules 1 and 2. Comments and every other literal are not code.

THE FLOORS, so a lexer that has stopped reading the module cannot report a clean sweep of nothing:
archive._resolve_child is defined once, with a `name`-typed p_child, and compares a relname inside its own body
(rule 1's witness); archive._refuse_foreign_read renders a regclass as text in its own body (rule 1's witness for
rendered names); and at least two functions hand their child name to it (rule 2's: archive.to_s3 and
archive.to_s3_parquet do today).

What this cannot see. It follows a name only as far as the text shows it. A child name that never travels as a
parameter called p_child (a parameter named otherwise, a column read into a local). A relname that leaves its
statement by any way but INTO a local named item for target: selected into a record or a row of other arity
(`select c.* into r`, then `r.relname` is still caught, but a field renamed by a composite type is not), returned
by a function, passed to one as an argument (whose parameter the callee may compare: caught there only if the
callee compares a name column or a p_child), or copied from the local into another (`v2 := v_rel`). A name
spliced into dynamic SQL text other than through format() (`'lock table ' || quote_ident(v_rel)`), and a
`::regclass` cast of a lone identifier holding text: the module casts oids that way (`v_stray::regclass`), and
a lexer cannot tell their types apart. For the same reason, a regclass the text did not make by a cast: a
regclass-typed parameter, local or column rendered by a cast of its own (`p_parent::text`,
`cfg.parent_table::text`), and a regclass rendered inside an array or a row
(`array_agg(c.oid::regclass)::text`). A by-name read in dynamic SQL from parameters (`format('%I.%I', p_schema,
p_table)`): the module does that for its own pg_temp snapshot table, so the rule could not be exception-free
there. tests/archive/db/49 proves the contract itself on both exports, with a second session moving the parent
between the hold and the key.

  ./scripts/check_archive_child_by_oid.py              # check pgpm_archive/install.sql
  ./scripts/check_archive_child_by_oid.py <file.sql>   # check another copy (a mutant, an old release)
  ./scripts/check_archive_child_by_oid.py --selftest   # prove each rule fails when its defect is present
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_archive_object_keys import NOT_CALLS, PARAM_MODES, executed_as_code, lex  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
TARGET = "pgpm_archive/install.sql"
RESOLVER = "archive._resolve_child"
CHILD = "p_child"
# what may receive a child name as a bare argument, besides a RAISE
RECEIVERS = {RESOLVER, "json_build_object", "jsonb_build_object"}
COMPARE_OPS = {"=", "<>", "!=", "<", ">", "<=", ">=", "~", "!"}
COMPARE_WORDS = {"in", "like", "ilike", "similar", "is", "between", "not", "any", "all", "collate"}
LOOKUP_CLAUSES = {"where", "on", "having", "using"}
CLAUSE_WORDS = LOOKUP_CLAUSES | {"select", "from", "into", "values", "set", "group", "order", "returning",
                                 "limit", "offset", "union", "intersect", "except", "join", "when", "then",
                                 "else", "end", "loop", "begin", "declare", "return", "perform", "execute"}
MIN_RESOLVING_CALLERS = 2
# The columns that hold a relation's name: pg_class's own, and the catalog views' and information_schema's
# names for the same thing, so a lookup through pg_tables or information_schema.tables is the lookup it is.
NAME_COLUMNS = {"relname", "tablename", "table_name", "viewname", "matviewname", "sequencename", "sequence_name"}
# What may follow a name column in a select list without being an alias of it.
ALIAS_STOP = CLAUSE_WORDS | COMPARE_WORDS | NOT_CALLS | {"and", "or", "asc", "desc", "nulls", "escape", "first",
                                                         "last"}
# What ends a select list, at its own depth.
SELECT_END = {"from", "into", "where", "group", "order", "having", "limit", "offset", "union", "intersect", "except",
              "window", "loop", "returning", "for", "fetch"}
# The calls a name may be a bare argument of, in a select item or a RAISE argument, and still only be reported.
MESSAGE_FNS = {"quote_ident", "format", "json_build_object", "jsonb_build_object"}
# The types a regclass renders to as its name, and the calls that take a regclass as text without a cast.
TEXT_TYPES = {"text", "varchar", "name", "bpchar", "char", "character", "citext"}
RENDER_FNS = {"text", "varchar", "name", "bpchar", "format", "concat", "concat_ws", "quote_literal", "quote_nullable",
              "to_json", "to_jsonb", "json_build_object", "jsonb_build_object", "json_build_array",
              "jsonb_build_array"}
TYPE_TAILS = {"varying", "precision"}
# The CLAUSE_WORDS that open a plpgsql statement rather than a clause of a query.
PLPGSQL_WORDS = {None, "when", "then", "else", "end", "loop", "begin", "declare", "return", "execute"}
# The one function that compares rendered names on purpose: it refuses a read that reached a namesake (#1055),
# so it renders the relations this backend holds and compares them with the name the read was by. Its
# rendering is rule 1's witness for rendered names, and nowhere else may a rendered regclass be compared.
RENDERED_NAME_SITE = "archive._refuse_foreign_read"


def last_part(ident):
    return ident.rsplit(".", 1)[-1]


def definitions(toks):
    """[(name, params, body_start, body_end, line)]: every function and procedure the file defines, its
    parameters as [(name, [type words])], and the token span of its dollar-quoted body."""
    out = []
    for k in range(1, len(toks) - 2):
        if not (toks[k][1] in ("function", "procedure") and toks[k - 1][1] in ("create", "replace")
                and toks[k + 1][0] == "ID" and toks[k + 2][1] == "("):
            continue
        params, cur, depth, j = [], [], 0, k + 3
        while j < len(toks):
            t = toks[j][1]
            if t == "(":
                depth += 1
            elif t == ")":
                if depth == 0:
                    break
                depth -= 1
            if t == "," and depth == 0:
                params.append(cur)
                cur = []
            else:
                cur.append(toks[j])
            j += 1
        if cur:
            params.append(cur)
        named = []
        for p in params:
            words = [t[1] for t in p if t[0] == "ID"]
            while words and words[0] in PARAM_MODES:
                words.pop(0)
            if len(words) > 1:
                named.append((words[0], words[1:]))
        b = j
        while b < len(toks) and toks[b][0] != "DOLLAR" and toks[b][1] != ";":
            b += 1
        if b >= len(toks) or toks[b][0] != "DOLLAR":
            out.append((toks[k + 1][1], named, None, None, toks[k][2]))
            continue
        e = b + 1
        while e < len(toks) and not (toks[e][0] == "DOLLAR" and toks[e][1] == toks[b][1]):
            e += 1
        out.append((toks[k + 1][1], named, b + 1, e, toks[k][2]))
    return out


def scope_of(defs, k):
    for name, _, a, b, _ in defs:
        if a is not None and a <= k < b:
            return name
    return None


def tok(toks, k):
    return toks[k] if 0 <= k < len(toks) else ("", "", 0)


def match_close(toks, p):
    """The index of the parenthesis that closes the one at p (or the last token)."""
    depth = 0
    for j in range(p, len(toks)):
        depth += (toks[j][1] == "(") - (toks[j][1] == ")")
        if depth == 0:
            return j
    return len(toks) - 1


def match_open(toks, q):
    """The index of the parenthesis that the one at q closes (or 0)."""
    depth = 0
    for j in range(q, -1, -1):
        depth += (toks[j][1] == ")") - (toks[j][1] == "(")
        if depth == 0:
            return j
    return 0


def is_call(toks, p):
    """Whether the parenthesis at p opens a call (a function's name before it) rather than grouping."""
    t = tok(toks, p - 1)
    return t[0] == "ID" and t[1] not in NOT_CALLS | CLAUSE_WORDS | COMPARE_WORDS | {"and", "or"}


def enclosing_open(toks, k):
    """The index of the parenthesis that directly encloses token k, or -1."""
    depth, p = 0, k - 1
    while p >= 0:
        depth += (toks[p][1] == ")") - (toks[p][1] == "(")
        if depth < 0:
            return p
        p -= 1
    return -1


def widen(toks, s, e):
    """[s, e] widened over the casts after it (`::text`, `::character varying`, `::text[]`), over a CAST( ... AS
    type ) around it and over parentheses that only group it, so `(c.relname)::text` is one value, judged by what
    stands around it."""
    while True:
        if tok(toks, e + 1)[1] == "::" and tok(toks, e + 2)[0] == "ID":
            e += 2
            while tok(toks, e + 1)[1] in TYPE_TAILS:
                e += 1
            while tok(toks, e + 1)[1] == "[" and tok(toks, e + 2)[1] == "]":
                e += 2
            continue
        if tok(toks, s - 1)[1] == "(" and last_part(tok(toks, s - 2)[1]) == "cast" and tok(toks, e + 1)[1] == "as":
            s, e = s - 2, match_close(toks, s - 1)
            continue
        if tok(toks, s - 1)[1] == "(" and tok(toks, e + 1)[1] == ")" and not is_call(toks, s - 1):
            s, e = s - 1, e + 1
            continue
        return s, e


def operand_start(toks, j):
    """The first token of the operand a `::` cast ending at token j applies to (`c.oid`, `(x || y)`, `f(x)`,
    `a::oid`)."""
    s = j
    if toks[s][1] == ")":
        s = match_open(toks, s)
        if is_call(toks, s):
            s -= 1
    if s >= 2 and toks[s - 1][1] == "::":
        return operand_start(toks, s - 2)
    return s


def rendered_regclass(toks):
    """[(s, e)]: every span that renders, as its name, a regclass a cast made (`x::regclass`, CAST(x AS
    regclass), regclass(x)): cast on to a text type (`x::regclass::text`, after any grouping, or by CAST ... AS
    text), handed to a call that takes it as text (format(), concat(), to_json() ...), concatenated with ||, and
    regclassout() of anything. A regclass-typed parameter or local cast to text is not seen (the docstring)."""
    out = []
    for k, (kind, text, _) in enumerate(toks):
        if kind != "ID":
            continue
        part = last_part(text)
        if part == "regclassout" and tok(toks, k + 1)[1] == "(":
            out.append((k, match_close(toks, k + 1)))
            continue
        if part != "regclass":
            continue
        if tok(toks, k - 1)[1] == "::":
            s, e = operand_start(toks, k - 2), k
        elif tok(toks, k - 1)[1] == "as" and tok(toks, k + 1)[1] == ")" \
                and last_part(tok(toks, match_open(toks, k + 1) - 1)[1]) == "cast":
            s, e = match_open(toks, k + 1) - 1, k + 1
        elif tok(toks, k + 1)[1] == "(":
            s, e = k, match_close(toks, k + 1)        # regclass(x), the call form of the cast
        else:
            continue                                  # a parameter's or a column's type, not a cast
        rendered = False
        while True:
            if tok(toks, e + 1)[1] == "::" and tok(toks, e + 2)[0] == "ID":
                rendered = rendered or last_part(tok(toks, e + 2)[1]) in TEXT_TYPES
                e += 2
                while tok(toks, e + 1)[1] in TYPE_TAILS:
                    e += 1
                continue
            if tok(toks, s - 1)[1] == "(" and last_part(tok(toks, s - 2)[1]) == "cast" and tok(toks, e + 1)[1] == "as":
                rendered = rendered or last_part(tok(toks, e + 2)[1]) in TEXT_TYPES
                s, e = s - 2, match_close(toks, s - 1)
                continue
            if tok(toks, s - 1)[1] == "(" and tok(toks, e + 1)[1] == ")" and not is_call(toks, s - 1):
                s, e = s - 1, e + 1
                continue
            p = enclosing_open(toks, s)
            if p > 0 and is_call(toks, p) and last_part(toks[p - 1][1]) in RENDER_FNS:
                s, e, rendered = p - 1, match_close(toks, p), True
                continue
            rendered = rendered or tok(toks, s - 1)[1] == "||" or tok(toks, e + 1)[1] == "||"
            break
        if rendered:
            out.append((s, e))
    return out


def contexts(toks):
    """(clause_at, sub_at, start_at), per token: the clause in force, whether the query it belongs to is a
    subquery, and the index of the word that opened that clause. A CASE ... END is a frame of its own, so its
    WHEN, THEN and ELSE do not end the clause the CASE stands in."""
    fresh = {"clause": None, "sub": False, "at": None, "case": False}
    frames = [dict(fresh)]
    n = len(toks)
    clause_at, sub_at, start_at = [None] * n, [False] * n, [None] * n
    for k, (kind, text, _) in enumerate(toks):
        top = frames[-1]
        clause_at[k], sub_at[k], start_at[k] = top["clause"], top["sub"], top["at"]
        if text == "(":
            frames.append(dict(top, case=False))
            continue
        if text == ")":
            while len(frames) > 1 and frames[-1]["case"]:
                frames.pop()
            if len(frames) > 1:
                frames.pop()
            continue
        if text == ";" or kind == "DOLLAR":
            frames = [dict(fresh)]
            continue
        if kind != "ID":
            continue
        if text == "case":
            frames.append(dict(top, case=True))
            continue
        if text == "end" and top["case"]:
            frames.pop()
            continue
        if top["case"] and text in ("when", "then", "else"):
            continue
        if text in CLAUSE_WORDS:
            top["clause"], top["at"] = text, k
            if text == "select" and len(frames) > 1:
                top["sub"] = True
    return clause_at, sub_at, start_at


def message_item(toks, s, e, ctx):
    """(start, end): the one item toks[s..e] stands in where rule 1 lets a name be read at all, an argument of a
    RAISE or an item of the select list of a statement's own query (not a subquery's). None anywhere else."""
    j = s - 1
    while j >= 0 and toks[j][1] != ";" and toks[j][0] != "DOLLAR":
        if toks[j] == ("ID", "raise", toks[j][2]):
            end = j + 1
            while end < len(toks) and toks[end][1] != ";":
                end += 1
            for a, b in split_top(toks, j + 1, run_end(toks, j + 1, end, {"using"})):
                if a <= s and e < b:
                    return a, b
            return None
        j -= 1
    clause_at, sub_at, start_at = ctx
    if clause_at[s] != "select" or sub_at[s] or start_at[s] is None:
        return None
    at = start_at[s]
    depth, j = 0, at + 1
    while j < len(toks):
        t = toks[j][1]
        if t == "(":
            depth += 1
        elif t == ")":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (t == ";" or toks[j][0] == "DOLLAR" or (toks[j][0] == "ID" and t in SELECT_END)):
            break
        j += 1
    for a, b in split_top(toks, at + 1, j):
        if a <= s and e < b:
            if toks[a][1] in ("distinct", "all") and tok(toks, a + 1)[1] != "on":
                a += 1
            return a, b
    return None


def alone_in(toks, item, s, e):
    """Whether toks[s..e] is all of the item, or a bare argument of a MESSAGE_FNS call that is all of it."""
    a, b = item
    if (a, b - 1) == (s, e):
        return True
    return (toks[a][0] == "ID" and last_part(toks[a][1]) in MESSAGE_FNS and tok(toks, a + 1)[1] == "("
            and match_close(toks, a + 1) == b - 1 and enclosing_open(toks, s) == a + 1
            and tok(toks, s - 1)[1] in ("(", ",") and tok(toks, e + 1)[1] in (")", ","))


def name_read(toks, s, e, ctx, what):
    """Why rule 1 refuses the name-bearing value toks[s..e], or None where it may stand: alone as an item of a
    statement's own select list or of a RAISE, or as a bare argument of quote_ident(), format() or
    json_build_object() there. Anywhere else is refused; the reasons only say which place it is."""
    s, e = widen(toks, s, e)
    item = message_item(toks, s, e, ctx)
    if item is not None and alone_in(toks, item, s, e):
        return None
    prev, nxt = tok(toks, s - 1), tok(toks, e + 1)
    clause_at, sub_at, _ = ctx
    if prev[1] in COMPARE_OPS or nxt[1] in COMPARE_OPS or (nxt[0] == "ID" and nxt[1] in COMPARE_WORDS):
        return f"{what} is compared"
    if clause_at[s] in LOOKUP_CLAUSES:
        return f"{what} stands in the {clause_at[s].upper()} clause of a query"
    if sub_at[s] and clause_at[s] == "select":
        return (f"{what} is projected out of a subquery (a derived table, a CTE, a scalar or IN subquery), where an "
                f"outer query can filter on it under any name")
    if item is not None and nxt[0] == "ID" and (nxt[1] == "as" or nxt[1] not in ALIAS_STOP):
        return f"{what} is given an alias, a name this check would not follow"
    where = ("in an expression of a select item or a RAISE argument (a CASE, an operator, a call), which a query "
             "can compare or sort by" if item is not None
             else f"in the {clause_at[s].upper()} clause of a query" if clause_at[s] not in PLPGSQL_WORDS
             else "in a plpgsql expression")
    return (f"{what} stands {where}; a name may be read only alone as an item of a statement's own select list or "
            f"of a RAISE, or as a bare argument of quote_ident(), format() or json_build_object() there")


def name_lookups(toks):
    """([(k, why, rendered)], clause_at, rendered spans): every name-bearing value rule 1 refuses, anywhere in the
    file (the caller tells the resolver's body and the rendered-name site apart), with whether it is a rendered
    regclass; the clause in force at each token, which the INTO pass reuses; and every span that renders a
    regclass as text."""
    ctx = contexts(toks)
    found = []
    for k, (kind, text, _) in enumerate(toks):
        if kind != "ID":
            continue
        if text == "natural":
            found.append((k, "a NATURAL JOIN compares every same-named column, relname included, without naming "
                             "one", False))
        elif last_part(text) in NAME_COLUMNS:
            why = name_read(toks, k, k, ctx, text)
            if why:
                found.append((k, why, False))
    spans = rendered_regclass(toks)
    for s, e in spans:
        what = "a regclass rendered as text (" + " ".join(t[1] for t in toks[s:e + 1])[:60] + ")"
        why = name_read(toks, s, e, ctx, what)
        if why:
            found.append((s, why, True))
    return found, ctx[0], spans


def split_top(toks, a, b):
    """The comma-separated parts of toks[a:b] at their own depth, as [(start, end)]."""
    parts, depth, s = [], 0, a
    for k in range(a, b):
        t = toks[k][1]
        if t == "(":
            depth += 1
        elif t == ")":
            depth -= 1
        elif t == "," and depth == 0:
            parts.append((s, k))
            s = k + 1
    parts.append((s, b))
    return parts


def run_end(toks, start, e, stops):
    """The first token of toks[start:e] at its own depth that is one of the words in stops, or e."""
    depth = 0
    for j in range(start, e):
        t = toks[j][1]
        depth += (t == "(") - (t == ")")
        if depth == 0 and toks[j][0] == "ID" and t in stops:
            return j
    return e


def tainted_locals(toks, a, b, rendered_at=frozenset()):
    """{local: the INTO token's index}: every variable a statement of the body toks[a:b] selects a name column,
    or a regclass rendered as text (the token indices in rendered_at), INTO, item for target (`select c.oid,
    c.relname into v_oid, v_rel` marks v_rel only)."""
    out, k = {}, a
    stops = {"from", "where", "group", "order", "limit", "union", "loop", "into", "having"}
    while k < b:
        e = k
        while e < b and toks[e][1] != ";":
            e += 1
        depth, sel, into = 0, None, None
        for j in range(k, e):
            t = toks[j][1]
            depth += (t == "(") - (t == ")")
            if depth == 0 and toks[j][0] == "ID":
                if t == "select" and sel is None:
                    sel = j
                elif t == "into" and sel is not None and into is None:
                    into = j
        if sel is not None and into is not None and into + 1 < e:
            items = split_top(toks, sel + 1, min(into, run_end(toks, sel + 1, e, stops)))
            t0 = into + 1 + (toks[into + 1][1] == "strict")
            targets = split_top(toks, t0, run_end(toks, t0, e, stops))
            if len(items) == len(targets):
                for (i0, i1), (g0, g1) in zip(items, targets):
                    named = any((toks[j][0] == "ID" and last_part(toks[j][1]) in NAME_COLUMNS) or j in rendered_at
                                for j in range(i0, i1))
                    if named and g1 - g0 == 1 and toks[g0][0] == "ID":
                        out[toks[g0][1]] = g0
        k = e + 1
    return out


def callee_of(toks, k, a):
    """The call whose parenthesis directly encloses token k (searching back no further than a), or None, and
    whether k is a bare argument of it (alone between its separators)."""
    depth, j = 0, k - 1
    while j >= a:
        t = toks[j][1]
        if t == ")":
            depth += 1
        elif t == "(":
            if depth == 0:
                break
            depth -= 1
        j -= 1
    if j < a:
        return None, False
    bare = toks[k - 1][1] in ("(", ",") and toks[k + 1][1] in (")", ",")
    name = toks[j - 1][1] if j - 1 >= a and toks[j - 1][0] == "ID" else None
    if name in NOT_CALLS or name in CLAUSE_WORDS:   # a parenthesis that opens no call: `else (select ...)`
        name = None
    return name, bare


def in_raise(toks, k, a):
    """Whether token k is a bare argument of a RAISE statement: the statement opened by `raise` before it,
    with no `;` between, and k alone between its commas at the statement's own depth."""
    depth, j = 0, k - 1
    while j >= a and toks[j][1] != ";":
        t = toks[j][1]
        if t == ")":
            depth += 1
        elif t == "(":
            depth -= 1
        if toks[j][0] == "ID" and t == "raise":
            return depth == 0 and toks[k - 1][1] == "," and toks[k + 1][1] in (",", ";")
        j -= 1
    return False


def check_text(src):
    """(violations, summary): violations as 'scope (line N): why'."""
    toks = executed_as_code(lex(src))
    defs = definitions(toks)
    v = []
    for name, _, a, _, line in defs:
        if a is None:
            v.append(f"{name} (line {line}): its body is not dollar-quoted, so this check cannot read it")
    resolvers = [d for d in defs if d[0] == RESOLVER]
    if len(resolvers) != 1:
        v.append(f"{RESOLVER} is defined {len(resolvers)} time(s), not once: the one place a child is resolved by "
                 f"name is what every other rule here is relative to")
        return v, None
    _, rparams, ra, rb, _ = resolvers[0]
    if (CHILD, ["name"]) not in rparams:
        v.append(f"{RESOLVER} takes no name-typed {CHILD}: the resolver is not the one this check knows")

    # rule 1: the name columns and the rendered regclasses, then the locals one was selected into, then a cast of
    # an expression to regclass
    inside = 0
    found, clause_at, spans = name_lookups(toks)
    rendered_at = {j for s, e in spans for j in range(s, e + 1)}
    witnessed = sum(1 for s, _ in spans if scope_of(defs, s) == RENDERED_NAME_SITE)
    for name, _, a, b, _ in defs:
        if name == RESOLVER or a is None:
            continue
        for local, at in tainted_locals(toks, a, b, rendered_at).items():
            held = f"{local}, which holds a relname selected into it,"
            for k in range(a, b):
                if k == at or toks[k][0] != "ID" or toks[k][1] != local:
                    continue
                prev, nxt = toks[k - 1], toks[k + 1]
                callee, _ = callee_of(toks, k, a)
                if prev[1] in COMPARE_OPS or nxt[1] in COMPARE_OPS or (nxt[0] == "ID" and nxt[1] in COMPARE_WORDS):
                    found.append((k, f"{held} is compared", False))
                elif clause_at[k] in LOOKUP_CLAUSES:
                    found.append((k, f"{held} stands in the {clause_at[k].upper()} clause of a query", False))
                elif callee in ("format", "to_regclass", "regclassin"):
                    found.append((k, f"{held} is handed to {callee}(), to name a relation again", False))
                elif nxt[1] == "::" and toks[k + 2][1] == "regclass":
                    found.append((k, f"{held} is cast to regclass, to name a relation again", False))
    for k, (kind, text, _) in enumerate(toks):
        if text == "::" and 0 < k < len(toks) - 1 and toks[k + 1][1] == "regclass" and toks[k - 1][1] == ")":
            found.append((k, "an expression is cast to regclass, a relation found by a name built at run time",
                          False))
    for k, why, rendered in sorted(set(found)):
        if not rendered and ra is not None and ra <= k < rb:
            inside += 1
            continue
        if rendered and scope_of(defs, k) == RENDERED_NAME_SITE:
            continue
        v.append(f"{scope_of(defs, k) or 'top level'} (line {toks[k][2]}): {why}, a relation looked up by name "
                 f"outside {RESOLVER}; take the regclass it returned")
    if inside == 0:
        v.append(f"{RESOLVER} compares no relname in its own body: the lexer is no longer reading it (rule 1's "
                 f"witness)")
    if witnessed == 0:
        v.append(f"{RENDERED_NAME_SITE} renders no regclass as text in its own body: the check of rendered names "
                 f"is no longer reading it, or the one place they are compared on purpose is gone (rule 1's "
                 f"witness for rendered names)")

    # rule 2
    callers = 0
    for name, params, a, b, _ in defs:
        if name == RESOLVER or a is None or (CHILD, ["name"]) not in params:
            continue
        resolves = False
        for k in range(a, b):
            if toks[k][0] != "ID" or toks[k][1] != CHILD:
                continue
            callee, bare = callee_of(toks, k, a)
            if bare and callee in RECEIVERS:
                resolves = resolves or callee == RESOLVER
                continue
            if in_raise(toks, k, a):
                continue
            if callee:
                where = f"an argument of {callee}()" if bare else f"in an expression handed to {callee}()"
            else:
                where = "used in an expression"
            v.append(f"{name} (line {toks[k][2]}): its child name {CHILD} is {where} rather than resolved by "
                     f"{RESOLVER} or reported: a child name reaches the catalog only through the resolver")
        callers += resolves
    if callers < MIN_RESOLVING_CALLERS:
        v.append(f"only {callers} function(s) hand a child name to {RESOLVER}, fewer than {MIN_RESOLVING_CALLERS}: "
                 f"the lexer is no longer reading the exports (rule 2's witness)")

    # rule 3
    regclass_calls = 0
    for k, (kind, text, line) in enumerate(toks):
        if kind == "ID" and last_part(text) in ("to_regclass", "regclassin") and k + 1 < len(toks) \
                and toks[k + 1][1] == "(":
            regclass_calls += 1
            if not (k + 3 < len(toks) and toks[k + 2][0] == "STR" and toks[k + 3][1] == ")"):
                v.append(f"{scope_of(defs, k) or 'top level'} (line {line}): to_regclass() of something other than a "
                         f"literal, a relation looked up by a name computed at run time")
    summary = (f"{RESOLVER} is the one place a child is resolved by name ({inside} lookup(s) by name in it); "
               f"{RENDERED_NAME_SITE} the one place rendered names are compared ({witnessed} rendering(s) in it); "
               f"{callers} function(s) hand the resolver their child name and otherwise only report it; no relation "
               f"is found by its name elsewhere; {regclass_calls} to_regclass() call(s), each of a literal")
    return v, summary


# ---------------------------------------------------------------------------------------------------------------
# --selftest fixtures. The scaffold is the shape the module has: the resolver, and the two exports handing it
# their child name. Each case adds or replaces one unit.

RESOLVER_SRC = """
create or replace function archive._resolve_child(p_parent regclass, p_child name, p_caller text)
returns regclass language plpgsql as $$
declare v_nsp name; v_now regclass;
begin
  select n.nspname, c.oid::regclass into v_nsp, v_now
    from pg_class p join pg_namespace n on n.oid = p.relnamespace
    left join pg_class c on c.relnamespace = p.relnamespace and c.relname = p_child
   where p.oid = p_parent;
  execute format('lock table %I.%I in access share mode', v_nsp, p_child);
  if v_now is null then
    raise exception 'pg_partition_magician: %.% does not exist', quote_ident(v_nsp), quote_ident(p_child);
  end if;
  return v_now;
end;
$$;
"""

EXPORTS_FIXED = """
create or replace function archive.to_s3(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare v_child regclass; v_nsp name; v_key text; cfg archive.config;
begin
  perform pgpm._refuse_null_arguments('archive.to_s3', json_build_object('p_parent', p_parent, 'p_child', p_child));
  v_child := archive._resolve_child(p_parent, p_child, 'archive.to_s3');
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = v_child;
  v_key := archive._child_object_key(p_parent, cfg.prefix, v_child, '.ndjson');
  -- a decoy in a comment: where relname = p_child, archive._child_object_key(p_parent, cfg.prefix, p_child, '')
  raise notice 'a decoy in a literal: relname = p_child and to_regclass(p_child)';
  raise exception 'archive.to_s3 of %.%: PUT failed', v_nsp, p_child;
end;
$$;
create or replace function archive.to_s3_parquet(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare v_child regclass; v_key text; cfg archive.config;
begin
  v_child := archive._resolve_child(p_parent, p_child, 'archive.to_s3_parquet');
  v_key := archive._child_object_key(p_parent, cfg.prefix, v_child, '.parquet');
  raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP %', p_child, 500;
end;
$$;
create or replace function archive._pq_snapshot(p_relation regclass) returns void language plpgsql as $$
declare v_snap regclass;
begin
  v_snap := to_regclass('pg_temp.archive_pq_snapshot');
end;
$$;
"""

OWNED_KEY_FIXED = """
create or replace function archive._owned_key(p_parent regclass, p_prefix text, p_child regclass, p_tail text)
returns text language plpgsql as $$
declare v_base_q text; v_relation oid; v_name name; v_nsp name;
begin
  select c.oid, n.nspname, c.relname into v_relation, v_nsp, v_name
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = coalesce(p_child, p_parent);
  v_base_q := p_prefix || quote_ident(v_nsp) || '.' || quote_ident(v_name);
  return v_base_q || p_tail;
end;
$$;
create or replace function archive._child_object_key(p_parent regclass, p_prefix text, p_child regclass, p_ext text)
returns text language sql as $$
  select archive._owned_key(p_parent, p_prefix, p_child, p_ext);
$$;
"""

# The real archive._refuse_foreign_read (#1055), verbatim: the one place rendered names are compared, to refuse.
REFUSE_FOREIGN_READ_SRC = """
create or replace function archive._refuse_foreign_read(p_caller text, p_relation regclass, p_before oid[], p_also oid[] default '{}')
returns void language plpgsql as $$
declare
  v_stray oid;
  v_name text := (select n[cardinality(n)] from parse_ident(p_relation::text) n);
begin
  with recursive tree(rel) as (
    select s.rel from (select p_relation::oid union select a from unnest(p_also) a where a is not null) s(rel)
    union
    select i.inhrelid from pg_catalog.pg_inherits i join tree t on i.inhparent = t.rel
  ), heaps(rel) as (
    select rel from tree
    union select c.reltoastrelid from pg_catalog.pg_class c join tree t on c.oid = t.rel where c.reltoastrelid <> 0
  ), own(rel) as (
    select rel from heaps
    union select i.indexrelid from pg_catalog.pg_index i join heaps h on i.indrelid = h.rel
  )
  select l into v_stray
    from unnest(archive._held_relations()) l
   where l >= 16384 and l <> all (coalesce(p_before, '{}'::oid[]))
     and (l not in (select rel from own)                                                          -- rule (1)
          or (l <> p_relation::oid and l <> all (coalesce(p_also, '{}'::oid[]))                   -- rule (2)
              and exists (select 1 from pg_catalog.pg_class c where c.oid = l and c.relkind in ('r', 'p', 'v', 'm', 'f'))
              and (select n[cardinality(n)] from parse_ident(l::regclass::text) n) = v_name))
   order by l limit 1;
  if v_stray is not null then
    raise exception 'pg_partition_magician: % reached % (oid %) while reading % (oid %): the name it read by named another relation by the time the read was parsed (a schema renamed meanwhile), so it refuses to go on with that relation''s rows; nothing was written, run it again',
      p_caller, v_stray::regclass, v_stray, p_relation, p_relation::oid;
  end if;
end;
$$;
"""

CLEAN = RESOLVER_SRC + OWNED_KEY_FIXED + EXPORTS_FIXED + REFUSE_FOREIGN_READ_SRC

# THE REAL INSTANCE (#1064): archive._owned_key as main had it at d8d45bd, verbatim, with the entry point and the
# two exports that handed it the child's name. Real past defects are the mutation set; a fixture invented here
# would miss what the real one does.
OWNED_KEY_PRE_1064 = """
create or replace function archive._owned_key(p_parent regclass, p_prefix text, p_child name, p_tail text)
returns text language plpgsql as $$
declare v_base_q text; v_owner oid; v_key text; v_held archive.object_key_claim; v_relation oid; v_name name;
        v_nsp name; v_kind text := case when p_child is null then 'chunk' else 'export' end;
begin
  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(coalesce(p_child, c.relname))
    into v_base_q
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = p_parent;
  -- the relation whose rows the object holds (#976): the parent for a chunk, the child for an export
  select n.nspname, coalesce(p_child, c.relname),
         case when p_child is null then c.oid
              else (select r.oid from pg_class r where r.relnamespace = n.oid and r.relname = p_child) end
    into v_nsp, v_name, v_relation
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = p_parent;
  if v_relation is null then
    raise exception 'pg_partition_magician: %.% does not exist; no object key is claimed for it',
      quote_ident(v_nsp), quote_ident(p_child);
  end if;
  insert into archive.object_key_owner (key_base, parent_oid) values (v_base_q, p_parent::oid)
    on conflict (key_base) do nothing
    returning parent_oid into v_owner;
  if v_owner is null then
    select o.parent_oid into v_owner from archive.object_key_owner o where o.key_base = v_base_q;
  end if;
  v_key := v_base_q
      || case when v_owner is not distinct from p_parent::oid then '' else '.' || p_parent::oid::text end
      || p_tail;
  v_held := archive._claim_object_key(v_key, p_parent, v_kind, v_relation);
  if (v_held.parent_oid, v_held.kind) is distinct from (p_parent::oid, v_kind) and v_owner = p_parent::oid then
    v_key := v_base_q || '.' || p_parent::oid::text || p_tail;
    v_held := archive._claim_object_key(v_key, p_parent, v_kind, v_relation);
  end if;
  if (v_held.parent_oid, v_held.kind) is distinct from (p_parent::oid, v_kind) then
    raise exception 'pg_partition_magician: the object key % is already claimed by the % of relation %; refusing to write the % of % over it (archive.object_key_claim)',
      v_key, v_held.kind, v_held.parent_oid, v_kind, p_parent;
  end if;
  if v_held.relation_oid is distinct from v_relation then
    raise exception 'pg_partition_magician: the object key % is already claimed by the % of relation % through %; refusing to write the % of %.% (relation %) over it (archive.object_key_claim)',
      v_key, v_held.kind, coalesce(v_held.relation_oid::text, '(unrecorded)'), p_parent, v_kind,
      quote_ident(v_nsp), quote_ident(v_name), v_relation;
  end if;
  return v_key;
end;
$$;
create or replace function archive._child_object_key(p_parent regclass, p_prefix text, p_child name, p_ext text)
returns text language sql as $$
  select archive._owned_key(p_parent, p_prefix, p_child, p_ext);
$$;
"""
EXPORTS_PRE_1064 = (EXPORTS_FIXED
                    .replace("archive._child_object_key(p_parent, cfg.prefix, v_child, '.ndjson')",
                             "archive._child_object_key(p_parent, cfg.prefix, p_child, '.ndjson')")
                    .replace("archive._child_object_key(p_parent, cfg.prefix, v_child, '.parquet')",
                             "archive._child_object_key(p_parent, cfg.prefix, p_child, '.parquet')"))
PRE_1064 = RESOLVER_SRC + OWNED_KEY_PRE_1064 + EXPORTS_PRE_1064 + REFUSE_FOREIGN_READ_SRC
# the real _owned_key alone, the exports already fixed: rules 1 and 2 must each see it
OWNED_KEY_ONLY_PRE_1064 = RESOLVER_SRC + OWNED_KEY_PRE_1064.replace(
    "create or replace function archive._child_object_key(p_parent regclass, p_prefix text, p_child name, p_ext text)",
    "create or replace function archive._child_object_key(p_parent regclass, p_prefix text, p_child regclass, p_ext text)"
) + EXPORTS_FIXED + REFUSE_FOREIGN_READ_SRC

# bench/mutations/mutate.py's archive_owned_key_resolves_by_name: the fixed signature, the by-name lookup back
MUTANT_JOIN = CLEAN.replace(
    """    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = coalesce(p_child, p_parent);
""",
    """    from pg_class p join pg_namespace n on n.oid = p.relnamespace
    join pg_class c on c.relnamespace = p.relnamespace
                   and c.relname = (select k.relname from pg_class k where k.oid = coalesce(p_child, p_parent))
   where p.oid = p_parent;
""")

# THE REAL INSTANCE the per-PR verification of #1150 built (P1-02), verbatim: the same by-name lookup with relname
# projected out of a derived table under an alias and compared as q.rn. The first version of rule 1 read only the
# token `relname` beside a comparison or in a WHERE/ON clause and printed PASS for it; installed, it is #1064.
MUTANT_ALIAS = CLEAN.replace(
    """    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = coalesce(p_child, p_parent);
""",
    """    from pg_class p join pg_namespace n on n.oid = p.relnamespace
    join (select k.oid as koid, k.relname as rn, k.relnamespace as ns from pg_class k) q
      on q.ns = p.relnamespace and q.rn = (select k2.relname from pg_class k2 where k2.oid = coalesce(p_child, p_parent))
    join pg_class c on c.oid = q.koid
   where p.oid = p_parent;
""")

# THE REAL INSTANCES the per-PR verification of #1150 built in its second round (#1154), verbatim: the same lookup
# with the name compared by a simple CASE in the ORDER BY, which has no operator token and was no clause the
# enumerated rule 1 inspected. P1-02 compares two name columns; V-01 a name column with the last part of the
# rendered child, parsed (no regclass cast in sight, so only the ORDER BY gives it away).
MUTANT_ORDER_CASE = CLEAN.replace(
    """    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = coalesce(p_child, p_parent);
""",
    """    from pg_class p join pg_namespace n on n.oid = p.relnamespace
    join pg_class c on c.relnamespace = p.relnamespace
    join pg_class k on k.oid = coalesce(p_child, p_parent)
   where p.oid = p_parent
   order by case c.relname when k.relname then 0 else 1 end limit 1;
""")
MUTANT_ORDER_CASE_PARSED = CLEAN.replace(
    """  select c.oid, n.nspname, c.relname into v_relation, v_nsp, v_name
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = coalesce(p_child, p_parent);
""",
    """  select r.oid into v_owner from pg_class r join pg_class pp on pp.relnamespace = r.relnamespace
   where pp.oid = p_parent
   order by case r.relname when (parse_ident(coalesce(p_child, p_parent)::text))[array_length(parse_ident(coalesce(p_child, p_parent)::text), 1)] then 0 else 1 end
   limit 1;
  select c.oid, n.nspname, c.relname into v_relation, v_nsp, v_name
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = v_owner;
""").replace("declare v_base_q text; v_relation oid;", "declare v_owner oid; v_base_q text; v_relation oid;")


def plant(body, params="p_parent regclass, p_child name", name="archive._planted"):
    return CLEAN + f"""
create or replace function {name}({params}) returns void language plpgsql as $$
declare v_nsp name; v_rel name; v_x regclass; v_oid oid; v_rec record;
begin
{body}
end;
$$;
"""


ROW_COMPARED = plant("  select c.oid into v_oid from pg_class c where (c.relnamespace, c.relname) = (v_oid, v_rel);")
CAST_COMPARED = plant("  select c.oid into v_oid from pg_class c join pg_namespace n on n.oid = c.relnamespace\n"
                      "    and lower(c.relname::text) = lower(v_rel);")
QUOTED_RELNAME = plant("  select c.oid into v_oid from pg_class c where c.\"relname\" = v_rel;")
LOCK_BY_NAME = plant("  execute format('lock table %I.%I in access share mode', v_nsp, p_child);")
EXECUTED_LOOKUP = plant("  execute 'select oid from pg_class where relname = $1' into v_oid using p_child;")
CAST_CHILD = plant("  v_x := p_child::regclass;")
CONCAT_CHILD = plant("  v_x := (quote_ident(v_nsp) || '.' || quote_ident(p_child))::regclass;")
QUOTED_IN_RAISE = plant("  raise exception 'no %', quote_ident(p_child);")
COMPUTED_REGCLASS = plant("  v_x := to_regclass(format('%I.%I', v_nsp, v_rel));", params="p_parent regclass")
RENDERED_FROM_OID = plant("  select c.relname, n.nspname into v_rel, v_nsp from pg_class c\n"
                          "    join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n"
                          "  raise notice '%.%', v_nsp, v_rel;", params="p_parent regclass")
CTE_PROJECTED = plant("  with q as (select oid as o, relname as rn from pg_class)\n"
                      "  select q.o into v_oid from q where q.rn = v_rel;", params="p_parent regclass")
COLUMN_LIST_ALIAS = plant("  select q.o into v_oid from (select k.oid, k.relname from pg_class k) q(o, rn)\n"
                          "   where q.rn = v_rel;", params="p_parent regclass")
IMPLICIT_ALIAS_LOOP = plant("  for v_rec in select c.oid, c.relname rn from pg_class c loop\n"
                            "    if v_rec.rn = v_rel then v_oid := v_rec.oid; end if;\n"
                            "  end loop;", params="p_parent regclass")
NATURAL = plant("  select c.oid into v_oid from pg_class c natural join (select v_rel::name) w;",
                params="p_parent regclass")
USING_JOIN = plant("  select c.oid into v_oid from pg_class c join pg_temp.wanted w using (relname);",
                   params="p_parent regclass")
INFORMATION_SCHEMA = plant("  select (t.table_schema || '.' || t.table_name)::regclass into v_x\n"
                           "    from information_schema.tables t where t.table_name = v_rel;",
                           params="p_parent regclass")
EXPRESSION_CAST = plant("  v_x := (v_nsp || '.' || v_rel)::regclass;", params="p_parent regclass")
INTO_COMPARED = plant("  select c.oid, c.relname into v_oid, v_rel from pg_class c where c.oid = p_parent;\n"
                      "  if v_rel = 'evt' then v_x := p_parent; end if;", params="p_parent regclass")
INTO_FORMATTED = plant("  select n.nspname, c.relname into v_nsp, v_rel from pg_class c\n"
                       "    join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n"
                       "  execute format('lock table %I.%I in access share mode', v_nsp, v_rel);",
                       params="p_parent regclass")
# #1180 (F8-05): a relation found by its RENDERED name, no name column anywhere, and the other spellings of the
# rendering: a cast on to text after any grouping or by CAST, a call that takes the regclass as text, ||, and
# regclassout(). Each in a WHERE, and the first in an ORDER BY's simple CASE (the two issues together).
RENDERED = {
    label: plant(f"  select c.oid into v_oid from pg_class c where {pred};", params="p_parent regclass")
    for label, pred in (("c.oid::regclass::text = v_rel", "c.oid::regclass::text = v_rel"),
                        ("(c.oid::regclass)::name = v_rel", "(c.oid::regclass)::name = v_rel"),
                        ("cast(c.oid::regclass as varchar) = v_rel", "cast(c.oid::regclass as varchar) = v_rel"),
                        ("lower(c.oid::regclass::text) = lower(v_rel)", "lower(c.oid::regclass::text) = lower(v_rel)"),
                        ("format('%s', c.oid::regclass) = v_rel", "format('%s', c.oid::regclass) = v_rel"),
                        ("c.oid::regclass || '' = v_rel", "c.oid::regclass || '' = v_rel"),
                        ("regclassout(c.oid) = v_rel", "regclassout(c.oid) = v_rel"),
                        ("cast(c.oid as regclass)::text = v_rel", "cast(c.oid as regclass)::text = v_rel"))}
RENDERED_ORDER_CASE = plant("  select c.oid into v_oid from pg_class c\n"
                            "   order by case c.oid::regclass::text when v_rel then 0 else 1 end limit 1;",
                            params="p_parent regclass")
RENDERED_INTO_FORMATTED = plant("  select c.oid::regclass::text into v_rel from pg_class c where c.oid = p_parent;\n"
                                "  execute format('lock table %s in access share mode', v_rel);",
                                params="p_parent regclass")
# the inverse's other places: a select item that compares the name, sorted by position; a function of the name
# in an ORDER BY; a name in a plpgsql expression; and the shapes it still allows
POSITIONAL = plant("  select c.oid, case c.relname when v_rel then 0 else 1 end into v_oid, v_x from pg_class c\n"
                   "   order by 2 limit 1;", params="p_parent regclass")
ORDER_FUNCTION = plant("  select c.oid into v_oid from pg_class c order by strpos(c.relname, v_rel) desc limit 1;",
                       params="p_parent regclass")
RECORD_FIELD = plant("  for v_rec in select c.oid, c.relname from pg_class c where c.oid = p_parent loop\n"
                     "    v_rel := lower(v_rec.relname);\n"
                     "  end loop;", params="p_parent regclass")
REPORTED = plant("  select c.oid::regclass::text, quote_ident(c.relname), n.nspname into v_rel, v_nsp, v_rec\n"
                 "    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n"
                 "  for v_rec in select c.oid, c.relname from pg_class c where c.oid = p_parent loop\n"
                 "    raise notice '% %', v_rec.relname, json_build_object('relation', v_rec.relname);\n"
                 "  end loop;\n"
                 "  raise notice '%', format('%s', p_parent::oid::regclass);", params="p_parent regclass")
NO_RENDERED_SITE = CLEAN.replace("archive._refuse_foreign_read(p_caller", "archive._refuse_read(p_caller")
DO_BLOCK = CLEAN + """
do $$ begin
  perform 1 from pg_class where relname = 'evt';
end $$;
"""
NO_RESOLVER = CLEAN.replace("archive._resolve_child(p_parent regclass", "archive._resolve(p_parent regclass")
RESOLVER_BLIND = CLEAN.replace("c.relname = p_child", "c.oid = p_child::regclass")
ONE_CALLER = CLEAN.replace("v_child := archive._resolve_child(p_parent, p_child, 'archive.to_s3_parquet');",
                           "v_child := null;")


def selftest():
    failures = 0

    def expect(label, src, ok, needle=None):
        nonlocal failures
        v, summary = check_text(src)
        if ok:
            if v:
                print(f"SELFTEST FAIL  {label}: expected clean, got:")
                for x in v:
                    print("        " + x)
                failures += 1
            else:
                print(f"SELFTEST PASS  {label}: clean")
        elif not v or (needle and not any(needle in x for x in v)):
            print(f"SELFTEST FAIL  {label}: expected a violation mentioning {needle!r}, got {v}")
            failures += 1
        else:
            print(f"SELFTEST PASS  {label}: refused ({next(x for x in v if not needle or needle in x)[:100]}...)")

    expect("clean (the fixed shape, with decoys in a comment and a literal)", CLEAN, True)
    expect("#1064, the real instance: main's archive._owned_key compares relname = p_child", OWNED_KEY_ONLY_PRE_1064,
           False, "archive._owned_key (line")
    expect("#1064, the real instance: main's archive._owned_key splices p_child into its key base",
           OWNED_KEY_ONLY_PRE_1064, False, "child name p_child is an argument of coalesce()")
    expect("#1064, the real instance: main's archive.to_s3 hands p_child to archive._child_object_key", PRE_1064,
           False, "archive.to_s3 (line")
    expect("#1064, the real instance: main's archive.to_s3_parquet hands p_child on the same way", PRE_1064,
           False, "archive.to_s3_parquet (line")
    expect("mutate.py's archive_owned_key_resolves_by_name: relname compared in a JOIN ... ON", MUTANT_JOIN, False,
           "archive._owned_key (line")
    expect("a row comparison of (relnamespace, relname)", ROW_COMPARED, False, "WHERE clause")
    expect("a relname cast and lowered in an ON clause", CAST_COMPARED, False, "ON clause")
    expect("the double-quoted column \"relname\"", QUOTED_RELNAME, False, "relname is compared")
    expect("#1030's shape: the child locked by format('%I.%I', ..., p_child)", LOCK_BY_NAME, False,
           "argument of format()")
    expect("a lookup in a literal EXECUTE runs, bound with USING", EXECUTED_LOOKUP, False, "relname is compared")
    expect("the same lookup's USING binding of the child name", EXECUTED_LOOKUP, False, "p_child is used in an expression")
    expect("#464's shape: p_child::regclass", CAST_CHILD, False, "child name p_child is used in an expression")
    expect("the child name quoted and concatenated into a regclass", CONCAT_CHILD, False, "argument of quote_ident()")
    expect("a RAISE renders the child name bare, never through a function", QUOTED_IN_RAISE, False,
           "argument of quote_ident()")
    expect("to_regclass() of a name computed at run time", COMPUTED_REGCLASS, False, "to_regclass() of something")
    expect("a relation's name read off its oid and reported", RENDERED_FROM_OID, True)
    expect("P1-02, the real instance: relname projected out of a derived table as rn, compared as q.rn",
           MUTANT_ALIAS, False, "projected out of a subquery")
    expect("relname projected out of a CTE and compared under its alias", CTE_PROJECTED, False,
           "projected out of a subquery")
    expect("relname renamed by a derived table's column list q(o, rn)", COLUMN_LIST_ALIAS, False,
           "projected out of a subquery")
    expect("relname given an implicit alias in a FOR loop's query, compared in plpgsql", IMPLICIT_ALIAS_LOOP, False,
           "given an alias")
    expect("a NATURAL JOIN on relname", NATURAL, False, "NATURAL JOIN")
    expect("a JOIN ... USING (relname)", USING_JOIN, False, "USING clause")
    expect("information_schema.tables found by table_name", INFORMATION_SCHEMA, False, "table_name is compared")
    expect("information_schema.tables' schema and name cast to regclass", INFORMATION_SCHEMA, False,
           "an expression is cast to regclass")
    expect("a schema and name concatenated and cast to regclass", EXPRESSION_CAST, False,
           "an expression is cast to regclass")
    expect("a relname selected INTO a local, the local compared", INTO_COMPARED, False,
           "v_rel, which holds a relname selected into it, is compared")
    expect("a relname selected INTO a local, the local spliced by format() into a LOCK", INTO_FORMATTED, False,
           "is handed to format()")
    expect("#1154, the real instance P1-02: _owned_key by ORDER BY case c.relname when k.relname ... limit 1",
           MUTANT_ORDER_CASE, False, "relname stands in the ORDER clause of a query")
    expect("#1154, the real instance V-01: _owned_key by ORDER BY case r.relname when parse_ident(...)",
           MUTANT_ORDER_CASE_PARSED, False, "r.relname stands in the ORDER clause of a query")
    for label, src in RENDERED.items():
        expect(f"#1180: a lookup by {label}", src, False, "a regclass rendered as text")
    expect("#1180 and #1154 together: ORDER BY case c.oid::regclass::text when v_rel ... limit 1", RENDERED_ORDER_CASE,
           False, "a regclass rendered as text (c.oid :: regclass :: text) stands in the ORDER clause")
    expect("a rendered regclass selected INTO a local, the local spliced by format() into a LOCK",
           RENDERED_INTO_FORMATTED, False, "is handed to format()")
    expect("a select item comparing relname by a simple CASE, the query sorted by its position", POSITIONAL, False,
           "relname stands in an expression of a select item")
    expect("a function of relname in an ORDER BY", ORDER_FUNCTION, False, "relname stands in the ORDER clause")
    expect("a relname read off a record into a plpgsql expression", RECORD_FIELD, False,
           "v_rec.relname stands in a plpgsql expression")
    expect("names projected alone or as a bare argument of quote_ident(), format(), json_build_object(), and in a "
           "RAISE", REPORTED, True)
    expect("floor: no archive._refuse_foreign_read rendering a regclass", NO_RENDERED_SITE, False,
           "rule 1's witness for rendered names")
    expect("a lookup by relname in a DO block", DO_BLOCK, False, "top level")
    expect("floor: no archive._resolve_child at all", NO_RESOLVER, False, "defined 0 time(s)")
    expect("floor: a resolver that compares no relname", RESOLVER_BLIND, False, "rule 1's witness")
    expect("floor: fewer than two exports hand their child name to the resolver", ONE_CALLER, False,
           "rule 2's witness")

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
    v, summary = check_text(path.read_text())
    for line in v:
        print("FAIL  " + line)
    if v:
        return 1
    print(f"PASS  {rel}: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
