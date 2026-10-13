# Surface of the change: 8 file(s), 11 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 4-13
- `bench/transmute_resume_text_time_encoding.sh` (added): 1-27
- `bench/upgrade_in_place.sh` (modified): 155-155
- `docs/guide.md` (modified): 338-340
- `docs/reference.md` (modified): 428-432, 3803-3803
- `pgpm_core/install.sql` (modified): 532-538, 550-550, 10053-10054, 10765-10772, 10774-10775, 10783-10784
- `test.sh` (modified): 1114-1114
- `tests/337_transmute_resume_text_time_encoding_test.sql` (added): 1-150

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:532-538` in `pgpm_core/install.sql` lines 532-538: top-level hunk, outside every function
- `pgpm_core/install.sql:550-550` in `pgpm_core/install.sql` lines 550-550: top-level hunk, outside every function
- `pgpm._transmute` in `pgpm_core/install.sql` lines 10004-11675: touched at 10053-10054
- `pgpm.transmute` in `pgpm_core/install.sql` lines 11720-11750: calls pgpm._transmute
- `CHANGELOG.md` (modified file, read it whole)
- `bench/transmute_resume_text_time_encoding.sh` (added file, read it whole)
- `bench/upgrade_in_place.sh` (modified file, read it whole)
- `docs/guide.md` (modified file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/337_transmute_resume_text_time_encoding_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._transmute`: `bench/cutover_reread_window.sh`, `bench/cutover_trigger_window.sh`, `bench/frontier_drought.sh`, `bench/null_arguments_refused.sh`, `bench/tests_fail_on_defect.sh`, `bench/transmute_cutover_order.sh`, `bench/transmute_cutover_timing.sh`, `bench/transmute_reads_caller_rls.sh`, `bench/ts_text_archive_chunk_transmute_min.sh`, `docs/reference.md`, `docs/reviews/2026-09-25.md`, `docs/reviews/2026-09-28.md` ...
