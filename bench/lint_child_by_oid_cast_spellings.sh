#!/usr/bin/env bash
# Prove scripts/check_archive_child_by_oid.py's rule 1 reads a cast to regclass, and a relation's name, by what
# they ARE and not by one spelling of each: outside archive._resolve_child nothing but a lone identifier, literal
# or parameter is cast to regclass, in any spelling of the cast, and a relation's name is a name however the text
# reaches it.
#
# WHY THIS GUARD EXISTS (review pass 12: #1287, and three more spellings on #1180).
#   * #1287: rule 1 says nothing is cast to regclass from a parenthesised expression (a relation found by a name
#     built at run time), and matched that as the three tokens `)` `::` `regclass`. The same cast written
#     `(...)::pg_catalog.regclass`, `CAST(... AS regclass)` or `regclass(...)` passed with no violation, and so
#     did the same name cast through text on the way, `(...)::text::regclass`. Each resolves the name at run time.
#   * #1180: a function finding a relation by the name column read as DATA out of its pg_class row (`where
#     to_jsonb(c) ->> 'relname' = v_rel`), by its rendered identity (`(pg_identify_object('pg_class'::regclass,
#     c.oid, 0)).identity = v_rel`), or by a set operation over a name that stands alone in its select list
#     (`select c.relname, c.oid ... intersect select v_rel, c2.oid ...`) passed too: no name column's token
#     stands where the rule refused one, and no regclass is rendered.
#   * #1386 (review pass 13): a name column cast to regclass alone in a select list, `select c.relname::regclass
#     into v_x` or `cast(c.relname as regclass)`, passed, because the checker took every cast around a name as
#     part of the value that may stand alone; `regclass(c.relname)` was refused. The cast is the lookup by name.
#     Its sibling: a regclass rendered as text and cast back (`c.oid::regclass::text::regclass`) was taken whole
#     as the rendering, which may stand alone too.
# The checker's --selftest carries these shapes, but a selftest lives in the file it tests; these fixtures are the
# guard's own, planted in the REAL module of this checkout, so a mutant of the checker is judged by code it did
# not write.
#
# HOW. Every refusal sits beside a LIVENESS twin the rule always refused (`(v_nsp || '.' || v_rel)::regclass`,
# a local holding a relname cast as `v_rel::regclass`, `c.relname = v_rel` in a WHERE), so a checker that has
# stopped reading fails a premise rather than reading as a pass; and the module itself, a lone value cast in
# every spelling, a number cast to regclass, each new reading alone in a select list and reported, and a UNION
# ALL must stay clean, so a checker that refuses everything fails too. A refusal is the planted statement's own:
# a violation must name one of its lines.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each one clause of the fix:
#   archive_child_by_oid_cast_qualified_unread  -- the type is matched as the bare word regclass again (#1287)
#   archive_child_by_oid_cast_as_unread         -- CAST(x AS regclass) is no cast to the rule (#1287)
#   archive_child_by_oid_cast_call_unread       -- regclass(x) is no cast to the rule (#1287)
#   archive_child_by_oid_cast_chain_unread      -- a cast to text on the way makes the value no name (#1287)
#   archive_child_by_oid_cast_case_unread       -- a CASE ... END cast to regclass is a lone `end` (#1323's V-01)
#   archive_child_by_oid_data_read_unread       -- a name column named as data is no name (#1180)
#   archive_child_by_oid_identity_unread        -- an object's rendered identity is no name (#1180)
#   archive_child_by_oid_set_operation_unread   -- a set operation compares nothing (#1180)
#   archive_child_by_oid_set_operation_flat     -- set operations without precedence: `a UNION ALL b INTERSECT c`
#                                                  refuses a name in a, which nothing compares (PR #1323's review)
#   archive_child_by_oid_identity_any_field     -- every field of pg_identify_object() is a name, so `.type =
#                                                  'table'` is refused (PR #1323's review)
#   archive_child_by_oid_name_cast_alone        -- a cast to regclass around a name column is part of the value
#                                                  that may stand alone in a select list (#1386)
#   archive_child_by_oid_rendered_recast_alone  -- a rendered regclass cast back to regclass is part of the
#                                                  rendering, which may stand alone (#1386's sibling)
#
# Usage: lint_child_by_oid_cast_spellings.sh <container> <db> [checker.py]
# The container and database are accepted for the shape bench/discriminate.sh calls every guard with and are
# not used: the checks are static and run on the host. With no third argument the checker is taken from this
# checkout. A third argument is a copy of it (discriminate.sh hands it a mutant, under a .sql name, at a /repo/
# path that is mapped to this checkout).
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
sys.path.insert(0, os.path.join(ROOT, "scripts"))   # the checker imports the archive lexer from there
fail = 0


def report(ok, label, detail=""):
    global fail
    print(f"{'PASS' if ok else 'FAIL'}  {label:<62} {detail}")
    fail |= not ok


path = UNDER or os.path.join(ROOT, "scripts/check_archive_child_by_oid.py")
try:
    loader = importlib.machinery.SourceFileLoader("under_test", path)
    spec = importlib.util.spec_from_loader("under_test", loader)
    chk = importlib.util.module_from_spec(spec)
    loader.exec_module(chk)
    chk.check_text
except Exception as e:  # a mutant that is not Python verifies nothing
    report(False, "GUARD: the checker under test loads", f"{type(e).__name__}: {e}")
    sys.exit(1)
print(f"# check_archive_child_by_oid: {path}")
MODULE = open(os.path.join(ROOT, "pgpm_archive/install.sql")).read()


def verdict(src):
    v, _ = chk.check_text(src)
    return v


def planted(body):
    """(the real module with one function planted after it, the planted statements)."""
    return MODULE + f"""
create or replace function archive._planted(p_parent regclass) returns void language plpgsql as $$
declare v_nsp name; v_rel name; v_said text; v_x regclass; v_oid oid; v_oids oid[];
begin
{body}
end;
$$;
""", body


def refused(body, why):
    """Whether a violation names a line of the planted statements AND says why: the refusal is of the planted
    lookup, for the reason this guard is about, not of something else beside it (identity, not a count)."""
    src, stmt = planted(body)
    first = src.count("\n", 0, src.index(stmt)) + 1
    lines = range(first, first + stmt.count("\n") + 1)
    return any(f"(line {n})" in x and why in x for x in verdict(src) for n in lines)


def clean(body):
    return not verdict(planted(body)[0])


report(not verdict(MODULE), "LIVENESS: the checkout's module passes the checker", "pgpm_archive/install.sql")

# --- #1287: a name built at run time, cast to regclass in every spelling of the cast --------------------------------
BUILT = "v_nsp || '.' || v_rel"
CAST = "an expression is cast to regclass"
report(refused(f"  v_x := ({BUILT})::regclass;", CAST), "LIVENESS: (v_nsp || '.' || v_rel)::regclass is refused")
for label, expr in (("(...)::pg_catalog.regclass", f"({BUILT})::pg_catalog.regclass"),
                    ("cast(... as regclass)", f"cast({BUILT} as regclass)"),
                    ("CAST((...) AS pg_catalog.regclass)", f"CAST(({BUILT}) AS pg_catalog.regclass)"),
                    ("regclass(...)", f"regclass({BUILT})"),
                    ("pg_catalog.regclass(...)", f"pg_catalog.regclass({BUILT})"),
                    ("(...)::text::regclass", f"({BUILT})::text::regclass"),
                    ("case ... end::regclass (#1323 V-01)", f"case when v_nsp is not null then {BUILT} end::regclass"),
                    ("case ... end::pg_catalog.regclass", f"case when v_rel is null then null else {BUILT} end::pg_catalog.regclass")):
    report(refused(f"  v_x := {expr};", CAST), f"a built name cast as {label} is refused", "#1287")

# ... and the local a relname was selected INTO, cast the same ways
INTO = "  select c.relname into v_rel from pg_class c where c.oid = p_parent;\n"
LOCAL = "v_rel, which holds a relname selected into it, is cast to regclass"
report(refused(INTO + "  v_x := v_rel::regclass;", LOCAL), "LIVENESS: a local holding a relname, v_rel::regclass, is refused")
for expr in ("v_rel::pg_catalog.regclass", "cast(v_rel as regclass)", "regclass(v_rel)", "v_rel::text::regclass"):
    report(refused(INTO + f"  v_x := {expr};", LOCAL), f"the local cast as {expr} is refused", "#1287")

# what the rule allows stays clean: a lone value in each spelling (the checker's stated limit: a lexer cannot tell
# an oid from text) and a value cast to a number type last, which is an oid again
report(clean("  v_x := v_oid::regclass; v_x := v_oid::pg_catalog.regclass; v_x := cast(v_oid as regclass);\n"
             "  v_x := regclass(v_oid); v_x := 'pg_class'::regclass; v_x := v_oids[1]::regclass;"),
       "LIVENESS: a lone identifier, literal or element cast is clean")
report(clean(f"  v_x := ({BUILT})::oid::regclass; v_x := cast(({BUILT})::oid as regclass);\n"
             f"  v_x := regclass(({BUILT})::int8);"),
       "LIVENESS: a value cast to a number, then to regclass, is clean")

# --- #1386: a name column cast to regclass where it would otherwise stand alone ------------------------------------
# the cast is the lookup by name (the relname resolved through search_path), so it is no part of the value that
# may stand alone in a select list; the call spelling was always refused, and a cast to text alone is still clean
ROW = "from pg_class c where c.oid = p_parent;"
report(refused(f"  select regclass(c.relname) into v_x {ROW}", "c.relname stands in an expression"),
       "LIVENESS: regclass(c.relname) alone in a select list is refused")
NAMED = "c.relname is cast to regclass"
for expr in ("c.relname::regclass", "cast(c.relname as regclass)", "c.relname::pg_catalog.regclass",
             "(c.relname)::text::regclass"):
    report(refused(f"  select {expr} into v_x {ROW}", NAMED), f"select {expr} into a local is refused", "#1386")
report(refused(f"  select format('%s', c.relname::regclass) into v_said {ROW}", NAMED),
       "format('%s', c.relname::regclass) is refused", "#1386")
report(clean(f"  select c.relname::text, cast(c.relname as varchar) into v_rel, v_said {ROW}\n"
             "  raise notice '% %', v_rel, v_said;"),
       "LIVENESS: a name column cast to text alone is clean")
# ... and its sibling: a regclass rendered as text, alone, is clean; cast back to regclass it is the name resolved
report(clean(f"  select c.oid::regclass::text into v_said {ROW}\n  raise notice '%', v_said;"),
       "LIVENESS: c.oid::regclass::text alone in a select list is clean")
RECAST = "a regclass rendered as text (c.oid :: regclass :: text) is cast to regclass"
for expr in ("c.oid::regclass::text::regclass", "cast(c.oid::regclass::text as regclass)"):
    report(refused(f"  select {expr} into v_x {ROW}", RECAST), f"select {expr} into a local is refused", "#1386")


# --- #1180: a relation found by its name with no name column's token where rule 1 refused one ----------------------
def by(pred):
    return f"  select c.oid into v_oid from pg_class c where {pred};"


report(refused(by("c.relname = v_rel"), "c.relname is compared"), "LIVENESS: a lookup by c.relname = v_rel is refused")
DATA = "a name column read as data"
for label, pred in (("to_jsonb(c) ->> 'relname' = v_rel", "to_jsonb(c) ->> 'relname' = v_rel"),
                    ("row_to_json(c)::jsonb #>> '{relname}'", "row_to_json(c)::jsonb #>> '{relname}' = v_rel"),
                    ("jsonb_extract_path_text(.., 'relname')", "jsonb_extract_path_text(to_jsonb(c), 'relname') = v_rel")):
    report(refused(by(pred), DATA), f"a lookup by {label} is refused", "#1180")
SAID = "an object's identity rendered as text"
for label, pred in (("(pg_identify_object(...)).identity = v_rel",
                     "(pg_identify_object('pg_class'::regclass, c.oid, 0)).identity = v_rel"),
                    ("pg_describe_object(...) = 'table ' || v_rel",
                     "pg_describe_object('pg_class'::regclass, c.oid, 0) = 'table ' || v_rel")):
    report(refused(by(pred), SAID), f"a lookup by {label} is refused", "#1180")
for op, stmt in (("INTERSECT", "  select c.relname, c.oid into v_rel, v_oid from pg_class c\n"
                               "  intersect select v_nsp, c2.oid from pg_class c2;"),
                 ("INTERSECT", "  select v_nsp, c2.oid into v_rel, v_oid from pg_class c2\n"
                               "  intersect select c.relname, c.oid from pg_class c;"),
                 ("EXCEPT", "  select c.relname, c.oid into v_rel, v_oid from pg_class c\n"
                            "  except select v_nsp, c2.oid from pg_class c2;"),
                 ("UNION", "  select c.relname into v_rel from pg_class c where c.oid = p_parent union select v_nsp;")):
    side = "second" if stmt.lstrip().startswith("select v_nsp") else "first"
    report(refused(stmt, f"c.relname stands in the select list of a query under {op}"),
           f"a name alone in the {side} operand of {op} is refused", "#1180")

# what the rule allows stays clean: each reading alone, off a row found by oid, and reported; and UNION ALL
report(clean("  select to_jsonb(c) ->> 'relname', (pg_identify_object('pg_class'::regclass, c.oid, 0)).identity\n"
             "    into v_rel, v_said from pg_class c where c.oid = p_parent;\n"
             "  raise notice '% is %', v_rel, v_said;"),
       "LIVENESS: a name read as data or identity and reported is clean")
report(clean("  select c.relname into v_rel from pg_class c where c.oid = p_parent\n"
             "  union all select c.relname from pg_class c where c.oid = p_parent;\n"
             "  raise notice '%', v_rel;"),
       "LIVENESS: a name alone under UNION ALL is clean")

# --- PR #1323's review: what the rule must NOT refuse (each beside its twin that it must) -------------------------
# INTERSECT binds tighter than UNION ALL, so in `a UNION ALL b INTERSECT c` only b and c are compared
report(refused("  select v_nsp into v_rel union all select c.relname from pg_class c\n"
               "  intersect select v_nsp;", "c.relname stands in the select list of a query under INTERSECT"),
       "LIVENESS: the name in b of a UNION ALL b INTERSECT c is refused")
report(clean("  select c.relname into v_rel from pg_class c where c.oid = p_parent\n"
             "  union all select v_nsp intersect select v_nsp;\n"
             "  raise notice '%', v_rel;"),
       "the name in a of a UNION ALL b INTERSECT c is clean", "precedence")
# an object's type or schema read off pg_identify_object() is no name; its name and identity are
report(refused(by("(pg_identify_object('pg_class'::regclass, c.oid, 0)).name = v_rel"), SAID),
       "LIVENESS: a lookup by (pg_identify_object(...)).name is refused")
report(clean(by("(pg_identify_object('pg_class'::regclass, c.oid, 0)).type = 'table' and c.oid = p_parent")),
       "(pg_identify_object(...)).type = 'table' is clean", "fields")
sys.exit(fail)
PY
