# Surface of the change: 7 file(s), 11 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 4-21
- `bench/hypertable_mixed_step_and_unit_remedy.sh` (added): 1-98
- `docs/reference.md` (modified): 1074-1082
- `pgpm_core/install.sql` (modified): 9064-9071, 9073-9073, 9075-9076, 9094-9094, 9097-9097, 9100-9100, 9102-9102
- `pgpm_hypertable/install.sql` (modified): 433-443, 451-459
- `test.sh` (modified): 601-604
- `tests/timescale/db/69_from_hypertable_mixed_step_and_unit_remedy_test.sql` (added): 1-206

## Units (read every one; the ledger names them exactly)
- `pgpm._time_unit_contract` in `pgpm_core/install.sql` lines 9070-9105: touched at 9064-9071
- `pgpm_hypertable/install.sql:433-443` in `pgpm_hypertable/install.sql` lines 433-443: top-level hunk, outside every function
- `pgpm._from_hypertable_check_arguments` in `pgpm_hypertable/install.sql` lines 445-460: touched at 451-459
- `pgpm._transmute` in `pgpm_core/install.sql` lines 10005-11666: calls pgpm._time_unit_contract
- `pgpm.from_hypertable_cutover` in `pgpm_hypertable/install.sql` lines 1637-2418: calls pgpm._from_hypertable_check_arguments
- `pgpm.from_hypertable` in `pgpm_hypertable/install.sql` lines 2430-2471: calls pgpm._from_hypertable_check_arguments
- `CHANGELOG.md` (modified file, read it whole)
- `bench/hypertable_mixed_step_and_unit_remedy.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/timescale/db/69_from_hypertable_mixed_step_and_unit_remedy_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._from_hypertable_check_arguments`: `bench/hypertable_argument_rules.sh`, `bench/hypertable_column_unit_rules.sh`, `bench/hypertable_mixed_step_and_unit_remedy.sh`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/timescale/db/58_from_hypertable_argument_rules_test.sql`, `tests/timescale/db/66_from_hypertable_column_unit_rules_test.sql`, `tests/timescale/db/69_from_hypertable_mixed_step_and_unit_remedy_test.sql`
- `pgpm._time_unit_contract`: `bench/hypertable_column_unit_rules.sh`, `bench/hypertable_mixed_step_and_unit_remedy.sh`, `bench/transmute_step_precision.sh`, `docs/reviews/2026-10-06-pass9.md`, `docs/reviews/2026-10-08-pass10.md`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/287_transmute_time_step_precision_test.sql`, `tests/306_date_key_anchor_midnight_test.sql`, `tests/timescale/db/66_from_hypertable_column_unit_rules_test.sql`, `tests/timescale/db/69_from_hypertable_mixed_step_and_unit_remedy_test.sql`
