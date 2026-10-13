## Claim format

One directory per claim, grouped by finder. The finder writes it; nothing else does.

```text
<claims>/<finder>/<claim-id>/claim.json
<claims>/<finder>/<claim-id>/repro.sql            or repro.sh
<claims>/<finder>/<claim-id>/repro.verified.sql   or repro.verified.sh   (the verifier's, optional)
```

The one exception to "nothing else writes it": a verifier that changed the fixture or the assertions
stores its rebuilt reproduction as `repro.verified.sql` (or `.sh`) beside the finder's, which it never
edits. When that file exists, `classify_claims.py` runs it instead of the finder's (recording which in
each claim's `repro_used`), `file_issues.py` puts it in the issue, and so the closure run against the
fixed `main` re-runs the sound version.

```json
{"tier": 1, "file": "pgpm_core/install.sql", "line": 4671, "lens": "concurrency",
 "scenario": "one line: what happens and what should have happened",
 "repro": "repro.sql", "install": ["pgpm_core/install.sql"], "fixtures": false}
```

`install` lists the files to load into the fresh database before the reproduction (default: the core
install); `fixtures: true` also loads `fixtures/demo.sql`. The harness follows `install`: a list with
`pgpm_archive/install.sql` runs in the archive harness (`--archive-container`, default `pgpm_test-archive`),
one with `pgpm_hypertable/install.sql` in the timescale harness (`--timescale-container`, default
`pgpm_test-timescale`), anything else in `--container` (default `pgpm_test-15`); an optional `container`
field overrides that. A claim directory without a reproduction file is recorded as a **hypothesis** and is
never counted or filed; one whose `claim.json` is not valid JSON is an **invalid claim**, reported with its
path and not run, and does not stop the run (`--only` and `--finders` never open a claim outside their
selection at all).

## Reproduction contract

The reproduction runs twice, against the review tree and against the pristine commit, each time in a
fresh database in the harness container with the tree under test installed. It must **fail when the
defect is present** and pass when it is absent; that is what lets the same file later close the finding
against the fixed `main`.

- `repro.sql` is piped into `psql -v ON_ERROR_STOP=1`. Present means psql exited non-zero or a line
  began with `not ok`. pgTAP is fine: `create extension if not exists pgtap;` at the top.
- `repro.sh` runs on the host under `bash` with these in the environment: `PSQL` (a command prefix
  that connects to the fresh database, use it as `$PSQL -tAc "..."`), `TREE` (the tree under test),
  `DB`, `CONTAINER`. Non-zero exit means present. Use this for two-session probes, `docker exec`
  against a second connection, or anything a single psql stream cannot express.

Every reproduction holds **at least one `LIVENESS:` assertion**: a premise check that the state the
defect needs was actually reached. Name premise checks `LIVENESS: ...` (other setup checks may be
`GUARD: ...` or `fixture: ...`) and defect checks without a prefix. A failure of prefixed checks alone
reads as "the fixture never ran", not as the defect, so a negative cannot pass (or fail) because
nothing happened. The prefix is exactly one of those three, colon included and case as written: a
defect check described "guard trigger is gone" is a defect check, and so is a `not ok` with no
description at all. In a `repro.sh`, report each check on a line of its own (`ok - LIVENESS: ...`,
`not ok - the rows are gone`): a non-zero exit whose every `not ok` line is a prefixed check reads as
the fixture never ran, exactly as it does for a `repro.sql`. `classify_claims.py`
scans the reproduction's text for `LIVENESS:` and classifies a reproduction without one as
`invalid_repro` without running it.

A reproduction that needs the finder's own environment, a hand edit to pgpm, or a state pgpm refuses
to enter is not a reproduction; the verifier will record why it fell.

