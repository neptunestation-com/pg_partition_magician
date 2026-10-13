## Per-PR adversarial verification of `ba30f7a` (base `b76002e`)

**Landing: clear.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1267 acceptance (F6-03): re-running install.sql over an older install whose pgpm.status() has an earlier result shape drops and recreates it (_surface_prepare); _surface_unreplaceable counts only pg_depend dependants, never the ACL, so the operator's REVOKE EXECUTE FROM PUBLIC and GRANT EXECUTE TO f603_mon are silently lost and PUBLIC can execute status() again, where the section header promises the upgrade keeps the function's grants or refuses | yes | yes | `surface_carry_grants_as_owner`: NO; `surface_prepare_drops_granted`: yes; `surface_prepare_grantor_unchecked`: NO |  |

### Closing claim

**holds**: Tried to reach #1267's consequence (an operator's grants on a reshaped surface function lost by re-running install.sql) outside the diff. (1) Call sites: the five declared functions are each created exactly once in pgpm_core/install.sql (14255, 14315, 14441, 14606, 14760) and each is followed by its _surface_carry_grants call; pgpm_archive and pgpm_hypertable neither create nor reshape any of them; install.sql itself issues no grants on them; _surface_settled fails an install that leaves a kept function, so a sixth declared function without its call fails loudly. The other drop-and-recreate sites (signature-changing drops of transmute/obtain/from_hypertable etc.) change the signature, are outside the #983 surface promise the body covers, and are not this mechanism. (2) Upgrade/resume: the stopped-run path (kept exists, current function dropped only if still unreplaceable, else carried) is coherent; the only grant loss I could construct needs a downgrade to an older install.sql between a stopped run and the next, which pgpm does not document. The documented command is --single-transaction. (3) Body promises: ran on pgpm_prv-15 an older status() owned by a non-installing role with PUBLIC revoked, a grant option to v_ops and a grant v_ops made through it; after the re-run the new shape held {postgres=X/postgres, v_ops=X*/postgres, v_mon=X/v_ops} and v_ops's own REVOKE removed v_mon, so grantor and chain order are carried. The owner (and the old owner's implicit EXECUTE) is not carried, which the body's Caveats disclose. The 42501 refusal checks every grant-option grantor with the same SET/MEMBER plus USAGE rule _acl_may_grant_as uses, before anything is taken. (4) Mutations: surface_prepare_drops_granted alone restores the issue's defect (the acceptance repro fails on it); surface_carry_grants_as_owner and surface_prepare_grantor_unchecked do not, by design: they put back the grantor and the up-front refusal, sub-claims the issue repro does not exercise, and tests/336 parts A and D catch them per the PR. (5) Contract change: the only new refusal (42501) applies to grants an operator made through a grant option that the installing session cannot SET ROLE to, and the guide documents it with a remedy (run as a superuser). It is not a refusal of a documented workflow. No claim written.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | pgpm._surface_prepare() still drops every reshaped declared function whatever its ACL (its loop computes `granted` and `kept` and then runs `drop function` unconditionally; no ALTER ROUTINE ... RENAME to pgpm._surface_kept_<name> exists in the file), so nothing is ever kept aside, every _surface_carry_grants() call is a no-op, and re-running install.sql over an older install whose status() lacks regrain_to loses the operator's REVOKE EXECUTE FROM PUBLIC and GRANT EXECUTE TO a monitoring role: the #1267 defect the PR body, CHANGELOG, header comment (install.sql:56-60) and docs/guide.md:147-150 say is fixed; the prepare should have renamed the granted function to pgpm._surface_kept_status() and the re-run should have carried both grants |

### Seed witness

- S1 in `pgpm_core/install.sql` (surface_prepare_drops_granted): **found**

### Coverage and budget

- P1: 16 of 16 units read (1.00)
- surface: 6 file(s), 16 unit(s) in the ledger (touched units, their callers, touched files)
- budget: P1 finder ~103k tokens (16/16 units), claims verifier ~73k; acceptance F6-03; seed = the PR's mutation surface_prepare_drops_granted (caught by P1 as P1-01); grant-option chains, a kept owner other than the installer, default privileges and the v0.6.0 upgrade path probed by both agents

🤖 Generated with [Claude Code](https://claude.com/claude-code)
