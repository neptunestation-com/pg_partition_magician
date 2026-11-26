#!/usr/bin/env bash
# Prove that each column table docs/reference.md gives a pgpm catalog table names every column the installed module
# gives that table, measured from the catalog of a fresh install rather than from a list kept by hand.
#
# WHY THIS GUARD EXISTS (issue #1246). The reference's pgpm.transmute_inflight table listed parent_table to
# started_at, and not owner_pid or owner_backend_start: the claiming session that transmute_abort's "still running in
# another session" refusal is judged by, and the one record of which session to wait for or end.
# pgpm.config.regrain_written_xid and pgpm.scratch.written_xid (#1241) were missing the same way. A column an upgrade
# adds with ALTER TABLE ... ADD COLUMN reaches no document unless someone remembers, and nothing noticed.
#
# HOW. install.sql into a fresh <db>, then information_schema.columns for every base table of schema pgpm. For each
# table whose "### `pgpm.<table>`" section in the reference holds a "| Column | Type | Meaning |" table, every column
# must have a row of its own ("| `col` |", or a shared one such as "| `lo` / `hi` |"). A table without such a section
# (pgpm.log documents its actions instead) is not judged.
#   LIVENESS  the install ran and the catalog read returned columns; at least seven tables have a column table and
#             pgpm.transmute_inflight is one of them, so "every column has a row" is not a check of an empty set.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   reference_inflight_owner_unnamed -- the reference's pre-#1246 transmute_inflight table, without the owner row
#
# Usage: doc_catalog_columns.sh <container> <db> [reference]
# With no third argument it reads docs/reference.md; with one it reads THAT file, which is how bench/discriminate.sh
# points it at a mutant (a /repo/... path is mapped to this checkout). PGPM_INSTALL overrides the install.sql path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${3:-$ROOT/docs/reference.md}"
REF="${REF/#\/repo\//$ROOT/}"
INSTALL="${PGPM_INSTALL:-/repo/pgpm_core/install.sql}"
if [ ! -f "$REF" ]; then printf 'FAIL  %-66s %s\n' "fixture: the reference to read exists" "$REF"; exit 1; fi

q() { docker exec "$C" psql -U postgres "$@"; }
COLS="$(mktemp)"
trap 'rm -f "$COLS"; q -q -c "drop database if exists $DB" >/dev/null 2>&1' EXIT
q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-66s %s\n' "LIVENESS: the module installed" "$INSTALL"; exit 1
fi
q -d "$DB" -qtAX -F ' ' -c "select c.table_name, c.column_name
                              from information_schema.columns c join information_schema.tables t using (table_schema, table_name)
                             where c.table_schema = 'pgpm' and t.table_type = 'BASE TABLE'
                             order by c.table_name, c.ordinal_position" > "$COLS"

python3 - "$COLS" "$REF" <<'PY'
import re, sys
cols = [l.split() for l in open(sys.argv[1]) if l.strip()]
ref = open(sys.argv[2]).read().split("\n")

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<66} {detail}")

def premise(ok, what, detail):
    say(ok, what, detail)
    if not ok:
        sys.exit(1)

sections, cur = {}, None
for line in ref:
    m = re.match(r"^### `pgpm\.(\w+)`\s*$", line)
    if m:
        cur = m.group(1)
        sections[cur] = []
        continue
    if line.startswith("#"):
        cur = None
        continue
    if cur and line.startswith("|"):
        sections[cur].append(line)
judged = {t: rows for t, rows in sections.items() if any(r.startswith("| Column | Type | Meaning |") for r in rows)}
installed = sorted({t for t, _ in cols})
premise(bool(cols), "LIVENESS: the installed catalog's pgpm columns were read", f"{len(cols)} columns in {len(installed)} tables")
premise(len(judged) >= 7 and "transmute_inflight" in judged,
        "LIVENESS: the reference has column tables, transmute_inflight's among them", ", ".join(sorted(judged)))

fail = 0
for t in sorted(judged):
    want = [c for tt, c in cols if tt == t]
    if not want:
        continue
    missing = [c for c in want
               if not any(re.match(r"^\| (`[a-z_0-9]+` / )*`" + re.escape(c) + r"`( / `[a-z_0-9]+`)* \|", r) for r in judged[t])]
    say(not missing, f"pgpm.{t}: every installed column has a row",
        f"all {len(want)}" if not missing else "NOT documented: " + ", ".join(missing))
    fail |= bool(missing)
sys.exit(1 if fail else 0)
PY
