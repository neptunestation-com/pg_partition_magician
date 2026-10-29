-------------------------------- MODULE Base --------------------------------
(***************************************************************************)
(* The shared world every pgpm protocol spec runs in: relations, rows,     *)
(* sessions, the object store, and the operator's hand actions.           *)
(*                                                                         *)
(* Source of every rule here: docs/pgpm-formal-methods-context-pack.md     *)
(* section 4.1 (modelling rules) and 4.2 (the environment), and the       *)
(* base-module requirements in docs/formal/tier12-catalogue.md ("What the  *)
(* base module has to contain", items 1 to 8).                             *)
(*                                                                         *)
(* ABSTRACTIONS (an unstated abstraction is a defect in the spec):         *)
(*  A1 One managed parent. Its partitions sit in Slots; slot s holds the   *)
(*     range [Lo(s), Hi(s)) of integer grid positions. A second parent    *)
(*     exists only as epoch 2: the table an operator re-creates under the  *)
(*     same name after dropping the first (forget_missing's runbook path). *)
(*  A2 Relations have identity (the oid, an element of Oids) and a name    *)
(*     (schema, relname), separately. Names are unique per schema; the     *)
(*     environment never creates a duplicate, as PostgreSQL refuses one.   *)
(*  A3 Rows are tokens with a grid position and an epoch. Payload is not   *)
(*     modelled. A row is in at most one relation.                         *)
(*  A4 Attachment: a relation is a partition of the parent (par = epoch),  *)
(*     possibly pending a concurrent detach (pend), or not a partition    *)
(*     (par = 0). A detach-pending partition's rows are invisible through  *)
(*     the parent, as in PostgreSQL.                                       *)
(*  A5 Session rendering: a stored bound is a record [w, off, rz]. With    *)
(*     off = TRUE, w is the instant (text with its UTC offset, canonical). *)
(*     With off = FALSE, the text is a wall time rendered in zone rz and   *)
(*     the instant is w - rz; a reader parses it in its own zone z as      *)
(*     w - z. Zones are small integers in grid positions. DateStyle and    *)
(*     abbreviation ambiguity are folded into the same shift.              *)
(*  A6 One atomic step per transaction (pack 4.1). A statement that waits  *)
(*     for a lock is modelled as two steps with the environment free to    *)
(*     act between them, only where the procedure resolves a name before   *)
(*     the wait; elsewhere the lock is taken by oid and the step is atomic.*)
(*  A7 The object store is a map from object key to the set of rows the    *)
(*     object holds. A PUT replaces the object and is NOT transactional:   *)
(*     it survives the rollback of the transaction that made it.          *)
(*  A8 Privileges and RLS (catalogue item 8) are not modelled here: no     *)
(*     custody Tier 1/2 in the retrodiction set turns on them.             *)
(*  A9 Environment actions are bounded by EnvBudget per behaviour, which   *)
(*     bounds the depth of every counterexample in environment steps, not  *)
(*     in pgpm steps. Time passing (Age) is bounded by the grid instead.   *)
(*  A10 A statement the environment starts is one environment step even    *)
(*     when it is two transactions: an operator's DETACH ... CONCURRENTLY  *)
(*     finishes (OpFinalize) without spending budget, and under LiveSpec   *)
(*     it is weakly fair, as a running statement finishes unless its       *)
(*     session dies (CrashDetacher, which does spend budget).              *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    Oids,        \* relation identities, e.g. 1..4
    Rows,        \* row tokens, e.g. {"r1","r2","r3"}
    Nsps,        \* schemas, e.g. {"a","b"}
    Names,       \* relnames, e.g. {"c1","c2","x"}
    Zones,       \* session zones as grid offsets, e.g. {-1, 0, 1}
    EnvBudget,   \* environment steps per behaviour
    EnvGroups    \* which environment groups are enabled (see Env below)

Slots == {1, 2}
Lo(s) == IF s = 1 THEN 0 ELSE 2
Hi(s) == IF s = 1 THEN 2 ELSE 4
Pos == 0..3
SlotOf(p) == IF p < 2 THEN 1 ELSE 2

Canon(v) == [w |-> v, off |-> TRUE, rz |-> 0]
Instant(b) == IF b.off THEN b.w ELSE b.w - b.rz
ParseIn(b, z) == IF b.off THEN b.w ELSE b.w - z
MinZ == CHOOSE z \in Zones : \A y \in Zones : z <= y
MaxZ == CHOOSE z \in Zones : \A y \in Zones : z >= y

VARIABLES
    rel,        \* [Oids -> [ex, dead, nsp, name, par, pend, slot, trig]]
    rloc,       \* [Rows -> Oids \cup {0}]: the relation holding the row, 0 if none
    rpos,       \* [Rows -> Pos]
    rst,        \* [Rows -> {"new", "live", "gone"}]
    repoch,     \* [Rows -> {1, 2}]
    parentNsp,  \* the managed parent's schema (ALTER TABLE ... SET SCHEMA moves it)
    parentEx,   \* the managed parent (epoch 1) exists
    epoch2,     \* a namesake parent (epoch 2) has been created
    opOwned,    \* relations an operator detached by hand: their rows are the operator's
    liveDet,    \* relations a live session is concurrently detaching (pending, session alive)
    envLeft     \* environment steps left

baseVars == <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet, envLeft>>

Trigs == {"none", "always", "origin", "off"}

Resolve(n, nm) ==
    LET S == {o \in Oids : rel[o].ex /\ rel[o].nsp = n /\ rel[o].name = nm}
    IN IF S = {} THEN 0 ELSE CHOOSE o \in S : TRUE

FreeOid == {o \in Oids : ~rel[o].ex /\ ~rel[o].dead}   \* no oid reuse (wraparound is out of scope)
RowsOf(o) == {r \in Rows : rst[r] = "live" /\ rloc[r] = o}
Attached(o, e) == o # 0 /\ rel[o].ex /\ rel[o].par = e /\ ~rel[o].pend
Pending(o) == o # 0 /\ rel[o].ex /\ rel[o].par # 0 /\ rel[o].pend
\* The relation the parent routes a write at position p to (epoch e), or 0.
RouteTo(p, e) ==
    LET S == {o \in Oids : Attached(o, e) /\ rel[o].slot = SlotOf(p)}
    IN IF S = {} THEN 0 ELSE CHOOSE o \in S : TRUE
\* A BEFORE trigger enabled ALWAYS fires for every session; one left origin-only
\* (ENABLE, the default) is skipped by a session_replication_role = replica writer.
Blocks(o, replica) == rel[o].trig = "always" \/ (rel[o].trig = "origin" /\ ~replica)

Env(g) == g \in EnvGroups /\ envLeft > 0
Spend == envLeft' = envLeft - 1

-----------------------------------------------------------------------------
(* Application writers (environment group "W").                           *)

\* INSERT through the parent, as an ordinary or a replica-role session.
AppInsert(r, p, replica) ==
    /\ Env("W") /\ rst[r] = "new"
    /\ LET o == RouteTo(p, repoch[r]) IN
         /\ o # 0 /\ ~Blocks(o, replica)
         /\ rloc' = [rloc EXCEPT ![r] = o]
         /\ rpos' = [rpos EXCEPT ![r] = p]
         /\ rst' = [rst EXCEPT ![r] = "live"]
    /\ Spend
    /\ UNCHANGED <<rel, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>

AppDelete(r) ==
    /\ Env("W") /\ rst[r] = "live"
    /\ Attached(rloc[r], repoch[r]) /\ ~Blocks(rloc[r], FALSE)
    /\ rst' = [rst EXCEPT ![r] = "gone"]
    /\ rloc' = [rloc EXCEPT ![r] = 0]
    /\ Spend
    /\ UNCHANGED <<rel, rpos, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>

-----------------------------------------------------------------------------
(* Operator hand actions (environment group "OD"): what the docs and the   *)
(* runbook allow or do not forbid.                                         *)

\* A hand detach makes the table the operator's, unless the protocol says the
\* relation stays its own (custody: a retirement pgpm dispatched): keep.
OpDetach(o, keep) ==   \* plain DETACH PARTITION, to keep the table
    /\ Env("OD") /\ Attached(o, 1)
    /\ rel' = [rel EXCEPT ![o].par = 0]
    /\ opOwned' = IF keep THEN opOwned ELSE opOwned \cup {o}
    /\ Spend
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, liveDet>>

OpDetachConc(o, keep) ==   \* DETACH ... CONCURRENTLY: first transaction committed, waiting
    /\ Env("OD") /\ Attached(o, 1)
    /\ rel' = [rel EXCEPT ![o].pend = TRUE]
    /\ opOwned' = IF keep THEN opOwned ELSE opOwned \cup {o}
    /\ liveDet' = liveDet \cup {o}
    /\ Spend
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2>>

\* The operator's live concurrent detach completes (it errors if finalized
\* under it). This is the second transaction of a statement the environment
\* already spent a step on (A10), so it spends none, whoever owns the table.
\* The caller excludes pgpm's own job's detach, which finishes in JobPhase2.
OpFinalize(o) ==
    /\ "OD" \in EnvGroups /\ o \in liveDet
    /\ rel' = IF Pending(o) THEN [rel EXCEPT ![o].par = 0, ![o].pend = FALSE] ELSE rel
    /\ liveDet' = liveDet \ {o}
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, envLeft>>

OpAttach(o, s) ==    \* ATTACH PARTITION back on a slot's bounds
    /\ Env("OD") /\ parentEx /\ rel[o].ex /\ rel[o].par = 0
    /\ ~\E q \in Oids : rel[q].ex /\ rel[q].par = 1 /\ rel[q].slot = s
    /\ \A r \in RowsOf(o) : SlotOf(rpos[r]) = s
    /\ rel' = [rel EXCEPT ![o].par = 1, ![o].slot = s]
    /\ opOwned' = opOwned \ {o}
    /\ Spend
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, liveDet>>

OpRename(o, nm) ==   \* group "RN": renames are their own group, so a config can leave them out
    /\ Env("RN") /\ rel[o].ex /\ Resolve(rel[o].nsp, nm) = 0
    /\ rel' = [rel EXCEPT ![o].name = nm]
    /\ Spend
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>

\* CREATE TABLE under a free name: a namesake once the name is free. It may
\* hold one row the operator puts in it (a different row than any partition's).
OpCreate(n, nm, r) ==
    /\ Env("OD") /\ Resolve(n, nm) = 0 /\ FreeOid # {}
    /\ LET o == CHOOSE q \in FreeOid : TRUE IN
         /\ rel' = [rel EXCEPT ![o] = [ex |-> TRUE, dead |-> FALSE, nsp |-> n, name |-> nm, par |-> 0,
                                       pend |-> FALSE, slot |-> 0, trig |-> "none"]]
         /\ opOwned' = opOwned \cup {o}
         /\ IF r = "none" THEN UNCHANGED <<rloc, rst, rpos, repoch>>
            ELSE /\ rst[r] = "new" /\ repoch[r] = 1
                 /\ rloc' = [rloc EXCEPT ![r] = o]
                 /\ rst' = [rst EXCEPT ![r] = "live"]
                 /\ UNCHANGED <<rpos, repoch>>
    /\ Spend
    /\ UNCHANGED <<parentNsp, parentEx, epoch2, liveDet>>

OpDropTable(o) ==    \* DROP TABLE by hand: the operator's own decision about its rows
    /\ Env("OD") /\ rel[o].ex
    /\ rel' = [rel EXCEPT ![o].ex = FALSE, ![o].dead = TRUE, ![o].par = 0, ![o].pend = FALSE]
    /\ rst' = [r \in Rows |-> IF rloc[r] = o /\ rst[r] = "live" THEN "gone" ELSE rst[r]]
    /\ rloc' = [r \in Rows |-> IF rloc[r] = o THEN 0 ELSE rloc[r]]
    /\ opOwned' = opOwned \ {o}
    /\ liveDet' = liveDet \ {o}
    /\ Spend
    /\ UNCHANGED <<rpos, repoch, parentNsp, parentEx, epoch2>>

OpDisableTrigger(o) ==   \* DROP TRIGGER / DISABLE TRIGGER by hand
    /\ Env("OD") /\ rel[o].ex /\ rel[o].trig # "off" /\ rel[o].trig # "none"
    /\ rel' = [rel EXCEPT ![o].trig = "off"]
    /\ Spend
    /\ UNCHANGED <<rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned, liveDet>>

ParentSetSchema(n) ==    \* ALTER TABLE parent SET SCHEMA n: moves the parent only
    /\ Env("OD") /\ parentEx /\ n # parentNsp
    /\ parentNsp' = n
    /\ Spend
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentEx, epoch2, opOwned, liveDet>>

-----------------------------------------------------------------------------
(* Crash or cancel (environment group "CR").                              *)

\* The session running a concurrent detach dies in its wait phase: the
\* partition stays pending, its rows invisible, until someone FINALIZEs it.
CrashDetacher(o) ==
    /\ Env("CR") /\ o \in liveDet
    /\ liveDet' = liveDet \ {o}
    /\ Spend
    /\ UNCHANGED <<rel, rloc, rpos, rst, repoch, parentNsp, parentEx, epoch2, opOwned>>

=============================================================================
