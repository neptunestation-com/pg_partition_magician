#!/usr/bin/env bash
# Prove scripts/check_quoted_splices.py (the `_q` marker, CI's `Quoted splices` job) reads EVERY body and
# EVERY assignment PL/pgSQL makes, so CLAUDE.md's "fails CI when a quote-derived text local lacks the
# suffix" holds for each of them.
#
# WHY THIS GUARD EXISTS. Review pass 12 found five ways a quoted list reached an unmarked text local the lint
# never read (#1278: F8-01, F12-06, F8-08; #1236 bullets B08-01 and B08-02, re-found as F12-03 and F12-05):
#   * a FOR or FOREACH loop's target is assigned as an INTO's is, and was never read (`for v_cols in select
#     string_agg(quote_ident(attname), ', ') ... loop`), nor was an EXECUTE's INTO;
#   * bodies were found by splitting the file on the bare `$$`, so a body tagged `$fn$` was never read;
#   * a `/* block comment */` was not blanked, so one before an assignment kept it from starting a statement
#     and a `;` inside one ended it early;
#   * an escape string's backslash was not read, so `E'it\'s'` closed at its escaped quote and the next quote
#     opened a literal that blanked the assignment after it.
# The script's --selftest carries these shapes too, but a selftest lives in the file it tests and goes
# wherever that file goes; these fixtures are the guard's own, so a mutant is judged by something it did not
# write.
#
# HOW. Each shape is a function whose unmarked text local v_cols holds a quoted list, and the guard requires
# the lint to refuse it and to pass its `_q`-marked twin. Every shape's premise is witnessed by BEHAVIOUR, not
# by its spelling: the function is created in a fresh database and run, so PL/pgSQL is shown to accept the
# shape and to put the QUOTED name into v_cols (the `%s` splice of it runs, and it returns "Foo Bar"). The
# plain shape every version of the lint refused is the liveness twin, and two negatives keep the readers from
# passing by refusing everything: the tree's own install files stay clean, and an EXECUTE whose template
# quotes with `%I` (a column's VALUE comes back, not a name) leaves its unmarked target alone.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   quoted_splices_loop_target_unread   -- a FOR or FOREACH loop's target is not an assignment (F8-01, F12-06)
#   quoted_splices_loop_first_branch    -- a loop over a set operation is given its first branch's list only
#   quoted_splices_scan_in_quoted_names -- a `..` or `loop` inside a quoted name is read as the loop's structure
#   quoted_splices_execute_into_unread  -- an EXECUTE's INTO is not an assignment (F8-01)
#   quoted_splices_bare_dollar_bodies   -- only a body tagged with the bare `$$` is read (F8-08)
#   quoted_splices_block_comment_kept   -- a block comment is not blanked (B08-01, F12-03)
#   quoted_splices_e_string_unescaped   -- an escape string's backslash escapes nothing (B08-02, F12-05)
# and, from PR #1313's verification (round 2):
#   quoted_splices_nested_dollar_as_code -- a dollar-quoted string nested in a body is read as code, so a `/*`
#                                           in it blanks the rest of the body (V-04)
#   quoted_splices_exec_statement_guessed -- an EXECUTE whose statement is in a variable is judged on nothing,
#                                           so check 2 refuses an earned `_q` (V-03)
#   quoted_splices_spliced_value_judged  -- an item a format() conversion splices in is judged as if it were
#                                           the value (V-03)
#   quoted_splices_paren_branch_skipped  -- a set operation's parenthesised branch is not read (V-01)
#   quoted_splices_format_template_unrendered -- a format() template's `%%` is not read as `%` (V-02)
#   quoted_splices_label_target_unread   -- a target qualified by its block's label is not read (V-05)
# Each round-2 negative (an unreadable statement must not be refused) has a liveness twin: check 2 refuses
# the same body's `_q` local given a plain literal.
#
# Usage: quoted_splices_every_body.sh <container> <db> [checker.py]
# The database is dropped and created here, and holds only the fixtures. With no third argument the checker
# is this checkout's; a third argument is a copy of it (discriminate.sh hands it a mutant, under a .sql name,
# at a /repo/ path that is mapped to this checkout).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="${1:?container}"; DB="${2:?db}"; UNDER="${3:-$ROOT/scripts/check_quoted_splices.py}"
UNDER="${UNDER/#\/repo\//$ROOT/}"
if [ ! -s "$UNDER" ]; then
  printf 'FAIL  %-66s %s\n' "GUARD: the checker under test is readable" "$UNDER"
  exit 1
fi
q() { docker exec "$C" psql -U postgres "$@"; }
q -q -c "drop database if exists $DB" >/dev/null 2>&1
if ! q -q -c "create database $DB" >/dev/null 2>&1; then
  printf 'FAIL  %-66s %s\n' "GUARD: the fixture database is created" "$C/$DB"
  exit 1
fi

ROOT="$ROOT" UNDER="$UNDER" C="$C" DB="$DB" python3 - <<'PY'
import importlib.machinery
import importlib.util
import os
import subprocess
import sys

ROOT, UNDER, C, DB = (os.environ[k] for k in ("ROOT", "UNDER", "C", "DB"))
fail = 0


def report(ok, label, detail=""):
    global fail
    print(f"{'PASS' if ok else 'FAIL'}  {label:<66} {detail}")
    fail |= not ok


def psql(sql):
    r = subprocess.run(["docker", "exec", "-i", C, "psql", "-U", "postgres", "-d", DB, "-qtA",
                        "-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    lines = r.stdout.strip().splitlines()
    return r.returncode, (lines[-1] if lines else ""), r.stderr.strip()


try:
    loader = importlib.machinery.SourceFileLoader("under_test", UNDER)
    spec = importlib.util.spec_from_loader("under_test", loader)
    cqs = importlib.util.module_from_spec(spec)
    loader.exec_module(cqs)
except Exception as e:  # a mutant that is not Python verifies nothing
    report(False, "GUARD: the checker under test loads", f"{type(e).__name__}: {e}")
    sys.exit(1)
if not hasattr(cqs, "check_text"):
    report(False, "GUARD: the checker under test is check_quoted_splices.py", UNDER)
    sys.exit(1)
print(f"# check_quoted_splices: {UNDER}")

rc, _, err = psql("create table public.g20_t (id int, \"Foo Bar\" int); insert into public.g20_t values (1, 2);")
report(rc == 0, "GUARD: the fixture table is created", err)

# The #409 shape: v_cols holds a quoted list, spliced with %s. {var} is v_cols, or v_cols_q in the twin.
FN = """
create or replace function public.{fn}() returns text language plpgsql as {tag}
{label}declare v_n bigint; v_x text; v_i int; {decl};
begin
  {stmt}
  execute format('select count(*) from (select %s from public.g20_t) s', {var}) into v_n;
  return {var};
end;
{tag};
"""


def fixture(fn, decl, stmt, tag="$$", marked=False, prefix="", label=""):
    src = prefix + FN.format(fn=fn, tag=tag, decl=decl, stmt=stmt, var="v_cols", label=label)
    return src.replace("v_cols", "v_cols_q") if marked else src


def judged(src):
    v, n = cqs.check_text("fixture.sql", src)
    return any("  v_cols " in x and "not _q-suffixed" in x for x in v), v, n


def premise(fn, src):
    rc, out, err = psql(src + f"select public.{fn}();")
    ok = rc == 0 and out == '"Foo Bar"'
    return ok, (f"returns {out}" if ok else f"rc {rc}, got {out!r}: {err[:120]}")


QI = "quote_ident('Foo Bar')"
SHAPES = [
    # (function, label, declaration, statement, tag, file prefix)
    ("g20_plain", "LIVENESS: the plain assignment every version refused", "v_cols text",
     f"v_cols := {QI};", "$$", ""),
    # #1278, F8-01 and F12-06: a loop's target
    ("g20_for", "a FOR ... IN SELECT loop's target", "v_cols text",
     "for v_cols in select string_agg(quote_ident(attname), ', ') from pg_attribute "
     "where attrelid = 'public.g20_t'::regclass and attname = 'Foo Bar' loop null; end loop;", "$$", ""),
    ("g20_for2", "the second of a FOR loop's targets", "v_cols text",
     f"for v_i, v_cols in select 1, {QI} loop null; end loop;", "$$", ""),
    ("g20_forx", "a labelled FOR ... IN EXECUTE loop's target", "v_cols text",
     "<<outer>> for v_cols in execute 'select quote_ident(''Foo Bar'')' loop null; end loop;", "$$", ""),
    ("g20_foreach", "a FOREACH ... IN ARRAY loop's target", "v_cols text",
     f"foreach v_cols in array array[{QI}] loop null; end loop;", "$$", ""),
    # a set operation returns every branch's rows; a `..` or `loop` in a quoted name is part of the name
    ("g20_for_union", "a FOR target quoted by a UNION's second branch", "v_cols text",
     f"for v_cols in select 'x' where false union all select {QI} loop null; end loop;", "$$", ""),
    ("g20_for_dots", "a FOR loop's target beside a column named \"a..b\"", "v_cols text",
     f"for v_cols in select {QI} as \"a..b\" loop null; end loop;", "$$", ""),
    ("g20_for_kw", "a FOR loop's target after a column named \"loop\"", "v_cols text",
     f"for v_x, v_cols in select 'x' as \"loop\", {QI} loop null; end loop;", "$$", ""),
    # #1278, F8-01: an EXECUTE's INTO
    ("g20_exec", "an EXECUTE ... INTO target", "v_cols text",
     "execute 'select quote_ident(''Foo Bar'')' into v_cols;", "$$", ""),
    ("g20_execf", "an EXECUTE format() ... INTO STRICT target", "v_cols text",
     "execute format('select quote_ident(%L) from %I.g20_t', 'Foo Bar', 'public') into strict v_cols;", "$$", ""),
    ("g20_execu", "an EXECUTE ... USING ... INTO target", "v_cols text",
     "execute 'select quote_ident($1)' using 'Foo Bar'::text into v_cols;", "$$", ""),
    # #1278, F8-08: every body, whatever its tag
    ("g20_tag_fn", "a body tagged $fn$", "v_cols text", f"v_cols := {QI};", "$fn$", ""),
    ("g20_tag_body", "a body tagged $body$ holding `$$` in a nested $q$", "v_cols text",
     f"v_x := $q$ $$ $q$; v_cols := {QI};", "$body$", ""),
    ("g20_tag_after", "a $$ body after `$$` in a literal and in comments", "v_cols text",
     f"v_cols := {QI};", "$$", "-- bodies are $$-quoted\n/* $$ */\nselect 'a $$ b';\n"),
    # #1236, B08-01 and F12-03: a block comment is a comment
    ("g20_bc_before", "an assignment behind a block comment", "v_cols text",
     f"v_n := 0; /* the quoted list */ v_cols := {QI};", "$$", ""),
    ("g20_bc_semi", "an assignment with a `;` in a block comment", "v_cols text",
     "v_cols := /* ; */ quote_ident('Foo Bar');", "$$", ""),
    ("g20_bc_nested", "a nested block comment holding `;` and `'`", "v_cols text",
     f"/* a /* b */ it's; */ v_cols := {QI};", "$$", ""),
    # #1236, B08-02 and F12-05: only an escape string's backslash escapes
    ("g20_e_quote", "an assignment after E'it\\'s'", "v_cols text",
     f"v_x := E'it\\'s'; v_cols := {QI};", "$$", ""),
    ("g20_e_bs", "an assignment after e'a\\\\'", "v_cols text",
     f"v_x := e'a\\\\'; v_cols := {QI};", "$$", ""),
    ("g20_plain_bs", "an assignment after a plain 'C:\\'", "v_cols text",
     f"v_x := 'C:\\'; v_cols := {QI};", "$$", ""),
    # PR #1313 round 2 (V-04): a `/*` inside a nested dollar-quoted string is text, not a comment
    ("g20_dollar_glob", "an assignment after $g$/tmp/*$g$", "v_cols text",
     f"v_x := $g$/tmp/*$g$; v_cols := {QI};", "$$", ""),
    # (V-01): a set operation's parenthesised branch is read, for a loop and for an EXECUTE
    ("g20_paren_for", "a FOR target quoted by a parenthesised UNION branch", "v_cols text",
     f"for v_cols in select 'x' where false union all (select {QI}) loop null; end loop;", "$$", ""),
    ("g20_paren_exec", "an EXECUTE INTO target quoted by a parenthesised branch", "v_cols text",
     "execute 'select ''x'' where false union all (select quote_ident(''Foo Bar''))' into v_cols;", "$$", ""),
    # (V-02): a format() template is read as format() renders it, `%%I` as `%I`
    ("g20_fmt_pct", "an EXECUTE INTO target quoted by a template's format(%%I)", "v_cols text",
     "execute format('select format(''%%I'', %L::text)', 'Foo Bar') into v_cols;", "$$", ""),
    # (V-05): a target qualified by its block's label is the local it names
    ("g20_label_for", "a FOR target qualified by its block's label", "v_cols text",
     f"for blk.v_cols in select {QI} loop null; end loop;", "$$", "", "<<blk>>\n"),
    ("g20_label_exec", "an EXECUTE INTO target qualified by its block's label", "v_cols text",
     "execute 'select quote_ident(''Foo Bar'')' into blk.v_cols;", "$$", "", "<<blk>>\n"),
    ("g20_label_into", "a SELECT INTO target qualified by its block's label", "v_cols text",
     f"select {QI} into blk.v_cols;", "$$", "", "<<blk>>\n"),
    ("g20_label_assign", "a `:=` target qualified by its block's label", "v_cols text",
     f"blk.v_cols := {QI};", "$$", "", "<<blk>>\n"),
]
for fn, label, decl, stmt, tag, prefix, *blk in SHAPES:
    lab = blk[0] if blk else ""
    src = fixture(fn, decl, stmt, tag, prefix=prefix, label=lab)
    ok, detail = premise(fn, src)
    report(ok, f"LIVENESS: PL/pgSQL runs {fn} and v_cols holds the quoted name", detail)
    hit, v, n = judged(src)
    mv, mn = cqs.check_text("twin.sql", fixture(fn, decl, stmt, tag, marked=True, prefix=prefix, label=lab))
    twin = not mv and mn == 1
    name = label if label.startswith("LIVENESS:") else f"_q: refused, {label}"
    report(hit and twin, name,
           "refused; its _q twin passes, counted once" if hit and twin
           else f"unmarked: {v} ({n} quoting); twin: {mv} ({mn} quoting)")

# Negatives: reading more must not refuse what is not quoted. An EXECUTE template's own %I quotes a name in
# the dynamic statement, and what comes back is the column's VALUE (2), which an unmarked local may hold.
neg = FN.format(fn="g20_neg", tag="$$", decl="v_cols_q text := quote_ident('Foo Bar'); v_raw text", var="v_cols_q",
                stmt="execute format('select %I from public.g20_t', 'Foo Bar') into v_raw; "
                     "if v_raw is distinct from '2' then raise exception 'v_raw holds %', v_raw; end if;", label="")
rc, out, err = psql(neg + "select public.g20_neg();")
report(rc == 0 and out == '"Foo Bar"', "LIVENESS: PL/pgSQL runs g20_neg and v_raw holds the column's value 2",
       f"rc {rc}, got {out!r} {err[:120]}")
v, n = cqs.check_text("neg.sql", neg)
report(not v and n == 1, "_q: an EXECUTE whose template quotes with %I is not refused", f"violations {v}, quoting {n}")

# PR #1313 round 2 (V-03): a dynamic statement the lint cannot read is judged in NEITHER direction. Each
# marked local below earns its suffix at run time (the function returns the quoted name out of it), but the
# value is not in the statement that assigns it: the statement arrives in a variable, or the list item is a
# value format() splices in. Check 2 must not refuse them; its liveness is the same body with the marked
# local given a plain literal, which it must refuse.
SQL_Q = "v_sql := 'select quote_ident(''Foo Bar'')'; "
UNREAD = [
    ("g20_un_var", "execute v_sql into v_cols_q", SQL_Q + "execute v_sql into v_cols_q;", 0),
    ("g20_un_forx", "for v_cols_q in execute v_sql", SQL_Q + "for v_cols_q in execute v_sql loop null; end loop;", 0),
    ("g20_un_spl", "a template splicing a _q value with %L",
     f"v_cols_q := {QI}; execute format('select %L::text', v_cols_q) into v_cols_q;", 1),
]
lie = FN.format(fn="g20_lie", tag="$$", decl="v_cols_q text; v_sql text", var="v_cols_q",
                stmt="v_cols_q := 'nothing quoted';", label="")
v, n = cqs.check_text("lie.sql", lie)
report(any("v_cols_q" in x and "nothing in its assignment" in x for x in v),
       "LIVENESS: check 2 refuses this body's _q local given a plain literal", f"violations {v}")
for fn, what, stmt, quoting in UNREAD:
    src = FN.format(fn=fn, tag="$$", decl="v_cols_q text; v_sql text", var="v_cols_q", stmt=stmt, label="")
    ok, detail = premise(fn, src)
    report(ok, f"LIVENESS: PL/pgSQL runs {fn} and v_cols_q holds the quoted name", detail)
    v, n = cqs.check_text("unread.sql", src)
    report(not v and n == quoting, f"_q: not judged, {what}", f"violations {v}, quoting {n}")
total, bad = 0, []
for rel in ("pgpm_core/install.sql", "pgpm_hypertable/install.sql", "pgpm_archive/install.sql"):
    v, n = cqs.check_text(rel, open(os.path.join(ROOT, rel)).read())
    total += n
    bad += v
report(not bad and total >= 12, "_q: the tree's own install files stay clean",
       f"{total} quoting assignments" if not bad else f"{bad[:3]}")

subprocess.run(["docker", "exec", C, "psql", "-U", "postgres", "-qc", f"drop database if exists {DB}"],
               capture_output=True)
sys.exit(fail)
PY
