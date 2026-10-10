#!/usr/bin/env bash
# Prove the two source lints CLAUDE.md says fail CI judge a VALUE, not the way it happens to be spelled:
# scripts/check_quoted_splices.py (the `_q` marker) and scripts/check_archive_object_keys.py (one function
# assembles every archive object key).
#
# WHY THIS GUARD EXISTS (review pass 10: #1094, #1096, and #1031 bullet A1031-3). Each lint passed a defect
# of its own class written in a spelling it did not expect:
#   * check_archive_object_keys.py recognised the prefix column by its token's spelling, and its lexer kept
#     a double-quoted identifier's quotes, so a second key built from `cfg."prefix"` (the same column as
#     `cfg.prefix`) passed (#1094);
#   * check_quoted_splices.py typed a local by all the text after its name, so a quoted list declared
#     `text default ''`, `text not null := ''` or `constant text` was never a `text` local and neither check
#     judged it (#1096);
#   * check_quoted_splices.py read an assignment only when it began its own line, so `if p then v_cols :=
#     quote_ident(c); end if;` and a DECLARE initialiser `v_cols text := quote_ident(c)` were never read
#     (#1031, A1031-3 and F8-01).
# Review pass 11 (#1179, F8-04) found check_quoted_splices.py still recognising each piece by its exact
# lower-case spelling: a body assignment only as `:=` (PL/pgSQL takes `=`), a quoting call only as
# `quote_ident(` or `format(` (not `quote_ident (`, `QUOTE_IDENT(`, `format (`), a local only when its type
# contained the word `text` (not `varchar`, `character varying(n)`, `pg_catalog.text`), and a SELECT INTO only
# with the list before INTO (not `select into v list`).
# Each script's --selftest carries these shapes too, but a selftest lives in the file it tests and goes
# wherever that file goes; these fixtures are the guard's own, so a mutant of either script is judged by
# something it did not write.
#
# HOW. Every defect check has a LIVENESS twin in the spelling each lint always handled (`cfg.prefix`, a
# plain `text` local assigned on its own line), so a checker that has stopped reading anything fails a
# premise rather than reading as a pass, and every "is not refused" sits beside a refusal of the same
# fixture in its other spelling.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   archive_keys_quoted_ident_spelled    -- the lexer keeps a quoted identifier's quotes again (#1094)
#   quoted_splices_type_rest_of_decl     -- only `:=` ends a declaration's type again (#1096)
#   quoted_splices_assign_line_anchored  -- a body assignment is read only at the start of a line (F8-01)
#   quoted_splices_initialiser_unread    -- a DECLARE initialiser is not an assignment (A1031-3)
#   quoted_splices_assign_colon_eq_only  -- a body assignment is only `:=`, never `=` (#1179)
#   quoted_splices_call_spelled          -- a quoting call is only its exact `name(` spelling (#1179)
#   quoted_splices_type_spelled          -- a declared type is its text as written, not the type (#1179)
#   quoted_splices_type_word_text        -- only `text` holds a quoted list, not varchar (#1179)
#   quoted_splices_into_list_first_only  -- a SELECT's INTO is read only after its list (#1179)
#
# Usage: lint_value_not_spelling.sh <container> <db> [checker.py]
# The container and database are accepted for the shape bench/discriminate.sh calls every guard with and
# are not used: the checks are static and run on the host. With no third argument both lints are taken from
# this checkout. A third argument is a copy of ONE of them (discriminate.sh hands it a mutant, under a .sql
# name, at a /repo/ path that is mapped to this checkout); which one is read from its interface, and the
# other is taken from the checkout.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_C="${1:?container}"; _DB="${2:?db}"; UNDER="${3:-}"
UNDER="${UNDER/#\/repo\//$ROOT/}"
if [ -n "$UNDER" ] && [ ! -s "$UNDER" ]; then
  printf 'FAIL  %-62s %s\n' "GUARD: the checker under test is readable" "$UNDER"
  exit 1
fi

ROOT="$ROOT" UNDER="$UNDER" python3 - <<'PY'
import importlib.machinery
import importlib.util
import os
import sys

ROOT, UNDER = os.environ["ROOT"], os.environ["UNDER"]
fail = 0


def report(ok, label, detail=""):
    global fail
    print(f"{'PASS' if ok else 'FAIL'}  {label:<62} {detail}")
    fail |= not ok


def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


cqs_path = os.path.join(ROOT, "scripts/check_quoted_splices.py")
aok_path = os.path.join(ROOT, "scripts/check_archive_object_keys.py")
if UNDER:
    try:
        under = load(UNDER, "under_test")
    except Exception as e:  # a mutant that is not Python verifies nothing
        report(False, "GUARD: the checker under test loads", f"{type(e).__name__}: {e}")
        sys.exit(1)
    if hasattr(under, "declared_types") and hasattr(under, "assignments"):
        cqs_path = UNDER
    elif hasattr(under, "scan") and hasattr(under, "CLAIM_TABLE"):
        aok_path = UNDER
    else:
        report(False, "GUARD: the checker under test is one of the two lints", UNDER)
        sys.exit(1)
cqs = load(cqs_path, "cqs")
aok = load(aok_path, "aok")
print(f"# check_quoted_splices: {cqs_path}\n# check_archive_object_keys: {aok_path}")

# --- check_archive_object_keys.py: the prefix is the column, however it is spelled (#1094) ------------
KEY_FN = r"""
create table if not exists archive.config (parent_table regclass primary key, prefix text not null);
create or replace function archive.configure(p_parent regclass, p_prefix text) returns void language plpgsql as $$
begin
  insert into archive.config (parent_table, prefix) values (p_parent, p_prefix)
  on conflict (parent_table) do update set prefix = excluded.prefix;
end;
$$;
create or replace function archive._owned_key(p_parent regclass, p_prefix text, p_child name) returns text
language plpgsql as $$
declare v_base_q text;
begin
  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(p_child) into v_base_q
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  insert into archive.object_key_owner (key_base, parent_oid) values (v_base_q, p_parent::oid)
    on conflict (key_base) do nothing;
  return v_base_q;
end;
$$;
create or replace function archive.export(p_parent regclass, p_child name) returns text language plpgsql as $$
declare cfg archive.config;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  return archive._owned_key(p_parent, cfg.prefix, p_child);
end;
$$;
create or replace function archive.export_too(p_parent regclass, p_child name) returns text language sql as $$
  select archive._owned_key(p_parent, (select prefix from archive.config where parent_table = p_parent), p_child);
$$;
"""


def second_key(fn, decl, read, expr):
    return KEY_FN + f"""
create or replace function {fn}(p_parent regclass, p_child name) returns text language plpgsql as $$
declare {decl}; v_key text;
begin
  {read}
  v_key := {expr} || quote_ident(p_child) || '.parquet';
  return v_key;
end;
$$;
"""


ROW = ("cfg archive.config", "select * into cfg from archive.config where parent_table = p_parent;")


def refused_in(src, fn):
    v, owner = aok.check_text("fixture.sql", src)
    return any(f"{fn} (line" in x for x in v), v, owner


v, owner = aok.check_text("one_key.sql", KEY_FN)
report(not v and owner == "archive._owned_key", "LIVENESS: archive keys: one key function is clean",
       f"owner {owner}" if not v else f"{v}")
hit, v, _ = refused_in(second_key("archive.k_bare", *ROW, "cfg.prefix"), "archive.k_bare")
report(hit, "LIVENESS: archive keys: a second key from cfg.prefix is refused",
       "names archive.k_bare" if hit else f"{v}")
for fn, decl, read, expr, what in [
        ("archive.k_quoted_col", *ROW, 'cfg."prefix"', 'from the quoted column cfg."prefix"'),
        ("archive.k_quoted_qual", '"Cfg" archive.config',
         'select * into "Cfg" from archive.config where parent_table = p_parent;', '"Cfg".prefix',
         'from the column behind a quoted qualifier "Cfg".prefix'),
        ("archive.k_quoted_subq", "v_unused int", "null;",
         '(select "prefix" from archive.config where parent_table = p_parent)',
         'from a subquery selecting the quoted column "prefix"'),
        ("archive.k_schema_qual", "v_unused int", "null;",
         "(select archive.config.prefix from archive.config where parent_table = p_parent)",
         "from the column qualified by schema and table")]:
    hit, v, _ = refused_in(second_key(fn, decl, read, expr), fn)
    report(hit, f"archive keys: a second key {what} is refused", f"names {fn}" if hit else f"{v}")
# "Prefix" quoted is another column: following the value must not turn every quoted word into the prefix
hit, v, owner = refused_in(second_key("archive.k_other", "cfg record", "select 'x' as \"Prefix\" into cfg;",
                                      'cfg."Prefix"'), "archive.k_other")
report(not hit and not v and owner == "archive._owned_key",
       'archive keys: a quoted "Prefix" (another column) is not the prefix',
       f"owner {owner}" if not v else f"{v}")

# --- check_quoted_splices.py: the declared type, every assignment (#1096, #1031) ------------------------
BODY = """
create or replace function f(p_on boolean) returns bigint language plpgsql as $$
declare v_nsp name := 'public'; {decl}; v_n bigint;
begin
  {stmt}
  execute format('select count(*) from (select %s from %I.t) s', {var}, v_nsp) into v_n;
  return v_n;
end;
$$;
"""


def flags(decl, stmt, var, why):
    v, q = cqs.check_text("fixture.sql", BODY.format(decl=decl, stmt=stmt, var=var))
    return any(f"  {var} " in x and why in x for x in v), v, q


C1, C2 = "not _q-suffixed", "nothing in its assignment"
QUOTE = "v_cols := quote_ident('c');"
LIE = "v_cols_q := 'nothing quoted here';"
hit, v, q = flags("v_cols text", QUOTE, "v_cols", C1)
report(hit, "LIVENESS: _q: check 1 flags an unmarked quoted list, plain `text`",
       "flagged" if hit else f"{v}")
hit, v, q = flags("v_cols_q text", LIE, "v_cols_q", C2)
report(hit, "LIVENESS: _q: check 2 flags an unearned _q, plain `text`", "flagged" if hit else f"{v}")
for decl, stmt, var, why, what in [
        ("v_cols text default ''", QUOTE, "v_cols", C1, "check 1, declared `text default ''`"),
        ("v_cols text not null := ''", QUOTE, "v_cols", C1, "check 1, declared `text not null := ''`"),
        ('v_cols text collate "C"', QUOTE, "v_cols", C1, 'check 1, declared `text collate "C"`'),
        ("v_cols_q text default ''", LIE, "v_cols_q", C2, "check 2, declared `text default ''`"),
        ("v_cols text := quote_ident('c')", "null;", "v_cols", C1, "check 1, a `:=` DECLARE initialiser"),
        ("v_cols text default format('%I', 'c')", "null;", "v_cols", C1, "check 1, a DEFAULT initialiser"),
        ("v_cols constant text = quote_ident('c')", "null;", "v_cols", C1, "check 1, `constant text = ...`"),
        ("v_cols_q text := 'nothing quoted'", "null;", "v_cols_q", C2, "check 2, a DECLARE initialiser"),
        ("v_cols text", "if p_on then v_cols := quote_ident('c'); end if;", "v_cols", C1,
         "check 1, in a one-line if"),
        ("v_cols text", "if p_on then null; else v_cols := quote_ident('c'); end if;", "v_cols", C1,
         "check 1, after else on one line"),
        ("v_cols text", "for v_n in 1..2 loop v_cols := quote_ident('c'); end loop;", "v_cols", C1,
         "check 1, after loop on one line"),
        ("v_cols text", "null; v_cols := quote_ident('c');", "v_cols", C1,
         "check 1, second statement on a line"),
        # #1179 (F8-04): the same value in each other spelling PL/pgSQL accepts
        ("v_cols text", "v_cols = quote_ident('c');", "v_cols", C1, "check 1, a body `=` assignment"),
        ("v_cols_q text", "v_cols_q = 'nothing quoted here';", "v_cols_q", C2, "check 2, a body `=` assignment"),
        ("v_cols text", "v_cols := quote_ident ('c');", "v_cols", C1, "check 1, `quote_ident (` with a space"),
        ("v_cols text", "v_cols := Quote_Ident('c');", "v_cols", C1, "check 1, `Quote_Ident(` mixed case"),
        ("v_cols text", "v_cols := pg_catalog . quote_ident('c');", "v_cols", C1,
         "check 1, `pg_catalog . quote_ident(`"),
        ("v_cols text", "v_cols := format ('%1$I', 'c');", "v_cols", C1, "check 1, `format (` with %1$I"),
        ("v_cols text", "v_cols := FORMAT('%I', 'c');", "v_cols", C1, "check 1, `FORMAT(` upper case"),
        ("v_cols varchar", QUOTE, "v_cols", C1, "check 1, declared `varchar`"),
        ("v_cols character varying(500)", QUOTE, "v_cols", C1, "check 1, declared `character varying(500)`"),
        ("v_cols pg_catalog.text", QUOTE, "v_cols", C1, "check 1, declared `pg_catalog.text`"),
        ('v_cols "text"', QUOTE, "v_cols", C1, 'check 1, declared `"text"`'),
        ("v_cols_q pg_catalog.text", LIE, "v_cols_q", C2, "check 2, declared `pg_catalog.text`"),
        ("V_Cols text", QUOTE, "v_cols", C1, "check 1, declared `V_Cols`, assigned as `v_cols`"),
        ("v_cols text", "select into v_cols quote_ident('c');", "v_cols", C1, "check 1, `select into v list`"),
        ("v_cols text", "select into strict v_cols quote_ident(relname) from pg_class limit 1;", "v_cols", C1,
         "check 1, `select into strict v list from`"),
        ("v_cols_q text", "select into v_cols_q 'nothing quoted here';", "v_cols_q", C2,
         "check 2, `select into v list`"),
        ("v_cols text", "select quote_ident(relname) from pg_class limit 1 into v_cols;", "v_cols", C1,
         "check 1, `select list from t into v`"),
        ("v_cols text", "for v_n in select 1 loop select into v_cols quote_ident('c'); end loop;", "v_cols", C1,
         "check 1, `select into v list` after a FOR's own query")]:
    hit, v, q = flags(decl, stmt, var, why)
    report(hit, f"_q: {what}", "flagged" if hit else f"not flagged (violations {v}, quoting {q})")
# A named-notation argument is not an assignment: the unmarked local named as the argument is not judged,
# while the marked list assigned beside it is read and counted
v, q = cqs.check_text("named.sql", BODY.format(
    decl="v_cols_q text; v_arg text", var="v_cols_q",
    stmt="if p_on then perform g(v_arg := quote_ident('c')); end if; v_cols_q := quote_ident('d');"))
report(not v and q == 1, "_q: a named-notation argument is not read as an assignment",
       f"violations {v}, quoting {q}")
# Reading INTO wherever it stands must still pair each target with its own item: an INTO-first SELECT
# assigning a marked list and an unmarked raw value judges each on its own (no violation, one quoting)
v, q = cqs.check_text("into_pair.sql", BODY.format(
    decl="v_cols_q text; v_raw text", var="v_cols_q",
    stmt="select into v_cols_q, v_raw quote_ident('c'), 'raw' from pg_class;"))
report(not v and q == 1, "_q: an INTO-first SELECT pairs each target with its own item",
       f"violations {v}, quoting {q}")
# A `name` local is the raw identifier's type and is not judged, so a quoting expression on the way to an
# OID (the shape pgpm._delta_seq is called in) is not read as a quoted value
v, q = cqs.check_text("name.sql", BODY.format(
    decl="v_seq name; v_cols_q text", var="v_cols_q",
    stmt="v_seq := pgpm._delta_seq(format('%I.%I', v_nsp, 'd')::regclass); v_cols_q := quote_ident(v_seq);"))
report(not v and q == 1, "_q: a `name` local holding a raw name is not judged",
       f"violations {v}, quoting {q}")

sys.exit(fail)
PY
