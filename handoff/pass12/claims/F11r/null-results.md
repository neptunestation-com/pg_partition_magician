# F11r null results (pass 12, slice S8c re-run: the bench guards the first finder did not read)

Claims: F11r-01 (Tier 5, fresh surface): the tree's own archive module fails the tree's own
`scripts/check_archive_child_by_oid.py` (CI's Lint job) at pgpm_archive/install.sql:3534
(`v_ctltype := v_ctl_typ::regtype::text`, added by the to_s3 pageable-type fix), and
bench/lint_child_by_oid_inverse.sh fails its LIVENESS premises on clean code as a result.

## fresh surface

- Ran the three static guards on the tree: lint_value_not_spelling.sh PASS (42 checks),
  liveness_witness_labels.sh PASS (117 floor labels, 0 spelling HITs in bench/ and in 326 wrapper-run
  test files), lint_child_by_oid_inverse.sh FAIL (claimed, F11r-01). Ran the other repo lints
  (check_quoted_splices, check_archive_object_keys, check_track_filters): all PASS, so the collision is
  the one.
- The `unreached -> fixture:` rule (#1177) in every timescale wrapper and the inverted wrappers: checked
  that a file whose defect shows as a raw ERROR still reaches assertions first (tests/timescale/db/30,
  hypertable_empty_copy_watermark), so the new rule does not starve that guard. Held.
- The verdict restatement (`N ran, M failed`) stays unprefixed and is set aside by starved(); the
  reached-at-all line carries LIVENESS:. Read in discriminate.sh's starved(). Held.
- Every LIVENESS:-prefixed label in the slice's non-wrapper guards (transmute_claim_squat,
  regrain_truncate_guard_upgrade, upgrade_unanchored_cell, upgrade_in_place, retire_detach_lock,
  regrain_outgoing_fk_lock, doc_archive_identity_recovery, reads_under_caller_rls,
  hypertable_cutover_*): each judged a premise, not a defect check. upgrade_in_place's DEGRADE_COLS check is
  deliberately unprefixed, and its maintain_obtain line is called a LIVENESS WITNESS by its own header.
  No defect check found carrying a premise prefix.
- archive_recorded_chunk_tick_race vs the new `_archive_hold_partition`: ACCESS SHARE on the parent does
  not conflict with the direct call's reads, so the guard's "direct call waits on a lock" witness still
  depends on the claim row and the mutant is still exposed. Held.
- hypertable_cutover_lock_timeout and hypertable_handoff_fk_lock_timeout record the copy's last write by
  hand (`_scratch_written`) and witness that the reader's snapshot is newer, so the cutover's new snapshot
  wait passes the reader and the lock_timeout is what is measured. Held.
- upgrade_in_place: the three new backfilled columns are in DEGRADE_COLS; install.sql treats a NULL
  regrain_written_xid as "wait for every snapshot" (comment and _regrain_snapshot_wait call read). Held.
- tests_fail_on_defect: G14 (tests/93, 74, 141) and S7 (tests/303) sections: each defect planted into the
  checkout, a behavioural LIVENESS probe for each, the plant failure now `fixture:`. Held.

## time and zones

- hypertable_time_rendering runs tests 35 (naive watermark vs session zone) and 36 (DateStyle SQL);
  doc_install_stops_on_error and the archive guards run under the server's UTC/ISO. Did not vary a
  fixed-offset vs DST zone in any guard (H4).

## boundary arithmetic and types

- tests_fail_on_defect's ab_probe (archive_byte_budget 2000, chunk 0-59) and tests/74's range_agg
  coverage read; archive_to_s3_multi_heap's parts (page of one row, NULL run, typmod) read via its header.
  No guard found whose fixture sits a step inside the edge it claims; nothing built.

## operator error

- doc_archive_identity_recovery: the runbook's `select pgpm.adopt_partition('public.events',
  'public.<partition>')` matches the signature (regclass, regclass) returning text; the guard measures it.
  Held.
- doc_install_stops_on_error: ran; every documented install command (8) stops at the first error and the
  core ones leave a refusing install unchanged. Held.

## failure injection

- archive_fn_s3_readback (PAR1-only PUT), hypertable_catchup_identity (one lost, one twice),
  tests_fail_on_defect (each plant): each injects one failure. Sibling not driven by archive_fn_s3_readback:
  an upload that lands the whole file but a ledger rows_archived that lies; not built.

## contracts versus documentation

- pages_deploy_after_release: evaluator and pages.yml read; the guard's own contract holds (deploy runs on a
  failed Release run). See H1 for what that deploy then serves.
- doc_install_stops_on_error and doc_archive_identity_recovery: run/read against README, guide, runbook,
  reference. Held.

## Hypotheses (no reproduction)

- H1 (Tier 4 candidate, .github/workflows/pages.yml "Assemble site" step): since #1169 the install page
  redeploys after a Release run that concluded failure because publish-dbdev refused the package over the
  250,000-character cap. The step substitutes DBDEV_VERSION with the new tag unconditionally
  (`sed ... s/DBDEV_VERSION/${TAG#v}/g`), so install.html then tells operators to type
  `create extension "dventimisupabase@pg_partition_magician" version '<new>'`, a version database.dev never
  received, which fails. bench/pages_deploy_after_release.sh proves the deploy runs and never asks what
  the dbdev line then says. A reproduction would run the step with a stub `gh` and assert the page names
  only a published dbdev version; no "absent" form exists to pass against without a fix design.
- H2 (Tier 5, latent): bench/archive_fn_s3_readback.sh:87 and bench/hypertable_catchup_identity.sh:90 print
  `planted the defect: ...` with no premise prefix, while tests_fail_on_defect.sh (and
  liveness_witness_labels.sh's FLOOR, which lists `planted the defect:` as a W for that guard) treat the
  same line as a `fixture:` premise. If the plant pattern stops matching, discriminate.sh reads the
  failure as a catch. Not claimed: the same guard run against clean code fails the same way, so CI's
  clean run is red first; no discrimination is falsely certified while the clean run is watched.
- H3 (install.sql, not this slice): upgrade_in_place stages no partition mid-retirement across the upgrade
  that added pgpm.part.detach_dispatched_oid; _disown_unvouched_retirements gives an attached marked
  partition its record only when `_detach_job_holds` can read cron.job. Without the privilege to read
  cron.job (exception -> false), an older install's own dispatched detach that pg_cron has yet to run lands
  on a mark with no record and is disowned on the next pass, leaving the detached table for the operator.
  Safe side by its own comment, but no guard drives it.
- H4: no guard in the slice runs a zone-sensitive fixture under a fixed-offset zone against a DST zone
  (tests 35/36 vary one each); not read further.
