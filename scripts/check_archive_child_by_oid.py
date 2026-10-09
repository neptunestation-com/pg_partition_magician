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
place a child is resolved by name) and none of them naming any other site:

  1. No relation is found by its name. A name column (pg_class's `relname`, and the same name as the catalog
     views and information_schema call it: `tablename`, `table_name`, `viewname`, `matviewname`,
     `sequencename`, `sequence_name`), however qualified or quoted, may be read only in the select list of a
     statement's own query, off a row found otherwise, and only under its own name. It may not stand beside a
     comparison (`=`, `<>`, `in`, `like`, `is` ...), anywhere in a WHERE, ON, HAVING or USING clause (a row
     comparison, a cast, a function of it), in the select list of any subquery (a derived table, a CTE, a
     scalar or IN subquery: an outer query can filter on what it projects under any name, which is how the
     first version of this rule passed `(select k.relname as rn ...) q ... q.rn = <name>`, P1-02 of #1150's
     verification), or under an alias (`as rn`, or a bare `rn`). No NATURAL JOIN, which compares same-named
     columns without naming one. A local a name column is selected INTO (item for target) may not be compared,
     stand in a lookup clause, go to format(), to_regclass() or regclassin(), or be cast to regclass. And
     nothing is cast to regclass from a parenthesised expression (`(v_nsp || '.' || v_rel)::regclass`).
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
(rule 1's witness); and at least two functions hand their child name to it (rule 2's: archive.to_s3 and
archive.to_s3_parquet do today).

What this cannot see. It follows a name only as far as the text shows it. A child name that never travels as a
parameter called p_child (a parameter named otherwise, a column read into a local). A relname that leaves its
statement by any way but INTO a local named item for target: selected into a record or a row of other arity
(`select c.* into r`, then `r.relname` is still caught, but a field renamed by a composite type is not), returned
by a function, passed to one as an argument (whose parameter the callee may compare: caught there only if the
callee compares a name column or a p_child), or copied from the local into another (`v2 := v_rel`). A name
spliced into dynamic SQL text other than through format() (`'lock table ' || quote_ident(v_rel)`), and a
`::regclass` cast of a lone identifier holding text: the module casts oids that way (`v_stray::regclass`), and
a lexer cannot tell their types apart. A by-name read in dynamic SQL from parameters (`format('%I.%I', p_schema,
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


def name_lookups(toks):
    """([(k, why)], clause_at): every name-column reference rule 1 refuses, anywhere in the file (the caller
    tells the resolver's body apart), and the clause in force at each token, which the INTO pass reuses."""
    found, frames = [], [{"clause": None, "sub": False}]
    clause_at = [None] * len(toks)
    for k, (kind, text, _) in enumerate(toks):
        top = frames[-1]
        clause_at[k] = top["clause"]
        if text == "(":
            frames.append({"clause": top["clause"], "sub": top["sub"]})
            continue
        if text == ")":
            if len(frames) > 1:
                frames.pop()
            continue
        if text == ";" or kind == "DOLLAR":
            frames = [{"clause": None, "sub": False}]
            continue
        if kind != "ID":
            continue
        if text == "natural":
            found.append((k, "a NATURAL JOIN compares every same-named column, relname included, without naming "
                             "one"))
            continue
        if text in CLAUSE_WORDS:
            top["clause"] = text
            if text == "select" and len(frames) > 1:
                top["sub"] = True
            continue
        if last_part(text) not in NAME_COLUMNS:
            continue
        prev = toks[k - 1] if k else ("", "", 0)
        nxt = toks[k + 1] if k + 1 < len(toks) else ("", "", 0)
        if prev[1] in COMPARE_OPS or nxt[1] in COMPARE_OPS or (nxt[0] == "ID" and nxt[1] in COMPARE_WORDS):
            found.append((k, f"{text} is compared"))
        elif top["clause"] in LOOKUP_CLAUSES:
            found.append((k, f"{text} stands in the {top['clause'].upper()} clause of a query"))
        elif top["sub"]:
            found.append((k, f"{text} is projected out of a subquery (a derived table, a CTE, a scalar or IN "
                             f"subquery), where an outer query can filter on it under any name"))
        elif nxt[0] == "ID" and (nxt[1] == "as" or nxt[1] not in ALIAS_STOP):
            found.append((k, f"{text} is given an alias, a name this check would not follow"))
    return found, clause_at


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


def tainted_locals(toks, a, b):
    """{local: the INTO token's index}: every variable a statement of the body toks[a:b] selects a name column
    INTO, item for target (`select c.oid, c.relname into v_oid, v_rel` marks v_rel only)."""
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
                    named = any(toks[j][0] == "ID" and last_part(toks[j][1]) in NAME_COLUMNS for j in range(i0, i1))
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

    # rule 1: the name columns, then the locals one was selected into, then a cast of an expression to regclass
    inside = 0
    found, clause_at = name_lookups(toks)
    for name, _, a, b, _ in defs:
        if name == RESOLVER or a is None:
            continue
        for local, at in tainted_locals(toks, a, b).items():
            held = f"{local}, which holds a relname selected into it,"
            for k in range(a, b):
                if k == at or toks[k][0] != "ID" or toks[k][1] != local:
                    continue
                prev, nxt = toks[k - 1], toks[k + 1]
                callee, _ = callee_of(toks, k, a)
                if prev[1] in COMPARE_OPS or nxt[1] in COMPARE_OPS or (nxt[0] == "ID" and nxt[1] in COMPARE_WORDS):
                    found.append((k, f"{held} is compared"))
                elif clause_at[k] in LOOKUP_CLAUSES:
                    found.append((k, f"{held} stands in the {clause_at[k].upper()} clause of a query"))
                elif callee in ("format", "to_regclass", "regclassin"):
                    found.append((k, f"{held} is handed to {callee}(), to name a relation again"))
                elif nxt[1] == "::" and toks[k + 2][1] == "regclass":
                    found.append((k, f"{held} is cast to regclass, to name a relation again"))
    for k, (kind, text, _) in enumerate(toks):
        if text == "::" and 0 < k < len(toks) - 1 and toks[k + 1][1] == "regclass" and toks[k - 1][1] == ")":
            found.append((k, "an expression is cast to regclass, a relation found by a name built at run time"))
    for k, why in sorted(set(found)):
        if ra is not None and ra <= k < rb:
            inside += 1
            continue
        v.append(f"{scope_of(defs, k) or 'top level'} (line {toks[k][2]}): {why}, a relation looked up by name "
                 f"outside {RESOLVER}; take the regclass it returned")
    if inside == 0:
        v.append(f"{RESOLVER} compares no relname in its own body: the lexer is no longer reading it (rule 1's "
                 f"witness)")

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
               f"{callers} function(s) hand it their child name and otherwise only report it; no relation is "
               f"found by its name elsewhere; {regclass_calls} to_regclass() call(s), each of a literal")
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

CLEAN = RESOLVER_SRC + OWNED_KEY_FIXED + EXPORTS_FIXED

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
PRE_1064 = RESOLVER_SRC + OWNED_KEY_PRE_1064 + EXPORTS_PRE_1064
# the real _owned_key alone, the exports already fixed: rules 1 and 2 must each see it
OWNED_KEY_ONLY_PRE_1064 = RESOLVER_SRC + OWNED_KEY_PRE_1064.replace(
    "create or replace function archive._child_object_key(p_parent regclass, p_prefix text, p_child name, p_ext text)",
    "create or replace function archive._child_object_key(p_parent regclass, p_prefix text, p_child regclass, p_ext text)"
) + EXPORTS_FIXED

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
