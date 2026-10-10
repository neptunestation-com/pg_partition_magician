#!/usr/bin/env bash
# Prove scripts/check_archive_object_keys.py follows the configured prefix when it is read out of the config
# row by the column's NAME, not only where the column is spelled as an identifier.
#
# WHY THIS GUARD EXISTS (review pass 11, F8-06, issue #1181). The lint promises to follow the value of
# archive.config.prefix rather than a spelling of it (#914), and refuses a second object key built from
# `cfg.prefix`. It knew the prefix only as an identifier token or a subquery selecting one, so the same value
# read through the row as JSON, `(to_jsonb(cfg) ->> 'prefix') || p_child`, `row_to_json(cfg) ->> 'prefix'` or
# `jsonb_extract_path_text(to_jsonb(cfg), 'prefix')`, assembled a second, unclaimed key (the shape of #711 and
# #872 the lint exists to keep out) with zero violations. A field read is a whole expression, and the
# parentheses around it are part of it, so the fix reads the reference as the expression and not the token.
# The checker's --selftest carries these shapes too, but a selftest lives in the file it tests and goes
# wherever that file goes; these fixtures are the guard's own, so a mutant of the checker is judged by
# something it did not write.
#
# HOW. Every refusal sits beside a LIVENESS twin the checker always refused (the same second key built from
# `cfg.prefix`), so a checker that has stopped reading anything fails a premise rather than reading as a pass;
# and the clean module, plus the same reads handed only to the key function, must stay clean, so "refuses a
# read by name" cannot be satisfied by refusing everything.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_keys_field_read_unjudged  -- a read through `->>` / `#>>` is judged at the literal alone again
#
# Usage: archive_keys_row_read.sh <container> <db> [check_archive_object_keys.py]
# The container and database are accepted for the shape bench/discriminate.sh calls every guard with and are
# not used: the check is static and runs on the host. A third argument is a copy of the checker
# (discriminate.sh hands it a mutant, under a .sql name, at a /repo/ path that is mapped to this checkout).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_C="${1:?container}"; _DB="${2:?db}"; UNDER="${3:-$ROOT/scripts/check_archive_object_keys.py}"
UNDER="${UNDER/#\/repo\//$ROOT/}"
if [ ! -s "$UNDER" ]; then
  printf 'FAIL  %-66s %s\n' "GUARD: the checker under test is readable" "$UNDER"
  exit 1
fi

UNDER="$UNDER" python3 - <<'PY'
import importlib.machinery
import importlib.util
import os
import sys

UNDER = os.environ["UNDER"]
fail = 0


def report(ok, label, detail=""):
    global fail
    print(f"{'PASS' if ok else 'FAIL'}  {label:<66} {detail}")
    fail |= not ok


try:
    loader = importlib.machinery.SourceFileLoader("under_test", UNDER)
    spec = importlib.util.spec_from_loader("under_test", loader)
    aok = importlib.util.module_from_spec(spec)
    loader.exec_module(aok)
    assert hasattr(aok, "check_text") and hasattr(aok, "CLAIM_TABLE")
except Exception as e:  # a mutant that is not the checker verifies nothing
    report(False, "GUARD: the checker under test loads", f"{type(e).__name__}: {e}")
    sys.exit(1)
print(f"# check_archive_object_keys: {UNDER}")

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


def with_fn(fn, body):
    return KEY_FN + f"""
create or replace function {fn}(p_parent regclass, p_child name) returns text language plpgsql as $$
declare cfg archive.config; v_key text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  {body}
end;
$$;
"""


def second_key(fn, expr):
    return with_fn(fn, f"v_key := {expr} || quote_ident(p_child) || '.parquet';\n  return v_key;")


def judged(src, fn):
    v, owner = aok.check_text("fixture.sql", src)
    return any(f"{fn} (line" in x for x in v), v, owner


v, owner = aok.check_text("one_key.sql", KEY_FN)
report(not v and owner == "archive._owned_key", "LIVENESS: one key function is clean",
       f"owner {owner}" if not v else f"{v}")
hit, v, _ = judged(second_key("archive.k_column", "cfg.prefix"), "archive.k_column")
report(hit, "LIVENESS: a second key from cfg.prefix is refused", "names archive.k_column" if hit else f"{v}")

for fn, expr, what in [
        ("archive.k_to_jsonb", "(to_jsonb(cfg) ->> 'prefix')", "(to_jsonb(cfg) ->> 'prefix')"),
        ("archive.k_row_to_json", "(row_to_json(cfg) ->> 'prefix')", "(row_to_json(cfg) ->> 'prefix')"),
        ("archive.k_text_path", "(to_jsonb(cfg) #>> '{prefix}')", "(to_jsonb(cfg) #>> '{prefix}')"),
        ("archive.k_cast_first", "(row_to_json(cfg)::jsonb ->> 'prefix')::text",
         "(row_to_json(cfg)::jsonb ->> 'prefix')::text"),
        ("archive.k_extract_path", "jsonb_extract_path_text(to_jsonb(cfg), 'prefix')",
         "jsonb_extract_path_text(to_jsonb(cfg), 'prefix')")]:
    hit, v, _ = judged(second_key(fn, expr), fn)
    report(hit, f"a second key from {what} is refused", f"names {fn}" if hit else f"{v}")

# the value read by name and assigned before it is concatenated: the assignment is the assembly
hit, v, _ = judged(with_fn("archive.k_assigned", "v_key := to_jsonb(cfg) ->> 'prefix';\n  return v_key || p_child;"),
                   "archive.k_assigned")
report(hit, "the prefix read by name and assigned to a local is refused",
       "names archive.k_assigned" if hit else f"{v}")

# Following the read must not mean refusing it: handed only to the key function, tested, or named in a message
# it is not a key, and a JSON key is case-sensitive, so 'Prefix' is another field.
for fn, body, what in [
        ("archive.k_handed", "return archive._owned_key(p_parent, (to_jsonb(cfg) ->> 'prefix'), p_child);",
         "handed only to the key function"),
        ("archive.k_tested", "if (to_jsonb(cfg) ->> 'prefix') is null then\n"
         "    raise exception 'archive.config has no % for %', 'prefix', p_parent;\n  end if;\n"
         "  return archive._owned_key(p_parent, cfg.prefix, p_child);", "tested and named in a message"),
        ("archive.k_other_field", "v_key := (to_jsonb(cfg) ->> 'Prefix') || p_child;\n  return v_key;",
         "as 'Prefix', another field")]:
    hit, v, owner = judged(with_fn(fn, body), fn)
    report(not v and owner == "archive._owned_key", f"the prefix read by name, {what}, is clean",
           f"owner {owner}" if not v else f"{v}")

sys.exit(fail)
PY
