#!/usr/bin/env bash
# Build a minified single-file package for dbdev / Trusted Language Extension
# publishing (CREATE EXTENSION). database.dev stores a package version's SQL in a
# `varchar(250000)` column (supabase/dbdev, supabase/migrations/20220117142137_package_tables.sql;
# nothing in its documentation says so), so a package over 250,000 characters cannot be published.
# Full-line `--` comments, blank lines, and COMMENT ON statements are stripped to stay under it.
# Dollar-quoted bodies and inline quoted literals are preserved verbatim.
#
# The cap check is strict by default (exit 1), which is what publishing needs. With
# PGPM_DBDEV_CAP=warn it prints a WARNING and exits 0 instead: the test harness builds the package
# that way, because the dbdev channel's tests install the file through psql, where the size does
# not matter, and a tree over the cap must still be testable and mergeable; the Test Suite's
# "dbdev package size" job runs the strict check on its own, off the required path.
#
# Usage:   [PGPM_DBDEV_CAP=warn] scripts/build_dbdev_package.sh <src.sql> <out.sql>
# Example: scripts/build_dbdev_package.sh pgpm_core/install.sql dist/pg_partition_magician--0.1.0.sql
set -euo pipefail

SRC="${1:?usage: $0 <src.sql> <out.sql>}"
OUT="${2:?usage: $0 <src.sql> <out.sql>}"
[ -f "$SRC" ] || { echo "build_dbdev_package: missing $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Header written before the minifier runs (which strips `--` lines).
cat > "$OUT" <<'HDR'
-- pg_partition_magician -- dbdev/TLE package (minified single file).
HDR

# The minifier is scripts/minify_sql.py, not the awk that used to live here: every decision it makes
# (drop a blank line, drop a `--` line, drop a COMMENT ON, collapse whitespace) depends on whether
# the line sits inside a string literal, and the awk judged each one from the line's own leading
# characters with no way to know (issue #410). It carries its own `--selftest`.
python3 "$HERE/minify_sql.py" "$SRC" >> "$OUT"

SIZE=$(wc -c < "$OUT")
echo "Built $OUT (${SIZE} bytes)"
if [ "$SIZE" -gt 250000 ]; then
  if [ "${PGPM_DBDEV_CAP:-strict}" = warn ]; then
    echo "WARNING: $OUT is ${SIZE} chars, over database.dev's 250,000-char column; it installs through psql but cannot be published to dbdev until it is under the cap (see RELEASING.md)" >&2
  else
    echo "ERROR: $OUT is ${SIZE} chars, exceeds the 250,000-char dbdev limit (database.dev's varchar(250000) sql column)" >&2
    exit 1
  fi
fi
