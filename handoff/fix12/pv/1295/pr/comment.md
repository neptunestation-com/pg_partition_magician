## Per-PR adversarial verification of `efdbc0b` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- closing claim: partial ((1) Entry points: adopt_partition has one, and nothing in pgpm_core/pgpm_archive/pgpm_hypertable calls it. The new inline refusal fires before the null check and every lock. Under READ COMMITTED a volatile plpgsql function takes a fresh snapshot per statement, so every read the body makes after the ); standing on V-01

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1262 acceptance (F4-03): adopt_partition's attached/not-pending checks (before and after its SHARE UPDATE EXCLUSIVE on the partition) read pg_inherits through the transaction snapshot, so a REPEATABLE READ caller whose snapshot predates a committed DETACH records the detached table in pgpm.part as an attached partition; the header promises 'the relation judged attached is still attached when its row commits' and retire()/_archive_hold_partition ask pg_partition_ancestors (the catalog as of the lock) for this reason | yes | yes | `adopt_partition_strict_isolation_admitted`: yes |  |
| `ACC-02` #1262 acceptance (F11-03): adopt_partition's attached check and its re-read under SHARE UPDATE EXCLUSIVE both read pg_inherits under the caller's snapshot, so in a REPEATABLE READ transaction whose snapshot predates another session's committed DETACH it records the detached table in pgpm.part as attached (the READ COMMITTED call on the same state refuses); it should re-read the catalog fresh after the lock, as the archive hold was fixed to (archive_hold_recheck_by_snapshot), or refuse a non-READ COMMITTED caller | yes | yes | `adopt_partition_strict_isolation_admitted`: yes |  |

### Closing claim

**partial**: (1) Entry points: adopt_partition has one, and nothing in pgpm_core/pgpm_archive/pgpm_hypertable calls it. The new inline refusal fires before the null check and every lock. Under READ COMMITTED a volatile plpgsql function takes a fresh snapshot per statement, so every read the body makes after the lock is current. The refusal itself holds. (2) Resume, upgrade and scheduled paths do not apply: it is a function, replaced by CREATE OR REPLACE, with no tick caller. (3) The body says 'every judgement after that lock ... is only worth the lock when its snapshot was taken after the lock was granted' and the header promises 'the relation judged attached is still attached when its row commits'. That promise breaks in READ COMMITTED because the lock is taken BY NAME: execute format('lock table %s ...', p_child::text). When another session renames the partition and creates a standalone table under the old name, committing while the call waits on that name, LOCK TABLE re-resolves the name after the wait and locks the new table. The oid re-read then passes (a fresh snapshot, the partition still attached), and the row is recorded with no lock on the relation it records. A DETACH then commits before the caller's transaction does, so pgpm.part records a standalone table as a partition, which is #1262's consequence. V-01 shows this on the head and the base alike (pg_locks: 0 locks on the recorded oid; pg_inherits: not a partition at commit). It is pre_existing, Tier 3, and inside the PR's surface (the function and the lock its argument relies on), with a different mechanism (name versus oid), so it does not block landing as a T1/T2 would. (4) The guard asserts the contract (refused, nothing recorded, LIVENESS witnesses). The single mutation (if false) restores this defect exactly: ACC-01 and ACC-02 fail on the mutant. (5) Contract change: an RR/SERIALIZABLE caller is now refused with a named remedy. That workflow was never documented as supported, and the change is in reference.md and CHANGELOG. EXTRA TASK: the acceptance reproductions' head failures come from the fix changing what the reproduction observes, not from a failure to fix. ACC-01 pinned the membership message, and the head refuses earlier with the isolation message while assertion 5 (nothing recorded) passes. ACC-02 called adopt_partition bare in REPEATABLE READ, so the refusal aborted psql before the contract assertion ran. Both were rebuilt as repro.verified.sql, pinning pgpm's refusal ('pg_partition_magician: %') plus nothing recorded, with LIVENESS kept. Results: ACC-01 base FAIL (3,5), head PASS 5/5, mutant FAIL (3,5); ACC-02 base FAIL (3,5), head PASS 7/7, mutant FAIL (3,5).

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | adopt_partition's new READ COMMITTED refusal is dead (its condition is the constant false), so a REPEATABLE READ caller whose snapshot predates a committed DETACH or RENAME is admitted and records the detached table (or the old name) in pgpm.part as a partition of the parent, where the header, docs/reference.md and the CHANGELOG say it refuses before taking any lock |
| `V-01` | 3 | pre_existing | finding T3 | adopt_partition takes its SHARE UPDATE EXCLUSIVE lock by NAME (lock table p_child::text), so when another session renames the partition and creates a standalone table under its old name, committing while the call waits, LOCK TABLE re-resolves the name and locks the new table; the oid re-read (READ COMMITTED, fresh) passes, the row is recorded with no lock on the relation it records, a DETACH commits before the caller's transaction does, and pgpm.part records a standalone table as a partition at commit (the #1262 consequence, in READ COMMITTED), against the header's 'the relation judged attached is still attached when its row commits'; it should lock by oid and verify the name resolution |

<details><summary><code>V-01</code> pre_existing: tails</summary>

base:
```
 dblink_disconnect | dblink_disconnect 
-------------------+-------------------
 OK                | OK
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 6
(1 row)
```
head:
```
 dblink_disconnect | dblink_disconnect 
-------------------+-------------------
 OK                | OK
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 6
(1 row)
```
Verifier: adopt_partition locks its partition by rendered NAME (execute format('lock table %s ...', p_child::text), head install.sql ~14034), so when a concurrent session renames the partition and gives the name to a new table, committing while the call waits, LOCK TABLE re-resolves the name after the wait and locks the new table instead of p_child; the oid re-read passes and the row commits with no lock on the relation it records, so a DETACH commits first and pgpm.part records a standalone table as attached. Breaks the header's 'the relation judged attached is still attached when its row commits' and reference.md's 'the partition cannot be detached or dropped between the check and the row'. Reproduced on base and head with the classifier (READ COMMITTED; LIVENESS: the call is seen waiting on a Lock, records the oid, and holds 0 locks on it). Distinct by mechanism from #1262 (snapshot reads, closed by the PR's READ COMMITTED refusal) and from #1061 (capture fast path's handler for non-lockable relations). Tier 3 as #1262: bookkeeping wrong at commit, no rows lost. Finder's repro run unchanged.

</details>

To file as issues (verified; below Tier 2, or outside the surface the PR touched; not held against this PR): `V-01`

### Seed witness

- S1 in `pgpm_core/install.sql` (adopt_partition_strict_isolation_admitted): **found**

### Coverage and budget

- P1: 7 of 7 units read (1.00)
- surface: 6 file(s), 7 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 1: P1 ~110k tokens (7/7 units), claims verifier ~75k, V-01 verifier ~56k; acceptance F4-03 and F11-03 rebuilt by the claims verifier to the refusal's contract (fail base, pass head, fail mutant); seed caught; BLOCKED on the closing claim: partial (V-01, the by-name LOCK TABLE), fixer round 2 in progress

🤖 Generated with [Claude Code](https://claude.com/claude-code)
