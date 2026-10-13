## Defect (#1262)

`pgpm.adopt_partition` locks the partition in `SHARE UPDATE EXCLUSIVE` mode and then re-reads the catalog to judge it attached and not pending, and to read its name and its bounds. Those reads (and the pre-lock check) went through the caller's snapshot. Under `REPEATABLE READ` or `SERIALIZABLE` that is the transaction's first snapshot, which can predate a change another session committed before the call:

- a `DETACH` committed after the snapshot was read as still attached, so `pgpm.part` recorded a standalone table as a partition of the parent (F4-03, F11-03), against the function's header ("the relation judged attached is still attached when its row commits");
- a `RENAME` committed after the snapshot was read under the old name, so the row recorded a `child_name` that no longer resolves to the `child_oid` it records (tests/332 part B shows it on the base: `t332_x` recorded for the relation now named `t332_x_renamed`).

The same calls under `READ COMMITTED` refuse, or read the current name.

## Fix

`adopt_partition` refuses any transaction stricter than `READ COMMITTED` as its first statement, before the null-argument check, the regrain lock, the config row lock and the partition lock, with an inline check in untransmute's shape (`current_setting('transaction_isolation') not in ('read committed', 'read uncommitted')`). Under `READ COMMITTED` every statement takes a fresh snapshot, so the existing re-read under the partition's lock (attached, not pending, name, kind, bounds) and every later read of `pgpm.part` are made through a snapshot taken after the lock is granted. Of the two shapes the issue offered, this is "a fresh snapshot", not `pg_partition_ancestors`: the ancestors read would answer the membership question as of the lock, but the name and bounds would still come through the stale snapshot (part B's rename is still attached, so an as-of-lock membership check alone admits it).

Why inline and not `pgpm._refuse_strict_isolation`: that helper also refuses on `default_transaction_isolation`, because `transmute` commits into fresh transactions that take that default. `adopt_partition` is a function and commits nothing, so only the calling transaction's level matters; a `READ COMMITTED` transaction in a session whose default is `REPEATABLE READ` is correct and is admitted (tests/332 part D runs exactly that). The helper's message is also transmute-specific.

The refusal names its remedy, `BEGIN ISOLATION LEVEL READ COMMITTED`, the call, `COMMIT`, and tests/332 part D types it under `default_transaction_isolation = 'repeatable read'` and shows it repairs the state: the renamed partition is recorded by its oid under its current name, the untouched one is recorded, and the detached table is refused as not a partition.

**Sites covered:** the one entry point, `pgpm.adopt_partition(regclass, regclass)`; every read it makes after the refusal (both membership checks, the name/kind/bounds read, the `pgpm.part` and `pgpm.archive_ledger` reads) runs under `READ COMMITTED`. Nothing in pgpm calls `adopt_partition`; only a direct caller meets the refusal. Docs: `docs/reference.md#adopt_partition` (refusal list and the locks paragraph), `CHANGELOG.md`.

## Acceptance

- **Test:** `tests/332_adopt_partition_isolation_test.sql` (18 assertions): A, a `REPEATABLE READ` snapshot older than a committed `DETACH`, refused and nothing recorded; B, older than a committed `RENAME` of a partition still attached, refused and nothing recorded; C, `SERIALIZABLE`, refused; D, the remedy as typed. Every negative is paired with a LIVENESS witness (the detach/rename committed, as seen from a second session, while this snapshot still shows the old state). Fails on the base (11 of 18), passes on the head, and on PG 18 too.
- **Guard:** `bench/adopt_partition_isolation.sh` (perf track, `pgpm_perf370`), in the shape of `bench/retain_recall_moved_parent.sh`.
- **Mutation:** `adopt_partition_strict_isolation_admitted` (the refusal's condition becomes `if false`, one clause). The guard FAILS against it at parts A, B, C and D, no LIVENESS line among the failures.

## Reproductions

Both fail on the base as the issue says. On the head:

- **F11-03 `repro.sql`: passes, 6 of 6.**
- **F4-03 `repro.sql`: 4 of 5 pass; assertion 3 fails on its message pattern only.** It pins `'%is not a partition of%'`, the message of the membership refusal. Under the fix a `REPEATABLE READ` caller is refused before the membership question is asked, with the isolation refusal (`... must run in a READ COMMITTED transaction (this one is repeatable read) ...`), so the call does refuse (the assertion's own description, "adopt_partition refuses a table the parent no longer holds") and assertion 5, the contract (`pgpm.part` records no row for the detached table), passes. Re-run in `READ COMMITTED`, as the refusal says, the same call meets the pinned message (tests/332 part D asserts it: `t332_y is not a partition of t332:`). The verifier's question, whether the reproduction FAILS against the mutant: yes, both fail exactly as on the base (F4-03 assertions 3 and 5, F11-03 assertion 4).

## Local proof

`./test.sh 15 --channel=psql` (through the gate) green; `python3 scripts/check_quoted_splices.py` PASS; every mutation in `bench/mutations/` builds; `bash -n test.sh`; `shellcheck` 0.11.0 clean on the new wrapper; `bench/throws_pinned.sh` PASS repo-wide; `scripts/check_living_docs.sh` PASS; markdownlint-cli2@0.13.0 clean on the two docs; the existing `bench/adopt_partition.sh`, `bench/adopt_partition_regrain_lock.sh` and `bench/null_arguments_refused.sh` stay green.

Closes #1262

🤖 Generated with [Claude Code](https://claude.com/claude-code)

