#!/usr/bin/env python3
"""Put a historical Tier 1/2 defect's mechanism back into the custody spec, and check TLC catches it.

This is the model's analogue of bench/mutations/ and ./test.sh discriminate (docs/pgpm-formal-methods-context-pack.md,
Phase 1: retrodiction). A spec that checks clean proves nothing on its own: it might be clean because the design is
right, or because the model cannot see the defect at all. So for every historical Tier 1/2 root cause on the
custody chain, a mutation here rewrites the guard its fix put in place (the lines tagged `@guard <id>` in
formal/specs/Custody.tla) back to the shape that shipped the defect, and the check requires TLC to report a
violation of the invariant that defect broke.

Two runs per mutation, and both must hold:
  CLEAN    the UNMUTATED spec under the mutation's config checks clean, every invariant. Otherwise a violation
           of the mutant proves nothing about the mutation: the config already fails without it.
  CAUGHT   the MUTANT under the same config, checking only the expected invariant (or property), is violated.

Each edit states how many sites it expects and REFUSES to build a mutant otherwise, as bench/mutations/mutate.py
does: a pattern that drifted out of date would silently produce a clean copy, which reads as "the model cannot
see this defect" when the truth is that the mutation never applied.

Where a later fix added a second guard over the same hole (defence in depth), the mutation that reintroduces the
one historical guard can come back clean: the other guard still holds. Those are listed with `composite`, the
design as it stood when the defect shipped, and `single` names the one-guard mutation, which is run too and
reported as MASKED or CAUGHT. Masking is itself a claim the model makes (that the second guard covers the first's
hole), worth a reproduction in Phase 2.

Usage: mutate.py --list
       mutate.py check [NAME ...] [--jobs N]     (all when no name; appends to formal/traces/mutations/results.tsv)
       mutate.py build NAME DIR                  (write the mutant spec and its config into DIR, for a hand run)
       mutate.py witness                         (every liveness witness must be reachable)
"""
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SPECS = os.path.join(HERE, '..', 'specs')
TLC = os.path.join(HERE, '..', 'tlc.sh')

ALL_GROUPS = ['W', 'OD', 'RN', 'CR', 'OC', 'SG', 'T', 'RG', 'PD', 'SB']


DEFAULT_HYP = ('H_C1', 'H_C2')


def cfg_text(groups, shapes, fk=False, budget=2, hyp=DEFAULT_HYP, check='NoLostRow', live=False):
    inv = '' if live else f'INVARIANTS\n  TypeOK\n  {check}\n'
    prop = f'PROPERTIES\n  {check}\n' if live else ''
    return (f"SPECIFICATION {'LiveSpec' if live else 'Spec'}\n"
            "CONSTANTS\n"
            "  Oids = {1, 2, 3, 4}\n"
            '  Rows = {"r1", "r2", "r3"}\n'
            '  Nsps = {"a", "b"}\n'
            '  Names = {"c1", "c2", "x"}\n'
            "  Zones <- MCZones\n"
            f"  EnvBudget = {budget}\n"
            "  EnvGroups = {" + ', '.join(f'"{g}"' for g in groups) + "}\n"
            "  Shapes = {" + ', '.join(f'"{s}"' for s in shapes) + "}\n"
            "  Hypotheses = {" + ', '.join(f'"{h}"' for h in hyp) + "}\n"
            f"  FKIn = {'TRUE' if fk else 'FALSE'}\n"
            + inv + prop)


ALL_INVARIANTS = ['NoLostRow', 'DropOnlyCovered', 'ArchiveNoClobber', 'ResolveByRecord', 'NoWedge']


def clean_cfg(c):
    """The same config with every invariant, for the CLEAN run (and the property, if the mutation checks one)."""
    t = re.sub(r'INVARIANTS\n(  .*\n)+', '', c)
    t = re.sub(r'PROPERTIES\n(  .*\n)+', '', t)
    prop = re.search(r'PROPERTIES\n  (\w+)', c)
    t += 'INVARIANTS\n  TypeOK\n' + ''.join(f'  {i}\n' for i in ALL_INVARIANTS)
    if prop:
        t += f'PROPERTIES\n  {prop.group(1)}\n'
    return t


# ---------------------------------------------------------------------------------------------------------------
# The guards, as they read in Custody.tla. Each constant is the exact text of one tagged definition.

G = {
    'G502': 'Key(lo) == lo  \\* @guard G502',
    'G727': 'OwnNsp(s) == IF part[s].oid # 0 /\\ rel[part[s].oid].ex THEN rel[part[s].oid].nsp ELSE parentNsp  \\* @guard G727',
    'G778': 'RecallNsp(s) == IF part[s].oid # 0 /\\ rel[part[s].oid].ex THEN rel[part[s].oid].nsp ELSE parentNsp  \\* @guard G778',
    'G1259': 'PgpmHolds(s, o) == part[s].ret /\\ part[s].disp = o /\\ o # 0  \\* @guard G1259',
    'G651': 'IsBlocked(o) == rel[o].trig = "always"  \\* @guard G651',
    'G500': 'PartHi(s, z) == ParseIn(part[s].hiB, 0)  \\* @guard G500',
    'G1336b8': 'ChunkHi(l, z) == IF led[l].hi.off THEN led[l].hi.w ELSE l  \\* @guard G1336b8',
    'G1336b8r': 'OffsetlessLive(s, o) == \\E l \\in LiveChunks(s, o) : ~led[l].hi.off  \\* @guard G1336b8',
    'G1363lo': 'RetLo(l) == IF led[l].lob.off THEN led[l].lob.w ELSE led[l].lob.w - MaxZ  \\* @guard G1363',
    'G1363hi': 'RetHi(l) == IF led[l].hi.off THEN led[l].hi.w ELSE led[l].hi.w - MinZ  \\* @guard G1363',
    'G1141b1': ('MarkGone(L) ==\n'
                '    [l \\in Pos |-> IF L[l].ex /\\ ~L[l].ret /\\ L[l].oid # 0 /\\ ~rel[L[l].oid].ex\n'
                '                   THEN [L[l] EXCEPT !.ret = TRUE] ELSE L[l]]  \\* @guard G1141b1'),
    'G454': 'ContractOK(lo, c, s) == lo < c /\\ c <= Hi(s)  \\* @guard G454',
    'G1030b3': 'ScriptContractOK(lo, c, s) == lo < c /\\ c <= Hi(s)  \\* @guard G1030b3',
    'G1069': 'RowsMatch(l, A) == led[l].dig = A  \\* @guard G1069',
    'G975': '                   => (l = lo /\\ ParseIn(led[l].hi, 0) = hi /\\ RowsMatch(l, A))  \\* @guard G975',
    'G501': 'StratShift(z) == 0  \\* @guard G501',
    'G977': 'Recorded(c, z) == Canon(c)  \\* @guard G977',
    'G788': 'ChunkStop(lo, z) == lo + 1  \\* @guard G788',
    'G564tick': "                 /\\ led' = ResetCoverage(s, o)  \\* @guard G564tick",
    'G452': '       ELSE IF LiveChunks(s, o) = {}  \\* @guard G452',
    'G1335b3': 'CandAtt(s, o) == Attached(o, 1)  \\* @guard G1335b3',
    'G1259step': 'StepReads(s, o) == Attached(o, 1)  \\* @guard G1259step',
    'G1335b10lock': 'RetireLockOK == Resolve(OwnNsp(rt.s), part[rt.s].name) = rt.o  \\* @guard G1335b10',
    'G1335b10drop': 'DropTarget(s, o) == o  \\* @guard G1335b10',
    'G1365': 'SlotHeldBy(s2) == Attached(part[s2].disp, 1) \\/ Pending(part[s2].disp)  \\* @guard G1365',
    'G1335b1': '    \\/ otherMark = "disp"  \\* @guard G1335b1',
    'G519': '         IF c # 0  \\* @guard G519',
    'G652': '       ELSE IF HandDetached(s, o)  \\* @guard G652',
    'G705': '       ELSE IF Pending(o) /\\ ~PgpmHolds(s, o)  \\* @guard G705',
    'G564': '       ELSE IF LiveChunks(s, o) # {} /\\ ~IsBlocked(o)  \\* @guard G564',
    'G1159': ('                 led[l].cnt = 0 /\\ \\E r \\in RowsOf(o) : rpos[r] >= l /\\ rpos[r] < ChunkHi(l, z)'
              '  \\* @guard G1159'),
    'G453': 'ReapLive(x) == x \\notin liveDet  \\* @guard G453',
    'G724': ('          /\\ IF jobRun # [n |-> rel[o].nsp, nm |-> rel[o].name] /\\ o \\notin liveDet'
             '  \\* @guard G724'),
    'G1159script': 'ScriptAtt(s, o) == Attached(o, 1)  \\* @guard G1159script',
    'G1054b2': 'ScriptLo(w, z) == Canon(w)  \\* @guard G1054b2',
    'G1160': 'AttributesChunk(o) == rel[o].trig \\in {"always", "origin", "none"}  \\* @guard G1160',
    'G511': 'SwapLedger(s, o) == ResetCoverage(s, o)  \\* @guard G511',
    'G893': 'ForgetIdlesJob == TRUE  \\* @guard G893',
    'G1260': 'ClaimHeld(k, sp) == k \\in claimed  \\* @guard G1260',
    'G822': '    /\\ IF ClaimHeld(k, sp)  \\* @guard G822',
    'G1259r4': 'ArcRecheck(o) == Attached(o, 1)  \\* @guard G1259r4',
    'GWitness': 'OrphanRows == {l \\in Pos : led[l].ex /\\ ~led[l].ret /\\ ~Spared(l)}  \\* @guard GWitness',
}


def e(gid, new):
    """Replace guard gid's text with new (the mutated shape), keeping the tag so the mutant reads as one."""
    old = G[gid]
    tag = old[old.rindex('\\* @guard'):] if '\\* @guard' in old else ''
    return (old, new + ('  ' + tag + ' MUTATED' if tag else ''))


# The mutated shapes, one per historical guard. Each is what the code did before the fix, at the model's level.
M = {
    'G452': e('G452', '       ELSE IF TRUE'),                          # lift the block whatever coverage says
    'G564tick': e('G564tick', "                 /\\ UNCHANGED led"),   # re-block without discarding coverage
    'G564': e('G564', '       ELSE IF FALSE'),                         # retire trusts coverage found under no block
    'G454': e('G454', 'ContractOK(lo, c, s) == TRUE'),
    'G1030b3': e('G1030b3', 'ScriptContractOK(lo, c, s) == TRUE'),
    'G453': e('G453', 'ReapLive(x) == TRUE'),
    'G511': e('G511', 'SwapLedger(s, o) == led'),
    'G519': e('G519', '         IF FALSE'),
    'G500': e('G500', 'PartHi(s, z) == ParseIn(part[s].hiB, z)'),
    'G501': e('G501', 'StratShift(z) == z'),
    'G502': e('G502', 'Key(lo) == lo % 2'),
    'G975': e('G975', '                   => TRUE'),
    'G651': e('G651', 'IsBlocked(o) == rel[o].trig \\in {"always", "origin"}'),
    'G652': e('G652', '       ELSE IF FALSE'),
    'G705': e('G705', '       ELSE IF FALSE'),
    'G724': e('G724', '          /\\ IF TRUE'),
    'G727': e('G727', 'OwnNsp(s) == parentNsp'),
    'G778': e('G778', 'RecallNsp(s) == parentNsp'),
    'G788': e('G788', 'ChunkStop(lo, z) == IF z # 0 THEN lo ELSE lo + 1'),
    'G822': e('G822', '    /\\ IF FALSE'),
    'G1260': e('G1260', 'ClaimHeld(k, sp) == k \\in claimed /\\ sp = "plain"'),
    'G893': e('G893', 'ForgetIdlesJob == FALSE'),
    'G977': e('G977', 'Recorded(c, z) == [w |-> c + z, off |-> FALSE, rz |-> z]'),
    'G1336b8': e('G1336b8', 'ChunkHi(l, z) == ParseIn(led[l].hi, z)'),
    'G1336b8r': e('G1336b8r', 'OffsetlessLive(s, o) == FALSE'),
    'G1069': e('G1069', 'RowsMatch(l, A) == Cardinality(led[l].dig) = Cardinality(A)'),
    'G1159': e('G1159', '                 FALSE'),
    'G1159script': e('G1159script', 'ScriptAtt(s, o) == TRUE'),
    'G1160': e('G1160', 'AttributesChunk(o) == rel[o].trig = "always"'),
    'G1259': e('G1259', 'PgpmHolds(s, o) == part[s].ret /\\ o # 0'),
    'G1259step': e('G1259step', 'StepReads(s, o) == Attached(o, 1) \\/ PgpmHolds(s, o)'),
    'G1335b3': e('G1335b3', 'CandAtt(s, o) == Attached(o, 1) \\/ PgpmHolds(s, o)'),
    'G1335b1': e('G1335b1', '    \\/ otherMark # "none"'),
    'G1335b10lock': e('G1335b10lock', 'RetireLockOK == TRUE'),
    # by name; when the name resolves to nothing the DROP errors and rolls back, which the model cannot
    # say inside DropTarget, so that case keeps o (the unmutated behaviour: it adds no violation)
    'G1335b10drop': e('G1335b10drop', 'DropTarget(s, o) == IF Resolve(OwnNsp(s), part[s].name) # 0 '
                                      'THEN Resolve(OwnNsp(s), part[s].name) ELSE o'),
    'G1363lo': e('G1363lo', 'RetLo(l) == ParseIn(led[l].lob, 0)'),
    'G1363hi': e('G1363hi', 'RetHi(l) == ParseIn(led[l].hi, 0)'),
    'G1365': e('G1365', 'SlotHeldBy(s2) == \\E q \\in Oids : Attached(q, 1) /\\ rel[q].name = part[s2].name'),
    'G1141b1': e('G1141b1', 'MarkGone(L) == L'),
    'G1259r4': e('G1259r4', 'ArcRecheck(o) == TRUE'),
    # not a pgpm defect: the model defect the witnesses exist for (every live chunk an orphan, so archiving
    # never completes a partition), which a witness check must notice
    'GWitness': e('GWitness', 'OrphanRows == {l \\in Pos : led[l].ex /\\ ~led[l].ret}'),
    'G1054b2': e('G1054b2', 'ScriptLo(w, z) == [w |-> w + z, off |-> FALSE, rz |-> z]'),
}

# ---------------------------------------------------------------------------------------------------------------
# The mutations. `rcs`: the root causes in the retrodiction set (docs/formal/tier12-catalogue.md, table A) this
# mechanism reintroduces. `inv`: the invariant the defect broke, in the model. `catalogue`: the invariant table A
# tags it with, when that differs (reported, not hidden). `guards`: the edits of the design as it stood when the
# defect shipped. `single`: the one guard the fix put in, when that differs from `guards` (run and reported too).

FRESH = ['fresh']
MUTATIONS = {
    'M452': dict(rcs=['#452'], inv='DropOnlyCovered', guards=['G452', 'G564tick', 'G564'], single=['G452'],
                 cfg=dict(groups=['W', 'T'], shapes=FRESH, budget=2),
                 note='coverage kept across a lifted block; a write lands; re-blocked, the stale coverage drops it'),
    # MISSED, and recorded so: #453's harm is DETACH CONCURRENTLY's skipped wait for old snapshots, which
    # the model has no snapshots to show (known gap K6; docs/formal/record.md)
    'M453': dict(rcs=['#453'], inv='NoLostRow', guards=['G453'], expect='MISSED',
                 cfg=dict(groups=['OD', 'RN', 'T'], shapes=FRESH, fk=True, budget=2),
                 note='_detach_reap finalizes a live concurrent detach'),
    'M454': dict(rcs=['#454'], inv='DropOnlyCovered', guards=['G454'],
                 cfg=dict(groups=['OC', 'T'], shapes=FRESH, budget=1),
                 note='covered_hi recorded unchecked: an overshoot opens the drop gate'),
    'M454w': dict(rcs=['#454'], inv='NoWedge', guards=['G454', 'G975'], single=['G454'], extra=True,
                  cfg=dict(groups=['OC', 'T'], shapes=FRESH, budget=1),
                  note='covered_hi = p_lo recorded: the (lo, lo) row collides every tick (P1C-04, same root cause); '
                       'as shipped, before #975 put the recorded-chunk check in the strategy, which today turns '
                       'the collision into a skip_archive every tick (a stall no ghost names: reported MASKED)'),
    'M511': dict(rcs=['#511'], inv='NoWedge', guards=['G511'],
                 cfg=dict(groups=['RG', 'T'], shapes=FRESH, budget=1),
                 note='a swap leaves the source\'s ledger rows; the copy\'s first chunk collides'),
    'M519': dict(rcs=['#519'], inv='NoWedge', guards=['G519'],
                 cfg=dict(groups=['RG', 'T'], shapes=FRESH, budget=1),
                 note='retire leaves an in-flight regrain\'s copy'),
    'M500': dict(rcs=['#500'], inv='NoLostRow', guards=['G500'],
                 cfg=dict(groups=['SG'], shapes=['opart'], budget=0),
                 note='a stored bound read in the caller\'s session: a live partition reads as aged'),
    'M501': dict(rcs=['#501'], inv='DropOnlyCovered', guards=['G501'],
                 cfg=dict(groups=['SG', 'T'], shapes=FRESH, budget=0),
                 note='the strategy reads its range in its session\'s zone and reports the asked range covered'),
    'M502': dict(rcs=['#502', '#823'], inv='ArchiveNoClobber', guards=['G502', 'G975'], single=['G502'],
                 cfg=dict(groups=['T'], shapes=FRESH, budget=0),
                 note='object keys not injective in lo (#502 the sign, #823 the era): one chunk\'s PUT replaces another\'s'),
    'M564': dict(rcs=['#564'], inv='DropOnlyCovered', guards=['G564'],
                 cfg=dict(groups=['OD', 'RN', 'W', 'T'], shapes=FRESH, budget=2),
                 note='block dropped by hand, a write, retire trusts the coverage'),
    'M651': dict(rcs=['#651'], inv='DropOnlyCovered', guards=['G651'],
                 cfg=dict(groups=['W'], shapes=['origin'], budget=1),
                 note='an origin-only block counts as a block; a replica writer passes it'),
    'M652': dict(rcs=['#652'], inv='NoLostRow', catalogue='ResolveByRecord', guards=['G652'],
                 cfg=dict(groups=['OD', 'RN', 'T'], shapes=FRESH, budget=1),
                 note='retire drops a partition the operator detached to keep'),
    'M705': dict(rcs=['B11-705'], inv='NoLostRow', guards=['G705'],
                 cfg=dict(groups=['OD', 'RN', 'T'], shapes=FRESH, budget=1),
                 note='a partition pending an operator\'s concurrent detach counts as attached'),
    'M724': dict(rcs=['#724'], inv='NoLostRow', guards=['G724'],
                 cfg=dict(groups=['T'], shapes=FRESH, fk=True, budget=1),
                 note='the recall clears the mark while a launched detach run is in flight'),
    'M727': dict(rcs=['#727'], inv='NoWedge', guards=['G727'],
                 cfg=dict(groups=['OD', 'RN', 'T'], shapes=FRESH, budget=1),
                 note='every step resolves a partition in the parent\'s schema'),
    'M778': dict(rcs=['#778'], inv='NoLostRowLive', live=True, guards=['G778'],
                 cfg=dict(groups=['OD', 'T'], shapes=FRESH, fk=True, budget=2),
                 note='the recall resolves in the parent\'s schema: a moved parent\'s retirement is never taken back. '
                      'No RN: a hand rename of a detached retired table also leaves it un-recalled for ever, and '
                      'the contract is silent on that (open question Q1 in docs/formal/record.md)'),
    'M788': dict(rcs=['#788'], inv='NoWedge', guards=['G788'],
                 cfg=dict(groups=['SG', 'T'], shapes=FRESH, budget=0),
                 note='the chunk stop round-trips through session text: no chunk, nothing logged'),
    'M822': dict(rcs=['#822'], inv='ArchiveNoClobber', guards=['G822'],
                 cfg=dict(groups=['PD', 'SB', 'T'], shapes=['pd'], budget=3),
                 note='a namesake table\'s writer PUTs to the dropped table\'s key unconditionally'),
    'M893': dict(rcs=['#893'], inv='NoLostRow', guards=['G893'],
                 cfg=dict(groups=['PD', 'T'], shapes=['pd'], fk=True, budget=2),
                 note='forget_missing leaves the detach job armed by name'),
    'M975': dict(rcs=['#975'], inv='ArchiveNoClobber', guards=['G975'],
                 cfg=dict(groups=['OC', 'T'], shapes=FRESH, budget=1),
                 note='a direct strategy call PUTs over a recorded chunk\'s key'),
    'M977': dict(rcs=['#977'], inv='DropOnlyCovered', guards=['G977', 'G1336b8', 'G1336b8r'], single=['G977'],
                 cfg=dict(groups=['SG', 'T'], shapes=FRESH, budget=0),
                 note='covered_hi recorded as written, offset-less, then read in another session\'s zone'),
    'M1069': dict(rcs=['#1069'], inv='ArchiveNoClobber', guards=['G1069'],
                  cfg=dict(groups=['OD', 'RN', 'OC', 'T'], shapes=FRESH, budget=3),
                  note='the recorded-chunk check compares a count, not the rows'),
    'M1159': dict(rcs=['#1159'], inv='DropOnlyCovered', guards=['G1159script', 'G1159'], single=['G1159script'],
                  cfg=dict(groups=['OD', 'RN', 'OC', 'T'], shapes=FRESH, budget=3),
                  note='the operator script archives a hand-detached partition through the parent: 0 rows, covered'),
    'M1160': dict(rcs=['#1160'], inv='NoWedge', guards=['G1160'],
                  cfg=dict(groups=[], shapes=['upg'], budget=0),
                  note='the upgrade marks a chunk under an origin-only block retired: its own partition held for good'),
    # G1259r4 too: the post-return re-check came in #1259's own fix (round 4), after the defect shipped
    'M1259': dict(rcs=['#1259'], inv='DropOnlyCovered', guards=['G1259', 'G1259step', 'G1335b3', 'G1159', 'G1259r4'],
                  single=['G1259'],
                  cfg=dict(groups=['OD', 'RN', 'T'], shapes=FRESH, fk=True, budget=2),
                  note='a mark without the dispatch record vouches for a hand-detached table'),
    'M1260': dict(rcs=['#1260'], inv='ArchiveNoClobber', guards=['G1260'],
                  cfg=dict(groups=['PD', 'SB', 'T'], shapes=['pd'], budget=3),
                  note='key claims compare spellings the store folds to one object'),
    'M1363': dict(rcs=['#1363'], inv='ArchiveNoClobber', guards=['G1363lo', 'G1363hi', 'G975'],
                  single=['G1363lo', 'G1363hi'],
                  cfg=dict(groups=['SG', 'T'], shapes=['oret'], budget=0),
                  note='a retired chunk\'s offset-less bounds read narrower than any session can have written them'),
    'M1365': dict(rcs=['#1365'], inv='NoWedge', guards=['G1365'],
                  cfg=dict(groups=['OD', 'RN', 'T'], shapes=FRESH, fk=True, budget=2),
                  note='the detach slot judged by relname: a namesake partition holds it'),
    'M1030b3': dict(rcs=['B9-1030b3'], inv='DropOnlyCovered', guards=['G1030b3'],
                    cfg=dict(groups=['OC', 'T'], shapes=FRESH, budget=1),
                    note='the operator script records covered_hi with no contract check'),
    # as shipped, without H_C2: its path is the tracked rename that makes the script's chunk an orphan, which
    # hypothesis H_C2 (claim C2) spares
    'M1054b2': dict(rcs=['B9-1054b2'], inv='NoWedge', guards=['G1054b2'],
                    cfg=dict(groups=['OC', 'OD', 'RN', 'SG', 'T'], shapes=FRESH, budget=2, hyp=('H_C1',)),
                    note='the operator script writes a session-rendered watermark as a ledger lo'),
    'M1141b1': dict(rcs=['B10-1141b1'], inv='ArchiveNoClobber', guards=['G1141b1'],
                    cfg=dict(groups=['OD', 'RN', 'T'], shapes=['ogone'], budget=1),
                    note='a coverage reset discards a gone relation\'s chunk instead of marking it retired'),
    'M1335b10': dict(rcs=['B12-1335b10'], inv='ResolveByRecord', guards=['G1335b10lock', 'G1335b10drop'],
                     cfg=dict(groups=['OD', 'RN', 'T'], shapes=FRESH, budget=2),
                     note='retire checks identity, then locks and drops by name: a rename plus a squatter'),
    'M1336b8': dict(rcs=['B12-1336b8'], inv='DropOnlyCovered', guards=['G1336b8', 'G1336b8r'],
                    cfg=dict(groups=['SG'], shapes=['olive'], budget=0),
                    note='an older install\'s offset-less live covered_hi read in the caller\'s zone'),
    'M1335b1': dict(rcs=['B12-1335b1'], inv='NoWedge', guards=['G1335b1'],
                    cfg=dict(groups=[], shapes=['other'], fk=True, budget=0),
                    note='a mark with no dispatch record holds the database-wide detach slot'),
    # #1335 b3 was found inside #1259's own fix, so G1259step was already in place: the single guard is the
    # design as shipped (a composite that also undid G1259step hands the step the table and wastes nothing)
    # Not in the 37: a finding of round 4 of #1259's per-PR verification (the catalogue's second, per-PR set),
    # the re-check after the strategy returns, which the fidelity read (H1) found the spec could not see.
    'M1259r4': dict(rcs=['PR1259-r4'], inv='DropOnlyCovered', guards=['G1259r4'], extra=True,
                    cfg=dict(groups=['W', 'OD', 'T'], shapes=FRESH, budget=3),
                    note='a concurrent detach overtakes the strategy\'s read; a short chunk (a second row written '
                         'into it, so the zero-row check of #1159 does not see it) is recorded; attached back, '
                         'retention drops the table'),
    'M1335b3': dict(rcs=['B12-1335b3'], inv='NoWedge', guards=['G1335b3'],
                    cfg=dict(groups=['OC', 'T'], shapes=FRESH, fk=True, budget=1),
                    note='a detached retirement of pgpm\'s own takes archive_batch 1\'s only turn'),
}

# Root causes of the retrodiction set the model does not try, with the reason. They count against recall.
NOT_MODELLED = {
    'B9-1062b2': 'archive._resolve_child, the synchronous export path (archive.to_s3): out of Phase 1 scope like '
                 'the other synchronous exports; filed under custody in table A',
    'B9-1064': 'archive._owned_key resolving an export\'s relation by name: the synchronous export path, as above',
}


def build(name, guards, dst):
    os.makedirs(dst, exist_ok=True)
    for f in ('Base.tla', 'Custody.tla'):
        shutil.copy(os.path.join(SPECS, f), dst)
    p = os.path.join(dst, 'Custody.tla')
    s = open(p).read()
    for gid in guards:
        old, new = M[gid]
        n = s.count(old)
        if n != 1:
            raise SystemExit(f'{name}: guard {gid} matched {n} sites, expected 1; refusing to build a stale mutant')
        s = s.replace(old, new)
    open(p, 'w').write(s)


def run_tlc(d, cfg, timeout=1800):
    open(os.path.join(d, 'M.cfg'), 'w').write(cfg)
    env = dict(os.environ)
    env.setdefault('FORMAL_WORKERS', '4')
    for attempt in (1, 2):
        try:
            out = subprocess.run([TLC, d, 'Custody.tla', 'M.cfg'], capture_output=True, text=True, env=env,
                                 timeout=timeout).stdout
        except subprocess.TimeoutExpired:
            return 'TIMEOUT', ''
        # SANY has been seen to die with a NullPointerException in its module lookup when several TLC
        # runs start at once (2026-10-29, M511's clean run). That is the parser failing, not the model
        # answering, so it is retried once, said aloud, and never anything else is.
        if attempt == 1 and 'Module-Table lookup failure' in out:
            print(f'  (parser crash in {d}, retrying once)', file=sys.stderr, flush=True)
            continue
        break
    m = re.search(r'Invariant (\w+) is violated', out)
    if m:
        return 'violated:' + m.group(1), out
    if 'Temporal properties were violated' in out:
        return 'violated:property', out
    if 'No error has been found' in out:
        return 'clean', out
    return 'error', out


def check_one(name):
    m = MUTATIONS[name]
    c = m['cfg']
    hyp = c.get('hyp', DEFAULT_HYP)
    cfg = cfg_text(c['groups'], c['shapes'], fk=c.get('fk', False), budget=c.get('budget', 2),
                   check=m['inv'], live=m.get('live', False), hyp=hyp)
    want = 'violated:property' if m.get('live') else f"violated:{m['inv']}"
    res = {'name': name}
    with tempfile.TemporaryDirectory() as t:
        d0 = os.path.join(t, 'clean')
        build(name, [], d0)
        # Without one of the claims' hypotheses, that claim's own invariant fails on the unmutated spec by design,
        # so the CLEAN run then holds the unmutated spec to the invariant the mutation is judged by, alone.
        res['clean'], out0 = run_tlc(d0, clean_cfg(cfg) if set(hyp) >= set(DEFAULT_HYP) else cfg)
        d1 = os.path.join(t, 'mutant')
        build(name, m['guards'], d1)
        res['mutant'], out1 = run_tlc(d1, cfg)
        res['caught'] = res['clean'] == 'clean' and res['mutant'] == want
        res['trace'] = out1 if res['mutant'].startswith('violated') else ''
        if 'single' in m:
            d2 = os.path.join(t, 'single')
            build(name, m['single'], d2)
            res['single'], _ = run_tlc(d2, cfg)
        if res['clean'] != 'clean':
            res['clean_trace'] = out0
    return res


# Liveness witnesses (Custody.tla): each must be VIOLATED, or the model's archive, drop, dispatch, overtaken read or
# custody is unreachable and every clean invariant over it vacuous. A witness of pgpm's own progress runs with the
# environment cut to writes and time ("W", "T") on a fresh install, so the operator script cannot do the step's
# work for it and no older-install shape starts past it; the rest
# run under the default config's constants as they stand.
PGPM_ONLY = ['W', 'T']
WITNESSES = [('WitTwoChunks', 'Custody.cfg', PGPM_ONLY), ('WitArchivedDrop', 'Custody.cfg', PGPM_ONLY),
             ('WitArchivedDrop', 'CustodyFK.cfg', PGPM_ONLY), ('WitDetachDispatched', 'CustodyFK.cfg', None),
             ('WitStrategyOvertaken', 'CustodyFK.cfg', None), ('WitCustody', 'CustodyFK.cfg', None)]


def witness_cfg(w, base, groups):
    c = open(os.path.join(SPECS, base)).read()
    c = re.sub(r'INVARIANTS\n(  .*\n)+', '', c) + f'INVARIANTS\n  {w}\n'
    if groups is not None:
        c = re.sub(r'EnvGroups = \{[^}]*\}', 'EnvGroups = {' + ', '.join(f'"{g}"' for g in groups) + '}', c)
        # and a fresh install: two older-install shapes start with a dropped relation's rows already archived
        c = re.sub(r'Shapes = \{[^}]*\}', 'Shapes = {"fresh"}', c)
    return c


def witness():
    bad = 0
    for w, base, groups in WITNESSES:
        with tempfile.TemporaryDirectory() as t:
            build('witness', [], t)
            res, _ = run_tlc(t, witness_cfg(w, base, groups))
        ok = res == f'violated:{w}'
        bad += not ok
        scope = base + (' (' + '+'.join(groups) + ')' if groups else '')
        print(f"{w}\t{scope}\t{res}\t{'ok' if ok else 'UNREACHABLE: every invariant over it is vacuous'}",
              flush=True)
    # the witness check discriminates: with the archive dead, pgpm's own progress witnesses must be unreachable
    for w, base, groups in WITNESSES[:3]:
        with tempfile.TemporaryDirectory() as t:
            build('witness-discriminate', ['GWitness'], t)
            res, _ = run_tlc(t, witness_cfg(w, base, groups))
        ok = res == 'clean'
        bad += not ok
        print(f"{w}\t{base} dead archive (GWitness)\t{res}\t{'ok' if ok else 'DOES NOT DISCRIMINATE'}", flush=True)
    if bad:
        sys.exit(1)


def main():
    args = sys.argv[1:]
    if not args or args[0] == '--list':
        for k, m in MUTATIONS.items():
            print(f"{k}\t{','.join(m['rcs'])}\t{m['inv']}\t{'+'.join(m['guards'])}\t{m['note']}")
        for k, why in NOT_MODELLED.items():
            print(f'-\t{k}\tnot modelled\t-\t{why}')
        return
    if args[0] == 'witness':
        witness()
        return
    if args[0] == 'build':
        build(args[1], MUTATIONS[args[1]]['guards'], args[2])
        m = MUTATIONS[args[1]]
        c = m['cfg']
        open(os.path.join(args[2], 'M.cfg'), 'w').write(
            cfg_text(c['groups'], c['shapes'], fk=c.get('fk', False), budget=c.get('budget', 2), check=m['inv'],
                     live=m.get('live', False), hyp=c.get('hyp', DEFAULT_HYP)))
        return
    jobs = 4
    if '--jobs' in args:
        i = args.index('--jobs'); jobs = int(args[i + 1]); del args[i:i + 2]
    names = args[1:] or list(MUTATIONS)
    tracedir = os.path.join(HERE, '..', 'traces', 'mutations')
    os.makedirs(tracedir, exist_ok=True)
    rows = []
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for r in ex.map(check_one, names):
            m = MUTATIONS[r['name']]
            # MISSED and MASKED mean TLC finished and found nothing. A run that timed out, errored or violated some
            # other invariant answers nothing, so it is never read as a miss or a mask: it is BROKEN and fails the
            # track, whatever the mutation expects. Otherwise a broken mutant would stand in for the evidence that
            # the model genuinely misses a defect (M453).
            want = 'violated:property' if m.get('live') else f"violated:{m['inv']}"
            if r['clean'] != 'clean':
                verdict = 'CONFIG-NOT-CLEAN'
            elif r['caught']:
                verdict = 'CAUGHT'
            elif r['mutant'] == 'clean':
                verdict = 'MISSED'
            else:
                verdict = f"BROKEN({r['mutant']})"
            single = r.get('single', '')
            if single:
                single = ('CAUGHT' if single == want else 'MASKED(clean)' if single == 'clean'
                          else f'BROKEN({single})')
            expect = m.get('expect', 'CAUGHT')
            ok = ('ok' if verdict == expect and not single.startswith('BROKEN')
                  else f'UNEXPECTED(want {expect})')
            line = '\t'.join([r['name'], ','.join(m['rcs']), m['inv'], m.get('catalogue', ''), verdict,
                              r['clean'], r['mutant'], single, ok])
            print(line, flush=True)
            rows.append(line)
            for k in ('trace', 'clean_trace'):
                if r.get(k):
                    open(os.path.join(tracedir, f"{r['name']}.{k}.txt"), 'w').write(r[k])
    with open(os.path.join(tracedir, 'results.tsv'), 'a') as f:
        for line in rows:
            f.write(line + '\n')
    if any(not l.endswith('\tok') for l in rows):
        sys.exit(1)


if __name__ == '__main__':
    main()
