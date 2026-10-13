---
name: dbdev-package-cap
description: database.dev (dbdev/TLE) caps a package's SQL at 250,000 chars via an undocumented varchar(250000) column; pgpm's minified core crossed it 2026-10-01; cap is informational on main, strict for publishing (PR #764, issue #765); user's stance on the channel
metadata:
  type: project
---

database.dev stores each package version's SQL in `varchar(250000)` (supabase/dbdev,
`supabase/migrations/20220117142137_package_tables.sql`, also package_upgrades). Nothing in its docs says so; the user
confirmed pg_flight_recorder hit the same limit by publishing. pgpm's minified `pgpm_core/install.sql` was 242,880 at
47a293a and crosses the cap with pass 5's core fixes (~268k). Since PR #764 the strict check runs only in
`publish-dbdev.yml`; the Test Suite's "dbdev package size (informational)" job (not required, always green) reports the
size in its job summary and raises a `::warning::` annotation while over; `PGPM_DBDEV_CAP=warn` elsewhere. Issue #765 has the breakdown (32% literal text, 30,665 chars of raise messages)
and the remedies (split into two TLE extensions, or cut ~20k).

**Why:** the user's words, 2026-10-01: the dbdev channel "is of dubious value and nobody has never used it yet, not for
pgfr or for pgpm. Nevertheless, we don't want to give it up so easily, but we also don't want to be hidebound by it.
We'll deal with it later."

**How to apply:** do not let the cap block a fix; do not remove the channel or its strict publish check either. A
release that wants to publish to dbdev must first pick a remedy on #765. An advisory CI job must stay green and speak
through `::warning::` and the job summary: land.sh stops on any failed check it cannot match to a known flake. See
[[fix5-phase]].
