---
name: project-next-issue-422
description: "#422 hypertable cutover identity MERGED 2026-09-23 (PR #432); the window map, and three test-harness constraints that shaped the guard and will shape any future timescale guard"
metadata: 
  node_type: memory
  type: project
  originSessionId: b6ac82fd-d962-4333-84ac-b096028f2af0
  modified: 2026-09-23T22:57:06.559Z
---

**[#422](https://github.com/dventimisupabase/pg_partition_magician/issues/422) MERGED** as `f7125b1`
(PR #432). `from_hypertable_cutover` locks the source BY OID and re-resolves to verify, and does the
same for the destination against the oid its own existence check found. User chose source+destination
scope and oid-locking over the issue's cheaper minimum.

**THE WINDOW MAP, which the issue only half-derives.** Most of the resolve-to-lock span is
self-protecting, so do not re-derive this:

- rename before the cutover starts -> loud (`found no copy to cut over`), as filed
- rename during the online pre-drain -> ALSO loud, by a mechanism the issue never names:
  `from_hypertable_drain_delta_step` / `_drain_appends_step` each re-resolve the name per batch and
  raise `found no delta`. The pre-drain commits per batch and so LOOKS like the widest part of the
  window; it is the safest part.
- rename during the index pre-builds -> **the only real exposure.** Explicitly the O(rows) work kept
  outside the lock so the outage stays brief, therefore the longest stretch, and nothing in it
  re-resolves the source. Silent only if something takes the vacated name; otherwise the lock errors.

The destination half is NOT in #422's title and is worse: it is renamed INTO the source's name, so an
unverified one becomes the production table. It is unlocked until the first index pre-build, and the
pre-drain's commits release even that. Scope limit that is deliberate and documented: the check
cannot see a destination substituted BEFORE the cutover was called, since nothing records what
`from_hypertable_copy` built.

**THREE HARNESS CONSTRAINTS ON THE TIMESCALE TRACK.** Any future guard there hits all of them:

1. `run_timescale` fails the track on any `ERROR:` line, so a raising call MUST be wrapped by
   `throws_like`; but a procedure reaching its own `COMMIT` inside a function raises `invalid
   transaction termination`. So a wrongly-SUCCEEDING procedure can never be observed committing --
   it rolls back into the same end state as a correct refusal. The refusal's MESSAGE is then the only
   discriminator, and tests/timescale/db/17 marks its state assertions as invariants rather than
   pretending otherwise.
2. Because everything rolls back, the proof that the test's lever fired must be NON-transactional.
   Used a sequence: `pg_sequences.last_value` is null until first read and again after `RESTART`, so
   null/not-null is exactly "it fired". Verified that semantics in-container before relying on it.
3. No `pg_prove` in the supabase/postgres image, which is why `run_timescale` parses TAP out of
   `psql -tAq` itself; the bench guard has to do the same.

The lever is an EVENT TRIGGER on `CREATE INDEX` (deterministic, no second session), and
`ddl_command_START` not `_end`: at `_end` the real destination already owns the temp index name, and
index names are schema-scoped, so the impostor could not be given one without a collision and a
mutant would die on that instead of on the identity it is meant to miss.

Mutations live under a NEW `MUTATION_TRACK = "timescale"`, run from `run_timescale` while its
container is up, so `./test.sh discriminate` stays laptop-runnable -- same reasoning as locktrace.

See [[project_pgpm_security_hardening_campaign]] and [[project_next_issue_421]].
