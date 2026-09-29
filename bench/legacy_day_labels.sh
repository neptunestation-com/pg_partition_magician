#!/usr/bin/env bash
# Run tests/138_legacy_day_labels_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same
# "the assertions were reached at all" count, so read that file's header for why a wrapper around a
# plain pgTAP file exists at all.
#
# What THIS file guards (issue #572): a day grid named before #503 keeps growing after the upgrade. Its
# children keep their wall-date labels, and east of UTC with a local-midnight anchor the first cell past
# the last of them renders the name that child already carries. obtain and extend_to must build that
# cell under its explicit-range name rather than take the taken name for "built". The file's "covered"
# and "accepted" assertions are negatives of a hole, so it pins its setup with liveness witnesses (the
# legacy label really is the next cell's plain name, the builder really reached past it), and this
# wrapper is what proves those witnesses would notice the fallback being removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   legacy_day_label_skipped_by_name  -- the collided cell is skipped as built again, which is the
#                                        one-day hole of #572
#
# Usage: legacy_day_labels.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/138_legacy_day_labels_test.sql}" \
GRID_TZ_LABEL="an upgraded day grid builds the cell its legacy labels collide with" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
