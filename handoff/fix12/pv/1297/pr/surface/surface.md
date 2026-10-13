# Surface of the change: 6 file(s), 16 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 5-17
- `bench/install_keeps_surface_grants.sh` (added): 1-58
- `docs/guide.md` (modified): 147-150
- `pgpm_core/install.sql` (modified): 56-60, 132-137, 140-140, 152-177, 182-245, 260-263, 14278-14278, 14382-14382, 14558-14558, 14722-14722, 14784-14784
- `test.sh` (modified): 1268-1268
- `tests/336_install_keeps_surface_grants_test.sql` (added): 1-248

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:56-60` in `pgpm_core/install.sql` lines 56-60: top-level hunk, outside every function
- `pgpm_core/install.sql:132-137` in `pgpm_core/install.sql` lines 132-137: top-level hunk, outside every function
- `pgpm._surface_prepare` in `pgpm_core/install.sql` lines 138-180: touched at 140-140
- `pgpm._surface_sig_kept` in `pgpm_core/install.sql` lines 183-186: touched at 182-245
- `pgpm._surface_carry_grants` in `pgpm_core/install.sql` lines 195-242: touched at 182-245
- `pgpm._surface_settled` in `pgpm_core/install.sql` lines 246-266: touched at 260-263
- `pgpm_core/install.sql:14278-14278` in `pgpm_core/install.sql` lines 14278-14278: top-level hunk, outside every function
- `pgpm_core/install.sql:14382-14382` in `pgpm_core/install.sql` lines 14382-14382: top-level hunk, outside every function
- `pgpm_core/install.sql:14558-14558` in `pgpm_core/install.sql` lines 14558-14558: top-level hunk, outside every function
- `pgpm_core/install.sql:14722-14722` in `pgpm_core/install.sql` lines 14722-14722: top-level hunk, outside every function
- `pgpm_core/install.sql:14784-14784` in `pgpm_core/install.sql` lines 14784-14784: top-level hunk, outside every function
- `CHANGELOG.md` (modified file, read it whole)
- `bench/install_keeps_surface_grants.sh` (added file, read it whole)
- `docs/guide.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/336_install_keeps_surface_grants_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._surface_carry_grants`: `tests/336_install_keeps_surface_grants_test.sql`
- `pgpm._surface_prepare`: `bench/doc_install_stops_on_error.sh`, `bench/install_keeps_surface_grants.sh`, `docs/reviews/2026-10-06-pass9.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/281_install_keeps_dependent_views_test.sql`, `tests/336_install_keeps_surface_grants_test.sql`
- `pgpm._surface_settled`: `bench/doc_install_stops_on_error.sh`, `docs/reviews/2026-10-06-pass9.md`, `tests/281_install_keeps_dependent_views_test.sql`, `tests/336_install_keeps_surface_grants_test.sql`
