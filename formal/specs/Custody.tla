------------------------------- MODULE Custody -------------------------------
(***************************************************************************)
(* The archive-then-retain custody chain of pg_partition_magician: the     *)
(* write block, the archive step with the strategy as an untrusted caller, *)
(* the ledger and its retired marks, the object store and its key claims,  *)
(* retire() on the one-step and the detach path, the pgpm_detach dispatch, *)
(* the recall of a retirement, _detach_reap, and the operator utility      *)
(* scripts/archive_partition_whole.sql. The synchronous exports            *)
(* (archive.to_s3 and friends) are NOT modelled (catalogue, Phase 1        *)
(* scope).                                                                 *)
(*                                                                         *)
(* This is the INTENDED design, from the documented contracts. Each        *)
(* action names the procedure and transaction it stands for; each guard a  *)
(* fix put in place is on one line tagged "@guard <id>", which is what     *)
(* formal/mutations/mutate.py rewrites to put a historical defect back.    *)
(*                                                                         *)
(* Contracts cited: docs/reference.md sections `retire`, `retain`,         *)
(* `_detach_reap`, `maintain` (write-blocking, chunked archiving), Archive *)
(* strategy contract, Byte-budget chunked archiving and its identity and   *)
(* contract checks, `pgpm.archive_ledger`; docs/guide.md "Archiving before *)
(* a drop"; pgpm_archive/README.md "Automatic vs. manual".                 *)
(*                                                                         *)
(* ABSTRACTIONS beyond Base's A1 to A9:                                    *)
(*  C1 A chunk is one grid position: an honest strategy archives [lo,lo+1) *)
(*     per call. The operator script asks for the partition's whole        *)
(*     remainder, and the strategy may stop early (its byte budget) and    *)
(*     return how far it got.                                              *)
(*     archive_batch is 1 (the default); retain_batch is unmodelled        *)
(*     (retire is called per partition, by the tick or by an operator).    *)
(*  C2 The strategy reads through the parent, as pgpm_archive's do: rows   *)
(*     of a detached or detach-pending partition are invisible to it.      *)
(*     An untrusted strategy ("OC") may also return covered_hi of p_lo     *)
(*     (no progress) or past p_hi (overshoot), and may write its covered_hi*)
(*     as offset-less text in its session's zone.                          *)
(*  C3 Object keys are the chunk's lo for this parent (the base is claimed *)
(*     by this parent on its first PUT). A namesake table's writer ("SB") *)
(*     appears only after the parent is dropped and re-created (epoch 2);  *)
(*     it spells the shared prefix plainly or with a leading slash, which  *)
(*     the store folds to one object (#1260).                              *)
(*  C4 The recorded-chunk check of pgpm_archive compares the call's range  *)
(*     with the recorded chunk's and the rows read with the recorded rows  *)
(*     (the digest, modelled exactly as the row set).                      *)
(*  C5 The pgpm_detach job holds one command naming a schema and a         *)
(*     relation; pg_cron runs it as three steps: the run starts and        *)
(*     resolves the name, the first transaction commits (pending), the     *)
(*     second finalizes. Another parent's retirement is reduced to one     *)
(*     mark (otherMark) on a paused parent that can never progress.        *)
(*  C6 maintain's per-table steps are separate actions in any order; the   *)
(*     order inside one tick is not relied on by any contract modelled.    *)
(*  C7 One retire() is in flight at a time; it is two steps (resolve, then *)
(*     the lock wait, then the rest under the lock).                       *)
(*  C8 Regrain is reduced to its effects on custody: a copy relation in    *)
(*     flight, and the swap that replaces a partition by its copy.         *)
(*  C9 The archive step's strategy call is two steps (ArchiveStep picks    *)
(*     the chunk and calls; ArchFinish is the return, the re-check and the *)
(*     record). In between: the tick's other steps wait, as do every hand  *)
(*     action that needs a lock conflicting with ACCESS SHARE on the parent *)
(*     (detach, finalize, attach, rename, drop, set schema), coarsely, for *)
(*     every relation; writes, a concurrent detach's first transaction and *)
(*     pg_cron's run proceed. A read the detach overtook returns anything  *)
(*     between what the parent shows after it and what it showed before.  *)
(*     The operator script's call stays one step (its re-check is not      *)
(*     modelled).                                                          *)
(***************************************************************************)
EXTENDS Base

CONSTANTS
    Shapes,      \* which initial states (fresh or older-install shapes) Init admits
    FKIn,        \* a foreign key references the parent: the detach path
    Hypotheses   \* guards the shipped code lacks, assumed so the rest can be checked (see below)

(***************************************************************************)
(* HYPOTHESES. A counterexample of the unmutated spec that reads as a real *)
(* defect is a claim for Phase 2, recorded in docs/formal/record.md. While *)
(* it stands, a config may assume the guard that would close it, so the    *)
(* rest of the design is still checked; the as-shipped config keeps the    *)
(* counterexample.                                                          *)
(*  H_C1  _retain_recall's re-attach branch waits, as its attached branch   *)
(*        does, until no launched run of the pgpm_detach command is in      *)
(*        flight. As shipped it idles the job, attaches and clears the mark *)
(*        in one transaction, and a run pg_cron launched before the idle    *)
(*        (queued behind the ATTACH's lock on the parent) detaches the      *)
(*        partition again with nothing vouching for it.                     *)
(*  H_C2  The archive step's orphan rule spares a chunk whose child_oid is  *)
(*        a tracked partition's, whatever name the chunk carries. As        *)
(*        shipped it discards by name, so a tracked rename (the old guide's *)
(*        recipe, pgpm.part renamed with the table) turns the partition's   *)
(*        recorded chunks into orphans: after the operator script archives  *)
(*        the rest under the new name, the discard leaves a gap below a     *)
(*        max(hi) that still reads as fully covered, and retire drops rows  *)
(*        no live chunk vouches for (their object survives, unrecorded).    *)
(*                                                                         *)
(* KNOWN GAPS. The independent fidelity read (docs/formal/record.md) found  *)
(* these places where the spec is narrower than the contracts. Each one     *)
(* narrows what a clean check means, and none is closed in Phase 1:         *)
(*  K1 Init has no pgpm.part row with a null child_oid and no retirement    *)
(*     mark at upgrade time, so the upgrade's disown and the null-oid       *)
(*     readers (own-schema lookup, range check, not archived) are unchecked.*)
(*  K2 No ALTER SCHEMA ... RENAME and no partition SET SCHEMA: the post-    *)
(*     effect identity checks the contract describes for a name resolved    *)
(*     before a lock wait are not exercised (A6 takes such locks by oid).   *)
(*  K3 No snapshots: no REPEATABLE READ caller of retire, and the operator  *)
(*     script's call is one step (C9).                                      *)
(*  K4 One retire() at a time (C7), where the contract allows several with  *)
(*     a per-partition claim; FKIn is a constant, so a foreign key dropped  *)
(*     mid-retirement is unreachable.                                       *)
(*  K5 Absent operator actions: schedule()/unschedule(), set_archive_fn(    *)
(*     null), hand edits of the ledger and pgpm.part, an operator FINALIZE  *)
(*     of an abandoned detach, UPDATE, and writes straight into a partition.*)
(*  K6 ResolveByRecord covers the DROP and the job's DETACH only, not the   *)
(*     recall's re-attach or the reap's FINALIZE; no invariant says the     *)
(*     reap never finalizes a live detach (why M453 is a miss).             *)
(*  K7 Regrain starts only on an unretired partition (C8 leaves it out).    *)
(*  K8 At EnvBudget 2 with both slots full, the documented substitute race  *)
(*     needs about four environment steps: reachable only from the ogone    *)
(*     and oret shapes.                                                     *)
(*                                                                         *)
(***************************************************************************)

VARIABLES
    part,      \* [Slots -> [pr, name, oid, ret, rOid, disp, hiB]]: pgpm.part
    led,       \* [Pos -> ledger row]: pgpm.archive_ledger, keyed (parent, lo)
    obj,       \* [Pos -> SUBSET Rows]: the object store, by canonical chunk key
    claimed,   \* chunk keys this parent claimed (archive.object_key_claim)
    horizon,   \* retention horizon: positions below it are aged
    archOn,    \* config.archive_fn is set
    cronOK,    \* the pgpm_detach job exists (pgpm.schedule() ran)
    job,       \* the pgpm_detach job: its command [n, nm] and the relation whose dispatch armed it, or NoJob
    jobRun,    \* the command text a launched pgpm_detach run carries, or NoRun
    jobOid,    \* the relation that run marked pending, or 0
    jobFor,    \* the relation the launched run's command was dispatched for (0: no live retirement owned it)
    rgCopy,    \* [Slots -> Oids \cup {0}]: an in-flight regrain copy of the slot
    rt,        \* retire() in flight: [s, o, z] or NoRt
    otherMark, \* another (paused) parent's mark: "none" or "undisp"
    upgraded,  \* install.sql's upgrade has run over an older install
    arc,       \* the archive step's strategy call in flight: [s, o, lo, a, z, A0, pre], or NoArc
    \* ghost variables, written only to state the invariants
    badDrop,   \* a pgpm DROP removed rows no live chunk of the dropped relation vouches for
    copied,    \* <<row, key>>: a ledger chunk attested the object at key held the row when its relation was dropped
    lostDrop,  \* rows a pgpm DROP removed that retention did not reach or the operator owned
    wrongTgt,  \* a pgpm destructive action reached a relation other than the recorded one
    collided,  \* a ledger insert hit an existing (parent, lo): the step raises every tick
    falseRef,  \* an identity refusal while the recorded relation was where its record says
    wasted,    \* archive_batch's only turn went to a partition that cannot be archived
    raised,    \* the archive step raised outside its per-child handling
    silent,    \* the archive step found an aged candidate and archived nothing, logging nothing
    stuckSlot, \* retire() refused for a detach slot held only by a mark that cannot progress
    heldOwn    \* the upgrade marked retired the chunk of a partition whose block attributes it (#1160)

custVars == <<part, led, obj, claimed, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt,
              otherMark, upgraded, arc>>
ghostVars == <<badDrop, copied, lostDrop, wrongTgt, collided, falseRef, wasted, raised, silent,
               stuckSlot, heldOwn>>
vars == <<baseVars, custVars, ghostVars>>

\* TLC configs cannot spell a negative number; they substitute these.
MCZones == {-1, 0, 1}
MCZone0 == {0}

\* A chunk's object key: injective in its lo (#502: the sign; #823: the era).
Key(lo) == lo  \* @guard G502

\* job: the command [n, nm] and the relation whose dispatch armed it (o); a run carries the text only
NoJob == [n |-> "", nm |-> "", o |-> 0]
NoRun == [n |-> "", nm |-> ""]
NoArc == [s |-> 0, o |-> 0, lo |-> 0, a |-> 0, z |-> 0, A0 |-> {}, pre |-> FALSE]
Idle == arc = NoArc
Cmd(j) == [n |-> j.n, nm |-> j.nm]
NoRt == [s |-> 0, o |-> 0, z |-> 0]
NoLed == [ex |-> FALSE, lob |-> Canon(0), hi |-> Canon(0), name |-> "", oid |-> 0, cnt |-> 0,
          dig |-> {}, ret |-> FALSE, key |-> 0]
\* key: the object the strategy PUT, named by the lo's instant whatever text the lo is stored as
LedRow(lob, hi, nm, o, A) == [ex |-> TRUE, lob |-> lob, hi |-> hi, name |-> nm, oid |-> o,
                              cnt |-> Cardinality(A), dig |-> A, ret |-> FALSE, key |-> Key(Instant(lob))]

SessZ == IF "SG" \in EnvGroups THEN Zones ELSE {0}
StoreRows == UNION {obj[k] : k \in Pos}
\* Rows the ledger attests an object holds: a chunk recorded (live or retired)
\* whose object still holds them. The ledger row is the record of the only
\* copy (reference.md `pgpm.archive_ledger`); an object no row records is not
\* one pgpm vouches for.
\* the <<row, object key>> pairs ledger chunks attest for the rows of R
AttestPairs(R) == UNION {{<<r, led[l].key>> : l \in {l2 \in Pos : led[l2].ex /\ r \in led[l2].dig /\ r \in obj[led[l2].key]}}
                          : r \in R}

-----------------------------------------------------------------------------
(* Resolution and identity (reference.md "What retire checks a partition's  *)
(* identity against"; catalogue base item 1).                              *)

\* A partition is resolved in its OWN schema, the schema of the relation
\* child_oid records, never the parent's (#727). A row whose relation is gone
\* takes the parent's.
OwnNsp(s) == IF part[s].oid # 0 /\ rel[part[s].oid].ex THEN rel[part[s].oid].nsp ELSE parentNsp  \* @guard G727
RecallNsp(s) == IF part[s].oid # 0 /\ rel[part[s].oid].ex THEN rel[part[s].oid].nsp ELSE parentNsp  \* @guard G778
PartRel(s) == Resolve(OwnNsp(s), part[s].name)
\* reference.md: a partition of the parent over another range than the row's is refused
IdentityOK(s) ==
    LET o == PartRel(s) IN
      /\ o # 0 /\ (part[s].oid = 0 \/ o = part[s].oid) /\ (part[s].rOid = 0 \/ o = part[s].rOid)
      /\ (rel[o].par = 0 \/ rel[o].slot = s)
\* A refusal is spurious when the recorded relation is attached over the row's
\* range and still carries the recorded name: the lookup looked in the wrong place.
Spurious(s) ==
    /\ part[s].oid # 0 /\ rel[part[s].oid].ex /\ Attached(part[s].oid, 1)
    /\ rel[part[s].oid].name = part[s].name /\ rel[part[s].oid].slot = s

\* A retiring_at mark vouches for a detach only with the record of pgpm's own
\* dispatch, detach_dispatched_oid (#1259).
PgpmHolds(s, o) == part[s].ret /\ part[s].disp = o /\ o # 0  \* @guard G1259
HandDetached(s, o) == o # 0 /\ ~Attached(o, 1) /\ ~Pending(o) /\ ~PgpmHolds(s, o)
\* What the invariants and the environment read: the design's own predicates,
\* untagged, so a mutation of the protocol never changes what is checked.
TrueHolds(s, o) == part[s].ret /\ part[s].disp = o /\ o # 0
\* A relation in pgpm's custody: one its own vouched retirement holds.
Custody(o) == \E s \in Slots : part[s].pr /\ TrueHolds(s, o)

\* Only a block enabled ALWAYS counts as a write block (#651).
IsBlocked(o) == rel[o].trig = "always"  \* @guard G651

\* A partition's stored bound is read on the grid's clock, partition_tz (zone 0),
\* never in the caller's session (#500).
PartHi(s, z) == ParseIn(part[s].hiB, 0)  \* @guard G500
Eligible(s, z) == PartHi(s, z) <= horizon

-----------------------------------------------------------------------------
(* The ledger and coverage (reference.md "Byte-budget chunked archiving",  *)
(* "pgpm.archive_ledger").                                                 *)

\* A chunk belongs to the relation child_oid names (null: matched by name).
LiveChunks(s, o) ==
    {l \in Pos : led[l].ex /\ ~led[l].ret
                 /\ (led[l].oid = o \/ (led[l].oid = 0 /\ led[l].name = part[s].name))
                 /\ SlotOf(l) = s}
\* A live chunk whose bound names no instant by itself proves no coverage (#1336 b8).
ChunkHi(l, z) == IF led[l].hi.off THEN led[l].hi.w ELSE l  \* @guard G1336b8
\* _archive_fully_covered: "true once the ledger's recorded ranges for that child
\* reach its own hi" (reference.md, Byte-budget chunked archiving), read as the
\* code reads it, the live chunks' greatest hi (#1335 b4 was struck on that
\* reading; see claim C2 in docs/formal/record.md for a gap it reaches).
MaxHi(s, o, z) ==
    LET W == {ChunkHi(l, z) : l \in LiveChunks(s, o)} \cup {Lo(s)}
    IN CHOOSE w \in W : \A v \in W : w >= v
FullyCovered(s, o, z) == ~archOn \/ MaxHi(s, o, z) >= Hi(s)
Watermark(s, o) == MaxHi(s, o, 0)
OffsetlessLive(s, o) == \E l \in LiveChunks(s, o) : ~led[l].hi.off  \* @guard G1336b8

\* A retired chunk's range, read at its widest when a bound names no instant
\* (reference.md: "never narrower than the chunk", #1363).
RetLo(l) == IF led[l].lob.off THEN led[l].lob.w ELSE led[l].lob.w - MaxZ  \* @guard G1363
RetHi(l) == IF led[l].hi.off THEN led[l].hi.w ELSE led[l].hi.w - MinZ  \* @guard G1363
OverRetired(s) ==
    \E l \in Pos : led[l].ex /\ led[l].ret /\ RetLo(l) < Hi(s) /\ Lo(s) < RetHi(l)

\* Every coverage reset first marks retired the chunks of a relation that no
\* longer exists (their objects are the only copy), then discards live chunks.
MarkGone(L) ==
    [l \in Pos |-> IF L[l].ex /\ ~L[l].ret /\ L[l].oid # 0 /\ ~rel[L[l].oid].ex
                   THEN [L[l] EXCEPT !.ret = TRUE] ELSE L[l]]  \* @guard G1141b1
Discard(L, S) == [l \in Pos |-> IF l \in S /\ ~L[l].ret THEN NoLed ELSE L[l]]
\* A reset of slot s's live coverage of relation o.
ResetCoverage(s, o) == LET M == MarkGone(led) IN Discard(M, {l \in Pos : M[l].ex /\ ~M[l].ret /\ SlotOf(l) = s})

\* archive_fn's return held to the contract before it is recorded (#454).
ContractOK(lo, c, s) == lo < c /\ c <= Hi(s)  \* @guard G454
ScriptContractOK(lo, c, s) == lo < c /\ c <= Hi(s)  \* @guard G1030b3

\* pgpm_archive's recorded-chunk check (#975, #1069): at a key the ledger
\* records a chunk at, a write may only reproduce that chunk: its own range
\* and the rows it recorded.
RowsMatch(l, A) == led[l].dig = A  \* @guard G1069
PutOK(lo, hi, A) ==
    \A l \in Pos : (led[l].ex /\ led[l].key = Key(lo))
                   => (l = lo /\ ParseIn(led[l].hi, 0) = hi /\ RowsMatch(l, A))  \* @guard G975

\* What a strategy reading [lo, hi) through the parent sees. A naive control
\* column is read on partition_tz, never in the strategy session's zone (#501).
StratShift(z) == 0  \* @guard G501
ReadThroughParent(lo, hi, z) ==
    {r \in Rows : rst[r] = "live" /\ repoch[r] = 1 /\ Attached(rloc[r], 1)
                  /\ rpos[r] >= lo + StratShift(z) /\ rpos[r] < hi + StratShift(z)}

\* covered_hi values a strategy may return for a chunk [lo, hi) it archived to a.
Returns(lo, a, s) == {a} \cup (IF "OC" \in EnvGroups THEN {lo, Hi(s) + 1} ELSE {})
\* The ledger records the instant the check accepted, canonically (#977).
Recorded(c, z) == Canon(c)  \* @guard G977
\* _next_archive_chunk's stop, on the native grid (#788).
ChunkStop(lo, z) == lo + 1  \* @guard G788

\* A drop of relation o for slot s, with the ghost bookkeeping.
\* pack 4.3 DropOnlyCovered: rows in archive objects attributed to the dropped relation's recorded
\* identity and range, that is, the objects its own live chunks name, holding the rows they recorded
Vouched(s, o) == {r \in Rows : \E l \in LiveChunks(s, o) : r \in led[l].dig /\ r \in obj[led[l].key]}
DropGhosts(o, s) ==
    /\ badDrop' = (badDrop \/ (archOn /\ ~(RowsOf(o) \subseteq Vouched(s, o))))
    /\ copied' = copied \cup AttestPairs(RowsOf(o))
    /\ lostDrop' = lostDrop \cup
         (IF o # part[s].oid \/ o \in opOwned THEN RowsOf(o)
          ELSE {r \in RowsOf(o) : rpos[r] >= horizon})
    /\ wrongTgt' = (wrongTgt \/ (part[s].oid # 0 /\ o # part[s].oid))
DropRel(o) ==
    /\ rel' = [rel EXCEPT ![o].ex = FALSE, ![o].dead = TRUE, ![o].par = 0, ![o].pend = FALSE]
    /\ rst' = [r \in Rows |-> IF rloc[r] = o /\ rst[r] = "live" THEN "gone" ELSE rst[r]]
    /\ rloc' = [r \in Rows |-> IF rloc[r] = o THEN 0 ELSE rloc[r]]

JobHolds(n, nm) == Cmd(job) = [n |-> n, nm |-> nm]
IdleIfHolds(n, nm) == job' = IF JobHolds(n, nm) THEN NoJob ELSE job

-----------------------------------------------------------------------------
(* Initial states. "fresh" is a new install; the others are catalog shapes *)
(* an older install leaves behind (pack 4.1: Init includes older installs).*)

FreshRel(o) ==
    IF o \in {1, 2}
    THEN [ex |-> TRUE, dead |-> FALSE, nsp |-> "a", name |-> IF o = 1 THEN "c1" ELSE "c2", par |-> 1,
          pend |-> FALSE, slot |-> o, trig |-> "none"]
    ELSE [ex |-> FALSE, dead |-> FALSE, nsp |-> "a", name |-> "", par |-> 0, pend |-> FALSE,
          slot |-> 0, trig |-> "none"]
FreshPart(s) == [pr |-> TRUE, name |-> IF s = 1 THEN "c1" ELSE "c2", oid |-> s, ret |-> FALSE,
                 rOid |-> 0, disp |-> 0, hiB |-> Canon(Hi(s))]
\* r1 at 0 and r2 at 1 in slot 1; r3 not yet written (epoch 2 in the "pd" shape).
RowPos == [r \in Rows |-> IF r = "r1" THEN 0 ELSE IF r = "r2" THEN 1 ELSE 0]

InitCommon ==
    /\ rpos = RowPos
    /\ parentNsp = "a" /\ parentEx = TRUE /\ epoch2 = FALSE
    /\ opOwned = {} /\ liveDet = {} /\ envLeft = EnvBudget
    /\ arc = NoArc /\ claimed = {} /\ job = NoJob /\ jobRun = NoRun /\ jobOid = 0 /\ jobFor = 0
    /\ rgCopy = [s \in Slots |-> 0] /\ rt = NoRt
    /\ badDrop = FALSE /\ lostDrop = {} /\ wrongTgt = FALSE /\ collided = FALSE
    /\ falseRef = FALSE /\ wasted = FALSE /\ raised = FALSE /\ silent = FALSE /\ stuckSlot = FALSE /\ heldOwn = FALSE
    /\ cronOK \in {TRUE, FALSE}

FreshRows ==
    /\ rloc = [r \in Rows |-> IF r \in {"r1", "r2"} THEN 1 ELSE 0]
    /\ rst = [r \in Rows |-> IF r \in {"r1", "r2"} THEN "live" ELSE "new"]

Init ==
    /\ InitCommon
    /\ \E sh \in Shapes :
       CASE sh = "fresh" ->
              /\ rel = [o \in Oids |-> FreshRel(o)] /\ FreshRows
              /\ repoch = [r \in Rows |-> 1]
              /\ part = [s \in Slots |-> FreshPart(s)] /\ led = [l \in Pos |-> NoLed]
              /\ obj = [k \in Pos |-> {}] /\ copied = {}
              /\ horizon = 0 /\ archOn \in {TRUE, FALSE} /\ otherMark = "none" /\ upgraded = TRUE
         \* An older install's block left origin-only, coverage recorded under it (#651).
         [] sh = "origin" ->
              /\ rel = [o \in Oids |-> IF o = 1 THEN [FreshRel(1) EXCEPT !.trig = "origin"] ELSE FreshRel(o)]
              /\ FreshRows /\ repoch = [r \in Rows |-> 1]
              /\ part = [s \in Slots |-> FreshPart(s)]
              /\ led = [l \in Pos |-> IF l = 0 THEN LedRow(Canon(0), Canon(1), "c1", 1, {"r1"}) ELSE NoLed]
              /\ obj = [k \in Pos |-> IF k = 0 THEN {"r1"} ELSE {}] /\ copied = {}
              /\ horizon = 2 /\ archOn = TRUE /\ otherMark = "none" /\ upgraded = TRUE
         \* Before the upgrade that adds archive_ledger.child_oid: a chunk with no
         \* oid, under a block left origin-only (#1160).
         [] sh = "upg" ->
              /\ rel = [o \in Oids |-> IF o = 1 THEN [FreshRel(1) EXCEPT !.trig = "origin"] ELSE FreshRel(o)]
              /\ FreshRows /\ repoch = [r \in Rows |-> 1]
              /\ part = [s \in Slots |-> FreshPart(s)]
              /\ led = [l \in Pos |-> IF l = 0 THEN LedRow(Canon(0), Canon(1), "c1", 0, {"r1"}) ELSE NoLed]
              /\ obj = [k \in Pos |-> IF k = 0 THEN {"r1"} ELSE {}] /\ copied = {}
              /\ horizon = 2 /\ archOn = TRUE /\ otherMark = "none" /\ upgraded = FALSE
         \* A pre-#977 live chunk: covered_hi stored offset-less by a strategy in
         \* zone -1, so its text reads 2 in a UTC session but names the instant 1.
         [] sh = "olive" ->
              /\ rel = [o \in Oids |-> IF o = 1 THEN [FreshRel(1) EXCEPT !.trig = "always"] ELSE FreshRel(o)]
              /\ FreshRows /\ repoch = [r \in Rows |-> 1]
              /\ part = [s \in Slots |-> FreshPart(s)]
              /\ led = [l \in Pos |-> IF l = 0
                          THEN LedRow(Canon(0), [w |-> 2, off |-> FALSE, rz |-> -1], "c1", 1, {"r1"})
                          ELSE NoLed]
              /\ obj = [k \in Pos |-> IF k = 0 THEN {"r1"} ELSE {}] /\ copied = {}
              /\ horizon = 2 /\ archOn = TRUE /\ otherMark = "none" /\ upgraded = TRUE
         \* A pre-#977 RETIRED chunk [0, 1) whose offset-less hi a UTC+1 session
         \* wrote (instant 1, text 0), and a partition re-created over its range and
         \* adopted (oid 3, holding r2). r1 is gone; the object at key 0 is its only copy.
         [] sh = "oret" ->
              /\ rel = [o \in Oids |->
                          IF o = 1 THEN [FreshRel(1) EXCEPT !.ex = FALSE, !.dead = TRUE, !.par = 0]
                          ELSE IF o = 3 THEN [FreshRel(1) EXCEPT !.trig = "always"]
                          ELSE FreshRel(o)]
              /\ rloc = [r \in Rows |-> IF r = "r2" THEN 3 ELSE 0]
              /\ rst = [r \in Rows |-> IF r = "r1" THEN "gone" ELSE IF r = "r2" THEN "live" ELSE "new"]
              /\ repoch = [r \in Rows |-> 1]
              /\ part = [s \in Slots |-> IF s = 1 THEN [FreshPart(1) EXCEPT !.oid = 3] ELSE FreshPart(s)]
              /\ led = [l \in Pos |-> IF l = 0
                          THEN [LedRow(Canon(0), [w |-> 0, off |-> FALSE, rz |-> -1], "c1", 1, {"r1"})
                                EXCEPT !.ret = TRUE]
                          ELSE NoLed]
              /\ obj = [k \in Pos |-> IF k = 0 THEN {"r1"} ELSE {}] /\ copied = {<<"r1", 0>>}
              /\ horizon = 2 /\ archOn = TRUE /\ otherMark = "none" /\ upgraded = TRUE
         \* A partition bound an older install stored offset-less (#500).
         [] sh = "opart" ->
              /\ rel = [o \in Oids |-> FreshRel(o)] /\ FreshRows /\ repoch = [r \in Rows |-> 1]
              /\ part = [s \in Slots |-> [FreshPart(s) EXCEPT !.hiB = [w |-> Hi(s), off |-> FALSE, rz |-> 0]]]
              /\ led = [l \in Pos |-> NoLed] /\ obj = [k \in Pos |-> {}] /\ copied = {}
              /\ horizon = 1 /\ archOn = FALSE /\ otherMark = "none" /\ upgraded = TRUE
         \* Another parent, paused, holds a mark its dispatch never recorded (#1335 b1).
         [] sh = "other" ->
              /\ rel = [o \in Oids |-> FreshRel(o)] /\ FreshRows /\ repoch = [r \in Rows |-> 1]
              /\ part = [s \in Slots |-> FreshPart(s)] /\ led = [l \in Pos |-> NoLed]
              /\ obj = [k \in Pos |-> {}] /\ copied = {}
              /\ horizon = 2 /\ archOn = FALSE /\ otherMark = "undisp" /\ upgraded = TRUE
         \* The forget_missing path: r3 belongs to a table re-created later (#893).
         [] sh = "pd" ->
              /\ rel = [o \in Oids |-> FreshRel(o)] /\ FreshRows
              /\ repoch = [r \in Rows |-> IF r = "r3" THEN 2 ELSE 1]
              /\ part = [s \in Slots |-> FreshPart(s)] /\ led = [l \in Pos |-> NoLed]
              /\ obj = [k \in Pos |-> {}] /\ copied = {}
              /\ horizon = 2 /\ archOn \in BOOLEAN /\ otherMark = "none" /\ upgraded = TRUE
         \* A partition dropped by hand after its chunk [0, 1) was archived (its object the
         \* only copy of r1), and a table re-created under its name and attached (oid 3,
         \* holding r2 at 0), not yet adopted (#1141 b1).
         [] sh = "ogone" ->
              /\ rel = [o \in Oids |->
                          IF o = 1 THEN [FreshRel(1) EXCEPT !.ex = FALSE, !.dead = TRUE, !.par = 0]
                          ELSE IF o = 3 THEN FreshRel(1)
                          ELSE FreshRel(o)]
              /\ rloc = [r \in Rows |-> IF r = "r2" THEN 3 ELSE 0]
              /\ rst = [r \in Rows |-> IF r = "r1" THEN "gone" ELSE IF r = "r2" THEN "live" ELSE "new"]
              /\ repoch = [r \in Rows |-> 1]
              /\ part = [s \in Slots |-> FreshPart(s)]
              /\ led = [l \in Pos |-> IF l = 0 THEN LedRow(Canon(0), Canon(1), "c1", 1, {"r1"}) ELSE NoLed]
              /\ obj = [k \in Pos |-> IF k = 0 THEN {"r1"} ELSE {}] /\ copied = {<<"r1", 0>>}
              /\ horizon = 2 /\ archOn = TRUE /\ otherMark = "none" /\ upgraded = TRUE

-----------------------------------------------------------------------------
(* maintain's write-block step (reference.md `maintain`, "Write-blocking"). *)

WriteBlockStep(s, z) ==
    /\ upgraded /\ parentEx /\ part[s].pr
    /\ LET o == PartRel(s) IN
       IF ~IdentityOK(s)
       THEN /\ falseRef' = (falseRef \/ Spurious(s))      \* fail_write_block_identity
            /\ UNCHANGED <<rel, led>>
       ELSE IF HandDetached(s, o) \/ (Pending(o) /\ ~PgpmHolds(s, o))
       THEN UNCHANGED <<rel, led, falseRef>>                \* the operator's: not walked
       ELSE IF Eligible(s, z)
       THEN IF IsBlocked(o) THEN UNCHANGED <<rel, led, falseRef>>
            ELSE \* coverage found under no block is discarded, then the block put back ALWAYS
                 /\ led' = ResetCoverage(s, o)  \* @guard G564tick
                 /\ rel' = [rel EXCEPT ![o].trig = "always"]
                 /\ UNCHANGED falseRef
       ELSE IF rel[o].trig = "none" THEN UNCHANGED <<rel, led, falseRef>>
       \* retention no longer reaches it: lift the block, unless coverage is recorded (skip_write_block_lift)
       ELSE IF LiveChunks(s, o) = {}  \* @guard G452
            THEN /\ rel' = [rel EXCEPT ![o].trig = "none"] /\ UNCHANGED <<led, falseRef>>
            ELSE UNCHANGED <<rel, led, falseRef>>
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet, envLeft>>
    /\ UNCHANGED <<part, obj, claimed, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED <<badDrop, copied, lostDrop, wrongTgt, collided, wasted, raised, silent, stuckSlot, heldOwn>>

-----------------------------------------------------------------------------
(* maintain's archive step, pgpm._archive_step (archive_batch 1): one      *)
(* transaction per call; the strategy's PUT is not undone by its rollback. *)

\* The step's candidates, before archive_batch's limit: an attached, ALWAYS-blocked,
\* not fully covered partition not over a retired chunk's range. A detached
\* retirement of pgpm's own is left out before the limit (#1335 b3).
CandAtt(s, o) == Attached(o, 1)  \* @guard G1335b3
\* No detached table is handed to the strategy, a retirement of pgpm's own included.
StepReads(s, o) == Attached(o, 1)  \* @guard G1259step
Candidate(s, z) ==
    /\ part[s].pr
    /\ LET o == PartRel(s) IN
         \/ ~IdentityOK(s)            \* refused below, deliberately holding the batch
         \/ /\ o # 0 /\ CandAtt(s, o) /\ IsBlocked(o)
            /\ ~FullyCovered(s, o, z) /\ ~OverRetired(s)
Archivable(s, z) ==
    LET o == PartRel(s) IN
      part[s].pr /\ IdentityOK(s) /\ Attached(o, 1) /\ IsBlocked(o) /\ ~FullyCovered(s, o, z) /\ ~OverRetired(s)

\* The coverage an untracked name holds over a tracked partition's range is
\* discarded first (#511's orphan rule); it reads each such row's lo as a
\* value, and a lo stored in a session's DateStyle does not cast (#1054 b2).
NameTracked(l) == \E s \in Slots : part[s].pr /\ part[s].name = led[l].name
OidTracked(l) == led[l].oid # 0 /\ \E s \in Slots : part[s].pr /\ part[s].oid = led[l].oid
Spared(l) == NameTracked(l) \/ ("H_C2" \in Hypotheses /\ OidTracked(l))
OrphanRows == {l \in Pos : led[l].ex /\ ~led[l].ret /\ ~Spared(l)}  \* @guard GWitness

ArchiveStep(z) ==
    /\ upgraded /\ parentEx /\ archOn /\ arc = NoArc
    /\ IF \E l \in OrphanRows : ~led[l].lob.off
       THEN /\ raised' = TRUE
            /\ UNCHANGED <<arc, led, obj, claimed, rel, collided, falseRef, wasted, silent>>
       ELSE IF OrphanRows # {}
       THEN /\ led' = Discard(MarkGone(led), {l \in OrphanRows : MarkGone(led)[l].ex /\ ~MarkGone(led)[l].ret})
            /\ UNCHANGED <<arc, obj, claimed, rel, raised, collided, falseRef, wasted, silent>>
       ELSE
       \E s \in Slots :
         /\ Candidate(s, z)
         /\ \A s2 \in Slots : s2 < s => ~Candidate(s2, z)          \* oldest first, batch of 1
         /\ LET o == PartRel(s) IN
            IF ~IdentityOK(s)
            THEN /\ falseRef' = (falseRef \/ Spurious(s))          \* fail_archive_identity
                 /\ UNCHANGED <<arc, led, obj, claimed, rel, raised, collided, wasted, silent>>
            ELSE IF ~StepReads(s, o)                                \* skip_archive: not the parent's now
            THEN /\ wasted' = (wasted \/ \E s2 \in Slots : s2 # s /\ Archivable(s2, z))
                 /\ UNCHANGED <<arc, led, obj, claimed, rel, raised, collided, falseRef, silent>>
            ELSE IF OffsetlessLive(s, o)                            \* archive_coverage_reset
            THEN /\ led' = ResetCoverage(s, o)
                 /\ UNCHANGED <<arc, obj, claimed, rel, raised, collided, falseRef, wasted, silent>>
            ELSE LET lo == Watermark(s, o)
                     a == ChunkStop(lo, z)
                     A == ReadThroughParent(lo, a, z) IN
                 IF a <= lo
                 THEN /\ silent' = TRUE                             \* no chunk, nothing logged
                      /\ UNCHANGED <<arc, led, obj, claimed, rel, raised, collided, falseRef, wasted>>
                 \* the strategy is called: ArchFinish is its return (the environment acts in between)
                 ELSE /\ arc' = [s |-> s, o |-> o, lo |-> lo, a |-> a, z |-> z, A0 |-> A, pre |-> led[lo].ex]
                      /\ UNCHANGED <<led, obj, claimed, rel, raised, collided, falseRef, wasted, silent>>
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet, envLeft>>
    /\ UNCHANGED <<part, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded>>
    /\ UNCHANGED <<badDrop, copied, lostDrop, wrongTgt, stuckSlot, heldOwn>>

\* After the strategy returns, the step asks the catalog once more and records the
\* chunk only if the partition is still attached and not pending a detach
\* (reference.md, Byte-budget chunked archiving; round 4 of #1259's verification).
ArcRecheck(o) == Attached(o, 1)  \* @guard G1259r4
\* What the strategy read: all of A0 if no detach's first transaction committed
\* during the call, otherwise anything from what the parent shows now up to A0.
ArchFinish ==
    /\ arc # NoArc
    /\ LET s == arc.s  o == arc.o  lo == arc.lo  a == arc.a  z == arc.z
           Now == ReadThroughParent(lo, a, z) IN
       \E A \in {X \in SUBSET arc.A0 : Now \subseteq X} :
       /\ arc' = NoArc
       /\ IF ~PutOK(lo, a, A)
          THEN UNCHANGED <<led, obj, claimed, collided>>         \* the strategy refuses: skip_archive
          ELSE \E c \in Returns(lo, a, s) :
               /\ obj' = [obj EXCEPT ![Key(lo)] = A]
               /\ claimed' = claimed \cup {Key(lo)}
               /\ IF ~ContractOK(lo, c, s)
                  THEN UNCHANGED <<led, collided>>          \* fail_archive_contract
                  ELSE IF ~ArcRecheck(o)
                  THEN UNCHANGED <<led, collided>>          \* skip_archive: a detach landed during the call
                  \* duplicate key: the step raises; every tick (a wedge) when the row was there before the
                  \* call, once when another session recorded the chunk during it
                  ELSE IF led[lo].ex
                  THEN /\ collided' = (collided \/ arc.pre) /\ UNCHANGED led
                  ELSE /\ led' = [led EXCEPT ![lo] = LedRow(Canon(lo), Recorded(c, z), part[s].name, o, A)]
                       /\ UNCHANGED collided
    /\ UNCHANGED <<baseVars, part, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark,
                   upgraded, rel>>
    /\ UNCHANGED <<badDrop, copied, lostDrop, wrongTgt, falseRef, wasted, raised, silent, stuckSlot, heldOwn>>

-----------------------------------------------------------------------------
(* retire(p_parent, p_child) (reference.md `retire`), called by retain()   *)
(* from a tick or directly by an operator in any session zone.             *)

\* Begin: claim the pgpm.part row, check the horizon and the identity
\* anchors, resolve the partition by name; then wait for its lock.
RetireBegin(s, z) ==
    /\ upgraded /\ parentEx /\ rt = NoRt /\ part[s].pr /\ Eligible(s, z)
    /\ IF ~IdentityOK(s)
       THEN /\ falseRef' = (falseRef \/ Spurious(s))        \* fail_retain_identity
            /\ IdleIfHolds(OwnNsp(s), part[s].name)
            /\ UNCHANGED rt
       ELSE /\ rt' = [s |-> s, o |-> PartRel(s), z |-> z]
            /\ UNCHANGED <<falseRef, job>>
    /\ UNCHANGED <<baseVars, part, led, obj, claimed, horizon, archOn, cronOK, jobRun, jobOid, jobFor, rgCopy,
                   otherMark, upgraded, arc>>
    /\ UNCHANGED <<badDrop, copied, lostDrop, wrongTgt, collided, wasted, raised, silent, stuckSlot, heldOwn>>

\* The lock is taken by oid and checked: the name must still denote the
\* relation retire vouched for once the wait ends (#1335 b10).
RetireLockOK == Resolve(OwnNsp(rt.s), part[rt.s].name) = rt.o  \* @guard G1335b10
\* The DROP names the relation retire locked, by the name it has under the lock.
DropTarget(s, o) == o  \* @guard G1335b10

\* Another retirement holds the database-wide detach slot: an earlier mark
\* vouched for by its dispatch record, on a partition still in the parent.
SlotHeldBy(s2) == Attached(part[s2].disp, 1) \/ Pending(part[s2].disp)  \* @guard G1365
SlotBusy(s) ==
    \/ \E s2 \in Slots : s2 # s /\ part[s2].pr /\ part[s2].ret
                         /\ PgpmHolds(s2, part[s2].disp) /\ SlotHeldBy(s2)
    \/ otherMark = "disp"  \* @guard G1335b1
TrueBusy(s) ==
    \/ \E s2 \in Slots : s2 # s /\ part[s2].pr /\ TrueHolds(s2, part[s2].disp)
                         /\ (Attached(part[s2].disp, 1) \/ Pending(part[s2].disp))
    \/ otherMark = "disp"

KeepRetire == UNCHANGED <<rpos, repoch, parentNsp, parentEx, epoch2, liveDet, envLeft,
                          obj, claimed, horizon, archOn, cronOK, jobRun, jobOid, jobFor, otherMark, upgraded, arc>>

\* The drop itself, in the one transaction: reclaim an in-flight regrain's
\* copy (#519), DROP, mark the chunks retired, delete the pgpm.part row.
RetireDrop(s, o) ==
    /\ DropGhosts(o, s)
    /\ LET c == rgCopy[s] IN
         IF c # 0  \* @guard G519
         THEN /\ rel' = [rel EXCEPT ![o].ex = FALSE, ![o].dead = TRUE, ![o].par = 0, ![o].pend = FALSE,
                                    ![c].ex = FALSE, ![c].dead = TRUE]
              /\ rgCopy' = [rgCopy EXCEPT ![s] = 0]
         ELSE /\ rel' = [rel EXCEPT ![o].ex = FALSE, ![o].dead = TRUE, ![o].par = 0, ![o].pend = FALSE]
              /\ UNCHANGED rgCopy
    /\ rst' = [r \in Rows |-> IF rloc[r] = o /\ rst[r] = "live" THEN "gone" ELSE rst[r]]
    /\ rloc' = [r \in Rows |-> IF rloc[r] = o THEN 0 ELSE rloc[r]]
    /\ led' = [l \in Pos |-> IF l \in LiveChunks(s, o) THEN [led[l] EXCEPT !.ret = TRUE] ELSE led[l]]
    /\ part' = [part EXCEPT ![s].pr = FALSE]
    /\ opOwned' = opOwned \ {o}
    \* the detach path returns the job to idle whatever it holds (retire step 3); the
    \* one-step path only if it still holds this partition's detach
    /\ IF FKIn THEN job' = NoJob ELSE IdleIfHolds(rel[o].nsp, rel[o].name)

RetireEnd ==
    /\ rt # NoRt
    /\ rt' = NoRt
    /\ LET s == rt.s  z == rt.z  o == rt.o IN
       IF ~part[s].pr \/ ~Eligible(s, z)
       THEN UNCHANGED <<rel, part, led, job, rgCopy, opOwned, rloc, rst, ghostVars>>
       ELSE IF ~RetireLockOK                                      \* fail_retain_identity
       THEN UNCHANGED <<rel, part, led, job, rgCopy, opOwned, rloc, rst, ghostVars>>
       \* a mark without the dispatch record vouches for nothing: disowned
       ELSE IF part[s].ret /\ ~Attached(o, 1) /\ ~PgpmHolds(s, o)
       THEN /\ part' = [part EXCEPT ![s].ret = FALSE, ![s].rOid = 0]
            /\ IdleIfHolds(rel[o].nsp, rel[o].name)
            /\ UNCHANGED <<rel, led, rgCopy, opOwned, rloc, rst, ghostVars>>
       \* detached by something other than pgpm: refused, fail_retain_drop (#652)
       ELSE IF HandDetached(s, o)  \* @guard G652
       THEN UNCHANGED <<rel, part, led, job, rgCopy, opOwned, rloc, rst, ghostVars>>
       \* pending a concurrent detach pgpm did not issue: skip_retain (#705)
       ELSE IF Pending(o) /\ ~PgpmHolds(s, o)  \* @guard G705
       THEN UNCHANGED <<rel, part, led, job, rgCopy, opOwned, rloc, rst, ghostVars>>
       \* coverage recorded while no block was in force is discarded (#564)
       ELSE IF LiveChunks(s, o) # {} /\ ~IsBlocked(o)  \* @guard G564
       THEN /\ led' = ResetCoverage(s, o)
            /\ rel' = [rel EXCEPT ![o].trig = "always"]
            /\ UNCHANGED <<part, job, rgCopy, opOwned, rloc, rst, ghostVars>>
       ELSE IF ~FullyCovered(s, o, z)
       THEN /\ rel' = [rel EXCEPT ![o].trig = "always"]
            /\ UNCHANGED <<part, led, job, rgCopy, opOwned, rloc, rst, ghostVars>>
       \* a 0-row chunk over rows the partition holds was never read (#1159)
       ELSE IF archOn /\ \E l \in LiveChunks(s, o) :
                 led[l].cnt = 0 /\ \E r \in RowsOf(o) : rpos[r] >= l /\ rpos[r] < ChunkHi(l, z)  \* @guard G1159
       THEN /\ led' = ResetCoverage(s, o)
            /\ rel' = [rel EXCEPT ![o].trig = "always"]
            /\ UNCHANGED <<part, job, rgCopy, opOwned, rloc, rst, ghostVars>>
       ELSE IF FKIn /\ (Attached(o, 1) \/ Pending(o))
       THEN \* the detach path: dispatch, return false; the DROP is a later call's
            IF Pending(o) \/ SlotBusy(s)
            THEN /\ stuckSlot' = (stuckSlot \/ (~Pending(o) /\ ~TrueBusy(s)))
                 /\ rel' = [rel EXCEPT ![o].trig = "always"]
                 /\ UNCHANGED <<part, led, job, rgCopy, opOwned, rloc, rst, badDrop, copied, lostDrop, wrongTgt,
                                collided, falseRef, wasted, raised, silent, heldOwn>>
            ELSE /\ rel' = [rel EXCEPT ![o].trig = "always"]
                 /\ part' = [part EXCEPT ![s].ret = TRUE, ![s].rOid = o,
                                         ![s].oid = IF part[s].oid = 0 THEN o ELSE part[s].oid,
                                         ![s].disp = IF cronOK THEN o ELSE part[s].disp]
                 /\ job' = IF cronOK THEN [n |-> rel[o].nsp, nm |-> rel[o].name, o |-> o] ELSE job
                 /\ UNCHANGED <<led, rgCopy, opOwned, rloc, rst, ghostVars>>
       ELSE RetireDrop(s, DropTarget(s, o)) /\ UNCHANGED <<collided, falseRef, wasted, raised, silent, stuckSlot, heldOwn>>
    /\ KeepRetire

-----------------------------------------------------------------------------
(* The pgpm_detach pg_cron job: its command names the partition; pg_cron   *)
(* re-resolves the name in its own session (reference.md "What retire      *)
(* checks a partition's identity against").                                *)

\* pg_cron launches a run with the command the job holds at that moment; the
\* run is independent of the job from then on, so returning the job to idle
\* does not stop a run already launched (the #724 race).
\* A run whose ALTER TABLE names no existing table errors at once, so a launched
\* run is one queued on an existing parent (epoch 1, or the namesake of epoch 2).
JobLaunch ==
    /\ cronOK /\ job # NoJob /\ jobRun = NoRun /\ (parentEx \/ epoch2)
    /\ jobRun' = Cmd(job)
    \* the relation whose dispatch armed the command, while a live retirement still owns it
    /\ jobFor' = IF \E s \in Slots : part[s].pr /\ part[s].ret /\ part[s].disp = job.o THEN job.o ELSE 0
    /\ UNCHANGED <<baseVars, part, led, obj, claimed, horizon, archOn, cronOK, job, jobOid, rgCopy, rt,
                   otherMark, upgraded, arc, ghostVars>>

\* The run's first transaction: the DETACH ... CONCURRENTLY statement resolves
\* the name under its lock (PostgreSQL re-resolves after the wait), checks that
\* it is a partition, and marks it pending; its rows leave the parent. One
\* step, since nothing that moves a relation can interleave under that lock.
\* A run dispatched for one relation that lands on ANOTHER is the documented
\* gap (reference.md "What retire checks a partition's identity against":
\* "The detach can still land on a substitute; the destructive half cannot"):
\* the substitute is then a table detached by something other than
\* retirement, the operator's. Two landings have no such cover: a run whose
\* command no live retirement owned when it launched (#893), and a run that
\* lands on the very relation it was dispatched for after pgpm took that
\* retirement back (claim C1).
JobPhase1 ==
    /\ jobRun # NoRun /\ jobOid = 0
    /\ LET x == Resolve(jobRun.n, jobRun.nm) IN
       IF x # 0 /\ rel[x].par # 0 /\ ~rel[x].pend /\ x \notin liveDet
       THEN LET mine == \E s \in Slots : part[s].pr /\ part[s].disp = x
                substitute == jobFor # 0 /\ x # jobFor IN
            /\ rel' = [rel EXCEPT ![x].pend = TRUE]
            /\ liveDet' = liveDet \cup {x}
            /\ jobOid' = x
            /\ wrongTgt' = (wrongTgt \/ (~mine /\ ~substitute))
            /\ opOwned' = IF ~mine /\ substitute THEN opOwned \cup {x} ELSE opOwned
            /\ UNCHANGED <<jobRun, jobFor>>
       ELSE /\ jobRun' = NoRun /\ jobFor' = 0                   \* the run errors
            /\ UNCHANGED <<rel, liveDet, jobOid, wrongTgt, opOwned>>
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, envLeft>>
    /\ UNCHANGED <<part, led, obj, claimed, horizon, archOn, cronOK, job, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED <<badDrop, copied, lostDrop, collided, falseRef, wasted, raised, silent, stuckSlot, heldOwn>>

\* Second transaction: the detach completes.
JobPhase2 ==
    /\ jobOid # 0 /\ jobOid \in liveDet /\ Pending(jobOid)
    /\ rel' = [rel EXCEPT ![jobOid].par = 0, ![jobOid].pend = FALSE]
    /\ jobRun' = NoRun /\ jobOid' = 0 /\ jobFor' = 0 /\ liveDet' = liveDet \ {jobOid}
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, envLeft>>
    /\ UNCHANGED <<part, led, obj, claimed, horizon, archOn, cronOK, job, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

\* A run whose session died (CrashDetacher) or whose partition was finalized
\* under it ends.
JobEnd ==
    /\ jobOid # 0 /\ (jobOid \notin liveDet \/ ~Pending(jobOid))
    /\ jobRun' = NoRun /\ jobOid' = 0 /\ jobFor' = 0 /\ liveDet' = liveDet \ {jobOid}
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, envLeft>>
    /\ UNCHANGED <<part, led, obj, claimed, horizon, archOn, cronOK, job, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

-----------------------------------------------------------------------------
(* _detach_reap (reference.md `_detach_reap`): finishes an ABANDONED       *)
(* concurrent detach, never a live one; first disowns a mark without the  *)
(* dispatch record.                                                        *)

ReapLive(x) == x \notin liveDet  \* @guard G453
DetachReap(x) ==
    /\ Pending(x) /\ ReapLive(x)
    /\ rel' = [rel EXCEPT ![x].par = 0, ![x].pend = FALSE]
    /\ part' = [s \in Slots |-> IF part[s].pr /\ part[s].ret /\ part[s].rOid = x /\ ~PgpmHolds(s, x)
                                THEN [part[s] EXCEPT !.ret = FALSE, !.rOid = 0] ELSE part[s]]
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet, envLeft>>
    /\ UNCHANGED <<led, obj, claimed, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

-----------------------------------------------------------------------------
(* The recall of a retirement retention no longer reaches (_retain_recall, *)
(* by set_retain or the next tick's retain(); reference.md `retire`, "A    *)
(* retirement belongs to the retention policy that started it").           *)

Recall(s, z) ==
    /\ upgraded /\ parentEx /\ part[s].pr /\ part[s].ret /\ ~Eligible(s, z)
    /\ LET o == Resolve(RecallNsp(s), part[s].name) IN
       \/ /\ o # 0 /\ Attached(o, 1)
          \* the job back to idle; the mark is cleared only once no detach of it is running (#724)
          /\ IdleIfHolds(rel[o].nsp, rel[o].name)
          /\ IF jobRun # [n |-> rel[o].nsp, nm |-> rel[o].name] /\ o \notin liveDet  \* @guard G724
             THEN part' = [part EXCEPT ![s].ret = FALSE, ![s].rOid = 0, ![s].disp = 0]
             ELSE UNCHANGED part
          /\ UNCHANGED rel
       \* H_C1, as the attached branch does it: with a run of the command in
       \* flight, idle the job and come back; attach once no run is in flight
       \* (a wait that only blocks would leave the armed job relaunching for ever)
       \/ /\ "H_C1" \in Hypotheses
          /\ o # 0 /\ rel[o].ex /\ rel[o].par = 0 /\ PgpmHolds(s, o)
          /\ jobRun = [n |-> rel[o].nsp, nm |-> rel[o].name]
          /\ IdleIfHolds(rel[o].nsp, rel[o].name)
          /\ UNCHANGED <<rel, part>>
       \/ /\ o # 0 /\ rel[o].ex /\ rel[o].par = 0 /\ PgpmHolds(s, o)
          /\ ("H_C1" \in Hypotheses => jobRun # [n |-> rel[o].nsp, nm |-> rel[o].name])
          \* already detached by that detach: attach it back on its own bounds (retain_reattach)
          /\ ~\E q \in Oids : rel[q].ex /\ rel[q].par = 1 /\ rel[q].slot = s
          /\ rel' = [rel EXCEPT ![o].par = 1, ![o].slot = s]
          /\ part' = [part EXCEPT ![s].ret = FALSE, ![s].rOid = 0, ![s].disp = 0]
          /\ IdleIfHolds(rel[o].nsp, rel[o].name)
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet, envLeft>>
    /\ UNCHANGED <<led, obj, claimed, horizon, archOn, cronOK, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

-----------------------------------------------------------------------------
(* The operator utility scripts/archive_partition_whole.sql ("OC"): the    *)
(* oldest candidate as the archive step picks it, its whole remainder in   *)
(* one strategy call, held to the same contract.                           *)

ScriptAtt(s, o) == Attached(o, 1)  \* @guard G1159script
ScriptLo(w, z) == Canon(w)  \* @guard G1054b2
ScriptArchive(z) ==
    /\ Env("OC") /\ upgraded /\ parentEx /\ archOn
    /\ \E s \in Slots :
       LET o == PartRel(s) IN
       /\ part[s].pr /\ IdentityOK(s) /\ ScriptAtt(s, o) /\ IsBlocked(o)
       /\ ~FullyCovered(s, o, z) /\ ~OverRetired(s)
       /\ \A s2 \in Slots : s2 < s => ~(part[s2].pr /\ IdentityOK(s2) /\ ScriptAtt(s2, PartRel(s2))
                                       /\ IsBlocked(PartRel(s2)) /\ ~FullyCovered(s2, PartRel(s2), z)
                                       /\ ~OverRetired(s2))
       /\ LET lo == Watermark(s, o) IN
          \* asked for the whole remainder, the strategy may stop early at m (its byte budget)
          \E m \in (lo + 1)..Hi(s) :
          LET A == ReadThroughParent(lo, m, z) IN
          /\ PutOK(lo, Hi(s), A)
          /\ \E c \in Returns(lo, m, s) :
             /\ obj' = [obj EXCEPT ![Key(lo)] = A]
             /\ claimed' = claimed \cup {Key(lo)}
             /\ IF ~ScriptContractOK(lo, c, s) THEN UNCHANGED <<led, collided>>
                \* a duplicate key raises to the operator and rolls back (the PUT stays): no tick wedges on it
                ELSE IF led[lo].ex THEN UNCHANGED <<led, collided>>
                ELSE /\ led' = [led EXCEPT ![lo] = LedRow(ScriptLo(lo, z), Canon(c), part[s].name, o, A)]
                     /\ UNCHANGED collided
    /\ Spend
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>
    /\ UNCHANGED <<part, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED <<badDrop, copied, lostDrop, wrongTgt, falseRef, wasted, raised, silent, stuckSlot, heldOwn>>

\* A direct call of the strategy ("OC"): the documented manual path, reading
\* [lo, hi) through the parent and PUTting to the chunk's key.
DirectStrategy(lo, hi) ==
    /\ Env("OC") /\ parentEx /\ lo < hi /\ hi <= Hi(SlotOf(lo))
    /\ LET A == ReadThroughParent(lo, hi, 0) IN
         /\ PutOK(lo, hi, A)
         /\ obj' = [obj EXCEPT ![Key(lo)] = A]
         /\ claimed' = claimed \cup {Key(lo)}
    /\ Spend
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>
    /\ UNCHANGED <<part, led, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

SetArchiveFn ==
    /\ Env("OC") /\ ~archOn /\ archOn' = TRUE
    /\ Spend
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>
    /\ UNCHANGED <<part, led, obj, claimed, horizon, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

-----------------------------------------------------------------------------
(* Time and policy ("T"): time passes, set_retain loosens.                 *)

Age ==
    /\ "T" \in EnvGroups /\ horizon < 4 /\ horizon' = horizon + 1
    /\ UNCHANGED <<baseVars, part, led, obj, claimed, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt,
                   otherMark, upgraded, arc, ghostVars>>
Loosen ==
    /\ Env("T") /\ horizon > 0 /\ horizon' = horizon - 1
    /\ Spend
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>
    /\ UNCHANGED <<part, led, obj, claimed, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

-----------------------------------------------------------------------------
(* Upgrade ("UP"): install.sql over an older install attributes each chunk *)
(* to the relation pgpm recorded under its name, when that relation's      *)
(* block is one pgpm leaves (ALWAYS, origin-only, absent); a block only an *)
(* operator leaves (disabled) marks it retired (reference.md               *)
(* `pgpm.archive_ledger`).                                                 *)

AttributesChunk(o) == rel[o].trig \in {"always", "origin", "none"}  \* @guard G1160
Upgrade ==
    /\ ~upgraded /\ upgraded' = TRUE
    /\ led' = [l \in Pos |->
                IF led[l].ex /\ led[l].oid = 0 /\ ~led[l].ret
                THEN LET s == SlotOf(l)
                         o == Resolve(OwnNsp(s), led[l].name) IN
                     IF part[s].pr /\ o # 0 /\ o = part[s].oid /\ AttributesChunk(o)
                     THEN [led[l] EXCEPT !.oid = o] ELSE [led[l] EXCEPT !.ret = TRUE]
                ELSE led[l]]
    \* reference.md: a chunk under an ALWAYS or origin-only block is its partition's; one under a
    \* disabled block, or of a renamed partition, is marked retired and the partition held
    /\ heldOwn' = (heldOwn \/ \E l \in Pos :
                    /\ led[l].ex /\ led[l].oid = 0 /\ ~led[l].ret /\ led'[l].ret
                    /\ part[SlotOf(l)].pr /\ part[SlotOf(l)].oid # 0
                    /\ rel[part[SlotOf(l)].oid].ex /\ rel[part[SlotOf(l)].oid].name = led[l].name
                    /\ rel[part[SlotOf(l)].oid].trig \in {"always", "origin"})
    /\ UNCHANGED <<baseVars, part, obj, claimed, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt,
                   otherMark, arc, badDrop, copied, lostDrop, wrongTgt, collided, falseRef, wasted, raised, silent,
                   stuckSlot>>

-----------------------------------------------------------------------------
(* Regrain's effects on custody ("RG").                                    *)

RegrainStart(s) ==
    /\ "RG" \in EnvGroups /\ envLeft > 0 /\ parentEx /\ part[s].pr /\ rgCopy[s] = 0 /\ ~part[s].ret
    /\ Attached(part[s].oid, 1) /\ FreeOid # {} /\ Resolve(OwnNsp(s), "x") = 0
    /\ LET c == CHOOSE q \in FreeOid : TRUE IN
         /\ rel' = [rel EXCEPT ![c] = [ex |-> TRUE, dead |-> FALSE, nsp |-> OwnNsp(s), name |-> "x",
                                        par |-> 0, pend |-> FALSE, slot |-> s, trig |-> "none"]]
         /\ rgCopy' = [rgCopy EXCEPT ![s] = c]
    /\ Spend
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>
    /\ UNCHANGED <<part, led, obj, claimed, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

\* The swap, one transaction: the copy takes the source's rows, name and slot;
\* the source is dropped; its live coverage no longer describes any relation
\* and is discarded (#511).
SwapLedger(s, o) == ResetCoverage(s, o)  \* @guard G511
RegrainSwap(s) ==
    /\ "RG" \in EnvGroups /\ parentEx /\ part[s].pr /\ rgCopy[s] # 0 /\ ~part[s].ret
    /\ LET o == part[s].oid  c == rgCopy[s] IN
         /\ Attached(o, 1) /\ rel[c].ex
         /\ rel' = [rel EXCEPT ![o].ex = FALSE, ![o].dead = TRUE, ![o].par = 0,
                               ![c].par = 1, ![c].name = rel[o].name, ![c].nsp = rel[o].nsp,
                               ![c].trig = rel[o].trig]
         /\ rloc' = [r \in Rows |-> IF rloc[r] = o THEN c ELSE rloc[r]]
         /\ part' = [part EXCEPT ![s].oid = c]
         /\ led' = SwapLedger(s, o)
         /\ rgCopy' = [rgCopy EXCEPT ![s] = 0]
    /\ UNCHANGED <<rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet, envLeft>>
    /\ UNCHANGED <<obj, claimed, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

-----------------------------------------------------------------------------
(* adopt_partition (reference.md `adopt_partition`): records the relation  *)
(* now holding a partition's name; the gone relation's chunks are marked   *)
(* retired, never discarded (#1141 b1).                                    *)

Adopt(s) ==
    /\ Env("OD") /\ upgraded /\ parentEx /\ part[s].pr
    /\ LET o == Resolve(OwnNsp(s), part[s].name) IN
         \* "a table of the same name attached over another range is never adopted"
         /\ o # 0 /\ o # part[s].oid /\ Attached(o, 1) /\ rel[o].slot = s
         /\ part' = [part EXCEPT ![s].oid = o]
         /\ led' = ResetCoverage(s, o)
    /\ Spend
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>
    /\ UNCHANGED <<obj, claimed, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

-----------------------------------------------------------------------------
(* The forget_missing path ("PD"): the runbook's "drop the table and run   *)
(* pgpm.forget_missing()", then a table re-created under the same name.    *)

\* A launched run is a statement queued for the parent's lock; DROP TABLE of the
\* parent queues behind it, so the run resolves (against the old table) first.
OpDropParent ==
    /\ Env("PD") /\ parentEx /\ (jobRun = NoRun \/ jobOid # 0)
    /\ LET D == {o \in Oids : rel[o].ex /\ rel[o].par = 1} IN
         /\ rel' = [o \in Oids |-> IF o \in D THEN [rel[o] EXCEPT !.ex = FALSE, !.dead = TRUE, !.par = 0, !.pend = FALSE]
                                   ELSE rel[o]]
         /\ rst' = [r \in Rows |-> IF rloc[r] \in D /\ rst[r] = "live" THEN "gone" ELSE rst[r]]
         /\ rloc' = [r \in Rows |-> IF rloc[r] \in D THEN 0 ELSE rloc[r]]
         /\ copied' = copied \cup AttestPairs(UNION {RowsOf(o) : o \in D})
    /\ parentEx' = FALSE
    /\ Spend
    /\ UNCHANGED <<rpos, repoch, parentNsp, epoch2, opOwned, liveDet>>
    /\ UNCHANGED <<custVars>>
    /\ UNCHANGED <<badDrop, lostDrop, wrongTgt, collided, falseRef, wasted, raised, silent, stuckSlot, heldOwn>>

ForgetIdlesJob == TRUE  \* @guard G893
\* reference.md `forget_missing`: clears the parent's pgpm.part and ledger rows
\* (the ledger's are logged first), drops nothing (a regrain copy or a detached
\* partition is left in place and reported), and returns pgpm_detach to idle
\* when it forgets the retirement that armed it (#893).
ForgetMissing ==
    /\ ~parentEx /\ \E s \in Slots : part[s].pr
    /\ part' = [s \in Slots |-> [part[s] EXCEPT !.pr = FALSE]]
    /\ led' = [l \in Pos |-> NoLed]
    /\ rgCopy' = [s \in Slots |-> 0]
    /\ job' = IF ForgetIdlesJob THEN NoJob ELSE job
    \* a detached partition it was retiring is reported in orphan_tables, the operator's to deal with
    /\ opOwned' = opOwned \cup {o \in Oids : rel[o].ex /\ Custody(o)}
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, liveDet, envLeft, obj, claimed, horizon, archOn, cronOK, jobRun, jobOid, jobFor, rt, otherMark,
                   upgraded, arc, ghostVars>>

OpRecreate ==
    /\ Env("PD") /\ ~parentEx /\ ~epoch2 /\ \A s \in Slots : ~part[s].pr
    /\ FreeOid # {} /\ Resolve(parentNsp, "c1") = 0 /\ rst["r3"] = "new" /\ repoch["r3"] = 2
    /\ LET o == CHOOSE q \in FreeOid : TRUE IN
         /\ rel' = [rel EXCEPT ![o] = [ex |-> TRUE, dead |-> FALSE, nsp |-> parentNsp, name |-> "c1",
                                        par |-> 2, pend |-> FALSE, slot |-> 1, trig |-> "none"]]
         /\ rloc' = [rloc EXCEPT !["r3"] = o]
         /\ rst' = [rst EXCEPT !["r3"] = "live"]
    /\ epoch2' = TRUE
    /\ Spend
    /\ UNCHANGED <<rpos, repoch, parentNsp, parentEx, opOwned, liveDet, custVars, ghostVars>>

\* A namesake table's archive writer ("SB"), sharing the prefix, spelling it
\* plainly or with a leading slash. A key this parent claimed is diverted to
\* the writer's oid-shaped key, which no object here holds (#822); claims
\* compare the store's own spelling of a key (#1260).
ClaimHeld(k, sp) == k \in claimed  \* @guard G1260
OtherPut(k, sp) ==
    /\ Env("SB") /\ epoch2
    /\ IF ClaimHeld(k, sp)  \* @guard G822
       THEN UNCHANGED obj
       ELSE obj' = [obj EXCEPT ![k] = {}]
    /\ Spend
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>
    /\ UNCHANGED <<part, led, claimed, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt, otherMark, upgraded, arc>>
    /\ UNCHANGED ghostVars

\* The guide's rename of a partition as it used to document it: pgpm.part's
\* child_name carried in the same transaction, the ledger left behind
\* (guide.md "Do not rename a partition out from under pgpm").
OpRenameTracked(s, nm) ==
    /\ Env("RN") /\ part[s].pr /\ part[s].oid # 0 /\ rel[part[s].oid].ex
    /\ Resolve(rel[part[s].oid].nsp, nm) = 0
    /\ rel' = [rel EXCEPT ![part[s].oid].name = nm]
    /\ part' = [part EXCEPT ![s].name = nm]
    /\ Spend
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>
    /\ UNCHANGED <<led, obj, claimed, horizon, archOn, cronOK, job, jobRun, jobOid, jobFor, rgCopy, rt,
                   otherMark, upgraded, arc, ghostVars>>

-----------------------------------------------------------------------------
(* The environment of Base, with custody's ghost bookkeeping on a hand drop. *)

KeepCust == UNCHANGED <<custVars, ghostVars>>
OpDropTableC(o) ==
    /\ OpDropTable(o)
    /\ copied' = copied \cup AttestPairs(RowsOf(o))
    /\ UNCHANGED <<custVars>>
    /\ UNCHANGED <<badDrop, lostDrop, wrongTgt, collided, falseRef, wasted, raised, silent, stuckSlot, heldOwn>>

EnvNext ==
    \/ \E r \in Rows, p \in Pos, rep \in BOOLEAN : AppInsert(r, p, rep) /\ KeepCust
    \/ \E r \in Rows : AppDelete(r) /\ KeepCust
    \* reference.md `retire`: a partition whose detach pgpm dispatched, and which an
    \* operator then detached by hand, is pgpm's retirement still
    \/ Idle /\ \E o \in Oids : OpDetach(o, Custody(o)) /\ KeepCust
    \/ \E o \in Oids : OpDetachConc(o, Custody(o)) /\ KeepCust
    \/ Idle /\ \E o \in Oids : o # jobOid /\ OpFinalize(o) /\ KeepCust
    \/ Idle /\ \E o \in Oids, s \in Slots : OpAttach(o, s) /\ KeepCust
    \/ Idle /\ \E o \in Oids, nm \in Names : OpRename(o, nm) /\ KeepCust
    \/ Idle /\ \E s \in Slots, nm \in Names : OpRenameTracked(s, nm)
    \/ \E n \in Nsps, nm \in Names, r \in Rows \cup {"none"} : OpCreate(n, nm, r) /\ KeepCust
    \/ Idle /\ \E o \in Oids : OpDropTableC(o)
    \/ \E o \in Oids : OpDisableTrigger(o) /\ KeepCust
    \/ Idle /\ \E n \in Nsps : ParentSetSchema(n) /\ KeepCust
    \/ \E o \in Oids : CrashDetacher(o) /\ KeepCust
    \/ Age \/ Loosen
    \/ \E z \in SessZ : ScriptArchive(z)
    \/ \E lo \in Pos, hi \in 1..4 : DirectStrategy(lo, hi)
    \/ SetArchiveFn
    \/ \E s \in Slots : RegrainStart(s)
    \/ \E s \in Slots : Adopt(s)
    \/ Idle /\ OpDropParent
    \/ OpRecreate
    \/ \E k \in Pos, sp \in {"plain", "slash"} : OtherPut(k, sp)

\* While the archive step's strategy call is in flight (arc), the tick's other
\* steps wait for it (C6), and anything that needs a lock conflicting with the
\* step's ACCESS SHARE on the parent waits too; pg_cron's run is another session,
\* and a concurrent detach's first transaction does not wait (C9).
PgpmNext ==
    \/ Idle /\ \E s \in Slots, z \in SessZ : WriteBlockStep(s, z)
    \/ \E z \in SessZ : ArchiveStep(z)
    \/ ArchFinish
    \/ Idle /\ \E s \in Slots, z \in SessZ : RetireBegin(s, z)
    \/ Idle /\ RetireEnd
    \/ JobLaunch \/ JobPhase1 \/ JobEnd
    \/ Idle /\ JobPhase2
    \/ Idle /\ \E x \in Oids : DetachReap(x)
    \/ Idle /\ \E s \in Slots, z \in SessZ : Recall(s, z)
    \/ Idle /\ Upgrade
    \/ Idle /\ \E s \in Slots : RegrainSwap(s)
    \/ Idle /\ ForgetMissing

Next == PgpmNext \/ EnvNext

\* Fairness on pgpm's own processes only (pack 4.3, NoWedge): every tick
\* step, the job and the reap keep being taken.
Fairness ==
    /\ \A s \in Slots : WF_vars(WriteBlockStep(s, 0)) /\ WF_vars(Recall(s, 0))
    /\ WF_vars(ArchiveStep(0)) /\ WF_vars(ArchFinish) /\ WF_vars(Idle /\ RetireEnd)
    /\ \A s \in Slots : WF_vars(RetireBegin(s, 0))
    /\ WF_vars(JobLaunch) /\ WF_vars(JobPhase1) /\ WF_vars(JobPhase2) /\ WF_vars(JobEnd)
    /\ \A x \in Oids : WF_vars(DetachReap(x))
    /\ WF_vars(Upgrade)
    \* a statement the environment started finishes (Base A10)
    /\ \A o \in Oids : WF_vars(Idle /\ o # jobOid /\ OpFinalize(o) /\ KeepCust)

Spec == Init /\ [][Next]_vars
LiveSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(* Invariants. Names are stable; layer B reuses them (pack 4.3).            *)

\* DropOnlyCovered (pack 4.3; reference.md `retire`: "will not drop a child
\* until _archive_fully_covered confirms every chunk has landed").
DropOnlyCovered == ~badDrop

\* ArchiveNoClobber (pack 4.3; reference.md `pgpm.archive_ledger`: a retired
\* chunk's object "is the record of the only copy of its chunk's rows"). A row
\* is in `copied` once its relation is dropped while a ledger chunk attests an
\* object holding it; that object must keep holding it.
ArchiveNoClobber == \A p \in copied : p[1] \in obj[p[2]]

\* ResolveByRecord (pack 4.3; reference.md "What retire checks a partition's
\* identity against": "The detach can still land on a substitute; the
\* destructive half cannot").
ResolveByRecord == ~wrongTgt

\* NoLostRow (pack 4.3; guide.md Retain: retention drops "only when its whole
\* range is older than the horizon"; reference.md `retire`: a table the
\* operator detached is left alone). A row retention does not reach is
\* visible through its parent, or in a relation the operator owns, or in
\* custody: a partition pgpm's own vouched retirement holds, which the
\* recall attaches back (NoLostRowLive says it does).
Unaged(r) == repoch[r] = 2 \/ rpos[r] >= horizon
Stranded(r) ==
    /\ rst[r] = "live" /\ Unaged(r)
    /\ ~Attached(rloc[r], repoch[r]) /\ rloc[r] \notin opOwned
NoLostRow ==
    /\ lostDrop = {}
    /\ \A r \in Rows : Stranded(r) => Custody(rloc[r])
\* The recall attaches back into the parent, so the promise lasts while the parent
\* does: a dropped parent's leftover tables are the operator's (forget_missing's
\* orphan_tables), their rows still in them.
NoLostRowLive == \A r \in Rows : [](Stranded(r) /\ parentEx => <>(~Stranded(r) \/ ~parentEx))

\* NoWedge, as safety (pack 4.3 states it as liveness; each conjunct is a
\* state from which a documented contract says maintenance makes progress,
\* reached instead as a permanent stop that no contract documents).
\*  - no ledger insert collides (the step then raises every tick: #511, #454)
\*  - no identity refusal while the recorded relation is where its record says (#727, #1365)
\*  - archive_batch's turn never goes to a partition the step cannot archive (#1335 b3)
\*  - the step never raises outside its per-child handling (#1054 b2)
\*  - an aged candidate never yields no chunk silently (#788)
\*  - a retirement is never held by a mark that cannot progress (#1335 b1)
\*  - a retired chunk's relation is gone (a live partition is never held over its own chunk: #1160)
\*  - no regrain copy outlives its source (#519)
NoWedge ==
    /\ ~collided /\ ~falseRef /\ ~wasted /\ ~raised /\ ~silent /\ ~stuckSlot
    /\ \A l \in Pos : (led[l].ex /\ led[l].ret /\ led[l].oid # 0) => ~rel[led[l].oid].ex
    \* and the upgrade never retires a chunk it should attribute (the by-name chunks of an older install)
    /\ ~heldOwn
    /\ \A s \in Slots : rgCopy[s] # 0 => part[s].pr

\* LIVENESS WITNESSES (CLAUDE.md: pair every negative with a witness that its
\* conditions arise). Each states that something the invariants depend on NEVER
\* happens, and mutate.py witness requires TLC to find it does, at the default
\* configs' scope. A clean invariant over a model whose archive or drop is dead
\* proves nothing: a misparsed orphan rule once discarded every chunk on the
\* next tick, and every config still checked clean (docs/formal/record.md).
WitTwoChunks == ~\E l1, l2 \in Pos : l1 # l2 /\ SlotOf(l1) = SlotOf(l2)  \* one partition archived past one chunk
                                     /\ led[l1].ex /\ led[l2].ex /\ ~led[l1].ret /\ ~led[l2].ret
WitArchivedDrop == ~(archOn /\ copied # {})
WitDetachDispatched == ~\E s \in Slots : part[s].disp # 0
WitStrategyOvertaken == ~(arc # NoArc /\ ~Attached(arc.o, 1))
WitCustody == ~\E r \in Rows : Stranded(r)

\* Debug: the archive step's next chunk starts inside the partition.
WatermarkIn == \A s \in Slots : part[s].pr /\ PartRel(s) # 0 => Watermark(s, PartRel(s)) \in Lo(s)..Hi(s)
GapFree == \A s \in Slots, z \in SessZ : part[s].pr /\ PartRel(s) # 0 /\ archOn
                             /\ ~FullyCovered(s, PartRel(s), z) => Watermark(s, PartRel(s)) < Hi(s)

TypeOK ==
    /\ horizon \in 0..4
    /\ jobOid \in Oids \cup {0}
    /\ \A r \in Rows : rloc[r] \in Oids \cup {0}

=============================================================================
