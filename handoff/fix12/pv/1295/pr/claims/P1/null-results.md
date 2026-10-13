# P1 null results: PR #1295 (adopt_partition refuses a transaction stricter than READ COMMITTED)

Review tree: the PR head as a single commit. Every unit in `surface/units.txt` was read in full before anything was built
(see `coverage.md`). One claim written, `P1-01` (Tier 3, fresh surface): the refusal at `pgpm_core/install.sql:14021`
is dead code on this tree (`if false then`), so the body's central promise, the reference's new bullet ("before it takes
any lock") and the CHANGELOG entry are not kept; a REPEATABLE READ caller is admitted and records a detached table and a
renamed partition's old name. The reproduction fails on the tree (4 defect checks, 6 LIVENESS witnesses green) and passes
10 of 10 against a scratch-database copy of the function with the condition made live, so it also closes.

## Lens: fresh surface

- **The refusal's placement and shape.** Read the hunk at 14005-14013 (header) and 14021-14024 (body). The body says the
  check runs "before the null-argument check, the regrain lock, the config row lock and the partition lock": in the text
  it does precede `_refuse_null_arguments`, `_regrain_lock`, the `for key share` read and the `lock table`. The message
  renders `p_parent`, `p_child` (regclass, so the CURRENT name through the syscache even under a stale snapshot, which is
  why tests/332 part B can pin `t332_x_renamed`) and `current_setting('transaction_isolation')`; the three-argument order
  in the `raise` matches the five `%` placeholders. Held, apart from the constant condition (P1-01).
- **Every reader after the refusal.** Walked the function end to end under READ COMMITTED: the pre-lock `pg_inherits`
  check, `lock table`, the `pg_class join pg_inherits` re-read (name, kind, bounds, pending flag), the `pgpm.part` by-oid
  read, the bounds decode, the same-name `for update` read, the materialized-CTE overlap check, `_mark_gone_chunks`, the
  `archive_ledger` delete and the `pgpm.log` insert. The function is VOLATILE (no STABLE/IMMUTABLE marker), so each
  statement takes its own snapshot in READ COMMITTED; every read after `lock table` therefore has a snapshot taken after
  the lock was granted. Confirmed by the control in P1-01's reproduction: on the same state, in READ COMMITTED, the
  untouched partition is adopted and the detached one is refused with `is not a partition of`.
- **"Nothing in pgpm calls adopt_partition."** `grep -rn adopt_partition pgpm_core pgpm_archive pgpm_hypertable` finds
  only its own definition, header and two comments (4681, 5122). No sibling copy in the archive or hypertable modules
  (neither mentions `inhdetachpending`). Held.
- **A READ COMMITTED transaction under a stricter `default_transaction_isolation`.** The inline check reads
  `transaction_isolation` alone, as untransmute's at 12191 does, while `_refuse_strict_isolation` (9647) also reads the
  default because transmute commits into fresh transactions. `adopt_partition` is a function and commits nothing, so
  the body's reasoning holds; tests/332 part D types that case and the reference says the remedy works there.
- **Docs.** `docs/reference.md#adopt_partition`: the new refusal bullet and the locks paragraph agree with the code's
  intent. The line-245 paragraph that lists transmute, `from_hypertable` and `from_hypertable_cutover` as refusing on
  the session default was not extended, correctly, since adopt_partition does not refuse on the default. CHANGELOG entry
  consistent with the body. `test.sh`: `pgpm_perf370` is unique in the guard list; the wrapper's shape is byte-for-byte
  that of `bench/retain_recall_moved_parent.sh` with the file and labels changed, takes the mutant's install path as its
  third argument as `discriminate.sh` passes it, and reports `LIVENESS: the assertions were reached at all` on a run
  that produced no TAP lines.
- **The new test (tests that pass for the wrong reason, in passing).** tests/332 has 18 assertions matching its plan;
  every refusal is pinned by message (`throws_like` with the full prefix, through `(this one is repeatable read)` or
  `serializable`), never `throws_ok(NULL)`; every negative has a LIVENESS witness read from a second dblink session; the
  fixture is asymmetric (1 renamed, 1 detached, 1 untouched; 1, 2 and 3 rows). Run against the review tree it fails at
  exactly the 11 assertions the body predicts (4,5,7,8,9,10,11,12,13,15,18) with every LIVENESS line green, so the test
  and its wrapper discriminate the mutation the PR names. Held.
- **F4-03 message-pattern caveat.** The issue's F4-03 reproduction pins `%is not a partition of%` for the REPEATABLE
  READ call; on a tree where the refusal fires it meets the isolation message instead, so that file's assertion 3 fails
  on the fixing commit (its contract assertion 5 passes). The body states this. It is a closure-process matter for the
  verifier (a rebuilt reproduction or the F11-03 file closes the issue), not a code defect; no claim.

## Lens: concurrency and locks

- **Check-then-act across the partition lock.** Pre-lock membership read, then `lock table <child> in share update
  exclusive mode`, then the re-read. SUE conflicts with DETACH (both forms take SUE or stronger on the partition), DROP
  and RENAME (ACCESS EXCLUSIVE), so after the lock is granted a READ COMMITTED re-read sees the committed state and
  refuses `any more (detached while this call waited)` or a pending detach. The two queue orders (adopt first, detach
  first) both end consistent; the existing `bench/adopt_partition.sh` covers the detach race and was not re-run.
- **The lock's target identity.** `p_child::text` renders through the syscache (the current, committed name, schema-
  qualified when not visible), so a rename committed before the call locks the right relation even under a stale
  snapshot. Held.
- **Regrain lock and config row.** `_regrain_lock` is an `insert ... on conflict do nothing` then `for update` on
  `pgpm.regrain_lock`; concurrent adopts of the same parent serialize there, so the overlap check cannot race another
  adopt. The config row is read `for key share`, so a concurrent zone change waits. Held.
- **DETACH CONCURRENTLY in flight.** Its first transaction commits `inhdetachpending`; both the pre-lock check and the
  re-read filter `not i.inhdetachpending`, so the call refuses whichever side of the lock the flag lands on. Held.

## Hypotheses (no reproduction)

- `docs/reference.md` locks paragraph: "so it refuses, naming the remedy: BEGIN ..., COMMIT (a session whose
  `default_transaction_isolation` is stricter included)". The parenthetical means the remedy works in such a session,
  but an operator can read it as "a stricter default is refused too", which the code does not do. Either reading leads
  the operator to type a remedy that works, so it is not a Tier 4 defect; a clearer wording would attach the
  parenthetical to the remedy explicitly.
- Under the live refusal, `adopt_partition(null, x)` in a REPEATABLE READ transaction meets the isolation message
  (rendering `<NULL>`) rather than `_refuse_null_arguments`' message, because the isolation check now runs first. No
  documented ordering between the two refusals; cosmetic. Cannot be shown on this tree (the refusal never fires here).
- A two-rename interleaving between `format('lock table %s', p_child::text)` rendering the name and the EXECUTE
  resolving it (another session renames child A to B and C to A in that gap) would lock C, leaving p_child unprotected
  for the re-read. The window is inside one backend with no wait point, so no deterministic reproduction; pre-existing
  and not introduced by the change.
