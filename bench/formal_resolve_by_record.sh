#!/usr/bin/env bash
# The invariant oracle's ResolveByRecord check as a guard of pgpm (formal methods Phase 3 W5): bench/formal_discriminate.sh
# over the custody files below, against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh can
# require it to FAIL against formal_retire_drop_child_oid_ignored (retire() resolves the partition by name, not by its recorded child_oid, #428 of the #407/#421 family).
# The verdict is the oracle's, never the files' own (see formal_discriminate.sh); run_perf runs it against the real
# install, the clean-code half of the pair.
# Usage: formal_resolve_by_record.sh <container> <db> [pgpm_core/install.sql]
exec bash "$(dirname "$0")/formal_discriminate.sh" "${1:?container}" "${2:?db}" "${3:-/repo/pgpm_core/install.sql}" ResolveByRecord \
  tests/103_retire_identity_unreferenced_test.sql
