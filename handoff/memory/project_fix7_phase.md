---
name: project_fix7_phase
description: Pass-7 fix phase DONE 2026-10-03: PRs #852-#870 merged, closure 59/69, #821-#848 closed, adjacent issues #872-#882 filed and verified (5 new Tier 1), record PR #883 MERGED; what pass 8 inherits
metadata:
  type: project
---

Pass-7 fix phase (coordinator run 2026-10-02 16:10Z to 2026-10-03 ~07:10Z). Scratch `$WORK` =
`.../scratchpad/fix7/` under the 4a6b7a35 session dir.

**Outcome:** 19 fixers (4.09M tokens), PRs #852-#870 ALL MERGED by 05:24Z (main 9f2efa6; 22 enqueues, 23 min
median queue time; 3 hand conflicts #859 #866 #870, all composing; no real CI failure; 1 flake -> issue #871 +
flake_check.sh signature). Closure 59/69 (every failure explained; caveats.json). #821-#848 CLOSED with
comments; #555 #632 #768 #769 #814 #815 #816 #817 #819 commented (#817 keeps the one-tick refusal window of
#858). Adjacent observations filed #872-#881 + method lessons #882; all 29 bullets verified (29 verifier
agents, 1.37M tokens): 23 confirmed, 6 struck, #880 closed. **Record PR #883** (docs + flake signature) MERGED 2026-10-03 06:33Z.

**Pass 8 inherits five new Tier 1 (unfixed, with reproductions on the issues):** #872 b2 (dropped_fk.definition
names the conversion-time schema; after SET SCHEMA the key is re-added against a namesake, logged success),
#872 b5 (manual archive.to_s3 keys by schema.name with unconditional PUT: overwrote a dropped table's only
copy), #873 b1 (non-BYPASSRLS owner regraining a FORCE RLS table LOSES hidden rows), #873 b3 (append-only
hypertable path loses a row when FORCE RLS lands mid-cutover; conservation check agrees with the filtered
read), #878 b2 (null regrain_source_mark across the #858 upgrade: no restart, stale copy swapped in). Plus
14 Tier 3 (incl. #875 b1, an RLS bypass through partitions' default privileges on Supabase; the rubric has
no tier for it), 3 Tier 4, 1 Tier 5. The pass-8 coordinator should pin only after these are fixed or
consciously carried (the backlog rule), and should count them as known-open if re-found.

**Lessons (also in #882):** take the verifiers' harness down before spawning fixers (gate.sh exits 7 on a
foreign fixed-name container; cost 8 local track runs and one fixer's gated run); the merge queue's 60-min
check timeout, not land.sh's wait, is the binding limit under a CI storm (68 queued runs); GitHub cancels
neither a dropped group's queued runs nor pre-rebase heads' runs (add concurrency groups); "all N mutations
build" counts are not comparable across fixers; reproductions pinned to a spelling stop at their own guard
when the fix removes the spelling.

**Why:** pass 8's coordinator needs the five Tier 1 list and the harness/queue lessons before pinning; the
user may ask to merge #883 or to start the Tier 1 fixes first.
