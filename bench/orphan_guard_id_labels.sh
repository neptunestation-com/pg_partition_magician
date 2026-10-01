#!/usr/bin/env bash
# Run tests/196_orphan_guard_id_labels_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same
# "the assertions were reached at all" count, so read that file's header for why a wrapper around a
# plain pgTAP file exists at all.
#
# What THIS file guards (issue #726): transmute's orphan guard and restore_incoming_fks's in-flight gate
# recognise every name _id_label can give a fine child, through one helper both call
# (pgpm._is_fine_child_label). Both used to match '^[0-9]{19}$', the label before #582, so an orphan
# named for a cell at or past 10^19, a fractional cell or a short negative one passed: the conversion
# completed and left that cell unbuilt with nothing logged, and the gate re-added a suspended FK while a
# child was still out of the parent. Half the assertions in tests/196 are negatives (the gate returns 0,
# the FK is absent, the conversion did nothing), which a run that never set the orphan up satisfies just
# as well, so the file pins its setup with witnesses (each orphan is named BY _part_name, and none of
# those names is 19 digits) and liveness (the cell is built and written once the orphan is gone; the
# gate returns 1 and re-adds that FK once the orphans are gone). This wrapper proves they would notice.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   orphan_guard_id_label_19_digits  -- the helper's id branch is the 19-digit pattern again, which
#                                       reaches both sites
#   fk_gate_id_label_19_digits       -- the gate matches with its own 19-digit pattern again instead of
#                                       asking the helper: the drift the shared helper exists to prevent
#
# Usage: orphan_guard_id_labels.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${ORPHAN_GUARD_ID_LABELS_TEST_FILE:-/repo/tests/196_orphan_guard_id_labels_test.sql}" \
GRID_TZ_LABEL="orphan guard and FK gate know every id label" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
