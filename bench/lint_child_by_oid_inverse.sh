#!/usr/bin/env bash
# Prove scripts/check_archive_child_by_oid.py's rule 1 is the INVERSE rule: outside archive._resolve_child a
# relation's name (a name column, or a regclass rendered as text) may stand only alone, as an item of a
# statement's own select list or of a RAISE, or as a bare argument of quote_ident(), format() or
# json_build_object() there; anywhere else is refused, whatever spelling it is in.
#
# WHY THIS GUARD EXISTS (review pass 11: #1154 and #1180). The first rule 1 enumerated the places a name column
# may NOT stand (beside a comparison operator, in a WHERE/ON/HAVING/USING clause, projected out of a subquery,
# under an alias) and gained a spelling per round:
#   * #1154: archive._owned_key finding its relation by `order by case c.relname when k.relname then 0 else 1
#     end limit 1` passed: a simple CASE has no operator token and ORDER BY was not a clause it inspected;
#   * #1180: `where c.oid::regclass::text = v_rel` passed: no name column appears at all, the relation is
#     found by its rendered name.
# Both, installed, reproduce #1064 (tests/archive/db/49 catches the module), so the lint passed for the wrong
# reason. The checker's --selftest carries these shapes too, but a selftest lives in the file it tests; these
# fixtures are the guard's own, and they are built from the REAL module of this checkout (its archive._owned_key
# statement respelled, a function planted beside it), so a mutant of the checker is judged by code it did not
# write.
#
# HOW. Every refusal sits beside a LIVENESS twin the first rule 1 always refused (`c.relname = k.relname` in an
# ON clause, `c.relname = v_rel` in a WHERE), so a checker that has stopped reading fails a premise rather than
# reading as a pass, and the module itself and the shapes rule 1 allows (a name read off a row found by oid,
# projected alone or reported) must stay clean, so a checker that refuses everything fails too.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   archive_child_by_oid_clause_list     -- rule 1 refuses only the places it lists again (#1154)
#   archive_child_by_oid_rendered_exempt -- a regclass rendered as text is exempt everywhere, not only in the
#                                           one function that compares rendered names to refuse (#1180)
#
# Usage: lint_child_by_oid_inverse.sh <container> <db> [checker.py]
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


def refused_in(src, stmt):
    """Whether a violation names a line of stmt, the statement planted in src: the refusal is of the planted
    lookup, not of something else the respelling disturbed (identity, not a count)."""
    at = src.index(stmt)
    first = src.count("\n", 0, at) + 1
    lines = range(first, first + stmt.count("\n") + 1)
    return any(f"(line {n})" in x for x in verdict(src) for n in lines)


# --- archive._owned_key's own lookup, respelled in the real module ------------------------------------------------
OLD = ("  select c.oid, n.nspname, c.relname into v_relation, v_nsp, v_name\n"
       "    from pg_class c join pg_namespace n on n.oid = c.relnamespace\n"
       "   where c.oid = coalesce(p_child, p_parent);\n")
if MODULE.count(OLD) != 1:
    report(False, "GUARD: archive._owned_key takes its relation by oid in this checkout", "anchor not found once")
    sys.exit(1)


def owned_key(stmt):
    return MODULE.replace(OLD, stmt), stmt


ON_EQ = owned_key("  select c.oid, n.nspname, c.relname into v_relation, v_nsp, v_name\n"
                  "    from pg_class p join pg_namespace n on n.oid = p.relnamespace\n"
                  "    join pg_class c on c.relnamespace = p.relnamespace\n"
                  "    join pg_class k on k.oid = coalesce(p_child, p_parent) and c.relname = k.relname\n"
                  "   where p.oid = p_parent;\n")
# #1154, the per-PR verification's real instance (P1-02 of #1150's round 2)
ORDER_CASE = owned_key("  select c.oid, n.nspname, c.relname into v_relation, v_nsp, v_name\n"
                       "    from pg_class p join pg_namespace n on n.oid = p.relnamespace\n"
                       "    join pg_class c on c.relnamespace = p.relnamespace\n"
                       "    join pg_class k on k.oid = coalesce(p_child, p_parent)\n"
                       "   where p.oid = p_parent\n"
                       "   order by case c.relname when k.relname then 0 else 1 end limit 1;\n")
# #1154, the claims verifier's instance (V-01): the name compared is parsed out of the rendered child
ORDER_CASE_PARSED = owned_key(
    "  select r.oid into v_owner from pg_class r join pg_class pp on pp.relnamespace = r.relnamespace\n"
    "   where pp.oid = p_parent\n"
    "   order by case r.relname when (parse_ident(coalesce(p_child, p_parent)::text))"
    "[array_length(parse_ident(coalesce(p_child, p_parent)::text), 1)] then 0 else 1 end\n"
    "   limit 1;\n"
    + OLD.replace("where c.oid = coalesce(p_child, p_parent);", "where c.oid = v_owner;"))
# the same lookup through a positional ORDER BY of a select item that compares the name
ORDER_POSITIONAL = owned_key("  select c.oid, n.nspname, c.relname, case c.relname when k.relname then 0 else 1 end\n"
                             "    into v_relation, v_nsp, v_name, v_owner\n"
                             "    from pg_class p join pg_namespace n on n.oid = p.relnamespace\n"
                             "    join pg_class c on c.relnamespace = p.relnamespace\n"
                             "    join pg_class k on k.oid = coalesce(p_child, p_parent)\n"
                             "   where p.oid = p_parent\n"
                             "   order by 4 limit 1;\n")
# ... and through a function of the name in the ORDER BY, no CASE and no operator beside it
ORDER_FUNCTION = owned_key("  select c.oid, n.nspname, c.relname into v_relation, v_nsp, v_name\n"
                           "    from pg_class p join pg_namespace n on n.oid = p.relnamespace\n"
                           "    join pg_class c on c.relnamespace = p.relnamespace\n"
                           "    join pg_class k on k.oid = coalesce(p_child, p_parent)\n"
                           "   where p.oid = p_parent\n"
                           "   order by strpos(c.relname, k.relname) desc limit 1;\n")

report(not verdict(MODULE), "LIVENESS: the checkout's module passes the checker", "pgpm_archive/install.sql")
report(refused_in(*ON_EQ), "LIVENESS: _owned_key by c.relname = k.relname in an ON is refused")
report(refused_in(*ORDER_CASE), "_owned_key by ORDER BY case relname when ... is refused", "#1154 P1-02")
report(refused_in(*ORDER_CASE_PARSED), "_owned_key by ORDER BY case relname when parse_ident(..)", "#1154 V-01")
report(refused_in(*ORDER_POSITIONAL), "_owned_key by ORDER BY 4, a select item comparing relname", "#1154")
report(refused_in(*ORDER_FUNCTION), "_owned_key by ORDER BY strpos(c.relname, k.relname)", "#1154")


# --- a relation found by its rendered name, in a function planted in the real module ------------------------------
def planted(body):
    return MODULE + f"""
create or replace function archive._planted(p_parent regclass) returns void language plpgsql as $$
declare v_rel name; v_oid oid; v_name text;
begin
{body}
end;
$$;
"""


def by(pred):
    stmt = f"  select c.oid into v_oid from pg_class c where {pred};\n"
    return planted(stmt + "  if v_oid is null then raise exception 'no %', v_rel; end if;"), stmt


report(refused_in(*by("c.relname = v_rel")), "LIVENESS: a lookup by c.relname = v_rel is refused")
for label, pred in (("c.oid::regclass::text = v_rel", "c.oid::regclass::text = v_rel"),
                    ("(c.oid::regclass)::text = v_rel", "(c.oid::regclass)::text = v_rel"),
                    ("cast(c.oid::regclass as text) = v_rel", "cast(c.oid::regclass as text) = v_rel"),
                    ("lower(c.oid::regclass::text) = lower(v_rel)", "lower(c.oid::regclass::text) = lower(v_rel)"),
                    ("format('%s', c.oid::regclass) = v_rel", "format('%s', c.oid::regclass) = v_rel"),
                    ("c.oid::regclass || '' = v_rel", "c.oid::regclass || '' = v_rel"),
                    ("regclassout(c.oid) = v_rel", "regclassout(c.oid) = v_rel")):
    report(refused_in(*by(pred)), f"a lookup by {label} is refused", "#1180")
ORDER_RENDERED = ("  select c.oid into v_oid from pg_class c\n"
                  "   order by case c.oid::regclass::text when v_rel then 0 else 1 end limit 1;")
report(refused_in(planted(ORDER_RENDERED), ORDER_RENDERED),
       "a lookup by ORDER BY case c.oid::regclass::text when ...", "#1180")

# --- what rule 1 allows stays clean ---------------------------------------------------------------------------------
report(not verdict(planted("  select c.oid::regclass::text, c.relname into v_name, v_rel from pg_class c\n"
                           "   where c.oid = p_parent;\n"
                           "  raise notice '% is %', v_name, quote_ident(v_rel);")),
       "LIVENESS: a name read off a row found by oid and reported is clean")
report(not verdict(planted("  select quote_ident(c.relname), format('%s', c.oid::regclass) into v_rel, v_name\n"
                           "    from pg_class c where c.oid = p_parent;\n"
                           "  raise notice '%', v_name;")),
       "LIVENESS: a name as a bare argument of quote_ident()/format() is clean")
sys.exit(fail)
PY
