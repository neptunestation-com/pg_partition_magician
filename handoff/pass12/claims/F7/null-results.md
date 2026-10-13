# F7 null results (pass 12, slice S7a: bench guards first half and the bench Python helpers)

The slice was read as the guards themselves, against their own headers. I read the 15 units never read
in pass 11 first, then the new and changed guards, then the rest. I ran the host-only guards and the doc
guards against the review tree, in my own `f7_*` databases, and dropped every database afterwards.

## Runs against the review tree

- Host-only, all PASS: `liveness_witness_labels.sh`, `doc_env_knobs.sh`, `doc_log_actions.sh`,
  `archive_keys_row_read.sh`, `ci_runs_lint_jobs.sh`, `lint_value_not_spelling.sh`.
- `lint_child_by_oid_inverse.sh` FAILS on the tree with "LIVENESS: the checkout's module passes the
  checker". The cause is that `scripts/check_archive_child_by_oid.py` refuses
  `pgpm_archive/install.sql:3534` (`v_ctltype := v_ctl_typ::regtype::text`) as a regtype rendered as
  text. I traced that line to a real defect: `archive.to_s3` drops the control column's typmod (claim
  F7-01). The guard is working. Its incidental catch is what pointed at the defect.
- On `pgpm_test-15`, all PASS: `doc_install_stops_on_error.sh`, `doc_install_guard_judges_stdin.sh`,
  `doc_fks_suspended_meaning.sh`, `doc_monolith_retention.sh`, `doc_remedy_and_symptom.sh`,
  `doc_transmute_no_default.sh`, `doc_maintain_does_not_obtain.sh`, `doc_retain_unit.sh`.
- On `pgpm_test-timescale`, PASS: `hypertable_catchup_identity.sh` (CONTROL, DEFECT and LIVENESS
  `p/1/1/245/245`).
- By hand: the `lock_view_names_scope_demo.sh` fixture plus `bench/sql/lockview_names.sql`. Each child
  resolved to one row with its own schema's parent.

## By lens

- **fresh surface.** I read all 15 new guards whole, plus the changed ones (`archive_fn_s3_readback`,
  `doc_archive_identity_recovery`, `doc_install_stops_on_error`, `hypertable_catchup_identity`,
  `lint_value_not_spelling`, `liveness_witness_labels`).
  - The wrappers' install-failure lines are spelled `fixture:` where the header says so
    (`archive_hold_detach_in_flight`, `archive_whole_skips_hand_detached`). Where they are spelled
    otherwise (`forget_missing_logs_object_keys`, `adopt_partition`), `discriminate.sh`'s own
    `installs()` check covers an uninstallable mutant first.
  - `hypertable_cutover_lock_timeout.sh` and `hypertable_handoff_fk_lock_timeout.sh` record
    `_scratch_written` and witness that the reader's snapshot is newer than the copy. That is the right
    premise for the new snapshot wait.
  - Following `archive_to_s3_multi_heap.sh` into its subject found F7-01: the typmod rule its header and
    tests/archive/db/51 part H promise is not kept by the tree's `archive.to_s3`.
- **contracts versus documentation.**
  - `doc_*` guards: each measures its fact before it reads the docs. Every premise is `need()` (exit) or
    LIVENESS-prefixed, and each has a planted CONTROL.
  - `doc_install_stops_on_error`: judges stdin, pipe and `-f` forms. Non-core installs are judged only
    on stopping, which the header says.
  - `doc_retain_unit`: only "count of X" phrasing is read (see the hypotheses).
  - `ci_runs_lint_jobs`: checked that `test.sh` runs each `lint_job_*` under `bash -e -o pipefail`, so a
    first failing command is not masked.
- **failure injection.**
  - `archive_fn_s3_readback` plants a PAR1-only PUT. Its sibling (a PUT whose body is the right length
    and the wrong bytes) is covered by the file's byte-for-byte compare.
  - `hypertable_catchup_identity` plants loss plus duplication after the cutover. The sibling (loss with
    no duplicate) would fail the count too.
  - `archive_recorded_chunk_tick_race` holds its window structurally. Its LIVENESS fails, as it should,
    if the direct call never waits.
- **time and zones.** Zone-sensitive wrappers (`grid_timezone` and its GRID_TZ siblings,
  `datestyle_bounds`, `archive_object_key_session`, `archive_to_s3_cursor_session`, `crossing_keys_*`,
  `month_*`, `naive_column_utc_grid`, `day_label_utc`) delegate the zones to their pgTAP files, which
  name New York, Havana, Asuncion, Amman, Shanghai, Guam and Kolkata. `frontier_drought.sh` runs under
  the server's UTC only (see the hypotheses).
- **boundary arithmetic and types.** `doc_retain_unit`'s fixture tells ids from intervals with
  asymmetric survivors. `extend_to_*` and `archive_to_s3_part_bytes` read at their edges. F7-01 is a
  typmod-at-the-type's-width defect (char(3), bit(3)).
- **operator error.** `hypertable_handoff_remedy.sh` runs the reference's own remedy block rather than
  typing one (header read). `doc_remedy_and_symptom` and `doc_archive_identity_recovery` measure each
  remedy they hold the docs to.

## Hypotheses (no reproduction built)

- **H1, `bench/doc_log_actions.sh`.** With no third argument, the only judgment of the tree is the line
  "LIVENESS: check 6 passes this tree". A doc that names a phantom action therefore fails only a
  LIVENESS-prefixed line, which `discriminate.sh`'s `starved()` and the classifier would read as a
  starved fixture, not a catch. Its mutations are run with a third argument (JUDGED path), so
  discrimination holds. The no-argument verdict is mislabelled as a premise. Tier 5 at most, unbuilt.
- **H2, `bench/lock_timeout_pairing_demo.sh`.** Its two premise checks, "session B's wait was actually
  aborted by lock_timeout" and "session A's commit is in the capture", carry no LIVENESS: prefix, so a
  run that failed only them would read as a defect. It is not in the discriminate track, so the impact
  is labelling only. The header also cites `bench/lock_view.py:108-121`, but `on_lock` spans 108-138.
- **H3, `bench/lock_trace.sh:153`.** "the probe attached and is delivering events" is a premise without
  a prefix, and it is not in the FLOOR of `liveness_witness_labels.sh`. Same class as H2.
- **H4, `bench/doc_scan.py` SPLIT.** It cuts a sentence at any `.` followed by whitespace, so "e.g. ",
  "i.e. " or "v0.6. " split a sentence. A doc rule that needs its negation in the same sentence (the
  DENIAL regex in `doc_transmute_no_default`, NEG in `doc_maintain_does_not_obtain`) could then flag a
  correct sentence, or miss a wrong one whose cause word lands in the next fragment. Unbuilt.
- **H5, `bench/doc_retain_unit.sh`.** Only "count of <unit>" phrasing is read. A runbook sentence giving
  the wrong unit in other words ("retain => 2 keeps two partitions") passes. Building it needs a
  planted doc line.
- **H6, `bench/frontier_drought.sh`.** It runs in the server's UTC session only. A uuidv7 or text_time
  frontier read from a session in a zone with a DST transition inside the 2-month lookahead is not
  exercised. The frontier is an instant, so this is probably sound.
- **H7, `bench/hypertable_catchup_identity.sh` DEFECT splice.** It deletes `where ctid = (...)` on a
  partitioned table, and ctid is not unique across partitions. It passes today (witness `p/1/1/245/245`)
  only because the oldest row's ctid matches no other partition's row. A fixture change could make it
  delete two rows and fail its own LIVENESS. That fails safe, but it is fragile.
- **H8, `bench/archive_to_s3_multi_heap.sh`.** Database creation and extension creation are not run
  under ON_ERROR_STOP with their exits read (unlike `archive_retired_chunk_digest_layer.sh`, which was
  fixed). The later install checks catch a missing database, so the impact is limited to an unlabelled
  failure.
- **H9, `bench/lock_view_names_scope_demo.sh`.** The fixture's two hand inserts into `pgpm.part` are not
  checked. I verified they succeed on today's schema. A future NOT NULL column on `pgpm.part` would make
  the second insert fail silently, the collision would vanish, and the demo would pass against the
  reverted query.

## Round 2

None of my hypotheses has one of the long-surviving shapes (1) to (6), and I have no mechanical pre-pass.
So I built the labelling hypotheses: a defect check carrying a premise prefix, or a premise without one.
Each is a repro.sh that reads the guard from `$TREE` and applies `bench/discriminate.sh`'s own `starved()`.

- **H1 built as F7-02 (Tier 5).** I ran `bench/doc_log_actions.sh` with no third argument from a scratch
  root, with a phantom action planted in the runbook's `action in (...)` list. Its only failure is
  "LIVENESS: check 6 passes this tree", which `starved()` reads as a starved fixture, not as a catch.
  Fails on the tree.
- **H3 built as F7-03 (Tier 5).** `bench/lock_trace.sh:153` prints "the probe attached and is delivering
  events" without a prefix, then `exit 1`. Rendered through its own `check()`, `starved()` certifies
  that line as a catch. Fails on the tree.
- **H2 not built.** `lock_timeout_pairing_demo.sh` has no mutation in the discriminate tracks, so no
  reader applies `starved()` to its labels. The mislabel changes no verdict, and a reproduction would
  show nothing a verifier could count.
- **H4 to H9 not attempted.** None has a long-surviving shape, and each needs a planted doc or a fixture
  change to the guard's subject. H7 and H9 are fragility notes. Their failure modes today fail safe or
  were checked to hold.
