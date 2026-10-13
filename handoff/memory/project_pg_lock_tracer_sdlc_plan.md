---
name: pg-lock-tracer-sdlc-plan
description: "eBPF-based pg_lock_tracer brought into CI for direct lock-sequence verification; issue #383 and all 5 phases + follow-ons MERGED and CLOSED 2026-09-16 through 2026-09-19"
metadata: 
  node_type: memory
  type: project
  originSessionId: c67f064d-dcf1-4b6b-a5c0-66535171dcf9
  modified: 2026-09-19T15:11:06.615Z
---

Proposed after [[project_next_issue_347]]'s bench-guard investigation ran long enough (a full
session) that David asked for a real plan to stop relying purely on indirect reader-probe
inference for lock-timing guards. **Tracking issue #383, filed 2026-09-14, CLOSED 2026-09-16.**
All 5 phases plus several follow-on fixes shipped within about 3 days:

- PR #388 (09-16): phases 1-2, `bench/lock_trace.sh` + wired into `discriminate.sh` mutations.
- PR #389/#391 (09-16): phase 3, `.github/workflows/locktrace.yml`, guard runs on every relevant PR.
- PR #390 (09-16): `./test.sh ci` runs the locktrace track behind a Linux-only guard (Mac still
  cannot run eBPF; matches the "confirmed structural" finding below).
- PR #392/#394 (09-17): phase 5 (the "stretch" item), replaced `animate_lock_graph` entirely with
  a purpose-built renderer reading `bench/lock_probe.py` JSON output directly (lock-view).
- Follow-on defect fixes on the new lock-view/lock-trace machinery: #393/#402 (`lock_trace.sh`
  said "grant" for what is actually a lock *request* — `attach_uprobe` fires at function entry,
  not grant), #395/#400 (a pairing demo's wait waited on nothing), #396/#403 (a lock-view row
  whose only mark is AccessShare rendered empty despite being counted drawn — visibility floor
  fix), #398/#400/#401 (the new eBPF lock-view probe had no CI path-filter gate at all).
- PR #404 (09-19): the design docs for this (`2026-09-16-lock-sequence-renderer-design.md`,
  `2026-09-16-lock-sequence-renderer.md`) were archived under `frozen/` now that the feature is
  built — see the new `frozen/` convention below.

**This whole initiative is done.** The reader-probe guards in `bench/` were kept as the fast,
portable, laptop-runnable first line of defense per the original plan (not replaced); the eBPF
trace is the CI-time, Linux-only second line. If a future session references this plan as
"not started" or "no phase started," that is stale — verify against `gh issue view 383` and the
`locktrace`/`lockview` tracks in `./test.sh ci` before trusting the old framing below.

**New project convention learned from this (PR #404):** finished design/spec docs move to a
top-level `frozen/` directory once the feature they describe has shipped, and living docs stop
linking into `frozen/` (commit `eb57027`). If you write a design doc for a multi-phase feature,
expect it to be archived there after the last phase merges, not left live in `docs/` or `bench/`.

---

**Original planning notes below, kept for archaeology:**

No phase started, no code written at time of writing — issue was scope-only, matching the #346
campaign-issue convention (each phase gets its own PR/issue when actually picked up).

**Why:** every guard in `bench/` (maintain_lock.sh, transmute_lock.sh, restore_fk_lock.sh,
retire_detach_lock.sh) proves "lock released before slow step" indirectly, via a concurrent
reader timing out or not. That missed a genuinely unconditional commit boundary (`#265`, before
FK-validate) for an unknown span of time; only a session of deterministic-sleep-and-check
archaeology surfaced it. A real eBPF trace (`pg_lock_tracer -j`) would show the gap directly as a
`lock_granted`/`lock_ungranted` pair with no ungrant before the next slow step's `query_begin`.

**Confirmed this session, empirically:**
- Docker Desktop for Mac's linuxkit VM CANNOT run this: no `/lib/modules`, `CONFIG_IKHEADERS`
  unset, no published headers for its bespoke per-Docker-Desktop-release kernel build. BTF *is*
  present (`CONFIG_DEBUG_INFO_BTF=y`), but the `python3-bpfcc` release available (0.29.1) has no
  BTF-only/CO-RE fallback for its `BPF(text=...)` compile-via-clang-against-headers path. This is
  structural, not a missing-package problem -- don't re-attempt on a Mac dev machine.
  Only got as far as compiling.
- GitHub Actions `ubuntu-latest` is NOT blocked -- pg-lock-tracer's own CI proves this exact recipe
  works there (`apt install python3-bpfcc`, copy dist-packages into a venv,
  `pip install pg-lock-tracer`), and this repo's other tracks (`perf.yml`, `archive.yml`,
  `observe.yml`) already run privileged/special-image containers on that same runner type.

**The plan, phased (see conversation for full detail if resuming this):**
1. PoC: new `bench/lock_trace.sh`, reusing `bench/maintain_lock.sh`'s existing mg_ret/ml fixture,
   installing bcc + pg-lock-tracer inside a `--privileged` postgres container (proven recipe),
   asserting directly on JSON trace events instead of inferring from a reader probe.
2. Wire into `bench/discriminate.sh`'s existing mutation framework (`bench/mutations/mutate.py`)
   -- the mutants already exist, this just needs a guard that also runs against them.
3. New path-filtered workflow, `.github/workflows/locktrace.yml`, `runs-on: ubuntu-latest`,
   modeled on `perf.yml`; own privileged container, not touching shared `docker-compose.yml`.
4. Supplement the existing reader-probe guards, don't replace them -- those stay as the fast,
   portable, laptop-runnable first line of defense.
5. Stretch: `animate_lock_graph` HTML output as a per-PR artifact for lock-sequence review.

**Local dev story:** still the deterministic `CALL` + `pg_sleep()` + single `pg_locks` check
technique (see [[feedback_pg_lock_tracer_toolbox]]) -- the eBPF trace is a CI-time layer, not
something expected to run pre-push on a Mac.

**Next action, if picked up:** file a scoped tracking issue first (matching the `#346`
security-hardening pattern), rather than starting Phase 1 without one -- this is a multi-PR
initiative.
