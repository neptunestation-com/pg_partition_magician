#!/usr/bin/env bash
# Run scripts/check_archive_object_keys.py against an ARBITRARY copy of pgpm_archive/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. The checker already runs in the lint job, on the tree and on its own
# --selftest fixtures. What this adds is the standing proof, on the REAL module, that it follows the
# prefix rather than a spelling of it (issue #914). Its contract is the #872 lever's invariant: exactly
# one function assembles an object key from archive.config.prefix, and it claims the key. Before #914
# the checker knew the prefix only by the names `prefix` and `p_prefix` beside `||`, so a second,
# unclaimed key assembled as `(select prefix from archive.config ...) || ...`, or by a function of the
# file whose parameter carrying the prefix was named otherwise (`p_base || ...`), passed it while its
# docstring promised that a key assembled anywhere else fails CI. Pointing it at a mutant holding each
# shape, every CI run checks that it now refuses them.
#
# A CONTROL runs first, so a checker that has stopped reading the file cannot read as a clean module: the
# same file with a second assembly in the one shape every version of the checker has refused
# (`p_prefix || ...` in an appended function) must be refused, by name. A checker that passes that has
# not read to the end of this file, and its PASS on the file itself would mean nothing.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   archive_key_prefix_by_subquery      -- a second export key assembled from a scalar subquery
#                                          selecting archive.config.prefix
#   archive_key_prefix_by_renamed_param -- a second export key assembled in a function of the file that
#                                          receives cfg.prefix as p_base
#   archive_key_prefix_by_execute       -- a second export key built from a prefix read by dynamic SQL,
#                                          execute 'select prefix from archive.config ...' into v (#1001:
#                                          the checker lexed every literal as one opaque token, so the
#                                          prefix inside the literal EXECUTE runs was never read)
# (A key built with no prefix at all is out of this checker's reach by design; tests/archive/db/39 Part 0
# enumerates the module's S3 writes for that, guarded by bench/archive_key_owner_every_path.sh.)
#
# Usage: archive_object_keys_static.sh <container> <db> [archive install.sql]
# The container and database are accepted for the shape bench/discriminate.sh calls every guard with and
# are not used: the check is static, run on the host, and a /repo/ path (the container's view of the
# repository) is read from this checkout. discriminate.sh installs the mutant before calling this, so a
# mutant that is not real SQL is reported there.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_C="${1:?container}"; _DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
case "$ARCHIVE_INSTALL" in
  /repo/*) SRC="$ROOT/${ARCHIVE_INSTALL#/repo/}" ;;
  *) SRC="$ARCHIVE_INSTALL" ;;
esac
CHK="$ROOT/scripts/check_archive_object_keys.py"
fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

if [ ! -s "$SRC" ]; then
  printf 'FAIL  %-58s %s\n' "the archive module under test is readable" "$SRC"
  exit 1
fi

# --- control: the checker reads this file to its end and can refuse it -----------------------------
{ cat "$SRC"; cat <<'SQL'
create or replace function archive._control_second_key(p_parent regclass, p_prefix text, p_child name) returns text
language sql stable as $$
  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(p_child) || '.ndjson'
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
$$;
SQL
} > "$work/control.sql"
ctl=$(python3 "$CHK" "$work/control.sql" 2>&1)
if grep -q 'archive._control_second_key (line' <<<"$ctl"; then
  printf 'PASS  %-58s %s\n' "LIVENESS: the checker refuses an appended p_prefix || ..." "names archive._control_second_key"
else
  printf 'FAIL  %-58s %s\n' "LIVENESS: the checker refuses an appended p_prefix || ..." "$(head -1 <<<"$ctl")"
  fail=1
fi

# --- the module under test: one assembling function, and it claims ---------------------------------
out=$(python3 "$CHK" "$SRC" 2>&1); rc=$?
if [ "$rc" = 0 ]; then
  printf 'PASS  %-58s %s\n' "every object key is assembled in one function (#914)" "$(sed -n 's/.*assembled in \([^,]*\), which.*/\1/p' <<<"$out")"
else
  printf 'FAIL  %-58s %s\n' "every object key is assembled in one function (#914)" "the checker refused it:"
  sed 's/^/      /' <<<"$out" | head -20
  fail=1
fi
exit "$fail"
