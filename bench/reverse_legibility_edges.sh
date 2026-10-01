#!/usr/bin/env bash
# Run tests/190_reverse_and_legibility_edges_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by its
# GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same "the assertions
# were reached at all" count, so read that file's header for why a wrapper around a plain pgTAP file exists.
#
# What THIS file guards (issue #710): untransmute hands back the parent's owner and comments (not the
# monolith's conversion-time ones); a write block re-enabled behind an operator's back is logged
# (write_block_reenable); a cell obtain or extend_to leaves unbuilt is logged (fail_obtain_name); a BC year
# is labelled apart from the same year AD; a regrain step ANALYZEs its delta only when it was never
# analyzed, not on every step while it is empty; and _grid_floor adds a fractional-second step's offset
# exactly. Each section pairs its assertion with a witness that the stale or silent state was really there
# (the monolith's old owner and comments, the disabled trigger, the held name, to_char's shared label, the
# lock the probe does see on the first step, the inexact double product), so a run that never set the
# state up cannot pass.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   untransmute_owner_not_restored       -- the restored table keeps the monolith's owner
#   untransmute_comments_not_restored    -- the parent's comments are captured and never replayed
#   write_block_reenable_unlogged        -- the re-enable happens with no log row again
#   obtain_unbuilt_cell_unlogged         -- obtain and extend_to skip a held name silently again
#   part_name_bc_unmarked                -- a BC label carries no era again
#   regrain_delta_reanalyzed             -- `reltuples <= 0` again: every step re-ANALYZEs an empty delta
#   grid_floor_offset_double             -- the offset from the anchor goes through double precision again
#
# Usage: reverse_legibility_edges.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${REVERSE_LEGIBILITY_EDGES_TEST_FILE:-/repo/tests/190_reverse_and_legibility_edges_test.sql}" \
GRID_TZ_LABEL="the reverse carries owner and comments; edges are logged" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
