#!/usr/bin/env bash
# Prove scripts/check_archive_object_keys.py refuses a configured prefix that stands anywhere it is not
# declared, compared, stored, reported or handed whole to a function of the file, and follows a parameter by
# its number and through a call in a FROM clause.
#
# WHY THIS GUARD EXISTS (review pass 12, F8-02 and F12r-07, issue #1279). The lint promises that exactly one
# function assembles an object key from archive.config.prefix, and it named the ways the value gets out
# (`||`, an assignment, a RETURN, a select item, a call it cannot follow). Every pass of review found the next
# way: here the prefix bound to an EXECUTE as a USING argument (`execute 'select $1 || $2' using cfg.prefix,
# p_name`), renamed by a FROM item (`from unnest(array[cfg.prefix]) as u(p)`, `from (values (cfg.prefix)) as
# u(p)`: a call after FROM was read as a relation with a column list, a VALUES row as a value list), and handed
# by position to a helper whose nameless parameter is read as `$1` (`select $1 || $2`). Each built a second,
# unclaimed key (the shape of #711 and #872 the lint exists to keep out) with zero violations. The fix inverts
# the rule: what a prefix MAY do is listed, and anything else is assembly; a parameter is followed under its
# number as under its name; a function called in a FROM clause is a call; and a function whose body the
# checker does not read (one that is not dollar-quoted) is not one the prefix can be handed to.
# The checker's --selftest carries these shapes too, but a selftest lives in the file it tests and goes
# wherever that file goes; these fixtures are the guard's own, so a mutant of the checker is judged by
# something it did not write.
#
# HOW. Every refusal sits beside a LIVENESS twin the checker always refused (the same second key built as
# `cfg.prefix || ...`), so a checker that has stopped reading anything fails a premise rather than reading as a
# pass. And "refuses what it has no name for" cannot be satisfied by refusing everything: the clean module,
# and the prefix doing each thing it may do (handed whole by position, by name, by number and in a FROM
# clause; compared; stored by an upsert; reported by RAISE; named by a statement outside any body that only
# defines), must stay clean, with archive._owned_key the one owner. Each refusal names the function the key
# is assembled in, or the top level.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one clause of the fix each:
#   archive_keys_unlisted_standing_passes  -- the inverse rule is gone: a prefix none of the named rules judged
#                                             passes, so the USING argument and the VALUES row pass again
#   archive_keys_param_number_unfollowed   -- a parameter is followed by its name alone, so `$1 || $2` in a
#                                             helper handed the prefix by position passes again
#   archive_keys_from_call_is_relation     -- a name before `(` after FROM or JOIN is a relation again, so a
#                                             helper of the file called there is not followed into its
#                                             parameter (the caller is refused, the helper that assembles is
#                                             never named, and one that only hands the prefix on is refused)
#   archive_keys_unread_body_followed      -- a function whose body is not dollar-quoted counts as one the
#                                             checker follows, so a helper written `as 'select $1 || $2'`
#                                             is handed the prefix and assembles a key out of its sight
#   archive_keys_type_word_alias_skipped   -- a select item aliased `text`, `name`, `varchar` or `character`
#                                             is skipped as a declaration again (PR #1314's V-01)
#   archive_keys_mode_after_name_unread    -- a mode written after the name (`k out text`) is not read, so
#                                             every later parameter shifts one position (V-02)
#   archive_keys_into_first_list_unread    -- an INTO-first SELECT's items are not a select list, so
#                                             `select into v prefix text` is skipped as a declaration
#   archive_keys_loop_keeps_clause         -- a LOOP does not end the clause before it, so a nested block's
#                                             `declare prefix text;` after `for i in select 1 loop` is refused
#   archive_keys_domain_declaration_refused -- a local or column declared with a type that is no TYPE_WORD
#                                             (a domain, `constant text`) is refused as assembly
#   archive_keys_case_branch_declared      -- a DECLARE's local may start after THEN or ELSE again, so the
#                                             prefix in a CASE branch of a local's default is never judged
#
# Usage: archive_keys_inverse_rule.sh <container> <db> [check_archive_object_keys.py]
# The container and database are accepted for the shape bench/discriminate.sh calls every guard with and are
# not used: the check is static and runs on the host. A third argument is a copy of the checker
# (discriminate.sh hands it a mutant, under a .sql name, at a /repo/ path that is mapped to this checkout).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_C="${1:?container}"; _DB="${2:?db}"; UNDER="${3:-$ROOT/scripts/check_archive_object_keys.py}"
UNDER="${UNDER/#\/repo\//$ROOT/}"
if [ ! -s "$UNDER" ]; then
  printf 'FAIL  %-98s %s\n' "GUARD: the checker under test is readable" "$UNDER"
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
    print(f"{'PASS' if ok else 'FAIL'}  {label:<98} {detail}")
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
"""
HANDED = "return archive._owned_key(p_parent, cfg.prefix, p_child);"


def with_fn(fn, body, decl="cfg archive.config; v_key text; v_arr text[];", before=""):
    return KEY_FN + before + f"""
create or replace function {fn}(p_parent regclass, p_child name) returns text language plpgsql as $$
declare {decl}
begin
  select * into cfg from archive.config where parent_table = p_parent;
  {body}
end;
$$;
"""


def refused(what, src, fn, why=""):
    """The checker refuses src and one violation names fn as a place a key is assembled, for the reason `why`."""
    v, _ = aok.check_text("fixture.sql", src)
    hit = any(f"{fn} (line" in x and why in x for x in v)
    report(hit, what, f"names {fn}" if hit else f"{[x.strip()[:150] for x in v]}")


def clean(what, src):
    v, owner = aok.check_text("fixture.sql", src)
    report(not v and owner == "archive._owned_key", what,
           f"owner {owner}" if not v else f"{[x.strip()[:150] for x in v[1:]]}")


clean("LIVENESS: one key function is clean", KEY_FN)
refused("LIVENESS: a second key from cfg.prefix || ... is refused",
        with_fn("archive.k_concat", "return cfg.prefix || quote_ident(p_child);"), "archive.k_concat", "||")

# --- the prefix bound to dynamic SQL as a USING argument (F8-02) -----------------------------------------------
for fn, body, what in [
        ("archive.k_using", "execute 'select $1 || ''/'' || $2' into v_key using cfg.prefix, p_child;\n  return v_key;",
         "the first USING argument of EXECUTE ... INTO"),
        ("archive.k_using_last", "execute 'select $2 || $1' into v_key using p_child, cfg.prefix;\n  return v_key;",
         "the last USING argument"),
        ("archive.k_using_cast", "execute 'select $1 || $2' using cfg.prefix::text, p_child into v_key;\n  return v_key;",
         "a USING argument under a cast, before INTO"),
        ("archive.k_using_query", "return query execute 'select $1 || $2' using cfg.prefix, p_child;",
         "a USING argument of RETURN QUERY EXECUTE"),
        ("archive.k_using_loop",
         "for v_key in execute 'select $1' using cfg.prefix loop\n    return v_key || p_child;\n  end loop;",
         "the USING argument of FOR ... IN EXECUTE")]:
    refused(f"a second key from the prefix as {what} is refused", with_fn(fn, body), fn, "standing between")

# --- the prefix renamed by a FROM item (F12r-07) -----------------------------------------------------------------
for fn, body, what, why in [
        ("archive.k_unnest", "return (select u.p || p_child from unnest(array[cfg.prefix]) as u(p));",
         "unnest(array[cfg.prefix]) as u(p)", "passed to unnest()"),
        ("archive.k_join_unnest",
         "return (select u.p || p_child from pg_class c join lateral unnest(array[cfg.prefix]) as u(p) on true limit 1);",
         "join lateral unnest(array[cfg.prefix]) as u(p)", "passed to unnest()"),
        ("archive.k_values", "return (select u.p || p_child from (values (cfg.prefix)) as u(p));",
         "(values (cfg.prefix)) as u(p)", "standing between"),
        ("archive.k_values_row", "return (select u.p || p_child from (values (cfg.prefix, 1)) as u(p, n));",
         "(values (cfg.prefix, 1)) as u(p, n)", "standing between"),
        ("archive.k_derived",
         "return (select c.p || p_child from (select prefix as p from archive.config where parent_table = p_parent) c);",
         "a derived table selecting prefix as p", "standing between"),
        ("archive.k_cte",
         "with c as (select prefix as p from archive.config where parent_table = p_parent)\n"
         "  select c.p || p_child into v_key from c;\n  return v_key;",
         "a WITH query selecting prefix as p", "standing between")]:
    refused(f"a second key from the prefix renamed by {what} is refused", with_fn(fn, body), fn, why)

# --- the prefix handed to a helper of the file and read there by number (F12r-07) --------------------------------
for helper, header, lang, hbody, call, what in [
        ("archive.k_join", "(text, name) returns text", "sql", "select $1 || $2",
         "archive.k_join(cfg.prefix, p_child)", "a nameless parameter read as $1"),
        ("archive.k_join_named", "(p_child name, p_base text) returns text", "sql", "select $2 || quote_ident($1)",
         "archive.k_join_named(p_base => cfg.prefix, p_child => p_child)", "a named parameter read as $2"),
        ("archive.k_join_out", "(out o_key text, text, name)", "plpgsql", "begin o_key := $2 || $3; end",
         "archive.k_join_out(cfg.prefix, p_child)", "a plpgsql parameter numbered past an OUT one"),
        ("archive.k_join_out_after", "(k out text, p_a text, p_b name)", "plpgsql", "begin k := p_a || p_b; end",
         "archive.k_join_out_after(cfg.prefix, p_child)", "a parameter placed after an OUT one written `k out text`"),
        ("archive.k_join_alias", "(text, name) returns text", "plpgsql",
         "declare v_base alias for $1; begin return v_base || $2; end",
         "archive.k_join_alias(cfg.prefix, p_child)", "a parameter renamed by ALIAS FOR $1"),
        ("archive.k_join_qualified", "(p_base text, p_child name) returns text", "sql",
         "select k_join_qualified.p_base || p_child",
         "archive.k_join_qualified(cfg.prefix, p_child)", "a parameter named behind the function's name")]:
    src = with_fn("archive.k_caller", f"return {call};",
                  before=f"create or replace function {helper}{header} language {lang} as $f$\n  {hbody}\n$f$;\n")
    refused(f"a second key in a helper from {what} is refused", src, helper)

# --- a function of the file called in a FROM clause is a call, followed into its parameter ------------------------
refused("a second key in a helper called in a FROM clause is refused at the helper",
        with_fn("archive.k_from_caller", "return (select r from archive.k_rows(cfg.prefix, p_child) r);",
                before="create or replace function archive.k_rows(p_base text, p_child name) returns setof text "
                       "language sql as $f$\n  select p_base || quote_ident(p_child)\n$f$;\n"),
        "archive.k_rows", "p_base concatenated with ||")

# --- a helper whose body the checker does not read cannot be followed into: handing it the prefix is the way out ---
for helper, rest, what in [
        ("archive.k_quoted", "(text, name) returns text language sql as 'select $1 || $2';", "a single-quoted body"),
        ("archive.k_standard", "(p_base text, p_child name) returns text language sql return p_base || p_child;",
         "a SQL-standard body")]:
    refused(f"the prefix handed to a helper with {what} is refused at the caller",
            with_fn("archive.k_unread_caller", f"return {helper}(cfg.prefix, p_child);",
                    before=f"create or replace function {helper}{rest}\n"),
            "archive.k_unread_caller", "whose body is not dollar-quoted")

# --- the other ways out that no rule named ------------------------------------------------------------------------
for fn, body, decl, what in [
        ("archive.k_array", "v_arr := array[cfg.prefix];\n  return v_arr[1] || p_child;", None, "an array constructor"),
        ("archive.k_case", "v_key := case when p_child is not null then cfg.prefix end;\n  return v_key || p_child;",
         None, "the result of a CASE"),
        ("archive.k_returning",
         "with u as (update archive.config set parent_table = parent_table where parent_table = p_parent\n"
         "             returning prefix as p)\n  select u.p || p_child into v_key from u;\n  return v_key;",
         None, "a RETURNING item"),
        ("archive.k_alias_text",
         "return (select c.prefix text from archive.config c where c.parent_table = p_parent) || p_child;", None,
         "a select item aliased with a type word, `select c.prefix text` (an alias, not a declaration)"),
        ("archive.k_into_first",
         "select into v_key prefix text from archive.config where parent_table = p_parent;\n  return v_key || p_child;",
         None, "an INTO-first SELECT's item aliased `text`"),
        ("archive.k_case_then_default", "return v_key;",
         "cfg archive.config; v_key text := case when true then cfg.prefix end || p_child;",
         "a CASE ... THEN branch of a DECLARE default"),
        ("archive.k_case_else_default", "return v_key;",
         "cfg archive.config; v_key text := case when false then '' else cfg.prefix end || p_child;",
         "a CASE ... ELSE branch of a DECLARE default"),
        ("archive.k_select_all",
         "for v_key in select all prefix from archive.config where parent_table = p_parent loop\n"
         "    return v_key || p_child;\n  end loop;", None, "a SELECT ALL item (ALL tests nothing there)"),
        ("archive.k_declared", "return v_key || p_child;", "cfg archive.config; v_arr text[]; v_key text = cfg.prefix;",
         "the initial value of a DECLARE's local, v_key text = cfg.prefix"),
        ("archive.k_element", "v_arr[1] = cfg.prefix;\n  return v_arr[1] || p_child;", None,
         "an array element assigned with =")]:
    src = with_fn(fn, body, decl=decl) if decl else with_fn(fn, body)
    refused(f"a second key from the prefix as {what} is refused", src, fn)

# --- what a prefix may do: each must stay clean, or "refuses the rest" is satisfied by refusing everything ----------
clean("the prefix handed whole by name, and as a subquery, is clean",
      with_fn("archive.k_ok_named",
              "if p_child is null then\n    return archive._owned_key(p_child => p_child, p_prefix => cfg.prefix, "
              "p_parent => p_parent);\n  end if;\n"
              "  return archive._owned_key(p_parent, (select prefix from archive.config where parent_table = p_parent), "
              "p_child);"))
clean("the prefix compared, tested and reported by RAISE is clean",
      with_fn("archive.k_ok_compared",
              "if cfg.prefix is null or cfg.prefix = '' or cfg.prefix not like '%/' or 'events/' <> cfg.prefix\n"
              "     or cfg.prefix in ('a/', 'b/') or cfg.prefix between 'a' and 'b' or p_child ~* cfg.prefix\n"
              "     or exists (select prefix from archive.config where parent_table <> p_parent)\n"
              "     or p_child::text = any (select prefix from archive.config) then\n"
              "    raise exception 'archive.config has the prefix % for %', cfg.prefix, p_parent using hint = cfg.prefix;\n"
              "  end if;\n"
              "  perform 1 from archive.config c where c.prefix = cfg.prefix and c.parent_table <> p_parent;\n  "
              + HANDED,
              decl="cfg archive.config; v_same boolean = 'events/' = cfg.prefix; "
                   "c_same cursor for select 1 from archive.config where prefix = 'events/';"))
clean("the prefix stored by an INSERT and an upsert's SET is clean",
      with_fn("archive.k_ok_stored",
              "insert into archive.config (parent_table, prefix) values (p_parent, cfg.prefix), (p_parent, cfg.prefix)\n"
              "  on conflict (parent_table) do update set prefix = excluded.prefix;\n"
              "  insert into archive.config (prefix) values (cfg.prefix);\n"
              "  update archive.config set prefix = cfg.prefix where prefix <> cfg.prefix;\n  " + HANDED))
clean("a helper called in a FROM clause that only hands the prefix on is clean",
      with_fn("archive.k_ok_from", "return (select r from archive.k_rows(cfg.prefix, p_parent, p_child) r);",
              before="create or replace function archive.k_rows(p_base text, p_parent regclass, p_child name) "
                     "returns setof text language sql as $f$\n  select archive._owned_key(p_parent, p_base, p_child)\n$f$;\n"))
clean("a nested block's declare prefix text; after a FROM-less loop query is a declaration",
      with_fn("archive.k_ok_loop_declare",
              "for v_key in select generate_series(1, 2)::text loop\n    declare prefix text;\n    begin\n"
              "      prefix := 'x';\n      raise notice '% %', v_key, prefix;\n    end;\n  end loop;\n  " + HANDED))
clean("a local and a column declared with a domain or CONSTANT type are declarations",
      with_fn("archive.k_ok_domain", "raise notice '% %', prefix, p_prefix;\n  " + HANDED,
              decl="cfg archive.config; prefix archive.prefix_domain; p_prefix constant text := 'events/';",
              before="create table archive.config_was (parent_table regclass, prefix archive.prefix_domain);\n"))
clean("a parameter handed on whole by its number is clean",
      with_fn("archive.k_ok_number", "return archive.k_pass(p_parent, cfg.prefix, p_child);",
              before="create or replace function archive.k_pass(regclass, text, name) returns text language sql as $f$\n"
                     "  select archive._owned_key($1, $2, $3)\n$f$;\n"))
# `$1` in the text an EXECUTE runs is its first USING argument, here the parent, and not the first parameter of
# the function around it, here the prefix
clean("a $1 that is an EXECUTE's USING argument is not the function's first parameter",
      with_fn("archive.k_ok_bind", "return archive.k_dyn(cfg.prefix, p_parent, p_child);",
              before="create or replace function archive.k_dyn(p_prefix text, p_parent regclass, p_child name) "
                     "returns text language plpgsql as $f$\ndeclare v text;\nbegin\n"
                     "  execute 'select $1::text || $2' into v using p_parent, p_child;\n"
                     "  return archive._owned_key(p_parent, p_prefix, p_child);\nend $f$;\n"))
clean("the column named by a statement outside any body that only defines is clean",
      with_fn("archive.k_ok_ddl", HANDED,
              before="alter table archive.config alter column prefix set default 'events/';\n"
                     "comment on column archive.config.prefix is 'what every object key of the parent starts with';\n"
                     "create table if not exists archive.config_was (parent_table regclass, prefix text,\n"
                     "  primary key (parent_table, prefix));\n"))
# ... and everything else outside a body is judged as a body is
refused("a second key at top level from the prefix renamed by a derived table is refused",
        KEY_FN + "select set_config('archive.marker', c.p || 'marker', false)\n"
                 "  from (select prefix as p from archive.config) c;\n",
        "top level", "standing between")

sys.exit(fail)
PY
