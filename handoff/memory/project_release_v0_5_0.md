---
name: project-release-v0-5-0
description: "pgpm v0.5.0 released 2026-09-22 (tag e116076); first release carrying the #346 security fixes; its upgrade footgun is #347's pgpm_obtain cron job"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0bfe9ec5-03bb-432c-aea6-f666d65e1065
  modified: 2026-09-23T00:25:45.507Z
---

**v0.5.0 shipped 2026-09-22** (tag `v0.5.0` -> `e116076`, release PR #426). All four `release.yml`
jobs succeeded including `Publish to database.dev`. Assets: dbdev package (148,807 bytes), bundle,
tarball. 106 commits since v0.4.0 (2026-09-08).

**Why it mattered:** it was the first released artifact carrying the #346 campaign's five security
fixes (#405, #406, #407, #408/#409, #410). Until it shipped, everyone on the GitHub Release or
database.dev channel was pinned at v0.4.0 with none of them, while #346 itself was already closed.
Watch for that gap again: "every candidate resolved" can be true of the repo and false of what
anyone can install. See [[project_pgpm_security_hardening_campaign]].

**THE UPGRADE FOOTGUN, which the release notes lead with and which support questions will be
about:** #347 moved `obtain` out of `maintain()` into its own `pg_cron` job, and `pgpm.schedule()`
is operator-invoked, so **an existing install does NOT pick the new `pgpm_obtain` job up by
installing the new file**. Until `pgpm.schedule()` is re-run, nothing extends the forward grid, and
with no DEFAULT partition (#288) a write past the last bound is REFUSED. `maintain_all()` logs the
new `warn_obtain_unscheduled` action once per sweep and deliberately does not self-heal (an inline
fallback would reintroduce the hostage problem #347 removed). **If a pilot reports writes failing
after upgrading, this is the first thing to check.** See [[project_boardy_pilot]].

**Release mechanics worth not re-deriving:**

- Release goes through a `chore/release-vX.Y.Z` PR, merged, THEN tag `main`. Tagging the branch
  would put the release on a commit not on main.
- Three version carriers must agree: `pgpm.version()` in install.sql, `default_version` in
  extension.control, and the git tag. Tag the full triple (the CI regex accepts `v0.5`).
- `release.yml` matches `## [X.Y.Z]` in CHANGELOG.md EXACTLY and silently falls back to a raw git
  log dump when it cannot find it. Check the heading before tagging.
- Leave an empty `## [Unreleased]` heading above the new section.
- `apt.postgresql.org` flaked mid-release and failed only the `PostgreSQL 15` job. Diagnosed, not
  assumed: two OTHER PG15 jobs on the same PR (pg_flight_recorder, TimescaleDB) built the identical
  image and passed, and the local `./test.sh ci` gate passed. Re-ran, green. **That cross-check is
  the right way to tell a runner flake from a real break.**
