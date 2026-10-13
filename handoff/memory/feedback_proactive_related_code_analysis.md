---
name: feedback-proactive-related-code-analysis
description: "when analyzing a design question or external article, proactively trace into other codebase features that share the same mechanism, not just the one literally named"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 7c02a40b-7b64-4354-bad5-2d03e4773c0f
  modified: 2026-09-22T14:38:45.367Z
---

When asked to connect an external idea (a blog post, a pattern name) to "what we just talked about,"
or to analyze a design/architecture question in this codebase, do not stop at the most obvious
match. Search for other features that share the same underlying mechanism or face the same
tradeoff, and read their actual implementation before concluding whether they already handle it
well, share the same gap, or are further ahead.

**Why:** Confirmed when connecting a blog post about Postgres "copy-swap-drop" table shrinking to
the transmute cutover-hoist work (issue #344 in dventimisupabase/pg_partition_magician). Rather than
stopping at "transmute's cutover uses the same swap-via-rename idea," I also traced into
`pgpm.regrain_step` (a different feature, not named in the article or the prior conversation) and
found it already implements a hardened version of the same pattern, down to logging its own swap
as `method => 'copy_swap_drop'` verbatim, and already hoists non-lock-dependent setup
(`_own_like_parent` + `_analyze`) out of its exclusive-lock window the same way #344 proposes for
transmute. The user's reaction: "you're anticipating my next questions as you draw in regrain_step
as well. Very good." An explicit confirmation, not a correction, so the pattern is worth repeating,
not just noted for once.

**Reconfirmed 2026-09-22 (#405 / PR #413), and extended to adjacent DEFECTS, not just design
precedent.** While editing `docs/reference.md` for #405 I noticed its `obtain` section was wrong on
three counts (claimed a procedure, an advisory lock, and a `p_deferred` parameter -- all removed by
#288, and contradicted by the section's own signature block). I flagged it rather than silently
folding it into a security diff, and David's reply was simply "fix the reference.md obtain doc too."
So: surface an unrelated defect you trip over, keep it OUT of the primary diff, and expect to be
asked to fix it -- offering is wanted, silently bundling is not.

A second, bigger instance the same session: the design option David selected for #405 carried a
predicate (`backend_start = owner_backend_start`) that empirical testing proved would have made the
reaper undo LIVE conversions cross-role, because Postgres masks `backend_start` for another role's
backend. Verifying the chosen design before implementing it -- rather than treating the selection as
settled -- is what caught it. Deviating from the approved detail, and saying plainly that I had
deviated and why, was the right call.

**How to apply:** Before answering a "how does X relate to Y" or "is this related to what we
discussed" question, grep the codebase for other functions/features that touch the same
mechanism (lock ordering, copy-then-swap, name-then-rename, etc.), and actually read their
implementation rather than reasoning from the feature's name or docstring alone. Surface what you
find even if it wasn't asked about directly, especially when it either validates the current
approach (precedent already exists) or reveals an analogous gap elsewhere. Related:
[[project_pgpm_bench_culture]] if written later, for the broader "verify against real code, not
plausible reasoning" norm this project holds contributors to.
