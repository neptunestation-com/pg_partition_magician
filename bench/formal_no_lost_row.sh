#!/usr/bin/env bash
# The invariant oracle's NoLostRow check as a guard of pgpm (formal methods Phase 3 W5): bench/formal_discriminate.sh
# over the custody files below, against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh can
# require it to FAIL against formal_regrain_reconcile_discards_delta (the reconcile skips applying the captured change, #916).
# The verdict is the oracle's, never the files' own (see formal_discriminate.sh); run_perf runs it against the real
# install, the clean-code half of the pair.
# Usage: formal_no_lost_row.sh <container> <db> [pgpm_core/install.sql]
exec bash "$(dirname "$0")/formal_discriminate.sh" "${1:?container}" "${2:?db}" "${3:-/repo/pgpm_core/install.sql}" NoLostRow \
  tests/110_triggers_enable_always_test.sql \
  tests/120_regrain_reconcile_offgrid_lo_test.sql \
  tests/136_regrain_reconcile_datestyle_test.sql
