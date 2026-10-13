---
name: next-issue-326
description: "Issue #326 (set_obtain/set_retain): implemented & MERGED (PR #375, squash-merged 2026-09-13)"
metadata:
  type: project
  originSessionId: 232f6d97-aa11-4a2d-98f5-e80e969d8822
  modified: 2026-09-14T05:06:16.164Z
---

**UPDATE 2026-09-13: implemented and MERGED.** `pgpm.set_obtain(p_parent, p_obtain)` and
`pgpm.set_retain(p_parent, p_retain default null)` landed in `pgpm_core/install.sql`, exactly per the
locked-in decision below (set_retain refuses, not warns). Tests `tests/97_set_obtain_test.sql` (6
assertions) and `tests/98_set_retain_test.sql` (15 assertions). Docs updated (`reference.md`,
`guide.md`, `CHANGELOG.md`) and two raw `update pgpm.config` examples in `guide.md`/`runbook.md` fixed
to use the new setters. `./test.sh 17 --channel=psql` and the full `./test.sh ci` matrix both green;
all CI checks (including timescale/observe/archive/perf tracks) passed on the PR itself. **PR #375
squash-merged into `main`** (David: "looks ready to merge"), branch `feat/set-obtain-set-retain`
deleted both locally and on origin. Everything below this line is the original scoping note, kept for
the "why" behind the design (refuse-by-default rationale, signature shapes, why #326 was picked over
the alternatives).

After [[project_next_issue_290]] merged (PR #374), surveyed the remaining open issues (#326, #343,
#344, #345, #346's ranked list, #347, #156) and recommended **#326** as next.

**The gap.** `obtain` and `retain` are settable only at `pgpm.transmute` time (`p_obtain`/`p_retain`).
Changing either afterward requires a raw `update pgpm.config set obtain = ...` -- no validation, no
units check against `control_kind`, not covered by any test or refusal. `set_regrain`/`pause`/`resume`
exist as first-class wrappers precisely so operators never hand-edit `pgpm.config`; `obtain`/`retain`
are more consequential (retain decides what gets DROPped) and have no equivalent.

**Why #326 over the alternatives:**

- **#343** (observability: transmute-to-freeze / regrain progress triangulation) -- real pain, but
  the issue itself says "needs real design thought" and lists open-ended possible directions, not a
  spec.
- **#345** (bench harness measuring transmute phase-3 / regrain_step swap durations, to decide
  whether #344's deferred reorders are worth the risk) -- fully spec'd with acceptance criteria, but
  it's a measurement tool that produces a recommendation, not a fix; explicitly "do not implement
  the reorder in this issue."
- **#344** (transmute cutover: hoist grants/RLS/policies/comments/identity before the rename) and
  **#347** (split `obtain` out of `maintain_all` into its own cron job) -- both large, invasive,
  already passed over twice before (see [[project_next_issue_290]]) for the same reason: bigger
  blast radius, real correctness risk, need proof/design work first (#345 exists specifically to
  produce that proof for #344).
- **#346's ranked security list** -- per [[project_pgpm_security_hardening_campaign]], wait for
  David to pick an item off that list; it is scope, not a queue to work through unprompted.
- **#156** (from_hypertable: compressed/Community-edition hypertable support) -- a different
  subsystem (`pgpm_hypertable`), plausible but not raised as a priority.

**#326 is contained and fully spec'd**: mirrors `set_regrain`'s existing shape (just touched for
#341), suggested signatures already sketched in the issue:

```sql
pgpm.set_obtain(p_parent regclass, p_obtain int)
pgpm.set_retain(p_parent regclass, p_retain text default null)   -- null = keep forever
```

`p_retain` as `text` (not `anyelement`) matches how `pgpm.config.retain` already stores it
(interval for `time`/`uuidv7`, bigint count for `id`) and how the rest of the engine carries bounds.

**Locked-in decision (David's, this session, before handoff): `set_retain` REFUSES by default** when
the new value would make the next `maintain`/`retain` tick drop a partition the OLD value would have
kept -- no override, no warn-only mode. This matches the house rule (loud failure over silent one)
already applied to `extend_to`'s `p_max` cap and to `set_regrain`'s coarser-target refusal. A future
session should NOT re-litigate refuse-vs-warn; implement the refusal directly.

Open detail left for the implementing session: what "would drop a partition the old value kept"
means precisely for `set_obtain` too, if anything -- the issue's own text and destructive-knob
framing is really about `retain`; `set_obtain` mainly needs the same units/`control_kind` validation
`transmute` already applies, not a refusal in the same sense. Confirm against the issue text
(`gh issue view 326`) at the start of that session rather than assume.

Also validate `p_obtain`/`p_retain` against `control_kind` the same way `transmute` does at
conversion time (an interval for `time`/`uuidv7`, a bigint-parseable count for `id`) -- refuse rather
than coerce, per the issue's own suggested shape.

**David explicitly wants this tackled in a NEW Claude Code session, not the one that scoped it** --
same pattern as [[project_next_issue_341]] -> #290 and #290 -> #326. If a future session is asked to
continue or pick up "the next thing," start with issue #326 directly, decision already made.
