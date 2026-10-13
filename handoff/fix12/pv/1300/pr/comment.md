## Per-PR adversarial verification of `2a721d2` (base `b76002e`)

**Landing: clear.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1270 acceptance (F1-06): a text_time transmute re-run with another encoding (here p_tt_epoch one day earlier) takes over the earlier attempt's claim, which checks the column (#628) and the grid (#574) but not the encoding, skips phase 1 because a pgpm_monolith_bound CHECK in the old encoding exists, and the cutover's ATTACH with bounds in the new encoding scans the table under ACCESS EXCLUSIVE and dies raw (partition constraint violated) after the bound and claim are committed; it should be refused up front in pgpm's words, as a resume on another column is | yes | yes | `transmute_resume_any_encoding`: yes |  |

### Closing claim

**holds**: (1) Call sites: transmute_inflight is written only by pgpm._transmute's claim insert (grep of pgpm_core, pgpm_archive, pgpm_hypertable, uninstall.sql); pgpm_hypertable has no text_time at all, pgpm_archive reads config only; the reaper and transmute_abort drop CHECK and claim together, so no claim-less stale CHECK is reachable through pgpm (only via uninstall without the abort that uninstall.sql's header requires first). (2) Resume arms: ran live on pgpm_prv-15 the ACC fixture extended to the DEAD-OWNER arm (first session disconnected, re-run from a new session in America/New_York with the epoch a day earlier): head refuses in pgpm's words before anything commits; base dies raw 'partition constraint of relation f1tt_p2026_10_12 is violated'. The same encoding respelled from that session (epoch '1969-12-31 19:00:00-05', default alphabet written out) resumes, logs transmute_resume, converts and keeps rows 1..20. Upgrade path: a claim recorded before the column exists is null and unchecked, which the body's caveat, the column comment and reference.md's transmute_inflight table all document, the same as #628's control_attnum, so it is documented behaviour and not a claim. Scheduled path: maintain/obtain never resume a transmute claim. (3) Normalisation checked against the encoder: _radix_encode's null alphabet is exactly substr('0-9a-z',1,radix), the one the record writes out; _ts_to_text_time reads epoch only as an instant (p_ts - p_epoch), so extract(epoch) is exact; p_tz is ignored by the text_time encoder and the claim's zone is adopted anyway; unit is limited to ms/s and discard_bits is non-null; the record covers every parameter the encoder reads. I found no case where two different encodings compare equal. (4) The single mutation removes only the comparison, which puts back exactly this defect (the ACC reproduction fails on it). (5) The doc change refuses only a re-run that could not have succeeded (its ATTACH would scan and fail or block), and it names the remedy (transmute_abort). No surviving path, so no V claims.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | pgpm._transmute records text_time_encoding on a fresh claim and reads the claim's into v_claim_tt_encoding on a take-over, but never compares the two: a resume under another p_tt_epoch (or any p_tt_*) takes the claim over, skips phases 1 and 2 on the old-encoding validated CHECK, and the cutover's ATTACH scans under ACCESS EXCLUSIVE and dies raw ('partition constraint ... is violated by some row'), exactly #1270's defect; PR #1300's body, CHANGELOG, guide.md, reference.md and tests/337 all promise it is refused up front in pgpm's words naming both encodings and the remedy |

### Seed witness

- S1 in `pgpm_core/install.sql` (transmute_resume_any_encoding): **found**

### Coverage and budget

- P1: 11 of 11 units read (1.00)
- surface: 8 file(s), 11 unit(s) in the ledger (touched units, their callers, touched files)
- budget: P1 finder ~134k tokens (11/11 units, pgpm._transmute read whole), claims verifier ~82k (the dead-owner resume arm run live); acceptance F1-06; seed = the PR's mutation transmute_resume_any_encoding (caught by P1 as P1-01)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
