---
name: feedback-never-ask-users-to-read-source
description: "Never tell end users to read a generator's source code to figure out format parameters -- give them the ready answer"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c67c06b5-62f4-4da1-93f9-11b179177c83
  modified: 2026-08-25T15:58:11.132Z
---

Never suggest that an end user read a third-party generator's source code (or otherwise reverse-engineer
format internals) to figure out configuration parameters. If a feature needs per-format parameters
(e.g. pgpm's `text_time` control kind needing `p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit` for
cuid/KSUID/ULID/ObjectId), the answer belongs in the docs as a ready-to-use recipe, not as an
instruction for the user to go derive it themselves.

**Why**: said in response to me writing "a user figures out cuid v1's parameters the same way I did:
read the actual generator's source" as the closing line of an answer about documentation. Correctly
called out as ridiculous — verifying correctness as the implementer and telling an end user what to do
are different audiences with different needs. Conflating them produces genuinely bad advice.

**How to apply**: whenever documenting a feature that has format-specific or environment-specific
configuration, do the verification work myself (fetch specs, check source, test empirically) and then
write the answer down as a concrete, copy-pasteable value or recipe. The user-facing docs should never
contain "go find this out yourself" as the answer to "how do I configure X for Y."
