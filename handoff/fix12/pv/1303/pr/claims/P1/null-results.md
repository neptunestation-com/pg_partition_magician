# Null results: P1, PR #1303

## Fresh surface

- `pgpm._disown_retirement`: read every line. The remedy's DROP names the relation the row records by `child_oid`,
  resolved to its current schema and name through `%I.%I`; verified on a parent `p1s."Ev T"` (non-public schema,
  quoted name) on both the install-pass path and `retire()`'s detached path that the statement as logged is valid SQL
  and drops the table (P1-01's check 7 passes). The fallback for a row with no `child_oid` goes through
  `_child_nsp`, the same resolution `_disown_unvouched_retirements` uses to find such a row, so the two agree.
  `v_parent_q` is computed and never used: the DELETE it was meant for is not in the method (P1-01).
- Every disown site logs through the one function: `retire()` (detached and pending branches), `_detach_reap`,
  `_retain_recall`, `_disown_unvouched_retirements`. Read all four; none composes a remedy of its own any more
  (the install pass's `v_why_q` lost the old half-remedy), so whatever `_disown_retirement` spells, every site
  spells it. The install pass and `retire()` were run (P1-01, tests/339); `_detach_reap` and `_retain_recall` were
  read only, as the body says.
- The DELETE's row identity: `pgpm.part`'s primary key is `(parent_table, child_name)` and nothing references
  `pgpm.part` by FK, so a `DELETE ... where parent_table = <parent>::regclass and child_name = <name>` (as the
  reference and tests/339 spell it) names exactly the one row and cannot be refused by a dependant; a namesake
  relation cannot produce a second row under the same parent. Nothing to claim here once the DELETE exists.
- The reference's `retire` entry, its upgrade paragraph and the log-action table all describe the two-statement
  remedy consistently with each other and with tests/339 and tests/327 C; what they disagree with is the code
  (P1-01).
- `bench/retain_disown_remedy.sh`: reports an install failure as FAIL, counts the assertions that ran, drops its
  database; `test.sh` lists it once under a database name (`pgpm_perf380`) no other guard uses.
- Unchanged behaviour the body claims: `fail_retain_identity` on a relation dropped under its row still fires on
  every call (P1-01's checks 9 and 10 show it on this tree), and what gets disowned and when is untouched (the
  disown conditions in all four sites are the #705 ones; tests/339's liveness checks 1-4, 13-16 pass).

## Operator error

- Typed the remedy exactly as the log row spells it (regex over the `method`, `\gset`, executed), on a quoted,
  non-public parent: the DROP works; the wedge that follows is the DELETE's absence (P1-01).
- Re-running the install pass after a disown: `_disown_unvouched_retirements` finds no mark (cleared) and logs
  nothing twice; `retain_disown` stays logged once per mark (tests/339 check 23 and the `retiring_at is not null`
  filter).
- Attaching back instead of dropping: `_retain_recall`'s disown text says "attach it back ... so retention retires
  it", which for a partition retention no longer reaches merely holds it attached; the statement is still a safe
  thing to type, so not claimed (hypothesis below).
- `DROP` on a pending partition before the detach finishes: PostgreSQL refuses a DROP of a partition pending detach
  under a concurrent detach's lock; the method says "once its detach is finished", consistent.

## Hypotheses (no reproduction)

- `_retain_recall`'s disown remedy inherits "attach it back ... so retention retires it"; when the recall fires,
  retention no longer reaches the partition, so attaching back keeps it rather than retiring it. Wording only; the
  action typed is harmless.
- tests/339 and tests/327 C extract the DROP with `drop table [^;]+;`; a partition name containing `;` would be
  cut short and the typed remedy would be broken SQL. Pathological names only; not built.
- `_disown_unvouched_retirements` filters `c.relname = p.child_name`, so a row whose relation was renamed after the
  mark is never disowned by the pass and stays marked until retire() reaches it; pre-existing, outside this PR's
  change.
