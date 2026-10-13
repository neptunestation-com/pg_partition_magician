# P1 null results: PR #1303 round 2

## Fresh surface

- `pgpm._disown_retirement` (the one writer of `retain_disown`): read whole. The remedy is decided by state
  (`v_reached` from `_control_followed(cfg)` + `_retain_boundary` + `_native_gt(hi, boundary)`), the same
  precondition `retire()` applies and the complement of `_retain_recall`'s `continue when ... reached`, so the
  path and the judgement cannot disagree in one transaction. The NOT REACHED and NOT JUDGED texts spell no
  `drop table`; the recall regression of round 1 (V-01) is gone. The REACHED text spells the DROP without the
  DELETE: claim P1-01.
- `_retain_recall`'s disown (part C scenario) run on the review tree: the row says `retention no longer reaches
  ... (the range ends past the horizon -700) ... attach it back ... alter table public.pc attach partition
  public.pc_p...100 for values from ('100') to ('200'); Do not drop it`; the ATTACH typed as logged puts rows
  150, 160 back beside 350 under the recorded `child_oid`, and two later `retain()` calls log nothing for
  [100, 200). Held.
- `retire()`'s detached branch with the parent in schema `s2`: the row names `s2.pb` and `s2.pb_p...100`
  schema-qualified in both statements; the ATTACH typed as logged is followed by retention retiring the
  partition (`retain_drop` for [100, 200), parent then holds exactly 250, 350). Held (the DROP half is P1-01).
- The install pass (`_disown_unvouched_retirements`) with the policy removed (`set_retain(null)` after the
  mark): the row says `the table has no retention policy`, spells the ATTACH alone and `Do not drop it`. Held.
- `_detach_reap`'s disown: read; same function, same `v_reached` judgement, pending partition so "once its
  detach is finished" is the true wording. Not run (needs an abandoned concurrent detach session; tests/327
  part C covers the pending state on the install pass).
- `retire()`'s pending branch: read; disowns through the same function after the horizon check, so it gets
  the reached text. Not run separately.
- `pgpm.part` has no FK and no trigger (checked on the installed tree), so the documented DELETE is typeable
  and nothing refuses it.
- `bench/retain_disown_remedy.sh`: wrapper in the shape of `retain_recall_moved_parent.sh`; counts the ran
  assertions and fails on 0 ran; the install failure is reported as FAIL, not PASS. `test.sh` registers it on
  pgpm_perf380 in the sharded guard list. Held (not run: `./test.sh` is out of bounds here).
- `tests/339`: parts A and B run the DROP and the DELETE only when the row spells one; part C runs the drop
  remedy if spelled, else the ATTACH, then asserts identity of served rows and the recorded oid. Asymmetric
  (2 in the disowned partition, 1 aged, 2 kept). On this tree parts A and B fail at the DELETE assertions and
  at the "logs nothing / failures stay 0 / part rows" checks, which is P1-01, not a test defect.
- `tests/327` part C's pattern now requires `attach it back%drop table %delete from pgpm.part where %`; it
  fails on this tree for the same reason as P1-01.

## Operator error

- Typing the ATTACH from a reached row rather than the DROP: retention retires the partition on the next
  tick (probe P2). Held.
- Typing the ATTACH from a not-reached row: rows served, no later log. Held.
- Typing only the DROP of a reached row: the documented consequence (fail_retain_identity for good) is what
  happens; on this tree that is the only remedy the row spells (P1-01).
- Hand edit `set_retain(null)` between the mark and the disown: judged "no policy", ATTACH only. Held.
- The DELETE statement in docs/reference.md names `parent_table = '<parent>'::regclass and child_name =
  '<child>'`, the primary key of `pgpm.part`, so it cannot delete a second row. Held.

## Hypotheses (no reproduction)

- NOT JUDGED branch: `cfg` is null after the strict select fails (a `pgpm.part` row whose `pgpm.config` row an
  operator deleted by hand); `_encode(null, ...)` then either raises (caught, bounds "could not be encoded")
  or returns null, giving `for values from (NULL) to (NULL)`. Not built: a part row without its config row is
  a state untransmute never leaves, and the text is explicitly marked unjudged.
- A `retire()`-disowned detached partition whose row's remedy says "once its detach is finished" when the
  detach is already finished: wording only.
- The horizon in the not-reached text is printed raw (`-700` for an id grid with `set_retain '1000'` and
  frontier 350): legible but odd; cosmetic.
- Deleting the `pgpm.part` row for a dropped partition leaves a gap in the grid ([100, 200) absent); whether
  any later walker (obtain's backfill, status gaps) re-creates or reports it was not probed.
