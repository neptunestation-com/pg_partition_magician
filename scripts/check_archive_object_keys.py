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
which this file only ever names `prefix` (the column, `cfg.prefix`, `excluded.prefix`) or `p_prefix`
(the parameter that carries it). So a prefix reference is ASSEMBLY when it

  * touches `||` on either side,
  * is assigned (`v := cfg.prefix`, `select prefix into v`), which would let the value travel under
    another name, or
  * is an argument of a call to anything this file does not define (`format`, `concat`, `coalesce`,
    `replace`, a pgpm_core function ...): a function this file defines is followed instead, since its
    own body is checked by the same rule.

Anything else is declaring it (`p_prefix text`), storing it (archive.configure's upsert) or passing it
along to a function of this file, and is not a key. The rule names no site and has no exceptions; an
allowlist is the thing that rots (CLAUDE.md, on `_q`).

THE CHECK. Exactly one function of pgpm_archive/install.sql assembles a prefix, and that function
references archive.object_key_owner, the claim. Two assembling functions fail (the shape main had
before #872: _object_key and _child_object_key each built their own), as does assembly in a DO block
or at top level, an assembling function that never claims, and no assembly at all (a lexer that has
stopped seeing the file must not report a clean sweep of nothing).

What this cannot see, and tests/archive/db/39 does: a key built with no prefix at all, or a PUT that
ignores the key it was given. That file takes every path that writes an object through a namesake and
asserts the first relation's object survives by key and content, and its Part 0 requires every
function that PUTs to take its key from the key helpers.

  ./scripts/check_archive_object_keys.py              # check pgpm_archive/install.sql
  ./scripts/check_archive_object_keys.py <file.sql>   # check another copy (a mutant, an old release)
  ./scripts/check_archive_object_keys.py --selftest   # prove each check fails when its defect is present
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = "pgpm_archive/install.sql"

# The names a key prefix goes by in this file: the column and the parameter that carries it.
PREFIX_NAME = re.compile(r"^(?:[a-z_][a-z0-9_]*\.)?(?:p_)?prefix$")
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
# The floor: fewer prefix references than this and the lexer is no longer reading the module.
MIN_PREFIX_REFS = 8

IDENT = re.compile(r'(?:[A-Za-z_][A-Za-z0-9_$]*|"(?:[^"]|"")*")(?:\.(?:[A-Za-z_][A-Za-z0-9_$]*|"(?:[^"]|"")*"|\*))*')


def lex(src):
    """Tokens of a SQL file as (kind, text, line), comments dropped and every string literal one STR
    token, so nothing inside a comment or a literal is ever read as code. Dollar-quote delimiters are
    DOLLAR tokens and what they enclose is lexed as code: in this module a $$ body is a function body.
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
            toks.append(("STR", src[i:j + 1], start))
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
            toks.append(("ID", m.group(0).lower(), line))
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


def scan(src):
    """Returns (refs, assembly, claims, defined): the number of prefix references, {scope: [(line,
    why)]} for every assembling reference, the scopes that name archive.object_key_owner, and the
    functions the file defines."""
    toks = lex(src)
    defined = set()
    for k in range(len(toks) - 2):
        if toks[k][1] in ("function", "procedure") and toks[k + 1][0] == "ID":
            if k > 0 and toks[k - 1][1] in ("create", "replace"):
                defined.add(toks[k + 1][1])

    refs, assembly, claims = 0, {}, set()
    scope, pending, body_tag = None, None, None
    parens = []
    for k, (kind, text, line) in enumerate(toks):
        prev = toks[k - 1] if k > 0 else ("", "", 0)
        nxt = toks[k + 1] if k + 1 < len(toks) else ("", "", 0)

        # scopes: a function from its header to the end of its body, a DO block likewise
        if kind == "ID" and text in ("function", "procedure") and prev[1] in ("create", "replace") and nxt[0] == "ID":
            pending = nxt[1]
        elif kind == "ID" and text == "do" and nxt[0] == "DOLLAR" and body_tag is None:
            pending = f"DO block at line {line}"
        if kind == "DOLLAR":
            if body_tag is None and pending is not None:
                body_tag, scope, pending = text, pending, None
            elif body_tag == text:
                body_tag, scope = None, None
            continue
        if kind == "OP" and text == ";" and body_tag is None:
            pending = None

        # calls: what each open parenthesis belongs to
        if kind == "OP" and text == "(":
            callee = None
            if prev[0] == "ID" and prev[1] not in NOT_CALLS:
                before = toks[k - 2][1] if k > 1 else ""
                if before in ("function", "procedure"):
                    callee = "<header>"
                elif before not in RELATION_BEFORE:
                    callee = prev[1]
            parens.append(callee)
            continue
        if kind == "OP" and text == ")":
            if parens:
                parens.pop()
            continue

        if kind != "ID":
            continue
        if text == CLAIM_TABLE and scope is not None:
            claims.add(scope)
        if not PREFIX_NAME.match(text):
            continue
        refs += 1
        if nxt[1] in TYPE_WORDS:
            continue  # a declaration
        why = None
        if prev[1] == "||" or nxt[1] == "||":
            why = "concatenated with ||"
        elif prev[1] == ":=" or nxt[1] == "into":
            why = "assigned to another name"
        else:
            callee = parens[-1] if parens else None
            if callee is not None and callee != "<header>" and callee not in defined:
                why = f"passed to {callee}(), which this file does not define"
        if why:
            where = scope if scope is not None else "top level"
            assembly.setdefault(where, []).append((line, f"{text} {why}"))
    return refs, assembly, claims, defined


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
