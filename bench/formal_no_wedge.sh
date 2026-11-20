#!/usr/bin/env bash
# The invariant oracle's NoWedge check as a guard of pgpm (formal methods Phase 3 W5): bench/formal_discriminate.sh
# over the custody files below, against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh can
# require it to FAIL against formal_mark_retired_chunks_unplaced_live_marked (a live partition's chunk marked retired, PR #1351 P1-01).
# The verdict is the oracle's, never the files' own (see formal_discriminate.sh); run_perf runs it against the real
# install, the clean-code half of the pair.
# Usage: formal_no_wedge.sh <container> <db> [pgpm_core/install.sql]
exec bash "$(dirname "$0")/formal_discriminate.sh" "${1:?container}" "${2:?db}" "${3:-/repo/pgpm_core/install.sql}" NoWedge \
  tests/346_archive_coverage_unnamed_bound_test.sql
