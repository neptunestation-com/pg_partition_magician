## Defect (#1270)

A failed `transmute` leaves a claim in `pgpm.transmute_inflight` and a validated `pgpm_monolith_bound` `CHECK`, and a re-run resumes from that bound. The resume checked the claim's column (#628) and grid (#574), but the claim did not record the `text_time` encoding that the `CHECK`'s two literals use. A re-run with another `p_tt_epoch` (or prefix, width, radix, unit, alphabet or discard bits) took the claim over. It skipped phases 1 and 2, because a validated constraint by that name exists, and attached the monolith with the bound encoded the new way. The `CHECK` does not imply that bound, so the `ATTACH` scanned the table under `ACCESS EXCLUSIVE` and died raw ("partition constraint ... is violated by some row") after the bound and claim had committed.

## Fix

- `pgpm.transmute_inflight` gains `text_time_encoding jsonb`, with an `add column if not exists` backfill line. `bench/upgrade_in_place.sh`'s degrade list names it.
- `_transmute` records the call's encoding with a fresh claim, for `text_time` only (null for every other kind, which encodes nothing). The form makes two spellings of one encoding compare equal: a null `p_tt_alphabet` is written out as the default alphabet for the radix, and `p_tt_epoch` is stored as seconds since 1970-01-01 UTC (`trim_scale(extract(epoch ...))`), so the same instant at another offset is the same encoding.
- On a resume (the `on conflict ... do update` take-over, both arms: a dead owner and this same session), a recorded encoding that is `is distinct from` the call's is refused in the first transaction, before anything commits. The refusal names both encodings and the remedy (`transmute_abort`, then re-run). The raise rolls the take-over back, so the claim, the bound and the table are unchanged.

What this guarantees: on a resumed `text_time` claim recorded by this install, the cutover never attaches with a bound encoded differently from the `CHECK` that phase 1 wrote. One site is covered: the claim insert and its resume in `pgpm._transmute`, the only writer of `transmute_inflight` (pgpm_hypertable and pgpm_archive do not claim). `transmute_abort` and the reaper read the claim with `select *` and are unaffected.

Caveat (deliberate, same as #628's `control_attnum`): a claim recorded before this column existed has `text_time_encoding` null after the upgrade, and its resume is not checked. That is the old behaviour.

## Acceptance

- F1-06's `repro.sql`, run unchanged: fails on base (test 3: `partition constraint of relation "f1tt_p..." is violated by some row`), passes on this head (refused with `pg_partition_magician: cannot resume the transmute of f1tt with text_time encoding ...`), and fails again on the mutant.
- `tests/337_transmute_resume_text_time_encoding_test.sql` (21 assertions). A real first attempt fails in the cutover from a dblink session, with liveness witnesses for the validated `CHECK` and for a row outside the re-run's encoded bound. A re-run with the epoch one day earlier is refused, with the message pinned by `throws_like`, and the claim, `CHECK` and table are unchanged. The same encoding spelled otherwise (epoch `'1970-01-01 01:00:00+01'`, default alphabet written out) resumes (`transmute_resume` logged) and converts, with rows 1..20 and the referencing row kept by identity. The remedy, typed on a second table: `transmute_abort`, then the new-encoding call converts fresh and registers the new epoch.
- Guard: `bench/transmute_resume_text_time_encoding.sh` (`pgpm_perf378`), a pgTAP wrapper over tests/337 through `bench/grid_timezone.sh`.
- Mutation: `transmute_resume_any_encoding` removes the comparison whole and keeps the recording. The guard FAILS against it on tests 6 and 17 (the refusals), not on a LIVENESS line.

Local proof: `./test.sh 15 --channel=psql` PASS (through the gate); tests/337 passes on `pgpm_test:18`; `bench/upgrade_in_place.sh` PASS; `bench/throws_pinned.sh` on tests/337 PASS; `check_quoted_splices.py` (and `--selftest`) PASS; every mutation builds; `check_living_docs.sh` PASS; shellcheck clean; markdownlint 0 errors.

Closes #1270

🤖 Generated with [Claude Code](https://claude.com/claude-code)

