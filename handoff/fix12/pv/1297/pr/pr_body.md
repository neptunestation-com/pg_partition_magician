## The defect (#1267, F6-03)

`pgpm._surface_prepare()`, the first thing `install.sql` runs, drops each function `pgpm._surface_shapes()` declares (`status()`, `progress(regclass)`, `observe_window(regclass, interval)`, `check_uuidv7(...)`, `check_text_time(...)`) whose installed shape CREATE OR REPLACE cannot replace, such as a pre-#343 `status()` without `regrain_to`. The file then creates it afresh, at its creator's default privileges. `_surface_unreplaceable()` weighs only pg_depend dependants, never the ACL, so the upgrade silently undid an operator's `REVOKE EXECUTE ... FROM PUBLIC` and `GRANT EXECUTE ... TO <monitoring role>`, against the #983 header's promise that the upgrade keeps the function's grants.

## The fix

- `_surface_prepare()`: a reshaped declared function with a non-default ACL (`proacl is not null`) is no longer dropped. It is renamed `pgpm._surface_kept_<name>` (same argument types; `ALTER ROUTINE ... RENAME`). One at the default ACL is dropped as before. If a stopped earlier run already kept one aside for that signature, the kept one holds the operator's grants and the currently installed function is dropped.
- `_surface_prepare()` also refuses up front (SQLSTATE `42501`, "Nothing has been changed", naming function, grantee and grantor) when such a function holds a grant another role made through a grant option and this session could not replay it as that role (`SET ROLE` membership, `SET` on 16+, plus the grantor's USAGE on `pgpm`; the `_acl_may_grant_as` rule, inlined because an older install has not created that helper yet when the prepare runs).
- New `pgpm._surface_carry_grants(sig)`, called right after **each of the five** declared functions' CREATE OR REPLACE: if a kept function exists for that signature, it revokes every grant the new function was created with (the owner's own included, as `_acl_reset` does for a relation), replays the kept function's grants in grant-option-chain order, each under its own grantor (one the kept function's owner made, by the installing role, the new owner; one another role made through a grant option, through `_acl_grant_as`, #903), then drops the kept function. Nothing kept: no-op, so a fresh install and an in-place replacement are untouched.
- `_surface_settled()` (end of file) also fails an install that leaves a kept function behind, naming the missing `_surface_carry_grants` call, so a sixth declared function added without its call fails loudly on the first upgrade that has grants on it.
- Docs: `docs/guide.md` upgrade paragraph, `CHANGELOG.md`.

What it guarantees: after a run of `install.sql` that completes, each of the five declared functions that had to be reshaped holds exactly the ACL its older shape held (PUBLIC revoked stays revoked, grants and grant options carried, a grant made through a grant option keeps its grantor). A run that stops between the prepare and the carry (no `--single-transaction`) leaves the older function, grants and all, as `pgpm._surface_kept_<name>`, and the next completed run carries them.

## Acceptance

- The issue's reproduction (F6-03 `repro.sh`, unchanged): fails on `main` (b76002e6) at its two contract lines (both LIVENESS lines pass), passes on this head, and fails again at the same two lines against the mutant `surface_prepare_drops_granted`.
- `tests/336_install_keeps_surface_grants_test.sql` (28 assertions). Part A: all five functions in an older shape with five different ACLs (PUBLIC revoked plus a grant; a grant option and a grant made through it; PUBLIC revoked alone; a plain extra grant; the default), each pinned by value before and after the re-run, plus the grantor's own REVOKE working afterwards. Part B: a run stopped after the prepare, carried by the next. Part C: the settle check. Part D: the up-front refusal for a session (the function's non-superuser owner) that cannot act as the grantor, nothing changed, then a superuser run that carries the grant.
- Guard `bench/install_keeps_surface_grants.sh` (`pgpm_perf375`, perf list), a pgTAP wrapper in the shape of `bench/retain_recall_moved_parent.sh`. Mutations: `surface_prepare_drops_granted` (the keep removed, the pre-fix shape: 11 assertions fail), `surface_carry_grants_as_owner` (every grant replayed as the owner: 4 fail), `surface_prepare_grantor_unchecked` (the up-front refusal removed: part D's refusal and "nothing changed" fail). No failing line of any is a LIVENESS line.
- Also run green locally on this head: `bench/install_keeps_dependent_views.sh` (#983's guard), `bench/doc_install_stops_on_error.sh`, `bench/upgrade_in_place.sh` (v0.6.0 upgrade, routines match a fresh install), `scripts/check_quoted_splices.py`, `scripts/check_living_docs.sh`, every mutation builds, shellcheck on the new guard.

## Caveats

- The new function's owner is the installing role (as before this change); the kept function's owner is not carried. Its grants are mapped onto the new owner, so with one role doing both (the usual case) the ACL is identical.
- Without `--single-transaction` (the documented command uses it), between a reshaped function's CREATE and the carry statement right after it, the new function holds its creator's default privileges.

Closes #1267

🤖 Generated with [Claude Code](https://claude.com/claude-code)

