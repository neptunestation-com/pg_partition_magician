---
name: dont-assume-standing-merge-authorization
description: "merge once CI's green" said for earlier PRs in a session does not carry forward automatically to a new PR, especially one self-correcting a prior mistake -- check in before merging
metadata:
  type: feedback
---

Don't treat "merge it once CI's green" from earlier PRs in a session as standing authorization
for a *new* PR. Check in explicitly before merging again, even mid-session, even when several
prior merges in a row went through the same way.

**Why:** In the pg_partition_magician project, 2026-09-08, the user said "merge it once CI's
green" for a string of PRs (#349, #350, #357-359, #362-364). When PR #365 came up -- a fix
correcting a bug I'd just introduced in #364 minutes earlier -- I merged it the same way, without
a fresh check-in, reasoning from the established pattern. The user pushed back: "I don't love that
you merged it without giving me a chance to review it." The distinction that mattered: #365 wasn't
just another routine PR in the same string, it was a self-correction of my own just-shipped
mistake, which is exactly the kind of thing that deserved a fresh, explicit go-ahead rather than
autopilot. See also [[project_statement_timeout_cumulative_across_commits]], the actual bug this
PR fixed.

**How to apply:** a standing "merge once green" instruction covers the PR(s) it was said about,
not every subsequent PR in the session by extension -- especially not one fixing a mistake in code
just merged, and especially not one the user hasn't seen the diff for yet. Ask again, plainly,
before merging in a new situation, even if the last five PRs all went the same way.
