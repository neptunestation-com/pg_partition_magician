# F17 null results (slice S13, the documents)

Method: read each document against the code it describes; typed the runnable statements in fresh databases
on pgpm_test-15 (`f17_*`, dropped after); a mechanical pass counted, for every helper the CHANGELOG's
Unreleased bullets name and for every function the three install files define, its call sites outside
comments. That pass is what found the dead `pgpm._refuse_detach_pending` (F17-02) and the dead
`pgpm._log_unbuilt_cell` (F17-03, F17-04); the only other uncalled definitions are `pgpm._archive_noop`
(documented as test-only) and `archive._pq_gzip_compress` (superseded by `_dynamic`, documented in its
comment). Every `pgpm.log` action the reference's vocabulary table names is written somewhere in the code
except `fail_obtain_name` from its two documented callers (the claims) and `obtain_backoff`, which is a
`p_status` note, not a log action (the CHANGELOG's #1078 bullet says "logged" loosely).

## fresh surface

- #1157 (untransmute vs a pending detach): the refusal function exists, its call is gone from both gates
  (F17-02, T1; the comment at the gate still promises it).
- #1159 (archive script): the `_part_detached_by_hand` filter and the `_archive_hold_partition` hold are
  both absent from `scripts/archive_partition_whole.sql`, each leaving only its comment (F17-05, F17-06,
  T1 each; independent: each repro still fails with the other fix applied). `_archive_step`'s own hold
  (install.sql 5393) and filter (5341) are present.
- #705/#1166/#1167/#1135/#1161/#1162/#1163/#1164/#1165/#1117/#1139/#1160/#1158/#1241: each named helper is
  called where the bullet says (`_detach_dispatched` x6, `_disown_retirement` x5, `_disown_unvouched_retirements`
  at install, `_transmute_refuse_child_holders` before and after the cutover's obtain,
  `_transmute_refuse_names_held` at the staging CREATE, both RENAMEs and the forward CREATEs, `_regrain_swap_budget`
  at the prepare tick and set_regrain (warn), `_cell_walk_rows/_step` in obtain and extend_to, the retired-hi
  index built after `retired_at`, forget_missing's `ARCHIVED CHUNKS` text, `_same_step` in set_regrain,
  `_naive_grid_zone_off`/`_reconvert_remedy`, `_backfill_chunk_oids`, the cutover's `SHARE` on the copy and the
  drains' `ROW EXCLUSIVE`, `_snapshot_wait` from regrain and the cutover, `_scratch_written` x3); retire takes
  `SHARE UPDATE EXCLUSIVE` before asking the catalog (3732); adopt_partition takes the regrain lock and refuses
  pending (14012-14025). Held.

## contracts versus documentation

- reference.md untransmute: the remedy `ALTER TABLE <table> DETACH PARTITION <partition>` for an interrupted
  concurrent detach fails on PostgreSQL ("has an unfinished detach", HINT FINALIZE) (F17-01, T4). The code's own
  messages (untransmute 12097, retire's skip_retain 3794) and reference.md 1501 and 1650 say FINALIZE correctly.
- Probed and held: README Quickstart (run from $TREE, all statements succeed); maintain's p_status format
  (`archived= dropped= restored_fk= regrain=`); maintain_obtain's `obtained=`; forget_missing's method text and
  the documented `parent_table::oid` query; the runbook's orphan-table refusal text (install.sql 9576), its
  `managed table with oid ... no longer exists` text (2356), the `pgpm.partitions` view it queries (15041);
  adopt_partition's documented refusals and locks; set_regrain's warning (not refusal) for the lock budget and its
  `warn_regrain_lock_budget` row; archive.configure's p_part_bytes floor (5 MiB) and p_fetch_rows floor (1) and
  to_s3's row checks; RELEASING.md's version pins and pages.yml's unconditional redeploy; release.yml's CHANGELOG
  heading match.

## operator error

- Remedies the documents tell an operator to type: the FINALIZE one fails (F17-01); `adopt_partition` for a
  restored partition, `delete from pgpm.part ...` only after a detach, the rename three-statement transaction
  (guide), the `update pgpm.archive_ledger set hi = ceil(hi::numeric)::text` repair (integer keys only), the
  refused-handoff three calls (guarded by bench/hypertable_handoff_remedy.sh), `restore_incoming_fks(p, array[id])`
  for a parked key: read against the code, held.
- set_retain's documented refusal of a tightening that would drop: met it while building F17-05 (it refused
  `set_retain('150')` naming the partition it would drop), held.

## time and zones

- The documents' zone statements (grid in the converting session's zone, naive keys recorded UTC, day labels in
  UTC, month labels in partition_tz, `_canonical_tz` refusing localtime/posixrules/Factory, the retain horizon's
  calendar part on the wall clock and time part off the instant) read against `_retain_horizon`,
  `_canonical_tz`, `_naive_grid_zone_off`: consistent. Not typed under a DST zone (budget).

## boundary arithmetic and types

- Lock budget: `2 * v_n > v_slots / 2` with `v_slots = max_locks_per_transaction x (max_connections +
  max_prepared_transactions)`; stock 64 x 100 gives 3200 slots, refusal from the 1601st child: matches the
  reference's "more than 1600". `_regrain_fine_count` caps at slots/4 + 1 and set_regrain's catalog-only id
  horizon (newest attached hi minus retain) is never earlier than the prepare tick's, so it never warns about a
  run the prepare tick accepts, as documented.
- archive knobs (part_bytes, fetch_rows) at their edges: as documented.

## failure injection

- Interrupted DETACH ... CONCURRENTLY (cancelled in its wait) built for F17-01/F17-02: the pending state and its
  aftermath are exactly what the reference describes for retire (skip_retain) and the reaper; untransmute's
  aftermath is the defect (F17-02).
- A strategy that raises (`skip_archive`, nothing recorded, retire returns false) used as F17-05/06's fixture:
  behaves as the reference's contract section says.

## Hypotheses (not built)

- H1 CHANGELOG.md hand-merge debris: the #1168 bullet (lines 321-359) carries five stale mutation-list fragments
  and a repeated sentence after its end; the #1157, #1170, #1171 and #1172 bullets appear twice; the #1161 bullet
  carries a stale second half (lines 125-131) saying `set_regrain` and the prepare tick "now refuse", where the
  code (`_regrain_swap_budget`, p_warn) and the first half say set_regrain only warns; the #1163 bullet repeats
  its tail (lines 99-100) and #1073's mutation list appears three times (984-986); the #633 bullet repeats a
  sentence (155). Wording only, changes nothing an operator types, so not claimed.
- H2 reference.md regrain_step lock budget: line 1801 says the swap needs "about one more [slot] for each
  incoming key the swap re-adds", line 1811 says the swap "charges each incoming foreign key two slots a child
  plus two more"; one of the two misdescribes the measured charge in `regrain_step` (not read to the line).
- H3 bench/README.md run_fh section: "(At scale this window is not negligible: CREATE TABLE LIKE carries no
  indexes, so the rebuild of the PK and secondary index on the full table happens inside it.)" contradicts the
  reference's online index pre-build before the cutover's lock (stale since the pre-build landed).
- H4 index.html: "One scheduled call ties it together: obtain stocks the future, retain drops ..." predates
  #347's split into two jobs (maintain does not obtain); bench/doc_maintain_does_not_obtain.sh reads the docs for
  "maintain obtains" and may not parse this sentence because it names no procedure.
- H5 docs/guide.md uninstall command `psql "$DATABASE_URL" --single-transaction -f pgpm_core/uninstall.sql`
  carries no `-v ON_ERROR_STOP=1`: uninstall's refusal rolls the whole run back (COMMIT of an aborted
  transaction), so nothing is half-done, but psql exits 0 on the refusal, so a scripted uninstall reads it as
  success. uninstall.sql's comment (151) says this shape was considered; not claimed.
- H6 README Quickstart comment "the key to range-partition on (must be in the PK)" against the documented keyless
  path (a table with no key converts keyless); wording.
- H7 bench/figures/README.md describes the pre-monolith DEFAULT-drain model ("rows draining out of the DEFAULT");
  historical figures, no operator action.
- H8 not typed for budget: set_partition_tz's refusal of a change whose newest bound is off the new zone's grid,
  under America/Havana or Asia/Amman midnight transitions; the reference's claim that a day-denominated step "can
  always change" its zone.

## Round 2

None of the round-1 hypotheses had one of the six long-surviving shapes, and this slice has no mechanical
pre-pass, so the order followed the brief's second rule (a CHANGELOG sentence promising what the code does not do).

- Built: H1, the stale second half of CHANGELOG.md's #1161 bullet (lines 524-530: "`set_regrain` now refuse a
  run ..."), as F17-07 (Tier 4). The repro reads the sentence from $TREE, runs set_regrain on a 2000-child run past
  half of 6400 lock slots, sees it warn, log warn_regrain_lock_budget and store the target, and passes once the
  stale lines are removed (checked against a copy with lines 524-530 deleted). The rest of H1 (the duplicated
  #1157/#1170/#1171/#1172 bullets, the #1168 mutation-list debris, #1073's triple list, #633's repeated sentence)
  promises nothing the code breaks, so it stays wording.
- Tried and dropped: H2. Read regrain_step's measured budget (install.sql 8555-8580): it charges `2 + 2 * v_fk`
  slots a child for incoming keys, which is what reference.md 1811 says ("two slots a child [for each key] plus two
  more"); line 1801's "about one more for each incoming key" describes the measured cost (about 1.2 a key, per the
  code's comment), not the charge. Consistent, no claim.
- Not attempted: H5 (the guide's uninstall command without ON_ERROR_STOP: the refusal still removes nothing under
  --single-transaction, only psql's exit status misleads; judged too weak to claim); H3, H4, H6, H7 (wording in
  bench/README, index.html, README and the historical figures README, nothing an operator types); H8 (set_partition_tz
  under DST midnight transitions: no specific mechanism to aim at within the budget).
