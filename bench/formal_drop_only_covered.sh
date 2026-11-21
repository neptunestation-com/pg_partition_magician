#!/usr/bin/env bash
# The invariant oracle's DropOnlyCovered check as a guard of pgpm (formal methods Phase 3 W5): bench/formal_discriminate.sh
# over the custody files below, against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh can
# require it to FAIL against formal_retire_drops_uncovered (retire() drops with no archive coverage, the pre-#238 shape) and formal_archive_retired_unmarked (#1141: the drop's chunks never marked retired).
# The verdict is the oracle's, never the files' own (see formal_discriminate.sh); run_perf runs it against the real
# install, the clean-code half of the pair.
# Usage: formal_drop_only_covered.sh <container> <db> [pgpm_core/install.sql]
exec bash "$(dirname "$0")/formal_discriminate.sh" "${1:?container}" "${2:?db}" "${3:-/repo/pgpm_core/install.sql}" DropOnlyCovered \
  tests/64_retire_archive_gate_test.sql \
  tests/130_retire_unguarded_coverage_test.sql
