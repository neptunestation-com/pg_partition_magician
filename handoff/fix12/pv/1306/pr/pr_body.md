## Defect (#1258, Tier 1)

`transmute`, `untransmute` and `from_hypertable` refuse a `REPEATABLE READ` or `SERIALIZABLE` caller; `regrain()`, `regrain_history()` and `regrain_step()` did not. Under a stricter level every statement reads through the transaction's first snapshot, so:

- **F3-02.** `regrain_history()` (or `regrain()`) in a `REPEATABLE READ` transaction copied the monolith through the caller's old snapshot. A row another session committed after that snapshot, before the call installed change capture, was in no fine child, and the swap dropped it with the source (`{10,20}` left of `{10,20,500}`).
- **F3-04.** A hand `regrain_step` at the swap tick in a `REPEATABLE READ` transaction (or a `maintain` tick under a stricter `default_transaction_isolation`, which its transactions take after each COMMIT) ran the residual reconcile and `_regrain_delta_count` through the tick's first snapshot, so a writer's change captured after it was invisible and the source was dropped with a committed `UPDATE` unapplied (row 10 back to `orig`).

## Fix

One helper, `pgpm._regrain_refuse_strict_isolation(p_routine, p_parent)`, raises when `current_setting('transaction_isolation')` is not `read committed` / `read uncommitted`. It is asked up front, right after the null-argument refusal and before any lock or read, by:

- `regrain_step` (`pgpm_core/install.sql`, the one function every regrain driver goes through): so a hand step, every step of `regrain()`, and **`maintain`'s auto-regrain tick**, whose handler logs the refusal as `skip_regrain` and moves on (the run does not start or advance under a stricter default);
- `regrain()`, before its regrain lock and its `SHARE` lock, so a refusal waits for nothing and names `regrain`;
- `regrain_history()`, naming `regrain_history`.

Only the calling transaction's own level is asked. These are functions and commit nothing, so a stricter session default under an explicit `BEGIN ISOLATION LEVEL READ COMMITTED` reaches none of their reads and is accepted; `maintain` reaches the check because its post-COMMIT transactions take the default.

The message puts the remedy before the table's name and the reason, so the 200 characters `maintain`'s `skip_regrain` row keeps carry it whatever the table is called: `pg_partition_magician: regrain_step must run in a READ COMMITTED transaction (this one is repeatable read): set default_transaction_isolation = 'read committed' (ALTER ROLE or ALTER DATABASE ... SET it for maintain's scheduled ticks), open no REPEATABLE READ or SERIALIZABLE transaction around it, and re-run. It was to regrain <table>: ...`

`docs/reference.md` (`regrain`, `regrain_step`, `regrain_history`) states the refusal, the remedy and the `maintain` behaviour; its swap-wait section no longer contemplates "a `REPEATABLE READ` caller of `regrain`" (the reason given for not ignoring a peer wait's snapshot is now the other driver's statement snapshot, which a subquery beside the call can still read the table through).

## What it guarantees

No regrain driver (`regrain`, `regrain_history`, `regrain_step`, `maintain`'s auto-regrain through `regrain_step`) copies, reconciles or swaps in a `REPEATABLE READ` or `SERIALIZABLE` transaction; each refuses before taking a lock or reading anything, and the same call in `READ COMMITTED` proceeds. Not covered here: `regrain_cancel` (it discards copies, the source stays whole) and the `pgpm_hypertable` copy and drain step entry points (see the report's adjacent observations; unverified).

## Acceptance

- `tests/329_regrain_refuses_strict_isolation_test.sql` (38 assertions): A, F3-02's shape (regrain_history in `REPEATABLE READ`, row 500 committed after the snapshot), refused and nothing changed, then the remedy typed as the message says regrains with 10, 20 and 500 all kept; B, `regrain()` in `SERIALIZABLE`; C, F3-04's shape made deterministic (the writer's `UPDATE` of 10 and `DELETE` of 30 committed and captured after the caller's snapshot, invisible to it), the hand swap step refused, then driven on in `READ COMMITTED` it applies both; D, `maintain` from a session whose `default_transaction_isolation` is `REPEATABLE READ` logs `skip_regrain` with the remedy and copies nothing, then after `SET default_transaction_isolation = 'read committed'` (the remedy as typed) regrains with every row kept. Every negative is paired with a `LIVENESS:` premise. Green on PG 15 and PG 18.
- Guard `bench/regrain_refuses_strict_isolation.sh` (`pgpm_perf366`), the pgTAP wrapper the discriminate track runs.
- Mutations: `regrain_step_isolation_unchecked` (the step's call dropped: parts C and D fail) and `regrain_isolation_serializable_only` (the helper refuses `SERIALIZABLE` alone: parts A, C and D fail). Neither failure is a `LIVENESS:` line.

## Reproductions

Both run unchanged from the claim directories. On the base: F3-02 fails tests 4 and 5 (`{10,20}`), F3-04 fails its last check (`10=orig`), all premises passing. On this head both pass (F3-02 prints `regrain_history refused: ...`; F3-04's swap tick errors with the refusal and row 10 keeps `updated`). Against `regrain_isolation_serializable_only` both fail again; against `regrain_step_isolation_unchecked` F3-04 fails and F3-02 still passes, because `regrain_history` asks the helper itself.

Closes #1258

🤖 Generated with [Claude Code](https://claude.com/claude-code)

