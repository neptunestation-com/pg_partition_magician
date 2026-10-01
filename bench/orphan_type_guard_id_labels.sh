#!/usr/bin/env bash
# Run tests/215_orphan_type_guard_id_labels_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same
# "the assertions were reached at all" count, so read that file's header for why a wrapper around a
# plain pgTAP file exists at all.
#
# What THIS file guards (issue #794): transmute's orphan-child guard refuses a TYPE named like any fine
# child pgpm could give the parent (#707), recognising the label through pgpm._is_fine_child_label as
# its pg_class half does (#726). The pg_type half kept '^[0-9]{19}$', the label before #582, so a type
# under a 20-digit, fractional or short negative cell's name passed, the conversion completed, and
# obtain left that cell unbuilt. tests/215 pins each refusal's message, pairs them with a 19-digit
# control the old check already refused (so the check exists and fires) and with a conversion that,
# once the 20-digit type is gone, builds that very cell, and pins the false-positive side (types shaped
# like digits but not like a label leave the conversion alone). This wrapper proves it would notice.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   orphan_type_guard_id_label_19_digits  -- the pg_type query matches the 19-digit pattern again
#                                            instead of asking the helper
#
# Usage: orphan_type_guard_id_labels.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${ORPHAN_TYPE_GUARD_ID_LABELS_TEST_FILE:-/repo/tests/215_orphan_type_guard_id_labels_test.sql}" \
GRID_TZ_LABEL="transmute's type orphan check knows every id label" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
