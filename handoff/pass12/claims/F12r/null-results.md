# F12r null results (slice S8d re-run: documents, review tooling, lints, test.sh)

## fresh surface

- CHANGELOG Unreleased: read every bullet against its code. Beyond F12r-01, the bullets' function and
  mutation names resolve; the #1161 bullet's first copy (set_regrain warns, stores) matches set_regrain and
  tests/315. Held apart from the merge residue claimed.
- test.sh `lint` track vs `.github/workflows/lint.yml`: the ten jobs match `summary.needs` in order; every
  `run:` command is copied; markdownlint uses the tracked set at 0.13.0; shellcheck's extension list covers
  the tracked tree (I checked: no extensionless file with a shell shebang is tracked). `ci` reads lint's exit 3
  as SKIPPED, never PASS. Held.
- pages.yml (as RELEASING.md describes it): deploys on every completed Release run, whatever its conclusion.
  Held.
- flake_check.sh signatures against the relabelled guards (`LIVENESS: the probe overlapped a running swap`,
  restore_fk_lock's two witnesses): spellings match the guards in the tree. Held.
- landq.sh rule-first ordering: traced `sort | while ... | sort | awk '!seen'` by hand for a PR listed twice
  (plain and `rule`), mixed tiers, and done PRs; lowest unfinished tier only, rule first, each PR once. Held.
- Lints run on the tree: `check_archive_object_keys.py` PASS (18 references). `check_archive_child_by_oid.py`
  FAILS on the tree's own pgpm_archive/install.sql line 3534 (`v_ctl_typ::regtype::text`): the behavioural
  defect behind it is F12r-05.
- Lint spellings that held (refused correctly): `c.oid::regclass::pg_catalog.text`, `::pg_catalog.regclass::text`,
  `::"regclass"::text`, `collate "C"`, `textin(regclassout(...))`, `::character varying`,
  `p_name = any(array[c.relname])`; object keys: `operator(pg_catalog.||)`, `array_to_string(array[...])`,
  `array_append(...)`.

## time and zones

- archive.to_s3's cursor text: `_cursor_text` pins TimeZone UTC and DateStyle ISO, extra_float_digits pinned
  on to_s3; a DateStyle SQL/Asia/Kolkata `IST` abbreviation round trip cannot occur. Held.
- forget_missing's chunk list renders lo/hi as stored canonical text; the reference example's format
  (`[lo, hi) 'key' retired`) matches the code. Held.
- loop_state.py times are UTC `Z` strings, parsed strictly. Held (see hypothesis on future-dated progress).

## boundary arithmetic and types

- pass_metrics/stop_check rounding: claimed F12r-02 (precision 16/23, fell 7/23, coverage 26/29).
- reference.md lock budget arithmetic: 64 x (100 + 0) = 6400 slots, half 3200, 1600 children at two slots;
  tests/315's `slots / 4` cap agrees. Held.
- coverage.py rounds to 3 places and pass_metrics counts `round(v, 3) >= 0.90`, consistent with each other;
  only the printed minimum (2 places) misleads stop_check (part of F12r-02).
- archive.to_s3 char(n) cursor: claimed F12r-05.

## operator error

- Runbook remedy typed in pgpm_test-15: `select id, constraint_name from pgpm.dropped_fk where parent_table =
  ... and restored_at is null` and `select pgpm.restore_incoming_fks('public.ev', array[5])` (int[] to
  bigint[] resolves). Both run.
- Runbook `select pgpm.regrain_history('public.events')` (default target null = partition step): the
  signature matches. Held.
- decisions_queue: `--by` with parentheses refused, `|` and newlines refused, resolving twice refused, an
  older `--loop` refused. Held; the hand-edit gap is F12r-04.
- loop_state: `--stale-hours` >= `--dead-hours` refused; corrupt or incomplete JSON refused. Held.
- file_issues: `--post` refuses over an existing filed.json; a group naming a non-finding is refused before
  writing. Held.

## failure injection

- file_issues.post writes filed.json after each issue, so a gh failure part way leaves an accurate record.
  Held (one gap: an issue created whose URL line cannot be parsed raises before it is recorded; noted below).
- uninstall.sql refusal path: a key it cannot restore raises before `drop schema`, inside the same DO block,
  so a client that continues past errors cannot reach the drop. Held.
- test.sh `ci`: each track is a child invocation, lint first; a failing lint job is FAIL, a missing tool
  SKIPPED with its name. Held.

## contracts versus documentation

- README/ONBOARDING/RELEASING/guide install and upgrade commands all carry `-v ON_ERROR_STOP=1
  --single-transaction` for install.sql. Held.
- reference `pgpm.part.detach_dispatched_oid`, `retain_disown`, `warn_regrain_lock_budget`, `warn_grid_off_unit`
  rows: the action names exist in install.sql. Held.
- pgpm_archive/README's to_s3 allowlist matches the code's list and the reference's. Held.
- scripts/review/README "Only candidate claims need a verdict ... reported as unverified": broken, F12r-03.

## Hypotheses (no reproduction built)

- stop_check.py criterion 4 uses Python's `round()`, which rounds half to even: a capture-recapture estimate
  leaving 0.5 Tier 1 reads "rounds to zero" (met), 1.5 reads 2. The method doc does not define the rounding,
  so whether 0.5 should count as one remaining is a policy question, not built.
- loop_state.py `verdict()`: a `last_progress` stamped in the future (a skewed clock on the host that wrote
  it) reads `ok` for as long as it stays in the future, so the dead-man switch cannot fire for that span plus
  six hours.
- pages.yml checks out the default branch on a `workflow_run`, so the install page publishes main's
  `uninstall.sql` beside the latest release's bundle; after main changes uninstall.sql, a released install is
  offered a newer uninstall script than its own (not in my slice; pages.yml belongs to S7b).
- guide.md "Read consistency" and "Regrain the history" say a regrain never undercounts and there is no read
  gap "on the synchronous path"; reference.md documents that under `regrain()` a REPEATABLE READ snapshot taken
  after the wait's last poll misses every row of the range. A documented limit, so not claimed, but the guide's
  absolute sentences contradict it.
- runbook "A from_hypertable cutover is slow" does not mention the new snapshot-wait refusal
  (`hypertable cutover deferred: N snapshot(s) older than the copies`) or that a dblink-held caller snapshot
  makes it refuse; an operator following that entry is not pointed at long REPEATABLE READ readers.
- review-pass SKILL.md step 7 runs pass_metrics.py without `--coverage` or `--capture-recapture`, so a record
  written from that skill alone has no coverage line and reads capture-recapture "not attempted";
  stop_check then can never meet criterion (a). The review-loop skill adds both, so not claimed.
- file_issues.post: `gh issue create` succeeding but printing a trailing non-URL line makes the URL parse
  raise after the issue exists and before filed.json records it; a re-run files it twice.
- uninstall.sql's header and guide list "the DEFAULT" among partitions left in place; pgpm never creates one
  (cosmetic).
- runbook "Storage is not dropping": "Two mechanisms reclaim aged data" is followed by one bullet (a removed
  bullet's residue; cosmetic).
