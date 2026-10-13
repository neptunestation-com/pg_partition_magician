# Surface of the change: 6 file(s), 9 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 5-15
- `bench/regrain_refuses_strict_isolation.sh` (added): 1-52
- `docs/reference.md` (modified): 1697-1711, 1770-1771, 2028-2030, 2202-2203
- `pgpm_core/install.sql` (modified): 7819-7841, 8657-8657, 8714-8714
- `test.sh` (modified): 1268-1268
- `tests/329_regrain_refuses_strict_isolation_test.sql` (added): 1-237

## Units (read every one; the ledger names them exactly)
- `pgpm._regrain_refuse_strict_isolation` in `pgpm_core/install.sql` lines 7832-7840: touched at 7819-7841
- `pgpm.regrain` in `pgpm_core/install.sql` lines 8651-8703: touched at 8657-8657
- `pgpm.regrain_history` in `pgpm_core/install.sql` lines 8708-8724: touched at 8714-8714
- `pgpm.set_regrain` in `pgpm_core/install.sql` lines 12848-12971: calls pgpm.regrain_history
- `CHANGELOG.md` (modified file, read it whole)
- `bench/regrain_refuses_strict_isolation.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/329_regrain_refuses_strict_isolation_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm.regrain`: `bench/README.md`, `bench/acl_grantor_owner_partitions.sh`, `bench/adopt_partition_regrain_lock.sh`, `bench/archive_ledger_identity.sh`, `bench/archive_retired_chunk_kept.sh`, `bench/control_column_rename.sh`, `bench/cutover_replica_identity.sh`, `bench/doc_fks_suspended_meaning.sh`, `bench/doc_log_actions.sh`, `bench/doc_maintain_does_not_obtain.sh`, `bench/doc_monolith_retention.sh`, `bench/dropped_fk_reconcile.sh` ...
- `pgpm.regrain_history`: `bench/README.md`, `bench/regrain_calendar_clamped_name.sh`, `bench/regrain_refuses_strict_isolation.sh`, `bench/regrain_step_positive.sh`, `bench/run_fh.sh`, `bench/tests_fail_on_defect.sh`, `docs/adversarial-review.md`, `docs/guide.md`, `docs/reference.md`, `docs/reviews/2026-10-08-pass10.md`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md` ...
