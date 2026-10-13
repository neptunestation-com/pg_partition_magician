---
name: merge-record-prs-without-asking
description: A loop's record PR (pure documentation) is merged by the agent, always, without waiting for the user; then move straight on to the review pass
metadata:
  type: feedback
---

The user (2026-10-12, after the lever phase before pass 12): "you never need to wait on me to merge the record PR that's part of a loop. It's pure documentation. There's no decision for me to make, other than to approve the merge, so just merge it, always, and move on to the review-pass."

**Why:** the record PR carries no code and no decision; holding the loop for a human click only costs wall-clock time. This replaces the pass-12 plan's "loop 12 keeps the record merge for the user".

**How to apply:** when a pass record, fix-phase record or lever-phase record PR is ready and lints clean, `gh pr merge <n> --merge` (the queue runs the tracks), wait for the merge, take the merge commit as the pin, and start the next `/review-pass` without asking. Fix PRs are different: [[dont-assume-standing-merge-authorization]] still governs code changes and self-corrections.
