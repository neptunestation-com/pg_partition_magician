---
name: gh-pr-create-cwd-bug
description: "gh pr create infers head branch from shell cwd, which silently resets to the main checkout after worktree commands -- always pass --head explicitly"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 76528814-f267-4a80-9071-366cc19f87fe
  modified: 2026-09-08T04:25:16.781Z
---

Always pass `--head <branch>` explicitly to `gh pr create` when working out of a git worktree.
Never rely on having `cd`'d into the worktree in a prior tool call.

**Why:** In this environment, the shell's working directory resets to the main repo checkout
after some Bash calls involving worktrees (observed repeatedly as "Shell cwd was reset to
<main-repo-path>" following `cd <worktree> && git push ...` commands) -- persistence across calls
is not guaranteed the way it looks. `gh pr create` (unlike `gh pr view`/`gh pr merge`/`gh pr edit`,
which take an explicit PR number and are immune to this) infers its head branch from the *current*
directory's checked-out branch, not from whatever branch was last pushed.

This caused a real incident: after pushing a docs branch from a worktree, a subsequent `gh pr
create` call (no explicit `cd`, no `--head`) ran from the main checkout, which was sitting on an
unrelated pre-existing branch (`docs/fix-transmute-lock-claim`) with its own already-completed,
unpushed-as-a-PR fix. `gh pr create` opened a PR against *that* branch, but titled/bodied it for
the intended (different) docs work. The PR was then merged, which correctly landed the unrelated
README fix but incorrectly auto-closed the wrong GitHub issue (`Fixes #NNN` in the body pointed at
work that was never actually in that PR's diff). Recovery required: editing the merged PR's
title/body to match its real diff, reopening the wrongly-closed issue, and separately opening a
new, correctly-targeted PR for the actual intended content.

**How to apply:** Any time a PR is created for work done in a worktree (or any branch other than
whatever the main checkout happens to be on), pass `--head <branch-name>` to `gh pr create`
explicitly -- do not trust that a preceding `cd` in the same conversation still applies. After
creating or editing a PR, verify with `gh pr view <number> --json headRefName` (or check the diff
`--name-only`) that it actually contains the intended files before treating it as ready to merge.
