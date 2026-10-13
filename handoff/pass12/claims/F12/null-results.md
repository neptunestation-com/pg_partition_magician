# F12 null results (slice S8d)

## fresh surface

- scripts/archive_partition_whole.sql against pgpm._archive_step: identity check by child_oid, RLS refusal,
  retired-chunk exclusion, contract check, canonical resume watermark and covered_hi all present and matching.
  The two pieces the pass-11 fix added (the `_part_detached_by_hand` candidate predicate and the
  `_archive_hold_partition` hold) are missing from the code although the header, the inline comments and
  docs/reference.md describe them: claimed as F12-01 (static hand detach) and F12-02 (detach in flight), each
  checked to pass against a copy with only its own piece restored (F12-02 fails with the filter alone).
- .github/workflows/pages.yml: the deploy job now runs on every completed Release; the site step degrades to
  the latest published release or the control file's version; nothing else gates the job. Held.
- lint.yml / test.sh run_lint: run_lint's job list equals summary.needs in order; every run: block's commands
  appear in its lint_job_*; each job runs in a child `bash -e -o pipefail`; a missing tool is SKIPPED by name and
  `ci` reports it apart from PASS. Held.
- The three lint scripts' --selftest pass; check_quoted_splices and check_archive_object_keys pass on the tree;
  check_archive_child_by_oid FAILS on the tree at pgpm_archive/install.sql:3534. That line drops the typmod of
  archive.to_s3's cursor type (v_ctl_mod read and never used), so the lint is right; the behaviour is F12-04.
- Review tooling: stop_check, loop_state, decisions_queue, pass_metrics, plant_seeds and file_issues --selftest all
  PASS (stop_check's later failed only after the coordinator removed docs/reviews from the tree).

## time and zones

- _same_step (`'24 hours'` is `'1 day'`) against _grid_floor: the fixed branch is an absolute lattice of seconds
  from the anchor, zone-free, so a day and 24 hours give the same grid, as the reference says. Calendar steps
  are counted on the wall clock in partition_tz. Held.
- archive_partition_whole.sql's ledger lo/hi go through _max_hi_native and _native_text, whatever the
  caller's DateStyle. Held by reading.

## boundary arithmetic and types

- set_regrain's lock-budget warning: `2 * v_n > v_slots / 2` with slots = 64 x (100 + 0) = 6400 warns above 1600
  children, as reference.md says ("more than 1600"). Held by arithmetic; not run.
- archive.to_s3's type allowlist vs. the cursor cast: char(n) and bit(n) lose their typmod. Claimed F12-04.
- runbook `array[<id>]` against `p_ids bigint[]`: an int[] literal coerces implicitly. Held.

## operator error

- The untransmute pending-detach refusal's remedy (FINALIZE, then re-run) is typed by tests/312 part A. Held.
- The runbook's dropped_fk query names real columns (id, constraint_name, parent_table, restored_at). Held.

## failure injection

- pages.yml after a Release run that failed before publishing redeploys the page already served. Held by reading.
- loop_state.py check: a stale or dead phase exits 3 or 4; waiting and done never do. Held, except a future
  last_progress (H5).

## contracts versus documentation

- reference.md's sentences on the operator script (hand-detached table not a candidate; holds the parent and
  asks again) are not kept by the code: F12-01, F12-02.
- reference.md's to_s3 type rule (char(n), bit(n) pageable, every row read once) is not kept: F12-04.
- forget_missing's log `method` shape (`ARCHIVED CHUNKS, their pgpm.archive_ledger rows cleared ...`) matches the
  example in reference.md. Held.
- RELEASING.md and ONBOARDING.md/README.md test.sh lines match test.sh's tracks. Held.

## Hypotheses (not built)

- H1 check_quoted_splices.py: a FOR loop's scalar text target (`for v_cols in select string_agg(quote_ident(a),
  ', ') from ... loop`) is never read as an assignment: select_into needs INTO, ASSIGN needs := or =. An
  unmarked quoted list assigned that way passes CHECK 1 (probed through check_text: not caught). The docstring
  does not list FOR, so this is a scope edge, not built as a claim.
- H2 check_quoted_splices.py type_key: a local declared `pgpm.log.method%type` (a text column) or as a domain
  over text is not in TEXT_TYPES, so neither check judges it (probed through check_text: not caught). The
  module has no %type locals today.
- H3 check_quoted_splices.py strip_noise: an E-string with a backslash-escaped quote (`E'a\'b'`) ends the literal
  early and re-opens one at the next quote, blanking the code between, so an assignment after it is unread
  (probed: not caught).
- H4 archive.to_s3 bit(n): the same typmod loss as F12-04 makes the cursor `$1::bit`, i.e. bit(1). A bit(3)
  cursor '101' cast that way raises or truncates, so an export of a bit(3) relation with more than fetch_rows rows
  fails or never ends (tests/archive/db/51 part J covers it). Same root cause as F12-04, not built separately.
- H5 scripts/review/loop_state.py verdict(): a last_progress in the future (`age < -0.05`) returns OK (exit 0)
  whatever the phase, so a clock skew or a hand-stamped future time switches the dead-man switch off silently
  until the clock catches up; the message says "check the clock" but the exit code reads as ok.
- H6 scripts/archive_partition_whole.sql: with F12-01/F12-02 fixed, the hold takes ACCESS SHARE on the parent
  with no lock_timeout. Behind a queued DETACH CONCURRENTLY's SHARE UPDATE EXCLUSIVE it waits for that detach's
  whole wait (bounded only by the caller's statement_timeout, as the comment says). Documented, not a defect.

## Round 2

None of the hypotheses has a long-surviving shape (pending detach, read before lock, unlocked judgement,
sibling copy, older-install state, derived name), and this slice has no mechanical pre-pass, so the order was
by cost.

- H3 (E-string escaped quote hides an assignment from check_quoted_splices.py): built as F12-05 (Tier 5). The
  fixture function is valid PL/pgSQL (checked in pgpm_test-15). The lint refuses it after a plain literal
  (LIVENESS) and passes it after E'it\'s'.
- H1 (a FOR loop's scalar text target is never read as an assignment): built as F12-06 (Tier 5). The fixture
  compiles. The same list assigned by SELECT INTO inside a loop is refused (LIVENESS), and as the FOR target it
  passes.
- H2 (%TYPE of a text column, a domain over text): not attempted. Same lint and the same scope edge as F12-06;
  the module declares no such local today, so it adds little beside F12-05 and F12-06.
- H4 (bit(n) cursor in archive.to_s3): not built. Same root cause and line as F12-04 (the typmod dropped at
  pgpm_archive/install.sql:3534), so it would group with it.
- H5 (loop_state.py check reads a future last_progress as ok): not built. The behaviour is deliberate (the
  message says "check the clock"), so a claim would be a design judgement, not a broken contract.
- H6: not a defect (documented behaviour); not attempted.
