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

  1. No relname is compared. A pg_class row found by its relname is a relation looked up by name: the column
     `relname`, however qualified or quoted, may not stand beside a comparison (`=`, `<>`, `in`, `like`, `is`
     ...), nor anywhere in a WHERE, ON, HAVING or USING clause (a row comparison, a cast, a function of it). A
     relname in a select list, read off an oid, is reading a name, not looking one up.
  2. A child name only goes to the resolver, or into a message. In every function with a `name`-typed
     parameter p_child, each use of p_child is a bare argument of archive._resolve_child, of a RAISE, or of
     json_build_object (the null-argument refusal renders it as JSON). Anything else (handing it to another
     function of this file, comparing it, casting it, splicing it with format() or ||, binding it with USING)
     fails: that is how a child name reaches the catalog again, and it is what archive.to_s3 did when it handed
     p_child to archive._child_object_key.
  3. to_regclass() reads only a literal: the module's own fixed names (pg_temp.archive_pq_snapshot), never a
     name computed at run time.

Dynamic SQL is code: every literal an EXECUTE runs is lexed as the SQL it is, by the lexer of
scripts/check_archive_object_keys.py (one lexer for the module's two static checks), so `execute 'select ... where
relname = $1' using p_child` fails rules 1 and 2. Comments and every other literal are not code.

THE FLOORS, so a lexer that has stopped reading the module cannot report a clean sweep of nothing:
archive._resolve_child is defined once, with a `name`-typed p_child, and compares a relname inside its own body
(rule 1's witness); and at least two functions hand their child name to it (rule 2's: archive.to_s3 and
archive.to_s3_parquet do today).

What this cannot see. A child name that never travels as a parameter called p_child (a parameter named
otherwise, a column read into a local); a by-name lookup that compares no relname and calls no to_regclass,
such as a `::regclass` cast of text built from names read off an oid, or a by-name read in dynamic SQL
(`format('%I.%I', v_nsp, v_rel)`): the module does those for its own pg_temp snapshot table, so the rule could
not be exception-free there. tests/archive/db/49 proves the contract itself on both exports, with a second
session moving the parent between the hold and the key.

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


def relname_comparisons(toks, defs):
    """[(k, why)] for every relname rule 1 refuses, anywhere in the file, the resolver's body included (the
    caller tells the two apart)."""
    found, stack = [], [None]
    for k, (kind, text, _) in enumerate(toks):
        if text == "(":
            stack.append(stack[-1])
            continue
        if text == ")":
            if len(stack) > 1:
                stack.pop()
            continue
        if text == ";" or kind == "DOLLAR":
            stack = [None]
            continue
        if kind != "ID":
            continue
        if text in CLAUSE_WORDS:
            stack[-1] = text
            continue
        if last_part(text) != "relname":
            continue
        prev = toks[k - 1] if k else ("", "", 0)
        nxt = toks[k + 1] if k + 1 < len(toks) else ("", "", 0)
        if prev[1] in COMPARE_OPS or nxt[1] in COMPARE_OPS or (nxt[0] == "ID" and nxt[1] in COMPARE_WORDS):
            found.append((k, f"{text} is compared"))
        elif stack[-1] in LOOKUP_CLAUSES:
            found.append((k, f"{text} stands in the {stack[-1].upper()} clause of a query"))
    return found


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

    # rule 1
    inside = 0
    for k, why in relname_comparisons(toks, defs):
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
        if kind == "ID" and last_part(text) == "to_regclass" and k + 1 < len(toks) and toks[k + 1][1] == "(":
            regclass_calls += 1
            if not (k + 3 < len(toks) and toks[k + 2][0] == "STR" and toks[k + 3][1] == ")"):
                v.append(f"{scope_of(defs, k) or 'top level'} (line {line}): to_regclass() of something other than a "
                         f"literal, a relation looked up by a name computed at run time")
    summary = (f"{RESOLVER} is the one place a child is resolved by name ({inside} relname comparison(s) in it); "
               f"{callers} function(s) hand it their child name and otherwise only report it; no relname is "
               f"compared elsewhere; {regclass_calls} to_regclass() call(s), each of a literal")
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


def plant(body, params="p_parent regclass, p_child name", name="archive._planted"):
    return CLEAN + f"""
create or replace function {name}({params}) returns void language plpgsql as $$
declare v_nsp name; v_rel name; v_x regclass; v_oid oid;
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
