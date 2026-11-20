#!/usr/bin/env bash
# The invariant oracle's ArchiveNoClobber check as a guard of pgpm_archive (formal methods Phase 3 W5):
# bench/formal_discriminate.sh --archive over tests/archive/db/42, against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can require it to FAIL against
# formal_archive_recorded_chunk_rows_unchecked (a direct call over a retired chunk's own range PUTs an empty object over
# the only copy, #975 F5-03 as #1069 left it). The retired chunks' objects are read back from MinIO, on the archive
# track's network (PGPM_FORMAL_NET, default docker-compose's pgpm_test_net, where it answers as minio:9000).
# The verdict is the oracle's, never the file's own (see formal_discriminate.sh); run_archive runs it against the real
# module, the clean-code half of the pair.
# Usage: formal_archive_no_clobber.sh <archive container> <db> [pgpm_archive/install.sql]
exec bash "$(dirname "$0")/formal_discriminate.sh" --archive "${PGPM_FORMAL_NET:-pgpm_test_net}" "${1:?container}" "${2:?db}" \
  "${3:-/repo/pgpm_archive/install.sql}" ArchiveNoClobber \
  tests/archive/db/42_archive_recorded_chunk_overwrite_test.sql
