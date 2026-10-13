# Surface of the change: 6 file(s), 13 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 4-17
- `bench/regrain_not_valid_check.sh` (added): 1-62
- `docs/reference.md` (modified): 2082-2088
- `pgpm_core/install.sql` (modified): 6540-6541, 6554-6561, 6621-6628, 6660-6665, 6673-6674, 8561-8582
- `test.sh` (modified): 1268-1268
- `tests/331_regrain_not_valid_check_test.sql` (added): 1-222

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:6540-6541` in `pgpm_core/install.sql` lines 6540-6541: top-level hunk, outside every function
- `pgpm._regrain_copy_make` in `pgpm_core/install.sql` lines 6546-6584: touched at 6554-6561
- `pgpm_core/install.sql:6621-6628` in `pgpm_core/install.sql` lines 6621-6628: top-level hunk, outside every function
- `pgpm._regrain_shape_drift` in `pgpm_core/install.sql` lines 6653-6706: touched at 6660-6665
- `pgpm.regrain_step` in `pgpm_core/install.sql` lines 7844-8666: touched at 8561-8582
- `pgpm._regrain_fresh_copy_drift` in `pgpm_core/install.sql` lines 6596-6611: calls pgpm._regrain_copy_make, pgpm._regrain_shape_drift
- `pgpm.regrain` in `pgpm_core/install.sql` lines 8671-8722: calls pgpm.regrain_step
- `pgpm.maintain` in `pgpm_core/install.sql` lines 13312-13515: calls pgpm.regrain_step
- `CHANGELOG.md` (modified file, read it whole)
- `bench/regrain_not_valid_check.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/331_regrain_not_valid_check_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._regrain_copy_make`: `bench/regrain_not_valid_check.sh`, `docs/reviews/2026-10-12-pass12.md`, `tests/331_regrain_not_valid_check_test.sql`
- `pgpm._regrain_shape_drift`: `bench/regrain_fk_drift_swap_scan.sh`, `docs/reviews/2026-10-02-pass7.md`, `docs/reviews/2026-10-04-pass8.md`, `tests/251_regrain_fk_drift_test.sql`
- `pgpm.regrain_step`: `bench/README.md`, `bench/grid_floor_across_era.sh`, `bench/maintain_regrain_lock_timeout.sh`, `bench/month_step_dst_gap.sh`, `bench/part_name_labels_injective.sh`, `bench/part_name_length.sh`, `bench/regrain_candidate_subdivides.sh`, `bench/regrain_capture_enabled_always.sh`, `bench/regrain_capture_origin_only_upgrade.sh`, `bench/regrain_children_tablespace.sh`, `bench/regrain_clamped_subrange_names.sh`, `bench/regrain_copy_name_clash.sh` ...
