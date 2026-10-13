---
name: verify-enqueue-and-deadman-on-next-state
description: Land every PR (record PRs included) with land.sh; verify an enqueue immediately by the queue entry, never by the command's output; every wait has a dead-man deadline on the NEXT expected state, not only the final one
metadata:
  type: feedback
---

On 2026-10-12 I ran `gh pr merge 1257 --merge` on the record PR, read its notice ("The merge strategy for main is set by the merge queue") as an enqueue, started a two-hour wait for MERGED, and the PR sat outside the queue for hours until the user asked why GitHub showed it not in the queue. The user: "Why did you not notice this when you called gh pr merge and why did you even run that if you know that in this repo a PR enters the queue through the enqueuePullRequest mutation? And, why did you not set a dead-man switch ... waiting for an event that was never going to happen? You have to do better."

**Why:** on this repository `gh pr merge` (with or without `--auto`) does NOT enqueue a PR whose required checks are still pending; it prints that notice and does nothing. Only the `enqueuePullRequest` GraphQL mutation, after the head is green, puts a PR in the queue, and `scripts/review/land.sh` does exactly that with stall handling. The project note "gh pr merge --squash enqueues rather than merges" holds only for a PR that is already green.

**How to apply:**
1. Land EVERY PR, record PRs included, with `scripts/review/land.sh <pr>` (or `landq.sh`), in the background with a Monitor on its log; never `gh pr merge` by hand.
2. After any enqueue, verify at once with `gh api graphql ... pullRequest(number:N){isInMergeQueue mergeQueueEntry{state position}}`; read the command's output as nothing.
3. Every wait names the next expected state and a deadline for it (green head within ~30 min for a docs PR, in the queue within 5 min of green, merged within ~45 min of enqueue), checked by a background loop that EXITS and reports when the deadline passes; a wait on the final state alone is not a dead-man switch. See [[build-alarms-for-background-work]].
