## Per-PR adversarial verification of `cf9bc47` (base `b76002e`)

**Landing: clear.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1265 acceptance (F2-02): check_time_monotonic casts a naive timestamp time column to timestamptz in the caller's session zone before comparing adjacent pairs, so a column whose values increase with the id (01:50, 02:30, 03:15 on 2026-03-08) reports fraction 0.5 from an America/New_York session (02:30 is in the spring-forward gap and casts past 03:15 EDT) and 1.0 from UTC; it should compare the column's own values (or cast in one fixed zone) so the documented fraction of non-decreasing pairs does not depend on who runs it | yes | yes | `check_time_monotonic_session_zone`: yes |  |

### Closing claim

**holds**: 1) Call sites: grep of head (pgpm_core, pgpm_archive, pgpm_hypertable, uninstall) finds check_time_monotonic called by nothing in pgpm (only tests and bench), so the SET timezone clause covers every entry point; the only other %I::timestamptz splice is archive's parquet writer at pgpm_archive/install.sql:2087-2100, which already documents and handles naive timestamp separately (and archive._row_digest already pins UTC), a different mechanism not reopened here. 2) Upgrade path: installed base then head over it in pgpm_prv-15; CREATE OR REPLACE carries proconfig {TimeZone=UTC}. No resume or scheduled path reaches the function (it is a stateless, read-only advisory call). 3) Body promises: built a naive timestamp fixture spanning New York's fall-back repeated hour and an October Lord_Howe half-hour DST change (asymmetric: 2 rises, 2 falls); head reports (4,2,0.5000) identically from America/New_York, Australia/Lord_Howe, UTC and inside a transaction, and the caller's TimeZone is restored. Text values whose meaning is zone-relative ('today' etc.) now resolve in UTC for every caller, so they no longer vary by caller. DateStyle dependence is disclosed in the body as out of scope and is not a TimeZone path. 4) The single mutation removes exactly the SET clause, i.e. restores the issue's defect itself (acceptance repro fails on it); tests/335 asserts fractions and identities from two zones plus asymmetric fixtures, i.e. the contract, not a spelling. 5) The reference.md addition documents the behaviour as zone-independent; no documented workflow is refused. No path to the issue's consequence survives.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | pgpm.check_time_monotonic on this tree carries no function-level SET timezone = 'UTC' clause (proconfig is null) although the comment above it, CHANGELOG.md, docs/reference.md and the PR body all say it does, so %I::timestamptz still casts a naive timestamp column in the caller's zone and a four-row column whose only falling pair straddles New York's spring-forward gap reports (3,3,1.0000) from America/New_York and (3,2,0.6667) from UTC; the documented fraction of non-decreasing pairs should be (3,2,0.6667) from every session zone |

### Seed witness

- S1 in `pgpm_core/install.sql` (check_time_monotonic_session_zone): **found**

### Coverage and budget

- P1: 7 of 7 units read (1.00)
- surface: 6 file(s), 7 unit(s) in the ledger (touched units, their callers, touched files)
- budget: P1 finder ~77k tokens (7/7 units), claims verifier ~48k; acceptance F2-02; seed = the PR's own mutation check_time_monotonic_session_zone (caught by P1 as P1-01)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
