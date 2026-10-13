## Per-PR adversarial verification of `71f2e91` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- P1-02: pre_existing with no verdict yet (unverified is not clear)
- V-01: pre_existing with no verdict yet (unverified is not clear)
- closing claim: partial (The round-2 check (lock the schema-qualified name, then to_regclass(name) = p_child under the lock) rests on 'a rename takes ACCESS EXCLUSIVE, which the held lock conflicts with'. That covers ALTER TABLE RENAME but not ALTER SCHEMA RENAME, which takes no relation lock. V-01 (Tier 3, deterministic, i); standing on V-01

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1262 acceptance (ACC-01-1295): #1262 acceptance (F4-03): adopt_partition's attached/not-pending checks (before and after its SHARE UPDATE EXCLUSIVE on the partition) read pg_inherits through the transaction snapshot, so a REPEATABLE READ caller whose snapshot predates a committed DETACH records the detached table in pgpm.part as an attached partition; the header promises 'the relation judged attached is still attached when its row commits' and retire()/_archive_hold_partition ask pg_partition_ancestors (the catalog as of the lock) for this reason | yes | yes | `adopt_partition_lock_name_unchecked`: NO; `adopt_partition_strict_isolation_admitted`: yes |  |
| `ACC-02` #1262 acceptance (ACC-02-1295): #1262 acceptance (F11-03): adopt_partition's attached check and its re-read under SHARE UPDATE EXCLUSIVE both read pg_inherits under the caller's snapshot, so in a REPEATABLE READ transaction whose snapshot predates another session's committed DETACH it records the detached table in pgpm.part as attached (the READ COMMITTED call on the same state refuses); it should re-read the catalog fresh after the lock, as the archive hold was fixed to (archive_hold_recheck_by_snapshot), or refuse a non-READ COMMITTED caller | yes | yes | `adopt_partition_lock_name_unchecked`: NO; `adopt_partition_strict_isolation_admitted`: yes |  |
| `ACC-03` #1262 acceptance (V-01-1295): adopt_partition takes its SHARE UPDATE EXCLUSIVE lock by NAME (lock table p_child::text), so when another session renames the partition and creates a standalone table under its old name, committing while the call waits, LOCK TABLE re-resolves the name and locks the new table; the oid re-read (READ COMMITTED, fresh) passes, the row is recorded with no lock on the relation it records, a DETACH commits before the caller's transaction does, and pgpm.part records a standalone table as a partition at commit (the #1262 consequence, in READ COMMITTED), against the header's 'the relation judged attached is still attached when its row commits'; it should lock by oid and verify the name resolution | yes | yes | `adopt_partition_lock_name_unchecked`: yes; `adopt_partition_strict_isolation_admitted`: NO |  |

### Closing claim

**partial**: The round-2 check (lock the schema-qualified name, then to_regclass(name) = p_child under the lock) rests on 'a rename takes ACCESS EXCLUSIVE, which the held lock conflicts with'. That covers ALTER TABLE RENAME but not ALTER SCHEMA RENAME, which takes no relation lock. V-01 (Tier 3, deterministic, in READ COMMITTED): the partition's schema is swapped with one holding a partitioned table S of the same name while the call waits, so LOCK TABLE re-resolves the name onto S, then recurses into S's partition and waits there; meanwhile the schemas are swapped back, so the check sees the name denote p_child and passes with no lock on p_child; the row is recorded, a DETACH of p_child commits before the call's transaction (detach succeeds, no 55P03), and pgpm.part records a standalone table at commit, the #1262 consequence, against body guarantee (2). It fails identically on the head, the base and the adopt_partition_lock_name_unchecked mutant (assertions 6 and 8, every LIVENESS passes), so it is pre_existing inside the PR's surface. What held: the asked attacks all refuse on the head: two renames in a row (squatter renamed again and a second squatter created, the squatter a partition of another parent q): refused, nothing recorded; the parent table renamed into the partition's name (LOCK on a partitioned table recurses into p_child): refused; a rename back after the squat cannot reach the check with the lock on the squatter, because the squatter is held SHARE UPDATE EXCLUSIVE and LOCK TABLE re-resolves at grant (no table-rename gap); a DETACH between the check and the row's commit waits and times out 55P03 (ACC-03 verified, assertion 8). Isolation refusal: sound (transaction_isolation, not the default; READ UNCOMMITTED is RC). Other entry points: nothing in pgpm calls adopt_partition; the archive and hypertable modules have no copy; other by-name locks in install.sql (10911, 11059, 11876, 12306) are on parents and outside this bullet. Mutations: adopt_partition_strict_isolation_admitted alone restores F4-03/F11-03 (ACC-01 fails); adopt_partition_lock_name_unchecked alone restores round 1's V-01 (ACC-03 verified fails), each puts back its own defect. ACC-03: premise_removed shape confirmed (its LIVENESS step 3 needs the call to record the row; on the head the call refuses, so its defect checks lose their premise); rebuilt as claims/ACC/ACC-03/repro.verified.sql pinning the contract (refuses naming v1_x_old, nothing recorded, no adoption logged, the remedy as typed records it, a DETACH meanwhile gets 55P03, after commit recorded by oid and attached with rows 950,960). Results: base FAILS (6 of 9: assertions 4-9, no LIVENESS), head PASSES 9 of 9, mutant adopt_partition_lock_name_unchecked FAILS (6 of 9: 4-9, no LIVENESS). No open issue names a schema rename against adopt_partition's lock (#1057 is capture's rename race, #768 resolution by name in other functions).

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | adopt_partition's isolation refusal is shipped as `if false then raise ...` (the PR's own strict_isolation_admitted mutant shape), so a SERIALIZABLE or REPEATABLE READ caller is admitted and a stale-snapshot caller records a detached table in pgpm.part; the body, CHANGELOG and docs/reference.md promise the refusal and tests/332 parts A-D fail on this tree (9 of 25) |
| `P1-02` | 4 | pre_existing | unverified | a partition renamed (no squatter) while adopt_partition waits for its lock is refused by LOCK TABLE's own 42P01 `relation "public.old" does not exist`, naming the old name as non-existent; docs/reference.md promises the call names the partition as it is now for exactly this case (only the squatter path does) |
| `V-01` | 3 | pre_existing | unverified | #1262 round 2 (closing claim): adopt_partition locks p_child by its schema-qualified NAME and then checks to_regclass(name) = p_child, relying on 'a rename takes ACCESS EXCLUSIVE, which the held lock conflicts with'. A SCHEMA rename takes no relation lock. When the partition's schema is renamed away and another schema (holding a partitioned table S of the same name) renamed into its place, committed while the call waits, LOCK TABLE re-resolves the name and locks S, then recurses into S's partitions and waits on one; while it waits the schemas are renamed back, so the check under the lock sees the name denote p_child and passes with NO lock on p_child. The re-read by oid (READ COMMITTED) finds it attached, the row is recorded, a DETACH of p_child commits before the call's transaction, and pgpm.part records a standalone table as a partition at commit, in READ COMMITTED, against the header's 'the relation judged attached is still attached when its row commits' and the body's guarantee (2). Deterministic (every order set by a lock queue, witnessed in pg_locks). It should hold a lock on the oid p_child itself (e.g. lock by oid, or verify the lock in pg_locks/by oid after LOCK) rather than infer it from the name. |

<details><summary><code>P1-02</code> pre_existing: tails</summary>

base:
```
-----------------------------------------------------------------------------------------------------------------
 not ok 6 - the refusal names the partition as it is now (p102_w_now), as docs/reference.md says it does        +
 # Failed test 6: "the refusal names the partition as it is now (p102_w_now), as docs/reference.md says it does"
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 6
(1 row)
```
head:
```
-----------------------------------------------------------------------------------------------------------------
 not ok 6 - the refusal names the partition as it is now (p102_w_now), as docs/reference.md says it does        +
 # Failed test 6: "the refusal names the partition as it is now (p102_w_now), as docs/reference.md says it does"
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 6
(1 row)
```

</details>

<details><summary><code>V-01</code> pre_existing: tails</summary>

base:
```
 dblink_disconnect | dblink_disconnect | dblink_disconnect 
-------------------+-------------------+-------------------
 OK                | OK                | OK
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 8
(1 row)
```
head:
```
 dblink_disconnect | dblink_disconnect | dblink_disconnect 
-------------------+-------------------+-------------------
 OK                | OK                | OK
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 8
(1 row)
```

</details>

### Seed witness

- S1 in `pgpm_core/install.sql` (adopt_partition_strict_isolation_admitted): **found**

### Coverage and budget

- P1: 7 of 7 units read (1.00)
- surface: 6 file(s), 7 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 2: P1 ~96k tokens (7/7 units), claims verifier ~84k (live); acceptance: round 1's two rebuilt reproductions and round 1's V-01 rebuilt to the refusal (fail base, pass head, fail mutant adopt_partition_lock_name_unchecked); seed caught; two renames, a rename back and a DETACH between check and commit all refused on the head; BLOCKED on the closing claim: partial, V-01 (round 2): ALTER SCHEMA RENAME takes no relation lock, so a schema swap during the lock wait lands the lock on a same-named table and the name check passes without a lock on p_child (Tier 3, pre-existing); P1-02 (Tier 4): a rename without a squatter refuses with LOCK TABLE's 42P01 on the old name against the reference's wording; both go to the fixer for round 3 (a pg_locks witness on p_child's oid)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
