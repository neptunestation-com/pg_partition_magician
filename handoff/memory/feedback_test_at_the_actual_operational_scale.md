---
name: test-at-the-actual-operational-scale
description: "when a fix's value depends on hitting a specific config/scale (e.g. a byte budget), measure AT that scale directly -- don't extrapolate from a different scale you happened to test"
metadata:
  type: feedback
  originSessionId: 76528814-f267-4a80-9071-366cc19f87fe
  modified: 2026-09-10T19:31:34.531Z
---

Don't present a benchmark improvement at scale A as evidence for a decision that actually depends
on scale B, even when A and B are "close" or the trend looks favorable. Re-measure directly at B.

**Why:** While fixing [[project_lz77_memory_blowup_fix]] (issue #366, PR #367), I measured a ~3x
peak-RSS improvement at ~150MB (the scale the original incident happened at) and wrote that into
the PR as the headline evidence. David pushed back: the actual ask on the table was whether
`archive_byte_budget` could be raised to **512MB** for Indranil, and a ~3x improvement at 150MB
says nothing directly about whether 512MB is safe -- it could still fail well short of that
config even after a real, verified fix. He was right to press: measuring directly at 512MB found
the fixed code peaks at ~3.05 GB there (~6.1x over budget), i.e. the fix, while genuine, does NOT
answer the actual operational question, and there's a SEPARATE, larger cost elsewhere in the
pipeline (filed as issue #368) that the 150MB-scale evidence gave no visibility into at all. If
I'd stopped at the 150MB number, I would have implicitly represented the wrong thing as settled.

**How to apply:** When a fix's practical value is gated by a specific number an operator cares
about (a memory budget, a row count, a timeout), test at THAT number, not at whatever scale is
convenient or matches a prior incident. A favorable ratio at one scale does not transfer to
another scale when the underlying costs don't all scale the same way -- in this case the intended
fix (LZ77 matcher) was flat/O(1) and improving, while an unrelated cost elsewhere in the pipeline
(`_pq_encode_column_data`) was still O(input) and became dominant exactly at the larger scale that
mattered. Also: when a user explicitly says "I have limited credibility/patience to spend on
asking for this" (David: "I can only go to the well so many times"), that's a signal to front-load
rigor now rather than let a second round-trip discover the gap.
