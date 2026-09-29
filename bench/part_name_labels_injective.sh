#!/usr/bin/env bash
# Run tests/150_part_name_labels_injective_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same
# "the assertions were reached at all" count, so read that file's header for why a wrapper around a
# plain pgTAP file exists at all.
#
# What THIS file guards (issue #582): every cell a grid can produce gets its own partition name. obtain,
# extend_to and regrain_step decide whether a cell's child already exists BY NAME, so a label shared by
# two cells is a hole in the forward grid or a regrain that fails on every attempt. Nearly every assertion
# in tests/150 is a negative ("no cell skipped", "different names") that a run which never set the
# collision up would satisfy just as well, so the file pins its setup with liveness witnesses (the two
# instants really share a minute, 10^19 really has 20 digits, 1.5 really floors onto 1, obtain and
# regrain really ran), and this wrapper is what proves those witnesses would notice the old labels.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   part_name_minute_floor        -- the finest time label is the minute again, so the two cells of a
#                                    30-second step share a name
#   part_name_id_label_truncated  -- an id label is lpad(floor(lo), 19) again, so 10^19 renders 10^18's
#                                    name and 1.5 renders 1's
#
# Usage: part_name_labels_injective.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${PART_NAME_LABELS_TEST_FILE:-/repo/tests/150_part_name_labels_injective_test.sql}" \
GRID_TZ_LABEL="every cell a grid can produce has its own name" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
