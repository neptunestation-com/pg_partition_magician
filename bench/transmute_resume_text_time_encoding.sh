#!/usr/bin/env bash
# Run tests/337_transmute_resume_text_time_encoding_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant. The harness is
# bench/grid_timezone.sh's, selected by its GRID_TZ_TEST_FILE override (see that file's header for why a
# wrapper around a plain pgTAP file exists at all, and bench/transmute_resume_control_column.sh for this
# one's closest sibling).
#
# What THIS file guards (issue #1270): a text_time transmute resumed after a failed cutover refuses an
# encoding (p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch)
# other than the one the recorded bound's CHECK was written in, instead of reusing that validated CHECK and
# attaching with the bound encoded the new way, which scans the whole table under ACCESS EXCLUSIVE and
# dies on the rows outside it. tests/337's witnesses pin that the first attempts really failed in the
# cutover and left validated CHECKs, that some row really lies outside the bound encoded the re-run's way
# (so nothing but the refusal stops it), and that the same encoding spelled otherwise really resumes; this
# wrapper proves those witnesses would notice the refusal removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_resume_any_encoding  -- the resume's encoding check removed, which is pre-#1270 behaviour
#                                     exactly: the re-runs with the epoch one day earlier are not refused,
#                                     die at their first COMMIT inside throws_like with 2D000, and
#                                     tests/337 pins the refusal's message
#
# Usage: transmute_resume_text_time_encoding.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/337_transmute_resume_text_time_encoding_test.sql}" \
GRID_TZ_LABEL="a resumed transmute refuses another text_time encoding" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
