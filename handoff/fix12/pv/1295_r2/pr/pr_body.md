## Defect (#1262)

`pgpm.adopt_partition` locks the partition in `SHARE UPDATE EXCLUSIVE` mode and then re-reads the catalog to judge it attached and not pending, and to read its name and its bounds. Those reads (and the pre-lock check) went through the caller's snapshot. Under `REPEATABLE READ` or `SERIALIZABLE` that is the transaction's first snapshot, which can predate a change another session committed before the call:

- a `DETACH` committed after the snapshot was read as still attached, so `pgpm.part` recorded a standalone table as a partition of the parent (F4-03, F11-03), against the function's header ("the relation judged attached is still attached when its row commits");
- a `RENAME` committed after the snapshot was read under the old name, so the row recorded a `child_name` that no longer resolves to the `child_oid` it records (tests/332 part B shows it on the base: `t332_x` recorded for the relation now named `t332_x_renamed`).

The same calls under `READ COMMITTED` refuse, or read the current name.

## Fix

`adopt_partition` refuses any transaction stricter than `READ COMMITTED` as its first statement, before the null-argument check, the regrain lock, the config row lock and the partition lock, with an inline check in untransmute's shape (`current_setting('transaction_isolation') not in ('read committed', 'read uncommitted')`). Under `READ COMMITTED` every statement takes a fresh snapshot, so the existing re-read under the partition's lock (attached, not pending, name, kind, bounds) and every later read of `pgpm.part` are made through a snapshot taken after the lock is granted. Of the two shapes the issue offered, this is "a fresh snapshot", not `pg_partition_ancestors`: the ancestors read would answer the membership question as of the lock, but the name and bounds would still come through the stale snapshot (part B's rename is still attached, so an as-of-lock membership check alone admits it).

Why inline and not `pgpm._refuse_strict_isolation`: that helper also refuses on `default_transaction_isolation`, because `transmute` commits into fresh transactions that take that default. `adopt_partition` is a function and commits nothing, so only the calling transaction's level matters; a `READ COMMITTED` transaction in a session whose default is `REPEATABLE READ` is correct and is admitted (tests/332 part D runs exactly that). The helper's message is also transmute-specific.

**Round 2 (verification V-01): the lock is on the relation `p_child` denotes.** `LOCK TABLE` takes a name and resolves it again once the lock is granted, and the lock used to be taken by `p_child::text`. A rename of the partition and a table created under its old name, committed while the call waited for the lock, left the lock on that new table, so the call recorded `p_child` with no lock on it and a `DETACH` of it could commit before the row did (in `READ COMMITTED`, the level the refusal requires). The lock now takes the partition's schema-qualified name (read from `pg_class` by `p_child`'s oid, so the caller's `search_path` chooses nothing), and under the lock asks `to_regclass` whether that name still denotes `p_child`. When it does not, the call refuses and names the partition as it is now; the answer under the lock is stable because a rename takes `ACCESS EXCLUSIVE`, which the held lock conflicts with. A partition dropped between the first check and the name read is refused as not a partition any more.

The refusal names its remedy, `BEGIN ISOLATION LEVEL READ COMMITTED`, the call, `COMMIT`, and tests/332 part D types it under `default_transaction_isolation = 'repeatable read'` and shows it repairs the state: the renamed partition is recorded by its oid under its current name, the untouched one is recorded, and the detached table is refused as not a partition.

**What it guarantees, and the sites covered:** the one entry point, `pgpm.adopt_partition(regclass, regclass)`. (1) Every read it makes after the isolation refusal (both membership checks, the name read for the lock, the name/kind/bounds read under the lock, the `pgpm.part` and `pgpm.archive_ledger` reads) runs under `READ COMMITTED`, so the reads after the lock see the catalog as of the lock. (2) The `SHARE UPDATE EXCLUSIVE` lock it holds when it records a row is on the relation whose oid it records, so a `DETACH` or `DROP` of that relation waits for the call's transaction: the relation judged attached is still attached when its row commits. Nothing in pgpm calls `adopt_partition`; only a direct caller meets the refusal. Docs: `docs/reference.md#adopt_partition` (refusal list and the locks paragraph), `CHANGELOG.md`.

## Acceptance

- **Test:** `tests/332_adopt_partition_isolation_test.sql` (25 assertions): A, a `REPEATABLE READ` snapshot older than a committed `DETACH`, refused and nothing recorded; B, older than a committed `RENAME` of a partition still attached, refused and nothing recorded; C, `SERIALIZABLE`, refused; D, the isolation refusal's remedy as typed; **E (round 2), V-01's race in `READ COMMITTED`**: a second session renames the partition and creates a standalone table under its old name, uncommitted; the call passes its first check and waits behind it for the partition's lock (witnessed in `pg_locks`, no sleeps); the rename commits; the call refuses naming the partition as it is now, and its transaction COMMITS with nothing recorded; then the remedy as typed (the call naming the current name) records the partition by oid, and while its transaction is open a `DETACH` of that partition from another session waits and gives up at its `lock_timeout` (55P03); after commit the partition is still attached with its rows. Every negative is paired with a LIVENESS witness. Fails on the base, passes on the head, and on PG 18 too.
- **Guard:** `bench/adopt_partition_isolation.sh` (perf track, `pgpm_perf370`), in the shape of `bench/retain_recall_moved_parent.sh`.
- **Mutations:** `adopt_partition_strict_isolation_admitted` (the isolation refusal's condition becomes `if false`, one clause): the guard FAILS at parts A, B, C and D. `adopt_partition_lock_name_unchecked` (the check under the lock becomes `if false`, one clause, so the lock is by name and unchecked again): the guard FAILS at part E (assertions 20 and 21), no LIVENESS line among either's failures. `adopt_partition_unlocked`'s pattern follows the lock's new argument and still fails `bench/adopt_partition.sh` at tests/303 part E.

## Reproductions

Both fail on the base as the issue says. On the head:

- **F11-03 `repro.sql`: passes, 6 of 6.**
- **V-01 `repro.sql` (round 1's claim):** on the head the call refuses, so the reproduction stops at its own `LIVENESS:` step 3 ("adopt_partition recorded the renamed partition"), whose premise is the defect; tests/332 part E is the acceptance for it. Against the `adopt_partition_lock_name_unchecked` mutant it fails exactly as on the base (assertions 4 and 6: no lock on the recorded relation, and it is not a partition when its row commits).
- **F4-03 `repro.sql`: 4 of 5 pass; assertion 3 fails on its message pattern only.** It pins `'%is not a partition of%'`, the message of the membership refusal. Under the fix a `REPEATABLE READ` caller is refused before the membership question is asked, with the isolation refusal (`... must run in a READ COMMITTED transaction (this one is repeatable read) ...`), so the call does refuse (the assertion's own description, "adopt_partition refuses a table the parent no longer holds") and assertion 5, the contract (`pgpm.part` records no row for the detached table), passes. Re-run in `READ COMMITTED`, as the refusal says, the same call meets the pinned message (tests/332 part D asserts it: `t332_y is not a partition of t332:`). The verifier's question, whether the reproduction FAILS against the mutant: yes, both fail exactly as on the base (F4-03 assertions 3 and 5, F11-03 assertion 4).

## Local proof

`./test.sh 15 --channel=psql` (through the gate) green; `python3 scripts/check_quoted_splices.py` PASS; every mutation in `bench/mutations/` builds; `bash -n test.sh`; `shellcheck` 0.11.0 clean on the new wrapper; `bench/throws_pinned.sh` PASS repo-wide; `scripts/check_living_docs.sh` PASS; markdownlint-cli2@0.13.0 clean on the two docs; the existing `bench/adopt_partition.sh`, `bench/adopt_partition_regrain_lock.sh` and `bench/null_arguments_refused.sh` stay green.

Closes #1262

🤖 Generated with [Claude Code](https://claude.com/claude-code)

