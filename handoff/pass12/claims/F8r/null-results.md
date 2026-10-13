# F8r null results (pass 12, slice S7b re-run)

Scope: the 142 units of the brief (the second half of `bench/*.sh` the first finder did not read, four lint
scripts, eight workflows). About 104 of them are template pgTAP wrappers. For each one I read the header and
diffed the body against the template (`bench/obtain_lock_budget.sh`). I did NOT read the wrapped `tests/` files
(each wrapper's real assertion set) in full: the budget did not cover them. Every bespoke guard, every lint
script and every workflow was read in full.

## fresh surface

- Ran every lint in the slice against the tree: `check_archive_object_keys.py` (selftest and real run PASS),
  `check_track_filters.py` (PASS, 4 workflows, exactly at its floor), `check_living_docs.sh` (PASS),
  `check_quoted_splices.py` (PASS), `image_build_key.sh --selftest` (PASS). **`check_archive_child_by_oid.py`
  FAILS on the tree's own `pgpm_archive/install.sql:3534`.** I traced that line to `archive.to_s3`: it casts
  the keyset cursor as `v_ctl_typ::regtype::text`, which drops the typmod that its own comment (and
  `v_ctl_mod`, computed and never used) promises. I reproduced the result: a char(3) export never ends. Claimed
  as **F8r-01** (Tier 2). With `format_type(v_ctl_typ, v_ctl_mod)` the export completes and the lint passes. So
  lint.yml's required `Archive object keys` job, and with it `./test.sh lint`, is red on this tree for the same
  cause.
- The guards new since pass 11 are not in this re-run's unit list, so I did not re-read them.
- LIVENESS-prefixed lines in the bespoke guards (`regrain_truncate_guard_upgrade`,
  `transmute_reap_lock_timeout`, `reap_and_abort_lock_timeout`, `upgrade_unanchored_cell`,
  `regrain_moved_parent_identity`, `tap_verdict`, `reads_under_caller_rls`): each prefixed line is a premise.
  None of them is a defect check. Held.

## time and zones

- `untransmute_race.sh` uses rows stamped `now() - g minutes` on a monthly grid. It holds across a month
  boundary because the late row is placed at the monolith's hi plus one hour. `retain_horizon_ambiguous_wall_time`,
  `set_partition_tz_*` and `time_literal_era` are template wrappers. Their tests/ files were not read, so whether
  they vary DateStyle or try a fixed-offset zone is unverified (see Hypotheses).

## boundary arithmetic and types

- F8r-01 is the typmod boundary: bare `character` is char(1). I checked numeric(10,2) and bit(3) in the code
  path only through test 51's description; the char(3) case is the one reproduced.
- In `regrain_outgoing_fk_lock.sh`, the setup loop stops at the cursor `>= hi`, and the FK count is restricted
  to `conparentid = 0`. Held.
- In `check_track_filters.py`, REF_RE sees only `bench|scripts|tests` paths. I widened the regex to every repo
  file a track body names (.sql/.sh/.py/.yml/.control/.md). The only miss is `lockview.yml` leaving out
  `pgpm_core/install.sql`, which its own header documents as deliberate.

## operator error

- `transmute_online.sh` is the field instrument. Its "no in-flight record left behind" counts every
  `pgpm.transmute_inflight` row in the database, so it would fail on a customer database where another
  conversion is in flight. Its labels lack the `LIVENESS:` prefix. It is not a CI guard, so this does not
  matter to discriminate.sh. No claim.
- `release.yml`'s `workflow_dispatch` takes a "Version tag" input, but `actions/checkout@v4` checks out the
  dispatched ref, not that tag. See Hypotheses.

## failure injection

- `regrain_outgoing_fk_lock.sh`: its witness `saw := true` follows the poll loop unconditionally, the vacuous
  shape `restore_fk_lock.sh`'s header records as #416. No check states that the swap ran. I built a mutant whose
  swap tick waits 2 s and then refuses, as a hand call does when its snapshot-wait budget runs out. The guard
  still FAILED, on "the outgoing FK is intact ... got 3, want 1": unattached copies carry their own top-level
  FKs, so the count check is an incidental witness that a swap happened. The guard therefore discriminates the
  no-swap case and I dropped the claim. What remains is a no-swap path that drops its copies and lasts long
  enough for one probe write. I did not build it (Hypotheses).
- `reap_and_abort_lock_timeout`, `transmute_reap_lock_timeout`, `untransmute_race`, `transmute_claim_squat`:
  each inject one failure (a long reader, a dead owner, a squatter, an uncommitted writer) and each pairs it
  with a witness. Sibling failures they do not drive: a statement_timeout instead of a lock_timeout, and a
  cancel of the reaper mid-DROP. Not built.
- Timescale wrapper verdict block: it handles a raw ERROR:, a psql exit other than 0, a plan shortfall and
  zero assertions reached ("fixture:"). `discriminate.sh`'s `starved()` reads `not ok` lines with leading
  whitespace, as the wrappers echo them. Held.

## contracts versus documentation

- `lint.yml`'s `sql-syntax` step is titled "Check dollar-quote / comment balance in the module". It counts only
  `$$`: it ignores `/* */` and the `$q$`, `$f$` and `$pgpm$` tags install.sql uses. I verified that an
  unterminated `/*` fails a real install loudly (psql exit 3, "unterminated /* comment"), so every test track
  still catches it. Too weak to claim.
- `check_living_docs.sh`'s FROZEN list matches `frozen/` exactly, and every frozen file carries the banner.
  Check 6 refuses a non-literal action. Held.
- `wrapper_tap_verdicts.sh`'s header says "eleven pgTAP wrappers", while its name list holds 14 (plus whatever
  the scan finds). This is prose drift in a header, not a verdict defect.
- `shared_preflight_conformance.sh`'s header counts 28 public routines for `null_refusal_dropped_<routine>`. Not
  checked against pg_proc (the catalogue is not in the tree).

## Hypotheses (no reproduction)

1. `release.yml` dispatch path: run by `workflow_dispatch` with `version: vX.Y.Z` from the default branch, the
   `validate` job tests the default branch, and the `release` job's `actions/checkout@v4` (no `ref:`) builds the
   bundle, dbdev package and tarball from the default branch's `pgpm_core/install.sql`. The job then publishes
   them under `tag_name: vX.Y.Z`. If that tag already exists (re-running a failed tag push), its release gets
   assets that are not the tag's code. The mechanism is the missing `ref: ${{ steps.v.outputs.version }}` on
   the checkout (and on validate's). It needs a GitHub run to reproduce.
2. `timescale.yml` line 76: `run: TS_PG_TAGS='${{ inputs.ts_pg_tags }}' ./test.sh timescale` splices a dispatch
   input into a shell line, so a tag containing `'` runs arbitrary shell. Only a writer can dispatch, so the
   impact is low.
3. `regrain_outgoing_fk_lock.sh` passes with no swap if the swap tick does both of these: (a) lasts long enough
   for the probe to see `regrain_step` active and land one write; (b) leaves no unattached copy carrying an FK
   (a tick that waits, then cancels or restarts the run and drops its copies). The witness `saw` cannot fail,
   and no assertion reads a `regrain` / `copy_swap_drop` log row. Fix: set `saw` only on a sighting, and add
   "LIVENESS: the swap ran" from pgpm.log.
4. The ~104 template wrappers' tests/ files were not read. The time-zone wrappers (`retain_horizon_ambiguous_wall_time`,
   `set_partition_tz_grid_lock`, `set_partition_tz_midflight`, `time_literal_era`, `regrain_calendar_clamped_name`,
   `regrain_clamped_subrange_names`) are where a single-zone or ISO-only fixture would hide. Unverified.
5. `run_observe` (test.sh) checks out the pinned PGFR SHA only when `bench/vendor/pg_flight_recorder` is absent.
   A stale local clone at another SHA is used silently. This affects local `./test.sh ci` runs only; CI starts
   from a fresh checkout.
6. In the multi-file wrappers (`reread_under_lock_tap.sh` and similar), suppose one file dies with no `not ok`
   (a defect caught as a crash) while another prints only a premise `not ok`. `starved()` then reads only the
   tap lines and calls the run starved, an over-strict verdict that would make discriminate.sh reject a real
   catch. Never observed.
