# P1 null results: PR #1297 (keep the grants on a surface function the upgrade reshapes)

Harness: `pgpm_prv-15` (PostgreSQL 15), fresh databases `prv_p1_x1` and `prv_p1_x2`, both dropped.

## Lens: fresh surface

- `pgpm._surface_prepare` (install.sql:138-180). Read whole. The refusal of dependants (unchanged) and the
  new up-front grantor refusal (`42501`, "Nothing has been changed") were read against `_acl_may_grant_as`
  (install.sql:9962): the inlined rule is the same (`pg_has_role(session_user, grantor, SET|MEMBER)` and the
  grantor's USAGE on the function's schema). The final loop is NOT what the PR body, CHANGELOG, header
  comment and guide describe: it selects `granted` and `kept` and then drops unconditionally. Claim P1-01.
- `pgpm._surface_sig_kept`: `regexp_replace(sig, '^pgpm\.', 'pgpm._surface_kept_')`; checked that it maps
  each of the five declared signatures to a name with the same argument types, and that `_surface_settled`
  and `_surface_carry_grants` use the same helper, so the three agree on the kept name. Held.
- `pgpm._surface_carry_grants`, exercised in isolation by keeping `status()` aside by hand (ALTER FUNCTION
  RENAME to `_surface_kept_status`, then recreating the declared shape from `pg_get_functiondef`) and
  calling the carry: (a) PUBLIC revoked plus a grant to a monitoring role: new ACL equals the kept one, kept
  dropped; (b) a three-deep grant-option chain (owner > p1_ops* > p1_r3* > p1_mon) with PUBLIC present: every
  grant replayed under its own grantor in chain order, and p1_r3 could afterwards revoke the grant it made;
  (c) kept function owned by another role (p1_inst) with grants it made and a grant made TO it through a
  grant option: grantor and grantee both mapped onto the new owner (`{postgres=X/postgres, p1_mon=X/postgres,
  p1_ops=X*/postgres, postgres=X/p1_ops}`), as the body's caveat says; (d) default privileges on the installing
  role giving the new function an extra birth grant (to p1_r3): revoked, exactly the kept ACL replayed;
  (e) a kept ACL of `{}` (everything revoked, the owner's included): the new function ends at `{}`. All held.
  No-op on a fresh install (nothing kept) confirmed by the five calls in a fresh install returning without
  effect.
- `pgpm._surface_settled`: the kept-left-behind check reads the same `_surface_sig_kept` name; its message
  names the carry call with the signature quoted. Held (and only reachable by hand in this tree, since the
  prepare never keeps).
- The five carry call sites (14278, 14382, 14558, 14722, 14784): each sits directly after its function's
  `CREATE OR REPLACE` closing `$$;`, one per declared function, signatures match `_surface_shapes()` by
  text; `_acl_grant_as` (9979) is created earlier in the file than the first call. Held.
- `tests/336_install_keeps_surface_grants_test.sql`, `bench/install_keeps_surface_grants.sh`, `test.sh`
  (perf list entry), `CHANGELOG.md`, `docs/guide.md:147-150`: read whole. The test's parts A and B assert
  the keep that this tree's prepare does not do, so on this tree the file cannot pass; that is the same
  root cause as P1-01, not a separate Tier 5 (the test does discriminate). The guard counts assertions run
  and fails a mutant that does not install. Held otherwise.

## Lens: upgrade and install paths

- Fresh install of the tree under `--single-transaction`: completes, `_surface_settled` passes, every
  `_surface_carry_grants` call a no-op. Held.
- Re-run over an install whose `status()` has the pre-#343 shape and a non-default ACL: the grants are lost
  (claim P1-01). With the default ACL: dropped and recreated as before, as documented.
- Order of creation on an older install: `_surface_sig_kept` (183) and `_surface_carry_grants` (195) are
  created before `select pgpm._surface_prepare()` (268) runs, and `_acl_grant_as` (9979) before the first
  carry (14278), so a v0.6.0 install that lacks them is not a problem for the mechanism as designed. Held.
- A grantor that no longer exists: not reachable (PostgreSQL refuses to drop a role that holds or made a
  grant on an object). A grantor that is not the owner is exactly the grant-option case, probed above.
- The #983 dependants keep: the refusal of a view over a reshaped function runs first and unchanged;
  nothing new is taken before it. Held.

## Hypotheses (no reproduction)

- Under `ALTER DEFAULT PRIVILEGES ... IN SCHEMA pgpm REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`, a reshaped
  function at the DEFAULT ACL (proacl null) is dropped and recreated, and PostgreSQL merges schema-specific
  default privileges with the built-in default, so the new one is born with PUBLIC EXECUTE where the
  operator's intent was otherwise. That is PostgreSQL's documented behaviour, and the older function had
  the same ACL, so nothing of its ACL is lost; not a claim.
- The body's caveat (kept owner not carried, grants mapped onto the new owner): a non-superuser previous
  owner loses its own EXECUTE when a different role runs the upgrade. Documented in the body; not probed
  as a claim.
