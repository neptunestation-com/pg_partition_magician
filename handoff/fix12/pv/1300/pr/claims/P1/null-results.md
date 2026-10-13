# P1 null results: per-PR verification of PR #1300

## Lens: fresh surface

- `pgpm.transmute_inflight.text_time_encoding` (install.sql 532-538, 550): the column is in the `create table` body and has its `add column if not exists` backfill line; `bench/upgrade_in_place.sh`'s DEGRADE_COLS names it, and its parser (`alter table <t> add column if not exists <c>`) reads the new line. Held.
- Recording (install.sql 10765-10772): `v_tt_encoding` is built for `text_time` only, with the null alphabet written out as the default for the radix and the epoch as `trim_scale(extract(epoch))`; every other kind writes null. Ran a first attempt and read the claim: `{"unit": "ms", "epoch": 0, "radix": 36, "width": 8, "prefix": "c", "alphabet": "0123456789abcdefghijklmnopqrstuvwxyz", "discard_bits": 0}`, as tests/337 expects. `trim_scale` is already used elsewhere in install.sql (PG13+), so the supported versions have it. Held.
- The take-over (`on conflict ... do update`) deliberately leaves `text_time_encoding` untouched, so RETURNING hands back the first attempt's encoding. Held.
- The comparison itself: ABSENT in this tree. `v_claim_tt_encoding` is declared (10054) and assigned (10784) and never read again; grep finds no `with text_time encoding` raise. Claim P1-01 (reproduced: the re-run under another epoch dies raw in the ATTACH; a scratch copy of install.sql with the comparison added passes the same reproduction, so it discriminates). Because the comparison is absent, the brief's sub-checks "every encoding argument is in the comparison" and "the same encoding spelled otherwise is admitted" cannot be probed on this tree beyond the obvious (everything is admitted); recorded as hypotheses below for the tree that has it.
- Non-text_time control's resume: `v_tt_encoding` is null for `time`, `id`, `uuidv7`; no comparison runs; the #628 (column) and #574 (grid) checks are unchanged in text and position. Held by reading.
- The remedy (`transmute_abort` then re-run): `transmute_abort` (11830) and the reaper (11885, 11901, 13939) delete the claim row by `parent_table`; a fresh claim after an abort records the new call's encoding. Held by reading (tests/337's ttabt leg exercises it).
- `pgpm.transmute` (11720-11750): passes every `p_tt_*` through unchanged; no change in the diff. Held.
- The cutover's ATTACH and the `pgpm.config` insert still encode and register with THIS call's `p_tt_*` (as before the change); with the comparison in place these equal the claim's for a resume. Held (consequence of P1-01 otherwise).
- tests/337 and `bench/transmute_resume_text_time_encoding.sh`: the test pins the refusal with `throws_like` (a committing procedure that does not refuse dies with 2D000 and a different message, so tests 6 and 17 cannot pass for the wrong reason); liveness witnesses for the validated CHECK and the out-of-bound row are present; the wrapper runs it through `bench/grid_timezone.sh`, which fails on 0 assertions ran. On this tree the test would fail on 6 and 17, so it discriminates. No Tier 5 claim.

## Lens: upgrade and install paths

- Install over an older install with a LIVE claim: installed the tree, dropped `text_time_encoding`, inserted a claim row, re-ran install.sql: the column is back and the claim row survives with `text_time_encoding` null (the documented "not checked" caveat, the same as #628's `control_attnum`). Held.
- `bench/upgrade_in_place.sh` (read whole): the degrade list names the new column, the GUARD that every backfilled column is in DEGRADE_COLS would fail a missing entry, the catalog comparison against a fresh oracle covers type and nullability. Held.
- docs: guide.md 338-340 and reference.md 428-432, 3803 describe the refusal and the equal-spelling rule; they match the PR body and tests/337 but not this tree (see P1-01; not filed separately as Tier 4 since the code, not the prose, is what is wrong). CHANGELOG entry matches the body.

## Hypotheses (no reproduction)

- With the comparison present (as the body describes, `is distinct from` on jsonb): a `p_tt_alphabet` that differs only in case from the recorded one is refused; that is correct (the column's collation orders them differently) but reference.md 428-432 does not say so. Not a defect.
- With the comparison present: an explicit `p_tt_epoch` with fractional seconds (e.g. `.5`) is normalised by `trim_scale`, and jsonb compares numbers numerically, so `0.50` and `0.5` are equal; a `p_tt_epoch` given in a session zone other than UTC is an instant, equal across offsets. Not a defect.
- A re-run whose encoding differs by so little that every row still satisfies the re-encoded bound (e.g. the epoch shifted by a second on a month grid) would not die in the ATTACH but would scan the table under ACCESS EXCLUSIVE and register `pgpm.config` with the new encoding; the same missing refusal (P1-01) covers it, and the refusal in the body covers it too. Not built: same root cause.
