# Changelog

## [Unreleased]

- **`scripts/archive_partition_whole.sql` leaves a table detached by hand out of its candidates** (#1159). Its
  candidate query chose on `pgpm.part.attached`, which an operator's own `DETACH PARTITION` never touches, so a
  table detached by hand that still carried pgpm's write block was handed to the strategy; one reading the
  range through the parent, as `pgpm_archive`'s transports do, found none of its rows, and the script recorded
  `[lo, hi)` as covered with 0 rows, so once the operator attached the table back `retain()` dropped rows
  nothing had archived. The query now asks `pgpm._part_detached_by_hand` first, as the archive step has since
  #705: such a table is never handed to the strategy, no coverage is recorded for it, and the call archives the
  parent's next eligible partition instead. Both the script and `pgpm._archive_step` also missed a detach that
  landed mid-call: they asked only in the candidate query and locked nothing, so the first read waited out a
  `DETACH PARTITION` in flight and a strategy reading through the parent then found none of the table's rows and
  the range was recorded as covered. Both now call `pgpm._archive_hold_partition` before the first read, which
  takes `ACCESS SHARE` on the parent (under `maintain`'s 200 ms `lock_timeout` a longer wait is `skip_archive`)
  and asks the catalog again as of that lock, under any isolation level; a table that left meanwhile is not
  archived and nothing is recorded. Tests `tests/313` and `tests/325` (and `tests/307` part B at `archive_batch`
  1); guards `bench/archive_whole_skips_hand_detached.sh` and `bench/archive_hold_detach_in_flight.sh`,
  mutations `archive_whole_trusts_part_attached`, `archive_hold_unlocked`, `archive_hold_recheck_by_snapshot`,
  `archive_step_hold_skipped` and `archive_whole_hold_skipped`.

- **A retired chunk's ledger row is the record of the only copy, and nothing discards it or archives over it**
  (#1141). After `retire()` dropped an archived partition, a partition re-created over its range by plain DDL
  and recorded with `pgpm.adopt_partition` made the next tick's orphan discard delete the retired chunk's
  `pgpm.archive_ledger` row and archive the new partition to the same object key (parent and `lo`), over the
  only copy of the dropped rows; under the dropped partition's own name, `adopt_partition`, `retire()`, the
  write-block step and a regrain's swap deleted it by name, and `_next_archive_chunk` and
  `_archive_fully_covered` read it as the new partition's coverage, so `retire()` could drop rows nothing had
  archived. `retire()` now marks the chunks of the partition it drops (`pgpm.archive_ledger.retired_at`, new,
  backfilled on upgrade from the `retain_drop` rows in `pgpm.log`), no reset site discards a marked row, no
  coverage reader counts one, and the archive step (and `scripts/archive_partition_whole.sql`) leaves a
  partition over a retired chunk's range out of its candidates, logged once as `skip_archive_retired_range`
  with the remedy, archiving the parent's next partition in the same tick; `retain()` leaves it out of its
  batch too. A chunk now records the relation it was read from (`pgpm.archive_ledger.child_oid`, new,
  attributed on upgrade only to a write-blocked relation `pgpm.part` records for its name, every other
  pre-existing chunk marked retired): the coverage readers match it by that oid, so a same-named successor inherits
  nothing, and every reset site marks retired (`archive_chunk_retired`), never discards, the chunks of a
  relation dropped outside `retire()`. Tests `tests/309` and `tests/archive/db/50`; guard
  `bench/archive_retired_chunk_kept.sh`, mutations `archive_retired_orphan_discard`,
  `archive_retired_adopt_discard`, `archive_retired_retire_discard`, `archive_retired_write_block_discard`,
  `archive_retired_regrain_swap_discard`, `archive_retired_regrain_rename_carried`,
  `archive_retired_coverage_counted`, `archive_retired_next_chunk_resumes`, `archive_retired_reoccupied_archived`,
  `archive_retired_unmarked`, `archive_retired_backfill_untimed`, `archive_gone_step_discard`,
  `archive_gone_retire_discard`, `archive_gone_write_block_discard`, `archive_gone_swap_discard`,
  `archive_gone_adopt_discard`, `archive_successor_coverage_counted`, `archive_successor_next_chunk_resumes`,
  `archive_ledger_oid_unrecorded`, `retain_held_partition_attempted`, `archive_ledger_oid_backfill_unanchored`,
  `archive_ledger_backfill_gone_kept`, `archive_ledger_backfill_namesake_kept`,
  `archive_ledger_backfill_unanchored_kept`, `archive_gone_null_oid_kept`, `archive_retired_rename_remedy_unnamed`,
  `archive_retired_unnamed_raises`, `archive_ledger_backfill_unblocked_attributed` and `archive_retired_orphan_delete_unfiltered`.

- **A synchronous export keys and claims the relation it resolved, by oid** (#1064). `archive._resolve_child`
  resolves and holds the export's child and returns its regclass, but `archive.to_s3` and
  `archive.to_s3_parquet` handed `archive._child_object_key` the child's NAME, and `archive._owned_key` looked
  it up again in the parent's current schema for the key and for the claim. The hold is on the child only, so
  `ALTER TABLE <parent> SET SCHEMA` inside the export had the resolved relation's rows keyed and claimed as a
  same-named table in the destination schema, whose own later export passed that claim and PUT over the only
  copy. Both functions now take the regclass, the key spells the relation's own schema and name read off its
  oid, and the claim records it. A static check, `scripts/check_archive_child_by_oid.py` (the `Archive object
  keys` lint job), refuses any relname compared, any child name used except to resolve or report it, and any
  `to_regclass()` of a computed name outside `archive._resolve_child`; its selftest carries the pre-fix
  `_owned_key` verbatim. Test `tests/archive/db/49`, guard `bench/archive_key_by_resolved_oid.sh`, mutation
  `archive_owned_key_resolves_by_name`.

- **The retain horizon never lands past `now()` in a fall-back hour** (#627). `_retain_boundary` and its twin
  in `regrain_step` took the whole retain off the wall clock in `partition_tz` and converted the result back
  with `at time zone`, which resolves an ambiguous wall time to its later instant: at 01:30 EDT on the first
  pass through the repeated hour, retain `'0'` gave 06:30Z, an hour past `now()`, so on an hourly grid
  `retain()` dropped the partition taking writes with its rows, and `regrain_step` discarded the same
  sub-range as aged at its swap. Both now call one helper, `_retain_horizon`: the retain's calendar part
  (months and days) is still taken on the wall clock (#455), its time part is subtracted from the instant,
  and a retain with no calendar part takes no wall-clock round trip at all. Guard
  `bench/retain_horizon_ambiguous_wall_time.sh` (`tests/311`: five clocks, four retains, hourly and daily
  grids, and a regrain), mutation `retain_horizon_wall_round_trip`.

- **A transmute claim taken under `SET ROLE` records its owner's identity** (#771 bullet 3). The claim insert
  read the session's `backend_start` from `pg_stat_activity` as the current role, which masks the session's
  own row under `SET ROLE` to a role that is not a member of the session user, so the claim recorded NULL:
  after a cutover failure the owning session's re-run was refused as "already in progress in another session"
  until it disconnected, and a `maintain_all` run by a role that could see `backend_start` read the
  still-connected owner as dead and undid its bound. The claim now takes the start from
  `pgpm._own_backend_start()`, which falls back to a `SECURITY DEFINER` read of the caller's own row only, and
  `transmute` refuses up front when even that cannot see it; `_session_alive` judges the caller's own pid by
  that same identity and reads a NULL start as dead from any role. Guard
  `bench/transmute_claim_owner_under_set_role.sh` (tests/310), mutations `transmute_claim_owner_start_masked`,
  `session_alive_self_masked` and `transmute_claim_without_identity`.

- **The liveness witnesses of eight shell guards print as lines `discriminate.sh` reads as premises**
  (#1095). Its starved-fixture rule (#713) refuses a mutant run whose every failure begins `LIVENESS:`,
  `GUARD:` or `fixture:`, reading only the head of each FAIL line, but `maintain_lock`,
  `obtain_backoff_headroom`, `obtain_int_ceiling`, `frontier_drought`, `archive_lz77_memory`,
  `archive_deflate_memory`, `archive_encode_memory` and `dropped_fk_identity` printed the checks their own
  headers call witnesses with no prefix, two of them behind a `<table>:` tag, so a mutant that starved one
  (retain deferred to `skip_retain`, a lock race never lost, a probe that sampled nothing) was certified as
  catching its defect. Those witnesses now lead with `LIVENESS:`; the archive guards' result checks
  ("returned a Parquet file", "raised no ERROR") stay unprefixed, because they are the only checks the #912
  and #992 mutants fail. Guard `bench/liveness_witness_labels.sh` renders each listed witness and defect check
  through its guard's own `check()` and applies `discriminate.sh`'s own `starved()` to it, and holds every
  `bench/*.sh` to a LIVENESS prefix at a label's head; mutations `witness_label_unprefixed` and
  `witness_label_prefix_behind_tag`.

- **The archive_fn S3 test reads its Parquet objects back** (#1093). `tests/archive/db/08` promised that the
  uploaded object is fetched back from MinIO and checked, and did that for NDJSON only: its Parquet checks read
  the ledger's `rows_archived`, the key's suffix and the ETag, so it stayed green against a transport that
  uploaded the 4-byte magic `PAR1` and recorded 5000 rows. Each Parquet object it makes (Part B's three ledger
  chunks, Parts C and D's direct calls) is now fetched back and compared, byte for byte, with the file of the
  rows its range holds. Guard `bench/archive_fn_s3_readback.sh`, mutation `archive_fn_parquet_readback_trusted`.

- **The retention-aware regrain test names the rows it keeps** (#1092). `tests/07` checked that the aged rows
  were gone, the copy count, the `regrain_aged` rows and that the fine children exist, so a regrain that lost
  every row of `[30000, 60000)` passed all six assertions. Its rows now carry their own payloads and the file
  compares every row from 30000 up with a snapshot taken before the regrain, by `(id, payload)`. Guard
  `bench/tests_fail_on_defect.sh` (a swap that loses 50000 and holds 50001 in its place), mutation
  `retain_regrain_survivors_unnamed`.

- **The hypertable cutover test asserts each scratch object dropped** (#1091). `tests/timescale/db/33`
  asserted the tracked copy's delta table and capture function gone with one null-concatenated expression,
  which passes as soon as either is gone, so a cutover that left `hg33_pgpm_delta_fn()` in `public` passed. It
  now asserts each absence on its own, beside a witness (an event trigger) that the copy minted both. Guard
  `bench/tests_fail_on_defect.sh`, run by the timescale track on its own container (a cutover that keeps the
  capture function), mutation `hypertable_cutover_capture_fn_drop_concatenated`.

- **The archive object-key lint follows the prefix column however it is quoted** (#1094).
  `scripts/check_archive_object_keys.py` recognised the prefix by its token's spelling, and its lexer kept a
  double-quoted identifier's quotes, so a second object key assembled from `cfg."prefix"`, the same column as
  `cfg.prefix`, passed it. The lexer now emits each identifier as the name it denotes (a bare part case-folded,
  a quoted part unquoted when it reads back as the same name, `"Prefix"` and `"a.b"` left quoted as the other
  names they are), and the prefix is matched behind any qualifier (`"Cfg".prefix`, `archive.config.prefix`).
  The module reads exactly as before (18 prefix references, one owner). Guard
  `bench/lint_value_not_spelling.sh`, mutation `archive_keys_quoted_ident_spelled`.

- **The `_q` lint types a local by its declared type** (#1096). `scripts/check_quoted_splices.py` took all the
  text after a local's name as its type, with only a `:=` initialiser set aside, so a quoted list declared
  `text default ''`, `text not null := ''` or `constant text` was never a `text` local and neither check judged
  it. CONSTANT, COLLATE, NOT NULL and the initialiser (`:=`, `=` or DEFAULT) are now set aside first. Guard
  `bench/lint_value_not_spelling.sh`, mutation `quoted_splices_type_rest_of_decl`.

- **The `_q` lint reads every assignment** (#1031, bullet A1031-3). `scripts/check_quoted_splices.py` read an
  assignment only where it began its own line, so `if p then v_cols := quote_ident(c); end if;` and a DECLARE
  initialiser `v_cols text := quote_ident(c)` were never judged. A body assignment is now read wherever a
  statement starts (the start of the body, after `;`, `begin`, `then`, `else` or `loop`), and every initialiser
  is an assignment for both checks, so a `_q` local initialised to `''` is refused as `v_q := ''` already was.
  The three install files judge 42 more assignments, none of them a violation. Guard
  `bench/lint_value_not_spelling.sh`, mutations `quoted_splices_assign_line_anchored` and
  `quoted_splices_initialiser_unread`.

- **A bound refusal offers a smaller step only when one would work** (#1088). `_control_bound_contract`'s
  refusal of a fresh monolith bound the `id` column cannot store always ended "or use a smaller step", also when
  the newest key was the type's maximum (`9999` on a `numeric(4,0)` key): the bound's `hi` is the grid line
  above it, `10000` or past it whatever the step, so an operator who re-ran with step 1 was refused on the same
  bound. The refusal now works out the bound the finest step the column admits would give (step 1, or the
  column's unit on a negative-scale `numeric`, with the same `p_bound_headroom`), offers a smaller step and
  names that bound only when the column's type can store it, and otherwise says no smaller step avoids it and
  names a wider type alone. Test `tests/305`, guard `bench/bound_contract_remedy.sh`, mutations
  `bound_contract_finest_step_unchecked`, `bound_contract_finest_step_headroom` and
  `bound_contract_finest_step_unit_one`.

- **The docs no longer say a `maintain` pass obtains** (#1087). README.md called `maintain` "the one procedure
  `pg_cron` calls (`obtain`, `retain`, optional auto-`regrain`)" and docs/runbook.md's retention entry annotated
  `call pgpm.maintain(...)` as "one pass: obtain, archive, retain", while obtain has been `maintain_obtain`'s, on
  its own `pgpm_obtain` job, since #347, and `maintain` builds no forward partition: an operator who scheduled
  or ran `maintain` alone ran out of grid and had writes refused. Both now say `maintain_obtain` obtains and
  `maintain` runs the rest. Guard `bench/doc_maintain_does_not_obtain.sh` measures `maintain` and `maintain_all`
  building no cell while `maintain_obtain` builds the due ones, then reads every sentence and fenced line of
  the docs for a claim that `maintain` obtains; mutation `readme_maintain_obtains`.

- **The documented install command stops at the first error** (#1090). README.md, docs/guide.md,
  pgpm_archive/README.md and the site's index.html gave `psql "$DATABASE_URL" -f pgpm_core/install.sql` with no
  `ON_ERROR_STOP`, so an upgrade that met `_surface_prepare()`'s refusal ("Nothing has been changed") ran the
  rest of the file anyway: it dropped the columns the file retires, passed over `_surface_settled()`'s error,
  recorded the new version over a half-upgraded install and exited 0. The core command is now
  `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --single-transaction -f pgpm_core/install.sql` (the file has no
  top-level `COMMIT`, so one transaction makes a run all or nothing), and the module and ONBOARDING commands
  carry `-v ON_ERROR_STOP=1`. Guard `bench/doc_install_stops_on_error.sh` runs each documented command's flags
  over a script that fails in its middle and, for the core command, over an install that has to refuse;
  mutation `readme_install_runs_past_error`.

- **`maintain` leaves a partition detached by hand alone** (#705, bullets 1 and 2). `_enforce_write_blocks`,
  `_archive_step` and the auto-regrain candidate scan read `pgpm.part.attached`, which an operator's own
  `DETACH PARTITION` never touches, so once retention reached a table the operator had detached to keep, a
  tick put `pgpm_write_block` on it and every write to it was refused "past its retention boundary"; a table
  detached after pgpm had blocked it was handed to the archive strategy and had coverage recorded for it; and
  a detached coarse child, being the oldest, was picked for auto-regrain, got the capture and `TRUNCATE`
  guard, had its rows copied and then failed every swap, wedging auto-regrain on it. `retire` already refused
  such a table (#652). All three now ask `pgpm._part_detached_by_hand`, built on `_part_built` (and
  `progress().coarse_frozen` mirrors the scan): a child whose table exists, is not a partition of the parent
  and carries no `retiring_at` is skipped, and its row stays for `retire` to refuse and log. A regrain
  already in flight when its source is detached by hand is ended by the next tick's janitor, scoped to that
  source as `retire`'s reclaim is (triggers off the operator's table, copies dropped, delta emptied, cursor
  cleared), and logged with the new action `regrain_source_detached`. A partition `retire` is detaching
  concurrently stays pgpm's, and one dropped by hand still logs `skip_write_block`. Test `tests/307`, guard
  `bench/write_block_skips_hand_detached.sh`, mutations `write_block_trusts_part_attached`,
  `archive_trusts_part_attached`, `regrain_trusts_part_attached`, `progress_coarse_counts_hand_detached`,
  `regrain_detached_source_orphaned`, `regrain_detached_logged_as_cancel`,
  `detached_by_hand_ignores_retiring_at`, `detached_by_hand_counts_dropped`.

- **`pgpm.adopt_partition` repairs an identity wedge without orphaning the partition** (#1082). A partition
  restored from a dump under its own name is a new oid, which the write-block, archive and retire steps refuse
  on identity, and the documented repair (delete the stale `pgpm.part` row) cleared the wedge and nothing else:
  the restored relation stayed attached with its rows and recorded by nothing, so retention marched past it,
  its rows outlived the policy for good, and `status().n_partitions` stopped counting it. The new
  `pgpm.adopt_partition(parent, partition)` records an attached partition by its oid: a stale row of the same
  name over the same range is re-anchored, and a partition with no row is recorded afresh over its catalog
  bounds (read the same way under any `DateStyle` or `TimeZone`). Archive coverage recorded under the name is
  discarded (`archive_coverage_reset`), since the relation that earned it is gone, and the call is logged
  `adopt_partition`. It refuses a parent pgpm does not manage, a relation not attached to it, one already
  recorded, a same-named row over another range or with a retirement or regrain in flight, a range another row
  records, and bounds the grid cannot express. The runbook, the reference and the guide now give it as the
  repair, and say to detach a relation pgpm should not manage before deleting its row. Test `tests/303`, guard
  `bench/adopt_partition.sh`, mutations `adopt_partition_keeps_stale_oid`, `adopt_partition_records_nothing`,
  `adopt_partition_credits_old_coverage` and `adopt_partition_unlocked`.

- **A re-run of `from_hypertable_copy` replaces the previous copy by its record, wherever it lives** (#1083).
  The re-run replaced the copy, delta and capture function `pgpm.scratch` recorded only while they sat under
  the names it mints in the hypertable's current schema. After `ALTER TABLE <hypertable> SET SCHEMA` (when the
  cutover finds no copy and names this re-run as the remedy) a tracking re-run died raw 42710 on the capture
  trigger the table carried with it, which `_from_hypertable_scratch_check` had accepted as recorded, and either
  re-run left the previous copy, a full second copy of the rows, in the old schema with its record overwritten;
  one without tracking also left the old capture firing into a delta nothing recorded. A RENAME of the
  hypertable left the previous apparatus the same way, under its old name. The re-run now drops each recorded
  object by its oid, and the hypertable's triggers firing the recorded function, so every name the check lets
  through is free when the copy mints it. Test `tests/timescale/db/60`, guard
  `bench/hypertable_copy_rerun_by_record.sh`, mutations `hypertable_copy_rerun_capture_by_name`,
  `hypertable_copy_rerun_delta_by_name` and `hypertable_copy_rerun_dest_by_name`.

- **A refused hypertable handoff no longer loses the retention it carried** (#1079). When
  `from_hypertable_cutover`'s handoff to `transmute` refused after the swap had committed, the reference's
  remedy (fix what the refusal names, call `pgpm.transmute` on the table) registered the table with no
  retention: the interval the cutover carried in (`p_retain`, or the source's `drop_chunks` policy interval)
  lived only in a plpgsql local, and the hypertable and its policy job went with the swap. The swap now records
  it in a new table, `pgpm.handoff`, against the table it puts in place, and `transmute` called on that table
  with `p_retain` null takes it (an explicit `p_retain` still wins); registration deletes the record. Test
  `tests/timescale/db/59`, guard `bench/hypertable_handoff_remedy.sh`, mutations
  `hypertable_handoff_retain_unrecorded` and `transmute_handoff_retain_unread`.

- **The refused-handoff remedy in the reference re-adds the incoming keys** (#1089). It promised the next
  maintenance tick would re-add the foreign keys the swap dropped, but `transmute` registers the table paused
  by default and `maintain` returns `paused` before its restore step, so referential integrity stayed off until
  someone called `restore_incoming_fks` by hand. The reference now gives the remedy as the three calls the
  cutover makes after its swap (`transmute`, `restore_incoming_fks`, `validate_incoming_fks`), and the guard
  runs that block verbatim. Test `tests/timescale/db/59`, guard `bench/hypertable_handoff_remedy.sh`, mutation
  `reference_handoff_remedy_without_restore`.

- **The table's identity sequences keep their grants through `transmute` and `untransmute`** (#1076). Both
  re-add identity, which makes a new sequence, and since #877 hand it the source sequence's name, but the new
  one was born with the converting role's `ALTER DEFAULT PRIVILEGES` and none of the source's grants: the app
  lost `USAGE` and `SELECT` on `t_id_seq` (`nextval` or `currval` by name failed 42501) and a role the operator
  had revoked got `UPDATE` (`setval`) back. One helper, `_identity_acl_carry_ddl`, now builds the carry for
  both from `_acl_carry_ddl` (reset, owner included, then every table and column grant under its grantor):
  transmute reads it off each original the statement before step 3 drops it and runs it after 3a's rename,
  untransmute reads it off the parent's under its lock and runs it after the owner step. transmute's up-front
  grantor check (#903) asks about the identity sequences' grants too. Test `tests/297`, guard
  `bench/identity_sequence_grants.sh`, mutations `identity_sequence_acl_unreset` and
  `transmute_identity_seq_grantor_unchecked`.

- **`check_text_time` decodes against `p_epoch` as an instant, in every session** (#1081). It spliced the
  epoch into its dynamic query with `%L`, a text render under the session's DateStyle and TimeZone that the
  query parsed back, so under `SQL, DMY` in Asia/Kolkata the Unix epoch became `01/01/1970 05:30:00 IST`,
  read back with IST as Israel's +02: every decoded instant was 3.5 hours late (one hour early in
  Europe/Dublin), `newest_decoded` was wrong, a maximum two hours old was reported as `newest_in_future`, and
  rows near either end of the plausible window were miscounted. The epoch is now a bound parameter of that
  query, for the sample's decode and the maximum's. The misreading was measured on PostgreSQL 15 and 17; 18
  reads the session zone's own abbreviations first, so in these zones a bare render round-trips there. Test
  `tests/301`, guard
  `bench/check_text_time_contract.sh`, mutation `check_text_time_epoch_spliced`.

- **One shaped row past the decode's range no longer aborts `check_text_time`** (#1084). The shape gate bounds
  the characters, not the number they spell, so a value with the declared prefix, width and alphabet whose
  count overflowed an interval or the `timestamptz` range (nine base-36 digits of seconds is about 1e14 s)
  reached `_text_time_to_ts`, which raised `interval out of range`, and the whole report raised with it. Both
  decodes now go through `_text_time_to_ts_bounded`, which reports null for such a count: the row counts as
  implausible and such a maximum reports a null `newest_decoded`, as a value that fails the shape does. Test
  `tests/302` part A, guard `bench/check_text_time_contract.sh`, mutation `check_text_time_decode_unbounded`.

- **`check_text_time` refuses a supplied alphabet's radix below 2, as `transmute` does** (#1039, bullet 3). The
  radix floor sat only on its default-alphabet branch, so radix 1 with alphabet `x` (or radix 0 with an empty
  one) was sampled and reported where `transmute` refuses the shape (#990). Both now ask one rule,
  `_text_time_radix_floor`, naming the caller's argument (`p_radix`, `p_tt_radix`). Test `tests/302` part B,
  guard `bench/check_text_time_contract.sh`, mutation `check_text_time_radix_floor_dropped`; `tests/285`'s
  first witness now asks the shape gate and the decoder directly instead of `check_text_time`.

- **`check_text_time` refuses the width, discard bits and unit `transmute` refuses, before it reads a row**
  (#1120). It checked none of them, so `p_width` 0 (every value decodes to the epoch) and `p_discard_bits` -1
  (every count doubled, so a column of half-counts read 100% plausible) were sampled and reported on, and an
  unknown `p_unit` was refused only when a shaped value in range reached the decoder: never on an empty
  column, and, once #1084's bounded decode returned null for an overflowing count first, not on a column whose
  shaped values all overflow either (found by PR #1115's verification). The width and discard-bits rules are
  now one rule, `_text_time_shape_floor`, that `transmute` and `check_text_time` both ask, naming the
  caller's arguments; the unit is refused up front with the decoder's message. Test `tests/302` part C, guard
  `bench/check_text_time_contract.sh`, mutations `check_text_time_shape_floor_dropped` and
  `check_text_time_unit_after_decode`.
- **`from_hypertable` and its cutover ask `transmute`'s argument rules before the swap** (#1085; #966 W2).
  A negative `p_retain` or `p_obtain`, or a `p_interval` that is not positive, was refused only by
  `transmute` at the handoff, after the cutover's swap had committed and dropped the hypertable, leaving a
  plain, unmanaged table under its name (every row kept); and a negative `p_interval` met the frontier check
  first, whose limit then lay in the past, so it was refused with a remedy that said to delete the newest
  rows, or to pass `p_force_frontier`, which committed the swap. `transmute`'s three rules now live in one
  function, `pgpm._refuse_bad_transmute_arguments`, which `transmute` asks, and which `from_hypertable` asks
  before its copy and `from_hypertable_cutover` before its pre-drain, ahead of every check that reads the
  table, with `transmute`'s messages. Test `tests/timescale/db/58`, guard
  `bench/hypertable_argument_rules.sh`, mutations `hypertable_arguments_unchecked`,
  `hypertable_arguments_unchecked_up_front` and `hypertable_cutover_arguments_unchecked`.

- **A `v*` tag publishes its GitHub Release while the dbdev package is over database.dev's cap** (#1077).
  `release.yml`'s Build release assets step ran `scripts/build_dbdev_package.sh` in its default strict mode,
  never moved to `PGPM_DBDEV_CAP=warn` when #764 made the 250,000-character cap advisory on the merge path, so
  while the package is over the cap (355,712 characters today) the step exited 1 before Publish GitHub
  Release and a tag published no release at all: no bundle, no tarball, no notes. The step now builds the
  package in warn mode, as the merge gate does; the strict refusal stays in `publish-dbdev.yml`, which is
  where `RELEASING.md` puts it. Guard `bench/release_assets_over_cap.sh` (runs both workflows' build steps on
  a tree padded over the cap), mutation `release_dbdev_build_strict`.

- **The zone a grid is recorded in is never one of `pg_timezone_names`' pseudo-entries** (#1086).
  `pgpm._canonical_tz` accepted any name that view lists, and three of them are not zones: `localtime` (on a
  `--with-system-tzdata` build, a link to the host's `/etc/localtime`), `posixrules` and `Factory`. So
  `set_partition_tz(t, 'localtime')`, or a transmute under `set timezone = 'localtime'`, recorded a grid zone
  that follows whatever the host is set to, and a restore on another host moved every calendar boundary with
  nothing recorded. `_canonical_tz` now refuses those three names in any casing (and under a directory
  prefix), so both callers refuse them with a message that names the rule. Test `tests/304`, guard
  `bench/canonical_tz_pseudo_zones.sh`, mutation `canonical_tz_admits_localtime`.

- **A hole in the lookahead bypasses the obtain back-off** (#1078). After a lost lock race armed
  `config.obtain_retry_after`, `maintain_obtain` honoured the back-off while `ceil(obtain / 2)` grid steps
  past the frontier's cell were covered, and measured that by walking from the frontier's cell up to the
  highest attached `hi`, assuming the coverage was contiguous. A forward cell dropped or detached by hand
  keeps its attached `pgpm.part` row, so it counted as coverage: the next tick logged `obtain_backoff`
  instead of rebuilding it, and every write into it stayed refused for the back-off window. The walk now
  asks each step, the frontier's own cell first, the question `obtain` asks of it (`_cell_attached`, then
  `_obtain_name`: would it build that cell?), so such a hole bypasses the back-off and `obtain` rebuilds it,
  while a hole `obtain` cannot build (its name held, `fail_obtain_name`) does not, and with that many steps
  `obtain` would leave alone the back-off still holds. The walk writes nothing (its forgets are rolled
  back), so the forget rows are still logged only by `obtain` or `extend_to`, as before. Test `tests/298`,
  guard `bench/obtain_backoff_hole.sh`, mutations `obtain_backoff_counts_hole`,
  `obtain_backoff_bypasses_held_name` and `obtain_backoff_walk_commits_forget`.

- **A role that writes the table through a view can write a regraining partition** (#1073). The regrain
  capture trigger wrote its delta as the writer, and `_regrain_capture_grant` grants `INSERT` on the delta only
  to the grantees and owners of the parent and the source. A write through an ordinary view is checked as the
  view's owner, but the table's triggers fire as the session's role, so a role whose only grant was on a view
  over the table got 42501 `permission denied for table <rel>_pgpm_regrain_delta` on every write into the
  regraining partition until the swap (and on every write into a hypertable during a tracking
  `from_hypertable_copy`'s online window, on `<rel>_pgpm_delta`). Both capture functions now write their delta
  as their owner, the table's (`pgpm._capture_definer`): `SECURITY DEFINER`, owned by the table's owner as
  the delta is, `search_path` pinned to `pg_catalog, pg_temp` so a writer's own operators never run as the
  owner; `EXECUTE` keeps PostgreSQL's default, since TimescaleDB re-creates the trigger on each new chunk
  as the hypertable's owner. Only while the owner can reach the delta: an owner without `USAGE` on the
  delta's schema keeps the writer-run capture (`SECURITY INVOKER`), which captures every role granted
  `INSERT` on the delta, as before. Armed where each is minted and decided again by every regrain tick and every drain, drain step
  and cutover (`_scratch_owner_follow`), so a capture minted by an earlier release becomes
  `SECURITY DEFINER` at the first of them after the upgrade, and until then still writes as the writer; a
  `USAGE` granted to or revoked from the owner, or a delta moved into a schema the owner cannot use, takes
  effect from the next one (until then such a revoke or move refuses writes into the source). The writer
  grants are still made. The capture's lost-delta refusal now names the table schema-qualified.
  Measured on 100,000-row updates of a capturing source on PG 15: about 2 to 3 microseconds more a captured
  write (the pinned `search_path`; the definer switch alone measured no difference). Tests `tests/294` and
  `tests/timescale/db/61`, guard
  `bench/regrain_capture_view_writer.sh`, mutations `capture_definer_dropped`,
  `capture_definer_search_path_unpinned`, `capture_definer_execute_owner_only`, `capture_definer_not_rearmed`,
  `capture_definer_owner_reach_unchecked` and `capture_definer_reach_by_fn_schema`.
  `capture_definer_search_path_unpinned`, `capture_definer_execute_kept`, `capture_definer_not_rearmed` and
  `capture_definer_owner_reach_unchecked`.
  `capture_definer_search_path_unpinned`, `capture_definer_execute_kept` and `capture_definer_not_rearmed`.
- **The archive contract holds an `id` grid's `covered_hi` to the control column's own type** (#1071).
  `pgpm._archive_contract_breach` judged it as `numeric` only, so a resumable strategy returning
  `(lo + hi) / 2` on a `bigint` key had `22.5000000000000000` (or `15000.0000000000000000`) recorded, and
  every later tick's `_next_archive_chunk`, which compares the column with the ledger's `hi` as a literal,
  raised `invalid input syntax for type bigint`, logged `skip_archive`: the partition was never archived
  further or retired, and pointing `pgpm.set_archive_fn` at a corrected strategy did not recover it. The check
  now also requires the value to survive a round trip through the control column's base type (a fraction on
  an integer key is refused, `fail_archive_contract`, nothing recorded; a fraction on a `numeric` key is
  still a value of the column), and the ledger records an `id` value at its least scale (`15000`), so an
  integral value written with a scale is the whole number it is. One check, so `_archive_step` and
  `scripts/archive_partition_whole.sql` both apply it; the function now takes the parent
  (`pgpm._archive_contract_breach(parent, kind, lo, hi, covered_hi)`, the four-argument form dropped). A
  ledger row an earlier install already recorded with such a value is not rewritten and still fails each
  tick; `docs/reference.md` gives the one-statement repair for an integer key. Test `tests/292`, guard
  `bench/archive_covered_hi_column_type.sh`, mutations `archive_covered_hi_scale_kept` and
  `archive_contract_column_type_unchecked`.

- **A cell whose own label makes its plain name too long is a hole, not the end of the tick** (#1072).
  An id label widens from 19 to 20 digits at 10^19, so on a `numeric` key a 42-byte table name fits every cell
  below that edge and none past it. `_obtain_name` caught `_part_name`'s over-63-byte refusal only for the
  explicit-range stand-in (#663); the plain name's refusal escaped, and `obtain` and `extend_to` are single
  functions, so the first unnameable cell unwound the whole call on every tick (`skip_obtain`) and the cell
  `[9.9e18, 10^19)` below it, whose name fits, was never built and refused every write. Such a cell is now left
  unbuilt and logged `fail_obtain_name` (its `method` gives the name, its length and the bytes to shorten by),
  and the cells that fit are built, by both callers. A table whose name fits not even the grid's ordinary
  label (renamed after `transmute`) is still refused, as before. Test `tests/293`, guard
  `bench/obtain_plain_name_too_long.sh`, mutations `obtain_plain_name_uncaught` and
  `obtain_plain_name_caught_always`.

- **transmute refuses an anchor off 00:00 UTC on a `date` key** (#769, last bullet). #581 held a `date` key's
  step to whole days and never its anchor, and `_time_unit_breach` returned nothing for a `date`, so an anchor
  at noon converted with every `pgpm.part` bound at noon while the catalog attached each partition at its
  whole date (a row dated a partition's first day lay outside its recorded range, and `extend_to` reported
  cells built while the write of the date it was asked for was refused), and `'2024-01-01'` typed in a New
  York session (05:00 UTC) committed a bound `CHECK` whose `VALIDATE` died on the table's own newest row,
  leaving it and the claim rejecting every later write until `transmute_abort`. `_time_unit_breach` now knows
  a `date`: its unit is one day and the anchor must be at 00:00 UTC, the lattice a date's grid is computed on
  (#504), asked through `_time_unit_contract` before anything is committed, with a message naming the
  session's zone and the remedy. Test `tests/306`, guard `bench/date_key_anchor_midnight.sh`, mutation
  `date_anchor_unchecked`.

- **An archive_fn strategy compares a recorded chunk's rows by identity, not by count** (#1069).
  `archive._refuse_recorded_chunk_overwrite` (#975) admitted a write at a key `pgpm.archive_ledger` records a
  chunk at when the range matched and the read's row count equalled `rows_archived`, so after `retire()`
  dropped the chunk's partition a partition re-created over the range by plain DDL, holding as many rows as
  the chunk did but other ones, had a direct `pgpm.archive_to_s3_ndjson` or `pgpm.archive_to_s3_parquet` call
  PUT them over the only copy with 200. Every write either strategy makes now records a digest of the rows
  it wrote on the key's whole-key claim (`archive.object_key_claim.rows_digest`: the md5 of the sorted md5s of
  each row's JSON text, rendered under pinned TimeZone, DateStyle, IntervalStyle, extra_float_digits,
  bytea_output, lc_monetary and search_path, taken in the read that produced the object's rows: the NDJSON
  statement itself, the Parquet encoder's snapshot), and a write at a recorded chunk's key is refused unless
  its read's digest is the recorded one. A chunk claimed before the column existed records none and can no
  longer be re-run. The refusal also locks the key's claim row before it reads the ledger, so a direct call
  made while a tick is archiving the same chunk (its ledger row not yet committed) waits for the tick and is
  then judged against the chunk it recorded; it used to find no ledger row and PUT a shorter range over the
  chunk after the tick's own PUT. The synchronous exports write export keys the ledger never records, so they
  are unaffected. Test `tests/archive/db/48`, guards `bench/archive_recorded_chunk_rows_identity.sh` and
  `bench/archive_recorded_chunk_tick_race.sh`, mutations `archive_recorded_chunk_identity_unchecked`,
  `archive_recorded_chunk_identity_unrecorded`, `archive_row_digest_session_zone`,
  `archive_row_digest_search_path`, `archive_pq_row_digest_alias_shadowed`,
  `archive_ndjson_row_digest_alias_shadowed` and `archive_recorded_chunk_claim_unlocked`.

- **A regrain reconcile tick applies and consumes only the delta rows it judged eligible** (#1070, Tier 1).
  `_regrain_reconcile` cut its batch from the eligible rows (keys in a sub-range the copy has finished) and
  then addressed it, in every later statement, by those rows' `pgpm_seq` values. `pgpm_seq` is not unique,
  and every writer of the table holds `INSERT` on the delta (the capture trigger writes it as the writer),
  which allows `OVERRIDING SYSTEM VALUE`, so a role with `INSERT` alone put a key from the sub-range still
  being copied on an eligible row's `pgpm_seq`: the tick wrote it into that half-copied sub-range, the copy
  resumed above it, and the swap dropped the rows it skipped with the source. The batch is now addressed by
  the rows themselves (their tuple identities, read in the snapshot that judged them, with their `pgpm_seq`
  values beside them only for the index), so a row the tick did not judge is neither applied nor consumed,
  whatever `pgpm_seq` it carries. And the swap gate's purge now discards every delta row no reconcile could
  consume: it deleted `not (<control> in range)`, which is `NULL` for a row whose control value is `NULL`, so
  a writer that put more such rows in the delta than the batch held the regrain at `reconciling:N` on every
  tick after the copy finished, until `regrain_cancel`. It deletes the rows whose range test is not true, and
  logs what it discards as `regrain_delta_purge`. Test `tests/291`, guard
  `bench/regrain_reconcile_judged_rows.sh`, mutations `regrain_reconcile_batch_by_seq` and
  `regrain_delta_purge_null_blind`.

- **A regrain on a `uuidv7` or `text_time` key stays on the encoding's unit** (#1039, bullet 2).
  `_regrain_step_shape` held a target to a `timestamp(p)` column's precision (#980) and asked nothing of an
  encoded key, so `'1.5 seconds'` on an ObjectId key (unit a second) or `'1500 microseconds'` on a `uuidv7` key
  (unit a millisecond) was accepted: the copy encoded each fine bound by flooring it to the unit while the
  reconcile placed a captured change by the unfloored grid, so a row deleted mid-regrain was consumed against
  the wrong copy and the swap brought it back. The same rule now asks the precision the encoding keeps (a
  millisecond for `uuidv7`, the `text_time_unit` for `text_time`) of the target and of the grid's registered
  `partition_anchor` and `partition_step`, so `set_regrain`, `regrain_step`, `regrain()`, `regrain_history()`
  and every tick refuse a target that is not whole units, and any target on a grid an older install
  registered off the unit, before anything is copied. `transmute` now holds a `uuidv7` step and `p_anchor` to
  whole milliseconds, as it holds a `text_time` key's to its unit (#989), so no such grid is registered again
  (#1113: a `'500 microseconds'` step had committed and validated the monolith's bound CHECK and then died at
  the cutover on `empty range bound`, leaving the table rejecting current writes). Test `tests/308`, guard
  `bench/regrain_target_encoded_unit.sh`, mutations `regrain_step_unit_uuidv7_unasked`,
  `regrain_step_unit_text_time_seconds_unread`, `transmute_uuidv7_anchor_unasked`,
  `transmute_uuidv7_step_unasked`, `regrain_step_registered_anchor_unasked` and
  `regrain_step_registered_step_unasked`.

- **A regrain's fine children are created in the parent's tablespace** (#1075). `regrain_step` creates each
  fine child as a standalone `CREATE TABLE (LIKE ...)`, which carries no tablespace, and named none, so after a
  regrain of a table `transmute` had placed in its own tablespace the fine children, and every row the regrain
  moved into them, were in the database default, where the documentation promises every partition pgpm mints
  lands in the table's. The create now names the parent's tablespace, read when the fine child is created, the
  one `_create_partition`'s `PARTITION OF` takes for obtain and `extend_to`; a parent in the database default
  leaves the create as it was. The role that drives a regrain therefore needs `CREATE` on that tablespace, as
  the maintenance role already did for obtain. Test `tests/296`, guard `bench/regrain_children_tablespace.sh`,
  mutation `regrain_children_tablespace_dropped`.

- **A table whose key has a column named `pgpm_seq` can be regrained** (#1074). Both change-capture deltas
  (the regrain's, and `from_hypertable_copy`'s with `p_track_changes`) are minted from the key's columns and
  then given an ordering identity column under the fixed name `pgpm_seq`, so a key with a column of that name
  failed the prepare tick 42701 (column already exists) on every call: `regrain()`, `regrain_history()` and
  auto-regrain could never make progress on a table transmute had accepted, and such a hypertable could not be
  tracked. The ordering column is now minted under a name no column of the delta holds (`pgpm_seq`, else
  `pgpm_seq_1`, `pgpm_seq_2`, ...; `pgpm._delta_seq_add`), and every reader finds it as the delta's identity
  column (`pgpm._delta_seq`) rather than by name: the regrain reconcile, the drift check (which by name dropped
  the key's own `pgpm_seq` and would have restarted the run every tick), the hypertable drains and the
  cutover. A delta an earlier release minted carries `pgpm_seq` as its identity column and reads the same.
  Tests `tests/295` and `tests/timescale/db/62`, guard `bench/regrain_delta_seq_name.sh`, mutation
  `delta_seq_fixed_name`.

- **`transmute` refuses a table or type created at its staging name while it runs** (#1080, #1105 bullet 1).
  The staging name `<table>_pgpm_new` was asked to be free (as a relation, and as a type) in the preflight
  only, so a table or a type committed at it after the preflight, while phases 1 and 2 had let go of the
  table, made the cutover's `CREATE TABLE ... LIKE` die raw (42P07 'relation ... already exists', 42710 'type
  ... already exists') after phases 1 and 2 had committed the write-rejecting bound and the claim; one that a
  transaction was still creating when the cutover reached it made the `CREATE` wait and die with 23505 on
  `pg_type_typname_nsp_index` once that committed. The `CREATE` now asks the preflight's check
  (`_transmute_refuse_staging_squatter`) again from its own failure, when the holder is committed and
  visible, and refuses in the preflight's words with its remedy; the refusal rolls the cutover back to the
  resumable phase-2 state. The rule is general: each of the cutover's three naming statements (the staging
  `CREATE`, the `RENAME` to the monolith's name, the `RENAME` of the new parent to the table's name) asks,
  from its own failure (42P07, 42710, 23505, or XX000 'tuple concurrently updated'), every name it takes:
  each relation name, its row type, its array type `_<name>`, and the table's own array type, and names
  whatever holds one, another type's implicit array type included (`_transmute_refuse_names_held`;
  mutations `transmute_create_held_names_unchecked`, `transmute_rename_held_names_unchecked`,
  `transmute_final_rename_unhandled`, `transmute_own_array_unchecked`). That second asking, like the monolith `RENAME`'s and step 7c's below, needs a
  snapshot taken after the wait, so `transmute` now refuses up front, before anything is committed, when the
  calling transaction or the session's `default_transaction_isolation` is stricter than READ COMMITTED, as
  `untransmute` does, and so do `from_hypertable` (before its copy) and `from_hypertable_cutover` (before its
  swap), which hand off to transmute only after the swap has dropped the hypertable. `tests/299` (new) under
  the guard `bench/transmute_cutover_names_held.sh`, mutations `transmute_staging_name_preflight_only` and
  `transmute_isolation_unchecked`; `tests/timescale/db/63` (new) under the guard
  `bench/hypertable_isolation_refused.sh`, mutations `from_hypertable_isolation_unchecked`,
  `from_hypertable_cutover_isolation_unchecked` and `hypertable_isolation_unchecked`.

- **`transmute` refuses a table or type created at the monolith's name while it runs** (#1104). The name the
  cutover renames the table to, `<table>_p<lo>_to_<hi>`, was asked to be free in phase 1's transaction only,
  so a table or type that held it by the time of the cutover's `RENAME`, committed after that asking or
  created by a transaction still open, made the `RENAME` die raw (42P07, 42710, or 23505) after phases 1
  and 2 had committed the bound and the claim. The `RENAME` now asks phase 1's check
  (`_transmute_refuse_monolith_squatter`) again from its own failure and refuses in its words. `tests/299`
  under the same guard; mutation `transmute_monolith_name_preflight_only`.

- **`transmute` refuses a publication change made while it runs that the cutover cannot carry** (#766 bullet
  4, #1105 bullet 2). The publication refusals (a row filter or a column list without
  `publish_via_partition_root`, and a publication the caller does not own) were asked in the preflight only,
  so a publication change committed after it (a filtered or unowned membership added while phases 1 and 2
  had let go of the table, or `publish_via_partition_root` turned off, or the publication handed to another
  role, which take no lock on the table and so can land inside the cutover while it waits on a referenced
  table) made step 7c's `ALTER PUBLICATION ... ADD TABLE` die raw ('cannot use publication WHERE clause for
  relation', 'must be owner of publication') after phases 1 and 2 had committed the bound and the claim.
  Step 7c now asks the preflight's check (`_transmute_refuse_publications`) again from its own failure and
  refuses in the preflight's words; the refusal rolls the cutover back to the resumable phase-2 state.
  `tests/300` (new) under the guard `bench/transmute_publication_change_refused.sh`; mutation
  `transmute_publication_preflight_only`.

- **A synchronous export resolves its child under one catalog snapshot** (#1062, bullet 2).
  `archive._resolve_child` read the parent's schema name in one statement and looked the child up by that
  name in the next, so a second session that swapped two schemas' names between them (the parent's schema
  renamed away, another given its name) had it resolve, hold and return the namesake in the schema that took
  the name: the `pgpm.part` anchor refused that for a recorded child, but for a relation `pgpm.part` has no row
  for, which the synchronous functions accept, `archive.to_s3` exported the namesake's rows under the named
  relation's key with no error. It now reads the schema and the child in one statement, joined through the
  parent's `relnamespace`, and checks after its by-name `LOCK` by identity that this backend holds that very
  relation; a lock the swap sent to a namesake is retried, and refused after three tries. Test
  `tests/archive/db/47`, guard `bench/archive_resolve_child_one_snapshot.sh`, mutation
  `archive_resolve_child_two_statements`.

- **Both change captures write their delta only while they hold it** (#1057, bullet 3). #1051 (regrain,
  `_regrain_capture_install`) and #1037 (`from_hypertable_copy`'s tracking copy) kept a fast path that checked
  the minted name with `to_regclass`, which takes no lock, and then ran the static insert, which looked the
  name up again after queueing on the delta's lock. A write that arrived while an operator's transaction held
  the delta to rename it passed the check, waited, and once the rename committed put its keys into whatever
  held the name by then: a table the operator created under the freed name in the same transaction (the swap
  never reads it, so a committed regrain update was reverted; the hypertable cutover refused its swap), or
  nothing, and the write died 42P01. Each capture now takes `ROW EXCLUSIVE` on the delta through the name it
  is about to use and writes through that name only if, with the lock held, it still leads to the recorded
  oid, so a rename, move or drop of the delta waits for the writer; a lock that landed elsewhere, or was
  refused, sends it to the delta's current name, locked and re-checked the same way. Measured on 100,000-row
  updates on PG 15: about 1 microsecond more a captured write on the fast path (4.6 to 5.5), and no change
  after a rename (about 10.5). Tests `tests/290` and `tests/timescale/db/57`, guards
  `bench/regrain_capture_delta_held.sh` and `bench/hypertable_capture_delta_held.sh`, mutations
  `regrain_capture_fast_path_unlocked` and `hypertable_capture_fast_path_unlocked`.

- **A Parquet export reads the relation it was handed, never a namesake** (#1055, bullet 1).
  `archive._pq_to_parquet` and the range encoder took a schema and a name from the relation's oid before their
  column loop, and `archive._pq_snapshot` read the rows by that name after it. `ALTER SCHEMA ... RENAME` takes
  no lock that conflicts with the hold `archive._resolve_child` takes, so a second session that swapped the
  child's schema with another holding a same-shaped table of the same name, committed in between, had
  `archive.to_s3_parquet` PUT the namesake's rows under the child's key with no error (21 of 40 tries at 1500
  columns). `archive._pq_snapshot` now takes the relation as a regclass and renders it in the statement that
  reads it (`archive._pq_from_relation`), after taking its snapshot table's ROW EXCLUSIVE so the INSERT's parse
  takes no new lock, and with it no catalog change, between the rendering and the lookup. That narrows the
  window and does not close it (the reproduction still reached the namesake in 3 of 400 tries), so the read is
  then checked: `archive._refuse_foreign_read` compares the relations the read newly locked with the one it
  was handed, its descendants, their indexes and TOAST tables, and refuses before anything is written when the
  read reached any other, or any relation but the one handed that carries its name (a descendant attached
  under the parent's name in another schema is where a swap can send a range read, and that partition is
  refused whenever a range read reaches it). Under the reproduction's continuous swaps 7 of 600 exports were refused and none
  exported the namesake. The automatic NDJSON strategy's read (`archive._encode_upload_ndjson_single`) took
  its name the same way and now renders the regclass and is checked the same way.
  Test `tests/archive/db/46`, guard `bench/archive_parquet_read_by_regclass.sh`, mutations
  `archive_pq_snapshot_reads_by_name`, `archive_pq_snapshot_render_only`,
  `archive_pq_snapshot_render_before_news`, `archive_read_witness_inert`,
  `archive_read_witness_descendants_admitted`, `archive_pq_snapshot_sampled_after_read` and
  `archive_ndjson_single_unchecked`.

- **Regrain's change capture writes its delta by the oid the prepare tick recorded** (#1051). The reconcile,
  the swap gate, the swap and `regrain_cancel` have found the delta by `pgpm.config.regrain_delta_oid` since
  #496, but the capture function `_regrain_capture_install` minted inserted into `<rel>_pgpm_regrain_delta`
  by name, so renaming the recorded delta mid-regrain refused every write into the regraining partition
  (42P01) for the life of the regrain, and a table created under the freed name took the captured keys, which
  the swap never read. The function keeps its static insert only while the minted name still leads to the
  recorded oid (still the body the #969 upgrade proof recognises); once it does not, it renders the oid to the
  delta's current name and inserts through it dynamically, the key values bound, and a delta that is gone
  refuses the write as 42P01, naming the remedy (the next tick restarts the run and re-mints capture).
  Measured on 100,000-row updates on PG 15: the name check costs about 0.3 microseconds a captured write, and
  a write after the rename about 5.5 more. The core sibling of #1037's bullet 1. Test `tests/288`, guard
  `bench/regrain_capture_delta_by_record.sh`, mutation `regrain_capture_delta_insert_by_name`.

- **A synchronous export reads the relation it claimed its key for** (#1030, bullet 1). `archive.to_s3`
  resolved the child and claimed the object key for its oid, then read the child later by schema and name with
  nothing held on it, so a second session that dropped the child and created another relation by its name in
  that window had the export PUT the new relation's rows over the old relation's export, under the old
  relation's claim, with exit 0: after the documented export-then-drop workflow, the only copy of those rows.
  `archive._resolve_child`, which `archive.to_s3` and `archive.to_s3_parquet` both call first, now holds the
  child (ACCESS SHARE, to the end of the calling transaction) and refuses one dropped or replaced while it
  waited, so a concurrent `DROP` or rename of the child waits for the export; and `archive.to_s3` reads the
  child by the resolved regclass, so a schema renamed away with a namesake in its place cannot stand in for
  it either. Test `tests/archive/db/45`, guard `bench/archive_to_s3_child_held.sh`, mutations
  `archive_to_s3_child_unheld`, `archive_resolve_child_unlocked` and `archive_to_s3_reads_child_by_name`.

- **`scripts/archive_partition_whole.sql` holds its archive strategy to the contract `_archive_step` does**
  (#1030, bullet 3). The operator utility wrote the strategy's `covered_hi` into `pgpm.archive_ledger` with
  none of #454's check, so a strategy that answered `[0, 1000)` with `1000000` and archived nothing marked the
  partition covered and `retire()` dropped it with nothing archived; one that answered `lo` wrote the `(lo, lo)`
  row that wedges the ledger. It now calls `pgpm._archive_contract_breach` before any ledger write, and on a
  breach records nothing, logs `fail_archive_contract` over the range it handed and returns the refusal. Its
  partial-or-whole message compares by value, not as text, so a whole cover spelt `1000.0` no longer reads as
  partial. It also refuses, before the strategy runs, a caller whose reads of the parent or the partition
  row-level security filters (the #873 lever `_archive_step` applies, logged `skip_archive`): a non-`BYPASSRLS`
  owner of a `FORCE ROW LEVEL SECURITY` table archived only the rows its policy admitted, recorded whole
  coverage, and `retire()` dropped the hidden ones. Test `tests/286`, guard
  `bench/archive_partition_whole_contract.sh`, mutations `archive_whole_contract_unchecked`,
  `archive_whole_partial_compared_as_text` and `archive_whole_rls_unrefused`.

- **`scripts/archive_partition_whole.sql` picks, resumes and finds a partition as `_archive_step` does**
  (#1054). The operator utility ordered its candidates by `pgpm.part.lo` as text, so on an id grid crossing a
  power of ten it archived `[1000, 1100)` ahead of the older `[200, 300)`; it now orders them in the
  control's native type. It rendered its resume watermark with a bare `::text` in the caller's `DateStyle`
  and wrote that as the next ledger row's `lo`, so a call under `SQL, DMY` recorded `13/08/2026 12:00:00 UTC`,
  and once `retire()` dropped the partition `_archive_step`'s #511 discard query could not parse it and every
  `maintain()` tick logged `skip_archive` for the parent; it now reads the watermark through
  `pgpm._max_hi_native`, so the `lo` it records is canonical. And it looked the partition up in the parent's
  schema, so after `ALTER TABLE <parent> SET SCHEMA` it refused the intact partition it had recorded; it now
  resolves it with `pgpm._child_nsp`, and its identity check still refuses a relation that took the name in
  the partition's own schema. Test `tests/289`, guard `bench/archive_partition_whole_follows_step.sh`,
  mutations `archive_whole_order_by_text`, `archive_whole_resume_session_render` and
  `archive_whole_parent_schema`.

- **`from_hypertable_copy`'s change capture writes its delta by the oid it recorded** (#1037, bullet 1). The
  drains, the cutover and uninstall have found the delta by its `pgpm.scratch` oid since #955, but the
  capture function the copy minted inserted into `<rel>_pgpm_delta` by name, so renaming the recorded delta
  during the online window refused every insert, update and delete on the live hypertable (42P01) until it
  was renamed back, and a table created under the freed name took the captured keys, which nothing drained.
  The function keeps its static insert only while the minted name still leads to the recorded oid; once it
  does not, it renders the oid to the delta's current name and inserts through it dynamically, the key
  values bound, and a delta that is gone refuses the write as 42P01, naming the remedy. Measured on
  100,000-row inserts on PG 15: the name check costs about 0.3 microseconds a captured row, and a write
  after the rename about 11 more. Test `tests/timescale/db/56`, guard
  `bench/hypertable_capture_delta_by_record.sh`, mutation `hypertable_capture_delta_by_name`.

- **`transmute` refuses a partition step or anchor a `timestamp(p)` key cannot hold, before anything
  commits** (#1039 bullet 1). The preflight held a `date` key to whole days and never a `timestamp(p)` key to
  its precision, so `'500 milliseconds'` on a `timestamptz(0)` key committed and validated the
  `pgpm_monolith_bound` CHECK, and the cutover's obtain then died on `empty range bound`, leaving the table
  rejecting every current write until `transmute_abort` (a retry resumed the same bound); `'1500
  milliseconds'` converted with `pgpm.part` bounds the catalog had rounded to other instants, and so did an
  anchor half a second off. The #980 regrain rule is now one helper, `pgpm._time_unit_breach`, which
  `_regrain_step_shape` and transmute's new `_time_unit_contract` both ask: a step (unless a whole number of
  months) and an anchor must be whole multiples of `10^-p` seconds, and the refusal names the unit and the
  remedies (whole units, a wider precision, `transmute_abort` for a bound an earlier attempt left). Test
  `tests/287`, guard `bench/transmute_step_precision.sh`, mutations `transmute_time_unit_contract_dropped`
  and `time_unit_anchor_unchecked`.

- **`./test.sh discriminate` no longer certifies a guard whose only failures against its mutant are LIVENESS
  witnesses** (the discriminate.sh bullet of #713). `bench/discriminate.sh` read any non-zero exit of a guard
  run against its installed mutant as "fails when the defect is present", so a mutant that starved the
  fixture (the guard failed only the checks saying the state the defect needs was reached, and never got to
  the defect) was counted as a catch and the track passed. It now applies the rule
  `scripts/review/classify_claims.py` applies to a reproduction: a run whose every failure is a `LIVENESS:`,
  `GUARD:` or `fixture:` check (its pgTAP `not ok` lines when it printed any, else its `FAIL` lines) FAILS the
  track as a starved fixture, while a witness failing beside a failed defect check still counts.
  `bench/discriminate_installs.sh` gains the shell and pgTAP cases that prove it, and its listing-on-stdin
  check, which was one LIVENESS line, is split into the defect check and its witness, and
  `bench/wrapper_tap_verdicts.sh`'s "carries exactly one verdict block" check, the #844 contract itself, is
  no longer labelled LIVENESS; mutation `discriminate_counts_liveness_only`.

- **The `Archive object keys` lint reads the SQL an `EXECUTE` runs** (#1001). Its lexer kept every
  single-quoted literal as one opaque token, so a second, unclaimed key function that read the prefix with
  `execute 'select prefix from archive.config where ...' into v` and returned `v || ...` passed CI, while the
  same function with a static `select prefix into v` failed it. Every literal in an EXECUTE's command (its
  `format()` arguments included), and every literal assigned to a local an EXECUTE of the same body runs, is
  now lexed as the code it is; every other literal stays text. `--selftest` gains the reproduction and both
  indirections; guard `bench/archive_object_keys_static.sh`, mutation `archive_key_prefix_by_execute`.

- **The `Quoted splices` lint types the locals of every DECLARE block** (#1004). It read only a body's first
  `declare ... begin`, so a text local declared in a nested block and assigned `string_agg(quote_ident(...))`
  without the `_q` suffix, the #409 shape, was never typed and never checked. Every DECLARE section is now
  read; no install file had such a local. `--selftest` gains the nested case, unmarked (refused) and marked
  (clean and counted).

- **`bench/archive_lz77_memory.sh` judges the repeat chunk by its bytes, not its length** (#992). Its
  witness "chunk3 (repeat) returned chunk1's file again", the premise of the no-compounding ratio, compared
  the two files' lengths, so a repeat that returned a different file of the same length passed as a repeat.
  Each chunk's result row now carries the md5 of the file it returned, and the repeat must match chunk1's.
  Mutation `archive_lz77_repeat_differs` (a footer stamped with the encode's clock time, fixed width).
- **`bench/upgrade_in_place.sh` compares nullability, defaults and constraints with a fresh install, and
  reads the backfilled rows** (#1003). "The pgpm catalog matches a fresh install exactly" hashed table,
  column and type alone, so a backfill line that lost its `not null default 'UTC'` for
  `config.partition_tz` upgraded to a nullable column, NULL on every existing row, and every stage passed.
  The catalog is now a named list of every column with its type, nullability and default and every
  constraint by definition, reported line by line where it differs, and every row that predates the
  upgrade must hold a value in each backfilled column a fresh install declares NOT NULL, beside a liveness
  check that each was read over existing rows. Mutation `upgrade_backfill_drops_not_null`.

- **tests/219's config-load sweep sees a FOR-loop load** (#999). Part F promises every whole-row
  `pgpm.config` load in pgpm is followed by `pgpm._control_followed`, but found the loads by the one spelling
  `select * into <var> from pgpm.config`, so a reader that loaded the row in a FOR loop (the shape `status()`
  and `progress()` use) and read the stale control column name after a rename passed it. Part F now finds a
  load by what it reads (SELECT INTO with INTO before or after FROM, a FOR loop, a composite assignment), runs
  the same probe over one fixed source per shape so a shape it stops seeing fails by name, and names
  `status()` and `progress()` among the FOR-loop loads; both now follow the control column too.
  Mutation `control_followed_missing_at_for_loop_load` (guard `bench/control_column_rename.sh`).

- **`bench/throws_pinned.sh` probes a bare-NULL assertion whose description is a psql variable** (#1000). The
  skip for a pattern that reads its file's own psql variable searched every argument after the statement, the
  description included, so `throws_ok($$ call pgpm... $$, NULL, :'d')` was reported INFO and the guard passed
  it. The skip now looks only at the arguments pgTAP reads as a pattern (the description is positional, except
  in a three-argument `throws_ok`, where it is the description only when the second argument is a NULL or a
  literal that is not five octets); a variable description is replaced by a literal and the site is probed.
  Mutation `throws_ok_null_pattern_var_desc`.

- **Ten conservation tests assert the rows a regrain or a transmute keeps by identity, not by count**
  (#997). `tests/43`, `45`, `46`, `48`, `53`, `54`, `67` and `68` (regrain: 'all rows conserved', 'lossless')
  and `tests/15` and `49` (transmute: 'all rows conserved through the parent') compared `count(*)` over
  fixtures whose rows all carried one payload, so a copy that rewrites a row's values while keeping every count
  passed all ten. Each fixture now carries a distinct value per row and each file adds a `bag_eq` of the rows
  against a snapshot taken before the operation (or the generated set the fixture wrote). Guard:
  `bench/tests_fail_on_defect.sh` now requires every one of the ten to fail against a regrain copy, or a
  transmute, that sets one row's value to another's (liveness read from a probe table of distinct values);
  mutations `regrain_conservation_by_count_43`, `_45`, `_46`, `_48`, `_53`, `_54`, `_67`, `_68` and
  `transmute_conservation_by_count_15`, `_49`.

- **`tests/79` names the healthy table's `pgpm.part` rows that survive `forget_missing()`** (#998). Under its
  own 'Identity, not cardinality' comment it compared a count, which a `forget_missing()` that rewrites every
  surviving row's `child_name` and `child_oid` keeps; it now compares `(child_name, child_oid, lo, hi)` with
  a snapshot taken before the drop. Guard: `bench/tests_fail_on_defect.sh` against exactly that rewrite;
  mutation `forget_missing_survivors_by_count`.

- **`tests/267` holds the scratch lever to what it promises at three sites it used to accept** (#993). Stage A
  read the regrain delta's owner only after the copy tick, whose ownership check re-owns it, so a prepare that
  minted the delta under the tick's role passed; the owner is now read right after the prepare as well. Its
  "the list is complete" snapshot looked at tables only (relkind `r` and `p`), so a sequence, view or matview
  the prepare minted unrecorded passed; it now takes every relation of every kind in the parent's schema and
  requires each to be a scratch relation pgpm recorded (`pgpm._scratch_objects`) or an index or identity
  sequence of one, and `tests/timescale/db/49` widens its list the same way. Stage E4 judged the table
  untransmute hands back by `count(*) = 299`, so one that lost row 17 and kept the deleted 450 passed; it now
  names the rows. `bench/tests_fail_on_defect.sh` runs `tests/267` against each defect (a delta minted the
  tick's, a swap of 17 for 450, an unrecorded sequence), with the mutations
  `scratch_suite_delta_owner_after_copy`, `scratch_suite_restored_rows_by_count` and
  `scratch_suite_list_tables_only`.

- **`tests/timescale/db/05` judges the keyless catch-up by its rows, not its count** (#996). It asserted
  `count(*) = 245`, so a migrated table that lost one copied row and held another twice passed. It now
  snapshots the source right before the cutover and compares the migrated table with it as a bag. The new
  timescale-track guard `bench/hypertable_catchup_identity.sh` runs the file against exactly that state, with
  the mutation `hypertable_catchup_rows_by_count`.

- **`tests/247` and `tests/178` name which table logged each transmute** (#994). Both asserted "each conversion
  logged its own transmute" as one `count(*)` summed over every converted table, which a log naming one table
  twice and another never satisfies. Each now asserts the transmute rows' parents by name, one per converted
  table. `bench/tests_fail_on_defect.sh` judges both files against an install whose transmute logs every
  conversion under the first parent it logged; mutations `transmute_log_summed_count_247`,
  `transmute_log_summed_count_178`.

- **`tests/140` names the rows `rn_old` kept across the reap** (#995). "rn_old kept every row it had, and the new
  one" was `count(*) = 22`, which a reap that rewrites id 1 to -1 satisfies; it now asserts ids 1 to 20, 100 and
  200. `bench/tests_fail_on_defect.sh` judges it against a reaper that does exactly that; mutation
  `reap_kept_rows_by_count`.

- **`tests/77` reads the retiring partition's rows, not only its name in `pg_inherits`** (#1002). "Still
  attached, and still holds its rows" (fixture 1, mid-retirement) and "left INTACT and attached, not
  half-retired" (the NO ACTION crossing) each counted one `pg_inherits` row under the partition's name and read
  none of its rows, so a `retire()` that emptied the partition passed both. Each is now three assertions: the
  partition attached by the oid it had before `retire()` and not detach-pending, ids 1, 25000 and 50000 (and
  42 for the crossing) by name, and exactly ids 1 to 50000. `bench/tests_fail_on_defect.sh` judges the file
  against a `retire()` that empties the partition at dispatch and one whose refused crossing deletes the rows
  nothing references, one install each, with a probe showing each defect present; mutations
  `retiring_partition_attachment_only`, `crossing_refusal_attachment_only`.

- **README.md no longer promises transmute a `DEFAULT` partition as its safety net** (#991). The front-door
  `transmute` bullet still said "a fresh `DEFAULT` is the safety net", though the `DEFAULT` partition went in
  #288: transmute builds none, and a write past the forward grid is refused ('no partition of relation ...
  found for row'), as the same README's caveat, the guide and the reference say. An operator who trusted it
  wrote ahead of the grid expecting the row to be parked, and skipped sizing `obtain` or calling
  `extend_to`. The bullet now names the forward grid, `obtain`'s lookahead and `extend_to`.
  `bench/doc_transmute_no_default.sh` measures the refusal (and `extend_to` lifting it) and checks every
  sentence of the docs that names a `DEFAULT` partition, with the mutation `readme_transmute_fresh_default`.

- **A regrain target finer than a `timestamp(p)` or `timestamptz(p)` control column's precision is refused up
  front** (#980). `_regrain_step_shape` had a precision rule for a `numeric` key (#899) and none for a time
  key, so `set_regrain('500 milliseconds')` on a `timestamptz(0)` key was stored, the run copied every
  sub-range, and at the swap `ATTACH PARTITION` rounded the fine bounds to whole seconds (`..:20.5` and
  `..:21` both to `..:21`) and failed `empty range bound` on every tick, with the capture trigger and the
  `TRUNCATE` refusal left on the source until the run was cancelled. A fixed step must now be a whole number
  of the column's smallest unit (`10^-p` seconds, read through any domain), at call time and by
  `regrain_step`, `regrain()` and each tick; a month step and an unconstrained column are unaffected.
  `tests/277`, guarded by `bench/regrain_target_time_precision.sh` with mutation
  `regrain_step_time_precision_unread`.

- **`uninstall.sql` drops every scratch object `pgpm.scratch` records, by oid, whatever it is called now**
  (#985). Its record sweep took only a recorded object that had lost the comment `from_hypertable_copy` also
  puts on it, and left every commented one to the comment sweeps, which also need the `<rel>_pgpm_delta` /
  `<rel>_pgpm_dest` name. So a never-cut-over copy and delta the operator had renamed (which the drains and
  the cutover still find by oid) matched neither: the copy, the delta and the capture function survived the
  uninstall, with the capture trigger still on the live hypertable and every chunk, while the schema drop
  took the record that named them. The record sweep now takes every recorded copy, delta and function by
  oid (a copy whose hypertable is gone is still left, with its `WARNING`), and the comment sweeps take only
  what the record does not name. `tests/282` (new, core), `tests/timescale/db/54` (new); `tests/timescale/db/32`
  and `48` now stage their comment-sweep copies as pre-record ones, so those sweeps stay guarded. Guards
  `bench/uninstall_scratch_by_record.sh` and `bench/uninstall_hypertable_scratch_by_record.sh`; mutations
  `uninstall_scratch_record_defers_commented`, `uninstall_scratch_record_drops_orphaned_copy`,
  `uninstall_scratch_record_skips_capture_fn` (and `uninstall_scratch_record_unread`, re-cut).

- **A forward cell detached by hand is rebuilt, not trusted** (#956 bullet 2). `obtain` and `extend_to` judged
  a cell built while the relation its `pgpm.part` row recorded existed, so a forward partition DETACHed by
  hand (its table kept) stayed "built": never rebuilt, nothing logged, every write into its range refused for
  good, while `status()` kept counting it. A cell is now built when its partition is a partition of the table
  (`pg_inherits`), or while a retirement of pgpm's is detaching it (`retiring_at`). A hand-detached cell's row
  is forgotten, logged with the new action `forget_detached_partition`, and a fresh partition is built over
  the range under its explicit-range name; the detached table is left exactly as it is, rows and all.
  `tests/280` (new), `bench/obtain_rebuilds_detached_cell.sh`; mutations `obtain_trusts_detached_cell`,
  `detached_cell_name_refused`, `retiring_cell_forgotten`.

- **progress() names only a built partition as the write child** (#982). `write_child`, `write_ceiling`,
  `freeze_margin` and `freeze_in` were read from the `pgpm.part` row alone, so a frontier partition dropped
  (or detached) by hand was reported as the one taking writes, with a healthy freeze margin, while every
  write into it was refused and `status()` no longer counted it. progress() now reads through the predicate
  `status()` uses (`pgpm._part_built`), and reports the four as null. `tests/279` (new),
  `bench/progress_write_child_built.sh`; mutation `progress_reads_unbuilt_write_child`.

- **A forward cell dropped by hand before an upgrade from 0.5.0 or older is rebuilt** (#981). The upgrade's
  `child_oid` backfill resolves attached partitions by name and finds nothing for a dropped one, and a null
  `child_oid` read as present, so `obtain` never rebuilt the cell and `forget_missing` (which clears only rows
  whose parent is gone) never reached it: every write into the range was refused, for good. Such a row now
  counts as gone once every partition of the table is accounted for, so `obtain` forgets it
  (`forget_dropped_partition`) and rebuilds the cell; while a partition of the table is unrecorded (renamed
  by hand before the upgrade), the row keeps counting, so `obtain` never dies on that partition's range.
  `tests/278` (new), `bench/upgrade_unanchored_cell.sh` (a real upgrade from v0.5.0); mutations
  `unanchored_row_reads_built`, `unanchored_row_reads_gone`; the #908 mutations re-anchored on
  `pgpm._part_built`, which replaces `pgpm._part_relation_exists`.

- **`transmute` refuses a `text_time` anchor or step finer than the encoding's unit** (#989). Every bound of
  a `text_time` grid is encoded by flooring to the unit (`p_tt_unit`) counted from `p_tt_epoch`, and
  `transmute` took `p_anchor => '2000-01-01 00:00:00.5+00'` on an ObjectId seconds grid: `pgpm.part` recorded
  every bound half a second above the catalog's, so a row in that half second sat in a partition whose
  recorded range does not hold its time. An anchor or step that is not a whole number of units from the
  epoch is now refused up front, naming the unit, as a negative-scale `numeric` id column's is.
  `tests/284` (new); guard `bench/text_time_anchor_unit.sh`; mutations `text_time_anchor_unit_unchecked`,
  `text_time_unit_unix_epoch`.

- **`transmute` refuses a supplied `text_time` alphabet with a radix below 2** (#990). With `p_tt_alphabet`
  supplied the only radix rule was the alphabet's length, so `p_tt_radix => 1` with alphabet `'x'` passed, and
  encoding the frontier divided by 1 forever: `transmute` (forced past the shape sample) spun until
  `statement_timeout`. It now refuses before anything is touched. `tests/285` (new); guard
  `bench/text_time_radix_lower_bound.sh`; mutation `text_time_radix_no_lower_bound`.

- **`transmute` refuses a NOT VALID or NO INHERIT CHECK, or a generated control column, committed while it
  runs** (#766 bullet 3). The three shapes #730 refuses up front were asked in the preflight only, so one
  committed after it (an `ALTER TABLE` queued behind phase 1's ADD of the bound is granted the moment phase 1
  commits) reached the cutover and failed it raw, after phases 1 and 2 had committed the write-rejecting
  bound and the claim: 'conflicts with NOT VALID constraint on child table' from the ATTACH, 'cannot add NO
  INHERIT constraint to partitioned table' from the staging LIKE, 'cannot use generated column in partition
  key'. The cutover now takes the table's ACCESS SHARE explicitly before its staging LIKE (the lock the LIKE
  takes anyway, and one every statement that adds such a shape must wait for) and asks all of them again
  under it, the NOT ENFORCED refusal included, in the preflight's words and with its remedy; the refusal
  rolls the cutover back to the resumable phase-2 state. `tests/283` (new) under the guard
  `bench/transmute_uncarried_shapes_under_lock.sh`; mutations `transmute_uncarried_constraints_preflight_only`,
  `transmute_generated_control_preflight_only`.

- **`pgpm_archive` reaches pgcrypto and the http extension in their own schemas, never through the caller's
  `search_path`** (#984). Both SigV4 signers called `hmac()`, `digest()`, `http()` and `http_set_curlopt()`
  unqualified in functions that pinned no `search_path`, so a function `hmac(bytea, bytea, text)` any role
  created in a schema ahead of pgcrypto's on the calling session's path (a `maintain()` tick's, a pg_cron
  job's) was handed `'AWS4' || <the S3 secret key>` and ran with the caller's privileges; and every S3
  function named the http types in its declarations, so a tick under an application `search_path` that does
  not name the extensions' schema (`set search_path = app`) logged `skip_archive` 'type "http_response" does
  not exist' on every tick and never archived or retired. The signers now pin their `search_path` to
  `pg_catalog`, every extension object is called in the schema `pg_extension` names for it at call time
  (`archive._sha256`, `archive._hmac_sha256`, and `archive._s3_send`, now the one transport every request goes
  through), and the functions that receive a response hold it in a record. `tests/archive/db/17`, `23`, `24`
  and `28` put their stand-ins in `archive._s3_send`'s place (`tests/archive/fixtures.sql`'s
  `mk_transport_standin`) rather than ahead of the extension on the path, and `tests/archive/db/39`'s scan
  starts from that transport. Acceptance: `tests/archive/db/44` (shadows owned by another role ahead of both
  extensions and of `pg_catalog`, and both strategies, both exports and the abort sweep under `search_path
  app`, read back by identity) under the guard `bench/archive_extension_resolution.sh`; mutations
  `archive_signer_hmac_through_search_path`, `archive_signer_search_path_unpinned`,
  `archive_upload_names_http_types` (and `signer_text_sends_server_encoding`, re-anchored on the new send).

- **Re-running `install.sql` keeps an operator's views over pgpm's functions** (#983). The file dropped
  `status()`, `progress(regclass)`, `observe_window(regclass, interval)`, `check_uuidv7` and `check_text_time`
  unconditionally on every run before creating them, so one monitoring view over `pgpm.status()` made the
  documented upgrade fail at that drop (the whole run rolled back under `--single-transaction` or the
  dashboard bundle; plain `psql -f` carried on without the new body). Each is now created with CREATE OR
  REPLACE only, keeping its oid, its grants and every view over it; `pgpm._surface_shapes()` declares the
  shape each is created with, and `pgpm._surface_prepare()`, the first thing the file runs, drops one only
  when its installed shape cannot be replaced in place, and refuses the run (SQLSTATE `2BP01`, naming the
  function, the dependant and the remedy) before anything else in the file has run when something depends on
  such a function. `pgpm._surface_settled()` fails any install whose declaration has drifted from what the
  file creates. `tests/281` (new), `bench/install_keeps_dependent_views.sh` (new); mutations
  `install_drops_surface_unconditionally`, `surface_shape_ignores_result`.

- **`from_hypertable` no longer carries a 0.6.0 change capture onto a hypertable renamed or moved since**
  (#988). A tracking copy pgpm 0.6.0 took leaves no record of its capture (no `pgpm.scratch` row, no horizon
  comment on its delta), so the swap recognised it by proof: a function `<rel>_pgpm_delta_fn` whose body
  inserts into `<rel>_pgpm_delta`, with `<rel>` the hypertable's CURRENT name. 0.6.0 named both for the table
  as it was at the copy, so after an `ALTER TABLE ... RENAME` or `SET SCHEMA` the capture read as the
  operator's trigger: the swap carried it, `transmute` cloned it onto every partition, and every write to the
  migrated table was logged into a delta nothing drains. The proof now reads the name and schema off the
  function itself (`<x>_pgpm_delta_fn` writing into `<x>_pgpm_delta` in its own schema), and is asked only of
  a capture with neither record, so the record and the comment stay the only ways to know the ones they
  mark. `tests/timescale/db/55` (new); guard `bench/hypertable_carry_capture_by_provenance.sh`; mutation
  `hypertable_carry_capture_proof_by_current_name`.

- **A from_hypertable migration's delta follows the hypertable's writers through the online window** (#979).
  A tracking `from_hypertable_copy` granted `INSERT` on its delta once, to the roles that could write the
  hypertable at that moment, and nothing granted again, so a role granted DML on the hypertable afterwards had
  every write refused 'permission denied for table `<rel>_pgpm_delta`' by the capture trigger until the
  cutover. Every drain, drain step and the cutover now re-syncs the delta's writer grants from the
  hypertable's ACL before it acts, as core's regrain does on every tick (#496), so such a role writes from the
  next one on. `tests/timescale/db/52` (new), `bench/hypertable_delta_writer_grants.sh`; mutation
  `hypertable_delta_grants_not_resynced`.

- **A hypertable handed to a new owner mid-migration is handed over by the next step, or refused up front**
  (#986). No `from_hypertable` drain and not the cutover asked whether the copy, the delta and the capture
  function still belonged to the hypertable's owner, so after `ALTER TABLE <hypertable> OWNER TO` the new
  owner's drain died raw 'permission denied for table `<rel>_pgpm_delta`', naming no remedy. Each now hands
  them to the hypertable's owner when its role may, and otherwise refuses once, before it changes anything,
  SQLSTATE `42501`, leading with the documented `pgpm.hand_over_scratch(...)` step, as every core path does.
  The cutover asks again under its lock on the hypertable, the copy and the delta, so nothing can re-own them
  between that answer and the swap. That makes a copy owned by another role at the swap unreachable, so the
  mutation `hypertable_cutover_serial_owned_before_carry` (#839's plausible one-step fix, caught only in that
  state) is retired; `tests/timescale/db/39` stays as the carry order's test. `tests/timescale/db/53` (new),
  `bench/hypertable_scratch_owner_follow.sh`; mutation `hypertable_drains_owner_not_followed`.

- **`pgpm.hand_over_scratch` reports only what it handed over, and refuses what it cannot** (#987). It
  counted the scratch objects before handing them over, and the hand-over let a session that could still act
  as the old owner go on without re-owning anything, so the old owner itself, or any member of it alone, was
  told it had handed over every object while each stayed where it was and nothing refused. It now reads back
  what it did, and refuses with SQLSTATE `42501` and the remedy (run it as a superuser or a member of both
  owners) when any object is left with another owner; nothing is handed over then. `tests/276` (new),
  `bench/hand_over_scratch_reports.sh`; mutation `hand_over_scratch_unverified`.

- **A scratch relation's sequences are minted owner-only too: a stranger can no longer setval the regrain
  delta's `pgpm_seq` into duplicates and make the swap drop rows** (#974, Tier 1). `_scratch_mint` reset
  the ACL of the delta it minted but not that of the delta's `pgpm_seq` identity sequence, which kept the
  minting role's ALTER DEFAULT PRIVILEGES (Supabase's `grant all on sequences to anon, authenticated` is
  that shape). A role holding nothing on the managed table could `setval` it; duplicate `pgpm_seq` values,
  the identity the reconcile addresses delta rows by, made one tick consume a key it had not applied into
  the sub-range being copied, and the swap dropped rows 60..89 with the source. The hypertable tracking
  delta's sequence had the same gap (the change counter readable, the drains' watermark settable). The mint
  now resets every sequence a minted relation owns (found through `pg_depend`), which follows its table's
  owner on a hand-over. `tests/272` and `tests/timescale/db/51` (new), guard `bench/scratch_sequences.sh`;
  mutations `scratch_mint_sequence_default_acl`, `hypertable_delta_sequence_default_acl`.

- **An `archive_fn` strategy no longer writes over a chunk the ledger records unless it reproduces it** (#975,
  pass 9 F5-03 and F5-04). #969's direct-call guard refused only an empty or inverted range shape, and the
  whole-key claim admits the same parent and kind, so nothing asked what `pgpm.archive_ledger` recorded at the
  key a direct `pgpm.archive_to_s3_ndjson` / `_parquet` call would write (Tier 1). After `retire()` dropped an
  archived partition, a call with the chunk's own `[lo, hi)`, which #969's refusal tells the caller to pass,
  read no row and PUT an empty object over the only copy of its rows; and on a live archived partition a call
  with the chunk's `lo` and a shorter `hi` PUT a subset over the chunk while the ledger still recorded
  `[lo, hi)`, so `retire()` then dropped the rest of the rows with no copy. Both encoders now ask
  `archive._refuse_recorded_chunk_overwrite` with the key and the read's row count before the PUT: where the
  ledger records a chunk at that key, only the same `[lo, hi)` (compared natively) with the recorded rows
  present is written, and anything else is refused, naming the recorded chunk and the key.
  `tests/archive/db/42` (new) under the guard `bench/archive_recorded_chunk.sh`; mutations
  `archive_ndjson_recorded_chunk_unchecked`, `archive_parquet_recorded_chunk_unchecked`,
  `archive_recorded_chunk_rows_unchecked`, `archive_recorded_chunk_range_unchecked`.

- **An export's object key is claimed by the relation it exports, so a namesake cannot export over it** (#976).
  `archive.object_key_claim` claimed a whole key by its parent and its kind only, so after `archive.to_s3` of
  a relation, its `DROP` and a new relation taking its name (the export-then-drop workflow, after which the
  object is the only copy of the dropped relation's rows), the same parent's export of the new one read as a
  re-run and PUT over the first export. The claim now records the relation whose rows the object holds
  (`relation_oid`: the parent for a chunk, the exported relation for an export); a re-run by the same
  relation still writes, and another relation's export at that key is refused, at the plain key and at the
  oid shape alike. Install records the relation of a chunk claim made before the column existed; an export
  claim's is not known, and every export over it is refused. Test `tests/archive/db/43` (and
  `tests/archive/db/13` part D, moved to a prefix of its own: its impostor's export over the real child's
  claimed key is now refused by the claim, before the anchor check it shows), guard
  `bench/archive_export_key_by_relation.sh`, mutations `archive_export_claim_relation_unchecked` and
  `archive_chunk_claim_relation_unrecorded` (and `archive_object_key_whole_unclaimed`, re-cut).

- **The archive ledger records the instant its contract check accepted, so `retire()` reads the same coverage
  from every session** (#977). `_archive_step` held an archive_fn's `covered_hi` to its chunk (#454) with a
  parse in the tick's session, then wrote the strategy's text into `pgpm.archive_ledger.hi` verbatim. An
  offset-less value is valid input, so a strategy that archived three hours short of a partition's `hi` and
  said so without an offset passed the check in a UTC tick, and `retire()` run from an America/New_York session
  read the same text as past `hi`, judged the partition covered and dropped it with the rows the strategy was
  never handed (Tier 1). The row now holds `pgpm._native_text` of the value, the canonical rendering
  (`_ts_text` for a time grid, numeric text for `id`) of what the check parsed, which is also how the next
  chunk's `lo` is rendered; `scripts/archive_partition_whole.sql` records its strategy's return the same way.
  Ledger rows a strategy wrote before this fix keep their text. `tests/273` (new),
  `bench/archive_covered_hi_canonical.sh`; mutation `archive_covered_hi_verbatim`.

- **The text_time collation check is a proof for the alphabet in use, so a two-letter contraction is
  refused** (#639 bullet 2). `transmute` and `check_text_time` probed adjacent single-character digit pairs,
  which no contraction disturbs: under `da-x-icu` `aa` is `å`, after `z`, so a hex (ObjectId-shaped)
  column on it was accepted and PostgreSQL routed a row whose timestamp field held `aa` (decoded 28
  November) into the December partition, where retain drops it on December's schedule (Tier 1); `cs-x-icu`
  (`ch` after `h`) passed for base32 and Crockford the same way. The check now requires every one- and
  two-character string of the alphabet behind the prefix to sort in place-value order under the column's
  collation, which covers every two-letter contraction (a prefix's last letter with the first digit
  included), ignored characters, case weights and numeric ordering, and still accepts a collation that
  orders the alphabet correctly (`en_US` for cuid, ULID and hex; `cs-x-icu` for hex). A cuid column under
  numeric ordering is now reported at the pair `'9'`/`'a'` (`'c09'` after `'c0a'`) rather than `'1'`/`'2'`.
  `tests/274` (new), `tests/134`'s message pins, `bench/text_time_collation_proof.sh` (with a database
  whose default collation is `C`); mutation `text_time_collation_probe_only` (and
  `text_time_collation_positional_only`, re-cut onto the proof).

- **A parent whose replica identity index was dropped keeps its forward grid growing** (#978). PostgreSQL
  lets `DROP INDEX` remove a table's `REPLICA IDENTITY USING INDEX` index, leaves the table marked USING
  INDEX with no index, and treats it as `NOTHING`. pgpm read that state as a partition missing its identity
  index and raised, so every mint failed: `obtain` raised, `maintain_obtain` logged `skip_obtain` on every
  tick, `extend_to` raised, and once the cells already built ahead of the frontier were used up every write
  past them was refused. A partition minted for such a parent (by `obtain`, `extend_to` or a regrain's swap)
  now takes `NOTHING`, the parent's identity in that state, and the transaction logs
  `warn_replica_identity_nothing` once for the parent, naming the first such partition, because it keeps
  `NOTHING` after the parent is given an identity again. `tests/275` (new) under the guard
  `bench/replica_identity_index_dropped.sh`; mutations `replica_identity_index_dropped_raises` and
  `replica_identity_index_dropped_default`.

- **The scratch-relation lever's residue: an upgrade no longer adopts a namesake, every path refuses a hand-over
  it cannot follow, and the swap carries an operator's trigger whatever its function is called** (#969
  bullets 2, 3, 5 and 7; part of #966). Re-running `install.sql`, the documented upgrade, recorded whatever
  plain table held `<rel>_pgpm_regrain_delta` as the delta of a parent that had never regrained, by its name
  alone, and the next prepare then DROPPED that table of the operator's with its rows (Tier 1); without the
  re-run the same prepare refuses it. The upgrade now records the pair only on proof that pgpm minted it (the
  capture function under its name, whose body inserts into exactly that relation, which carries the delta's
  `pgpm_seq` identity column), which a real 0.6.0 capture, in flight or left by a completed run, meets. After a
  table was handed to a non-superuser new owner, the tick preparing its next regrain logged `skip_regrain`
  'must be owner of function <rel>_pgpm_regrain_capture' on every tick, and `regrain_cancel`, a retirement
  reclaiming a regrain's source and `untransmute` failed 'permission denied' half-way; each now refuses once,
  up front, with the documented `pgpm.hand_over_scratch(...)` step, and that refusal is now SQLSTATE `42501`
  (it was `P0001`), so `uninstall.sql`'s per-parent handler still warns and goes on. And
  `from_hypertable`'s swap left out any trigger whose function was named `<rel>_pgpm_delta_fn`, so an
  operator's own trigger of that name went with the hypertable; it now knows the module's capture by
  `pgpm.scratch`'s record, the delta's comment record, or (a capture 0.6.0 minted, which has neither) by its
  body. `tests/270` (new), `tests/267` stage E, `tests/timescale/db/49` stage D, `bench/upgrade_in_place.sh`'s
  namesake assertions; mutations `scratch_upgrade_adopts_namesake`, `scratch_prepare_owner_not_followed`,
  `scratch_cancel_owner_not_followed`, `scratch_reclaim_owner_not_followed`,
  `scratch_untransmute_owner_not_followed`, `scratch_owner_refusal_not_42501`, `hypertable_carried_ddl_by_name`,
  `hypertable_carried_ddl_record_unread` (and `hypertable_carry_capture_unrecorded`, re-cut).

- **The shared preflight reaches `pgpm_archive`, and a NOT ENFORCED CHECK is named for what it is** (#969
  bullets 9 and 10; lever phase #966). `pgpm.archive_to_s3_ndjson` and `pgpm.archive_to_s3_parquet` never
  checked their bounds: a null `p_lo` died raw on `archive.object_key_claim`'s NOT NULL, and a null `p_hi` read
  no row and PUT an empty object over the key an earlier call had archived `[lo, hi)` to (the key is derived
  from `lo` alone), returning `covered_hi = null`; a direct call for `[lo, lo)` did the same with no null at
  all. After `retire()` that object is the only copy of the chunk's rows. Every public routine of
  `pgpm_archive` (`archive.configure`, `unconfigure`, `s3_url_encode`, `s3_signed_request`,
  `s3_signed_request_bytea`, `to_s3`, `to_s3_parquet` and the two strategies) now refuses a null with no
  meaning first, naming it, and each strategy refuses an empty or inverted range, compared as the grid's
  native type, before anything is read or sent. On PostgreSQL 18, `transmute`'s refusal of a constraint the
  cutover cannot carry (#730) read a NOT ENFORCED CHECK as NOT VALID and prescribed `VALIDATE CONSTRAINT`,
  which PostgreSQL rejects for it; it is now refused as NOT ENFORCED, with the remedies that apply (drop it,
  or re-create it as an enforced CHECK). Acceptance: `tests/archive/db/41` (a null sweep over the module's
  routines, enumerated from `pg_proc`, and the reproduction read back by identity) under the guard
  `bench/archive_null_arguments.sh`, with one mutation per site (`archive_null_refusal_dropped_<routine>` for
  the seven routines of schema `archive`, `null_refusal_dropped_archive_to_s3_ndjson` and `_parquet`,
  `archive_ndjson_empty_range_unrefused`, `archive_parquet_empty_range_unrefused`,
  `archive_empty_range_compared_as_text`), and `tests/271`, which the PostgreSQL 18 leg of the matrix runs.

- **Scratch relations are minted owner-only, found by their record, and follow the table's owner** (#949,
  #950, #955; the lever of #966). A relation pgpm makes for its own use beside a table (a regrain's delta,
  capture function and fine children; `from_hypertable`'s copy, delta and capture function) used to be born
  with the maintaining role's `ALTER DEFAULT PRIVILEGES` and reset late (a fine child at its sub-range's end,
  the hypertable copy at the swap) or never (both deltas), so a role those defaults name (on Supabase, `anon`
  and `authenticated`) read the copied rows or the captured keys of a table it holds no grant on. It was also
  found again by a name rendered from the table's: `from_hypertable_copy` dropped an operator's own
  `<rel>_pgpm_dest` and `<rel>_pgpm_delta` (Tier 1) and replaced a `<rel>_pgpm_delta_fn()` or
  `<rel>_pgpm_delta_trg` of theirs; the drains and the cutover worked, and swapped in, whatever answered to
  the name; `regrain_cancel` truncated, and `untransmute` and `uninstall.sql` dropped, an operator's
  `<rel>_pgpm_regrain_delta` and `<rel>_pgpm_regrain_capture()` on a table that had never regrained. And a
  table handed to a new owner mid-regrain left its delta with the old one, so every tick the new owner ran
  failed `permission denied`. Now each is minted through `pgpm._scratch_mint` (the table's owner and an
  owner-only ACL, in the transaction that creates it), recorded there (the new catalog table `pgpm.scratch`
  for the hypertable's, which an upgrade fills from the comments earlier releases kept on a copy), and
  resolved only from the record; a name held by anything pgpm did not record is refused before anything is
  created. Each resuming regrain tick gives the scratch relations the table's current owner, or, when the
  tick's role can neither re-own them nor act as their owner, refuses once with the documented hand-over
  step, the new `pgpm.hand_over_scratch(table)`. `from_hypertable_copy` now refuses up front a migrating
  role that cannot give the copy to the hypertable's owner, which the swap already required, and the
  cutover refuses a copy pgpm did not record (one made by hand, or by 0.6.0 or earlier: drop it and re-run
  the copy). Conformance suite `tests/267` and `tests/timescale/db/49`, guard `bench/scratch_relations.sh`
  with one mutation per site (`scratch_*`, `regrain_capture_names_derived_fallback`,
  `hypertable_copy_*_by_name`, `hypertable_*_minted_default_acl`, `hypertable_delta_writers_ungranted`,
  `hypertable_drain_*_by_name`, `hypertable_cutover_*_by_name`, `hypertable_swap_keeps_scratch_record`,
  `uninstall_scratch_record_unread`), and `bench/upgrade_in_place.sh`'s fill assertion
  (`scratch_upgrade_fill_dropped`).
- **One shared preflight for every converting entry point: null arguments, the control type, and the key
  gates** (#951, #952 bullets 1 and 2, #959; lever phase #966). A refusal the core made before anything
  committed was re-implemented, or not made, at the other entry points. `pgpm._refuse_null_arguments` guarded
  `transmute` and `extend_to` only, so `suspend_incoming_fks(p, null)` read the null as `p_force => true` and
  dropped the live keys, and `from_hypertable(..., p_paused => null)` reached `transmute`'s check only after its
  swap had dropped the hypertable (a null `p_lock_timeout` left the swap's lock wait unbounded). Every public
  routine of `pgpm_core` and `pgpm_hypertable` now refuses a null with no meaning first, naming it (`transmute`'s
  `p_obtain` included, by the shared message). A `numeric(6,-2)` key with step 10 passed the id preflight and
  died raw in the cutover's `ATTACH` after phases 1 and 2 had committed the bound, as did a bound past a
  `numeric(4,0)` key's precision; the step, the anchor and the monolith's bound are now held to what the column
  can store (`pgpm._id_step_contract`, `pgpm._control_bound_contract`), and a resume holds the bound an older
  install recorded to the same contract, so a pre-#922 claim with `hi = NaN` is refused with the
  `transmute_abort` remedy instead of completing a monolith `[0, NaN)`. `from_hypertable_preflight` never read
  `convalidated`, so a `NOT VALID` incoming key was dropped by the swap and promoted by the handoff; the preflight
  and the cutover under its lock now call the gate `transmute` uses (`pgpm._refuse_unconvertible_keys`), which on
  PostgreSQL 18 also names a `NOT ENFORCED` key for what it is, with a remedy that applies to it, instead of the
  `NOT VALID` wording and a `VALIDATE CONSTRAINT` PostgreSQL rejects. Acceptance: `tests/268` (a null sweep over
  every public routine, enumerated from `pg_proc`, and the refusal cases against `transmute`), `tests/269` (the
  resume's recorded bound) and `tests/timescale/db/50` (the module's sweep and cases), under the guards
  `bench/shared_preflight_conformance.sh` and `bench/hypertable_shared_preflight.sh`, with one mutation per
  site (`null_refusal_dropped_<routine>` for each of 38 routines, `transmute_null_obtain_unlisted`,
  `set_retain_refuses_null_retain`, `id_step_contract_dropped`, `bound_contract_call_dropped`,
  `bound_contract_finiteness_dropped`, `bound_contract_representability_dropped`,
  `incoming_gate_shared_check_dropped`, `hypertable_preflight_key_gate_dropped`,
  `hypertable_cutover_key_gate_dropped`).
- **The archive object-key checks enumerate writes and follow the prefix, instead of matching text** (#914).
  `tests/archive/db/39`'s Part 0 looked for a `'PUT'` literal and for a key helper's name anywhere in a body,
  so a write site that took its verb from a variable, named a helper in a comment, or PUT a second object at
  an inline key beside a claimed one passed it while writing at a key nothing claimed; and
  `scripts/check_archive_object_keys.py` knew the prefix only as `prefix` / `p_prefix` beside `||`, so a second
  key assembled from `(select prefix from archive.config ...)`, or in a function of the file whose parameter
  carrying the prefix had another name, passed it. Part 0 now lexes the module's bodies and enumerates every
  S3 request (every call to a function that calls the http extension, a write unless its method is the literal
  GET, HEAD or DELETE), requiring each write's key to be a local only a key helper assigned; the checker
  follows the prefix through parameters, scalar subqueries, returns and select lists to a fixed point. Guards
  `bench/archive_key_owner_every_path.sh` (mutations `archive_put_site_helper_named_in_comment`,
  `archive_put_site_verb_in_variable`, `archive_to_s3_parquet_second_put_inline`) and the new
  `bench/archive_object_keys_static.sh` (`archive_key_prefix_by_subquery`,
  `archive_key_prefix_by_renamed_param`).
- **Every guard discriminate.sh drives is also run against the unmodified code** (#917, F8-04).
  `discriminate.sh` reads any non-zero exit of a guard pointed at a mutant as a catch, and nine guards with
  mutations (`write_block_identity`, `retire_identity_unreferenced`, `coverage_reset_identity`,
  `archive_identity_substitution` and the `hypertable_cutover_identity`, `late_appends`, `replica_capture`,
  `exclusion_refusal` and `derived_names` wrappers) were in no track, so a copy broken enough to fail against
  everything (a missing file: exit 1, "0 ran") was scored as catching each of its mutants. The core four now
  run in the perf track and the five wrappers in the timescale track, and `bench/guards_run_on_clean_code.sh`
  fails the perf track on any guard `bench/mutations/mutate.py` names that no track runs, with the mutations
  `clean_run_perf_entry_dropped` and `clean_run_timescale_call_commented`.
- **The timescale and observe tracks count the plan themselves** (#918, F8-06). Their verdicts read a plan
  shortfall only from "# Looks like you planned", which pgTAP prints from `finish()` alone, so a file that
  plans 3, runs 2 and never calls `finish()` exited psql 0 and passed both tracks while pg_prove fails it.
  Both now count the assertions that ran against the `1..N` plan line, as the timescale wrappers' shared
  block does. `bench/tap_verdict.sh` adds a fixture without `finish()` and one that runs no assertion, and
  evaluates each region under test.sh's own `set -euo pipefail`, with the mutations
  `tap_verdict_reads_finish_only` and `tap_verdict_count_ends_track` (a count that exits non-zero on zero
  assertions would end the track unjudged).
- **The runbook's foreign-key VALIDATE step names `validate_incoming_fks`** (#910). Its "Prevent" step after a
  preserve conversion said to call `restore_incoming_fks` "again next tick for the VALIDATE", while
  `restore_incoming_fks` re-adds the key `NOT VALID` and stops there (a second call returns 0) and the
  conversion registers the table paused, so no tick validates it either: an operator following it left the
  key `NOT VALID`. The step now runs `restore_incoming_fks` and then `validate_incoming_fks`, as step 5 and
  the guide already do. `bench/doc_remedy_and_symptom.sh` measures which of the two validates and checks
  every code line of the docs that calls `restore_incoming_fks`, with the mutation
  `runbook_fk_validate_by_restore`.
- **The runbook's dropped-table symptom quotes the reason the ticks log** (#911). "A managed table was
  dropped without `untransmute`" said the `skip_obtain` / `skip_write_block` / `skip_retain` rows all give
  `syntax error at or near "<number>"`, while since #296 `_frontier_native` refuses first with `managed
  table with oid N no longer exists (dropped without pgpm.untransmute)`, so a search of `pgpm.log` for the
  documented text found nothing. The entry now quotes that message. The same guard drops a managed table,
  ticks it, and holds every quoted dropped-table skip reason in the docs to what was logged, with the
  mutation `runbook_dropped_table_syntax_symptom`.
- **`bench/throws_pinned.sh` judges every `throws_*` pgTAP installs** (#915). Its site pattern was a
  hand-written list, `throws_(ok|like|matching|imatching)`, without pgTAP's `throws_ilike`, so a
  `throws_ilike($$ call pgpm... $$, '%')`, which accepts the 2D000 of a procedure that did not refuse, was
  never probed and the guard reported the file clean. The forms are now read from the catalog of the pgTAP
  the probe runs against (every extension function named `throws_<word>`), so a form a later pgTAP adds is
  judged the day it is installed, and the guard fails when that read does not include the form its controls
  use. Mutation `throws_ilike_unpinned`.
- **`bench/regrain_perf.sh` checks the regrained rows by identity and value, not by count** (#916). Its
  "conservation, so a fast wrong answer cannot pass" was `count(*) > ROWS`, and its fixture's only captured
  change is an UPDATE of already-copied rows, so a reconcile that consumed the delta without applying it
  (no scan, so the guard's work checks rewarded it) reverted every one of those updates at the swap and
  passed. It now compares every row with the one it must be, by id (the updated ids read their new payload,
  the rest their original, the frontier row its own, none missing or extra), beside a liveness check that
  the updates were made and captured. Mutation `regrain_reconcile_discards_delta`.
- **The three archive memory guards read each encode's own result and fail on any ERROR** (#912).
  `bench/archive_encode_memory.sh`, `bench/archive_lz77_memory.sh` and `bench/archive_deflate_memory.sh` ran
  their probe psql without `ON_ERROR_STOP` and took a marker printed after the call as "the call completed",
  which prints after a raised call too; their "sampled" witness was met during the `pg_sleep` before the call,
  and only the DEFLATE guard looked for an error, `invalid memory alloc` alone. So an encoder that raised
  `out of memory` on every call passed every check with a small RSS. Each guard now reads the call's tagged
  result row (the column's exact PLAIN length, each chunk's `PAR1`-framed Parquet file with the repeat equal
  to the original, a DEFLATE stream at least 99% of the incompressible payload), fails on any `ERROR:` in
  its log, and counts an RSS sample only when start and done markers bracket it inside the call. Mutations
  `archive_encode_raises`, `archive_lz77_range_raises` and `archive_deflate_raises` (an encoder that does the
  work and then raises); the guards' memory mutations are still caught.
- **`tests/88` and `tests/91` assert text_time's drought immunity, not only coverage of now()** (#881, bullet
  G18). They asserted only that a partition covers now() and that a write at now() is accepted, which
  transmute's monolith already satisfies through its own inline `greatest(decoded, now())`, so both stayed
  green with text_time dropped from `_frontier_native`'s clock blend and only `bench/frontier_drought.sh`
  caught it. Each format (cuid, ULID, KSUID) now carries the `tests/85` fixture's checks: a witness that the
  data is 11 months stale, then, before the live insert, `_frontier_native` at or past now() and a forward
  partition past the monolith (named by `pgpm.config.monolith_oid`) covering now() + 1 month.
  `bench/tests_fail_on_defect.sh` runs both files against a text_time-only frontier mutant, with the mutations
  `text_time_drought_coverage_only` and `text_time_drought_coverage_only_ulid_ksuid`.
- **`tests/92` holds the rows regrain's swap moved to the seeded ones, by identity** (#919). Under a comment
  promising identity it asserted `count(*) = 250` over ids 1..2500, so a swap that lost row 2500 and invented
  a row 2499 left the file green. Each seeded row now carries its own payload, and the file compares the
  whole table, `(id, ref_id, payload)` row by row, with the 250 seeded rows and the frontier.
  `bench/tests_fail_on_defect.sh` runs it against a swap that rewrites one copied key, which a count cannot
  see, with the mutation `regrain_survivors_by_count`.
- **`bench/obtain_backoff_headroom.sh` holds the grid the low-headroom tick builds by identity** (#913). Its
  header promised the tick extends the grid "by identity", but the checks were a count of attached partitions
  and the only write probe (8999) landed above the old top, so an obtain that built the right number of cells
  one cell too far, leaving `[5000,6000)` in `ob_race` and `[4000,5000)` in `ob_q` refusing every write, stayed
  green. Every grid check now names its `[lo,hi)` cells in order, and each extending tick is followed by a
  write into the first cell the bypass must build. Mutation `obtain_backoff_bypass_shifts_cell`.
- **`transmute` refuses an incoming foreign key left `NOT VALID` instead of validating it on the operator's
  behalf** (#902). `_transmute_incoming_gate` preserved any incoming key that referenced the reused key without
  looking at `convalidated`, so under `p_incoming_fks => 'preserve'` (or `'drop'`) the cutover recorded a key
  the operator had deliberately left `NOT VALID`, `restore_incoming_fks` re-added it `NOT VALID` like any
  other, and `maintain`'s `validate_incoming_fks` then validated it: a clean one was silently promoted, and one
  over orphans the operator tolerated failed and was re-scanned every five minutes for good
  (`fail_validate_incoming_fk`), orphans the runbook attributed to pgpm's window. The gate now refuses such a
  key up front, naming it, as the outgoing side refuses a `NOT VALID` outgoing key, in the preflight and
  again under the cutover's lock. `tests/259`, guarded by `bench/incoming_not_valid_refused.sh` with mutation
  `transmute_incoming_gate_accepts_not_valid`.
- **`uninstall.sql` removes a `from_hypertable_copy` that was never cut over** (#773, last bullet). It swept
  a tracking copy's change capture (#737) but left the copy itself: `<rel>_pgpm_dest`, a full second copy of
  the hypertable's rows, with the tracking copy's pre-built key index and the outgoing foreign keys the copy
  replayed on it, so a referenced row the hypertable no longer used could not be deleted, where the guide
  says nothing else pgpm made remains. The copy now comments its table `pgpm from_hypertable copy of <oid>`
  as it creates it, the swap replaces that comment with the source's own (or none), and uninstall finds each
  copy by that record, never by its name, and drops it while the hypertable it names still exists. A copy
  whose hypertable is gone may be the only home of its rows, so it is left with a `WARNING`.
  `tests/timescale/db/48` under `bench/uninstall_hypertable_copy.sh`, with the mutations
  `uninstall_keeps_hypertable_copy`, `uninstall_hypertable_copy_by_name`, `uninstall_drops_orphaned_copy`
  and `hypertable_swap_keeps_copy_record`.
- **Every grant the conversions carry keeps its grantor** (#903). `_acl_carry_ddl` read grantee, privilege and
  grant option off the ACL and dropped the grantor, so `transmute`'s parent, `from_hypertable`'s swapped copy
  and `untransmute`'s restored table recorded every grant as the owner's: one a role made through its grant
  option could no longer be revoked by that role, and its grantee kept the privilege. A grant another role made
  is now replayed as that role (`pgpm._acl_grant_as`), after the grant that gave it the option, and a session
  that cannot become the grantor is refused rather than recording it under another: by `transmute` up front,
  naming the roles, before anything is committed, and inside the hypertable's swap and `untransmute`, which
  roll back whole. `tests/254`, guarded by `bench/acl_grantor_owner_partitions.sh` with mutation
  `acl_carry_drops_grantor`.
- **`untransmute`'s reset takes the owner's privileges too, and a partition pgpm mints grants nothing but its
  owner's** (#875). `untransmute` revoked only from the grantees the restored table's ACL named, so on a
  monolith at the `NULL` default it revoked nobody and a privilege the owner had revoked from itself on the
  managed table came back; it now resets through `pgpm._acl_reset`, as `transmute`'s carry does. And every
  partition `obtain`, `extend_to`, the conversion's forward grid and a regrain's fine children mint kept the
  maintaining role's `ALTER DEFAULT PRIVILEGES` (`_own_like_parent` changes only the owner), so a role revoked
  on the table, or one the parent's row security filters, read every row of it by naming it. Each is now put
  at its owner's default privileges once it has the parent's owner. `tests/255` and `tests/256`, guarded by
  `bench/acl_grantor_owner_partitions.sh` with mutations `untransmute_acl_reset_spares_owner`,
  `partition_acl_unreset` and `regrain_fine_child_acl_unreset`.
- **One partition's retire raise defers that partition alone** (#907). `retain()`'s loop over `retire()` had no
  exception block of its own, and `retire()` isolates its `DROP` but not the write-block install before it, so a
  lock timeout there on one aged partition (a `VACUUM` or `ANALYZE` holding `SHARE UPDATE EXCLUSIVE` on it alone)
  unwound the whole retain step into `maintain()`'s one handler and rolled back the drops already completed for
  the other aged partitions of the same call, logged as one `skip_retain` with no range; retention of the whole
  table stood still while that one partition stayed locked. Each partition now runs in its own subtransaction,
  as in `_enforce_write_blocks` and `_archive_step`: the one that raised is logged `skip_retain` over its own
  `lo` and `hi` and taken again by the next call, and the rest are retired. `tests/263` (the lock held by a
  second session) under `bench/retain_loop_per_child_isolation.sh`, with the mutations
  `retain_loop_no_child_isolation` and `retain_loop_silent_skip`.
- **`obtain` and `extend_to` rebuild a forward cell whose partition was dropped by hand** (#908). Both took an
  attached `pgpm.part` row for a built cell without asking whether its partition still existed, so after a
  `DROP TABLE` on one of obtain's empty forward cells the cell was never rebuilt and nothing was logged: every
  write into its range was refused with `no partition of relation ... found for row`, for good, while
  `status()` still counted the partition and reported its `hi` as the ceiling. A row overlapping the cell
  whose `child_oid` no longer resolves is now forgotten first, logged `forget_dropped_partition` naming what
  was dropped, and the cell is built again (`pgpm._cell_attached`, one place for obtain's walk and extend_to's
  dry count and walk); `status().n_partitions`, `coarse_partitions` and `newest_bound` read only rows whose
  partition exists. `tests/264` under `bench/obtain_rebuilds_dropped_cell.sh`, with the mutations
  `obtain_trusts_dropped_cell`, `obtain_rebuild_keeps_stale_row` and `status_counts_dropped_cell`.
- **A regrain to a calendar step names a clamped first cell by its own start, so the per-year split
  completes on a year lattice that does not start in January** (#904). `_regrain_sub_name` left month and
  year targets to `_part_name` on the premise that a calendar child's edge sits on the target's lattice. A
  year lattice starts in the month the anchor reads in `partition_tz`, December west of UTC with the default
  anchor (or the month of a non-January `p_anchor`), so a monthly `America/New_York` monolith starting
  2023-03-01 clamped `[2023-03-01, 2023-12-01)` under `_p2023`, the name of the lattice cell after it, and
  `regrain_history(.., '1 year')` refused its own first copy as a relation it did not create. A clamped
  calendar cell now takes #783's rule, the year and the month read in `partition_tz` as its coarsest grains
  (`_p2023_03`); a lattice cell's name, and a clamp whose bounds read exactly at the step's grain, are
  unchanged. `bench/regrain_calendar_clamped_name.sh` runs tests/260 against the mutation
  `regrain_calendar_name_by_lattice`.
- **`incoming_fk_orphans` counts under the key's match type** (#909). It counted with `MATCH SIMPLE`'s rule
  (every FK column non-null and no parent row) for every key, so for a `MATCH FULL` key, which `preserve`
  re-adds as written, a row with some but not all of its FK columns null made `validate_incoming_fks` fail
  23503 while `incoming_fk_orphans` reported no orphan for that key. It now reads `confmatchtype`: a `MATCH
  FULL` key also counts its partly-null rows, a `MATCH SIMPLE` key still exempts any row with a null. Test
  265, guarded by `bench/incoming_fk_orphans_match_type.sh` with mutations `incoming_fk_orphans_simple_only`
  and `incoming_fk_orphans_full_everywhere`.
- **untransmute hands a primary key made since the conversion back under the managed table's name** (#901).
  #830's hand-back renamed each index the parent's DDL had cloned onto the monolith, but skipped every
  primary-key index to spare a pre-#789 conversion's original key, so a `PRIMARY KEY` added after converting a
  keyless table (or replacing the key) came back as the monolith clone's `t_p<label>_pkey` and `ON CONFLICT ON
  CONSTRAINT <its name>` failed with 42704. A primary key is now handed back when its monolith copy carries
  the name PostgreSQL chose for the clone (`pgpm._is_clone_pkey_name`, the partition's name clipped to fit 63
  bytes); a pre-#789 original key, under the name the table gave it, still keeps it. `tests/257`, guarded by
  `bench/untransmute_primary_key_name.sh` with mutations `untransmute_pkey_name_kept` and
  `untransmute_pkey_clone_name_unclipped`.
- **The table's identity sequences keep their names through transmute and untransmute** (#877, bullet 1).
  transmute added identity to the parent while it was still the staging `<table>_pgpm_new`, so the sequence
  was `t_pgpm_new_id_seq` on the converted table, and untransmute added it to the monolith before renaming
  it back, so it was `t_p<label>_id_seq` on the restored one; every `setval`, `GRANT ... ON SEQUENCE` or
  `ALTER SEQUENCE` naming `t_id_seq` failed with 42P01 after either. transmute now hands the parent's sequence
  the original's name (read under the cutover's lock, freed when the monolith's identity is dropped), and
  untransmute hands the restored table's the parent's, after the move into the parent's schema. `tests/258`,
  guarded by `bench/identity_sequence_name.sh` with mutations `transmute_identity_sequence_staging_name`,
  `untransmute_identity_sequence_monolith_name` and `untransmute_identity_sequence_renamed_early`.
- **A regrain step at a target the run in flight was not cut on is refused** (#905). The one-run-per-parent
  check (#267) skips the child the run is on, and only `set_regrain` refused a change of target (#554), so
  with an auto-regrain to 50 in flight a hand `regrain_step` or `regrain` at 20 on the same child resumed the
  run on the 20 grid and minted a copy `[40, 60)` beside its `[0, 50)`, and every later swap failed 'would
  overlap' (`skip_regrain`) until `regrain_cancel`; a `maintain` tick did the same to a run started by hand
  at a step other than `regrain_to`. Nothing records a run's step, so `regrain_step` now reads it off the run
  (`_regrain_off_grid`: every copy a sub-range of the requested grid, the cursor one of its boundaries) and
  refuses before it mutates anything. `tests/261` under `bench/regrain_retarget_in_flight.sh`, with the
  mutation `regrain_step_retarget_unchecked`.
- **The owners of a regraining partition and of its parent can write it mid-regrain** (#906).
  `_regrain_capture_grant` granted `INSERT` on the delta to the roles an ACL of the parent or the source
  lists, never to their owners, whose rights are implicit, so after `ALTER TABLE <parent> OWNER TO` (which
  does not reach the partitions) the old owner's every write into the regraining source failed 42501 on the
  delta until the swap, and a parent re-owned mid-regrain left its new owner the same. Both owners are now
  granted beside the ACL grantees, and re-synced every tick. `tests/262` under
  `bench/regrain_capture_owner_grant.sh`, with the mutation `regrain_capture_grant_acl_only`.
- **An export and a chunk never write one object key** (#890, "Archive object keys" bullet 1). An object key
  was claimed by its BASE, `<prefix><schema>.<name>`, and a chunk's key (`<base>_<stem><ext>`) and an
  export's (`<base'><ext>`, named after the child) have different bases, so `archive.to_s3('public.evt',
  'evt_0', ...)` of an untracked relation named like a chunk PUT `<prefix>public.evt_0.ndjson` over the chunk
  `retire()` had left as the only copy of its rows, while both claims and the ledger recorded it (and a chunk
  could PUT over such an export the other way round). Every key is now also claimed whole in
  `archive.object_key_claim`, by parent and kind, before its PUT; a writer that finds its key another's
  takes the oid shape, or is refused when that is taken too; the compressed NDJSON transport's `.gz` is
  inside the claimed key; and install claims every key `pgpm.archive_ledger` records. Test
  `tests/archive/db/40`, guard `bench/archive_key_full_claim.sh`, mutations
  `archive_object_key_whole_unclaimed`, `archive_ndjson_gz_outside_claim` and
  `archive_object_key_claim_unseeded`.
- **`retire()` refuses a crossing `DELETE` the parent's row-level security would filter** (#890, "Reads
  under RLS" bullet 1). The #873 lever asked the referencing tables but not the parent the crossing `DELETE`
  reads, and on a time grid nothing else reads it first, so a non-`BYPASSRLS` owner of a `FORCE`'d parent
  deleted only the referenced rows its policy admits, the declared `CASCADE` reached their referencing rows
  alone, and the dispatched detach was refused forever by the rest. `retire()` now asks
  `pgpm._refuse_filtered_reads` of the parent before the `DELETE`, changing nothing when it refuses. Test
  `tests/266`, guard `bench/retire_crossing_parent_rls.sh`, mutation `retire_crossing_parent_rls_unasked`.
- **`transmute` carries a policy whose expression names the table itself** (#897). The cutover replayed the
  table's policies onto the staging parent `<rel>_pgpm_new` before the renames, and `pg_get_expr` qualifies a
  reference to the outer row with the table's own name (a correlated subquery's `m.tenant = t.org`, and `org`
  written unqualified too), so the common tenant-membership policy failed `CREATE POLICY` raw in phase 3,
  after the write-rejecting bound and the claim had committed, on every retry; a subquery over the table
  itself bound to the oid the rename hands the monolith. The policies are still captured before the renames
  and are now replayed after them, beside the triggers, when the parent bears the name, so both mean the
  parent; `_refuse_oid_bound_dependants` loses the staging exemption that existed only for the pre-rename
  copies. `tests/250`, guarded by `bench/transmute_self_naming_policy.sh` (mutation
  `transmute_policies_on_staging`); `bench/transmute_cutover_order.sh` now requires the replay after the
  second rename and the capture before the first (`transmute_cutover_early_policy` and
  `transmute_cutover_late_policy_capture` replace `transmute_cutover_late_policy`), and
  `oid_bound_dependants_policy_on_staging` replaces `oid_bound_dependants_no_staging_exemption`.
- **`transmute` and `extend_to` refuse a null argument up front, naming it** (#896). Only `p_obtain`'s null
  was refused (#581), and PL/pgSQL reads every other null through three-valued logic as "not true": so
  `p_force_frontier`, `p_force_uuidv7` and `p_force_text_time => null` skipped their refusals and acted as
  `true`, `p_incoming_fks => null` passed its argument check, the incoming-key gate and the cutover's drop
  and left the referencing key on the monolith partition, `p_regrain_batch` or `p_paused => null` died at
  `pgpm.config`'s NOT NULL in the cutover after phases 1 and 2 had committed the write-rejecting bound,
  `p_tt_epoch => null` committed an unsatisfiable bound, and `extend_to`'s `p_max => null` walked a typo'd
  value step by step while a null `p_value` created partitions until the shared lock table ran out. One
  check, `pgpm._refuse_null_arguments`, now runs first in `_transmute` (both overloads) and in `extend_to`,
  over every argument with no documented null meaning (`p_retain`, the `text_time` shape arguments and
  `p_tt_alphabet` keep theirs). `tests/248` and `tests/249`, guarded by `bench/null_arguments_refused.sh`
  with mutations `transmute_null_arguments_accepted`, `extend_to_null_arguments_accepted` and
  `transmute_refuses_null_retain`.
- **An outgoing foreign key added to a parent mid-regrain restarts the run instead of being validated
  under the swap's lock** (#898). Each copy is born with its own validated instance of the parent's
  outgoing keys while it is still empty, so that the swap's `ATTACH PARTITION` adopts them, but the drift check compared
  columns and `CHECK` constraints only: a copy made before a key was added reached the swap without it, and
  `ATTACH` validated the key by scanning the copy while the swap held `ACCESS EXCLUSIVE` on the parent, and a
  key the parent dropped stayed on the fine child. `_regrain_shape_drift` now compares the parent's validated
  outgoing keys with each copy's by definition, so a key added, dropped or redefined restarts the run
  (`regrain_restart`) and every copy is made again carrying the keys the parent has now. `tests/251`, guarded
  by `bench/regrain_fk_drift_swap_scan.sh` (the copies' scan counters across the swap tick) with mutation
  `regrain_fk_drift_ignored`.
- **An outgoing foreign key added to a parent mid-regrain restarts the run instead of being validated
  under the swap's lock** (#898). Each copy is born with its own validated instance of the parent's
  outgoing keys while it is still empty, so that the swap's `ATTACH PARTITION` adopts them, but the drift check compared
  columns and `CHECK` constraints only: a copy made before a key was added reached the swap without it, and
  `ATTACH` validated the key by scanning the copy while the swap held `ACCESS EXCLUSIVE` on the parent, and a
  key the parent dropped stayed on the fine child. `_regrain_shape_drift` now compares the parent's validated
  outgoing keys with each copy's by definition, so a key added, dropped or redefined restarts the run
  (`regrain_restart`) and every copy is made again carrying the keys the parent has now. `tests/251`, guarded
  by `bench/regrain_fk_drift_swap_scan.sh` (the copies' scan counters across the swap tick) with mutation
  `regrain_fk_drift_ignored`.
- **`forget_missing` returns `pgpm_detach` to idle when it forgets the retirement that armed it** (#893). A
  referenced partition's retirement arms the standing job with `DETACH PARTITION ... CONCURRENTLY` by name,
  and `forget_missing` deleted the dropped parent's retiring row without disarming it, so the command outlived
  the retirement and pg_cron's next run detached the same-named partition of a table re-created under the same
  name and grid, its rows gone from every read of the parent with nothing logged. It now disarms a detach of a
  partition the forgotten parent was retiring, and only when no live retirement owns that exact command (a
  namesake already retiring the same-named partition keeps its own). `tests/246` under
  `bench/forget_missing_disarms_detach.sh`, with the mutations `forget_missing_keeps_detach_armed`,
  `forget_missing_disarm_any_command` and `forget_missing_disarm_owned`.
- **Regrain's change capture counts only while its trigger is `ENABLE ALWAYS`** (#892). `regrain_step` resumed
  a run whenever the source carried a trigger named `pgpm_regrain_capture`, never asking whether it fires, so
  one an owner disabled (`ALTER TABLE <partition> DISABLE TRIGGER USER` for a bulk load, or the same on the
  parent) or left origin-only (the matching `ENABLE TRIGGER USER`, or a run prepared by 0.6.0 and in flight
  across the upgrade, whose replica-role DML it skipped) still counted as live capture, and the swap attached
  copies that missed the changes made meanwhile: an UPDATE reverted, a DELETE resurrected. A resuming tick
  that finds the trigger in any other state now restarts the run (`regrain_restart`, `method` naming the
  state), discarding the copies and re-minting capture `ENABLE ALWAYS`, and the swap asks again under its
  `DETACH` and rolls back rather than drop the source. Tests 244 (owner DDL, a negative witness, the swap's
  check) and 245 (the upgraded state), guarded by `bench/regrain_capture_enabled_always.sh`,
  `bench/regrain_capture_origin_only_upgrade.sh` and the in-flight stage of `bench/upgrade_in_place.sh`, with
  mutations `regrain_capture_unarmed_ignored`, `regrain_capture_unarmed_no_remint`,
  `regrain_swap_capture_unchecked`, `regrain_capture_unarmed_disabled_only` and
  `upgrade_regrain_capture_origin_only_kept`.
- **`from_hypertable`'s scratch tables are named in `pg_temp`, never through the search_path** (#894). The
  tracked drain step's `pgpm_dbatch` and the keyed append-only cutover's `pgpm_htail` are temp tables `ON
  COMMIT DROP`, each dropped first by an unqualified `drop table if exists`. A fresh transaction has no temp
  table of that name, so the drop resolved through the search_path and took an operator's own
  `public.pgpm_dbatch` (the first drain batch, the drain procedure, a tracked cutover's pre-drain) or
  `public.pgpm_htail` (the cutover) with its rows; and under a search_path naming `pg_temp` after a schema
  holding one, the unqualified reads took that table as the batch, consuming the real batch's keys without
  applying them, or as the tail. Every drop, create, analyze and read now names `pg_temp`.
  `tests/timescale/db/47`, guarded by `bench/hypertable_scratch_tables_in_pg_temp.sh` with the mutations
  `hypertable_scratch_dbatch_drop_unqualified`, `hypertable_scratch_htail_drop_unqualified` and
  `hypertable_scratch_reads_unqualified`.
- **`retire`'s crossing step finds a mixed-case `text_time` cell's referencing keys whatever the referencing
  column's collation** (#900). `_crossing_keys` compared the referencing column against the cell's bounds
  under that column's own collation, the database default for one declared without `COLLATE`. Under `en_US`
  a KSUID cell whose bounds run from an uppercase to a lowercase digit is an empty interval, so no crossing
  key was found, the declared `ON DELETE CASCADE` ran on none of the referencing rows and the dispatched
  detach was refused by them on every run. The range is now compared under the control column's collation.
  `tests/253`, guarded by `bench/crossing_keys_control_collation.sh`; mutation
  `crossing_keys_referencing_collation`.
- **A regrain target finer than the control column's declared scale is refused up front** (#899).
  `_regrain_step_shape` refused a fractional target only on a column whose type name was `int2`, `int4` or
  `int8`, so `set_regrain('0.5')` on a `numeric(12,0)` key was stored, the run copied every sub-range, and at
  the swap `ATTACH PARTITION` rounded the fine bounds to the key's scale (`0.5` and `1.0` both to `1`) and
  failed `empty range bound` on every tick, with the capture trigger and the `TRUNCATE` refusal left on the
  source until the run was cancelled. The column is now judged by its effective scale: a step that is not a
  multiple of `numeric(p,s)`'s smallest unit is refused at call time and by `regrain_step`, `regrain()` and
  each tick, and a domain is judged by its base type and typmod. `tests/252`, guarded by
  `bench/regrain_target_column_scale.sh` with mutations `regrain_step_scale_by_typname` and
  `regrain_step_shape_domain_blind`.
- **`transmute` refuses a `numeric` `id` control holding `NaN`, `Infinity` or `-Infinity`, before anything
  commits** (#895). The id branch of the frontier read took the greatest value (`NaN` sorts above every number)
  with no finiteness check, where the `time` kind refuses `infinity`, so phase 1 committed a
  `pgpm_monolith_bound` CHECK and a claim with `hi = NaN`, phase 2's VALIDATE failed raw, and after the operator
  deleted the row the re-run resumed that bound and completed a monolith `[0, NaN)` that takes every future id,
  so `obtain`, retention and regrain never acted on the table again. A `-Infinity` minimum is refused too.
  `tests/247` pins the three refusals and the corrected re-run's finite monolith, guarded by
  `bench/transmute_non_finite_id_key.sh` with the mutation `transmute_id_frontier_non_finite`.
- **Every read of user rows refuses a caller whose reads row-level security would filter, asked of the
  relation it actually reads** (#873). `transmute` leaves the monolith its own `ENABLE` / `FORCE ROW LEVEL
  SECURITY` and policies and carries them onto the parent, and only the conversions asked
  `pgpm._refuse_filtered_reads` (#825). So for a non-superuser owner without `BYPASSRLS` of a `FORCE`'d table,
  `regrain` copied only the source rows its policies admit and the swap dropped the rest, and
  `from_hypertable_cutover`, asked only up front, swapped in a copy short of a row appended past the watermark
  and hidden by a policy committed while it prepared, its catch-up and conservation check agreeing through
  that policy. The same refusal is now asked by the write frontier (`obtain`, `extend_to`, `progress`, and on
  an `id` grid `retain`, `retire` and `set_retain`), `regrain_step`'s source, `untransmute`'s gate, the archive
  step (of the parent and the partition, before any strategy runs), `retire`'s referencing tables,
  `incoming_fk_orphans`, `check_uuidv7`, `check_text_time` and `check_time_monotonic`, `archive.to_s3`,
  `archive.to_s3_parquet` and the two S3 transports, the hypertable drains, and the cutover again under its
  lock; inside `maintain` each is that step's `skip_*` deferral. `tests/241` classifies every public entry
  point from the catalog (its modules' halves are `tests/archive/db/38` and `tests/timescale/db/46`) and
  `tests/242` holds regrain and untransmute by identity, guarded by `bench/reads_under_caller_rls.sh` with
  one `rls_*_unchecked` mutation per site (19).
- **A regrain survives its parent being moved to another schema mid-run** (#872, bullet 1). Its copies are
  standalone tables that stay where they were made, but `_regrain_copy_rel` (the swap gate, the attach, the
  reconcile) and the copy branch looked each one up in the parent's CURRENT schema, so after `ALTER TABLE
  <parent> SET SCHEMA` every tick refused at the swap gate (`skip_regrain`) and the run never finished; a copy
  part-filled at the move was replaced by a second one beside the parent, the first left full of rows; and the
  swap's `archive_coverage_reset` named a source that never existed. Every copy is now found in the schema of
  the relation its `child_oid` records, new copies are made beside the source, and the reset names the source
  where it was. Mutations `regrain_copy_rel_parent_schema`, `regrain_copy_branch_parent_schema` and
  `regrain_coverage_reset_parent_schema`.
- **A preserved incoming key comes back against the table it was recorded for, by identity** (#872, bullets 2
  and 3). `restore_incoming_fks` (and so `maintain`, regrain's swap and `uninstall.sql`) and `untransmute`
  replayed `pgpm.dropped_fk.definition` verbatim, its `REFERENCES` naming the parent as it was at the
  conversion, so after a `SET SCHEMA` or a `RENAME` the key came back against whatever now held the old name
  (logged `restore_incoming_fk`, RI against the managed table off) or died 42P01 every tick, and inside a
  regrain swap was put back nowhere. Every re-add now renders the definition against the referenced table by
  oid (`pgpm._fk_readd_definition`). And `uninstall.sql` exempted a suspended record from its refusal when any
  key of that NAME was live on the referencing table; it now asks for that key against the managed table, as
  `_forget_dangling_fks` adopts, so a namesake key against another table no longer lets the schema drop take
  the only record of the real one. Tests 239 (a moved-parent conformance suite: one table moved before every
  lifecycle stage, a namesake planted where the old resolution lands) and 240, guard
  `bench/recorded_identity.sh`, mutations `restore_fk_replays_recorded_definition`,
  `untransmute_fk_replays_recorded_definition` and `uninstall_fk_exempt_by_name`.
- **A tracking `from_hypertable_copy` of a renamed hypertable builds its key index** (#872, bullet 4). The copy
  pre-built the key's index under `<conname>_pgpm_new` whatever held that name, and a key keeps its name across
  `ALTER TABLE ... RENAME`, so an abandoned tracking copy taken under the old name made it die `already exists`.
  The copy and the cutover now both ask `pgpm._from_hypertable_key_tmp`, which takes the name already on the
  destination, else the first of `<conname>_pgpm_new` and `pgpm_new_<index oid>` that is free, so they agree
  and the cutover adopts the copy's index. `tests/timescale/db/45`, mutations `hypertable_copy_key_tmp_by_name`
  and `hypertable_cutover_key_tmp_unshared`. The helper's fallback would also repair the #707 cut temp name, so
  the mutation `hypertable_tmp_name_cut` now puts that cut back inside the helper as well, and
  `bench/hypertable_index_names.sh` still fails against it.
  and `hypertable_cutover_key_tmp_unshared`.
- **A synchronous export never writes over another relation's object, and every archive key comes from one
  function** (#872). `archive._child_object_key` keyed `archive.to_s3` and `archive.to_s3_parquet` by
  `<prefix><schema>.<child>` with no owner, and both PUT unconditionally, so after the documented
  to_s3-then-drop workflow and `pgpm.forget_missing()` a new table taking the dropped table's name exported its
  same-named partition over the dropped table's export, the only copy of those rows. #822 had given the
  automatic chunk keys an owner and left these. Every key, chunk or export, is now assembled and claimed in
  `archive._owned_key`: the first parent to write under a name keeps the shape it always had, any other gets
  its oid in the key (`<prefix><schema>.<child>.<oid><ext>` for an export). `scripts/check_archive_object_keys.py`
  (the `Archive object keys` lint job) fails CI when a key prefix is assembled anywhere else, and
  `tests/archive/db/39` under `bench/archive_key_owner_every_path.sh` takes every path that writes an object
  through a namesake, with one mutation per site: `archive_child_key_unclaimed`, `archive_object_key_unclaimed`,
  `archive_to_s3_key_inline`, `archive_to_s3_gz_key_inline`, `archive_to_s3_parquet_key_inline`,
  `archive_ndjson_strategy_key_inline` and `archive_parquet_strategy_key_inline`.
- **A regrain in flight across the upgrade that added `config.regrain_source_mark` no longer swaps in stale
  copies** (#878). Such a run carries a null mark, `_regrain_source_drift` answered null for it, and
  `regrain_step` then recorded the source as it was at that tick as the mark, so copies made before a
  same-type `ALTER ... USING` rewrite (which fires no row trigger) were blessed and attached with the
  pre-rewrite values, with no `regrain_restart`. A null mark over copies is now drift, and the run restarts;
  re-running `install.sql` restarts every such run that has copies at the upgrade itself (logged
  `regrain_restart`, `method` naming the upgrade) and only records the mark of one that has none.
  `tests/243` under `bench/regrain_null_source_mark.sh` (mutation `regrain_null_mark_adopted`), and a new
  in-flight stage of `bench/upgrade_in_place.sh` that upgrades a run with a copy from v0.6.0 (mutations
  `upgrade_regrain_mark_adopted`, `upgrade_regrain_mark_block_noop`).
- **`bench/hypertable_time_rendering.sh` carries the shared pgTAP verdict, and `bench/wrapper_tap_verdicts.sh`
  finds every timescale wrapper by what it does** (#844). The wrapper added for #791 and #793 kept the pre-#795
  verdict in its `run_file`: psql's exit ignored, a plan shortfall read only from finish()'s line, a `not ok`
  counted only with a description, so it passed `tests/timescale/db/35` and `36` after a session lost 1 of 3
  assertions in, or after an undescribed assertion failed. The guard that holds every wrapper to the shared
  block never judged it, because it discovered wrappers by the literal `-f "$TEST_FILE"` and this one ran
  `-f "$file"`. The wrapper now runs the shared block, and the guard takes any bench script that names a
  `tests/timescale/db/` file and runs a file through psql with tuples-only unaligned output, in any spelling;
  each must carry the block, the scan is held to positive and negative spellings and must find every wrapper on
  its name list, and a seventh fixture fails an undescribed assertion. Mutation
  `wrapper_verdict_time_rendering_hand_rolled`.
- **The timescale and observe tracks fail a file whose psql session was lost** (#819, F9-01). `run_timescale`
  and `run_observe_file` judged a pgTAP file by grepping its output and never read psql's exit status, so the
  verdict passed a file whose session died part-way (FATAL, no `ERROR:`, finish() never reached); as run,
  `set -e` then ended the track at that call with no verdict, no teardown and its remaining files unrun. Both
  keep the exit status and fail any file psql did not run to its end. `bench/tap_verdict.sh` now evaluates
  each track's whole verdict region, the capture included, against two lost-session fixtures besides its
  four, with the mutation `tap_verdict_ignores_psql_exit`.
- **`bench/doc_env_knobs.sh` checks every knob in a documented command's prefix** (#847). Its command regex
  bound only the `NAME=value` next to `./test.sh`, so `TS_VERSIONS='2.9.1' TS_PG_TAGS='15.14.1.127' ./test.sh
  timescale` passed on the read TS_PG_TAGS although TS_VERSIONS, the #599 knob, is read nowhere. The prefix is
  now matched whole and walked assignment by assignment, and a second control plants an unread knob before a
  read one and requires both to be extracted, the first reported unread. The new mutation
  `onboarding_unread_knob_first` puts that two-knob command in ONBOARDING.md.
- **Check 6 of `scripts/check_living_docs.sh` reads the action a `pgpm.log` write names, not any line holding
  the literal** (#848). An action counted as written when its quoted literal was on any non-comment install.sql
  line, so a runbook alert on `action = 'copy_swap_drop'` passed although that literal is only ever the
  `method` of an action `regrain` row and the alert can never fire. The check now tokenizes the three install
  files (comments and string literals known) and reads the `action` position of every `insert into pgpm.log
  (...)`, `values` (one row or many) or `select`, a CASE's THEN and ELSE literals included; a write whose
  action is not a literal, or one inside dynamic SQL, fails the check naming the site. `--selftest` gains
  both re-breaks, and `bench/doc_log_actions.sh` a control planting the method value, with the mutation
  `runbook_alert_on_method`.
- **`bench/transmute_cutover_order.sh` orders the policy replay, not only the ENABLE ROW LEVEL SECURITY**
  (#845). Its PASS line named the RLS and policies replay, but it located only the ENABLE, so a copy of
  `_transmute` whose CREATE POLICY loop ran after both cutover renames, inside the outage #344 keeps the new
  parent's configuration out of, installed, transmuted and passed. The CREATE POLICY is now found as the
  `execute format('...` that issues it, exactly once, before the first rename. The new mutation
  `transmute_cutover_late_policy` moves that loop alone.
- **The `_frontier_native` half of #325 has a guard of its own** (#846). `tests/85` and
  `bench/frontier_drought.sh` asserted only that a partition covers now() and that a write at now() is accepted,
  which transmute's monolith already satisfies through its own inline `greatest(decoded, now())`, so both passed
  with `_frontier_native` reverted to the stale data maximum, the defect that refuses every write once a drought
  outlasts the monolith. Both now also require `_frontier_native` itself at or past now() and a forward
  partition past the monolith covering now() + 1 month, and each guard tick runs `maintain_obtain` after
  `maintain`. The new mutation `frontier_native_data_only` reverts that one site; `frontier_data_only` still
  reverts both.
- **`from_hypertable` recognises its own change capture by its record, not by the table's current name**
  (#842). The swap's trigger carry (#787) left out the capture trigger whose function was named for the
  hypertable's current schema and relname, so after a tracking copy that was never cut over and an
  `ALTER TABLE ... SET SCHEMA` or `RENAME`, the stale trigger was carried onto the copy and cloned by
  `transmute` onto the parent and every partition, logging every write into a delta nothing drains. A trigger
  whose function sits beside a delta carrying the copy's horizon comment is left out now, as
  `pgpm_core/uninstall.sql` finds such a copy (#737); a copy from a release that wrote no record is still
  known by the derived name. `tests/timescale/db/42` under `bench/hypertable_carry_capture_by_record.sh`,
  with the mutations `hypertable_carry_capture_by_name` and `hypertable_carry_capture_unrecorded`;
  `hypertable_cutover_carries_capture` now removes both ways of knowing the capture.
- **`from_hypertable` carries the hypertable's publication membership and replica identity** (#816). The swap
  drops the hypertable, which took it out of every publication `FOR TABLE` it, and renames in a `LIKE` copy
  with the `DEFAULT` identity, so `transmute`, which carries both from a plain table (#566, #782), carried
  nothing: subscribers silently stopped receiving the table, and a keyless `REPLICA IDENTITY FULL` one under a
  publication of updates refused every `UPDATE` and `DELETE` with 55000. Both are put on the copy in the swap
  now, each membership with its row filter and column list, and a filtered membership in a publication with
  `publish_via_partition_root = false`, which `transmute` refuses on a partitioned table, is refused before the
  swap by the preflight and by the cutover under its lock (`_from_hypertable_check_publications`).
  `tests/timescale/db/43` under `bench/hypertable_carry_publications_replica_identity.sh`, with the mutations
  `hypertable_swap_drops_publications`, `hypertable_swap_drops_replica_identity`,
  `hypertable_publications_unchecked_up_front` and `hypertable_cutover_publications_unchecked`.
- **`from_hypertable_cutover` adopts a key index only when it is on its destination** (#768). It skipped a
  key's index build whenever any relation in the schema held the temp name `<conname>_pgpm_new`, so after a
  tracking copy that was never cut over and a `RENAME` of the hypertable (whose key keeps its name), the stale
  copy's index was taken for the key's and the swap failed adopting it after the whole copy. The index is
  adopted now only when `pg_index.indrelid` is the destination; otherwise the key is built under the oid form
  of the temp name. `tests/timescale/db/44` under `bench/hypertable_key_index_on_destination.sh`, with the
  mutation `hypertable_key_index_by_name`.
- **A role granted DML on the regraining partition itself can write it mid-regrain** (#843). The capture
  trigger inserts into the delta as the writer, and `_regrain_capture_grant` gave INSERT on the delta to the
  grantees of DML on the parent only, so a role granted `UPDATE` or `DELETE` directly on the source partition
  (a write PostgreSQL permits with no grant on the parent) got 42501 on every write into it for the life of the
  regrain. The source's own grantees, table- and column-level, are granted too, at the prepare tick and on every
  tick after it. `tests/236` under `bench/regrain_capture_source_grantees.sh`, with the mutation
  `regrain_capture_grant_parent_only`.
- **A regrain finds its source where it is after `ALTER TABLE ... SET SCHEMA` on the parent** (#768, F3-04 and
  F3-12). `regrain_step`, the capture install, `_regrain_capture_active`, the reconcile's read of the source
  rows, the janitor, `_regrain_reclaim` and install.sql's #650 upgrade block resolved the source as the parent's
  current schema plus its name, so after the documented-safe schema move every auto-regrain tick failed
  `relation <new schema>.<monolith> does not exist`, the monolith could never be regrained, and re-running
  install.sql no longer put a missing TRUNCATE guard back on an in-flight source. They all ask the new
  `pgpm._regrain_child_rel`, the relation `pgpm.part.child_oid` recorded. `tests/237` and
  `bench/regrain_moved_parent_identity.sh`, with the mutations `regrain_step_source_parent_schema` and
  `regrain_upgrade_guard_parent_schema`.
- **A regrain's delta is read and cleared in its own schema after the parent moves** (#555, F3-11).
  `regrain_cancel`, the swap, `_regrain_reclaim`, the purge, the reconcile, the per-tick grant and
  `untransmute` paired the delta's recorded name with the parent's current schema, so a cancel after a
  mid-regrain schema move emptied an unrelated table of that name in the new schema and left the real delta
  holding its captured changes. Each takes the schema `_regrain_capture_names` resolves from the recorded
  `regrain_delta_oid`. `tests/237` part C under `bench/regrain_moved_parent_identity.sh`, with the mutation
  `regrain_cancel_delta_parent_schema`.
- **`set_regrain` checks a clamped first cell's name the way `regrain_step` will mint it** (#815, F3-06).
  `_regrain_names_fit` rendered every cell with `_part_name` at the target step's granularity, but a clamped
  first sub-range is named through `_regrain_sub_name` at a finer, longer label, so a table name that fit the
  day label and not the hour one was accepted and every auto-regrain tick then logged `skip_regrain` on the
  63-byte limit. Each cell is now named through `_regrain_sub_name` with the bounds `regrain_step` gives it.
  `tests/238` under `bench/regrain_names_fit_clamped_cell.sh`, with the mutation `regrain_names_fit_part_name`.
- **A converted table holds exactly the original's grants, not those plus its creator's default privileges**
  (#838). transmute's parent and from_hypertable's `CREATE TABLE ... LIKE` copy are new tables, born with the
  creating role's `ALTER DEFAULT PRIVILEGES` (on Supabase, `anon` and `authenticated` in `public`), and both
  grant carries only added the original's grants onto them, so a privilege REVOKEd on the table or hypertable
  was held by the converted table readers query. Both now go through one lever, `pgpm._acl_carry_ddl`, whose
  first statement (`pgpm._acl_reset`) revokes everything the new table holds, its owner's privileges included,
  before the original's table and column grants are replayed; an original with a `NULL` ACL gives its owner
  ALL and nobody else anything. `tests/235` under `bench/transmute_grant_carry_resets_acl.sh`, with the
  mutations `acl_carry_additive`, `acl_reset_no_owner_default` and `acl_reset_spares_owner`, and
  `tests/timescale/db/38` under `bench/hypertable_grant_carry_resets_acl.sh`, with
  `hypertable_acl_carry_unreset`.
- **One partition's archive raise defers that partition alone** (#833). `_archive_step`'s per-candidate loop had
  no exception block of its own, so with `archive_batch` above 1 a strategy that raised for one partition (the
  documented `skip_archive` retry path) unwound the whole step and discarded the ledger rows of every other
  partition archived in the same call, after the strategy had already run, and uploaded, for them; while one
  partition kept failing no partition of the parent recorded coverage or retired. Each candidate now runs in
  its own subtransaction, as in `_enforce_write_blocks`: the one that raised is logged `skip_archive` over its
  own `lo` and `hi` and retried with the same chunk, and the rest of the batch records what it archived.
  `tests/228` under `bench/archive_step_child_isolation.sh`, with the mutation `archive_step_no_child_isolation`.
- **A retirement finished by the one-step `DROP` returns `pgpm_detach` to idle** (#835). `retire` disarmed the
  standing job only on its referenced path, so a partition whose detach was dispatched while an incoming FK
  existed, and whose FK was dropped before pg_cron ran it, was dropped on the one-step path with the job left
  running `DETACH PARTITION` of the dropped name every tick. That path now disarms too, before the drop, and
  only if the job still holds this partition's command. `tests/229` under `bench/retire_one_step_disarm.sh`,
  with the mutations `retire_one_step_no_disarm` and `retire_one_step_disarm_any`.
- **`extend_to`'s `p_max` counts the forward edge's own cell** (#836). The dry count counted grid steps past the
  frontier's floor while the walk also built the frontier's own cell when nothing covered it, so
  `extend_to(..., p_max => 1)` could create two partitions. The edge's cell is counted when it is missing,
  asked the way the walk asks it. `tests/230` under `bench/extend_to_edge_cell_count.sh`, with the mutations
  `extend_to_edge_uncounted` and `extend_to_edge_always_counted`.
- **`retire`'s crossing step reads a `timestamptz` referencing key back through `_ts_text`** (#814). `_crossing_keys`
  rendered it with a bare `::text`, so under a DateStyle that abbreviates zones in a zone whose abbreviation is
  ambiguous (`SQL` in Asia/Kolkata, whose `IST` PostgreSQL before 18 reads as Israel) the crossing `DELETE`
  matched nothing: the FK's declared `ON DELETE` was never applied, `retain_crossing` reported 0 rows, and the
  dispatched detach could never succeed. `tests/231` under `bench/crossing_keys_datestyle.sh`, with the
  mutation `crossing_keys_bare_text`.
- **`archive.to_s3` pages every row whatever the session's DateStyle and TimeZone** (#834). Its keyset
  cursor crossed from one page's query to the next as the control value's text in the caller's session, and a
  non-ISO DateStyle names a timestamptz's zone by abbreviation: in Asia/Shanghai under DateStyle Postgres the
  `CST` it wrote read back as US Central, the cursor jumped 14 hours, the next page skipped the rows in between
  and the conservation check refused every multi-page export with nothing writing (in Pacific/Guam the `ChST`
  did not parse at all and the second page raised). The cursor is now rendered by the new
  `archive._cursor_text`, which pins TimeZone and DateStyle as `archive._object_stem` does, so it reads back as
  the same value in any session. The objects' content is unchanged. `tests/archive/db/36` under
  `bench/archive_to_s3_cursor_session.sh`, with the mutation `to_s3_cursor_session_text`.
- **A Parquet encode no longer leaves lock-table entries behind it** (#632, F5-04). `archive._pq_snapshot`
  created its temp table and the encoders dropped it on every encode, and a dropped relation's locks are held
  to transaction end, so each encode left about eight entries in the shared lock table until commit and one
  `pgpm._archive_step` grew it by eight per chunk archived. The snapshot relation is now reused by every
  encode of the same shape in a transaction (emptied, then refilled by one INSERT, still one snapshot), and
  rebuilt only when the shape changes; the files are byte for byte the same. `tests/archive/db/37` under
  `bench/archive_parquet_snapshot_locks.sh`, with the mutation `parquet_snapshot_per_encode_table`; the
  `parquet_per_column_statements` mutation is re-anchored on the new lifecycle.
- **`from_hypertable` migrates a hypertable with a `serial` column, and keeps the sequences it owns** (#839).
  The copy is made `LIKE ... INCLUDING DEFAULTS`, so a serial column's default on it called the sequence the
  SOURCE's column owned, and the cutover's `DROP TABLE` of the source failed on that dependency after the whole
  online copy, every time; a sequence owned through a column that no default named was dropped with the source,
  silently. The swap now lets go of every sequence the source owns before the drop and hands each to the same
  column of the table renamed into its place, once it carries the source's owner (a one-step hand-over is
  refused when another role owns the table). `tests/timescale/db/39` under
  `bench/hypertable_cutover_serial_sequences.sh`, with the mutations
  `hypertable_cutover_serial_sequence_kept_by_source` and `hypertable_cutover_serial_owned_before_carry`.
- **`from_hypertable_cutover` refuses outgoing foreign keys changed since the copy** (#840). Only the copy
  carries outgoing keys, and the shape check (#738) compared columns, defaults and CHECKs but not keys, so a key
  added to the hypertable between the copy and the cutover was dropped with the source and the migrated table
  accepted orphans, and a key dropped in that window came back. `_from_hypertable_shape_diff` now compares the
  outgoing keys by name and definition, up front and under the lock. `tests/timescale/db/40` under
  `bench/hypertable_cutover_foreign_keys.sh`, with the mutation `hypertable_shape_ignores_foreign_keys`.
- **`from_hypertable_cutover` asks the exclusion-constraint check again under its lock** (#841). It was asked
  only up front, so an `EXCLUDE` constraint added while the cutover prepared (the pre-drain, the index
  pre-builds) was dropped by the swap and the migrated table accepted the rows it rejected. It is now asked
  under the `ACCESS EXCLUSIVE` too, like the shape, key and frontier checks. `tests/timescale/db/41` and a
  second-session window under `bench/hypertable_cutover_exclusion_window.sh`, with the mutation
  `hypertable_cutover_exclusion_unchecked_under_lock`; the up-front call's mutation,
  `hypertable_cutover_no_exclusion_check`, moves to this guard, whose first part pins the refusal before the
  pre-drain commits.
- **`check_text_time` reads the alphabet as data, so one malformed row no longer aborts the sample** (#837).
  Both its shape tests (the sample's and the column maximum's) spliced the alphabet raw into the regex
  `'[^' || alphabet || ']'`. Under an alphabet `transmute` accepts, such as `+-0123456789`, the `-` made a range,
  a value with `,` in its timestamp field counted as shaped, and `_text_time_to_ts` raised on it, aborting
  `check_text_time` and `transmute`'s sampling step (`p_force_text_time` included); an alphabet holding `\`
  left the bracket unclosed and raised on every column. Both now ask `_text_time_shaped`, whose `translate()`
  test exists for exactly this. `tests/232` under `bench/check_text_time_alphabet_syntax.sh`, with the mutation
  `check_text_time_alphabet_regex`.
- **BC values floor to their own calendar cell, and BC or five-digit-year child names are recognised** (part of
  #769). `_grid_floor`'s month and year branch counted years with `extract(year)`, which has no year 0, so a BC
  value floored a whole year early from the default 2000 anchor (an interrupted `transmute` of a table with BC
  rows was refused on its same-step re-run, and `regrain_step` of a BC monolith minted an inverted copy child)
  and an AD value floored above itself from a BC anchor. Years are now counted astronomically. And
  `_is_fine_child_label`'s time pattern matched no `_bc` label and no year past 9999, so `transmute`'s orphan
  guard (both its relation and its type half) and `restore_incoming_fks`'s in-flight gate let such names
  through; it now accepts both. `tests/233` under `bench/grid_floor_across_era.sh` (mutation
  `grid_floor_calendar_no_year_zero`) and `tests/234` under `bench/fine_child_label_bc_wide_year.sh` (mutation
  `fine_child_label_time_four_digit`).
- **`transmute` carries a secondary unique constraint as a constraint, under its name and with its
  deferrability** (#828). Step 9b carried every unique index beside the reused key as a bare partitioned index
  `<name>_pgpm`, including one that backs a `UNIQUE` constraint, so `INSERT ... ON CONFLICT ON CONSTRAINT
  <name>` failed with 42704 on the converted table, and a `DEFERRABLE` constraint was immediate on the parent and
  on every forward partition, where a one-statement swap the table accepted before failed with 23505. Such a
  constraint is now carried the way the key is (#789, #731): the monolith's copy makes way as
  `pgpm_key_<index oid>` (refused up front if that name is taken), the parent takes the name with the
  original definition (`NULLS NOT DISTINCT`, `INCLUDE`, the index's storage parameters, `DEFERRABLE`,
  `INITIALLY DEFERRED`), the monolith's own index is attached under it, and `untransmute` hands every such name
  back, not only the key's. `tests/225` under `bench/cutover_secondary_unique_constraint.sh`, with the mutations
  `cutover_secondary_unique_as_index`, `untransmute_unique_names_one` and `transmute_unique_key_clash_unchecked`.
- **`transmute`'s parent takes the table's tablespace** (#829). The cutover's `CREATE TABLE ... (LIKE ...)
  PARTITION BY` named no `TABLESPACE`, so the parent was created in the database default, and so was every
  partition `obtain`, `extend_to` and a regrain minted from it: every row written past the monolith filled the
  default volume instead of the one the table was on. The parent is now put in the table's tablespace, read
  under the cutover's lock, and a caller without `CREATE` on that tablespace is refused before anything is
  committed. `tests/226` under `bench/cutover_tablespace.sh`, with the mutations `cutover_tablespace_dropped` and
  `transmute_tablespace_unchecked`.
- **`untransmute` hands back a table moved with `ALTER TABLE ... SET SCHEMA`** (#827). Moving the managed
  table leaves its partitions, the monolith among them, where they were (#727), but the reverse resolved the
  restored table and built its comment, grant, policy and publication statements as `<the parent's
  schema>.<name>`, where nothing of that name exists once the parent is dropped, so every reverse of a moved
  table died raw with 42P01. The restored table is now named by the oid `transmute` recorded and moved into the
  parent's schema, where the application has been finding it, after its preserved incoming FKs are re-added.
  `tests/220` under `bench/untransmute_moved_parent.sh`, with the mutations
  `untransmute_moved_parent_resolved_by_name` and `untransmute_moved_parent_not_moved`.
- **`untransmute` hands back the names of indexes and constraints made since the conversion** (#830). A
  `UNIQUE` constraint or index created on the managed table clones onto the monolith under an auto-name of the
  partition's, which the DETACH kept, and only the key was renamed back (#789), so after a reverse
  `ON CONFLICT ON CONSTRAINT <name>` failed with 42704 and `DROP INDEX <name>` found nothing. Each copy is now
  found by the parent index it is attached under and given that index's name; a carried secondary index keeps
  the table's own name, and a pre-#789 conversion's primary key keeps the name it had. `tests/221` under
  `bench/untransmute_index_names.sh`, one mutation per rule.
- **`untransmute` hands back the managed table's replica identity** (#815, F1-06). `ALTER TABLE ... REPLICA
  IDENTITY` on the managed table lands on the parent only, so the restored table took the monolith's
  conversion-time identity: a table set `FULL` since came back `DEFAULT`, publishing key-only before-images,
  and one set `DEFAULT` came back `FULL`. It now takes the parent's, `USING INDEX` mapped to its own index
  attached under the parent's identity index, and only when the two differ. `tests/222` under
  `bench/untransmute_replica_identity.sh`, with the mutations `untransmute_replica_identity_not_restored` and
  `untransmute_replica_identity_kind_only`.
- **A preserved incoming key re-added by hand while still recorded as dropped is adopted** (#832).
  `_forget_dangling_fks` reconciled only a record marked re-added whose key is gone, never the opposite: a
  record still marked dropped (`restored_at` null) whose key the operator had put back, the remedy uninstall's
  refusal and the guide name. `restore_incoming_fks` re-added it blindly and logged `fail_restore_incoming_fk`
  ("already exists") on every call, and `untransmute`, whose pre-drop loop drops only re-added records, left
  the key on the parent and died with 23503 at the DETACH. The reconcile every caller shares now marks such a
  record re-added (validated as the live key is), logged `adopt_incoming_fk`, when the live key is on its
  referencing table, under its name, against this parent; a namesake against another table is not adopted.
  `tests/227` under `bench/restore_fk_adopts_live_key.sh`, with the mutations
  `dropped_fk_live_key_never_adopted` and `dropped_fk_adopt_by_name`.
- **`untransmute` refuses an object typed by the parent's row type, rather than dying on its `DROP`** (#831).
  `_refuse_oid_bound_dependants` (#779) asked `pg_depend` about the parent's `pg_class` row alone, so a
  function taking the managed table's row type (or an array of it), or a column of that type, created since
  the conversion passed the refusal and the reverse died raw at `drop table` with 2BP01 ("other objects depend
  on it"). The helper now asks about the parent's row type and its array type as well, and names each
  function, column or domain with the rest. `tests/223` part A under `bench/untransmute_drop_dependants.sh`,
  with the mutations `untransmute_dependants_monolith_counted` and `oid_bound_dependants_row_type_unasked`.
- **`transmute` refuses what is typed by the table's row type, and `untransmute` what sits over a partition
  its `DROP` takes** (#815, F1-02 and F10-06). The cutover hands the table's row type to the monolith with
  its oid, so a function taking the table's rows, another table's column of that type or a domain over it
  followed the rename: `f(t)` stopped taking the table's rows (42883), the column rejected them (42804), and
  the monolith could never be dropped. They are refused now, named with the views and rules, before anything
  is committed and again under the cutover's lock. `untransmute`'s `DROP` cascades to the empty forward
  partitions and any `DEFAULT`, and it asked about the parent alone, so a view over one of them died raw
  after the detach; it now asks about every partition but the monolith, oid and row type, leaving out a
  partition's own rules and policies, which go with it. `tests/224` under
  `bench/transmute_row_type_dependants.sh` (mutations `oid_bound_dependants_row_type_unasked`,
  `oid_bound_dependants_array_type_unasked`) and `tests/223` part B under `bench/untransmute_drop_dependants.sh`
  (`untransmute_dependants_parent_only`, `untransmute_dependants_partition_rules_named`).
- **A renamed control column is followed, not lost** (#826). `pgpm.config.control_column` records the column
  by name, and every reader resolved it by that name, so after `ALTER TABLE ... RENAME COLUMN` of the
  partition key (which PostgreSQL allows, the table routing on) obtain's ceiling check ran `select
  '<bound>'::`, every tick logged `skip_obtain` and the forward grid never grew again; the id frontier,
  `extend_to`, regrain's copy and `untransmute` named a column that no longer exists, and `set_partition_tz`
  and `set_regrain` failed open on a type lookup that found nothing (a naive grid's zone was moved). Every
  load of a config row now goes through `pgpm._control_followed`, which takes the column's current name from
  the parent's partition key (`pg_partitioned_table.partattrs`), in the core and in `pgpm_archive`.
  `tests/219` under `bench/control_column_rename.sh` (its last part checks that every whole-row config load in
  the installed code is followed), with the mutations `control_followed_noop`, `control_followed_obtain_only`
  and `control_followed_missing_at_retain`.
- **An archive object key is never reused by a different relation** (#822). `archive._object_key` named a
  chunk by the parent's current `<prefix><schema>.<table>` and its `lo`, and both transports PUT
  unconditionally, so after the runbook's drop and `pgpm.forget_missing()` (which deletes the dropped table's
  ledger rows) a new managed table taking the same name and prefix archived its `[0, 10000)` over the old
  table's only copy of the rows `retire()` had dropped. The first relation to archive under a name now claims
  it in `archive.object_key_owner`, which nothing deletes from, and keeps its keys unchanged; any other
  relation's chunks carry its oid, `<prefix><schema>.<table>.<oid>_<stem><ext>`. Install seeds the claims from
  the keys `pgpm.archive_ledger` already records, so tables archived before the upgrade are covered.
  `tests/archive/db/34` under `bench/archive_key_reused_name.sh`, with the mutations
  `archive_object_key_reusable_name` and `archive_object_key_owner_unseeded`.
- **A BC chunk and an AD chunk of one table no longer share an object key** (#823). `archive._object_stem`
  kept only the digits of a time kind's `lo` rendered in UTC, which threw away the BC era marker, so 2024-01-01
  BC and 2024-01-01 AD of one table were keyed alike and the second PUT replaced the first while both reported
  their rows archived; the same projection collapsed a fraction of a second onto a five-digit year. The stem
  now ends `BC` for a BC instant and keeps a fraction's decimal point (`2024010100000000BC`,
  `20240101000000.100`); a whole-second AD stem is unchanged. `tests/archive/db/35` under
  `bench/archive_stem_era.sh`, with the mutation `archive_object_stem_drops_era`.
- **A regrain restarts on DDL that changes its source's values, not only its columns** (#824). `_regrain_shape_drift`
  compared the copies with the parent by column signature alone, so a column dropped and added back under its old
  name and type, or `ALTER COLUMN ... TYPE <same type> USING <expression>`, which fire no row trigger, left the copies
  made before them looking current, and the swap attached them: the regrained range served the dropped column's
  values, or the pre-rewrite ones. The prepare tick now records the source's relfilenode and each column's attnum in
  the new `config.regrain_source_mark`, and a resumed tick that finds either changed while copies exist restarts the
  run from the source (`regrain_restart`, naming the rewrite or the replaced columns). `tests/216` parts A and B
  under `bench/regrain_drift_values.sh`, with the mutation `regrain_value_drift_ignored`.
- **A regrain survives a `CHECK` added to its parent, and a key column renamed or widened, mid-flight** (#817, F3-03,
  F7-03, F10-02, F3-02, F3-08). The copies lacked a `CHECK` added to the parent after them, which the swap's `ATTACH`
  requires, so every swap tick failed 'child table is missing constraint'; the parent's `CHECK` constraints are now
  compared with the copies' by name and expression, and a difference restarts the run. And the capture apparatus kept
  the key's names and types from the prepare, so after a rename every write into the regraining range failed 42703 and
  every reconcile of a change captured before it failed, and after a widening every key past the old type failed
  22003, each until the swap. A resumed tick now compares the delta's columns with the key and, when they differ,
  restarts the run and re-mints capture for the key as it is now; a write between the `ALTER` and that tick is still
  refused, never lost. `tests/216` part C under `bench/regrain_drift_values.sh`, with the mutation
  `regrain_check_drift_ignored`, and `tests/217` under `bench/regrain_capture_follows_key.sh`, with the mutations
  `regrain_capture_drift_ignored` and `regrain_restart_keeps_capture`.
- **`transmute` and `from_hypertable` refuse a caller whose reads row-level security would filter** (#825).
  Both read the table as the caller, so on a table with `FORCE ROW LEVEL SECURITY` a non-superuser owner
  without `BYPASSRLS` saw only the rows its policies admit. `from_hypertable` copied those rows, its
  conservation check read the source the same way and agreed, and the swap dropped the hidden rows with the
  hypertable; `transmute` sized the monolith's bound from them, committed it, and died at phase 2's `VALIDATE`
  with a raw 23514, leaving the bound rejecting every write below it. One shared refusal,
  `pgpm._refuse_filtered_reads` (PostgreSQL's `row_security_active()`), is now asked up front by `transmute`,
  by `from_hypertable_preflight` (so by `from_hypertable` and `from_hypertable_copy`) and by
  `from_hypertable_cutover`, before anything is read or committed. A `BYPASSRLS` role, a superuser, and an owner
  on a table that only `ENABLE`s row-level security convert as before. `tests/218` and
  `tests/timescale/db/37`, guarded by `bench/transmute_reads_caller_rls.sh` and
  `bench/hypertable_reads_caller_rls.sh` with the mutations `transmute_reads_under_caller_rls`,
  `hypertable_preflight_reads_under_caller_rls` and `hypertable_cutover_reads_under_caller_rls`.
- **The NDJSON encoders archive the whole row on a table with a column named `t`** (#821). Both
  (`archive._encode_upload_ndjson_single`, behind `pgpm.archive_to_s3_ndjson`, and `archive.to_s3`, in its pages
  and its conservation fingerprint) aliased the table `t` and rendered `row_to_json(t)`, and PostgreSQL binds a
  bare name to a column before a whole-row reference. With a composite column `t` each line held only that
  column's fields, no id and no payload, while the ledger recorded the chunk and `retire()` dropped the only
  complete copy; a `timestamptz` column `t` raised on every tick instead. All three sites now render
  `row_to_json(t.*)`, which only the FROM item's alias can satisfy, so every other table's objects are byte for
  byte what they were. `tests/archive/db/33` checks each object's lines by identity (exactly the table's columns,
  each row's own values) under `bench/archive_ndjson_row_alias.sh`, with the mutations
  `archive_ndjson_single_row_alias_shadowed`, `to_s3_row_alias_shadowed` and `to_s3_fingerprint_row_alias_shadowed`.
- **The timescale wrapper guards fail a file that ran fewer assertions than it planned, however it stopped**
  (#795, #712). The eleven `bench/hypertable_*.sh` and `bench/uninstall_hypertable_capture.sh` wrappers judge
  their pgTAP file from `psql -tAq` output. Eight read a plan shortfall only from finish()'s "# Looks like you
  planned" line and ignored psql's exit status, so a file whose session died part-way (FATAL, no `ERROR:`) never
  reached finish() and was passed after 1 of 3 planned assertions; three (`late_appends`, `cutover_identity`,
  `replica_capture`) had no shortfall check at all. All eleven now share one verdict block: the assertions that
  ran are counted against the `1..N` plan line, and any psql exit other than 0 fails the file.
  `bench/wrapper_tap_verdicts.sh` evaluates each wrapper's block, as written, against six real pgTAP outputs
  (clean, failed, short of its plan, session lost mid-file, session lost after its plan, raw error) that pg_prove
  is shown to pass or fail, with the mutations `wrapper_verdict_reads_finish_only`,
  `wrapper_verdict_no_shortfall_check` and `wrapper_verdict_ignores_exit`.
- **`bench/transmute_cutover_order.sh` finds the statements it orders, not the first mention of them** (#796).
  It located the new parent's CREATE TABLE by the first `partition by range` in `_transmute`'s source, which is a
  comment in the procedure's preamble, so it passed a copy whose real CREATE TABLE ran after both renames, the
  #344 defect it exists for. The CREATE TABLE, the renames and the RLS replay are each found as the
  `execute format('...` that issues them, and the guard requires each to be found the expected number of times.
  The new mutation `transmute_cutover_late_create_table` moves that one statement alone.
- **`fail_obtain_name` names a type that holds an unbuilt cell's name** (#790). `_log_unbuilt_cell`
  resolved the holder through `to_regclass` alone, which sees relations only, so when an enum, domain or
  range type held a forward cell's name (the cell `obtain` and `extend_to` leave unbuilt since #707) the
  holder clause was null and the method stopped at "is held by ", naming nothing. It now names the type
  with `_type_squatter`'s noun (`an enum type public.x`). `tests/214` under
  `bench/unbuilt_cell_type_holder.sh`, with the mutation `unbuilt_cell_type_holder_unnamed`.
- **`transmute` refuses a type under any fine child's name, not only a 19-digit one** (#794). The pg_type half
  of the orphan-child guard (#707) still matched an id suffix with `'^[0-9]{19}$'` after #726 moved its
  pg_class half to `_is_fine_child_label`, so a type holding a 20-digit, fractional or short negative cell's
  name passed, the conversion completed and `obtain` left that cell unbuilt. Both halves now ask the same
  helper. `tests/215` under `bench/orphan_type_guard_id_labels.sh`, with the mutation
  `orphan_type_guard_id_label_19_digits`.
- **`from_hypertable_cutover` keeps a naive watermark in the column's own type** (#791). The append-only
  catch-up's watermark, `max(control)` of the destination, was held in a `timestamptz` local, so a
  `timestamp` (no tz) value went through the session `TimeZone`; inside that zone's spring-forward gap
  (America/New_York, 2024-03-10 02:30) it moved an hour forward, the in-order appends below that hour were
  not caught up, and the conservation check refused the swap, blaming out-of-order appends. It is now
  carried as text through the new `pgpm._from_hypertable_ctl_text`, as the online drain already carried
  it. `tests/timescale/db/35` pins it keyless and keyed; `bench/hypertable_time_rendering.sh` proves it
  against `hypertable_cutover_watermark_timestamptz`.
- **`from_hypertable` renders its chunk bounds and watermarks independently of the session's `DateStyle`**
  (#793). The copy spliced each chunk bound with a bare `%L`, and the drains and the cutover carried their
  watermarks and reconcile ranges as a bare `::text`, all in the session's `DateStyle`. Under `SQL`,
  `Postgres` or `German` that names the zone by abbreviation, and `CST` (Asia/Shanghai) reads back as US
  Central: the copy skipped its oldest 14 hours and every catch-up started 14 hours late, so the cutover
  refused the swap after the whole online copy. The bounds now go through `pgpm._ts_text` and every
  control value through `pgpm._from_hypertable_ctl_text`, both pinned to ISO. `tests/timescale/db/36`
  reaches every site (the copy, the pre-drain and its step, the change drain, and the cutover's keyless, keyed and tracked
  catch-ups); `bench/hypertable_time_rendering.sh` proves it against `hypertable_chunk_bounds_session_datestyle`
  and `hypertable_ctl_text_session_datestyle`.
- **`transmute` carries the table's replica identity** (#782). The cutover carried publication membership
  (#566) but not `REPLICA IDENTITY`, and PostgreSQL gives a new partition none of its parent's, so a keyless
  `REPLICA IDENTITY FULL` table in a publication got forward partitions with none and every `UPDATE` and
  `DELETE` of a row past the monolith failed with 55000 (a keyed `FULL` or `NOTHING` table published its
  key instead). The parent now takes the table's identity (`USING INDEX` mapped to the parent's index the
  original is attached under), and every partition pgpm mints from it, obtain's, `extend_to`'s and a
  regrain's fine children, takes the parent's. `tests/207` under `bench/cutover_replica_identity.sh`, one
  mutation per site.
- **`transmute`'s parent keeps the key's constraint name** (#789). Step 8 declared the parent's key
  anonymously, so it came back auto-named (`t_pkey1`, or `<t>_pkey` for a named key) and every
  `INSERT ... ON CONFLICT ON CONSTRAINT <name>` failed with 42704 on the converted table. The parent now
  declares it under the original name (with its deferrability, #731) after renaming the monolith's copy
  `pgpm_key_<index oid>`, which fits at any key length; `untransmute` hands the original name back, and a
  relation already holding that name is refused up front. `tests/208` under `bench/cutover_key_name.sh`.
- **A regrain names a clamped first cell by its own start, so a day regrain of a monthly grid in a non-UTC
  zone completes** (#783). A regrain toward a fixed step clamps a child's first cell to the child's lower
  bound when that bound is off the target's lattice, and named it by the UTC date of that bound, which is
  the label of the cell beside it too: on a monthly `America/New_York` grid regrained to `'1 day'`,
  February's first cell `[02-01 05:00Z, 02-02 00:00Z)` rendered the `_p2024_02_01` January's last cell
  held, and every regrain of February was refused; a Los Angeles monolith anchored at local midnight
  clamped its first hour under the next cell's name, and auto-regrain logged `skip_regrain` on every tick
  with the capture trigger left on. A clamped cell is now labelled at the coarsest grain, no coarser than
  the step's, at which both its bounds read exactly (`_p2024_02_01_05`); a lattice cell's name, and a
  clamped one whose bounds already read exactly at the step's grain, are unchanged.
  `bench/regrain_clamped_subrange_names.sh` runs tests/209 against the mutation
  `regrain_clamped_name_by_floor`.
- **`obtain` builds what fits in half the shared lock table and leaves the rest to the next tick** (#786).
  It is a function, so every partition one call creates holds its locks to that transaction's end, and
  `set_obtain` bounds only the sign of the lookahead: a lookahead past about 2000 missing cells on a stock
  server died with 53200 `out of shared memory` on every tick, rolled back every cell it had built, logged
  `skip_obtain`, and the forward grid never advanced. `obtain` now takes `extend_to`'s measurement (#591):
  once two partitions exist it projects what the next would hold, in non-fast-path `pg_locks` rows counted
  from just after the frontier read, and stops before its partitions would pass half of
  `max_locks_per_transaction x (max_connections + max_prepared_transactions)`. It stops rather than refuses,
  since its lookahead is opportunistic: the call returns what it built and the next tick carries on, so a
  large `set_obtain` is reached over several ticks. `tests/212_obtain_lock_budget_test.sql` pins the tick
  (no `skip_obtain`, the contiguous run it built by lower bound) and a direct call's held slots against the
  half; `bench/obtain_lock_budget.sh` is required to fail against the `obtain_no_lock_budget` mutation.
- **`from_hypertable`'s swap keeps the table's grants, owner, row-level security, policies, comment and
  triggers** (#787). The cutover renamed the copy, built by `CREATE TABLE ... LIKE`, which carries none of
  them, into the dropped hypertable's place, so `transmute` found nothing to carry and every grantee was
  refused once the migration completed. The cutover now reads them off the source under its lock, just
  before the drop (`_from_hypertable_carried_ddl`), and replays them in the swap transaction, leaving out
  TimescaleDB's insert blocker and the module's own capture trigger. `tests/timescale/db/33` under
  `bench/hypertable_cutover_carries_access.sh`, with the mutations `hypertable_cutover_access_not_carried`,
  `hypertable_cutover_carries_insert_blocker` and `hypertable_cutover_carries_capture`.
- **`from_hypertable` asks `transmute`'s key and frontier refusals before the swap, and takes
  `p_force_frontier`** (#792). A hypertable keyed by a bare unique index, or holding a row more than a step
  and an hour ahead of `now()`, passed every pre-swap check, so the swap dropped the hypertable and
  `transmute` then refused, leaving a plain unmanaged table. The preflight asks the key, `from_hypertable`
  the frontier before its copy, and the cutover both under its lock, with `transmute`'s own rule (the core's
  new `_transmute_bare_unique` and `_frontier_skew_limit`, which `transmute` now calls too);
  `from_hypertable` and `from_hypertable_cutover` pass `p_force_frontier` through. `tests/timescale/db/34`
  under `bench/hypertable_handoff_refusals.sh`, with six mutations, one per check and per pass-through.
- **The archive picker and `transmute`'s monolith lo read a timestamptz the same from every DateStyle**
  (#788). Two more sites rendered a control value with a bare `::text` and parsed it back in the same
  session, the class `_ts_text` exists for (#500, #570). `_next_archive_chunk` read the window's newest
  value, the next distinct value and the tie extension that way, so from a session in DateStyle SQL and
  Europe/Dublin (whose summer `IST` the default abbreviations read as Israel) every value read an hour early,
  no chunk was returned and the aged partition was never archived or retired, with nothing logged.
  `_transmute` read min(control) that way, so from DateStyle SQL in Asia/Kolkata an oldest row in a month's
  last 3.5 hours floored the monolith's lo into the next month, phase 2's VALIDATE failed on it and the
  NOT VALID bound was left behind. Both now render through `_ts_text`. `tests/213` pins the chunk, the
  ledger and the retire from a SQL/Dublin session and the conversion from a SQL/Kolkata one, and
  `bench/ts_text_archive_chunk_transmute_min.sh` runs it with the mutations `archive_chunk_bare_text` and
  `transmute_min_bare_text`, one per site.
- **A regrain survives `ALTER TABLE` on its parent** (#785). The fine copies are made `LIKE` the parent when
  each is created and never saw later DDL, while the copy, the reconcile and the swap's `ATTACH` list the
  parent's current columns, so an `ADD COLUMN` mid-regrain failed every later tick with `skip_regrain`
  ('column ... does not exist'), and a `DROP COLUMN` or a type change failed the swap, leaving capture on and
  the monolith unsplit until someone found `regrain_cancel`. Each resumed tick now compares every copy's
  columns with the parent's and, when they differ, discards the copies and copies the range again from the
  source (logged `regrain_restart`, naming the columns). Copied again rather than altered, because a
  volatile default gave each source row a value a copy cannot re-derive. `tests/211` under
  `bench/regrain_survives_parent_ddl.sh`, with the mutations `regrain_shape_drift_ignored` and
  `regrain_shape_restart_keeps_cursor`.
- **A whole regrain target written with a fraction is refused on an integer control column** (#784).
  `_regrain_step_shape` tested the step's value, which `'10.0'` passes, while the grid carries the step's
  numeric scale into every bound it renders, so `set_regrain('10.0')` on a `bigint` key was stored and every
  tick after the prepare failed creating the first fine cell (`invalid input syntax for type bigint: "0.0"`)
  and logged `skip_regrain`, with the capture trigger left on the source. On `int2`, `int4` and `int8` a step
  with any scale is now refused at every entry point (`set_regrain`, `regrain_step`, `regrain()`, and a tick
  reading a target an older install stored), and the message names the spelling to use (`10`); `numeric`
  columns are unchanged. `tests/165` asserted `'5.000'` was accepted and now asserts the refusal;
  `tests/210` under `bench/regrain_target_step_spelling.sh`, with the mutation
  `regrain_step_scale_on_integer`.
- **Archived floats keep their exact value whatever `extra_float_digits` the archiving session has** (#781).
  Both NDJSON encoders (`archive._encode_upload_ndjson_single`, behind `pgpm.archive_to_s3_ndjson`, and
  `archive.to_s3`) rendered rows with `row_to_json` in the calling session, and the Parquet writer an array
  column with `array_to_json`, so under `extra_float_digits = 0` (set by `ALTER ROLE` or `ALTER DATABASE` and
  inherited by a tick) every float8 was archived to 15 significant digits and every float4 to 6, a value the
  row never held, while the ledger recorded the chunk and `to_s3`'s fingerprint, hashing the same rounded
  text on both sides, passed. The three functions now pin `extra_float_digits = 1` (shortest-exact, the
  PostgreSQL 12+ default, so objects written from a default session are unchanged), as `_object_stem` pins
  `TimeZone` and `DateStyle`. `tests/archive/db/32` reads every object back value by value under
  `bench/archive_float_digits_pinned.sh`, with one mutation per site (`archive_ndjson_single_float_digits_unpinned`,
  `to_s3_float_digits_unpinned`, `parquet_array_float_digits_unpinned`).
- **`transmute` refuses a table that views and other objects name by its oid** (#779). A view's query, a
  materialized view's, a rule's action, a `BEGIN ATOMIC` function body and a policy's expression name each
  relation by oid, and the cutover renames the original table, oid and all, into the monolith partition, so a
  view over the table silently read the monolith alone after the conversion and missed every row routed to a
  forward partition. They are now refused, all named at once, before anything is committed and again under
  the cutover's lock (the table's own policies stay carried), and `untransmute` refuses the same objects over
  the parent rather than failing raw on its `DROP` or dropping a rule on the parent with it. Re-pointing them
  inside the cutover was rejected: a materialized view would be re-created and refreshed under
  `ACCESS EXCLUSIVE`, losing its indexes and grants. `tests/205` under
  `bench/transmute_oid_bound_dependants.sh`, with one mutation per refusal site.
- **`untransmute` hands back the managed table's publication membership, not the conversion's** (#780).
  After a `transmute` the parent is the table, so `ALTER PUBLICATION ... ADD`, `DROP` or `SET TABLE` naming
  it changes the parent's `pg_publication_rel` rows; `untransmute` dropped those with the parent and kept the
  monolith's, so a publication the table had joined since stopped publishing it at the reverse (every later
  write missing at its subscribers) and one it had left published it again. The reversal now reads the
  parent's memberships under its `ACCESS EXCLUSIVE`, beside the grants and comments, and puts them on the
  restored table with their row filters and column lists, issuing DDL only for the memberships that differ.
  `tests/206` runs under `bench/untransmute_publication_membership.sh`, with the mutations
  `untransmute_publication_not_restored`, `untransmute_publication_capture_before_lock` and
  `untransmute_publication_always_readd`.
- **Loosened retention takes back a retirement on a table moved to another schema** (#778). `_retain_recall`
  (#724) still resolved a retiring partition in the parent's current schema, the one lifecycle step #727
  left there, so after `ALTER TABLE <parent> SET SCHEMA` a loosening `set_retain` logged
  `fail_retain_identity` ("oid nothing now") and its conditional disarm named a command the `pgpm_detach`
  job did not hold: cron detached a partition the loosened policy keeps, and no tick re-attached it. It now
  resolves each partition through `pgpm._child_nsp`, so the identity check, the disarm, the `ATTACH` and the
  constraint drop name it in its own schema, and a squatter on the name there is still refused.
  `tests/204` pins it through `bench/retain_recall_moved_parent.sh` (`retain_recall_parent_schema`,
  `retain_recall_by_oid`).
- **`scripts/review/closure.sh` starts the timescale harness when a claim needs it.** Pass 5 was the first
  pass with hypertable reproductions in its claim set; `classify_claims.py` routes those to `pgpm_test-timescale`
  and the closure script had never started that service, so its first run died on its first claim. It now reads
  the claims' install lists, brings the service up and waits for it, as it does for the archive service.
- **Pass 5's novel seeds join the mutation catalogue** (`type_squatter_any_schema`,
  `schedule_without_cron_silent`, `throws_ok_null_pattern_113`, `untransmute_acl_capture_before_lock`,
  `hypertable_cutover_refusals_reordered`). Three were caught by nothing, so each gets the test that was
  missing and a wrapper that runs it: `tests/201` (a type of the same name in another schema does not make
  `transmute` refuse) under `bench/transmute_type_squatter_other_schema.sh`, `tests/202` (`schedule()`
  refuses by name where pg_cron is not installed) under `bench/schedule_without_pg_cron.sh`, and
  `tests/203` (a GRANT committed while `untransmute` waits for its lock is kept) under
  `bench/untransmute_acl_capture_under_lock.sh`. The loosened `tests/113` assertion is a second test-file
  mutation on `bench/throws_pinned.sh`, and the reordered hypertable refusals a third mutation on
  `bench/hypertable_replica_capture.sh`, whose `tests/timescale/db/25` refusal messages catch it. The
  runbook seed (S4) was already catalogued by #749 as `runbook_phantom_alert_action`, the identical edit,
  which `bench/doc_log_actions.sh` fails. The sixth seed, a bench identity assertion
  weakened to a count (S5), is not catalogued: an earlier assertion in the same guard fails first, so the
  guard still discriminates and no mechanical guard for it exists (#775).
- **The living-docs check reads the log actions in the operator docs' SQL** (#742). Check 6 of
  `scripts/check_living_docs.sh` held only the reference's vocabulary table and "logged `x`" prose to the
  actions an `install.sql` writes, so a phantom action in a runbook alert query (`and action in (...)`, the
  text an operator copies into an alert) passed it. It now also reads every literal the operator docs
  compare `action` with (`=`, `<>`, `!=`, `in (...)` over any number of lines), fails when it reads none,
  and its `--selftest` re-breaks both SQL forms. `bench/doc_log_actions.sh` runs the check over a copy of
  the tree, with the mutation `runbook_phantom_alert_action`.
- **`tests/18` and `tests/90` pin the refusals they exist for** (#743). `tests/18` pinned the orphaned-child
  refusal by SQLSTATE alone, and in its fixture the monolith's name is the orphan's, so the monolith-name
  guard's own P0001 satisfied it with the orphan guard deleted; it now pins the message. `tests/90` asserted
  `_radix_decode`'s alphabet-length refusal with `throws_ok(sql, NULL, NULL)` on a digit outside the
  alphabet, which raises the invalid-digit error anyway; it now decodes a digit inside the alphabet and pins
  the SQLSTATE and message. `bench/tests_fail_on_defect.sh` runs each file against its defect put back, with
  the mutations `orphan_refusal_sqlstate_only` and `radix_length_refusal_unpinned`.
- **`tests/11` and `tests/12` hold the migrated rows to the seeded ones, by identity** (#744). Each took its
  "before" count after `fixtures/demo.sql` had already run the migration and compared the table's count
  with it, so the check passed with seeded rows lost. `fixtures/demo.sql` now snapshots the seeded rows
  before it transmutes (`public.events_id_seeded`, `public.events_uuid_seeded`), and each file compares the
  count and the bag of `(id, payload)` with that snapshot. `bench/tests_fail_on_defect.sh` replaces two
  seeded rows with strangers under the same ids, which a count cannot see, with the mutations
  `id_conservation_after_migration` and `uuid_conservation_after_migration`.
- **The reference's recovery for a `fail_archive_identity` wedge works on the table that has one** (#739).
  It said to clear the stale row with `forget_missing`, which clears only a parent whose relation is gone,
  while the archive step's identity check only ever runs for a live one, so following it cleared nothing and
  the wedge (at `archive_batch` 1, the table's whole archiving and retention) stayed. It now says to delete
  the `pgpm.part` row, as the runbook does. `bench/doc_archive_identity_recovery.sh` measures both repairs
  on a real wedge and checks every sentence that offers `forget_missing` for one, with the mutation
  `reference_archive_identity_forget_missing`.
- **A standing `status().fks_suspended` is read as the cutover's dropped key, not a dead swap** (#740). The
  reference said a standing non-zero value means a regrain swap died mid-flight, and the runbook that a move
  was still in flight, while a paused `transmute` with `p_incoming_fks => 'preserve'` leaves it standing by
  design until `restore_incoming_fks` re-adds the key (`maintain` does nothing on a paused table). Both now
  say so. `bench/doc_fks_suspended_meaning.sh` measures it on a paused and an unpaused conversion and checks
  every sentence that reads the value, with the mutation `reference_fks_suspended_dead_swap`.
- **The docs no longer call retention over an unregrained keyless monolith dormant** (#741). `README.md`
  and the reference's `from_hypertable` notes said `retain` drops only fine partitions until the monolith is
  regrained, while `retain()` drops the monolith whole, in one step, once its range is past the horizon (as
  the reference's own `retain` section and the guide say), so the migrated history goes in the one cliff the
  operator was told could not happen. Both now say so. `bench/doc_monolith_retention.sh` measures the drop on
  a keyless monolith and checks every sentence about monolith retention, with the mutation
  `reference_keyless_monolith_dormant`.
- **`uninstall.sql` removes `from_hypertable`'s change capture too** (#737). It swept only regrain's, so
  after a `from_hypertable_copy(..., p_track_changes => true)` that was never cut over, the
  `<rel>_pgpm_delta` table, its `<rel>_pgpm_delta_fn()` and the `<rel>_pgpm_delta_trg` trigger on the live
  hypertable and its chunks survived the uninstall, and the trigger went on logging every write into a
  delta nothing would drain. Beside the schema drop (so a refused uninstall leaves it in place), uninstall
  now finds each such copy by the record it keeps on its delta (the `pgpm from_hypertable horizon`
  comment), never by a name pattern, and drops the function (taking the trigger with it) and the delta; an
  operator's table that only shares the name is left alone. `tests/timescale/db/32` pins both halves; `bench/uninstall_hypertable_capture.sh`
  proves them against `uninstall_keeps_hypertable_capture` and `uninstall_hypertable_capture_by_name`.
- **A `time` bound keeps its era, so a table holding a row before 1 AD converts** (#733). `_time_literal`
  rendered the year with `to_char` `YYYY`, which drops the era, so an instant before 1 AD read back as an
  AD year: `transmute` on a table whose oldest row was 100 BC committed a write-rejecting
  `pgpm_monolith_bound` starting in 101 AD and failed phase 2's `VALIDATE` with a raw 23514, the bound
  left on the live table. The literal now carries the era (a trailing `BC`) when its wall time is before
  1 AD, which every DateStyle reads back as the same instant for timestamptz, timestamp and date.
  `bench/time_literal_era.sh` runs tests/199 against the mutation `time_literal_drops_era`.
- **`check_uuidv7` and `check_text_time` report the column's maximum past a NULL** (#734). Both read
  `newest_decoded` with `ORDER BY ... DESC LIMIT 1`, and `DESC` sorts NULLs first, so one NULL in a still
  nullable column was "the maximum": `newest_decoded` and `newest_in_future` came back null while a row
  five years ahead sat in the table, the very row the pair exists to show (#457). The read now skips NULLs
  in its `WHERE` clause, which keeps the backward index scan (`max()` has no `uuid` form before
  PostgreSQL 18, and `NULLS LAST` would sort). Guarded by `tests/200` through
  `bench/check_newest_skips_nulls.sh` (`check_newest_nulls_first`).
- **transmute and the regrain janitor and reclaim read what they act on under the lock that holds it still**
  (#706). The cutover replayed the table's grants before its rename, and `GRANT` and `REVOKE` take no lock
  on the table, so one committed after that read landed on the monolith alone and the parent kept a revoked
  privilege or lacked a granted one; the grants are now read after the rename and the attach, which rewrite
  the catalog rows a `GRANT` or `REVOKE` must rewrite too, so a later one waits for the cutover. With
  `p_incoming_fks => 'error'` a key added before the cutover's lock followed the rename onto the monolith;
  the gate, and the transition-table trigger refusal, are asked again under the lock. The key and identity
  the preflight planned from are checked again after the staging `LIKE` (an identity made `ALWAYS`
  meanwhile came back `BY DEFAULT`), and refuse on a change. The regrain janitor and `retire`'s reclaim now
  take `pgpm.regrain_lock`: the janitor skips (`skip_regrain_capture`) while a driver holds it, and reclaim
  waits. `tests/185` through `bench/reread_under_lock_remaining_tap.sh`, with one mutation per site. Not
  closed here: `_transmute` still reads the minimum and maximum before phase 1's lock.
- **An identity sequence's options are carried as they are at the cutover, not as an earlier read saw them**
  (#732). `transmute`'s cutover and `untransmute` read `INCREMENT BY`, the bounds, `START`, `CACHE` and
  `CYCLE` before their `ACCESS EXCLUSIVE`, and `ALTER SEQUENCE` takes no lock on the table anyway, so an
  `INCREMENT BY` committed while either ran was lost and the parent (or the restored table) handed out ids
  on the old spacing. Both now read them under the table's lock and under a lock on the sequence that
  `ALTER SEQUENCE` waits for (`_identity_options_locked`). `tests/186` through
  `bench/reread_under_lock_remaining_tap.sh` (`transmute_identity_options_before_lock`,
  `untransmute_identity_options_before_lock`, `identity_options_unlocked`).
- **Refusal and legibility edges: `transmute` refuses an `EXCLUDE` constraint and an unowned publication up
  front, `untransmute` carries back the owner and comments, and maintenance logs what it used to do
  silently** (#710). A table with an exclusion constraint, or a publication naming it that the converting
  role does not own, failed raw inside the cutover after phases 1 and 2 had committed the bound and the
  claim, so the table rejected every write past `hi` until a `transmute_abort`; both are now refused before
  anything is committed. `untransmute` hands the table back with the parent's owner and table and column
  comments, which `ALTER ... OWNER TO` and `COMMENT ON` on the managed table never reached on the monolith.
  `set_regrain` asks about the names of every cell auto-regrain would split at both ends of each child, not
  only the anchor's, so a fractional target on a `numeric` key whose later names do not fit is refused at
  call time. A write block put back `ENABLE ALWAYS` after an operator disabled it logs
  `write_block_reenable`, and a cell `obtain` or `extend_to` leaves unbuilt because its name is held
  elsewhere logs `fail_obtain_name`. A BC year's label carries `_bc`, so 1 BC and 1 AD no longer share
  names. A regrain step re-ANALYZEs its change-capture delta only when it was never analyzed, or once when it has
  filled after an ANALYZE found it empty, not on every step while it stays empty. `_grid_floor` adds a fixed step's offset from the anchor exactly, so a
  fractional-second step far from the anchor stays on its lattice. Guarded by `tests/189` and `tests/190`
  through `bench/transmute_refusal_edges.sh` and `bench/reverse_legibility_edges.sh`, with ten mutations
  (`transmute_exclude_not_refused`, `transmute_publication_owner_late`, `set_regrain_anchor_name_only`,
  `untransmute_owner_not_restored`, `untransmute_comments_not_restored`, `write_block_reenable_unlogged`,
  `obtain_unbuilt_cell_unlogged`, `part_name_bc_unmarked`, `regrain_delta_reanalyzed`,
  `grid_floor_offset_double`).
- **`from_hypertable_cutover` re-adds each identity column as it was** (#640). The swap re-added every
  identity `GENERATED BY DEFAULT` with the default sequence options and seeded it at `last_value + 1`, so a
  `GENERATED ALWAYS` column came out accepting supplied ids, an `INCREMENT BY 2` sequence stepped by 1 from an
  id off its lattice (6 after 1, 3, 5), and a descending sequence failed the swap outright. It now carries the
  kind, the options and the sequence's own next value through the same helpers `transmute` uses
  (`_identity_options`, `_seq_next`, `_identity_reseed`), and the post-handoff backstop advances in the
  sequence's own direction. `tests/timescale/db/27` pins it through
  `bench/hypertable_cutover_identity_options.sh` (`hypertable_cutover_identity_by_default`).
- **`from_hypertable_cutover` refuses a copy whose shape is no longer the source's** (#738). The copy's
  shape is fixed by `CREATE TABLE ... LIKE` when `from_hypertable_copy` runs, and the cutover read its
  column list and fingerprint from the source alone, so DDL on the live hypertable in the online window was
  silently reverted by the swap: a dropped column came back with its old values, a changed default reverted,
  an added `CHECK` was gone. The cutover now compares the two (columns with their type, `NOT NULL`, collation
  and default or generation expression, `CHECK` constraints, column order) up front and again under its
  lock, and refuses, naming every difference, with the source untouched; re-running `from_hypertable_copy`
  rebuilds the copy in the current shape. `tests/timescale/db/28` and `bench/hypertable_cutover_shape.sh`
  (DDL landing while the cutover prepares, from a second session) guard it, with one mutation per check.
- **`from_hypertable` migrates a hypertable whose index or table names hold a space** (#735). The index
  pre-builds rewrote `pg_get_indexdef` with a pattern that stops at the first space, so for a hypertable
  named `"f6 metrics"` the statement ran unrewritten, tried to build a second `"f6 metrics_pkey"` on the
  source, and the cutover failed with `relation already exists` after the whole online copy, though the
  preflight had accepted the table. The copy's tracked key build and the cutover's key and secondary builds
  now replace the index's own name and table by identity, as `transmute` does for its carried indexes.
  Guarded by `tests/timescale/db/29` through `bench/hypertable_index_names.sh`
  (`hypertable_index_ddl_by_pattern`).
- **`from_hypertable` keeps an index's temp name whole, and refuses a monolith name `transmute` would refuse
  before the swap** (#707). The temp names were cut to 63 bytes, which for a 63-byte key name is the key's
  own name: the tracked copy died on `already exists` and the append-only cutover failed adopting an index
  the drop had taken. A name that does not fit is now `pgpm_new_<index oid>`. And the cutover handed the
  table to `transmute` only after its swap had committed, so a 38 to 48 byte name on a daily grid, whose
  monolith name is over 63 bytes, was refused with the hypertable already gone; the cutover, and
  `from_hypertable` before its copy, now ask for that name first. Guarded by `tests/timescale/db/29`
  through `bench/hypertable_index_names.sh` (`hypertable_tmp_name_cut`, `hypertable_handoff_unchecked`).
- **An append-only `from_hypertable` of a hypertable that was empty at the copy catches up its appends**
  (#736). The empty copy's watermark is `NULL`, and the pre-drain, its step function and the cutover's
  catch-up all read that as nothing to catch up, so every row appended after the copy stayed out of the
  destination and the conservation check refused the swap, blaming rows at or below a watermark that does
  not exist. A `NULL` watermark now puts every row past it. Guarded by `tests/timescale/db/30` through
  `bench/hypertable_empty_copy_watermark.sh` (`hypertable_empty_watermark_nothing_past`).
- **The last unbounded lock waits #657 and #665 left behind give up after 5 s** (#708). `maintain_all`'s
  `_detach_reap` finalized an abandoned detach under pg_cron's default of no `lock_timeout`, so one reader
  of the abandoned partition parked the sweep before it reached any parent, with every later access to the
  partition queued behind its `ACCESS EXCLUSIVE` request; it now carries transmute's default bound as a
  `SET lock_timeout` clause, and a timeout is logged `fail_detach_reap` and retried next tick.
  `transmute_abort` takes a new `p_lock_timeout` (default `'5s'`, as `transmute`) for its `DROP
  CONSTRAINT`, and refuses with `lock_not_available`, changing nothing, when the table's lock is not had in
  time. `from_hypertable_cutover` applies its `p_lock_timeout` to the incoming keys' re-add and `VALIDATE`
  after the handoff, where the `VALIDATE` waited under the session's setting; a timeout leaves the key for
  `maintain`, logged `fail_validate_incoming_fk`. Guarded by tests/198, `bench/reap_and_abort_lock_timeout.sh`
  (`detach_reap_no_lock_timeout`, `transmute_abort_no_lock_timeout`) and
  `bench/hypertable_handoff_fk_lock_timeout.sh` (`hypertable_handoff_validate_no_lock_timeout`).
- **The text SigV4 signer sends the bytes it hashed, so a non-UTF8 database archives non-ASCII NDJSON**
  (#728). `archive.s3_signed_request` hashed `convert_to(payload, 'UTF8')` but put the payload on the wire
  in the server encoding, so in a LATIN1 database every body holding a non-ASCII character was refused
  with `XAmzContentSHA256Mismatch`, and the uncompressed NDJSON strategy, which signs its chunk there,
  logged `skip_archive` every tick and never covered or retired the partition. The signer now sends the
  UTF-8 bytes through `bytea_to_text`, as the bytea signer does. `tests/archive/db/29` drives the strategy
  in a LATIN1 sibling database it builds through dblink; `bench/archive_signer_non_utf8.sh` is required to
  fail against `signer_text_sends_server_encoding`.
- **pgpm_archive's pass-4 edges** (#711). `archive.to_s3` and `archive.to_s3_parquet` keyed their object
  `<prefix><child>.<ext>`, so same-named parents in two schemas sharing a prefix overwrote each other's
  export; the key is now `<prefix><schema>.<child>.<ext>` (`archive._child_object_key`). A `timestamptz`
  Parquet leaf now carries `LogicalType TIMESTAMP(isAdjustedToUTC=true)` beside `TIMESTAMP_MICROS`, which
  DuckDB read alone as a naive `TIMESTAMP`. `archive._s3_abort_uploads_at` follows the listing's markers
  to its last page instead of reading one, and `tests/archive/db/28`'s stand-in now answers the sweep's
  listing by key prefix as S3 does, so the exact-key filter is watched against MinIO too. Guarded by
  `tests/archive/db/30` through `bench/archive_edges_pass5.sh` (`to_s3_sync_key_bare_child`,
  `parquet_tstz_no_logical_type`, `abort_sweep_one_page`, with DuckDB and pyarrow reading the files) and
  by `bench/archive_to_s3_loud_edges.sh` (`abort_sweep_no_exact_key_filter`).
- **A `NaN` in a `numeric(p,s)` column no longer wedges Parquet archiving** (#635). Parquet DECIMAL cannot
  hold it, and `archive._pq_plain_decimal` raised `cannot convert NaN to integer` on every encode of its
  chunk, so the Parquet strategy logged `skip_archive` every tick and the partition was never covered or
  retired. `NaN` is now written as null, and a `NOT NULL` column holding one gets an optional leaf in that
  file. `tests/archive/db/31` pins each file byte for byte against the same rows with null in place of
  `NaN`; `bench/archive_parquet_decimal_nan.sh` reads them back with pyarrow and DuckDB and is required to
  fail against `parquet_decimal_nan_raises`.
- **`set_partition_tz` takes turns with `obtain` and `extend_to`** (#725). It judged the grid from committed
  `pgpm.part` and shared no lock with either, so a zone change accepted while another session's extension
  had built cells on the old lattice and not yet committed them, or one an extension had read around before
  it committed, left the grid's top off the recorded zone's lattice and a one-hour hole past it that
  refused writes; run one after the other, the same change is refused. `obtain` and `extend_to` now read
  the parent's config row `FOR KEY SHARE` and `set_partition_tz` reads it `FOR UPDATE`, so each waits for
  the other to commit. `tests/195` pins both orders for both callers, and
  `bench/set_partition_tz_grid_lock.sh` proves it against one mutation per lock (`set_partition_tz_config_unlocked`,
  `extend_to_config_unlocked`, `obtain_config_unlocked`).
- **`transmute`'s orphan guard and `restore_incoming_fks`'s in-flight gate know every id label** (#726).
  Both matched an id grid's child names with `^[0-9]{19}$`, the label before #582, so an orphan an
  interrupted regrain left under a 20-digit label (a cell at or past 10^19), a `_<frac>` label or a padded
  negative one passed: the conversion completed, `obtain` left that cell unbuilt with nothing logged and
  every write into it was refused, and the gate re-added a suspended FK while that child was out of the
  parent. Both now ask one helper, `_is_fine_child_label`, which recognises an id suffix by its round trip
  through `_id_label` itself. `bench/orphan_guard_id_labels.sh` runs tests/196 against the mutations
  `orphan_guard_id_label_19_digits` and `fk_gate_id_label_19_digits`.
- **A table moved with `ALTER TABLE ... SET SCHEMA` keeps being maintained** (#727). The write block, the
  archive step and `retire` resolved every partition in the parent's current schema, but moving the parent
  leaves its partitions where they were, so afterwards no step found one again: `skip_write_block` and
  `fail_retain_identity` ("oid nothing now") on every tick, nothing archived, and retention wedged for good
  with every partition still attached under its recorded oid. A new `pgpm._child_nsp` reads the schema off
  the relation `pgpm.part.child_oid` records (falling back to the parent's attached partition of that name,
  then to the parent's schema), and `retire`, `_install_write_block`, `_remove_write_block`,
  `_is_write_blocked`, `_enforce_write_blocks`, `_archive_step`, `_next_archive_chunk` and `_archive_noop`
  all resolve through it; each still compares the name against `child_oid`, so a squatter in that schema is
  still refused. `tests/197` pins it through `bench/moved_parent_lifecycle.sh` (`child_nsp_parent_schema`).
- **Loosening retention takes back a retirement it no longer reaches** (#724). A referenced partition's
  retirement dispatches a concurrent detach to the `pgpm_detach` cron job, and when `set_retain` loosened
  retention (or an `id` frontier moved back) before it ran, nothing recalled it: cron detached a partition
  the policy now keeps, `retire()` was never called on it again, and its rows vanished from every read of
  the parent while `status()` reported no failure. `set_retain` now returns the job to idle at once
  (`retain_recall`), and each tick's `retain()` recalls an armed detach the horizon no longer reaches and
  re-attaches a partition whose detach had already landed (`retain_reattach`, or `fail_retain_reattach`,
  counted in `retain_drop_failures`). Guarded by `tests/194` through `bench/retain_recall_armed_detach.sh`,
  with the mutations `retain_recall_never`, `retain_recall_clears_at_once` and
  `retain_recall_ignores_horizon`.
- **A regrain reconciles captured changes only into the fine child it created** (#723). `_regrain_reconcile`
  deleted from and inserted into a completed sub-range's copy by the name `pgpm.part` records, never checking
  the `child_oid` the copy branch checks since #631, so once that copy was renamed aside and an unrelated
  table took its name, a captured key's delete-and-reinsert removed the stranger's row and put the managed
  table's row in its place. The reconcile now resolves the copy through the new `_regrain_copy_rel`, which
  refuses when the name no longer resolves to the recorded oid, before anything is written or the delta is
  consumed. `tests/183` through `bench/regrain_reconcile_identity.sh`
  (`regrain_reconcile_into_named_relation`).
- **The regrain swap attaches only the copies it created, and the other name-keyed sites go by identity
  too** (#707). The swap attached each copy by its recorded name, so a completed copy renamed aside and a
  table created `LIKE` it `INCLUDING ALL` under its old name (which carries the `_ck`) was attached in its
  place, the source was dropped, and that sub-range's rows left the managed table. It now resolves every copy
  through `_regrain_copy_rel` before the FK suspend and the `DETACH`, refusing with nothing locked, and
  attaches the resolved relation. `regrain_cancel` drops the capture trigger and `TRUNCATE` guard from the
  relation each row's `child_oid` records rather than from whatever bears its name; `regrain_step` refuses to
  create a fine child whose name `pgpm.part` already records for another range, instead of recording it
  `on conflict do nothing`; `obtain` and `extend_to` leave a cell whose name a type holds unbuilt rather than
  failing the whole call with 42710 on every tick; and `transmute`'s orphan-child guard refuses a type named
  like a child, through `_type_squatter`. `tests/184` through `bench/regrain_child_oid_sites.sh`, one
  mutation per site (`regrain_swap_attaches_named_relation`, `regrain_cancel_triggers_by_name`,
  `regrain_copy_row_other_bounds`, `obtain_name_relations_only`, `transmute_orphan_guard_relations_only`).
- **`set_regrain(t, null)` stops a `maintain` tick already in flight from starting a regrain** (#729).
  `maintain` dispatched auto-regrain with the `regrain_to` it read at the top of the tick, three commits
  before its regrain step, so turning auto-regrain off while the tick was archiving was overridden: the
  tick prepared a new run (capture trigger, `TRUNCATE` guard, cursor) that nothing would drive, and a second
  `set_regrain(t, null)`, finding auto-regrain already off, changed nothing. The regrain step now takes the
  per-parent regrain lock and reads `regrain_to` again under it before choosing or dispatching anything.
  Guarded by `tests/191` through `bench/maintain_sweep_reads_tap.sh` (`maintain_regrain_stale_target`).
- **`maintain_obtain_all` sweeps in `maintain_all`'s turn order** (#634). It visited the tables in fixed
  `parent_table` order under one shared `statement_timeout`, so a table whose `obtain` overran the clock was
  first on every sweep and every table behind it was denied `obtain`, the one step whose lateness refuses
  writes. It now orders by `config.sweep_turn_at` and records turns exactly as `maintain_all` does (the
  first table before it starts, each table when its `maintain_obtain` returns, skipped while the row is
  held). Guarded by `tests/192` through `bench/maintain_sweep_reads_tap.sh`
  (`maintain_obtain_all_fixed_order`, `maintain_obtain_all_no_first_turn_stamp`).
- **`transmute` refuses up front three shapes its cutover could not convert** (#730). A `NOT VALID`
  `CHECK` (or, on PostgreSQL 18, `NOT VALID` `NOT NULL`) constraint, a `CHECK ... NO INHERIT` constraint
  and a generated control column passed every preflight check, so phases 1 and 2 committed the validated,
  write-rejecting `pgpm_monolith_bound` and the claim, and the cutover then died raw on every retry
  (the `ATTACH` refused the table under the parent's validated copy; PostgreSQL refuses a `NO INHERIT`
  constraint on a partitioned table, and a generated column in a partition key), leaving writes past `hi`
  rejected until `transmute_abort`. Each is now refused before anything is committed, naming the
  constraint or column; pgpm's own `NOT VALID` bound on a resume is not. Guarded by `tests/187` through
  `bench/transmute_uncarriable_shapes.sh`, one mutation per refusal (`transmute_carries_not_valid_check`,
  `transmute_carries_no_inherit_check`, `transmute_generated_control`).
- **`transmute` keeps a reused key's deferrability** (#731). The cutover re-created the reused primary key
  or unique constraint on the parent as a bare `ADD PRIMARY KEY` / `ADD UNIQUE`, which still adopted a
  `DEFERRABLE` monolith key, so the monolith kept its deferred check while every forward partition's clone
  was immediate, and a one-statement key swap the table accepted before failed with a duplicate key past
  the monolith. The parent's key now carries `DEFERRABLE` and `INITIALLY DEFERRED` as the original had
  them, read under the cutover's lock, and still adopts the monolith's index in place. Guarded by
  `tests/188` through `bench/transmute_key_deferrability.sh` (`transmute_key_immediate`).
- **The runbook states an id grid's `retain` in ids, as pgpm reads it** (#676). "Storage is not dropping
  despite a retention policy" called it a count of intervals, while `_retain_boundary` subtracts it from
  the frontier as a count of ids (as `reference.md` and `guide.md` say), so an operator setting
  `retain => 2` on a 1000-wide grid to keep two partitions kept only the one taking writes. The runbook
  now says count of ids, with that example. `bench/doc_retain_unit.sh` measures the unit from pgpm's own
  `retain()` and checks every sentence of the docs that states it, with the mutation
  `runbook_retain_count_of_intervals`.
- **`from_hypertable` refuses a hypertable with an exclusion constraint instead of dropping it** (#675).
  The copy's `CREATE TABLE ... LIKE` carries CHECK and NOT NULL only, the cutover re-adds only primary and
  unique keys and skips every constraint-backed index, and preflight did not object, so an `EXCLUDE`
  constraint vanished in the migration and the partitioned table accepted the double booking the hypertable
  had rejected. `from_hypertable_preflight` (and so `from_hypertable` and `from_hypertable_copy`) now refuses
  it up front, naming every such constraint, and `from_hypertable_cutover` repeats the check in its own right.
  `tests/timescale/db/26` pins each entry point's refusal; `bench/hypertable_exclusion_refusal.sh` proves it
  against one mutation per call site.
- **`untransmute` hands the table back with the parent's grants, row security and policies** (#667). It
  replayed only the parent's triggers onto the restored table, which kept the ACL, RLS flags and policies
  the monolith had at the conversion, so a `REVOKE`, `ENABLE ROW LEVEL SECURITY` or `CREATE POLICY` issued
  on the managed table since was silently undone. It now captures the parent's table and column grants,
  both RLS flags and its policies under the lock it already takes, resets the monolith's copy and replays
  the parent's. Guarded by `tests/176` through `bench/untransmute_security_state.sh`
  (`untransmute_security_not_restored`).
- **`untransmute` finds the monolith by the identity `transmute` recorded, and refuses once it is gone**
  (#672). It took the attached partition with the smallest `lo`, so after retention had retired the
  original table, or a regrain's swap had replaced it, a forward partition or fine child holding every
  remaining row was handed back under the table's name as the restored original. `transmute` now records
  the original's oid in the new `pgpm.config.monolith_oid` (an upgrade adopts the one attached partition
  older than its parent), and `untransmute` refuses when that relation is no longer an attached partition.
  Guarded by `tests/177` through `bench/untransmute_monolith_identity.sh`
  (`untransmute_monolith_by_position`) and by `bench/upgrade_in_place.sh`
  (`upgrade_monolith_oid_backfill_noop`).
- **A `time`-kind `transmute` accounts for a future-dated row before anything is committed** (#668). The
  monolith's `hi` was the grid boundary above `now()` and nothing compared the column's maximum with it, so
  a table holding one row dated past that boundary committed the write-rejecting bound and the claim in
  phase 1 and then failed phase 2's `VALIDATE` with a raw 23514. The time kind now takes the newer of the
  maximum and the clock as its frontier, as uuidv7 and text_time do, under the same one-step-plus-one-hour
  refusal and `p_force_frontier` override, and refuses an `infinity` maximum outright. tests/112, 128 and
  140, which built their half-converted state on exactly that failure, now commit their stray row from a
  second session after the conversion read the maximum, with a witness on the ordering.
  `bench/transmute_future_maximum.sh` runs tests/178 against the mutation `transmute_time_frontier_clock_only`.
- **`archive.to_s3`'s three loud edges are refused up front or cleaned up** (#636). `archive.configure`
  refused only a `p_part_bytes` of zero or less (#594), so a positive size under 5 MiB, S3's minimum for
  a non-final multipart part, was stored and every export of more than one part uploaded all of them and
  then failed at complete with `EntityTooSmall`; configure now refuses it, and 5 MiB exactly is accepted.
  It also refuses a `p_fetch_rows` under 1, and `archive.to_s3` refuses a row holding one by name (0 read
  no page and tripped the conservation check, a negative value failed on `LIMIT`). And an export broken
  inside its initiate POST, after the store created the upload but before its `UploadId` reached the
  function, left that upload in flight with nothing to abort it: both handlers now list the uploads at
  the export's key and abort each one at exactly that key (`archive._s3_abort_uploads_at`), which also
  clears one an earlier failed export leaked there. `tests/archive/db/28_to_s3_loud_edges_test.sql` pins
  the bounds and, for a cancel and for a transport error inside the initiate, that the upload the store
  created is gone while a bystander at a longer key survives; `bench/archive_to_s3_loud_edges.sh` is
  required to fail against `to_s3_initiate_orphan_unaborted`, `configure_part_bytes_under_s3_min` and
  `configure_fetch_rows_unbounded`.
- **`transmute` carries a secondary index whose quoted name holds a space** (#669). The cutover renamed
  each carried index by a pattern (`\S+` for the name) that cannot match `"Body Lookup"`, so the rewrite
  did nothing, the original `CREATE INDEX` ran again and failed with a raw 42P07 after phases 1 and 2 had
  committed the write-rejecting bound, and every re-run failed the same way. The prefix `pg_get_indexdef`
  writes is now replaced by identity. `bench/carried_index_quoted_name.sh` runs tests/179 against the
  mutation `carried_index_name_by_pattern`.
- **`transmute` and `untransmute` keep an identity column's sequence options** (#670). Identity was re-added
  with its kind alone, so the new sequence took the defaults: an `INCREMENT BY 2` identity (odd ids only)
  handed out even ids after the conversion, a descending one failed the cutover on its reseed, and
  `MINVALUE`/`MAXVALUE`, `CACHE` and `CYCLE` were dropped. The options are carried, and the reseed moves
  along the sequence's own lattice, in its own direction, until it clears every existing id.
  `bench/transmute_identity_options.sh` runs tests/180 against the mutation `transmute_identity_kind_only`.
- **`transmute` refuses a type holding its staging or monolith name up front** (#671). Both guards asked
  `to_regclass`, which cannot see an enum, domain or range type, although `CREATE TABLE` and `RENAME` need
  the name free in `pg_type`; the cutover died with a raw 42710 after the bound and the claim were
  committed. `bench/transmute_type_squatter.sh` runs tests/181 against the mutation
  `transmute_name_guard_relations_only`.
- **A regrain target step that mixes a month count with a duration is refused** (#674). `set_regrain` judged a
  target only through `_grid_next`, whose calendar branch keeps the months and drops the rest, so
  `'1 month 1 day'`, `'1 month -40 days'` (below zero by interval ordering) and `'-1 month 40 days'` were
  stored, and once a coarse child froze every tick's `regrain_step` failed in `_grid_floor` ("mixed month +
  duration interval unsupported") and logged `skip_regrain`. The new `_regrain_step_shape`, called from the
  #588 forward check so `set_regrain`, `regrain_step`, `regrain()` and `regrain_history()` all refuse it,
  applies the rules `transmute` applies to a `partition_step`, including its date rule: a step that is not
  a whole number of days is refused on a `date` column. Guard `bench/regrain_target_shape.sh` (tests/164),
  mutations `regrain_step_mixed_month_duration` and `regrain_step_date_subday`.
- **A fractional regrain target on an integer control column is refused** (#641). `set_regrain('2.5')` on a
  bigint grid passed every call-time check, and every tick after the prepare failed creating the first fine
  child (invalid input syntax for type bigint) and logged `skip_regrain` with the capture trigger left on the
  source. `_regrain_step_shape` refuses a step that is not a whole number on an `int2`, `int4` or `int8`
  column (a `numeric` column still regrains toward `'0.5'`). Guard `bench/regrain_target_integral.sh`
  (tests/165), mutation `regrain_step_fraction_on_integer`.
- **A preserved incoming key whose referencing table was dropped no longer wedges `untransmute` or regrain**
  (#658). `pgpm.dropped_fk` was never reconciled with the catalog, so once the application dropped a
  referencing table (or a restored key by hand) `untransmute` and regrain's swap died on the record every
  time and the table could be neither reversed nor regrained. The four paths that act on the records now
  forget one the catalog no longer backs first, logged `forget_incoming_fk`; `tests/173` is the acceptance,
  guarded by `bench/dropped_fk_reconcile.sh` against the `dropped_fk_never_reconciled` mutation.
- **A malformed `text_time` maximum no longer stops the forward grid** (#661). PostgreSQL routes a value
  whose timestamp field is not in the declared shape (a digit outside the alphabet, a field shorter than the
  width) into an existing partition by string order, and once it was `max(control)`, `_frontier_native`'s
  decode raised on every obtain tick, each was logged as `skip_obtain` and writes were refused once the
  lookahead ran out. The frontier now falls back to `now()` for a maximum that does not have the shape, the
  way `check_text_time` already reports one as null; a well-formed maximum ahead of the clock still leads.
- **The Parquet writer archives a finite timestamp past 294247 AD** (#664). PostgreSQL's range runs
  about 30 years past the last instant INT64 microseconds since 1970 can hold, and #586 clamped only the
  infinities, so a `timestamptz` or `timestamp` after 294247-01-10 04:00:54.775806 UTC raised `bigint out
  of range` on every encode of its chunk (`skip_archive` every tick, the partition never archived or
  retired), and one just after it came out below its predecessor. Such a value is now written as INT64
  max minus 1, the largest timestamp DuckDB reads back as finite, one below the `infinity` sentinel.
  `tests/archive/db/27_parquet_timestamp_range_test.sql` pins the values and bytes and runs the issue's
  two ticks; `bench/archive_parquet_timestamp_range.sh` reads the files back with pyarrow and DuckDB and
  is required to fail against the `parquet_timestamp_no_ceiling` mutation.
- **transmute and untransmute resume an identity sequence past every id handed out before their lock**
  (#656). Both read `max(id)` and the sequence's position before the lock that stops writers (transmute in
  its preflight, untransmute before its second gate), so ids a writer took in between were issued again
  and the first inserts after the conversion or the reversal failed with a duplicate key. Both now read
  them under that ACCESS EXCLUSIVE through `pgpm._identity_resume_at`, which re-reads the max only when an
  index answers it in one descent and otherwise keeps the earlier max as its floor, so no scan runs under
  the lock. `tests/157` drives both windows with a dblink writer, and `bench/cutover_reread_window.sh`
  and `bench/reread_under_lock_tap.sh` carry the mutations `transmute_identity_reseed_preflight` and
  `untransmute_identity_reseed_before_lock`.
- **untransmute captures the parent's triggers under its ACCESS EXCLUSIVE** (#666), the mirror of #593's
  fix in transmute. Captured before the lock, a trigger created, or a state changed, while the lock was
  queued was lost from the restored table. `tests/158` is the acceptance test, and
  `bench/reread_under_lock_tap.sh` runs it against the mutation `untransmute_trigger_capture_before_lock`.
- **The transmute cutover carries the secondary indexes, outgoing keys, owner, RLS flags and comments the
  table has under the lock that protects each** (#630). The index and key lists were read in the preflight
  and the owner, RLS flags and comments before the staging `LIKE`, so an index or key committed before the
  cutover's lock stayed on the monolith (a unique index enforced nothing for rows routed to a forward
  partition, a key checked none of them) and an owner, RLS or comment change was lost. The owner and RLS
  flags are now read after the `LIKE`, whose ACCESS SHARE excludes changing them, and the index and key
  lists (through `pgpm._transmute_carried_indexes` and `pgpm._transmute_outgoing_fks`) and the comments
  under the cutover's ACCESS EXCLUSIVE, where the up-front refusals are asked again: an uncarryable unique
  index or a NOT VALID key added in between rolls the cutover back to the resumable phase-2 state instead
  of being left behind. `tests/159` and `bench/cutover_reread_window.sh` (a second session committing
  mid-cutover) are the acceptance, with the mutations `transmute_carried_indexes_preflight`,
  `transmute_outgoing_fks_preflight`, `transmute_comments_before_lock` and
  `transmute_owner_rls_before_like`.
- **Every call that drives or reconfigures a regrain serialises on one per-parent lock, and `set_regrain`
  refuses to retarget a run in flight** (#554). Nothing held a per-parent lock across a regrain step, so a
  hand-driven `regrain_step` and a `maintain` tick copied the same rows into the same fine child (the
  second died on its key), a step that had read the run before a `regrain_cancel` committed carried on
  from the state the cancel tore down, and a setter read around another session's uncommitted prepare.
  And `set_regrain(parent, <another step>)` mid-flight was accepted: nothing records the step a run
  started at, so every later tick walked the half-built run on the new grid and wedged (`skip_regrain`
  on every tick, a CHECK violation or a swap refusal blaming retention). `regrain_step` (so `maintain`,
  `regrain()` and `regrain_history()`), `regrain_cancel`, `set_regrain` and `set_partition_tz` now take a
  row lock on the new `pgpm.regrain_lock` first (pgpm-owned, not an advisory key any role could squat),
  and `set_regrain` refuses a change of target while a run is in flight, naming `regrain_cancel`.
  `tests/162_regrain_drivers_serialize_test.sql` pins both with two dblink sessions ordered by lock state;
  `bench/regrain_drivers_serialize.sh` drives it against the `regrain_lock_noop` and
  `set_regrain_retarget_midflight` mutations, which `./test.sh discriminate` requires it to fail.
- **`set_partition_tz` refuses a zone change while a regrain is in flight** (#660). It judged only the
  attached bounds, and a run's copies are not attached, so a UTC month grid switched to a zone that agrees
  at every attached bound and disagrees inside the monolith was accepted mid-run; the rest of the run was
  computed in the new zone, overlapped the copies and the swap refused on every attempt. The refusal names
  `regrain_cancel`; re-stating the recorded zone still passes. `tests/163_set_partition_tz_midflight_test.sql`
  pins it single-session and against another session's uncommitted prepare;
  `bench/set_partition_tz_midflight.sh` drives it against the `set_partition_tz_regrain_midflight` mutation.
- **A grid floor is exact at any magnitude, so it never lands above its input** (#659). Three sites
  took `floor()` of a quotient that had already been rounded: general numeric division keeps a bounded
  scale and double precision about 16 digits, so a quotient a hair below an integer rounded up to it.
  `_text_time_to_ts` decoded a KSUID stamped 2020-12-31 23:59:59Z whose random low bits are near all-ones
  as the next second, `_grid_floor`'s id branch floored the id 1799999999999999999 at a step of 3e16 to
  1800000000000000000, and its fixed-step time branch floored the last microsecond before a day boundary
  to the boundary when the anchor was in year 1. `transmute` takes the floor of the oldest value as the
  monolith's lower bound, so such a row made the bound CHECK exclude it and VALIDATE fail on every run.
  All three now go through `pgpm._floor_div`, an exact integer floor built on `div()` and `mod()`, which
  `_radix_encode` already used for the same reason. `tests/174` is the acceptance test, and
  `bench/grid_floor_exact.sh` runs it against one mutation per site (`text_time_decode_rounded_floor`,
  `grid_floor_id_rounded_floor`, `grid_floor_fixed_float_floor`).
- **`maintain_all`'s reaper gives up on a table's lock after 5 s and retries next tick** (#657).
  `_transmute_reap` runs first in every sweep, before any `lock_timeout` is set, and its `DROP CONSTRAINT
  pgpm_monolith_bound` takes `ACCESS EXCLUSIVE` on the half-converted live table; under pg_cron's default of
  no timeout one long reader parked it, and its pending request queued every read and write of the table,
  and the rest of the sweep, behind that reader. The function now carries transmute's default bound as a
  `SET lock_timeout` clause (the caller's setting is back when it returns), and a timeout skips that table
  alone, logged `skip_transmute_reap`, with its bound and claim kept for the next tick. Guarded by
  tests/166 and `bench/transmute_reap_lock_timeout.sh` (mutation `transmute_reap_no_lock_timeout`).
- **`from_hypertable_cutover` bounds its wait for the source's lock with a new `p_lock_timeout`** (#665).
  The cutover's `LOCK TABLE ... IN ACCESS EXCLUSIVE MODE` on the live hypertable ran under the session's
  `lock_timeout`, by default none, so behind one long reader its pending request blocked every new read
  and write of the production table for that reader's whole life. `p_lock_timeout` (default `'5s'`, as for
  `transmute`) now bounds every wait in the swap transaction, is passed to the handoff's `transmute`, and is
  validated before any work (in `from_hypertable` too, before its copy); a timeout rolls the swap back whole
  and the cutover can be re-run. Guarded by tests/timescale/db/24 and
  `bench/hypertable_cutover_lock_timeout.sh` (mutation `hypertable_cutover_no_lock_timeout`).

- **A held `pgpm.config` row no longer aborts or hangs a sweep** (#662). `maintain_all`'s `sweep_turn_at`
  stamps and `maintain_obtain`'s `obtain_retry_after` writes (the clear after a successful obtain and the
  arming in its deferral handler) were plain UPDATEs outside any handler, so while another transaction
  held a parent's config row the sweep raised 55P03, or for its first parent waited with no
  `lock_timeout`, and every parent behind it went unmaintained or without obtain. All four now take the
  row through `pgpm._config_try_lock` (`SKIP LOCKED`) and skip the write while it is held. tests/167 and
  `bench/config_stamp_lock.sh` guard it, with the mutation `config_stamp_waits_on_row`.
- **An archive object key names its parent and its `lo` the same in every session** (#551). The
  `archive_fn` transports keyed each object on `p_parent::text`, which leaves the schema out whenever
  the ticking session's search_path reaches the parent, so two tables named `evt` in two schemas sharing
  a prefix (the default `events/` is shared by every table) wrote one object: the second PUT overwrote
  the first while both ledger rows recorded it, and retire() dropped the first table's partition. A time
  kind's stem was the digits of `lo` as the session rendered it, offset sign dropped, so a chunk rendered
  at `+05` and another at `-05` shared a key the same way. `archive._object_key` now names the parent
  `quote_ident(schema).quote_ident(table)` and `archive._object_stem` renders a time `lo` in UTC; keys
  already in `pgpm.archive_ledger` stay as written. `tests/archive/db/26_archive_key_schema_zone_test.sql`
  ticks two same-named parents from their own search_paths through both transports and archives two
  chunks from opposite-sign zones, asserting exact keys and object contents;
  `bench/archive_object_key_session.sh` runs it under `discriminate` against the
  `archive_object_key_search_path_parent` and `archive_object_key_session_zone` mutations.
- **`from_hypertable_cutover` refuses to swap unless both sides hold the same rows, not merely as many**
  (#653). The conservation check compared `count(*)` only, so a copied row deleted plus a row appended
  behind the watermark during the online window left 72 = 72, the swap went ahead, the late row was lost
  and the deleted row came back; an update of a copied row, or one that bypassed the capture trigger,
  changed no count at all. It now also compares a content fingerprint (a sum of 64-bit hashes of each
  row's text), carried through the catch-up by `RETURNING`, and refuses with `... both hold N rows ...,
  but not the same rows`. tests/timescale/db/22 and `bench/hypertable_cutover_conservation.sh`, with the
  mutation `hypertable_cutover_conservation_by_count`.
- **`archive.to_s3` lands an object only when it holds the partition's rows by identity** (#673). Its
  conservation check compared the paged row count with `count(*)` taken as the export began, so one
  concurrent UPDATE moving an unpaged row behind the paging cursor and a paged row ahead of it cancelled,
  and the object landed without a row the partition held before and after. It now sums a hash of every
  exported line and compares count and fingerprint with the partition as it stands after the last page.
  tests/archive/db/25 and `bench/archive_to_s3_conservation.sh`, with the mutation
  `to_s3_conservation_by_count`.
- **`from_hypertable_cutover` refuses to swap over a write its change capture missed, not only over one
  that changed a count** (#654). The tracking copy's trigger is origin-only (TimescaleDB refuses
  `ENABLE ALWAYS` on a hypertable and on its chunks), so an `UPDATE` under
  `session_replication_role = replica` never reached the delta, left both counts equal, and was silently
  reverted by the swap. The copy now records on the delta the xmin horizon of a snapshot taken before any
  chunk is read, and under the lock the cutover requires every source row version at or past it to sit in
  the reconciled destination exactly as in the source, refusing with the count and the first key
  otherwise. The check shares the conservation count's scan, probes only the rows written during the
  window, verifies every row for a delta built before this release, and handles compressed chunks.
- **Regrain's change-capture names are never cut to 63 bytes, so they are never the table's own** (#655).
  They were `left(<table> || '_pgpm_regrain_delta', 63)` and the same for the trigger function, which for a
  table renamed to a 63-byte name IS the table: with nothing recorded (it had never regrained)
  `regrain_cancel` truncated it, `untransmute` dropped the restored table and `uninstall.sql` dropped it with
  every partition, and an upgrade recorded it as its own delta. A name that does not fit whole is now
  `pgpm_regrain_delta_<oid>` / `pgpm_regrain_capture_<oid>` (the parent's oid), so such a table also
  regrains, and the upgrade backfill takes only a plain non-partition table for a delta. Guard
  `bench/regrain_capture_name_fits.sh` (tests/160).
- **`obtain` builds past an upgraded day grid's collided cell whose explicit-range name cannot fit** (#663).
  On a day grid labelled before #503 east of UTC, the cell a legacy label collides with is built under its
  `_p<lo>_to_<hi>` name, 14 bytes longer; for a 38 to 51 byte table name that name is over 63 bytes, and
  its refusal escaped and unwound the whole call, so every maintenance tick logged `skip_obtain` and the
  grid stopped growing. That one cell is now left unbuilt, never under a cut name, and the cells after it
  are built by `obtain` and `extend_to` alike. Guard `bench/obtain_explicit_name_too_long.sh` (tests/161).
- **`from_hypertable` refuses a hypertable whose working names would not fit, before any DDL** (#552).
  `<rel>_pgpm_dest`, `_pgpm_delta`, `_pgpm_delta_fn` and `_pgpm_delta_trg` were cut to 63 bytes silently,
  and from 55 bytes the destination took the change-capture delta's name, so the capture trigger made
  every write to the live hypertable fail on NOT NULL from the copy onward. The preflight, the copy, the
  cutover and both online drains now refuse a name over 63 bytes (a hypertable name over 48 bytes), saying
  by how much to shorten it. Guard `bench/hypertable_derived_names.sh` (tests/timescale/db/23).

- **A write block counts only when it is enabled `ALWAYS`, so coverage recorded under an origin-only or
  disabled one is discarded instead of dropped on** (#651). `_is_write_blocked` asked only whether the
  trigger existed. A pre-#450 pgpm installed the block origin-only, which a `session_replication_role =
  replica` writer (an apply worker, a loader silencing triggers) passes, and an operator can disable it by
  hand; the first tick after the upgrade repaired the trigger to `ALWAYS` but kept the coverage recorded
  before, so `retire()` read the stale watermark as full coverage and dropped the partition with a
  replica-written row no strategy was ever handed. The predicate now requires `tgenabled = 'A'`, so the
  #452/#564 discard in `maintain`'s write-block step and in a direct `retire()` fires on either state
  (logged as `archive_coverage_reset`) before the block is repaired, and the archive step no longer
  records coverage under a block that is not in force. `tests/170_write_block_enabled_state_test.sql`
  asserts by identity which ledger rows go, which row survives and what the strategy is handed before
  the drop, on both paths and for both states, with an `ALWAYS` sibling as the positive;
  `bench/write_block_enabled_state.sh` drives it against the `write_block_presence_only` mutation.
  `tests/102` enables its hand-made stranded trigger `ALWAYS` so the substitute is still an archive
  candidate, and `tests/104` reads its stranded trigger's presence from `pg_trigger`.
- **A regrain copies only into fine children it created, and `regrain_cancel` drops copies by identity**
  (#631). `regrain_step` skipped its create whenever a sub-range's name already resolved and copied into
  whatever relation bore it, so regraining a new table created under the name of a managed table renamed
  aside put its rows into the old table's attached partition (49 rows in the review's reproduction), and
  `regrain_cancel` dropped copies by name, so a copy renamed aside survived while the table that took its
  name was dropped. The copy now refuses a name held by a relation its `pgpm.part` row does not record,
  and every path that discards copies (cancel, the restart of copies that predate capture, and retire's
  reclaim) drops the relation by its recorded `child_oid`. `tests/172_regrain_copy_name_clash_test.sql`
  pins the refusals and the drop, and `bench/regrain_copy_name_clash.sh` drives it against the
  `regrain_copy_into_named_relation`, `regrain_copy_dropped_by_name` and
  `regrain_recreated_copy_oid_stale` mutations, which `./test.sh discriminate` requires it to fail.
- **An `id` retain of `NaN` is refused like a negative one** (#649). `_retain_nonnegative` judged an id
  retain with `>= 0`, and PostgreSQL orders numeric `NaN` above every number, so a `config.retain` edited by
  hand to `'NaN'` passed the #451 defence: its horizon was `NaN`, every partition sorted below it, and one
  maintenance tick dropped the whole table, the partition taking writes and every row included, while
  `regrain_step` would have discarded every sub-range as aged. The rule now refuses `NaN`, so the tick logs
  `skip_write_block` and `skip_retain` and keeps everything, `status()` reports `retain_backlog` as null,
  and `set_retain` refuses it with the sign-rule message and can repair it. `tests/168_retain_nan_test.sql`
  pins each site; `bench/retain_nan.sh` runs it against the `retain_nonnegative_admits_nan` mutation.
- **`retire` leaves alone a partition an operator detached, on the one-step path too** (#652). It asked
  `pg_inherits` whether the child was still a partition only when an incoming FK referenced the parent, so
  on the ordinary path a table an operator `DETACH`ed to keep (still marked attached in `pgpm.part`) was
  write-blocked and dropped with its rows by the next `retain`. Both paths now refuse up front, before any
  side effect, a child that is no longer a partition and carries no `retiring_at`: `false`, logged
  `fail_retain_drop`, no write block, no `DROP`; a child pgpm's own retirement detached is still dropped.
  Guarded by `tests/171` and `bench/retire_detached_unreferenced.sh`, with the mutations
  `retire_trusts_part_attached` and `retire_refuses_own_detach`.
- **A regrain in flight across the upgrade refuses `TRUNCATE` too** (#650). The #449 guard was installed by
  the prepare tick alone, and a regrain resumes without re-preparing whenever its capture trigger is up, so a
  regrain begun under 0.6.0 kept a source with capture and no guard to its swap: a `TRUNCATE` of it went
  through and the swap attached copies of every truncated row. Re-running `install.sql` now puts the guard on
  every source still regraining, and every resuming `regrain_step` tick puts back a missing one (a no-op
  when it is present). `tests/169` and `bench/regrain_truncate_guard_upgrade.sh` cover both, against the
  mutations `regrain_truncate_guard_no_upgrade` and `regrain_truncate_guard_no_resume`.
- **Pass 4's three novel seeds join the mutation catalogue** (`set_retain_strict_horizon`,
  `regrain_sync_share_update_exclusive`, `text_time_collation_default_trusted`). Each was planted for the
  pass, found by three finders (recall 9 of 9) and is caught by an existing pgTAP file (tests/98, 149 and 122);
  the new guards `bench/set_retain_horizon.sh` and `bench/text_time_default_collation.sh` run the first and
  the last against the mutant, and `bench/regrain_writer_waits.sh` already runs tests/149, so
  `./test.sh discriminate` proves all three, the way the method asks after every pass.
- **`land.sh --batch` enqueues a stacked PR as its predecessor merges, and every enqueue is confirmed.**
  The first live batch (#646 and #647) showed the merge queue dropping a PR whose head sits on another
  queued PR's head, twelve seconds after each add and without building a group; the batch now keeps the
  parallel head-check round and gives each PR its own merge group in turn, and `enqueue` re-reads the
  queue entry and retries once when the request did not take.
- **Pass 3's three novel seeds join the mutation catalogue** (`retire_straddles_horizon`,
  `archive_contract_no_overclaim`, `abort_owner_alive_by_pid_only`). Each was planted for the pass, found by
  the finders (recall 9 of 9) and is caught by an existing pgTAP file (tests/60, 115 and 101); the new
  guards `bench/retire_straddle.sh`, `bench/archive_overclaim.sh` and `bench/transmute_abort_owner.sh` run
  those files against the mutant so `./test.sh discriminate` proves it, the way the method asks after
  every pass.
- **The landing tooling batches PRs through a merge-commit queue, and the PR workflows cancel a superseded
  head's runs** (#644). `scripts/review/land.sh --batch` rebases up to five PRs onto one another, pushes and
  checks the heads in parallel, enqueues them in order and lets the queue build them as one group; its wait
  caps (`LAND_WAIT_*_MIN`), merge method (`LAND_MERGE_METHOD`) and tooling directory (`LAND_TOOLING`) are
  environment knobs, a wait timeout is exit 6 and a rerun rather than a failure, a merge is re-checked
  before it is read as a fall-out, and the rebase pins the two-way conflict style. `landq.sh` is the tier-
  ordered landing loop pass 3 ran in scratch form, `gate.sh` serialises the fixers' harness runs and waits
  for the fixed-name container to be gone first, and `landing_stats.py` renders the record's landing table
  from the loop's log. The seven PR-triggered workflows carry a `concurrency` group keyed by the PR
  number (pushes to `main` and merge groups by sha), so a rebase cancels the runs it supersedes instead of
  queueing about ninety of them behind the runner cap, as pass 3's fix heads did.
- **`keep_both.py` resolves diff3 and zdiff3 conflict hunks, and refuses one it cannot** (#598). Its hunk
  pattern knew only git's two-way shape, so under the diff3 or zdiff3 conflict style (a common global
  setting) it folded the `||||||| <base>` section into one side and exited 0 with that marker line left in
  the file, which `land.sh` then committed. A three-way hunk with an empty base is now resolved like any
  add/add hunk, one whose base holds a line (both sides edited it) is refused, and the result is checked
  for all four marker kinds. `bench/keep_both_diff3.sh` has git write the hunks under each style, with
  the mutation `keep_both_two_way_only`.
- **`ONBOARDING.md` names the timescale track's real knob** (#599). It told developers to run
  `TS_VERSIONS='2.9.1' ./test.sh timescale`, a variable `test.sh` stopped reading in #155, so the command
  silently ran the default 2.16.1 leg and reported PASS; it now documents `TS_PG_TAGS` (one leg per
  supabase/postgres image tag) and no longer claims 2.9.1 coverage. `bench/doc_env_knobs.sh` checks
  every `NAME=... ./test.sh <track>` command in the docs against the track that must read it, with the
  mutation `onboarding_ts_versions`.
- **`classify_claims.py` reads a reproduction's TAP as its contract says** (#600). A failing pgTAP
  assertion without a description (psql prints `not ok 2` and exits 0) now reads as the defect rather than as passing; a
  `repro.sh` whose only failing `not ok` lines are premise checks is `invalid_repro`, as a `repro.sql`
  already was, instead of a candidate; and only the contract's prefixes (`LIVENESS:`, `GUARD:`,
  `fixture:`, colon and case as written) mark a premise, so a defect check described "guard trigger is
  gone" is no longer discarded. `bench/classify_claims_tap.sh` drives all three through real psql output,
  with one mutation each (`classify_tap_needs_description`, `classify_sh_exit_code_only`,
  `classify_premise_bare_word`).
- **Three harness checks no longer pass for the wrong reason** (#601). `bench/throws_pinned.sh` splits
  each `throws_*` call's arguments instead of pattern-matching them, so the one-argument
  `throws_ok($$ call pgpm... $$)`, a single-quoted statement and a `format()`-built one are all judged
  (mutation `throws_ok_one_argument`). The timescale and observe tracks now fail a pgTAP file that ran
  fewer assertions than it planned, as pg_prove does (`bench/tap_verdict.sh`, mutation
  `tap_verdict_misses_plan_shortfall`). And `bench/discriminate.sh` installs every mutant of an
  `install.sql` before trusting its guard's failure, so a mutant that does not install no longer
  certifies its guard; it also reads its listing on its own descriptor and checks it read every line,
  because a guard's `docker exec -i` used to swallow the rest of the listing (on `main`, shard 4/4
  counted 76 of 78 mutations). `bench/discriminate_installs.sh` runs first in the discriminate track,
  with the mutations `discriminate_counts_uninstallable` and `discriminate_list_on_stdin`.
- **`archive.configure` refuses a `p_part_bytes` of zero or less, and `archive.to_s3` refuses a row
  holding one before it sends anything** (#594). The knob had no lower bound, and `archive.to_s3`
  fills each multipart part until it holds `part_bytes`, so with 0 its read loop never read a row: it
  initiated a multipart upload and PUT empty parts until the store refused part 10001 (about 20 s
  against MinIO, 10000 round trips against S3, all inside the caller's transaction). A row written
  before the bound, or by a raw `UPDATE`, is refused by `archive.to_s3` itself.
  `tests/archive/db/23_to_s3_part_bytes_bound_test.sql` asserts both refusals and, through a counting
  stand-in for the http transport, that the refused export sent no request while the same export
  sends its one PUT once the value is positive; `bench/archive_to_s3_part_bytes.sh` drives it against
  the `to_s3_part_bytes_unbounded` mutation, which `./test.sh discriminate` requires it to fail.

- **A cancelled `archive.to_s3` aborts its multipart upload** (#595). The abort ran only from an
  `exception when others` handler, and `others` does not catch `query_canceled`, so a
  `statement_timeout` or `pg_cancel_backend` mid-export left the upload and its parts in the bucket,
  accruing storage, against the module README's promise. Naming the cancel in that handler is not
  enough: a cancel that arrives while another error is being raised (pgsql-http's transfer aborted by
  its interrupt callback) is taken at the handler's first statement, before the abort, and measured
  against MinIO a handler that only named the cancel still leaked the upload under a real
  `statement_timeout`. The export now runs in a block of its own, and an
  enclosing `query_canceled` handler aborts whatever upload is still recorded as in flight, then
  re-raises the cancel. `tests/archive/db/24_to_s3_cancel_aborts_multipart_test.sql` covers a cancel
  raised inside the transport, a real `statement_timeout`, and a transport error with a cancel
  pending, each witnessed with one upload in flight at the key before and none after;
  `bench/archive_to_s3_cancel_abort.sh` drives it against the `to_s3_abort_misses_cancel` mutation,
  which `./test.sh discriminate` requires it to fail.
- **`extend_to` refuses before it exhausts the shared lock table** (#591). It is a function, so every
  partition one call creates holds its locks to that one transaction's end, and `p_max` (default 10000)
  was its only bound: on a stock server a call about 5000 cells out passed its own dry count and died with
  53200 `out of shared memory` after ~2100 partitions, filling the lock table every other session shares on
  the way. Once two partitions exist the call now measures what one costs in non-fast-path `pg_locks` rows,
  projects the rest of the walk, and refuses in its own words (creating nothing, since the raise rolls the
  two back) when its partitions would hold more than half the nominal lock table,
  `max_locks_per_transaction x (max_connections + max_prepared_transactions)`; the message names the measured cost and how many partitions one call can
  create. `tests/156_extend_to_lock_budget_test.sql` pins the refusal, the untouched catalog by identity and
  an in-budget call that still extends; `bench/extend_to_lock_budget.sh` is required to fail against the
  `extend_to_no_lock_budget` mutation.
- **`uninstall.sql` loses no pending foreign key and leaves no regrain copy behind** (#589). An incoming
  key `transmute(..., p_incoming_fks => 'preserve')` dropped waits in `pgpm.dropped_fk` for a maintenance
  tick to re-add it, and a paused table (the default) gets none, so an uninstall in that window dropped
  the only record with the schema and the key was gone for good, silently. Uninstall now re-adds every
  pending key through `restore_incoming_fks` first, as a tick would (`NOT VALID` on a plain referencer,
  with a `WARNING` naming each key pgpm tracked that is still unvalidated), and while any key cannot be
  restored it refuses and drops nothing, with each key's DDL and the reason in the message; deleting the
  key's `pgpm.dropped_fk` row is how to accept losing it. The schema drop now sits in the same block as
  that check, so a client that carries on past an error cannot reach it. An uninstall during a regrain
  also left the regrain's not-yet-attached fine copies as standalone tables in the operator's schema,
  with `pgpm.part`, the one record of what they were, gone; it now abandons the regrain through
  `regrain_cancel` first, as `untransmute` does (the source still holds every row).
  `tests/155_uninstall_residue_test.sql` stages both and runs the script twice (refused, then through);
  `bench/uninstall_residue.sh` drives it against the `uninstall_drops_pending_fk` and
  `uninstall_keeps_regrain_copies` mutants of `uninstall.sql` for `./test.sh discriminate`.
- **Every cell a grid can produce gets its own partition name** (#582). `obtain`, `extend_to` and
  `regrain_step` decide whether a cell's child already exists by its name, and three labels were not
  injective. The finest time label was the minute, so the two cells of a 30-second step (which
  `transmute`, `regrain` and `set_regrain` all accept) shared one: `obtain` built every other forward cell
  with nothing logged, writes into the rest were refused with "no partition of relation found", and a
  regrain toward 30 seconds copied the second cell's rows into the first cell's child and failed with a
  raw 23514 on every attempt. An id label was `lpad(floor(lo)::text, 19, '0')`, and `lpad` truncates, so
  on a `numeric` grid crossing 10^19 the cell at 10^19 took the name of the cell at 10^18 and was never
  built; `floor` dropped a fraction, so a regrain toward 0.5 put 1 and 1.5 under one name. A step under a
  minute is now labelled to the second and one under a second to the microsecond; an id label is padded
  to 19 digits but never cut, and a non-integral one keeps its fraction (`_p0000000000000000001_5`).
  Every label that was already unique keeps its form, so no existing grid's names move, and an existing
  sub-minute grid's missing cells are built by the next `obtain`. `tests/150` pins the rule, and
  `bench/part_name_labels_injective.sh` runs it against `part_name_minute_floor` and
  `part_name_id_label_truncated`. The reference's label budget named 16 bytes for a minute label; it is
  15.
- **The synchronous `regrain()` no longer deadlocks with a write into the table it is regraining**
  (#580). It runs every `regrain_step` in one transaction, so the capture trigger's SHARE ROW EXCLUSIVE
  lock on the source was held for the whole copy. A write into the source's range took ROW EXCLUSIVE on
  the parent, queued on the source still holding it, and the swap's `DETACH` then waited on that writer
  for ACCESS EXCLUSIVE on the parent: PostgreSQL broke the cycle with 40P01, aborting the application's
  write or the whole `regrain()` after all its copying. `regrain()` now takes SHARE on the parent (only
  the parent) before its first step, so a writer waits at the parent for the call and then lands in the
  fine children. Reads are unaffected; writes to the table wait for the call, which is the cost of one
  transaction, and auto-regrain, which commits every tick, takes no such lock. Pinned by
  `tests/149_regrain_writer_waits_test.sql`; `bench/regrain_writer_waits.sh` runs it against the
  `regrain_sync_no_parent_lock` mutant, which puts the deadlock back.
- **A parent renamed mid-regrain no longer wedges the regrain** (#585). `regrain_step` found the fine
  child of the sub-range it was copying by a name rendered from the parent's current relname, so after an
  `ALTER TABLE ... RENAME` of the parent (documented as harmless mid-regrain) the next tick did not find
  the child the copy had started, minted a second not-attached child for the same `[lo, hi)` and recorded
  it beside the first; the swap then failed `would overlap` on every tick until `regrain_cancel`. It now
  asks `pgpm.part` for a not-attached child with exactly the sub-range's bounds, the authority the swap
  attaches from, and renders a name only to create one. `tests/153_regrain_parent_rename_midcopy_test.sql`
  renames the parent with 4 of a sub-range's 10 rows copied, applies an update, a delete and two inserts,
  and requires the next batch to land in the started child and the swap to attach that same relation (by
  oid) with every row named; `bench/regrain_parent_rename_midcopy.sh` drives it against the
  `regrain_fine_child_by_name` mutation, which `./test.sh discriminate` requires it to fail.

- **A zero or negative regrain target step is refused** (#588). `set_regrain` refused only a target
  coarser than `partition_step` and one with over-long names, and a step of zero or below is narrower than
  anything, so it was stored: `'0'` then divided by zero on every tick (`skip_regrain` forever), and a
  negative step minted a fine child with inverted bounds and walked the cursor below `lo`, so auto-regrain
  churned `regrain_prepare` / `regrain_capture_orphan` / `regrain_restart` with the capture trigger left
  on the source, and `pgpm.regrain()` spun toward its 10,000,000-iteration limit. `set_regrain` and
  `regrain_step` (so `regrain()`, `regrain_history()` and `maintain` too) now refuse any step for which the
  grid's next boundary past `partition_anchor` is not past it, which covers an id step, a fixed interval
  and a calendar one. `tests/154_regrain_step_positive_test.sql` pins every refusal to its message on an
  id and a time grid beside a valid step each entry accepts; `bench/regrain_step_positive.sh` drives it
  against the `regrain_step_sign_unchecked` mutation, which `./test.sh discriminate` requires it to fail.
- **A resumed `transmute` refuses a control column other than the one its recorded bound is on** (#628).
  The claim a failed attempt leaves records the bound and its zone, and #574 holds a resume to its grid, but
  it did not record the control column, so a re-run on another column took the claim over, skipped phases 1 and 2 because a
  validated `pgpm_monolith_bound` already existed, and partitioned by the new column: the `CHECK` is on the
  old one and does not imply the new partition bound, so the cutover's `ATTACH` scanned the whole table under
  `ACCESS EXCLUSIVE` (or failed there on a row outside the old column's bound). `pgpm.transmute_inflight`
  gains `control_attnum`, and a resume on a different column is refused before anything is committed, naming
  both columns, with the claim and its bound left as they were. The column is compared by attribute number,
  the identity the `CHECK` holds, so the same column renamed in between still resumes; a claim recorded
  before the column existed is not checked. `tests/182` fails a cutover on `a` and re-runs it on `b` and on
  `a` renamed; `bench/transmute_resume_control_column.sh` runs it against `transmute_resume_any_column`.
- **A resumed `transmute` refuses a step or anchor its recorded bound is not on** (#574). The claim a
  failed attempt leaves records the bound (and its zone) but not the step and anchor it was computed on,
  so a re-run with another step reused the bound and registered the new step. The recorded `hi` was not
  a boundary of the new grid: `obtain` skipped the new grid's cell that overlaps the monolith and started
  one cell later, leaving a permanent hole right past the monolith's `hi` where every write failed with
  "no partition of relation found for row". A resume now checks that the recorded `lo` and `hi` are
  boundaries of the call's step and anchor in the claim's zone, and refuses before anything is committed
  when they are not, naming both and what each floors to; the claim and its bound are left as they were,
  for a re-run with the original step or `transmute_abort`. The check is on the lattice, not the
  spelling, so a step the bound is flush with (5 after 10) still resumes. `tests/139` fails a step-10
  cutover and re-runs it with step 7, anchor 5 and step 5; `bench/transmute_resume_lattice.sh` runs it
  against `transmute_resume_any_step`.

- **The transmute sweep and `transmute_abort` find a half-converted table by oid** (#575). Both resolved
  the table by the schema and name its claim recorded, so a table renamed or moved to another schema
  after its conversion failed read as gone: the sweep deleted the claim and left the write-rejecting
  `pgpm_monolith_bound` `CHECK` with nothing recording it, and `transmute_abort`, called by the new
  name, altered the old one, which no longer exists. Both now use the claim's `parent_table` oid, and the
  sweep forgets a claim only when that oid names no relation at all. `tests/140` renames one failed
  conversion, moves one, drops one and aborts a fourth by its new name;
  `bench/transmute_reap_identity.sh` runs it against `transmute_reap_by_name`.

- **`transmute` refuses a non-positive step, a date step that is not whole days, and a negative or null
  `p_obtain`** (#581). None was checked. A negative step computed `lo > hi`, so phase 1 committed an
  unsatisfiable bound `CHECK` and the table rejected every write until an abort (a corrected re-run
  resumed the same bound and failed again), and a zero one divided by zero. A sub-day step on a `date`
  column had its bounds truncated to dates, so phase 2 validated a `CHECK` of `dt < current_date` and the
  cutover died on an empty hourly range, leaving every row dated today rejected. `p_obtain => -1`, which
  `set_obtain` refuses as a silent no-op, registered a grid `obtain` never extends, so the first write
  past the monolith failed. All three are now refused before anything is committed, `p_obtain` with
  `set_obtain`'s own message. `tests/141` pins each refusal by its message and then converts every
  fixture with the corrected argument; `bench/transmute_step_preflight.sh` runs it against
  `transmute_no_step_obtain_preflight`.
- **A GZIP encode no longer takes lock-table entries, so one archive tick cannot exhaust the cluster's
  lock table** (#587). `archive._pq_huffman_lengths`, which runs three times per dynamic-Huffman
  encode, built its merge queue in a temp table it created and dropped on every call, and a dropped
  relation's locks are held to transaction end: ~15 shared lock-table entries per call, ~44 per
  encode. A `pgpm.maintain()` tick with `archive_batch` null archiving 25 partitions of a 29-column
  compressed-Parquet table (~725 encodes in one transaction) failed with 53200 `out of shared memory`
  at the default `max_locks_per_transaction`, for every session in the cluster while it lasted,
  logged `skip_archive`, archived nothing and did the same again every tick; `archive.to_s3` with
  `compress` on hit the same cliff at ~600 members. The queue is now local arrays, which take no
  lock, and builds the same codes byte for byte. `tests/archive/db/22_huffman_lock_entries_test.sql`
  counts this backend's lock entries across twenty Huffman builds and ten encodes in one transaction
  and requires no growth, with a temp-table control that proves the instrument sees the mechanism and
  known-answer vectors taken from the old implementation; `bench/archive_huffman_lock_entries.sh`
  drives it against the `archive_huffman_temp_table` mutation, which `./test.sh discriminate`
  requires it to fail.
- **`untransmute` no longer validates a preserved incoming FK under its `ACCESS EXCLUSIVE`** (#577). It
  re-added each key `NOT VALID` and then ran `VALIDATE` in the same call, which is one transaction already
  holding `ACCESS EXCLUSIVE` on the restored table, so every reader and writer of it waited out a full scan
  of the referencing table during what the reference calls a metadata-only reverse, and an orphan written while the key was suspended rolled the whole reverse back.
  The key on an unpartitioned referencing table now comes back `NOT VALID`, enforcing every new write, and
  a `NOTICE` names the `ALTER TABLE ... VALIDATE CONSTRAINT` to run afterwards, in its own transaction,
  where it blocks neither table. `pgpm` forgets the table at the end of the call, so nothing validates it
  for you. Guarded by `bench/untransmute_fk_validate_lock.sh` (locks held at the end of the call and the
  referencing table's scan counters) and its mutation `untransmute_inline_validate`; tests/145 states the
  contract.
- **`maintain_all` visits the table whose turn is oldest first, so a backlog cannot starve the tables
  behind it** (#579). The scheduled sweep is one top-level statement, so `statement_timeout` runs
  across every table in it, and the cancellation escapes `maintain()`'s step handlers. The sweep went
  `order by parent_table` every tick, so a table with a backlog of documented-size archive chunks near
  the front spent the clock on every tick and every table behind it was cancelled on every tick, never
  archived or retired. A new `config.sweep_turn_at` records each table's turn when its `maintain()`
  returns, and for the sweep's first table as it starts; the sweep orders by it, oldest (or never) first.
  A table cut short leads the next sweep, and one whose own tick overruns the timeout cannot lead every
  sweep. Guarded by `tests/147` through `bench/maintain_all_sweep_turns.sh`, against the mutations
  `maintain_all_fixed_sweep_order` and `maintain_all_no_first_turn_stamp`.

- **A lock race in `maintain()`'s auto-regrain candidate search defers the regrain step instead of
  ending the sweep** (#590). The candidate search reads the parent (through `_frontier_native`) under
  the tick's 200 ms `lock_timeout`, and it ran ahead of the regrain step's exception handler, so while
  another session held a lock on a table with `regrain_to` set the lock timeout raised out of
  `maintain()` and `maintain_all()` stopped before every table ordered after it. The search now runs
  inside the regrain step's handler: a `skip_regrain` row, `regrain=deferred`, retried next tick.
  Guarded by `tests/148` through `bench/regrain_candidate_lock_race.sh`, against the mutation
  `regrain_candidate_outside_handler`.
- **`set_partition_tz` judges every bound of the grid, not only the newest** (#583). It refused a zone
  whose lattice the newest attached bound was not on, and two zones can agree there and disagree
  further down: UTC and `Europe/London` share every month edge from November to March and none from
  April to October, so a UTC month grid whose monolith ended on October 1 and whose top was December 1
  was moved to London. The monolith could then never be regrained: regrain clamps its sub-ranges to the
  child's bounds, the last one, `[09-30 23:00Z, 10-01 00:00Z)`, rendered the name of the forward cell
  at October 1 and got no fine child, and every swap refused, auto-regrain logging `skip_regrain` on
  every tick with a message blaming retention. Every attached bound that is a grid boundary in the
  recorded zone must now be one in the new zone too, and the refusal names the oldest one that is not
  and its partition. A bound the recorded zone does not put on the lattice (a finer regrain's day
  child, or a grid built in a zone pgpm never recorded) is not judged, so the upgrade case is still
  accepted. `tests/151` pins it; `bench/set_partition_tz_every_bound.sh` runs it against
  `set_partition_tz_newest_bound_only`.

- **A month floor never exceeds its input where a fall-back repeats midnight on the 1st** (#584).
  In `America/Havana` the clocks go back from 01:00 CDT to 00:00 CST on 2020-11-01 and again on
  2026-11-01, and `at time zone` resolves the repeated 00:00 to its later occurrence, 05:00Z, which is
  where every grid in such a zone has its November edge. `_grid_floor` returned that edge for a value in
  the first occurrence of the hour, so the floor of 04:30Z was 05:00Z, above its input; `transmute` takes
  the floor of the oldest value as the monolith's lower bound, so a table whose oldest row fell in that
  hour got a bound CHECK excluding it and failed at VALIDATE on every run. The floor is now the greatest
  grid point at or below its input: such a value floors to the October edge, the cell every existing
  grid already routes it to. The lattice itself does not move, so no existing partition changes width.
  `tests/152` pins it; `bench/month_floor_doubled_midnight.sh` runs it against
  `grid_floor_month_later_midnight`.
- **`transmute(p_incoming_fks => 'preserve')` of a table referenced from a partitioned table completes**
  (#576). The cutover dropped every foreign key whose referenced table was the one being converted,
  including the per-partition copies of a key declared on a partitioned referencing table. Dropping the
  declared key removes those copies, so the next drop failed with `constraint ... does not exist`, the
  cutover rolled back, and the table kept the write-rejecting `pgpm_monolith_bound` and a claim that every
  re-run failed on the same way. The cutover now drops and records the top-level keys only, and
  `restore_incoming_fks` re-adds each at the partitioned table, which copies it to every partition.

- **`transmute` refuses a secondary index too long to carry, instead of calling it a leftover to drop**
  (#592). The partitioned copy of each secondary index is named `<index>_pgpm`, and that name was cut to
  63 bytes unchecked. For an index already at 63 bytes, which is what PostgreSQL's own auto-naming gives a
  long table and column list, the cut name was the index's own, so the collision check refused it as a
  leftover of an interrupted run and told the operator to drop it: their own index. `transmute` now
  refuses up front, naming each index over 58 bytes and asking for a rename, with nothing committed.

- **A trigger created while `transmute`'s cutover runs reaches the new parent** (#593). The cutover
  captured the table's triggers before its staging work, under a lock that does not exclude
  `CREATE TRIGGER`, and replayed only what it had captured; a trigger another session committed in
  between stayed on the monolith alone, or was dropped from it, and rows routed to forward partitions
  escaped it with nothing logged. The capture now happens under the table's `ACCESS EXCLUSIVE`, taken
  explicitly as the outage begins (where the incoming-FK drop or the rename took it before), so the
  outage is no longer than it was.
- **An upgraded day grid builds the cell its old labels collide with** (#572). #503 relabelled day and
  week cells by the UTC date of their start and left existing partitions under their old names, the wall
  date of their start in `partition_tz`. East of UTC with the grid anchored at local midnight (Asia/Tokyo:
  cells start 15:00Z) a cell's wall date is its UTC date plus one, so the new label of every cell is the
  old label of the cell before it, and on a grid converted before the upgrade the first cell past the last
  old-named partition rendered the name that partition carries. `obtain` and `extend_to` took the taken
  name for "already built" and skipped the cell: a one-day hole that refused every write into it, nothing
  logged, while the cells after it were built. Both now ask their overlap check first and, when a missing
  cell's plain name belongs to one of the parent's own partitions (by `pgpm.part.child_oid`) over a
  different range, build it under its explicit-range name `_p<lo>_to_<hi>`, leaving the old partition
  untouched; a name held by anything else is left alone as before. `tests/138` builds the pre-#503 state on
  two Tokyo grids, and `bench/legacy_day_labels.sh` runs it against `legacy_day_label_skipped_by_name`.
- **A uuidv7 millisecond holding a chunk's worth of rows no longer wedges archiving and retention**
  (#571). #513's extension of a chunk past a native unit read the first row minted after it with
  `min(<control>)`, the one aggregate read in `pgpm._next_archive_chunk` that #507 missed, and PostgreSQL
  has no `min(uuid)` before 18. So on PostgreSQL 15 to 17 every pick that reached it raised 42883: each
  tick's archive step was logged `skip_archive`, no ledger row was written past the burst, and the aged
  partition was never covered nor retired. The read is now `ORDER BY ... LIMIT 1`, and the burst travels
  as one oversized chunk as `docs/reference.md` says it does. `tests/137_archive_chunk_uuidv7_ties_test.sql`
  is tests/125's tie fixture as uuidv7 (100 ids in one millisecond, a budget for fewer) and asserts the
  direct pick and the ledger's exact three chunks through write-block, archive and retire;
  `bench/archive_chunk_uuidv7_ties.sh` runs it in the perf track, and `./test.sh discriminate` requires it
  to fail against `archive_chunk_native_tie_min_uuid`, the mutation that puts `min()` back.
- **`obtain()` stops at an `int` or `smallint` id column's type ceiling with what it built, instead of
  building nothing** (#578). Its grid-ceiling check only ran `_encode` on the candidate's upper bound, and
  `_encode` is a passthrough for `id`, so it could not see that an `int` column ends at 2147483647. On a
  table whose frontier was within `obtain` steps of that, the first inexpressible bound raised from
  `CREATE TABLE ... PARTITION OF`, rolling back every partition the call had built: `maintain_obtain`
  logged `skip_obtain` every tick, the grid froze, and writes of ids with a perfectly expressible
  partition were refused until an operator ran `extend_to` by hand. `transmute` of such a table failed
  outright, since it calls `obtain`. The check now casts the encoded bound to the control column's own
  type, the same coercion the partition bound gets, and exits the lookahead where that overflows.
  Guarded by `tests/146_obtain_int_ceiling_test.sql` and `bench/obtain_int_ceiling.sh`, whose mutation
  `obtain_ceiling_encode_only` removes the cast.
- **A `from_hypertable_cutover` whose handoff to `transmute` refuses no longer loses the incoming keys or
  the identity position** (#563). The cutover commits its swap (hypertable dropped, incoming foreign keys
  dropped, the copy renamed into place with identity re-added) before calling `transmute`, and it held the
  dropped keys' definitions and the source sequence's position in plpgsql locals until `transmute` returned.
  A refusal there (reproduced with a 45-byte table name, whose daily monolith name is over 63 bytes) left
  the referencing tables with no key and nothing recording one, no `pgpm.dropped_fk` row and no log row,
  and the plain table's identity restarting at 1, reissuing ids the table already held. The swap now
  records each dropped key in `pgpm.dropped_fk` (logged `drop_incoming_fk`) against the table it puts in
  place and sets the re-added identity to the source's position, both in the swap transaction, and
  `transmute`'s cutover moves every `pgpm.dropped_fk` record naming the table it converts onto the new
  parent, so the operator's re-run of `transmute` after the refusal brings the keys back through
  `restore_incoming_fks`. The reference now says what a refused handoff leaves and how to finish it.
  `tests/timescale/db/21_from_hypertable_swap_order_test.sql` pins on a real hypertable that the records
  and log rows predate the handoff's `transmute` row, and the carry on its own;
  `bench/hypertable_swap_order.sh` drives the refused handoff as a bare CALL and asserts both keys by name,
  the next id (8 against a `max(id)` of 3) and the recovery, and fails against the
  `hypertable_swap_fk_record_after_handoff`, `hypertable_swap_identity_from_one` and
  `transmute_dropped_fk_parent_not_carried` mutations under `./test.sh discriminate`.
- **A regrain whose change capture the janitor reaped restarts from the source instead of resuming from
  unreconciled copies** (#569). `regrain_step`'s prepare tick discards the copies made without capture
  behind them, but only when `config.regrain_cursor` was set. The capture janitor is documented as the
  backstop for a cursor cleared by some other route (a hand edit): it tears down the capture the null
  cursor does not cover and leaves the copies, so the next run re-installed capture, resumed from them,
  and the swap attached rows that never saw the changes made while capture was off: a committed UPDATE
  reverted, a committed DELETE came back, a committed INSERT vanished. The discard is now decided by the
  copies, not the cursor: with no capture installed, every not-attached copy inside the source's range is
  dropped, and `regrain_restart` is logged when one was (or, as before, when a cursor was set). The
  reference now says so. `tests/135_regrain_restart_null_cursor_test.sql` witnesses the copy, the reaped
  capture and the uncaptured changes, then asserts the restart row, the dropped copy and the rows through
  the swap by identity; `bench/regrain_restart_null_cursor.sh` drives the same file for
  `./test.sh discriminate`, where the `regrain_restart_needs_cursor` mutation puts the defect back.

- **The regrain reconcile files each captured change by its instant in any session `DateStyle`** (#570).
  `_regrain_reconcile` rendered each captured key's control value with a bare `::text`, in the session's
  `DateStyle` and `TimeZone`, and parsed it back to pick the key's fine child. Under `SQL` `DateStyle` in
  `Asia/Kolkata` the text reads `IST`, which the default `timezone_abbreviations` parse as Israel (+02), so
  every key was filed 3.5 hours late: a captured DELETE was consumed against the wrong fine child and the
  swap brought the deleted row back, and a captured UPDATE or INSERT was reinserted into a child whose
  CHECK refused it, wedging the regrain. Both the timestamptz and the naive (`timestamp`, `date`) render
  now go through `_ts_text`, which pins ISO. `tests/136_regrain_reconcile_datestyle_test.sql` copies in a
  UTC session and reconciles and swaps from a `SQL, MDY` / `Asia/Kolkata` one, witnessing the `IST` render
  and the 3.5-hour round trip, and asserts by identity which fine child serves each row;
  `bench/regrain_reconcile_datestyle.sh` drives the same file for `./test.sh discriminate`, where the
  `regrain_reconcile_bare_text` mutation puts the defect back.
- **The Parquet writer reads a negative numeric scale as negative** (#567). Since PostgreSQL 15 a
  numeric typmod's scale is a signed 11-bit field, and both encoders read it as the unsigned low 16
  bits, so a `numeric(5,-2)` column was written at scale 2046: every value came out as zero and the
  footer declared a scale no reader accepts, while the upload and the ledger row succeeded. The column
  shape now comes from one helper, `archive._pq_decimal_shape`, which decodes the signed scale and
  writes `numeric(p,-k)` as `DECIMAL(p+k, 0)`, every value exactly as itself.
  `tests/archive/db/18_parquet_negative_scale_test.sql` pins the leaf and the value bytes of both
  encoders; `bench/archive_parquet_negative_scale.sh` reads the files back with pyarrow and DuckDB and
  is required to fail against the `parquet_numeric_scale_unsigned` mutation.
- **The Parquet writer archives `infinity` and `-infinity` timestamps** (#586). A `timestamptz` or
  `timestamp` holding either raised `cannot convert infinity to bigint` on every encode of its chunk,
  so `maintain()` logged `skip_archive` every tick and, at `archive_batch`'s default of 1, the
  partition and every younger one of the table were never archived or retired. They are now written as
  INT64 max and minus INT64 max, the pair DuckDB reads back as `infinity` and `-infinity`.
  `tests/archive/db/19_parquet_timestamp_infinity_test.sql` pins the bytes and runs the issue's two
  ticks; `bench/archive_parquet_timestamp_infinity.sh` reads the files back with pyarrow and DuckDB and
  is required to fail against the `parquet_timestamp_no_infinity` mutation.
- **The Parquet writer declares a precision that covers the scale** (#596). A `numeric(2,4)` column
  (legal since PostgreSQL 15) was declared `DECIMAL(2,4)`, which Parquet forbids and pyarrow refuses
  for the whole file, while the upload and the ledger row succeeded. Such a column is now declared
  `DECIMAL(s, s)`, which holds its values unchanged.
  `tests/archive/db/20_parquet_scale_above_precision_test.sql` pins the leaf and the value bytes;
  `bench/archive_parquet_scale_above_precision.sh` reads the files back with pyarrow and DuckDB and is
  required to fail against the `parquet_decimal_scale_above_precision` mutation.
- **The Parquet strategy archives keyless tables** (#597). `archive._pq_to_parquet_range` refused a
  parent with no primary key or unique constraint on every chunk, for want of a tiebreak on the
  control column, while `pgpm.set_archive_fn` accepted `pgpm.archive_to_s3_parquet` for it: every
  tick logged `skip_archive` and nothing of the table was covered or retired. The tiebreak has been
  unnecessary since every column is read from one numbered snapshot, so a keyless parent is now
  ordered by its control column alone, and a keyed table's bytes do not change.
  `tests/archive/db/21_parquet_keyless_test.sql` asserts that tied rows keep their values together
  and runs the issue's tick; `bench/archive_parquet_keyless.sh` reads the file back with pyarrow and
  DuckDB and is required to fail against the `parquet_range_refuses_keyless` mutation.
  `scripts/verify_parquet_range.py`'s two refusal checks now assert the archive instead.
- **`retire()` discards archive coverage it finds without its write block, instead of dropping on it**
  (#564). `_enforce_write_blocks` has discarded ledger rows on an unblocked partition since #452 (a
  trigger dropped by hand, or lifted by an older pgpm, leaves a watermark nothing has been guarding),
  but `retire()` is documented as independently callable and only `maintain()` is guaranteed to run
  that step first. Called directly on a fully archived partition whose block had gone, `retire()`
  re-installed the block, read the stale watermark as full coverage and dropped the partition with a
  row written while it was unblocked that no strategy was ever handed. It now makes the same discard
  before it installs the block, logged as `archive_coverage_reset` with the number of chunks, and
  returns `false`; archiving starts over from `lo` under the restored block and a later call drops the
  partition once every row in it has been handed over. `tests/130_retire_unguarded_coverage_test.sql`
  asserts by identity which ledger rows go, that the unguarded row survives and is archived before the
  drop, that a guarded sibling is still dropped, and that no reset is logged where there was no
  coverage; `bench/retire_unguarded_coverage.sh` drives the file against the
  `retire_trusts_unguarded_coverage` and `retire_coverage_check_after_block` mutations, which
  `./test.sh discriminate` requires it to fail.
- **`transmute` puts the new parent in every publication that named the table** (#566). The #277
  carry-over replayed owner, grants, RLS, policies, comments and triggers, but not publication membership.
  `pg_publication_rel` records a table by oid, and the cutover renames that oid into the monolith, so a
  publication `FOR TABLE` the table went on publishing the monolith alone. The new parent and every forward
  partition were in no publication, and every row written past the monolith was silently not replicated
  (logical subscribers, Supabase Realtime). The cutover now adds the parent to each of those publications
  with the same row filter and column list. The monolith keeps its own membership, so an `untransmute`
  hands the table back still published. A publication with `publish_via_partition_root = false` that names
  the table with a row filter or a column list is refused up front, before anything is committed:
  PostgreSQL does not allow either on a partitioned table in such a publication, and dropping them would
  replicate what the operator excluded. `tests/132_transmute_publication_membership_test.sql` asserts the
  exact set of publications, the carried filter and column list, and what `pg_publication_tables` offers a
  subscriber. `bench/transmute_publication_membership.sh` runs the same file for `./test.sh discriminate`,
  where the `transmute_publication_not_carried` mutation puts the defect back.

- **A serial column's sequence follows the table through `transmute`, so retention can drop the
  monolith** (#573). `CREATE TABLE ... LIKE INCLUDING DEFAULTS` copied the column's `nextval()` default onto
  the new parent, but the sequence stayed `OWNED BY` the original oid, now the monolith. `DROP` of the
  aged-out monolith then failed with "other objects depend on it" and logged `fail_retain_drop` on every
  tick, so the monolith could never be retired. The cutover now moves every sequence the table owns through
  a column onto the same column of the parent. `untransmute` moves it back before it drops the parent,
  since the parent's drop would otherwise take the sequence the restored table's default still calls.
  `tests/133_transmute_serial_sequence_owner_test.sql` covers two serial columns and a sequence the table
  only calls, retention past the monolith, and the reversal. `bench/transmute_serial_sequence_owner.sh`
  runs it for `./test.sh discriminate` against the `transmute_serial_owner_not_moved` and
  `untransmute_serial_owner_not_returned` mutations, one per site.
- **An interval retain is refused if any of its fields is negative, not only when it compares below zero**
  (#565). The sign check `pgpm.transmute` and `pgpm.set_retain` apply to `p_retain`, and the defence in
  depth in `_retain_boundary` and `regrain_step`, compared the interval with zero, which PostgreSQL does on
  a 30-day-month, 360-day-year normalisation; the horizon it protects is calendar arithmetic on the wall
  clock. So `'-1 year 360 days'` compared equal to zero and was accepted, its horizon sat five or six days
  in the FUTURE, and the first maintenance tick dropped every partition up to it, the one taking writes
  included, with the rows written that day. `_retain_nonnegative` now judges the months, days and time
  fields separately and refuses the value if any is negative, which every entry point inherits; a mixed-sign
  value that happens to net positive (`'1 mon -1 day'`) is refused with the rest. A config already holding
  one keeps every partition and logs `skip_write_block` and `skip_retain` until `pgpm.set_retain` repairs
  it. `tests/131_retain_interval_sign_test.sql` pins the rule, each entry point and the tick;
  `bench/retain_interval_sign.sh` runs it against the `retain_interval_normalised_compare` mutation.

- **CI caches the third-party images, so a burst of PRs cannot spend a registry's anonymous quota**
  (#558). On 2026-09-26 seventeen PR heads pushed within twenty minutes spent ECR Public's anonymous
  data quota for `public.ecr.aws/supabase/postgres` (`toomanyrequests: Data limit exceeded`) and
  failed a TimescaleDB job outright; `test.sh`'s five-attempt backoff is sized for a rate limit, which
  clears in seconds, not for a quota, which does not. The TimescaleDB job, the archive job and every
  `discriminate` shard (each of which brings MinIO up from Docker Hub) now restore a `docker save`
  tarball from the Actions cache, keyed on the exact image reference compose resolves, and save one
  after a miss whether the tests passed or not. `test.sh` skips the pull of an image that is already
  present, so a cache hit never calls the registry. MinIO is cached under the local tag
  `pgpm-cache/minio:<digest>`, which `PGPM_MINIO_IMAGE` points compose at, because the runners'
  classic image store drops the digest on `docker save` and a loaded copy could not answer to the
  pinned reference itself.

- **Review tooling: verifiers store the reproduction they rebuilt, seeds record their side effects, and
  issues are filed by script** (part of #558). In pass 2 five candidates reached their defect only because
  another seed had frozen the monolith; their verifiers rebuilt the fixtures but never stored them, so the
  issues shipped with reproductions that could not close them. The `verifier` agent now writes any rebuilt
  reproduction as `repro.verified.sql` (or `.sh`) beside the finder's and marks its verdict
  `"rebuilt": true`. `scripts/review/classify_claims.py` runs that file in preference to the finder's, records
  `repro_used` per claim, counts the verified ones in its summary, and classifies a reproduction with no
  `LIVENESS:` assertion as `invalid_repro` without running it (the prefix is now mandatory in the finder's
  contract). A plan entry's optional `side_effects` reaches `sealed.json` and `--catalogue`, and
  `pass_metrics.py` prints it in the record's new "Seeds" section and lists, under "Seed interactions to
  check", every candidate whose pristine run failed only its liveness checks. The new
  `scripts/review/file_issues.py` renders one issue per root-cause group with the reproductions inline
  (the verified one when present) and an acceptance paragraph, and with `--post` files them Tier 1 first
  and writes `filed.json`. Each script's `--selftest` holds the new cases and runs in the lint workflow.

- **The fix phase has its own tooling and roles.** `scripts/review/land.sh` lands fix PRs through the
  squash merge queue one at a time (rebase onto `main`, keep-both resolution of the three list files
  with `keep_both.py`, the checks CI would fail on run first, known flakes retried once via
  `flake_check.sh`); `closure.sh` re-runs every reproduction of a pass against the fixed `main` and
  `close_comments.py` posts the evidence per issue, reopening one whose sound reproduction still
  fails. A `fixer` agent and the `/fix-phase` coordinator skill give parallel fixers assigned test
  numbers, guard databases and scratch, so the next wave does not collide (issue #558).
- **`text_time` refuses a collation that weighs a run of digits by its value** (#568). The #456 check
  compared each adjacent digit pair as `'<d><max>...' < '<d+1><zero>...'`, which proves the digits are
  separated at the primary level for a collation that compares position by position and says nothing
  about one that does not. An ICU collation with numeric ordering (`und-u-kn-true`, or any locale
  carrying `-u-kn-true`, possible as a database default on 15+) compares a run of decimal digits by its
  numeric value, so `'ck9abcde'` sorts before `'ck10000'`, and it passed (1 is less than 2000...):
  `transmute` accepted a cuid column under it, late-November rows landed in the December partition,
  where retention drops them a month early, and some February rows were rejected with `no partition of
  relation found for row`. The check now also probes the opposite padding (`'<d><zero>...' <
  '<d+1><max>...'`) and a lower cell's string extended by each digit against the next cell's bound,
  which is what catches a pure-decimal alphabet, whose paddings are digits either way. Both hold under
  every collation the first probe accepts for the right reason, so cuid, ULID and ObjectId on `en_US`
  or on ICU without numeric ordering still convert. The refusal message now also names the pair of
  strings the collation misordered. New: `tests/134` and `bench/text_time_numeric_collation.sh`,
  required to fail against the `text_time_collation_positional_only` mutation.
- **`archive.to_s3` honours `archive.config.compress`** (#520). The synchronous NDJSON export never
  read the flag: with it on, it uploaded plain NDJSON at `<prefix><child>.ndjson`, while the module's
  README promised GZIP for either format and `archive.to_s3_parquet` and both `archive_fn` strategies
  honoured it, so a reader pointed at the documented `.ndjson.gz` key found nothing. With the flag on
  it now writes a GZIP stream at `<prefix><child>.ndjson.gz` (Content-Type `application/gzip`), the
  key the automatic NDJSON strategy already uses, and nothing at the plain key. A large export
  compresses each `part_bytes` text chunk into a gzip member of its own and accumulates members into
  a multipart part until the part is full, since S3 and MinIO refuse a non-final part under 5 MiB; the
  concatenation is one valid gzip file (RFC 1952) and memory stays bounded as before.
  `tests/archive/db/16_to_s3_compress_test.sql` exports through both the single-PUT and the multipart
  path and checks the single member's CRC-32 and length against the partition's NDJSON;
  `bench/archive_to_s3_compress.sh` inflates both objects with Python's gzip and asserts every row by
  identity, and drives the file against the `to_s3_compress_unread` mutation, which
  `./test.sh discriminate` requires it to fail.

- **The SigV4 signers stamp `x-amz-date` from the wall clock, not from the transaction start** (#520).
  `archive.s3_signed_request` and `archive.s3_signed_request_bytea` read `now()`, which in PostgreSQL is
  the transaction's start time, so every S3 request a transaction made carried the same stamp, and S3
  and MinIO refuse one more than 15 minutes from their own clock (HTTP 403 `RequestTimeTooSkewed`).
  `archive.to_s3` signs a whole multipart export inside one transaction and a `pgpm.maintain()` tick
  signs every chunk it archives inside one, so an export or a tick that ran past fifteen minutes had
  every later request refused: a loud abort with the partition kept, but the README's "handles any
  size" did not hold. Both signers now read `clock_timestamp()`.
  `tests/archive/db/17_sigv4_wall_clock_test.sql` records the stamps through a stand-in for the http
  extension and asserts that a stamp taken two seconds into a transaction is later than the
  transaction start; `bench/archive_sigv4_wall_clock.sh` drives it against the
  `sigv4_transaction_start_stamp` mutation, which `./test.sh discriminate` requires it to fail.
- **A refusal assertion around a committing procedure pins the SQLSTATE or the message, and a guard
  keeps every one of them pinned** (#522). pgTAP's `throws_ok` and `throws_like` run the statement
  under test inside a plpgsql function, so a procedure that does NOT refuse runs on to its first COMMIT
  there and dies with 2D000 `invalid transaction termination`, rolling back into the same state a
  refusal leaves. `throws_ok(sql, NULL, description)` pins neither SQLSTATE nor message (the
  three-argument overload reads a second argument that is not five octets, NULL included, as the
  message), so four refusal tests passed with their refusal deleted: the transition-table refusal in
  `tests/72_transmute_attributes_test.sql`, the keyless and nullable-key `p_track_changes` refusals in
  `tests/timescale/db/10` and `14`, and the E2 cutover failure in `tests/timescale/db/08`. Each now pins
  the refusal's own message with `throws_like`, or for E2 the DROP's `2BP01` and its message, and each
  was shown to fail with its refusal removed (the first three on that 2D000, E2 on a COMMIT moved ahead
  of the DROP). `bench/throws_pinned.sh` re-issues every `throws_*` around `call pgpm.` with the
  statement swapped for one that raises exactly that 2D000 and requires pgTAP to say `not ok`, after two
  controls prove the instrument; `./test.sh discriminate` requires it to fail against
  `throws_ok_null_pattern`, the catalogue's first test-file mutation. The issue's third finding, three
  wrapper-driven files missing from `perf.yml`'s path filter, was already moot: the filter went when PRs
  moved to the merge queue, and the perf and discriminate jobs run on every PR.
- **Retention dropping the coarse source of an in-flight regrain reclaims that regrain instead of
  orphaning it** (#519). With auto-regrain, an `archive_fn` and `retain` all on, the archive step and the
  regrain worked the same wholly-aged coarse child at once, and when archiving covered it first `retire()`
  dropped it and left everything the regrain had built behind: not-attached `pgpm.part` rows that no
  partition covered, standalone fine copies still holding the rows retention had just dropped,
  `config.regrain_cursor` pointing into a range that no longer existed, and no tick able to reclaim any of
  it (auto-regrain answered `none`, the capture sweep only tears down what the cursor does not cover). No
  rows were lost, the source had been archived, but the documented pipeline was not kept and the
  leftovers held disk and misreported `status().inflight_partitions` for good. `retire()` now calls a new
  `pgpm._regrain_reclaim` in the drop's own subtransaction, ahead of the `DROP`: it discards the copies
  inside the dropped range, the captured changes when this child carries the capture trigger, and the
  cursor when it is unambiguously this child's, and logs one `regrain_cancel` row whose `method` names
  `retire`. Scoped to the source, not the parent, so a regrain in flight on another child is untouched
  and a refusal reclaims nothing; reclaimed rather than refused because `set_regrain(parent, null)`
  leaves cursor and capture in place, so a `retire` that waited for the regrain would wait forever. The
  `retain`, `retire`, `regrain_step`, `regrain_cancel` and `pgpm.log` entries in `docs/reference.md` and
  the retention bullet in `docs/guide.md` describe it. `tests/129_retire_regrain_source_test.sql`
  reproduces the scheduled path, the hand-driven path with a captured change pending, and the neighbour
  case, asserting by identity which copies existed at the drop and that none survives it;
  `bench/retire_regrain_source.sh` drives it against the `retire_drops_regrain_source` and
  `retire_cancels_whole_parent_regrain` mutations, which `./test.sh discriminate` requires it to fail.
- **A substituted partition name no longer discards the real partition's archive coverage** (#518).
  `_enforce_write_blocks` decided "coverage found without its block" by name,
  `_is_write_blocked(child_name)`, at the top of its loop body, before the identity check
  `_install_write_block` makes further down. A relation holding a partition's name has no trigger, so
  the tick deleted the `pgpm.archive_ledger` rows describing the real partition (still attached, still
  write-blocked, merely renamed aside) and logged `archive_coverage_reset` in the same tick that logged
  `fail_write_block_identity` for the same child; once the name was sorted out, archiving started over
  from `lo`. No row was lost, but ledger rows naming archived objects were destroyed on the strength of a
  relation that was not the partition, against the guide's promise that every step acting on a name
  checks it first. The loop now resolves each child's name against `pgpm.part.child_oid` before anything
  it decides by that name, with the same predicate as the install (a null anchor compares as nothing; a
  name resolving to nothing stays on the `skip_write_block` path), and a substituted name suppresses the
  discard: the identity refusal is the whole of what the tick does for that child.
  `tests/129_coverage_reset_identity_test.sql` reproduces the substitution, asserts by identity that the
  ledger row survives and that the first tick after the name is restored archives from the watermark
  rather than from `lo`, and pins the positive side (trigger really gone, identity intact: still
  discarded) and the unanchored side (a null `child_oid` is not a mismatch);
  `bench/coverage_reset_identity.sh` drives it against the `coverage_reset_by_name` and
  `coverage_reset_unanchored_is_mismatch` mutations, which `./test.sh discriminate` requires it to fail.

- **The guide's database.dev snippet names the version this tree installs, and the reference names only
  log actions pgpm writes** (#521). `docs/guide.md`'s `create extension ... version '0.4.0'` sat two
  releases behind `extension.control`'s `0.6.0`, because RELEASING.md's list of files to bump at release
  time did not include it, so an operator following the guide installed a release this file lists fixes
  for. And `docs/reference.md`'s Foreign keys section promised `from_hypertable_adopt_fk` beside
  `from_hypertable_carry_fk` after the cutover's adopt step, its only writer, was removed (transmute's
  parent-level re-add logs nothing), so an alert on that action, part of the log-action contract
  RELEASING.md spells out, could never fire. The pin is `0.6.0`, the sentence names
  `from_hypertable_carry_fk` alone, and RELEASING.md and ONBOARDING.md list the pin as the third file a
  release bumps. `scripts/check_living_docs.sh` gained two checks that keep both true: every
  `version 'X.Y.Z'` literal in a living document must equal `extension.control`'s `default_version`, and
  every `pgpm.log.action` the operator docs name (the reference's vocabulary table and every "logged
  `x`" sentence) must be a literal some `install.sql` writes, failing loudly when the vocabulary table
  cannot be found rather than passing on nothing. Its new `--selftest`, which the `Living docs` lint job
  now runs first, re-breaks a scratch copy four ways (the stale pin, the phantom action in prose and as a
  table row, the vocabulary heading moved) and requires each check to fail against its re-break.

- **Turning auto-regrain off mid-flight abandons the run it started, instead of stranding it** (#516).
  `set_regrain(parent, null)` wrote `regrain_to` and nothing else. `maintain` dispatches `regrain_step` only
  while `regrain_to` is set, so the run in flight was never driven again, and the capture janitor keeps
  capture on the child whose range covers `config.regrain_cursor`, which nothing cleared, so it was never
  swept either: the capture trigger kept taxing every write into the source and filling a delta nobody
  drained, the not-yet-attached copies stayed on disk, and `TRUNCATE` of the parent stayed refused as "a
  regrain is in flight", indefinitely, until the operator found `regrain_cancel`. The reference promised
  `maintain` would sweep it and the runbook promised the run would complete; the code did neither. Now a
  `set_regrain(parent, null)` that actually turns auto-regrain off, with a regrain in flight, abandons that
  run through `regrain_cancel` (capture and the `TRUNCATE` guard off, delta cleared, copies dropped, cursor
  null, one `regrain_cancel` row); the source still holds every row, so only the copy work is lost. A call
  that finds auto-regrain already off changes nothing, so it never cancels an operator-driven regrain. The
  reference, the runbook's "Disk is filling during a regrain" and the guide now say so.
  `tests/129_set_regrain_off_midflight_test.sql` witnesses the run in flight (capture, cursor, a captured
  update, the refused `TRUNCATE`) before the call and asserts by identity what is left after it and after
  three more ticks; `bench/set_regrain_off_midflight.sh` drives the same file for `./test.sh discriminate`,
  where the `set_regrain_off_keeps_regrain` mutation puts the defect back.

- **A burst of rows minted within one second (or millisecond) no longer stalls the archiving of its
  partition, silently and for good** (#513). `pgpm._next_archive_chunk` ends a chunk at the next distinct
  control value, decoded to the native grid. For `text_time` and `uuidv7` that decode truncates to the
  encoding's unit (a second for ObjectId and KSUID, a millisecond for uuidv7, ULID and cuid), so when one
  unit held at least a chunk's worth of rows (a bulk import) the next distinct value decoded to the chunk's
  own `lo`: the picker returned no chunk, `_archive_step` moved on without a log row, and every later tick
  stopped at the same place. The partition was never covered, `retire()` never dropped it, and `status()`
  showed nothing. The picker now extends such a chunk past the unit, to the first row minted after it (or
  the child's `hi`), so the tied rows travel as one oversized chunk, which is what the contract always said
  a run of ties does. `tests/125_archive_chunk_ties_test.sql` walks the issue's fixture (100 ObjectId ids
  in one second, a budget for about 35) through write-block, archive and retire and asserts the ledger's
  exact three chunks; `bench/archive_chunk_ties.sh` runs that file in the perf track, and
  `./test.sh discriminate` requires it to fail against `archive_chunk_native_ties`, the mutation that
  removes the extension. The uuidv7 millisecond takes the same step but is not exercised until #507
  (`max(uuid)` in the same picker) lands.

- **Day and week partitions are named by the UTC date they start on, in every `partition_tz`** (#503).
  A day-denominated step is an absolute 86400 s lattice from the anchor instant, but `_part_name`
  rendered its label as the wall date of the cell's start in `partition_tz`. In a zone with daylight
  saving that lattice drifts an hour against local midnight twice a year, so two adjacent cells could
  start on the same wall date: with the anchor at a summer midnight, the New York cells starting 00:00
  EDT and 23:00 EST of the fall-back Sunday; with the default anchor, the 00:00Z cells of the fall-back
  Sunday and the Monday in `Atlantic/Azores`. And `set_partition_tz`, documented as safe on a day step
  because "only the names move", moved every label onto the previous cell's after a change to a zone
  west of the old one. `obtain` and `extend_to` skip a candidate whose name already exists, so the
  second cell of any such pair was never built: a permanent one-day hole that refused every write once
  the frontier reached it, with nothing logged and a healthy `status()`. Fixed-second cells (day, week,
  hour, minute) are now all labelled by the UTC reading of their start, the rule hour and minute labels
  already followed; month and year cells keep their wall-month label in `partition_tz`. A day grid's
  zone is therefore a pure setting: its bounds and names are both absolute. Names of existing day
  partitions are not changed (the name is a label; `pgpm.part` holds the bounds). `tests/125` pins the
  rule, `bench/day_label_utc.sh` runs it against `part_name_day_label_in_zone`, and `tests/111`'s three
  day-label expectations follow the new rule.
- **Archive coverage follows the partition, not a stale name** (#511). `pgpm.archive_ledger` is keyed
  `(parent_table, lo)` and matches chunks to their partition by `child_name`, and two things changed
  what a name meant without touching it. `regrain`'s swap dropped a partly archived source (allowed since
  #278) and deleted its `pgpm.part` row but left its chunks recorded under its name, so the first fine
  child's first chunk, at the same `lo`, collided on `archive_ledger_pkey`: `_archive_step` raised out of
  every tick (`skip_archive`, `duplicate key`), and no partition of that parent was archived or retired
  again. The documented rename procedure (update `pgpm.part.child_name` "and nothing else") orphaned a
  partly archived partition's chunks the same way, so archiving restarted from `lo` under the new name
  and collided with the old name's row, every tick, for good. Both were wedges that never cleared.

  `_archive_step` now discards coverage recorded under a `child_name` that is no longer a tracked
  partition of the parent when it overlaps a range a tracked partition holds, logged once per name as
  `archive_coverage_reset`, and the live partition archives from its own `lo` (nothing guarded that
  coverage across the change, the same reasoning as #452; chunks of retired partitions overlap nothing
  and are left as the record of where their rows went). Where pgpm itself changes a name or replaces a
  partition it keeps the ledger consistent in the same transaction: the swap retires the source's chunks
  with its `pgpm.part` row, and the #266 transitional rename carries them to the new name (the old bare
  name is what the first fine child is then called, so a row left there would sit under a live name with
  only #452's no-block reset between it and adoption). The guide and runbook now document the rename as
  updating `pgpm.part.child_name` and `pgpm.archive_ledger.child_name` together, which keeps coverage
  attached and resumes archiving from the watermark instead of exporting the prefix twice; the old
  procedure no longer wedges, it re-exports. `tests/125_archive_ledger_identity_test.sql` pins all four
  paths by which ids were handed under which name; `bench/archive_ledger_identity.sh` runs it against the
  mutants `archive_ledger_no_orphan_sweep`, `regrain_swap_keeps_source_ledger` and
  `regrain_rename_orphans_ledger`, one per mechanism, and each must fail it.
- **A uuidv7 table can be regrained, archived and retired again: nothing reads its control column
  with `max()` or `min()` any more** (#507). PostgreSQL has no `max(uuid)` or `min(uuid)` aggregate
  before 18, and three reads of a uuidv7 table's newest or next control value used exactly those.
  `regrain_step`'s copy resumed from `max(<control>)` over the fine child, so every regrain of a
  uuidv7 monolith raised `42883 function max(uuid) does not exist` on its first copy batch:
  `regrain()` and `regrain_history()` died synchronously, and once `set_regrain` had armed
  auto-regrain every maintenance tick prepared the monolith, failed the copy and logged `skip_regrain`,
  forever, so a uuidv7 history could never be split. `_next_archive_chunk` sized a chunk with
  `max(<control>)` over the byte-budget window and extended it past ties with `min(<control>)`, so on a
  uuidv7 table with an `archive_fn` every tick's archive step raised the same way, was logged as
  `skip_archive`, wrote no ledger row, and `retain()` never dropped the aged partition. All three
  now read the value with `ORDER BY ... LIMIT 1`, the shape `_frontier_native` has used for uuid
  since #325. `tests/125_uuidv7_regrain_archive_test.sql` regrains a frozen uuidv7 monolith both
  synchronously and through `maintain` ticks, then archives and retires the aged month through a
  400-byte budget so the tie extension is reached, asserting the exact rows, partitions, ledger range
  and `retain_drop` involved; `bench/uuidv7_regrain_archive.sh` runs that file against the three
  mutations `regrain_copy_watermark_max_uuid`, `archive_chunk_boundary_max_uuid` and
  `archive_chunk_tie_min_uuid`, one per site, so `./test.sh discriminate` proves each site is
  exercised on its own.
- **`transmute` refuses up front a table it cannot convert and a name it cannot take, and a failed attempt
  can be retried or aborted from the session that owns it (#509).** Three conditions the cutover was
  always going to trip on were checked nowhere before it, so phases 1 and 2 first committed a validated,
  write-rejecting `pgpm_monolith_bound` and the `transmute_inflight` claim, and the failure surfaced as a
  raw error from inside the cutover, on a table the docs promised an up-front refusal would leave
  untouched. Re-running `transmute` on an already converted table (the documented remedy after any
  failure, and what a client that lost its connection after the cutover committed will do) added the
  bound to the live partitioned parent, where it propagated to the forward partitions and rejected every
  write past the original monolith's `hi`, i.e. every current write; with the frontier already past the
  monolith it instead succeeded and nested the whole table under a second parent, with two `pgpm.config`
  rows. A relation already holding the monolith's own coarse name `<table>_p<lo>_to_<hi>`, which neither
  orphan-guard regex matches, failed the cutover's `RENAME` with `42P07`, bound and claim left behind; a
  sequence, view or index holding a child-partition name was skipped by the guard's `relkind = 'r'`
  filter and then by `obtain` itself, so that conversion completed with no forward partition and nothing
  logged, and the first write past `hi` failed with `no partition of relation ... found for row`. And
  after a cutover failure (a `lock_timeout` in phase 3) the
  claim's owner was the operator's still-connected session, which the take-over predicate and
  `transmute_abort` both read as "another session", so the documented retry and the documented abort were
  refused until that session disconnected, which no document said. `transmute` now refuses, before
  anything is committed, a table with a `pgpm.config` row, one whose relkind is not a plain table, and a
  partition, inheritance child or inheritance parent; checks the monolith's own name once the claim has
  made the bound final; and runs the orphan guard over every relation kind, naming what it found (new
  helper `_relkind_noun`). A claim recorded by the calling session itself is that session's own earlier,
  failed attempt: `transmute` resumes it and `transmute_abort` clears it, while a different live session
  is still refused both ways and the reaper's plain liveness test is unchanged, so a `maintain_all` run by
  hand from the owning session still leaves the bound alone. `tests/125_transmute_preconditions_test.sql`
  pins all of it, driving the failing conversions through dblink so a late failure really commits and its
  damage is observable; `bench/transmute_preconditions.sh` runs that file against the three mutations
  `transmute_no_shape_precondition`, `transmute_names_unchecked` and
  `transmute_claim_refuses_own_session`. `tests/101`'s "another session" claim is now owned by a real
  second backend rather than the test's own, which the fix would otherwise have let through.

- **`untransmute` hands back the monolith with none of pgpm's own apparatus left on it** (#508). It
  captured and replayed the parent's row triggers, and `DETACH` strips their clones, but the triggers
  maintenance puts directly on the monolith child were never touched. A monolith retention had reached
  but not dropped, because archiving was deferred or because recorded coverage kept the block after the
  frontier regressed (#452), came back as an unmanaged table whose `pgpm_write_block` rejected every
  INSERT, UPDATE and DELETE with "past its retention boundary", with `pgpm.config` and `pgpm.part` gone so
  no tick could ever lift it. And with a regrain in flight, `pgpm_regrain_capture` rode the monolith into
  the restored table, so `untransmute`'s own `drop function` died on the dependency and the whole call
  rolled back, neither the documented refusal nor a reverse; a reverse that got past it would have
  orphaned the not-yet-attached fine copies, which the parent's `DROP` never reaches. Now, under the lock
  and after the gate, `untransmute` lifts the block through `_remove_write_block` and abandons an in-flight
  regrain through `regrain_cancel` (trigger and `TRUNCATE` guard off, copies dropped, delta cleared, cursor
  null, one `regrain_cancel` log row), then reverses as before; a regrain that has swapped still shuts the
  door. `tests/125_untransmute_residue_test.sql` builds all three states (deferred block, coverage-kept
  block, mid-regrain), witnesses each before the reverse and asserts by which rows and which triggers
  remain; `bench/untransmute_residue.sh` drives the same file for `./test.sh discriminate`, where the
  `untransmute_keeps_write_block` and `untransmute_keeps_regrain_capture` mutations each put one half of
  the defect back.
- **A name pgpm derives from the table's is never truncated; `transmute` and `set_regrain` refuse
  instead** (#510). `_part_name` cast `<rel>_p<label>` to `name`, which silently cuts it to 63 bytes, and
  its comment called that cosmetic because `pgpm.part` holds the bounds. But `obtain` decides whether a
  forward cell already exists by that name, so for a table name of about 55 characters or more every
  candidate rendered the same 63 bytes, the monolith took that name at `transmute`, every forward cell was
  skipped as existing, nothing was logged, and the first write past the monolith's `hi` failed with
  PostgreSQL's `no partition of relation ... found for row`; one byte longer and the cut monolith name
  equalled the cut staging name `<rel>_pgpm_new`, so the cutover's RENAME failed after two phases had
  committed. `_part_name` now refuses a name over 63 bytes with a `pg_partition_magician:` error naming
  it, its length and the bytes to shorten the table name by, which covers `obtain`, `extend_to`,
  `regrain_step` and `transmute`, where the monolith is named before anything is claimed or committed;
  `transmute` holds the staging name to the same rule, and `set_regrain` refuses a target step whose
  wider labels would not fit at call time rather than logging `skip_regrain` on every tick. The budget is
  under [Partition naming](docs/reference.md#partition-naming): on a monthly grid the table name can be up
  to 43 bytes when the data spans more than one month. `tests/124_part_name_length_refused_test.sql` pins
  the boundary from both sides (a 63-byte name renders, a 64-byte one refuses, and every refusal is paired
  with the same shape one byte shorter converting and building its forward grid); `bench/part_name_length.sh`
  runs it under `discriminate` against three mutations (`part_name_silent_truncation`,
  `transmute_staging_name_silent_truncation`, `set_regrain_no_name_check`).

  **Upgrading in place: a long-named table converted before this fix has no forward grid.** Its monolith
  carries a cut name and `obtain` skipped every cell. After the upgrade each tick's `obtain` refuses
  instead and `maintain` logs `skip_obtain` with the message, so the table is visible rather than silent,
  but nothing repairs it: `untransmute` (a clean reverse, since every row is still in the monolith), rename
  the table within the budget, and `transmute` again. `select parent_table, child_name from pgpm.part
  where attached and octet_length(child_name) = 63` lists the candidates; a cut name ends mid-label.
- **Auto-regrain selects only a child its target actually subdivides (#515).** `maintain`'s candidate
  was the oldest frozen child wider than one `partition_step`; `regrain_step` then required that the
  target step subdivide it, and the two agreed only while the target was no wider than the step at
  every point of the calendar, which `set_regrain`'s coarser-than-step refusal checks once, at
  `partition_anchor`. `'30 days'` on a monthly grid passed (narrower than the anchor's January), yet a
  30-day cell that starts in February is wider than the calendar month from there, so once the first
  coarse child had been split, that cell was the candidate on every tick, answered `nosubdiv`, and every
  coarse child behind it was never regrained: silent and permanent. The candidate query now requires
  both (coarse by the grid's step, and subdividable by the target, `regrain_step`'s own precondition),
  so a cell the target cannot split is skipped and the next coarse child is worked; such cells stay
  counted in `status().coarse_partitions`, and `progress().coarse_frozen` mirrors the same test so it
  reports what auto-regrain will actually work. The refusal itself is unchanged, and its comment now
  says what it does and does not compare. `tests/125` (a monthly ULID grid split into years, then
  auto-regrained toward 30 days: the second year is what the unfixed code never reached), guard
  `bench/regrain_candidate_subdivides.sh`, mutation `regrain_candidate_ignores_target`.
- **A schema whose name needs quoting no longer wedges archive, retire and regrain** (#512).
  `_is_write_blocked` and `_regrain_capture_active` selected the parent's `nspname` and cast the raw
  name back with `::regnamespace`, whose input parses its text as an SQL identifier: for a managed
  table in `"Sales"` the lookup raised `schema "sales" does not exist`, so every `maintain()` tick
  logged `skip_archive`, nothing was archived and the aged partition was never dropped, while an
  auto-regrain could not prepare (`skip_regrain`) and the janitor logged `skip_regrain_capture` per
  child; once a lower-case `sales` schema existed the cast instead answered silently for the twin's
  same-named child. Both functions now compare the child's `relnamespace` against the parent's
  namespace OID and never re-parse a name. `tests/124_quoted_schema_test.sql` drives the archive,
  regrain and twin cases with a lower-case control alongside each; `bench/quoted_schema.sh` runs it
  against an arbitrary install so `./test.sh discriminate` proves it fails against the
  `schema_name_regnamespace_cast` mutation.
- **`maintain` re-applies its 200 ms `lock_timeout` after the retain boundary too, so auto-regrain's
  swap gives up instead of blocking the parent** (#514). `set local` dies at `COMMIT`, and `maintain`
  put `lock_timeout` back after each of its boundaries except the one after `retain`, which is the one
  that precedes the auto-regrain block. `regrain_step` therefore ran under the session default (`0`,
  wait forever): with a writer holding one row in the source, the swap's `DETACH` kept its
  `ACCESS EXCLUSIVE` request on the parent queued for the writer's whole transaction, every read of the
  parent queued behind that request, and when the writer committed the tick swapped as if nothing had
  happened, where the reference promises a `skip_regrain` row after 200 ms and a retry next tick. The
  missing `set_config` is back. `bench/maintain_regrain_lock_timeout.sh` (perf track) holds a row in
  the source from a second session and runs one tick from a third: the tick must return while the
  writer still holds, log exactly `skip_regrain` with the lock-timeout message and nothing else, leave a
  third-session reader unblocked, and swap on a later tick once the writer is gone, with the held row
  read back from its fine child. Its mutation, `maintain_no_lock_timeout_after_retain`, removes the one
  line.
- **regrain's change capture is found by identity, re-minted per regrain, and writable by the parent's
  writers** (#496). The per-parent delta table and trigger function were found by NAME, derived from the
  parent's CURRENT relname, and kept once minted. An ordinary `ALTER TABLE ... RENAME` of the parent
  mid-regrain therefore left the source's trigger writing the delta it was given while the reconcile, the
  swap gate and the swap all derived a new name, found nothing, counted 0 pending and swapped: every
  change committed since the copy went with the source (an UPDATE reverted, a DELETE resurrected, an
  INSERT gone). A key column renamed between two regrains left the delta with the first regrain's
  columns while the trigger function inserted the current key's, so every write into the source raised
  for the life of the next regrain. And the delta was created by whoever ran the tick, with no grants,
  while the trigger runs as the writer, so every non-owner role with DML on the parent got
  `permission denied` on every write into the regraining child. The prepare tick now records the oids it
  minted in `config.regrain_delta_oid` and `config.regrain_capture_fn_oid`, and every reader resolves the
  relations from there (`_regrain_capture_names`; the parent-derived names, now `_regrain_capture_derive`,
  are what it mints under and the fallback when nothing is recorded); it drops and re-mints the delta on
  every prepare from the key as it is then, refusing a foreign relation on the name rather than truncating
  it; and it owns the delta like the parent and grants `INSERT` on it to every role holding `INSERT`,
  `UPDATE` or `DELETE` on the parent (`_regrain_capture_grant`), re-synced on every tick so a grant made
  mid-regrain is honoured from the next tick. Re-running `install.sql` backfills the two anchors for a
  regrain already in flight. Pinned by `tests/124`, run against its three mutations by the new
  `bench/regrain_capture_identity.sh` (`regrain_capture_by_name`, `regrain_delta_reused`,
  `regrain_delta_ungranted`); `bench/upgrade_in_place.sh` now upgrades with a regrain in flight and
  requires the anchors backfilled by identity (`upgrade_regrain_capture_backfill_noop`).
- **`pgpm.dropped_fk` records anchor a preserved incoming key by identity, from any session** (#498).
  The cutover recorded `pg_get_constraintdef()` as rendered in the transmuting session, which leaves the
  referenced table unqualified whenever that session's `search_path` can see it, and `restore_incoming_fks`
  replayed the text in pg_cron's session, so `REFERENCES orders(id)` resolved to whatever `orders` meant
  there: an unrelated `public.orders` (the key came back against the wrong table, logged
  `restore_incoming_fk`) or nothing (`fail_restore_incoming_fk` every tick). And `referencing_table` was
  the referencing table's oid as of the capture: for a self-referential key that is the very oid the
  cutover renames into the monolith child, and for any key it is the oid a later `transmute` of the
  referencing table renames the same way, so the restore re-added the key on that one partition and every
  row routed to a forward partition escaped it, while the log said restored. Now the definition is captured
  through `pgpm._fk_definition`, which pins `search_path` to `pg_catalog` so the referenced table is
  always schema-qualified (the hypertable module's capture uses it too); the cutover moves every record in
  which the converted table is the referencer onto its new parent, in the rename's own transaction, and
  `untransmute` moves them back onto the restored table; and re-running `install.sql` rewrites a record an
  earlier pgpm captured unqualified. Records an earlier pgpm anchored on a monolith partition are not
  rewritten: their key may physically live on that partition, and moving the record without the key would
  break `suspend_incoming_fks`. `tests/124_dropped_fk_identity_test.sql` (the issue's three reproductions
  plus both `untransmute` round trips), `bench/dropped_fk_identity.sh` (the same file against an arbitrary
  install, plus the upgrade rewrite), and three mutations in `bench/mutations/mutate.py`.
- **Native bounds are stored in ISO 8601 form whatever the writing session's `DateStyle`** (#500). Every
  native time value pgpm stores (`pgpm.part.lo`/`hi`, `pgpm.log.lo`/`hi`, `config.partition_anchor`,
  `transmute_inflight.lo`/`hi`, the archive ledger's bounds) is text, and it was rendered with a bare
  `timestamptz::text`, which follows the writing session's `DateStyle`. A `transmute` run from a session
  on `SQL, DMY` stored 1 October 2026 as `01/10/2026 00:00:00 UTC`; the pg_cron session, on the default
  `ISO, MDY`, read that back as 10 January, so the monolith's real upper bound (next month) sat below the
  retention horizon and `retain()` dropped the live write partition, rows written that day included.
  Every render now goes through `pgpm._ts_text`, which pins `DateStyle` to ISO for the duration of the
  call, so a stored bound reads as the same instant from any session; parses are unchanged and still
  honour the caller's session. Bounds a pre-fix install wrote from a non-ISO session keep their old form
  and read correctly only under the `DateStyle` that wrote them, exactly as before. Guarded by
  `tests/124_datestyle_independent_bounds_test.sql` (the issue's reproduction, with the stored text and
  the instant an `ISO, MDY` session reads it back as asserted by identity), which
  `bench/datestyle_bounds.sh` runs against its mutation (`datestyle_session_render`) under
  `./test.sh discriminate`.
- **`pgpm_archive`'s object key keeps the sign (and decimal point) of an `id` kind's lo** (#502). Both
  transports, `pgpm.archive_to_s3_ndjson` and `pgpm.archive_to_s3_parquet`, named the uploaded object
  after the digits of the chunk's lo, `regexp_replace(p_lo, '[^0-9]', '', 'g')`, so chunk lo `-10000`
  and chunk lo `10000` of one table shared one key: a single `maintain()` tick uploaded the second over
  the first, both ledger rows recorded the shared key as archived, and `retire()` would have dropped the
  `[-10000, 0)` partition with its rows gone from the store. On a `numeric` control the same projection
  folded `10.5` onto `105`. The stem now comes from `archive._object_stem(kind, lo)`, which keeps the
  `id` kind's numeric text whole (`<prefix><parent>_-10000.ndjson`) and leaves the digits-only shape of
  every time-based kind, and so every existing key, untouched; a non-negative integer lo produces the
  same key as before. `tests/archive/db/16_archive_object_key_identity_test.sql` drives both transports
  on the issue's fixture and reads each object back by identity; `bench/archive_object_key.sh` runs it
  in the archive track and under `discriminate` against the `archive_object_key_digits_only` mutation,
  which puts the digits-only stem back.
- **`pgpm.set_archive_fn` refuses a strategy that does not return `pgpm.archive_result`** (#517). The
  `regprocedure` cast resolves a name and an argument list and never looks at the return type, and nothing
  else did, so a strategy declared `returns text` was accepted, against the reference's promise that
  assignment validates the whole signature. `_run_archive_strategy` reads the strategy's result into a
  `pgpm.archive_result` variable positionally, so that strategy's one column became `covered_hi`; one that
  echoed `p_hi` passed the contract check as a perfect answer, wrote a ledger row with `rows_archived null`,
  and the next `retain()` dropped the partition with nothing archived. `set_archive_fn` now looks the
  function up in `pg_proc` and refuses one whose return type is not exactly `pgpm.archive_result` (any
  other type, or `setof`), or an oid that names no function, with an error naming the function, what it
  returns and the contract, and leaves `config.archive_fn` unchanged. `docs/reference.md` says what the
  cast checks and what the function checks. `tests/129_set_archive_fn_return_type_test.sql` pairs each
  refusal with the witness that the cast alone accepts the candidate and that the tick which follows
  archives through the well-typed twin; `bench/set_archive_fn_return_type.sh` drives it against the
  `set_archive_fn_no_return_type_check` mutation, which `./test.sh discriminate` requires it to fail.

- **The S3 archive transports read a chunk in the grid's zone** (#501).
  `archive._encode_upload_ndjson_single` and `archive._encode_upload_parquet`, the transports behind
  `pgpm.archive_to_s3_ndjson` and `pgpm.archive_to_s3_parquet`, rendered the chunk's `[lo, hi)` into
  column literals without `config.partition_tz`, so each literal carried the wall clock in UTC. A
  `timestamptz` column reads the same instant from any offset and was unaffected. A naive `timestamp`
  or `date` column drops the offset and compares the wall clock, so on a grid recorded in another
  zone (`America/New_York`, say) the strategy read the range five hours late: the object held the
  wrong hour's rows, `rows_archived` counted them, and `covered_hi = p_hi` still declared the chunk
  archived, so `retire()` could drop a partition whose own rows were never uploaded. Both transports
  now pass `partition_tz`, as every reader of a chunk in `pgpm_core` already did.
  `tests/archive/db/16_encode_partition_tz_test.sql` builds the issue's fixture (three rows in one
  New York hourly child, archived from a UTC session) and reads both objects back from MinIO by row
  identity; `bench/archive_encode_partition_tz.sh` drives it in the archive track and in
  `discriminate` against the `archive_encode_no_partition_tz` mutation, which removes the argument
  from all four sites.
- **A row trigger's enabled state survives `transmute` and `untransmute`** (#499). Both replayed the
  table's triggers from `pg_get_triggerdef`, which never emits `pg_trigger.tgenabled`, so every replayed
  trigger came back `ENABLE` (origin-only) whatever it had been: a trigger the operator had `DISABLE`d
  fired again on the very next write and silently rewrote what was stored, an `ENABLE ALWAYS` one stopped
  firing under `session_replication_role = replica` and an `ENABLE REPLICA` one started firing for
  ordinary sessions, with nothing refused or logged. Each site now captures the trigger's name and state
  alongside its definition and re-applies every non-default state after the verbatim replay: at the new
  parent, where `ENABLE`/`DISABLE TRIGGER` recurses to the clone on every partition and a clone minted
  for a later partition inherits it, and at the restored table. `tests/124_cutover_trigger_tgenabled_test.sql`
  carries one trigger per state through the cutover and the reversal and asserts by which rows carry
  which value; `bench/cutover_trigger_state.sh` drives the same file for `./test.sh discriminate`, where
  the `transmute_trigger_state_dropped` and `untransmute_trigger_state_dropped` mutations each put one
  site's defect back.

- **A regrain reconcile pass consumes from the delta exactly the captured rows it applied, never
  "everything at or below a watermark"** (#497). `_regrain_reconcile` read its batch watermark, its list
  of touched fine children, each child's delete and reinsert, and its final `delete from <delta> where
  pgpm_seq <= wm` as separate statements, each under its own READ COMMITTED snapshot. `pgpm_seq` is an
  identity value assigned when the capture trigger fires, inside the writer's transaction, so a writer
  that updated an already-copied row, held its transaction open across a tick, and committed while the
  tick was applying its batch had a capture below the watermark that the apply statements could not see
  and the final delete could: it was deleted unapplied, the fine child kept the pre-change row, and the
  swap attached it, silently reverting a committed UPDATE. The batch is now materialised once, as the
  `pgpm_seq` values of the eligible rows visible in a single snapshot, and every later statement in the
  tick, the final delete included, addresses the delta by that set; a capture the tick did not see stays
  in the delta for the next tick, which applies it. `tests/124_regrain_reconcile_snapshot_test.sql`
  reproduces the three-session interleaving by lock state and asserts by identity that the UPDATE
  survives the swap; `bench/regrain_reconcile_snapshot.sh` drives it against the
  `regrain_reconcile_delete_by_watermark` mutation, which `./test.sh discriminate` requires it to fail.

- **A `timestamp` or `date` control column's grid is the column's own wall clock, recorded as
  `partition_tz = 'UTC'`** (#504). pgpm read a naive value as wall time in the transmuting session's
  zone, computed the grid on the resulting instants and rendered every bound back in that zone with an
  offset the column then discarded. A calendar step round-trips that way, but the day and hour steps are
  an absolute lattice of seconds that does not sit on the column's clock in a zone with an offset: under
  `America/New_York` a `date` column with a day step got a monolith `CHECK` of `d < yesterday's date`
  (the 00:00Z boundary rendered as 20:00 the previous day), so phase 2's `VALIDATE` failed with a raw
  `23514` after phase 1 had committed and the `NOT VALID` `CHECK` rejected every row dated today; with an
  hourly step the two cells either side of the autumn fall-back rendered to the same naive wall time
  (05:00Z and 06:00Z are both 01:00 in New York), `CREATE TABLE` refused the second as an empty range
  and the grid could never extend past that hour; and `set_partition_tz` accepted a zone change for such
  a column, after which new bound literals were rendered in a different zone from the existing ones.
  Now a naive column's values are taken as what they are, wall readings: a day is `[D 00:00, D+1 00:00)`
  in the column's values, an hour `[H:00, H+1:00)`, a month `[1st 00:00, next 1st 00:00)`, and every
  literal is that reading. That is the UTC lattice, so `transmute` records `UTC` for such a column
  whatever the session's zone (as it does for an `id` grid) and `set_partition_tz` refuses to move it.
  The write frontier for such a column is `now()` on that same clock, so an application writing local
  wall time from a zone east of UTC runs ahead of it by its offset, which the forward slack covers on a
  day or coarser grid and needs `obtain` above the offset in hours on an hourly one. A naive-column
  table transmuted from a non-UTC session on an unreleased build keeps its recorded zone (its grid is on
  that lattice). `tests/126` pins the rule, `bench/naive_column_utc_grid.sh` runs it against
  `naive_column_grid_in_session_zone`, and `tests/111` (d) follows it.
  A grid converted before this change keeps the zone it was recorded in, and pgpm keeps reading it there;
  `tests/archive/db/16_encode_partition_tz_test.sql` (#501's guard) now builds that legacy state by hand,
  since it is the state on which the transports' zone argument is observable.

- **A month step is one lattice where midnight on the 1st falls in a daylight-saving gap** (#505). Where
  a zone's clocks jumped forward at midnight on the 1st (`America/Asuncion` on 2023-10-01, `Asia/Amman`
  on 2016-04-01), `_grid_floor` correctly resolved the boundary to the first instant of the month, which
  reads 01:00 on the wall clock, but `_grid_next` added the month to that reading as it stood and landed
  an hour past the next boundary: `next(floor(Oct))` was 01:00 on November 1 while `floor(Nov)` was
  00:00. `regrain_step` walks its sub-ranges with exactly that pair, so the October child ended an hour
  after the November child began, the swap's `ATTACH` failed with "would overlap", and under
  auto-regrain that was `skip_regrain` on every tick, forever. `_grid_next` now steps a month boundary
  from its month's wall midnight, so the two functions describe one lattice; an off-grid value (the
  anchor `set_regrain` compares two widths from) still steps by a plain calendar month. `tests/127` pins
  the pair regrain computes on both gaps and on a twelve-step chain, under two session zones;
  `bench/month_step_dst_gap.sh` runs it against `grid_next_month_unsnapped`, and the existing
  `grid_session_timezone` mutation is re-anchored on the rewritten line.

- **A resumed `transmute` keeps the zone its bound was computed in** (#506). Phase 1 computes the
  monolith's bound in the transmuting session's zone and records it in `pgpm.transmute_inflight` so a
  re-run after a failure between the phases resumes on it, but the claim did not record the zone. A
  resume from a session in another zone reused the bound and then registered `config.partition_tz`
  from its own session, so the monolith sat on one lattice and every later grid computation on another:
  `obtain`'s first candidates half-overlapped the monolith and were skipped, a hole one whole step wide
  was left right past its `hi` (writes there failed with "no partition of relation found for row"), and
  `set_partition_tz` refused to repair it. `pgpm.transmute_inflight` now carries `partition_tz`, the
  claim records it, a resume adopts it along with the bound, and the `transmute_resume` log row names
  the zone it reused. A claim recorded before the column existed carries null there and a resume keeps
  the session's zone, as before. `tests/128` resumes a New York claim from a UTC session and checks the
  monolith's bound is a boundary in the recorded zone and the first forward child starts exactly at it;
  `bench/transmute_resume_zone.sh` runs it against `transmute_resume_session_zone`.

- **PRs land through a merge queue, and the repository moved to `neptunestation-com`.** GitHub offers the queue only on organization-owned repositories, which is why the move; the explainer now lives at `neptunestation-com.github.io/pg_partition_magician` and the old Pages URL does not redirect (the old repository URL does). Every PR workflow (`test`, `lint`, `perf`, `archive`, `observe`,
  `locktrace`, `lockview`) now also runs on `merge_group`, so the queue tests `main` plus the queued
  PRs as one tree before merging, and `main` requires three stable summary checks (`Test Summary`,
  the new `Lint summary` and `Perf summary`) instead of eight job names. The perf workflow drops its
  path filter, because a required check that did not run blocks a PR from being queued; sharded, it
  is about as long as one pgTAP matrix job. Before this, `main`'s "branch must be up to date" rule
  made every merge a rebase plus a full CI run per PR, about 30 minutes each, serialised.

- **The perf CI job is sharded across runners.** One job that ran every bench guard and then every
  discriminating mutation took 27 minutes and was the critical path of every PR's CI (the pgTAP matrix
  takes 6). `./test.sh perf --shard=I/N` and `./test.sh discriminate --shard=I/N` (also
  `bench/discriminate.sh --shard=I/N`) run the I-th of N interleaved slices of the same lists, chosen by
  index, so every guard and every mutation runs in exactly one of `.github/workflows/perf.yml`'s seven
  matrix jobs and no guard's environment changes: each still gets its own runner, container and
  database. A slice that would select nothing fails instead of passing vacuously, and `--list` prints a
  slice without touching Docker, which is how the partition was checked. Without `--shard` both tracks
  still run everything, as `./test.sh ci` does.

- **The partition grid is computed in a recorded zone, never in the caller's session `TimeZone`** (#455).
  `_grid_floor`, `_grid_next`, `_part_name` and `transmute`'s bound computation evaluated `date_trunc`,
  `extract`, `+ interval` and `to_char` in whatever zone the calling session had. An operator transmuting
  under `America/New_York` therefore built children on the `00:00-04/-05` lattice while pg_cron, under
  the server's UTC, computed `obtain`'s candidates on the `00:00+00` lattice, found each half-overlapping
  an existing child, skipped it, and created the first one past the New York tail: a permanent hole about
  `p_obtain` steps out, with nothing logged and a healthy `status()`. Independently, `+ '1 day'` on a
  `timestamptz` is a calendar day in the session zone (23 or 25 hours across a DST transition) while
  `_grid_floor`'s fixed-seconds branch is an absolute 86400 s lattice, so any DST-observing session
  opened a 23-hour hole every autumn on daily and weekly grids.

  `transmute` now records the transmuting session's `TimeZone` in the new `pgpm.config.partition_tz`
  (`UTC` for `id` grids; the call refuses a session zone that is not a `pg_timezone_names` name), and
  every adapter call takes that zone as a parameter, so the same table gets the same bounds and names
  from any session. Day-denominated steps are an absolute number of seconds in `_grid_next` too, so the
  two functions share one lattice; the price is that in a DST zone a daily boundary drifts an hour against
  local midnight twice a year (UTC is unaffected). `timestamp` and `date` control columns are read as
  wall time in `partition_tz` everywhere, and every bound literal pgpm writes carries the wall time in
  that zone with its offset, so all three column types get the same bounds from any session. Hour and
  minute partition labels are rendered in UTC: a DST zone's wall clock repeats an hour every autumn, so
  two adjacent hourly cells would otherwise share a name and `obtain` would skip one.

  **Upgrading in place: check `partition_tz` if any table was transmuted from a non-UTC session.** The
  column backfills to `UTC`, because nothing in the catalog records which zone an existing grid was built
  in. If the operator's session was in another zone at `transmute` time, run
  `select pgpm.set_partition_tz('schema.table', 'That/Zone')` for that table. The new setter validates
  the name against `pg_timezone_names` and refuses unless the grid's newest bound is on that zone's
  lattice (a day-denominated grid is on the same lattice in every zone and always accepts). A refusal
  means maintenance has already extended the grid in UTC: keep `UTC`, and look for an existing hole by
  walking `pgpm.part` for the table ordered by `lo::timestamptz`, where any row whose `hi` differs from
  the next row's `lo` marks a range no partition covers and must be created by hand. Installs that only
  ever transmuted from UTC sessions need no action.
- **A Parquet file is now written from one snapshot (#462).** `archive._pq_to_parquet` and
  `archive._pq_to_parquet_range` used to run `count(*)` and then one query per column straight
  against the relation. A VOLATILE plpgsql function under READ COMMITTED takes a fresh snapshot per
  statement, so a row that committed between two column reads was in the later columns and not the
  earlier ones, and from that column on every value sat one row away from the row it belonged to.
  The file was well-formed (every column had exactly `count(*)` values), so no reader could tell;
  the bug hunt read 8000 of 8000 rows with a `tag` belonging to a different row's `id`. Both
  encoders now materialise the rows once, in their final order, with the new
  `archive._pq_snapshot` (one statement, one snapshot, into a session temp table dropped as soon
  as the last column is read), and read every column from that. Bytes are unchanged for an
  unchanged table: the ordering key is the same, verified byte-for-byte across both entry points,
  compressed and not. The automatic path's `rows_archived` comes from that same snapshot too, via
  the new `archive._pq_to_parquet_range_counted(...) -> (p_file, p_num_rows)`; the bytea
  `archive._pq_to_parquet_range` is now a one-line wrapper over it, so existing callers are
  unaffected. The comment on `archive.to_s3_parquet` that claimed a single snapshot now describes
  one, and says plainly that the manual path has no write fence: a row that commits after the
  snapshot is not in the file, so quiesce the partition first or use the automatic path.

  If you archived Parquet on the **manual** path (`archive.to_s3_parquet`) while the partition was
  still being written to, files written before this fix may be misaligned across columns in exactly
  this way, and nothing in the file says so. Re-encode from the source if you still have it, or
  check a sample of rows against a column you can cross-reference. The automatic path write-blocks a
  partition before archiving it, so its files were exposed only to a writer that bypassed the
  fence (`session_replication_role = replica`). New: `tests/archive/db/15`, the two-session race,
  and `bench/archive_parquet_snapshot.sh`, which reads the racy files back with pyarrow and is
  required to fail against the `parquet_per_column_statements` mutation.
- **`text_time` refuses a digit alphabet the control column's collation does not order** (#456). A RANGE
  partition on a `text` column compares under the column's collation, while the bounds `text_time`
  computes are ordered by base-N place value, which is bytewise. Under `en_US`, the default collation of
  most databases, case is a tertiary weight, so `a` sorts before `P` where base62 puts `a` = 36 above
  `P` = 25: random-payload KSUIDs do not sort in timestamp order (13% of 2,085 sorted outside their own
  month), the guide's exact KSUID recipe failed at VALIDATE with `check constraint "pgpm_monolith_bound"
  ... is violated by some row`, and a small table that happened to pass routed rows to the wrong month,
  where retention would drop them early. `transmute` (before anything is touched, and not overridable by
  `p_force_text_time`, which covers a sampling heuristic, not arithmetic) and `check_text_time` (as a
  refusal, not a plausible fraction) now compare the alphabet's adjacent digits under the column's
  collation at the declared width and refuse, naming the collation (the effective database locale when
  the column is on `"default"`), the first misordered digit pair and the remedy,
  `alter table ... alter column ... type text collate "C"`. The comparison is of width-long strings, not
  single characters: a multi-level collation can order two characters at the case level and let a later
  position override it (`'a' < 'A'` yet `'aZ' > 'Ab'` under `en_US`), and the string form fails exactly
  when two digits are not separated at the primary level. cuid, ULID-as-text and ObjectId are
  single-case and unaffected, verified rather than assumed by `tests/122`'s random-payload ULID on an
  `en_US` column. `tests/91`'s KSUID fixture moves to a `collate "C"` column, which the guide's recipe now
  says it must be; its payload-zero values are the month bounds themselves, so it could never have
  caught this. New internal `pgpm._check_text_time_collation`.
- **`_detach_reap` no longer finalizes a live concurrent detach** (#453). It finalized every partition
  flagged pending detach under a managed parent, with no check that the session running the detach was
  gone. A concurrent detach spends its whole wait phase in exactly that state, for as long as the longest
  transaction holding a lock on the parent, and `maintain_all` shares a cadence with the `pgpm_detach`
  job, so the reaper routinely finalized a detach that was alive and waiting: PostgreSQL's
  wait-for-old-snapshots phase was skipped, and the real detacher then failed with `is not a partition`,
  once per tick, into `cron.job_run_details`. The reaper now skips a pending partition while any other
  session is still running its detach. The test is shaped by a measured fact: a detacher parked in its
  wait phase holds **no** relation lock at all (its first transaction commits before it waits), so "does
  anyone hold a lock on the partition" cannot see the phase the bug lives in. Three signals, any one of
  which means live: a lock held or awaited on the partition itself (the finalizing transaction), an
  active `DETACH PARTITION ... CONCURRENTLY` statement naming the partition (every phase, but visible
  same-role only), and a backend parked on the vxid of a transaction that has the parent locked (the wait
  phase, `pg_locks` only, so it covers a hand-run detach under a role whose statement the reaper cannot
  read). A skipped partition is not logged: a detach in progress is the expected state, not a deferral.
  The residual failure is deferring a reap by one tick, never finalizing a live detach. `tests/116` pins
  four cases with the detacher's liveness witnessed before every reap: live and same-role, live in the
  wait phase and live in the finalizing phase with the reaper run as a role for which the detacher's
  statement is masked (each isolating one signal), and abandoned with the holder's transaction still open
  on the parent, which is what tells the signals from a "someone has the parent locked" shortcut.
- **Fixed: Parquet shifted `timestamp` (without time zone) columns by the session zone** (#465). The
  writer cast a naive timestamp through `::timestamptz`, which reads the wall clock in the SESSION
  zone, so the same partition archived by pg_cron (the cluster's default zone) and by
  `call pgpm.maintain()` from a differently-zoned psql carried different instants, while NDJSON's
  `row_to_json` preserved the wall clock either way. A `timestamp` column is now written as its wall
  clock read as UTC and annotated `TIMESTAMP(isAdjustedToUTC=false, MICROS)` beside the legacy
  `TIMESTAMP_MICROS` (the pair pyarrow writes for a naive timestamp), so the bytes no longer depend on
  the session, and pyarrow and DuckDB return the wall clock as a naive timestamp, the same value NDJSON
  carries. `timestamptz` is unchanged. **Parquet files written before this fix from a `timestamp`
  column under a non-UTC session carry instants shifted by that session's UTC offset at each row's
  date** (under `America/New_York`, January rows read five hours late and July rows four); files
  written under UTC hold the right values and only lack the annotation, so readers label their wall
  clock UTC.
- **`transmute` refuses a `uuidv7`/`text_time` maximum far ahead of the clock (#457).** For these kinds
  the frontier is `greatest(max(control), now())` and had no upper sanity bound, so one row minted by a
  client with a wrong clock set the frontier, and with it the monolith's permanent `hi`, years into the
  future: every row written today landed in the monolith, `check_uuidv7` passed at 0.9975, `status()`
  showed nothing abnormal, and the monolith could not be regrained nor anything behind it dropped until
  the clock really got there. `transmute` now refuses, before anything is committed, a newest value that
  decodes to more than **one partition step plus one hour** past `now()`, naming the offending value, its
  decoded timestamp, the `hi` it would have imposed and the one the clock alone gives. The allowance is
  measured from `now()`, not from a `p_bound_headroom`-widened bound; one step because the cost of a
  maximum inside it is bounded to what `p_bound_headroom => 1` would have cost, one hour so a fine grid
  still tolerates ordinary clock skew. The check runs after the UUIDv7 ceiling refusal, so a forced random
  column keeps getting the message that names its real cause. New trailing parameter
  **`p_force_frontier boolean default false`** on `_transmute` and the interval-width `transmute` accepts
  the far `hi` knowingly (with a `NOTICE` restating the cost); the previous shapes of both are dropped on
  upgrade so a 3-argument call cannot become ambiguous. `check_uuidv7` and `check_text_time` gain
  **`newest_decoded`** (the column's actual maximum, decoded, not the sample's) and **`newest_in_future`**
  (more than one hour past `now()`), so the row is visible before converting; both are drop-and-recreate,
  so re-running `install.sql` picks them up. `tests/123`.
- **regrain's aged skip is re-checked at the swap, and never fires on a half-copied sub-range** (#448).
  As the cursor passed a sub-range entirely below the retention horizon, `regrain_step` skipped it
  (`regrain_aged`) and that decision lived on only as the advanced cursor. Two consequences.
  `set_retain(parent, null)`, or a longer value, before the swap made the policy say keep while the rows
  were still visible through the attached source, and the swap's `DROP` took them (39,999 rows in the
  hunt that found this). And a sub-range partially copied in one tick whose range aged before the next
  was skipped anyway, so the swap attached its partial child and the parent served a fraction of the
  range as the whole of it.

  Now the swap walks every sub-range of the source on the target grid, before it locks anything, and
  **refuses**, naming the range, when one that has no fine child to attach is no longer below the
  current horizon: the source stays attached, the cursor stays at `hi`, and the run resumes once
  `retain` is set back (or `regrain_cancel` it and re-run under the new policy; through `maintain` the
  refusal is a `skip_regrain` row carrying the message). The skip itself no longer fires on a sub-range
  that already has a fine child: its copy is finished instead, which is what lets the swap treat "a
  child exists" as "its copy is complete". `set_retain` **warns**, rather than refuses, when it loosens
  retention under an in-flight regrain, since the change is safe and only the swap's timing is affected.
  New internal `pgpm._regrain_has_child(parent, lo, hi)`, the one notion of "this sub-range has a fine
  child" both sites share, answered from `pgpm.part` because that is what the swap attaches from.
  Guarded by `tests/121`: four sub-ranges skipped as aged, `set_retain(null)`, the swap refuses and every
  sampled aged row is still served by identity; a longer value, and the refusal names the first range no
  longer below the horizon; the original value, and the very next tick swaps. Then a batch smaller than
  a sub-range, one tick copying 100 of 249 rows, the frontier moving the horizon past it, and the
  following ticks finishing the copy, so that after the swap no attached partition holds a strict subset
  of its source range.
- **Fix: `regrain_step`'s reconcile no longer discards captured changes in a clamped first sub-range**
  (#446). When a coarse child's `lo` is off the target grid (a weekly `regrain_to` on a monthly monolith,
  which `set_regrain` accepts; a `7000` target on a child starting at `20000`), `regrain_step` clamps the
  first sub-range to that `lo` and names the fine child from it, but the reconcile re-derived the sub-range
  from the grid floor with no clamp, looked for a child that never existed, took its absence for "skipped
  as aged", logged `regrain_reconcile_aged` and deleted the captured keys. The swap then dropped the source
  with them: every UPDATE in that sub-range reverted, every DELETE came back, every INSERT vanished. The
  reconcile now locates the fine child by range containment in `pgpm.part` (the name is a label; the
  recorded bounds are authoritative), and a sub-range with no fine child is treated as aged only when it
  is below the retention horizon, the same test `regrain_step` applied when it skipped it. Otherwise the
  tick raises and the delta keeps the keys, which `maintain` surfaces as `skip_regrain`. The
  `regrain_reconcile_aged` row now carries the sub-range's `lo` and `hi` in place of a rendered name.
  Pinned by `tests/120`: the issue's fixture with one UPDATE, one DELETE and one INSERT inside the clamped
  sub-range, asserted by identity in the fine child before the swap and through the parent after it, with
  the aged path kept, the not-aged raise, and the monthly-to-weekly name disagreement on the time grid.
- **A write block is no longer lifted from a partition `pgpm.archive_ledger` covers** (#452). Coverage is
  a watermark, and it describes the partition's contents only while the write block has been on it since
  the first chunk. Eligibility regresses, though: an `id` table's frontier is `max(control)`, so deleting
  the newest rows moved the horizon back, and `set_retain` loosening moved it back for every kind. The
  tick lifted the block, a late write landed in a range the ledger already called done, the block came
  back, archiving resumed from the watermark, and `retire` dropped the partition with a row in it that no
  strategy had ever been handed. Now the block stays while coverage exists: the partition keeps being
  archived to completion and is dropped only if retention reaches it again. The first tick that keeps a
  block it would otherwise have lifted logs `skip_write_block_lift` for that partition, once; to make it
  writable again, delete its `pgpm.archive_ledger` rows and the next tick lifts the block (archiving
  starts over from `lo` if it is ever blocked again). Coverage a tick finds on a partition with **no**
  block (a trigger removed by hand, or lifted by a pgpm older than this rule before an upgrade) is
  discarded and logged as `archive_coverage_reset` with the chunk count, so an in-place upgrade heals such
  a partition on its first tick instead of trusting a watermark nothing has been guarding. `tests/114`
  pins all three by identity (the `id` frontier regression, `set_retain` loosening followed by the
  documented way out, and the unblocked-coverage backstop), each ending in a drop whose contents equal
  exactly what the strategy was handed.
- **`TRUNCATE` is refused while a regrain is in flight** (#449). Change capture is a row trigger, and
  `TRUNCATE` fires none, so a truncate of the coarse child mid-regrain left the delta empty, and a
  truncate of the parent never reached the standalone copies; the swap then attached copies of every
  row the operator had just removed (9,999 rows resurrected in the hunt that found it). The prepare
  tick now puts a `BEFORE TRUNCATE` statement trigger (`pgpm_regrain_truncate_guard`) on the source
  beside the row trigger, and it raises `pg_partition_magician: cannot TRUNCATE ... a regrain is in
  flight on it` for either spelling (`TRUNCATE parent` cascades to the source as a partition and fires
  the partition's own trigger), before anything is truncated. Refuse rather than capture, matching the
  write ceiling: loud refusal over silent divergence. The guard is `ENABLE ALWAYS`, so
  `session_replication_role = replica` cannot skip it, and it goes wherever the row trigger goes: with
  the dropped source at the swap, in `regrain_cancel`, and in `maintain`'s sweep of an abandoned
  regrain. Pinned by `tests/119`, which also proves the replica-mode case discriminates.
- **Fixed: upgrading from 0.4.0 or older left two ambiguous overloads behind** (#441). `create or
  replace` across a changed argument list does not replace the old function; it adds a second overload
  beside it, and four signature changes were missing their `drop function if exists` lines:
  `restore_incoming_fks(regclass)` and `schedule(text)` (the shapes 0.2.0 through 0.4.0 shipped) and the
  two-argument `_encode`/`_decode` (0.1.0 and 0.2.0). **An install upgraded from 0.4.0 or older to
  0.5.0 or 0.6.0 has the first two today**, and the upgrade reported success: `select pgpm.schedule()`
  fails with `function pgpm.schedule() is not unique`, and every `maintain` tick logs a
  `skip_restore_fk` row with `method = 'function pgpm.restore_incoming_fks(regclass) is not unique'`,
  so a preserve-managed incoming FK is never restored and `p_status` carries `restore_fk_deferred` for
  good. **Re-running `install.sql` with this fix removes the stale overloads**: the fix is itself the
  remedy for an install already upgraded, and the next tick restores the FK. Verified from every tag
  0.2.0 through 0.5.0: the routine catalog after the upgrade is identical to a fresh install's. (0.1.0,
  the pre-transmute `adopt` release, additionally leaves its seven `adopt`-era routines behind; those
  are removed names rather than overloads, nothing calls them, and they are out of scope here.) New
  guard `bench/upgrade_from_release.sh` upgrades a real released artifact, v0.2.0's `install.sql`
  fetched from the tag, and requires routine identity with a fresh install, `schedule()` resolving, and
  one tick restoring the FK; `bench/upgrade_in_place.sh` now compares routines by name as well.
  Mutation: `upgrade_stale_overloads_kept`.
- **The archive step now holds `archive_fn` to its contract (#454).** The `covered_hi` a strategy
  returned was written into `pgpm.archive_ledger` verbatim, and that ledger is `retire()`'s drop
  precondition, so a strategy bug that answered chunk `[0, 15)` with `covered_hi = 15000` marked the
  partition fully covered on the spot and the next `retain()` dropped it with nothing archived.
  `_archive_step` now checks the returned `covered_hi` against the chunk it handed over: it must be a
  native grid value with `p_lo < covered_hi <= p_hi`. On a breach (null, at or below `p_lo`, past
  `p_hi`, or not a native value) no ledger row is written; the step logs the new `fail_archive_contract`
  action, with the strategy, the chunk, the value returned and the rule it broke in `method`, skips that
  partition for the tick, and `status().retain_drop_failures` counts it alongside the other `fail_*`
  actions that stall retention.

  The strict lower bound closes a second defect for free: a strategy returning `covered_hi = p_lo` ("no
  progress") used to write a `(lo, lo)` ledger row, after which every tick resumed from `max(hi) = lo`,
  handed the strategy the same chunk, and collided on the ledger's primary key, a permanent wedge that
  `maintain()` reported as a `skip_archive` deferral. Such a return is now refused before it reaches the
  ledger. A strategy that genuinely cannot make progress on a call should raise; that is logged as
  `skip_archive` and retried with the same chunk, which is the deferral path.

  `fail_archive_contract` is a prefixed non-success event per the naming rule, so alerts matching exact
  action values are unaffected. Unlike the identity refusals it is retryable by construction: nothing
  advanced, so a corrected strategy (`pgpm.set_archive_fn`) is handed the very same chunk next tick. The
  built-in `pgpm._archive_noop` and `pgpm_archive`'s two S3 strategies always return the chunk's own
  `p_hi` and are unaffected. One new internal, `pgpm._archive_contract_breach(kind, lo, hi, covered_hi)`,
  which returns the rule broken or null; internal, so no promise attaches to it. `tests/115` drives four
  misbehaving strategies (overshoot, `p_lo`, null, not a number) through the step and a `maintain()`
  tick, each paired with the strategy's own record of the chunk it was handed, and then a well-behaved
  one on the same chunk as the control.
- **Fixed: a primary key that excludes the control column is refused whatever other unique constraints
  the table has** (#445). `transmute` on `events(id PRIMARY KEY, created_at, UNIQUE (tenant, created_at))`
  by `created_at` used to fall through to the unique-constraint reuse: the parent adopted the UNIQUE,
  `events_pkey` stayed on the monolith, and every forward partition accepted duplicate `id`s with no
  error, notice or log row. The docs said the shape was refused; it was refused only when there was
  nothing else to adopt. It is now refused up front, before any COMMIT, with a message naming the primary
  key constraint and the control column and prescribing the widening (`CREATE UNIQUE INDEX CONCURRENTLY`,
  then `DROP CONSTRAINT ..., ADD PRIMARY KEY USING INDEX ...`); adding a unique constraint is no longer
  offered as a remedy, since it is exactly the shape being refused. Unchanged: a table with no primary
  key and a unique constraint that includes the control column still reuses that constraint, and a
  primary key that includes it is still reused in place. Pinned by `tests/113`.
- **`uninstall.sql` now removes regrain's change capture from your schema** (#442). The per-parent delta
  table, its trigger function and the `pgpm_regrain_capture` row trigger live in the parent's schema, not
  in `pgpm`, so `drop schema pgpm cascade` never reached them: after an uninstall during a regrain the
  trigger kept firing on every write to the former source child, appending to a delta table nothing would
  ever drain, and a parent that had ever regrained kept the table and function for good. The script now
  walks `pgpm.config` and drops all three for every managed parent before the schema goes, the way
  `untransmute` already did. Best-effort per parent: a parent dropped without `untransmute` is skipped, a
  parent whose capture objects the running role cannot drop is reported in a warning naming them, and a
  re-run with the schema already gone stays a no-op. The guide's uninstall paragraph now says exactly what
  goes and what stays: your partitioned tables, their partitions and every row, and nothing else pgpm
  made. The bound `CHECK` a completed `transmute` leaves is nothing, since the cutover drops it; the one
  it cannot undo, a conversion interrupted between phases, is called out with the `transmute_abort` call
  to run first. `./test.sh` stages a real regrain before every channel's uninstall check and asserts the
  trigger is present before, and no relation, function or trigger named for it after.
- **`from_hypertable_cutover` refuses to swap when the source and the destination disagree, and the
  append-only catch-up no longer loses a row that lands exactly at the watermark** (#460). Without
  `p_track_changes` the cutover caught up rows with control strictly greater than `max(control)` in the
  destination. A row arriving during the online window BELOW that watermark (out-of-order appends:
  multi-writer clock skew, batched device uploads, backfills, the normal IoT shape) was never copied, a row
  EXACTLY AT it was not copied either, and nothing under the lock compared the two sides, so the source was
  dropped short with no error and no log row. Three layers, cheapest first. On a keyed table the under-lock
  catch-up is now inclusive at the watermark with a key anti-join against the destination, bounded to the
  tail (an unbounded anti-join would be O(rows) under the lock) and materialised and ANALYZEd first so the
  plan probes the pre-built key index instead of seqscanning the destination (measured: even at 20k rows
  the direct form planned a Seq Scan of the destination); equality is never a loss and the copied row
  already there is not duplicated. A keyless table keeps the strict `>`: a duplicate row is legitimate
  there, so an all-columns anti-join would refuse to copy one. Under the lock, BEFORE the drop, `count(*)`
  over the frozen source is compared with the destination's count (its pre-lock baseline plus exactly what
  the catch-up changed, so the destination is not scanned again) and the swap is REFUSED on a mismatch with
  a message naming both counts, the difference and the fix; the raise precedes every irreversible step, so
  the source stays whole and still a hypertable. The reference now states the late-arrival caveat as loudly
  as the update/delete one and recommends `p_track_changes => true` whenever the table has a key; the
  default is unchanged, a behaviour change worth its own issue. Cost: one `count(*)` over the source joins
  the locked window, the one step in it that scales with the table. `tests/timescale/db/20` pins all three
  layers: the equal and 1 us-past rows survive by identity on a keyed table with no duplicate, and a row an
  hour behind the watermark makes the cutover refuse with `243` vs `242` (keyed) and `243` vs `241`
  (keyless), source intact. `bench/hypertable_late_appends.sh` proves both assertions discriminate against
  mutants that put the strict `>` and the missing check back.
- **A `p_incoming_fks => 'preserve'` conversion that fails after phase 1 no longer loses the incoming
  foreign keys (#444).** The cutover is where the referencing table's key is dropped now, in the same
  transaction that records it in `pgpm.dropped_fk`. It used to be dropped in the first of `transmute`'s
  three transactions, with the record written only in the third, so a stray row failing phase 2's
  `VALIDATE` (or a lock timeout in the cutover) left the key gone from the referencing table with no
  record anywhere: `transmute_abort` reported the table restored, the referencing table accepted orphans,
  and a clean re-run had nothing to restore. Now a failure in phase 1 or 2 leaves every incoming key
  exactly where it was, a failure in the cutover rolls the drop back with it, and referential integrity
  on the referencing table is off only between a completed cutover and `restore_incoming_fks`. Nothing
  in phases 1 or 2 ever needed the key gone; the drop was simply left behind when the conversion was
  split. Two things came free: the drop's wait for the referencing table's lock is now bounded by
  `p_lock_timeout` (it used to wait indefinitely, before anything was claimed), and the cutover drops
  what is live at that moment rather than a list captured at the start, so a key the operator dropped
  during the validation scan is not recorded as pgpm's to restore. `tests/112` pins the phase 2
  failure, the abort, the cutover failure under a lock on the referencing table, and the resume path.
- **`from_hypertable_copy` applies each chunk's bounds in the dimension's own type**, so a `timestamp`
  (without time zone) or `date` dimension migrates whole under any session `TimeZone` (#459). The chunks
  view renders every time dimension's `range_start`/`range_end` as `timestamptz`, and the copy spliced them
  as bare literals, which render in the session zone (`'2024-01-01 09:00:00+09'` under `Asia/Tokyo`) and,
  coerced to a `timestamp` column, lose the offset. Every chunk range shifted by the UTC offset. East of
  UTC the oldest chunk's first hours were copied by no chunk (540 of 2880 rows in the reproduction), and
  because the cutover's catch-up only reaches rows past `max(control)` in the destination, they were gone
  after the migration; west of UTC the last chunk's tail was missed by the copy and came back only through
  the catch-up; a `date` dimension lost its last day west of UTC. A `timestamptz` dimension was never
  affected. Bounds are now `::timestamptz`, `at time zone 'UTC'`, or the `::date` of that, per dimension
  type: exactly the value each chunk's own CHECK constraint names. A hypertable on any other dimension type
  is refused by the copy up front, before it creates anything, rather than bounded on a `NULL` (the view
  has no `range_start` for it, and the old predicate would have copied nothing into a destination the
  cutover would then have renamed into place). `tests/timescale/db/19` pins the `Asia/Tokyo` and
  `America/Los_Angeles` cases by row identity, with witnesses that the zone was in effect and that the view
  rendered the bounds with an offset.
- **`archive.to_s3_parquet` resolves its child in the parent's schema, and both manual archive functions
  check the child's identity** (#464). `to_s3_parquet` cast the bare child name to `regclass`, so it
  resolved through the caller's `search_path`: from a session whose `search_path` did not reach a managed
  table's schema, the real child was refused with `relation does not exist`, and once any same-named
  relation existed in `public`, that relation's rows went out under the partition's key with HTTP 200.
  `to_s3` had the schema right but, like `to_s3_parquet`, never compared what the name resolved to
  against `pgpm.part.child_oid`. Both now resolve `%I.%I` off the parent's namespace and refuse, with a
  `pg_partition_magician:` error naming both oids, a relation that has taken a partition's name: the
  manual-path twin of the automatic path's `fail_archive_identity`. A child that does not exist in the
  parent's schema fails with a clear message rather than a bare `relation does not exist`; a null
  `child_oid` is unanchored and skips the comparison, as everywhere else.
- **`from_hypertable` refuses an integer-time dimension, and a `p_control` that is not the dimension, up
  front** (#458). The chunk-by-chunk copy bounds each chunk on `range_start`/`range_end` from
  `timescaledb_information.chunks`, which are ranges of the dimension column and are populated only for a
  timestamp-typed dimension. Preflight checked only that `p_control` exists, so a `bigint` dimension copied
  `t >= NULL and t < NULL` (nothing) and the cutover dropped the hypertable before `transmute` refused the
  column, leaving an empty plain table and no hypertable; and a second time column that is not the
  dimension migrated to a partitioned table with zero rows and reported success. `from_hypertable_preflight`
  now requires `p_control` to be the primary dimension (naming the actual dimension when it is not) and the
  dimension to be `timestamptz`, `timestamp` or `date`, and `from_hypertable_cutover` runs the same two
  checks in its own right, since a destination left by a copy under an older version reaches the
  irreversible drop without preflight ever having run. `tests/timescale/db/18` pins both refusals through
  every entry point, with the hypertable intact by identity afterwards, and passes `timestamp` and `date`
  dimensions as positive controls. The retention translation's `(config->>'drop_after')::interval`, which
  would have read an integer policy's `1000` as seconds, is unreachable now that integer dimensions are
  refused before it, and is left as is.
- **`transmute` and `set_retain` refuse a negative retain** (#451). Neither `transmute` overload
  checked the sign of `p_retain`, so `p_retain => interval '-1 day'` (or `-1000` on an `id` grid)
  registered a retention horizon in the future, and the first maintenance tick write-blocked and dropped
  every partition, the one taking writes included; the next insert failed with `no partition of
  relation ... found for row`. Both overloads now raise before anything is committed, and `set_retain`
  refuses a negative value unconditionally: before, only its would-drop guard stood in the way, and that
  guard compares boundaries, so a value that grid-floored to the current boundary (retain 0 to -400 at a
  frontier of 2501, step 1000) went through and armed a later tick. Zero is unchanged and legitimate: its
  horizon is the write partition's own floor, so it keeps that partition and ages everything behind it.
  As defence in depth for a `config.retain` edited by hand, `_retain_boundary` and `regrain_step` refuse
  to compute a horizon from a negative value: a tick against such a row logs `skip_write_block` and
  `skip_retain` (and `skip_regrain`, when auto-regrain reaches it) carrying the message and drops
  nothing, `status()` stays up with `retain_backlog` null for that table, and `set_retain` can still
  repair it. A positive retain shorter than one `partition_step` is unaffected. New internal
  `pgpm._retain_nonnegative(kind, retain)`; internal, so no promise attaches to it.
- **`untransmute` decides its one-way door under the lock that acts on it (#443).** It refuses when any
  row lives outside the original monolith, and that refusal was decided once, under `ACCESS SHARE`, by a
  check that cannot see another session's uncommitted insert; the detach and drop that acted on the
  answer took their `ACCESS EXCLUSIVE` later. A writer whose insert into a forward partition was
  uncommitted at the check and committed before that lock was granted had its row dropped with the
  parent, and `pgpm.log` recorded the `untransmute` as a success. The check now runs again under an
  explicit `lock table ... in access exclusive mode`, taken one statement before the detach would have
  taken the same lock, so the exclusive window opens where it always did and grows by one probe of
  partitions that are empty whenever it passes; the unlocked check stays as the cheap refusal that blocks
  no writer when the door is already shut. The wait is bounded by the caller's `lock_timeout` and a
  refusal rolls the whole call back. Because the second answer is only worth something if its snapshot
  postdates the lock, `untransmute` now also refuses to run under `REPEATABLE READ` or `SERIALIZABLE`,
  whose snapshot predates the call. Guarded by `bench/untransmute_race.sh` (a writer parked on an
  uncommitted forward-partition insert, `untransmute` witnessed waiting on `AccessExclusiveLock` while
  that xid is still open, then released) with the mutation `untransmute_no_recheck_under_lock`, and by
  `tests/109`, which runs the same race through `dblink` in the version matrix.
- **regrain's swap now reconciles every captured change before it drops the source (#447).** After
  the `DETACH`, the swap drained the change-capture delta for at most 100 passes of
  `greatest(batch, 1000)` keys and then attached, dropped and truncated unconditionally; nothing checked
  that the loop had stopped because the delta was empty. The pre-swap gate bounds only what had committed
  before it ran: a writer already holding a row in the source keeps the `DETACH` waiting, and everything
  it commits during that wait lands in the delta after the gate. Under `maintain` the `DETACH`'s 200 ms
  `lock_timeout` keeps that window small; a hand-driven `regrain_step` has none, and a history purge
  committing during the wait was exactly the shape that overflowed. Reproduced: 150,051 committed rows,
  49,851 of them gone after a clean `swapped:30`, no error anywhere.

  The loop now runs until the reconcile finds nothing (the `DETACH`'s lock is what makes that finite),
  and before the `DROP` the swap asserts that no captured change in `[lo, hi)` remains, raising a
  `pg_partition_magician: internal error` otherwise so the whole swap rolls back with the source still
  attached; under `maintain` that surfaces as a `skip_regrain` row and the next tick reconciles the
  backlog before swapping. New internal `pgpm._regrain_delta_count(parent, lo, hi)`, the range-scoped
  count that check uses (range-scoped because a cross-partition `UPDATE`'s new key can sit outside the
  child being split). Guarded by `tests/107`, a two-session probe in which a writer commits 120,002
  captured changes after seeing the swap's ungranted `ACCESS EXCLUSIVE`, and by
  `bench/regrain_swap_reconcile.sh`, which drives that file against two mutants: the pre-fix bound put
  back (the file fails on identity, after a swap that reported success) and the bound with the new
  check left in (the file fails on the swap tick, which now raises), so the check is proven live rather
  than assumed.
- **`archive.to_s3` no longer drops rows that tie on the control column at a page boundary** (#463).
  The synchronous NDJSON export read the partition `fetch_rows` at a time and resumed each page from
  the previous page's `max(control)`. The control column need not be unique, so when a run of equal
  values straddled a page boundary the cursor landed on the tied value and the next page's `> cursor`
  skipped the rest of the run: 30 rows at one timestamp with a 10-row page came out as 10, with HTTP
  200 and no error, on the path the README offers for archiving before a manual drop. Paging is now
  by the total order `(control, ctid)`, so a page boundary can fall anywhere in a tie run and lose
  nothing. The export also counts what it pages against the partition's row count when it began and
  **refuses to write the object** on a mismatch (`pg_partition_magician: archive.to_s3 of ... paged N
  rows but the partition held M ...`), aborting an in-flight multipart upload, rather than reporting
  success; with the fix in place that check trips only when something wrote to the partition during
  the export, which is the operator's cue that the partition was not quiescent. Pinned by
  `tests/archive/db/12`, whose witness proves the first page ends inside the tie run and whose
  assertions name the previously lost rows by identity.
- **Parquet archives of a `numeric(p,s)` column with `p >= 17` encoded negative values, and positives
  of 19 or more digits, as different numbers, and every reader agreed on the wrong one (#461).**
  `archive._pq_plain_decimal` stepped its two's-complement byte loop with `trunc(v / 256)`, and
  PostgreSQL's numeric `/` rounds its quotient to about 16 significant digits, so once the running
  value had 17 or more integer digits the rounding carried into every higher byte. Every negative gets
  there at the 8-byte width `numeric(17,s)` is the first to need (its `2^(8n) + value` step has 20
  digits), so `numeric(19,4)`, the money shape, was squarely inside it: `-1.5` came back as `5.0536`,
  `-0.0001` as `0.0255` and the column maximum `999999999999999.9999` as `1000000000000000.0255`, from
  pyarrow and DuckDB alike. `numeric(16,s)` and narrower, 7 bytes or fewer, were never affected, which
  is why `scripts/verify_parquet.py`, whose widest DECIMAL fixture was 5 bytes, stayed green. The loop
  now steps with `div()`/`mod()`, exact at any magnitude, as `pgpm._radix_encode` already did for the
  same reason.

  **A Parquet file written before this fix from a `numeric(p >= 17)` column that held a negative
  value, or a positive of 19 or more digits, carries wrong values, and nothing in the file says so:**
  each wrong value is a valid encoding of some other number (`-0.0001` became the exact bytes of
  `+0.0255`), so no reader can flag it and the file cannot be repaired from itself. The repair is to
  re-archive the range from the source rows while they still exist; `pgpm.archive_ledger` lists which
  ranges went to which keys. A column of that shape that only ever held non-negative values under 19
  digits was encoded correctly and needs nothing, and NDJSON archives (`archive.to_s3`, which renders
  rows with `row_to_json`) were never affected. Pinned by `tests/archive/db/11`, which checks the
  encoder's bytes against a Python-derived two's-complement reference for five values at every width
  1..16 they fit (the width-8 row is required to be present, since widths 1..7 passed before the fix
  and pass again against it), and by three new `verify_parquet.py` fixtures (`numeric(19,4)`, `(17,2)`,
  `(38,10)`, with negatives and near-max values) read back exactly through both readers; all three
  fail against the previous encoder.
- **Both pgpm triggers now fire under `session_replication_role = replica`** (#450). The write block
  and the regrain change capture were created in PostgreSQL's default origin-only state, so a session
  running as `replica`, which is what a logical-replication apply worker runs as and what some bulk
  loaders set to silence triggers, wrote straight past both: a replica-role `INSERT` landed in a
  write-blocked partition, where archive coverage was already complete and the row would have been
  dropped unarchived, and replica-role DML during a regrain went uncaptured and was reverted, lost or
  resurrected by the swap. Both triggers are now `ENABLE ALWAYS`, asserted directly against
  `pg_trigger.tgenabled` in `tests/110`, which also shows the refusal and the capture from a
  replica-role session. **Upgrading in place:** re-running `install.sql` touches no existing trigger, so
  every write block an older pgpm installed is repaired on the first `maintain` tick afterwards, by the
  same per-child revisit that already runs every tick. A regrain already in flight across the upgrade
  keeps its origin-only capture trigger until it swaps; if a replica-role writer can touch that table,
  `regrain_cancel` it and the next tick re-prepares with the new trigger.
- **`pgpm.progress(p_parent regclass default null)`**: the drill-down `status()` is not (#343). One row
  per managed table, or one, answering the two questions that watching a production `transmute`, freeze,
  `regrain` sequence used to leave to hand arithmetic over `pgpm.part`, `pgpm.config`, `pgpm.log` and
  `cron.job_run_details`. *When will the monolith freeze?* `frontier`, `write_child`, `write_ceiling`,
  `freeze_margin`, `freeze_in`, `coarse_frozen`. *How far along is the regrain, and when does it finish?*
  `regrain_child`, `regrain_cursor`, `regrain_pct_range`, `regrain_rows_copied`, `regrain_rows_total_est`,
  `regrain_delta_pending`, `regrain_started_at`, `regrain_elapsed`, `regrain_eta`. The ETA is extrapolated
  from `config.regrain_cursor`, which already records exact, monotonic range progress, so it costs no
  scan and no per-tick timing on the hot path. That is why the issue's question of whether to instrument
  per-microbatch duration is answered no rather than deferred: an ETA never needed it.

  Three places a plausible number would have been a lie, and what was done instead. `regrain_pct_range`
  is a fraction of the RANGE and `regrain_rows_copied` a count of rows, never fused into an "N of M":
  rows are not uniform across a range, the cursor sits still until a whole sub-range completes, and an
  aged sub-range is advanced over without being copied, so the two legitimately disagree (pinned by
  `tests/106`, where 40% of the range is behind the cursor with 15% of the rows moved). `freeze_in` is
  **null for `id` grids**, whose frontier is `max(control)` with no clock and no history to make a rate
  from; `freeze_margin` carries the count instead. And `regrain_eta` is **null until there is progress**
  to extrapolate from, which is the whole of the first sub-range, even when rows have already moved.
- **`status()` gains `regrain_to`**, appended so positional readers are unaffected (#343). The auto-regrain
  target was the one field that had to be read from `pgpm.config` separately to learn whether the history
  was being split at all. `status()` is drop-and-recreate, so re-running `install.sql` picks it up.
- **New internal `pgpm._native_frac(kind, lo, hi, x)`**, the one place pgpm subtracts native grid values
  rather than comparing them. Internal, so no promise attaches to it.
- **Runbook: the lock-race deferral row is `skip_regrain`, not `regrain_skip`.** The regrain triage
  section named the suffixed form, which is exactly the shape the log-naming rule exists to forbid, and
  a reader filtering on it would have found nothing.
- The sixth gap in #343, telling a caught-error `skip_regrain` apart from a routine, self-healing
  `skip_write_block` without reading the source, is not in this change. It touches the log vocabulary
  across every action value and belongs in its own change; the issue stays open for it.

## [0.6.0] - 2026-09-23

**Upgrading in place needs no action this time.** `pgpm.part` gains `child_oid`, and unlike the
columns 0.5.0 added it is **backfilled** as part of re-running `install.sql`: through `pg_inherits`
for an attached partition, so what gets adopted is a partition of that parent by construction, and by
name for a not-yet-attached regrain child. A row whose name no longer resolves is left null, reads as
unanchored, and behaves exactly as before.

Two things will look different, neither of which is a migration step:

- **Three new `pgpm.log.action` values** -- `fail_archive_identity` (#421),
  `fail_write_block_identity` (#429), and wider use of the existing `fail_retain_identity` (#428).
  All are prefixed non-success events per the naming rule, so alerts matching exact action values are
  unaffected; all three count in `status().retain_drop_failures`, and none of them ever clears
  itself. A non-zero count where there was none means a partition's name has stopped resolving to the
  relation pgpm recorded for it, and the runbook's retention-triage section now leads with them.
- **pgpm now refuses where it previously acted.** That is the whole content of this release: four
  places resolved a partition or table by *name* and then read, dropped or replaced whatever answered,
  with nothing asserting it was the object they meant. Each now checks an oid first and stops. In a
  healthy install none of this is reachable and nothing changes.

This release closes the last of the #346 security-hardening campaign's successors. #411's
per-function time-of-check/time-of-use pass is fully worked through: #421, #428, #429 and #422.

- **`from_hypertable_cutover` locked a name and then `DROP`ped it, without verifying the oid (#422).**
  It resolved `p_hypertable` to a name pair once at the top, did a great deal of work, then
  `lock table <nsp>.<rel>`, `drop table <nsp>.<rel>`, and renamed the copy into place. `LOCK TABLE`
  freezes whatever a name means *at lock time*, so locking by name is only half the standard pattern;
  nothing re-resolved it afterwards, and the missing half is what turns a rename in the window into a
  `DROP TABLE` on a relation the procedure never identified.

  Most of that window turns out to be self-protecting, and it is worth recording which part is not. A
  rename before the cutover starts is caught by the `found no copy to cut over` check. A rename during
  the online pre-drain is caught too, but by a mechanism the issue did not name: the drain *steps*
  re-resolve the name per batch and raise `found no delta`, so the part of the window that commits
  repeatedly, and therefore looks widest, is the safest. What is left is the index pre-builds --
  explicitly the O(rows) work kept outside the lock so the outage stays brief, and so the longest
  stretch in the window, with nothing in it that re-resolves the source.

  The cutover now locks the source **by oid** (`p_hypertable::text` renders the current name of the
  relation actually passed in, so the lock lands on it even after a rename) and then requires the name
  to resolve back to it. It does the same for the **destination**, against the oid its own existence
  check resolved, and locks that too: the destination is renamed *into* the source's name, so an
  unverified one does not merely get dropped, it becomes the production table. Either mismatch aborts.

  Two limits, stated rather than implied. The destination check covers the window from the existence
  check to the swap; a destination substituted before the cutover was ever called is out of reach,
  because nothing in this module records what `from_hypertable_copy` built. And the lock could not
  simply move earlier: building the indexes outside it is what keeps the blocking window bounded by
  the catch-up rather than by the table size.

- **`_install_write_block` created its trigger on whatever answered to the name (#429).** It resolves
  the child by name and issues `CREATE TRIGGER` against the result, and `_enforce_write_blocks` calls
  it for every attached child on every `maintain()` tick -- so a relation that had taken a
  partition's name got a pgpm trigger rejecting all of its `INSERT`s, `UPDATE`s and `DELETE`s. DDL on
  a table pgpm was never handed, recorded nowhere in its own catalog.

  It is also what made #421 reachable rather than theoretical: `_archive_step`'s candidate query
  gates on `_is_write_blocked`, so a substituted name was only ever *eligible* for archiving because
  this step had made it so. Maintenance manufactured its own bad candidate. The check now lives in
  `_install_write_block` itself rather than in the reconciling loop, so a caller that does not know
  about it cannot reintroduce the defect; on a mismatch it logs the new `fail_write_block_identity`
  and returns without issuing DDL, rather than raising (which would propagate out of `retire`, and
  would be logged as a `skip_`, implying a deferral that a later tick clears -- which this is not).

  **`_remove_write_block` is deliberately left resolving by name.** Refusing to install on an
  unidentified relation is protective; refusing to *remove* is the opposite. A pre-#429 pgpm could
  already have stranded this trigger on a relation it never managed, leaving it rejecting every
  write, and an anchored removal would refuse to touch the very trigger pgpm itself wrongly created.
  Resolving by name is what lets an upgraded pgpm clean up after an older one.

  `fail_write_block_identity` is a prefixed non-success event per the naming rule, so alerts matching
  exact action values are unaffected; it counts in `status().retain_drop_failures` and, like its two
  siblings, never clears itself. No new column and no migration.

- **`retire`'s ordinary one-step `DROP` was unanchored (#428).** #407 gave `retire` an identity check
  but scoped it to the defect #407 was about: its anchor, `pgpm.part.retiring_oid`, is set only inside
  the referenced-partition branch, as `retire` dispatches a concurrent detach. For a partition nothing
  points a foreign key at -- the overwhelmingly common case -- it is null on every call, the check was
  skipped whole, and the closing `drop table schema.child` destroyed whatever answered to the name.
  `pgpm.part.child_oid` (#421) is the anchor that path was missing, since it is recorded at creation
  and so populated for every partition, and `retire` now consults it before any side effect.

  **The two anchors are checked independently, not coalesced**, and the difference is not academic:
  `retiring_oid` is itself resolved *by name*, out of `pg_inherits` at dispatch time, so a
  substitution that landed before the dispatch is adopted by that anchor and comparing the name
  against it passes forever. `coalesce(retiring_oid, child_oid)` would never reach the one anchor that
  still remembers the original. A disagreement with either refuses, and `method` names which, so a
  stale dispatch and a stale catalog row are distinguishable.

  No new action value and no new column: this reuses `fail_retain_identity`, which already counts in
  `status().retain_drop_failures` and already never clears itself. The `method` text has changed shape
  to name the disagreeing anchor; alerts matching the action value are unaffected. A null anchor is
  still not consulted, so nothing an upgrade cannot compare gets wedged.

- **The archive path carried a partition's identity as a name, with nothing anchoring it (#421).**
  `pgpm._archive_step` selects `child_name` out of `pgpm.part`, and every step downstream re-resolves
  that string on its own: the write-block eligibility test matches it against `pg_class`,
  `_next_archive_chunk` reads `schema.child` three times to size the chunk, and `archive_fn` is handed
  the bare name. Nothing asserted that the relation answering to it was the partition the row was
  written for.

  That needed no race. A name that has stopped meaning what it meant is a state pgpm already knows is
  reachable -- `pgpm.forget_missing` exists for it -- and on this path it is not read-only reporting:
  the chunk is sized from the substitute's rows, and the `pgpm.archive_ledger` row that follows claims
  coverage of a range those rows never came from. That ledger is `retire()`'s drop precondition, so the
  bogus claim opened the gate and the next `retain()` tick dropped the relation holding the name.

  `pgpm.part` gains `child_oid`, recorded where a partition *enters* the catalog (`obtain`, regrain's
  standalone child, `transmute`'s monolith) rather than at retirement the way `retiring_oid` is -- that
  one is null for every partition the archive step ever touches. `_archive_step` resolves each
  candidate's name against it before reading anything, and on a mismatch (including a name that
  resolves to nothing) logs the new `fail_archive_identity` action and skips that partition, leaving
  the rest of the batch to proceed. Nothing is read, so no ledger row is written, so coverage never
  completes and the drop precondition stays shut.

  Two notes for an upgrade, neither needing action. `child_oid` is **backfilled**, from `pg_inherits`
  for an attached partition and by name for a standalone regrain child, so an existing install is
  anchored the moment it upgrades rather than only for partitions minted afterward; a row whose name
  no longer resolves is left null, reads as unanchored, and behaves exactly as before. And
  `fail_archive_identity` is a prefixed non-success event per the naming rule, so alerts matching exact
  action values are unaffected; it counts in `status().retain_drop_failures` and, like
  `fail_retain_identity`, never clears itself.

## [0.5.0] - 2026-09-22

**Upgrading in place? Read this first.** `obtain` has moved out of `maintain()` into its own
procedure and its own `pg_cron` job (#347), and `pgpm.schedule()` is operator-invoked, so **an
existing install does not pick the new job up by installing this file**. Until you re-run
`pgpm.schedule()`, nothing extends the forward grid: `maintain()` no longer obtains at all, and
with no `DEFAULT` partition (#288) a write past the last bound is refused rather than absorbed.
`maintain_all()` detects the state and logs the new `warn_obtain_unscheduled` action once per
sweep, so it is visible rather than silent, but it does not self-heal. **Re-run
`pgpm.schedule()` right after upgrading.**

Three smaller surface changes, none of which needs action:

- `pgpm.part` gains `retiring_oid` (#407) and `pgpm.transmute_inflight` gains
  `owner_pid`/`owner_backend_start` (#405), all backfilled null. Null reads as "not anchored" and
  "no live owner" respectively, so a retirement or conversion already in flight across the upgrade
  behaves exactly as it did before.
- Two new `pgpm.log.action` values, `fail_retain_identity` (#407) and `warn_obtain_unscheduled`
  (#347). Both are prefixed non-success events, per the naming rule; alerts matching exact values
  are unaffected. `fail_retain_identity` is counted in `status().retain_drop_failures` and, unlike
  its neighbours there, never clears itself.
- `pgpm.set_regrain` now refuses a target step coarser than `partition_step` (#341), where it
  previously accepted one and produced a regrain that could not converge. A caller relying on the
  old acceptance gets an error instead of a wedge.

This release also carries five security fixes from the #346 hardening campaign, none of which
shipped in 0.4.0: #405 (an advisory-lock denial of service any connected role could trigger with
no grants at all), #406 (an unpinned publishing CLI handed a live token), plus #407, #408/#409
and #410. The campaign is closed; its two remaining findings are tracked as #421 and #422.

- **The dbdev minifier decided what a line was without knowing where it sat (#410).**
  `scripts/build_dbdev_package.sh` trims `pgpm_core/install.sql` from 329,376 chars to fit dbdev's
  250,000-char cap by dropping blank lines, full-line `--` comments and `COMMENT ON` statements. The
  `awk` that did it judged every one of those from the line's own leading characters, with no idea
  whether the line sat inside a string literal. A line beginning `--` inside a multi-line `'...'`
  literal is *data*: a statement assembled across several source lines, an example inside a `raise`
  message. Dropping it changes the SQL an operator installs from dbdev while the reviewed, committed
  `install.sql` still reads correctly, and nothing catches that, because the script's only check is
  the size ceiling and a dropped line can only help pass it.

  **#410 recorded this as dormant. Line-*dropping* was; whitespace *collapsing* was not.** The same
  blindness was already rewriting literal content in the published package, at **17 lines across
  five multi-line literals** -- among them the body of the delta trigger `regrain` generates, whose
  indentation and internal spacing were being rewritten inside the `format()` string that carries
  it. Harmless in every one of the five (the altered text lands in generated whitespace or inside a
  generated comment), which is exactly why it had never been noticed.

  The minifier is now `scripts/minify_sql.py`: one character-level scanner over the whole file
  carrying real lexical state -- single-quoted literals with `''` escapes, double-quoted
  identifiers, nestable `/* */` comments, and a stack of dollar-quote tags -- with every line's
  decision made from the state the line *starts* in. A line starting inside a literal is emitted
  byte for byte. A file that does not lex end to end (an unbalanced quote or dollar tag) is a loud
  error rather than a silent minify, and so is a run that drops no lines at all.

  Two things deliberately did not change. Comments inside `$$` bodies are still stripped: they are
  most of what the minifier removes, and #410's sketch of leaving dollar-quoted bodies alone does
  not fit under the cap. And `COMMENT ON` stripping stays, now state-aware, so a `;` inside the
  comment's own text no longer ends the statement early (the old `;$` line match did, and emitted
  the remainder of the literal as stray SQL). `\ir`/`\i` expansion is gone rather than fixed: it had
  never run against any file in this repo, so it was unverified code standing between the reviewed
  file and the published one, and a build that meets one now fails loudly.
  `scripts/build_install_bundle.sh` keeps its includes, which is a real asymmetry rather than an
  oversight -- it copies lines verbatim, where an include boundary costs nothing.

  The self-test carries a port of the old awk and requires each of its five defect fixtures to come
  out *differently* under it, so a rewrite that quietly reintroduced the blindness fails; three more
  fixtures assert the opposite, that the preserved behaviour still matches the old minifier exactly.
  Checked by pointing `minify()` at the legacy logic: the five fail, the three pass. New package is
  148,737 chars against the 250,000 cap, and `./test.sh 17 --channel=dbdev` installs it and runs the
  full pgTAP suite against it, green.

- **`bench/upgrade_in_place.sh` degraded 15 of the 25 columns it claimed to, and nothing said so
  (#417).** The guard proves that re-running `install.sql` over an existing database upgrades it
  rather than half-breaking it: it drops "every column `install.sql` backfills with `add column if
  not exists`" from a populated install, re-runs the file, and requires the result to hash-match a
  fresh oracle. `DEGRADE_COLS` is that list, and it held **15 entries against 25 backfill lines**.
  Ten backfill lines were exercised by nothing: the seven `text_time` `pgpm.config` columns
  (#334/#335), `pgpm.config.archive_batch`, and
  `pgpm.transmute_inflight.owner_pid`/`owner_backend_start` -- the last two being the columns #405's
  whole claim rests on, that a conversion whose session died stays reapable. On an upgraded install
  that backfill was unverified.

  The list's one precondition ran the wrong way. "Every LISTED column exists in a fresh install"
  catches the list naming a column the product has DROPPED, and the list was not stale in that
  direction, so it passed and reported nothing. It cannot catch the product GAINING a backfilled
  column the list forgot, which is the direction drift actually goes: every new column is an
  opportunity to forget one.

  So the guard gains a second precondition running the other way -- read the backfill lines out of
  the install file about to be run, and fail naming any that `DEGRADE_COLS` omits -- and the ten
  missing columns are now degraded. The hardcoding stays, because deriving the list from those same
  lines would make the guard circular against its own mutation, and the new check is one-directional
  for the same reason: `upgrade_no_column_backfill` DELETES a backfill line, and a missing backfill
  *line* is not a missing *list entry*, so the check still passes under that mutant and the
  catalog-hash assertion is still what fails it. Confirmed by running it, not assumed. The converse
  check ("every list entry has a backfill line") would fail under that mutant for a reason that is
  not the defect, and is deliberately absent.

  The new precondition has a mutation of its own, `upgrade_degrade_list_drift`: it gives
  `install.sql` a backfilled column the list does not name, and the guard has to fail on that
  precondition, by name. It is the first mutation here whose modelled defect lives in the guard
  rather than in the product, the product being moved only because that is the one way to reproduce
  it. The parse carries its own liveness witness: the loose match is case-insensitive and the strict
  one is not, so a backfill line written in a style the parser cannot read surfaces as a loud count
  mismatch instead of a line the check silently does not cover.

  The same defect one level up turned out to be sitting in `.github/workflows/perf.yml`, and is
  fixed with it: its path filter enumerated the guards it covers, and four of the thirteen the perf
  track runs were not on it. `bench/upgrade_in_place.sh` was one, so a change to the very file this
  entry is about triggered no perf job at all on its own. The filter matches `bench/*.sh` now, which
  is a shape rather than a list and so cannot fall behind.

- **`bench/restore_fk_lock.sh` stops racing a 4 ms window, and its liveness witness can now fail
  (#416).** The guard polled `pg_stat_activity` until it saw `restore_incoming_fks` active and only
  then began writing. Measured on PG 17.11 against its own fixture, the fixed restore takes
  **4.4 ms** -- it is one `ADD CONSTRAINT ... NOT VALID`, and `NOT VALID` does not scan -- so the
  probe was trying to catch a 4 ms window by polling. It missed intermittently, wrote nothing, and
  reported `at least one write landed inside it got false` against perfectly good code. Exactly the
  instrument-versus-window mistake CLAUDE.md records.

  Worse, the witness that was supposed to stop "no timeouts" from passing vacuously was itself
  vacuous: `saw := true` sat *after* the spin loop, so it was set whether the loop found the restore
  or exhausted two million iterations having seen nothing, and `"the probe overlapped a running
  restore"` could not fail.

  The race is now gone rather than tuned. A gate makes the ordering structural -- the probe starts
  writing and announces itself, the restore does not begin until that lands, and the probe does not
  stop until it finishes -- so the probe's write span *contains* the restore by construction and
  nothing has to be caught. Each attempt and the restore both record the interval they occupied, and
  the guard requires a genuine interval overlap, which also catches an attempt that began before the
  window and blocked into it. That the new witness CAN fail was checked rather than assumed: against
  a deliberately sabotaged copy whose probe never overlaps, it reports `0 of 300 attempts overlapped`
  and fails -- while "writes are not blocked" passes, which is the vacuous green the old guard
  reported as success. Fixed code 5/5 with 22-32 overlapping attempts; the
  `restore_fk_inline_validate` mutation still fails it (221.8 ms restore, 4 timeouts).

- **A retirement now knows WHICH relation it is retiring, not just its name (#407).** Retiring a
  partition an incoming foreign key references needs `ALTER TABLE ... DETACH PARTITION ...
  CONCURRENTLY`, which PostgreSQL refuses to run from a function, a procedure, a `DO` block or a
  dynamic `EXECUTE` -- so pgpm dispatches it to pg_cron as command text and completes the `DROP` on a
  later tick. A command text can only name a relation; there is no way to write an oid into it. The
  cron session therefore re-resolves `schema.child` a tick or more later, with no lock held on the
  partition across the interval, and had no way to notice that the name had come to mean something
  else. That is the same time-of-check/time-of-use shape as the `SPLIT`/`MERGE PARTITION` finding
  that motivated the whole #346 audit -- a name decided now, re-resolved and trusted by something
  else later -- and it ended in a `DROP`.

  pgpm cannot close the window, because the reason the statement is dispatched at all is that
  PostgreSQL will not let pgpm hold anything while it runs. So `pgpm.part` gains `retiring_oid`,
  recorded in the same transaction as the dispatch, and `retire` checks it at the top of every later
  call -- before the write block, the crossing `DELETE`, the re-dispatch or the `DROP`, so no step
  can touch a substitute. Two facts have to agree, since either alone is forgeable: the name
  resolves, and it resolves to that oid. When they do not, `retire` logs the new
  `fail_retain_identity`, returns the standing `pgpm_detach` job to idle and does nothing else. The
  detach can still land on a substitute; the destructive half cannot, which is the half worth
  anchoring. `status().retain_drop_failures` counts the refusal alongside `fail_retain_drop`,
  `fail_retain_crossing` and `fail_retain_detach`, because it wedges retention the same way -- and
  unlike those it never clears itself, so it is a wedge an operator has to look at.

  Three smaller changes fall out of the same reading. `_dispatch_detach` now takes the child as a
  `regclass` and renders both relation names from oids, so the text that lands on `cron.job` can only
  name relations the caller resolved in its own transaction. The standing job is returned to idle
  BEFORE the `DROP` rather than after it: the armed window was never one cron interval, it lasted
  until the drop SUCCEEDED, and a drop that kept failing left a stale name armed and re-firing
  indefinitely. And `_idle_detach_job` takes the command it expects to find, so the wedge above --
  which revisits it on every tick for as long as it lasts -- disarms only its own dispatch instead of
  clobbering another parent's on every tick; both it and `_dispatch_detach` build that text through
  the new `pgpm._detach_cmd`, so arming and disarming cannot drift. Both changed signatures are
  dropped explicitly, since `create or replace` can change neither a parameter's type nor its
  arity, and the old copies would otherwise stay installed and resolvable beside the new ones.

  `tests/77_retain_incoming_fk_test.sql` builds the substitution in the only shape that matters --
  the impostor is a genuine partition of the same parent under the same name, so the dispatched
  detach succeeds on it -- and drives both refusals, with liveness witnesses for the recorded oid,
  the impostor's different oid, and the impostor actually being attached. Every assertion there is a
  negative, so `bench/retire_detach_substitution.sh` runs the same file against an arbitrary copy of
  the module and the `retire_drop_unanchored_name` mutation deletes the identity check, which
  `./test.sh discriminate` requires the file to FAIL against. Measured: the mutant loses seven
  assertions, including the one that finds the substitute dropped. `retiring_oid` is added with `add
  column if not exists` and reads null for a retirement already in flight across the upgrade, which
  is treated as unanchored and behaves exactly as it did before rather than wedging mid-flight.

- **A `_q` suffix now marks every already-quoted SQL fragment, and CI keeps the mark honest
  (#409).** Several functions build a comma-joined fragment out of `quote_ident`'d pieces and then
  splice the whole fragment with a bare `%s` -- correct, since `%I` over an already-quoted string
  double-quotes it into garbage, but indistinguishable at the call site from a raw identifier
  someone forgot to `%I`. A later edit could swap one for the other in any of these functions and
  nothing would read as wrong.

  Applied to all 31 sites rather than the three #409 cited: `_regrain_reconcile` and
  `from_hypertable_drain_delta_step` were only the most visible copies, and a suffix on 3 of 31
  would have made the other 28 read as "not pre-quoted". (#409's third site,
  `_pq_to_parquet_range`'s `v_order_by`, is not among the 31 because it no longer exists: #408
  turned it into a `name[]` the encoder quotes itself, which is the stronger answer wherever it is
  available. A marker is for the fragments that have to stay fragments.) The sweep also turned up
  sites nobody had listed, including `regrain_step`'s `v_pkjoin_q` (a `format('d.%I = s.%I', ...)`
  join predicate), `transmute`'s `v_pdef_q` (a whole CREATE INDEX statement), and
  `from_hypertable_cutover`'s
  `v_pseq_q` (a `pg_get_serial_sequence` result, quoted by Postgres and spliced with `%s`).

  `scripts/check_quoted_splices.py` (CI's `Quoted splices` lint job) enforces it in both
  directions: a quote-derived `text` local must carry the suffix, and a suffixed one must be
  assigned from something that actually quotes, so the name cannot outlive its value. It carries a
  `--selftest` over embedded fixtures that requires each check to FAIL against its own defect, and
  a floor on how many quoting assignments it must find, so a parser that has stopped reading the
  module fails instead of reporting a clean sweep of nothing. Only `text` locals are considered,
  which is why it parses the DECLARE block: `format('%I.%I', ...)::regclass` quotes identifiers on
  its way to an OID, and an OID is not a fragment anyone can splice wrong.

- **No parameter of `archive._pq_encode_column_data` carries SQL any more (#408).** It was the one
  place among the 166 `execute format(...)` sites the #346 audit covered where a `text` parameter
  reached the executed statement through a bare `%s` with no quoting at all: the whole FROM item
  (`p_from_sql`) and the whole ORDER BY list (`p_order_by`), twice each, in every one of the seven
  type branches. Nothing untrusted ever reached it -- `_pq_to_parquet` passed a `%I`-quoted
  `schema.table` and the literal `'ctid'`, and `_pq_to_parquet_range` passed a `quote_ident`-joined
  key list and a `%I`/`%L`-built subquery -- so this closes no live hole. What it closes is where the
  guarantee lived: entirely in the two callers, so the function promised nothing on its own and a
  third caller written later would have inherited nothing.

  The relation now arrives as `p_schema`/`p_table` and the range as `p_control`/`p_lo`/`p_hi`, both
  of which go to the new `archive._pq_from_item` to be `%I`/`%L`-quoted; the ordering arrives as
  `p_order_by name[]` and is `quote_ident`'d element by element inside the function. There is no
  longer a parameter a caller can paste SQL into, so a future caller cannot route around it. Both
  entry points also build their `count(*)` FROM item through `_pq_from_item`, which is now the only
  place in the module that builds one.

  `tests/archive/db/10_encode_boundary_test.sql` drives a statement-terminator payload through every
  one of those parameters. Its `p_table` payload is deliberately self-completing -- it closes the
  SELECT, drops a victim table, and supplies a third statement returning the `(boolean[], bytea)`
  pair the `EXECUTE ... INTO` needs -- because the obvious payload leaves an unterminated identifier,
  and a statement that fails rolls back the very drop it was meant to prove, which would have made
  "the victim table survived" pass against vulnerable code too.

  That those assertions discriminate is now a standing check rather than something checked once by
  hand: `bench/archive_encode_boundary.sh` runs the same pgTAP file against an arbitrary copy of
  the module, and two mutations put each half of the defect back (`archive_from_item_raw_splice`
  weakens `%I` to `%s` in `_pq_from_item`; `archive_order_by_raw_splice` drops `quote_ident` from
  the ORDER BY build), so `./test.sh discriminate` requires the file to FAIL against both. The
  first takes the victim table with it; the second turns the payload into a syntax error instead of
  a quoted column name. The signature is pinned by the test and the old 7-arg arity is dropped
  explicitly, #209's gotcha being that `CREATE OR REPLACE` would otherwise leave the SQL-taking
  version installed beside the new one.

- **`docs/reference.md` described an `obtain` that has not existed since #288.** Its closing paragraph
  called `obtain` "a procedure, not a function", said it took "an advisory lock per parent" so a second
  concurrent call "defers instead of interfering", and said it reported failures through `p_deferred`.
  All three were false: `obtain` is `function pgpm.obtain(p_parent regclass) returns int` (as the
  section's own signature block, three paragraphs above, said correctly), there is no advisory lock
  anywhere in `pgpm_core/install.sql`, and no `p_deferred` parameter exists. Removed rather than
  rewritten -- the paragraphs above it already describe the real early-stop and lookahead behavior, so
  it left no gap.

- **`transmute` no longer claims a conversion with a session advisory lock (#405).** The claim was keyed
  on `hashtextextended('pgpm_transmute:' || oid)` -- a formula published in `install.sql`, over an oid
  anyone can read out of `pg_class` -- and advisory locks carry no ACL of any kind. Any role that could
  merely CONNECT could therefore take it, with no grant on any pgpm function and no privilege on the
  table. Two consequences, the second much worse than the first: holding it pre-emptively blocked every
  `transmute()` of that table outright, and grabbing it the instant a crashed conversion released it
  starved `_transmute_reap` forever, because the reaper decided "still running" by trying to take that
  same lock. That second one had no way out at all -- `transmute_abort`, the documented manual escape
  hatch, consulted the same lock and refused too -- so a crash could be turned into a permanent outage,
  with the table's `pgpm_monolith_bound` CHECK rejecting every write outside `[lo, hi)` indefinitely.

  `pgpm.transmute_inflight`'s existing primary key on `parent_table` is now the exclusion itself: one row
  per table, taken by a single atomic `insert ... on conflict do update`, in a pgpm-owned table carrying
  no GRANTs, so an unprivileged role cannot take or hold it at all. Liveness -- still the thing that has
  to tell "running" from "its session died", with no heartbeat and no timeout guess -- comes from the
  claiming session's identity, recorded in two new columns (`owner_pid`, `owner_backend_start`).

  The subtlety that decided the implementation, found by measuring rather than reasoning: `backend_start`
  is **masked for a backend owned by another role**, reading NULL rather than its real value (measured on
  stock PostgreSQL 17.10: an unprivileged role sees the row and its `pid`, but `backend_start`,
  `backend_type` and `query` all read NULL). The reaper runs from pg_cron under whatever role scheduled
  it, which need not be the role that ran `transmute`, so the obvious predicate
  `backend_start = owner_backend_start` evaluates to NULL for a perfectly live cross-role conversion --
  and the reaper would then have undone it out from under itself, dropping the bound and deleting the
  claim mid-validation-scan. `pgpm._session_alive` therefore DEGRADES instead: pid and `backend_start`
  where that column is visible, pid alone where it is not. The residual failure is under-reaping (a
  recycled pid looks live, leaving an abandoned bound for an operator's `transmute_abort`) and never
  over-reaping a live conversion. Same discipline #98 established for the ambient sensors: read what
  every role can see, never a column `pg_monitor` masks.

  Guarded by `bench/transmute_claim_squat.sh`, which drives a real second-session squatter against the
  old key and asserts -- with a liveness witness that the squat is genuinely in place, on the right key,
  from a session that is not the claim's owner -- that the reaper and `transmute_abort` both work anyway.
  Its mutation (`transmute_claim_advisory_reap`) restores the advisory-lock recovery paths and the guard
  fails against it. `tests/101_transmute_claim_test.sql` pins the claim's state machine and the liveness
  predicate. Upgrades in place: the two columns are added with `add column if not exists`, and a claim
  recorded before they existed reads as having no live owner, so it stays reapable rather than becoming
  stuck behind a check it has no data for.

- **The lock-trace guard now runs in CI (`.github/workflows/locktrace.yml`, #383 phase 3 / #389).**
  Until now nothing in CI ran that track, so off Linux it was verified by nobody. A spike on a hosted
  runner settled the three questions that had kept the workflow unwritten, by measurement rather than
  argument: BCC compiles and attaches on `ubuntu-latest` (kernel `6.17.0-1022-azure`) and the guard
  passes there, including failing against its mutant; headers matching `uname -r` are already present,
  so there is no drift to work around and no source build; and the whole job takes 132 s, of which the
  image build is 91 s, which is why it carries no build cache. The job asserts the header requirement
  up front so that losing it later is a legible failure rather than an opaque BCC compile error, and
  runs a single `./test.sh locktrace`, since that track already runs the guard and requires it to fail
  against the defect. `./test.sh ci`'s skip notice and `CLAUDE.md` now say CI covers the skip, which
  before this they could not truthfully say.

  Running it in CI immediately earned its keep by failing, on a defect in the instrument rather than
  in pgpm, and that failure ended with **pg-lock-tracer being abandoned entirely**. It emitted every
  lock event for the whole server through a PER-CPU perf buffer and formatted each one as JSON in
  Python: ~120,000 events per tick to deliver about ten facts. Two consequences followed from that one
  design choice. Per-CPU buffers deliver out of order across CPUs (measured: 4 inversions in 101,185
  events, two of them statement markers, which moved a boundary 53,000 positions and silently shrank
  the window under test to almost nothing), and the Python consumer could not keep up, so the buffer
  overflowed -- opened with no `lost_cb`, discarding events in complete silence (measured: 4,150 lost
  in one run, the guard reporting a lock as never released while the commits in the same interval
  proved it had been).

  `bench/lock_probe.py` replaces it: ~40 lines of BPF C we own, probing `LockRelationOid` and
  `CommitTransaction` and filtering by relation oid and backend IN THE KERNEL, so dozens of events
  reach userspace instead of ~120,000. It uses `BPF_RINGBUF` rather than `BPF_PERF_OUTPUT` -- one
  shared buffer, so records arrive in order and nothing needs sorting, and `ringbuf_reserve()` fails
  visibly when full, so the probe counts its own drops in the kernel and the guard asserts that count
  is zero. A truncated stream can no longer masquerade as a complete one. The image drops
  pg-lock-tracer, four Python libraries and the script that patched its source in two places; only
  `python3-bpfcc` and version-pinned debug symbols remain. The release path is deliberately not
  probed: `UnGrantLock` takes a struct pointer, so reading a relation oid from it would mean
  depending on field offsets that shift between PostgreSQL versions, whereas
  `LockRelationOid(Oid, LOCKMODE)` passes scalars. A commit releases the lock, so the commit is the
  honest signal.

- **Lock boundaries are now OBSERVED, not inferred, by a new `./test.sh locktrace` track (issue #383,
  phases 1 and 2).** Every lock guard in `bench/` proves "the lock was released before the next slow
  step" indirectly: a concurrent reader under a short `lock_timeout` either times out or does not.
  Cheap and portable, but it cannot see a lock it did not happen to collide with, and it cannot say
  which boundary released one. `bench/lock_trace.sh` attaches
  [pg-lock-tracer](https://github.com/jnidzwetzki/pg-lock-tracer) uprobes to the running server and
  asserts the thing itself: between the last `AccessExclusiveLock` grant on `mg_ret`'s parent and the
  first lock event on `ml`'s parent, there is an ungrant (the release) and a `TRANSACTION_COMMIT` (the
  `#265`/`#279` boundary). Measured on correct code: 2 releases and 7 commits in that interval; against
  the mutant, zero of each while every liveness witness still passes. The track runs the guard and its
  mutation together in about 50 seconds. It is a supplement, not a replacement: the reader-probe guards
  stay as the fast, portable first line, and `./test.sh discriminate` is unchanged and still runs
  anywhere. `./test.sh ci` runs the track on Linux and reports it as `SKIPPED`, never folded into the
  `PASS`, on anything else; the condition is the kernel alone, so a Linux box that cannot actually
  trace FAILS rather than skipping, on the rule that a guard which never ran is unverified. eBPF needs
  a privileged container and the host's own kernel headers, which Docker Desktop for Mac cannot
  provide. (`bench/lock_trace.sh`, `bench/skip_fastpath_probes.py`,
  `bench/mutations/mutate.py`'s `maintain_no_commits_trace`, the `locktrace` compose service,
  `Dockerfile`'s `WITH_LOCK_TRACER`)

  Two findings worth keeping. The trace JSON is written in perf-buffer DELIVERY order, not time order:
  4 inversions in 101,185 events, two of them the statement markers themselves, which moved
  `maintain_all()`'s `QUERY_BEGIN` 53,000 events away from its real position and silently reduced the
  window under test to almost nothing. Sort by `timestamp` first. And that failure was caught by the
  guard's liveness witnesses rather than its ordering assertion, which held vacuously over the empty
  window -- the exact shape `CLAUDE.md` exists to prevent, arriving from a direction nobody had
  anticipated.

- **`maintain_obtain()` no longer lets its back-off outlast the forward grid.** One lost `lock_timeout`
  race sets a 30-second `config.obtain_retry_after` back-off, and obtain was skipped for all of it, however
  little grid was left. That was harmless while a `DEFAULT` partition caught writes past the grid; since
  #288 such a write is refused. A local load test at ~42k ids/s against a 3-partition lookahead (~14 s)
  lost one race and every client aborted with `no partition of relation ... found for row`. The back-off
  is now honored only while at least `ceil(obtain / 2)` complete grid steps of attached coverage remain
  beyond the frontier's own grid cell; below that, obtain runs anyway (status note
  `obtain_backoff_bypassed`). Coverage, not partitions: grid inside a monolith widened by
  `p_bound_headroom` counts, so such a table does not retry obtain's `ACCESS EXCLUSIVE` every tick while
  it still has room. The count runs only while a back-off is active. (tests/100, bench/obtain_backoff_headroom.sh)

- **Leftovers from the `DEFAULT`/drain removal (#288) cleaned out of `pgpm_core/install.sql`.** Two
  error messages named machinery that no longer exists: `pgpm.schedule()` without `pg_cron` told you to
  call `drain_all`, and now points at `maintain_all()`/`maintain_obtain_all()`; `transmute`'s orphan-table
  refusal blamed an "interrupted drain" and now says "interrupted regrain", matching the runbook. Also
  removed: `regrain()`'s unreachable `default_dirty` branch and about a dozen unused adaptive-feathering
  variables in `maintain()`; comments that still described the drain now describe regrain.

- **`obtain` split out of `maintain()`/`maintain_all()` into its own procedure and its own `pg_cron`
  job (issue #347).** `maintain_all()` loops over every managed table sequentially in one session,
  calling `maintain()` for each; a slow `archive`/`retain`/`regrain_step` for one table used to delay
  `obtain` for every table after it in the same tick, purely because of loop order. Every other step
  degrades gracefully if delayed; only `obtain` turns "ran late" into "writes started failing," since
  there is no `DEFAULT` partition (#288) to catch a write past the forward grid. `pgpm.maintain_obtain(p_parent,
  inout p_status)` and `pgpm.maintain_obtain_all()` now carry `obtain` on their own, and
  `pgpm.schedule()` takes a second, independent cadence parameter, `p_obtain_every` (default
  unchanged), registering a new `pgpm_obtain` job alongside the existing `pgpm` and `pgpm_detach`
  ones; `pgpm.unschedule()` removes all three. `pgpm.obtain()` itself, and `maintain_all()`'s
  structure, are untouched. `maintain()`'s returned status string no longer includes `obtained=`
  (unchanged: `pgpm.log`'s `obtain`/`skip_obtain` action values, which now originate from
  `maintain_obtain()` instead).
  **Upgrade hazard:** `schedule()` is operator-invoked, never automatic -- an installation that
  already called it before upgrading past this change will NOT pick up the new `pgpm_obtain` job on
  its own, and `obtain` will silently stop running until the forward grid runs out and writes start
  failing. **Anyone with an existing `pgpm.schedule()` must re-run it after upgrading.**
  `maintain_all()` also logs a `warn_obtain_unscheduled` row to `pgpm.log` once per sweep as a
  backstop for anyone who misses this. (tests/31, tests/78)

- **`pgpm.set_obtain(p_parent, p_obtain)` and `pgpm.set_retain(p_parent, p_retain default null)`
  (issue #326).** `obtain`/`retain` were settable only at `transmute` time; changing either
  afterward meant a raw `update pgpm.config`, with no validation and no test coverage -- the only
  other `update pgpm.config set obtain/retain...` anywhere was the internal backoff writer.
  `set_obtain` refuses a negative `p_obtain`, which would otherwise silently and permanently disable
  lookahead (`obtain`'s `for k in 0 .. cfg.obtain` loop never runs when `cfg.obtain < 0`). `set_retain`
  validates `p_retain`'s shape against `control_kind` the same way `transmute` does (`numeric` for
  `id`, an interval otherwise), and -- since `retain` is the destructive knob that decides what
  `retain()` `DROP`s -- **refuses**, not merely warns, whenever the new value would make the very
  next `retain()` tick drop a partition the *old* value still kept. Loosening (a bigger
  interval/count, or `null` = keep forever) can never trip that refusal. (tests/97, tests/98)

- **`pgpm.extend_to(p_parent, p_value, p_max default 10000)` pre-extends the forward grid past
  `obtain`'s lookahead ceiling (issue #290).** Since #288 removed the `DEFAULT` partition, `obtain`'s
  `config.obtain x partition_step` lookahead is the only thing standing between a write and `no
  partition of relation ... found for row`, and for an `id` grid the frontier is data-driven and can
  jump past it with no recovery path: a sequence restart, a non-dense Snowflake/ULID generator, a
  bulk import, a backfill. `extend_to` is the relief valve -- name a value you know is coming and it
  builds every missing partition on the existing grid up to and including the one that would hold it,
  without moving the frontier or touching data. It never partially extends: the number of new
  partitions needed is checked up front, before any DDL, and a target needing more than `p_max`
  (default 10000) is refused loudly rather than silently stopping short. Idempotent; returns how many
  partitions it actually created.

- **`set_regrain` now refuses a target step coarser than `partition_step` (issue #341).** Accepting
  one used to silently wedge auto-regrain forever: `maintain()`'s auto-regrain candidate query
  calls a child "coarse" whenever it is wider than one `partition_step` (hardcoded, not
  `regrain_to`), while `regrain_step`'s own `'nosubdiv'` guard refuses to split a child already at
  (or narrower than) the configured target. With `regrain_to` coarser than `partition_step`, a
  coarse child got split down to `regrain_to`-wide pieces exactly once; those pieces were still
  wider than `partition_step`, so the candidate query kept reselecting the same now-unsplittable
  child every tick, forever, with nothing raised and no log signal beyond the routine no-progress
  status. `set_regrain` now rejects a coarser target at call time instead. Equal-or-finer targets
  are unaffected -- every existing call site in this repo (`README.md`, `docs/guide.md`,
  `docs/runbook.md`, all five tests, all three bench scripts) already passes one. The one-off
  manual functions, `pgpm.regrain()` and `pgpm.regrain_history()`, are untouched and remain fully
  general: `docs/runbook.md`'s disk-pressure workflow deliberately regrains to a step coarser than
  the final grid through those, and it is single-shot, not a perpetual tick loop, so it never hits
  this failure mode.

## [0.4.0] - 2026-09-08

**Upgrading in place? Read this first.** This release adds `config.archive_batch`, backfilled onto
every existing managed table with a default of `1`. If you currently rely on `_archive_step`
fanning out across every eligible partition in one `maintain()` tick (the only behavior earlier
versions had), that default silently makes archiving strictly sequential -- one partition at a
time -- immediately after upgrading. Set `archive_batch = null` for any table where you want to
keep the old unbounded behavior; see [Byte-budget chunked
archiving](docs/reference.md#byte-budget-chunked-archiving) for the tradeoff. Everything else in
this release is additive or a pure bug/doc fix with no behavior change for an existing install.

- **One partition's lock timeout no longer stalls write-blocking (and regrain-capture cleanup)
  for every other eligible partition that tick (issue #360).** `_enforce_write_blocks` and
  `_enforce_regrain_capture` each looped over every eligible child with no per-iteration exception
  handling, so a lock timeout (or any other failure) on any single child raised out of the whole
  loop, leaving every other child that tick -- lock-contended or not -- untouched. Since `retain`
  only drops a child once it is write-blocked, this could turn one recurring point of lock
  contention into a compounding retention backlog. Fixed by isolating each child's attempt in its
  own exception scope (a failure now logs `skip_write_block` / `skip_regrain_capture`, attributed
  to that child's own `hi`, and the loop moves on) and adding `order by hi asc` to
  `_enforce_write_blocks`'s cursor so forward progress always prioritizes the oldest, most overdue
  partitions first, matching `_archive_step`'s existing convention. Verified directly: a
  deliberately "poisoned" middle child (its underlying table dropped out from under an
  otherwise-normal `pgpm.part` row) no longer prevents children before *or* after it from being
  correctly write-blocked -- against the old code, the same fixture failed to block even the
  oldest eligible child, since the old query had no ordering guarantee at all.

- **Docs: corrected a stale comment describing `obtain`'s `lock_timeout` rationale (issue #361).**
  The comment justifying `obtain`'s 200ms lock timeout in `maintain()` described the pre-#288
  `ADD CONSTRAINT`/`VALIDATE` exclusion-constraint dance against a `DEFAULT` partition -- a
  mechanism issue #288 removed. Rewritten to describe what `obtain` actually does today (a single
  `CREATE TABLE ... PARTITION OF`, taking `ACCESS EXCLUSIVE` on the parent itself and scanning
  nothing). No behavior changed; the timeout value itself is unchanged.

- **Docs: `p_bound_headroom` permanently delays regrain eligibility, undocumented (issue #342).**
  Headroom widens the monolith's upper bound `hi` before the bound `CHECK` is added in `transmute`'s
  phase 1, and that same `hi` becomes the monolith's permanent, attached partition bound at cutover
  (Postgres's zero-scan `ATTACH PARTITION` requires the validated `CHECK` to exactly imply the
  attached bound, so there is no cheaper way to widen the transient write-ceiling protection alone).
  `regrain_step`'s frozen precondition is a whole-child test against that same `hi`, so headroom
  sized to cover a write-ceiling window lasting seconds to minutes also delays regrain eligibility
  for the entire monolith by the same number of grid steps. Documented in both `docs/reference.md`'s
  `p_bound_headroom` parameter description and `docs/guide.md`'s transmute walkthrough; no code
  changed.

- **Docs: sizing `archive_byte_budget` (issue #354).** Added a "Sizing `archive_byte_budget`:
  there is no single optimal size" subsection to [Byte-budget chunked
  archiving](docs/reference.md#byte-budget-chunked-archiving) -- the four considerations that pull
  in different directions (the DEFLATE compression window's 32 KB floor, the `statement_timeout`
  ceiling, query-engine pruning being file-level only, and per-file overhead), a sizing method
  (tie the budget to a meaningful partition boundary, measure real per-row cost rather than assume
  it, prefer `archive_batch` over `archive_byte_budget` for throughput), and why the ~1 GiB
  in-memory ceiling documented in `pgpm_archive/README.md` isn't the one that actually binds.
  Linked from [docs/guide.md](docs/guide.md#archiving-before-a-drop) too.

- **S3 archive uploads no longer break on a table name that needs quoting.** `archive._encode_upload_ndjson_single`/`_encode_upload_parquet` build their S3 key from `p_parent::text`, which Postgres renders with a literal `"` for any identifier that needs it (mixed case, a reserved word) -- a Prisma-style `PascalCase` table, for one. That quote rode straight into the request path unencoded: the canonical request used for SigV4 signing diverged from what actually went out over the wire, and every upload failed `403 SignatureDoesNotMatch`. Fixed by `archive._s3_encode_path`, applied to the S3 key in both signer functions (`archive.s3_signed_request`/`s3_signed_request_bytea`): percent-encodes each path segment via the existing `archive.s3_url_encode`, while leaving `/` alone as the path separator, matching AWS's own S3 canonical-URI rule.

- **Regrain no longer stalls on a table's outgoing foreign key (issue #348).** A fine child is created
  via `like ... including constraints`, which never copies a `FOREIGN KEY` (no `LIKE` option does), so
  every fine child reached the swap's `ATTACH PARTITION` with no matching constraint at all. PostgreSQL
  then validated the parent's outgoing FK for that partition from scratch, inside the `ATTACH`
  statement, under whatever lock it already holds and with no timeout of its own -- in production this
  reached the session's `statement_timeout` outright and the swap never completed. Fixed by giving each
  fine child its own outgoing FK, added and validated while the child is still empty (the same moment
  the bound `CHECK` is added), so the scan costs nothing and the swap's `ATTACH` adopts the
  already-validated constraint instead of re-scanning -- the same adoption `transmute` already relies on
  for the monolith. Measured: attaching a 90,000-row partition with the FK pre-validated took 0.69ms;
  the identical attach without pre-validating took 16.9ms for the same row count. Guarded by
  `bench/regrain_outgoing_fk_lock.sh` (`./test.sh perf`), with a paired mutation
  (`regrain_no_outgoing_fk` in `bench/mutations/mutate.py`) so `./test.sh discriminate` proves the
  guard actually catches the regression.

- **Parquet column encoding is no longer O(n^2) (issue #353).** `archive._pq_encode_column_data`
  built each column's data page by growing a `bytea` (or, for `bool`, a `boolean[]`) one row at a
  time with `:=`/`||` inside a PL/pgSQL loop -- every append reallocated and copied the entire
  accumulated buffer, costing O(n^2) total for n rows, regardless of `archive.config.compress`
  (this ran identically either way, before compression ever saw the result). Rewritten to derive
  both the column's null bitmap and its encoded bytes with real SQL aggregates
  (`string_agg`/`array_agg` over `unnest(...) with ordinality`), mirroring the pattern this file
  already used correctly elsewhere for list/array encoding. Verified byte-for-byte identical output
  against the prior implementation across all eight supported types, both nullable states, and
  empty/single-row/all-null/all-present edge cases (40 cases, zero mismatches). Measured: encoding
  a 100,000-row text column dropped from 22.96s to 189ms (~121x), and scaling from 100K to 500K
  rows is now close to linear (4.9x for 5x rows) rather than the ~29.5x it was.

- **Chunked archiving now paces itself across partitions, not just within one (issue #351).**
  `_archive_step` used to loop over every write-blocked, not-yet-covered partition on every
  `maintain()` tick with no cap -- fine when one new partition becomes eligible per rollover
  interval, but a single tick's duration scaled with the size of the archiving *backlog* the moment
  a bulk regrain or backfill left many partitions eligible at once, which could itself cross
  `statement_timeout` regardless of how conservatively `archive_byte_budget` was tuned. New
  `config.archive_batch` (default `1`; `null` = unbounded) caps how many different partitions one
  call touches, oldest first -- the same shape as `retain_batch`, but a different default:
  `retain_batch`'s unlimited default is safe because `DROP TABLE` is cheap and constant-cost
  regardless of volume, while archiving a partition is a real read, encode, and (with compression
  on) CPU-bound pass. Defaulting to `1` makes archiving strictly sequential: one partition fully
  archived, and so retirable, before the next is even touched.

- **Parquet archival supports PostgreSQL enums and arrays (issue #339).** Enums are written as UTF-8
  strings, while arrays are written as JSON-tagged strings that preserve null arrays, empty arrays,
  null elements, multidimensional values, and element escaping. Both whole-table and automatic
  range archival use catalog type metadata, so schema-qualified and mixed-case enum names work.

## [0.3.0] - 2026-08-26

- **`uuidv7`'s forward frontier no longer stalls on a data drought (issue #325).** Every other kind's
  frontier is either the clock (`time`) or bounded by it (`id` has no clock, so it cannot fall behind
  where the next write goes). `uuidv7` was the one exception: gridded against plain `max(control)`, with
  no clock in it at all. A table whose writes went quiet for longer than `obtain x step` -- a restored
  dump, a stale clone, a table that simply stopped being written to -- had that frontier stuck wherever
  the data ended while `now()` kept moving. `obtain` then measured itself against its own past output,
  found nothing to do, and every write past the stalled grid was refused, permanently and silently: no
  `fail_*`/`skip_*` log event distinguished the tick from a healthy one.
  - Fixed by gridding `uuidv7` against `greatest(max(control), now())`, in **both** places that compute
    it: `_frontier_native` (what `obtain`/`maintain`/`regrain_step` use every tick) and `_transmute`'s
    separate inline duplicate (the initial monolith bound, computed before `pgpm.config` exists to call
    the shared function). Fixing only one leaves the other stuck at the data-only value, opening a
    partition gap between the monolith's frozen edge and `obtain`'s now()-anchored forward grid on the
    very next tick.
  - `bench/frontier_drought.sh` reproduces the issue's own repro (a table backfilled 13/11 months stale,
    `p_obtain => 2`) and drives three separate maintenance ticks, matching the issue's own "across five
    ticks, nothing changes" observation but showing it now stays fixed instead. Verified via
    `./test.sh discriminate` against the `frontier_data_only` mutation, which reverts both sites.
  - `docs/pilot.md`'s uuid preflight section, added while this was still open, is retired: there is
    nothing to check before converting now.

- **A fourth control kind, `text_time`, for opaque sortable TEXT ids** -- classic `cuid`, KSUID, ULID
  stored as text, and MongoDB `ObjectId`, none of which fit `time`/`id`/`uuidv7`. The shape is declared,
  not detected: a constant prefix, a fixed character width, a radix, a time unit, and (for formats that
  need them) a custom digit alphabet, a bit-discard count, and a non-Unix epoch --
  `p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit`/`p_tt_alphabet`/`p_tt_discard_bits`/`p_tt_epoch` on
  `transmute`. `pgpm.check_text_time` (the `check_uuidv7` analogue) samples a column against the declared
  shape to gate the conversion, the same way `check_uuidv7` gates `uuidv7`; `p_force_text_time`
  overrides. Ready-to-use parameter recipes for all four formats are in the
  [user guide](docs/guide.md#pick-the-kind).
  - Motivated by a real production id shape: a customer's `cuid()`-generated TEXT primary key, verified
    empirically (order-monotonicity and value-closeness against a companion timestamp column, and a
    check for incoming foreign keys) before choosing to partition on it directly rather than widen the
    key or drop it.
  - ULID and KSUID needed more than cuid and ObjectId did. ULID uses Crockford's base32 (deliberately
    skips I/L/O/U), not the plain `0-9a-z` convention -- `p_tt_alphabet` overrides it. KSUID base62-encodes
    its *entire* 160-bit payload (a 32-bit timestamp plus 128 bits of random) as a single number against
    a non-Unix epoch (`2014-05-13 16:53:20+00`) -- the timestamp is the top 32 bits of a wider decoded
    value, not a separate substring, which is what `p_tt_discard_bits` and `p_tt_epoch` are for. Every
    alphabet and epoch value was verified against the format's own source (`segmentio/ksuid`,
    `ulid/spec`, MongoDB's BSON reference), not assumed from the name.
  - `_radix_decode`/`_radix_encode` (the base-N codec `text_time` is built on; PostgreSQL has none built
    in) widened from `bigint` to `numeric`, since KSUID's whole-payload value overflows a 64-bit bigint
    by close to 100 decimal digits. Building the KSUID case surfaced a real arithmetic bug at that scale:
    digit extraction used `floor(v_n / p_radix)`, and PostgreSQL's general numeric division computes a
    non-terminating quotient to a *bounded* number of decimal digits -- exact enough at cuid's ~12-digit
    scale, silently wrong (occasionally negative "digits") at KSUID's ~48-digit scale. Fixed with exact
    integer `div()`/`mod()`, verified with a round trip at real KSUID scale.
  - Inherits the `uuidv7` frontier fix above from day one: `_frontier_native` and `_transmute`'s inline
    duplicate both grid `text_time` against `greatest(max(control), now())`. Confirmed the hard way
    during development that generalizing only the shared function reproduces the exact partition-gap
    defect the `uuidv7` fix closed, since `_transmute`'s copy is a separate site that does not call it.
    `bench/frontier_drought.sh` proves the drought-immunity property for `uuidv7` and `text_time`
    independently rather than inferring one from the other, for exactly that reason.

- **The pilot playbook (`docs/pilot.md`) split rung 0 into correctness and concurrency, and gained a
  field apparatus for the second half.** An idle restored clone proves a conversion is correct but
  cannot prove it is online -- "no reader or writer was blocked" is trivially true where there are none.
  Rung 0a now covers correctness on an idle clone; rung 0b needs a live writer and reader across the
  conversion, and now has one: `bench/pilot_workload.sql` generates a self-consistent workload from a
  target table's own catalog (copying an existing row with the control column overridden, so every
  `NOT NULL`, FK and `CHECK` holds by construction), and `bench/transmute_online.sh` is the field
  instrument that drives a live conversion under it and asserts no writer was blocked or even queued.
  Verified on a 3M-row table: 9/9 assertions pass against real `install.sql` and fail correctly against
  the `transmute_no_commits` mutant.
  - The rung 0a/0b split also surfaced the `uuidv7` idle-clone gap that became issue #325, and the doc's
    reset-between-runs section was rewritten from measurement rather than reasoning: on a real
    point-in-time restore, `cron.job`'s scheduler resumes about one second after the database becomes
    reachable, immediately re-applying whatever retention pass the restore had just undone. The fix is
    to take the reset point with pgpm **paused**, verified with a controlled pair of restores (resumed
    vs. paused) on the same project.

## [0.2.0] - 2026-08-20

- **An installed database can say what it is: `pgpm.version()` and `pgpm.installed`.** There was no way
  to ask a database which pgpm was in it. The only version string lived in `extension.control`, which the
  `install.sql` channel never reads, so a database installed that way carried no version at all and every
  support conversation started by guessing.
  - `pgpm.version()` returns the semver triple, baked into `install.sql` at release time.
    `RELEASING.md` makes it the same string as `extension.control`'s `default_version` and the git tag.
  - `pgpm.installed` records one row per `install.sql` run, with the version and the full
    `server_version`. It is a history, not a current-version row, because re-running `install.sql` *is*
    the upgrade path for this channel. The `insert` is deliberately the **last statement in the file**,
    so a row for version V means the V run reached the end rather than dying partway: `psql -f` gives
    each statement its own transaction unless called with `--single-transaction`.
  - One honest limit: an install predating the table records its first row as the version it was
    upgraded *to*. The history can only start where the table does.

- **`bench/upgrade_in_place.sh`: the in-place upgrade was never tested at all.** `install.sql` is the
  upgrade path, and a new column reaches an existing database only if the file also carries an
  `alter table ... add column if not exists` line for it. There are fourteen such lines, all
  hand-maintained, and nothing enforced them. Add a column to a `create table` body, forget the backfill
  line, and every existing install comes out missing it.
  - The whole pgTAP suite is blind to this by construction: it installs **fresh**, one database per file,
    so it never upgrades anything. The break lands only on operators who already had pgpm installed,
    which is to say only on the ones who are not evaluating it.
  - The guard installs, degrades the database to an older shape by dropping all fourteen columns,
    re-runs `install.sql`, and requires the result to be catalog-identical to a fresh install of the
    same code, with its managed table's rows intact by identity and its registration unchanged.
  - Two liveness witnesses, because every assertion in it is of the form "the upgrade restored X" and
    all of them pass against a degrade that silently did nothing. First: the columns really are absent
    after the degrade. Second: `maintain()` still mints a partition afterwards, named, since a
    structurally perfect install that can no longer obtain is not an upgrade anyone wants.
  - The fixture is id-kind rather than time-kind, and that is load-bearing: `obtain` measures a time
    table against the **clock**, so nothing the harness inserts can give it work to do. For an id table
    the frontier is `max(control)`, which the harness moves on purpose. It moves it to one below the last
    bound, since with no DEFAULT partition (#288) an insert past the newest bound is rejected rather than
    extending the grid.
  - Mutation `upgrade_no_column_backfill` deletes the `obtain_retry_after` backfill line and the guard
    fails against it, catalog mismatch first and then `record "cfg" has no field "obtain_retry_after"`
    out of `maintain` itself. Wired into `./test.sh perf`, verified by `./test.sh discriminate`.

- **`RELEASING.md`, `SECURITY.md`, `docs/pilot.md`.** Project mechanics that had no written form.
  `RELEASING.md` states what a version number covers (the callable surface, the config tables, the
  `pgpm.log.action` values, the supported PostgreSQL majors), the pre-1.0 policy and the bar for
  spending `1.0.0`, the release steps and two traps in the existing tag pipeline, and the
  install.sql-is-the-upgrade-path rule for contributors. Cadence anchored to PostgreSQL's release
  calendar, and the deprecation policy, are recorded there as an explicit TODO rather than invented now.
  `SECURITY.md` gives a private report route and scope, and states the properties a reviewer would
  otherwise have to infer: no `SECURITY DEFINER` anywhere, no superuser requirement of pgpm's own, and
  identifiers quoted through `format(%I)` or `quote_ident()` in dynamic SQL. `docs/pilot.md` is the
  template for an early production install: what it does not promise, the exposure ladder, the kill
  switch and what a stopped pgpm actually leaves behind, and the two health queries an operator needs.

- **`transmute` refuses a colliding `<index>_pgpm` name up front instead of failing mid-cutover
  (issue #311).** It recreates each carried secondary index as a partitioned index on the new parent named
  `<original>_pgpm`, then attaches the monolith's original under it. Nothing checked that name was free.
  - A pre-existing relation by that name made the `CREATE INDEX` fail with a raw `42P07` from inside the
    cutover: `relation "q_p_idx_pgpm" already exists`, no `pg_partition_magician:` prefix, no guidance,
    and no hint that the remedy is `drop index ..._pgpm`.
  - **The operator was not left where they started.** The cutover is one transaction, so no data was lost,
    but phases 1 and 2 had already committed. Measured with a bare `CALL` against pre-fix code: a
    `pgpm.transmute_inflight` row and a live `pgpm_monolith_bound` `CHECK` remained on the table, and that
    `CHECK` goes on refusing every write outside `[lo, hi)` until someone runs `transmute_abort`.
  - Every sibling shape already refused up front with the remedy (a key excluding the control column, a
    bare unique index, an un-carryable `UNIQUE` secondary, a transition-table row trigger, an orphaned
    child table). This was the one hole in that contract. The new check names every collision at once,
    since one per retry would make an operator with several re-run the conversion once per index.
  - `tests/83` records something worth knowing about the other refusal tests too: `throws_ok` is a
    function, and a committing procedure cannot commit inside one, so a refusal that happens *after*
    phase 1's `COMMIT` cannot be asserted with it -- the call dies at the commit with `2D000` and never
    reaches the defect. Only the first assertion discriminates; the rest characterise the post-fix
    contract, and the file says so rather than letting them read as proof.

- **`transmute` no longer downgrades `GENERATED ALWAYS AS IDENTITY` to `GENERATED BY DEFAULT`
  (issue #308).** The conversion moves identity from the original table to the new parent, and re-added it
  unconditionally as `BY DEFAULT`, so an `ALWAYS` column came back `BY DEFAULT`.
  - **It is a write-path change, not a catalog cosmetic.** `ALWAYS` *rejects* an insert that supplies the
    column unless the statement says `OVERRIDING SYSTEM VALUE`; `BY DEFAULT` accepts it. The downgrade
    therefore silently began accepting writes the operator's schema was written to refuse, with no error,
    no `pgpm.log` row, and nothing in `status()`. The first evidence is a row that should not exist.
  - The identity **kind** is now captured alongside the column (`pg_attribute.attidentity`, `'a'` or
    `'d'`) and replayed in the same form, in `transmute` and in `untransmute`, so a round trip is stable
    in both directions rather than stable because both ends were flattened. `untransmute`'s "transmute
    already normalises ALWAYS -> BY DEFAULT" fidelity note goes with it.
  - `tests/82` asserts the **behaviour**, not the flag: the supplied-value insert must still fail with
    `428C9`, `OVERRIDING SYSTEM VALUE` must still work, and an ordinary insert must still generate. A
    catalog assertion on `attidentity` would pass against code that set the flag without restoring the
    semantics. It opens with a liveness witness proving the fixture really has `ALWAYS` in force *before*
    the conversion, and closes with a `BY DEFAULT` control so the fix cannot over-correct in the other
    direction. Verified to fail against pre-fix code (assertions 2, 5 and 6) and pass against the fix.
- **`transmute` no longer waits indefinitely for a lock (issue #309).** It takes `ACCESS EXCLUSIVE` twice
  on the operator's live table -- phase 1's `ADD CONSTRAINT`, phase 3's `RENAME` -- and set no
  `lock_timeout` on any phase, while `maintain` has applied one at every boundary since #279.
  - **The wait was the hazard, not the lock.** Both locks are brief. But a *pending* `AccessExclusive`
    request blocks every lock request queued behind it, including plain `SELECT`s that conflict with
    nothing currently running, so one long-running query turned transmute's wait into an outage of the
    whole table, with nothing to break it.
  - New `p_lock_timeout` on both public overloads, `'5s'` by default, applied at each of the three phases
    (re-applied per phase, since `set local` does not survive a `COMMIT` -- the caution `maintain` already
    records at its own boundaries). One setting covers every wait in the cutover, which is one
    transaction: the `RENAME`, and the outgoing-FK re-add's `SHARE ROW EXCLUSIVE` on each *referenced*
    table (#263), which queues behind writers there rather than on the table being converted.
  - A bad value is refused before anything is committed, rather than from inside phase 1 or, far worse,
    phase 3 -- after the operator has already waited through the `O(rows)` validation scan. The check
    restores the previous setting, so validating the parameter does not double as applying it.
  - **Adding the parameter changed the argument count**, so `install.sql` now drops the prior arities of
    `pgpm.transmute` (both overloads) and `pgpm._transmute` first. `CREATE OR REPLACE` does not replace
    across a different arg count even when the new parameter has a default, so without the drops a
    re-install over a prior one would leave both arities defined and every existing call site ambiguous.
    That is #209/#210 exactly.
  - Guarded by `bench/transmute_lock_timeout.sh` (a second session holds a conflicting lock; the
    conversion must fail with `55P03`, leave nothing behind, and -- the liveness witness -- succeed once
    unblocked), with a `transmute_no_lock_timeout` mutation that strips the per-phase `set_config` and
    requires the guard to fail. The mutation deliberately leaves the parameter in the signature: a mutant
    that removed it too would fail the guard's `CALL` with `42883` and look like a catch for the wrong
    reason. `tests/81` covers the parameter's own contract, which the shell guard cannot: the up-front
    refusal, that it leaves no inflight row or bound `CHECK`, and that the caller's `lock_timeout` is
    unchanged afterwards.

- **`transmute` no longer silently stops enforcing an outgoing foreign key (issue #263).** A foreign key
  follows the table it is defined ON, and the conversion renames the original aside to become the monolith
  child, so the constraint landed on the monolith and never on the new parent.
  - **The loss was partial, which is what made it dangerous.** The key kept enforcing for rows routed into
    the monolith, and only rows in a FORWARD partition escaped. Measured before the fix: an insert
    referencing a row that does not exist was accepted into `ev263_p0000000000000030000`, with no error and
    nothing in `pgpm.log`. The obvious post-conversion check ("is my foreign key still there?") passed,
    because the constraint genuinely existed; it was simply scoped to one partition.
  - The captured definitions are now re-added at the parent inside the same transaction as the attach, so
    no session ever observes the parent without its keys. Replayed verbatim from `pg_get_constraintdef`, so
    composite keys, referential actions and `DEFERRABLE`-ness come along without pgpm reasoning about them.
  - **It is metadata-only.** PostgreSQL adopts a partition's equivalent already-validated foreign key
    rather than rescanning: measured at **0.8 ms against a 200,000-row monolith**, with the parent
    constraint ending up `convalidated` and the monolith's demoted to a child.
  - **A `NOT VALID` outgoing key is refused**, with the `VALIDATE CONSTRAINT` remedy. Over one of those the
    same `ADD` scans: `seq_tup_read` +400,000 at 200k rows, and 89 ms at 2M, holding SHARE ROW EXCLUSIVE on
    the table and on the referenced table. That is the data-coupled blocking lock the project's acceptance
    rule forbids, and validating on the operator's behalf would either fail on rows they never checked or
    silently promote a constraint they deliberately left unvalidated.
  - Self-referential keys are untouched here on purpose: `confrelid = p_parent` makes them **incoming** as
    well, so `p_incoming_fks` has already decided their fate (verified: such a table hits the incoming
    refusal).
  - `tests/80_transmute_outgoing_fk_test.sql`, 11 assertions, opening with a liveness witness that the
    plain table enforced the key BEFORE the conversion. Verified to fail against pre-fix code, where the
    forward-partition orphan is accepted and the row count comes out one too high as a result.

- **Deleted the adaptive-feathering surface (issue #304).** #288 removed the drain and, with it, the AIMD
  controller that paced it against WAL rate, checkpoint pressure and ambient IO/lock waiters. The machinery
  that *measured and reported on* it survived, analysing a signal nothing emits.
  - Gone: `_wal_sustainable_bps`, `_feather_congested`, `_ambient_lock_waiters`, `_ambient_io_latency`,
    `_ambient_io_surge`, `_ambient_congested`, `_ambient_surge`, `_forced_checkpoints`, `_aimd_next`, and
    the public `pgpm.feathering_validation` -- 295 lines, every one with zero call sites. Dropped via
    `drop function if exists` in the upgrade path, as `install.sql` already does for the fourteen removed
    `config` columns.
  - `observe_window` loses `drains`, `adaptive_ticks` and the per-signal `backoffs` columns, and
    `rows_moved` becomes `rows_copied`. They counted `drain_move` / `drain_budget` log actions, neither of
    which has been written since #288, so they could only ever read 0. **A reported zero that means "this
    never happens" is worse than no column, because it looks like a measurement.** `impact_report` loses its
    feathering line for the same reason; both functions otherwise stay and remain useful.
  - **CI was keeping it green by manufacturing its input.** `tests/65` and `tests/observe/db/with_pgfr_test.sql`
    each inserted synthetic `drain_budget` rows and then asserted the analysis read them correctly. Those
    assertions were true and useless: they proved the *analyser* worked, not that anything *emitted* the
    signal, so a green suite said nothing about whether the feature existed. Both now exercise real regrain
    and retention actions instead.
  - `tests/41` keeps the claim that never depended on the sensors (no pgpm function reads cross-role
    `wait_event`, so pgpm needs no `pg_monitor`) and gains one asserting the whole sensor family is gone.
  - **`bench/run.sh` was already broken**: its observe poll read `pgpm._ambient_lock_waiters()` and
    `config.drain_ambient_baseline`, a function and a column `install.sql` had already removed, so the poll
    errored rather than reporting. Its dead samples and the adaptive-feathering summary are gone, and
    `bench/run_ambient_demo.sh` is deleted -- it configured knobs that no longer exist to demonstrate a
    capability that no longer exists. `bench/plot_results.py` is untouched: it renders figures from stored
    run CSVs, which are history and still render.
  - `scripts/check_living_docs.sh` gained the newly-removed identifiers, and immediately found four
    documents still naming them (`README.md`, `docs/guide.md`, `docs/reference.md`, `bench/README.md`) --
    the guard doing exactly the job it was added for in #300.

- **`from_hypertable` no longer loses the migrated table's foreign keys (issue #264).** Outgoing keys went
  silently; incoming keys failed outright, after the entire online copy had run.
  - **Outgoing, silent loss.** `CREATE TABLE ... LIKE ... INCLUDING CONSTRAINTS` copies CHECK and NOT NULL
    only -- no `INCLUDING` option copies foreign keys -- nothing later added them, and the cutover dropped
    the source hypertable, the only relation still holding them. Measured before the fix: the constraint
    count went to 0 and an orphan row was accepted. Now each definition is replayed verbatim
    (`pg_get_constraintdef`, so composite keys, referential actions and `DEFERRABLE` come along) on the
    private copy as `NOT VALID`, validated there in its own transaction, and re-added at the new parent
    after the handoff.
  - **Validated on the copy, adopted at the parent.** A validating `ADD CONSTRAINT ... FOREIGN KEY` holds
    SHARE ROW EXCLUSIVE on the *referenced* table for the whole scan, so the `O(rows)` work is done in the
    copy phase where such work belongs, not in the cutover, whose pre-build shares a transaction with the
    swap. The parent-level add is then metadata-only, because PostgreSQL adopts a partition's equivalent
    already-validated key. **Carrying it onto the copy alone is not enough**: measured, that leaves the key
    enforcing over the monolith's range only, and an orphan routed into a forward partition was accepted.
  - **Incoming, hard failure.** An FK pointing at the hypertable puts a constraint on every chunk, so
    `drop table <source>` was refused -- and only after the whole copy, leaving the populated destination
    orphaned behind the rollback. The cutover now captures and drops those keys (which is what unblocks the
    drop) and they are re-added against the new parent after the handoff via `pgpm.dropped_fk`, reusing the
    core's `restore_incoming_fks` / `validate_incoming_fks` rather than duplicating the
    `NOT VALID`-then-`VALIDATE` dance.
  - **The residual window is stated, not hidden.** Referential integrity is off on the referencing table
    from the cutover's drop until the re-add, bounded by the swap plus one `transmute`, and surfaced by
    `status().fks_suspended`. Re-adding inside the cutover is impossible: `transmute` refuses a table that
    still carries an incoming key.
  - **Two new preflight refusals**, both before any copying: an outgoing key that is `NOT VALID` (replaying
    it would either fail validation on rows the source never checked or silently upgrade the constraint),
    and an incoming key that references anything other than the key pgpm will reuse. The second is the one
    that matters most, since the alternative is discovering it after hours of copying.
  - Tests: `tests/timescale/db/16_from_hypertable_foreign_keys_test.sql` (12 assertions, including
    enforcement in a forward partition -- which fails against a fix that carries the key onto the copy but
    never re-adds it at the parent) and two added to `01_preflight_refusals_test.sql`. Whole track green at
    114 assertions.

- **A uuidv7 grid can no longer produce a partition with `lo > hi` (issue #299).** A UUIDv7 carries its
  timestamp in the leading 48 bits, so the grid it can express stops at `2^48 - 1` ms after the epoch:
  `10889-08-02 05:31:50.65504+00`. Past that, `to_hex` returns 13 hex digits and **`lpad(..., 12, '0')`
  truncates rather than pads**, silently dropping the high nibble, so a LATER timestamp encoded as a
  SMALLER uuid:

  ```text
  _ts_to_uuid(ceiling)        -> ffffffff-ffff-0000-0000-000000000000
  _ts_to_uuid(ceiling + 1 ms) -> 10000000-0000-0000-0000-000000000000
  ```

  Monotonicity is the one property every bound-computing caller assumes. Losing it silently produced
  partition bounds with `lo > hi`, surfacing much later as PostgreSQL's `empty range bound specified for
  partition` -- an error naming neither the cause nor the ceiling.
  - **`_ts_to_uuid` now refuses** (`datetime_field_overflow`) instead of truncating. Fixed at the root, so
    no caller can receive a non-monotonic bound. The inverse needs no guard: a uuid's leading 48 bits
    cannot exceed the 48-bit maximum, so `_uuid_to_ts` always returns a representable timestamp and only
    stepping *forward* off the end is possible.
  - **`transmute` refuses up front** when the monolith's own upper bound `B` -- the grid boundary above the
    frontier -- cannot be expressed, leaving the table untouched. **`p_force_uuidv7` does not override
    this**: that override exists to let an operator vouch for a column the *sampling* misjudged, not to
    request a bound no uuid can carry. In practice it catches the same random-UUIDv4 column the sampling
    check does, from the other side.
  - **`obtain` exits cleanly** when the grid runs out rather than raising, so a table that legitimately
    advances toward the ceiling keeps working with a shorter lookahead. Deliberately not logged: obtain
    runs every tick and the condition is permanent, so logging would bury real failures under identical
    rows -- and a write past the grid is already refused loudly by PostgreSQL.
  - `tests/39_uuidv7_refused_test.sql` goes from 5 to 11 assertions and **stops being a CI flake**. It had
    asserted that `p_force_uuidv7` converts a random-uuid column; whether that blew up depended on how
    close to the ceiling the run's random maximum landed. The ceiling case now uses a crafted
    top-of-range fixture, and a new deterministic year-1990 fixture keeps the override's real remit
    covered (samples implausible, grid ordinary). Verified across 12 independent runs with fresh
    `gen_random_uuid()` data.
  - **`bench/maintain_lock.sh`: probe `lock_timeout` 1 s -> 150 ms.** Against its own mutant this guard
    scored exactly **1** timeout -- a margin of a single observation, because one attempt costs one
    timeout and only one or two fit in the blocked window. The `obtain` change above shifted timing by
    milliseconds and flipped it to 0, so `./test.sh discriminate` correctly reported the guard as
    non-discriminating. At 150 ms the same window is ~12 observations wide (measured: 8 against the
    mutant, 0 against real code) while staying ~150x above obtain's own ~1 ms lock window.

- **`pgpm.status()` no longer returns nothing when a managed table was dropped without `untransmute`
  (issue #296).** `pgpm.config.parent_table` is a `regclass` and carries no dependency on the relation, so
  a plain `DROP TABLE` on a managed parent left the config row pointing at an oid with no `pg_class` entry.
  `regclass::text` then rendered the bare oid, which `_frontier_native` interpolated into a `FROM` clause:

  ```text
  ERROR:  syntax error at or near "17379"
  LINE 1: select t.id::text from 17379 t order by t.id desc limit 1
  ```

  Because `status()` loops every config row and raised out of the whole set-returning function, **one**
  dropped table meant `status()` returned nothing at all -- for every managed table, healthy ones included.
  Dropping a managed table is off-contract, so the state is self-inflicted; what made it worth fixing is
  that the *diagnostic* was the thing that broke. Maintenance kept running (its per-step handlers absorb
  the error) and logged `skip_obtain` / `skip_write_block` / `skip_retain` every tick forever, each giving
  a syntax error as the reason, while the one tool that would explain it returned zero rows.
  - Trigger, measured and narrower than it looks: only `id`/`uuidv7` kinds reach the failing `EXECUTE`
    (`time` returns `now()` before it), and only when `config.retain` is set (otherwise `_retain_boundary`
    short-circuits first). Both conditions are ordinary.
  - **`_frontier_native` now refuses legibly**, naming the cause and the remedy instead of letting
    PostgreSQL blame a syntax error on an integer. Checked there rather than in each of its four callers,
    so `obtain`, `_retain_boundary`, `regrain_step` and `maintain` all inherit the real message. This
    deliberately sits *before* the `control_kind` branch, so a `time` table no longer sails past it to fail
    less legibly further downstream.
  - **`status()` gains `parent_missing boolean`** and reports such a row instead of dying on it.
    Everything else in the row still comes from pgpm's own catalog, so a dead parent gets a full, useful
    row; only `retain_backlog` is null, since the horizon is derived from `max(control)` read from the
    relation and there is no honest answer without it (`0` would read as "nothing is eligible", a claim
    `status()` cannot make).
  - **New `pgpm.forget_missing()`**, returning `(parent_oid, partitions_forgotten, orphan_tables)`. It
    takes **no argument** on purpose: the relation is gone so there is no name to pass, and with no
    argument it can only ever match rows whose relation is already absent, so by construction it cannot
    touch a live managed table. Not an automatic reaper -- silently deleting pgpm state would trade a loud
    failure for a silent one.
  - **It drops nothing.** A *detached* partition survives its parent's `DROP` still holding its rows
    (measured on PG 17.10), and "detached, not yet dropped" is exactly the state a referenced partition's
    retirement sits in between the cron detach and the completing drop (#268). Those tables are reported by
    name in `orphan_tables` and left in place; destroying data as a side effect of a cleanup command would
    be the worst possible reading of "forget". `pgpm.log` is left intact as the audit trail it is.
  - A second, quieter reason to clear a stale row: `pg_class` oids are recycled, so leaving one is a
    standing chance of pgpm eventually believing it manages an unrelated table that lands on that oid.
  - Tests: `tests/79_status_survives_dropped_parent_test.sql` (26 assertions), including the orphan case
    against a genuinely detached-then-orphaned partition, and a new runbook entry.

- **Retention now reclaims a partition an incoming foreign key references (issue #268).** `p_incoming_fks
  => 'preserve'` and a `retain` policy were both supported and both documented, and the combination never
  reclaimed anything: every `retain()` failed on the oldest eligible partition and returned 0, forever,
  while `retire()` had already installed the write block. The partition ended up frozen **and**
  unreclaimable -- no writes in, no storage back -- for the life of the table.
  - `DROP TABLE <partition>` is refused on a pure **catalog** dependency, and the refusal is
    data-independent: identical whether one row references it, zero rows do, or the referencing table is
    empty. `retire()` now DETACHes first, which severs the per-partition constraint and leaves the drop
    unguarded. The referencing table's own foreign key survives and still enforces. **Do not** take
    PostgreSQL's `HINT: Use DROP ... CASCADE` here: that drops the constraint and keeps the data,
    silently removing referential integrity across the whole referencing table.
  - The detach must be `CONCURRENTLY`. Measured on PG 17.10 against an 8M-row referencing table, plain
    `DETACH` holds `AccessExclusiveLock` on the **managed parent** for ~1.5 s and a concurrent read of it
    dies with `55P03`; `CONCURRENTLY` holds only `ShareUpdateExclusive` and the parent stays readable and
    writable. Retention must not block the table pgpm exists to keep online, for a duration set by a
    table pgpm does not own.
  - PostgreSQL refuses `DETACH CONCURRENTLY` from a function, a procedure that has already committed, a
    `DO` block, and dynamic `EXECUTE` -- it is a check on execution context, and pgpm is pure SQL. So
    `retire()` **dispatches** it: `pgpm.schedule()` now also creates a standing, idle `pgpm_detach`
    cron job, `retire()` rewrites its command in place (a cron command runs as a top-level statement in
    its own session, where the statement is legal), and a later call completes the `DROP` and returns the
    job to idle. **Retiring a referenced partition therefore requires `pgpm.schedule()`**; if you
    scheduled pgpm before this change, re-run it once to create the second job.
  - **The crossing** -- a live row genuinely referencing a doomed one -- is executed, not decided. pgpm
    issues `DELETE FROM <parent> WHERE <crossing keys>` and lets PostgreSQL apply whatever the operator
    declared in the foreign key: `CASCADE`, `SET NULL` and `SET DEFAULT` proceed, `NO ACTION` and
    `RESTRICT` refuse and block retention with the constraint's own error (`fail_retain_crossing`). There
    is no new knob, because the foreign key already is the policy. Identifying the crossing runs first
    and unconditionally: measured at 0.7 ms indexed and 141.9 ms unindexed, against a *failing* detach's
    1176 ms unindexed -- a near-full scan under `ShareLock` paid only to learn it cannot proceed.
  - **`pgpm._detach_reap()`**, called from `maintain_all` before the per-parent loop alongside
    `_transmute_reap`. A backend killed during a concurrent detach's *wait* phase leaves the partition
    flagged `pg_inherits.inhdetachpending` with its rows **already invisible through the parent**
    (measured: a 2,000,000-row parent read 1,000,000) -- rows vanishing from the user's table, which is
    strictly worse than the wedge this fixes. It `FINALIZE`s unconditionally but drops nothing:
    `retire()` completes pgpm's own retirements (it can tell from the new `pgpm.part.retiring_at`), and an
    operator's interrupted hand-run detach is finished and then left alone.
  - **At most one detach is in flight database-wide.** There is a single standing job, so a second
    dispatch would overwrite the first and abandon it. `retain()`'s batch loop walks every eligible
    partition and `maintain_all` walks every managed parent, so this is the ordinary path, not a race:
    without the guard one `retain()` call marked a whole three-partition backlog as retiring while only
    the last dispatch was real. A retirement stops holding the job the moment its partition is detached,
    so this yields rather than blocks -- the next tick takes the next partition. It yields only to a
    strictly **older** in-flight retirement, on a total order: "yield to any other" deadlocks, because
    two concurrent `retire()` calls can both pass the check before either marks, after which each sees
    the other and neither proceeds again. `retiring_at` is therefore set with `coalesce` and never
    refreshed by a retry -- re-stamping would make the winner perpetually the newest marker and collapse
    the order back to nothing.
  - New: `pgpm.part.retiring_at`, `status().retain_detaching`, log actions `retain_detach` /
    `retain_crossing` / `detach_reap` and failures `fail_retain_detach` / `fail_retain_crossing` (both
    counted in `status().retain_drop_failures`, since both wedge retention the same way).
  - `retire()` and `retain()` stay **functions**. `cron.alter_job` called from a non-committing function
    inside a transaction takes effect at commit, so no transaction boundary is required -- and the marker
    and the dispatch then commit atomically, leaving no window where a detach is in flight unrecorded.
  - Guarded by `bench/retire_detach_lock.sh` (the managed parent stays readable *and* writable across a
    referenced partition's retirement) with a `retire_inline_detach` mutation that swaps the dispatch for
    an in-process plain `DETACH`; `./test.sh discriminate` requires the guard to fail against it. The
    mutant is functionally identical -- the partition still ends up detached and dropped, and every
    behavioural test still passes -- so nothing but a lock probe distinguishes them.
  - Tests: `tests/77_retain_incoming_fk_test.sql` (the state machine, the crossing under both `CASCADE`
    and `NO ACTION`, the FK still enforcing afterwards, the reaper against a genuinely interrupted
    detach) and `tests/78_retain_detach_dispatch_test.sql` (the cron handoff; runs against `postgres`
    like `tests/31`, since `pg_cron` only installs there).

- **Parquet writer: add `uuid`, `json`/`jsonb`, and `numeric(p,s)`.** Six supported types
  becomes nine. `uuid` encodes as `FIXED_LEN_BYTE_ARRAY(16)` (the raw bytes `uuid_send()` already
  gives, no logical-type annotation -- readers get fixed-size binary, not a typed UUID).
  `json`/`jsonb` reuse the existing text-encoding path verbatim, tagged `ConvertedType.JSON`
  instead of `UTF8`. `numeric(p,s)` is a real Parquet DECIMAL: a scaled-integer, two's-complement,
  big-endian encoding sized to the column's own declared precision (`archive._pq_decimal_byte_width`
  computes the minimal byte width for any precision Postgres allows). Bare, unconstrained `numeric`
  (no declared precision/scale) is refused with a clear error -- Parquet DECIMAL needs one fixed
  precision/scale for the whole column, and Postgres's bare `numeric` can vary per row. Arrays and
  composite types remain out of scope (real nested/repeated-schema support, a materially bigger
  lift than adding a type).
  - `archive._pq_build_schema_leaf` gained three new optional trailing params
    (`p_type_length`/`p_scale`/`p_precision`), each omitted from the Thrift schema element when
    null -- byte-for-byte unchanged for the six original types.
  - `archive._pq_encode_column_data` gained two new optional trailing params
    (`p_decimal_scale`/`p_decimal_bytes`), used only for `numeric`.
  - Both changed arg counts, so `install.sql` now also drops the old-signature overloads
    (`archive._pq_build_schema_leaf(text,int4,int4,boolean)` /
    `archive._pq_encode_column_data(text,text,text,boolean,text)`) so re-running it over a prior
    install doesn't leave both versions coexisting as ambiguous overloads.
  - `scripts/verify_parquet.py` gained 8 new test functions (uuid/jsonb/numeric, each with a
    nullable variant, plus the bare-numeric refusal), all green first try against real pyarrow +
    DuckDB round-trips; `test_unsupported_type_refused` now uses an `int4[]` array instead of
    `jsonb`, since jsonb is supported now.

- **Rewrite `pgpm_archive/README.md` from the ground up for simplicity and concision.** The
  previous version (post the docs/ fold) had grown into an engineering narrative: architecture
  rationale ("why this lives apart from core"), internal-mechanism recitation ("the gate is gone,
  `retire()` checks coverage directly"), and "verified end-to-end" proof-of-work sections that
  don't help someone trying to use the module. Cut all of that -- most of it (the byte-budget
  chunker's mechanics, the ledger, coverage checking) was already covered properly in
  `docs/reference.md`'s "Byte-budget chunked archiving" section anyway, just re-explained in
  different words. The new README is six short sections: Install, Automatic vs. manual (a small
  comparison table replacing the old multi-section "choosing a strategy" essay), NDJSON or
  Parquet, Limits (only the constraints a user actually needs to know before hitting them), and
  Testing. ~500 lines down to ~95. No content lost that isn't already documented elsewhere
  (`docs/reference.md` for the full contract, `docs/guide.md` for the operator's view).

- **Restore a function-based operator interface for archiving; no more raw SQL as the config
  surface.** Issue #240's deletion of the old paced worker collaterally deleted its
  `archive.configure`/`unconfigure` operator interface too, regressing back to `insert into
  archive.config` / `update pgpm.config set archive_fn = ...` as the documented way to set up
  archiving -- exactly the "raw SQL as the user interface" pattern issue #233 existed to eliminate.
  Two new functions restore it, scoped to the current (schedule-free) architecture:
  - `pgpm.set_archive_fn(p_parent, p_archive_fn regprocedure default null)` in `pgpm_core`, matching
    the existing `set_regrain`/`set_drain_adaptive`/`set_drain_ambient` convention -- the operator
    switch for `config.archive_fn`.
  - `archive.configure(p_parent, p_bucket, ...)` / `archive.unconfigure(p_parent)` in
    `pgpm_archive` -- an upsert/delete on `archive.config`, guarded by a pgpm-managed check. Narrower
    than the old, deleted interface: connection settings only, no scheduling knob (there is nothing
    left to schedule now that `pgpm.maintain()` drives archiving for every managed table).
  Every README/reference/guide example and test fixture that showed raw SQL now calls these
  instead. No behavior change to the underlying columns; purely an interface restoration.

- **Fold `pgpm_archive/docs/` into `pgpm_archive/README.md`; no more docs subfolder.** The three
  pages (`strategies-overview.md`, `to-s3.md`, `chunked-parquet.md`, ~2000 lines total) are gone;
  their narrative, honest-limits, and verified-end-to-end content now lives directly in
  `pgpm_archive/README.md`, one file instead of four. The ~1000+ lines of embedded SQL those pages
  reproduced (the SigV4 signer, the multipart uploader, the from-scratch Parquet/DEFLATE/GZIP
  writer) are dropped rather than carried over: they were byte-for-byte identical to what's already
  shipped in `pgpm_archive/install.sql`, so keeping a second copy in the docs was pure drift risk
  for no benefit. The merged README points at `install.sql` by function name instead. No behavior
  change; purely a documentation consolidation.

- **Fold `pgpm_observe` into `pgpm_core`; one less optional module.** Its four functions
  (`_observe_has_pgfr`, `observe_window`, `impact_report`, `feathering_validation`) move rename-only
  into `pgpm_core/install.sql`, right after `snapshot()`; no behavior change, no new install-time
  cost (the PGFR-aware code was never install-time-coupled to PGFR -- a PL/pgSQL function body isn't
  resolved against `pgfr_analyze` until called). PGFR stays **never a dependency**: the two
  PGFR-backed functions still raise a clear error until it's installed, exactly as before.
  **Operationally breaking**: `pgpm_observe/install.sql` no longer exists; drop it from any install
  script (re-running `pgpm_core/install.sql` already brings the functions along, so nothing else
  changes). The test track follows the same split as the functions' own PGFR-optionality: the
  PGFR-absent gate (no real PGFR needed) moves into the main suite as
  `tests/65_observe_no_pgfr_test.sql`; the PGFR-present correlation, which does need a real vendored
  PGFR install, stays its own track (`tests/observe/db/with_pgfr_test.sql`, `./test.sh observe`,
  `.github/workflows/observe.yml`).

- **Retire the `prototypes/parquet-writer/` prototype; its independent-reader verification moves
  into `scripts/`, wired into CI.** Both features it was built for (the Parquet writer, #199, and
  dynamic Huffman coding, #206) had already been ported rename-only into `pgpm_archive/install.sql`;
  keeping the prototype's own copy of the SQL around any longer was just a second, drifting copy of
  already-shipped code. Its two genuinely load-bearing pieces -- `verify.py`/`verify_range.py`,
  which check `archive._pq_to_parquet`/`_range`'s output against two independent Parquet readers
  (pyarrow and DuckDB), something the pgTAP-based archive test track never did -- move to
  `scripts/verify_parquet.py`/`verify_parquet_range.py`, retargeted to call the real shipped
  `archive._pq_*` functions directly (no more local install step) against `pgpm_core`+
  `pgpm_archive` installed by `test.sh`'s own `run_archive()`. `./test.sh archive` now runs both,
  in a venv (`scripts/requirements-verify.txt`), right after the pgTAP suite, against the same
  running instance -- closing a real gap the archive test track's own docs had flagged (no
  independent-reader re-verification of a real compressed Parquet object). The now-redundant
  fixed-vs-dynamic-Huffman comparison tests (meaningful during #206's own development, not for
  ongoing regression coverage, since production exposes no such toggle) were folded into the
  plain compressed-output tests instead of duplicated. `prototypes/` (the whole tree) is deleted.

- **Docs/CI: describe the retention/archiving merge as it now actually works; breaking change
  (#241).** Closes out the stack #242-#240 built: `pgpm.hook` and `pgpm_archive`'s old paced-worker
  scanning apparatus (`archive.tick`/`file_gate`/`configure`/`schedule` and friends) are gone, and
  archiving is configured per table via `pgpm.config.archive_fn` -- a partition only drops once it
  is write-blocked and, if `archive_fn` is set, fully archived. **Breaking**: any table that relied
  on `pgpm.hook_register`/`archive.configure`/`archive.schedule` for archiving-before-drop needs to
  set `config.archive_fn` instead; there is no migration shim (pre-1.0, no live installs, #217's
  precedent).

  - `pgpm_archive/docs/assistant.md` (the partition-aligned, `archive.tick`/`file_gate`-driven paced
    worker) is deleted outright, not banner-and-keep: every function it documented is gone with no
    successor (the `archive_fn` contract only ported the byte-budget rule, #237, never the
    partition-aligned one), so there is nothing left for it to point at.
  - `pgpm_archive/docs/chunked-parquet.md` and `docs/strategies-overview.md` are rewritten to
    describe the current, much smaller design space: `config.archive_fn`'s built-in byte-budget
    strategy (automatic, drop-gated) versus the synchronous `archive.to_s3`/`archive.to_s3_parquet`
    functions (manual, no automatic tie to a drop). The old "two knobs, four configurations" table
    (boundary rule x drop-trigger rule) and the module name-mapping table are both gone -- there is
    only one built-in strategy now, and its names never diverged from the module's own.
  - `pgpm_archive/docs/to-s3.md` and `pgpm_archive/README.md` drop every `pgpm.hook_register`/
    `archive.configure`/`archive.schedule` reference; the synchronous functions are reframed
    honestly as **not** gating a drop on their own (a real behavior change from the old
    hook-based design, where a failed copy blocked the drop automatically) -- `config.archive_fn`
    is now the path for that guarantee.
  - `docs/guide.md`'s "Pre-drop hooks" section is replaced with "Archiving before a drop", describing
    `config.archive_fn` directly; `docs/runbook.md` and `ONBOARDING.md` had their own stale
    `retain_hook_failures`/`archive.config` shape references fixed to match #238's renames and
    #240's column drops.
  - `test.sh`'s `archive` track no longer provisions a disposable database per test file: nothing
    in `tests/archive/db/*.sql` commits internally anymore (the old paced worker's internal commits
    were the only reason it needed to), so it now installs once and runs every file via `pg_prove`
    against one shared database, each wrapped in its own `BEGIN`/`ROLLBACK` -- the same pattern the
    default channel matrix already uses. `tests/archive/db/04_parquet_and_sync_hook_test.sql` is
    renamed to `04_parquet_and_sync_archive_test.sql` ("hook" no longer being the right word for a
    plain function call).
  - Backfills the `CHANGELOG.md` entries #239 and #240 should have landed with (below), which this
    issue's own audit found missing.

- **Port `archive.to_s3`/`archive.to_s3_parquet` onto the `archive_fn` contract (#239).**
  `pgpm.archive_to_s3_ndjson`/`pgpm.archive_to_s3_parquet` (in the `pgpm` schema, defined in the
  optional `pgpm_archive/install.sql`) adapt the existing synchronous functions' transport onto
  `pgpm.config.archive_fn`'s calling contract, so a table can ride `pgpm.maintain()`'s own
  byte-budget chunking (#237) instead of a separate schedule. Both delegate to the exact same
  encode/upload steps the synchronous functions already use
  (`archive._encode_upload_ndjson_single`/`archive._encode_upload_parquet`) and read connection
  settings from the same `archive.config` row, so there is no second, independently configured
  surface. `archive._encode_upload_ndjson_commits` (the third format, with internal `COMMIT`s) has
  no `archive_fn` counterpart and cannot: `archive_fn` is a plain function, and PL/pgSQL forbids
  transaction control inside one regardless of call context -- it does not need one anyway, since
  `pgpm._next_archive_chunk` already bounds every call to `config.archive_byte_budget` before
  `archive_fn` ever runs. Widens `pgpm.archive_result` (`covered_hi`, `rows_archived`) to also carry
  `s3_key`/`etag`, threaded through `pgpm._archive_step`'s ledger insert -- closing the gap #237's
  own comment flagged ("`s3_key`/`etag` stay null until a real strategy has something to put
  there"). New `tests/archive/db/08_archive_fn_s3_test.sql` (10 assertions, against real MinIO):
  both strategies dispatch via `config.archive_fn`, chunk via `pgpm.maintain()`, ledger every chunk
  with a non-null `s3_key`/`etag`, and the uploaded NDJSON object round-trips exactly through a
  direct MinIO fetch.

- **Delete the old paced worker and `pgpm.hook` entirely (#240).** Cutover: everything the old
  paced/`self_driving` apparatus existed to do -- pick ranges, record a ledger, gate a drop on a
  recount, drive the drop itself on a schedule -- is now done by the unified `archive_fn` path
  (#235-#239). Deletion only, no new behavior. Deleted from `pgpm_archive/install.sql`:
  `archive.tick`, `_tick_one`, `_next_range_partition_aligned`, `_next_range_byte_budget`,
  `_retire_covered`, `file_gate`, `_file_watermark`, `archive_range`, `archive_partition`,
  `run_all`, the `archive.ledger` table, and the `archive.configure`/`unconfigure`/`schedule`/
  `unschedule` operator interface (#233), along with the `pgpm-archiver` pg_cron job they
  registered. `archive.config`'s `boundary_rule`/`drop_trigger`/`format`/`byte_budget`/
  `probe_sample` columns are dropped (`ALTER TABLE ... DROP COLUMN IF EXISTS`, upgrade-safe);
  `part_bytes`/`fetch_rows` stay, still used by `archive.to_s3`'s own multipart chunking. Deleted
  `pgpm.hook`/`hook_register`/`hook_unregister` from `pgpm_core` entirely: `retire()` stopped
  consulting it in #238, and #239 gave `archive.file_gate` -- its last real registrant -- a
  replacement on the `archive_fn` contract, so nothing depended on it anymore. `archive.to_s3`/
  `archive.to_s3_parquet` (the synchronous functions) and `pgpm.archive_to_s3_ndjson`/
  `archive_to_s3_parquet` (the `archive_fn` strategies, #239) are untouched and keep working
  exactly as before. Deleted `tests/58` (`pgpm.hook` mechanics, the registry it tested no longer
  exists) and `tests/archive/db/01/02/03/05/06/07` (each tested exactly the deleted
  paced-worker/operator-interface/hook surface); rewrote `tests/archive/db/04` to call
  `archive.to_s3_parquet` directly with no hook registration; stripped the now-impossible
  `pgpm.hook` assertions from `tests/62` and fixed dangling `tests/58` cross-references in
  `tests/59`/`60`/`64`/`63`.

- **`pgpm.retire()`: drop only once write-blocked and archive-covered; `pgpm.hook` no longer
  consulted (#238).** With write-blocking (#235) and ledger-driven archive coverage (#237) both in
  place, `retire()`'s drop precondition becomes fully internal: past the retention boundary (as
  before), write-blocked (ensured here via idempotent `pgpm._install_write_block`, not merely
  assumed -- `retire()` is called by more than one path, and asserting instead of ensuring would
  make it raise for any caller that reaches an eligible partition without `maintain()` having run
  first), and `pgpm._archive_fully_covered`. A not-yet-covered child is a normal, retryable state,
  not a failure: `retire()` returns `false` and logs nothing, the same as an already-retired or
  concurrently-claimed partition. Only a genuinely unexpected `DROP` failure is logged
  (`retain_drop_fail`, replacing `retain_hook_fail`; `status()`'s `retain_hook_failures` is renamed
  `retain_drop_failures` to match what it now actually measures).

  `pgpm.hook`'s `pre_drop` loop is removed from `retire()` entirely -- nothing in `pgpm_core` calls a
  registered hook anymore. **`pgpm.hook`/`hook_register`/`hook_unregister` are deliberately NOT
  dropped**: `pgpm_archive`'s existing gate-only architecture still registers `archive.file_gate`
  through them, and removing the table/functions now would break that before `pgpm_archive` migrates
  onto the `archive_fn` contract (#239/#240). A registered hook simply never runs anymore; full
  removal is #240's job. This is a real, known regression for `pgpm_archive`'s `gate_only` and
  `self_driving`-with-a-failing-hook scenarios in the meantime (documented in
  `pgpm_archive/README.md` and `docs/strategies-overview.md`; `tests/archive/db/01` and `06` are
  `skip()`ped with a clear reason rather than rewritten, since re-expressing those scenarios on the
  new contract is #241's job, not this one's).

  Rewrote `tests/58` (proves a registered `pre_drop` hook, even one that always raises, no longer
  blocks anything -- the opposite of what it proved before this issue), `tests/59` (the `retain_batch`
  wedge demonstration now uses a not-yet-archive-covered child instead of a failing hook, and
  explicitly asserts `retain_drop_failures` stays zero throughout -- the key new distinction), and
  `tests/60` (removed hook-blocks-a-drop assertions; added write-block-ensured and
  archive-coverage-gate assertions). New `tests/64_retire_archive_gate_test.sql` (8 assertions, the
  issue's own test plan): a child crosses the boundary, is write-blocked immediately but stays
  undropped while chunked archiving is still incomplete, and drops the moment coverage completes (in
  the very same tick); a `none`-strategy child drops on the very next eligible cycle, exactly as
  `retain()` always behaved before this whole stack existed.

- **Docs: `docs/retention-write-block-and-merge.md`, the positioning doc for a retention/archiving
  merge stack (#242).** Chunked archiving (#213, #221) can now take several `maintain()` ticks to
  fully archive one large partition, and nothing today stops a backdated write into that
  still-attached, still-writable span -- `archive.file_gate`'s recount only catches the divergence
  reactively, after the fact. The doc lays out the fix (a `BEFORE INSERT OR UPDATE OR DELETE`
  trigger that write-blocks a partition the instant it crosses the retention boundary, independent
  of archiving), the two mechanisms ruled out first with the concrete evidence (`REVOKE` only
  checks the parent's ACL on a parent-routed write; a spanning lock defeats the point of chunking),
  the target end state (a pluggable `archive_fn` contract on `pgpm.config`, ledger-driven chunked
  archiving as the built-in strategy, a unified `retire()` drop precondition, `pgpm.hook` retired),
  and the implementation order for #235-#241 that follow it. Also settles the module-split question
  from the prior harmonization stack (#217-#222): the dependency surface a hard `pgpm_core`/archive
  split would leave behind isn't small enough to be worth it, so `archive` stays a namespace inside
  the same install, not an independently versioned module. Documentation only -- no code changes,
  no behavior changes; every mechanism the doc describes is still a plan.

- **Port byte-budget chunked archiving and its ledger onto the `archive_fn` contract (#237).**
  `pgpm_archive`'s `archive._next_range_byte_budget`/`archive.archive_range`/`archive.ledger`
  (#213, #221) proved that archiving a large partition safely means chunking it instead of doing it
  as one giant operation; this ports that mechanism, unchanged in intent, onto `pgpm.config.archive_fn`
  (#236) and the write-block trigger (#235). New `pgpm.archive_ledger` (successor to
  `archive.ledger`, same shape: `parent_table`, `lo`, `hi`, `child_name`, `s3_key`, `etag`,
  `rows_archived`, `archived_at` -- `s3_key`/`etag` stay null until a real transport strategy, #239,
  has something to put there). New `pgpm._next_archive_chunk(p_parent, p_child)` picks the next
  chunk within one already-write-blocked child's own `[lo, hi)` (the one real adaptation from the
  original, which picked ranges across the whole table since nothing else gated eligibility yet --
  here that gating is the write-block trigger's job). New `pgpm._archive_fully_covered(p_parent,
  p_child)`: true once the ledger's ranges for that child reach its own `hi`, or the strategy is
  `none` -- the intended `retire()` drop precondition once #238 wires it in, not consulted by
  anything yet. New `pgpm._archive_step(p_parent)` -- one `maintain()` tick's worth: for every
  attached child that **already has the write-block trigger installed** (checked directly against
  `pg_trigger`, never re-derived from the boundary formula) and is not yet fully covered, picks its
  next chunk, runs `pgpm._run_archive_strategy`, and records the result. `pgpm.maintain()` now runs
  this right after write-blocking, ahead of `retain()`; its summary gains an `archived=N` field.
  `archive.ledger`/`archive.archive_range`/`archive.tick` in `pgpm_archive` are completely untouched
  and keep working exactly as before -- they are deleted only once this path replaces them (#240).
  New `tests/63_archive_chunk_ledger_test.sql` (14 assertions): a multi-chunk partition archives
  across several `maintain()` ticks with bounded per-tick progress; `_archive_fully_covered` flips
  true only once the last chunk lands; resuming across ticks never duplicates or skips a range; a
  child holding real data but not yet write-blocked is never touched even though `archive_fn` is set
  for the whole table; a `none`-strategy table is immediately fully covered with nothing ever
  ledgered. Caught and fixed one real bug along the way: `archive_ledger.hi` is `text`, so a plain
  `max(hi)` compares lexicographically (`'91' > '1000'`) instead of numerically/temporally --
  `_next_archive_chunk`/`_archive_fully_covered` now cast to the native type first, the same fix
  `archive._file_watermark` already needed for the identical reason.

- **Write-block a partition the instant it crosses the retention boundary (#235).** Chunked
  archiving can take several `maintain()` ticks to fully archive one large partition, and for the
  whole span between crossing `_retain_boundary()` and the last chunk landing, the partition sat
  attached and, with nothing to stop it, fully writable -- a backdated write into that span,
  including into a range some earlier chunk already archived and ledgered, would silently diverge
  the archive from what is live. `REVOKE` on the child does nothing (a parent-routed write is
  checked against the *parent's* ACL, never the child's), and a lock spanning the whole archiving
  window defeats the reason chunking exists, so instead: a `BEFORE INSERT OR UPDATE OR DELETE`
  trigger (`pgpm._install_write_block`) is installed on a child the moment its whole range is
  at/below the horizon, and removed (`pgpm._remove_write_block`) if an operator loosens
  `config.retain` and the child becomes ineligible again -- both idempotent, so a repeat
  `_enforce_write_blocks` tick never raises a duplicate-trigger error. `pgpm.maintain()` now runs
  `_enforce_write_blocks` every tick, ahead of `retain()`'s own drop logic. Purely additive: not
  wired into `retire()`'s drop precondition yet (that's #238), and `pgpm.hook` is untouched -- a
  write-blocked partition still drops exactly as before, the trigger going with the table on
  `DROP TABLE`. New `tests/61_write_block_test.sql` (22 assertions): a child crossing the boundary
  gets the trigger; parent-routed and direct-to-child inserts, updates, and deletes are all
  rejected; a sibling child still under the boundary is unaffected; reads through the parent are
  unaffected; re-running `maintain()` is idempotent; loosening `config.retain` removes the trigger.
  First rung of the retention/archiving merge stack positioned in #242
  (`docs/retention-write-block-and-merge.md`).

- **`pgpm.config.archive_fn`: a pluggable archive strategy contract, the first step toward
  replacing `pgpm.hook`'s `pre_drop` registry (#236).** `pgpm.hook` is generic (any event, any
  number of hooks) but has only ever had one real use: archiving before a drop. `archive_fn` is a
  nullable `regprocedure` column narrowing that to one archive strategy per managed table (`null` =
  strategy `none`, immediately drop-ready) -- casting the reference validates the function exists
  with exactly this signature at assignment time, not later when a maintenance tick tries to call
  it, the same reasoning `hook_register`'s `p_hook` parameter already uses. The calling contract:
  `archive_fn(p_parent regclass, p_child name, p_lo text, p_hi text) returns pgpm.archive_result`
  (`covered_hi text, rows_archived bigint`), expected to be **resumable** -- called once per tick,
  making bounded incremental progress and reporting how much of `[p_lo, p_hi)` is now durably
  archived, not finishing the whole range in one call. New `pgpm._run_archive_strategy` dispatches
  to `config.archive_fn` (or synthesizes an immediate "already covered" result for the `none`
  strategy); new `pgpm._archive_noop` is a trivial built-in strategy that exists only to exercise
  real dispatch (an actual regprocedure call, not the null special case) in tests. Schema and
  contract only: nothing yet calls `_run_archive_strategy` from `retire()`/`retain()`, and
  `pgpm.hook` is completely untouched -- both continue to work exactly as before. New
  `tests/62_archive_fn_contract_test.sql` (10 assertions). Positioned in #242
  (`docs/retention-write-block-and-merge.md`), the next rung after #235's write-block trigger.

- **`archive.configure`/`archive.unconfigure`/`archive.schedule`/`archive.unschedule`: a real
  operator interface for `pgpm_archive`, replacing raw SQL against `archive.config` and a bare
  `cron.schedule` call.** Normal operation should never need a hand-written `insert`/`update`
  against a catalog table -- `archive.configure(parent, bucket, ...)` upserts a table's connection
  settings and knobs (an idempotent, re-callable setup, same shape as `pgpm.transmute`'s
  many-named-parameters-with-defaults style), `archive.unconfigure(parent)` removes them, and
  `archive.schedule`/`unschedule` wrap `cron.schedule_in_database` exactly the way
  `pgpm.schedule`/`unschedule` already do (same guard when `pg_cron` isn't installed, same
  idempotent re-scheduling). Deliberately does *not* also register a `pre_drop` hook: which one
  (`archive.file_gate` for the paced worker, `archive.to_s3`/`archive.to_s3_parquet` for the
  synchronous hook) depends on which architecture a table uses, so that stays its own explicit
  `pgpm.hook_register` call. New `tests/archive/db/07_configure_and_schedule_test.sql` (13
  assertions); `tests/archive/fixtures.sql`'s `mk_archive_config` now calls `archive.configure`
  instead of its own raw insert, and every doc/`README.md` snippet showing the old
  `insert into archive.config` pattern was updated to match.

- **Move the archive docs under `pgpm_archive/` and stop referencing archival from the root
  `README.md`.** Archiving to S3 is a downstream concern from partition lifecycle management, not
  part of `pg_partition_magician` core -- it started as worked examples embedded in markdown and
  later graduated into an installable module, but the root README had kept linking to it as though
  it were a core feature. Fixed: the four archive docs (`archive-strategies-overview.md`,
  `archive-to-s3.md`, `archive-assistant.md`, `archive-chunked-parquet.md`) moved from `docs/` to
  `pgpm_archive/docs/` (`strategies-overview.md`, `to-s3.md`, `assistant.md`, `chunked-parquet.md`),
  every cross-reference among them and from `docs/guide.md`/`docs/reference.md`/
  `prototypes/parquet-writer/README.md`/`pgpm_archive/install.sql` updated to match; the root
  `README.md`'s "Documentation" section no longer mentions archiving at all. In their place,
  `pgpm_archive/README.md` is a new front door -- what the module is, why it's separate from core,
  install + configure + register in one place, the two-architecture picture, and links into its own
  `docs/`. Together, these leave `pgpm_archive/` reorganizable into its own repo with near-zero
  further effort, which was the whole point.

- **Point `docs/archive-*.md` at `pgpm_archive/install.sql` as the installable source of truth
  (#222, 3 of 3 -- closes the six-issue archive harmonization stack, #217-#222).** The three
  implementation pages (`archive-to-s3.md`, `archive-assistant.md`, `archive-chunked-parquet.md`)
  and the overview (`archive-strategies-overview.md`) keep every line of hand-rolled SQL, their
  original names, and everything they verified exactly as written -- they remain the design
  rationale, the honest limits, and the live-verification story. Each of the three implementation
  pages gets a short callout near its top plus an updated "Install"/"Register and pace it" section
  showing the module-based path (install `pgpm_archive/install.sql`, configure one `archive.config`
  row per table) as the recommended way to deploy, with the original hand-rolled instructions kept
  as the alternative. `archive-strategies-overview.md` gets a new "Installing the module" section
  with the full name-mapping table (`archive.partition` -> `archive.archive_partition`,
  `archive.scan()` -> `archive.tick()`, `archive._chunk_one` -> `archive._tick_one`,
  `archive.chunk_all` -> `archive.run_all`, `c_self_driving`/`c_format`/`c_compress`/... ->
  `archive.config` columns), and its "Positioning" section now reflects that #222 actually closed
  the "two entry points remain unmerged" gap that section used to flag as still open.

- **Permanent CI infrastructure for `pgpm_archive` (#222, 2 of a planned 2-3 PR sequence):
  a `./test.sh archive` track, replacing the ad hoc Postgres 17 + `pgsql-http` + MinIO harness
  #217-#221 and #222's first PR were hand-verified against.** The shared `Dockerfile` grows an
  opt-in `WITH_PGSQL_HTTP` build arg (default `false`, so the existing pg15-18 matrix images are
  byte-for-byte unaffected); `docker-compose.yml` grows a `minio` service and an `archive` PG17
  service (own profile, excluded from `all`, matching the `timescale` service's own pattern).
  `test.sh` gets a `run_archive` function modeled on `run_timescale`'s disposable-database-per-file
  shape, not `run_observe`'s begin/rollback shape: `archive.tick()` and
  `archive._encode_upload_ndjson_commits` commit internally, and PL/pgSQL only allows that when the
  call chain traces to a top-level `CALL`, which rules out wrapping them in `begin`/`rollback` (or
  in any pgTAP assertion function -- `lives_ok`/`throws_ok` are themselves functions, so a
  commit-issuing procedure must be invoked as a bare top-level `CALL`, its success proven by
  separate assertions afterward, not by the wrapper).

  New `tests/archive/fixtures.sql`: a `vault.decrypted_secrets` stub (the module reads S3
  credentials via Supabase Vault's public view; the test image is plain Postgres with no
  pgsodium/Vault available) seeded with the test MinIO's root credentials, plus small
  managed-table and `archive.config`-row builders wired to the harness's MinIO bucket/endpoint. Six
  `tests/archive/db/*.sql` pgTAP files cover the worker end to end: the happy path via
  `archive.tick()` (`gate_only`), a `self_driving` table dropping partitions in the same `tick()`
  call that archived them, the `byte_budget` boundary rule chunking a span that does not align to
  any partition, the `parquet` format plus the structurally separate synchronous
  `archive.to_s3_parquet` hook, the forward-only guard on `archive.archive_partition`, and --
  the highest-value regression -- the unconditional retire sweep fix from #222's first PR, proven
  the same way it was live-verified there: a second `pre_drop` hook fails one partition's drop, a
  first `tick()` leaves it stuck while archiving and retiring the other two, and a second `tick()`
  -- with nothing new to archive -- still retries and drops it.

  A standalone, path-filtered `.github/workflows/archive.yml` runs the new track on push/PR
  touching `pgpm_archive/install.sql`, `pgpm_core/install.sql`, `tests/archive/**`, or the harness
  itself, mirroring `observe.yml`'s non-gating model (not wired into `test.yml`/`release.yml`),
  since archival is fully optional user-land and depends on external MinIO infrastructure that
  should not gate releases. Verified locally end to end (`./test.sh archive`, all green) and that
  `WITH_PGSQL_HTTP` defaulting to `false` is a true no-op for the existing matrix
  (`./test.sh 17`, unaffected).

  Next in this sequence: update the existing `docs/archive-*.md` pages to point at this module as
  the installable source of truth, keeping their narrative, honest-limits, and live-verification
  write-ups.

- **New `pgpm_archive/install.sql`: the archival harmonization stack (#217-#221), packaged as a
  real, installable, optional add-on (#222, 1 of a planned 2-3 PR sequence).** Mirrors
  `pgpm_hypertable/`/`pgpm_observe/`'s existing shape (one `install.sql`, no config table of its
  own to copy from -- both siblings take parameters directly or read an external catalog, so the
  config table here is a genuine new design, not a port). Ports every `archive.*` object out of
  `docs/archive-to-s3.md`/`archive-assistant.md`/`archive-chunked-parquet.md`'s embedded SQL
  (58 functions/procedures, verbatim where unchanged) into one file, replacing every
  "deployment constants: edit these N" block with one real table, `archive.config`: one row per
  managed table, carrying connection settings (bucket/region/endpoint/prefix/vault secret names)
  and the three knobs the harmonization stack built (`boundary_rule`, `drop_trigger`, `format` +
  `compress`).

  This is also where the stack's own remaining gap finally closes: `archive.partition` and
  `archive._chunk_one` -- kept as two separate, hand-built entry points through #217-#221
  specifically to avoid packaging today's two-implementation shape twice -- are now one truly
  unified worker. `archive.archive_range`/`archive.archive_partition` do the actual archiving
  (dispatching to whichever encode/upload step `archive.config.format` names); `archive._tick_one`
  picks the next range per `archive.config.boundary_rule`; `archive.tick()` (the standing pg_cron
  entry point) and `archive.run_all(parent)` (the operator's "do it now") both work for every
  table regardless of which knobs it's configured with.

  Building the true unified worker surfaced one more real gap, caught live before shipping:
  #220's self-driving retire only ever ran right after a fresh chunk was archived, so a
  byte-budget-aligned table that quiesced (no new data, so no new chunks, ever) could never retry
  a partition whose `retire()` failed once for a reason unrelated to archiving -- the same
  category of gap #219 already fixed for the partition-aligned rule specifically, just not
  generalized to the other one. Fixed by running the retire sweep unconditionally, every tick, for
  every self-driving table, regardless of whether that table archived anything new this cycle.
  Reproduced live: registered a second `pre_drop` hook that fails one specific partition's drop
  (simulating an unrelated external failure), confirmed it stayed stuck through one `tick()` call
  that successfully archived and retired everything else, removed the failing hook, and confirmed
  a *second* `tick()` call -- with nothing new to archive, watermark unchanged -- still retried and
  correctly dropped the previously-stuck partition.

  Live-verified end-to-end against the same Postgres 17 + `pgsql-http` + MinIO harness used for
  #217-#221: all four boundary-rule x drop-trigger-rule combinations plus both new format
  cross-combinations, driven entirely through `archive.config` rows; the tie-break fix and the
  forward-only guard, unaffected by the config-driven rewiring; and the synchronous hooks
  (`archive.to_s3`/`archive.to_s3_parquet`) reading their connection settings from
  `archive.config` too, for one consistent configuration story across every archival strategy in
  the module. `install.sql` applies cleanly from empty and re-applies idempotently.

  Next in this sequence: permanent CI infrastructure (a MinIO service, a `pgsql-http`-enabled test
  image, a `./test.sh archive` track, `tests/archive/`'s pgTAP suite) to replace the ad hoc harness
  this PR (and #217-#221) verified against by hand; then the existing `docs/archive-*.md` pages
  updated to point at this module as the installable source of truth, keeping their narrative,
  honest-limits, and live-verification write-ups.

- **Docs: pluggable encode/upload step for the paced worker -- format x compression x commit
  strategy (#221, closes #213, #214).** The last hardwired piece after #217-#220: *how* a range
  becomes bytes and lands in S3. Adds three shared, matching-shaped steps -- `(p_parent, p_lo,
  p_hi, p_compress)` in, `(s3_key, etag, rows_archived)` out -- defined once in
  `docs/archive-assistant.md`'s "The archiver": `archive._encode_upload_ndjson_single` (one read,
  one `PUT`, optionally one gzip member), `archive._encode_upload_ndjson_commits` (the per-part-
  commit technique, generalized off any range instead of always exactly one partition), and
  `archive._encode_upload_parquet` (a thin wrapper around the chunker's own range encoder). Both
  `archive.partition` and `archive._chunk_one` get a `c_format` constant dispatching to whichever
  step is configured (`'ndjson_commits'` / `'parquet'` respectively by default, unchanged); Parquet
  with internal commits is named explicitly as impossible, not a gap -- its footer needs every row
  group's byte offset, known only once the whole file exists.

  Generalizing the per-part-commit reader past "always one partition" surfaced a real,
  previously-latent bug, not just a mechanical lift: the original ordered its keyset pagination by
  the control column alone with a strict `>` resume predicate, correct only if no two rows share a
  control-column value across a page boundary. Reproduced directly -- a 21-row, time-kind fixture
  (mostly 3-4 rows per timestamp) read page-by-page with the original query returned only 16 of 21
  rows, 5 silently dropped at a page boundary tie. Every prior test of `archive.partition` had used
  a unique id-kind control column, where this gap can never manifest. Fixed by ordering and
  resuming on a `text[]` of `(control column, real key columns)` -- Postgres compares arrays
  lexicographically, so this is a genuine composite tiebreak without dynamic-arity `ROW()`
  construction -- using `archive._key_columns` (relocated from `archive-chunked-parquet.md` to
  `archive-to-s3.md`, since both the Parquet and NDJSON range readers need the identical key
  discovery now). The same fixture through the fixed reader returned all 21 rows, verified by id.

  Compressing an NDJSON-with-commits range gzips each part independently and lets S3 multipart's
  own byte-range concatenation produce the final object -- a valid multi-member gzip stream (RFC
  1952 permits concatenating independent gzip members; standard decompressors read through all of
  them transparently) -- verified against a 30,000-row fixture forced into several 6MiB+ parts,
  decompressing cleanly with a stock `gunzip` into all 30,000 rows, no loss or duplication.

  Live-verified end-to-end: the unchanged defaults for both pages; the two newly-possible
  combinations (`archive.partition` with `c_format := 'parquet'`, `archive._chunk_one` with
  `c_format := 'ndjson_single'`); the tie-break bug reproduced and then confirmed fixed;
  compression on the commits variant; and the #218 forward-only guard and #220 self-driving retire
  both unaffected by the new dispatch layer. The S3 key naming changed as a side effect of no
  encode/upload step knowing a child name anymore: newly archived objects are now keyed by
  `(parent, lo)` rather than `(child name)` -- already-archived objects and their ledger rows are
  unaffected.

- **Docs: add a drop-trigger toggle (gate-only vs self-driving) to the paced worker (#220).** Fills
  the two previously-unbuilt cells in `docs/archive-strategies-overview.md`'s boundary-rule x
  drop-trigger-rule table. Adds a shared `archive._retire_covered(p_parent, p_up_to)` procedure
  (kind-aware, claim-guarded via `pgpm.retire()`, one `commit` per drop) that retires every
  attached partition whose bounds fit inside `p_up_to`. Both `archive.scan()` and
  `archive._chunk_one` get a `c_self_driving` deployment constant: `archive.scan()` defaults to
  `true` (unchanged, self-driving) and can be set `false` for gate-only, becoming a pure archiver
  that leaves drop timing to `retain()`'s own schedule; `archive._chunk_one` defaults to `false`
  (unchanged, gate-only) and can be set `true` to call `archive._retire_covered` with the chunk's
  own newly-advanced watermark right after its ledger row commits -- the byte-budget-aligned,
  self-driving configuration [#212](https://github.com/dventimisupabase/pg_partition_magician/issues/212)
  asked about, generalized to both boundary rules at once. `archive.scan()`'s retire sweep was
  also simplified in the same change: it now loops managed tables directly and calls the shared,
  committing `archive._retire_covered` per table, rather than materializing every table's targets
  into one list first (a live cursor calling a committing procedure per iteration is exactly the
  pattern PG11 added transaction control in procedures to support). Live-verified all four
  boundary-rule x drop-trigger-rule combinations: the assistant self-driving (unchanged) and
  gate-only (new, archives without retiring, `retain()`+`archive.file_gate` pick up the drop
  later); the chunker gate-only (unchanged) and self-driving (new, retires three partitions in one
  call right after a chunk that happened to span all three); and the restructured retire sweep
  across two managed tables in one `archive.scan()` call.

- **Docs: extract the paced worker's boundary rule as a pluggable step (#219).** Factors "pick the
  next range to archive" out of both archivers into two matching-shaped functions --
  `archive._next_range_partition_aligned(p_parent)` (the assistant's existing eligibility logic:
  the first attached, retention-eligible partition whose ledger row is missing or stale) and
  `archive._next_range_byte_budget(p_parent, c_byte_budget, c_probe_sample)` (`archive._chunk_one`'s
  existing byte-budget computation, unchanged) -- both `(p_parent)` in, `(lo, hi)` or no rows out.
  `archive._chunk_one` now calls the byte-budget picker instead of inlining its computation, with
  byte-identical results (re-verified: single-file and 334-file/5,000-row fixtures, same ranges,
  same counts, same gap-free contiguity). `archive.scan()` now calls the partition-aligned picker
  in a loop until exhausted for the archiving half of its work, with one honest, deliberate
  restructuring: archiving and retiring are no longer interleaved per partition -- the picker drains
  first, then the existing retire sweep (unchanged) attempts every eligible partition, not just the
  ones just archived. Re-verified this preserves the one guarantee that split had to keep: a
  partition archived on an earlier cycle but left un-retired (a drop deferred for a reason unrelated
  to archiving) is correctly *not* re-archived by the picker but still retried by the retire sweep.
  Stale-veto self-repair and the #218 forward-only guard were both re-run through the new
  picker-driven call path with identical results.

- **Docs: unify `archive.gate` and `archive.file_gate` into one gate (#218).** `archive.file_gate`
  (`docs/archive-chunked-parquet.md`'s fast-path-watermark-plus-decrement veto) replaces the
  retired `archive.gate` (`docs/archive-assistant.md`'s simpler per-child recount) everywhere; both
  pages now register the identical function, defined once alongside the ledger in
  `docs/archive-assistant.md`'s "The ledger and the gate". Live verification against a Postgres 17,
  `pgsql-http`, and MinIO harness caught a real gap before it shipped: `archive.gate` looked up one
  partition by `child_name`, independent of anything else, so nothing could fool it; swapping in
  `archive.file_gate` unmodified let a later partition archived out of order (bypassing
  `archive.scan`'s own in-order sweep) push the shared watermark past an earlier, still-unarchived
  partition, and `pgpm.retire()` dropped that earlier partition **with no error and no log entry**.
  Fixed with a forward-only guard in `archive.partition`: it now refuses to write a ledger row out
  of order (exempting a legitimate re-archive of an already-ledgered, stale partition), the same
  discipline `archive._chunk_one` already keeps by construction. Re-verified end-to-end: happy path
  and both vetoes with `archive.file_gate` registered on the assistant's own tables, the
  out-of-order sequence now failing fast instead of silently dropping unarchived data, and a second
  table run through the chunker concurrently with no cross-talk in the shared ledger.

- **Docs: unify `archive.ledger` and `archive.file_ledger` (#217).** The archive assistant
  (`docs/archive-assistant.md`) and the chunked Parquet archiver (`docs/archive-chunked-parquet.md`)
  each recorded the same underlying fact -- a `[lo, hi)` range of the control column durably
  archived to an S3 key -- in two different table shapes, one keyed by `child_name` and one by
  `lo`. A partition's own bounds are already a native-grid `[lo, hi)` range, so `archive.ledger`
  now adopts `archive.file_ledger`'s shape (`lo` as the primary key) with `child_name` kept as an
  optional, nullable convenience column populated only when a range happens to equal exactly one
  partition's bounds; `archive.file_ledger` is gone (nothing was deployed against either shape
  yet, so there was no migration to preserve). `archive.partition` now looks up its partition's
  `lo`/`hi` from `pgpm.part` before writing the ledger row.
  `archive.gate`, `archive.scan`, `archive._file_watermark`, `archive.file_gate`, and
  `archive._chunk_one` needed no behavior change -- only the table each already pointed at. First
  rung of a six-issue stack (#217-#222) toward one paced-worker mechanism parameterized by the two
  knobs `docs/archive-strategies-overview.md` names (boundary rule, drop-trigger rule).

- **Docs: chunked, cross-partition Parquet archival (`docs/archive-chunked-parquet.md`).** A third
  archival strategy alongside `archive-to-s3.md` and `archive-assistant.md`: decouples Parquet file
  boundaries from partition boundaries entirely, so the vacuum-horizon hold is bounded by a chosen
  target file size instead of emergent partition size (a busy month's partition can be far bigger
  than a quiet one's under time-cut partitioning). Adds `archive.file_ledger` (an additive table
  recording one row per archived file, `[lo, hi)` ranges always contiguous and gap-free from the
  parent's grid anchor, the watermark derived as `max(hi)`), a cross-partition range-query variant
  of the Parquet encoder (`archive._pq_to_parquet_range`, reading straight off the parent and
  relying on Postgres's own partition pruning, ordering by `(control column, real key)` instead of
  `ctid` since a range can span more than one child's heap and a time-kind control column routinely
  repeats; key discovery mirrors `pgpm.regrain_step`'s own PK/unique-constraint contract exactly,
  refusing keyless tables the same way), a two-part `archive.file_gate` (a derived-watermark fast
  path plus a whole-file defense-in-depth recount), and `archive._chunk_one`/`archive.chunk_step`/
  `archive.chunk_all` (the chunker itself, stopping each file at the smallest of a byte-budget
  estimate, the frozen floor, and the retention horizon, mirroring `pgpm.regrain_step`/`regrain`'s
  two driving modes).

  Verification surfaced a real correctness gap beyond the original design: a naive gate that
  recounts a file's live range against a *static* `rows_archived` misfires the moment two
  partitions sharing a file are dropped in separate `retire()` calls (the ordinary case, since
  `retain_batch` paces drops one at a time) -- partition A's legitimate drop makes the file's live
  count permanently look "short" to partition B's later check, indistinguishable from a real stray.
  The fix keeps `rows_archived` in lockstep by decrementing it (under `FOR UPDATE`) by exactly the
  dropped partition's overlap with each file it touches, verified against the constructed failure
  case directly. Verified end-to-end against a live MinIO instance through the real
  `pgpm.retire()`/`retain()` path: a 1,000-row/20-day fixture chunked into 57 files, every one
  fetched back and read by both pyarrow and DuckDB, the union exactly reconstructing the source
  (zero dup, zero drop, contiguous ranges confirmed programmatically); the sequential-sibling-drop
  fix proven against the exact adversarial sequence that breaks the naive version; a real stray
  (a row deleted out of an already-archived partition) caught through the actual `retain()` path
  and logged via the standard `retain_hook_fail` contract; single-writer confirmed under real
  concurrency; and both driving modes (paced one-file-per-tick, and drain-the-backlog-now)
  exercised. Prototype + its own from-scratch test suite (13 cases) live alongside the existing
  whole-relation encoder in `prototypes/parquet-writer/`.

- **The metaphor gets its cast sorted, and the archival examples leave `public`.** The drain is no
  longer called the magician's "assistant" anywhere: pgpm does its own drain work (it is all one big
  act), and **assistant** now names the archive-then-retire scanner (`docs/archive-janitor.md` is now
  `docs/archive-assistant.md`). Separately, every object in the worked archival examples moved from
  `public` into a dedicated `archive` schema (`archive.to_s3`, `archive.s3_signed_request`,
  `archive.ledger`, `archive.gate`, `archive.partition`, `archive.scan`): on Supabase, `public` is
  typically exposed through the Data API, which serves tables over REST and functions as RPC
  (PostgreSQL grants `EXECUTE` to `PUBLIC` on new functions by default); archival machinery has no
  business being API-visible. The relocated SQL was re-verified end-to-end against MinIO (both hooks'
  happy paths and the assistant's full matrix: vetoes, self-repair, crash cleanup).
- **Docs: the archive assistant (`docs/archive-assistant.md`).** The scanner variant of the S3 archival
  example: a standing pg_cron procedure that archives aged partitions **with per-part commits**, so
  the vacuum horizon is held for one part's network time instead of a whole partition's upload, and
  then drops each partition itself via `pgpm.retire()`, with the lean `archive.gate` `pre_drop` hook
  keeping `retain()` an honest backstop (defers unarchived or changed partitions loudly). Ledger
  table records the fact; the gate owns the veto; the archiver owns the repair. Verified end-to-end
  against MinIO: happy path (multipart + empty fast-path, retired via `retire()`), the unarchived
  veto, the stale veto + self-repair (a backdated row caught by the row-count contract), crash
  cleanup (a mid-part failure leaks an in-flight upload; the next scan's cleanup-on-entry aborts it,
  since PL/pgSQL forbids transaction control inside a block with an `EXCEPTION` clause, so a
  committing procedure cannot abort-on-exit), and the horizon claim measured directly: 1 distinct
  `backend_xmin` across the synchronous hook's whole run versus 11 advancing values under the
  assistant, same ~110MB payload, same ~1s wall-clock. Re-verified on a live Supabase project against
  Supabase Storage (same matrix, same deterministic ETags; the full-scale measurement: a ~110MB
  10-part archive over the real network showed 20 advancing `backend_xmin` values in 27 samples for
  the assistant versus one pinned value for the synchronous hook). The live run surfaced two Supabase
  ceilings, now documented loudly on both archival pages: Storage enforces the project upload file
  size limit (default 50MB, `HTTP 413` `EntityTooLarge`, boundary-verified at 49MB pass / 51MB fail,
  raised under Dashboard Storage -> Files -> Settings) on the S3 protocol per whole object, multipart
  included; and `statement_timeout` is 2 minutes (server configuration file, pooler and direct
  alike), the synchronous hook's wall-clock ceiling, which the assistant's per-part statements
  sidestep.

- **`pgpm.retire(parent, child)`: the sanctioned single-partition drop.** `retain()`'s per-partition
  body -- claim, `pre_drop` hooks in registration order, `DROP`, catalog + log, per-partition failure
  isolation -- factored into a public verb, so an external assistant (e.g. an archive-then-drop scanner)
  or several cooperating ones can drive retirement directly without hand-rolling pgpm's protocol.
  `retire` never widens what retention may drop (it refuses anything not entirely past the retention
  horizon; a caller only picks which eligible partition and when), and the `pgpm.part` row is claimed
  `FOR UPDATE SKIP LOCKED`, giving each partition exactly one owner at a time: concurrent assistants, or
  an assistant and `retain()`, never double-invoke hooks and never log a spurious `retain_hook_fail` from
  a lock race. `retain()` is now a loop over `retire()`, with its signature, return value,
  `retain_batch` pacing, and failure isolation unchanged. (issues #195, #188; tests/60, including a
  live two-session claim test via dblink)

- **Docs: a worked S3-archival `pre_drop` hook (`docs/archive-to-s3.md`).** A complete, user-supplied
  hook that copies a partition's rows to S3 as NDJSON before `retain()` drops it, and blocks the drop
  when the copy fails: the `http` extension for the synchronous PUT (with the honest account of why
  `pg_net` cannot do this job), AWS SigV4 signing via `pgcrypto`, credentials in Vault, paced by
  `retain_batch = 1`. The exact function was verified end-to-end through the real `retain()` path,
  twice: against MinIO's SigV4 enforcement (archive + drop, outage blocking the drop, the paced backlog
  draining after recovery), and against a live Supabase project archiving to Supabase Storage's
  S3-compatible endpoint (same lifecycle, plus a real S3 rejection logged verbatim and deferring the
  drop). The Storage run hardened the example's path-style branch: an endpoint may carry a path prefix
  (Storage's `/storage/v1/s3`), so the Host header and the canonical URI are split out of the endpoint
  instead of assuming a bare host. A **multipart variant** lifts the single-PUT memory ceiling: it
  keyset-paginates the partition on the control column and streams it through S3 multipart upload
  holding at most one ~8MiB part in memory (small/empty partitions short-circuit to the plain PUT),
  aborting the in-flight upload on any failure so no invisible incomplete parts accrue. Verified
  through the real `retain()` path against both MinIO and a live Supabase project on Supabase
  Storage's S3 endpoint: 3-part uploads with every row account-checked across part seams (identical
  composite ETags on both stores), the fast path, a simulated mid-part network failure (abort
  confirmed on the store via `ListMultipartUploads`, drop blocked), and a clean retry. Linked from
  the guide's pre-drop-hooks section, `hook_register` in the reference, and the README.
- **`retain_batch`: pace retention drops across maintenance ticks.** `config.retain_batch` caps how many
  eligible partitions one `retain()` call will attempt (hooks + drop), oldest first; the rest of an
  aged-out backlog waits for later ticks, each its own transaction on the `pg_cron` path -- the
  `drain_batch` shape, applied to drops. `null` (the default) is unbounded, the prior behavior. The cap
  bounds attempts, not successes: a failing `pre_drop` hook at the head of the backlog defers everything
  behind it until it clears. The motivating case is a slow synchronous `pre_drop` hook (e.g. copying a
  partition to long-term storage before it ages out): `retain_batch = 1` bounds each tick's lock and
  transaction time to one partition's hooks + drop. `pgpm.status()` gains `retain_backlog` -- eligible
  partitions not yet dropped; falling tick over tick is a paced backlog draining, flat with
  `retain_hook_failures` climbing is retention wedged on a failing hook. (issue #189; tests/59)
- **Lifecycle hooks: a `pre_drop` hook fires before `retain()` drops a partition.** The first hook in what
  is meant to grow into a general registry (`pgpm.hook`), for use cases like copying a partition's
  contents to long-term storage (e.g. S3) before it ages out. Register with `pgpm.hook_register(parent,
  'pre_drop', hook_fn)`, where `hook_fn` is a `function(parent regclass, child name, lo text, hi text)
  returns void`; `hook_register` validates the function exists with that exact signature up front
  (`regprocedure`), instead of discovering a bad reference the next time `retain()` calls it. Each
  partition's hooks + drop are isolated in their own subtransaction inside `retain()`'s loop: a hook that
  raises blocks only that partition's drop (logged `retain_hook_fail`, retried on the next `retain()`
  call) without undoing drops already committed earlier in the same call, and without re-invoking hooks
  already run for other partitions (not assumed idempotent). Multiple hooks on the same event run in
  registration order; a disabled hook (`hook_register(..., p_enabled => false)`) never runs.
  `pgpm.status()` gains `retain_hook_failures`, counted the same since-last-progress way as `drain_skips`.
  (tests/58)
- **`from_hypertable` builds the cutover key index once.** With `p_track_changes`, the destination's
  reused-key index was built twice off the lock: once as a throwaway for the online delta drain's per-batch
  key lookups, then again as the real `PRIMARY KEY`/`UNIQUE` index the cutover adopts. Now `from_hypertable_copy`
  pre-builds the reused-key index once -- with the same temp name and definition the cutover adopts -- so the
  delta drain uses it and the cutover's index pre-build loop, now re-entrant, **adopts** it (`USING INDEX`,
  metadata-only) instead of rebuilding. One key-index build instead of two, all still off the lock, so no
  change to the brief `ACCESS EXCLUSIVE` window (it removes redundant `O(rows*log rows)` work from total
  migration time, which matters at large scale). Append-only / non-tracking and keyless paths are unaffected.
  (issue #175; tests/timescale/db/14)
- **`from_hypertable` pre-drains the append-only catch-up online too (default, non-tracking path).** Without
  `p_track_changes`, the cutover caught up every row appended past the copy watermark in one `insert ...
  where control > watermark` *under the lock*, so that window grew with the copy -- the same wound #170
  closed for the tracking path, still open for the default. New `from_hypertable_drain_appends` (a `_step` +
  driver, mirroring the #170 delta drain) copies that tail **online, in bounded batches that advance the
  watermark**, so the locked catch-up applies only the final tail. It is purely additive (append-only means
  copied rows never change), so unlike the delta drain it needs no delta, no reconcile, no key, and no dest
  index, and works on a **keyless** hypertable (the common shape); each batch is bounded to the control
  value `p_batch` rows past the watermark and **inclusive of ties** at that bound (so no tie straddling a
  batch boundary is dropped), as literal constants for chunk exclusion. The cutover runs it automatically
  (`p_predrain`, default `true`) for the non-tracking path, and the watermark read that drives the under-lock
  catch-up now happens **before** the lock, so an `O(rows)` `max()` seqscan on a keyless dest is no longer in
  the blocking window. (issue #174; tests/timescale/db/15)
- **`from_hypertable` drains the change-capture delta online, before the cutover lock.** With
  `p_track_changes`, the cutover reconciled the *entire* delta under the `ACCESS EXCLUSIVE` lock -- and the
  delta is every key touched for the whole online-copy duration, so the locked window grew with the table it
  is meant to migrate quickly. New `from_hypertable_drain_delta` (a `_step` + driver pair, mirroring
  `drain`) reconciles the delta **online, in bounded micro-batches, while the source stays live**, chasing
  the backlog down so the lock applies only a tiny residual. The reconcile is idempotent and
  order-independent per key, which makes incremental draining safe; it delete-RETURNS each batch from the
  delta as the authority and reconciles exactly those keys against the live source (so a change is never
  deleted-without-applying), bounded per batch to the touched control range for chunk exclusion. The cutover
  now runs this pre-drain automatically (best-effort, new `p_predrain` default `true`); under sustained write
  load it stops at a residual threshold and the under-lock pass -- still the correctness backstop -- finishes
  the rest, or a convergence budget fails loudly. The delta gains a monotonic `pgpm_seq` ordering column for
  the batch watermark. Also closes a pre-existing silent-loss hole: tracking is now refused on a key with a
  nullable (non-control) column, since a `NULL` key component can never be reconciled. (issue #170,
  supersedes #165; tests/timescale/db/14)
- **`transmute` and `untransmute` preserve an identity sequence's exact position.** Both reseeded the
  identity sequence to `max(id) + 1`, which is correct only when the sequence sits at its max. A sequence
  **ahead** of `max(id)` -- from rolled-back inserts, sequence caching, or deleted high rows -- would then
  re-issue ids it had already handed out. Both now capture the original sequence's next value up front and
  seed to the greater of `max(id) + 1` and that value, so a transmute (and a transmute/untransmute round
  trip) never moves the sequence backward over ids already issued. The common case (a sequence at its max)
  is unchanged. (This generalises the `from_hypertable`-specific preservation to plain `transmute`.)
  (tests/56)
- **`from_hypertable` warns about transient disk use up front.** The online copy writes a full second table
  before cutover, so the migration transiently needs roughly the source's current size in extra disk
  (reclaimed when the old hypertable is dropped at cutover). `from_hypertable_preflight` now raises a
  `NOTICE` with that estimate, and a new `from_hypertable_disk_estimate(p_hypertable)` returns it as `bigint`
  (the total on-disk size across all chunks) so a volume can be sized ahead of time. (tests/timescale/db/12)
- **`from_hypertable` preserves the source identity sequence's exact position.** `transmute` seeds a
  migrated identity sequence to `max(id) + 1`, which is correct only when the sequence sits right at its
  max. A sequence that is **ahead** of `max(id)` -- from rolled-back inserts, sequence caching, or deleted
  high rows -- would then re-issue ids the source had already moved past. `from_hypertable` now captures each
  source sequence's next value before the cutover and advances the migrated sequence to it (when higher)
  after the transmute handoff, so the next generated id continues from where the source left off. (Plain
  `transmute` of a non-hypertable still seeds to `max(id) + 1`; this preservation is specific to the
  `from_hypertable` path, which discards the source sequence object during the copy.) (tests/timescale/db/11)
- **`from_hypertable` can migrate update/delete workloads online (trigger-based change capture).** The
  default cutover catch-up is append-only (rows past the copy watermark), which silently loses UPDATEs and
  DELETEs to already-copied rows that arrive during the online window. Pass `p_track_changes => true` and
  `from_hypertable_copy` installs an `AFTER INSERT/UPDATE/DELETE` row trigger on the source that logs the
  touched key values to a `<rel>_pgpm_delta` table; the cutover reconciles every touched key against the
  live source (delete each dirty key's copied row, then re-insert its current source row, which is
  idempotent and order-independent and covers inserts, updates, and deletes). The cutover auto-detects the
  apparatus, so the two phases cannot disagree, and cleans it up inside the swap transaction. Reconciliation
  is by the key `transmute` reuses (a primary key or unique constraint), so tracking is refused up front on
  a keyless table rather than silently falling back. Default stays `false` (append-only, no trigger
  overhead). (tests/timescale/db/10)
- **CHECK constraints reach the partitioned parent (bug fix).** `transmute` built the parent with `LIKE`
  but without `INCLUDING CONSTRAINTS`, so the user's CHECK constraints stayed on the monolith child only --
  the parent, the DEFAULT, and future forward partitions did not enforce them (a silent gap: new rows in
  new partitions escaped the CHECK). The parent is now built `INCLUDING CONSTRAINTS`; the transient
  `pgpm_monolith_bound` CHECK that `LIKE` also copies is dropped from the parent (the monolith keeps its
  own copy for the metadata-only attach). CHECK constraints now propagate to every partition. (tests/55;
  tests/timescale/db/07)
- **Generated columns are supported (bug fix).** `drain`, `regrain`, and `from_hypertable` move rows by
  building an explicit column list, which wrongly **included generated columns** -- so the move failed
  with `cannot insert a non-DEFAULT value into a generated column`. Two fixes: omit generated columns from
  those INSERT lists (they recompute on insert), and create the destination/partition child with
  `INCLUDING GENERATED` so its generated column matches the parent (otherwise the attach failed with
  `column ... must be a generated column`). A table with a STORED generated column now drains, regrains, and
  migrates correctly, with the generated value recomputed on the destination. (tests/54;
  tests/timescale/db/09)
- **`from_hypertable` hardening tests.** Added retention translation (a `drop_chunks` policy becomes pgpm
  `retain`), schema fidelity (the parent carries the primary key including the control column, secondary
  indexes, column defaults, and NOT NULL), and abort/rollback (nothing is irreversible before cutover; a
  failure inside the cutover transaction rolls back whole and leaves the source intact) -- run across both
  fleet TimescaleDB versions. (tests/timescale/db/06-08)

- **The `from_hypertable` CI track runs against the fleet's TimescaleDB versions, not just one.** It is now
  a matrix over the two big Supabase clusters, **2.9.1** (~224 projects) and **2.16.1** (~434), on PG15
  (set `TS_VERSIONS` to override). The full track passes on both, confirming the migration (including the
  `drop_chunks` retention auto-translation, which reads the version-sensitive jobs catalog) works on 2.9.1.
- **`from_hypertable` exposes its phases, with an online append-only catch-up.** The migration is split
  into `from_hypertable_copy` (build the destination and bulk-copy the existing chunks to a watermark,
  source stays live) and `from_hypertable_cutover` (catch up rows that arrived after the watermark, swap
  the copy in, hand off to transmute); `from_hypertable` runs both back to back. Driving them separately
  lets writes keep arriving during the migration: appends written between copy and cutover (control > the
  copy watermark) are caught up at cutover, so no row is lost. (tests/timescale/db/05)
- **`from_hypertable` preserves identity columns.** A hypertable with an identity/sequence column (e.g. a
  composite `(id, ts)` PK with `id GENERATED ... AS IDENTITY`) kept losing it on migration: `CREATE TABLE
  (LIKE ...)` does not carry identity, so the destination's column became a plain column and inserts that
  omitted it failed. `from_hypertable` now captures the source's identity columns and re-establishes the
  property on the destination before the transmute handoff (which reseeds the sequence past the max
  migrated value), so writes that omit the column keep auto-generating without collision. Normalised to
  `GENERATED BY DEFAULT`, matching transmute. (tests/timescale/db/04)

- **`transmute` partitions keyless tables; `from_hypertable` migrates keyless hypertables.** The key is
  now optional: the only hard requirement is a **`NOT NULL` control column**. A primary key or unique
  constraint that includes the control column is still reused in place when present, but a table with
  neither is now partitioned **keyless** (no key synthesized, faithful to the source) instead of refused.
  This is the common "Timescale as a partition manager" shape -- `create_hypertable` makes the time column
  `NOT NULL` but adds no key -- so `from_hypertable` drops its keyless refusal and migrates those
  hypertables (tests/timescale/db/03; tests/timescale/db/01 updated). A nullable control column, a key that
  *excludes* the control column, and a bare unique index are still refused with guidance. One limitation:
  `regrain` is unavailable on a keyless monolith (no key to dedup a resumable copy), so its history stays as
  one coarse, queryable child; `regrain` raises a clear error rather than failing obscurely. (tests/52;
  tests/32 removed as obsolete, tests/25 updated.)
- **`regrain` reuses the same key `transmute` did (bug fix).** `regrain`'s resumable copy identifies rows by
  the reused key, but it was built from the **primary key only** -- so on a monolith whose reused key is a
  *unique constraint* (the case the previous entry added) it produced malformed SQL (`... where )`) and
  failed. It now uses the primary key or the unique constraint, matching `transmute`. (tests/53)
- **`transmute` reuses a unique constraint, not just a primary key.** The key contract is relaxed: the
  control column must be part of a **primary key OR a unique constraint** (Postgres requires a partitioned
  table's key only to *include* the partition key). `transmute` reuses whichever exists in place, with no
  rebuild: the parent adopts the monolith's existing constraint index (`ADD PRIMARY KEY` adopts a child PK
  index, `ADD UNIQUE` adopts a child unique-constraint index; both metadata-only, verified on PG 15-18).
  This is faithful -- no primary key is synthesized when the source had only a unique constraint -- and it
  unblocks tables (e.g. time-series with a `UNIQUE (device_id, ts)` and no PK) that previously could not be
  partitioned at all. The control column it covers is required to be `NOT NULL` (a primary key guarantees
  this; for a unique constraint it is checked, never scanned). A *bare* unique index (not a constraint) is
  refused with guidance to promote it metadata-only via `ADD CONSTRAINT ... UNIQUE USING INDEX` (`ADD
  UNIQUE` would otherwise rebuild it); a table with no primary key and no usable unique constraint is still
  refused. Incoming-FK preservation now accepts an FK that references the reused unique constraint, not
  only the primary key. (tests/49-51; tests/32 updated for the relaxed contract)
- **The bounded-child transmute redesign: the original table becomes a "monolith" partition, not the
  `DEFAULT`; the history is split on demand by `regrain`.** This supersedes the metadata-only-cutover and
  `DEFAULT`-as-store framing of the entries below. `transmute` now renames the original aside and attaches
  it, intact, as one bounded coarse **monolith** child covering `[grid_floor(min), B)`, under a fresh
  **empty `DEFAULT`** safety net: still no row movement, but the cutover does one online, read-only
  `VALIDATE` scan (under a non-blocking `SHARE UPDATE EXCLUSIVE` lock) before the brief metadata-only
  rename/attach. The historical bulk no longer drains row-by-row; it stays in the monolith until
  **`regrain()`** splits it into proper partitions by **copying** (no dead tuples, no vacuum), atomically
  (synchronous `regrain` / `regrain_history`) or paced across maintenance ticks (`set_regrain` auto-regrain,
  budget-feathered like the drain). Regrain is retention-aware (below-horizon sub-ranges are skipped, not
  materialized) and optional (a coarse monolith is a correct, permanent state). The drain is demoted to a
  **sideline**: it keeps the empty `DEFAULT` empty by evacuating strays, so `obtain` takes a cheap
  scan-free attach. `status()` gains `coarse_partitions` and `history_unregrained` (the regraining backlog);
  `untransmute`'s gate is now monolith/data-based (reversible until a row lands outside the monolith or
  regraining begins); `maintain` suspends preserve-managed incoming FKs around the drain's row movement (a
  copy-`regrain` needs no such leash; its swap handles the FK atomically -- see the regrain-copy fix below).
  Partitions wider than one step are named `_p<lo>_to_<hi>`. (PRs #116-#119, #123; tests/42-47; REDESIGN.md)
- **`regrain` copies instead of moving (correctness fix for the redesign above).** The first implementation
  of `regrain_step` was inadvertently a clone of the drain: it `DELETE`d rows out of the coarse source and
  re-`INSERT`ed them into unattached children, contradicting the design's *copy, never delete*. That bloated
  the source with dead tuples and reopened the `snapshot()` read gap that copy-then-swap exists to avoid --
  a paced auto-regrain **undercounted** the parent mid-regrain. `regrain_step` now **copies** each frozen
  sub-range into a standalone born-validated child (budget-sized anti-join `INSERT`s resumed from the
  child's high-water mark, progress tracked across ticks by a new `config.regrain_cursor`) and **skips**
  below-horizon sub-ranges without deleting (discarded with the source at the swap); the source stays whole
  and **attached** until one atomic swap, so a read of the parent is never short. Three consequences follow
  from the source staying attached: `snapshot()` no longer unions a regrain's copy-children (their rows are
  still in the monolith, so it would double-count); `restore_incoming_fks` no longer counts them as in-flight
  drain children; and `maintain` no longer suspends an incoming FK for a regrain. The multi-tick copy needs no
  FK leash -- only the swap's `DETACH` does (Postgres refuses to detach a partition whose rows are still
  referenced), so the swap transiently drops and re-adds the FK within its one atomic transaction (no visible
  RI window, unlike the drain's). Log actions are `regrain_copy` / `regrain_aged` (were `regrain_move` /
  `regrain_reclaim`). (PR #128; new tests/48, tests/47 rewritten, tests/07/45/46 updated)
- **Docs rewritten for the monolith model; `DESIGN.md` retired.** The reference, guide, README, and runbook
  are rewritten from scratch against the current API; `REDESIGN.md` is now the canonical design note (the
  original `DESIGN.md`'s enduring supply/demand operating model is folded into it) and `DESIGN.md` is
  removed.

- **The `transmute` redesign: one function, metadata-only, never rewrites the primary key.** The three
  entry points (`transmute` / `transmute_by_id` / `transmute_by_uuidv7`) collapse into a single overloaded `transmute`:
  a `bigint` width selects the integer grid, an `interval` width the time grid, with `time` vs `uuidv7`
  inferred from the control column's type. Bare interval literals must cast: `transmute(t, c, interval '1
  month')`. `transmute` no longer drops or rebuilds the primary key, so the cutover is always metadata-only:
  it reuses the existing PK when the control column is a member of it (Postgres requires only that a
  partitioned PK include the partition key, not lead it, so `PK (tenant_id, id)` partitioned by `id`
  qualifies), and refuses (with a suggested migration) a table whose primary key excludes the control
  column, or that has no primary key at all (pgpm does not support no-PK tables), betting on a
  time-ordered primary key (Snowflake bigint / UUIDv7 / ULID) as the data model. Forbidding PK rewrites removed `build_pk_concurrently`, the composite-FK recovery
  path (`generate_fk_recovery`, the `'drop'` incoming-FK mode, the `dropped_fk` composite columns), and
  the build-path complexity; every incoming FK is now the `preserve` path. (tests/25)
- **Retention reclaims the un-drained `DEFAULT` tail (issue #91).** When the drain lags, an interval
  that ages past `retain` while still in the `DEFAULT` is now reclaimed in place: the drain `DELETE`s it
  straight out of the `DEFAULT` (paced like a microbatch, logged as `retain_reclaim`) instead of
  materializing a partition that `retain` would immediately drop. Retention now bounds storage even on a
  never-completing drain, and the materialize-then-drop churn is gone. `retain()` itself is unchanged (a
  cheap `DROP` of materialized partitions). (tests/34)
- **`status()` distinguishes a wedged drain from a slow one (issue #92).** It gains `closed_rows` (the
  drainable backlog, the same value `check_default` reports), `last_drained` (when the drain last made
  progress), and `drain_skips` (deferrals logged since that progress). A non-zero `closed_rows` with a
  stale `last_drained` and a climbing `drain_skips` is a wedged drain (e.g. the upsert/duplicate-key
  wedge); a healthy slow drain shows `closed_rows` falling and `drain_skips` near zero. (tests/35)
- **transmute refuses a random-uuid control column (issue #96).** A `uuid` control column is treated as
  `uuidv7` on assumption; when it samples as overwhelmingly random (UUIDv4 -- a plausibility fraction
  below 0.5), transmute now refuses rather than only warning, since range-partitioning a
  non-time-ordered key scatters rows across meaningless partitions on a garbage frontier (mirroring the
  float-key and PK refusals). A new `p_force_uuidv7 => true` overrides it for an operator certain the
  column is time-ordered. (tests/13, tests/39)
- **The block budget no longer disables itself when row stats are missing (issue #93).**
  `drain_max_blocks` translates to a row cap via the default's average bytes/row. When `reltuples <= 0`
  (a freshly transmuted or never-analyzed default -- the early-drain window when it is largest and
  widest) the budget previously fell back to the raw `drain_batch` row count, so a batch of wide
  incompressible rows could be the multi-GB spike the feature exists to prevent. It now estimates the
  average by sampling `pg_column_size` (cheap and TOAST-aware), so the budget holds even before ANALYZE.
  (tests/36)
- **The adaptive ambient signal no longer depends on `pg_monitor` (issue #98); pg_cron is again the only
  runtime dependency.** The consumer-priority signal previously read `pg_stat_activity.wait_event`, which
  Postgres masks for other roles unless the reader holds `pg_monitor`. It is rebuilt from two
  role-independent terms, OR'd, on catalogs any unprivileged role reads in full: a **lock-wait** count
  from `pg_locks` (non-pgpm backends blocked on an ungranted lock) and a **read-I/O latency** from
  `pg_stat_database` (ms/block, inert when `track_io_timing` is off). Both are self-calibrating (EWMA
  baseline + relative surge) like before; the `drain_ambient_*` knobs are unchanged, with new controller
  state `drain_ambient_io_baseline` / `drain_io_read_time` / `drain_io_blks_read`. `_ambient_io_waiters()`
  is replaced by `_ambient_lock_waiters()`. (tests/26, tests/41)
- **A non-PK UNIQUE secondary index is no longer silently dropped (issue #90).** transmute now carries
  it onto the parent as a partitioned unique index when its key includes the partition key (global
  uniqueness genuinely preserved, exactly as the PK is reused), and refuses with guidance when it
  excludes the partition key, or is partial/expression (global uniqueness cannot be enforced on a
  partitioned table) -- the same refuse-or-preserve contract as the PK and incoming-FK cases, instead of
  a `raise notice` that quietly lost the guarantee. (tests/33)
- **An in-flight (unattached) drain child is now tracked in pgpm's catalog (issue #94).** The drain
  creates each child standalone and attaches it only when the interval has fully moved; that child is
  now recorded in `pgpm.part` with a new `attached` column set `false` at creation and flipped `true` at
  the attach, instead of being discoverable only by scanning `pg_class`. `status()` gains
  `inflight_partitions` (and `n_partitions` now counts only attached partitions); `pgpm.partitions`
  exposes `attached`; `retain` only drops attached partitions, never an in-flight one. (tests/37)
- **A preserve-managed incoming FK can no longer be permanently bricked by an orphan, and its state is
  visible (issue #95).** `restore_incoming_fks` now splits the re-add: `ADD CONSTRAINT ... NOT VALID`
  (enforces every new write, always succeeds) is committed separately from `VALIDATE`. An orphan written
  while the FK is suspended (RI is off for the drain's duration -- inherent) used to make `VALIDATE` fail
  and roll the whole re-add back, so the FK was never restored, silently. Now the FK comes back enforcing
  new writes immediately and a blocked `VALIDATE` leaves it `NOT VALID`, surfaced by the new
  `status().fks_unvalidated`. New `pgpm.incoming_fk_orphans(parent)` lists the blocking rows and
  `pgpm.validate_incoming_fks(parent)` finishes validation once they are cleared; `status().fks_suspended`
  surfaces the RI-off window. `pgpm.dropped_fk` gains a `validated_at` column. (tests/38)
- **Docs: clarified that retention is a standing floor, not just an aging process (issue #97, closed as
  working-as-intended).** A row inserted with a control value already past the horizon (a backdated or
  late-arriving event) is reclaimed by the next maintenance cycle, exactly as any retention system would
  drop it -- the `INSERT` succeeds and a later transaction removes it per the policy you set. To keep
  late-arriving data, retain on an ingestion timestamp or widen the window. Pinned by tests/40.
- `transmute(..., p_incoming_fks => 'preserve')` + `pgpm.restore_incoming_fks` / `pgpm.suspend_incoming_fks`:
  keep incoming foreign keys across the conversion. Since `transmute` never rewrites the PK, the referenced
  unique key always survives, so `'preserve'` drops each incoming FK for the conversion, records it in
  `pgpm.dropped_fk`, and re-adds it verbatim against the new parent (`NOT VALID` + `VALIDATE`) once the
  drain is idle. `maintain` manages the lifecycle: a managed FK is live only while the closed tail is
  empty, so it suspends (re-drops) a live FK before a drain that would move referenced rows and restores
  it after, and a later obtain-miss drain neither stalls (`NO ACTION`) nor silently deletes/nulls the
  referencing rows (`CASCADE` / `SET NULL`). Referential actions, `DEFERRABLE`-ness, and self-referential
  FKs are preserved (the self-ref re-add is validating, not online). `pgpm.dropped_fk.restored_at` tracks
  the live/dropped state. (tests/19-24)
- `transmute` no longer runs `obtain` inside its transaction. Attaching a partition to a
  parent whose DEFAULT already holds data makes Postgres scan the default, and inside
  transmute's `ACCESS EXCLUSIVE` transaction that scan blocked all access for its duration
  (~minutes per premade partition at scale). `transmute` now does the metadata-only cutover
  only (a fresh parent with just the DEFAULT attached scans nothing), so it stays online
  even on a 100GB+ table. Run `pgpm.obtain()` / `pgpm.maintain()` afterward to build
  the future partitions online (their `VALIDATE` scans run under a non-blocking lock).
  Until then, writes route to the DEFAULT (correct, just not yet split into future cells).
- `maintain` no longer lets an obtain/retain failure abort the drain. Obtaining a
  future partition needs `ACCESS EXCLUSIVE` on the parent plus a scan of the DEFAULT, which
  contends with concurrent inserts into the default's open cell; under sustained write load
  the two sides could deadlock, and because obtain ran first in the same transaction the
  deadlock aborted the whole maintenance run, so the drain never made progress. `maintain`
  now caps lock waits (`lock_timeout`, turning a would-be deadlock into a fast retryable miss)
  and isolates obtain, retain, and the drain in separate subtransactions: a step that
  loses the lock race is deferred (logged as `*_skip`, retried next tick) without aborting the
  drain. The closed-tail drain attaches via the scan-skip path, so it keeps converting the
  table online even while obtain repeatedly defers under load. Two further safeguards keep
  obtain from disrupting the workload under sustained writes: (a) obtain/retain use a very
  short `lock_timeout` so a lost lock race fails in milliseconds -- barely blocking the workload,
  and bailing before obtain's `VALIDATE` scan of the default; (b) after a deferral, obtain
  backs off (a window recorded in `pgpm.config.obtain_retry_after`) instead of retrying every
  tick. The drain keeps a longer `lock_timeout` so its infrequent, must-win attach isn't starved.
- `drain_step`'s "any rows left in this range?" check now uses `EXISTS` instead of `count(*)`.
  The old `count(*)` re-scanned the entire remaining range after every microbatch -- O(rows^2 /
  batch) work, and while the default is not all-visible mid-drain the planner seq-scans the
  range each step (a sequential-scan storm that dominates I/O at scale). `EXISTS` stops at the
  first row (index scan), which is all the drain needs to decide between draining and attaching.
- `transmute` no longer scans the table to advance identity sequences. After the cutover it advances
  each identity sequence past the largest existing value -- but transmute has just swapped the PK to
  `(control, id)`, leaving no id-leading index, so the old `select max(id)` seq-scanned the whole
  DEFAULT under transmute's `ACCESS EXCLUSIVE` lock: O(rows), a multi-minute blocking step at 100GB+
  scale that undercut the metadata-only cutover. `transmute` now captures `max(identity)` up front --
  while the table's original id index still exists, so it is an index lookup -- and reuses it to
  advance the (freshly recreated) parent sequence. The cutover stays metadata-only at any size.
- `transmute` reuses the existing PK when the partition key already covers it. For `id` / `uuidv7`
  tables the computed PK columns equal the existing PK, so transmute no longer drops and rebuilds an
  identical index -- it reuses the index in place. In the common case the one-time setup cost center
  collapses to zero and only the drain remains. Flat (single-digit ms) to ~40M rows. (tests/15)
- `drain_max_blocks` config: block-budgeted drain batching. Batching by a fixed row count is unsafe
  when row width varies (20 000 rows each carrying a 2 MB document is tens of GB rewritten in one
  microbatch). When set, `drain_step` caps each microbatch at roughly that many heap+TOAST blocks
  (translated to a row limit via the default's average bytes/row) and takes the smaller of that and
  `drain_batch`; when null it falls back to the row cap unchanged. (tests/17)
- `pgpm.check_time_monotonic(parent, key_col, time_col)`: an additive, read-only co-monotonicity
  check, the tier-2 safety gate for a future key-to-time retention bridge (calendar retention on an
  id-partitioned table). It samples whether the id and timestamp rise together and reports the
  fraction in order, analogous to `check_uuidv7`'s plausibility sampling. (tests/16)
- `transmute` now refuses up front when an orphaned child-partition table exists. A drain creates each
  child as a standalone table (`CREATE TABLE ... LIKE`) and ATTACHes it only at the end of that
  child's drain, so an interrupted drain leaves an un-attached child -- which `DROP TABLE <parent>
  CASCADE` does not remove (no dependency on the parent). Re-transmuting the recreated table would let
  the next drain reuse the orphan by name and collide on its stale keys, surfacing as a cryptic
  mid-drain "duplicate key" deep inside `drain_step`. `transmute` now detects any standalone
  (un-attached) table whose name matches this parent's child-partition naming and raises a clear,
  actionable error instead. (tests/18)

## [0.1.0] - 2026-06-19

Initial release of pg_partition_magician.

- Pure-SQL online RANGE-partition manager (schema `pgpm`); only runtime dependency is pg_cron.
- Partition dimensions: `time`, `id` (bigint/numeric, incl. Snowflake-style), `uuidv7`/ULID-as-uuid. float/double rejected.
- `transmute` / `transmute_by_id` / `transmute_by_uuidv7`: online conversion of an existing table (attach as DEFAULT, no rebuild of the default's PK index).
- obtain ahead of the write frontier; paced microbatch drain of the DEFAULT's closed tail (scan-skip attach); retain; maintenance via pg_cron.
- Incoming-FK handling: refuse by default, opt-in drop+record, and `generate_fk_recovery()`.
- Three install channels (psql / bundle / dbdev-TLE) built from one source; PG 15-18 channel test matrix; 53 pgTAP tests.
