# P1 null results: PR #1295 round 2

## Fresh surface

- `pgpm.adopt_partition`, the isolation refusal (install.sql:14022): NOT held. The tree ships it as
  `if false then raise ...`, the PR body's own `adopt_partition_strict_isolation_admitted` mutant shape.
  Claim P1-01. The tree's own `tests/332` fails parts A-D (9 of 25) on the tree and passes 25 of 25 on a
  scratch copy of install.sql with the real condition substituted (the tree was not edited).
- The refusal's placement (before `_refuse_null_arguments`, the regrain lock, the config row lock and the
  partition lock) and its message: read; with the condition live (scratch copy) parts A-D of tests/332 pin
  both. `READ UNCOMMITTED` admitted as documented.
- The name read for the lock (`format('%I.%I', nspname, relname)` by oid, `_q` suffixed, spliced with
  `%s`): schema-qualified so the caller's `search_path` chooses nothing; `to_regclass` of the same text
  resolves the quoted form. Held.
- The "dropped between the first check and the name read" refusal: the window is one statement wide; a
  drop committed while the call WAITS for the lock is refused by `LOCK TABLE`'s 42P01 instead (probed:
  nothing recorded, see Hypotheses on the message).
- Re-read under the lock (`pg_inherits ... not inhdetachpending`, relkind, bounds): in READ COMMITTED each
  takes a fresh snapshot after the lock; probed detach-while-waiting and rename-and-squat-while-waiting
  (tests/332 part E passes on the tree, 7 of 7). Held.
- `bench/adopt_partition_isolation.sh`: read whole; shape of `retain_recall_moved_parent.sh` (install
  failure reported as FAIL, `ran` counted, LIVENESS line on 0 ran). `pgpm_perf370` is unique in test.sh.
- `test.sh` 1268: the guard registered in the perf list; sharding is `idx % SHARD_N`, no pinned count.
- `CHANGELOG.md`, `docs/reference.md`: the entry and the section read whole; both promise the refusal
  P1-01 shows absent, and reference.md promises "names the partition as it is now" for the renamed case,
  which only the squatter path keeps (P1-02, Tier 4).
- `tests/332_adopt_partition_isolation_test.sql`: read whole. Every negative has a LIVENESS witness; part
  E orders by the lock queue (pg_locks poll, no sleeps); `throws_ok(..., '55P03', NULL, ...)` is pinned by
  SQLSTATE around a function, not a committing procedure. On the tree part E passes and A-D fail, so the
  file discriminates the dead refusal (it is the PR's acceptance; the tree is what does not keep it).

## Concurrency and locks

- Lock on the relation `p_child` denotes: under the SUE lock on whatever `v_child_q` resolves to, that
  name's binding is stable (rename and drop of the locked relation take ACCESS EXCLUSIVE; a second
  relation cannot take the name while the locked one holds it), so `to_regclass(v_child_q) = p_child`
  under the lock implies the lock is on `p_child`. Probed: rename-and-squat while waiting refuses with the
  current name and records nothing (tests/332 E 20-21 on the tree); a DETACH of the recorded partition
  waits for the open transaction (E 23). Held.
- Rename only (no squatter) while waiting: `LOCK TABLE` re-resolves to nothing, 42P01, nothing recorded.
  The lock guarantee holds; the message is the wrong one (P1-02).
- Drop while waiting: 42P01 from `LOCK TABLE`, nothing recorded. Held.
- Lock order: regrain lock, config row FOR KEY SHARE, then the partition SUE; unchanged by the round-2
  diff. A refused call leaves its (wrong-relation) lock to its transaction's end; the transaction is
  aborted so COMMIT is a ROLLBACK. Held.

## Hypotheses (no reproduction)

- A schema rename (`ALTER SCHEMA ... RENAME`) committed while the call waits: `LOCK TABLE` on the old
  schema-qualified name gives 42P01, same class as P1-02's message; not built (same consequence).
- If the `if false` is a packaging slip (the mutant left applied when the head was committed), the
  shipped `bench/mutations` entry for `adopt_partition_strict_isolation_admitted` would be a no-op diff
  against this tree; cannot be checked here (bench/mutations removed from the review tree by rule).
