---
name: project-pgpm-text-time-control-kind
description: "text_time control kind: all four formats (cuid v1, ULID, KSUID, ObjectId) merged, #334 + #335"
metadata: 
  node_type: memory
  type: project
  originSessionId: c67c06b5-62f4-4da1-93f9-11b179177c83
  modified: 2026-08-25T17:26:18.008Z
---

Built and merged to main on 2026-08-25, via
https://github.com/dventimisupabase/pg_partition_magician/pull/334 (branch
`feat/text-time-control-kind`, now deleted). Motivated by
[[project-boardy-searchhistory-cuid]]. Scoped as "general" rather than cuid-narrow per an explicit
decision: no real pgpm users yet, so pay the generalization cost now rather than face "major surgery"
later with real customers depending on a narrower shape.

**What #334 shipped**: a fourth `control_kind`, `text_time`, for a TEXT id shaped `<constant
prefix><fixed-width base-N encoded epoch>` via 4 declared numbers
(`p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit`), not detected from the column. Genuinely covered
only cuid v1 and MongoDB ObjectId at that point — the doc claim that it also covered KSUID/ULID
"without any format-specific code" was WRONG and had to be corrected; see below. Built bottom-up:
`_radix_decode`/`_radix_encode` (base-2..36 codec) → `_text_time_to_ts`/`_ts_to_text_time` (timestamp
wrapper; encode produces a *minimal* boundary — prefix + zero-padded digits, nothing appended) → 4 new
nullable `pgpm.config` columns → `_encode`/`_decode` widened with matching trailing params threaded
through ~25 call sites, including 3 dynamic-SQL ones in `regrain_step` → `pgpm.check_text_time` (the
`check_uuidv7` analogue) → wired into `transmute`'s preflight as a sampling gate.

**What #335 added (merged to main 2026-08-25)**: real support for ULID (Crockford
base32, skips I/L/O/U) and KSUID (base62-encodes its *entire* 160-bit payload as one number against a
non-Unix epoch 2014-05-13 16:53:20+00 — the timestamp is the top 32 of 160 bits, not a separate
substring). New params: `p_tt_alphabet` (explicit digit-to-character override; default's 36-radix cap
only applies when none is given), `p_tt_discard_bits` (right-shift the decoded field this many bits
before treating it as the time count; 0 for cuid/ULID, 128 for KSUID), `p_tt_epoch`. `_radix_decode`/
`_radix_encode` widened `bigint` → `numeric` (KSUID's payload overflows a 64-bit bigint by ~100 decimal
digits). A real arithmetic bug was found and fixed while proving KSUID at actual scale: `_radix_encode`
used `floor(v_n / p_radix)`, and Postgres's general numeric division computes non-terminating quotients
to a *bounded* number of decimal digits — exact enough at cuid's ~12-digit scale, silently wrong
(sometimes negative "digits") at KSUID's ~48-digit scale. Fixed with exact integer `div()`/`mod()`.
Every alphabet/epoch value was verified against the format's actual source
(`segmentio/ksuid`, `ulid/spec`, MongoDB's BSON reference) before being written into code or docs — see
[[feedback-never-ask-users-to-read-source]] for why that verification burden sits with the
implementation, not the end user.

**A real defect was caught during the build, not just designed around**: generalizing
`_frontier_native`'s `greatest(decoded, now())` treatment (#325's fix) to `text_time` without also
generalizing `_transmute`'s *separate* inline duplicate of that same logic reproduced #325's exact
failure mode — a 10-month gap with no partition at all, not just a stale frontier. `pgpm.config` doesn't
exist yet at the second site, so it can't just call the shared function; both sites had to be updated
independently. Caught by empirically inspecting `pgpm.part` after a manual `transmute` + `maintain`, not
by reasoning about the code. `bench/frontier_drought.sh` now runs its full sequence against both
`uuidv7` and `text_time` independently for exactly this reason — shared code path is not evidence the
fix landed in both places.

**How to apply**: if this comes up again, check whether PR #335 has merged (search install.sql for
`text_time_alphabet` or `p_tt_discard_bits`) before re-scoping or re-deriving anything above. If
extending to a fifth control kind ever needs config beyond `text_time_*`'s 7 columns, the
config-threading design choice made here (nullable scalar columns + matching trailing params on every
adapter call, chosen over passing the whole `pgpm.config` row) was deliberate — see the "Go with A"
decision in this session — not an oversight to fix.
