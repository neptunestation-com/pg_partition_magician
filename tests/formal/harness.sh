#!/usr/bin/env bash
# Run the oracle's own pgTAP files (tests/formal/*_test.sql) against a running pgpm_test container, each in a fresh
# clone of a template holding pgtap, pgpm's core, the demo fixtures and tests/formal/oracle.sql: the template
# test.sh's run_version builds (pgpm_tmpl), plus the oracle.
#
#   tests/formal/harness.sh <container> [file ...]     default: every tests/formal/*_test.sql
#
# The container mounts this repository at /repo (docker run ... -v "$PWD":/repo pgpm_test:<ver>). Exit status is
# nonzero when any file fails. Wiring this into test.sh is W4's (docs/formal/phase3-design.md, "Wiring").
set -euo pipefail

c="${1:?usage: harness.sh <container> [tests/formal/file_test.sql ...]}"
shift
cd "$(dirname "$0")/../.."

# shellcheck source=tests/formal/lib.sh
source tests/formal/lib.sh

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  for f in tests/formal/*_test.sql; do files+=("$f"); done
fi

build_template pgpm_fx_tmpl
rc=0
for f in "${files[@]}"; do
  db="pgpm_fx_$(basename "$f" .sql | tr -c 'a-z0-9_\n' '_' | cut -c1-40)"
  q -c "drop database if exists $db" >/dev/null
  q -c "create database $db template pgpm_fx_tmpl" >/dev/null
  echo "### $f"
  docker exec "$c" pg_prove --timer -U postgres -d "$db" "/repo/$f" || rc=1
  q -c "drop database if exists $db" >/dev/null
done
q -c "drop database if exists pgpm_fx_tmpl" >/dev/null
exit "$rc"
