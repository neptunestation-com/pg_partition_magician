#!/usr/bin/env python3
"""Reintroduce a known defect into pgpm_core/install.sql, so a guard can be shown to catch it.

A guard that passes proves nothing on its own: it might pass because the defect is gone, or because it
never observed anything. This repo has produced the second kind six times, so every guard under
bench/ has a mutation here that puts its defect back, and bench/discriminate.sh asserts the guard FAILS
against it. A guard that stays green on its own mutant is not a guard.

Each mutation states the exact number of sites it expects to change and REFUSES to write a mutant if
the count is off. That matters more than it looks: a mutation whose pattern has drifted out of date
would silently produce a clean copy of install.sql, the guard would pass against it, and
discriminate.sh would report "does not discriminate" for a guard that is in fact fine. Failing loudly
on a stale pattern is the same liveness-witness discipline the guards themselves follow.

Usage: mutate.py <name> <src install.sql> <dst path>
       mutate.py --list [--track=NAME]     (heaviest first: MUTATION_COST, so --shard=I/N balances)
"""
import re
import sys

# Each boundary is a BOUNDARY comment block, a `commit;`, and (usually) the set_config that re-applies
# lock_timeout, since `set local` does not survive a COMMIT. Matching the whole block keeps the mutant
# readable rather than leaving orphaned comments explaining a commit that is no longer there.
BOUNDARY_RE = re.compile(
    r"^  -- BOUNDARY \(#(?:279|265)\).*?\n  commit;\n(?:  perform set_config\('lock_timeout'.*?\n)?",
    re.MULTILINE | re.DOTALL,
)

# _create_partition's two boundaries. Removing them collapses the three phases back into one
# transaction, which is the pre-#280 shape exactly.


# Put the inline VALIDATE back where #265 removed it. Anchored on the comment block that replaced it, so
# a stale pattern fails loudly rather than yielding an unmutated copy.
RESTORE_MARKER = "    -- The VALIDATE deliberately does NOT happen here (#265)."
# untransmute's operator notice, which took the place of its inline VALIDATE (#577). The mutation that
# puts the VALIDATE back replaces exactly these two lines.
UNTRANSMUTE_FK_NOTICE = (
    "      raise notice 'pg_partition_magician: untransmute re-added % on % NOT VALID; validate it outside "
    "this transaction with: ALTER TABLE % VALIDATE CONSTRAINT %',\n"
    "        quote_ident(r.constraint_name), r.referencing_table::text, r.referencing_table::text, "
    "quote_ident(r.constraint_name);\n"
)
# retire()'s identity check, whole (#407 widened by #428). Shared by three mutations that each take a
# different bite out of it, so the exact text lives in one place: a block this long, duplicated, is a
# block that drifts in one copy and silently stops matching in the other -- and a mutation that
# stops matching is one mutate.py refuses to build, which reads as a broken guard rather than a
# stale pattern until someone goes and looks.
RETIRE_IDENTITY_BLOCK = """  if r.retiring_oid is not null or r.child_oid is not null then
    v_now := to_regclass(format('%I.%I', v_nsp, p_child));
    v_why := concat_ws(' and ',
      case when r.retiring_oid is not null and v_now::oid is distinct from r.retiring_oid
           then format('not the oid %s this retirement dispatched a detach for', r.retiring_oid) end,
      case when r.child_oid is not null and v_now::oid is distinct from r.child_oid
           then format('not the oid %s recorded for this partition when it was created', r.child_oid) end);
    if v_why <> '' then
      if r.retiring_oid is not null then
        perform pgpm._idle_detach_job(pgpm._detach_cmd(p_parent, v_nsp, p_child));
      end if;
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_retain_identity', r.lo, r.hi,
                format('%I.%I is oid %s now, %s; refusing to detach or drop it',
                       v_nsp, p_child, coalesce(v_now::oid::text, 'nothing'), v_why));
      return false;
    end if;
  end if;
"""

# The upgrade backfill of regrain's capture anchors (#496, reshaped by #655 and #969), whole. Shared by the
# mutation that deletes it and the ones that loosen it, for the reason RETIRE_IDENTITY_BLOCK is a constant.
# Its two gates are constants too: the plain-table check (#655) and the proof that pgpm minted the pair (#969).
REGRAIN_CAPTURE_BACKFILL_PLAIN = """    if v_delta is null
       or not exists (select 1 from pg_class c where c.oid = v_delta and c.relkind = 'r' and not c.relispartition)
    then continue; end if;
"""
REGRAIN_CAPTURE_BACKFILL_PROOF = """    if v_fn is null   -- #969: the proof that pgpm minted the pair
       or not exists (select 1 from pg_proc p
                       where p.oid = v_fn and p.prorettype = 'trigger'::regtype
                         and strpos(p.prosrc, format('insert into %I.%I (', v_nsp, left(v_rel || '_pgpm_regrain_delta', 63)::name)) > 0)
       or not exists (select 1 from pg_attribute a
                       where a.attrelid = v_delta and a.attname = 'pgpm_seq' and a.attidentity = 'a' and not a.attisdropped)
    then continue; end if;
"""
REGRAIN_CAPTURE_BACKFILL_BLOCK = """do $$
declare r record; v_nsp name; v_rel name; v_delta regclass; v_fn regprocedure;
begin
  for r in select parent_table from pgpm.config where regrain_delta_oid is null loop
    select n.nspname, c.relname into v_nsp, v_rel
      from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = r.parent_table;
    if v_nsp is null then continue; end if;
    v_delta := to_regclass(format('%I.%I', v_nsp, left(v_rel || '_pgpm_regrain_delta', 63)::name));
""" + REGRAIN_CAPTURE_BACKFILL_PLAIN + """    v_fn := to_regprocedure(format('%I.%I()', v_nsp, left(v_rel || '_pgpm_regrain_capture', 63)::name));
""" + REGRAIN_CAPTURE_BACKFILL_PROOF + """    update pgpm.config
       set regrain_delta_oid      = v_delta::oid,
           regrain_capture_fn_oid = v_fn::oid
     where parent_table = r.parent_table;
  end loop;
end $$;
"""

# _from_hypertable_carried_ddl's ways of knowing the module's own capture trigger, which the swap must not
# replay: pgpm.scratch's record (#969), a 0.6.0 capture (no record, no comment) by proof (#969), and the
# delta's horizon comment (#842). Constants because five mutations cut them. The proof reads <x> off the
# function (#988) and is asked only of a capture that carries neither record, so the three stay disjoint.
HT_CAPTURE_ARM_RECORD = """       and not exists (select 1 from pgpm.scratch s   -- #969: by the record, never by the function's name
                        where s.parent_oid = p_hypertable::oid and s.kind = 'hypertable_delta_fn' and s.obj = t.tgfoid)
"""
HT_CAPTURE_ARM_PROOF = """       and not (right(f.proname, 14) = '_pgpm_delta_fn' and f.pronargs = 0   -- #969: 0.6.0's, on proof
                and strpos(f.prosrc, format('insert into %I.%I (', fn.nspname, left(f.proname, -3))) > 0   -- #988: its own name
                and not exists (select 1 from pgpm.scratch s   -- and asked only of a capture with neither record
                                 where s.parent_oid = p_hypertable::oid and s.kind = 'hypertable_delta_fn' and s.obj = t.tgfoid)
                and not exists (select 1 from pg_class d
                                  join pg_description dd on dd.objoid = d.oid and dd.classoid = 'pg_class'::regclass
                                                        and dd.objsubid = 0
                                 where d.relnamespace = f.pronamespace and d.relname = left(f.proname, -3)
                                   and d.relkind = 'r' and dd.description ~ '^pgpm from_hypertable horizon [0-9]+$'))
"""
HT_CAPTURE_ARM_COMMENT = """       and not exists (select 1 from pg_class d
                         join pg_description dd on dd.objoid = d.oid and dd.classoid = 'pg_class'::regclass
                                               and dd.objsubid = 0
                        where right(f.proname, 14) = '_pgpm_delta_fn' and f.pronargs = 0
                          and d.relnamespace = f.pronamespace and d.relname = left(f.proname, -3)
                          and d.relkind = 'r' and dd.description ~ '^pgpm from_hypertable horizon [0-9]+$')
"""

# _install_write_block's identity check (#429), and the whole of _remove_write_block, which is
# deliberately NOT anchored. Both live here as constants for the same reason the retire block does.
WRITE_BLOCK_IDENTITY_BLOCK = """  select p.lo, p.hi, p.child_oid into r
    from pgpm.part p where p.parent_table = p_parent and p.child_name = p_child;
  if found and r.child_oid is not null then
    v_now := to_regclass(format('%I.%I', v_nsp, p_child));
    if v_now is not null and v_now::oid <> r.child_oid then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_write_block_identity', r.lo, r.hi,
                format('%I.%I is oid %s now, not the oid %s recorded for this partition when it was created; refusing to write-block it',
                       v_nsp, p_child, v_now::oid::text, r.child_oid));
      return;
    end if;
  end if;

"""

REMOVE_WRITE_BLOCK_FN = """create or replace function pgpm._remove_write_block(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare v_nsp name;
begin
  v_nsp := pgpm._child_nsp(p_parent, p_child);   -- #727: the partition's own schema, not the parent's
  execute format('drop trigger if exists pgpm_write_block on %I.%I', v_nsp, p_child);
end;
$$;
"""

# from_hypertable_cutover's two lock-then-verify halves (#422), each mutated separately so a guard
# failure names which one went missing.
HT_CUTOVER_SOURCE_VERIFY = """  execute format('lock table %s in access exclusive mode', p_hypertable::text);
  if to_regclass(format('%I.%I', v_nsp, v_rel)) is distinct from p_hypertable then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) resolved % .% at the start, but that name is oid % now -- something renamed or replaced the source while the cutover was preparing; refusing to drop a relation it did not identify. Re-run the cutover once the name is settled.',
      p_hypertable, quote_ident(v_nsp), quote_ident(v_rel),
      coalesce(to_regclass(format('%I.%I', v_nsp, v_rel))::oid::text, 'nothing');
  end if;

"""

HT_CUTOVER_DEST_VERIFY = """  execute format('lock table %s in access exclusive mode', v_dest_oid::text);
  if to_regclass(format('%I.%I', v_nsp, v_dest)) is distinct from v_dest_oid then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) found destination % .% as oid % at the start, but that name is oid % now -- something replaced the copy while the cutover was preparing; refusing to rename an unverified relation into %.',
      p_hypertable, quote_ident(v_nsp), quote_ident(v_dest), v_dest_oid::oid,
      coalesce(to_regclass(format('%I.%I', v_nsp, v_dest))::oid::text, 'nothing'), quote_ident(v_rel);
  end if;
"""
# The cutover's conservation check (#460, #653): the source's count and content fingerprint under the lock
# compared with the destination's carried-in count and fingerprint, and the refusal. Deleting it is the
# pre-#460 cutover exactly: the catch-up runs, nothing compares the two sides, and the DROP goes ahead on a
# destination that is short. The reads themselves are left in place: since #654 the tracking path takes
# the count in the same per-relation scan as the untracked-write check, and both paths read the fingerprint
# before this block, so the comparison is the part that is the conservation check.
HT_CUTOVER_CONSERVATION = """  if v_src_n <> v_dest_n or v_src_h <> v_dest_h then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) refusing to swap: %. %',
      p_hypertable,
      case when v_src_n <> v_dest_n
        then format('the source holds %s rows but the destination would hold %s after the %s catch-up, a difference of %s',
                    v_src_n, v_dest_n, case when v_track then 'change-tracking' else 'append-only' end,
                    abs(v_src_n - v_dest_n))
        else format('the source and the destination would both hold %s rows after the %s catch-up, but not the same rows (their content fingerprints over every column differ)',
                    v_src_n, case when v_track then 'change-tracking' else 'append-only' end)
      end,
      case when v_track
        then 'A write reached the source without firing the change-capture trigger (session_replication_role = replica, or the trigger disabled), so the delta never saw it. Nothing was dropped and the source is whole. Make every writer fire triggers, then re-run from_hypertable_copy with p_track_changes => true.'
        else format('Rows arrived during the online window with a control value at or below the copy watermark (out-of-order appends, a backfill, or an update or delete of a copied row), which the append-only catch-up cannot see. Nothing was dropped and the source is whole. Re-run from_hypertable_copy(%L, %L, p_track_changes => true), which needs a primary key or unique constraint; on a keyless table, pause writes to the source for the copy instead.',
                    p_hypertable::text, p_control)
      end;
  end if;
"""
# The cutover's untracked-write refusal (#654), by its condition alone, and the fallback that verifies
# every row when the copy recorded no horizon, by its assignment alone.
HT_CUTOVER_UNTRACKED_REFUSAL = "  if v_unmatched > 0 then\n"
# The same refusal whole, with the comment that says why it comes first: pass 5 seed S9 moves it after the
# conservation check, so a write the trigger never saw is reported as a count or fingerprint mismatch.
HT_CUTOVER_UNTRACKED_BLOCK = """  -- Two refusals guard the swap, the specific one first. A row the capture trigger never saw (#654) is named by
  -- its key below; the count-and-fingerprint comparison after it (#460, #653) catches everything else, so a
  -- write that bypassed the trigger is reported as what it is rather than as a fingerprint mismatch.
  if v_unmatched > 0 then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) refusing to swap: % source row(s) changed during the online window without firing the change-capture trigger, and the destination does not hold them as the source does (first key %). A write reached the source under session_replication_role = replica (a logical-replication apply worker, a loader silencing triggers) or with the trigger gone, and TimescaleDB cannot enable the trigger ALWAYS on a hypertable, so the delta never saw it. Nothing was dropped and the source is whole. Make every writer fire triggers for the whole window (pause the subscription, or run the loader as origin), then re-run from_hypertable_copy with p_track_changes => true.',
      p_hypertable, v_unmatched, v_first_key;
  end if;
"""
HT_CUTOVER_NO_HORIZON_FALLBACK = "      v_fresh := 'true';\n"
# The under-lock append-only catch-up's keyed branch, by its condition and the comment that opens it: the
# pre-lock key-column build tests the same condition at the same indentation (since #736 took away the
# `if v_watermark is not null` both used to differ by), and the count check below refuses to build the
# mutant if the pair ever stops being unique.
HT_CATCHUP_KEYED_BRANCH = "    if v_akey is not null then\n      -- Materialise the tail first"

# from_hypertable_cutover's two in-swap records (#563): the incoming keys it drops, and the source
# sequence's position on the re-added identity. Each is deleted alone, so a guard failure names which.
HT_SWAP_FK_RECORD = """    insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition)
      values (v_dest_oid, k.referencing, k.conname, k.def);
    insert into pgpm.log (parent_table, action, method) values (v_dest_oid, 'drop_incoming_fk', k.conname);
"""
HT_SWAP_IDENTITY_POSITION = """      if v_ident_next[v_i] is not null then
        perform pgpm._identity_reseed(
          pg_get_serial_sequence(format('%I.%I', v_nsp, v_rel), v_ident_cols[v_i]::text)::regclass,
          v_ident_next[v_i], null, null);
      end if;
    end loop;
  end if;
"""
# The swap's identity re-add, kind and options (#640). The mutation that puts the pre-#640 re-add back
# replaces exactly these two argument lines.
HT_SWAP_IDENTITY_KIND_OPTS = """                     case when v_ident_kinds[v_i] = 'a' then 'always' else 'by default' end,
                     coalesce(v_ident_opts[v_i], ''));
"""
# The cutover's two shape checks (#738), each anchored on the comment that introduces it so the two
# mutations cannot remove the wrong one.
HT_SHAPE_UP_FRONT = """  -- before the pre-drain and the index pre-builds spend anything. Asked again under the lock below.
  perform pgpm._from_hypertable_check_shape(p_hypertable, v_dest_oid);
"""
HT_SHAPE_UNDER_LOCK = """  -- in between. Both relations are frozen now, and the column list read at the top must still describe both.
  perform pgpm._from_hypertable_check_shape(p_hypertable, v_dest_oid);
"""
# The cutover's exclusion check under its lock (#841), anchored on its own comment.
HT_EXCLUSION_UNDER_LOCK = """  -- ...and an EXCLUDE constraint, for the same reason (#841). The check up front saw none, but one added while
  -- the cutover prepared is on the frozen source now, and the swap below would drop it with the hypertable.
  perform pgpm._from_hypertable_check_exclusion(p_hypertable);
"""
# The swap letting go of the sequences the source owns, before its DROP (#839).
HT_SERIAL_LET_GO = """    execute format('alter sequence %s owned by none', k.seq::text);
"""
# The shape diff's three outgoing-foreign-key arms (#840).
HT_SHAPE_FK_ARMS = """    union all
    select 4, fs.name, format('FOREIGN KEY %I (%s) is on the source but not on the copy', fs.name, fs.def)
      from fk fs where fs.rel = p_src
       and not exists (select 1 from fk fd where fd.rel = p_dest and fd.name = fs.name)
    union all
    select 4, fd.name, format('FOREIGN KEY %I is on the copy but no longer on the source', fd.name)
      from fk fd where fd.rel = p_dest
       and not exists (select 1 from fk fs where fs.rel = p_src and fs.name = fd.name)
    union all
    select 4, fs.name, format('FOREIGN KEY %I is %s on the source but %s on the copy', fs.name, fs.def, fd.def)
      from fk fs join fk fd on fd.name = fs.name and fd.rel = p_dest
     where fs.rel = p_src and fs.def <> fd.def
"""
# transmute's carry of the records that name the table it converts as the REFERENCED side (#563).
TRANSMUTE_DROPPED_FK_PARENT_CARRY = """  update pgpm.dropped_fk set parent_table = v_parent where parent_table = p_parent;
"""

RESTORE_INLINE = """    if v_readded and not v_is_part then
      begin
        execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
        update pgpm.dropped_fk set validated_at = now() where id = r.id;
      exception when others then null;
      end;
    end if;
    -- The VALIDATE deliberately does NOT happen here (#265)."""

# regrain_step's swap-time residual reconcile (#447): the loop as fixed, the pre-#447 bounded form, and
# the pre-drop check that follows the loop. Constants because two mutations share the loop swap and only
# one of them removes the check; the difference between them is the point.
REGRAIN_SWAP_DRAIN_LOOP = """  loop
    exit when pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_hi, greatest(v_batch, 1000)) = 0;
  end loop;
"""

REGRAIN_SWAP_DRAIN_LOOP_BOUNDED = """  for v_i in 1 .. 100 loop
    exit when pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_hi, greatest(v_batch, 1000)) = 0;
  end loop;
"""

REGRAIN_SWAP_PENDING_CHECK = """  v_delta_n := pgpm._regrain_delta_count(p_parent, v_lo, v_hi);
  if v_delta_n > 0 then
    raise exception 'pg_partition_magician: internal error regraining % -- % captured change(s) in [%, %) are still pending after the swap''s residual reconcile; refusing to drop the source with changes unapplied. The swap rolls back whole: the source stays attached and the next tick reconciles the backlog before swapping.',
      v_child_name, v_delta_n, v_lo, v_hi;
  end if;
"""
# untransmute's lock-and-recheck (#443), matched from its marker comment through the end of its `if`,
# so the mutant reads as the pre-#443 function rather than as a comment describing a lock that is not
# there. Anchored on the marker rather than the code so a rewording of the explanation fails loudly
# here instead of quietly leaving the lock in place.
UNTRANSMUTE_RECHECK_RE = re.compile(
    r"^  -- THE GATE, AGAIN, UNDER THE LOCK \(#443\)\..*?\n  end if;\n\n",
    re.MULTILINE | re.DOTALL,
)

# #668's time-kind frontier block, matched from its marker comment through the frontier assignment, so the
# mutant is the pre-#668 `v_frontier_native := now()` with no max(control) read at all.
TIME_FRONTIER_BLOCK_RE = re.compile(
    r"^    -- #668: the data maximum counts for `time` too\..*?"
    r"^    v_frontier_native := pgpm\._ts_text\(greatest\(v_max_ts, now\(\)\)\);\n",
    re.MULTILINE | re.DOTALL,
)

# name -> (guard it must break, why this is the right defect, [(find, replace, expected_count)])
# #344's hoist: the new parent's CREATE TABLE ... PARTITION BY RANGE, identity, owner, RLS and
# policies, moved to run BEFORE either rename so none of it adds to the outage. (The comments were in it
# too until #630 moved them under the cutover's ACCESS EXCLUSIVE, beside the triggers, and the grants
# until #706 moved them after the attach, which is what serialises a GRANT or REVOKE against the cutover.)
# #766's second asking of the #730 refusals, under an explicit ACCESS SHARE, opens it and moves with it.
TRANSMUTE_CUTOVER_HOIST = """  -- #344: everything below that only touches the NEW parent -- not the original/monolith relation -- runs
  -- BEFORE either rename, under a staging name (v_staging, collision-checked earlier alongside the
  -- orphan-name guard). None of it needs the original table's lock: CREATE TABLE ... LIKE only takes
  -- ACCESS SHARE on p_parent (a rename changes no column/default/constraint, so building it from p_parent
  -- now is byte-for-byte the same as building it from the monolith name later), and everything after that
  -- targets the not-yet-visible staging relation. This is what shrinks the outage: previously all of it
  -- ran AFTER the rename, adding directly to how long the live table was unavailable.

  -- 5a (#766). The shapes the LIKE below cannot carry, asked again under the ACCESS SHARE the LIKE would
  -- take anyway, taken explicitly one statement earlier so that nothing can add one between the asking and
  -- the LIKE: a NOT VALID or NO INHERIT CHECK, or a generated control column, committed since the preflight
  -- is refused in the preflight's words and rolls the cutover back to the resumable phase-2 state, where it
  -- used to fail the LIKE or the ATTACH raw. Under this phase's lock_timeout, like every wait in it.
  execute format('lock table %s in access share mode', p_parent::text);
  perform pgpm._transmute_refuse_generated_control(p_parent, p_control);
  perform pgpm._transmute_refuse_uncarried_constraints(p_parent);

  -- 5. create the partitioned parent under the STAGING name (no PK yet). INCLUDING CONSTRAINTS carries the
  -- user's CHECK constraints onto the parent so every partition (the monolith, the DEFAULT, and future
  -- forward children) enforces them -- without it, only the monolith would. LIKE also copies the transient
  -- pgpm_monolith_bound CHECK (already validated on p_parent by phase 2), which must NOT constrain the
  -- parent (it would reject any row at/after B), so drop it from the parent immediately; the monolith keeps
  -- its own copy for the metadata-only attach below, dropped separately afterward.
  execute format('create table %I.%I (like %s including defaults including generated including storage including constraints) partition by range (%I)',
                 v_nsp, v_staging, p_parent::text, p_control);
  v_parent := format('%I.%I', v_nsp, v_staging)::regclass;
  execute format('alter table %s drop constraint if exists pgpm_monolith_bound', v_parent::text);
  -- 0b (owner, RLS). After the LIKE, under its ACCESS SHARE (see 0b).
  select pg_get_userbyid(relowner), relacl, relrowsecurity, relforcerowsecurity
    into v_owner, v_acl, v_rls, v_rls_force
    from pg_class where oid = p_parent;
  -- The key and the identity the preflight planned from (#706), checked here, under the same ACCESS SHARE,
  -- which excludes every statement that changes them (see _transmute_key_shape). Steps 6 and 8 act on the
  -- preflight's v_idcols, v_idkinds and v_pkcols, and a change committed while phases 1 and 2 had let go of
  -- the table went unseen: an identity re-declared ALWAYS came back BY DEFAULT, a replaced key was declared
  -- on the parent as it had been. A change refuses, which rolls the cutover back to the resumable phase-2
  -- state; the re-run plans afresh from the table as it is and resumes from the recorded bound.
  if pgpm._transmute_key_shape(p_parent, p_control) is distinct from v_keyshape then
    raise exception 'pg_partition_magician: the primary key, a unique constraint, an identity column or the NOT NULL of % on % changed while this transmute ran (after its preflight read them and before its cutover), so the cutover would carry a key or identity the table no longer has. Nothing was converted: re-run transmute, which plans from the table as it is now and resumes from the recorded bound. (was: %; now: %)',
      quote_ident(p_control), p_parent, v_keyshape, pgpm._transmute_key_shape(p_parent, p_control);
  end if;

  -- 6. re-establish identity on the parent, in the SAME form it had (#308). The kind is not cosmetic:
  -- ALWAYS rejects an insert that supplies the column, BY DEFAULT accepts it, so re-adding an ALWAYS
  -- column BY DEFAULT silently starts accepting writes the operator's schema was written to refuse.
  -- The %s carries a keyword, not user input: v_idkinds comes from pg_attribute.attidentity, which
  -- Postgres constrains to 'a' or 'd'.
  -- And with the same sequence options (#670): a bare ADD GENERATED gives the new sequence the defaults,
  -- dropping an INCREMENT BY, MINVALUE/MAXVALUE, CYCLE or CACHE the operator declared. They are read off
  -- the original's sequence, which still exists here (step 3 drops it, after the renames); the %s is
  -- _identity_options' clause, numbers and keywords only. Read here to build the sequence outside the
  -- outage, and read again under the lock (0b, #732), which is the read the parent keeps.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      v_idopts[v_i] := pgpm._identity_options(pg_get_serial_sequence(p_parent::text, v_idcols[v_i])::regclass);
      execute format('alter table %s alter column %I add generated %s as identity %s',
                     v_parent::text, v_idcols[v_i],
                     case when v_idkinds[v_i] = 'a' then 'always' else 'by default' end,
                     coalesce(v_idopts[v_i], ''));
    end loop;
  end if;

  -- 7b (moved before the renames -- #344). Replay everything captured at 0b onto the staging parent,
  -- EXCEPT triggers and policies: those are the steps that need the LIVE name in place, not just the right
  -- OID (see 0b), so they stay below, after both renames. And except comments, which only the table's ACCESS
  -- EXCLUSIVE holds still (#630), so they are read and replayed below it, beside the triggers; and except
  -- grants, which no lock on the table holds still (#706), so they are read and replayed after the attach.
  execute format('alter table %s owner to %I', v_parent::text, v_owner);

  -- RLS. FORCE matters as much as ENABLE: without it the table owner bypasses every policy, so an
  -- owner-run query would see all rows and the isolation would be silently absent for exactly the role
  -- most likely to be running reports.
  if v_rls then
    execute format('alter table %s enable row level security', v_parent::text);
  end if;
  if v_rls_force then
    execute format('alter table %s force row level security', v_parent::text);
  end if;
  -- 0b (policies). Captured here, under the LIKE's ACCESS SHARE (see 0b), and replayed after both renames
  -- (7b, policies), not here onto the staging parent (#897). pg_get_expr renders a policy's expression
  -- against the table it is on, so a reference to the outer row comes back qualified by the table's own
  -- name (a correlated subquery's `m.tenant = t.org`, and `org` written unqualified as `t.org` too), and
  -- a subquery over the table itself names it. Created on <rel>_pgpm_new that text either failed raw
  -- ("missing FROM-clause entry"), after phases 1 and 2 had committed the bound and the claim, on every
  -- retry, or bound the subquery to this oid, which the rename hands to the monolith. Each statement names
  -- the table, which the new parent is by the time it runs, so it replays verbatim, as the triggers do.
  for v_pol in
    select polname, polcmd, polpermissive,
           case when polroles = '{0}'::oid[] then 'public'
                else (select string_agg(quote_ident(rolname), ', ' order by rolname)
                        from pg_roles where oid = any(polroles)) end as roles_q,
           pg_get_expr(polqual, polrelid)      as qual,
           pg_get_expr(polwithcheck, polrelid) as withcheck
      from pg_policy where polrelid = p_parent order by polname
  loop
    v_poldefs := v_poldefs || format('create policy %I on %I.%I as %s for %s to %s%s%s',
      v_pol.polname, v_nsp, v_rel,
      case when v_pol.polpermissive then 'permissive' else 'restrictive' end,
      case v_pol.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update'
                        when 'd' then 'delete' else 'all' end,
      v_pol.roles_q,
      case when v_pol.qual is not null then ' using (' || v_pol.qual || ')' else '' end,
      case when v_pol.withcheck is not null then ' with check (' || v_pol.withcheck || ')' else '' end);
  end loop;

"""

# #630 and #666: the blocks the reread-under-the-lock fix placed after an ACCESS EXCLUSIVE, shared by the
# mutations below that move each back to where it was read before the fix. Copied from the source verbatim,
# so a rewording there fails the build of these mutants loudly instead of leaving the fix in place.
TRANSMUTE_COMMENTS_UNDER_LOCK = """  -- 7b (comments). Read and replayed under the lock (see 0b): COMMENT takes only SHARE UPDATE EXCLUSIVE,
  -- which the staging LIKE's ACCESS SHARE does not exclude. p_parent is the monolith's oid by now, which
  -- is the table the comments are on.
  v_comment := obj_description(p_parent, 'pg_class');
  if v_comment is not null then
    execute format('comment on table %s is %L', v_parent::text, v_comment);
  end if;
  for v_colcom in
    select a.attname, col_description(p_parent, a.attnum) as c
      from pg_attribute a
     where a.attrelid = p_parent and a.attnum > 0 and not a.attisdropped
       and col_description(p_parent, a.attnum) is not null
  loop
    execute format('comment on column %s.%I is %L', v_parent::text, v_colcom.attname, v_colcom.c);
  end loop;

"""
TRANSMUTE_OWNER_RLS_AFTER_LIKE = """  -- 0b (owner, RLS). After the LIKE, under its ACCESS SHARE (see 0b).
  select pg_get_userbyid(relowner), relacl, relrowsecurity, relforcerowsecurity
    into v_owner, v_acl, v_rls, v_rls_force
    from pg_class where oid = p_parent;
"""
UNTRANSMUTE_TRIGGER_CAPTURE_UNDER_LOCK = """  -- Capture the parent's triggers before it is dropped (#277). transmute dropped the monolith's own
  -- originals in favour of the parent's, which clone down to every partition, and DETACH strips those
  -- clones -- so without this the reversal silently returns a table with no triggers at all. As in
  -- transmute, pg_get_triggerdef names the PARENT, and the restored table takes that name back below, so
  -- the definitions replay verbatim. And as in transmute (#499), the text carries no tgenabled, so each
  -- trigger's name and state are captured alongside, index-aligned, and re-applied after the replay.
  --
  -- Under the lock, not before it (#666, the mirror of transmute's #593). CREATE TRIGGER and ENABLE or
  -- DISABLE TRIGGER need only SHARE ROW EXCLUSIVE, which the first check's ACCESS SHARE does not exclude,
  -- so a trigger committed while the lock was queued was on neither the capture nor the restored table,
  -- and a state changed then came back as it had been. From here nothing can change them.
  select coalesce(array_agg(pg_get_triggerdef(oid) order by tgname), '{}'),
         coalesce(array_agg(tgname::text order by tgname), '{}'),
         coalesce(array_agg(tgenabled::text order by tgname), '{}')
    into v_trgdefs, v_trgnames, v_trgstates
    from pg_trigger where tgrelid = p_parent and not tgisinternal;

"""
UNTRANSMUTE_IDENTITY_UNDER_LOCK = """  -- Where each restored identity sequence resumes, read under the lock for the same reason (#656): an id a
  -- writer took while the lock was queued is past any earlier read, and the restored sequence would hand
  -- it out again. Before the DROP below, which takes the parent's sequence with it.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      v_ra := pgpm._identity_resume_at(p_parent, v_idcols[v_i], v_idnext[v_i], v_idmax[v_i], v_idmin[v_i]);
      v_idnext[v_i] := v_ra.o_next; v_idmax[v_i] := v_ra.o_max; v_idmin[v_i] := v_ra.o_min;
    end loop;
  end if;
"""

# untransmute's privileges and row-security capture (#667), under the lock, in two pieces (pass 5 seed
# S8 moves both above the gate). The first is the comment and the RLS flags read.
UNTRANSMUTE_ACL_CAPTURE_HEAD = """  -- Capture the parent's privileges and row security (#667), here, under the lock: GRANT, REVOKE and the
  -- RLS and policy DDL all change the parent, the table the application uses by name, and none of them
  -- recurses to a partition, so the monolith still carries whatever the table had at the conversion. The
  -- parent's state is what gets handed back, replayed below onto the restored table once it has the name
  -- again, as statements built here with the name it will have (the monolith's own copy is reset first).
  -- The shape is transmute's 7b, run the other way.
  select relrowsecurity, relforcerowsecurity into v_rls, v_rls_force
    from pg_class where oid = p_parent;
"""
# The rest of the #667 capture: the table and column grants and the policies. A piece of its own because
# #710 (PR #753) inserts the owner and comment capture between the two, under the lock, where it stays.
UNTRANSMUTE_ACL_CAPTURE_BODY = """  -- The grants as transmute carries them, the other way (#875, #903): the reset of the restored table's ACL
  -- first, the owner included (_acl_reset), then the parent's table and column grants, each under its grantor.
  v_grantdefs := pgpm._acl_carry_ddl(p_parent, format('%I.%I', v_nsp, v_rel));
  for v_g in
    select polname, polcmd, polpermissive,
           case when polroles = '{0}'::oid[] then 'public'
                else (select string_agg(quote_ident(rolname), ', ' order by rolname)
                        from pg_roles where oid = any(polroles)) end as roles_q,
           pg_get_expr(polqual, polrelid)      as qual,
           pg_get_expr(polwithcheck, polrelid) as withcheck
      from pg_policy where polrelid = p_parent order by polname
  loop
    v_poldefs := v_poldefs || format('create policy %I on %I.%I as %s for %s to %s%s%s',
      v_g.polname, v_nsp, v_rel,
      case when v_g.polpermissive then 'permissive' else 'restrictive' end,
      case v_g.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update'
                      when 'd' then 'delete' else 'all' end,
      v_g.roles_q,
      case when v_g.qual is not null then ' using (' || v_g.qual || ')' else '' end,
      case when v_g.withcheck is not null then ' with check (' || v_g.withcheck || ')' else '' end);
  end loop;

"""

# untransmute's publication-membership capture (#780), under the lock, and its apply after the rename.
UNTRANSMUTE_PUB_CAPTURE = """  -- and its publication memberships (#780, see above), under the lock for the same reason: ALTER PUBLICATION
  -- ... ADD or DROP TABLE takes SHARE UPDATE EXCLUSIVE on the table, which the first gate's ACCESS SHARE does
  -- not exclude, so one committed while the lock was queued was in neither a capture read before it nor the
  -- monolith's rows. From here none can commit.
  select coalesce(array_agg(o_def order by o_pub), '{}') into v_pubdefs
    from pgpm._publication_adds(p_parent, v_nsp, v_rel);
"""
UNTRANSMUTE_PUB_APPLY = """  for v_g in select o_pub, o_def from pgpm._publication_adds(v_restored, v_nsp, v_rel) loop
    if v_g.o_def = any(v_pubdefs) then
      v_pubdefs := array_remove(v_pubdefs, v_g.o_def);
    else
      execute format('alter publication %I drop table %s', v_g.o_pub, v_restored::text);
    end if;
  end loop;
  foreach v_tdef in array v_pubdefs loop
    execute v_tdef;
  end loop;
"""

# The "no commits in the sweep" defect, shared BY REFERENCE by the two mutations that model it: one
# for the reader-probe guard (bench/maintain_lock.sh) and one for the trace guard
# (bench/lock_trace.sh). Not copied, on purpose. This pattern's expected count has already drifted
# out of date three times as maintain() gained and lost boundaries; a second copy would have to be
# found and corrected each of those times, and the failure mode if it were missed is the bad one --
# one copy keeps matching while the other silently stops, leaving one guard verified and the other
# only apparently so.
MAINTAIN_NO_COMMITS_EDITS = [
    (BOUNDARY_RE, "", 5),
    ("    call pgpm.maintain(r.parent_table, v_status);\n"
     "    if pgpm._config_try_lock(r.parent_table) then\n"
     "      update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;\n"
     "    end if;\n"
     "    commit;\n",
     "    call pgpm.maintain(r.parent_table, v_status);\n"
     "    if pgpm._config_try_lock(r.parent_table) then\n"
     "      update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;\n"
     "    end if;\n", 1),
]

# transmute's two #509 precondition blocks. Each is one contiguous block anchored on its opening comment
# AND its closing raise, so a rewrite of anything between them fails the count instead of quietly yielding
# a clean copy. The shape block is the four refusals (pgpm.config row, relkind, partition or inheritance
# child, inheritance parent) between the nsp/rel lookup and `v_default :=`; the name block is the
# to_regclass check on the monolith's own name, just after the claim has made the bound final.
TRANSMUTE_SHAPE_PRECONDITION_RE = re.compile(
    r"  -- #509: transmute converts an ORDINARY table, once\..*?"
    r"refuses to attach an inheritance parent as a partition\.',\n"
    r"      p_parent, \(select string_agg\(inhrelid::regclass::text, ', ' order by inhrelid\) "
    r"from pg_inherits where inhparent = p_parent\);\n  end if;\n\n",
    re.DOTALL,
)
TRANSMUTE_MONOLITH_NAME_RE = re.compile(
    r"  -- #509: the cutover RENAMEs the table to this name.*?"
    r"      v_nsp, v_monolith, v_lo_native, v_hi_native;\n  end if;\n",
    re.DOTALL,
)
# The three places #511 made pgpm.archive_ledger follow the partition rather than a stale name, each
# held here whole (comment and code) so the mutant reads as code that never had the rule, not as a
# comment describing a statement that is no longer there. One constant per mechanism, because the
# guard has a direct assertion for each and a refactor that drops one should be named for it.
ARCHIVE_LEDGER_ORPHAN_SWEEP = """  -- COVERAGE UNDER A NAME NO LONGER TRACKED IS DISCARDED (issue #511). The ledger is keyed
  -- (parent_table, lo) and matched to its partition by child_name, so coverage is attached to a
  -- NAME, and a name can stop meaning what it meant without the ledger hearing about it: an operator
  -- renames a partly archived partition and updates pgpm.part.child_name (the procedure the guide
  -- used to document, and nothing else), or a pgpm older than this fix regrained a partly archived
  -- child and dropped the source with its chunks still recorded. Either way the rows now sit under a
  -- name that is not a tracked partition of this parent, over a range that a tracked partition
  -- holds, and that partition's own first chunk starts at the same lo: the INSERT below collides on
  -- archive_ledger_pkey, this whole step raises, maintain() logs skip_archive, and at archive_batch's
  -- default of 1 nothing of this parent is archived or retired again. A wedge that never clears.
  --
  -- Discarding is the only honest resolution, for the reason #452 gives: a watermark describes a
  -- partition's contents only because the write block has been on THAT relation since the first
  -- chunk, and nothing guarded the relationship between these rows and the partition that now holds
  -- the range. Adopting them would let a row written between the change and the block be dropped
  -- unarchived; the partition archives again from its own lo instead. Rows under an untracked name
  -- that overlap NO tracked partition are left alone: retire() leaves each dropped partition's
  -- chunks in place as the record of where its rows went, and those never collide with anything.
  -- Per name rather than per row, so one relation's coverage is discarded whole and the log says
  -- which relation it was; same action as the #452 discard, because it is the same statement about
  -- the ledger ("this coverage cannot be vouched for"), with `method` saying why.
  --
  -- Where pgpm itself changes a name or replaces a partition it keeps the ledger consistent in the
  -- same transaction (regrain_step's transitional rename carries the rows, its swap retires the
  -- source's), so on a current install this finds only what an operator or an older pgpm left.
  for r in execute format(
    'select l.child_name, count(*) as chunks, min(l.lo::%1$s)::text as lo, max(l.hi::%1$s)::text as hi
       from pgpm.archive_ledger l
      where l.parent_table = %2$L::regclass
        and l.child_name is not null
        and not exists (select 1 from pgpm.part p
                         where p.parent_table = l.parent_table and p.child_name = l.child_name)
        and exists (select 1 from pgpm.part t
                     where t.parent_table = l.parent_table
                       and l.lo::%1$s < t.hi::%1$s and l.hi::%1$s > t.lo::%1$s)
      group by l.child_name',
    v_ncast, p_parent::text)
  loop
    delete from pgpm.archive_ledger where parent_table = p_parent and child_name = r.child_name;
    insert into pgpm.log (parent_table, action, lo, hi, rows, method)
      values (p_parent, 'archive_coverage_reset', r.lo, r.hi, r.chunks,
              format('%s archived chunk(s) were recorded for %I.%I, which is no longer a tracked partition of %s, over a range a tracked partition now holds; nothing guarded that coverage across the change, so it is discarded and the partition holding the range archives from its own lo',
                     r.chunks, v_nsp, r.child_name, p_parent::text));
  end loop;

"""

# from_hypertable_cutover's choice of a key index's temp name and its build (#768, #872), whole. Shared by
# the mutation that puts back the pre-#768 by-name skip and the one that puts back the pre-#872 choice the
# copy did not share, for the reason RETIRE_IDENTITY_BLOCK is a constant.
HT_CUTOVER_KEY_TMP_BLOCK = """    v_tmp := pgpm._from_hypertable_key_tmp(k.conname, k.conindid, v_nsp, v_dest_oid);
    if v_tmp is null then
      raise exception 'pg_partition_magician: cannot build the index of key % of % on %.% -- both of its temp names (% and pgpm_new_%) are held by relations that are not on that destination. Drop or rename them and re-run.',
        quote_ident(k.conname), p_hypertable, quote_ident(v_nsp), quote_ident(v_dest),
        pgpm._from_hypertable_tmp_name(k.conname, k.conindid), k.conindid;
    end if;
    v_tmp_oid := to_regclass(format('%I.%I', v_nsp, v_tmp));
    if not exists (select 1 from pg_index i where i.indexrelid = v_tmp_oid and i.indrelid = v_dest_oid) then
      execute pgpm._from_hypertable_index_ddl(k.conindid, v_tmp, v_nsp, v_dest);
    end if;
"""

REGRAIN_SWAP_LEDGER_RETIRE = """  -- The source's archive coverage goes with it (#511). A partly archived child can be regrained
  -- (#278), and its chunks sit in pgpm.archive_ledger keyed (parent_table, lo) under its name. Left
  -- there, they describe a relation that no longer exists, and the first fine child starts at the
  -- same lo, so its first chunk's INSERT collides on the primary key: _archive_step raises every tick
  -- and nothing of this parent is archived or retired again. Retire them here, in the swap's own
  -- transaction, rather than leave them for _archive_step's orphan discard: the first fine child of a
  -- #266-renamed source takes the source's OLD bare name, so a row left under that name is not an
  -- orphan the discard can see but a chunk recorded for a different relation sitting under a live
  -- partition's name, with only _enforce_write_blocks' no-block reset (#452) between it and being
  -- adopted as that partition's watermark. The ledger should not lean on a backstop for a state the
  -- swap can simply not leave behind. The fine children hold every row and archive from their own lo
  -- under their own blocks; the objects the source's chunks already wrote stay in the archive,
  -- unreferenced.
  delete from pgpm.archive_ledger where parent_table = p_parent and child_name = v_child_name;
  get diagnostics v_rec = row_count;
  if v_rec > 0 then
    insert into pgpm.log (parent_table, action, lo, hi, rows, method)
      values (p_parent, 'archive_coverage_reset', v_lo, v_hi, v_rec,
              format('%s archived chunk(s) were recorded for %I.%I, which this regrain replaced with %s fine partition(s) and dropped; discarded, and each fine partition archives from its own lo',
                     v_rec, v_src_nsp, v_child_name, v_made));   -- #872: where the source was
  end if;
"""

REGRAIN_RENAME_LEDGER_CARRY = """    -- ...and its archive coverage with it (#511). pgpm.archive_ledger matches chunks to their partition
    -- by child_name, so rows left under the old name are coverage nothing tracks: _archive_step's
    -- orphan discard would throw them away on the next tick and re-export the prefix, and the old bare
    -- name is exactly what the first fine sub-range is about to be called, so after the swap they
    -- would sit under a live partition's name as a watermark recorded for a different relation, with
    -- only the #452 no-block reset between them and adoption. Same relation, same transaction, block
    -- untouched, so carrying the rows keeps every #452 invariant.
    update pgpm.archive_ledger set child_name = v_src_name
     where parent_table = p_parent and child_name = v_child_name;
"""

# _next_archive_chunk's extension past the encoding's unit (#513), whole. The `if` that opens it shares
# its first line with the `no progress possible` return two statements down at a different indent, so
# the pattern carries the body too: matched as a block it is unique, and a block that stops matching is
# one mutate.py refuses to build rather than a clean copy passed off as a mutant.
ARCHIVE_CHUNK_TIES_BLOCK = """    if not pgpm._native_gt(cfg.control_kind, v_stop, v_lo) then
      v_unit := case cfg.control_kind
                  when 'text_time' then case cfg.text_time_unit when 's' then '1 second' else '1 millisecond' end
                  when 'uuidv7' then '1 millisecond'
                  when 'time' then '1 microsecond'
                  else '1' end;
      execute format('select %s from %I.%I t where t.%I >= %L order by t.%I asc limit 1',
                     v_cval_q, v_nsp, p_child, cfg.control_column,
                     pgpm._encode(cfg.control_kind, pgpm._grid_next(cfg.control_kind, v_unit, v_lo, cfg.partition_tz),
                                  cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit,
                                  cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz),
                     cfg.control_column)
        into v_next_distinct_col;
      v_stop := case when v_next_distinct_col is null then v_child_hi
                     else pgpm._col_to_native(cfg, v_next_distinct_col) end;
    end if;
"""

# retire()'s reclamation of the regrain whose source it drops (#519), whole (comment and code), so the
# first mutant reads as code that never had it. The second keeps a comment of its own, because what it
# puts in place is a plausible "simplification" a refactor might make, and the mutant should read as
# one: the operator verb, parent-wide, where the scoped helper was.
RETIRE_REGRAIN_RECLAIM = """    -- THE REGRAIN THIS DROP WOULD ORPHAN GOES WITH IT (issue #519). If this partition is the source of
    -- an in-flight regrain, its fine copies, its captured changes and config.regrain_cursor would
    -- outlive it with nothing left to reclaim them: auto-regrain answers 'none' once no coarse child
    -- remains, and the janitor only tears down capture the cursor does not cover. _regrain_reclaim
    -- takes exactly that regrain's state and no other's (see there for why reclaiming beats refusing,
    -- and why it is not regrain_cancel). In the drop's own subtransaction, ahead of the DROP, so a lock
    -- lost on a copy leaves the source whole and this retirement retried next tick, and so the cancel
    -- is recorded before the drop it makes room for.
    perform pgpm._regrain_reclaim(p_parent, p_child, r.lo, r.hi);
"""

RETIRE_REGRAIN_CANCEL_WHOLE_PARENT = """    -- the source of an in-flight regrain is being dropped: cancel the regrain
    perform pgpm.regrain_cancel(p_parent);
"""

# archive._pq_huffman_lengths' merge queue (#587): local arrays now, a temp table created and dropped on
# every call before, whose locks outlived the drop to transaction end. The mutant restores the old
# declarations and the old queue, verbatim from db64096, so it reads as the function that shipped.
ARCHIVE_HUFF_DECL_ARRAYS = """  v_f1 bigint; v_f2 bigint;
  v_freq bigint[];
  v_alive boolean[];
  v_group int4[];
  v_j int4;
  v_max_len int4;
"""

ARCHIVE_HUFF_DECL_TEMP_TABLE = """  v_f1 bigint; v_f2 bigint;
  v_m1 int4[]; v_m2 int4[];
  v_sym int4;
  v_max_len int4;
"""

ARCHIVE_HUFF_QUEUE_ARRAYS = """  -- The merge queue lives in local arrays, indexed by node id: v_freq and v_alive per node, and
  -- v_group[symbol] = the node that currently holds it (0 = unused). It used to be a temp table
  -- created and dropped on every call, three calls per GZIP encode, and a dropped relation's locks
  -- are held to transaction end: ~15 shared lock-table entries per call, so one maintain() tick
  -- archiving enough compressed chunks exhausted the cluster's lock table (issue #587). Arrays take
  -- no lock at all. Node ids are handed out in the same order the table's were and the minimum is
  -- the same (freq, node_id), so the merge sequence, and every code, is unchanged.
  v_freq := array_fill(0::bigint, array[2 * n]);
  v_alive := array_fill(false, array[2 * n]);
  v_group := array_fill(0, array[n]);
  for i in 1..n loop
    if p_freqs[i] > 0 then
      v_node_id := v_node_id + 1;
      v_freq[v_node_id] := p_freqs[i];
      v_alive[v_node_id] := true;
      v_group[i] := v_node_id;
    end if;
  end loop;

  v_ncount := v_node_id;

  -- a length-limited prefix code for v_ncount symbols can only ever exist if
  -- v_ncount <= 2^p_max_bits (Kraft's inequality's own ceiling: v_ncount codes of
  -- exactly p_max_bits each already sum to v_ncount * 2^-p_max_bits, which must be
  -- <= 1). Never reachable from a real DEFLATE call (max_bits is always 15 there,
  -- alphabets max out at 286) -- guarded so a misuse fails loudly instead of
  -- infinite-looping in the Kraft-restore pass below.
  if v_ncount > power(2, p_max_bits)::bigint then
    raise exception 'archive._pq_huffman_lengths: % distinct symbols cannot fit a %-bit-limited prefix code (needs <= % symbols)',
      v_ncount, p_max_bits, power(2, p_max_bits)::bigint;
  end if;

  if v_ncount = 0 then
    return v_lengths;
  end if;

  if v_ncount = 1 then
    v_lengths[array_position(v_group, 1)] := 1;
    return v_lengths;
  end if;

  while v_ncount > 1 loop
    -- the two live nodes with the smallest (freq, node_id): scanning ids in ascending order and
    -- replacing only on a strictly smaller freq keeps the lower id on a tie.
    v_id1 := null; v_id2 := null;
    for v_j in 1..v_node_id loop
      if v_alive[v_j] then
        if v_id1 is null or v_freq[v_j] < v_f1 then
          v_id2 := v_id1; v_f2 := v_f1;
          v_id1 := v_j; v_f1 := v_freq[v_j];
        elsif v_id2 is null or v_freq[v_j] < v_f2 then
          v_id2 := v_j; v_f2 := v_freq[v_j];
        end if;
      end if;
    end loop;

    v_node_id := v_node_id + 1;
    v_freq[v_node_id] := v_f1 + v_f2;
    v_alive[v_node_id] := true;
    v_alive[v_id1] := false;
    v_alive[v_id2] := false;
    for i in 1..n loop
      if v_group[i] = v_id1 or v_group[i] = v_id2 then
        v_lengths[i] := v_lengths[i] + 1;
        v_group[i] := v_node_id;
      end if;
    end loop;

    v_ncount := v_ncount - 1;
  end loop;
"""

ARCHIVE_HUFF_QUEUE_TEMP_TABLE = """  create temp table archive_huff_groups (node_id int4 primary key, freq bigint, members int4[])
    on commit drop;

  for i in 1..n loop
    if p_freqs[i] > 0 then
      v_node_id := v_node_id + 1;
      insert into archive_huff_groups values (v_node_id, p_freqs[i], array[i]);
    end if;
  end loop;

  select count(*) into v_ncount from archive_huff_groups;

  -- a length-limited prefix code for v_ncount symbols can only ever exist if
  -- v_ncount <= 2^p_max_bits (Kraft's inequality's own ceiling: v_ncount codes of
  -- exactly p_max_bits each already sum to v_ncount * 2^-p_max_bits, which must be
  -- <= 1). Never reachable from a real DEFLATE call (max_bits is always 15 there,
  -- alphabets max out at 286) -- guarded so a misuse fails loudly instead of
  -- infinite-looping in the Kraft-restore pass below.
  if v_ncount > power(2, p_max_bits)::bigint then
    raise exception 'archive._pq_huffman_lengths: % distinct symbols cannot fit a %-bit-limited prefix code (needs <= % symbols)',
      v_ncount, p_max_bits, power(2, p_max_bits)::bigint;
  end if;

  if v_ncount = 0 then
    drop table archive_huff_groups;
    return v_lengths;
  end if;

  if v_ncount = 1 then
    select members into v_m1 from archive_huff_groups;
    v_lengths[v_m1[1]] := 1;
    drop table archive_huff_groups;
    return v_lengths;
  end if;

  while v_ncount > 1 loop
    select node_id, freq, members into v_id1, v_f1, v_m1
      from archive_huff_groups order by freq, node_id limit 1;
    select node_id, freq, members into v_id2, v_f2, v_m2
      from archive_huff_groups where node_id <> v_id1 order by freq, node_id limit 1;

    foreach v_sym in array v_m1 loop
      v_lengths[v_sym] := v_lengths[v_sym] + 1;
    end loop;
    foreach v_sym in array v_m2 loop
      v_lengths[v_sym] := v_lengths[v_sym] + 1;
    end loop;

    delete from archive_huff_groups where node_id in (v_id1, v_id2);
    v_node_id := v_node_id + 1;
    insert into archive_huff_groups values (v_node_id, v_f1 + v_f2, v_m1 || v_m2);

    select count(*) into v_ncount from archive_huff_groups;
  end loop;

  drop table archive_huff_groups;
"""

# #574's resume lattice check, whole (comment and code), so the mutant reads as a resume that never
# had the rule rather than a comment describing a refusal that is no longer there.
TRANSMUTE_RESUME_LATTICE_RE = re.compile(
    r"  -- #574: and the bound has to lie on the grid THIS call registers\..*?"
    r"      v_hi_native, pgpm\._grid_floor\(p_control_kind, p_step, p_anchor, v_hi_native, v_tz\), p_parent;\n"
    r"  end if;\n",
    re.DOTALL,
)
# #628's resume control-column check, whole (comment and code). The claim still records control_attnum,
# so the mutant is exactly "recorded but never compared", the half of the fix a refactor could drop.
TRANSMUTE_RESUME_COLUMN_RE = re.compile(
    r"  -- #628: and the bound has to be on the column THIS call partitions by\..*?"
    r"               'a column since dropped'\),\n"
    r"      p_parent;\n"
    r"  end if;\n",
    re.DOTALL,
)
# #581's three transmute refusals: the step's sign and the lookahead's, which sit together after the
# retain check, and the date column's whole-day rule, which sits in the control-type chain.
TRANSMUTE_STEP_OBTAIN_PREFLIGHT_RE = re.compile(
    r"  -- #581: the step must be positive, which nothing checked either\..*?"
    r"    raise exception 'pg_partition_magician: p_obtain must be a non-negative integer \(got %\)', p_obtain;\n"
    r"  end if;\n",
    re.DOTALL,
)
TRANSMUTE_DATE_WHOLE_DAYS_RE = re.compile(
    r"  elsif p_control_kind = 'time' and v_typname = 'date'\n.*?"
    r"the cutover would fail on an empty partition range', quote_ident\(p_control\), p_step;\n",
    re.DOTALL,
)
# archive.to_s3's enclosing query_canceled handler (#595), whole, so the mutant reads as the function
# before it: the labelled export block with its `when others` abort, and nothing around it. The
# handler's #636 sweep of an initiate it never saw the id of goes with it.
TO_S3_CANCEL_HANDLER = """end export;
exception when query_canceled then
  -- a cancel, from the export or from the handler above before it could abort (see the top of the
  -- body). It is taken by now, so this DELETE runs; the cancel is re-raised either way.
  if v_upload_id is not null then
    begin
      perform archive.s3_signed_request('DELETE', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                       'uploadId=' || archive.s3_url_encode(v_upload_id),
                                       'text/plain', '', v_key_id, v_secret);
    exception when others then null;
    end;
  elsif v_initiating then
    begin
      perform archive._s3_abort_uploads_at(cfg.endpoint, cfg.bucket, cfg.region, v_key, v_key_id, v_secret);
    exception when others then null;
    end;
  end if;
  raise;
end;
$$;
"""

# #706 and #732: blocks the reread-under-the-lock fix placed where the protecting lock is held, shared by
# the mutations below that put each back where it was read before the fix. Copied from the source verbatim,
# so a rewording there fails the build of these mutants loudly instead of leaving the fix in place.
TRANSMUTE_GRANTS_AFTER_ATTACH = """  -- 7b (grants), HERE, after the rename and the attach (#706). GRANT and REVOKE take no lock on the table at
  -- all, so no lock this cutover holds stops one, and the grants used to be read before the rename (with the
  -- staging work, under only the LIKE's ACCESS SHARE): a REVOKE or GRANT committed after that read landed
  -- on the original table alone, now the monolith, and the parent every query names kept the privilege
  -- that was revoked, or lacked the one that was granted. What serialises them is the catalog row each
  -- rewrites. A table-level GRANT or REVOKE rewrites the table's pg_class row, which the rename has just
  -- rewritten in this transaction; a column-level one rewrites the column's pg_attribute row, which the
  -- attach has just rewritten (it marks every column inherited). So one committed before this point is in
  -- what is read here, and one that has not committed cannot commit before the cutover does: it waits on
  -- this transaction and then fails with "tuple concurrently updated". p_parent is the monolith's oid by
  -- now, which is the table the grants are on.
  -- The parent ends with exactly the table's grants, table and column level (#838): it was born with this
  -- role's ALTER DEFAULT PRIVILEGES, so _acl_carry_ddl's first statement resets its ACL and the rest replay
  -- the table's. Additive grants left a privilege REVOKEd on the table held on the parent. After the OWNER
  -- TO above, which the reset needs (it takes the owner's own privileges too).
  foreach v_grant in array pgpm._acl_carry_ddl(p_parent, v_parent::text) loop
    execute v_grant;
  end loop;

"""
TRANSMUTE_IDENTITY_OPTIONS_UNDER_LOCK = """  -- #732: and each identity sequence's options. ALTER SEQUENCE takes no lock on the table, so the table's
  -- ACCESS EXCLUSIVE does not hold them still; _identity_options_locked takes the lock on the sequence that
  -- does, held to the commit. An INCREMENT BY (or a bound, CACHE or CYCLE) committed since step 6 read them
  -- is put on the parent's sequence here, before 8b reseeds it on that lattice; RESTART only puts the fresh
  -- sequence back at its new START, which 8b moves past anyway. The clause is _identity_options' own,
  -- unwrapped from its parentheses: numbers and keywords only.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      v_opt := pgpm._identity_options_locked(pg_get_serial_sequence(p_parent::text, v_idcols[v_i])::regclass);
      if v_opt is distinct from v_idopts[v_i] then
        execute format('alter sequence %s %s restart', pg_get_serial_sequence(v_parent::text, v_idcols[v_i]),
                       substr(v_opt, 2, length(v_opt) - 2));
      end if;
    end loop;
  end if;
"""
UNTRANSMUTE_IDENTITY_OPTIONS_UNDER_LOCK = """  -- And each parent sequence's options (#670), which go with the parent's sequence when the parent is
  -- dropped below, read here (#732) under a lock on the sequence itself: ALTER SEQUENCE takes no lock on the
  -- table, so the table's ACCESS EXCLUSIVE does not hold them still, and an INCREMENT BY committed while the
  -- lock above was queued, read before it, was lost with the parent. _identity_options_locked's lock is held
  -- to the commit, so one that has not committed by now waits for this reversal.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      v_idopts[v_i] := pgpm._identity_options_locked(pg_get_serial_sequence(p_parent::text, v_idcols[v_i])::regclass);
    end loop;
  end if;
"""

# archive._object_stem's body since #823 (the era and the decimal point kept). Three mutations put an
# older body back in its place (#502, #551, #823), so the text they all find lives in one place.
OBJECT_STEM_BODY = (
    "  select case when p_kind = 'id' then p_lo\n"
    "              else regexp_replace(p_lo::timestamptz::text, '[^0-9.]', '', 'g')\n"
    "                   || case when p_lo::timestamptz::text like '% BC' then 'BC' else '' end end;\n"
)

# archive._pq_snapshot's fill and the two Parquet encoders' tails (#632). Shared by the two mutations
# that take the snapshot's lifecycle apart (parquet_per_column_statements, the pre-#462 view, and
# parquet_snapshot_per_encode_table, the pre-#632 table per encode), so the exact text lives in one place.
PQ_SNAPSHOT_FILL = """  truncate pg_temp.archive_pq_snapshot;
  -- ONE statement, so ONE snapshot: every row the encoder writes is a row this statement saw.
  execute format(
    'insert into pg_temp.archive_pq_snapshot
       select %s, row_number() over (order by %s) as archive_pq_ord from %s',
    v_cols_q, v_order_q, v_from_q);
  get diagnostics v_num_rows = row_count;
"""
PQ_SNAPSHOT_TAIL = "  truncate pg_temp.archive_pq_snapshot;  -- emptied, not dropped: the next encode reuses it (#632)\n"

# _frontier_native's #325 clock blend for uuidv7 and text_time, as one (find, replace, count) edit that puts
# the data-only frontier back. Shared by frontier_data_only (which reverts _transmute's inline duplicate
# too) and frontier_native_data_only (which reverts this site alone, #846), so the two cannot drift apart.
FRONTIER_NATIVE_CLOCK_BLEND = (
    "  v_decoded := pgpm._decode(cfg.control_kind, v_max,\n"
    "                             cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);\n"
    "  -- #325: uuidv7 (and text_time, the same shape of thing) is a TIME grid fed by DATA. Left as plain\n"
    "  -- max(control), a table whose writes go quiet (a restored dump, a stale clone, a drought) has a\n"
    "  -- frontier stuck wherever the data ended while now() keeps moving -- obtain measures itself against\n"
    "  -- its own past output and finds nothing to do, so the grid stalls exactly where the drought began and\n"
    "  -- every write past it is refused, permanently and silently. greatest() with now() makes both kinds\n"
    "  -- self-healing the same way `time` already is: the grid can never fall further behind the clock than\n"
    "  -- one maintenance tick, drought or not. `id` is untouched below -- it has no clock, so its frontier\n"
    "  -- can only be where the data actually put it.\n"
    "  if cfg.control_kind in ('uuidv7', 'text_time') then\n"
    "    return pgpm._ts_text(greatest(v_decoded::timestamptz, now()));\n"
    "  end if;\n"
    "  return v_decoded;\n"
    "end;\n",
    "  return pgpm._decode(cfg.control_kind, v_max,\n"
    "                       cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);\n"
    "end;\n",
    1,
)

# _transmute's policy blocks (#845, #897), each whole, so the mutations that move them match them exactly:
# the capture, which builds each CREATE POLICY as text naming the table before the renames; the replay,
# which executes them after both; and the pre-#897 loop, which executed them onto the staging parent.
TRANSMUTE_POLICY_CAPTURE = """  -- 0b (policies). Captured here, under the LIKE's ACCESS SHARE (see 0b), and replayed after both renames
  -- (7b, policies), not here onto the staging parent (#897). pg_get_expr renders a policy's expression
  -- against the table it is on, so a reference to the outer row comes back qualified by the table's own
  -- name (a correlated subquery's `m.tenant = t.org`, and `org` written unqualified as `t.org` too), and
  -- a subquery over the table itself names it. Created on <rel>_pgpm_new that text either failed raw
  -- ("missing FROM-clause entry"), after phases 1 and 2 had committed the bound and the claim, on every
  -- retry, or bound the subquery to this oid, which the rename hands to the monolith. Each statement names
  -- the table, which the new parent is by the time it runs, so it replays verbatim, as the triggers do.
  for v_pol in
    select polname, polcmd, polpermissive,
           case when polroles = '{0}'::oid[] then 'public'
                else (select string_agg(quote_ident(rolname), ', ' order by rolname)
                        from pg_roles where oid = any(polroles)) end as roles_q,
           pg_get_expr(polqual, polrelid)      as qual,
           pg_get_expr(polwithcheck, polrelid) as withcheck
      from pg_policy where polrelid = p_parent order by polname
  loop
    v_poldefs := v_poldefs || format('create policy %I on %I.%I as %s for %s to %s%s%s',
      v_pol.polname, v_nsp, v_rel,
      case when v_pol.polpermissive then 'permissive' else 'restrictive' end,
      case v_pol.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update'
                        when 'd' then 'delete' else 'all' end,
      v_pol.roles_q,
      case when v_pol.qual is not null then ' using (' || v_pol.qual || ')' else '' end,
      case when v_pol.withcheck is not null then ' with check (' || v_pol.withcheck || ')' else '' end);
  end loop;
"""
TRANSMUTE_POLICY_REPLAY = """  -- 7b (policies). After both renames (#897), when the table's name, which every captured statement names
  -- and pg_get_expr used to qualify the outer row, is the new parent's. Inside the outage, which #344 kept
  -- the staging configuration out of; a CREATE POLICY on an empty partitioned table is catalog work, and
  -- before the renames the text could not be replayed at all. Policies live on the PARENT and only on the
  -- parent (measured: a parent policy governs parent-routed reads into a partition, with no policy on the
  -- partition at all). Do not "fix" the apparent gap by scattering copies onto children; direct partition
  -- access needs grants that live on the parent anyway.
  foreach v_poldef in array v_poldefs loop
    execute v_poldef;   -- names the ORIGINAL table, which is now the parent: replays verbatim
  end loop;

"""
TRANSMUTE_POLICY_ON_STAGING_PRE_897 = """  -- Policies live on the PARENT and only on the parent (measured: a parent policy governs parent-routed
  -- reads into a partition, with no policy on the partition at all). Do not "fix" the apparent gap by
  -- scattering copies onto children; direct partition access needs grants that live on the parent anyway.
  for v_pol in
    select polname, polcmd, polpermissive,
           case when polroles = '{0}'::oid[] then 'public'
                else (select string_agg(quote_ident(rolname), ', ' order by rolname)
                        from pg_roles where oid = any(polroles)) end as roles,
           pg_get_expr(polqual, polrelid)      as qual,
           pg_get_expr(polwithcheck, polrelid) as withcheck
      from pg_policy where polrelid = p_parent
  loop
    execute format('create policy %I on %s as %s for %s to %s%s%s',
      v_pol.polname, v_parent::text,
      case when v_pol.polpermissive then 'permissive' else 'restrictive' end,
      case v_pol.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update'
                        when 'd' then 'delete' else 'all' end,
      v_pol.roles,
      case when v_pol.qual is not null then ' using (' || v_pol.qual || ')' else '' end,
      case when v_pol.withcheck is not null then ' with check (' || v_pol.withcheck || ')' else '' end);
  end loop;
"""
# The pre-#897 shape put back, shared by the two guards that must each catch it on its own.
TRANSMUTE_POLICIES_ON_STAGING_EDITS = [(TRANSMUTE_POLICY_CAPTURE, TRANSMUTE_POLICY_ON_STAGING_PRE_897, 1),
                                       (TRANSMUTE_POLICY_REPLAY, "", 1)]

# hypertable_time_rendering.sh's run_file verdict as it stood before #844, whole: its own hand-rolled
# lines in place of the shared `# >>> pgTAP verdict` block (psql's exit never captured, a shortfall read
# only from finish()'s line, a `not ok` counted only with a ` -` description). The mutation that puts it
# back replaces the block with exactly this text, so it lives here once rather than inside a pattern.
TIME_RENDERING_PRE_844_VERDICT = r"""  out=$(q -d "$DB" -tAq -f "$file" 2>&1)
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+ -')
  # Two failure shapes, reported apart. A file that died early leaves a raw ERROR: and few or no
  # assertions, which must NOT read the same as assertions that ran and failed: discriminate.sh treats
  # any non-zero exit as "the guard caught the defect", so a harness broken enough to fail against
  # everything would otherwise be reported as proving the mutation. And a plan shortfall is a failure
  # too (#601), which this runner, unlike pg_prove, has to look for itself.
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "$label: the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | cut -c1-240 | sed 's/^/      /'
    ffail=1
  fi
  if echo "$out" | grep -qE '^# Looks like you planned'; then
    printf 'FAIL  %-58s %s\n' "$label: the file ran every assertion it planned" "$(echo "$out" | grep -E '^# Looks like you planned')"
    ffail=1
  fi
  if [ "$bad" = 0 ] && [ "$ffail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "$label" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "$label" "$ran ran, $bad failed"; ffail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "$label: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    ffail=1
  fi
  [ "$ffail" = 0 ] || fail=1
"""

# Issue #978's fix in _replica_identity_like_parent, whole: both of its mutations replace it.
_RI_DROPPED_BLOCK = (
    "  if v_want = 'i' and not exists (select 1 from pg_index where indrelid = p_parent and indisreplident) then\n"
    "    v_want := 'n';\n"
    "    v_warned := coalesce(current_setting('pgpm.warned_replica_identity_nothing', true), '');\n"
    "    if not p_parent::oid::text = any(string_to_array(v_warned, ',')) then\n"
    "      perform set_config('pgpm.warned_replica_identity_nothing', concat_ws(',', nullif(v_warned, ''), p_parent::oid::text), true);\n"
    "      insert into pgpm.log (parent_table, action, method)\n"
    "        values (p_parent, 'warn_replica_identity_nothing',\n"
    "                format('%s took REPLICA IDENTITY NOTHING: the identity index of %s was dropped, which PostgreSQL treats as NOTHING; partitions minted until %s is given a replica identity again keep NOTHING',\n"
    "                       p_child, p_parent, p_parent));\n"
    "    end if;\n"
    "  end if;\n"
)

# The proof query of _check_text_time_collation (#639), which the two mutations that put an older check
# back replace: text_time_collation_positional_only (pre-#568) and text_time_collation_probe_only (pre-#639).
_TT_COLLATION_PROOF = (
    "    with d(i, c) as (select i, substr(%1$L, i, 1) from generate_series(1, %2$s) as i),\n"
    "    s(k, v) as (\n"
    "      select x.i * (%2$s + 1), %3$L || x.c from d x\n"
    "      union all\n"
    "      select x.i * (%2$s + 1) + y.i, %3$L || x.c || y.c from d x cross join d y\n"
    "    ),\n"
    "    chain(k, lo, hi) as (select k, v, lead(v) over (order by k) from s)\n"
    "    select lo, hi\n"
    "      from chain\n"
    "     where hi is not null and not ((lo::text collate %4$s) < (hi::text collate %4$s))\n"
    "     order by k limit 1\n"
    "  $q$, v_alphabet, length(v_alphabet), v_prefix, v_coll_q)\n"
)

MUTATIONS = {
    "transmute_no_commits": (
        "bench/transmute_lock.sh",
        "Pre-#275 transmute: one transaction, so the ADD's ACCESS EXCLUSIVE is still held during the "
        "O(rows) validation scan.",
        [("  commit;   -- releases the ADD's ACCESS EXCLUSIVE before the scan; "
          "the claim row survives (it is committed)\n", "", 1)],
    ),
    "transmute_claim_advisory_reap": (
        "bench/transmute_claim_squat.sh",
        "Pre-#405 recovery paths: _transmute_reap and transmute_abort decide 'is this conversion still "
        "running?' by trying to TAKE the session advisory lock keyed on the table's oid, instead of "
        "asking whether the claim's recorded owner session is alive. That key carries no ACL and is "
        "computable by anyone, so a role that can merely CONNECT can hold it and make both paths read "
        "'still running' forever -- pinning a write-rejecting pgpm_monolith_bound on the operator's "
        "table with no automated or manual way back.",
        [
            ("    if pgpm._session_alive(r.owner_pid, r.owner_backend_start) then\n"
             "      continue;   -- still running; leave it alone\n"
             "    end if;\n",
             "    if not pg_try_advisory_lock(hashtextextended('pgpm_transmute:' || "
             "r.parent_table::oid::text, 0)) then\n"
             "      continue;   -- still running; leave it alone\n"
             "    end if;\n", 1),
            ("  if pgpm._session_alive(r.owner_pid, r.owner_backend_start) and r.owner_pid <> pg_backend_pid() then\n"
             "    raise exception 'pg_partition_magician: cannot abort the transmute of % -- it is "
             "still running in another session', p_parent;\n"
             "  end if;\n",
             "  if not pg_try_advisory_lock(hashtextextended('pgpm_transmute:' || "
             "p_parent::oid::text, 0)) then\n"
             "    raise exception 'pg_partition_magician: cannot abort the transmute of % -- it is "
             "still running in another session', p_parent;\n"
             "  end if;\n", 1),
        ],
    ),
    "transmute_no_shape_precondition": (
        "bench/transmute_preconditions.sh",
        "Pre-#509 _transmute: no check that p_parent is an unconverted plain table (relkind 'r', no "
        "pgpm.config row, no pg_inherits row as child or parent). Re-run on an already converted table, "
        "the documented remedy after any failure, phase 1 adds pgpm_monolith_bound NOT VALID to the live "
        "PARTITIONED parent (propagating to the forward partitions taking writes), phase 2 validates it, "
        "and the cutover fails on the monolith's name, leaving the bound rejecting every write past the "
        "original monolith's hi. tests/125 part A: the refusal's own message, no bound anywhere in the "
        "family, one config row, and a write past the monolith still landing in the forward partition.",
        [(TRANSMUTE_SHAPE_PRECONDITION_RE, "", 1)],
    ),
    "transmute_names_unchecked": (
        "bench/transmute_preconditions.sh",
        "Pre-#509 name guards: the monolith's own coarse name <rel>_p<lo>_to_<hi> is checked nowhere "
        "before the cutover's RENAME, so a standalone table holding it gets through phases 1 and 2 (bound "
        "committed and validated, claim taken) and fails the cutover with a raw 42P07, where reference.md "
        "promises an up-front refusal with the table untouched; and the orphan guard matches relkind 'r' "
        "only, so a sequence holding a CHILD's name is skipped by it and then by obtain itself, and that "
        "conversion completes with no forward partition and nothing logged. tests/125 part B: the "
        "refusal's own message naming the relation, no bound, no claim, the table still plain, and the "
        "same call converting once the squatter is gone.",
        [
            (TRANSMUTE_MONOLITH_NAME_RE, "", 1),
            ("     where c.relnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)\n"
             "       and starts_with(c.relname, v_rel || '_p')\n",
             "     where c.relnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)\n"
             "       and c.relkind = 'r'\n"
             "       and starts_with(c.relname, v_rel || '_p')\n", 1),
        ],
    ),
    "transmute_claim_refuses_own_session": (
        "bench/transmute_preconditions.sh",
        "Pre-#509 claim protocol: the take-over predicate is `not _session_alive(owner)` alone, and "
        "transmute_abort refuses whenever the owner is alive. After a cutover failure the owner is the "
        "operator's own still-connected session, so the documented re-run is refused as 'already in "
        "progress in another session', so is the abort, and the write-rejecting bound stays until that "
        "session disconnects. tests/125 part C drives the failure, the retry and the abort through ONE "
        "dblink backend, and pins that a different live session is still refused both ways.",
        [
            ("          or (transmute_inflight.owner_pid = excluded.owner_pid\n"
             "              and transmute_inflight.owner_backend_start = excluded.owner_backend_start)\n",
             "", 1),
            (" and r.owner_pid <> pg_backend_pid() then\n", " then\n", 1),
        ],
    ),
    "maintain_no_commits": (
        "bench/maintain_lock.sh",
        "Pre-#279 maintain_all: one transaction for the WHOLE sweep, so a step's ACCESS EXCLUSIVE for "
        "one table is held across every table after it, including the long regrain copy. Issue #347 "
        "moved obtain into its own procedure/job, so this mutant no longer touches it (maintain() has "
        "no obtain step to strip); the guard now drives a retain-drop on a throwaway table ahead of "
        "the regrain table in the sweep, so this needs ALL THREE of maintain()'s own 5 remaining "
        "internal boundaries (write-block, archive, retain, regrain, and the #265 one before "
        "FK-validate -- that one runs unconditionally every tick even with no incoming FK, so it is "
        "just as much a leak point as the #279 ones) AND maintain_all()'s outer per-parent commit "
        "stripped -- any ONE of those left in place still releases the lock before the next table's "
        "turn, which is exactly what made this mutant look non-discriminating the first three times "
        "the count/pattern here was updated.",
        # EVERY remaining boundary inside maintain(), not just the one before regrain -- same
        # discriminate.sh lesson as before, restated: removing only one still releases the lock a few
        # statements later, at the NEXT boundary or (failing that) the outer loop's own per-parent
        # commit, which the guard rightly does not object to.
        MAINTAIN_NO_COMMITS_EDITS,
    ),
    "maintain_no_commits_trace": (
        "bench/lock_trace.sh",
        "The SAME defect as maintain_no_commits, put back for the eBPF trace guard (#383). The two "
        "guards make the same claim about the same sweep and differ only in how they observe it -- "
        "one infers the lock's lifetime from whether a concurrent reader timed out, the other reads "
        "the acquire/release events off uprobes -- so the defect that must break them is one defect, "
        "and the edits are shared by reference rather than restated. It earns its own entry because "
        "discriminate.sh maps one mutation to one guard, and because a guard without a mutation of "
        "its own is unverified no matter how well its twin is covered.",
        MAINTAIN_NO_COMMITS_EDITS,
    ),
    "maintain_no_lock_timeout_after_retain": (
        "bench/maintain_regrain_lock_timeout.sh",
        "Pre-#514 maintain: the retain boundary's COMMIT is not followed by the set_config that puts "
        "lock_timeout back, so the auto-regrain block after it runs under the session default (0: wait "
        "forever). Its swap's DETACH takes ACCESS EXCLUSIVE on the parent; a writer holding one row in "
        "the source keeps that request queued for its whole transaction, every read of the parent "
        "queues behind the request, and the tick swaps when the writer lets go instead of logging "
        "skip_regrain and retrying. Removes only that one line: the other four boundaries keep their "
        "re-apply, so the mutant is the shipped procedure exactly and nothing else about the tick "
        "moves. Anchored on the line's own #514 marker, which is what makes it unique among the "
        "identical re-applies after the write-block and archive boundaries.",
        [("  perform set_config('lock_timeout', '200ms', true);   -- #514: the auto-regrain below is a step too\n",
          "", 1)],
    ),
    "restore_fk_inline_validate": (
        "bench/restore_fk_lock.sh",
        "Pre-#265 restore_incoming_fks: the VALIDATE runs inline, in the same transaction as the ADD, so "
        "the ADD's SHARE ROW EXCLUSIVE on the managed parent is held across an O(referencing table) scan.",
        [(RESTORE_MARKER, RESTORE_INLINE, 1)],
    ),
    "retire_inline_detach": (
        "bench/retire_detach_lock.sh",
        "The tempting wrong fix for #268: retire() detaches the referenced partition ITSELF, with a "
        "plain (non-concurrent) DETACH. Functionally identical -- the partition ends up detached and "
        "then dropped, and every behavioural test still passes -- but it holds ACCESS EXCLUSIVE on the "
        "MANAGED PARENT for the whole O(referencing table) scan, so reads of the parent die with "
        "55P03. This is the defect the dispatch-to-cron machinery exists to avoid, and nothing but a "
        "lock probe can tell the two apart.",
        [("      v_reason := pgpm._dispatch_detach(p_parent, v_child);\n",
          "      execute format('alter table %s detach partition %I.%I',\n"
          "                     p_parent::text, v_nsp, p_child);\n"
          "      v_reason := null;\n", 1)],
    ),
    "retire_drop_unanchored_name": (
        "bench/retire_detach_substitution.sh",
        "Pre-#407 retire(): nothing checks that the partition's NAME still resolves to the relation "
        "whose detach was dispatched. Deleting the identity check is the whole defect, because the "
        "rest of the function already acts on p_child by name -- the retirement is carried on, and "
        "completed with a DROP, against whatever answers to that name when the tick comes round. "
        "The detach travels to pg_cron as text and is re-resolved in another session a tick or more "
        "later, with no lock held across the gap, so a relation substituted under the name in "
        "between is detached and then destroyed with no error anywhere. retiring_oid is left in "
        "place deliberately: the defect being modelled is 'the anchor is not consulted', not 'the "
        "anchor does not exist', and a mutant that dropped the column too would fail the test file "
        "on its liveness witnesses and look like a catch for the wrong reason.",
        [(RETIRE_IDENTITY_BLOCK, "", 1)],
    ),
    "retire_drop_child_oid_ignored": (
        "bench/retire_identity_unreferenced.sh",
        "Pre-#428 retire(): the identity check consults retiring_oid ONLY. That anchor is set inside "
        "the `if v_referenced` branch, as retire() dispatches a concurrent detach, so it is null for "
        "every partition nothing points a foreign key at -- which is the ordinary one-step path, and "
        "the one whose bare `drop table schema.child` has nothing else between it and the write "
        "block. Narrows the entry condition back to retiring_oid and removes the child_oid arm of "
        "the reason string, which together is exactly what #428 widened. child_oid itself is left in "
        "place: the defect being modelled is 'the anchor is not consulted on this path', not 'the "
        "anchor does not exist', and a mutant that dropped the column would fail the test file on "
        "its liveness witnesses and look like a catch for the wrong reason. Breaks part A of "
        "tests/103; part B still passes, which is what tells the two mutations apart.",
        [("  if r.retiring_oid is not null or r.child_oid is not null then\n",
          "  if r.retiring_oid is not null then\n", 1),
         ("           then format('not the oid %s this retirement dispatched a detach for', "
          "r.retiring_oid) end,\n"
          "      case when r.child_oid is not null and v_now::oid is distinct from r.child_oid\n"
          "           then format('not the oid %s recorded for this partition when it was created', "
          "r.child_oid) end);\n",
          "           then format('not the oid %s this retirement dispatched a detach for', "
          "r.retiring_oid) end);\n", 1)],
    ),
    "retire_identity_coalesced_anchors": (
        "bench/retire_identity_unreferenced.sh",
        "The plausible-but-wrong #428: fall back from retiring_oid to child_oid rather than checking "
        "both. It closes the gap #428 was filed for, so part A of tests/103 still passes -- which is "
        "the point of having this mutation as well as the other one. What it misses is that "
        "retiring_oid is ITSELF resolved by name, out of pg_inherits at dispatch time, so a "
        "substitution that landed before the dispatch is adopted BY that anchor; coalesce then picks "
        "the adopted one, the comparison passes forever, and the one anchor that still remembers the "
        "original is never consulted. Part B constructs exactly that state and must FAIL here. The "
        "reason string deliberately keeps the child_oid wording so part A's message assertion still "
        "passes: this mutant must be caught by part B alone, not by a message mismatch elsewhere.",
        [(RETIRE_IDENTITY_BLOCK,
          "  if coalesce(r.retiring_oid, r.child_oid) is not null then\n"
          "    v_now := to_regclass(format('%I.%I', v_nsp, p_child));\n"
          "    if v_now::oid is distinct from coalesce(r.retiring_oid, r.child_oid) then\n"
          "      if r.retiring_oid is not null then\n"
          "        perform pgpm._idle_detach_job(pgpm._detach_cmd(p_parent, v_nsp, p_child));\n"
          "      end if;\n"
          "      insert into pgpm.log (parent_table, action, lo, hi, method)\n"
          "        values (p_parent, 'fail_retain_identity', r.lo, r.hi,\n"
          "                format('%I.%I is oid %s now, not the oid %s recorded for this partition "
          "when it was created; refusing to detach or drop it',\n"
          "                       v_nsp, p_child, coalesce(v_now::oid::text, 'nothing'), "
          "coalesce(r.retiring_oid, r.child_oid)));\n"
          "      return false;\n"
          "    end if;\n"
          "  end if;\n", 1)],
    ),
    "archive_step_unanchored_name": (
        "bench/archive_identity_substitution.sh",
        "Pre-#421 _archive_step(): nothing checks that the candidate's NAME still resolves to the "
        "relation pgpm.part recorded for it. Deleting the identity check is the whole defect, "
        "because every step after it already acts on child_name by name -- _next_archive_chunk "
        "sizes the chunk from whatever answers to it, and the ledger row that follows records a "
        "coverage claim for a range those rows never came from. That ledger is retire()'s drop "
        "precondition via _archive_fully_covered, so the bogus claim does not merely put a wrong "
        "object in the bucket: it opens the gate and the next retain() tick DROPs the relation "
        "holding the name. No race is needed -- a rename is enough. child_oid and its select-list "
        "entry are left in place deliberately: the defect being modelled is 'the anchor is not "
        "consulted', not 'the anchor does not exist', and a mutant that dropped the column too "
        "would fail the test file on its liveness witnesses and look like a catch for the wrong "
        "reason.",
        [("      v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));\n"
          "      if r.child_oid is not null and v_now::oid is distinct from r.child_oid then\n"
          "        insert into pgpm.log (parent_table, action, lo, hi, method)\n"
          "          values (p_parent, 'fail_archive_identity', r.lo, r.hi,\n"
          "                  format('%I.%I is oid %s now, not the oid %s recorded for this "
          "partition; refusing to archive it',\n"
          "                         v_nsp, r.child_name, coalesce(v_now::oid::text, 'nothing'), "
          "r.child_oid));\n"
          "        continue;\n"
          "      end if;\n\n", "", 1)],
    ),
    "write_block_unanchored_name": (
        "bench/write_block_identity.sh",
        "Pre-#429 _install_write_block(): it resolves p_child by NAME and issues CREATE TRIGGER "
        "against whatever comes back, with no assertion that the relation is the partition "
        "pgpm.part recorded. _enforce_write_blocks calls it for every attached child on every "
        "maintain() tick, so a relation that has taken a partition's name gets a pgpm trigger "
        "rejecting all of its INSERTs, UPDATEs and DELETEs -- DDL on a table pgpm was never handed, "
        "recorded nowhere in its own catalog. It is also what MAKES a substituted name an archive "
        "candidate, since _archive_step gates on _is_write_blocked, so this is upstream of #421's "
        "own refusal rather than redundant with it. Deletes the check only; child_oid stays, "
        "because the defect being modelled is 'the anchor is not consulted', not 'the anchor does "
        "not exist'.",
        [(WRITE_BLOCK_IDENTITY_BLOCK, "", 1)],
    ),
    "write_block_refuses_missing_relation": (
        "bench/write_block_identity.sh",
        "The tempting consistency fix: widen _install_write_block's check to `is distinct from`, so "
        "it also fires when the name resolves to NOTHING, matching retire() and _archive_step. It "
        "is wrong here and the asymmetry is deliberate. Those two fire on null because the next "
        "thing either would do is act on the relation; this one has no wrong relation to act on, "
        "and the null case already has accurate, tested handling -- the ::regclass cast raises, "
        "_enforce_write_blocks' per-child handler catches it, and skip_write_block carries the real "
        "error (issue #360). Making this fire instead reports 'something else holds the name' about "
        "a partition that was simply dropped, AND stops tests/94's poison raising at all, which "
        "quietly retires the loop-isolation coverage that whole file exists for. Part C of "
        "tests/104 is what catches it.",
        [("    if v_now is not null and v_now::oid <> r.child_oid then\n",
          "    if v_now::oid is distinct from r.child_oid then\n", 1),
         ("                       v_nsp, p_child, v_now::oid::text, r.child_oid));\n",
          "                       v_nsp, p_child, coalesce(v_now::oid::text, 'nothing'), "
          "r.child_oid));\n", 1)],
    ),
    "write_block_remove_anchored": (
        "bench/write_block_identity.sh",
        "The symmetrical-looking mistake #429 deliberately did NOT make: anchoring "
        "_remove_write_block as well as the install. It reads as consistency -- pgpm should not "
        "touch a relation it has not identified -- but the two directions are not equivalent. A "
        "pre-#429 pgpm installed this trigger on whatever held the name, so an install upgrading "
        "into the fix can already have one stranded on a relation it never managed, rejecting every "
        "write to it; an anchored removal then refuses to touch the very trigger pgpm itself "
        "wrongly created, and that relation stays read-only permanently with no pgpm-side recovery. "
        "Part B of tests/104 is the only thing that catches this, which is why it exists.",
        [(REMOVE_WRITE_BLOCK_FN,
          "create or replace function pgpm._remove_write_block(p_parent regclass, p_child name)\n"
          "returns void language plpgsql as $$\n"
          "declare v_nsp name; v_oid oid;\n"
          "begin\n"
          "  v_nsp := pgpm._child_nsp(p_parent, p_child);   -- #727: the partition's own schema, not the parent's\n"
          "  select p.child_oid into v_oid from pgpm.part p\n"
          "   where p.parent_table = p_parent and p.child_name = p_child;\n"
          "  if v_oid is not null and to_regclass(format('%I.%I', v_nsp, p_child))::oid is distinct "
          "from v_oid then\n"
          "    return;\n"
          "  end if;\n"
          "  execute format('drop trigger if exists pgpm_write_block on %I.%I', v_nsp, p_child);\n"
          "end;\n"
          "$$;\n", 1)],
    ),
    "coverage_reset_by_name": (
        "bench/coverage_reset_identity.sh",
        "Pre-#518 _enforce_write_blocks: 'coverage found without its block is discarded' (#452) is "
        "decided by NAME, _is_write_blocked(child_name), before and outside the #429 identity check "
        "that _install_write_block makes further down the same loop body. A relation squatting on a "
        "partition's name has no trigger, so the tick reads the REAL partition's coverage as unguarded "
        "and deletes its pgpm.archive_ledger rows (archive_coverage_reset) in the same tick that logs "
        "fail_write_block_identity for the same child; the rows described a relation still attached, "
        "still blocked and unchanged, and archiving starts over from lo once the name is sorted out. "
        "The identity predicate is left computed and unused, deliberately: the defect being modelled is "
        "'the anchor is not consulted', not 'the anchor does not exist'. Part A of tests/129 is what "
        "catches it, by the ledger row's identity and by which ids the strategy is handed afterwards.",
        [("      if v_chunks > 0 and not v_substituted and not pgpm._is_write_blocked(p_parent, r.child_name) then\n",
          "      if v_chunks > 0 and not pgpm._is_write_blocked(p_parent, r.child_name) then\n", 1)],
    ),
    "coverage_reset_unanchored_is_mismatch": (
        "bench/coverage_reset_identity.sh",
        "The tempting consistency fix for #518's predicate: `is distinct from`, the form retire() and "
        "_archive_step use, instead of _install_write_block's `is not null and ... <>`. It reads a null "
        "child_oid as a substitution, so on an install upgrading into identity anchoring every partition "
        "created before the upgrade keeps coverage found without its block -- coverage nothing vouches "
        "for, the exact #452 defect, for exactly the partitions an upgrade has nothing to compare against. "
        "Part C of tests/129 is the only thing that catches it, which is why that part exists.",
        [("      v_substituted := r.child_oid is not null and v_now is not null and v_now::oid <> r.child_oid;\n",
          "      v_substituted := v_now::oid is distinct from r.child_oid;\n", 1)],
    ),
    "retire_trusts_unguarded_coverage": (
        "bench/retire_unguarded_coverage.sh",
        "Pre-#564 retire(): no discard of coverage found without its write block. retire() is documented "
        "as independently callable and only maintain() is guaranteed to have run _enforce_write_blocks "
        "(which does discard it, #452) first, so a direct caller reaches a fully archived child whose "
        "trigger was dropped by hand, retire() re-installs the block, reads the stale watermark as full "
        "coverage and DROPs the child with a row written while it was unblocked that no strategy was "
        "ever handed. Removes the whole discard block, comment included, so the mutant is the pre-fix "
        "function exactly. Part A of tests/130 catches it, by which rows survive and which ids the "
        "strategy is handed before the drop.",
        [(re.compile(r"^  -- COVERAGE FOUND WITHOUT ITS BLOCK IS DISCARDED HERE TOO \(issue #564\).*?\n  end if;\n\n"
                     r"(?=  perform pgpm\._install_write_block\(p_parent, p_child\);\n)",
                     re.MULTILINE | re.DOTALL), "", 1)],
    ),
    "retire_coverage_check_after_block": (
        "bench/retire_unguarded_coverage.sh",
        "The tempting reordering of #564's discard: install the write block first, then ask whether "
        "coverage exists without one. The block is always on by the time the question is asked, so "
        "nothing is ever discarded and the stale watermark licenses the drop exactly as before the fix. "
        "Adds one install ahead of the ledger read (the original install below stays, and is idempotent), "
        "which is the smallest edit that makes that mistake. Part A of tests/130 catches it.",
        [("  select count(*) into v_chunks from pgpm.archive_ledger\n"
          "   where parent_table = p_parent and child_name = p_child;\n",
          "  perform pgpm._install_write_block(p_parent, p_child);\n"
          "  select count(*) into v_chunks from pgpm.archive_ledger\n"
          "   where parent_table = p_parent and child_name = p_child;\n", 1)],
    ),
    "hypertable_cutover_unverified_source": (
        "bench/hypertable_cutover_identity.sh",
        "Pre-#422 from_hypertable_cutover(): it locks the SOURCE by the name it resolved at the top "
        "and never re-resolves it. LOCK TABLE freezes whatever a name means at lock time, so locking "
        "by name is only half the standard pattern; a rename landing in the window is acquired "
        "cleanly and the procedure goes on to DROP TABLE a relation it never identified. The window "
        "that matters is the index pre-builds -- deliberately outside the lock so the outage stays "
        "brief, and therefore the longest stretch in it -- which is exactly where part A of "
        "tests/timescale/db/17 lands its substitution. Restores the by-name lock verbatim; the "
        "destination half is left in place so a failure names which half went missing.",
        [(HT_CUTOVER_SOURCE_VERIFY,
          "  execute format('lock table %I.%I in access exclusive mode', v_nsp, v_rel);\n\n", 1)],
    ),
    "hypertable_cutover_unverified_dest": (
        "bench/hypertable_cutover_identity.sh",
        "The other half of the same swap: the destination is existence-checked at the top of the "
        "cutover and then renamed INTO the source's name at the bottom, with nothing verifying it is "
        "still the relation that check found -- and nothing locking it until the first index "
        "pre-build, which the pre-drain's per-batch commits release anyway. An unverified "
        "destination does not merely get dropped, it BECOMES the production table. Deletes only the "
        "destination lock-and-verify, leaving the source half, so part A still passes and only part "
        "B of tests/timescale/db/17 catches this.",
        [(HT_CUTOVER_DEST_VERIFY, "", 1)],
    ),
    "hypertable_catchup_strict_watermark": (
        "bench/hypertable_late_appends.sh",
        "Pre-#460 append-only catch-up on a KEYED table: control strictly greater than the copy watermark, "
        "no key anti-join. A row that lands during the online window with a control value EXACTLY equal to "
        "max(control) in the destination is never copied; the strict bound exists to avoid duplicating the "
        "copied row already at that value, and it throws the late one out with it. Sends the keyed branch "
        "down the keyless path (`if false`), which IS the old catch-up for every table, and leaves the "
        "conservation check in place. So in part A of tests/timescale/db/20 the check refuses the swap "
        "that part expects to SUCCEED (a raw ERROR, and the table is still a hypertable: 241 rows would "
        "have gone forward against 242), and part B's refusal names 241 where 242 is asserted. It fails "
        "on the lost row, never on a missing refusal -- that is the other mutation's job.",
        [(HT_CATCHUP_KEYED_BRANCH,
          "    if false then   -- MUTANT: the pre-#460 strict > on every table, keyed or not\n"
          "      -- Materialise the tail first", 1)],
    ),
    "hypertable_cutover_no_conservation": (
        "bench/hypertable_late_appends.sh",
        "Pre-#460 from_hypertable_cutover(): nothing under the lock compares the source with the "
        "destination. Rows that arrived during the online window BELOW the watermark (out-of-order "
        "appends, backfills, the normal IoT shape) are invisible to the append-only catch-up, and the DROP "
        "TABLE went ahead on a destination that was short, with no error and no log row. Deletes the "
        "count comparison whole and leaves the keyed catch-up in place, so part A of "
        "tests/timescale/db/20 still passes and only parts B and C catch this -- through the refusal "
        "message, which is the only thing that separates a refusal from a cutover that wrongly ran on to "
        "its COMMIT inside throws_like.",
        [(HT_CUTOVER_CONSERVATION, "", 1)],
    ),
    "hypertable_cutover_conservation_by_count": (
        "bench/hypertable_cutover_conservation.sh",
        "Pre-#653 from_hypertable_cutover(): the conservation check compares count(*) of the source with "
        "the destination's carried-in count and nothing else, so compensating changes during the online "
        "window pass it. A copied row deleted plus a row appended behind the watermark left 72 = 72, the "
        "swap went ahead, the late row was lost and the deleted row came back; an update of a copied row, "
        "or one that bypassed the capture trigger, changes no count at all. Drops the fingerprint half of "
        "the comparison and leaves the count half and its message, so tests/timescale/db/20 (whose "
        "shortfalls are all count-visible) still passes and only parts A, B and C of "
        "tests/timescale/db/22 catch this, through the refusal message that names equal counts.",
        [("  if v_src_n <> v_dest_n or v_src_h <> v_dest_h then\n",
          "  if v_src_n <> v_dest_n then   -- MUTANT: the pre-#653 count-only comparison\n", 1)],
    ),
    "hypertable_swap_fk_record_after_handoff": (
        "bench/hypertable_swap_order.sh",
        "Pre-#563 from_hypertable_cutover(): the swap drops each incoming foreign key and commits, and the "
        "key's definition is held only in a plpgsql local until transmute returns. Deletes the in-swap "
        "pgpm.dropped_fk and drop_incoming_fk log inserts, so when the handoff refuses (the guard's "
        "carried index needs a name a squatter holds) the key is gone from both "
        "referencing tables and written nowhere, and the operator's re-run of transmute has nothing to "
        "restore. The identity position is left in place, so only the record assertions fail.",
        [(HT_SWAP_FK_RECORD, "", 1)],
    ),
    "hypertable_swap_identity_from_one": (
        "bench/hypertable_swap_order.sh",
        "Pre-#563 from_hypertable_cutover(): the swap re-adds identity on the plain table, which starts "
        "its sequence at 1, and applies the source sequence's position only after transmute returns. "
        "Deletes the in-swap setval, so when the handoff refuses the plain table hands out id 1 over "
        "rows that already hold 1, 2 and 3 (a hypertable's key includes the time column, so nothing "
        "rejects the duplicate); the guard's source sequence sits at 8 against max(id) 3, so neither "
        "a restart (1) nor a reseed past max(id) (4) reads as the preserved position.",
        [(HT_SWAP_IDENTITY_POSITION, "    end loop;\n  end if;\n", 1)],
    ),
    "hypertable_cutover_identity_by_default": (
        "bench/hypertable_cutover_identity_options.sh",
        "Pre-#640 from_hypertable_cutover(): the swap re-adds every identity column GENERATED BY DEFAULT "
        "with the default sequence options, whatever the source's were. tests/timescale/db/27's ALWAYS "
        "column then accepts a supplied id, its INCREMENT BY 2 sequence steps by 1, and its descending BY "
        "DEFAULT column (INCREMENT BY -3, MINVALUE -9000, MAXVALUE -1) comes back ascending from 1. Replaces "
        "the kind and the options in the re-add only; the captured position and its reseed stay, so what "
        "fails is the kind, the options and the lattice, not the capture.",
        [(HT_SWAP_IDENTITY_KIND_OPTS,
          "                     'by default', '');   -- MUTANT: pre-#640, BY DEFAULT with default options\n", 1)],
    ),
    "hypertable_cutover_shape_unchecked_up_front": (
        "bench/hypertable_cutover_shape.sh",
        "#738 without its up-front check: the cutover compares the copy's shape with the source's only under "
        "its lock. A dropped column, a changed default and an added CHECK are still refused there, by the "
        "same message, but a column ADDED to the source since the copy reaches the pre-lock reads of the "
        "copy first (the pre-drain, the conservation baseline), which name the column the copy lacks and "
        "die raw (column \"note\" does not exist). PART A's assertion D (tests/timescale/db/28) "
        "pins the named refusal and fails; PART B, the under-lock window, still passes.",
        [(HT_SHAPE_UP_FRONT,
          "  -- before the pre-drain and the index pre-builds spend anything. Asked again under the lock below.\n", 1)],
    ),
    "hypertable_cutover_shape_unchecked_under_lock": (
        "bench/hypertable_cutover_shape.sh",
        "Pre-#738 from_hypertable_cutover() for the window the up-front check cannot see: nothing compares "
        "the copy's shape with the source's under the lock, so DDL that lands while the cutover prepares "
        "(after the up-front check, before the LOCK TABLE) is reverted by the swap. PART B lands a new "
        "default and a new CHECK on the source while the cutover is queued on the copy, and the mutant "
        "converts the table with the copy's old default and no CHECK; PART A still passes, its DDL being "
        "refused up front.",
        [(HT_SHAPE_UNDER_LOCK,
          "  -- in between. Both relations are frozen now, and the column list read at the top must still describe both.\n", 1)],
    ),
    "hypertable_cutover_access_not_carried": (
        "bench/hypertable_cutover_carries_access.sh",
        "Pre-#787 from_hypertable_cutover(): the swap renames the LIKE-built copy into the hypertable's place "
        "and puts nothing back on it, so transmute finds no grants, no row-level security, no policies, no "
        "comment and no triggers to carry, and every grantee is refused once the migration completes. "
        "Deletes the replay of the captured statements and leaves the capture; tests/timescale/db/33's "
        "catalog comparison, its privilege checks and its reads as each role fail.",
        [("""  foreach v_stmt in array v_carried_ddl loop
    execute v_stmt;
  end loop;
""", "  -- MUTANT: the captured statements are not replayed\n", 1)],
    ),
    "hypertable_cutover_carries_insert_blocker": (
        "bench/hypertable_cutover_carries_access.sh",
        "#787 replaying every trigger on the hypertable: TimescaleDB's own ts_insert_blocker (its function "
        "lives in _timescaledb_functions) is created on the plain table too, and transmute carries it onto "
        "the parent. tests/timescale/db/33's count of the parent's own triggers fails on the extra one.",
        [("       and fn.nspname not like '\\_timescaledb%'\n", "", 1)],
    ),
    "hypertable_cutover_carries_capture": (
        "bench/hypertable_cutover_carries_access.sh",
        "#787 replaying the tracked copy's change-capture trigger: the swap dropped its function with the "
        "source, so the replay dies in the swap transaction and the cutover of tests/timescale/db/33's "
        "tracked hypertable fails on a raw error, leaving it a hypertable. Every one of the carry's ways of "
        "knowing the capture is removed: pgpm.scratch's record and the proof of a 0.6.0 capture (#969), and "
        "the delta's horizon comment (#842).",
        [(HT_CAPTURE_ARM_RECORD + HT_CAPTURE_ARM_PROOF + HT_CAPTURE_ARM_COMMENT, "", 1)],
    ),
    "hypertable_carry_capture_by_name": (
        "bench/hypertable_carry_capture_by_record.sh",
        "Pre-#842 _from_hypertable_carried_ddl: the module's capture trigger is left out only under the name "
        "derived from the hypertable's CURRENT schema and relname, so an abandoned tracking copy's trigger, "
        "named for the table before a SET SCHEMA or RENAME, is carried onto the copy and cloned onto every "
        "partition. tests/timescale/db/42's parents and partitions fire the stale capture and its deltas grow.",
        [(HT_CAPTURE_ARM_COMMENT, "", 1)],
    ),
    "hypertable_carry_capture_unrecorded": (
        "bench/scratch_relations.sh",
        "#842 and #955 trusting the records alone: a capture pgpm 0.6.0 minted carries neither pgpm.scratch's "
        "record nor the horizon comment, and it is still on a hypertable whose abandoned copy the operator "
        "dropped to re-run the migration; an untracked migration then carries its trigger onto the table and "
        "every partition, logging every write into a delta nothing drains. The proof-gated arm (#969) removed. "
        "tests/timescale/db/49 stage D (D3) catches it. tests/timescale/db/42's u42, which guarded this before "
        "the record existed, is recorded now and needs no proof.",
        [(HT_CAPTURE_ARM_PROOF, "", 1)],
    ),
    "hypertable_swap_drops_publications": (
        "bench/hypertable_carry_publications_replica_identity.sh",
        "Pre-#816 from_hypertable swap: the hypertable's publication membership goes with the DROP and the "
        "LIKE copy is in no publication, so transmute carries none onto the parent and every subscriber "
        "silently stops receiving the table. tests/timescale/db/43's membership assertions fail.",
        [("""     where pr.prrelid = p_hypertable
     order by p.pubname
""", """     where pr.prrelid = p_hypertable and false   -- MUTANT: no membership is carried
     order by p.pubname
""", 1)],
    ),
    "hypertable_swap_drops_replica_identity": (
        "bench/hypertable_carry_publications_replica_identity.sh",
        "Pre-#816 from_hypertable swap: the LIKE copy has the DEFAULT replica identity and nothing puts the "
        "hypertable's on it, so transmute carries DEFAULT onto the parent and every partition, and a keyless "
        "FULL table under a publication of updates refuses every UPDATE and DELETE with 55000. "
        "tests/timescale/db/43's identity assertions and its UPDATE and DELETE fail.",
        [("""  select c.relreplident into v_ri from pg_class c where c.oid = p_hypertable;
""", """  v_ri := 'd';   -- MUTANT: the replica identity is not carried
""", 1)],
    ),
    "hypertable_publications_unchecked_up_front": (
        "bench/hypertable_carry_publications_replica_identity.sh",
        "#816's carry without the preflight's check: a membership with a row filter in a publication with "
        "publish_via_partition_root = false is carried onto the copy and refused by transmute only after the "
        "swap has dropped the hypertable. tests/timescale/db/43's from_hypertable refusal is not raised (the "
        "call reaches the copy's first COMMIT and dies 2D000 there instead).",
        [("""  -- (3b3) a publication membership transmute could not carry onto the parent (issue #816). See
  -- _from_hypertable_check_publications.
  perform pgpm._from_hypertable_check_publications(p_hypertable);
""", "  -- MUTANT: the preflight does not ask for the publication shape transmute refuses\n", 1)],
    ),
    "hypertable_cutover_publications_unchecked": (
        "bench/hypertable_carry_publications_replica_identity.sh",
        "#816's carry without the cutover's own check under its lock: a filtered membership added after the "
        "copy reaches the swap, which commits, and transmute refuses after it. tests/timescale/db/43's "
        "cutover refusal is not raised (the call dies 2D000 at the swap's COMMIT instead).",
        [("""  -- cutover prepared is refused here with the source whole. See _from_hypertable_check_publications.
  perform pgpm._from_hypertable_check_publications(p_hypertable);
""", "  -- MUTANT: the cutover does not ask for the publication shape under its lock\n", 1)],
    ),
    "hypertable_key_index_by_name": (
        "bench/hypertable_key_index_on_destination.sh",
        "Pre-#768 (F6-09) from_hypertable_cutover: a key's index build is skipped whenever ANY relation holds "
        "its temp name, so after an abandoned tracking copy and a RENAME of the hypertable (whose key keeps "
        "its name) the stale copy's index is taken for the key's and the swap fails adopting it, after the "
        "whole copy. tests/timescale/db/44's migration of the renamed table fails.",
        [(HT_CUTOVER_KEY_TMP_BLOCK, """    v_tmp := pgpm._from_hypertable_tmp_name(k.conname, k.conindid);
    if to_regclass(format('%I.%I', v_nsp, v_tmp)) is null then   -- MUTANT: by name, anywhere in the schema
      execute pgpm._from_hypertable_index_ddl(k.conindid, v_tmp, v_nsp, v_dest);
    end if;
""", 1)],
    ),
    "hypertable_acl_carry_unreset": (
        "bench/hypertable_grant_carry_resets_acl.sh",
        "Pre-#838 from_hypertable_cutover(): the swap replays the hypertable's grants onto the copy and does "
        "not reset the copy's ACL first, so what the migrating role's ALTER DEFAULT PRIVILEGES gave the copy "
        "at the LIKE stays, and transmute carries it onto the parent. Drops the first of _acl_carry_ddl's "
        "statements, the reset, and keeps the grants; tests/timescale/db/38 parts A (the copy and the "
        "parent) and B fail.",
        [("  v_ddl := v_ddl || pgpm._acl_carry_ddl(p_hypertable, v_tbl_q);\n",
          "  v_ddl := v_ddl || (pgpm._acl_carry_ddl(p_hypertable, v_tbl_q))[2:];   -- MUTANT: no reset\n", 1)],
    ),
    "hypertable_key_unchecked": (
        "bench/hypertable_handoff_refusals.sh",
        "Pre-#792 pgpm_hypertable: nothing asks for a bare unique index as the key until transmute does, after "
        "the cutover's swap has committed, so the hypertable is dropped and the table left plain and "
        "unmanaged. _from_hypertable_check_key asks nothing; part A of tests/timescale/db/34 fails where the "
        "preflight, from_hypertable, the copy and the cutover are pinned to refuse it by name.",
        [("""  v_idx := pgpm._transmute_bare_unique(p_hypertable, p_control);
  if v_idx is null then return; end if;""",
          """  v_idx := null;   -- MUTANT: the bare unique index is not asked for
  if v_idx is null then return; end if;""", 1)],
    ),
    "hypertable_cutover_key_unchecked_under_lock": (
        "bench/hypertable_handoff_refusals.sh",
        "#792 without the cutover's own key check: a destination left by an older version's copy, or made by "
        "hand, reaches the swap without the preflight having run, and a bare unique index goes through to "
        "transmute's refusal after it. Only tests/timescale/db/34's cutover assertion fails (the 2D000 of "
        "the pre-drain-free cutover's swap COMMIT where the refusal is pinned).",
        [("""  perform pgpm._from_hypertable_check_key(p_hypertable, p_control);
  perform pgpm._from_hypertable_check_frontier(p_hypertable, p_control, p_interval, p_force_frontier);
  if v_track then""",
          """  perform pgpm._from_hypertable_check_frontier(p_hypertable, p_control, p_interval, p_force_frontier);
  if v_track then""", 1)],
    ),
    "hypertable_frontier_unchecked_up_front": (
        "bench/hypertable_handoff_refusals.sh",
        "#792 without from_hypertable's up-front frontier check: the cutover still refuses under its lock, but "
        "only after the whole online copy. tests/timescale/db/34's two from_hypertable refusals, pinned to "
        "come before the copy, die on the copy's first COMMIT inside throws_like instead.",
        [("""  perform pgpm._from_hypertable_check_frontier(p_hypertable, p_control, p_interval, p_force_frontier);
  call pgpm.from_hypertable_copy(""",
          """  call pgpm.from_hypertable_copy(""", 1)],
    ),
    "hypertable_cutover_frontier_unchecked": (
        "bench/hypertable_handoff_refusals.sh",
        "Pre-#792 from_hypertable_cutover(): nothing asks transmute's frontier bound before the swap, so a "
        "hypertable whose newest row leads the clock by more than a step and an hour is dropped and "
        "transmute refuses the plain table. Deletes the cutover's check under the lock; tests/timescale/db/34's "
        "cutover refusal is pinned and fails on the 2D000 of the swap's COMMIT.",
        [("""  perform pgpm._from_hypertable_check_frontier(p_hypertable, p_control, p_interval, p_force_frontier);
  if v_track then""",
          """  if v_track then""", 1)],
    ),
    "hypertable_cutover_force_frontier_dropped": (
        "bench/hypertable_handoff_refusals.sh",
        "#792 with p_force_frontier accepted by the cutover but not passed to transmute: the cutover skips its "
        "own check, swaps, and transmute refuses the frontier the operator accepted, leaving the plain table. "
        "tests/timescale/db/34's forced cutover, and the forced one-shot migration that reaches it, fail on "
        "raw errors and on their by-value assertions.",
        [("p_lock_timeout => p_lock_timeout, p_force_frontier => p_force_frontier);",
          "p_lock_timeout => p_lock_timeout);   -- MUTANT: the override is not passed on", 1)],
    ),
    "hypertable_force_frontier_not_to_cutover": (
        "bench/hypertable_handoff_refusals.sh",
        "#792 with p_force_frontier accepted by from_hypertable but not passed to the cutover, which then "
        "refuses the frontier under its lock after the whole copy. tests/timescale/db/34's forced one-shot "
        "migration fails on a raw error and its by-value assertion after it.",
        [("""                                    p_drain_batch, p_anchor, p_paused, p_predrain, p_lock_timeout,
                                    p_force_frontier);""",
          """                                    p_drain_batch, p_anchor, p_paused, p_predrain, p_lock_timeout);""", 1)],
    ),
    "hypertable_cutover_untracked_unchecked": (
        "bench/hypertable_replica_capture.sh",
        "Pre-#654 from_hypertable_cutover(): on the tracking path nothing but the row count compares the "
        "two sides, and the capture trigger is origin-only because TimescaleDB refuses ENABLE ALWAYS on a "
        "hypertable and its chunks. An UPDATE made under session_replication_role = replica during the "
        "online window never reaches the delta and changes no count, so the swap installs the copy's stale "
        "row over it. Disables the refusal by its condition and leaves the scan, the horizon and the count "
        "check in place, so parts A and B of tests/timescale/db/25 fail through their refusal messages "
        "(the cutover runs on to its COMMIT inside throws_like) and parts C and D still pass.",
        [(HT_CUTOVER_UNTRACKED_REFUSAL,
          "  if false then   -- MUTANT: the pre-#654 cutover, count-only on the tracking path\n", 1)],
    ),
    "hypertable_cutover_no_horizon_trusted": (
        "bench/hypertable_replica_capture.sh",
        "The untracked-write check with its anchor missing: a delta built before #654 carries no recorded "
        "horizon, and reading that absence as 'nothing to verify' rather than 'verify every row' puts the "
        "silent revert back for exactly the copies taken before an upgrade. Turns the fallback predicate "
        "from true into false, so part A of tests/timescale/db/25 (a horizon recorded) still refuses and "
        "only part B (the horizon removed) fails, through its refusal message.",
        [(HT_CUTOVER_NO_HORIZON_FALLBACK,
          "      v_fresh := 'false';   -- MUTANT: no horizon read as nothing to check\n", 1)],
    ),
    "hypertable_preflight_no_exclusion_check": (
        "bench/hypertable_exclusion_refusal.sh",
        "Pre-#675 from_hypertable_preflight(): nothing refuses an EXCLUDE constraint, and nothing in the "
        "migration carries one (CREATE TABLE ... LIKE takes CHECK and NOT NULL only, the cutover re-adds "
        "only p and u keys and skips constraint-backed indexes), so the migrated table accepts the rows "
        "the hypertable rejected. Deletes the preflight's call, leaving the cutover's own, so the "
        "preflight, from_hypertable and from_hypertable_copy assertions of tests/timescale/db/26 fail "
        "(no exception, or the 2D000 of a first COMMIT, where the message naming both constraints is "
        "pinned) and the cutover's still passes.",
        [("  perform pgpm._from_hypertable_check_exclusion(p_hypertable);\n\n  -- (4) an outgoing FK",
          "\n  -- (4) an outgoing FK", 1)],
    ),
    "hypertable_cutover_no_exclusion_check": (
        "bench/hypertable_cutover_exclusion_window.sh",
        "Pre-#675 from_hypertable_cutover(): the irreversible phase re-checks the dimension but not an "
        "EXCLUDE constraint up front. Deletes the cutover's up-front call only. Since #841 the call under "
        "the lock still refuses before the swap, so tests/timescale/db/26's pre-drain-free cutover still "
        "passes; what is lost is the refusal BEFORE the pre-drain commits anything, which PART A of the "
        "guard (tests/timescale/db/41: four rows past the watermark, a one-row batch) pins: the pre-drain "
        "reaches its first COMMIT inside throws_like and dies with 2D000 where the refusal naming the "
        "constraint is pinned.",
        [("  perform pgpm._from_hypertable_check_exclusion(p_hypertable);\n  -- Keep the OID this check resolved",
          "  -- Keep the OID this check resolved", 1)],
    ),
    "hypertable_cutover_exclusion_unchecked_under_lock": (
        "bench/hypertable_cutover_exclusion_window.sh",
        "Pre-#841 from_hypertable_cutover(): the exclusion check is asked up front only, not again under "
        "the ACCESS EXCLUSIVE, so an EXCLUDE constraint added while the cutover prepares (after the "
        "up-front check, before the LOCK TABLE) is dropped by the swap. PART B adds one while the cutover "
        "is queued on the copy, and the mutant converts the table without it; PART A still passes, its "
        "constraint being refused up front.",
        [(HT_EXCLUSION_UNDER_LOCK, "", 1)],
    ),
    "hypertable_cutover_serial_sequence_kept_by_source": (
        "bench/hypertable_cutover_serial_sequences.sh",
        "Pre-#839 from_hypertable_cutover(): nothing lets go of the sequences the source owns through a "
        "column, so the copy's nextval() default (CREATE TABLE ... LIKE INCLUDING DEFAULTS) depends on a "
        "sequence the DROP TABLE of the source would take, and the DROP fails with 2BP01 after the whole "
        "online copy. tests/timescale/db/39's migration raises the raw error and its assertions on the "
        "migrated table fail.",
        [(HT_SERIAL_LET_GO, "    -- MUTANT: the source keeps the sequences it owns\n", 1)],
    ),
    # hypertable_cutover_serial_owned_before_carry is RETIRED (#986). It was the plausible one-step #839 fix
    # (OWNED BY the copy's column before the DROP), caught only while the copy belonged to another role than
    # the source at the swap. #986 made that state unreachable: during the migration every drain and the
    # cutover hand a re-owned copy back to the hypertable's owner (or refuse 42501), the cutover asks again
    # under its ACCESS EXCLUSIVE on the hypertable and the copy so nothing can re-own between that follow and
    # the swap, and a copy re-owned before an upgrade meets the same follow at the first cutover after it.
    # tests/timescale/db/39 and bench/hypertable_cutover_serial_sequences.sh stay as the carry order's test.
    "hypertable_shape_ignores_foreign_keys": (
        "bench/hypertable_cutover_foreign_keys.sh",
        "Pre-#840 _from_hypertable_shape_diff: columns, defaults and CHECKs are compared, outgoing foreign "
        "keys are not, so a key added to the hypertable between the copy and the cutover is dropped with "
        "the source (orphans accepted afterwards) and a key dropped in that window comes back. Deletes the "
        "three foreign-key arms; tests/timescale/db/40's refusal assertion fails (the cutover runs on to "
        "its COMMIT inside throws_like), its invariants and its remedy pass.",
        [(HT_SHAPE_FK_ARMS, "", 1)],
    ),
    "hypertable_index_ddl_by_pattern": (
        "bench/hypertable_index_names.sh",
        "Pre-#735 pgpm_hypertable: the index pre-builds rewrite pg_get_indexdef with "
        "'^(CREATE (UNIQUE )?INDEX )[^ ]+ ON [^ ]+' instead of replacing the index's own quoted name and "
        "table by identity. A quoted name holding a space does not match, the statement runs unrewritten, "
        "and it tries to build a second \"f6 metrics_pkey\" on the SOURCE: 'relation already exists' after "
        "the whole online copy. Part A of tests/timescale/db/29 (the append-only cutover and the tracked "
        "copy of a hypertable whose names hold a space) fails on the raw error and on relkind.",
        [("""  if starts_with(v_def, v_upfx_q) then
    return 'CREATE UNIQUE INDEX ' || v_to_q || substr(v_def, length(v_upfx_q) + 1);""",
          """  return regexp_replace(v_def, '^(CREATE (UNIQUE )?INDEX )[^ ]+ ON [^ ]+',   -- MUTANT: by pattern
    '\\1' || quote_ident(p_tmp) || ' ON ' || quote_ident(p_nsp) || '.' || quote_ident(p_dest));
  if starts_with(v_def, v_upfx_q) then
    return 'CREATE UNIQUE INDEX ' || v_to_q || substr(v_def, length(v_upfx_q) + 1);""", 1)],
    ),
    "hypertable_tmp_name_cut": (
        "bench/hypertable_index_names.sh",
        "Pre-#707 pgpm_hypertable: an index's pre-build temp name is left(<name> || '_pgpm_new', 63), and "
        "for a 63-byte key name that cut IS the key's own name. The tracked copy's key build dies on "
        "'already exists', and the append-only cutover finds the source's own index under the temp name and "
        "fails on it, after the whole copy. Part B of tests/timescale/db/29 fails. Since #872 a key's temp name "
        "is chosen by _from_hypertable_key_tmp, whose fallback (a name held by anything not on the destination "
        "takes pgpm_new_<oid>) would quietly repair a cut name, so the defect is put back INSIDE that helper "
        "too: the cut name, taken by name, with neither the destination check nor the oid form.",
        [("""  select (case when octet_length(p_name || '_pgpm_new') <= 63 then p_name || '_pgpm_new'
               else 'pgpm_new_' || p_index::text end)::name""",
          """  select left(p_name || '_pgpm_new', 63)::name   -- MUTANT: cut to 63 bytes""", 1),
         ("""  with c(tmp, ord) as (
    values (pgpm._from_hypertable_tmp_name(p_name, p_index), 1), (('pgpm_new_' || p_index::text)::name, 2)
  ), h as (
    select tmp, ord, to_regclass(format('%I.%I', p_nsp, tmp)) as held from c
  )
  select tmp from h
   where held is null or exists (select 1 from pg_index i where i.indexrelid = h.held and i.indrelid = p_dest)
   order by (held is not null) desc, ord
   limit 1
""", """  select left(p_name || '_pgpm_new', 63)::name   -- MUTANT: cut to 63 bytes, by name, no oid form
""", 1)],
    ),
    "hypertable_handoff_unchecked": (
        "bench/hypertable_index_names.sh",
        "Pre-#707 pgpm_hypertable: nothing asks for the monolith name transmute will derive from p_interval "
        "until transmute does, after the cutover's swap has committed, so a 38 to 48 byte hypertable name "
        "on a daily grid is refused with the hypertable already dropped. _from_hypertable_check_handoff "
        "returns at once; part C of tests/timescale/db/29 fails where from_hypertable and the cutover are "
        "pinned to refuse up front (they die on the 2D000 of their first COMMIT inside throws_like).",
        [("""  select c.relname into v_rel from pg_class c where c.oid = p_hypertable;
  perform pgpm._part_name(v_rel, 'time', p_interval::text,""",
          """  select c.relname into v_rel from pg_class c where c.oid = p_hypertable;
  return;   -- MUTANT: the handoff's names are not asked for up front
  perform pgpm._part_name(v_rel, 'time', p_interval::text,""", 1)],
    ),
    "hypertable_empty_watermark_nothing_past": (
        "bench/hypertable_empty_copy_watermark.sh",
        "Pre-#736 pgpm_hypertable: the NULL watermark of an empty copy reads as 'nothing to catch up', so "
        "the pre-drain, its step and the cutover's own catch-up take no row, and the conservation check "
        "refuses the swap, blaming rows at or below a watermark that does not exist. Turns "
        "_from_hypertable_past's NULL case from true into false, which is the old behaviour at all three "
        "sites; every part of tests/timescale/db/30 fails.",
        [("then 'true'   -- #736: nothing was copied, so every row is past it",
          "then 'false'   -- MUTANT: a NULL watermark has nothing past it", 1)],
    ),
    "hypertable_cutover_watermark_timestamptz": (
        "bench/hypertable_time_rendering.sh",
        "Pre-#791 from_hypertable_cutover(): the append-only watermark max(control) of the destination is "
        "held in a timestamptz local and spliced back through ::text, so a naive timestamp watermark goes "
        "through the session TimeZone. Inside America/New_York's spring-forward gap the conversion moves it "
        "an hour forward, the in-order appends below that hour are not caught up, and the conservation "
        "check refuses the swap: both cutovers of tests/timescale/db/35 fail, keyless and keyed.",
        [("  v_watermark text;   -- the column's own text (#791), never a timestamptz: see _from_hypertable_ctl_text\n",
          "  v_watermark timestamptz;   -- MUTANT: a naive watermark goes through the session TimeZone\n", 1),
         ("coalesce(sum(%s), 0), pgpm._from_hypertable_ctl_text(max(%I)) from %I.%I', v_fp_q, p_control",
          "coalesce(sum(%s), 0), max(%I) from %I.%I', v_fp_q, p_control", 1),
         ("pgpm._from_hypertable_past(p_control, v_watermark, p_inclusive => true)",
          "pgpm._from_hypertable_past(p_control, v_watermark::text, p_inclusive => true)", 1),
         ("pgpm._from_hypertable_past(p_control, v_watermark), v_fp_q)",
          "pgpm._from_hypertable_past(p_control, v_watermark::text), v_fp_q)", 1)],
    ),
    "hypertable_chunk_bounds_session_datestyle": (
        "bench/hypertable_time_rendering.sh",
        "Pre-#793 from_hypertable_copy(): each chunk's range_start/range_end is spliced with a bare %L, in "
        "the session's DateStyle. Under 'SQL, DMY' in Asia/Shanghai the bound renders with the abbreviation "
        "CST, which reads back as US Central, so every chunk predicate moves 14 hours later and the oldest "
        "14 hours are not copied: tests/timescale/db/36 part A fails for timestamptz and naive alike.",
        [("    v_lo := format(v_bound_tpl, pgpm._ts_text(r.range_start));   -- #793: never the session DateStyle\n"
          "    v_hi := format(v_bound_tpl, pgpm._ts_text(r.range_end));\n",
          "    v_lo := format(v_bound_tpl, r.range_start);   -- MUTANT: the session DateStyle\n"
          "    v_hi := format(v_bound_tpl, r.range_end);\n", 1)],
    ),
    "hypertable_ctl_text_session_datestyle": (
        "bench/hypertable_time_rendering.sh",
        "Pre-#793 drains and catch-ups: _from_hypertable_ctl_text renders a control value in the session's "
        "DateStyle (a bare ::text, as max(ts)::text did), so under 'SQL, DMY' in Asia/Shanghai every "
        "watermark and reconcile range the pre-drain, its step, the change drain and the cutover carry "
        "reads back 14 hours later. The copy itself is exact (its bounds go through pgpm._ts_text), so "
        "this isolates the other five sites: tests/timescale/db/36 parts B, C and D fail.",
        [("create or replace function pgpm._from_hypertable_ctl_text(p_value anyelement)\n"
          "returns text language sql stable set datestyle = 'ISO, MDY' as $$\n",
          "create or replace function pgpm._from_hypertable_ctl_text(p_value anyelement)\n"
          "returns text language sql stable as $$   -- MUTANT: the session DateStyle\n", 1)],
    ),
    "transmute_dropped_fk_parent_not_carried": (
        "bench/hypertable_swap_order.sh",
        "transmute's cutover moves every pgpm.dropped_fk record whose referencing_table is the table it "
        "converts onto the new parent (0d, #498), but not the records whose PARENT is that table. "
        "Before #563 nothing wrote one ahead of a conversion; from_hypertable_cutover's swap now does, "
        "against the plain table it puts in place, since the parent does not exist yet. Deleting the "
        "carry leaves each record naming the monolith child after the rename, so restore_incoming_fks "
        "on the parent finds nothing and the key never comes back: the guard's recovery half (the "
        "operator re-runs transmute after the refused handoff) restores 0 keys where 2 are due.",
        [(TRANSMUTE_DROPPED_FK_PARENT_CARRY, "", 1)],
    ),
    "transmute_no_lock_timeout": (
        "bench/transmute_lock_timeout.sh",
        "Pre-#309 transmute: no lock_timeout on any phase, so it waits indefinitely for the ACCESS "
        "EXCLUSIVE the ADD and the RENAME need -- and a PENDING AccessExclusive blocks every request "
        "queued behind it, turning one slow query into an outage of the whole table. Strips only the "
        "per-phase set_config, leaving p_lock_timeout in the signature: the defect being modelled is "
        "'the timeout is not applied', not 'the parameter does not exist'. A mutant that dropped the "
        "parameter too would fail the guard's CALL with 42883 and look like a catch for the wrong "
        "reason.",
        # Phase 1's line is anchored on the statement that FOLLOWS it: these edits are plain substring
        # replacements, and the bare line is also a substring of the (more-indented) validation check
        # near the top of _transmute, which must survive -- the mutant should still reject a bad
        # p_lock_timeout, it just must not apply a good one.
        [("  perform set_config('lock_timeout', p_lock_timeout, true);\n"
          "  if not exists (select 1 from pg_constraint\n",
          "  if not exists (select 1 from pg_constraint\n", 1),
         ("  perform set_config('lock_timeout', p_lock_timeout, true);   -- `set local` did not survive the COMMIT\n",
          "", 2)],
    ),
    "transmute_reap_no_lock_timeout": (
        "bench/transmute_reap_lock_timeout.sh",
        "Pre-#657 _transmute_reap(): no bound on the DROP CONSTRAINT's ACCESS EXCLUSIVE, so the reaper runs "
        "under maintain_all's session default (pg_cron's 0: wait forever). One long reader of a half-converted "
        "table parks it, its PENDING lock queues every later read and write of the table behind it, and the "
        "sweep stalls for the reader's whole life. Strips only the function's SET lock_timeout clause and "
        "keeps the lock_not_available handler, so the defect modelled is 'the wait is not bounded': the "
        "guard's write times out behind the queued reaper, and the sweep outlives its ceiling.",
        [("returns int language plpgsql\nset lock_timeout = '5s'\nas $$\n"
          "declare r pgpm.transmute_inflight%rowtype; v_n int := 0;\n",
          "returns int language plpgsql\nas $$\n"
          "declare r pgpm.transmute_inflight%rowtype; v_n int := 0;\n", 1)],
    ),
    "detach_reap_no_lock_timeout": (
        "bench/reap_and_abort_lock_timeout.sh",
        "Pre-#708 _detach_reap(): no bound on the FINALIZE's ACCESS EXCLUSIVE on the abandoned partition, so "
        "the reaper runs under maintain_all's session default (pg_cron's 0: wait forever). One reader of the "
        "partition parks it, its PENDING lock queues every later access to the partition behind it, and the "
        "sweep never reaches a parent. Strips only the function's SET lock_timeout clause and keeps the "
        "per-row handler, so the defect modelled is 'the wait is not bounded': the guard's read of the "
        "partition times out behind the queued reaper, and the sweep outlives its ceiling.",
        [("returns int language plpgsql\nset lock_timeout = '5s'\nas $$\ndeclare\n  r record; v_n int := 0;\n",
          "returns int language plpgsql\nas $$\ndeclare\n  r record; v_n int := 0;\n", 1)],
    ),
    "transmute_abort_no_lock_timeout": (
        "bench/reap_and_abort_lock_timeout.sh",
        "Pre-#708 transmute_abort(): the DROP CONSTRAINT's ACCESS EXCLUSIVE waits under the operator's session "
        "setting (0 by default: forever), so behind one long reader its PENDING request blocks every later "
        "read and write of the live table for the reader's whole life. Strips only the set_config that "
        "applies p_lock_timeout to the DROP, leaving the parameter, its up-front validation and the "
        "lock_not_available refusal in place: the defect modelled is 'the bound is not applied', and the "
        "guard's bare call still resolves. Anchored on the #708 comment, because the bare line is also a "
        "substring of the (more-indented) validation block, which must survive.",
        [("  -- #708: under p_lock_timeout, and the caller's own setting back the moment the lock is had.\n"
          "  v_prev_lock_timeout := current_setting('lock_timeout');\n"
          "  perform set_config('lock_timeout', p_lock_timeout, true);\n",
          "  -- #708: under p_lock_timeout, and the caller's own setting back the moment the lock is had.\n"
          "  v_prev_lock_timeout := current_setting('lock_timeout');\n", 1)],
    ),
    "hypertable_handoff_validate_no_lock_timeout": (
        "bench/hypertable_handoff_fk_lock_timeout.sh",
        "Pre-#708 from_hypertable_cutover(): after the handoff's COMMIT, validate_incoming_fks runs under the "
        "session default (0: wait forever), so its VALIDATE's SHARE UPDATE EXCLUSIVE on a referencing table "
        "waits as long as any VACUUM, ANALYZE or other holder of that lock lives, and the operator's cutover "
        "with it. Strips only the set_config before the VALIDATE (the restore's, which transmute's own leftover "
        "bound masks anyway, stays), so the defect modelled is 'the VALIDATE is not bounded': the guard's "
        "cutover outlives its ceiling and logs no fail_validate_incoming_fk.",
        [("    perform set_config('lock_timeout', p_lock_timeout, true);   -- `set local` did not survive the COMMIT\n"
          "    perform pgpm.validate_incoming_fks(",
          "    perform pgpm.validate_incoming_fks(", 1)],
    ),
    "hypertable_cutover_no_lock_timeout": (
        "bench/hypertable_cutover_lock_timeout.sh",
        "Pre-#665 from_hypertable_cutover(): the swap's LOCK TABLE ... ACCESS EXCLUSIVE on the live "
        "hypertable runs under the session default (0: wait forever), so behind one long reader its "
        "PENDING request blocks every later read and write of the production table for the reader's whole "
        "life. Strips only the set_config that applies p_lock_timeout to the swap transaction, leaving the "
        "parameter, its up-front validation and the handoff's pass-through in place: the defect modelled "
        "is 'the bound is not applied', and the guard's bare CALL still resolves. Anchored on the comment "
        "line before it, because the bare line is also a substring of the two (more-indented) validation "
        "blocks, which must survive.",
        [("  -- are as they were, and re-running the cutover costs only the index pre-builds.\n"
          "  perform set_config('lock_timeout', p_lock_timeout, true);\n",
          "  -- are as they were, and re-running the cutover costs only the index pre-builds.\n", 1)],
    ),
    "transmute_cutover_late_build": (
        "bench/transmute_cutover_order.sh",
        "Pre-#344 transmute: the new parent's CREATE TABLE/identity/grants/RLS/policies/comments ran "
        "AFTER the rename, adding directly to the outage even though none of it touches the original "
        "table. Moves the exact hoisted block back to after both renames (right before the trigger "
        "replay, where the equivalent code sat before #344) -- the guard only asserts order against "
        "the FIRST rename, which relocating this one block alone already flips.",
        [(TRANSMUTE_CUTOVER_HOIST, "", 1),
         ("  -- 7b (triggers).", TRANSMUTE_CUTOVER_HOIST + "  -- 7b (triggers).", 1)],
    ),
    "transmute_cutover_late_create_table": (
        "bench/transmute_cutover_order.sh",
        "The #344 defect at its narrowest (#796): only the new parent's CREATE TABLE ... PARTITION BY RANGE "
        "statement moved to after both renames, everything else hoisted in place. The guard used to anchor on "
        "the FIRST 'partition by range' in _transmute's source, which is a preamble comment, so it passed this "
        "copy (12231 < 96413); transmute_cutover_late_build moves the RLS replay too and so never tested that "
        "check. The copy installs (plpgsql bodies are not resolved at CREATE), which is all the guard reads.",
        [("  execute format('create table %I.%I (like %s including defaults including generated including storage including constraints) partition by range (%I)',\n"
          "                 v_nsp, v_staging, p_parent::text, p_control);\n", "", 1),
         ("  execute format('alter table %s rename to %I', v_parent::text, v_rel);\n",
          "  execute format('alter table %s rename to %I', v_parent::text, v_rel);\n"
          "  execute format('create table %I.%I (like %s including defaults including generated including storage including constraints) partition by range (%I)',\n"
          "                 v_nsp, v_staging, p_parent::text, p_control);\n", 1)],
    ),
    "transmute_cutover_early_policy": (
        "bench/transmute_cutover_order.sh",
        "The #897 defect in the cutover's statement order: the policy replay loop moved, verbatim, to just after "
        "the capture, before either rename, where #344's outage reasoning would put it and #845 once anchored "
        "it. There the captured text, which names the table and qualifies its outer-row references with the "
        "table's name, cannot mean the new parent. Replaces transmute_cutover_late_policy, whose defect (the "
        "replay after the renames) is now the contract. Counts unchanged, so only the order check can catch it; "
        "the copy installs (plpgsql bodies are not resolved at CREATE), which is all the guard reads.",
        [(TRANSMUTE_POLICY_REPLAY, "", 1),
         (TRANSMUTE_POLICY_CAPTURE, TRANSMUTE_POLICY_CAPTURE + TRANSMUTE_POLICY_REPLAY, 1)],
    ),
    "transmute_cutover_late_policy_capture": (
        "bench/transmute_cutover_order.sh",
        "#897's other half of the order: the policy capture moved to just after the second rename, beside the "
        "replay. pg_policy is then read off p_parent, which is the monolith's oid by now, and pg_get_expr "
        "qualifies each outer-row reference with the MONOLITH's name, so the replayed policy fails on the "
        "parent exactly as it failed on the staging parent. Only the capture check can catch it; the copy "
        "installs, which is all the guard reads.",
        [(TRANSMUTE_POLICY_CAPTURE, "", 1),
         ("  execute format('alter table %s rename to %I', v_parent::text, v_rel);\n",
          "  execute format('alter table %s rename to %I', v_parent::text, v_rel);\n" + TRANSMUTE_POLICY_CAPTURE, 1)],
    ),
    "transmute_policies_on_staging": (
        "bench/transmute_self_naming_policy.sh",
        "Issue #897 put back, the pre-fix shape: the cutover executes each CREATE POLICY onto the staging parent "
        "<rel>_pgpm_new where it used to, before the renames, and the replay after them is gone. A policy whose "
        "expression qualifies the outer row with the table's own name fails raw in phase 3, after the bound and "
        "the claim committed. The one part of the pre-fix code not restored is _refuse_oid_bound_dependants' "
        "staging exemption, which #897 retired; it plays no part in tests/250 part A, which catches this.",
        TRANSMUTE_POLICIES_ON_STAGING_EDITS,
    ),
    "untransmute_no_recheck_under_lock": (
        "bench/untransmute_race.sh",
        "Pre-#443 untransmute: the outside-rows check runs once, under ACCESS SHARE, and the DETACH and "
        "DROP that act on its answer take their ACCESS EXCLUSIVE later. A writer whose forward-partition "
        "insert is uncommitted at the check and committed before that lock is granted has its row "
        "dropped with the parent, and pgpm.log records the untransmute as a success. Removes the "
        "lock-and-recheck block only: the unlocked check and the READ COMMITTED precondition stay, so "
        "the mutant still refuses a row that was already committed (tests/27) and is caught by "
        "nothing but the race.",
        [(UNTRANSMUTE_RECHECK_RE, "", 1)],
    ),
    "regrain_no_delta_analyze": (
        "bench/regrain_perf.sh",
        "Pre-#272 regrain: the trigger-populated delta carries no row estimate, so the planner "
        "misplans a reconcile tick into a seq scan of the whole delta.",
        [("""  select coalesce(reltuples, -1) into v_reltuples
    from pg_class where oid = format('%I.%I', v_dnsp, v_delta)::regclass;
  if v_reltuples = 0 then
    execute format('select exists (select 1 from %I.%I)', v_dnsp, v_delta) into v_delta_has_rows;
  end if;
  if v_reltuples < 0 or (v_reltuples = 0 and v_delta_has_rows) then
    perform pgpm._analyze(format('%I.%I', v_dnsp, v_delta)::regclass);
  end if;
""", "", 1)],
    ),
    "regrain_reconcile_discards_delta": (
        "bench/regrain_perf.sh",
        "The fast wrong answer (#916): _regrain_reconcile resolves each fine child and then `continue`s past "
        "the delete+reinsert that applies the captured change, while the final delete still consumes the "
        "batch's keys. No scan of anything, so checks 1 and 2 pass, and the row count is intact, so the old "
        "conservation check (count(*) > ROWS) passed too; the swap attaches the copies as they were copied "
        "and every captured UPDATE of an already-copied row (25,000 in the guard's fixture) is reverted. "
        "One site, the line after the copy relation is resolved.",
        [("    v_sub_rel := pgpm._regrain_copy_rel(p_parent, v_sub_name, 'reconcile captured changes into');\n",
          "    v_sub_rel := pgpm._regrain_copy_rel(p_parent, v_sub_name, 'reconcile captured changes into');\n"
          "    continue;\n", 1)],
    ),
    "upgrade_no_column_backfill": (
        "bench/upgrade_in_place.sh",
        "A column present in pgpm.config's `create table` body with no matching `add column if not "
        "exists` line: precisely the mistake install.sql's `add column if not exists` backfill lines "
        "exist to prevent. A FRESH "
        "install is unaffected, because it gets the column from the create table -- so the whole pgTAP "
        "suite stays green, installing fresh one database per file and never upgrading anything. Only a "
        "database that already had pgpm installed comes out of the upgrade missing the column, which is "
        "to say only the operators who are not evaluating it.",
        [("alter table pgpm.config add column if not exists obtain_retry_after timestamptz;\n", "", 1)],
    ),
    "upgrade_backfill_drops_not_null": (
        "bench/upgrade_in_place.sh",
        "#1003: pgpm.config.partition_tz's backfill line adds the column without its `not null default "
        "'UTC'`, while the `create table` body keeps both, so a fresh install is unchanged and the whole "
        "pgTAP suite stays green. An upgraded database gets a column of the right name and type, nullable, "
        "and every config row that predates the upgrade holds NULL where a fresh install holds 'UTC'. The "
        "guard's catalog read used to be name and type alone and called that identical to a fresh install; "
        "it must compare nullability and default, and find the NULL rows.",
        [("alter table pgpm.config add column if not exists partition_tz text not null default 'UTC';\n",
          "alter table pgpm.config add column if not exists partition_tz text;\n", 1)],
    ),
    "upgrade_child_oid_backfill_noop": (
        "bench/upgrade_in_place.sh",
        "The upgrade recreates pgpm.part.child_oid and populates nothing (issue #421). Deletes only "
        "the backfill UPDATE for ATTACHED partitions, leaving the `add column if not exists` line "
        "and the standalone-regrain-child UPDATE in place -- so the catalog-shape assertion stays "
        "green and the column is there, null, for every partition an existing install already had. "
        "That is the whole defect: a null child_oid reads as unanchored by design, so the archive "
        "step's identity check silently does nothing on precisely the installs that have been "
        "running longest, and no fresh install anywhere in the suite can show it. What must FAIL "
        "here is the child_oid assertion by name; a mutant that dropped the column instead would "
        "fail the catalog hash and look like a catch for the wrong reason.",
        [("update pgpm.part p set child_oid = i.inhrelid\n"
          "  from pg_inherits i join pg_class c on c.oid = i.inhrelid\n"
          " where i.inhparent = p.parent_table and c.relname = p.child_name\n"
          "   and p.attached and p.child_oid is null;\n", "", 1)],
    ),
    "upgrade_monolith_oid_backfill_noop": (
        "bench/upgrade_in_place.sh",
        "The upgrade adds pgpm.config.monolith_oid (#672) and populates nothing: the backfill UPDATE that "
        "adopts the one attached partition older than its parent writes null instead, the `add column if not "
        "exists` line left in place, so the catalog-shape assertion stays green and the column is there, "
        "null, for every table an existing install had converted. untransmute refuses a null anchor rather "
        "than guess, so every such table silently becomes irreversible on upgrade. What must FAIL here is "
        "the monolith_oid assertion by identity, not the catalog hash.",
        [("update pgpm.config c set monolith_oid = m.child_oid\n", "update pgpm.config c set monolith_oid = null\n", 1)],
    ),
    "upgrade_degrade_list_drift": (
        "bench/upgrade_in_place.sh",
        "install.sql gains a backfilled column that bench/upgrade_in_place.sh's hardcoded DEGRADE_COLS "
        "does not name. Unlike every other mutation here the defect being modelled lives in the GUARD, "
        "not in the product, and the product is moved because that is the only way to reproduce it: the "
        "guard degrades an install by dropping the columns on that list, so a backfill line for a column "
        "it omits is exercised by nothing, and the guard goes on claiming it covers 'every column "
        "install.sql backfills'. Measured at 958156c the list was 15 entries against 25 backfill lines "
        "(issue #417) -- among the ten missing, the two pgpm.transmute_inflight owner columns that carry "
        "#405's claim that a crashed transmute stays reapable. Nothing reported it, because the only "
        "precondition ran the other way (every LISTED column must exist fresh), which catches a column "
        "the product dropped and never one it gained. What must FAIL here is the new opposite "
        "precondition, by name; a mutant that instead failed the fresh-oracle install would be a "
        "non-zero exit for the wrong reason, so keep the added column nullable and inert.",
        [("alter table pgpm.config add column if not exists archive_batch int default 1;\n",
          "alter table pgpm.config add column if not exists archive_batch int default 1;\n"
          "alter table pgpm.config add column if not exists mutant_unlisted_col int;\n", 1)],
    ),
    "upgrade_regrain_capture_backfill_noop": (
        "bench/upgrade_in_place.sh",
        "The upgrade adds pgpm.config.regrain_delta_oid and regrain_capture_fn_oid (#496) and populates "
        "neither: the backfill block that records the derived-name relations of an install that predates "
        "the anchors is deleted, the `add column if not exists` lines left in place, so the catalog-shape "
        "assertion stays green and both columns are there, null, for the regrain the operator had in "
        "flight across the upgrade. Null anchors mean the readers fall back to the parent's current name, "
        "which is the pre-#496 rename hazard exactly, for precisely the regrain that was running. What "
        "must FAIL here is the anchor assertion by identity, not the catalog hash.",
        [(REGRAIN_CAPTURE_BACKFILL_BLOCK, "", 1)],
    ),
    "upgrade_stale_overloads_kept": (
        "bench/upgrade_from_release.sh",
        "The four `drop function if exists <old signature>` lines issue #441 added are gone again, "
        "which is install.sql exactly as 0.5.0 and 0.6.0 shipped it. `create or replace` across a "
        "changed argument list does not replace anything: it creates a SECOND overload beside the "
        "first, so an upgrade from 0.2.0, 0.3.0 or 0.4.0 keeps pgpm.schedule(text) beside "
        "pgpm.schedule(text, text) and pgpm.restore_incoming_fks(regclass) beside the p_ids form. The "
        "new parameter's default makes the old call shape match BOTH, so `select pgpm.schedule()` "
        "fails with 'is not unique', and so does the restore_incoming_fks(p_parent) call maintain() "
        "makes every tick -- inside a handler, so it lands as one routine-looking skip_restore_fk row "
        "per tick and a preserve-managed FK is never restored. A fresh install is untouched (there is "
        "nothing to drop), so the whole pgTAP suite stays green, and bench/upgrade_in_place.sh has no "
        "stale signature to find either: its origin is a degraded FRESH install. Only a real released "
        "origin shows it, which is what upgrade_from_release.sh installs. What must FAIL here is the "
        "routine-identity assertion, by name, and then schedule() and the tick behind it. One entry "
        "per line, so a stale pattern names the line that moved.",
        [
            ("drop function if exists pgpm.restore_incoming_fks(regclass);\n", "", 1),
            ("drop function if exists pgpm.schedule(text);\n", "", 1),
            ("drop function if exists pgpm._encode(text, text);\n", "", 1),
            ("drop function if exists pgpm._decode(text, text);\n", "", 1),
        ],
    ),
    "frontier_data_only": (
        "bench/frontier_drought.sh",
        "Pre-#325: uuidv7's (and, since the text_time control kind, text_time's) forward frontier was "
        "plain max(control), decoded, with no clock in it at all. A table whose writes go quiet (a "
        "restored dump, a stale clone, a drought exceeding obtain x step) has that frontier stuck "
        "wherever the data ended while now() keeps moving -- obtain measures itself against its own "
        "past output, finds nothing to do, and every write past the stalled grid is refused, "
        "permanently and silently. Reverts BOTH sites for BOTH kinds: _frontier_native (what "
        "obtain/maintain/regrain_step use every tick) and _transmute's inline duplicate (what sets the "
        "monolith's initial bound, before pgpm.config exists to call the shared function). Fixing only "
        "one site, or only one kind, leaves the other stuck at the data-only value -- confirmed the hard "
        "way while adding text_time: generalizing _frontier_native without also generalizing the inline "
        "duplicate reproduced a 10-month gap with no partition at all, not just a stale frontier.",
        [
            FRONTIER_NATIVE_CLOCK_BLEND,
            ("    if v_max_raw is null then\n"
             "      v_frontier_native := case when p_control_kind = 'id' then p_anchor else pgpm._ts_text(now()) end;\n"
             "    elsif p_control_kind in ('uuidv7', 'text_time') then\n"
             "      -- #325: mirrors _frontier_native's greatest(decoded, now()) here too. pgpm.config does not exist\n"
             "      -- yet (see the note above), so this cannot just call the shared function -- and fixing only that\n"
             "      -- one would leave THIS bound stuck at the data-driven value, opening a gap between the\n"
             "      -- monolith's frozen upper edge and obtain's now()-anchored forward grid on the very next tick.\n"
             "      -- Confirmed the hard way while building text_time support: adding the kind to _frontier_native\n"
             "      -- but not here reproduces exactly that gap (an unfixed [2025-07,2025-10) monolith with the next\n"
             "      -- partition not starting until 2026-08 -- ten covered months missing entirely).\n"
             "      v_frontier_native := pgpm._ts_text(greatest(pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch)::timestamptz, now()));\n"
             "    else\n"
             "      v_frontier_native := pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);\n"
             "    end if;\n",
             "    v_frontier_native := coalesce(pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch),\n"
             "                                  case when p_control_kind = 'id' then p_anchor else pgpm._ts_text(now()) end);\n",
             1),
        ],
    ),
    "frontier_native_data_only": (
        "bench/frontier_drought.sh",
        "#325 with only its _frontier_native half reverted (#846): uuidv7's and text_time's per-tick frontier "
        "(what obtain, maintain and regrain_step read) is plain max(control) again, while _transmute's inline "
        "duplicate keeps greatest(decoded, now()), so the monolith transmute builds still reaches now() and "
        "every 'a partition covers now()' check holds on the day of the transmute. The defect is the grid "
        "after that: obtain measures a drought table against its stale data maximum, plans nothing past the "
        "monolith, and once the drought outlasts the monolith's hi plus obtain x step every write is refused. "
        "frontier_data_only reverts both sites together and so never tested this half alone; tests/85 and the "
        "guard's coverage checks passed against this copy.",
        [FRONTIER_NATIVE_CLOCK_BLEND],
    ),
    "regrain_swap_reconcile_bounded": (
        "bench/regrain_swap_reconcile.sh",
        "Pre-#447 regrain_step swap, exactly: after the DETACH the residual reconcile runs for at most "
        "100 passes of greatest(batch, 1000) keys, and the ATTACH loop, `drop table <source>` and "
        "`truncate <delta>` follow unconditionally, with nothing checking that the loop stopped because "
        "the delta was empty. The gate before the DETACH bounds only what had committed before it ran; a "
        "writer already holding a row in the source keeps the DETACH waiting and everything it commits "
        "during that wait lands in the delta after the gate, so past 100 * batch keys the rest went with "
        "the source, silently. tests/107 fails against this on its identity assertions after a swap that "
        "reported `swapped:10`: 20,001 late rows missing and one deleted row resurrected.",
        [(REGRAIN_SWAP_DRAIN_LOOP, REGRAIN_SWAP_DRAIN_LOOP_BOUNDED, 1),
         (REGRAIN_SWAP_PENDING_CHECK, "", 1)],
    ),
    "regrain_swap_reconcile_bounded_checked": (
        "bench/regrain_swap_reconcile.sh",
        "The 100-pass bound put back with the #447 pre-drop check left in place. Not a shape that ever "
        "shipped; it exists to prove the check is LIVE, which nothing else can: on correct code the loop "
        "runs until the delta is empty, so the check can never fire and a typo in its raise would only "
        "ever be found the day it was needed. Against this mutant tests/107 fails on the swap tick "
        "itself, which raises instead of dropping the source; against the pure pre-#447 mutant above it "
        "fails on the identity assertions after a swap that succeeded. The two failures being different "
        "is what tells the two layers apart.",
        [(REGRAIN_SWAP_DRAIN_LOOP, REGRAIN_SWAP_DRAIN_LOOP_BOUNDED, 1)],
    ),
    "regrain_reconcile_delete_by_watermark": (
        "bench/regrain_reconcile_snapshot.sh",
        "Pre-#497 _regrain_reconcile at the one statement where the loss happened: the tick's final "
        "delete consumes every eligible delta row at or below the batch's highest pgpm_seq, under its "
        "own READ COMMITTED snapshot, instead of exactly the rows the apply statements addressed. "
        "pgpm_seq is assigned when the capture trigger fires, inside the writer's transaction, so a "
        "writer that captured an UPDATE and then held its transaction open across the tick commits a "
        "row whose pgpm_seq is below the watermark: invisible to the apply statements, visible to the "
        "final delete, and gone unapplied. The fine child keeps the pre-change row and the swap "
        "attaches it. tests/124 fails against this on id 150000 reading 'orig' after a clean swap, on "
        "the witness that T1's capture survived the tick, and on the tick's consumed-row count.",
        [("  execute format('delete from %I.%I where pgpm_seq = any($1)', v_dnsp, v_delta) using v_seqs;\n",
          "  execute format('delete from %I.%I where pgpm_seq <= %s and %s', v_dnsp, v_delta,\n"
          "                 (select max(s) from unnest(v_seqs) s), v_elig);\n", 1)],
    ),
    "set_archive_fn_no_return_type_check": (
        "bench/set_archive_fn_return_type.sh",
        "Pre-#517 set_archive_fn: the regprocedure cast alone, which resolves a name and an ARGUMENT list "
        "and never looks at what the function returns, so a strategy declared `returns text` (or SETOF, or "
        "an oid naming no function) is stored in config.archive_fn without complaint. _run_archive_strategy "
        "reads the strategy's result INTO a pgpm.archive_result variable positionally, so at the next tick "
        "that strategy's one text column lands in covered_hi; one that echoes p_hi passes the contract check "
        "(#454) as a perfect answer, writes a ledger row with rows_archived null, and retain() drops the "
        "partition with nothing archived. tests/129 fails against this on each refusal, on the switch that "
        "should have been left unchanged, on the strategy the tick actually called, and on the ledger row "
        "that records a positional echo instead of the well-typed twin's 7 rows.",
        [("""declare v_rettype regtype; v_retset boolean;
begin
  -- #951: refused before anything is read or committed; p_archive_fn (null turns archiving off) is not
  perform pgpm._refuse_null_arguments('set_archive_fn', json_build_object('p_parent', p_parent));
  -- The regprocedure cast resolves a NAME and an ARGUMENT LIST, so a reference with the wrong
  -- arguments fails at the cast (42883) and a function with the right arguments and any return type
  -- at all gets through it. That mattered: _run_archive_strategy reads the strategy's result INTO a
  -- pgpm.archive_result variable positionally, so a `returns text` strategy's one column landed in
  -- covered_hi, and one that echoed p_hi passed the contract check as a perfect answer, wrote a
  -- ledger row with rows_archived null, and the partition was dropped with nothing archived (#517).
  -- This is the one moment the return type can be checked before a tick acts on it, so it is
  -- checked here, and the switch is left exactly where it was. SETOF is refused too: the contract
  -- is one row, and a set is a different signature even when its element type is the right one.
  if p_archive_fn is not null then
    select p.prorettype, p.proretset into v_rettype, v_retset from pg_proc p where p.oid = p_archive_fn::oid;
    if not found then
      raise exception 'pg_partition_magician: set_archive_fn(%, %) refused -- % does not name a function', p_parent, p_archive_fn, p_archive_fn::oid;
    end if;
    if v_retset or v_rettype <> 'pgpm.archive_result'::regtype then
      raise exception
        'pg_partition_magician: set_archive_fn(%, %) refused -- the strategy returns %, and the archive_fn contract is '
        '(p_parent regclass, p_child name, p_lo text, p_hi text) returns pgpm.archive_result. The regprocedure cast checks '
        'only the argument list; a result of any other shape would be mapped positionally onto covered_hi by a maintenance '
        'tick, and a strategy echoing p_hi would then pass the contract check and record coverage with nothing archived.',
        p_parent, p_archive_fn, case when v_retset then 'setof ' else '' end || v_rettype::text;
    end if;
  end if;
  update pgpm.config set archive_fn = p_archive_fn where parent_table = p_parent;
""",
          "begin\n"
          "  -- #951: refused before anything is read or committed; p_archive_fn (null turns archiving off) is not\n"
          "  perform pgpm._refuse_null_arguments('set_archive_fn', json_build_object('p_parent', p_parent));\n"
          "  update pgpm.config set archive_fn = p_archive_fn where parent_table = p_parent;\n", 1)],
    ),
    "regrain_no_outgoing_fk": (
        "bench/regrain_outgoing_fk_lock.sh",
        "Pre-#348 regrain_step: a fine child is created via `like ... including constraints`, "
        "which never copies a FOREIGN KEY, and nothing else gives it one. So the swap's ATTACH "
        "PARTITION forces PostgreSQL to validate the parent's outgoing FK for that partition from "
        "scratch, an O(rows) scan under whatever lock the swap already holds -- exactly what "
        "reached a production statement_timeout. Two sites: the #348 block, and the outgoing-key arm "
        "#898 added to _regrain_shape_drift, because with that arm in place a copy without the parent's key "
        "is drift, the run restarts on every tick, and the ATTACH scan the guard measures is never reached; "
        "pre-#348 code had neither.",
        [("""      -- #348: give the fine child its own already-validated copy of every outgoing FK the parent
      -- has, the same trick the bound CHECK above uses. The child is still empty here (this runs
      -- before the first row is copied in below), so VALIDATE costs nothing -- exactly how an empty
      -- CHECK validates for free. Every row copied in afterward is checked at INSERT time by the
      -- ordinary FK machinery regardless, so this one-time, zero-row validation is the only one this
      -- constraint will ever need; by the swap's ATTACH (below), Postgres adopts it instead of
      -- re-scanning, the same adoption transmute already relies on for the monolith
      -- (install.sql:2841-2851). A NOT VALID outgoing FK on the parent is left alone (the
      -- convalidated filter skips it): that matches today's behavior for it exactly, and transmute
      -- already refuses a NOT VALID outgoing FK at conversion time, so this only matters if one was
      -- added directly to the parent afterward.
      for r in
        select conname, pg_get_constraintdef(oid) as def
          from pg_constraint
         where conrelid = p_parent and contype = 'f' and confrelid <> p_parent and conparentid = 0
           and convalidated
      loop
        execute format('alter table %I.%I add constraint %I %s not valid', v_sub_nsp, v_sub_name, r.conname, r.def);
        execute format('alter table %I.%I validate constraint %I', v_sub_nsp, v_sub_name, r.conname);
      end loop;
""", "", 1),
         ("     where k.contype = 'f' and k.conparentid = 0\n",
          "     where k.contype = 'f' and k.conparentid = 0 and false\n", 1)],
    ),
    "obtain_backoff_ignores_headroom": (
        "bench/obtain_backoff_headroom.sh",
        "Pre-fix maintain_obtain: a lock-timeout deferral's obtain_retry_after back-off is honored however "
        "little forward grid is left. Harmless while a DEFAULT partition caught writes past the grid; since "
        "#288 such a write is refused, so a 30 s back-off that outlasts the lookahead turns one lost lock "
        "race into every writer aborting. Removes only the low-headroom bypass and leaves the back-off "
        "itself intact: the defect being modelled is 'the back-off ignores headroom', not 'there is no "
        "back-off'. A mutant that dropped the back-off entirely would fail the guard's ample-headroom "
        "assertion instead and look like a catch for the wrong reason.",
        [("  if not v_try then\n"
          "    begin\n"
          "      -- the first grid boundary past the frontier's own cell, and the top of attached coverage\n",
          "  if false then\n"
          "    begin\n"
          "      -- the first grid boundary past the frontier's own cell, and the top of attached coverage\n", 1)],
    ),
    "obtain_headroom_ignores_monolith": (
        "bench/obtain_backoff_headroom.sh",
        "The first cut of the low-headroom bypass (review on #386): headroom counted as attached partitions "
        "whose lo starts past the frontier's own cell. A monolith widened by transmute's p_bound_headroom "
        "covers several complete steps beyond the frontier, but its lo is far behind, so none of that room "
        "is counted and the back-off is bypassed every tick, retrying obtain's ACCESS EXCLUSIVE under "
        "contention while the table still has grid. Swaps the coverage walk back for that row count and "
        "leaves the bypass itself intact, so the guard's forward-grid assertions still pass and only the "
        "monolith-headroom one can catch it.",
        [("      -- the first grid boundary past the frontier's own cell, and the top of attached coverage\n"
          "      v_cell := pgpm._grid_next(cfg.control_kind, cfg.partition_step,\n"
          "                  pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,\n"
          "                                   pgpm._frontier_native(p_parent), cfg.partition_tz), cfg.partition_tz);\n"
          "      execute format('select %s from pgpm.part where parent_table = %L::regclass and attached',\n"
          "                     pgpm._max_hi_native(cfg.control_kind), p_parent::text) into v_top;\n"
          "      v_ahead := 0;\n"
          "      while v_top is not null and v_ahead < ceil(cfg.obtain / 2.0)\n"
          "            and not pgpm._native_gt(cfg.control_kind,\n"
          "                  pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_cell, cfg.partition_tz), v_top) loop\n"
          "        v_ahead := v_ahead + 1;\n"
          "        v_cell := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_cell, cfg.partition_tz);\n"
          "      end loop;\n",
          "      select count(*) into v_ahead\n"
          "        from pgpm.part p\n"
          "       where p.parent_table = p_parent and p.attached\n"
          "         and not pgpm._native_gt(cfg.control_kind,\n"
          "               pgpm._grid_next(cfg.control_kind, cfg.partition_step,\n"
          "                 pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,\n"
          "                                  pgpm._frontier_native(p_parent), cfg.partition_tz), cfg.partition_tz),\n"
          "               p.lo);\n", 1)],
    ),
    "obtain_headroom_integer_division": (
        "bench/obtain_backoff_headroom.sh",
        "The low-headroom threshold written with integer division instead of ceil: `cfg.obtain / 2` rather "
        "than `ceil(cfg.obtain / 2.0)`. Invisible at even obtain (ceil(4/2) and 4/2 are both 2), which is why "
        "the guard and tests/100 both carry an obtain 3 case: ceil(3/2) is 2 but 3/2 is 1, so with exactly "
        "one complete step of headroom left the real rule bypasses the back-off and this mutant honors it, "
        "leaving the grid unextended while the frontier keeps advancing. Mutates both sites (the walk's "
        "bound and the decision) so the mutant is self-consistent rather than a half-applied defect.",
        [("ceil(cfg.obtain / 2.0)", "cfg.obtain / 2", 2)],
    ),
    "obtain_backoff_bypass_shifts_cell": (
        "bench/obtain_backoff_headroom.sh",
        "#913, the finder's shifted-cell obtain: the tick that bypasses a recorded back-off on low headroom "
        "skips the FIRST cell it should create and builds one past the top instead, so it creates exactly "
        "as many partitions as the real code but leaves a one-cell hole just past the old grid ([5000,6000) "
        "in the guard's ob_race, [4000,5000) in ob_q) where every write is refused, the outage the guard "
        "exists for. The guard once checked the grid as a count of attached partitions and probed only a "
        "write at 8999, above the hole, so it stayed green; it now names every [lo,hi) cell and writes into "
        "the first cell the bypass must build. Gated on obtain_retry_after being set, so the raced ticks and "
        "the ample-headroom tick (which never reaches obtain) behave as the real code does.",
        [("  v_made int := 0; k int;\n",
          "  v_made int := 0; k int; v_skipped boolean := false;  -- MUTANT (#913)\n", 1),
         ("  for k in 0 .. cfg.obtain loop\n",
          "  for k in 0 .. cfg.obtain + (case when cfg.obtain_retry_after is not null then 1 else 0 end) loop\n", 1),
         ("    perform pgpm._create_partition(cfg, v_nsp, v_rel, null, v_name, v_lo, v_hi);\n"
          "    v_made := v_made + 1;\n",
          "    if cfg.obtain_retry_after is not null and not v_skipped then v_skipped := true; continue; end if;\n"
          "    perform pgpm._create_partition(cfg, v_nsp, v_rel, null, v_name, v_lo, v_hi);\n"
          "    v_made := v_made + 1;\n", 1)],
    ),
    "set_regrain_off_keeps_regrain": (
        "bench/set_regrain_off_midflight.sh",
        "Pre-#516 set_regrain: turning auto-regrain off writes regrain_to and nothing else, so the run in "
        "flight is stranded. maintain dispatches regrain_step only while regrain_to is set, so the run is "
        "never driven again, and _enforce_regrain_capture keeps capture on the child whose range covers "
        "config.regrain_cursor, which nothing clears, so it is never swept: the capture trigger, the "
        "TRUNCATE refusal, the delta and the not-yet-attached copies all stay until regrain_cancel. Removes "
        "only the regrain_cancel branch, so tests/129's section (A) -- capture gone, cursor null, copies "
        "dropped, one regrain_cancel row, TRUNCATE accepted -- is what catches it; sections (B) and (C) "
        "pass on the mutant too, which shows the gating they pin is not what discriminates.",
        [("""  if p_target_step is null and cfg.regrain_to is not null
     and (cfg.regrain_cursor is not null
          or exists (select 1 from pgpm.part where parent_table = p_parent and not attached)
          or exists (select 1 from pgpm.part p where p.parent_table = p_parent
                      and pgpm._regrain_capture_active(p_parent, p.child_name))) then
    perform pgpm.regrain_cancel(p_parent);
  end if;
""", "", 1)],
    ),
    "regrain_sync_no_parent_lock": (
        "bench/regrain_writer_waits.sh",
        "Pre-#580 regrain(): the synchronous driver loops regrain_step in one transaction without first "
        "taking SHARE on the parent. The capture trigger's SHARE ROW EXCLUSIVE on the source is held to the "
        "end of the call, so a write into the source's range takes ROW EXCLUSIVE on the parent and queues "
        "on the source still holding it, and the swap's DETACH, needing ACCESS EXCLUSIVE on the parent, "
        "waits on that writer in turn: PostgreSQL breaks the cycle with 40P01, aborting the write or the "
        "whole regrain after all its copying. Removes only the LOCK statement and the comment explaining "
        "it; tests/149's liveness witnesses (capture lock held mid-copy, the write waiting while regrain() "
        "runs) still pass on the mutant, and its outcome and row-identity assertions are what catch it.",
        [(re.compile(r"^  -- #580: take SHARE on the parent.*?\n  execute format\('lock table only %s in share mode', p_parent::text\);\n",
                     re.MULTILINE | re.DOTALL), "", 1)],
    ),
    "grid_session_timezone": (
        "bench/grid_timezone.sh",
        "Pre-#455 _grid_next: the calendar step is `p_lo::timestamptz + interval`, evaluated in the "
        "SESSION's TimeZone, with the zone parameter accepted and ignored. A transmute under "
        "America/New_York then builds children on the 00:00-04/-05 lattice while pg_cron, under the "
        "server's UTC, steps the grid on the 00:00+00 lattice: obtain's candidates half-overlap the New "
        "York children and are skipped, and the first one past the tail is created with a permanent hole "
        "behind it. Only the month branch is reverted, deliberately: the fixed-seconds branch is left "
        "absolute so the mutant is exactly 'the zone parameter is not consulted', not 'the day lattice "
        "is broken again', and a catch is a catch for the right reason. tests/111's month-step pairs "
        "(computed under two session zones) and its transmute-under-New-York walk are what catch it.",
        [("      return pgpm._ts_text((v_wall + make_interval(months => v_months)) at time zone p_tz);\n",
          "      return pgpm._ts_text(p_lo::timestamptz + make_interval(months => v_months));\n", 1)],
    ),
    "datestyle_session_render": (
        "bench/datestyle_bounds.sh",
        "Pre-#500 rendering of a native timestamptz as text: _ts_text loses its DateStyle pin and renders "
        "in the SESSION's DateStyle again, which is what every bare timestamptz::text did before it "
        "existed. A transmute from a 'SQL, DMY' session then stores 1 October 2026 as "
        "'01/10/2026 00:00:00 UTC' in pgpm.part.lo/hi, pgpm.log and config.partition_anchor, and a "
        "maintain tick on the default 'ISO, MDY' reads it back as 10 January: the monolith's hi falls "
        "below the retention horizon and retain() drops the live write partition, today's rows "
        "included. One site, because the fix is one function: every render goes through it, so removing "
        "the pin puts the defect back everywhere at once. tests/124's render, adapter and stored-bound "
        "identities, all written under SQL, DMY and read back under ISO, MDY, are what catch it.",
        [("returns text language sql stable set datestyle = 'ISO, MDY' as $$\n  select p_ts::text;\n$$;\n",
          "returns text language sql stable as $$\n  select p_ts::text;\n$$;\n", 1)],
    ),
    "regrain_capture_by_name": (
        "bench/regrain_capture_identity.sh",
        "Pre-#496 _regrain_capture_names: the delta table and trigger function are resolved from the "
        "parent's CURRENT relname, the oids pgpm.config recorded at prepare ignored. The trigger the "
        "prepare tick installed has the delta's name baked in, so after ALTER TABLE ... RENAME of the "
        "parent mid-regrain it keeps writing ev_pgpm_regrain_delta while the reconcile, the swap gate "
        "and the swap all look for events_pgpm_regrain_delta, find nothing, count 0 pending and swap: a "
        "committed UPDATE reverts, a DELETE comes back, an INSERT vanishes. tests/124 section (A) is "
        "what catches it: the resolver's answer after the rename, the gate's count, and the three rows "
        "by identity after the swap.",
        [("  select regrain_delta_oid, regrain_capture_fn_oid into cfg from pgpm.config where parent_table = p_parent;\n"
          "  if not found then return; end if;\n",
          "  select regrain_delta_oid, regrain_capture_fn_oid into cfg from pgpm.config where parent_table = p_parent;\n"
          "  return;\n", 1)],
    ),
    "regrain_delta_reused": (
        "bench/regrain_capture_identity.sh",
        "Pre-#496 _regrain_capture_install: the per-parent delta is created only when nothing sits under "
        "its name and merely TRUNCATED otherwise, so it keeps the key columns of the FIRST regrain while "
        "the trigger function is regenerated from the CURRENT key. Rename a key column between two "
        "regrains (PK (id, k2) -> (id, k3)) and the prepare tick succeeds, then every INSERT, UPDATE and "
        "DELETE on the source raises 'column k3 of relation b_pgpm_regrain_delta does not exist' for the "
        "life of the regrain, where the reference promises committed DML against the source is honoured. "
        "The identity anchors stay, so only the re-mint is missing: tests/124 section (B)'s column list, "
        "its 'not the same relation' check and its lives_ok are what catch it.",
        [("  if exists (select 1 from pg_class where oid = cfg.regrain_delta_oid) then\n"
          "    execute format('drop table %s', cfg.regrain_delta_oid::regclass::text);\n"
          "  end if;\n"
          "  execute format('create table %I.%I as select %s from %s with no data', v_nsp, v_delta, v_keycols_q, p_parent::text);\n",
          "  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then\n"
          "  execute format('create table %I.%I as select %s from %s with no data', v_nsp, v_delta, v_keycols_q, p_parent::text);\n", 1),
         ("  execute format('create index on %I.%I (pgpm_seq)', v_nsp, v_delta);\n"
          "  v_delta_reg := format('%I.%I', v_nsp, v_delta)::regclass;\n",
          "  execute format('create index on %I.%I (pgpm_seq)', v_nsp, v_delta);\n"
          "  end if;\n"
          "  execute format('truncate %I.%I', v_nsp, v_delta);\n"
          "  v_delta_reg := format('%I.%I', v_nsp, v_delta)::regclass;\n", 1)],
    ),
    "regrain_delta_ungranted": (
        "bench/regrain_capture_identity.sh",
        "Pre-#496 grants: the delta is created by whoever runs regrain_step (the scheduling role under "
        "cron), owned by it and granted to nobody, and the per-tick re-sync is gone too. The capture "
        "trigger inserts into it with the WRITER's privileges (pgpm has no SECURITY DEFINER anywhere), "
        "so an application role holding full DML on the parent, and even the parent's own owner, gets "
        "42501 on every UPDATE, DELETE and INSERT landing in the regraining child for the whole regrain. "
        "tests/124 section (C)'s owner and has_table_privilege checks and its lives_ok writes as those "
        "roles are what catch it.",
        [("  perform pgpm._scratch_mint(p_parent, v_delta_reg);\n"
          "  perform pgpm._regrain_capture_grant(p_parent, v_delta_reg, v_src);\n", "", 1),
         ("  if v_delta_reg is not null then perform pgpm._regrain_capture_grant(p_parent, v_delta_reg, v_child); end if;\n", "", 1)],
    ),
    "schema_name_regnamespace_cast": (
        "bench/quoted_schema.sh",
        "Pre-#512 _is_write_blocked and _regrain_capture_active: the parent's schema is selected by NAME "
        "and cast back with `v_nsp::regnamespace`, whose input parses its text as an SQL identifier. A "
        "schema that needs quoting (\"Sales\") downcases: with no lower-case twin the lookup raises "
        "`schema \"sales\" does not exist` (skip_archive on every tick, nothing archived, the aged child "
        "never retired; a regrain cannot prepare and the janitor logs skip_regrain_capture), and once a "
        "twin exists it silently answers for the twin's same-named child. Both sites go back, so the "
        "mutant is exactly the shipped shape and not one function patched around the other. tests/124's "
        "quoted-schema archive, regrain and twin cases catch it. _is_write_blocked keeps #727's resolution "
        "of the child's own schema in the mutant, so the cast is the only thing put back there. "
        "_regrain_capture_active has no schema lookup left since #768 (it asks the relation pgpm.part "
        "recorded), so its edit puts back its whole pre-#512 body, parent's schema and cast both.",
        [("returns boolean language plpgsql stable as $$\nbegin\n"
          "  return exists (select 1 from pg_trigger t\n"
          "                  where t.tgname = 'pgpm_regrain_capture'\n"
          "                    and t.tgrelid = pgpm._regrain_child_rel(p_parent, p_child));\n",
          "returns boolean language plpgsql stable as $$\n"
          "declare v_nsp name;\nbegin\n  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n"
          "  return exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid\n"
          "                  where t.tgname = 'pgpm_regrain_capture' and c.relname = p_child\n"
          "                    and c.relnamespace = v_nsp::regnamespace);\n", 1),
         ("declare v_nsp_oid oid;\nbegin\n"
          "  -- #727: the partition's own schema, not the parent's; matched by name = name, never parsed (#512)\n"
          "  select n.oid into v_nsp_oid from pg_namespace n where n.nspname = pgpm._child_nsp(p_parent, p_child);\n",
          "declare v_nsp name;\nbegin\n  v_nsp := pgpm._child_nsp(p_parent, p_child);\n", 1),
         ("c.relnamespace = v_nsp_oid", "c.relnamespace = v_nsp::regnamespace", 1)],
    ),
    "part_name_silent_truncation": (
        "bench/part_name_length.sh",
        "Pre-#510 _part_name: the length check is gone and the rendered <rel>_p<label> goes straight "
        "through the cast to name, which silently cuts it to 63 bytes. For a relation name long enough "
        "that the label itself is cut, every forward candidate renders the same 63 bytes, the monolith "
        "takes that name at transmute, obtain skips every cell as already existing, nothing is logged, and "
        "the first write past the monolith's hi is refused by PostgreSQL. tests/124's boundary pairs (a "
        "64-byte name rendered instead of refused) and its 44-character transmute (a conversion where a "
        "refusal was promised) are what catch it.",
        [("""  if octet_length(v_name) > 63 then
    raise exception 'pg_partition_magician: cannot name a partition of % -- % is % bytes, over PostgreSQL''s 63-byte identifier limit, and pgpm never truncates a partition name (obtain and regrain decide whether a partition already exists by name, so truncated names collide and the forward grid silently stops growing). Shorten the table name by at least % byte(s), or use a coarser step, whose labels are shorter.',
      p_relname, v_name, octet_length(v_name), octet_length(v_name) - 63;
  end if;
""", "", 1)],
    ),
    "transmute_staging_name_silent_truncation": (
        "bench/part_name_length.sh",
        "Pre-#510 transmute: the staging name <rel>_pgpm_new is cast to name with no length check, so a "
        "table name of 55 characters or more gets a truncated staging name. In the yearly one-step band "
        "the partition names fit and the truncated staging name is used as-is; at 61 characters it "
        "equalled the truncated monolith name and phase 3's RENAME failed after two phases had committed. "
        "tests/124's 55-character yearly table (a conversion where a refusal was promised) and its "
        "60-character table (refused for the monolith's name rather than the staging name's, so the "
        "message names the wrong thing) are what catch it.",
        [("""  if octet_length(v_rel || '_pgpm_new') > 63 then
    raise exception 'pg_partition_magician: cannot transmute % -- its staging name % is % bytes, over PostgreSQL''s 63-byte identifier limit, and pgpm never truncates a name it derives from the table''s (a truncated one can collide with another). Shorten the table name by at least % byte(s).',
      p_parent, v_rel || '_pgpm_new', octet_length(v_rel || '_pgpm_new'), octet_length(v_rel || '_pgpm_new') - 63;
  end if;
""", "", 1)],
    ),
    "set_regrain_no_name_check": (
        "bench/part_name_length.sh",
        "set_regrain records a target step without asking _part_name whether the fine names at that step "
        "fit. A finer step has a wider label than partition_step's, so a table whose monthly names fit "
        "can be handed a daily regrain_to whose names do not: nothing refuses at call time, and every "
        "later tick raises the same error from regrain_step and logs skip_regrain, the #341 wedge one "
        "level down. tests/124's 52-character table (a daily target recorded where a refusal was "
        "promised, regrain_to no longer null) is what catches it.",
        [("""  if p_target_step is not null then
    select c.relname into v_rel from pg_class c where c.oid = p_parent;
    perform pgpm._part_name(v_rel, cfg.control_kind, p_target_step, cfg.partition_anchor, null, cfg.partition_tz);
  end if;
""", "", 1)],
    ),
    "grid_next_month_unsnapped": (
        "bench/month_step_dst_gap.sh",
        "Pre-#505 _grid_next: the calendar step adds the months to the grid value's wall reading as it "
        "stands. A grid value is the first instant of its month in partition_tz, and where midnight on the "
        "1st fell in a DST gap (America/Asuncion 2023-10-01, Asia/Amman 2016-04-01) that instant reads "
        "01:00, so next(floor(Oct)) lands at 01:00 on Nov 1 while floor(Nov) is 00:00 on Nov 1: "
        "regrain_step's consecutive sub-ranges overlap by that hour, the swap's ATTACH fails 'would "
        "overlap', and auto-regrain logs skip_regrain on every tick, forever. The snap that steps such a "
        "value from its wall midnight is removed, and nothing else: an off-grid value never took it. "
        "tests/127's next(floor(Oct)) = floor(Nov) pairs, its cursor-floors-to-itself check and its "
        "twelve-step chain are what catch it.",
        [("      if (date_trunc('month', v_wall) at time zone p_tz) = p_lo::timestamptz then\n"
          "        v_wall := date_trunc('month', v_wall);\n"
          "      end if;\n",
          "", 1)],
    ),
    "transmute_resume_session_zone": (
        "bench/transmute_resume_zone.sh",
        "Pre-#506 _transmute: a resume reuses the claim's bound but ignores the zone recorded with it and "
        "registers config.partition_tz from the RESUMING session. The bound sits on the claiming session's "
        "lattice, so the monolith is on one lattice and every later grid computation on another: obtain's "
        "first candidates half-overlap the monolith and are skipped, a hole one whole step wide is left "
        "right past its hi (writes there fail with no partition found), and set_partition_tz refuses the "
        "repair. The column and the recording stay; only the adoption on resume is removed, so the mutant "
        "is exactly 'the recorded zone is not consulted'. tests/128's resume from a UTC session of a New "
        "York claim is what catches it: partition_tz reads UTC, the monolith's hi is not a UTC boundary, "
        "and obtain leaves the hole.",
        [("  if v_resumed then\n    v_tz := coalesce(v_claim_tz, v_tz);\n  end if;\n", "", 1)],
    ),
    "part_name_day_label_in_zone": (
        "bench/day_label_utc.sh",
        "Pre-#503 _part_name: a day or week label is the wall DATE of the cell's start in partition_tz, "
        "although the day lattice is an absolute 86400 s lattice from the anchor instant. In a zone with "
        "daylight saving that lattice drifts an hour against local midnight twice a year, so the two "
        "cells straddling a fall-back can start on the same wall date (00:00 EDT and 23:00 EST of the "
        "same Sunday when the anchor is a summer midnight; the 00:00Z cells of the Sunday and the Monday "
        "in Atlantic/Azores) and share a name; and after set_partition_tz to a zone west of the old one "
        "every cell's new label is its predecessor's old one. obtain and extend_to skip a candidate whose "
        "name already exists before their overlap check, so the second cell of the pair is never built: a "
        "permanent one-day hole that refuses writes. tests/125's adapter pairs, its New York grid across "
        "the fall-back and its zone change on a UTC day grid are what catch it.",
        [("    v_label_tz := case when v_months > 0 then p_tz else 'UTC' end;\n",
          "    v_label_tz := case when v_months > 0 or v_secs >= 86400 then p_tz else 'UTC' end;\n", 1)],
    ),
    "legacy_day_label_skipped_by_name": (
        "bench/legacy_day_labels.sh",
        "Pre-#572 obtain and extend_to: a missing cell whose plain name is held by one of the parent's own "
        "partitions over a DIFFERENT range is skipped as though it were built, instead of being built under "
        "its explicit-range name. The #503 relabelling left pre-upgrade day children with their wall-date "
        "labels, and east of UTC with a local-midnight anchor the new label of every cell is the old label "
        "of the cell before it, so on an upgraded grid the first cell past the last legacy child is never "
        "built: a one-day hole that refuses every write, nothing logged, while the cells after it are "
        "built. Only the fallback is removed (the helper returns null where it would take the explicit "
        "name), so the mutant is exactly 'a taken name means built'. tests/138's Tokyo grids, relabelled "
        "the pre-#503 way, are what catch it: the collided cell is missing and the write into it refused.",
        [("  begin\n"
          "    v_name := pgpm._part_name(p_rel, cfg.control_kind, cfg.partition_step, p_lo, p_hi, cfg.partition_tz, true);\n"
          "  exception when raise_exception then\n"
          "    if sqlerrm not like 'pg_partition_magician: cannot name a partition of %' then raise; end if;\n"
          "    return null;\n"
          "  end;\n"
          "  if to_regclass(format('%I.%I', p_nsp, v_name)) is not null then return null; end if;\n"
          "  if pgpm._type_squatter(p_nsp, v_name) is not null then return null; end if;   -- #707\n"
          "  return v_name;\n",
          "  return null;\n", 1)],
    ),
    "naive_column_grid_in_session_zone": (
        "bench/naive_column_utc_grid.sh",
        "Pre-#504 _transmute and set_partition_tz: a timestamp or date control column records the "
        "transmuting SESSION's zone as partition_tz, and set_partition_tz accepts a change for it. The "
        "column's values are wall readings with no zone, but the fixed-step lattices are absolute seconds "
        "from the anchor instant, so read in a zone with an offset they no longer sit on the column's own "
        "clock: under America/New_York the 00:00Z day boundary renders as 20:00 the previous day, which a "
        "date column reads as the previous DATE, so the monolith's CHECK excludes every row dated today "
        "and phase 2's VALIDATE fails after phase 1 committed; the hourly cells either side of the autumn "
        "fall-back render to the same naive wall time and CREATE TABLE refuses the second as an empty "
        "range; and after an accepted zone change every new bound literal is rendered in a different zone "
        "from the existing ones. Two sites, because the refusal is half of the fix: without it a table "
        "correctly recorded as UTC can still be moved off its own clock. tests/126's date-column "
        "conversion, its hourly cells across the fall-back and its refused set_partition_tz are what catch it.",
        [("  if p_control_kind = 'id' or (p_control_kind = 'time' and v_typname in ('timestamp', 'date')) then\n    v_tz := 'UTC';\n",
          "  if p_control_kind = 'id' then\n    v_tz := 'UTC';\n", 1),
         ("  if cfg.control_kind = 'time' and pgpm._control_naive(p_parent, cfg.control_column) then\n"
          "    raise exception 'pg_partition_magician: set_partition_tz(%, %) refused -- column % of % is a timestamp or date column, which carries no zone: its grid and its bound literals are the column''s own wall clock (recorded as ''UTC''), and rendering new bounds in another zone would shift them by that zone''s offset against every existing partition', p_parent, p_tz, cfg.control_column, p_parent;\n"
          "  end if;\n",
          "", 1)],
    ),
    "archive_lz77_hash_scratch": (
        "bench/archive_lz77_memory.sh",
        "Pre-#366 archive._pq_lz77_tokens: LZ77 candidate lookup materializes a per-position temp "
        "table (one row per byte of the ENTIRE input) plus a btree index, instead of the fixed-size "
        "in-place hash table -- O(input size) peak memory, measured at ~40x the input on a "
        "production-shaped fixture, instead of a flat ~64 MiB regardless of size. Also restores "
        "archive._pq_lz_pos_hashes, which the fixed code has no use for and this mutant depends on.",
        [(
            '''-- The LZ77 matcher shared by archive._pq_deflate_encode and archive._pq_deflate_encode_dynamic:
-- single most-recent candidate per 3-byte hash, greedy, window 32768, max match 258. Returns one
-- row per token in stream order: literal (is_match=false, val1=byte 0-255) or match
-- (is_match=true, val1=length, val2=distance).
--
-- #366: candidates come from a fixed-size, in-place hash table (v_table), not a per-position temp
-- table + btree index -- that materialized one row per byte of the ENTIRE input up front, ~40x the
-- input size in peak memory, and degraded further across repeated calls in one backend session
-- (archive_batch > 1). v_table is one int4 slot per possible 3-byte value (2^24 = 16,777,216
-- entries, ~64 MiB, initialized to -1 = "no entry"), holding only the MOST RECENT position seen
-- for that exact 3-byte value -- sized to the full hash domain, not just the 32768-byte window,
-- specifically so there are zero collisions and a lookup is exactly "the largest pos < v_pos with
-- this exact hash", matching what the old exhaustive index computed, byte for byte. A table sized
-- to the window instead (the conventional zlib-style choice) would collide different 3-byte values
-- into the same slot and could silently hide a real, older match behind a newer, unrelated one --
-- still valid DEFLATE, but not byte-identical to today's output.
--
-- The old temp table held an entry for every position 0..n-3 regardless of whether the main loop's
-- greedy skip-ahead (v_pos := v_pos + v_mlen) ever visited it. A hash table that only records
-- positions the loop actually LANDS ON would silently skip the ones a match jumps over, finding
-- fewer candidates than before and producing valid but not byte-identical output. So a match's
-- branch below backfills v_table for every position it consumes (v_pos..v_pos+v_mlen-1), in
-- ascending order so ties resolve to the largest position -- not just advancing past them.
create or replace function archive._pq_lz77_tokens(payload bytea)
returns table(is_match boolean, val1 int4, val2 int4)
language plpgsql as $$
declare
  n int4 := length(payload);
  v_pos int4 := 0;
  v_hash int4; v_candidate int4; v_mlen int4;
  v_table int4[] := array_fill(-1, array[16777216]);
  v_end int4; v_j int4; v_h int4;
begin
  while v_pos < n loop
    v_candidate := null;
    if v_pos <= n - 3 then
      v_hash := (get_byte(payload,v_pos)<<16) | (get_byte(payload,v_pos+1)<<8) | get_byte(payload,v_pos+2);
      v_candidate := v_table[v_hash + 1];
      if v_candidate = -1 or v_pos - v_candidate > 32768 then
        v_candidate := null;
      end if;
    end if;
    if v_candidate is not null then
      v_mlen := archive._pq_lz_match_len(payload, v_pos, v_candidate, least(258, n - v_pos));
    else
      v_mlen := 0;
    end if;

    if v_mlen >= 3 then
      is_match := true; val1 := v_mlen; val2 := v_pos - v_candidate;
      return next;
      -- backfill every position this match consumes, including v_pos's own (never written
      -- before the lookup above) -- see the header note on why skipped positions still need
      -- an entry.
      v_end := least(v_pos + v_mlen - 1, n - 3);
      for v_j in v_pos..v_end loop
        v_h := (get_byte(payload,v_j)<<16) | (get_byte(payload,v_j+1)<<8) | get_byte(payload,v_j+2);
        v_table[v_h + 1] := v_j;
      end loop;
      v_pos := v_pos + v_mlen;
    else
      is_match := false; val1 := get_byte(payload, v_pos); val2 := null;
      return next;
      if v_pos <= n - 3 then
        v_table[v_hash + 1] := v_pos;
      end if;
      v_pos := v_pos + 1;
    end if;
  end loop;

  return;
end;
$$;''',
            '''-- Same matching algorithm as archive._pq_deflate_encode's inline loop (single most-
-- recent candidate per 3-byte hash, precomputed over the whole buffer via
-- archive._pq_lz_pos_hashes, greedy, window 32768, max match 258) -- factored out so
-- archive._pq_deflate_encode_dynamic below can reuse it verbatim. Returns one row per
-- token in stream order: literal (is_match=false, val1=byte 0-255) or match
-- (is_match=true, val1=length, val2=distance).
create or replace function archive._pq_lz_pos_hashes(data bytea) returns table(pos int4, h int4)
language sql immutable as $$
  select i, (get_byte(data,i)<<16) | (get_byte(data,i+1)<<8) | get_byte(data,i+2)
  from generate_series(0, length(data)-3) i;
$$;

create or replace function archive._pq_lz77_tokens(payload bytea)
returns table(is_match boolean, val1 int4, val2 int4)
language plpgsql as $$
declare
  n int4 := length(payload);
  v_pos int4 := 0;
  v_hash int4; v_candidate int4; v_mlen int4;
begin
  drop table if exists archive_lz77_hash_scratch;
  create temp table archive_lz77_hash_scratch as select * from archive._pq_lz_pos_hashes(payload);
  create index on archive_lz77_hash_scratch (h, pos);

  while v_pos < n loop
    v_candidate := null;
    if v_pos <= n - 3 then
      v_hash := (get_byte(payload,v_pos)<<16) | (get_byte(payload,v_pos+1)<<8) | get_byte(payload,v_pos+2);
      select pos into v_candidate from archive_lz77_hash_scratch
       where h = v_hash and pos < v_pos and v_pos - pos <= 32768
       order by pos desc limit 1;
    end if;
    if v_candidate is not null then
      v_mlen := archive._pq_lz_match_len(payload, v_pos, v_candidate, least(258, n - v_pos));
    else
      v_mlen := 0;
    end if;

    if v_mlen >= 3 then
      is_match := true; val1 := v_mlen; val2 := v_pos - v_candidate;
      return next;
      v_pos := v_pos + v_mlen;
    else
      is_match := false; val1 := get_byte(payload, v_pos); val2 := null;
      return next;
      v_pos := v_pos + 1;
    end if;
  end loop;

  drop table archive_lz77_hash_scratch;
  return;
end;
$$;''',
            1,
        )],
    ),
    "archive_encode_array_agg_unnest": (
        "bench/archive_encode_memory.sh",
        "Pre-#368 archive._pq_encode_column_data (text/array_json branch): fetches the whole "
        "column into an array_agg, then re-aggregates it a SECOND time over unnest(...) with "
        "ordinality to derive is_present and the PLAIN-encoded payload -- two full-size copies of "
        "the column alive at overlapping times, instead of one dynamic query that aggregates both "
        "directly from the source relation. Measured at ~6x the raw column size in peak RSS "
        "instead of the fix's ~1.2x-2.8x.",
        [(
            """  elsif p_pgtype in ('text', 'array_json') then
    execute format(
      case when p_pgtype = 'array_json'
        then 'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
                     coalesce(string_agg(archive._pq_plain_text(array_to_json(%I)::text), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
                from %s'
        else 'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
                     coalesce(string_agg(archive._pq_plain_text(%I::text), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
                from %s'
      end,
      p_col, v_order_q, p_col, v_order_q, p_col, v_from_q)
      into is_present, values_payload;
""",
            """  elsif p_pgtype in ('text', 'array_json') then
    declare arr_text text[];
    begin
    execute format(
      case when p_pgtype = 'array_json'
        then 'select array_agg(array_to_json(%I)::text order by %s) from %s'
        else 'select array_agg(%I::text order by %s) from %s'
      end,
      p_col, v_order_q, v_from_q) into arr_text;
    select coalesce(array_agg(v is not null order by ord), '{}'::boolean[]),
           coalesce(string_agg(archive._pq_plain_text(v), ''::bytea order by ord) filter (where v is not null), ''::bytea)
      into is_present, values_payload
      from unnest(arr_text) with ordinality as u(v, ord);
    end;
""",
            1,
        )],
    ),
    "archive_deflate_six_arrays": (
        "bench/archive_deflate_memory.sh",
        "Pre-#370 archive._pq_deflate_encode / _pq_deflate_encode_dynamic: six parallel int4[] "
        "token-bookkeeping arrays in the dynamic encoder (one element per LZ77 token, retained "
        "for the whole call) plus a v_bytes int4[] appended one element per OUTPUT byte in BOTH "
        "encoders, hex-round-tripped at the end -- on poorly-compressible input (near one token "
        "per byte), these can reach Postgres's ~1GB single-allocation ceiling well before the raw "
        "payload does. Measured at ~1.23GB peak RSS on a 15MB near-random fixture instead of the "
        "fix's ~364MB, and this is exactly what production hit archiving a "
        "prompts.\"PromptRunLog\" chunk at archive_byte_budget=256MB.",
        [
            ('-- DEFLATE-encode `payload` as one final, fixed-Huffman block (RFC 1951 3.2.3/3.2.6). Consumes\n-- archive._pq_lz77_tokens\'s token stream -- the same LZ77 matcher the dynamic-Huffman path uses\n-- (see that function for the match-finding strategy, #366) -- rather than keeping a second, inline\n-- copy of the matching loop.\n--\n-- #370: emits fixed-size chunks via `return next` (pre-sized once, filled with set_byte, never\n-- grown -- archive._pq_plain_boolean_array\'s idiom) instead of appending one int4 per OUTPUT byte\n-- to a growing v_bytes int4[] and hex-round-tripping it at the end -- that old shape cost 4 bytes\n-- of int4[] storage per compressed byte, scaling with compressed OUTPUT size independent of #366\'s\n-- token-count fix. archive._pq_deflate_encode (below) does the final string_agg aggregate over\n-- this function\'s chunk stream, the same "return next, real aggregate downstream" shape\n-- archive._pq_lz77_tokens already uses for its own token stream.\ncreate or replace function archive._pq_deflate_encode_chunks(payload bytea)\nreturns table(chunk bytea)\nlanguage plpgsql as $$\ndeclare\n  v_tok record;\n  v_acc int4 := 0; v_acc_n int4 := 0;\n  v_chunk_size constant int4 := 8192;\n  v_chunk_empty constant bytea := decode(repeat(\'00\', v_chunk_size), \'hex\');\n  v_chunk bytea := v_chunk_empty;\n  v_chunk_pos int4 := 0;\n  v_code int4; v_nbits int4; v_rev int4;\n  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;\n  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;\n  v_dist int4; v_len int4; v_sym int4;\nbegin\n  -- block header: BFINAL=1, BTYPE=01 (fixed Huffman) -- raw, LSB-of-value-first (the OPPOSITE\n  -- convention from Huffman codes, which are MSB-of-the-code-first; RFC 1951 3.1.1 splits these\n  -- two conventions and it is easy to invert one for the other by accident).\n  v_acc := v_acc | (3 << v_acc_n); v_acc_n := v_acc_n + 3;\n  while v_acc_n >= 8 loop\n    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n    v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n  end loop;\n\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    if v_tok.is_match then\n      v_len := v_tok.val1;\n      v_dist := v_tok.val2;\n\n      -- length code (RFC 1951 3.2.5), inlined rather than a separate lookup function -- see the\n      -- section header note on OUT-parameter call overhead.\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      -- distance code (RFC 1951 3.2.5), inlined\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      -- length code\'s literal/length Huffman code (RFC 1951 3.2.6), inlined\n      v_sym := v_lcode;\n      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;\n      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;\n      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;\n      else v_code := 192+(v_sym-280); v_nbits := 8;\n      end if;\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop\n        v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n        v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n      end loop;\n\n      if v_lextra_bits > 0 then\n        v_acc := v_acc | (v_lextra_val << v_acc_n); v_acc_n := v_acc_n + v_lextra_bits;\n        while v_acc_n >= 8 loop\n          v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n          v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n          if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n        end loop;\n      end if;\n\n      -- distance code: fixed 5-bit Huffman, identity-mapped (RFC 1951 3.2.6)\n      v_rev := archive._pq_bit_reverse(v_dcode, 5);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 5;\n      while v_acc_n >= 8 loop\n        v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n        v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n      end loop;\n\n      if v_dextra_bits > 0 then\n        v_acc := v_acc | (v_dextra_val << v_acc_n); v_acc_n := v_acc_n + v_dextra_bits;\n        while v_acc_n >= 8 loop\n          v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n          v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n          if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n        end loop;\n      end if;\n    else\n      v_sym := v_tok.val1;\n      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;\n      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;\n      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;\n      else v_code := 192+(v_sym-280); v_nbits := 8;\n      end if;\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop\n        v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n        v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n      end loop;\n    end if;\n  end loop;\n\n  -- end-of-block (symbol 256): 7-bit code, value 0\n  v_rev := archive._pq_bit_reverse(0, 7);\n  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 7;\n  while v_acc_n >= 8 loop\n    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n    v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n  end loop;\n  if v_acc_n > 0 then   -- pad final byte\n    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n  end if;\n\n  if v_chunk_pos > 0 then\n    chunk := substr(v_chunk, 1, v_chunk_pos); return next;\n  end if;\n  return;\nend;\n$$;\n\ncreate or replace function archive._pq_deflate_encode(payload bytea) returns bytea\nlanguage sql as $$\n  select coalesce((select string_agg(chunk, \'\'::bytea) from archive._pq_deflate_encode_chunks(payload)), \'\'::bytea);\n$$;\n', "-- DEFLATE-encode `payload` as one final, fixed-Huffman block (RFC 1951 3.2.3/3.2.6). Consumes\n-- archive._pq_lz77_tokens's token stream -- the same LZ77 matcher the dynamic-Huffman path uses\n-- (see that function for the match-finding strategy, #366) -- rather than keeping a second, inline\n-- copy of the matching loop.\ncreate or replace function archive._pq_deflate_encode(payload bytea) returns bytea\nlanguage plpgsql as $$\ndeclare\n  v_tok record;\n  v_acc int4 := 0; v_acc_n int4 := 0; v_bytes int4[] := '{}';\n  v_code int4; v_nbits int4; v_rev int4;\n  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;\n  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;\n  v_dist int4; v_len int4; v_sym int4;\nbegin\n  -- block header: BFINAL=1, BTYPE=01 (fixed Huffman) -- raw, LSB-of-value-first (the OPPOSITE\n  -- convention from Huffman codes, which are MSB-of-the-code-first; RFC 1951 3.1.1 splits these\n  -- two conventions and it is easy to invert one for the other by accident).\n  v_acc := v_acc | (3 << v_acc_n); v_acc_n := v_acc_n + 3;\n  while v_acc_n >= 8 loop\n    v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n  end loop;\n\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    if v_tok.is_match then\n      v_len := v_tok.val1;\n      v_dist := v_tok.val2;\n\n      -- length code (RFC 1951 3.2.5), inlined rather than a separate lookup function -- see the\n      -- section header note on OUT-parameter call overhead.\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      -- distance code (RFC 1951 3.2.5), inlined\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      -- length code's literal/length Huffman code (RFC 1951 3.2.6), inlined\n      v_sym := v_lcode;\n      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;\n      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;\n      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;\n      else v_code := 192+(v_sym-280); v_nbits := 8;\n      end if;\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop\n        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n      end loop;\n\n      if v_lextra_bits > 0 then\n        v_acc := v_acc | (v_lextra_val << v_acc_n); v_acc_n := v_acc_n + v_lextra_bits;\n        while v_acc_n >= 8 loop\n          v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        end loop;\n      end if;\n\n      -- distance code: fixed 5-bit Huffman, identity-mapped (RFC 1951 3.2.6)\n      v_rev := archive._pq_bit_reverse(v_dcode, 5);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 5;\n      while v_acc_n >= 8 loop\n        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n      end loop;\n\n      if v_dextra_bits > 0 then\n        v_acc := v_acc | (v_dextra_val << v_acc_n); v_acc_n := v_acc_n + v_dextra_bits;\n        while v_acc_n >= 8 loop\n          v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n        end loop;\n      end if;\n    else\n      v_sym := v_tok.val1;\n      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;\n      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;\n      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;\n      else v_code := 192+(v_sym-280); v_nbits := 8;\n      end if;\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop\n        v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n      end loop;\n    end if;\n  end loop;\n\n  -- end-of-block (symbol 256): 7-bit code, value 0\n  v_rev := archive._pq_bit_reverse(0, 7);\n  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 7;\n  while v_acc_n >= 8 loop\n    v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;\n  end loop;\n  if v_acc_n > 0 then v_bytes := array_append(v_bytes, v_acc & 255); end if;   -- pad final byte\n\n  return (select decode(string_agg(lpad(to_hex(x), 2, '0'), '' order by ord), 'hex')\n          from unnest(v_bytes) with ordinality as t(x, ord));\nend;\n$$;\n", 1),
            ('-- The full dynamic-Huffman (BTYPE=10) block encoder: tokenizes via\n-- archive._pq_lz77_tokens (pass 1, tallying the real litlen/distance symbol\n-- frequencies), builds a genuine per-block Huffman code for each alphabet\n-- (archive._pq_huffman_lengths/_canonical_codes -- pass 2), transmits both via the\n-- code-length meta-alphabet (archive._pq_clc_rle, Huffman-coded the same way), then\n-- re-tokenizes and emits the token stream under the new codes (pass 3). Same bit-\n-- accumulator convention as archive._pq_deflate_encode (LSB-first byte packing,\n-- Huffman codes bit-reversed via archive._pq_bit_reverse before packing since they\'re\n-- conventionally written MSB-first, raw fields/extra-bits pushed unreversed).\n--\n-- #370: pass 3 calls archive._pq_lz77_tokens a SECOND time and recomputes each token\'s\n-- length/distance code inline (duplicating pass 1\'s case blocks, the same way\n-- archive._pq_deflate_encode already computes-and-immediately-uses these per token without\n-- storing them) instead of replaying six parallel int4[] arrays (v_litlen_sym/_extra_val/\n-- _extra_bits, v_dist_sym/_extra_val/_extra_bits) that pass 1 used to fill, one element per\n-- LZ77 token. On poorly-compressible input (near one token per byte) those six arrays could\n-- exceed Postgres\'s ~1GB single-value ceiling well before the raw payload did -- exactly\n-- what production hit archiving a prompts."PromptRunLog" chunk. Re-running the matcher is a\n-- bounded, cheap cost since #366 made it O(1) memory and fast; this trades that for removing\n-- an O(token count) memory cost entirely. Also emits fixed-size chunks via `return next`,\n-- same as archive._pq_deflate_encode_chunks above, instead of a growing v_bytes int4[] --\n-- see that function\'s comment for why.\ncreate or replace function archive._pq_deflate_encode_dynamic_chunks(payload bytea)\nreturns table(chunk bytea)\nlanguage plpgsql as $$\ndeclare\n  v_tok record;\n  v_litlen_freq bigint[] := array_fill(0::bigint, array[286]);\n  v_dist_freq bigint[] := array_fill(0::bigint, array[30]);\n\n  v_litlen_lengths int4[]; v_litlen_codes int4[];\n  v_dist_lengths int4[]; v_dist_codes int4[];\n\n  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;\n  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;\n  v_len int4; v_dist int4;\n\n  v_acc int4 := 0; v_acc_n int4 := 0;\n  v_chunk_size constant int4 := 8192;\n  v_chunk_empty constant bytea := decode(repeat(\'00\', v_chunk_size), \'hex\');\n  v_chunk bytea := v_chunk_empty;\n  v_chunk_pos int4 := 0;\n\n  v_combined_lengths int4[];\n  v_litlen_hi int4; v_dist_hi int4;\n  v_hlit int4; v_hdist int4;\n  v_clc_sym int4[] := \'{}\'; v_clc_extra_val int4[] := \'{}\'; v_clc_extra_bits int4[] := \'{}\';\n  v_clc_freq bigint[] := array_fill(0::bigint, array[19]);\n  v_clc_lengths int4[]; v_clc_codes int4[];\n  v_clc_order int4[] := array[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];\n  v_hclen int4;\n  i int4; v_sym int4; v_code int4; v_nbits int4; v_rev int4;\nbegin\n  -- ---- pass 1: tokenize, tally frequencies only (#370: no per-token array storage) ----\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    if v_tok.is_match then\n      v_len := v_tok.val1; v_dist := v_tok.val2;\n\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      v_litlen_freq[v_lcode+1] := v_litlen_freq[v_lcode+1] + 1;\n      v_dist_freq[v_dcode+1] := v_dist_freq[v_dcode+1] + 1;\n    else\n      v_litlen_freq[v_tok.val1+1] := v_litlen_freq[v_tok.val1+1] + 1;\n    end if;\n  end loop;\n\n  v_litlen_freq[257] := v_litlen_freq[257] + 1;   -- symbol 256 (end-of-block), always present\n\n  if (select count(*) from unnest(v_dist_freq) f where f > 0) = 0 then\n    v_dist_freq[1] := 1;   -- RFC 1951 requires >=1 distance code even with zero matches\n  end if;\n\n  -- ---- pass 2: the real per-block Huffman codes ----\n  v_litlen_lengths := archive._pq_huffman_lengths(v_litlen_freq, 15);\n  v_litlen_codes := archive._pq_canonical_codes(v_litlen_lengths);\n  v_dist_lengths := archive._pq_huffman_lengths(v_dist_freq, 15);\n  v_dist_codes := archive._pq_canonical_codes(v_dist_lengths);\n\n  -- meta-alphabet: RLE the combined length sequence, then Huffman-code THAT\n  select max(gs) into v_litlen_hi from generate_series(1,286) gs where v_litlen_lengths[gs] > 0;\n  if v_litlen_hi < 257 then v_litlen_hi := 257; end if;\n  select max(gs) into v_dist_hi from generate_series(1,30) gs where v_dist_lengths[gs] > 0;\n  if v_dist_hi is null then v_dist_hi := 1; end if;\n\n  v_hlit := v_litlen_hi - 257;\n  v_hdist := v_dist_hi - 1;\n\n  v_combined_lengths := v_litlen_lengths[1:v_litlen_hi] || v_dist_lengths[1:v_dist_hi];\n\n  for v_tok in select * from archive._pq_clc_rle(v_combined_lengths) loop\n    v_clc_sym := array_append(v_clc_sym, v_tok.sym);\n    v_clc_extra_val := array_append(v_clc_extra_val, v_tok.extra_val);\n    v_clc_extra_bits := array_append(v_clc_extra_bits, v_tok.extra_bits);\n    v_clc_freq[v_tok.sym+1] := v_clc_freq[v_tok.sym+1] + 1;\n  end loop;\n\n  v_clc_lengths := archive._pq_huffman_lengths(v_clc_freq, 7);\n  v_clc_codes := archive._pq_canonical_codes(v_clc_lengths);\n\n  v_hclen := 19;\n  while v_hclen > 4 and v_clc_lengths[v_clc_order[v_hclen]+1] = 0 loop\n    v_hclen := v_hclen - 1;\n  end loop;\n\n  -- ---- pass 3: re-tokenize, emit bits under the now-known dynamic codes ----\n  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BFINAL=1\n  v_acc := v_acc | (0 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE low bit\n  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE high bit (=10, dynamic)\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n  v_acc := v_acc | (v_hlit << v_acc_n); v_acc_n := v_acc_n + 5;\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n  v_acc := v_acc | (v_hdist << v_acc_n); v_acc_n := v_acc_n + 5;\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n  v_acc := v_acc | ((v_hclen - 4) << v_acc_n); v_acc_n := v_acc_n + 4;\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n  for i in 1..v_hclen loop\n    v_acc := v_acc | (v_clc_lengths[v_clc_order[i]+1] << v_acc_n); v_acc_n := v_acc_n + 3;\n    while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n  end loop;\n\n  for i in 1..array_length(v_clc_sym, 1) loop\n    v_sym := v_clc_sym[i];\n    v_nbits := v_clc_lengths[v_sym+1];\n    v_code := v_clc_codes[v_sym+1];\n    v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n    v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n    while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n    if v_clc_extra_bits[i] > 0 then\n      v_acc := v_acc | (v_clc_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_clc_extra_bits[i];\n      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n    end if;\n  end loop;\n\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    if v_tok.is_match then\n      v_len := v_tok.val1; v_dist := v_tok.val2;\n\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      v_sym := v_lcode;\n      v_nbits := v_litlen_lengths[v_sym+1];\n      v_code := v_litlen_codes[v_sym+1];\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n      if v_lextra_bits > 0 then\n        v_acc := v_acc | (v_lextra_val << v_acc_n); v_acc_n := v_acc_n + v_lextra_bits;\n        while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n      end if;\n\n      v_sym := v_dcode;\n      v_nbits := v_dist_lengths[v_sym+1];\n      v_code := v_dist_codes[v_sym+1];\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n      if v_dextra_bits > 0 then\n        v_acc := v_acc | (v_dextra_val << v_acc_n); v_acc_n := v_acc_n + v_dextra_bits;\n        while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n      end if;\n    else\n      v_sym := v_tok.val1;\n      v_nbits := v_litlen_lengths[v_sym+1];\n      v_code := v_litlen_codes[v_sym+1];\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n    end if;\n  end loop;\n\n  -- end-of-block symbol (256), dynamic code\n  v_nbits := v_litlen_lengths[257];\n  v_code := v_litlen_codes[257];\n  v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;\n\n  if v_acc_n > 0 then\n    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;\n    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;\n  end if;\n\n  if v_chunk_pos > 0 then\n    chunk := substr(v_chunk, 1, v_chunk_pos); return next;\n  end if;\n  return;\nend;\n$$;\n\ncreate or replace function archive._pq_deflate_encode_dynamic(payload bytea) returns bytea\nlanguage sql as $$\n  select coalesce((select string_agg(chunk, \'\'::bytea) from archive._pq_deflate_encode_dynamic_chunks(payload)), \'\'::bytea);\n$$;\n', "-- The full dynamic-Huffman (BTYPE=10) block encoder: tokenizes via\n-- archive._pq_lz77_tokens (pass 1, also tallying the real litlen/distance symbol\n-- frequencies), builds a genuine per-block Huffman code for each alphabet\n-- (archive._pq_huffman_lengths/_canonical_codes -- pass 2), transmits both via the\n-- code-length meta-alphabet (archive._pq_clc_rle, Huffman-coded the same way), then\n-- emits the actual token stream under the new codes (pass 3). Same bit-\n-- accumulator convention as archive._pq_deflate_encode (LSB-first byte packing,\n-- Huffman codes bit-reversed via archive._pq_bit_reverse before packing since they're\n-- conventionally written MSB-first, raw fields/extra-bits pushed unreversed).\ncreate or replace function archive._pq_deflate_encode_dynamic(payload bytea) returns bytea\nlanguage plpgsql as $$\ndeclare\n  v_tok record;\n  v_k int4 := 0;\n  v_litlen_sym int4[] := '{}';\n  v_litlen_extra_val int4[] := '{}';\n  v_litlen_extra_bits int4[] := '{}';\n  v_dist_sym int4[] := '{}';\n  v_dist_extra_val int4[] := '{}';\n  v_dist_extra_bits int4[] := '{}';\n\n  v_litlen_freq bigint[] := array_fill(0::bigint, array[286]);\n  v_dist_freq bigint[] := array_fill(0::bigint, array[30]);\n\n  v_litlen_lengths int4[]; v_litlen_codes int4[];\n  v_dist_lengths int4[]; v_dist_codes int4[];\n\n  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;\n  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;\n  v_len int4; v_dist int4;\n\n  v_acc int4 := 0; v_acc_n int4 := 0; v_bytes int4[] := '{}';\n\n  v_combined_lengths int4[];\n  v_litlen_hi int4; v_dist_hi int4;\n  v_hlit int4; v_hdist int4;\n  v_clc_sym int4[] := '{}'; v_clc_extra_val int4[] := '{}'; v_clc_extra_bits int4[] := '{}';\n  v_clc_freq bigint[] := array_fill(0::bigint, array[19]);\n  v_clc_lengths int4[]; v_clc_codes int4[];\n  v_clc_order int4[] := array[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];\n  v_hclen int4;\n  i int4; v_sym int4; v_code int4; v_nbits int4; v_rev int4;\nbegin\n  -- ---- pass 1: tokenize, tally frequencies ----\n  for v_tok in select * from archive._pq_lz77_tokens(payload) loop\n    v_k := v_k + 1;\n    if v_tok.is_match then\n      v_len := v_tok.val1; v_dist := v_tok.val2;\n\n      case\n        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;\n        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;\n        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;\n        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;\n        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;\n        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;\n        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;\n      end case;\n\n      case\n        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;\n        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;\n        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;\n        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;\n        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;\n        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;\n        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;\n        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;\n        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;\n        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;\n        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;\n        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;\n        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;\n        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;\n      end case;\n\n      v_litlen_sym[v_k] := v_lcode; v_litlen_extra_val[v_k] := v_lextra_val; v_litlen_extra_bits[v_k] := v_lextra_bits;\n      v_dist_sym[v_k] := v_dcode; v_dist_extra_val[v_k] := v_dextra_val; v_dist_extra_bits[v_k] := v_dextra_bits;\n\n      v_litlen_freq[v_lcode+1] := v_litlen_freq[v_lcode+1] + 1;\n      v_dist_freq[v_dcode+1] := v_dist_freq[v_dcode+1] + 1;\n    else\n      v_litlen_sym[v_k] := v_tok.val1; v_litlen_extra_val[v_k] := 0; v_litlen_extra_bits[v_k] := 0;\n      v_dist_sym[v_k] := null;\n\n      v_litlen_freq[v_tok.val1+1] := v_litlen_freq[v_tok.val1+1] + 1;\n    end if;\n  end loop;\n\n  v_litlen_freq[257] := v_litlen_freq[257] + 1;   -- symbol 256 (end-of-block), always present\n\n  if (select count(*) from unnest(v_dist_freq) f where f > 0) = 0 then\n    v_dist_freq[1] := 1;   -- RFC 1951 requires >=1 distance code even with zero matches\n  end if;\n\n  -- ---- pass 2: the real per-block Huffman codes ----\n  v_litlen_lengths := archive._pq_huffman_lengths(v_litlen_freq, 15);\n  v_litlen_codes := archive._pq_canonical_codes(v_litlen_lengths);\n  v_dist_lengths := archive._pq_huffman_lengths(v_dist_freq, 15);\n  v_dist_codes := archive._pq_canonical_codes(v_dist_lengths);\n\n  -- meta-alphabet: RLE the combined length sequence, then Huffman-code THAT\n  select max(gs) into v_litlen_hi from generate_series(1,286) gs where v_litlen_lengths[gs] > 0;\n  if v_litlen_hi < 257 then v_litlen_hi := 257; end if;\n  select max(gs) into v_dist_hi from generate_series(1,30) gs where v_dist_lengths[gs] > 0;\n  if v_dist_hi is null then v_dist_hi := 1; end if;\n\n  v_hlit := v_litlen_hi - 257;\n  v_hdist := v_dist_hi - 1;\n\n  v_combined_lengths := v_litlen_lengths[1:v_litlen_hi] || v_dist_lengths[1:v_dist_hi];\n\n  for v_tok in select * from archive._pq_clc_rle(v_combined_lengths) loop\n    v_clc_sym := array_append(v_clc_sym, v_tok.sym);\n    v_clc_extra_val := array_append(v_clc_extra_val, v_tok.extra_val);\n    v_clc_extra_bits := array_append(v_clc_extra_bits, v_tok.extra_bits);\n    v_clc_freq[v_tok.sym+1] := v_clc_freq[v_tok.sym+1] + 1;\n  end loop;\n\n  v_clc_lengths := archive._pq_huffman_lengths(v_clc_freq, 7);\n  v_clc_codes := archive._pq_canonical_codes(v_clc_lengths);\n\n  v_hclen := 19;\n  while v_hclen > 4 and v_clc_lengths[v_clc_order[v_hclen]+1] = 0 loop\n    v_hclen := v_hclen - 1;\n  end loop;\n\n  -- ---- pass 3: emit bits ----\n  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BFINAL=1\n  v_acc := v_acc | (0 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE low bit\n  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE high bit (=10, dynamic)\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n  v_acc := v_acc | (v_hlit << v_acc_n); v_acc_n := v_acc_n + 5;\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n  v_acc := v_acc | (v_hdist << v_acc_n); v_acc_n := v_acc_n + 5;\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n  v_acc := v_acc | ((v_hclen - 4) << v_acc_n); v_acc_n := v_acc_n + 4;\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n  for i in 1..v_hclen loop\n    v_acc := v_acc | (v_clc_lengths[v_clc_order[i]+1] << v_acc_n); v_acc_n := v_acc_n + 3;\n    while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n  end loop;\n\n  for i in 1..array_length(v_clc_sym, 1) loop\n    v_sym := v_clc_sym[i];\n    v_nbits := v_clc_lengths[v_sym+1];\n    v_code := v_clc_codes[v_sym+1];\n    v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n    v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n    while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n    if v_clc_extra_bits[i] > 0 then\n      v_acc := v_acc | (v_clc_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_clc_extra_bits[i];\n      while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n    end if;\n  end loop;\n\n  for i in 1..v_k loop\n    v_sym := v_litlen_sym[i];\n    v_nbits := v_litlen_lengths[v_sym+1];\n    v_code := v_litlen_codes[v_sym+1];\n    v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n    v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n    while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n    if v_litlen_extra_bits[i] > 0 then\n      v_acc := v_acc | (v_litlen_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_litlen_extra_bits[i];\n      while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n    end if;\n\n    if v_dist_sym[i] is not null then\n      v_sym := v_dist_sym[i];\n      v_nbits := v_dist_lengths[v_sym+1];\n      v_code := v_dist_codes[v_sym+1];\n      v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n      while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n      if v_dist_extra_bits[i] > 0 then\n        v_acc := v_acc | (v_dist_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_dist_extra_bits[i];\n        while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n      end if;\n    end if;\n  end loop;\n\n  -- end-of-block symbol (256), dynamic code\n  v_nbits := v_litlen_lengths[257];\n  v_code := v_litlen_codes[257];\n  v_rev := archive._pq_bit_reverse(v_code, v_nbits);\n  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;\n  while v_acc_n >= 8 loop v_bytes := array_append(v_bytes, v_acc & 255); v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; end loop;\n\n  if v_acc_n > 0 then v_bytes := array_append(v_bytes, v_acc & 255); end if;\n\n  return (select decode(string_agg(lpad(to_hex(x), 2, '0'), '' order by ord), 'hex')\n          from unnest(v_bytes) with ordinality as t(x, ord));\nend;\n$$;\n", 1),
        ],
    ),
    "archive_encode_raises": (
        "bench/archive_encode_memory.sh",
        "#912: archive._pq_encode_column_data does the whole encode and then raises 'out of memory' "
        "(53200) instead of returning the column, the way an encode that outgrows the backend fails. "
        "Pre-#912 the guard's probe psql ran without ON_ERROR_STOP and its 'completed' witness was a "
        "marker that prints after a raised call too, its 'sampled' witness was met during the pg_sleep "
        "before the call, and nothing read the ERROR, so a call that never returned a result passed "
        "every check with a small RSS. The guard must read the call's own result and refuse any ERROR.",
        [("  if p_nullable then\n    return archive._pq_definition_levels(is_present) || values_payload;\n",
          "  raise exception using errcode = '53200', message = 'out of memory';\n"
          "  if p_nullable then\n    return archive._pq_definition_levels(is_present) || values_payload;\n", 1)],
    ),
    "archive_lz77_range_raises": (
        "bench/archive_lz77_memory.sh",
        "#912: archive._pq_to_parquet_range_counted builds the whole file and then raises 'out of "
        "memory' (53200) instead of returning it, on every chunk. Pre-#912 the guard counted marker "
        "lines that its probe psql (no ON_ERROR_STOP) prints after a raised call as after a returned "
        "one, so all three chunks 'completed' with every bound and the repeat ratio met. The guard "
        "must read each chunk's returned file length and refuse any ERROR.",
        [("  p_num_rows := v_num_rows;\nend;\n",
          "  p_num_rows := v_num_rows;\n"
          "  raise exception using errcode = '53200', message = 'out of memory';\nend;\n", 1)],
    ),
    "archive_lz77_repeat_differs": (
        "bench/archive_lz77_memory.sh",
        "#992: the Parquet footer's created_by carries the encode's clock time to the microsecond, a fixed "
        "width, so every call returns a different file of the same length, and chunk3, which re-encodes "
        "chunk1's rows, does not return chunk1's file. The guard compared the two files by length alone, so "
        "the repeat that the no-compounding ratio leans on passed as a repeat. It must compare their bytes.",
        [("      || archive._pq_write_binary(4, 6, convert_to('pg_partition_magician parquet prototype', 'UTF8')) -- created_by\n",
          "      || archive._pq_write_binary(4, 6, convert_to('pg_partition_magician parquet prototype '\n"
          "           || to_char(clock_timestamp() at time zone 'utc', 'YYYYMMDD\"T\"HH24MISS.US'), 'UTF8')) -- created_by\n", 1)],
    ),
    "archive_deflate_raises": (
        "bench/archive_deflate_memory.sh",
        "#912: archive._pq_deflate_encode and archive._pq_deflate_encode_dynamic each encode the whole "
        "payload and then raise 'out of memory' (53200) instead of returning the stream. Pre-#912 the "
        "guard's 'completed' witness was a marker its probe psql (no ON_ERROR_STOP) prints after a DO "
        "block that raised, and its only error check matched 'invalid memory alloc', so any other "
        "error passed every check. The guard must read the encoded length the call produced and "
        "refuse any ERROR.",
        [("language sql as $$\n  select coalesce((select string_agg(chunk, ''::bytea) from archive._pq_deflate_encode_chunks(payload)), ''::bytea);\n$$;\n",
          "language plpgsql as $$\ndeclare v_out bytea;\nbegin\n"
          "  v_out := coalesce((select string_agg(chunk, ''::bytea) from archive._pq_deflate_encode_chunks(payload)), ''::bytea);\n"
          "  raise exception using errcode = '53200', message = 'out of memory';\nend;\n$$;\n", 1),
         ("language sql as $$\n  select coalesce((select string_agg(chunk, ''::bytea) from archive._pq_deflate_encode_dynamic_chunks(payload)), ''::bytea);\n$$;\n",
          "language plpgsql as $$\ndeclare v_out bytea;\nbegin\n"
          "  v_out := coalesce((select string_agg(chunk, ''::bytea) from archive._pq_deflate_encode_dynamic_chunks(payload)), ''::bytea);\n"
          "  raise exception using errcode = '53200', message = 'out of memory';\nend;\n$$;\n", 1)],
    ),
    "archive_from_item_raw_splice": (
        "bench/archive_encode_boundary.sh",
        "Pre-#408 FROM item: archive._pq_from_item pastes p_schema/p_table in with %s instead of "
        "%I, which is exactly what handing archive._pq_encode_column_data a `p_from_sql text` and "
        "splicing it bare used to do. The boundary test's p_table payload is shaped to survive "
        "this -- it closes the SELECT, drops a victim table, and supplies a third statement "
        "returning the (boolean[], bytea) pair the EXECUTE ... INTO needs -- so the injected DROP "
        "COMMITS rather than rolling back with a failing statement.",
        [(
            """    when p_control is null then format('%I.%I', p_schema, p_table)""",
            """    when p_control is null then format('%s.%s', p_schema, p_table)""",
            1,
        )],
    ),
    "archive_order_by_raw_splice": (
        "bench/archive_encode_boundary.sh",
        "Pre-#408 ORDER BY: p_order_by's elements are joined without quote_ident wherever that "
        "list is built, which is what passing the whole ORDER BY list in as `p_order_by text` and "
        "splicing it bare used to amount to. An element carrying a statement terminator then "
        "reaches the statement as SQL rather than as one (absurd) column name. Two sites since "
        "#462: archive._pq_encode_column_data builds the list for its two aggregates, and "
        "archive._pq_snapshot builds it again, identically, for the row_number() that fixes the "
        "snapshot's row order. The defect is the missing quote_ident, not the function it is "
        "missing from, so the mutant removes it from both; a count of 1 here would either refuse "
        "to build (the stale-pattern refusal below) or, anchored on one site, leave the other "
        "quoting and misdescribe what pre-#408 code looked like.",
        [(
            """  select string_agg(quote_ident(c), ', ' order by ord) into v_order_q
    from unnest(p_order_by) with ordinality as t(c, ord);""",
            """  select string_agg(c, ', ' order by ord) into v_order_q
    from unnest(p_order_by) with ordinality as t(c, ord);""",
            2,
        )],
    ),
    "parquet_per_column_statements": (
        "bench/archive_parquet_snapshot.sh",
        "Pre-#462 read: archive._pq_snapshot materialises nothing. Its temp TABLE becomes a temp VIEW "
        "over the live relation and its row count a separate count(*), so every per-column query "
        "archive._pq_encode_column_data runs afterwards goes back to the relation itself under a READ "
        "COMMITTED snapshot of its own (one per column, plus one for the count), which is exactly the "
        "N+1 snapshots the encoders used to take. A row committing between two column reads is then "
        "in the later columns and not the earlier ones, and from that column on every value belongs "
        "to the row next door, in a file every reader accepts. Four edits, all in the snapshot's "
        "lifecycle since #632 made it reusable: the create (a view, so no WITH NO DATA), the fill "
        "(the truncate and the one-statement INSERT become the separate count), the two encoders' "
        "tails (they empty the table; the mutant drops the view, so the next call builds it again) "
        "and the drop of a misshapen one, so the mutant runs to completion rather than erroring on a "
        "TRUNCATE or a `drop table` of a view, which would fail the guard for the wrong reason.",
        [
            ("      'create temp table archive_pq_snapshot on commit drop as\n"
             "         select %s, row_number() over (order by %s) as archive_pq_ord from %s with no data',\n",
             "      'create temp view archive_pq_snapshot as\n"
             "         select %s, row_number() over (order by %s) as archive_pq_ord from %s',\n", 1),
            (PQ_SNAPSHOT_FILL, "  execute 'select count(*) from pg_temp.archive_pq_snapshot' into v_num_rows;\n", 1),
            (PQ_SNAPSHOT_TAIL, "  drop view pg_temp.archive_pq_snapshot;\n", 2),
            ("    drop table pg_temp.archive_pq_snapshot;\n",
             "    drop view pg_temp.archive_pq_snapshot;\n", 1),
        ],
    ),
    "transmute_trigger_state_dropped": (
        "bench/cutover_trigger_state.sh",
        "Pre-#499 transmute cutover (step 7b): the original table's row triggers are replayed onto the "
        "new parent from pg_get_triggerdef alone, and pg_get_triggerdef never emits tgenabled, so every "
        "replayed trigger comes back origin-only ('O') whatever it was. A trigger the operator had "
        "DISABLED fires again on the very next write and silently rewrites what is stored; an ENABLE "
        "ALWAYS one stops firing under session_replication_role = replica and an ENABLE REPLICA one "
        "starts firing for ordinary sessions. Nothing is refused or logged. The capture of tgname and "
        "tgenabled is left in place and unused, so the mutant is exactly 'the state is not re-applied', "
        "not 'the capture is broken', and tests/124's post-cutover catalog and write assertions are "
        "what catch it.",
        [("""    -- #499: the verbatim text carries no tgenabled, so every trigger just created is origin-only. Put
    -- back what the original had. At the parent, on purpose: ENABLE/DISABLE TRIGGER on a partitioned
    -- table recurses to the clones the CREATE above put on every partition (the monolith included), and
    -- a clone minted for a later partition inherits the parent's state, so one statement per trigger
    -- is the whole of it.
    for v_i2 in 1 .. array_length(v_trgdefs, 1) loop
      if v_trgstates[v_i2] <> 'O' then
        execute format('alter table %s %s trigger %I', v_parent::text,
                       case v_trgstates[v_i2] when 'D' then 'disable'
                                              when 'A' then 'enable always'
                                              when 'R' then 'enable replica' end,
                       v_trgnames[v_i2]);
      end if;
    end loop;
""", "", 1)],
    ),
    "untransmute_trigger_state_dropped": (
        "bench/cutover_trigger_state.sh",
        "Pre-#499 untransmute: the parent's row triggers are replayed onto the restored table from "
        "pg_get_triggerdef alone, so the table handed back carries every trigger ENABLE, however the "
        "parent had them: a DISABLED trigger fires on the next write, ALWAYS and REPLICA fall back to "
        "origin-only. The transmute half is left intact, so this mutant is caught by tests/124's "
        "post-reversal assertions and by nothing before them, which is what shows that half of the "
        "file discriminates on its own.",
        [("""  for v_i in 1 .. coalesce(array_length(v_trgdefs, 1), 0) loop
    if v_trgstates[v_i] <> 'O' then
      execute format('alter table %s %s trigger %I', v_restored::text,
                     case v_trgstates[v_i] when 'D' then 'disable'
                                           when 'A' then 'enable always'
                                           when 'R' then 'enable replica' end,
                     v_trgnames[v_i]);
    end if;
  end loop;
""", "", 1)],
    ),
    "transmute_publication_not_carried": (
        "bench/transmute_publication_membership.sh",
        "Pre-#566 transmute cutover: the new parent is never added to the publications that name the "
        "table. pg_publication_rel records the table by oid, the rename makes that oid the monolith, "
        "so every publication FOR TABLE <table> goes on publishing the monolith alone, and each row "
        "written past it lands in a forward partition that is in no publication and is silently not "
        "replicated. The up-front refusal of a filtered leaf-publishing membership is left in place, "
        "so the mutant is exactly 'the membership is not carried', and tests/132's membership and "
        "pg_publication_tables assertions are what catch it.",
        [("""    execute format('alter publication %I add table %s%s%s', v_pub.pubname, v_parent::text,
                   case when v_pub.cols_q is not null then ' (' || v_pub.cols_q || ')' else '' end,
                   case when v_pub.qual is not null then ' where (' || v_pub.qual || ')' else '' end);
""", "    null;\n", 1)],
    ),
    "transmute_serial_owner_not_moved": (
        "bench/transmute_serial_sequence_owner.sh",
        "Pre-#573 transmute cutover: a sequence the table owns through a column (a serial, or an "
        "explicit OWNED BY) stays owned by the oid the rename makes the monolith, while the new "
        "parent's copied default calls nextval on it. DROP of the aged-out monolith then fails with "
        "'other objects depend on it', retention logs fail_retain_drop on every tick, and the "
        "monolith can never be retired. The untransmute half is left intact (it finds nothing on the "
        "parent to hand back), so tests/133's ownership and retention assertions are what catch it.",
        [("    execute format('alter sequence %s owned by %s.%I', v_sq.seq::text, v_parent::text, v_sq.attname);\n",
          "    null;\n", 1)],
    ),
    "untransmute_serial_owner_not_returned": (
        "bench/transmute_serial_sequence_owner.sh",
        "The reversal's half of #573: untransmute drops the parent without first handing the serial "
        "sequences it owns back to the restored table, so the DROP takes (or, here, refuses to take) "
        "the sequence the restored table's column default still calls, and the whole reversal rolls "
        "back with 'other objects depend on it'. The transmute half is left intact, so this mutant is "
        "caught by tests/133's reversal assertions and by nothing before them, which is what shows "
        "that half of the file discriminates on its own.",
        [("    execute format('alter sequence %s owned by %s.%I', v_sq.seq::text, v_monreg::text, v_sq.attname);\n",
          "    null;\n", 1)],
    ),
    "archive_encode_no_partition_tz": (
        "bench/archive_encode_partition_tz.sh",
        "Pre-#501 transports: archive._encode_upload_ndjson_single and archive._encode_upload_parquet "
        "call pgpm._encode without config.partition_tz, so its last parameter falls back to its UTC "
        "default and the chunk's [lo, hi) is rendered as UTC wall time. A timestamptz column reads the "
        "same instant from either rendering; a naive timestamp column drops the offset and keeps the "
        "wall clock, so on a grid recorded in another zone the strategy reads the range shifted by "
        "the zone offset, uploads the wrong hour's rows, and still returns covered_hi = p_hi, which "
        "opens retire()'s drop gate for rows that were never archived. Four sites, lo and hi in each "
        "transport: the defect is the missing argument, not either function it is missing from, so "
        "the mutant removes it from all four.",
        [("pcfg.text_time_discard_bits, pcfg.text_time_epoch, pcfg.partition_tz)",
          "pcfg.text_time_discard_bits, pcfg.text_time_epoch)", 4)],
    ),
    "archive_object_key_digits_only": (
        "bench/archive_object_key.sh",
        "Pre-#502 object key: archive._object_stem projects EVERY native lo onto its digits, "
        "regexp_replace(p_lo, '[^0-9]', '', 'g'), the id kind included, so the sign (and on a numeric "
        "control the decimal point) is gone from the key and chunk lo -10000 and chunk lo 10000 of one "
        "table upload to the same object: the second PUT of a tick overwrites the first while both "
        "ledger rows record the shared key as archived, and retire() drops the first partition with its "
        "rows gone from the store. One site: both transports take the stem from the helper, which is "
        "what lets one edit put the defect back in the NDJSON and the Parquet path at once.",
        [(OBJECT_STEM_BODY,
          "  select regexp_replace(p_lo, '[^0-9]', '', 'g');\n", 1)],
    ),
    # #551, one mutation per session rendering the fix took out of the key, so a catch names which one
    # came back. Both break bench/archive_object_key_session.sh through tests/archive/db/26.
    "archive_object_key_search_path_parent": (
        "bench/archive_object_key_session.sh",
        "Pre-#551 object key: archive._owned_key names a chunk's parent p_parent::text, regclass output, "
        "which leaves the schema out whenever the calling session's search_path reaches the relation. "
        "Two parents named `evt` in schemas t26a and t26b, sharing a prefix and each ticked under its "
        "own search_path, both upload to <prefix>evt_0.ndjson (and <prefix>pq_0.parquet): the second "
        "PUT overwrites the first while both ledger rows record the key as archived, and retire() has "
        "already dropped the first table's partition. One site: every key is assembled in the one "
        "function, and only the chunk half (no p_child) is put back, so a synchronous export's key "
        "keeps its schema.",
        [("  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(coalesce(p_child, c.relname))\n",
          "  select p_prefix || case when p_child is null then p_parent::text\n"
          "                          else quote_ident(n.nspname) || '.' || quote_ident(p_child) end   -- MUTANT\n", 1)],
    ),
    "archive_object_key_session_zone": (
        "bench/archive_object_key_session.sh",
        "Pre-#551 time stem: archive._object_stem takes the digits of a time kind's lo text as the "
        "session rendered it, zone offset included and its sign dropped, instead of re-rendering the "
        "instant in UTC. 2024-01-01 00:00Z rendered in Asia/Karachi (05:00:00+05) and 10:00Z rendered "
        "in America/Bogota (05:00:00-05) are two chunks with one stem, so the second PUT overwrites the "
        "first while each call reports its chunk covered, and one chunk archived from two zones lands "
        "on two keys. The pre-#551 function exactly: immutable, no pinned TimeZone, digits of p_lo.",
        [("returns text language sql stable set timezone = 'UTC' set datestyle = 'ISO, MDY' as $$\n"
          + OBJECT_STEM_BODY,
          "returns text language sql immutable as $$\n"
          "  select case when p_kind = 'id' then p_lo else regexp_replace(p_lo, '[^0-9]', '', 'g') end;\n", 1)],
    # #498, one mutation per site of the fix, so a catch names which anchor went missing. All three break
    # bench/dropped_fk_identity.sh: the first two through tests/124's own assertions, the third through
    # the wrapper's upgrade half, which is the only place a second run of install.sql happens.
    ),
    # #822, one mutation per site of the fix: the key that ignores its claim, and the install-time seed.
    # Both break bench/archive_key_reused_name.sh through tests/archive/db/34.
    "archive_object_key_reusable_name": (
        "bench/archive_key_reused_name.sh",
        "Pre-#822 object key: archive._object_key names a chunk by the parent's current schema.relname "
        "and lo alone, whatever relation claimed that name first. After the runbook's drop and "
        "pgpm.forget_missing(), which deletes the dropped table's ledger rows, a new managed table taking "
        "the name and prefix archives its [0, 10000) to <prefix><schema>.<table>_0.ndjson (and .parquet), "
        "and the unconditional PUT replaces the dropped table's only copy of the rows retire() dropped. "
        "One site: archive._owned_key, which assembles every key, so the synchronous exports lose their "
        "oid shape with it (tests/archive/db/39 sees that half; this mutation's guard is #822's).",
        [("      || case when v_owner is not distinct from p_parent::oid then '' else '.' || p_parent::oid::text end\n",
          "", 1)],
    ),
    "archive_object_key_owner_unseeded": (
        "bench/archive_key_reused_name.sh",
        "Install claims nothing from the keys pgpm.archive_ledger already records: an installation "
        "upgraded to the release with archive.object_key_owner starts with no claims, so a table that "
        "archived before the upgrade owns no base, and once it is dropped and forgotten a new table taking "
        "its name claims the base itself and PUTs over the old table's objects. tests/archive/db/34 part C "
        "re-runs the seed the way a re-install does and requires the claim it makes.",
        [("             where l.s3_key like '%\\_%' and l.s3_key !~ '\\.[0-9]+_[^_]*$') b\n",
          "             where false) b\n", 1)],
    ),
    # #872 bullet 5, the archive object-key lever: one mutation per site that takes its key from the one
    # function that assembles and claims it, each putting back a key built without the claim. All break
    # bench/archive_key_owner_every_path.sh through tests/archive/db/39, and each is also refused statically
    # by scripts/check_archive_object_keys.py (a second assembly).
    "archive_child_key_unclaimed": (
        "bench/archive_key_owner_every_path.sh",
        "Pre-#872 synchronous key: archive._child_object_key assembles <prefix><schema>.<child><ext> itself "
        "and claims nothing, so after the documented to_s3-then-drop workflow and pgpm.forget_missing(), a "
        "new table taking the dropped table's name exports its same-named partition over the dropped "
        "table's export, the only copy of those rows. One site, the entry point both archive.to_s3 and "
        "archive.to_s3_parquet take their key from: the defect the issue reported.",
        [("returns text language sql as $$\n"
          "  select archive._owned_key(p_parent, p_prefix, p_child, p_ext);\n",
          "returns text language sql stable as $$   -- MUTANT: the pre-#872 unclaimed export key\n"
          "  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(p_child) || p_ext\n"
          "    from pg_class c join pg_namespace n on n.oid = c.relnamespace\n"
          "   where c.oid = p_parent;\n", 1)],
    ),
    "archive_object_key_unclaimed": (
        "bench/archive_key_owner_every_path.sh",
        "Pre-#822 chunk key, at the chunk entry point: archive._object_key assembles "
        "<prefix><schema>.<table>_<stem><ext> itself and claims nothing, so a table that takes a dropped "
        "and forgotten table's name archives its [0, 10000) over the dropped table's only copy of the rows "
        "retire() dropped. One site, the entry point both archive_fn transports take their key from.",
        [("  select archive._owned_key(p_parent, p_prefix, null, '_' || archive._object_stem(p_kind, p_lo) || p_ext);\n",
          "  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(c.relname)   -- MUTANT: unclaimed\n"
          "         || '_' || archive._object_stem(p_kind, p_lo) || p_ext\n"
          "    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n", 1)],
    ),
    "archive_to_s3_key_inline": (
        "bench/archive_key_owner_every_path.sh",
        "archive.to_s3 builds its plain NDJSON key inline, <prefix><schema>.<child>.ndjson, instead of "
        "asking archive._child_object_key, so the export PUTs to a key nothing claimed and a namesake's "
        "export replaces a dropped table's. One site, the uncompressed key line.",
        [("    v_key := archive._child_object_key(p_parent, cfg.prefix, p_child, '.ndjson');    v_ctype := 'application/x-ndjson';\n",
          "    v_key := cfg.prefix || quote_ident(v_nsp) || '.' || quote_ident(p_child) || '.ndjson';    v_ctype := 'application/x-ndjson';   -- MUTANT\n", 1)],
    ),
    "archive_to_s3_gz_key_inline": (
        "bench/archive_key_owner_every_path.sh",
        "archive.to_s3 builds its compressed key inline, <prefix><schema>.<child>.ndjson.gz, instead of "
        "asking archive._child_object_key, so a compressed export PUTs to a key nothing claimed and a "
        "namesake's export replaces a dropped table's. One site, the compressed key line.",
        [("    v_key := archive._child_object_key(p_parent, cfg.prefix, p_child, '.ndjson.gz'); v_ctype := 'application/gzip';\n",
          "    v_key := cfg.prefix || quote_ident(v_nsp) || '.' || quote_ident(p_child) || '.ndjson.gz'; v_ctype := 'application/gzip';   -- MUTANT\n", 1)],
    ),
    "archive_to_s3_parquet_key_inline": (
        "bench/archive_key_owner_every_path.sh",
        "archive.to_s3_parquet builds its key inline, <prefix><schema>.<child>.parquet, instead of asking "
        "archive._child_object_key, so the export PUTs to a key nothing claimed and a namesake's file "
        "replaces a dropped table's. One site.",
        [("  v_key := archive._child_object_key(p_parent, cfg.prefix, p_child, '.parquet');   -- named with its schema (#711)\n",
          "  v_key := cfg.prefix || quote_ident((select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace\n"
          "                                     where c.oid = p_parent)) || '.' || quote_ident(p_child) || '.parquet';   -- MUTANT\n", 1)],
    ),
    "archive_ndjson_strategy_key_inline": (
        "bench/archive_key_owner_every_path.sh",
        "The NDJSON archive_fn transport builds its chunk key inline, <prefix><schema>.<table>_<stem>.ndjson, "
        "instead of asking archive._object_key, so a namesake's chunk PUTs over a dropped table's only copy. "
        "One site, archive._encode_upload_ndjson_single's key line.",
        [("  v_key := archive._object_key(p_parent, cfg.prefix, pcfg.control_kind, p_lo,\n"
          "                               case when p_compress then '.ndjson.gz' else '.ndjson' end);\n",
          "  v_key := cfg.prefix || quote_ident(v_nsp) || '.' || quote_ident(v_rel)\n"
          "           || '_' || archive._object_stem(pcfg.control_kind, p_lo)\n"
          "           || case when p_compress then '.ndjson.gz' else '.ndjson' end;   -- MUTANT\n", 1)],
    ),
    "archive_parquet_strategy_key_inline": (
        "bench/archive_key_owner_every_path.sh",
        "The Parquet archive_fn transport builds its chunk key inline, <prefix><schema>.<table>_<stem>.parquet, "
        "instead of asking archive._object_key, so a namesake's chunk PUTs over a dropped table's only copy. "
        "One site, archive._encode_upload_parquet's key line.",
        [("  v_key := archive._object_key(p_parent, cfg.prefix, pcfg.control_kind, p_lo, '.parquet');\n",
          "  v_key := cfg.prefix || (select quote_ident(n.nspname) || '.' || quote_ident(c.relname)\n"
          "                           from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent)\n"
          "           || '_' || archive._object_stem(pcfg.control_kind, p_lo) || '.parquet';   -- MUTANT\n", 1)],
    ),
    # #914: a write site Part 0 of tests/archive/db/39 must refuse by ENUMERATING the module's S3 writes, each
    # shaped so the scan it replaced (a 'PUT' literal present, a key helper's name absent from the body)
    # passes it: a helper named in a comment, a verb that is not a literal, and a second PUT at an inline key
    # beside a claimed one. Each key carries no prefix, the case scripts/check_archive_object_keys.py hands
    # to db/39. All three break bench/archive_key_owner_every_path.sh through Part 0 alone.
    "archive_put_site_helper_named_in_comment": (
        "bench/archive_key_owner_every_path.sh",
        "A new write site, archive.to_s3_marker, PUTs a completion marker at <child>.done, a key no "
        "helper made or claimed, while its comment names archive._child_object_key(: the pre-#914 Part 0 read "
        "the helper's name anywhere in the body, comment included, and passed it.",
        [("    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n",
          "    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n"
          "create or replace function archive.to_s3_marker(p_parent regclass, p_child name) returns void\n"
          "language plpgsql as $$\n"
          "declare cfg archive.config; v_key_id text; v_secret text; v_key text;\n"
          "begin\n"
          "  select * into cfg from archive.config where parent_table = p_parent;\n"
          "  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;\n"
          "  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;\n"
          "  -- MUTANT: beside the export archive._child_object_key(p_parent, cfg.prefix, p_child, ...) names, unclaimed\n"
          "  v_key := quote_ident(p_child) || '.done';\n"
          "  perform archive.s3_signed_request('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',\n"
          "                                   'text/plain', '', v_key_id, v_secret);\n"
          "end;\n"
          "$$;\n", 1)],
    ),
    "archive_put_site_verb_in_variable": (
        "bench/archive_key_owner_every_path.sh",
        "A new write site, archive._s3_send, takes its method as a parameter (p_method text default 'PUT', a "
        "default in the signature and so not in the body) and writes at <child>.ndjson, a key no helper made "
        "or claimed: the pre-#914 Part 0 looked for a 'PUT' literal in the body and passed it.",
        [("    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n",
          "    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n"
          "create or replace function archive._s3_send(p_parent regclass, p_child name, p_body text, p_method text default 'PUT')\n"
          "returns http_response language plpgsql as $$\n"
          "declare cfg archive.config; v_key_id text; v_secret text; v_key text;\n"
          "begin\n"
          "  select * into cfg from archive.config where parent_table = p_parent;\n"
          "  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;\n"
          "  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;\n"
          "  v_key := quote_ident(p_child) || '.ndjson';   -- MUTANT: unclaimed\n"
          "  return archive.s3_signed_request(p_method, cfg.endpoint, cfg.bucket, cfg.region, v_key, '',\n"
          "                                   'application/x-ndjson', p_body, v_key_id, v_secret);\n"
          "end;\n"
          "$$;\n", 1)],
    ),
    "archive_to_s3_parquet_second_put_inline": (
        "bench/archive_key_owner_every_path.sh",
        "archive.to_s3_parquet, having PUT its file at the key archive._child_object_key claimed, PUTs a "
        "manifest beside it at <child>.manifest.json, a key nothing claimed: the pre-#914 Part 0 saw a 'PUT' "
        "literal and a helper's name in the body and passed it. One site; the export itself is unchanged, so "
        "Part C's identity checks still pass and only the enumeration of writes can catch it.",
        [("    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n",
          "    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "  v_key := quote_ident(p_child) || '.manifest.json';   -- MUTANT: a second object, unclaimed\n"
          "  v_resp := archive.s3_signed_request('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',\n"
          "                                     'application/json', '{\"rows\": null}', v_key_id, v_secret);\n", 1)],
    ),
    # #914: a second key assembly scripts/check_archive_object_keys.py must refuse by FOLLOWING the prefix,
    # the two shapes review pass 8 found (F8-05) that its token-adjacency rule passed. Both break
    # bench/archive_object_keys_static.sh, which runs the checker on the mutant.
    "archive_key_prefix_by_subquery": (
        "bench/archive_object_keys_static.sh",
        "A second, unclaimed export key, archive._export_key_ndjson, assembled as (select prefix from "
        "archive.config where ...) || <schema>.<child>.ndjson: `prefix` touches no ||, is not assigned and is "
        "no call's argument, so the pre-#914 checker read it as one assembly (archive._owned_key's) and passed.",
        [("    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n",
          "    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n"
          "create or replace function archive._export_key_ndjson(p_parent regclass, p_child name) returns text\n"
          "language sql stable as $$   -- MUTANT: a second, unclaimed assembly\n"
          "  select (select prefix from archive.config where parent_table = p_parent)\n"
          "         || quote_ident(n.nspname) || '.' || quote_ident(p_child) || '.ndjson'\n"
          "    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n"
          "$$;\n", 1)],
    ),
    "archive_key_prefix_by_renamed_param": (
        "bench/archive_object_keys_static.sh",
        "A second, unclaimed export key: archive._export_key_parquet hands cfg.prefix to archive._join_key, a "
        "function the file defines, whose parameter is p_base and whose body is p_base || <schema>.<child>: the "
        "pre-#914 checker followed the call on the promise that the callee's body is checked by the same rule, "
        "but that rule knew only the names prefix and p_prefix, so p_base || ... passed.",
        [("    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n",
          "    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n"
          "create or replace function archive._join_key(p_base text, p_parent regclass, p_child name) returns text\n"
          "language sql stable as $$   -- MUTANT: a second, unclaimed assembly\n"
          "  select p_base || quote_ident(n.nspname) || '.' || quote_ident(p_child) || '.parquet'\n"
          "    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n"
          "$$;\n"
          "create or replace function archive._export_key_parquet(p_parent regclass, p_child name) returns text\n"
          "language plpgsql stable as $$\n"
          "declare cfg archive.config;\n"
          "begin\n"
          "  select * into cfg from archive.config where parent_table = p_parent;\n"
          "  return archive._join_key(cfg.prefix, p_parent, p_child);\n"
          "end;\n"
          "$$;\n", 1)],
    ),
    # #1001: a second key assembly that reads the prefix through dynamic SQL, the shape review pass 9 found
    # (F8-02): the checker lexed the literal EXECUTE runs as one opaque string. Breaks
    # bench/archive_object_keys_static.sh, which runs the checker on the mutant.
    "archive_key_prefix_by_execute": (
        "bench/archive_object_keys_static.sh",
        "A second, unclaimed export key, archive._export_key_dynamic, reads archive.config.prefix with execute "
        "'select prefix from archive.config where parent_table = $1' into v_base and returns v_base || "
        "<schema>.<child>.ndjson: the pre-#1001 checker lexed that literal as one opaque token, so it saw no "
        "prefix reference in the function at all and passed it, while the same SELECT written statically fails.",
        [("    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n",
          "    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);\n"
          "  end if;\n"
          "end;\n"
          "$$;\n"
          "create or replace function archive._export_key_dynamic(p_parent regclass, p_child name) returns text\n"
          "language plpgsql stable as $$\n"
          "declare v_base text; v_nsp name;\n"
          "begin\n"
          "  execute 'select prefix from archive.config where parent_table = $1' into v_base using p_parent;\n"
          "  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n"
          "  return v_base || quote_ident(v_nsp) || '.' || quote_ident(p_child) || '.ndjson';\n"
          "end;\n"
          "$$;\n", 1)],
    ),
    # #823: the pre-#823 stem exactly, UTC-pinned digits only. Breaks bench/archive_stem_era.sh through
    # tests/archive/db/35.
    "archive_object_stem_drops_era": (
        "bench/archive_stem_era.sh",
        "Pre-#823 time stem: archive._object_stem keeps only the digits of the lo rendered in UTC, so the "
        "' BC' era is thrown away with the punctuation and 2024-01-01 BC and 2024-01-01 AD of one table "
        "share a key: the AD chunk's PUT replaces the BC chunk's object while both report their rows "
        "archived. The decimal point goes too, so a tenth of a second in 2024 and a whole second in the "
        "year 20240 share a stem. One site: both transports take the stem from the helper.",
        [(OBJECT_STEM_BODY,
          "  select case when p_kind = 'id' then p_lo else regexp_replace(p_lo::timestamptz::text, '[^0-9]', '', 'g') end;\n", 1)],
    ),
    "dropped_fk_definition_session_search_path": (
        "bench/dropped_fk_identity.sh",
        "Pre-#498 capture: the cutover records pg_get_constraintdef() as rendered in the TRANSMUTING "
        "session, which leaves the referenced table unqualified whenever that session's search_path can "
        "see it. restore_incoming_fks replays the text in a later session with the default search_path, "
        "so `REFERENCES orders(id)` resolves to whatever `orders` means there: an unrelated public.orders "
        "(the key comes back against the wrong table, logged restore_incoming_fk) or nothing "
        "(fail_restore_incoming_fk every tick). tests/124's app.orders/public.orders pair, converted under "
        "`set search_path = app, public` and restored under the default, is what catches it.",
        [("      select c.conrelid::regclass as reltbl, c.conname, pgpm._fk_definition(c.oid) as def\n",
          "      select c.conrelid::regclass as reltbl, c.conname, pg_get_constraintdef(c.oid) as def\n", 1)],
    ),
    "dropped_fk_referencer_stays_on_monolith": (
        "bench/dropped_fk_identity.sh",
        "Pre-#498 cutover: nothing moves the records in which the converted table is the REFERENCER, so "
        "they keep naming the oid this rename turns into the monolith child and the restore lands on that "
        "single partition (relkind 'r', so NOT VALID, logged restore_incoming_fk) while every row the "
        "referencing table routes to a forward partition escapes the key. One site, two findings: a "
        "self-referential key (F5-02, conrelid IS p_parent, recorded one statement before the rename) and a "
        "key another parent preserved against this table before it was converted (F5-07). tests/124 "
        "inserts an orphan at id 5000, past the monolith, in each and requires the refusal, with the "
        "parent (conparentid = 0) named as the key's owner. Only the cutover's update is removed; "
        "untransmute's mirror stays, so the mutant is exactly 'the record does not follow the rename'.",
        [("  update pgpm.dropped_fk set referencing_table = v_parent where referencing_table = p_parent;\n",
          "", 1)],
    ),
    "dropped_fk_definition_no_backfill": (
        "bench/dropped_fk_identity.sh",
        "The install-time rewrite of a legacy record removed: a dropped_fk.definition captured by an "
        "earlier pgpm keeps its unqualified `REFERENCES parent(` after the upgrade, so the first regrain "
        "swap or restore to run in pg_cron's session re-adds the key against whatever that name means "
        "there. Invisible to every pgTAP file (each installs FRESH, so no record predates the install); "
        "the wrapper's second half forges the legacy text on a real record, re-runs install.sql over the "
        "database, and requires the qualified spelling and a restore that lands on the recorded parent "
        "rather than the same-named decoy in public.",
        [("update pgpm.dropped_fk d\n"
          "   set definition = replace(d.definition,\n"
          "                            ' REFERENCES ' || quote_ident(c.relname) || '(',\n"
          "                            ' REFERENCES ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || '(')\n"
          "  from pg_class c join pg_namespace n on n.oid = c.relnamespace\n"
          " where c.oid = d.parent_table\n"
          "   and position(' REFERENCES ' || quote_ident(c.relname) || '(' in d.definition) > 0;\n",
          "", 1)],
    ),
    "regrain_candidate_ignores_target": (
        "bench/regrain_candidate_subdivides.sh",
        "Pre-#515 maintain(): the auto-regrain candidate is the oldest child that is coarse by "
        "partition_step and frozen, with no test that regrain_to actually SUBDIVIDES it. The two "
        "predicates that have to agree (the candidate query's, and regrain_step's 'nosubdiv') then agree "
        "only while the target is no wider than the grid step at every lo, which set_regrain checks once, "
        "at the anchor. '30 days' on a '1 month' grid passes that check, and a 30-day cell that starts in "
        "February is wider than the calendar month from there: once the first coarse child has been split "
        "into such cells, that one is the oldest candidate on every tick, answers 'nosubdiv', and every "
        "coarse child behind it is never regrained. progress().coarse_frozen is reverted with it so the "
        "mutant is self-consistent (it counted by the grid's step alone too) and tests/125's mirror "
        "assertion fails for the same reason rather than by accident. tests/125's second coarse year, "
        "never reached, is what catches it.",
        [("        || ' and pgpm._native_gt(%L, p.hi, pgpm._grid_next(%L, %L, p.lo, %L))'   -- #515: the target subdivides it\n"
          "        || ' and not pgpm._native_gt(%L, p.hi, %L) order by p.lo::%s asc limit 1',\n"
          "        p_parent::text, cfg.control_kind, cfg.control_kind, cfg.partition_step, cfg.partition_tz,\n"
          "        cfg.control_kind, cfg.control_kind, v_regrain_to, cfg.partition_tz,\n",
          "        || ' and not pgpm._native_gt(%L, p.hi, %L) order by p.lo::%s asc limit 1',\n"
          "        p_parent::text, cfg.control_kind, cfg.control_kind, cfg.partition_step, cfg.partition_tz,\n", 1),
         ("         and pgpm._native_gt(r.control_kind, p.hi, pgpm._grid_next(r.control_kind, coalesce(r.regrain_to, r.partition_step), p.lo, r.partition_tz))\n",
          "", 1)],
    ),
    "untransmute_keeps_write_block": (
        "bench/untransmute_residue.sh",
        "Pre-#508 untransmute: the parent's triggers are captured and replayed and DETACH strips their "
        "clones, but pgpm_write_block sits on the monolith CHILD (retention's fence, ENABLE ALWAYS), so a "
        "monolith retention had reached but not dropped -- archiving deferred, or coverage kept the block "
        "after the frontier regressed (#452) -- was handed back as an unmanaged table that rejected every "
        "INSERT, UPDATE and DELETE with 'past its retention boundary', with pgpm.config and pgpm.part gone "
        "so no tick could ever lift it. Removes only the _remove_write_block call, so the mutant is exactly "
        "'the block is not lifted' and tests/125's sections (A) and (B) are what catch it; the regrain "
        "half stays intact, which is what shows those sections discriminate on their own.",
        [("  perform pgpm._remove_write_block(p_parent, v_mon);\n", "", 1)],
    ),
    "untransmute_keeps_regrain_capture": (
        "bench/untransmute_residue.sh",
        "Pre-#508 untransmute during an in-flight regrain: pgpm_regrain_capture rides the monolith child "
        "into the restored table, so untransmute's own `drop function <rel>_pgpm_regrain_capture()` dies "
        "with 'cannot drop function ... because other objects depend on it' and the whole call rolls back "
        "(no loss, but neither the documented refusal nor the clean reverse), and a reverse that got past "
        "that would orphan the not-yet-attached fine copies, which are standalone relations the parent's "
        "DROP never reaches. Removes only the regrain_cancel branch, so the write-block half stays intact "
        "and tests/125's section (C) is what catches it.",
        [("""  if exists (select 1 from pgpm.config where parent_table = p_parent and regrain_cursor is not null)
     or exists (select 1 from pgpm.part where parent_table = p_parent and not attached)
     or pgpm._regrain_capture_active(p_parent, v_mon) then
    perform pgpm.regrain_cancel(p_parent);
  end if;
""", "", 1)],
    ),
    # Issue #507, one mutation per site so each is proven caught on its own. PostgreSQL has no max(uuid)
    # or min(uuid) before 18, and three reads of a uuidv7 table's newest or next control value used
    # exactly those aggregates; the fix reads all three with ORDER BY ... LIMIT 1, the way
    # _frontier_native already did. Split three ways because the third site is only reached when a
    # chunk is budget-limited: a single combined mutation would be caught by the first site's failure
    # and prove nothing about whether tests/125 ever exercises the tie extension.
    "regrain_copy_watermark_max_uuid": (
        "bench/uuidv7_regrain_archive.sh",
        "Pre-#507 regrain_step: the copy microbatch resumed from `(select max(d2.<control>) from <fine "
        "child> d2)`. On a uuidv7 table that is 42883 'function max(uuid) does not exist' on the very "
        "first copy batch, so pgpm.regrain() and regrain_history() die synchronously, and once "
        "set_regrain has armed auto-regrain every maintain tick prepares, fails the copy, and logs "
        "skip_regrain, forever, with the capture trigger left on a monolith that can never be split. "
        "tests/125's parts (A) and (B) catch it: regrain() dying, and skip_regrain rows where the "
        "monolith should have become three months.",
        [("       where s.%2$I >= coalesce((select d2.%2$I from %7$I.%8$I d2 order by d2.%2$I desc limit 1), %3$L)\n",
          "       where s.%2$I >= coalesce((select max(d2.%2$I) from %7$I.%8$I d2), %3$L)\n", 1)],
    ),
    "archive_chunk_boundary_max_uuid": (
        "bench/uuidv7_regrain_archive.sh",
        "Pre-#507 _next_archive_chunk: the byte-budget window's newest control value was read with "
        "max(<control>) over the window. On a uuidv7 table with an archive_fn that is 42883 on every "
        "tick's archive step, logged as skip_archive; no ledger row is ever written, "
        "_archive_fully_covered stays false and retain() never drops the aged partition. tests/125 "
        "catches it twice: the direct _next_archive_chunk call on the frozen monolith dies, and part (C) "
        "finds skip_archive rows where the ledger should cover the aged month.",
        [("    'with w as (select t.%I as c, %s as c_text from %I.%I t where t.%I >= %L order by t.%I limit %s)\n"
          "     select (select count(*) from w), (select w.c_text from w order by w.c desc limit 1)',\n"
          "    cfg.control_column, v_cval_q, v_nsp, p_child, cfg.control_column,\n",
          "    'select count(*), max(%I)::text from (select %I from %I.%I t where t.%I >= %L order by t.%I limit %s) s',\n"
          "    cfg.control_column, cfg.control_column, v_nsp, p_child, cfg.control_column,\n", 1)],
    ),
    "archive_chunk_tie_min_uuid": (
        "bench/uuidv7_regrain_archive.sh",
        "Pre-#507 _next_archive_chunk: the extension of a full chunk past a run of ties read the next "
        "distinct control value with min(<control>). Reached only when the window fills the byte "
        "budget, so a fixture whose partitions each fit one chunk never gets here and a guard would "
        "pass with the defect present; tests/125 part (C) forces the aged month through a 400-byte "
        "budget, asserts that it took several chunks, and so finds the skip_archive rows this puts back.",
        [("    execute format('select %s from %I.%I t where t.%I > %L order by t.%I asc limit 1',\n"
          "                   v_cval_q, v_nsp, p_child, cfg.control_column, v_probe_hi_col, cfg.control_column)\n",
          "    execute format('select min(%I)::text from %I.%I t where t.%I > %L',\n"
          "                   cfg.control_column, v_nsp, p_child, cfg.control_column, v_probe_hi_col)\n", 1)],
    ),
    "archive_ledger_no_orphan_sweep": (
        "bench/archive_ledger_identity.sh",
        "Pre-#511 _archive_step: coverage recorded under a child_name that is no longer a tracked "
        "partition of the parent is left in the ledger. The ledger is keyed (parent_table, lo), so the "
        "partition that now holds that range collides on archive_ledger_pkey with its own first chunk, "
        "the step raises, maintain logs skip_archive every tick, and at archive_batch 1 nothing of the "
        "parent is archived or retired again. tests/125 case B (a partly archived partition renamed with "
        "pgpm.part.child_name updated and nothing else, the procedure the guide used to document) is what "
        "catches it.",
        [(ARCHIVE_LEDGER_ORPHAN_SWEEP, "", 1)],
    ),
    "regrain_swap_keeps_source_ledger": (
        "bench/archive_ledger_identity.sh",
        "Pre-#511 regrain swap: the source's pgpm.part row is deleted and the source dropped, but its "
        "pgpm.archive_ledger chunks stay recorded under its name. The tick's own orphan discard then clears "
        "them, so the run still completes; what names this mutant is tests/125 case A asserting, BEFORE any "
        "maintenance tick, that nothing is left under the source's name and that the swap logged one "
        "archive_coverage_reset for it, and case D asserting the same for a #266-renamed source.",
        [(REGRAIN_SWAP_LEDGER_RETIRE, "", 1)],
    ),
    "regrain_rename_orphans_ledger": (
        "bench/archive_ledger_identity.sh",
        "Pre-#511 #266 transitional rename: pgpm.part.child_name is updated to the source's on-target-grid "
        "name, pgpm.archive_ledger.child_name is not, so a partly archived source's coverage is left under "
        "a name nothing tracks (and, once the swap frees it, the first fine child's name). tests/125 case D "
        "asserts right after the preparing step that the chunk is recorded under the new name and nothing "
        "under the old.",
        [(REGRAIN_RENAME_LEDGER_CARRY, "", 1)],
    ),
    "archive_chunk_native_ties": (
        "bench/archive_chunk_ties.sh",
        "Pre-#513 _next_archive_chunk: the chunk ends at the next distinct COLUMN value decoded to the "
        "native grid, and nothing handles that decode landing on the chunk's own lo. For text_time and "
        "uuidv7 the decode truncates to the encoding's unit (a second for ObjectId and KSUID, a "
        "millisecond for uuidv7, ULID and cuid), so a unit holding at least a chunk's worth of rows (a "
        "bulk import minted within one second) makes v_stop = v_lo: the picker returns no chunk, "
        "_archive_step continues without a log row, and every later tick stops at the same place. The "
        "partition is never covered nor retired, and status() shows nothing. One site: the extension "
        "past the unit, removed whole, so the mutant falls through to the `no progress possible` return "
        "that follows it, which is the shipped behaviour exactly. tests/125's ledger identity (three "
        "chunks, the burst whole in the second) and its retire assertions are what catch it, through "
        "bench/archive_chunk_ties.sh.",
        [(ARCHIVE_CHUNK_TIES_BLOCK, "", 1)],
    ),
    "archive_chunk_native_tie_min_uuid": (
        "bench/archive_chunk_uuidv7_ties.sh",
        "Pre-#571 _next_archive_chunk: #513's extension past a native unit read the first row minted after "
        "it with min(<control>), the one aggregate #507 missed. PostgreSQL has no min(uuid) before 18, so "
        "on a uuidv7 table a millisecond holding a chunk's worth of rows raises 42883 at every pick: every "
        "archive tick logs skip_archive, no ledger row is written past the burst and the aged child is "
        "never covered nor retired. Reached only through a budget-limited chunk that ends inside one "
        "millisecond, which tests/125_uuidv7_regrain_archive never builds; tests/137's direct pick, its "
        "ledger identity (three chunks, the burst whole in the second) and its retire assertions are what "
        "catch it, through bench/archive_chunk_uuidv7_ties.sh, on PostgreSQL 17.",
        [("      execute format('select %s from %I.%I t where t.%I >= %L order by t.%I asc limit 1',\n"
          "                     v_cval_q, v_nsp, p_child, cfg.control_column,\n",
          "      execute format('select min(%I)::text from %I.%I t where t.%I >= %L',\n"
          "                     cfg.control_column, v_nsp, p_child, cfg.control_column,\n", 1),
         ("                                  cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz),\n"
          "                     cfg.control_column)\n"
          "        into v_next_distinct_col;\n",
          "                                  cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz))\n"
          "        into v_next_distinct_col;\n", 1)],
    ),
    "retire_drops_regrain_source": (
        "bench/retire_regrain_source.sh",
        "Pre-#519 retire(): the coarse source of an in-flight regrain is dropped once archiving covers it, "
        "and the regrain's fine copies (not-attached pgpm.part rows and their standalone tables, still "
        "holding the rows retention just dropped), its captured changes and config.regrain_cursor are left "
        "behind with no tick able to reclaim them: auto-regrain answers 'none' with no coarse child left and "
        "the janitor only tears down capture the cursor does not cover. tests/129 cases A (the scheduled "
        "path) and B (retire by hand, with a captured change pending) are what catch it.",
        [(RETIRE_REGRAIN_RECLAIM, "", 1)],
    ),
    "retire_cancels_whole_parent_regrain": (
        "bench/retire_regrain_source.sh",
        "The scoped _regrain_reclaim replaced by pgpm.regrain_cancel(p_parent), the operator verb: a superset "
        "that also tears capture off every other child, drops every not-attached copy of the parent and "
        "clears a cursor that belongs to a regrain of a DIFFERENT child, so retiring any covered partition "
        "cancels whatever regrain is in flight on the same parent. Cases A and B still pass (the cancel "
        "covers them); tests/129 case C, which retires a neighbour while the monolith's regrain is in "
        "flight and then finishes that regrain, is what names this mutant.",
        [(RETIRE_REGRAIN_RECLAIM, RETIRE_REGRAIN_CANCEL_WHOLE_PARENT, 1)],
    ),
    "transmute_incoming_fk_clones_dropped": (
        "bench/cutover_partitioned_referencer.sh",
        "Pre-#576 transmute cutover: step 0c selects the incoming keys to drop and record by confrelid "
        "alone, so a key declared on a PARTITIONED referencing table is iterated once per partition clone "
        "as well. Dropping the declared key removes its clones, the next iteration raises 'constraint ... "
        "does not exist', and the cutover rolls back every time, leaving the write-rejecting bound and the "
        "claim. tests/142 never converts, so its plan dies at the transmute.",
        [("        from pg_constraint c where c.confrelid = p_parent and c.contype = 'f' and c.conparentid = 0\n"
          "       order by c.conname\n",
          "        from pg_constraint c where c.confrelid = p_parent and c.contype = 'f'\n"
          "       order by c.conname\n", 1)],
    ),
    "transmute_index_name_unchecked": (
        "bench/carried_index_name_length.sh",
        "Pre-#592 transmute: no length check on the <index>_pgpm name step 9b casts to name. A 63-byte "
        "index name (PostgreSQL's own auto-name for a long table and column list) truncates back to "
        "itself, and the #311 collision guard refuses it as a leftover of an interrupted run, telling the "
        "operator to drop what is their own index. tests/143's refusal assertion sees that message.",
        [("  if v_long_idx_q is not null then\n", "  if false then\n", 1)],
    ),
    "transmute_trigger_capture_unlocked": (
        "bench/cutover_trigger_window.sh",
        "Pre-#593 transmute cutover, in its essential part: the triggers are captured with nothing on the "
        "table stronger than the staging LIKE's ACCESS SHARE, which does not exclude CREATE TRIGGER. The "
        "explicit ACCESS EXCLUSIVE before the capture is removed, so a trigger another session commits "
        "while the cutover waits on the incoming-FK drop's lock is never replayed and 7b drops it from the "
        "monolith: the guard's ev_b is on no relation and every row carries 1, not 11.",
        [("  execute format('lock table %s in access exclusive mode', p_parent::text);\n"
          "  select coalesce(array_agg(pg_get_triggerdef(oid) order by tgname), '{}'),\n",
          "  select coalesce(array_agg(pg_get_triggerdef(oid) order by tgname), '{}'),\n", 1)],
    ),
    "extend_to_no_lock_budget": (
        "bench/extend_to_lock_budget.sh",
        "Pre-#591 extend_to: nothing bounds the call by the lock table, only by p_max. It is a function, so "
        "every partition it creates holds its locks (the table, its indexes, its TOAST table) to the one "
        "transaction's end, and on a stock server (max_locks_per_transaction 64) a call a few thousand cells "
        "out passes its own dry count and dies with 53200 `out of shared memory` after ~2100 partitions, "
        "having filled the lock table every other backend shares on the way. One site: the refusal's "
        "condition, made unreachable, so the measurement still runs and the walk goes on exactly as the old "
        "function's did. tests/156's far call (budget + 1 cells, inside the default p_max, refused by pgpm "
        "where the mutant reaches the server's resource error) is what catches it.",
        [("        if v_projected > v_slots / 2 then\n", "        if false then\n", 1)],
    ),
    "throws_ok_null_pattern": (
        "bench/throws_pinned.sh",
        "Pre-#522 tests/72: the transition-table refusal asserted with throws_ok(..., NULL, desc). "
        "pgTAP's three-argument overload reads a second argument that is not five octets, NULL "
        "included, as the MESSAGE, so this resolves to errcode NULL and errmsg NULL and accepts any "
        "error at all, including the 2D000 a transmute that did NOT refuse raises at its first COMMIT "
        "inside the wrapper; the relkind check after it passes then too, because the statement rolled "
        "back. The first test-file mutation in this catalogue, deliberately: the defect is in the "
        "assertion, not in pgpm, and bench/throws_pinned.sh judges assertions, so the file it has to be "
        "pointed at is the test. Puts the exact pre-#522 text back, so the guard's probe finds a site "
        "that says ok where it must say not ok.",
        [("select throws_like($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$,\n"
          "  'pg_partition_magician: cannot transmute % -- the row trigger(s) (ev72t_after) use a transition table%',\n",
          "select throws_ok($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$, NULL,\n", 1)],
    ),
    "sigv4_transaction_start_stamp": (
        "bench/archive_sigv4_wall_clock.sh",
        "Pre-#520 SigV4 signers: archive.s3_signed_request and archive.s3_signed_request_bytea stamp "
        "x-amz-date, and so the credential scope's date, from now(), which is the TRANSACTION start "
        "time, not the wall clock. Every request a transaction makes carries the same stamp, and S3 "
        "and MinIO refuse one more than 15 minutes from their own clock (403 RequestTimeTooSkewed), so "
        "an archive.to_s3 multipart export or a maintain() tick that runs past fifteen minutes has "
        "every later request refused: a loud abort with the partition kept, not data loss, but the "
        "README's 'handles any size' broken for any partition that takes longer than that to export. "
        "Two sites, one per signer.",
        [
            ("  v_amz_date     := to_char(clock_timestamp() at time zone 'utc', 'YYYYMMDD\"T\"HH24MISS\"Z\"');\n",
             "  v_amz_date     := to_char(now() at time zone 'utc', 'YYYYMMDD\"T\"HH24MISS\"Z\"');\n", 2),
        ],
    ),
    "obtain_ceiling_encode_only": (
        "bench/obtain_int_ceiling.sh",
        "Pre-#578 obtain(): the grid-ceiling guard only runs _encode on the candidate's upper bound, "
        "and _encode is a passthrough for `id`, so it cannot see that an int column ends at 2^31-1. "
        "The first inexpressible bound in the lookahead raises from CREATE TABLE ... PARTITION OF "
        "instead, aborting the whole obtain and rolling back every partition built before it; "
        "maintain_obtain logs skip_obtain every tick, the grid freezes, and a write of an id with a "
        "perfectly expressible partition is refused. One site: the cast of the encoded bound to the "
        "control column's own type.",
        [("      execute format('select %L::%s', v_hi_lit, v_coltype);\n", "", 1)],
    ),
    "to_s3_compress_unread": (
        "bench/archive_to_s3_compress.sh",
        "Pre-#520 archive.to_s3: the synchronous NDJSON export never read archive.config.compress. "
        "With the flag on it uploaded plain NDJSON at <prefix><child>.ndjson, Content-Type "
        "application/x-ndjson, while pgpm_archive/README.md promised GZIP for either format and "
        "archive.to_s3_parquet and both archive_fn strategies honoured the flag; a reader pointed at "
        "the documented <prefix><child>.ndjson.gz found nothing. One site: the function's one read of "
        "the flag, so the mutant exports exactly as the old function did, at the old key with the old "
        "type, through both the single-PUT and the multipart path.",
        [
            ("  v_gzip := cfg.compress;\n", "  v_gzip := false;\n", 1),
        ],
    ),
    "retain_interval_normalised_compare": (
        "bench/retain_interval_sign.sh",
        "Pre-#565 _retain_nonnegative: an interval retain is judged with `>= interval '0'`, which "
        "PostgreSQL evaluates on a 30-day-month / 360-day-year normalisation, while the horizon it "
        "protects is calendar arithmetic on the wall clock. '-1 year 360 days' compares equal to zero, "
        "so transmute and set_retain accept it and _retain_boundary computes a horizon five or six days "
        "in the future from a hand-edited one, and the first tick drops every partition up to it, the one "
        "taking writes included. One site, the function every entry point shares. tests/131: the field-"
        "by-field refusals in (A), transmute's and set_retain's message pins in (B) and (C), and in (D) "
        "the tick's exact skip actions, every partition by name and every row by identity.",
        [
            ("  v_i := p_retain::interval;\n"
             "  -- date_trunc keeps the months, then the months and days; the differences isolate one field each, and a\n"
             "  -- single-field interval compares exactly\n"
             "  return date_trunc('month', v_i) >= interval '0'\n"
             "     and date_trunc('day', v_i) - date_trunc('month', v_i) >= interval '0'\n"
             "     and v_i - date_trunc('day', v_i) >= interval '0';\n",
             "  return p_retain::interval >= interval '0';\n", 1),
        ],
    ),
    "retain_nonnegative_admits_nan": (
        "bench/retain_nan.sh",
        "Pre-#649 _retain_nonnegative: the id branch is `p_retain::numeric >= 0` alone, and numeric "
        "orders NaN above every number, so 'NaN' is accepted as non-negative. The #451 defence in "
        "_retain_boundary then computes frontier - NaN = NaN, every partition's hi sorts below it, and "
        "one tick against a hand-edited config.retain drops every partition, the one taking writes "
        "included, with every row; regrain_step's own copy of the horizon marks every sub-range aged. "
        "One site, the function every entry point shares. tests/168: the rule in (A), set_retain's "
        "message pin in (B), the tick's exact skip actions with every partition by name and every row "
        "by identity in (C), and regrain_step's refusal in (D).",
        [
            ("  if p_kind = 'id' then return p_retain::numeric >= 0 and p_retain::numeric <> 'NaN'::numeric; end if;\n",
             "  if p_kind = 'id' then return p_retain::numeric >= 0; end if;\n", 1),
        ],
    ),
    "text_time_collation_positional_only": (
        "bench/text_time_numeric_collation.sh",
        "Pre-#568 _check_text_time_collation: one probe shape per adjacent digit pair at the declared "
        "width, '<prefix><d><max>...' < '<prefix><d+1><zero>...', which proves the digits are separated "
        "at the primary level for a collation that compares position by position and says nothing about "
        "one that weighs a run of decimal digits by its value. An ICU collation with numeric ordering "
        "('und-u-kn-true') passes it, since the zero padding extends the higher digit's run (1 < 2000...), "
        "so transmute accepts a cuid column under it and RANGE routing disagrees with base-36 order: late "
        "November rows land in the December partition and retain drops them a month early. Since #639 the "
        "check is a proof over every one- and two-digit string of the alphabet, so the proof's query is "
        "replaced by that single probe and nothing else. tests/134's refusals of a cuid and a decimal "
        "column on that collation are what catch it.",
        [(_TT_COLLATION_PROOF,
          "    with d(i, c) as (select i, substr(%1$L, i, 1) from generate_series(1, %2$s) as i),\n"
          "    probe(i, lo, hi) as (\n"
          "      select x.i, %3$L || x.c || %4$L, %3$L || y.c || %6$L\n"
          "        from d x join d y on y.i = x.i + 1\n"
          "    )\n"
          "    select lo, hi\n"
          "      from probe\n"
          "     where not ((lo::text collate %5$s) < (hi::text collate %5$s))\n"
          "     order by i limit 1\n"
          "  $q$, v_alphabet, length(v_alphabet), v_prefix,\n"
          "       repeat(substr(v_alphabet, length(v_alphabet), 1), greatest(coalesce(p_width, 1), 1) - 1), v_coll_q,\n"
          "       repeat(substr(v_alphabet, 1, 1), greatest(coalesce(p_width, 1), 1) - 1))\n",
          1)],
    ),
    "text_time_collation_probe_only": (
        "bench/text_time_collation_proof.sh",
        "Pre-#639 _check_text_time_collation: the probes of #456 and #568 in place of the proof. Each "
        "adjacent digit pair is compared at the declared width in three shapes ('<d><max>...' against "
        "'<d+1><zero>...', the opposite padding, and the first extended by every digit), which catches a "
        "case weight and a numeric ordering but never puts two letters of a contraction side by side "
        "unless one of them is a padding digit. da-x-icu ('aa' is a-ring, after 'z') passes for hex, so "
        "transmute accepts an ObjectId-shaped column on it and PostgreSQL routes a row decoded 28 November "
        "into the December partition, which retain drops on December's schedule; cs-x-icu ('ch') passes "
        "for Crockford base32. One site: the proof's query, replaced by the probe query it superseded. "
        "tests/274's refusals catch it.",
        [(_TT_COLLATION_PROOF,
          "    with d(i, c) as (select i, substr(%1$L, i, 1) from generate_series(1, %2$s) as i),\n"
          "    probe(i, n, lo, hi) as (\n"
          "      select x.i, 0, %3$L || x.c || %4$L, %3$L || y.c || %6$L\n"
          "        from d x join d y on y.i = x.i + 1\n"
          "      union all\n"
          "      select x.i, 1, %3$L || x.c || %6$L, %3$L || y.c || %4$L\n"
          "        from d x join d y on y.i = x.i + 1\n"
          "      union all\n"
          "      select x.i, 2 + s.i, %3$L || x.c || %4$L || s.c, %3$L || y.c || %6$L\n"
          "        from d x join d y on y.i = x.i + 1 cross join d s\n"
          "    )\n"
          "    select lo, hi\n"
          "      from probe\n"
          "     where not ((lo::text collate %5$s) < (hi::text collate %5$s))\n"
          "     order by i, n limit 1\n"
          "  $q$, v_alphabet, length(v_alphabet), v_prefix,\n"
          "       repeat(substr(v_alphabet, length(v_alphabet), 1), greatest(coalesce(p_width, 1), 1) - 1), v_coll_q,\n"
          "       repeat(substr(v_alphabet, 1, 1), greatest(coalesce(p_width, 1), 1) - 1))\n",
          1)],
    ),
    "parquet_numeric_scale_unsigned": (
        "bench/archive_parquet_negative_scale.sh",
        "Pre-#567 numeric decode: archive._pq_decimal_shape reads the typmod's scale as the unsigned low "
        "16 bits again, ignoring PostgreSQL 15's signed 11-bit field, so numeric(5,-2) comes out as scale "
        "2046. Every value is multiplied by 10^2046 before it is written, the leaf no longer declares "
        "DECIMAL(7,0), and the file no longer equals its numeric(7,0) twin's. One site: the scale line of "
        "the one helper both encoders take the shape from.",
        [
            ("  v_scale int4 := (((p_typmod - 4) & 2047) # 1024) - 1024;\n",
             "  v_scale int4 := (p_typmod - 4) & 65535;\n", 1),
        ],
    ),
    "parquet_timestamp_no_infinity": (
        "bench/archive_parquet_timestamp_infinity.sh",
        "Pre-#586 archive._pq_epoch_micros: the bare round(extract(epoch from v) * 1e6)::int8 with no case "
        "for 'infinity' or '-infinity', so a legal infinite timestamp or timestamptz raises 'cannot convert "
        "infinity to bigint' on every encode of its chunk: maintain() logs skip_archive each tick, and at "
        "archive_batch 1 the partition holding it and every younger one are never archived or retired. One "
        "site, the helper both timestamp branches call.",
        [
            ("  select case\n"
             "    when isfinite(v) then round(extract(epoch from least(v, '294247-01-10 04:00:54.775806+00'::timestamptz)) * 1000000)::int8\n"
             "    when v > 'epoch'::timestamptz then 9223372036854775807::int8\n"
             "    else -9223372036854775807::int8\n"
             "  end;\n",
             "  select round(extract(epoch from v) * 1000000)::int8;\n", 1),
        ],
    ),
    "parquet_timestamp_no_ceiling": (
        "bench/archive_parquet_timestamp_range.sh",
        "Pre-#664 archive._pq_epoch_micros: the infinities are still the INT64 sentinels, but a FINITE value "
        "is cast without the clamp at 294247-01-10 04:00:54.775806 UTC, so one past it (PostgreSQL's range "
        "runs 30 years further) raises 'bigint out of range' on every encode of its chunk, and one just past "
        "it comes out of extract(epoch)'s float8 fallback below its predecessor. maintain() logs skip_archive "
        "each tick and the partition holding it is never archived or retired. One site, the helper both "
        "timestamp branches call.",
        [
            ("    when isfinite(v) then round(extract(epoch from least(v, '294247-01-10 04:00:54.775806+00'::timestamptz)) * 1000000)::int8\n",
             "    when isfinite(v) then round(extract(epoch from v) * 1000000)::int8\n", 1),
        ],
    ),
    "parquet_decimal_scale_above_precision": (
        "bench/archive_parquet_scale_above_precision.sh",
        "Pre-#596 leaf shape: a numeric(p,s) column with s > p (legal since PostgreSQL 15) is declared "
        "DECIMAL(p, s) again, which Parquet forbids and pyarrow refuses for the whole file, while the "
        "upload and the ledger row succeed. One site: the widening branch of archive._pq_decimal_shape "
        "keeps the column's own precision.",
        [
            ("  elsif v_scale > v_precision then\n"
             "    p_precision := v_scale;\n",
             "  elsif v_scale > v_precision then\n"
             "    p_precision := v_precision;\n", 1),
        ],
    ),
    "parquet_range_refuses_keyless": (
        "bench/archive_parquet_keyless.sh",
        "Pre-#597 archive._pq_to_parquet_range_counted: a parent with no primary key or predicate-free "
        "unique constraint is refused on every chunk for want of a tiebreak, although pgpm.set_archive_fn "
        "accepts the Parquet strategy for it and the single snapshot (#462) makes the tiebreak unnecessary. "
        "Every maintain() tick logs skip_archive and nothing of the table is ever covered or retired. The "
        "exact pre-#597 refusal, put back in front of the ordering.",
        [
            ("  v_order_cols := array[p_control] || coalesce(v_key_cols, '{}'::name[]);\n",
             "  if v_key_cols is null then\n"
             "    raise exception 'archive._pq_to_parquet_range: % has no primary key or predicate/expression-free unique constraint; a resumable cross-partition range read cannot tiebreak ties on % without one (the same refusal pgpm.regrain_step already makes for keyless tables)',\n"
             "      p_parent, p_control;\n"
             "  end if;\n"
             "  v_order_cols := array[p_control] || v_key_cols;\n", 1),
        ],
    ),
    "regrain_restart_needs_cursor": (
        "bench/regrain_restart_null_cursor.sh",
        "Pre-#569 regrain_step: the prepare tick discards the copies made without change capture only "
        "when config.regrain_cursor IS NOT NULL. The janitor's documented backstop (a cursor cleared by "
        "hand, then _enforce_regrain_capture reaping the capture it no longer covers) leaves the copies "
        "with the cursor NULL, so the next run re-installs capture, resumes from them, and the swap "
        "attaches rows that never saw the changes made while capture was off: an UPDATE reverts, a "
        "DELETE comes back, an INSERT vanishes. Puts the cursor gate back around the discard and keeps "
        "the log condition as it was, so the mutant is the old branch exactly. tests/135's restart row, "
        "dropped copy and rows-through-the-swap identities are what catch it.",
        [("""    for r in execute format(
      'select child_name from pgpm.part where parent_table = %L::regclass and not attached'
      || ' and lo::%s >= %L::%s and hi::%s <= %L::%s',
      p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast)
    loop
      perform pgpm._regrain_drop_copy(p_parent, v_nsp, r.child_name);   -- #631: by recorded oid
      v_made := v_made + 1;
    end loop;
    if cfg.regrain_cursor is not null or v_made > 0 then
      insert into pgpm.log (parent_table, action, lo, hi, rows, method)
        values (p_parent, 'regrain_restart', v_lo, v_hi, v_made, 'copies predate change capture');
    end if;
""", """    if cfg.regrain_cursor is not null then
      for r in execute format(
        'select child_name from pgpm.part where parent_table = %L::regclass and not attached'
        || ' and lo::%s >= %L::%s and hi::%s <= %L::%s',
        p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast)
      loop
        perform pgpm._regrain_drop_copy(p_parent, v_nsp, r.child_name);   -- #631: by recorded oid
        v_made := v_made + 1;
      end loop;
      insert into pgpm.log (parent_table, action, lo, hi, rows, method)
        values (p_parent, 'regrain_restart', v_lo, v_hi, v_made, 'copies predate change capture');
    end if;
""", 1)],
    ),
    "regrain_reconcile_bare_text": (
        "bench/regrain_reconcile_datestyle.sh",
        "Pre-#570 _regrain_reconcile: each captured key's control value is rendered with a bare ::text, "
        "in the session's DateStyle and TimeZone, before _grid_floor parses it back to pick the key's "
        "fine child. Under SQL DateStyle and Asia/Kolkata the text reads 'IST', which the default "
        "timezone_abbreviations parse as Israel (+02), so every key is filed 3.5 hours late: a captured "
        "DELETE is consumed against the wrong fine child and the swap brings the row back, and a "
        "captured UPDATE or INSERT is reinserted into a child whose CHECK refuses it. Both branches of "
        "the render are reverted (a timestamptz column's own text, a naive column's instant), which is "
        "the old expression exactly; tests/136's evd identity catches the silent loss and its ev and "
        "evn swaps catch the wedge.",
        [("""  v_kctl_native_q := case when pgpm._control_naive(p_parent, cfg.control_column)
                          then format('pgpm._ts_text(k.%I::timestamp at time zone %L)', cfg.control_column, cfg.partition_tz)
                          when cfg.control_kind = 'time'
                          then format('pgpm._ts_text(k.%I)', cfg.control_column)
                          else format('k.%I::text', cfg.control_column) end;
""", """  v_kctl_native_q := case when pgpm._control_naive(p_parent, cfg.control_column)
                          then format('(k.%I::timestamp at time zone %L)::text', cfg.control_column, cfg.partition_tz)
                          else format('k.%I::text', cfg.control_column) end;
""", 1)],
    ),
    "set_partition_tz_newest_bound_only": (
        "bench/set_partition_tz_every_bound.sh",
        "Pre-#583 set_partition_tz: only the newest attached bound is checked against the new zone's "
        "lattice. UTC and Europe/London agree on every month edge from November to March and on none "
        "from April to October, so a UTC month grid whose monolith ends on October 1 and whose top is "
        "December 1 is moved to London, and the monolith can then never be regrained: its last clamped "
        "sub-range renders the label of the forward cell at October 1, gets no fine child, and every "
        "swap refuses. The every-bound check is removed whole and the top check left as it was. "
        "tests/151's refusal (named bound, partition_tz untouched, nothing logged) is what catches it.",
        [("""  if found then
    raise exception 'pg_partition_magician: set_partition_tz(%, %) refused -- partition % has a bound at %""",
          """  if false then
    raise exception 'pg_partition_magician: set_partition_tz(%, %) refused -- partition % has a bound at %""", 1)],
    ),
    "grid_floor_month_later_midnight": (
        "bench/month_floor_doubled_midnight.sh",
        "Pre-#584 _grid_floor: the month branch returns the boundary of the value's wall month even when "
        "that boundary lies above the value. Where a fall-back repeats midnight on the 1st "
        "(America/Havana on 2020-11-01 and 2026-11-01) the boundary is the later midnight, so a value in "
        "the first occurrence of that hour floored to a point above itself; transmute took the floor of "
        "the oldest row as the monolith's lo, its bound CHECK excluded that row, and VALIDATE failed on "
        "every run. The step back to the previous boundary is disabled, and nothing else. tests/152's "
        "hand-derived floors and its end-to-end conversion are what catch it.",
        [("      if v_out > ts then\n        k := k - v_months;\n", "      if false then\n        k := k - v_months;\n", 1)],
    ),
    "maintain_all_fixed_sweep_order": (
        "bench/maintain_all_sweep_turns.sh",
        "Pre-#579 maintain_all: the sweep visits the parents `order by parent_table`, the same fixed order "
        "every tick. The whole sweep is one top-level statement, so statement_timeout runs across all of "
        "it, and the query_canceled that ends it escapes maintain()'s `when others`: a parent with a "
        "backlog near the front spends the shared clock on every tick and every parent behind it is cut "
        "short on every tick, never archived or retired, although its own maintain() fits the timeout. "
        "Only the ORDER BY goes back; the turn stamps are still written, so the mutant is exactly 'the "
        "order ignores them'. tests/147's tick 2, which must lead with the parent tick 1 cut short, is "
        "what catches it, in both of its scenarios.",
        [("  for r in select parent_table from pgpm.config order by sweep_turn_at asc nulls first, parent_table loop\n",
          "  for r in select parent_table from pgpm.config order by parent_table loop\n", 1)],
    ),
    "maintain_all_no_first_turn_stamp": (
        "bench/maintain_all_sweep_turns.sh",
        "The #579 fix without its second half: turns are stamped only when a parent's maintain() "
        "returns, and the sweep's first parent is not stamped before it starts. A parent whose own tick "
        "overruns the timeout then never gets a stamp at all, so it leads, and is cancelled in, every "
        "sweep, and every other parent is cut short on every tick: the fixed-order starvation back, "
        "now for everyone rather than for the tail. tests/147's second scenario (P overruns on its own, "
        "Q must retire on tick 2) is what catches it; the first scenario passes against this mutant, "
        "which is why it is a mutation of its own.",
        [("    if v_first then   -- #579: the sweep's first parent has had its turn once it starts\n"
          "      if pgpm._config_try_lock(r.parent_table) then\n"
          "        update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;\n"
          "      end if;\n"
          "      commit;\n"
          "      v_first := false;\n"
          "    end if;\n",
          "", 1)],
    ),
    "maintain_regrain_stale_target": (
        "bench/maintain_sweep_reads_tap.sh",
        "Pre-#729 maintain(): auto-regrain is dispatched from the regrain_to the tick read at its top, "
        "three COMMITs before its regrain block, never re-read under the per-parent regrain lock. A "
        "set_regrain(t, null) committed mid-tick (inside the archive step, say) is overridden: the tick "
        "prepares a new run (capture trigger, TRUNCATE guard, cursor) that nothing drives, and a second "
        "set_regrain(t, null) by design changes nothing. One site: the re-read under the lock becomes the "
        "stale value, so the lock is still taken and only what is read under it is wrong. tests/191's rg_off "
        "tick, whose operator turns auto-regrain off from inside the archive step, is what catches it.",
        [("      select regrain_to into v_regrain_to from pgpm.config where parent_table = p_parent;\n",
          "      v_regrain_to := cfg.regrain_to;\n", 1)],
    ),
    "maintain_obtain_all_fixed_order": (
        "bench/maintain_sweep_reads_tap.sh",
        "Pre-#634 maintain_obtain_all: the obtain sweep visits the parents `order by parent_table` and "
        "stamps no turns, though docs/reference.md says it runs in maintain_all's order. The sweep is one "
        "top-level statement, so statement_timeout runs across all of it and the query_canceled that ends "
        "it escapes maintain_obtain's `when others`: a parent whose obtain overruns the clock is first on "
        "every sweep and every parent behind it is denied obtain on every sweep. The loop goes back to the "
        "pre-fix one exactly. tests/192's part A (oa obtained first) and part C (sb starved behind sa on "
        "the second sweep) both catch it.",
        [("  for r in select parent_table from pgpm.config\n"
          "            order by sweep_turn_at asc nulls first, parent_table loop   -- #634: maintain_all()'s order\n"
          "    if v_first then   -- #634: as in maintain_all(), the first parent has had its turn once it starts\n"
          "      if pgpm._config_try_lock(r.parent_table) then\n"
          "        update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;\n"
          "      end if;\n"
          "      commit;\n"
          "      v_first := false;\n"
          "    end if;\n"
          "    call pgpm.maintain_obtain(r.parent_table, v_status);\n"
          "    if pgpm._config_try_lock(r.parent_table) then\n"
          "      update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;\n"
          "    end if;\n"
          "    commit;\n",
          "  for r in select parent_table from pgpm.config order by parent_table loop\n"
          "    call pgpm.maintain_obtain(r.parent_table, v_status);\n"
          "    commit;\n", 1)],
    ),
    "maintain_obtain_all_no_first_turn_stamp": (
        "bench/maintain_sweep_reads_tap.sh",
        "The #634 fix without its second half, as maintain_all_no_first_turn_stamp is for #579: the obtain "
        "sweep follows the turn order and stamps a parent when its maintain_obtain returns, but does not "
        "stamp the sweep's first parent before it starts. A parent whose own obtain overruns the timeout is "
        "then never stamped, so it leads, and is cancelled in, every obtain sweep, and every parent behind "
        "it is denied obtain. tests/192's part C (sa overruns, sb must obtain on the second sweep) catches "
        "it; parts A and B pass against it, which is why it is a mutation of its own.",
        [("    if v_first then   -- #634: as in maintain_all(), the first parent has had its turn once it starts\n"
          "      if pgpm._config_try_lock(r.parent_table) then\n"
          "        update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;\n"
          "      end if;\n"
          "      commit;\n"
          "      v_first := false;\n"
          "    end if;\n",
          "", 1)],
    ),
    "regrain_candidate_outside_handler": (
        "bench/regrain_candidate_lock_race.sh",
        "Pre-#590 maintain(): the auto-regrain candidate is searched for BEFORE the regrain step's "
        "exception handler. The search takes the grid floor from pgpm._frontier_native, which reads the "
        "parent under the tick's 200 ms lock_timeout, so while another session holds a lock on a parent "
        "with regrain_to set the 55P03 raises out of maintain() into maintain_all(), which has no "
        "handler by design, and the sweep stops before every parent ordered after it: no write-block, "
        "archive or retain for them while the lock lasts. Moves the handler's `begin` from above the "
        "search to below it, which is the pre-fix block structure exactly: the search unguarded, the "
        "regrain_step call still guarded. (#729's lock and re-read of regrain_to, which open the search, "
        "move out of the handler with it.)",
        [("    begin   -- #590: the candidate search is part of the regrain step\n"
          "      perform pgpm._regrain_lock(p_parent);   -- #729: before the re-read\n",
          "      perform pgpm._regrain_lock(p_parent);   -- #729: before the re-read\n", 1),
         ("        into v_regrain_child;\n      end if;\n      v_batch := cfg.regrain_batch;   -- regrain's own microbatch size\n",
          "        into v_regrain_child;\n      end if;\n    begin\n      v_batch := cfg.regrain_batch;   -- regrain's own microbatch size\n", 1)],
    ),
    "untransmute_inline_validate": (
        "bench/untransmute_fk_validate_lock.sh",
        "Pre-#577 untransmute: each preserved incoming FK on an unpartitioned referencing table is "
        "re-added NOT VALID and then VALIDATEd in the same call, which is one transaction already "
        "holding ACCESS EXCLUSIVE on the restored table, so every reader and writer of it waits out a "
        "full scan of the referencing table (and an orphan written while the key was suspended rolls "
        "the whole reverse back). One site: the operator notice that replaced the VALIDATE becomes the "
        "VALIDATE again, so the mutant is the shipped function exactly.",
        [
            (UNTRANSMUTE_FK_NOTICE,
             "      execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);\n",
             1),
        ],
    ),
    "archive_huffman_temp_table": (
        "bench/archive_huffman_lock_entries.sh",
        "Pre-#587 archive._pq_huffman_lengths: its merge queue is a temp table created and dropped on "
        "every call, three calls per GZIP encode (literal/length, distance, code-length codes). A dropped "
        "relation's locks are held to transaction end, so each call leaves ~15 entries in the SHARED lock "
        "table until commit, and one pgpm._archive_step transaction archiving 25 partitions of a "
        "29-column compressed-Parquet table (~725 encodes) exhausts it at the default "
        "max_locks_per_transaction: 53200 out of shared memory for every session in the cluster, "
        "skip_archive, nothing archived, the same again every tick. The codes it builds are identical, "
        "so every known-answer assertion in tests/archive/db/22 still passes; the two lock-growth zeros "
        "are what name it. Two sites: the declarations and the queue, both restored verbatim.",
        [
            (ARCHIVE_HUFF_DECL_ARRAYS, ARCHIVE_HUFF_DECL_TEMP_TABLE, 1),
            (ARCHIVE_HUFF_QUEUE_ARRAYS, ARCHIVE_HUFF_QUEUE_TEMP_TABLE, 1),
        ],
    ),
    "transmute_resume_any_step": (
        "bench/transmute_resume_lattice.sh",
        "Pre-#574 _transmute: a resume reuses the claim's bound (and, since #506, its zone) whatever step "
        "and anchor the re-run is given, and registers the NEW ones. The recorded bound sits on the first "
        "attempt's grid, so a re-run with another step leaves the monolith's hi off the registered grid: "
        "obtain skips the new grid's cell that overlaps the monolith and starts one cell later, a "
        "permanent hole right past the monolith's hi where every write fails with no partition found. "
        "The lattice check is removed whole, and nothing else. tests/139's step-7 and anchor-5 re-runs of "
        "a claim recorded on the step-10 grid are what catch it: neither is refused, each dies at its "
        "first COMMIT inside throws_like with 2D000, and the refusal's message is pinned.",
        [(TRANSMUTE_RESUME_LATTICE_RE, "", 1)],
    ),
    "transmute_resume_any_column": (
        "bench/transmute_resume_control_column.sh",
        "Pre-#628 _transmute: a resume reuses the claim's bound whatever control column the re-run is "
        "given. The bound and its validated pgpm_monolith_bound CHECK are on the first attempt's column, "
        "phases 1 and 2 are skipped because a validated constraint by that name exists, and the cutover "
        "partitions by the NEW column: the CHECK does not imply the new partition bound, so the ATTACH "
        "scans the whole table under ACCESS EXCLUSIVE. The comparison is removed whole and the recording "
        "kept. tests/182's re-run on b of a claim recorded on a is what catches it: it is not refused, "
        "dies at its first COMMIT inside throws_like with 2D000, and the refusal's message is pinned.",
        [(TRANSMUTE_RESUME_COLUMN_RE, "", 1)],
    ),
    "transmute_reap_by_name": (
        "bench/transmute_reap_identity.sh",
        "Pre-#575 _transmute_reap and transmute_abort: the half-converted table is resolved by the "
        "schema and name the claim recorded (nsp, rel), not by the claim's oid. A table renamed or moved "
        "to another schema after its conversion failed reads as gone: the reaper deletes the claim and "
        "leaves the write-rejecting pgpm_monolith_bound CHECK with nothing recording it, and "
        "transmute_abort, called by the new name, alters the old one, which no longer exists. Three "
        "sites: the reaper's existence test and both ALTERs. tests/140's renamed and moved tables (bound "
        "still there after the sweep, no transmute_reap logged under their oid) and its abort by the new "
        "name are what catch it.",
        [
            ("    if not exists (select 1 from pg_class c where c.oid = r.parent_table) then\n",
             "    if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace\n"
             "                    where n.nspname = r.nsp and c.relname = r.rel) then\n", 1),
            ("    execute format('alter table %s drop constraint if exists pgpm_monolith_bound', r.parent_table::text);\n",
             "    execute format('alter table %I.%I drop constraint if exists pgpm_monolith_bound', r.nsp, r.rel);\n", 1),
            # transmute_abort's, inside the lock_not_available block #708 put around it
            ("    execute format('alter table %s drop constraint if exists pgpm_monolith_bound', p_parent::text);\n"
             "  exception when lock_not_available then\n",
             "    execute format('alter table %I.%I drop constraint if exists pgpm_monolith_bound', r.nsp, r.rel);\n"
             "  exception when lock_not_available then\n", 1),
        ],
    ),
    "transmute_no_step_obtain_preflight": (
        "bench/transmute_step_preflight.sh",
        "Pre-#581 _transmute: nothing checks the step's sign, a date column's step against whole days, or "
        "p_obtain against the non-negative rule set_obtain applies. A negative step commits an "
        "unsatisfiable pgpm_monolith_bound CHECK in phase 1 and the table rejects every write until an "
        "abort; a sub-day step on a date column validates a CHECK of dt < current_date and dies in the "
        "cutover on an empty-range hourly cell; p_obtain => -1 registers a grid obtain never extends. All "
        "three refusals are removed, whole. tests/141 pins each refusal by its own message, so each call "
        "that is not refused dies at its first COMMIT inside throws_like with 2D000 and fails there.",
        [
            (TRANSMUTE_STEP_OBTAIN_PREFLIGHT_RE, "", 1),
            (TRANSMUTE_DATE_WHOLE_DAYS_RE, "", 1),
        ],
    ),
    "regrain_fine_child_by_name": (
        "bench/regrain_parent_rename_midcopy.sh",
        "Pre-#585 regrain_step: the copy branch finds the in-progress sub-range's fine child by a name "
        "rendered from the parent's CURRENT relname (to_regclass(_part_name(v_rel, ...))) rather than by "
        "its bounds in pgpm.part. After an ALTER TABLE ... RENAME of the parent mid-copy the rendered name "
        "no longer matches the child the copy started, so the next tick mints a second not-attached child "
        "for the same [lo, hi) and records it beside the first, and the swap fails 'would overlap' on "
        "every tick until regrain_cancel. One site: the bounds lookup goes, the render stays. tests/153 "
        "catches it at the first tick after the rename (the batch lands in a new rn2_p... child) and "
        "again at the swap.",
        [("    select p.child_name into v_sub_name from pgpm.part p\n"
          "     where p.parent_table = p_parent and not p.attached\n"
          "       and not pgpm._native_gt(cfg.control_kind, p.lo, v_sub_lo) and not pgpm._native_gt(cfg.control_kind, v_sub_lo, p.lo)\n"
          "       and not pgpm._native_gt(cfg.control_kind, p.hi, v_sub_hi) and not pgpm._native_gt(cfg.control_kind, v_sub_hi, p.hi);\n"
          "    v_sub_name := coalesce(v_sub_name,\n"
          "                           pgpm._regrain_sub_name(v_rel, cfg, v_step, v_sub_lo, v_sub_hi));   -- #783\n",
          "    v_sub_name := pgpm._regrain_sub_name(v_rel, cfg, v_step, v_sub_lo, v_sub_hi);\n", 1)],
    ),
    "regrain_copy_into_named_relation": (
        "bench/regrain_copy_name_clash.sh",
        "Pre-#631 regrain_step: the copy branch skips its CREATE whenever the sub-range's name resolves "
        "and inserts into whatever relation it resolves to. A managed table renamed aside keeps its "
        "partitions' names, so regraining a new table created under the old name copies its rows into "
        "the old table's attached partition (49 rows in F3-05), and a copy whose name another table has "
        "taken over is copied into the stranger. Both refusals become 'if false'. tests/172 catches it at "
        "the refusals it pins and at the other table's rows, named one by one.",
        [("    if v_sub_now is not null and not v_sub_known then\n", "    if false then\n", 1),
         ("    if v_sub_now is not null and v_sub_oid is not null and v_sub_now::oid <> v_sub_oid then\n",
          "    if false then\n", 1)],
    ),
    "regrain_copy_dropped_by_name": (
        "bench/regrain_copy_name_clash.sh",
        "Pre-#631 regrain_cancel: every not-attached copy is dropped with `drop table %I.%I` on its "
        "recorded name, not by the child_oid regrain_step recorded, so a copy renamed aside survives the "
        "cancel and the unrelated table that took its old name is the one dropped. One site: "
        "_regrain_drop_copy's anchored branch is never taken. tests/172 (B) catches it: the recorded oid "
        "is still in pg_class and the squatter's row is gone.",
        [("  if v_oid is null then\n    execute format('drop table if exists %I.%I', p_nsp, p_child);\n",
          "  if true then\n    execute format('drop table if exists %I.%I', p_nsp, p_child);\n", 1)],
    ),
    "regrain_recreated_copy_oid_stale": (
        "bench/regrain_copy_name_clash.sh",
        "#631's drop by recorded oid without the recreate's re-anchoring: a copy dropped by hand "
        "mid-regrain is created again under its pgpm.part row, but the row keeps the dead oid, so "
        "regrain_cancel drops nothing and the recreated copy is left on disk for good (the next regrain "
        "then refuses its name as a relation it did not create). One site: the child_oid update becomes "
        "'if false'. tests/172 (C) catches it: a relation is still under the copy's name after the cancel.",
        [("      if v_sub_known then\n        update pgpm.part set child_oid",
          "      if false then\n        update pgpm.part set child_oid", 1)],
    ),
    "regrain_reconcile_into_named_relation": (
        "bench/regrain_reconcile_identity.sh",
        "Issue #723 put back: _regrain_reconcile writes a completed sub-range's captured changes into "
        "whatever relation bears the fine child's recorded NAME, never asking child_oid. A copy renamed "
        "aside and an unrelated table created under its old name then loses its row with a captured key "
        "and gains the managed table's row. One site: the fine child resolves by name, not through "
        "_regrain_copy_rel. tests/183 catches it at the refusal it pins and at the stranger's rows, named "
        "one by one.",
        [("    v_sub_rel := pgpm._regrain_copy_rel(p_parent, v_sub_name, 'reconcile captured changes into');\n",
          "    v_sub_rel := format('%I.%I', pgpm._child_nsp(p_parent, v_sub_name), v_sub_name)::regclass;\n", 1)],
    ),
    "regrain_swap_attaches_named_relation": (
        "bench/regrain_child_oid_sites.sh",
        "Issue #707 (the swap) put back: the swap attaches each copy by its recorded NAME and drops that "
        "relation's _ck, never asking child_oid. A completed copy renamed aside and a table created LIKE it "
        "INCLUDING ALL under its old name is attached in its place, the source is dropped, and the copied "
        "rows leave the managed table. Two sites: the pre-DETACH identity check goes, and the attach loop "
        "resolves by name. tests/184 (A) catches it at the refusal and at rows 10, 20, 30.",
        [("    perform pgpm._regrain_copy_rel(p_parent, r.child_name, 'attach');\n", "    null;\n", 1),
         ("    v_copy := pgpm._regrain_copy_rel(p_parent, r.child_name, 'attach');   -- #707: by recorded oid\n",
          "    v_copy := format('%I.%I', v_nsp, r.child_name)::regclass;\n", 1)],
    ),
    "regrain_cancel_triggers_by_name": (
        "bench/regrain_child_oid_sites.sh",
        "Issue #707 (regrain_cancel) put back: the capture and TRUNCATE-guard triggers are dropped `on` each "
        "pgpm.part row's NAME, so a source renamed aside keeps both for good and a relation that took its "
        "name loses its own triggers of those names. One site: the recorded-oid branch is never taken. "
        "tests/184 (B) catches it on both relations' trigger lists.",
        [("    v_rel := pgpm._regrain_child_rel(p_parent, r.child_name);   -- #768: a null child_oid in its own schema\n",
          "    v_rel := to_regclass(format('%I.%I', v_nsp, r.child_name));\n", 1)],
    ),
    "regrain_copy_row_other_bounds": (
        "bench/regrain_child_oid_sites.sh",
        "Issue #707 (the create branch) put back: a pgpm.part row already holding the rendered name over "
        "OTHER bounds is not refused, so the copy is created and filled while `on conflict do nothing` "
        "leaves that row describing a different range. One site: the refusal becomes 'if false'. "
        "tests/184 (C) catches it at the refusal and at the relation created under the name.",
        [("    if not v_sub_known then\n      select p.lo, p.hi into v_held_lo, v_held_hi from pgpm.part p\n",
          "    if false then\n      select p.lo, p.hi into v_held_lo, v_held_hi from pgpm.part p\n", 1)],
    ),
    "obtain_name_relations_only": (
        "bench/regrain_child_oid_sites.sh",
        "Issue #707 (obtain) put back: _obtain_name asks to_regclass alone whether a cell's name is free, so "
        "a TYPE holding it reaches CREATE TABLE, which dies with 42710 and unwinds every other cell of the "
        "call, on every tick. Two sites, the plain name and the explicit-range one. tests/184 (D) catches "
        "it: obtain raises instead of building the three cells around the squatted one.",
        [("    if pgpm._type_squatter(p_nsp, v_name) is not null then return null; end if;   -- #707\n", "", 1),
         ("is not null then return null; end if;\n  if pgpm._type_squatter(p_nsp, v_name) is not null then return null; end if;   -- #707\n",
          "is not null then return null; end if;\n", 1)],
    ),
    "transmute_orphan_guard_relations_only": (
        "bench/regrain_child_oid_sites.sh",
        "Issue #707 (transmute) put back: the orphan-child guard looks in pg_class alone, so a domain or enum "
        "named like one of the parent's children passes the conversion and obtain meets it later. One site: "
        "the pg_type half of the guard matches nothing. tests/184 (E) catches it: the call is not refused.",
        [("       and pgpm._type_squatter(v_nsp, t.typname) is not null\n     limit 1;\n",
          "       and false\n     limit 1;\n", 1)],
    ),
    "regrain_step_sign_unchecked": (
        "bench/regrain_step_positive.sh",
        "Pre-#588: nothing tests that a regrain target step moves the grid forward. set_regrain stores "
        "'0' or '-100' (both are 'finer' than any partition_step, so the #341 comparison passes them), "
        "and regrain_step runs with them: '0' divides by zero in _grid_floor on every tick, a negative "
        "step makes 'nosubdiv' trivially false, mints a fine child with inverted bounds and walks the "
        "cursor below lo, and pgpm.regrain() spins toward its 10,000,000-iteration limit. One site: "
        "_regrain_step_forward's test, which both entry points call, becomes 'if false'. tests/154 "
        "catches it at every refusal it pins, id and time grids alike.",
        [("  if not pgpm._native_gt(cfg.control_kind,\n"
          "                         pgpm._grid_next(cfg.control_kind, p_step, cfg.partition_anchor, cfg.partition_tz),\n"
          "                         cfg.partition_anchor) then\n",
          "  if false then\n", 1)],
    ),
    "part_name_minute_floor": (
        "bench/part_name_labels_injective.sh",
        "Pre-#582 _part_name: the finest time label is the minute (YYYY_MM_DD_HH24MI) whatever the step, "
        "so the two cells of a 30-second step (and every sub-second cell of a second) render one name. "
        "obtain skips the second cell as already existing, so every other forward cell is never built "
        "(nothing logged, writes there refused with 'no partition of relation found'), and regrain toward "
        "30 seconds copies the second cell's rows into the first cell's child, whose CHECK refuses them "
        "with a raw 23514 on every attempt. The second and microsecond branches go, nothing else. "
        "tests/150's sub-minute adapter pairs, its 30-second obtain grid and its uuidv7 regrain toward "
        "30 seconds are what catch it.",
        [("    elsif v_secs  >= 60                          then fmt := 'YYYY_MM_DD_HH24MI';\n"
          "    elsif v_secs  >= 1                           then fmt := 'YYYY_MM_DD_HH24MISS';\n"
          "    else                                              fmt := 'YYYY_MM_DD_HH24MISS_US';\n",
          "    else                                              fmt := 'YYYY_MM_DD_HH24MI';\n", 1)],
    ),
    "part_name_id_label_truncated": (
        "bench/part_name_labels_injective.sh",
        "Pre-#582 _part_name: an id label is lpad(floor(lo)::text, 19, '0'). lpad TRUNCATES a longer "
        "string, so on a numeric grid crossing 10^19 the cell at 10^19 renders the name of the cell at "
        "10^18, obtain skips it as existing and writes into [10^19, 1.1*10^19) are refused; and floor() "
        "drops a fraction, so a regrain toward 0.5 puts the cells at 1 and 1.5 under one name and the copy "
        "fails 23514. Both _part_name call sites go back to the old expression. tests/150's id adapter "
        "cases, its grid past 10^19 and its regrain toward 0.5 are what catch it.",
        [("    v_lo := pgpm._id_label(p_lo_native);\n"
          "    if v_coarse then v_hi := pgpm._id_label(p_hi_native); end if;\n",
          "    v_lo := lpad(floor(p_lo_native::numeric)::text, 19, '0');\n"
          "    if v_coarse then v_hi := lpad(floor(p_hi_native::numeric)::text, 19, '0'); end if;\n", 1)],
    ),
    # Issue #589, one mutation per defect, both of pgpm_core/uninstall.sql, so each is proven caught on
    # its own by tests/155 through bench/uninstall_residue.sh.
    "uninstall_drops_pending_fk": (
        "bench/uninstall_residue.sh",
        "Pre-#589 uninstall.sql: `drop schema pgpm cascade` takes pgpm.dropped_fk, the only record of an "
        "incoming foreign key transmute(..., p_incoming_fks => 'preserve') dropped and pgpm has not "
        "restored yet (a paused table's never are), with no restore, no refusal and no warning, so the key "
        "is gone for good. Removes the whole restore-then-refuse step and leaves the bare schema drop, "
        "which is the old script exactly. tests/155 catches it twice: the first uninstall raises nothing "
        "where it must refuse on the key it cannot restore, and after the second the restorable key is "
        "not back on its referencing table.",
        [(re.compile(r"^  begin\n    select coalesce\(max\(id\), 0\) into v_mark from pgpm\.log;\n.*?"
                     r"^    when undefined_table then null;\n  end;\n", re.MULTILINE | re.DOTALL),
          "", 1)],
    ),
    "uninstall_keeps_regrain_copies": (
        "bench/uninstall_residue.sh",
        "Pre-#589 uninstall.sql during an in-flight regrain: the change capture is torn down but the "
        "regrain is not abandoned, so its not-yet-attached fine copies (standalone tables holding copies "
        "of rows the source still holds) stay in the operator's schema, and pgpm.part, the only record "
        "that they are pgpm's staging copies, goes with the schema. Removes only the regrain_cancel "
        "branch; the key half stays intact, so tests/155's section (B) is what catches it.",
        [("""      if v_copies_q is not null
         or exists (select 1 from pgpm.config where parent_table = r.parent_table and regrain_cursor is not null) then
        perform pgpm.regrain_cancel(r.parent_table);
      end if;
""", "", 1)],
    ),
    "uninstall_keeps_hypertable_capture": (
        "bench/uninstall_hypertable_capture.sh",
        "Pre-#737 uninstall.sql after a from_hypertable_copy(p_track_changes => true) that was never cut "
        "over: only regrain's change capture is swept, so the module's <rel>_pgpm_delta, "
        "<rel>_pgpm_delta_fn() and the <rel>_pgpm_delta_trg trigger on the live hypertable and its chunks "
        "survive the uninstall and go on logging every write. Deletes the sweep (its comment through its "
        "loop) from the schema drop's block, which is the old script's behaviour, so tests/timescale/db/32's "
        "five removal assertions fail and its look-alike ones still pass.",
        [(re.compile(r"^  -- Drop from_hypertable's change capture \(#737\)\..*?^  end loop;\n\n",
                     re.MULTILINE | re.DOTALL), "", 1)],
    ),
    "uninstall_hypertable_capture_by_name": (
        "bench/uninstall_hypertable_capture.sh",
        "#737's sweep keyed on a name pattern instead of the module's record: every table ending in "
        "_pgpm_delta, with the function beside it, is dropped whether the copy made it or the operator "
        "did. Removes the pg_description join and the record predicate, so the copies' capture still goes "
        "and tests/timescale/db/32's look-alike (the module's names, no record) is dropped with its "
        "trigger: the two assertions that it survives and still fires fail.",
        [("""      from pg_description d
      join pg_class c on c.oid = d.objoid
      join pg_namespace n on n.oid = c.relnamespace
     where d.classoid = 'pg_class'::regclass and d.objsubid = 0
       and d.description ~ '^pgpm from_hypertable horizon [0-9]+$'
       and c.relkind = 'r' and right(c.relname, 11) = '_pgpm_delta'
""", """      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'r' and right(c.relname, 11) = '_pgpm_delta'
""", 1)],
    ),
    # Issue #773 (its last bullet): uninstall drops a from_hypertable copy that was never cut over, found by
    # the record the copy keeps on it, and only while its hypertable still holds every row; the swap leaves
    # the migrated table no record. One mutation per half, all caught by tests/timescale/db/48 through
    # bench/uninstall_hypertable_copy.sh.
    "uninstall_keeps_hypertable_copy": (
        "bench/uninstall_hypertable_copy.sh",
        "Pre-#773 uninstall.sql after a from_hypertable_copy that was never cut over: only the tracking "
        "copy's change capture is swept, so <rel>_pgpm_dest (a full second copy of the hypertable's rows), "
        "its pre-built key index <conname>_pgpm_new and the outgoing foreign keys the copy replayed on it "
        "survive, and a referenced row the hypertable no longer uses cannot be deleted. Deletes the sweep "
        "(its comment through its loop), so tests/timescale/db/48's removal assertions fail and its "
        "survivors still pass.",
        [(re.compile(r"^  -- Drop from_hypertable's copies that were never cut over \(#773\)\..*?^  end loop;\n\n",
                     re.MULTILINE | re.DOTALL), "", 1)],
    ),
    "uninstall_hypertable_copy_by_name": (
        "bench/uninstall_hypertable_copy.sh",
        "#773's sweep keyed on a name instead of the copy's record: every table ending in _pgpm_dest beside "
        "a table of the derived name is taken for a copy of it and dropped, whether the module made it or "
        "the operator did. tests/timescale/db/48's look-alike (public.u773_c_pgpm_dest beside public.u773_c, "
        "no record) is dropped with its rows.",
        [("""    select n.nspname as nsp, c.relname as dest,
           substring(d.description from '^pgpm from_hypertable copy of ([0-9]+)$')::oid as src
      from pg_description d
      join pg_class c on c.oid = d.objoid
      join pg_namespace n on n.oid = c.relnamespace
     where d.classoid = 'pg_class'::regclass and d.objsubid = 0
       and d.description ~ '^pgpm from_hypertable copy of [0-9]+$'
       and c.relkind = 'r' and right(c.relname, 10) = '_pgpm_dest'
""", """    select n.nspname as nsp, c.relname as dest,
           coalesce(substring(d.description from '^pgpm from_hypertable copy of ([0-9]+)$')::oid,
                    to_regclass(format('%I.%I', n.nspname, left(c.relname, -10)))::oid) as src
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      left join pg_description d on d.objoid = c.oid and d.classoid = 'pg_class'::regclass and d.objsubid = 0
     where c.relkind = 'r' and right(c.relname, 10) = '_pgpm_dest'
""", 1)],
    ),
    "uninstall_drops_orphaned_copy": (
        "bench/uninstall_hypertable_copy.sh",
        "#773's sweep without its source check: a copy whose hypertable the operator has since dropped is "
        "dropped too, although it may be the only home of those rows. tests/timescale/db/48's copy of the "
        "dropped public.u773_d is gone with its three rows.",
        [("""    if not exists (select 1 from pg_class s where s.oid = r.src) then
      raise warning 'pg_partition_magician: left behind %.%, a from_hypertable copy that was never cut over: the hypertable it was copied from (oid %) no longer exists, so this table may hold the only copy of those rows. Drop it once you have checked.',
        quote_ident(r.nsp), quote_ident(r.dest), r.src;
      continue;
    end if;
""", "", 1)],
    ),
    "hypertable_swap_keeps_copy_record": (
        "bench/uninstall_hypertable_copy.sh",
        "The swap replays the source's comment only when it has one (the pre-#773 carry), so the copy's "
        "`pgpm from_hypertable copy of <oid>` record survives onto the migrated table of a hypertable "
        "without a comment. tests/timescale/db/48's migrated public.u773_e carries it, before the uninstall "
        "and after.",
        [("""  v_ddl := v_ddl || format('comment on table %s is %L', v_tbl_q, obj_description(p_hypertable, 'pg_class'));
""", """  if obj_description(p_hypertable, 'pg_class') is not null then
    v_ddl := v_ddl || format('comment on table %s is %L', v_tbl_q, obj_description(p_hypertable, 'pg_class'));
  end if;
""", 1)],
    ),
    "to_s3_part_bytes_unbounded": (
        "bench/archive_to_s3_part_bytes.sh",
        "Pre-#594 archive.configure and archive.to_s3: configure stores any p_part_bytes, and to_s3 reads "
        "whatever the row holds as the size of each multipart part. With 0 or less its read loop "
        "(`while octet_length(payload) < part_bytes`) is false at once, so the export never reads a row: "
        "it initiates a multipart upload and PUTs empty parts until the store refuses part 10001 (about "
        "20 s against MinIO, 10000 round trips against S3, all in the caller's transaction). Two sites, "
        "both bounds, so the mutant is the old code exactly; tests/archive/db/23 asserts each on its own.",
        [
            ("  if p_part_bytes <= 0 then\n"
             "    raise exception 'archive.configure: p_part_bytes must be a positive number of bytes, not %', p_part_bytes;\n"
             "  end if;\n", "", 1),
            ("  if cfg.part_bytes <= 0 then\n"
             "    raise exception 'archive.to_s3: % has archive.config.part_bytes %; it must be a positive number of bytes (set it with archive.configure)',\n"
             "      p_parent, cfg.part_bytes;\n"
             "  end if;\n", "", 1),
        ],
    ),
    "to_s3_abort_misses_cancel": (
        "bench/archive_to_s3_cancel_abort.sh",
        "Pre-#595 archive.to_s3: the multipart abort runs only from `exception when others`, which does "
        "not catch query_canceled (57014). A statement_timeout or pg_cancel_backend mid-export, or a "
        "cancel still pending when a transport error is raised (taken at the handler's first statement), "
        "skips the DELETE ?uploadId and leaves the upload and its parts in the bucket, against the "
        "README's 'an in-flight multipart upload is aborted'. One site: the enclosing query_canceled "
        "handler, removed whole, so only the old `when others` handler is left.",
        [(TO_S3_CANCEL_HANDLER, "end export;\nend;\n$$;\n", 1)],
    ),
    "to_s3_conservation_by_count": (
        "bench/archive_to_s3_conservation.sh",
        "Pre-#673 archive.to_s3: the conservation check compares the number of rows it paged with the "
        "partition's row count and nothing else. The pages are read across many READ COMMITTED snapshots, "
        "so one UPDATE that moves a row not yet paged behind the (control, ctid) cursor (-1) and a paged "
        "row ahead of it (+1) keeps the count, and the export completes with an object that holds the "
        "first row in neither form. Drops the fingerprint half of the comparison and leaves the count half "
        "and its message, so the quiescent export of tests/archive/db/25 still passes and only its race "
        "part catches this: no refusal, and an object at the key.",
        [("      if v_written <> v_expected or v_written_h <> v_expected_h then\n",
          "      if v_written <> v_expected then   -- MUTANT: the pre-#673 count-only comparison\n", 1)],
    ),
    "to_s3_initiate_orphan_unaborted": (
        "bench/archive_to_s3_loud_edges.sh",
        "Pre-#636 archive.to_s3: both handlers abort only the upload whose UploadId they recorded, and "
        "the id is recorded only once the initiate POST's response is parsed. A cancel or a transport "
        "error inside that POST, after the store created the upload, leaves an upload in flight at the "
        "key with nothing to abort it. Two sites, both sweeps by key, so neither handler finds the orphan.",
        [
            ("""  elsif v_initiating then
    begin
      perform archive._s3_abort_uploads_at(cfg.endpoint, cfg.bucket, cfg.region, v_key, v_key_id, v_secret);
    exception when others then null;
    end;
    v_initiating := false;
  end if;
""", "  end if;\n", 1),
            ("""  elsif v_initiating then
    begin
      perform archive._s3_abort_uploads_at(cfg.endpoint, cfg.bucket, cfg.region, v_key, v_key_id, v_secret);
    exception when others then null;
    end;
  end if;
""", "  end if;\n", 1),
        ],
    ),
    "configure_part_bytes_under_s3_min": (
        "bench/archive_to_s3_loud_edges.sh",
        "Pre-#636 archive.configure: only p_part_bytes <= 0 is refused (#594), so a positive size under "
        "S3's 5 MiB minimum for a non-final multipart part is stored, and every archive.to_s3 export of "
        "more than one part uploads all of them and fails at CompleteMultipartUpload with EntityTooSmall.",
        [("""  if p_part_bytes < 5 * 1024 * 1024 then
    raise exception 'archive.configure: p_part_bytes must be at least 5242880 bytes (5 MiB, the smallest multipart part S3 accepts), not %', p_part_bytes;
  end if;
""", "", 1)],
    ),
    "configure_fetch_rows_unbounded": (
        "bench/archive_to_s3_loud_edges.sh",
        "Pre-#636 archive.configure and archive.to_s3: any p_fetch_rows is stored and read as each "
        "page's LIMIT, so 0 reads no page and trips the conservation check with a message about rows, "
        "and a negative value fails on LIMIT. Two sites, both bounds, so the mutant is the old code.",
        [
            ("""  if p_fetch_rows < 1 then
    raise exception 'archive.configure: p_fetch_rows must be a positive number of rows, not %', p_fetch_rows;
  end if;
""", "", 1),
            ("""  if cfg.fetch_rows < 1 then
    raise exception 'archive.to_s3: % has archive.config.fetch_rows %; it must be a positive number of rows (set it with archive.configure)',
      p_parent, cfg.fetch_rows;
  end if;
""", "", 1),
        ],
    ),
    "signer_text_sends_server_encoding": (
        "bench/archive_signer_non_utf8.sh",
        "Pre-#728 archive.s3_signed_request: x-amz-content-sha256 is the hash of convert_to(p_payload, "
        "'UTF8') but the body on the wire is p_payload itself, text in the SERVER encoding. In a LATIN1 "
        "database every body holding a non-ASCII character is refused (400 XAmzContentSHA256Mismatch), so "
        "the uncompressed NDJSON strategy, which signs its chunk through this signer, logs skip_archive "
        "every tick and the partition is never covered or retired. One site, the signer's one send (since #984 the "
        "bytes it hands archive._s3_send, here the payload in the server encoding, which is what the extension "
        "sent for a text body).",
        [("  return archive._s3_send(p_method, v_url, v_amz_date, v_payload_hash, v_auth, p_ctype, convert_to(p_payload, 'UTF8'));\n",
          "  return archive._s3_send(p_method, v_url, v_amz_date, v_payload_hash, v_auth, p_ctype, convert_to(p_payload, getdatabaseencoding()));\n", 1)],
    ),
    "to_s3_sync_key_bare_child": (
        "bench/archive_edges_pass5.sh",
        "Pre-#711 archive.to_s3 and archive.to_s3_parquet: the object key is <prefix><child><ext>, the "
        "child's bare relname. Two parents named evt in two schemas sharing a prefix export their [0, 10000) "
        "partitions to one key, and the second export replaces the first. One site, the one function "
        "every key is assembled in, its export half only (a chunk's key keeps its schema).",
        [("  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(coalesce(p_child, c.relname))\n",
          "  select p_prefix || case when p_child is null then quote_ident(n.nspname) || '.' || quote_ident(c.relname)\n"
          "                          else p_child end   -- MUTANT: the pre-#711 bare-child key\n", 1)],
    ),
    "parquet_tstz_no_logical_type": (
        "bench/archive_edges_pass5.sh",
        "Pre-#711 Parquet writer: only a `timestamp` leaf carries a LogicalType; a `timestamptz` leaf has "
        "the legacy ConvertedType TIMESTAMP_MICROS alone, which DuckDB reads as a naive TIMESTAMP rather "
        "than TIMESTAMP WITH TIME ZONE. Two sites, one per encoder, so neither annotates the instant.",
        [("      p_logical_type => case when v_col_pgtypes[i] = 'timestamp' then archive._pq_logical_timestamp_micros(false)\n"
          "                             when v_col_pgtypes[i] = 'timestamptz' then archive._pq_logical_timestamp_micros(true) end);\n",
          "      p_logical_type => case when v_col_pgtypes[i] = 'timestamp' then archive._pq_logical_timestamp_micros(false) end);   -- MUTANT\n",
          2)],
    ),
    "abort_sweep_one_page": (
        "bench/archive_edges_pass5.sh",
        "Pre-#711 archive._s3_abort_uploads_at: one page of ListMultipartUploads is read and the IsTruncated "
        "flag ignored, so an upload in flight at the key past the first page is never aborted. One site, "
        "the loop's exit: the mutant leaves after the first page whatever the store says.",
        [("    exit when v_truncated is distinct from 'true';\n",
          "    exit;   -- MUTANT: the pre-#711 single page\n", 1)],
    ),
    "abort_sweep_no_exact_key_filter": (
        "bench/archive_to_s3_loud_edges.sh",
        "archive._s3_abort_uploads_at without its exact-key filter: S3 lists in-flight uploads by key "
        "PREFIX, so the sweep sends an abort naming every upload at a longer key the export's key is a "
        "prefix of, another object's upload. Against MinIO, which lists the exact key, tests/archive/db/28 "
        "could not see the line go (#711); its stand-in now answers the listing with S3's semantics. One "
        "site, the filter line, deleted exactly as the issue's reproduction deletes it.",
        [("     where u.upload_key = p_key\n", "", 1)],
    ),
    "parquet_decimal_nan_raises": (
        "bench/archive_parquet_decimal_nan.sh",
        "Pre-#635 Parquet DECIMAL encode: a NaN in a numeric(p,s) column reaches archive._pq_plain_decimal, "
        "which raises 'cannot convert NaN to integer' on every encode of the chunk holding it, so the "
        "Parquet strategy fails, maintain() logs skip_archive every tick and the partition is never "
        "covered or retired. One site, the numeric branch of archive._pq_encode_column_data, put back as "
        "it was: present and encoded whenever not null.",
        [("""      'select coalesce(array_agg(%I is not null and %I <> ''NaN''::numeric order by %s), ''{}''::boolean[]),
              coalesce(string_agg(archive._pq_plain_decimal(%I::numeric, %L, %L), ''''::bytea order by %s) filter (where %I is not null and %I <> ''NaN''::numeric), ''''::bytea)
         from %s',
      p_col, p_col, v_order_q, p_col, p_decimal_scale, p_decimal_bytes, v_order_q, p_col, p_col, v_from_q)
""", """      'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
              coalesce(string_agg(archive._pq_plain_decimal(%I::numeric, %L, %L), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
         from %s',
      p_col, v_order_q, p_col, p_decimal_scale, p_decimal_bytes, v_order_q, p_col, v_from_q)   -- MUTANT: pre-#635
""", 1)],
    ),
    "archive_ndjson_single_float_digits_unpinned": (
        "bench/archive_float_digits_pinned.sh",
        "Pre-#781 archive._encode_upload_ndjson_single: the automatic NDJSON strategy's row_to_json renders "
        "floats by the calling session's extra_float_digits, so under 0 (ALTER ROLE / ALTER DATABASE, "
        "inherited by a tick) every float8 lands in the object rounded to 15 significant digits and every "
        "float4 to 6 while the ledger records the chunk archived. One site, the function's SET clause.",
        [("returns table(s3_key text, etag text, rows_archived bigint)\n"
          "language plpgsql set extra_float_digits = 1 as $$\n"
          "declare\n  cfg archive.config; pcfg pgpm.config; v_nsp name; v_rel name;\n",
          "returns table(s3_key text, etag text, rows_archived bigint)\n"
          "language plpgsql as $$   -- MUTANT: pre-#781, the caller's extra_float_digits\n"
          "declare\n  cfg archive.config; pcfg pgpm.config; v_nsp name; v_rel name;\n", 1)],
    ),
    "to_s3_float_digits_unpinned": (
        "bench/archive_float_digits_pinned.sh",
        "Pre-#781 archive.to_s3: its row_to_json pages, and the conservation fingerprint that hashes the "
        "same text on both sides, render floats by the calling session's extra_float_digits, so under 0 the "
        "object holds 15-digit float8 values and the fingerprint passes. One site, the function's SET clause.",
        [("create or replace function archive.to_s3(p_parent regclass, p_child name, p_lo text, p_hi text)\n"
          "returns void language plpgsql set extra_float_digits = 1 as $$\n",
          "create or replace function archive.to_s3(p_parent regclass, p_child name, p_lo text, p_hi text)\n"
          "returns void language plpgsql as $$   -- MUTANT: pre-#781, the caller's extra_float_digits\n", 1)],
    ),
    "parquet_array_float_digits_unpinned": (
        "bench/archive_float_digits_pinned.sh",
        "Pre-#781 archive._pq_encode_column_data: an array column is written as array_to_json text, which "
        "renders a float8[] element by the calling session's extra_float_digits, so under 0 both Parquet "
        "encoders write 15-digit elements. One site, the function's SET clause.",
        [("default, so a file written from a default session is unchanged. The scalar float8 leaf is binary.\n"
          "language plpgsql set extra_float_digits = 1 as $$\n",
          "default, so a file written from a default session is unchanged. The scalar float8 leaf is binary.\n"
          "language plpgsql as $$   -- MUTANT: pre-#781, the caller's extra_float_digits\n", 1)],
    ),
    "archive_ndjson_single_row_alias_shadowed": (
        "bench/archive_ndjson_row_alias.sh",
        "Pre-#821 archive._encode_upload_ndjson_single: the automatic NDJSON strategy renders each row as "
        "row_to_json(t) over the table alias t, which a column named t shadows, so a composite column t is "
        "archived in place of the row (no id, no payload) while the ledger records the chunk and retire() "
        "drops the only full copy, and a timestamptz column t raises on every tick. One site.",
        [("    'select coalesce(string_agg(row_to_json(t.*)::text, e''\\n'' order by t.%I), ''''), count(*)\n",
          "    'select coalesce(string_agg(row_to_json(t)::text, e''\\n'' order by t.%I), ''''), count(*)   -- MUTANT: pre-#821\n", 1)],
    ),
    "to_s3_row_alias_shadowed": (
        "bench/archive_ndjson_row_alias.sh",
        "Pre-#821 archive.to_s3: its pages render row_to_json(t) and its conservation fingerprint hashes the "
        "same text, so on a table with a composite column t both sides agree on that column alone and the "
        "object lands without the rows' other columns; a timestamptz column t raises. Both sites.",
        [("           from (select row_to_json(t.*)::text as j, t.%I as k, t.ctid as c from %I.%I t\n",
          "           from (select row_to_json(t)::text as j, t.%I as k, t.ctid as c from %I.%I t   -- MUTANT: pre-#821\n", 1),
         ("coalesce(sum(hashtextextended(row_to_json(t.*)::text, 0)), 0) from %I.%I t',\n",
          "coalesce(sum(hashtextextended(row_to_json(t)::text, 0)), 0) from %I.%I t',   -- MUTANT: pre-#821\n", 1)],
    ),
    "to_s3_fingerprint_row_alias_shadowed": (
        "bench/archive_ndjson_row_alias.sh",
        "A partial #821 fix: archive.to_s3's pages render row_to_json(t.*) but the after-the-last-page "
        "fingerprint still hashes row_to_json(t), so on a table with a column named t the two never agree "
        "and every export of it is refused (or raises, on a timestamptz t). One site, the fingerprint.",
        [("coalesce(sum(hashtextextended(row_to_json(t.*)::text, 0)), 0) from %I.%I t',\n",
          "coalesce(sum(hashtextextended(row_to_json(t)::text, 0)), 0) from %I.%I t',   -- MUTANT: partial #821\n", 1)],
    ),
    "to_s3_cursor_session_text": (
        "bench/archive_to_s3_cursor_session.sh",
        "Pre-#834 archive.to_s3: the keyset cursor's control value crosses from one page's query to the "
        "next as `k::text`, rendered in the calling session's DateStyle and TimeZone, and is cast back "
        "with `$1::<type>` in that same session. Under a non-ISO DateStyle a timestamptz names its zone "
        "by abbreviation, and Asia/Shanghai's CST reads back as US Central (-06): the cursor lands 14 "
        "hours past the last paged row, the next page skips every row in between, and the conservation "
        "check refuses every multi-page export of an unwritten partition. One site, the render.",
        [("archive._cursor_text((array_agg(k order by k desc, c desc))[1]),",
          "(array_agg(k order by k desc, c desc))[1]::text,", 1)],
    ),
    "parquet_snapshot_per_encode_table": (
        "bench/archive_parquet_snapshot_locks.sh",
        "Pre-#632 Parquet encoders: each drops archive._pq_snapshot's temp table when it is done with it, "
        "so the next encode finds none and builds a fresh one. A dropped relation's locks are held to "
        "transaction end (the table, its TOAST table and index, its two row types: ~8 entries in the "
        "SHARED lock table), so one pgpm._archive_step, which encodes one chunk per partition for up to "
        "archive_batch partitions in one transaction, grows the cluster's lock table by ~8 per chunk "
        "until it commits. The files are byte for byte the same, so every identity assertion in "
        "tests/archive/db/37 still passes; the lock-growth zeros and the emptied relation are what name "
        "it. Two sites, the two encoders' tails.",
        [(PQ_SNAPSHOT_TAIL,
          "  drop table pg_temp.archive_pq_snapshot;   -- MUTANT: pre-#632, a fresh snapshot table per encode\n", 2)],
    ),
    "keep_both_two_way_only": (
        "bench/keep_both_diff3.sh",
        "Pre-#598 scripts/review/keep_both.py: the hunk pattern knows only the two-way conflict shape and the "
        "marker check looks only for <<<<<<< and >>>>>>>. Under git's diff3 or zdiff3 style a hunk carries a "
        "`||||||| <base>` section, which the pattern folds into 'ours', so the script exits 0 with the "
        "`|||||||` line (and any base lines) left in CHANGELOG.md, and a hunk whose base is NOT empty (both "
        "sides edited the same line) is kept as text instead of refused. Three sites, the exact pre-#598 "
        "text: the pattern, the base refusal disabled, the marker check.",
        [
            ('CONFLICT = re.compile(r"^<{7}(?: [^\\n]*)?\\n(.*?)^(?:\\|{7}(?: [^\\n]*)?\\n(.*?)^)?={7}\\n(.*?)^>{7}(?: [^\\n]*)?\\n",\n'
             '                      re.S | re.M)\n',
             'CONFLICT = re.compile(r"<<<<<<< [^\\n]*\\n(.*?)=======\\n(.*?)>>>>>>> [^\\n]*\\n", re.S)\n', 1),
            ("        ours, base, theirs = m.group(1), m.group(2), m.group(3)\n        if base:\n",
             "        ours, theirs = m.group(1), m.group(2)\n        if False:\n", 1),
            ("    left = MARKER.search(s2)\n", '    left = re.search(r"<{7}|>{7}", s2)\n', 1),
        ],
    ),
    "onboarding_ts_versions": (
        "bench/doc_env_knobs.sh",
        "Pre-#599 ONBOARDING.md: the timescale track's knob documented as TS_VERSIONS='2.9.1' ./test.sh "
        "timescale, a variable test.sh stopped reading in #155 (run_timescale loops over TS_PG_TAGS, image "
        "tags), so the documented command silently runs the default 2.16.1 leg and reports PASS. The exact "
        "pre-#599 text, its stale '2.9.1 + 2.16.1' coverage claim included.",
        [("./test.sh timescale # the from_hypertable track: TimescaleDB 2.16.1 / PG15 on the fleet image\n"
          "                    # supabase/postgres:15.14.1.127, NOT in the default matrix. One leg per\n"
          "                    # image tag, and each tag bundles one TimescaleDB: to add the 2.9.x\n"
          "                    # cluster, name a tag that ships it (TS_PG_TAGS='15.14.1.127 <tag>' ./test.sh timescale)\n",
          "./test.sh timescale # the from_hypertable track: TimescaleDB 2.9.1 + 2.16.1 / PG15\n"
          "                    # (the big fleet clusters), its own image, NOT in the default matrix\n"
          "                    # (TS_VERSIONS='2.9.1' ./test.sh timescale runs just one)\n", 1)],
    ),
    "onboarding_unread_knob_first": (
        "bench/doc_env_knobs.sh",
        "Pre-#847 blind spot, as a document: ONBOARDING.md's timescale knob documented as TS_VERSIONS='2.9.1' "
        "TS_PG_TAGS='15.14.1.127 <tag>' ./test.sh timescale. TS_PG_TAGS is read, TS_VERSIONS (the #599 knob) is "
        "read nowhere, so the 2.9.1 the reader asked for is silently ignored. The guard's command regex bound "
        "only the assignment next to ./test.sh, saw the read TS_PG_TAGS, and passed this. One site.",
        [("# cluster, name a tag that ships it (TS_PG_TAGS='15.14.1.127 <tag>' ./test.sh timescale)\n",
          "# cluster, name a tag that ships it (TS_VERSIONS='2.9.1' TS_PG_TAGS='15.14.1.127 <tag>' ./test.sh timescale)\n",
          1)],
    ),
    "runbook_retain_count_of_intervals": (
        "bench/doc_retain_unit.sh",
        "Pre-#676 docs/runbook.md: 'Storage is not dropping despite a retention policy' calls an id grid's "
        "retain a count of intervals, while pgpm subtracts it from the frontier as a raw count of ids (as "
        "reference.md and guide.md say), so an operator setting retain => 2 on a 1000-wide grid to keep two "
        "partitions keeps only the partition taking writes. The exact pre-#676 text.",
        [("(Watch the unit, too: `retain` is an **interval** for `time`/`uuidv7`/`text_time` and a **count of ids**\n"
          "for `id`, subtracted from the highest id written. It is not a number of partitions: `retain => 2` on a\n"
          "1000-wide id grid keeps two ids of history, which in practice is only the partition taking writes, so\n"
          "size it as partitions times the grid width.\n"
          "A misread puts the horizon far from where you meant it.)\n",
          "(Watch the unit, too: `retain` is an **interval** for `time`/`uuidv7` and a **count of intervals** for\n"
          "`id` -- a misread makes the horizon far longer than intended.)\n", 1)],
    ),
    "reference_archive_identity_forget_missing": (
        "bench/doc_archive_identity_recovery.sh",
        "Pre-#739 docs/reference.md: the archive step's identity check tells an operator facing a "
        "fail_archive_identity wedge to clear the stale row with forget_missing, which clears only a parent "
        "whose relation is gone, while fail_archive_identity is only ever logged for a live one: the advice "
        "clears nothing and the wedge (at archive_batch 1, the table's whole archiving and retention) stays. "
        "The exact pre-#739 text.",
        [("relation back under that name, or delete the stale `pgpm.part` row (`delete from pgpm.part where\n"
          "parent_table = ... and child_name = ...`), after which the archive step moves on to the next partition.\n"
          "[`forget_missing`](#forget_missing) is not the tool here: it clears only a parent whose relation no longer\n"
          "exists, and this check only ever runs for a live one. At `archive_batch`'s default of `1` a wedged\n"
          "partition also holds up that parent's other partitions, which is deliberate: pgpm's catalog is\n"
          "demonstrably wrong about which relation is which, and retention should not march on past that.",
          "relation back under that name, or clear the stale row with\n"
          "[`forget_missing`](#forget_missing). At `archive_batch`'s default of `1` a wedged partition also\n"
          "holds up that parent's other partitions, which is deliberate: pgpm's catalog is demonstrably wrong\n"
          "about which relation is which, and retention should not march on past that.", 1)],
    ),
    "reference_fks_suspended_dead_swap": (
        "bench/doc_fks_suspended_meaning.sh",
        "Pre-#740 docs/reference.md: status() reads a standing non-zero fks_suspended as a regrain swap that "
        "died mid-flight, while a paused transmute with p_incoming_fks => 'preserve' leaves it standing by "
        "design, with no swap anywhere, until restore_incoming_fks re-adds the key; the operator hunts a dead "
        "swap instead of running the restore. The exact pre-#740 text.",
        [("  re-added `NOT VALID` but blocked from full validation by pre-existing orphans. A standing non-zero\n"
          "  `fks_suspended` is a `transmute` cutover's preserve drop that\n"
          "  [`restore_incoming_fks`](#restore_incoming_fks) has not re-added yet: `maintain` re-adds it on the next\n"
          "  tick, but a paused table (the default after `transmute`) is not maintained, so there it stands until you\n"
          "  call `restore_incoming_fks` or [`resume`](#resume--pause) the table. A regrain swap drops and re-adds its\n"
          "  keys inside one transaction, so no other session ever sees it counted here.\n",
          "  re-added `NOT VALID` but blocked from full validation by pre-existing orphans. `fks_suspended` is a\n"
          "  transient state inside a regrain swap now, so a standing non-zero value means a swap died mid-flight.\n", 1)],
    ),
    "reference_keyless_monolith_dormant": (
        "bench/doc_monolith_retention.sh",
        "Pre-#741 docs/reference.md: the from_hypertable notes call retention over an unregrained (keyless) "
        "monolith dormant and say a keyless migration will not reclaim disk until it is regrained, while "
        "retain() drops the monolith whole, in one step, once its range is past the horizon, so the operator "
        "meets the cliff they were told could not happen. The exact pre-#741 text.",
        [("- A carried-over `drop_chunks` retention policy is auto-translated into `pgpm`'s `retain`, and it covers the\n"
          "  unregrained monolith too: the monolith is **not exempt**, and drops whole, in one step, once its entire range\n"
          "  is past the horizon (see [`retain`](#retain)). What `regrain` changes is only the granularity, and `regrain`\n"
          "  is unavailable on a keyless monolith, so a keyless migration reclaims its migrated history in that one cliff\n"
          "  unless a key is added and the monolith is regrained first.\n",
          "- A carried-over `drop_chunks` retention policy is auto-translated into `pgpm`'s `retain`, but retention over\n"
          "  the unregrained **monolith is dormant** until you `regrain` it (`retain` only drops attached fine partitions),\n"
          "  and `regrain` is unavailable on a keyless monolith. So a keyless migration that relied on `drop_chunks` will\n"
          "  not reclaim disk until a key is added and the monolith is regrained.\n", 1)],
    ),
    "readme_transmute_fresh_default": (
        "bench/doc_transmute_no_default.sh",
        "Pre-#991 README.md: the transmute bullet says 'a fresh `DEFAULT` is the safety net', while the DEFAULT "
        "partition was removed in #288: transmute builds none and a write past the forward grid is refused "
        "('no partition of relation ... found for row'), so an operator who trusts the bullet writes ahead of "
        "the grid without sizing obtain or calling extend_to. The exact pre-#991 text.",
        [("  original is renamed aside and attached intact as one bounded **monolith** child, with a forward grid of\n"
          "  real partitions laid down ahead of it. There is no `DEFAULT`: a write past that grid is refused, so the\n"
          "  safety net is `obtain`'s lookahead, and `extend_to` for a write you know will land beyond it. The cutover\n"
          "  is one read-only scan plus a metadata flip: no rebuild, no row rewrite, and **no lock that scales with row\n"
          "  count** -- the scan runs under a lock that blocks neither readers nor writers\n",
          "  original is renamed aside and attached intact as one bounded **monolith** child; a fresh `DEFAULT` is the\n"
          "  safety net. The cutover is one read-only scan plus a metadata flip: no rebuild, no row rewrite, and **no\n"
          "  lock that scales with row count** -- the scan runs under a lock that blocks neither readers nor writers\n", 1)],
    ),
    "runbook_fk_validate_by_restore": (
        "bench/doc_remedy_and_symptom.sh",
        "Pre-#910 docs/runbook.md: the Prevent step after a preserve conversion tells the operator to call "
        "restore_incoming_fks again next tick 'for the VALIDATE', while restore_incoming_fks re-adds the key NOT "
        "VALID and stops there (a second call returns 0) and the conversion registers paused, so no tick "
        "validates either: the key is left NOT VALID. validate_incoming_fks validates. The exact pre-#910 text.",
        [("select pgpm.restore_incoming_fks('public.events');    -- re-adds the key NOT VALID, and stops there\n"
          "select pgpm.validate_incoming_fks('public.events');   -- then validates it; returns the number validated\n"
          "```\n"
          "\n"
          "Run both yourself: a second `restore_incoming_fks` finds nothing left to re-add and returns 0, and the\n"
          "conversion registers the table paused, so no tick runs the `VALIDATE` for you.\n",
          "select pgpm.restore_incoming_fks('public.events');   -- then again next tick for the VALIDATE\n"
          "```\n", 1)],
    ),
    "runbook_dropped_table_syntax_symptom": (
        "bench/doc_remedy_and_symptom.sh",
        "Pre-#911 docs/runbook.md: the dropped-without-untransmute entry says the skip_obtain / skip_write_block "
        "/ skip_retain rows all give `syntax error at or near \"<number>\"` as the reason, while since #296 "
        "_frontier_native refuses first with 'managed table with oid N no longer exists (dropped without "
        "pgpm.untransmute)', so a search of pgpm.log for the documented symptom finds nothing. The exact "
        "pre-#911 text.",
        [("every tick, all giving `managed table with oid <oid> no longer exists (dropped without pgpm.untransmute)` as\n"
          "the reason, so search `method` for `no longer exists (dropped without pgpm.untransmute)`. (On a version\n"
          "before 0.2.0, `pgpm.status()` itself fails with a syntax error and returns **no rows at all** for any managed\n"
          "table.)\n",
          "every tick, all giving `syntax error at or near \"<number>\"` as the reason; or, on a version before 0.2.0,\n"
          "`pgpm.status()` raises that syntax error and returns **no rows at all** for any managed table.\n", 1)],
    ),
    "classify_tap_needs_description": (
        "bench/classify_claims_tap.sh",
        "Pre-#600 classify_claims.py (a): only `not ok <n> - <description>` lines count as failures, so a "
        "failing pgTAP assertion WITHOUT a description (psql prints ` not ok 2 +` and exits 0) reads as "
        "passing: a true reproduction is classified not_reproduced and dropped, and a defect still present at "
        "closure reads as closed. One site, the exact pre-#600 pattern.",
        [('NOT_OK_LINE = re.compile(r"^\\s*not ok\\b[ \\t]*\\d*[ \\t]*(?:-[ \\t]*)?(.*)$", re.M)\n',
          'NOT_OK_LINE = re.compile(r"^\\s*not ok\\s+\\d+\\s*-\\s*(.*)$", re.M)\n', 1)],
    ),
    "classify_sh_exit_code_only": (
        "bench/classify_claims_tap.sh",
        "Pre-#600 classify_claims.py (b): a repro.sh is judged by its exit code alone and its echoed "
        "`not ok - LIVENESS: ...` lines are never read, so one whose only failing check is its premise is a "
        "candidate on both trees instead of invalid_repro (a repro.sql already got this right). One site: "
        "the repro.sh verdict put back to `fails = r.returncode != 0`.",
        [('                kind = script_failure_kind(r.stdout, r.returncode)\n'
          '                fails = kind == "defect"\n',
          '                kind = None\n'
          '                fails = r.returncode != 0\n', 1)],
    ),
    "classify_premise_bare_word": (
        "bench/classify_claims_tap.sh",
        "Pre-#600 classify_claims.py (c): the premise pattern matches the bare words LIVENESS, GUARD, "
        "fixture, setup and precondition, case-insensitively and with no colon, so an unprefixed DEFECT check "
        "described 'guard trigger is gone ...' is read as a premise and a real reproduction is classified "
        "invalid_repro and never counted. One site, the exact pre-#600 pattern.",
        [('LIVENESS = re.compile(r"^(?:LIVENESS|GUARD|fixture):")\n',
          'LIVENESS = re.compile(r"^(LIVENESS|GUARD|fixture|setup|precondition)\\b", re.I)\n', 1)],
    ),
    "throws_ok_one_argument": (
        "bench/throws_pinned.sh",
        "A ONE-argument throws_ok($$ call pgpm.transmute(...) $$) added to tests/72 beside its pinned "
        "throws_like. It accepts any error at all, the 2D000 of a transmute that did not refuse included. "
        "Pre-#601 bench/throws_pinned.sh demanded a comma after the statement, so it never saw this form and "
        "passed the file on the pinned neighbour alone ('1 pinned of 1'); the neighbour is deliberate, because "
        "a file with NO site already fails the guard's 'found a site' check and could not show the blind spot.",
        [("select throws_like($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$,\n",
          "select throws_ok($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$);\n"
          "select throws_like($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$,\n", 1)],
    ),
    "throws_ilike_unpinned": (
        "bench/throws_pinned.sh",
        "A throws_ilike($$ call pgpm.transmute(...) $$, '%') added to tests/72 beside its pinned throws_like. "
        "The pattern '%' matches every message, so it accepts the 2D000 of a transmute that did not refuse. "
        "Pre-#915 bench/throws_pinned.sh recognised throws_(ok|like|matching|imatching) only, so it never saw "
        "this form and passed the file on the pinned neighbour alone ('1 pinned of 1'); the neighbour is there "
        "for the reason throws_ok_one_argument gives (a file with no site already fails 'found a site').",
        [("select throws_like($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$,\n",
          "select throws_ilike($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$, '%',\n"
          "  'an unpinned refusal: the pattern matches the 2D000 too');\n"
          "select throws_like($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$,\n", 1)],
    ),
    "throws_ok_null_pattern_var_desc": (
        "bench/throws_pinned.sh",
        "A throws_ok($$ call pgpm.transmute(...) $$, NULL, :'d72') added to tests/72 beside its pinned "
        "throws_like, its description set by \\set. The NULL pattern accepts the 2D000 of a transmute that did "
        "not refuse; the variable is only the description. Pre-#1000 bench/throws_pinned.sh searched every "
        "argument after the statement for a psql variable, so it read this site as an unevaluable pattern, "
        "reported it INFO and passed the file on the pinned neighbour ('1 pinned, 1 by an expression, of 2').",
        [("select throws_like($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$,\n",
          "\\set d72 'a row trigger with a transition table is refused'\n"
          "select throws_ok($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$, NULL, :'d72');\n"
          "select throws_like($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$,\n", 1)],
    ),
    "tap_verdict_misses_plan_shortfall": (
        "bench/tap_verdict.sh",
        "Pre-#601 test.sh: the timescale and observe tracks call a pgTAP file failed on `not ok`, "
        "'# Looks like you failed' or ERROR:, and not on '# Looks like you planned N tests but ran M', so a "
        "file whose assertion silently never ran (over zero rows, or deleted without lowering plan()) passes "
        "both tracks while pg_prove fails it. Four sites, two per track: the exact pre-#601 pattern, and "
        "the #918 count of the assertions that ran against the plan line taken out.",
        [("grep -qE '^not ok|^# Looks like you (failed|planned)|ERROR:'",
          "grep -qE '^not ok|^# Looks like you failed|ERROR:'", 2),
         ("ERROR:' \\\n         || [ -z \"$planned\" ] || [ \"$ran\" != \"$planned\" ]; then\n",
          "ERROR:'; then\n", 1),
         ("ERROR:' \\\n       || [ -z \"$planned\" ] || [ \"$ran\" != \"$planned\" ]; then echo",
          "ERROR:'; then echo", 1)],
    ),
    "tap_verdict_reads_finish_only": (
        "bench/tap_verdict.sh",
        "Pre-#918 test.sh: the timescale and observe verdicts read a plan shortfall only from finish()'s "
        "'# Looks like you planned' line, and pgTAP prints that line from finish() alone, so a file that "
        "plans 3, runs 2 and never calls finish() exits psql 0 with no `not ok` and no ERROR: and passes "
        "both tracks while pg_prove fails it. Two sites, one per track: the count of the assertions that "
        "ran against the 1..N plan line taken out of the verdict.",
        [("ERROR:' \\\n         || [ -z \"$planned\" ] || [ \"$ran\" != \"$planned\" ]; then\n",
          "ERROR:'; then\n", 1),
         ("ERROR:' \\\n       || [ -z \"$planned\" ] || [ \"$ran\" != \"$planned\" ]; then echo",
          "ERROR:'; then echo", 1)],
    ),
    "tap_verdict_count_ends_track": (
        "bench/tap_verdict.sh",
        "#918's count without its `|| true`: grep -c exits 1 when it counts no assertion, so under test.sh's "
        "`set -euo pipefail` a file that errors before its first assertion ends the timescale or observe track "
        "at that file with no verdict, no teardown and the rest unrun (#819's crash, by another road). Two "
        "sites, one per track.",
        [("ran=$(echo \"$out\" | grep -cE '^(not )?ok [0-9]+( |$)' || true)\n",
          "ran=$(echo \"$out\" | grep -cE '^(not )?ok [0-9]+( |$)')\n", 2)],
    ),
    "clean_run_perf_entry_dropped": (
        "bench/guards_run_on_clean_code.sh",
        "Pre-#917 test.sh: write_block_identity.sh, a guard discriminate.sh drives against three mutants, is in "
        "no track's run, so it never meets the unmodified module and a copy of it broken enough to fail "
        "against everything is scored as catching all three. One site: its entry in run_perf's guard list.",
        [('    "bench/write_block_identity.sh pgpm_wbident"\n', '', 1)],
    ),
    "clean_run_timescale_call_commented": (
        "bench/guards_run_on_clean_code.sh",
        "Pre-#917 test.sh for a timescale wrapper: hypertable_late_appends.sh's run_timescale call commented "
        "out, so test.sh still NAMES the guard (in a comment) but no track runs it against the unmodified "
        "module, and only its mutants ever exercise it. One site.",
        [('    bash "$(dirname "$0")/bench/hypertable_late_appends.sh" pgpm_test-timescale pgpm_htlate || fail=1\n',
          '    # bash "$(dirname "$0")/bench/hypertable_late_appends.sh" pgpm_test-timescale pgpm_htlate || fail=1\n', 1)],
    ),
    "tap_verdict_ignores_psql_exit": (
        "bench/tap_verdict.sh",
        "Pre-#819 test.sh: the timescale and observe tracks run each pgTAP file with `out=$(psql -tAq ...)` "
        "and never keep or read psql's exit status, so a file whose session is lost part-way (FATAL, no "
        "ERROR:, finish() never reached) is PASSED by the verdict after 1 of its 3 planned assertions (and, "
        "as run, `set -e` ends the track at that call with no verdict and no teardown). Six sites: each "
        "track's capture, each verdict's exit test, each FAIL line's exit status.",
        [('rc=0; out=$($DC "${px[@]}" -d "$db" -tAq -f "/repo/$f" 2>&1) || rc=$?\n',
          'out=$($DC "${px[@]}" -d "$db" -tAq -f "/repo/$f" 2>&1)\n', 1),
         ('rc=0; out=$($DC "${px[@]}" -d "$db" -tAq -f "$f" 2>&1) || rc=$?\n',
          'out=$($DC "${px[@]}" -d "$db" -tAq -f "$f" 2>&1)\n', 1),
         ('if [ "$rc" != 0 ] || echo "$out" | grep -qE', 'if echo "$out" | grep -qE', 2),
         (' (psql exit $rc)";', '";', 2)],
    ),
    "wrapper_verdict_time_rendering_hand_rolled": (
        "bench/wrapper_tap_verdicts.sh",
        "Pre-#844 hypertable_time_rendering.sh: run_file judges tests/timescale/db/35 and 36 with its own "
        "verdict instead of the shared block, so psql's exit is ignored, a shortfall is read only from "
        "finish()'s line and an undescribed `not ok` is not counted: a file whose session is lost after 1 of "
        "3 planned assertions, or whose undescribed assertion fails, is PASSED. Two sites: the block put back "
        "to the hand-rolled lines, run_file's locals put back to the names they read.",
        [(re.compile(r"  # The verdict is the shared block every timescale wrapper carries \(#844\).*?"
                     r"  \[ \"\$failed_before\" = 0 \] \|\| fail=1\n", re.DOTALL),
          lambda _m: TIME_RENDERING_PRE_844_VERDICT, 1),
         ('  local TEST_FILE="$1" LABEL="$2" out rc planned ran bad failed_before="$fail"\n',
          '  local file="$1" label="$2" out ran bad ffail=0\n', 1)],
    ),
    "wrapper_verdict_reads_finish_only": (
        "bench/wrapper_tap_verdicts.sh",
        "Pre-#795 timescale wrapper verdict (hypertable_index_names.sh and seven siblings): a plan shortfall is "
        "read only from finish()'s '# Looks like you planned' line and psql's exit status is never captured, so "
        "a file whose session dies part-way (FATAL, no ERROR:) never reaches finish() and is PASSED after 1 of "
        "its 3 planned assertions. Two sites in one wrapper: the exit status dropped, the plan comparison put "
        "back to the finish() line.",
        [('  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=$?\n', '  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=0\n', 1),
         ('  if [ -z "$planned" ] || [ "$ran" != "$planned" ]; then\n', "  if echo \"$out\" | grep -qE '^# Looks like you planned'; then\n", 1)],
    ),
    "wrapper_verdict_no_shortfall_check": (
        "bench/wrapper_tap_verdicts.sh",
        "Pre-#712 hypertable_late_appends.sh (and cutover_identity, replica_capture): no plan shortfall check "
        "at all and psql's exit ignored, so a file whose third assertion ran over zero rows is PASSED after 2 "
        "of 3. Two sites in one wrapper: the exit status dropped, the plan comparison never true.",
        [('  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=$?\n', '  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=0\n', 1),
         ('  if [ -z "$planned" ] || [ "$ran" != "$planned" ]; then\n', "  if false; then\n", 1)],
    ),
    "wrapper_verdict_ignores_exit": (
        "bench/wrapper_tap_verdicts.sh",
        "The exit half of #795's verdict alone: hypertable_cutover_identity.sh compares the assertions that ran "
        "with the plan but no longer captures psql's exit status, so a file whose session is lost after its "
        "plan completed (psql exits 2, no ERROR:, nothing short) is PASSED where pg_prove fails it. One site.",
        [('  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=$?\n', '  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=0\n', 1)],
    ),
    "discriminate_counts_uninstallable": (
        "bench/discriminate_installs.sh",
        "Pre-#601 bench/discriminate.sh: a mutant is never installed before its guard runs, so a mutation "
        "whose patched text no longer compiles certifies its guard as discriminating although the guard's "
        "only failure is that the module did not install and it never reached an assertion. One site: the "
        "mutant's install check removed (the unmutated source's check stays, and is harmless alone).",
        [('      installs "$target_c" "$src" "$OUT/$name.sql" "${db}_install" "$OUT/$name.install.log" || installed=0\n',
          "", 1)],
    ),
    "discriminate_list_on_stdin": (
        "bench/discriminate_installs.sh",
        "Pre-#601 bench/discriminate.sh: the mutation listing is read on stdin and the guards inherit it, so "
        "the first `docker exec -i` a guard makes forwards the rest of the listing into the container and "
        "the loop ends early, reporting PASS for the mutations it reached (on main at 8c1be7c shard 4/4 "
        "counted 76 of 78). Four sites: the listing back on stdin, the guard's stdin no longer /dev/null, and "
        "the read-count check disabled.",
        [
            ("while IFS=$'\\t' read -r name guard why src <&3; do\n",
             "while IFS=$'\\t' read -r name guard why src; do\n", 1),
            ('done 3< "$LIST"\n', 'done < "$LIST"\n', 1),
            ('>"$OUT/$name.log" 2>&1 </dev/null; then', '>"$OUT/$name.log" 2>&1; then', 1),
            ('if [ "$i" != "$listed" ]; then', "if false; then", 1),
        ],
    ),
    "discriminate_counts_liveness_only": (
        "bench/discriminate_installs.sh",
        "Pre-#713 bench/discriminate.sh: any non-zero exit of a guard run against its installed mutant is "
        "certified as 'fails when the defect is present', so a guard whose only failures are LIVENESS "
        "witnesses (the mutant starved the fixture, the defect check never ran or passed) is counted as "
        "discriminating and the track reports PASS. One site: the starved-fixture branch of the verdict, whole.",
        [("  elif starved \"$OUT/$name.log\"; then\n"
          "    # Its failures are printed after a marker, so that none of them reads as a failure of whatever runs this.\n"
          "    printf 'FAIL  %s failed only LIVENESS witnesses against its mutant: the fixture starved and never "
          "reached the defect, so the guard is unverified\\n' \"$guard\"\n"
          "    grep -E '^[[:space:]]*not ok|^FAIL' \"$OUT/$name.log\" | sed 's/^[[:space:]]*/      guard: /'\n"
          "    fail=1\n", "", 1)],
    ),
    "retire_straddles_horizon": (
        "bench/retire_straddle.sh",
        "Pass 3 seed: retire() compares the partition's LO, not its hi, with the retention horizon, so a "
        "partition straddling the horizon (lo below it, hi above it) is judged entirely past it and dropped "
        "with the rows above the horizon in it. One site, the refusal at the top of retire(). tests/60's "
        "straddling-partition refusal catches it.",
        [("  if pgpm._native_gt(cfg.control_kind, r.hi, v_boundary) then\n",
          "  if pgpm._native_gt(cfg.control_kind, r.lo, v_boundary) then\n", 1)],
    ),
    "archive_contract_no_overclaim": (
        "bench/archive_overclaim.sh",
        "Pass 3 seed: _archive_contract_breach no longer refuses covered_hi > hi, so a strategy that "
        "over-claims (says it covered a range above the chunk it was handed) records coverage retire() then "
        "trusts, and rows the strategy never archived are dropped as archived. One site: the second range "
        "check, removed whole. tests/115's over-claim refusal catches it.",
        [("    if pgpm._native_gt(p_kind, p_covered_hi, p_hi) then\n"
          "      return 'covered_hi must not exceed hi: the strategy is claiming coverage of a range it was not handed';\n"
          "    end if;\n", "", 1)],
    ),
    "config_stamp_waits_on_row": (
        "bench/config_stamp_lock.sh",
        "Pre-#662 sweeps: the bookkeeping writes to a parent's pgpm.config row (maintain_all's two "
        "sweep_turn_at stamps, maintain_obtain's clearing and arming of obtain_retry_after) WAIT for the row "
        "instead of skipping it while another transaction holds it. Drops SKIP LOCKED from "
        "_config_try_lock, the one site all four writes go through, so each waits exactly as the bare "
        "UPDATE did: under a lock_timeout the 55P03 escapes the sweep, which has no handler, and the first "
        "parent's stamp, with none, waits until the sweeper's statement_timeout. tests/167 catches it in "
        "both parts: the sweeps return ERROR, and the parents behind the held one keep their aged "
        "partitions and unbuilt lookahead.",
        [("  perform 1 from pgpm.config where parent_table = p_parent for no key update skip locked;\n",
          "  perform 1 from pgpm.config where parent_table = p_parent for no key update;\n", 1)],
    ),
    "abort_owner_alive_by_pid_only": (
        "bench/transmute_abort_owner.sh",
        "Pass 3 seed: transmute_abort tests the claim owner's liveness by pid alone, passing null for the "
        "recorded backend_start, so _session_alive never matches a live backend (backend_start = null is "
        "null) and the owner reads as dead: any session can abort a conversion still running in another, and "
        "a reused pid is never told apart from the original. One site. tests/101's live-owner refusal "
        "catches it.",
        [("  if pgpm._session_alive(r.owner_pid, r.owner_backend_start) and r.owner_pid <> pg_backend_pid() then\n",
          "  if pgpm._session_alive(r.owner_pid, null) and r.owner_pid <> pg_backend_pid() then\n", 1)],
    ),
    "set_retain_strict_horizon": (
        "bench/set_retain_horizon.sh",
        "Pass 4 seed: set_retain's would-drop guard tests hi < new horizon instead of hi <= it, while retain() "
        "drops hi <= horizon, so a partition whose hi lands exactly on the new horizon (the common case: horizons "
        "are grid-floored, so they fall on partition edges) is not named, the tightening is accepted, and the "
        "next retain() tick drops a partition the old value kept. One site, the guard's own predicate. tests/98's "
        "tightening and arm-from-null refusals catch it.",
        [("       and not pgpm._native_gt(cfg.control_kind, p.hi, v_new_boundary)\n",
          "       and pgpm._native_gt(cfg.control_kind, v_new_boundary, p.hi)\n", 1)],
    ),
    "regrain_sync_share_update_exclusive": (
        "bench/regrain_writer_waits.sh",
        "Pass 4 seed: regrain() takes SHARE UPDATE EXCLUSIVE on the parent instead of SHARE (#580). That mode "
        "admits a writer's ROW EXCLUSIVE, so the write into the source's range proceeds to the parent, queues on "
        "the source behind the capture trigger's SHARE ROW EXCLUSIVE holding the parent lock, and the swap's "
        "DETACH waits on it: the pre-#580 40P01 is back with a lock statement still in place. One site. "
        "tests/149's completion-without-40P01 assertion catches it, as it catches the lock's removal.",
        [("  execute format('lock table only %s in share mode', p_parent::text);\n",
          "  execute format('lock table only %s in share update exclusive mode', p_parent::text);\n", 1)],
    ),
    "text_time_collation_default_trusted": (
        "bench/text_time_default_collation.sh",
        "Pass 4 seed: _check_text_time_collation returns early for a column carrying the database default "
        "collation and judges only an explicit COLLATE, so a text_time column in a database whose default "
        "collation does not order the digit alphabet bytewise (an ICU locale with numeric ordering, or any "
        "locale that weighs digits by value) is accepted and its rows are routed by an order that disagrees "
        "with the encoding. One site: the default-collation branch, which resolves the effective locale for "
        "the message, becomes a return. tests/122's default-collation refusal catches it.",
        [("  if v_collnsp = 'pg_catalog' and v_collname = 'default' then\n"
          "    select coalesce(j->>'datlocale', j->>'daticulocale', j->>'datcollate') into v_dbloc\n"
          "      from (select to_jsonb(d) as j from pg_database d where d.datname = current_database()) x;\n"
          "  end if;\n",
          "  if v_collnsp = 'pg_catalog' and v_collname = 'default' then\n"
          "    return;\n"
          "  end if;\n", 1)],
    ),
    "regrain_truncate_guard_no_upgrade": (
        "bench/regrain_truncate_guard_upgrade.sh",
        "Pre-#650 upgrade path: re-running install.sql over a regrain in flight since before #449 puts no "
        "TRUNCATE guard on its source, so a TRUNCATE between the upgrade and the regrain's next tick goes "
        "through and the swap attaches copies of every truncated row. One site: the upgrade loop's ensure "
        "call, emptied. The resuming tick still ensures the guard, so tests/169 passes against this mutant "
        "and only the guard's before-any-tick assertions catch it.",
        [("    perform pgpm._regrain_truncate_guard_ensure(r.child);\n", "    null;\n", 1)],
    ),
    "regrain_truncate_guard_no_resume": (
        "bench/regrain_truncate_guard_upgrade.sh",
        "Pre-#650 regrain_step: a tick that resumes (capture present, so no prepare) does not put back a "
        "missing TRUNCATE guard, so a source that lost it (dropped by hand, or a regrain begun before #449 "
        "on an install whose upgrade step did not run) stays unguarded to its swap. One site: the ensure "
        "call on the resume path, removed. The upgrade loop is intact, so the guard's section 2 still "
        "passes; its section 4 and tests/169 section (A) catch it.",
        [("  perform pgpm._regrain_truncate_guard_ensure(v_child);\n", "", 1)],
    ),
    "retire_trusts_part_attached": (
        "bench/retire_detached_unreferenced.sh",
        "Issue #652: retire() stops asking pg_inherits whether the child is still a partition before its "
        "first side effect, which is the pre-fix shape on the one-step path: pgpm.part.attached is trusted, "
        "so a table an operator DETACHed to keep is write-blocked and dropped with its rows by the next "
        "retain(). One site, the refusal right after the identity check, switched off. tests/171 part A "
        "catches the drop, part B the write block the referenced path used to put on it.",
        [("  if r.retiring_at is null and not exists (\n"
          "       select 1 from pg_inherits i\n"
          "        where i.inhparent = p_parent\n",
          "  if false and not exists (\n"
          "       select 1 from pg_inherits i\n"
          "        where i.inhparent = p_parent\n", 1)],
    ),
    "retire_refuses_own_detach": (
        "bench/retire_detached_unreferenced.sh",
        "Issue #652, the plausible-but-wrong fix: refuse EVERY child that is no longer a partition, without "
        "asking whether pgpm's own retirement detached it (retiring_at). A referenced partition's retirement "
        "then never completes: the detach pgpm dispatched lands and retire() refuses the DROP it was waiting "
        "for, forever. One site, the retiring_at clause of the same refusal. tests/171 part B's completion "
        "of pgpm's own detach catches it.",
        [("  if r.retiring_at is null and not exists (\n"
          "       select 1 from pg_inherits i\n",
          "  if not exists (\n"
          "       select 1 from pg_inherits i\n", 1)],
    ),
    "retain_recall_never": (
        "bench/retain_recall_armed_detach.sh",
        "Issue #724, the pre-fix shape: nothing takes back a retirement retention no longer reaches. A "
        "referenced partition's dispatched detach stays armed after set_retain loosens retention (or an id "
        "frontier moves back), pg_cron detaches it, retire() is never called on it again and nothing "
        "re-attaches it, so its rows vanish from every read of the parent with nothing logged. One site, "
        "_retain_recall's loop, made to select nothing. tests/194 parts A, B and C catch it.",
        [("  for r in select child_name, lo, hi, retiring_oid, child_oid from pgpm.part\n"
          "            where parent_table = p_parent and attached and retiring_at is not null\n",
          "  for r in select child_name, lo, hi, retiring_oid, child_oid from pgpm.part\n"
          "            where parent_table = p_parent and attached and retiring_at is not null and false\n", 1)],
    ),
    "retain_recall_clears_at_once": (
        "bench/retain_recall_armed_detach.sh",
        "Issue #724, the plausible-but-wrong fix: the recall clears the retiring marker in the same call that "
        "returns the job to idle. A detach pg_cron had already picked up still runs, and lands on a partition "
        "with no marker, which reads as detached by an operator, so nothing re-attaches it and its rows stay "
        "out of the parent. One site, the marker cleared in the recall branch. tests/194 part B catches it.",
        [("                         v_nsp, r.child_name, coalesce(v_boundary, 'none')));\n"
          "        v_n := v_n + 1;\n"
          "        continue;\n",
          "                         v_nsp, r.child_name, coalesce(v_boundary, 'none')));\n"
          "        update pgpm.part set retiring_at = null, retiring_oid = null\n"
          "         where parent_table = p_parent and child_name = r.child_name;\n"
          "        v_n := v_n + 1;\n"
          "        continue;\n", 1)],
    ),
    "retain_recall_ignores_horizon": (
        "bench/retain_recall_armed_detach.sh",
        "Issue #724, overreach in the other direction: every retirement under way is taken back, whether or "
        "not retention still reaches the partition. A loosening that still reaches it (or any tick) recalls "
        "the detach retire() just armed, so a referenced partition's retirement never completes. One site, "
        "the horizon check at the top of _retain_recall's loop, removed. tests/194 part D catches it.",
        [("    -- still reached: the retirement stands, and retire() finishes it\n"
          "    continue when v_boundary is not null and not pgpm._native_gt(cfg.control_kind, r.hi, v_boundary);\n",
          "", 1)],
    ),
    "control_followed_noop": (
        "bench/control_column_rename.sh",
        "Issue #826, the pre-fix shape at every reader: pgpm._control_followed hands back the control column "
        "name recorded at transmute instead of the partition key's current one. After ALTER TABLE ... RENAME "
        "COLUMN of the key, obtain's ceiling check runs `select '<bound>'::` and every tick logs skip_obtain, "
        "the id frontier, extend_to, regrain's copy and untransmute's CHECK name a column that no longer "
        "exists, and set_partition_tz and set_regrain fail open. One site, the helper's lookup. tests/219 "
        "parts A to E catch it.",
        [("  p_cfg.control_column := coalesce(\n"
          "    (select a.attname\n",
          "  p_cfg.control_column := coalesce(\n"
          "    (select null::name\n", 1)],
    ),
    "control_followed_obtain_only": (
        "bench/control_column_rename.sh",
        "Issue #826, the per-site fix: only the line the issue names follows the rename (obtain's ceiling "
        "check reads the column's type through the partition key), and every other reader keeps the recorded "
        "name. The reported symptom is gone, so tests/219 part A passes; parts B to E (the id frontier, "
        "extend_to, regrain, set_partition_tz, untransmute) catch it.",
        [("  p_cfg.control_column := coalesce(\n"
          "    (select a.attname\n",
          "  p_cfg.control_column := coalesce(\n"
          "    (select null::name\n", 1),
         ("    from pg_attribute a where a.attrelid = p_parent and a.attname = cfg.control_column;\n\n"
          "  v_frontier := pgpm._frontier_native(p_parent);\n",
          "    from pg_attribute a join pg_partitioned_table pt on pt.partrelid = a.attrelid and a.attnum = pt.partattrs[0]\n"
          "   where a.attrelid = p_parent;\n\n"
          "  v_frontier := pgpm._frontier_native(p_parent);\n", 1)],
    ),
    "control_followed_missing_at_retain": (
        "bench/control_column_rename.sh",
        "Issue #826, the class rather than a site: one reader added (or edited) without the follow. "
        "pgpm.retain loads its config row and goes on without pgpm._control_followed, so after a rename it "
        "would hand the stale name to everything it calls. No part of tests/219 exercises retain after a "
        "rename, so only part F, which checks that every whole-row config load in the installed code is "
        "followed, catches it.",
        [("  select * into cfg from pgpm.config where parent_table = p_parent;\n"
          "  cfg := pgpm._control_followed(cfg);\n"
          "  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;\n"
          "  -- #724: first, take back",
          "  select * into cfg from pgpm.config where parent_table = p_parent;\n"
          "  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;\n"
          "  -- #724: first, take back", 1)],
    ),
    "control_followed_missing_at_for_loop_load": (
        "bench/control_column_rename.sh",
        "Issue #999, the class in another spelling: pgpm.retain loads its config row in a FOR loop "
        "(`for cfg in select * from pgpm.config ... loop end loop;`, the shape status() and progress() use) "
        "and goes on without pgpm._control_followed, so after a rename it hands the stale control column name "
        "to everything it calls. FOUND and the row are what the SELECT INTO left, so nothing else changes. "
        "Pre-#999 tests/219 part F enumerated loads by the spelling `select * into <var> from pgpm.config` "
        "alone, so this load dropped out of its list and the sweep stayed green; part F now enumerates the "
        "FOR-loop shape too.",
        [("  select * into cfg from pgpm.config where parent_table = p_parent;\n"
          "  cfg := pgpm._control_followed(cfg);\n"
          "  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;\n"
          "  -- #724: first, take back",
          "  for cfg in select * from pgpm.config where parent_table = p_parent loop end loop;\n"
          "  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;\n"
          "  -- #724: first, take back", 1)],
    ),
    "retain_recall_parent_schema": (
        "bench/retain_recall_moved_parent.sh",
        "Issue #778, the pre-fix shape: _retain_recall resolves a retiring partition in the PARENT's current "
        "schema, the one lifecycle step #727 left there. After ALTER TABLE <parent> SET SCHEMA the partition "
        "stays where it was, so a loosening logs fail_retain_identity ('oid nothing now'), its disarm names a "
        "command the job does not hold, pg_cron detaches a partition the policy keeps, and no tick re-attaches "
        "it. One site, the schema the loop resolves in. tests/204 parts A, B and C catch it.",
        [("    v_nsp := pgpm._child_nsp(p_parent, r.child_name);\n"
          "    v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));\n"
          "    v_cmd_q := pgpm._detach_cmd(p_parent, v_nsp, r.child_name);\n",
          "    select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n"
          "    v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));\n"
          "    v_cmd_q := pgpm._detach_cmd(p_parent, v_nsp, r.child_name);\n", 1)],
    ),
    "retain_recall_by_oid": (
        "bench/retain_recall_moved_parent.sh",
        "Issue #778, the plausible-but-wrong fix: find the retiring partition by the oid pgpm recorded instead "
        "of by its name in its own schema. A moved parent's recall works, but the identity check compares the "
        "recorded oid with itself, so a relation squatting on the partition's name is never refused: the "
        "recall logs retain_recall over a command that now names the squatter, where it must log "
        "fail_retain_identity. One site, how the loop resolves the name. tests/204 part C catches it.",
        [("    v_nsp := pgpm._child_nsp(p_parent, r.child_name);\n"
          "    v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));\n",
          "    v_nsp := pgpm._child_nsp(p_parent, r.child_name);\n"
          "    v_now := coalesce(r.retiring_oid, r.child_oid)::regclass;\n", 1)],
    ),
    "child_nsp_parent_schema": (
        "bench/moved_parent_lifecycle.sh",
        "Issue #727: pgpm._child_nsp answers with the PARENT's current schema again, the pre-fix shape of "
        "every lifecycle step at once (retire, _install_write_block, _remove_write_block, _is_write_blocked, "
        "_enforce_write_blocks, _archive_step, _next_archive_chunk, _archive_noop). After ALTER TABLE <parent> "
        "SET SCHEMA the partitions stay where they were, so no step finds one again: skip_write_block, "
        "fail_retain_identity ('oid nothing now'), nothing archived, retention wedged. One site, the helper's "
        "body. tests/197 parts A to D all catch it (D through its sibling's retirement, its liveness witness).",
        [("""  select coalesce(
    (select n.nspname from pgpm.part p
       join pg_class c on c.oid = p.child_oid
       join pg_namespace n on n.oid = c.relnamespace
      where p.parent_table = p_parent and p.child_name = p_child),
    (select n.nspname from pg_inherits i
       join pg_class c on c.oid = i.inhrelid
       join pg_namespace n on n.oid = c.relnamespace
      where i.inhparent = p_parent and c.relname = p_child
      limit 1),
    (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent));
""", """  select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
""", 1)],
    ),
    "write_block_presence_only": (
        "bench/write_block_enabled_state.sh",
        "Pre-#651 _is_write_blocked: true whenever the pgpm_write_block trigger EXISTS, whatever its enable "
        "state, so a block that is present and does not fire (origin-only, as a pre-#450 pgpm installed it and "
        "a session_replication_role = replica writer passes; or disabled by hand) reads as in force. The #452/#564 "
        "discard in _enforce_write_blocks and retire() then keeps the coverage recorded under it, "
        "_install_write_block repairs the trigger to ALWAYS, the stale watermark reads as full coverage, and "
        "retire() drops the partition with a row no strategy was handed. One site, the tgenabled = 'A' "
        "condition. tests/170 catches it on all three paths: maintain's step, a direct retire(), and "
        "_archive_step archiving under an origin-only block.",
        [("     where t.tgname = 'pgpm_write_block' and c.relname = p_child and c.relnamespace = v_nsp_oid\n"
          "       and t.tgenabled = 'A'\n",
          "     where t.tgname = 'pgpm_write_block' and c.relname = p_child and c.relnamespace = v_nsp_oid\n", 1)],
    ),
    "regrain_capture_name_cut": (
        "bench/regrain_capture_name_fits.sh",
        "Pre-#655 _regrain_capture_derive: the delta and trigger-function names are left(<rel> || suffix, 63) "
        "again, whatever the length. For a parent named 63 bytes (an ALTER TABLE ... RENAME to anything that "
        "long lands there) the delta name IS the parent's, and a parent that never regrained has nothing "
        "recorded, so the resolver falls back to it: regrain_cancel TRUNCATEs the managed table, untransmute "
        "DROPs the restored one and uninstall.sql DROPs it with every partition. tests/160's oid-form names, "
        "its ids 1..45 after regrain_cancel and the untransmuted table's 46 rows are what catch it.",
        [("""  delta := case when octet_length(v_rel || '_pgpm_regrain_delta') <= 63 then v_rel || '_pgpm_regrain_delta'
                else 'pgpm_regrain_delta_' || p_parent::oid end;
  fn    := case when octet_length(v_rel || '_pgpm_regrain_capture') <= 63 then v_rel || '_pgpm_regrain_capture'
                else 'pgpm_regrain_capture_' || p_parent::oid end;
""", """  delta := left(v_rel || '_pgpm_regrain_delta', 63)::name;
  fn    := left(v_rel || '_pgpm_regrain_capture', 63)::name;
""", 1)],
    ),
    "regrain_capture_backfill_adopts_parent": (
        "bench/regrain_capture_name_fits.sh",
        "The upgrade backfill (#496) takes whatever relation holds the name older releases minted a delta "
        "under, left(<rel> || '_pgpm_regrain_delta', 63), for this parent's delta, with no check that it is "
        "a plain table. For a 63-byte parent that name is the parent itself, so a re-run of install.sql "
        "records the parent as its OWN delta by oid, and every reader then resolves it by identity: "
        "regrain_cancel TRUNCATEs the managed table even with the derive fixed. tests/160 section (C), "
        "which re-runs the install, is what catches it. The #969 proof goes too: it would refuse the parent "
        "on its own (no capture function writes it), so with it in place this would not be the pre-#655 shape.",
        [(REGRAIN_CAPTURE_BACKFILL_BLOCK,
          REGRAIN_CAPTURE_BACKFILL_BLOCK.replace(
              REGRAIN_CAPTURE_BACKFILL_PLAIN, "    if v_delta is null then continue; end if;\n").replace(
              REGRAIN_CAPTURE_BACKFILL_PROOF, ""), 1)],
    ),
    "obtain_explicit_name_uncaught": (
        "bench/obtain_explicit_name_too_long.sh",
        "Pre-#663 _obtain_name: the #572 explicit-range fallback asks _part_name for the collided cell's "
        "_p<lo>_to_<hi> name and lets its #510 over-63-byte refusal escape. obtain is one function, so on an "
        "upgraded east-of-UTC day grid whose table name is 38 to 51 bytes the raise unwinds every cell the "
        "tick would have built: maintain_obtain logs skip_obtain on every tick and the grid never grows "
        "again. tests/161's obtained=N status, its no-skip_obtain check and the cells past the collided one "
        "are what catch it.",
        [("""  begin
    v_name := pgpm._part_name(p_rel, cfg.control_kind, cfg.partition_step, p_lo, p_hi, cfg.partition_tz, true);
  exception when raise_exception then
    if sqlerrm not like 'pg_partition_magician: cannot name a partition of %' then raise; end if;
    return null;
  end;
""", """  v_name := pgpm._part_name(p_rel, cfg.control_kind, cfg.partition_step, p_lo, p_hi, cfg.partition_tz, true);
""", 1)],
    ),
    "hypertable_derived_names_unchecked": (
        "bench/hypertable_derived_names.sh",
        "Pre-#552 pgpm_hypertable: _from_hypertable_check_names refuses nothing, so the working names "
        "<rel>_pgpm_dest, _pgpm_delta, _pgpm_delta_fn and _pgpm_delta_trg are cut to 63 bytes by the parser "
        "again. At 55 bytes the destination and the delta cut to one name: the skeleton drops the delta and "
        "takes its name, and the capture trigger on the live source inserts key-only rows into the "
        "destination, failing every write. tests/timescale/db/23's pinned refusals (the copy, the "
        "preflight, the cutover, both drains, the 49-byte boundary) are what catch it.",
        [("  if v_long is not null then\n"
          "    raise exception 'pg_partition_magician: cannot migrate hypertable % -- the working relation name",
          "  if false then\n"
          "    raise exception 'pg_partition_magician: cannot migrate hypertable % -- the working relation name", 1)],
    ),
    "text_time_decode_rounded_floor": (
        "bench/grid_floor_exact.sh",
        "#659: _text_time_to_ts takes floor() of the general numeric quotient v_wide / 2^discard_bits again, "
        "which rounds to a bounded scale before floor() sees it, so a KSUID whose 128 random low bits are near "
        "all-ones decodes one second late (23:59:59 reads as the next day's 00:00:00) and, as the oldest row, "
        "makes transmute's monolith CHECK exclude it. One site. tests/174's KSUID decode and conversion catch it.",
        [("  v_count := pgpm._floor_div(v_wide, power(2::numeric, p_discard_bits));",
          "  v_count := floor(v_wide / power(2::numeric, p_discard_bits));", 1)],
    ),
    "grid_floor_id_rounded_floor": (
        "bench/grid_floor_exact.sh",
        "#659: _grid_floor's id branch takes floor((x - anchor) / step) over general numeric division again, "
        "so at a snowflake-scale step of 3e16 the id 1799999999999999999 floors to 1800000000000000000, above "
        "itself, and transmute's monolith CHECK excludes the oldest row. One site. tests/174's id floor and "
        "conversion catch it.",
        [("    return (pgpm._floor_div(p_native::numeric - p_anchor::numeric, p_step::numeric) * p_step::numeric",
          "    return (floor((p_native::numeric - p_anchor::numeric) / p_step::numeric) * p_step::numeric", 1)],
    ),
    "grid_floor_fixed_float_floor": (
        "bench/grid_floor_exact.sh",
        "#659: _grid_floor's fixed-step time branch counts steps in double precision again, "
        "floor(epoch(ts - anchor) / secs), so with an anchor in year 1 the last microsecond before a day "
        "boundary divides to the boundary's own count and floors above its input. One site. tests/174's "
        "year-1 anchor floor and conversion catch it.",
        [("      k := pgpm._floor_div(extract(epoch from (ts - anc)), v_secs)::bigint;",
          "      k := floor(extract(epoch from (ts - anc)) / v_secs::float8)::bigint;", 1)],
    ),
    "regrain_lock_noop": (
        "bench/regrain_drivers_serialize.sh",
        "Pre-#554 regrain path: nothing serialises the calls that drive or reconfigure a regrain of one "
        "parent. The body of pgpm._regrain_lock becomes a no-op, so regrain_step, regrain_cancel, regrain(), "
        "set_regrain and set_partition_tz all still call it and take nothing. tests/162's two-session "
        "sections catch it three ways: a second regrain_step reads the cursor around the first one's "
        "uncommitted batch and dies on the fine child's key (C); set_regrain reads around an uncommitted "
        "prepare, finds no run in flight and its UPDATE then lands on the committed one (D); and a step "
        "issued behind an uncommitted regrain_cancel logs a regrain_restart of the run the cancel tore down (E). "
        "Section (A), the single-session retarget refusal, passes on this mutant, which is why the refusal "
        "has a mutation of its own.",
        [("""  insert into pgpm.regrain_lock (parent_table)
    select p_parent where exists (select 1 from pgpm.config where parent_table = p_parent)
  on conflict (parent_table) do nothing;
  perform 1 from pgpm.regrain_lock where parent_table = p_parent for update;
""", "  null;\n", 1)],
    ),
    "set_regrain_retarget_midflight": (
        "bench/regrain_drivers_serialize.sh",
        "Pre-#554 set_regrain: a change of target while a run is in flight is accepted (pass-3 F8-02, pass-4 "
        "F3-02 and F9-03). Nothing records the step the run was started at, so every later tick walks the "
        "half-built run on the new grid against copies cut on the old one: a CHECK violation on the old "
        "first child, or a swap re-check refusing as if retention had been loosened, on every tick. Removes "
        "only the refusal; the lock stays, so tests/162's sections (A) and (B) are what catch it.",
        [("""  if p_target_step is not null and p_target_step is distinct from cfg.regrain_to
     and pgpm._regrain_in_flight(p_parent) then
""", """  if false then
""", 1)],
    ),
    "set_partition_tz_regrain_midflight": (
        "bench/set_partition_tz_midflight.sh",
        "Pre-#660 set_partition_tz: a zone change while a regrain is in flight is accepted, since the lattice "
        "checks judge only attached bounds and the run's copies are not attached. The rest of the run is "
        "computed in the new zone, overlaps the copies cut in the old one and leaves a hole the swap refuses "
        "on every attempt. Removes only the refusal; the lock stays. tests/163's single-session refusal (A) "
        "and its two-session one (B) both catch it.",
        [("""  if v_tz is distinct from cfg.partition_tz and pgpm._regrain_in_flight(p_parent) then
""", """  if false then
""", 1)],
    ),
    "set_partition_tz_config_unlocked": (
        "bench/set_partition_tz_grid_lock.sh",
        "Pre-#725 set_partition_tz: it reads its config row without FOR UPDATE, so nothing it holds conflicts "
        "with the FOR KEY SHARE obtain() and extend_to() take (its own UPDATE takes FOR NO KEY UPDATE, which "
        "does not). It judges committed pgpm.part around another session's uncommitted cells and accepts a "
        "zone change that leaves the grid's top off the new lattice, and an extension already past its read "
        "builds on the old one. One site. tests/195's four sections all catch it.",
        [("  select * into cfg from pgpm.config where parent_table = p_parent for update;\n",
          "  select * into cfg from pgpm.config where parent_table = p_parent;\n", 1)],
    ),
    "extend_to_config_unlocked": (
        "bench/set_partition_tz_grid_lock.sh",
        "Pre-#725 extend_to: it reads its config row without FOR KEY SHARE, so a zone change neither waits for "
        "its uncommitted cells nor holds it off while the change is uncommitted. Only extend_to's read; "
        "obtain's and the setter's locks stay. tests/195's sections (A) and (B) catch it.",
        [("""  -- change under it, and set_partition_tz cannot judge the grid around the cells it has not committed.
  select * into cfg from pgpm.config where parent_table = p_parent for key share;
""", """  -- change under it, and set_partition_tz cannot judge the grid around the cells it has not committed.
  select * into cfg from pgpm.config where parent_table = p_parent;
""", 1)],
    ),
    "obtain_config_unlocked": (
        "bench/set_partition_tz_grid_lock.sh",
        "Pre-#725 obtain: it reads its config row without FOR KEY SHARE, so a maintain tick's obtain and a zone "
        "change neither wait for the other. Only obtain's read; extend_to's and the setter's locks stay. "
        "tests/195's sections (C) and (D) catch it.",
        [("""  -- waits for a zone change in flight and then sees the zone it committed. See pgpm.set_partition_tz.
  select * into cfg from pgpm.config where parent_table = p_parent for key share;
""", """  -- waits for a zone change in flight and then sees the zone it committed. See pgpm.set_partition_tz.
  select * into cfg from pgpm.config where parent_table = p_parent;
""", 1)],
    ),
    "transmute_identity_reseed_preflight": (
        "bench/cutover_reread_window.sh",
        "Pre-#656 transmute: where each identity sequence resumes is read in the PREFLIGHT, before phase 1, "
        "and 8b reseeds the parent from it. Writers run on until the cutover's ACCESS EXCLUSIVE, so every id "
        "they take is issued again: the guard's writer takes 6, 7, 8 and 40 after the resume's preflight, "
        "the parent's sequence resumes at 6, and the first insert fails with a duplicate key. The under-lock "
        "refresh at 0b is removed, so 8b reseeds from the preflight's floors (max, min and _seq_next, which "
        "the merged preflight reads anyway): exactly the pre-#656 values.",
        [("  select o_names, o_defs into v_out_names, v_out_defs from pgpm._transmute_outgoing_fks(p_parent);\n"
          "  if v_idcols is not null then\n"
          "    for v_i in 1 .. array_length(v_idcols, 1) loop\n"
          "      v_ra := pgpm._identity_resume_at(p_parent, v_idcols[v_i], v_idnext[v_i], v_idmax[v_i], v_idmin[v_i]);\n"
          "      v_idnext[v_i] := v_ra.o_next; v_idmax[v_i] := v_ra.o_max; v_idmin[v_i] := v_ra.o_min;\n"
          "    end loop;\n"
          "  end if;\n",
          "  select o_names, o_defs into v_out_names, v_out_defs from pgpm._transmute_outgoing_fks(p_parent);\n", 1)],
    ),
    "transmute_carried_indexes_preflight": (
        "bench/cutover_reread_window.sh",
        "Pre-#630 transmute: step 9b carries the secondary-index list the PREFLIGHT read, and the cutover "
        "never lists them again. CREATE INDEX takes only SHARE, so the unique index the guard's second "
        "session commits while the cutover waits follows the rename onto the monolith alone, and a "
        "duplicate routed to a forward partition goes in. One site: the cutover's second asking.",
        [("  -- back to the resumable phase-2 state. Before the renames, so p_parent still resolves by its own name.\n"
          "  select o_names, o_defs into v_idx_names, v_idx_defs\n"
          "    from pgpm._transmute_carried_indexes(p_parent, v_nsp, p_control, v_ctl_attnum, v_reuse_idx);\n",
          "  -- back to the resumable phase-2 state. Before the renames, so p_parent still resolves by its own name.\n", 1)],
    ),
    "transmute_outgoing_fks_preflight": (
        "bench/cutover_reread_window.sh",
        "Pre-#630 transmute: step 7a re-adds the outgoing-key list the PREFLIGHT read. ADD FOREIGN KEY takes "
        "only SHARE ROW EXCLUSIVE, so the key the guard's second session commits while the cutover waits "
        "stays on the monolith, and an orphan routed to a forward partition goes in. One site: the "
        "cutover's second asking.",
        [("  select o_names, o_defs into v_out_names, v_out_defs from pgpm._transmute_outgoing_fks(p_parent);\n"
          "  if v_idcols is not null then\n"
          "    for v_i in 1 .. array_length(v_idcols, 1) loop\n"
          "      v_ra := pgpm._identity_resume_at(",
          "  if v_idcols is not null then\n"
          "    for v_i in 1 .. array_length(v_idcols, 1) loop\n"
          "      v_ra := pgpm._identity_resume_at(", 1)],
    ),
    "transmute_comments_before_lock": (
        "bench/cutover_reread_window.sh",
        "Pre-#630 transmute: the table and column comments are read and replayed onto the staging parent "
        "BEFORE the cutover's ACCESS EXCLUSIVE. COMMENT takes only SHARE UPDATE EXCLUSIVE, which the "
        "staging LIKE's ACCESS SHARE does not exclude, so the comments the guard's second session commits "
        "while the cutover waits are lost. The block is moved to just before the lock, which is later than "
        "the pre-fix read and still misses them.",
        [(TRANSMUTE_COMMENTS_UNDER_LOCK, "", 1),
         ("  -- 0b (triggers). The outage starts HERE",
          TRANSMUTE_COMMENTS_UNDER_LOCK + "  -- 0b (triggers). The outage starts HERE", 1)],
    ),
    "transmute_owner_rls_before_like": (
        "bench/reread_under_lock_tap.sh",
        "Pre-#630 transmute: the owner and the RLS flags are read at the start of phase 3, BEFORE the "
        "staging LIKE whose ACCESS SHARE is what excludes ALTER OWNER and ENABLE ROW LEVEL SECURITY, so "
        "a change committed between the read and the LIKE is not carried. No second session can land "
        "there on cue; tests/159's event trigger on the staging CREATE TABLE changes both at the latest "
        "point the window allows, and its parent keeps the old owner with RLS off.",
        [(TRANSMUTE_OWNER_RLS_AFTER_LIKE, "", 1),
         ("  -- #344: everything below that only touches the NEW parent",
          TRANSMUTE_OWNER_RLS_AFTER_LIKE + "\n  -- #344: everything below that only touches the NEW parent", 1)],
    ),
    "untransmute_trigger_capture_before_lock": (
        "bench/reread_under_lock_tap.sh",
        "Pre-#666 untransmute: the parent's triggers are captured before its explicit ACCESS EXCLUSIVE "
        "(#443's second gate), under only the first gate's ACCESS SHARE, which does not exclude CREATE "
        "TRIGGER or DISABLE TRIGGER. tests/158's writer creates tg158_b and disables tg158_a while the lock "
        "is queued; the restored table lacks the one and fires the other.",
        [(UNTRANSMUTE_TRIGGER_CAPTURE_UNDER_LOCK, "", 1),
         ("  -- THE GATE, AGAIN, UNDER THE LOCK (#443).",
          UNTRANSMUTE_TRIGGER_CAPTURE_UNDER_LOCK + "  -- THE GATE, AGAIN, UNDER THE LOCK (#443).", 1)],
    ),
    "untransmute_identity_reseed_before_lock": (
        "bench/reread_under_lock_tap.sh",
        "Pre-#656 untransmute: where the restored identity sequence resumes is read before the explicit "
        "ACCESS EXCLUSIVE, so the ids tests/157's writer takes while the lock is queued (6, 7 and 60) are "
        "issued again and the first insert after the reversal collides. The under-lock refresh is removed, "
        "so the reseed uses the pre-lock loop's floors (max, min and _seq_next), exactly the pre-#656 values.",
        [(UNTRANSMUTE_IDENTITY_UNDER_LOCK, "", 1)],
    ),
    "frontier_decodes_malformed_max": (
        "bench/frontier_malformed_max.sh",
        "Issue #661: _frontier_native decodes a text_time max(control) without first asking whether it has "
        "the declared shape, so a maximum PostgreSQL routed into a partition by string order (a digit outside "
        "the alphabet, a field shorter than the width) makes _decode raise, every obtain tick is logged as "
        "skip_obtain and the forward grid stops growing. One site: the shape fallback to now(), removed "
        "whole. tests/175's frontier, obtain and grid-identity assertions catch it.",
        [("  if cfg.control_kind = 'text_time'\n"
          "     and not pgpm._text_time_shaped(v_max, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix,\n"
          "                                    cfg.text_time_alphabet) then\n"
          "    return pgpm._ts_text(now());\n"
          "  end if;\n", "", 1)],
    ),
    "dropped_fk_never_reconciled": (
        "bench/dropped_fk_reconcile.sh",
        "Issue #658: _forget_dangling_fks forgets nothing, so a pgpm.dropped_fk record whose referencing table "
        "was dropped (or whose restored key was dropped by hand) is acted on as if the catalog still backed "
        "it: untransmute's and suspend_incoming_fks's DROP CONSTRAINT die on the bare oid every time (the "
        "table can be neither reversed nor regrained), and restore/validate log a failure every tick. One "
        "site, the helper's DELETE, which the four callers share. tests/173 catches it in every section.",
        [("    delete from pgpm.dropped_fk d\n     where d.parent_table = p_parent\n",
          "    delete from pgpm.dropped_fk d\n     where false and d.parent_table = p_parent\n", 1)],
    ),
    "dropped_fk_live_key_never_adopted": (
        "bench/restore_fk_adopts_live_key.sh",
        "Issue #832, the pre-fix shape: _forget_dangling_fks reconciles only a restored record whose key is "
        "gone, never a SUSPENDED record whose key the operator re-added by hand. restore_incoming_fks re-adds "
        "it blindly and logs fail_restore_incoming_fk ('already exists') on every call, and untransmute's "
        "pre-drop loop skips it, so the live key stops the DETACH with 23503. One site, the adoption's "
        "UPDATE, which every caller shares. tests/227 parts A and B catch it.",
        [("     where d.parent_table = p_parent and d.restored_at is null\n"
          "       and k.conrelid = d.referencing_table and k.conname = d.constraint_name\n",
          "     where false and d.parent_table = p_parent and d.restored_at is null\n"
          "       and k.conrelid = d.referencing_table and k.conname = d.constraint_name\n", 1)],
    ),
    "dropped_fk_adopt_by_name": (
        "bench/restore_fk_adopts_live_key.sh",
        "Issue #832, the plausible-but-wrong fix: adopt a suspended record whose NAME is live on its "
        "referencing table, without asking that the key be against this parent. A namesake against another "
        "table is recorded as the restored key, so its honest 'already exists' failure is swallowed and the "
        "record says live while RI against the parent is off. One site, the adoption's confrelid test. "
        "tests/227 part A catches it.",
        [("       and k.contype = 'f' and k.confrelid = d.parent_table\n"
          "    returning d.constraint_name, k.convalidated\n",
          "       and k.contype = 'f'\n"
          "    returning d.constraint_name, k.convalidated\n", 1)],
    ),
    "regrain_step_mixed_month_duration": (
        "bench/regrain_target_shape.sh",
        "Pre-#674: _regrain_step_shape does not refuse a month count mixed with a duration. _grid_next's "
        "calendar branch keeps the months and drops the rest, so the #588 forward test and the #341 width "
        "comparison both pass '1 month 1 day', '1 month -40 days' (below zero by interval ordering) and "
        "'-1 month 40 days', set_regrain stores them, and once a coarse child freezes every tick's "
        "regrain_step raises 'mixed month + duration interval unsupported' from _grid_floor and logs "
        "skip_regrain. One site: the mixed-shape test becomes 'if false'. tests/164 catches it at every "
        "mixed refusal it pins and at the valid target they must leave in place.",
        [("    if v_months <> 0 and v_rest <> interval '0' then\n", "    if false then\n", 1)],
    ),
    "regrain_step_date_subday": (
        "bench/regrain_target_shape.sh",
        "Pre-#674: _regrain_step_shape does not apply transmute's #581 date rule to a regrain target, so "
        "set_regrain stores '12 hours' or '36 hours' on a date column, whose fine cells' bounds truncate to "
        "dates. One site: the date test becomes 'if false'. Part two of tests/164 catches it (both sub-day "
        "refusals and the whole-day target they must leave in place).",
        [("    if v_typname = 'date' and v_months = 0 and extract(epoch from p_step::interval)::numeric % 86400 <> 0 then\n",
          "    if false then\n", 1)],
    ),
    "regrain_step_fraction_on_integer": (
        "bench/regrain_target_integral.sh",
        "Pre-#641 (F3-04): _regrain_step_shape does not refuse a fractional target on an integer control "
        "column. set_regrain('2.5') on a bigint grid passes every other call-time check, and every tick "
        "after the prepare fails creating the first fine child (invalid input syntax for type bigint: "
        "\"0.0\") and logs skip_regrain with the capture trigger left on the source; regrain() raises the "
        "same raw error. One site: the whole-number test becomes 'if false'. tests/165 catches it at the "
        "bigint and int4 refusals, at regrain_step's and regrain()'s, and at the valid target the refused "
        "calls must leave in place; its numeric case still passes, which is what shows the rule is the "
        "column's.",
        [("    if v_typname in ('int2', 'int4', 'int8') and p_step::numeric <> trunc(p_step::numeric) then\n",
          "    if false then\n", 1)],
    ),
    "regrain_step_scale_on_integer": (
        "bench/regrain_target_step_spelling.sh",
        "Pre-#784 (pass 6 F3-02): _regrain_step_shape tests a regrain target's VALUE on an integer control "
        "column and not its spelling, so set_regrain('10.0') on a bigint grid is stored, the grid carries the "
        "step's scale into every bound ('0.0'), and every tick after the prepare fails creating the first fine "
        "cell (invalid input syntax for type bigint) and logs skip_regrain with the capture trigger left on "
        "the source; regrain_step and regrain() raise the same raw error. One site: the scale check becomes "
        "'if false'. tests/210 catches it at the bigint, int2 and int4 refusals, at regrain_step's, regrain()'s "
        "and the tick's, and at the valid target a refused call must leave in place; its numeric case and "
        "the separate #641 refusal of '2.5' still pass, which is what shows the mutant is this rule alone.",
        [("    if v_typname in ('int2', 'int4', 'int8') and p_step::numeric = trunc(p_step::numeric) and scale(p_step::numeric) > 0 then\n",
          "    if false then\n", 1)],
    ),
    "regrain_step_scale_by_typname": (
        "bench/regrain_target_column_scale.sh",
        "Pre-#899 (pass 8 F3-05): _regrain_step_shape refuses a fractional regrain target only on a column "
        "whose type NAME is int2, int4 or int8, so set_regrain('0.5') on a numeric(12,0) key is stored, the "
        "run copies every sub-range, and at the swap ATTACH PARTITION coerces the fine bounds to the key's "
        "typmod ('0.5' and '1.0' both to 1) and fails 'empty range bound' on every tick, with the capture "
        "trigger and the TRUNCATE refusal left on the source. One site: the scale check becomes 'if false'. "
        "tests/252 catches it at the numeric(12,0) and numeric(12,1) refusals, at regrain_step's, regrain()'s "
        "and the tick's, at the valid target a refused call must leave in place and at the source left "
        "without capture; its accepted 0.5 on numeric(12,1) and the domain-over-bigint cases still pass, "
        "which is what shows the mutant is this rule alone.",
        [("    if v_scale is not null and p_step::numeric <> round(p_step::numeric, v_scale) then\n",
          "    if false then\n", 1)],
    ),
    "regrain_step_shape_domain_blind": (
        "bench/regrain_target_column_scale.sh",
        "#899's second half put back: _regrain_step_shape judges a domain-typed control column by the "
        "domain's own name, so a domain over numeric(12,0) carries no scale and a domain over bigint is "
        "neither int2, int4 nor int8, and a fractional or fraction-spelled target is stored on either. One "
        "site: the walk to the base type and its typmod becomes 'while false'. tests/252 catches it at the "
        "domain refusals (0.5 through two domains, 2.5 and 10.0 on a domain over bigint) while its plain "
        "numeric(p,s) refusals still pass.",
        [("  while (select t.typtype from pg_type t where t.oid = v_type) = 'd' loop\n",
          "  while false loop\n", 1)],
    ),
    "regrain_step_time_precision_unread": (
        "bench/regrain_target_time_precision.sh",
        "Pre-#980 (pass 9 F3-03): _regrain_step_shape has no precision rule for a time key, so "
        "set_regrain('500 milliseconds') on a timestamptz(0) key is stored, the run copies every sub-range, "
        "and at the swap ATTACH PARTITION rounds the fine bounds to whole seconds ('..:20.5' and '..:21' both "
        "to '..:21') and fails 'empty range bound', with the capture trigger and the TRUNCATE refusal left on "
        "the source. One site: the precision check becomes 'if false'. tests/277 catches it at the "
        "timestamptz(0), timestamp(1), timestamptz(3) and domain refusals, at regrain_step's, regrain()'s and "
        "the tick's, at the valid target a refused call must leave in place and at the source left without "
        "capture; its accepted whole-second, 500 ms on timestamp(1), month and microsecond steps still pass, "
        "which is what shows the mutant is this rule alone.",
        [("    if v_time_unit is not null then\n",
          "    if false then\n", 1)],
    ),
    # #669-#671: three transmute contract gaps, each caught by its own pgTAP file through a wrapper in
    # bench/transmute_abort_owner.sh's shape.
    "carried_index_name_by_pattern": (
        "bench/carried_index_quoted_name.sh",
        "Issue #669 put back: step 9b renames each carried secondary index by regexp_replace over "
        "'^CREATE (UNIQUE )?INDEX \\S+ ON ', which cannot match a quoted name holding a space, so the rewrite "
        "no-ops and the cutover re-runs the ORIGINAL CREATE INDEX (a raw 42P07) after phases 1 and 2 committed "
        "the bound. One site, the identity splice replaced whole by the pattern. tests/179's conversion of "
        "\"Body Lookup\", \"by tag ON body\" and \"Uniq Id Body\" catches it.",
        [("""      v_ipfx_q := 'CREATE INDEX ' || quote_ident(v_old) || ' ON ';
      v_upfx_q := 'CREATE UNIQUE INDEX ' || quote_ident(v_old) || ' ON ';
      if starts_with(v_idx_defs[j], v_upfx_q) then
        v_pdef_q := 'CREATE UNIQUE INDEX ' || quote_ident(v_new) || ' ON ONLY ' || substr(v_idx_defs[j], length(v_upfx_q) + 1);
      elsif starts_with(v_idx_defs[j], v_ipfx_q) then
        v_pdef_q := 'CREATE INDEX ' || quote_ident(v_new) || ' ON ONLY ' || substr(v_idx_defs[j], length(v_ipfx_q) + 1);
      else
        raise exception 'pg_partition_magician: cannot carry the index % of %: its definition (%) does not start with CREATE [UNIQUE] INDEX % ON, so its partitioned copy cannot be named',
          quote_ident(v_old), p_parent, v_idx_defs[j], quote_ident(v_old);
      end if;
""", """      v_pdef_q := regexp_replace(v_idx_defs[j], '^CREATE (UNIQUE )?INDEX \\S+ ON ',
                                 'CREATE \\1INDEX ' || quote_ident(v_new) || ' ON ONLY ');
""", 1)],
    ),
    "transmute_identity_kind_only": (
        "bench/transmute_identity_options.sh",
        "Issue #670 put back: _identity_options yields nothing, so transmute's step 6 and untransmute re-add "
        "identity with its kind alone and the new sequence takes the defaults, dropping INCREMENT BY, "
        "MINVALUE/MAXVALUE, CYCLE and CACHE. One site, the helper both callers share; the lattice-aware "
        "reseed stays, so the mutant is exactly 'the options are not carried'. tests/180's increment, bounds "
        "and next-id assertions catch it (an INCREMENT BY 2 identity hands out 10 after 9).",
        [("    from pg_sequence s where s.seqrelid = p_seq;\n$$;\n",
          "    from pg_sequence s where false;\n$$;\n", 1)],
    ),
    "transmute_name_guard_relations_only": (
        "bench/transmute_type_squatter.sh",
        "Issue #671 put back: _type_squatter never finds a type, so the staging-name and monolith-name guards "
        "see relations only (to_regclass) and an enum or domain holding either name reaches the cutover, "
        "whose CREATE TABLE or RENAME dies with a raw 42710 after phases 1 and 2 committed the bound and the "
        "claim. One site, the helper both guards share. tests/181's enum and domain refusals catch it.",
        [("   where n.nspname = p_nsp and t.typname = p_name and t.typrelid = 0\n",
          "   where false and n.nspname = p_nsp and t.typname = p_name and t.typrelid = 0\n", 1)],
    ),
    "transmute_time_frontier_clock_only": (
        "bench/transmute_future_maximum.sh",
        "Issue #668 put back: the time kind's frontier is now() alone and max(control) is never read, so "
        "the #457 allowance check never runs for it and a future-dated row is found only by phase 2's "
        "VALIDATE (a raw 23514) after phase 1 committed the write-rejecting bound and the claim. One site, "
        "the time branch of the frontier computation. tests/178's refusal, raised-hi and infinity "
        "assertions catch it.",
        [(TIME_FRONTIER_BLOCK_RE, "    v_frontier_native := pgpm._ts_text(now());\n", 1)],
    ),
    "untransmute_security_not_restored": (
        "bench/untransmute_security_state.sh",
        "Pre-#667 untransmute: the parent's grants, row-security flags and policies are captured but never "
        "put on the restored table, so it comes back with the ACL, RLS state and policies the monolith kept "
        "from the conversion: a REVOKE issued on the managed table since is undone (the revoked role reads "
        "it again), row security enabled since comes off, and a policy dropped since comes back. Removes the "
        "reset-and-replay after the rename whole, one site; tests/176's post-reversal assertions catch it, "
        "and its LIVENESS witnesses show the monolith really carried the stale state into the reverse.",
        [("""  foreach v_tdef in array v_grantdefs loop
    execute v_tdef;
  end loop;
  execute format('alter table %s %s row level security', v_restored::text,
                 case when v_rls then 'enable' else 'disable' end);
  execute format('alter table %s %s row level security', v_restored::text,
                 case when v_rls_force then 'force' else 'no force' end);
  for v_g in select polname from pg_policy where polrelid = v_restored loop
    execute format('drop policy %I on %s', v_g.polname, v_restored::text);
  end loop;
  foreach v_tdef in array v_poldefs loop
    execute v_tdef;
  end loop;
""", "", 1)],
    ),
    "untransmute_monolith_by_position": (
        "bench/untransmute_monolith_identity.sh",
        "Pre-#672 untransmute: the monolith is the attached partition with the smallest lo, not the relation "
        "transmute recorded in pgpm.config.monolith_oid. Once retention has retired the original table, or a "
        "regrain's swap has replaced it, that is a forward partition or the first fine child; with every "
        "remaining row inside it the outside-rows door passes, and it is detached and handed back under the "
        "table's name as the restored original instead of refused. One site, the lookup at the gate, put "
        "back as it was (transmute still records the oid, so the mutant is exactly 'untransmute does not "
        "use it'); tests/177's sections (A) and (B) catch it.",
        [("""  if cfg.monolith_oid is null then
    raise exception 'pg_partition_magician: cannot untransmute % -- pgpm has no record of which partition is the original table (the conversion predates pgpm.config.monolith_oid and the upgrade could not identify it), and it will not hand back a partition it cannot prove is the original',
      p_parent;
  end if;
  select c.relname, p.lo, p.hi into v_mon, v_mon_lo, v_mon_hi
    from pgpm.part p
    join pg_inherits i on i.inhrelid = p.child_oid and i.inhparent = p_parent
    join pg_class c on c.oid = p.child_oid
   where p.parent_table = p_parent and p.attached and p.child_oid = cfg.monolith_oid;
  if v_mon is null then
    raise exception 'pg_partition_magician: cannot untransmute % -- the original table (the monolith transmute recorded, oid %) is no longer one of its partitions: retention retired it or a regrain replaced it with finer children, so there is no original to hand back. This is a one-way door.',
      p_parent, cfg.monolith_oid;
  end if;
  v_monreg := cfg.monolith_oid::regclass;
""", """  execute format('select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and attached order by lo::%s asc limit 1',
                 p_parent::text, pgpm._native_type(cfg.control_kind)) into v_mon, v_mon_lo, v_mon_hi;
  if v_mon is null then
    raise exception 'pg_partition_magician: cannot untransmute % -- no managed partition found', p_parent;
  end if;
  v_monreg := format('%I.%I', v_nsp, v_mon)::regclass;
""", 1)],
    ),
    # #730: one mutation per refusal, all three judged by the same guard (tests/187), so each refusal is
    # shown to be caught on its own rather than only all three together.
    "transmute_carries_not_valid_check": (
        "bench/transmute_uncarriable_shapes.sh",
        "Issue #730 put back for a NOT VALID constraint: the preflight never finds one, so the cutover's "
        "LIKE gives the parent a validated copy and its ATTACH dies raw ('conflicts with NOT VALID "
        "constraint on child table') after phases 1 and 2 committed the bound and the claim. One site, the "
        "NOT VALID query. tests/187's refusal of nvc_amt_pos (and, on 18, of nvn_amt_nn) catches it.",
        [("   where conrelid = p_parent and contype in ('c', 'n') and not convalidated\n",
          "   where false and conrelid = p_parent and contype in ('c', 'n') and not convalidated\n", 1)],
    ),
    "transmute_carries_no_inherit_check": (
        "bench/transmute_uncarriable_shapes.sh",
        "Issue #730 put back for a CHECK ... NO INHERIT: the preflight never finds one, so the cutover's "
        "CREATE TABLE ... LIKE INCLUDING CONSTRAINTS dies raw ('cannot add NO INHERIT constraint to "
        "partitioned table') after phases 1 and 2 committed the bound and the claim. One site, the NO "
        "INHERIT query. tests/187's refusal of nic_amt_pos catches it.",
        [("   where conrelid = p_parent and contype = 'c' and connoinherit;\n",
          "   where false and conrelid = p_parent and contype = 'c' and connoinherit;\n", 1)],
    ),
    "transmute_generated_control": (
        "bench/transmute_uncarriable_shapes.sh",
        "Issue #730 put back for a GENERATED control column: the preflight reads its type only, so the "
        "cutover's CREATE TABLE ... PARTITION BY RANGE dies raw ('cannot use generated column in partition "
        "key') after phases 1 and 2 committed the bound and the claim. One site, the attgenerated lookup. "
        "tests/187's refusal of gcc.d catches it.",
        [("       where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) <> '' then\n",
          "       where false and a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) <> '' then\n", 1)],
    ),
    # #766 bullet 3: the cutover asks the #730 refusals again, before its staging LIKE, under the ACCESS SHARE
    # it takes for that. One mutation per helper it calls, so each second asking is shown caught on its own.
    "transmute_uncarried_constraints_preflight_only": (
        "bench/transmute_uncarried_shapes_under_lock.sh",
        "Pre-#766 transmute: the NOT ENFORCED, NOT VALID and NO INHERIT CHECK refusals are asked in the "
        "preflight only. A NOT VALID CHECK committed after it (tests/283 (A), added with phase 1's bound) "
        "reaches the cutover, whose LIKE gives the parent a validated copy, and the ATTACH dies raw "
        "('conflicts with NOT VALID constraint on child table'); a NO INHERIT one (B) fails the LIKE itself "
        "('cannot add NO INHERIT constraint to partitioned table'). Both after phases 1 and 2 committed the "
        "bound and the claim. One site: the cutover's second asking of the constraint helper.",
        [("  perform pgpm._transmute_refuse_generated_control(p_parent, p_control);\n"
          "  perform pgpm._transmute_refuse_uncarried_constraints(p_parent);\n",
          "  perform pgpm._transmute_refuse_generated_control(p_parent, p_control);\n", 1)],
    ),
    "transmute_generated_control_preflight_only": (
        "bench/transmute_uncarried_shapes_under_lock.sh",
        "Pre-#766 transmute: the generated-control-column refusal is asked in the preflight only. A control "
        "column dropped and re-added as a stored generated column after it (tests/283 (C)) reaches the "
        "cutover, whose CREATE TABLE ... PARTITION BY RANGE dies raw ('cannot use generated column in "
        "partition key') after phases 1 and 2 committed. One site: the cutover's second asking of the "
        "generated-column helper.",
        [("  perform pgpm._transmute_refuse_generated_control(p_parent, p_control);\n"
          "  perform pgpm._transmute_refuse_uncarried_constraints(p_parent);\n",
          "  perform pgpm._transmute_refuse_uncarried_constraints(p_parent);\n", 1)],
    ),
    "transmute_key_immediate": (
        "bench/transmute_key_deferrability.sh",
        "Issue #731 put back: step 8 re-creates the reused key on the parent as a bare ADD PRIMARY KEY / "
        "ADD UNIQUE, which still adopts a DEFERRABLE monolith key, so every forward partition's clone is "
        "immediate and a one-statement key swap the table accepted before fails with a duplicate key. Both "
        "branches (the primary key and the unique constraint) lose the clause, the one site that carries "
        "it. tests/188's flag, forward-partition and swap assertions on dpk and duq catch it.",
        [("coalesce(v_key_defer, '')", "''", 2)],
    ),
    # Issue #726, one mutation per site the helper serves, so each is proven caught on its own.
    "orphan_guard_id_label_19_digits": (
        "bench/orphan_guard_id_labels.sh",
        "Pre-#726 _is_fine_child_label: an id suffix is a fine child's label when it is 19 digits, the "
        "label before #582. An orphan named for a cell at or past 10^19 (20 digits), a fractional cell "
        "(`_<frac>`) or a short negative one passes transmute's guard and restore_incoming_fks's gate: the "
        "conversion completes, obtain leaves that cell unbuilt with nothing logged, and the FK is re-added "
        "while a child is still out of the parent. The helper's id branch goes back to the old pattern, "
        "which reaches both sites; tests/196's three refusals and its two gate zeros catch it.",
        [("""  if p_suffix !~ '^(0*-)?[0-9]+(_[0-9]+)?$' then
    return false;
  end if;
""", """  return p_suffix ~ '^[0-9]{19}$';
  if p_suffix !~ '^(0*-)?[0-9]+(_[0-9]+)?$' then
    return false;
  end if;
""", 1)],
    ),
    "fk_gate_id_label_19_digits": (
        "bench/orphan_guard_id_labels.sh",
        "The drift #726 closes: restore_incoming_fks's in-flight gate matches an id child's suffix with its "
        "own '^[0-9]{19}$' again instead of asking the helper transmute's orphan guard asks. The guard is "
        "correct and the gate is not, so a suspended FK is re-added while a 20-digit or fraction-labelled "
        "child is still out of the parent. Only the gate's call goes back; tests/196's two gate zeros, and "
        "the 1 the gate returns once the orphans are gone, catch it.",
        [("""     and pgpm._is_fine_child_label(cfg.control_kind, substr(c.relname, length(v_rel) + 3))
""", """     and case when cfg.control_kind = 'id'
              then substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{19}$'
              else substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{4}(_[0-9]+)*$'
         end
""", 1)],
    ),
    "transmute_exclude_not_refused": (
        "bench/transmute_refusal_edges.sh",
        "Pre-#710 transmute: nothing refuses an EXCLUDE constraint. Its index is not unique, so it is listed "
        "as a plain secondary to carry, phases 1 and 2 commit the validated bound and the claim, and step "
        "9b's ATTACH of the constraint's index under a plain partitioned copy dies with a raw 'index "
        "definitions do not match': the table rejects every write past hi until a transmute_abort. The "
        "refusal in _transmute_carried_indexes is disarmed, one site; tests/189 A's pinned refusal, its "
        "no-claim and no-bound checks and its write past hi catch it (the conversion runs over dblink, so "
        "the mutant really commits).",
        [("  if v_excl_q is not null then\n", "  if false then\n", 1)],
    ),
    "transmute_publication_owner_late": (
        "bench/transmute_refusal_edges.sh",
        "Pre-#710 transmute: a role that owns the table but not a publication naming it is not refused up "
        "front, so the cutover's ALTER PUBLICATION ... ADD TABLE fails with a raw 'must be owner of "
        "publication' after phases 1 and 2 committed the bound and the claim. The up-front refusal is "
        "disarmed, one site; tests/189 B's pinned refusal and its state checks catch it.",
        [("  if v_unowned_pub_q is not null then\n", "  if false then\n", 1)],
    ),
    "set_regrain_anchor_name_only": (
        "bench/transmute_refusal_edges.sh",
        "Pre-#710 set_regrain: only the anchor cell's name is asked about at the target step, so a numeric "
        "key's later cells, whose labels carry a fraction, can be refused at tick time by regrain_step on "
        "every tick (skip_regrain). The _regrain_names_fit call is removed, one site; tests/189 C's 1e-23 "
        "target, accepted by the mutant, catches it.",
        [("""  if p_target_step is not null then
    perform pgpm._regrain_names_fit(p_parent, cfg, v_rel, p_target_step);
  end if;
""", "", 1)],
    ),
    "untransmute_owner_not_restored": (
        "bench/reverse_legibility_edges.sh",
        "Pre-#710 untransmute: the parent's owner is not carried back, so after ALTER TABLE ... OWNER TO on "
        "the managed table (which does not reach its partitions) the restored table is owned by the "
        "conversion-time owner and the role that owned the managed table has no privilege on it. The owner "
        "change after the rename is removed, one site; tests/190 A catches it.",
        [("""  if (select relowner from pg_class where oid = v_restored) <> v_owner then
    execute format('alter table %s owner to %I', v_restored::text, pg_get_userbyid(v_owner));
  end if;
""", "", 1)],
    ),
    "untransmute_comments_not_restored": (
        "bench/reverse_legibility_edges.sh",
        "Pre-#710 untransmute: the parent's table and column comments are captured and never replayed, so "
        "the restored table comes back with the comments it had at the conversion. The replay loop is "
        "removed, one site; tests/190 A's comment assertions catch it.",
        [("""  foreach v_tdef in array v_comdefs loop
    execute v_tdef;
  end loop;
""", "", 1)],
    ),
    "write_block_reenable_unlogged": (
        "bench/reverse_legibility_edges.sh",
        "Pre-#710 _install_write_block: a write block an operator disabled is put back ENABLE ALWAYS on the "
        "next revisit with no log row, so the partition goes read-only again and pgpm.log says nothing. "
        "The insert is removed, one site; tests/190 B's write_block_reenable row catches it.",
        [("""      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'write_block_reenable', r.lo, r.hi,
                format('%I.%I: pgpm_write_block was %s and is ENABLE ALWAYS again (retention''s fence)',
                       v_nsp, p_child,
                       case v_enabled when 'D' then 'disabled' when 'R' then 'replica-only' else 'origin-only' end));
""", "", 1)],
    ),
    "obtain_unbuilt_cell_unlogged": (
        "bench/reverse_legibility_edges.sh",
        "Pre-#710 obtain and extend_to: a cell _obtain_name leaves unbuilt (its name held by a relation that "
        "is not this table's partition) is skipped with nothing logged, a hole the operator finds through "
        "refused writes. Both _log_unbuilt_cell calls are removed, two sites; tests/190 C's "
        "fail_obtain_name rows catch it.",
        # extend_to's (deeper) call first: obtain's six-space line is a substring of it
        [("        perform pgpm._log_unbuilt_cell(p_parent, cfg, v_nsp, v_rel, v_lo, v_hi);\n", "        null;\n", 1),
         ("      perform pgpm._log_unbuilt_cell(p_parent, cfg, v_nsp, v_rel, v_lo, v_hi);\n", "      null;\n", 1)],
    ),
    "part_name_bc_unmarked": (
        "bench/reverse_legibility_edges.sh",
        "Pre-#710 _part_name: a time label is to_char's YYYY... alone, which drops the era, so year N BC "
        "and year N AD share every label. Both `_bc` suffixes go, two sites; tests/190 D catches it.",
        [("         || case when extract(year from p_lo_native::timestamptz at time zone v_label_tz) < 0 then '_bc' else '' end;\n",
          "         || '';\n", 1),
         ("           || case when extract(year from p_hi_native::timestamptz at time zone v_label_tz) < 0 then '_bc' else '' end;\n",
          "           || '';\n", 1)],
    ),
    "regrain_delta_reanalyzed": (
        "bench/reverse_legibility_edges.sh",
        "Pre-#710 _regrain_reconcile: the delta is re-ANALYZEd whenever reltuples <= 0, and ANALYZE of an "
        "empty delta records 0, so every regrain step re-ANALYZEs it while it stays empty, each time taking "
        "SHARE UPDATE EXCLUSIVE on it. One site; tests/190 E's lock probe on the later steps catches it.",
        [("  if v_reltuples < 0 or (v_reltuples = 0 and v_delta_has_rows) then",
          "  if v_reltuples <= 0 then", 1)],
    ),
    "grid_floor_offset_double": (
        "bench/reverse_legibility_edges.sh",
        "Pre-#710 _grid_floor: the fixed step's offset from the anchor is make_interval(secs => k * v_secs), "
        "through double precision, so a fractional-second step far from the anchor ('1.000001 seconds' "
        "from a year-1 anchor) floors microseconds off its lattice and the next cell's floor is not the "
        "previous cell's next. One site; tests/190 F catches it.",
        [("""      return pgpm._ts_text(anc + make_interval(hours => trunc(v_h / 2)::int)
                               + make_interval(hours => (v_h - trunc(v_h / 2))::int,
                                               secs => ((v_us - v_h * 3600000000) / 1000000)::double precision));
""", """      return pgpm._ts_text(anc + make_interval(secs => k * v_secs));
""", 1)],
    ),
    "transmute_grants_before_lock": (
        "bench/reread_under_lock_remaining_tap.sh",
        "Pre-#706 transmute: the grants are read and replayed onto the staging parent with the rest of the "
        "#344 staging work, before the cutover's ACCESS EXCLUSIVE and long before the rename. GRANT and REVOKE "
        "take no lock on the table, so the REVOKE and two GRANTs tests/185 (A)'s second session commits after "
        "that read land on the monolith alone: the parent keeps t185_r1's SELECT and lacks t185_r2's INSERT "
        "and UPDATE (note). The block is moved back to where it was, just before the RLS replay.",
        [(TRANSMUTE_GRANTS_AFTER_ATTACH, "", 1),
         ("  -- RLS. FORCE matters as much as ENABLE", TRANSMUTE_GRANTS_AFTER_ATTACH + "  -- RLS. FORCE matters as much as ENABLE", 1)],
    ),
    "transmute_incoming_gate_preflight_only": (
        "bench/reread_under_lock_remaining_tap.sh",
        "Pre-#706 transmute: the incoming-key gate is asked in the preflight only, and 0c runs for 'preserve' "
        "alone, so under p_incoming_fks => 'error' the key tests/185 (B) adds after the preflight follows the "
        "rename onto the monolith and the conversion completes. One site: the cutover's second asking.",
        [("  perform pgpm._transmute_incoming_gate(p_parent, p_incoming_fks, v_pkcols);\n"
          "  if p_incoming_fks <> 'error' then\n",
          "  if p_incoming_fks <> 'error' then\n", 1)],
    ),
    "transmute_transition_refusal_preflight_only": (
        "bench/reread_under_lock_remaining_tap.sh",
        "Pre-#706 transmute: the transition-table trigger refusal is asked in the preflight only, so the row "
        "trigger tests/185 (C) creates after it is captured and replayed onto the parent, which fails the "
        "cutover with PostgreSQL's raw error instead of pgpm's refusal. One site: the cutover's second asking.",
        [("  -- one committed since the preflight would otherwise reach the replay in 7b and fail it with a raw error.\n"
          "  perform pgpm._transmute_refuse_transition_triggers(p_parent);\n",
          "  -- one committed since the preflight would otherwise reach the replay in 7b and fail it with a raw error.\n", 1)],
    ),
    "transmute_key_shape_unchecked": (
        "bench/reread_under_lock_remaining_tap.sh",
        "Pre-#706 transmute: steps 6 and 8 act on the key and identity the preflight read, and nothing checks "
        "them again once the staging LIKE's ACCESS SHARE holds them still. tests/185 (D) re-declares the "
        "identity ALWAYS after the preflight, and the parent comes back BY DEFAULT. The comparison is made "
        "never true; the preflight's read stays.",
        [("  if pgpm._transmute_key_shape(p_parent, p_control) is distinct from v_keyshape then\n",
          "  if false then\n", 1)],
    ),
    "regrain_janitor_without_lock": (
        "bench/reread_under_lock_remaining_tap.sh",
        "Pre-#706 _enforce_regrain_capture: the janitor reads the cursor without pgpm.regrain_lock, so it judges "
        "a regrain's marks around a driver in flight. tests/185 (E) holds the lock in a second session over an "
        "orphaned capture, and the janitor tears it down instead of skipping. The try-lock is made to succeed.",
        [("  if not pgpm._regrain_try_lock(p_parent) then\n", "  if false then\n", 1)],
    ),
    "regrain_reclaim_without_lock": (
        "bench/reread_under_lock_remaining_tap.sh",
        "Pre-#706 _regrain_reclaim: retire's reclaim reads the cursor and the copies, and clears them, without "
        "pgpm.regrain_lock, so it runs around a step in flight. tests/185 (F) holds the lock in a second "
        "session, and reclaim clears the cursor and drops the copy instead of waiting out its lock_timeout.",
        [("  -- subtransaction (fail_retain_drop) and the next tick retries it.\n"
          "  perform pgpm._regrain_lock(p_parent);\n",
          "  -- subtransaction (fail_retain_drop) and the next tick retries it.\n", 1)],
    ),
    "transmute_identity_options_before_lock": (
        "bench/reread_under_lock_remaining_tap.sh",
        "Issue #732 put back in transmute: the parent's identity sequence keeps the options step 6 read before "
        "the cutover's lock, so the INCREMENT BY 7 tests/186 (A)'s second session commits after that read is "
        "lost: the parent has INCREMENT BY 1 and hands out 12, 13. The under-lock re-read is removed whole.",
        [(TRANSMUTE_IDENTITY_OPTIONS_UNDER_LOCK, "", 1)],
    ),
    "identity_options_unlocked": (
        "bench/reread_under_lock_remaining_tap.sh",
        "Issue #732, the half a re-read alone misses: the options are read under the table's lock but with no "
        "lock on the sequence, and ALTER SEQUENCE takes none on the table, so one committed after the read and "
        "before the commit is still lost. _identity_options_locked takes no lock: tests/186's late ALTER "
        "SEQUENCE, in transmute's cutover and in untransmute, commits instead of waiting.",
        [("  if p_seq is null then return null; end if;\n  perform pg_sequence_last_value(p_seq);\n",
          "  if p_seq is null then return null; end if;\n", 1)],
    ),
    "untransmute_identity_options_before_lock": (
        "bench/reread_under_lock_remaining_tap.sh",
        "Issue #732 put back in untransmute: the parent sequence's options are read in the pre-lock loop, before "
        "the explicit ACCESS EXCLUSIVE, so the INCREMENT BY 7 tests/186 (B)'s second session commits while the "
        "reversal is under way is lost with the parent: the restored table has INCREMENT BY 1 and hands out 6, "
        "7. The under-lock read is removed and the pre-lock one put back, unlocked, as it was.",
        [(UNTRANSMUTE_IDENTITY_OPTIONS_UNDER_LOCK, "", 1),
         ("      v_idnext := array_append(v_idnext, pgpm._seq_next(v_seq));\n    end loop;\n",
          "      v_idnext := array_append(v_idnext, pgpm._seq_next(v_seq));\n"
          "      v_idopts := array_append(v_idopts, pgpm._identity_options(v_seq));\n    end loop;\n", 1)],
    ),
    "check_newest_nulls_first": (
        "bench/check_newest_skips_nulls.sh",
        "Issue #734 put back: check_uuidv7 and check_text_time read the column's maximum with ORDER BY "
        "... DESC LIMIT 1 and no IS NOT NULL, so DESC's NULLS FIRST makes one NULL the maximum and "
        "newest_decoded and newest_in_future come back null while a row years ahead is in the table. Two "
        "sites, one per function. tests/200's future-row and past-row assertions catch it.",
        [("         m as (select pgpm._uuid_to_ts(t.%1$I) as ts from %2$s t where t.%1$I is not null\n"
          "                order by t.%1$I desc limit 1)\n",
          "         m as (select pgpm._uuid_to_ts(t.%1$I) as ts from %2$s t order by t.%1$I desc limit 1)\n", 1),
         ("         m as (select t.%1$I::text as v from %2$s t where t.%1$I is not null order by t.%1$I desc limit 1),\n",
          "         m as (select t.%1$I::text as v from %2$s t order by t.%1$I desc limit 1),\n", 1)],
    ),
    "time_literal_drops_era": (
        "bench/time_literal_era.sh",
        "Pre-#733 _time_literal: the wall time is rendered with to_char 'YYYY' and nothing else, so an instant "
        "before 1 AD loses its era and reads back as an AD year (100 BC as 100 AD). One site, the era clause "
        "removed whole with its comment, so the mutant is the function as it was. tests/199's round-trip "
        "assertions catch it, and its transmute of a table holding a 100 BC row dies at phase 2's VALIDATE "
        "with the monolith bound left on the live table.",
        [("""      || case when abs(v_off) % 60 = 0 then '' else ':' || lpad((abs(v_off) % 60)::text, 2, '0') end
      -- #733: 'YYYY' prints the year without its era, so an instant before 1 AD read back as an AD year
      -- about 2 x |year| later (100 BC became 0100, i.e. 100 AD). The era goes last, where PostgreSQL's
      -- own output puts it and where every DateStyle's input reads it, for all three column types.
      || case when v_wall < timestamp '0001-01-01 00:00:00' then ' BC' else '' end;
""", """      || case when abs(v_off) % 60 = 0 then '' else ':' || lpad((abs(v_off) % 60)::text, 2, '0') end;
""", 1)],
    ),
    "runbook_phantom_alert_action": (
        "bench/doc_log_actions.sh",
        "Pre-#742 blind spot, as a document: docs/runbook.md's step-2 alert query (`and action in (...)`, the "
        "SQL an operator copies into an alert) names 'fail_retire_identity', an action no install.sql writes "
        "(pgpm logs fail_retain_identity), so the alert can never fire. Check 6 of "
        "scripts/check_living_docs.sh read only the reference's vocabulary table and 'logged `x`' prose, so it "
        "passed this; it now reads the docs' SQL literals too and fails it. One site.",
        [("      and action in ('fail_retain_detach', 'fail_retain_crossing', 'fail_retain_identity',\n",
          "      and action in ('fail_retain_detach', 'fail_retain_crossing', 'fail_retire_identity',\n", 1)],
    ),
    "runbook_alert_on_method": (
        "bench/doc_log_actions.sh",
        "Pre-#848 blind spot, as a document: docs/runbook.md's regrain progress query watches for "
        "action in ('skip_regrain', 'copy_swap_drop'). 'copy_swap_drop' is the METHOD regrain's swap logs "
        "under action 'regrain'; no pgpm.log row ever carries it as its action, so the query never shows a "
        "completed regrain. Check 6 counted an action as written when its literal was on any non-comment "
        "install.sql line, which that method's is, so it passed this; it now reads the action position of "
        "each pgpm.log write. One site.",
        [("    where parent_table = 'public.events'::regclass and action in ('skip_regrain', 'regrain')\n",
          "    where parent_table = 'public.events'::regclass and action in ('skip_regrain', 'copy_swap_drop')\n",
          1)],
    ),
    "orphan_refusal_sqlstate_only": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#743 tests/18: the orphaned-child refusal pinned by SQLSTATE alone, throws_ok(..., 'P0001', null, "
        "desc). In its own fixture the one-step monolith's name IS the planted orphan's name, so with the orphan "
        "guard deleted transmute is still refused with P0001, by the monolith-name guard, and the whole file "
        "passes against a pgpm with no orphan guard. The exact pre-#743 assertion.",
        [("""select throws_like(
  $$ call pgpm.transmute('public.og', 'id', 100000) $$,
  'pg_partition_magician: public.og_p0000000000000000000 already exists as a standalone table matching this parent''s partition naming%',
""", """select throws_ok(
  $$ call pgpm.transmute('public.og', 'id', 100000) $$,
  'P0001', null,
""", 1)],
    ),
    "radix_length_refusal_unpinned": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#743 tests/90: _radix_decode's alphabet-length refusal asserted with throws_ok(sql, NULL, NULL) on "
        "_radix_decode('5', 10, '01234'), whose digit '5' is outside the alphabet, so the invalid-digit 22P02 "
        "satisfies it and the assertion passes with the length check deleted. The exact pre-#743 assertion.",
        [("""  $$ select pgpm._radix_decode('3', 10, '01234') $$,
  'P0001', 'pg_partition_magician: alphabet 01234 has length 5, which does not match radix 10',
""", """  $$ select pgpm._radix_decode('5', 10, '01234') $$,
  NULL, NULL,
""", 1)],
    ),
    "id_conservation_after_migration": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#744 tests/11: the 'before' row count is taken AFTER fixtures/demo.sql has already run the "
        "migration and compared with the table's count in the next statement, count = count, which passes "
        "whatever the migration lost. The exact pre-#744 text, plan included.",
        [("select plan(6);\n", "select plan(5);\n", 1),
         ("""-- Conservation is judged against the rows fixtures/demo.sql seeded BEFORE it ran the migration
-- (public.events_id_seeded). A count taken here, after the migration, is the migration's own output, and
-- comparing the table to it compares the count to itself. Identity, not only cardinality: a lost row
-- and a stray one cancel in a count, never in the bag of (id, payload).
select is(
  (select count(*) from public.events_id)::bigint,
  (select count(*) from public.events_id_seeded)::bigint,
  'row count conserved across the id migration (against the count seeded before it)'
);

select bag_eq(
  'select id, payload from public.events_id',
  'select id, payload from public.events_id_seeded',
  'every seeded events_id row survives the migration by identity: none lost, none added, none altered'
);
""", """create temporary table _before_id as select count(*) as n from public.events_id;


select is(
  (select count(*) from public.events_id)::bigint,
  (select n from _before_id)::bigint, 'row count conserved across the id migration'
);
""", 1)],
    ),
    "uuid_conservation_after_migration": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#744 tests/12: as id_conservation_after_migration, for events_uuid. The exact pre-#744 text, "
        "plan included.",
        [("select plan(7);\n", "select plan(6);\n", 1),
         ("""-- Conservation is judged against the rows fixtures/demo.sql seeded BEFORE it ran the migration
-- (public.events_uuid_seeded). A count taken here, after the migration, is the migration's own output, and
-- comparing the table to it compares the count to itself. Identity, not only cardinality: a lost row
-- and a stray one cancel in a count, never in the bag of (id, payload).
select is(
  (select count(*) from public.events_uuid)::bigint,
  (select count(*) from public.events_uuid_seeded)::bigint,
  'row count conserved across the uuid migration (against the count seeded before it)'
);

select bag_eq(
  'select id, payload from public.events_uuid',
  'select id, payload from public.events_uuid_seeded',
  'every seeded events_uuid row survives the migration by identity: none lost, none added, none altered'
);
""", """create temporary table _before_uuid as select count(*) as n from public.events_uuid;


select is(
  (select count(*) from public.events_uuid)::bigint,
  (select n from _before_uuid)::bigint, 'row count conserved across the uuid migration'
);
""", 1)],
    ),
    "regrain_survivors_by_count": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#919 tests/92: the rows regrain's swap moved, judged by count(*) = 250 over ids 1..2500 under a "
        "comment promising identity. A swap that loses row 2500 and invents row 2499 keeps the count, so the "
        "file stays green against it. The exact pre-#919 assertion (the per-row payloads stay; a count "
        "cannot read them).",
        [("""select results_eq(
  $$ select id, ref_id, payload from public.ofk92 order by id $$,
  $$ select id, ref_id, payload from (
       select (g*10)::bigint as id, ((g*10) % 100) + 1 as ref_id, 'p' || (g*10) as payload
         from generate_series(1, 250) g
       union all select 20000::bigint, 1, 'frontier') e order by id $$,
  'every row the regrain copied survived the swap: the same (id, ref_id, payload) rows, none lost, none invented, none altered');
""", """select is((select count(*)::int from public.ofk92 where id between 1 and 2500), 250,
  'every row the regrain copied survived the swap');
""", 1)],
    ),
    "text_time_drought_coverage_only": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#881 tests/88: text_time's #325 drought immunity for cuid asserted only as 'a partition covers "
        "now()' after one tick and 'a row at now() is accepted'. Both hold with text_time dropped from "
        "_frontier_native's greatest(decoded, now()), because transmute's monolith takes its upper bound from "
        "its OWN inline greatest() and so covers now() by itself on the day of the transmute; the file stayed "
        "green against that mutant and only bench/frontier_drought.sh caught it. The exact pre-#881 text, "
        "plan included: no stale-data witness, no frontier check, no forward partition past the monolith.",
        [
            ("select plan(10);\n", "select plan(7);\n", 1),
            ("""create temporary table _before_tt as select count(*) as n from public.tt_search;

-- LIVENESS WITNESS: the drought is really present. The frontier and forward-partition checks below are
-- of the form "obtain still reaches past now()", which would also pass against a fixture that was never
-- stale.
select cmp_ok(
  now() - (select max(pgpm._decode('text_time', id, 'c', 8, 36, 'ms')::timestamptz) from public.tt_search),
  '>', interval '2 months',
  'the newest backfilled cuid is well outside the 2-month (p_obtain x step) lookahead about to be configured'
);
""", """create temporary table _before_tt as select count(*) as n from public.tt_search;
""", 1),
            ("""
-- The check above holds on the day of the transmute even with text_time dropped from _frontier_native's
-- greatest(decoded, now()) (#881, as tests/85 explains for uuidv7): transmute's monolith takes its upper
-- bound from its OWN inline greatest(), so the monolith alone covers now() and accepts the write. These
-- two read what only _frontier_native produces, before the live insert below moves the data maximum to
-- now(): the frontier itself, and a FORWARD partition (starting at or past the monolith's hi, so not the
-- monolith; the monolith named by pgpm.config.monolith_oid) covering a point inside the lookahead.
select ok(
  pgpm._frontier_native('public.tt_search'::regclass)::timestamptz >= now(),
  'the text_time frontier obtain measures by is at or past now(), not the 11-month-stale data maximum'
);

select ok(
  exists (
    select 1 from pgpm.part p
     where p.parent_table = 'public.tt_search'::regclass and p.attached
       and p.lo::timestamptz <= now() + interval '1 month' and p.hi::timestamptz > now() + interval '1 month'
       and p.lo::timestamptz >= (select m.hi::timestamptz from pgpm.part m
                                  join pgpm.config c on c.parent_table = m.parent_table and c.monolith_oid = m.child_oid
                                 where m.parent_table = p.parent_table)
  ),
  'a forward partition past the monolith covers now() + 1 month, inside the 2-month lookahead'
);

""", """
""", 1),
        ],
    ),
    "text_time_drought_coverage_only_ulid_ksuid": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#881 tests/91: as text_time_drought_coverage_only, for ULID and KSUID. The exact pre-#881 text, "
        "plan and header included.",
        [
            ("""-- each: refusal on a bad param, successful conversion, row conservation, and the #325 drought-immunity
-- property carrying over to both, asserted as tests/85 asserts it for uuidv7 (#881): a witness that the
-- data really is stale, then the frontier _frontier_native returns and a FORWARD partition past the
-- monolith, both read before the live insert. "A partition covers now()" alone holds even with text_time
-- dropped from _frontier_native's greatest(decoded, now()), because transmute's monolith takes its upper
-- bound from its OWN inline greatest() and so covers now() by itself on the day of the transmute.
""", """-- each: refusal on a bad param, successful conversion, row conservation, and the #325 drought-immunity
-- property carrying over to both.
""", 1),
            ("select plan(15);\n", "select plan(9);\n", 1),
            ("""create temporary table _before_ulid as select count(*) as n from public.tt_ulid;

-- LIVENESS WITNESS: the drought is really present (every check below would pass on a fresh fixture).
select cmp_ok(
  now() - (select max(pgpm._decode('text_time', id, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ')::timestamptz) from public.tt_ulid),
  '>', interval '2 months',
  'ULID: the newest backfilled row is well outside the 2-month (p_obtain x step) lookahead'
);
""", """create temporary table _before_ulid as select count(*) as n from public.tt_ulid;
""", 1),
            (""");
select ok(
  pgpm._frontier_native('public.tt_ulid'::regclass)::timestamptz >= now(),
  'ULID: the frontier obtain measures by is at or past now(), not the 11-month-stale data maximum'
);
select ok(
  exists (select 1 from pgpm.part p where p.parent_table = 'public.tt_ulid'::regclass and p.attached
            and p.lo::timestamptz <= now() + interval '1 month' and p.hi::timestamptz > now() + interval '1 month'
            and p.lo::timestamptz >= (select m.hi::timestamptz from pgpm.part m
                                       join pgpm.config c on c.parent_table = m.parent_table and c.monolith_oid = m.child_oid
                                      where m.parent_table = p.parent_table)),
  'ULID: a forward partition past the monolith covers now() + 1 month, inside the 2-month lookahead'
);
""", """);
""", 1),
            ("""create temporary table _before_ksuid as select count(*) as n from public.tt_ksuid;

-- LIVENESS WITNESS: the drought is really present (every check below would pass on a fresh fixture).
select cmp_ok(
  now() - (select max(pgpm._decode('text_time', id, '', 27, 62, 's',
     '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00')::timestamptz) from public.tt_ksuid),
  '>', interval '2 months',
  'KSUID: the newest backfilled row is well outside the 2-month (p_obtain x step) lookahead'
);
""", """create temporary table _before_ksuid as select count(*) as n from public.tt_ksuid;
""", 1),
            (""");
select ok(
  pgpm._frontier_native('public.tt_ksuid'::regclass)::timestamptz >= now(),
  'KSUID: the frontier obtain measures by is at or past now(), not the 11-month-stale data maximum'
);
select ok(
  exists (select 1 from pgpm.part p where p.parent_table = 'public.tt_ksuid'::regclass and p.attached
            and p.lo::timestamptz <= now() + interval '1 month' and p.hi::timestamptz > now() + interval '1 month'
            and p.lo::timestamptz >= (select m.hi::timestamptz from pgpm.part m
                                       join pgpm.config c on c.parent_table = m.parent_table and c.monolith_oid = m.child_oid
                                      where m.parent_table = p.parent_table)),
  'KSUID: a forward partition past the monolith covers now() + 1 month, inside the 2-month lookahead'
);
""", """);
""", 1),
        ],
    ),
    # Review pass 5's novel seeds (S1, S3, S6, S8, S9): each was planted for the pass, and the suite check
    # showed what caught it, if anything. These put each back so its guard is proven to fail against it.
    "type_squatter_any_schema": (
        "bench/transmute_type_squatter_other_schema.sh",
        "Pass 5 seed S1: _type_squatter loses its n.nspname = p_nsp filter, so a type named like the staging "
        "or monolith name in ANY schema counts, and transmute refuses a conversion whose names are free in the "
        "table's own schema (the only one a table's row type can collide in). One site, the lookup's WHERE. "
        "tests/181 has no other-schema case; tests/201's _type_squatter assertions on the s201 enum and domain "
        "fail, and its conversion of tyo is refused.",
        [("   where n.nspname = p_nsp and t.typname = p_name and t.typrelid = 0\n",
          "   where t.typname = p_name and t.typrelid = 0\n", 1)],
    ),
    "schedule_without_cron_silent": (
        "bench/schedule_without_pg_cron.sh",
        "Pass 5 seed S3: pgpm.schedule() returns null instead of raising when pg_cron is not installed, so the "
        "call that turns the scheduled lifecycle on succeeds while nothing is scheduled, and the grid stops "
        "extending until a late write is rejected. One site, the absence branch's raise. No pgTAP file pinned "
        "the refusal (tests/31 runs where pg_cron lives); tests/202's two throws_like refusals catch it.",
        [("    raise exception 'pg_partition_magician: pg_cron is not installed in this database; enable it "
          "(create extension pg_cron) to schedule maintenance, or call pgpm.maintain_all() and "
          "pgpm.maintain_obtain_all() by hand';\n",
          "    return null;\n", 1)],
    ),
    "throws_ok_null_pattern_113": (
        "bench/throws_pinned.sh",
        "Pass 5 seed S6: tests/113's refusal of a primary key that excludes the control column loosened from "
        "throws_like to throws_ok(sql, NULL, desc), which pins neither SQLSTATE nor message and so also accepts "
        "the 2D000 a transmute that did NOT refuse raises at its first COMMIT inside pgTAP's wrapper; the "
        "relkind check after it passes then too, because the statement rolled back. The second test-file "
        "mutation of this shape (throws_ok_null_pattern is tests/72), on a statement written across lines. "
        "One site: the assertion's opening and its pattern line.",
        [("select throws_like(\n"
          "  $$ call pgpm.transmute('public.t1', 'created_at', interval '1 day', p_obtain => 5) $$,\n"
          "  'pg_partition_magician: cannot partition %t1 on created_at%the primary key t1_pkey (id) does not include created_at%',\n",
          "select throws_ok(\n"
          "  $$ call pgpm.transmute('public.t1', 'created_at', interval '1 day', p_obtain => 5) $$,\n"
          "  NULL,\n", 1)],
    ),
    "untransmute_acl_capture_before_lock": (
        "bench/untransmute_acl_capture_under_lock.sh",
        "Pass 5 seed S8: untransmute captures the parent's privileges and row security (#667) above its "
        "explicit ACCESS EXCLUSIVE (#443's second gate), under only the first gate's ACCESS SHARE, which does "
        "not exclude a GRANT. tests/158 covers the trigger capture (#666) under that lock and nothing covered "
        "this one. tests/203's writer grants SELECT to acl203_late while the lock is queued; the restored "
        "table carries acl203_early's grant and not acl203_late's. Both pieces of the capture move above the "
        "gate, the one anchor the trigger-capture mutation uses too.",
        [(UNTRANSMUTE_ACL_CAPTURE_HEAD, "", 1),
         (UNTRANSMUTE_ACL_CAPTURE_BODY, "", 1),
         ("  -- THE GATE, AGAIN, UNDER THE LOCK (#443).",
          UNTRANSMUTE_ACL_CAPTURE_HEAD + UNTRANSMUTE_ACL_CAPTURE_BODY + "\n  -- THE GATE, AGAIN, UNDER THE LOCK (#443).", 1)],
    ),
    "regrain_clamped_name_by_floor": (
        "bench/regrain_clamped_subrange_names.sh",
        "Pre-#783 naming: a regrain sub-range clamped to a child's off-lattice lo is named at the target "
        "step's own granularity, so a day cell is labelled by the UTC date of its start, which it shares with "
        "the lattice cell before or after it. On a monthly New York grid regrained to a day, February's "
        "clamped first cell renders the name January's last cell holds and every regrain of February is "
        "refused; a Los Angeles monolith's clamped first hour takes the name of the cell after it and "
        "auto-regrain logs skip_regrain on every tick. One site, _regrain_sub_name's finer label replaced "
        "by _part_name's, so the mutant names every sub-range as before. tests/209 parts A, B and C catch it.",
        [("      return pgpm._part_name(p_relname, cfg.control_kind, v_label_steps[i], p_lo, null, cfg.partition_tz);\n",
          "      return pgpm._part_name(p_relname, cfg.control_kind, p_step, p_lo, p_hi, cfg.partition_tz);\n", 1)],
    ),
    "hypertable_cutover_refusals_reordered": (
        "bench/hypertable_replica_capture.sh",
        "Pass 5 seed S9: from_hypertable_cutover's untracked-write refusal (#654) moved AFTER the count-and-"
        "fingerprint comparison (#460, #653). The swap is still refused, so nothing is lost, but a write that "
        "reached the source under session_replication_role = replica is reported as a fingerprint mismatch "
        "that names no key, and the operator is sent after the wrong cause. Both refusals stay whole; only "
        "their order changes, anchored on the conservation block other mutations already use. "
        "tests/timescale/db/25's refusal-message assertions in parts A and B catch it.",
        [(HT_CUTOVER_UNTRACKED_BLOCK, "", 1),
         (HT_CUTOVER_CONSERVATION, HT_CUTOVER_CONSERVATION + HT_CUTOVER_UNTRACKED_BLOCK, 1)],
    ),
    "untransmute_publication_not_restored": (
        "bench/untransmute_publication_membership.sh",
        "Pre-#780 untransmute: the parent's publication memberships are dropped with the parent and the "
        "restored table keeps the monolith's, which date from the conversion, so a publication the managed "
        "table joined since stops publishing it at the reverse (every later write missing at its "
        "subscribers) and one it left publishes it again. Removes the apply after the rename whole, one "
        "site; tests/206's Part A membership, filter and column-list assertions and Part B's late join "
        "catch it, and its LIVENESS witnesses show the monolith really carried the stale set.",
        [(UNTRANSMUTE_PUB_APPLY, "", 1)],
    ),
    "untransmute_publication_capture_before_lock": (
        "bench/untransmute_publication_membership.sh",
        "Issue #780's placement undone: untransmute reads the parent's publication memberships above its "
        "explicit ACCESS EXCLUSIVE (#443's second gate), under only the first gate's ACCESS SHARE, which "
        "does not exclude ALTER PUBLICATION ... ADD or DROP TABLE (SHARE UPDATE EXCLUSIVE). tests/206 Part "
        "B's writer adds the table to pub206_late and removes it from pub206_gone while the lock is queued; "
        "the restored table comes back in pub206_gone and not in pub206_late. One block, moved.",
        [(UNTRANSMUTE_PUB_CAPTURE, "", 1),
         ("  -- THE GATE, AGAIN, UNDER THE LOCK (#443).",
          UNTRANSMUTE_PUB_CAPTURE + "\n  -- THE GATE, AGAIN, UNDER THE LOCK (#443).", 1)],
    ),
    "untransmute_publication_always_readd": (
        "bench/untransmute_publication_membership.sh",
        "Issue #780's apply without its comparison: every membership the restored table has is dropped and "
        "every one the parent had is re-added, matching or not. The memberships come out right, but a "
        "reverse with nothing changed issues an ALTER PUBLICATION per publication, so it needs every "
        "publication's owner where it needed none. tests/206's event-trigger record catches it: pub206_kept "
        "is re-added in Part A, and Part A2's unchanged reverse issues an ADD TABLE. One site.",
        [("""    if v_g.o_def = any(v_pubdefs) then
      v_pubdefs := array_remove(v_pubdefs, v_g.o_def);
    else
      execute format('alter publication %I drop table %s', v_g.o_pub, v_restored::text);
    end if;
""", """      execute format('alter publication %I drop table %s', v_g.o_pub, v_restored::text);
""", 1)],
    ),
    # #779: one mutation per refusal site of _refuse_oid_bound_dependants, all judged by tests/205, so each
    # site is shown to be caught on its own rather than only all of them together.
    "oid_bound_dependants_unrefused": (
        "bench/transmute_oid_bound_dependants.sh",
        "Issue #779 put back, the pre-fix shape: nothing refuses an object that names the table by its oid. A "
        "view over the table follows the cutover's rename into the monolith and silently reads its rows alone, "
        "missing every row routed to a forward partition, and untransmute's DROP fails raw on a view over the "
        "parent or takes a rule on it silently. One site, the helper made to find nothing. tests/205 parts A, "
        "B and C catch it.",
        [("  if v_deps_q is null then\n    return;\n  end if;\n  if p_untransmute then\n",
          "  if v_deps_q is null or true then\n    return;\n  end if;\n  if p_untransmute then\n", 1)],
    ),
    "oid_bound_dependants_cutover_only": (
        "bench/transmute_oid_bound_dependants.sh",
        "Issue #779, the late refusal: the objects are refused only by the cutover, under its lock, after "
        "phases 1 and 2 committed the write-rejecting bound and the claim, so every retry fails the same way "
        "with the table fenced. One site, the preflight's call. tests/205 part A's pinned refusal catches it: "
        "the call, wrapped by pgTAP, now reaches phase 1's COMMIT and dies there with 2D000 instead.",
        [("  perform pgpm._refuse_oid_bound_dependants(p_parent, false);\n", "", 1)],
    ),
    "oid_bound_dependants_preflight_only": (
        "bench/transmute_oid_bound_dependants.sh",
        "Issue #779, asked once: the preflight refuses, but a view created between it and the cutover's "
        "ACCESS EXCLUSIVE (phases 1 and 2 let go of the table) follows the rename into the monolith. One "
        "site, the cutover's re-check. tests/205 part B, whose event trigger creates the view in that window, "
        "catches it.",
        [("  perform pgpm._refuse_oid_bound_dependants(p_parent, false);   -- #779, again under the lock\n", "", 1)],
    ),
    "oid_bound_dependants_policy_on_staging": (
        "bench/transmute_oid_bound_dependants.sh",
        "Issue #779's overreach, by the route that is left (#897): the policy loop executes onto the staging "
        "parent before the renames again, so the cutover's re-check meets the copy of the table's own "
        "self-referencing policy, bound to the original oid, and refuses the table under the lock, after phases "
        "1 and 2 committed the bound, though the preflight let it through. Replaces "
        "oid_bound_dependants_no_staging_exemption: #897 replays the policies after the renames, so the copy no "
        "longer exists when the re-check asks and the exemption it removed is gone. tests/205 part A's "
        "conversion of dv205 (policy dv205_self) catches it.",
        TRANSMUTE_POLICIES_ON_STAGING_EDITS,
    ),
    "untransmute_oid_bound_dependants_unrefused": (
        "bench/transmute_oid_bound_dependants.sh",
        "Issue #779's symmetric case put back: untransmute asks nothing about objects over the parent, so its "
        "DROP fails raw ('cannot drop table ... because other objects depend on it') on a view, and drops a "
        "rule on the parent along with it without a word. Both sites, the unlocked ask and the one under the "
        "lock. tests/205 part C catches it.",
        [("  perform pgpm._refuse_oid_bound_dependants(p_parent, true);", "  null;", 2)],
    ),
    # #831 and #815 (F1-02, F10-06): the dependants _refuse_oid_bound_dependants asks about beyond the pg_class
    # row of the table itself. Two guards: the transmute direction (tests/224) and untransmute's (tests/223).
    "oid_bound_dependants_row_type_unasked": (
        "bench/transmute_row_type_dependants.sh",
        "Issue #815's F1-02 put back, the pre-fix shape: the helper asks pg_depend about the table's pg_class "
        "row only, never its row type. A function taking the table's row type, a column of that type and a "
        "domain over it follow the cutover's rename into the monolith: f(t) stops taking the table's rows "
        "(42883), the column rejects them (42804), and the monolith can never be dropped. untransmute meets a "
        "function over the parent's row type raw at its DROP (#831). One site, the row-type arm of the "
        "helper's targets. tests/224 catches it (and tests/223 part A).",
        [("     where x.typ <> 0\n  )", "     where x.typ <> 0 and false\n  )", 1)],
    ),
    "oid_bound_dependants_array_type_unasked": (
        "bench/transmute_row_type_dependants.sh",
        "Issue #815's F1-02, half fixed: the helper asks about the table's row type but not that type's array "
        "type, so a function taking an array of the table's rows (or a column of that array type) still "
        "follows the rename into the monolith. One site, the array type in the helper's targets. tests/224's "
        "pinned refusal, which names arr224(rt224[]), catches it.",
        [("cross join lateral (values (ty.oid), (ty.typarray)) x(typ)",
          "cross join lateral (values (ty.oid)) x(typ)", 1)],
    ),
    "untransmute_dependants_parent_only": (
        "bench/untransmute_drop_dependants.sh",
        "Issue #815's F10-06 put back: untransmute asks about the parent alone, though its DROP cascades to "
        "every partition but the monolith, so a view over an empty forward partition (or a DEFAULT), or a "
        "function typed by one's row type, makes the reverse die raw with 2BP01 after the detach. One site, "
        "the partitions in the helper's relation set. tests/223 part B catches it.",
        [("     where p_untransmute and t.relid <> p_rel and t.relid is distinct from v_mon\n",
          "     where false and p_untransmute and t.relid <> p_rel and t.relid is distinct from v_mon\n", 1)],
    ),
    "untransmute_dependants_monolith_counted": (
        "bench/untransmute_drop_dependants.sh",
        "Issues #831 and F10-06, overreach: untransmute counts the MONOLITH among the partitions its DROP "
        "takes, so a view over the monolith or a function typed by its row type is refused, though the "
        "monolith is detached and handed back as the table and both go on working against it. One site, the "
        "monolith's exemption. tests/223 parts A and B (mono223, ut223_mono_v, fv223_mono_v) catch it.",
        [(" and t.relid is distinct from v_mon\n", "\n", 1)],
    ),
    "untransmute_dependants_partition_rules_named": (
        "bench/untransmute_drop_dependants.sh",
        "Issue F10-06, overreach: a rule ON one of the partitions untransmute drops is refused, though it goes "
        "with its partition, without an error (only a rule on the parent is refused, because writes through "
        "the table stop firing it). One site, the rule exemption. tests/223 part B (fv223_fwd_r) catches it.",
        [("where r.oid = d.objid\n                         and (r.ev_class = p_rel or r.ev_class not in (select oid from rel)))",
          "where r.oid = d.objid)", 1)],
    ),
    "regrain_shape_drift_ignored": (
        "bench/regrain_survives_parent_ddl.sh",
        "Issue #785, the pre-fix shape: regrain_step never compares its copies' columns with the parent's. "
        "An ADD COLUMN on the parent mid-regrain fails every later copy and reconcile ('column ... does not "
        "exist'), a DROP COLUMN or a TYPE change fails the swap's ATTACH, and the run never moves again. One "
        "site, the restart branch, switched off. tests/211 parts A and B catch it.",
        [("  if v_drift <> '' or v_capture_drift is not null then\n"
          "    for r in execute format(\n",
          "  if false then\n"
          "    for r in execute format(\n", 1)],
    ),
    "regrain_shape_restart_keeps_cursor": (
        "bench/regrain_survives_parent_ddl.sh",
        "Issue #785, the plausible-but-wrong fix: the drifted copies are discarded but regrain_cursor is left "
        "where it was. The sub-ranges behind it then have no copy and are not aged, so the swap refuses every "
        "tick and the run is wedged again. One site, the cursor reset in the restart branch. tests/211 parts A "
        "and B catch it.",
        [("    update pgpm.config set regrain_cursor = v_lo, regrain_source_mark = pgpm._regrain_source_mark(v_child)\n"
          "     where parent_table = p_parent;\n"
          "    insert into pgpm.log (parent_table, action, lo, hi, rows, method)\n"
          "      values (p_parent, 'regrain_restart', v_lo, v_hi, v_made,\n",
          "    update pgpm.config set regrain_source_mark = pgpm._regrain_source_mark(v_child)\n"
          "     where parent_table = p_parent;\n"
          "    insert into pgpm.log (parent_table, action, lo, hi, rows, method)\n"
          "      values (p_parent, 'regrain_restart', v_lo, v_hi, v_made,\n", 1)],
    ),
    "archive_chunk_bare_text": (
        "bench/ts_text_archive_chunk_transmute_min.sh",
        "Pre-#788 _next_archive_chunk: the window's newest value, the next distinct value past it and the "
        "tie extension are read with a bare ::text, in the session's DateStyle and TimeZone, and parsed back "
        "by _col_to_native (and, as a literal, by the next-distinct probe) in the same session. Under SQL "
        "DateStyle and Europe/Dublin the summer text reads 'IST', which the default timezone_abbreviations "
        "parse as Israel (+02), so every value reads an hour early, the stop falls below lo and no chunk is "
        "returned: the aged child is never archived and so never retired, with nothing logged. The one "
        "render the three reads share is reverted to the old expression; tests/213's SQL/Dublin pick, its "
        "two ledger chunks and the retire catch it.",
        [("""  v_cval_q := case when cfg.control_kind = 'time' and not pgpm._control_naive(p_parent, cfg.control_column)
                   then format('pgpm._ts_text(t.%I)', cfg.control_column)
                   else format('t.%I::text', cfg.control_column) end;
""", """  v_cval_q := format('t.%I::text', cfg.control_column);
""", 1)],
    ),
    "transmute_min_bare_text": (
        "bench/ts_text_archive_chunk_transmute_min.sh",
        "Pre-#788 _transmute: min(control) is read with a bare t.col::text, in the session's DateStyle and "
        "TimeZone, and parsed back with ::timestamptz in the same session. Under SQL DateStyle and "
        "Asia/Kolkata the text reads 'IST', which parses as Israel (+02), so the minimum reads 3.5 hours "
        "late, an oldest row in the last hour of March floors the monolith's lo into April, phase 2's "
        "VALIDATE fails on that row and the NOT VALID bound is left behind. The read is reverted to the "
        "old expression; tests/213's SQL/Kolkata conversion, its lo and its bound catch it.",
        [("""                 case when p_control_kind = 'time' and v_typname not in ('timestamp', 'date')
                      then format('pgpm._ts_text(t.%I)', p_control) else format('t.%I::text', p_control) end,
""", """                 format('t.%I::text', p_control),
""", 1)],
    ),
    "obtain_no_lock_budget": (
        "bench/obtain_lock_budget.sh",
        "Pre-#786 obtain: nothing bounds a call by the lock table, only by config.obtain, which set_obtain "
        "bounds only by sign. obtain is a function, so every partition one call creates holds its locks to "
        "the transaction's end, and a lookahead past ~2000 missing cells on a stock server dies with 53200 "
        "`out of shared memory` on every tick, rolling back every cell it built: maintain_obtain logs "
        "skip_obtain and the grid never advances. One site: the budget's stop, made unreachable, so the "
        "measurement still runs and the walk goes on exactly as the old function's did. tests/212's tick "
        "(no skip_obtain, a contiguous run of cells built) and its direct call (no more than half the table "
        "held) are what catch it.",
        [("    exit when v_made >= 2\n", "    exit when false and v_made >= 2\n", 1)],
    ),
    # Issue #782, one mutation per site that carries the replica identity, so each is proven caught on its own.
    "cutover_replica_identity_parent_dropped": (
        "bench/cutover_replica_identity.sh",
        "Issue #782 put back at the cutover: 9d reads the table's replica identity as the default, so the "
        "parent gets none of FULL, NOTHING or USING INDEX, and every partition minted from it takes the "
        "parent's default. A keyless FULL table in a publication fails every UPDATE and DELETE routed to a "
        "forward partition with 55000. tests/207's parent and partition identity assertions in every part, "
        "and its UPDATE and DELETE in part A, catch it.",
        [("  select c.relreplident into v_replident from pg_class c where c.oid = p_parent;\n",
          "  v_replident := 'd';\n", 1)],
    ),
    "create_partition_replica_identity_dropped": (
        "bench/cutover_replica_identity.sh",
        "Issue #782 put back where obtain and extend_to mint: _create_partition gives the new partition "
        "nothing of the parent's replica identity, which PostgreSQL does not give it either, so the parent "
        "is right and every forward partition has the default. tests/207's forward-partition assertions in "
        "parts A to D catch it.",
        [("  perform pgpm._replica_identity_like_parent(format('%I.%I', p_nsp, p_rel)::regclass,\n"
          "                                             format('%I.%I', p_nsp, p_name)::regclass);   -- #782\n",
          "", 1)],
    ),
    "regrain_swap_replica_identity_dropped": (
        "bench/cutover_replica_identity.sh",
        "Issue #782 put back where a regrain's swap attaches its fine children: a LIKE copy has the default "
        "identity whatever the parent's, and nothing gives it the parent's, so a FULL table's regrained range "
        "publishes its key. tests/207's part F catches it.",
        [("    perform pgpm._replica_identity_like_parent(p_parent, v_copy);\n", "", 1)],
    ),
    # Issue #978: a parent whose USING INDEX identity index was dropped.
    "replica_identity_index_dropped_raises": (
        "bench/replica_identity_index_dropped.sh",
        "Issue #978 put back: _replica_identity_like_parent reads a parent with relreplident 'i' and no "
        "identity index (DROP INDEX on the identity index, which PostgreSQL allows and treats as NOTHING) as "
        "a child missing its index and raises, so every mint fails: obtain raises, maintain_obtain logs "
        "skip_obtain on every tick, extend_to raises, and writes past the grid are refused once it runs out. "
        "tests/275's rx assertions catch it.",
        [(_RI_DROPPED_BLOCK, "", 1)],
    ),
    "replica_identity_index_dropped_default": (
        "bench/replica_identity_index_dropped.sh",
        "Issue #978, the plausible-but-wrong fix: the mint proceeds but leaves the new partition at the "
        "default identity, which publishes the key the parent no longer publishes (the parent is NOTHING), "
        "and logs nothing, so a partition minted while the index is gone is not findable afterwards. "
        "tests/275's rx identity and warning assertions catch it.",
        [(_RI_DROPPED_BLOCK,
          "  if v_want = 'i' and not exists (select 1 from pg_index where indrelid = p_parent and indisreplident) then\n"
          "    return;\n"
          "  end if;\n", 1)],
    ),
    # Issue #789, one mutation per site.
    "cutover_key_anonymous": (
        "bench/cutover_key_name.sh",
        "Issue #789 put back: step 8 leaves the monolith's key under its own name and declares the parent's "
        "key anonymously, so it comes back auto-named (t_pkey1, or <t>_pkey for a named key) and every "
        "INSERT ... ON CONFLICT ON CONSTRAINT <the key's name> fails with 42704. Both branches, the primary "
        "key and the reused unique constraint. tests/208's name, upsert and adoption assertions in parts A "
        "to D catch it.",
        [("    execute format('alter table %s rename constraint %I to %I', v_monreg::text, v_key_name, 'pgpm_key_' || v_key_idx);\n",
          "    null;\n", 1),
         ("add constraint %I primary key (%s)%s', v_parent::text, v_key_name,",
          "add primary key (%s)%s', v_parent::text,", 1),
         ("add constraint %I unique (%s)%s', v_parent::text, v_key_name,",
          "add unique (%s)%s', v_parent::text,", 1)],
    ),
    "untransmute_key_name_kept": (
        "bench/cutover_key_name.sh",
        "Issue #789's reverse left out: untransmute drops the parent, which carried the key's name, and leaves "
        "the restored table's key under the pgpm_key_<index oid> name step 8 gave the monolith's copy, so "
        "the upsert naming the key fails with 42704 after the reverse instead. tests/208's part E catches it.",
        [("    execute format('alter table %s rename constraint %I to %I', v_monreg::text, v_key_mon, v_key_name);\n",
          "    null;\n", 1)],
    ),
    "transmute_key_clash_unchecked": (
        "bench/cutover_key_name.sh",
        "Issue #789's refusal left out: nothing asks whether pgpm_key_<index oid>, the name step 8 renames the "
        "monolith's key to, is free, so a relation holding it fails the rename raw inside the cutover after "
        "phases 1 and 2 committed the bound and the claim. tests/208's pinned refusal in part F catches it.",
        [("  if v_key_clash is not null then\n", "  if false and v_key_clash is not null then\n", 1)],
    ),
    "cutover_secondary_unique_as_index": (
        "bench/cutover_secondary_unique_constraint.sh",
        "Issue #828 put back: step 9b carries an index that backs a secondary UNIQUE constraint the way it "
        "carries a bare one, as a partitioned unique index <name>_pgpm, so the parent has no constraint by "
        "the name (ON CONFLICT ON CONSTRAINT <name> fails with 42704) and a DEFERRABLE one is immediate on "
        "every forward partition. One site, the constraint branch switched off, which leaves exactly the "
        "pre-fix loop; tests/225's name, upsert, deferral and definition assertions catch it.",
        [("      if found then\n        if right(v_ucon_def, length(v_ucon_sfx)) is distinct from v_ucon_sfx then\n",
          "      if false then\n        if right(v_ucon_def, length(v_ucon_sfx)) is distinct from v_ucon_sfx then\n", 1)],
    ),
    "untransmute_unique_names_one": (
        "bench/cutover_secondary_unique_constraint.sh",
        "Issue #828's reverse cut short: untransmute hands back only the first pgpm_key_<index oid> name, as "
        "it did when the key was the only constraint step 8 renamed, so a restored table keeps a unique "
        "constraint under pgpm_key_<index oid> and every statement naming it fails with 42704. tests/225's "
        "part D catches it.",
        [("  for v_i in 1 .. coalesce(array_length(v_key_mons, 1), 0) loop\n",
          "  for v_i in 1 .. least(coalesce(array_length(v_key_mons, 1), 0), 1) loop\n", 1)],
    ),
    "transmute_unique_key_clash_unchecked": (
        "bench/cutover_secondary_unique_constraint.sh",
        "Issue #828's refusal left out: the up-front check asks whether pgpm_key_<index oid> is free for the "
        "key alone, not for each secondary unique constraint 9b renames the same way, so a relation holding "
        "that name fails the rename raw inside the cutover after phases 1 and 2 committed the bound and the "
        "claim. tests/225's pinned refusal in part E catches it.",
        [("                  or exists (select 1 from pg_constraint c\n"
          "                              where c.conrelid = p_parent and c.contype = 'u' and c.conindid = i.indexrelid))) k\n",
          "                  or false)) k\n", 1)],
    ),
    "cutover_tablespace_dropped": (
        "bench/cutover_tablespace.sh",
        "Issue #829 put back: the cutover creates the parent in the database default whatever tablespace the "
        "table is in, so every partition obtain, extend_to and a regrain mint from it lands there too. One "
        "site, the SET TABLESPACE switched off; tests/226's part A catches it, while part B's default-"
        "tablespace table still passes.",
        [("  if v_spc is not null then\n    execute format('alter table %s set tablespace %I', v_parent::text, v_spc);\n",
          "  if false then\n    execute format('alter table %s set tablespace %I', v_parent::text, v_spc);\n", 1)],
    ),
    "transmute_tablespace_unchecked": (
        "bench/cutover_tablespace.sh",
        "Issue #829's refusal left out: nothing asks up front whether the caller can create a relation in the "
        "table's tablespace, so one who cannot fails with a raw 42501 inside the cutover, after phases 1 and "
        "2 committed the bound and the claim. tests/226's pinned refusal in part C catches it.",
        [("  if v_spc is not null and not has_tablespace_privilege(v_spc, 'CREATE') then\n",
          "  if false then\n", 1)],
    ),
    "unbuilt_cell_type_holder_unnamed": (
        "bench/unbuilt_cell_type_holder.sh",
        "Pre-#790 _log_unbuilt_cell: the holder is resolved through to_regclass alone, so when a type (an "
        "enum, a domain, a range type) holds an unbuilt cell's name the holder clause is null and "
        "fail_obtain_name's method stops at 'is held by ', naming nothing. One site, the type branch of the "
        "holder clause switched off, which leaves exactly the pre-fix expression; tests/214's enum, domain "
        "and range-type methods (obtain's and extend_to's) catch it.",
        [("                   case when v_held is null\n"
          "                        then coalesce(pgpm._type_squatter(p_nsp, v_name)",
          "                   case when false\n"
          "                        then coalesce(pgpm._type_squatter(p_nsp, v_name)", 1)],
    ),
    "orphan_type_guard_id_label_19_digits": (
        "bench/orphan_type_guard_id_labels.sh",
        "Pre-#794 transmute: the pg_type half of the orphan-child guard (#707) matches an id suffix with "
        "'^[0-9]{19}$', the label before #582, instead of asking _is_fine_child_label as its pg_class half "
        "does (#726). A type under a 20-digit, fractional or short negative cell's name passes, the "
        "conversion completes, and obtain leaves that cell unbuilt. One site, the pg_type query's label "
        "test; tests/215's three refusals catch it, while its 19-digit control still passes.",
        [("       and pgpm._is_fine_child_label(p_control_kind, substr(t.typname, length(v_rel) + 3))\n",
          "       and case when p_control_kind = 'id'\n"
          "                then substr(t.typname, length(v_rel) + 3) ~ '^[0-9]{19}$'\n"
          "                else substr(t.typname, length(v_rel) + 3) ~ '^[0-9]{4}(_[0-9]+)*$'\n"
          "           end\n", 1)],
    ),
    # Issue #825, one mutation per site that asks pgpm._refuse_filtered_reads.
    "transmute_reads_under_caller_rls": (
        "bench/transmute_reads_caller_rls.sh",
        "Pre-#825 transmute: nothing asks whether row-level security filters the caller's reads, so a "
        "non-superuser owner without BYPASSRLS of a FORCE'd table sizes the monolith's bound from the rows "
        "its policies admit, phase 1 commits it, and phase 2's VALIDATE dies with a raw 23514, leaving the "
        "bound rejecting every write below it. tests/218's pinned refusal and its no-claim, no-bound and "
        "backfill assertions in part A catch it.",
        [("  perform pgpm._refuse_filtered_reads(p_parent, 'transmute',\n"
          "    'the monolith''s bound would be sized from those rows alone and reject the others');\n",
          "", 1)],
    ),
    "hypertable_preflight_reads_under_caller_rls": (
        "bench/hypertable_reads_caller_rls.sh",
        "Pre-#825 preflight: from_hypertable and from_hypertable_copy copy the hypertable as an owner whose "
        "reads a FORCE'd policy filters, so the copy holds only the rows it admits and the swap drops the "
        "rest. tests/timescale/db/37's pinned refusals in part A catch it (the preflight's own, and the copy "
        "dying at its first COMMIT inside the function context instead of refusing).",
        [("  perform pgpm._refuse_filtered_reads(p_hypertable, 'migrate hypertable',\n"
          "    'the copy would hold only those rows, the conservation check would read the source the same way "
          "and agree, and the swap would drop the others with the hypertable');\n", "", 1)],
    ),
    "hypertable_cutover_reads_under_caller_rls": (
        "bench/hypertable_reads_caller_rls.sh",
        "Pre-#825 cutover: its catch-up and its conservation check read the source as an owner whose reads a "
        "FORCE'd policy filters, and nothing refuses that caller first. tests/timescale/db/37's pinned "
        "refusal in part B catches it (the cutover dies at its first COMMIT inside the function context).",
        [("  perform pgpm._refuse_filtered_reads(p_hypertable, 'cut over hypertable',\n"
          "    'the catch-up and the conservation check would read only those rows, and the swap would drop "
          "the others with the hypertable');\n", "", 1)],
    ),
    # Issue #873, the reads-under-RLS lever: one mutation per site that asks pgpm._refuse_filtered_reads,
    # each deleting that one call (and its comment) so the read behind it runs as the filtered caller again.
    "rls_frontier_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 _frontier_native: the write frontier (max of the control column) is read through the parent "
        "under the caller's row-level security, so for an owner whose FORCE'd policy hides the largest id, "
        "obtain, extend_to, progress, retention's id horizon and maintain's regrain dispatch all run on the "
        "visible maximum. tests/241 part C1 catches it (obtain and the rest no longer refuse; status() "
        "answers; maintain_obtain and maintain log no frontier refusal).",
        [("  -- #873: the read below is the caller's, so under row-level security that filters it the frontier would be\n"
          "  -- the largest VISIBLE value. Asked here, at the one read every caller shares (obtain, extend_to, progress,\n"
          "  -- retention's horizon on an id grid, maintain's regrain dispatch), rather than at each of them.\n"
          "  perform pgpm._refuse_filtered_reads(p_parent, 'read the write frontier of',\n"
          "    'the frontier, the largest value of the control column, would be the largest one those rows hold, and "
          "obtain, retention and regrain would place the grid by it');\n", "", 1)],
    ),
    "rls_regrain_source_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 regrain_step (#873 bullet 1, Tier 1): the copy reads the source partition directly, under the "
        "monolith's own FORCE'd policy, and the swap drops the source whole, so every row the policy hides from "
        "a non-BYPASSRLS owner is lost. tests/242 part A catches it (the parent set NO FORCE, so no other check "
        "stands in): the regrain runs, and 8 hidden rows of 60 are gone by identity.",
        [("  -- #873: the copy, the reconcile and the avg-width probe below read the SOURCE directly, under its own\n"
          "  -- row-level security (transmute leaves the monolith its ENABLE / FORCE and policies), and the swap drops it\n"
          "  -- whole. Asked of v_child, the relation read, before anything below writes; the parent's read is the\n"
          "  -- frontier's, asked in _frontier_native.\n"
          "  perform pgpm._refuse_filtered_reads(v_child, 'regrain',\n"
          "    'the copy would hold only those rows, and the swap would drop the others with the source');\n", "", 1)],
    ),
    "rls_untransmute_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 untransmute: its outside-rows gate reads through the parent under the caller's row-level "
        "security, so a hidden row in a forward partition is invisible to it and the reverse drops that "
        "partition with the parent. tests/242 part C catches it: row 45 is gone and ut242 is a plain table.",
        [("  -- #873: the gate reads through the parent, under the caller's row-level security, and a row it cannot see\n"
          "  -- outside the monolith is one the DROP below takes with the parent. Asked AFTER the gate's first read, under\n"
          "  -- the ACCESS SHARE that read took and holds to the end: ENABLE, FORCE and CREATE POLICY all need ACCESS\n"
          "  -- EXCLUSIVE, so the answer cannot change between here and the reads it vouches for (the gate again under\n"
          "  -- the lock, the identity maxima).\n"
          "  perform pgpm._refuse_filtered_reads(p_parent, 'untransmute',\n"
          "    'the check that every row still lives in the monolith would pass with rows outside it, and the reverse "
          "would drop them with the parent');\n", "", 1)],
    ),
    "rls_archive_step_parent_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 _archive_step, the parent's half: an archive strategy that reads the chunk through the parent "
        "(pgpm_archive's transports do) runs as a caller the parent's policy filters, and its ledger row opens "
        "retire()'s drop gate over the rows it never saw. tests/241 part C4 catches it: the strategy counts "
        "the visible rows into a ledger row.",
        [("      perform pgpm._refuse_filtered_reads(p_parent, 'archive a partition of',\n"
          "        'an archive strategy reading the partition through it would archive only those rows, and retention "
          "would drop the others with the partition');\n", "", 1)],
    ),
    "rls_archive_step_child_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 _archive_step, the partition's half: the chunk is sized from, and a strategy such as "
        "_archive_noop reads, the monolith under its own FORCE'd policy. tests/241 part C5 catches it (the parent "
        "NO FORCE): a ledger row records the visible rows as the partition's.",
        [("      perform pgpm._refuse_filtered_reads(v_now, 'archive',\n"
          "        'the chunk would be sized and archived from those rows alone, and retention would drop the others "
          "with the partition');\n", "", 1)],
    ),
    "rls_check_uuidv7_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 check_uuidv7 (#873 bullet 2): it samples, and finds the maximum, under the caller's "
        "row-level security, so a hidden future-dated row never reaches newest_in_future. tests/241 part C6 "
        "catches it.",
        [("  -- #873: the sample and the maximum are the caller's reads; under row-level security that filters them\n"
          "  -- they would describe the visible rows as the column's.\n"
          "  perform pgpm._refuse_filtered_reads(p_table, 'sample',\n"
          "    'check_uuidv7 would report its fraction and the column''s maximum from those rows alone');\n", "", 1)],
    ),
    "rls_check_text_time_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 check_text_time (#873 bullet 2), as check_uuidv7's. tests/241 part C7 catches it.",
        [("  perform pgpm._refuse_filtered_reads(p_table, 'sample',\n"
          "    'check_text_time would report its fraction and the column''s maximum from those rows alone');\n", "", 1)],
    ),
    "rls_check_time_monotonic_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 check_time_monotonic: it samples under the caller's row-level security, so a hidden "
        "out-of-order row never lowers the fraction. tests/241 part C8 catches it.",
        [("  perform pgpm._refuse_filtered_reads(p_table, 'sample',\n"
          "    'check_time_monotonic would report its fraction from those rows alone');\n", "", 1)],
    ),
    "rls_crossing_keys_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 _crossing_keys: retire() reads the rows referencing a retiring partition from the referencing "
        "table as the caller, so a row its FORCE'd policy hides is not deleted with the declared ON DELETE and "
        "the detach is refused by it. tests/241 part C9 catches it: retire no longer refuses, and the visible "
        "crossing is deleted.",
        [("    -- #873: read from the referencing table as the caller, under ITS row-level security.\n"
          "    perform pgpm._refuse_filtered_reads(r.referencing, 'read the rows referencing a retiring partition from',\n"
          "      'retention would honour the declared ON DELETE for those rows alone, and the detach would then be "
          "refused by the others');\n", "", 1)],
    ),
    "rls_fk_orphans_referencing_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 incoming_fk_orphans, the referencing side: an orphan the referencing table's policy hides is "
        "not counted. tests/241 part C10 (ra241) catches it.",
        [("    perform pgpm._refuse_filtered_reads(c.conrelid::regclass, 'count the orphans in',\n"
          "      'incoming_fk_orphans would count those rows alone');\n", "", 1)],
    ),
    "rls_fk_orphans_parent_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 incoming_fk_orphans, the parent side: a parent row the policy hides makes the rows referencing "
        "it count as orphans. tests/241 part C10 (ob241) catches it.",
        [("    perform pgpm._refuse_filtered_reads(c.confrelid::regclass, 'count the orphans against',\n"
          "      'a referencing row whose key those rows do not hold would be counted as an orphan');\n", "", 1)],
    ),
    "rls_to_s3_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 archive.to_s3: the export and its conservation check read the partition under the caller's "
        "row-level security and agree on an object of the visible rows. tests/archive/db/38 catches it.",
        [("  perform pgpm._refuse_filtered_reads(archive._resolve_child(p_parent, p_child, 'archive.to_s3'), 'export',\n"
          "    'the object would hold only those rows');\n",
          "  perform archive._resolve_child(p_parent, p_child, 'archive.to_s3');\n", 1)],
    ),
    "rls_to_s3_parquet_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 archive.to_s3_parquet, as archive.to_s3's. tests/archive/db/38 catches it.",
        [("  perform pgpm._refuse_filtered_reads(v_child, 'export', 'the object would hold only those rows');   -- #873\n",
          "", 1)],
    ),
    "rls_archive_ndjson_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 pgpm.archive_to_s3_ndjson: the chunk is read through the parent as the caller, and the "
        "object holds the rows its policy admits. tests/archive/db/38 catches it (called directly, where "
        "_archive_step's own check is not in front of it).",
        [("  -- #873: the chunk is read through the parent as the caller, and its ledger row opens retire()'s drop gate\n"
          "  perform pgpm._refuse_filtered_reads(p_parent, 'archive a chunk of',\n"
          "    'the object would hold only those rows, and retention would drop the others once it is recorded');\n", "", 1)],
    ),
    "rls_archive_parquet_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 pgpm.archive_to_s3_parquet, as archive_to_s3_ndjson's. tests/archive/db/38 catches it.",
        [("  -- #873: as archive_to_s3_ndjson's\n"
          "  perform pgpm._refuse_filtered_reads(p_parent, 'archive a chunk of',\n"
          "    'the object would hold only those rows, and retention would drop the others once it is recorded');\n", "", 1)],
    ),
    "rls_cutover_unchecked_under_lock": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 from_hypertable_cutover (#873 bullet 3, Tier 1): the caller's row-level security is asked up "
        "front only, so FORCE and a policy committed while the cutover prepares filter its append-only "
        "catch-up and its conservation check alike, they agree, and the swap drops the hidden row with the "
        "hypertable. PART H catches it: row 11 is gone, and the refusal that follows is transmute's, after "
        "the swap.",
        [("  perform pgpm._refuse_filtered_reads(p_hypertable, 'swap in the copy of hypertable',\n"
          "    'the catch-up and the conservation check, read under this lock, would see only those rows and agree "
          "with each other (row-level security came on after the cutover''s first check), and the swap would drop "
          "the others with the hypertable');\n", "", 1)],
    ),
    "rls_drain_appends_step_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 from_hypertable_drain_appends_step: the tail is read as the caller, and a tail its policy "
        "hides reads as nothing to drain. tests/timescale/db/46 catches it.",
        [("  -- #873: the tail is read from the source as this caller\n"
          "  perform pgpm._refuse_filtered_reads(p_hypertable, 'drain appends from hypertable',\n"
          "    'the copy would be brought up to date with those rows alone');\n", "", 1)],
    ),
    "rls_drain_appends_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 from_hypertable_drain_appends: its own residual check reads the source as the caller, so a "
        "wholly hidden tail ends the drain before its step is called. tests/timescale/db/46 catches it.",
        [("  -- #873: its own residual check reads the source too, and a tail its policies hide entirely reads as none\n"
          "  perform pgpm._refuse_filtered_reads(p_hypertable, 'drain appends from hypertable',\n"
          "    'the copy would be brought up to date with those rows alone');\n", "", 1)],
    ),
    "rls_drain_delta_step_unchecked": (
        "bench/reads_under_caller_rls.sh",
        "Pre-#873 from_hypertable_drain_delta_step: the batch's changes leave the delta and their rows are "
        "re-read from the source as the caller, so a hidden row's change is consumed and never applied. "
        "tests/timescale/db/46 catches it: the delta is emptied and row 2 leaves the copy.",
        [("  -- #873: the batch's keys leave the delta below and their rows are re-read from the source as this caller,\n"
          "  -- so under row-level security that filters it a hidden row's change would be consumed and never applied.\n"
          "  perform pgpm._refuse_filtered_reads(p_hypertable, 'drain changes from hypertable',\n"
          "    'the copy would be brought up to date with those rows alone');\n", "", 1)],
    ),
    "regrain_value_drift_ignored": (
        "bench/regrain_drift_values.sh",
        "Pre-#824 regrain_step: the source mark the prepare tick recorded is never compared with the source, "
        "so DDL that changes the source's values under an unchanged column signature (a column dropped and "
        "added back under its old name and type, ALTER COLUMN ... TYPE <same type> USING) is not drift, no "
        "restart happens, and the swap attaches the copies made before it, serving the dropped column's "
        "values or the pre-rewrite ones. One site, the source-drift term of the restart condition; "
        "tests/216 parts A and B catch it.",
        [("                            then pgpm._regrain_source_drift(v_child, cfg.regrain_source_mark) end);\n",
          "                            then null end);\n", 1)],
    ),
    "regrain_check_drift_ignored": (
        "bench/regrain_drift_values.sh",
        "Pre-#817 _regrain_shape_drift: the parent's CHECK constraints are not compared with the copies', "
        "so a CHECK added to the parent mid-regrain is not drift and every swap tick fails ATTACH with "
        "'child table is missing constraint' (skip_regrain forever, capture left on the source), and a "
        "CHECK the parent dropped stays on the fine children. One site, the CHECK half of the comparison; "
        "tests/216 part C catches it.",
        [("     where (k.conrelid = p_parent or k.conrelid = any(p_copies)) and k.contype = 'c'\n",
          "     where (k.conrelid = p_parent or k.conrelid = any(p_copies)) and k.contype = 'c' and false\n", 1)],
    ),
    "regrain_fk_drift_ignored": (
        "bench/regrain_fk_drift_swap_scan.sh",
        "Pre-#898 _regrain_shape_drift: the parent's outgoing foreign keys are not compared with the copies', "
        "so a key added to the parent mid-regrain is not drift, the copies made before it reach the swap "
        "without it, and ATTACH PARTITION validates it by scanning each of them under the swap's ACCESS "
        "EXCLUSIVE on the parent. One site, the foreign-key half of the comparison; tests/251 parts A, B "
        "and C catch it too.",
        [("     where k.contype = 'f' and k.conparentid = 0\n",
          "     where k.contype = 'f' and k.conparentid = 0 and false\n", 1)],
    ),
    "regrain_null_mark_adopted": (
        "bench/regrain_null_source_mark.sh",
        "Pre-#878 _regrain_source_drift: a null source mark (a run in flight across the upgrade that added "
        "config.regrain_source_mark) answers null, 'no drift', so regrain_step's no-drift branch records the "
        "source as it is now as the mark, over copies made before a rewrite that fired no row trigger, and the "
        "swap attaches them with the pre-rewrite values. One site, the filter that turns a null mark into no "
        "answer; tests/243 parts A and B catch it. The upgrade block is untouched, and does not run in that "
        "file, so this proves regrain_step's lever on its own.",
        [("   where m.now is not null;\n", "   where p_mark is not null and m.now is not null;\n", 1)],
    ),
    "upgrade_regrain_mark_adopted": (
        "bench/upgrade_in_place.sh",
        "The #878 upgrade block records the source as it is now as the mark of every in-flight run, copies "
        "or not: its copy discard is gone, so a run with copies takes the no-copies branch. That is the "
        "tempting fix (the mark exists after the upgrade, so regrain_step compares against something) and "
        "the defect exactly: a rewrite made before the upgrade, which the origin could not see, is blessed, "
        "regrain_step's null-mark lever never fires because the mark is no longer null, and the swap attaches "
        "the pre-rewrite copy. bench/upgrade_in_place.sh's in-flight stage (assertion 8) must FAIL on the "
        "copy still existing after the upgrade, on the missing regrain_restart, and on the values swapped in.",
        [("      perform pgpm._regrain_drop_copy(v_parent, v_nsp, c.child_name);   -- #631: by recorded oid\n"
          "      v_made := v_made + 1;\n", "", 1)],
    ),
    "upgrade_regrain_mark_block_noop": (
        "bench/upgrade_in_place.sh",
        "The #878 upgrade block visits no run: the pre-#878 upgrade, which only adds the column and leaves a "
        "run in flight with copies and a null mark. regrain_step's own lever still restarts that run at its "
        "next tick, so the values the stage finally reads are right; what must FAIL is the stage's state "
        "right after the upgrade, before any tick (the copy by oid, the regrain_restart row, the mark), "
        "which is what makes this stage the block's proof and not regrain_step's.",
        [("  for v_parent in select parent_table from pgpm.config\n"
          "                   where regrain_cursor is not null and regrain_source_mark is null loop\n",
          "  for v_parent in select parent_table from pgpm.config where false loop\n", 1)],
    ),
    "regrain_capture_drift_ignored": (
        "bench/regrain_capture_follows_key.sh",
        "Pre-#817 regrain_step: the capture apparatus is never compared with the parent's key, so after a "
        "reused-key column is renamed every write into the regraining range fails 42703 and every reconcile "
        "of a change captured before the rename fails ('column d.k does not exist'), and after one is "
        "widened every write of a key the old type cannot hold fails 22003, each until the swap. One site, "
        "the capture-drift probe; tests/217 parts A and B catch it.",
        [("  v_capture_drift := pgpm._regrain_capture_drift(p_parent, v_keyidx);\n",
          "  v_capture_drift := null;\n", 1)],
    ),
    "regrain_restart_keeps_capture": (
        "bench/regrain_capture_follows_key.sh",
        "#817, the plausible-but-wrong fix: the capture drift is seen and the run restarts, but the restart "
        "keeps the capture apparatus minted at prepare, as #785's restart did. The writes the old trigger "
        "cannot record keep failing, and the drift is seen again on every tick, so the run restarts forever "
        "and never swaps. One site, the re-mint in the restart branch; tests/217 parts A and B catch it.",
        [("    if v_capture_drift is not null then\n"
          "      perform pgpm._regrain_capture_install(p_parent, v_child_name);\n"
          "    end if;\n", "", 1)],
    ),
    # Issue #892: regrain's change capture counts only while its trigger is ENABLE ALWAYS.
    "regrain_capture_unarmed_ignored": (
        "bench/regrain_capture_enabled_always.sh",
        "Pre-#892 regrain_step: a resuming tick never asks whether the source's capture trigger is ENABLE "
        "ALWAYS, only (through _regrain_capture_active) that it exists, so a trigger an owner disabled with "
        "ALTER TABLE <partition> DISABLE TRIGGER USER, or left origin-only by the matching ENABLE TRIGGER USER, "
        "counts as live capture and the run carries on from copies that missed the changes made meanwhile. "
        "One site, the resuming tick's probe. tests/244 part A catches it: no regrain_restart, no re-mint, and "
        "(with the swap's own check still in place) no swap at all.",
        [("  v_unarmed := pgpm._regrain_capture_unarmed(v_child);\n  v_restart_why := concat_ws(",
          "  v_unarmed := null;\n  v_restart_why := concat_ws(", 1)],
    ),
    "regrain_capture_unarmed_no_remint": (
        "bench/regrain_capture_enabled_always.sh",
        "#892, the plausible-but-wrong fix: a capture trigger that is not ENABLE ALWAYS restarts the run (the "
        "copies are discarded and the cursor goes back), but capture is not re-minted, so the trigger stays "
        "disabled or origin-only, the next tick finds it so again, and the run restarts forever without "
        "swapping. One site, the fold that sends an unarmed trigger to the re-mint; tests/244 part A catches it.",
        [("  v_capture_drift := coalesce(v_capture_drift, v_unarmed);\n", "", 1)],
    ),
    "regrain_swap_capture_unchecked": (
        "bench/regrain_capture_enabled_always.sh",
        "#892, the swap's half: the swap does not ask again whether capture is ENABLE ALWAYS once its DETACH "
        "holds ACCESS EXCLUSIVE on the source, so a trigger disabled after the tick's own check (ALTER TABLE "
        "... DISABLE TRIGGER needs only SHARE ROW EXCLUSIVE, which nothing the tick holds before the DETACH "
        "conflicts with) is never seen and the swap drops the source for copies capture may have missed "
        "changes for. One site, the post-DETACH check; tests/244 part C catches it.",
        [("  v_unarmed := pgpm._regrain_capture_unarmed(v_child);\n  if v_unarmed is not null then\n",
          "  v_unarmed := null;\n  if v_unarmed is not null then\n", 1)],
    ),
    "regrain_capture_unarmed_disabled_only": (
        "bench/regrain_capture_origin_only_upgrade.sh",
        "#892, the plausible-but-wrong fix: only a DISABLED capture trigger counts as not live, so an "
        "origin-only one (the state v0.6.0 minted, which a run in flight across the upgrade keeps, and the "
        "state ENABLE TRIGGER USER leaves) passes, though a session_replication_role = replica writer skips "
        "it. Nothing re-mints it, and the swap reverts a replica-role UPDATE and resurrects a DELETE. One site, "
        "the state _regrain_capture_unarmed accepts; tests/245 catches it.",
        [("  select case when t.tgenabled = 'A' then null\n",
          "  select case when t.tgenabled <> 'D' then null\n", 1)],
    ),
    "upgrade_regrain_capture_origin_only_kept": (
        "bench/upgrade_in_place.sh",
        "Pre-#892, through a REAL upgrade: a regrain in flight under the released v0.6.0 carries the "
        "origin-only capture trigger v0.6.0 minted, the upgrade's #878 block restarts the run and keeps capture "
        "as it was, and no tick asks whether capture is ENABLE ALWAYS, so a replica-role UPDATE and DELETE "
        "applied after the restarted run has re-copied their sub-range are never captured. The same edit as "
        "regrain_capture_unarmed_ignored; bench/upgrade_in_place.sh's in-flight stage (assertion 8) must FAIL "
        "on the trigger still origin-only after the first tick and on the run never swapping (the swap's own "
        "check refuses it every tick).",
        [("  v_unarmed := pgpm._regrain_capture_unarmed(v_child);\n  v_restart_why := concat_ws(",
          "  v_unarmed := null;\n  v_restart_why := concat_ws(", 1)],
    ),
    # Issues #827, #830 and #815 (F1-06): what untransmute hands back, and where.
    "untransmute_moved_parent_resolved_by_name": (
        "bench/untransmute_moved_parent.sh",
        "Pre-#827 untransmute: the restored table is resolved as <the parent's schema>.<name> after the rename "
        "instead of by the monolith's recorded oid, so after ALTER TABLE <parent> SET SCHEMA every reverse dies "
        "raw with 42P01 on a name it built itself, rolled back. One site, the resolution; tests/220's reverse "
        "and everything after it catch it.",
        [("  v_restored := v_monreg;\n",
          "  v_restored := format('%I.%I', v_nsp, v_rel)::regclass;\n", 1)],
    ),
    "untransmute_moved_parent_not_moved": (
        "bench/untransmute_moved_parent.sh",
        "Issue #827's move left out: the restored table is named by its oid but stays in the monolith's schema, "
        "so the trigger replay, built off the parent in its new schema, dies raw with 42P01, and a reverse "
        "without one would hand the table back out of the schema the application finds it in. tests/220's "
        "reverse and schema assertions catch it.",
        [("    execute format('alter table %s set schema %I', v_restored::text, v_nsp);\n", "    null;\n", 1)],
    ),
    "untransmute_index_names_kept": (
        "bench/untransmute_index_names.sh",
        "Pre-#830 untransmute: only the key is renamed back, so a UNIQUE constraint or index made on the "
        "managed table since the conversion comes back under the monolith clone's auto-name and ON CONFLICT "
        "ON CONSTRAINT <its name> fails with 42704. One site, the rename loop; tests/221's parts A and B "
        "catch it.",
        [("    execute format('alter index %s rename to %I', v_ix_oids[v_i]::regclass::text, v_ix_names[v_i]);\n",
          "    null;\n", 1)],
    ),
    "untransmute_index_names_carried_renamed": (
        "bench/untransmute_index_names.sh",
        "Issue #830's first exception left out: a secondary index transmute carried (step 9b, parent copy "
        "<name>_pgpm) is handed its parent copy's name too, so the table's own nx221_w_idx comes back as "
        "nx221_w_idx_pgpm. tests/221's part A catches it.",
        [("     and pc.relname::text <> mc.relname::text || '_pgpm'\n", "", 1)],
    ),
    "untransmute_index_names_legacy_key_renamed": (
        "bench/untransmute_index_names.sh",
        "Issue #830's second exception left out: a pre-#789 conversion's original key, whose parent copy "
        "PostgreSQL auto-named, is renamed to that auto-name (lg221_pkey1) instead of keeping the name it "
        "always had, as #789 decided. Since #901 the exception is the primary keys whose monolith copy does "
        "not carry a clone's auto-name; this hands back every primary key. tests/221's part B catches it.",
        [("     and (not mi.indisprimary or pgpm._is_clone_pkey_name(mt.relname, mc.relname))\n", "", 1)],
    ),
    # Issue #901 (F1-02): a primary key made since the conversion, handed back.
    "untransmute_pkey_name_kept": (
        "bench/untransmute_primary_key_name.sh",
        "Pre-#901 untransmute: #830's hand-back skips every primary-key index, so a PRIMARY KEY made on the "
        "managed table since the conversion (a keyless table's, or one replacing the key) comes back under the "
        "monolith clone's auto-name <monolith>_pkey and ON CONFLICT ON CONSTRAINT <its name> fails with 42704. "
        "One site, the filter; tests/257's parts A, B and C catch it.",
        [("     and (not mi.indisprimary or pgpm._is_clone_pkey_name(mt.relname, mc.relname))\n",
          "     and not mi.indisprimary\n", 1)],
    ),
    "untransmute_pkey_clone_name_unclipped": (
        "bench/untransmute_primary_key_name.sh",
        "Issue #901's clone-name test without PostgreSQL's clip: _is_clone_pkey_name compares the monolith's "
        "whole name plus _pkey, never clipped to fit 63 bytes, so a table whose monolith name is longer than 58 "
        "bytes keeps the clone's auto-name. tests/257's part C catches it.",
        [("  while octet_length(v_pfx) > 63 - 1 - octet_length(v_m[2]) loop\n"
          "    v_pfx := left(v_pfx, -1);\n"
          "  end loop;\n", "", 1)],
    ),
    # Issue #877, bullet 1 (F1-08): the identity sequence keeps the table's name through both directions.
    "transmute_identity_sequence_staging_name": (
        "bench/identity_sequence_name.sh",
        "Pre-#877 transmute: the parent's identity sequence keeps the name PostgreSQL gave it under the staging "
        "parent, <table>_pgpm_new_<col>_seq, so setval, GRANT ... ON SEQUENCE and ALTER SEQUENCE naming the "
        "table's sequence fail with 42P01 on the converted table. One site, step 3a's rename; tests/258's parts "
        "A and B catch it.",
        [("        execute format('alter sequence %s rename to %I', v_seq::text, v_idseqs[v_i]);\n",
          "        null;\n", 1)],
    ),
    "untransmute_identity_sequence_monolith_name": (
        "bench/identity_sequence_name.sh",
        "Pre-#877 untransmute: the restored table's identity sequence keeps the name PostgreSQL gave it on the "
        "monolith, <table>_p<label>_<col>_seq, so statements naming the table's sequence fail with 42P01 after "
        "the reverse. One site, the hand-back's rename; tests/258's parts A and B catch it.",
        [("    v_seq := pg_get_serial_sequence(v_restored::text, v_idcols[v_i])::regclass;\n"
          "    if (select s.relname from pg_class s where s.oid = v_seq) is distinct from v_idseqs[v_i] then\n"
          "      execute format('alter sequence %s rename to %I', v_seq::text, v_idseqs[v_i]);\n",
          "    v_seq := pg_get_serial_sequence(v_restored::text, v_idcols[v_i])::regclass;\n"
          "    if (select s.relname from pg_class s where s.oid = v_seq) is distinct from v_idseqs[v_i] then\n"
          "      null;\n", 1)],
    ),
    "untransmute_identity_sequence_renamed_early": (
        "bench/identity_sequence_name.sh",
        "Issue #877's hand-back placed before the move into the parent's schema (#827): the restored table's "
        "sequence is renamed in the monolith's schema, where a relation left behind under the name dies the "
        "reverse raw with 42P07. tests/258's part B (a squatter on public.mv258_id_seq) catches it.",
        [("  if (select relnamespace from pg_class where oid = v_restored) <> (select oid from pg_namespace where nspname = v_nsp) then\n"
          "    execute format('alter table %s set schema %I', v_restored::text, v_nsp);\n"
          "  end if;\n",
          "  for v_i in 1 .. coalesce(array_length(v_idcols, 1), 0) loop\n"
          "    v_seq := pg_get_serial_sequence(v_restored::text, v_idcols[v_i])::regclass;\n"
          "    if (select s.relname from pg_class s where s.oid = v_seq) is distinct from v_idseqs[v_i] then\n"
          "      execute format('alter sequence %s rename to %I', v_seq::text, v_idseqs[v_i]);\n"
          "    end if;\n"
          "  end loop;\n"
          "  if (select relnamespace from pg_class where oid = v_restored) <> (select oid from pg_namespace where nspname = v_nsp) then\n"
          "    execute format('alter table %s set schema %I', v_restored::text, v_nsp);\n"
          "  end if;\n", 1)],
    ),
    "untransmute_replica_identity_not_restored": (
        "bench/untransmute_replica_identity.sh",
        "Pre-#815 (F1-06) untransmute: the parent's replica identity is read and never applied, so the "
        "restored table keeps the monolith's conversion-time identity: FULL set since comes back DEFAULT, "
        "DEFAULT comes back FULL. One site, the hand-back's ALTER, built and discarded; tests/222's every "
        "transition catches it.",
        [("    execute format('alter table %s replica identity %s', v_restored::text,\n",
          "    perform format('alter table %s replica identity %s', v_restored::text,\n", 1)],
    ),
    "untransmute_replica_identity_kind_only": (
        "bench/untransmute_replica_identity.sh",
        "Issue #815's hand-back compares only the KIND of identity: a table whose identity was USING INDEX on "
        "its key at the conversion and USING INDEX on another index since keeps its key as the identity. "
        "tests/222's rh222 catches it.",
        [("     or (v_ri = 'i' and not (select indisreplident from pg_index where indexrelid = v_ri_idx)) then\n",
          "     then\n", 1)],
    ),
    "check_text_time_alphabet_regex": (
        "bench/check_text_time_alphabet_syntax.sh",
        "Pre-#837 check_text_time: both shape tests (the sample's and the maximum's) splice the alphabet raw "
        "into the regex bracket expression '[^' || alphabet || ']' again instead of asking "
        "_text_time_shaped, so '-' between two characters is a range and a backslash an unclosed bracket. "
        "A value with ',' in its timestamp field under '+-0123456789' counts as shaped and raises in "
        "_text_time_to_ts, aborting the sample and transmute's sampling step. tests/232 catches it at the "
        "sample, the maximum, the backslash alphabet and both transmutes, while its default-alphabet control "
        "still passes.",
        [("              and pgpm._text_time_shaped(v, %4$L, %5$s, %7$s, %6$L)\n",
          "              and left(v, length(%4$L)) = %4$L\n"
          "              and length(v) >= length(%4$L) + %5$s\n"
          "              and substr(v, length(%4$L) + 1, %5$s) !~ ('[^' || %6$L || ']')\n", 1),
         ("           select case when pgpm._text_time_shaped(v, %4$L, %5$s, %7$s, %6$L)\n",
          "           select case when left(v, length(%4$L)) = %4$L\n"
          "                        and length(v) >= length(%4$L) + %5$s\n"
          "                        and substr(v, length(%4$L) + 1, %5$s) !~ ('[^' || %6$L || ']')\n", 1)],
    ),
    "grid_floor_calendar_no_year_zero": (
        "bench/grid_floor_across_era.sh",
        "Pre-#769 _grid_floor: the calendar branch counts the years from the anchor with extract(year) "
        "again, which has no year 0, so across the era the month count is 12 off: a BC value floors a year "
        "early from the 2000 anchor and an AD value floors above itself from a BC anchor. tests/233's unit "
        "sweep, the same-step resume of an interrupted BC transmute and the regrain of a BC monolith catch "
        "it, while its AD controls still pass.",
        [("      k := ((v_ty - v_ay) * 12\n",
          "      k := ((extract(year from ts_wall) - extract(year from anc_wall)) * 12\n", 1)],
    ),
    "fine_child_label_time_four_digit": (
        "bench/fine_child_label_bc_wide_year.sh",
        "Pre-#769 _is_fine_child_label: the time branch is '^[0-9]{4}(_[0-9]+)*$' again, which matches no "
        "`_bc` (BC) label and no five-digit-year label, so transmute's orphan guard (both halves) and "
        "restore_incoming_fks's in-flight gate let such names through. One site, the helper all three "
        "callers ask; tests/234's refusals and gate zeros catch it, while its AD controls still pass.",
        [("    return p_suffix ~ '^([0-9]{4}|[1-9][0-9]{4,})(_[0-9]+)*(_bc)?$';\n",
          "    return p_suffix ~ '^[0-9]{4}(_[0-9]+)*$';\n", 1)],
    ),
    "archive_step_no_child_isolation": (
        "bench/archive_step_child_isolation.sh",
        "Pre-#833 _archive_step: the per-candidate loop has no exception block of its own, so one strategy "
        "raise (the documented skip_archive retry path) unwinds the whole step into maintain()'s one handler "
        "and discards the ledger rows of every other partition archived in the same call, after the strategy "
        "already ran for them. One site, the block's exception clause removed (the bare begin/end left is "
        "inert). tests/228 catches it: the neighbours' chunks, the per-partition skip row, the same-tick "
        "retirements, and A handed to the strategy twice.",
        [("    exception when others then\n"
          "      insert into pgpm.log (parent_table, action, lo, hi, method)\n"
          "        values (p_parent, 'skip_archive', r.lo, r.hi, left(sqlerrm, 200));\n"
          "    end;\n"
          "  end loop;\n"
          "  return v_count;\n",
          "    end;\n"
          "  end loop;\n"
          "  return v_count;\n", 1)],
    ),
    "retain_loop_no_child_isolation": (
        "bench/retain_loop_per_child_isolation.sh",
        "Pre-#907 retain(): the loop over retire() has no exception block of its own, so a lock timeout in "
        "retire()'s write-block install on one aged partition (a VACUUM or ANALYZE holding SHARE UPDATE "
        "EXCLUSIVE on it) unwinds the whole retain step into maintain()'s one handler and rolls back the DROPs "
        "already completed for the other aged partitions of the call. One site, the block's exception clause "
        "removed (the bare begin/end left is inert). tests/263 catches it: the neighbours' drops, the rows "
        "left, and the per-partition skip_retain row.",
        [("      if pgpm.retire(p_parent, r.child_name) then v_dropped := v_dropped + 1; end if;\n"
          "    exception when others then\n"
          "      insert into pgpm.log (parent_table, action, lo, hi, method)\n"
          "        values (p_parent, 'skip_retain', r.lo, r.hi, left(sqlerrm, 200));\n"
          "    end;\n",
          "      if pgpm.retire(p_parent, r.child_name) then v_dropped := v_dropped + 1; end if;\n"
          "    end;\n", 1)],
    ),
    "retain_loop_silent_skip": (
        "bench/retain_loop_per_child_isolation.sh",
        "Issue #907, the plausible-but-wrong fix: retain()'s loop isolates each partition but swallows the "
        "raise without logging it, so the neighbours are retired and the held partition's deferral leaves no "
        "trace in pgpm.log: no skip_retain over its range, nothing for an operator to see while retention of "
        "that partition stalls. One site, the handler's INSERT replaced by null. tests/263's per-partition "
        "skip_retain assertion catches it while its drop assertions pass.",
        [("    exception when others then\n"
          "      insert into pgpm.log (parent_table, action, lo, hi, method)\n"
          "        values (p_parent, 'skip_retain', r.lo, r.hi, left(sqlerrm, 200));\n"
          "    end;\n",
          "    exception when others then\n"
          "      null;\n"
          "    end;\n", 1)],
    ),
    "retire_one_step_no_disarm": (
        "bench/retire_one_step_disarm.sh",
        "Pre-#835 retire(): the one-step DROP of a retirement that had dispatched a detach (its incoming FK "
        "dropped before pg_cron ran it) never returns pgpm_detach to idle, so the job runs DETACH PARTITION "
        "of the dropped name every tick. One site, the one-step path's disarm. tests/229 part A catches it.",
        [("  elsif r.retiring_at is not null then\n", "  elsif false then\n", 1)],
    ),
    "retire_one_step_disarm_any": (
        "bench/retire_one_step_disarm.sh",
        "Issue #835, the plausible-but-wrong fix: the one-step path disarms UNCONDITIONALLY, as the referenced "
        "path does after a detach landed. No detach landed here, so nothing proves the job still holds this "
        "retirement's command, and another retirement's dispatch is clobbered (the #407 rule). One site, the "
        "disarm's argument. tests/229 part B catches it.",
        [("    perform pgpm._idle_detach_job(pgpm._detach_cmd(p_parent, v_nsp, p_child));\n"
          "  end if;\n\n"
          "  begin\n"
          "    -- THE REGRAIN THIS DROP WOULD ORPHAN",
          "    perform pgpm._idle_detach_job(null);\n"
          "  end if;\n\n"
          "  begin\n"
          "    -- THE REGRAIN THIS DROP WOULD ORPHAN", 1)],
    ),
    "forget_missing_keeps_detach_armed": (
        "bench/forget_missing_disarms_detach.sh",
        "Pre-#893 forget_missing(): it deletes a dropped parent's retiring pgpm.part row and leaves the "
        "pgpm_detach job holding that retirement's DETACH ... CONCURRENTLY by name, so pg_cron's next run "
        "detaches the same-named partition of a table re-created under the same name and grid. One site, the "
        "disarm's guard. tests/246 part A catches it.",
        [("    if v_retiring is not null then\n", "    if false then\n", 1)],
    ),
    "forget_missing_disarm_any_command": (
        "bench/forget_missing_disarms_detach.sh",
        "Issue #893, the over-wide fix: forget_missing() disarms whatever unowned command the job holds, not "
        "only a detach of a partition the forgotten parent was retiring, so another table's dispatch, armed "
        "after the drop, is clobbered. One site, the partition-name match. tests/246 part B catches it.",
        [("                        and right(v_cmd, length(quote_ident(t.child_name)) + 14)\n"
          "                          = '.' || quote_ident(t.child_name) || ' concurrently')\n",
          "                        )\n", 1)],
    ),
    "forget_missing_disarm_owned": (
        "bench/forget_missing_disarms_detach.sh",
        "Issue #893, the plausible-but-wrong fix: forget_missing() disarms a matching detach without asking "
        "whether a LIVE retirement owns it. A namesake re-created and already retiring the same-named partition "
        "holds a command of identical text, and it is clobbered (the #407 rule). One site, the live-owner "
        "check. tests/246 part C catches it.",
        [("         and not exists (select 1 from pgpm.part p\n"
          "                          where p.retiring_at is not null\n",
          "         and not exists (select 1 from pgpm.part p\n"
          "                          where false and p.retiring_at is not null\n", 1)],
    ),
    "extend_to_edge_uncounted": (
        "bench/extend_to_edge_cell_count.sh",
        "Pre-#836 extend_to: the p_max dry count counts grid steps past the frontier's floor only, while the "
        "walk also builds the frontier's own cell when it is missing, so p_max => 1 creates two partitions. "
        "One site, the edge's count. tests/230 part A catches it.",
        [("  then\n    v_edge := 1;\n  end if;\n", "  then\n    v_edge := 0;\n  end if;\n", 1)],
    ),
    "extend_to_edge_always_counted": (
        "bench/extend_to_edge_cell_count.sh",
        "Issue #836, the over-correction: the edge's cell is counted whether or not it is built, so a call "
        "one step past a built edge needs p_max => 2 and p_max => 1 is refused where it must create its one "
        "partition. One site, the edge's count. tests/230 part C catches it.",
        [("  v_needed int := 0; v_edge int := 0; v_made int := 0; v_walked int := 0;\n",
          "  v_needed int := 0; v_edge int := 1; v_made int := 0; v_walked int := 0;\n", 1),
         ("  then\n    v_edge := 1;\n  end if;\n", "  then\n    null;\n  end if;\n", 1)],
    ),
    "obtain_trusts_dropped_cell": (
        "bench/obtain_rebuilds_dropped_cell.sh",
        "Pre-#908 obtain and extend_to: an attached pgpm.part row is taken for a built cell without asking "
        "whether its partition still exists, so a forward cell dropped by hand is never rebuilt and nothing "
        "is logged. One site, _cell_attached's forget. tests/264 parts A and B catch it.",
        [("          and not pgpm._part_built(p_parent, p.child_oid, p.retiring_at)) then\n",
          "          and false) then   -- MUTANT: the dead row is trusted\n", 1)],
    ),
    "obtain_rebuild_keeps_stale_row": (
        "bench/obtain_rebuilds_dropped_cell.sh",
        "Issue #908, the plausible-but-wrong fix: the cell is judged on rows whose partition exists, so it is "
        "rebuilt, but the dead row is never forgotten, and _create_partition's insert of the rebuilt row "
        "conflicts on the name and does nothing: the row keeps the dropped partition's oid, so every "
        "identity check after it refuses the live one, and nothing is logged. Two sites in _cell_attached. "
        "tests/264 parts A and B catch it.",
        [("          and not pgpm._part_built(p_parent, p.child_oid, p.retiring_at)) then\n",
          "          and false) then   -- MUTANT: the dead row is kept\n", 1),
         ("       and pgpm._native_gt(cfg.control_kind, p_hi, p.lo));\nend;\n",
          "       and pgpm._native_gt(cfg.control_kind, p_hi, p.lo) and pgpm._part_built(p_parent, p.child_oid, p.retiring_at));\nend;\n",
          1)],
    ),
    "status_counts_dropped_cell": (
        "bench/obtain_rebuilds_dropped_cell.sh",
        "Pre-#908 status(): n_partitions, coarse_partitions and newest_bound read pgpm.part alone, so a "
        "partition dropped by hand is still counted, and still the ceiling when it was the top cell. Three "
        "sites in status(). tests/264 part A catches it.",
        [(" and pgpm._part_built(parent_table, child_oid, retiring_at)", "", 3)],
    ),
    # Issue #981: a pgpm.part row an upgrade from before child_oid could not anchor.
    "unanchored_row_reads_built": (
        "bench/upgrade_unanchored_cell.sh",
        "Pre-#981 _part_built: a null child_oid (a row the upgrade's backfill could not anchor, its partition "
        "dropped by hand before the upgrade) reads as built, so obtain never forgets or rebuilds the cell and "
        "every write into it is refused. One site, the null branch.",
        [("    when p_child_oid is null then\n"
          "      exists (select 1 from pg_inherits i\n"
          "               where i.inhparent = p_parent\n"
          "                 and not exists (select 1 from pgpm.part a\n"
          "                                  where a.parent_table = p_parent and a.child_oid = i.inhrelid))\n",
          "    when p_child_oid is null then true\n", 1)],
    ),
    "unanchored_row_reads_gone": (
        "bench/upgrade_unanchored_cell.sh",
        "Issue #981, the over-correction: a null child_oid reads as gone whatever the table holds, so the row "
        "of a cell RENAMED by hand before the upgrade (the backfill cannot resolve it either) is forgotten, "
        "and obtain dies on the renamed partition's overlap at every tick. One site, the null branch.",
        [("    when p_child_oid is null then\n"
          "      exists (select 1 from pg_inherits i\n"
          "               where i.inhparent = p_parent\n"
          "                 and not exists (select 1 from pgpm.part a\n"
          "                                  where a.parent_table = p_parent and a.child_oid = i.inhrelid))\n",
          "    when p_child_oid is null then false\n", 1)],
    ),
    # Issue #982: progress() reads the write child through the predicate status() shares.
    "progress_reads_unbuilt_write_child": (
        "bench/progress_write_child_built.sh",
        "Pre-#982 progress(): write_child, write_ceiling, freeze_margin and freeze_in come from the pgpm.part "
        "row alone, so a frontier cell dropped or detached by hand is reported as the partition taking "
        "writes, with a healthy margin. One site. tests/279 catches it.",
        [("         and pgpm._part_built(r.parent_table, p.child_oid, p.retiring_at)\n", "", 1)],
    ),
    # Issue #956: a forward cell DETACHed by hand is not built.
    "obtain_trusts_detached_cell": (
        "bench/obtain_rebuilds_detached_cell.sh",
        "Pre-#956 _part_built: an anchored row is built when its relation exists, so a forward cell detached "
        "by hand (its table kept) is never rebuilt and nothing is logged, while every write into its range is "
        "refused. One site, the anchored branch. tests/280 parts A and B catch it.",
        [("    else exists (select 1 from pg_inherits i where i.inhparent = p_parent and i.inhrelid = p_child_oid)\n"
          "         or (p_retiring_at is not null and exists (select 1 from pg_class c where c.oid = p_child_oid))\n",
          "    else exists (select 1 from pg_class c where c.oid = p_child_oid)\n", 1)],
    ),
    "detached_cell_name_refused": (
        "bench/obtain_rebuilds_detached_cell.sh",
        "Issue #956, the plausible-but-wrong fix: the hand-detached row is forgotten, but _obtain_name reads the "
        "detached table, which still holds the cell's plain name, as a stranger's, so the cell is logged "
        "fail_obtain_name and left unbuilt. One site, _obtain_name's stand-in. tests/280 parts A and B catch it.",
        [("     and not exists (\n"
          "       select 1 from pgpm.log l\n"
          "        where l.parent_table = p_parent and l.action = 'forget_detached_partition'\n"
          "          and strpos(l.method, format('(oid %s)', v_held::oid)) > 0) then\n",
          "     then\n", 1)],
    ),
    "retiring_cell_forgotten": (
        "bench/obtain_rebuilds_detached_cell.sh",
        "Issue #956, the over-correction: a partition retire() is detaching concurrently (retiring_at set) "
        "reads as detached by hand, so obtain forgets its row and builds the range again under a retirement "
        "in flight. One site, the anchored branch. tests/280 part C catches it.",
        [("\n         or (p_retiring_at is not null and exists (select 1 from pg_class c where c.oid = p_child_oid))\n",
          "\n", 1)],
    ),
    "crossing_keys_bare_text": (
        "bench/crossing_keys_datestyle.sh",
        "Pre-#814 (F4-01) _crossing_keys: a timestamptz referencing key is read back with a bare ::text, so "
        "under DateStyle SQL in Asia/Kolkata ('IST', Israel to PostgreSQL before 18) retire()'s crossing "
        "DELETE parses every key 3.5 hours off and matches nothing: the declared ON DELETE CASCADE never "
        "runs and the dispatched detach can never succeed. One site, the render. tests/231 catches it on "
        "PostgreSQL 15 to 17.",
        [("    v_refval_q := case when v_reftype = 'timestamptz'::regtype then format('pgpm._ts_text(%I)', v_refcol)\n"
          "                       else format('%I::text', v_refcol) end;\n",
          "    v_refval_q := format('%I::text', v_refcol);\n", 1)],
    ),
    "crossing_keys_referencing_collation": (
        "bench/crossing_keys_control_collation.sh",
        "Pre-#900 (F4-07) _crossing_keys: the referencing column is compared against a text_time cell's bounds "
        "under its OWN collation, so for a referencing column declared without COLLATE in an en_US database a "
        "mixed-case KSUID cell whose bounds run from an uppercase to a lowercase digit is an empty interval: "
        "no crossing key is found, the declared ON DELETE CASCADE never runs and the dispatched detach is "
        "refused on every run. One site, the compared expression. tests/253 catches it.",
        [("    v_refcmp_q := format('%I', v_refcol) || coalesce(' collate ' || v_ctrl_coll_q, '');\n",
          "    v_refcmp_q := format('%I', v_refcol);   -- MUTANT: the referencing column's own collation\n", 1)],
    ),
    "acl_carry_additive": (
        "bench/transmute_grant_carry_resets_acl.sh",
        "Issue #838, the pre-fix shape: _acl_carry_ddl emits the source's grants with no reset in front of "
        "them, so transmute's parent keeps every privilege the transmuting role's ALTER DEFAULT PRIVILEGES "
        "gave it at its creation, a privilege REVOKEd on the table included. One site, the reset statement. "
        "tests/235 parts A, B and C catch it.",
        [("  v_ddl := array[format('select pgpm._acl_reset(%L::regclass, %L)', p_dst_q,\n"
          "                        (select c.relacl is null from pg_class c where c.oid = p_src))];\n",
          "  v_ddl := '{}';   -- MUTANT: no reset, the grants are added to what the destination holds\n", 1)],
    ),
    "acl_reset_no_owner_default": (
        "bench/transmute_grant_carry_resets_acl.sh",
        "Issue #838, a reset that only revokes: a source whose ACL is NULL (the owner's implicit default) has "
        "no grant to replay, so without the GRANT ALL to the owner the parent's owner holds nothing at all. "
        "One site, the owner's grant after the revokes. tests/235 part B catches it.",
        [("  if p_default then\n"
          "    execute format('grant all on %s to %I', p_rel::text,\n"
          "                   (select pg_get_userbyid(c.relowner) from pg_class c where c.oid = p_rel));\n"
          "  end if;\n", "", 1)],
    ),
    "acl_reset_spares_owner": (
        "bench/transmute_grant_carry_resets_acl.sh",
        "Issue #838, untransmute's pre-#875 reset shape taken over verbatim: revoke only from the roles the "
        "destination's ACL names. A parent born with a NULL ACL names nobody, so nothing is revoked and the "
        "first replayed GRANT materialises the owner's implicit everything, a privilege the owner had "
        "revoked from itself on the table included. One site, the owner in the revoke list. tests/235 "
        "part C catches it.",
        [("    select c.relowner as grantee from pg_class c where c.oid = p_rel\n"
          "    union\n", "", 1)],
    ),
    "regrain_capture_grant_parent_only": (
        "bench/regrain_capture_source_grantees.sh",
        "Pre-#843 _regrain_capture_grant: INSERT on the delta goes to the grantees of DML on the PARENT "
        "only. The capture trigger runs as the writer, so a role granted UPDATE or DELETE directly on the "
        "regraining partition (which PostgreSQL lets write it with no grant on the parent) gets 42501 on "
        "the delta on every write into the source until the swap. Both halves of the grantee query, the "
        "table ACL and the column ACLs, read the parent alone again. tests/236 catches it at the delta's "
        "grantee list and at every write of the three partition-level writers.",
        [("             where c.oid in (p_parent, p_source) and c.relacl is not null\n",
          "             where c.oid = p_parent and c.relacl is not null\n", 1),
         ("             where att.attrelid in (p_parent, p_source) and att.attnum > 0 and not att.attisdropped\n",
          "             where att.attrelid = p_parent and att.attnum > 0 and not att.attisdropped\n", 1)],
    ),
    "regrain_step_source_parent_schema": (
        "bench/regrain_moved_parent_identity.sh",
        "Issue #768 (F3-04) put back at regrain_step's read of the source: <the parent's current "
        "schema>.<p_child>, not the relation pgpm.part recorded. After ALTER TABLE <parent> SET SCHEMA "
        "(safe by contract, the partitions stay) every auto-regrain tick fails 'relation <new schema>."
        "<monolith> does not exist' and the monolith is never regrained. One site; the capture install and "
        "_regrain_capture_active keep the fix, so only the step itself is wrong. tests/237 parts A and B "
        "catch it.",
        [("  v_child      := pgpm._regrain_child_rel(p_parent, p_child);\n",
          "  v_child      := format('%I.%I', v_nsp, p_child)::regclass;\n", 1)],
    ),
    "regrain_cancel_delta_parent_schema": (
        "bench/regrain_moved_parent_identity.sh",
        "Issue #555 (F3-11) put back at regrain_cancel: the delta is truncated as <the parent's current "
        "schema>.<the recorded delta's name>, not in the schema the recorded regrain_delta_oid is in. After "
        "the parent moves mid-regrain the cancel empties an unrelated relation of that name in the new "
        "schema and leaves the real delta holding its captured changes. One site. tests/237 part C catches "
        "it on both tables.",
        [("  select nsp, delta into v_dnsp, v_delta from pgpm._regrain_capture_names(p_parent);\n"
          "  if v_delta is not null then   -- #955: the recorded delta, or nothing\n"
          "    execute format('truncate %I.%I', v_dnsp, v_delta);\n",
          "  select delta into v_delta from pgpm._regrain_capture_names(p_parent);\n"
          "  if v_delta is not null and to_regclass(format('%I.%I', v_nsp, v_delta)) is not null then\n"
          "    execute format('truncate %I.%I', v_nsp, v_delta);\n", 1)],
    ),
    "regrain_upgrade_guard_parent_schema": (
        "bench/regrain_moved_parent_identity.sh",
        "Issue #768 (F3-12) put back at install.sql's #650 upgrade block: an in-flight source is found by "
        "relname in the PARENT's schema, so after ALTER TABLE <parent> SET SCHEMA a source that lost its "
        "TRUNCATE guard is not found, re-running install.sql leaves it unguarded, and a TRUNCATE of the "
        "regraining source goes through. One site, the block's join; _regrain_capture_active keeps the "
        "fix. The guard's second half (the re-run of install.sql) catches it; tests/237 does not, since a "
        "pgTAP file cannot re-run install.sql.",
        [("    select pgpm._regrain_child_rel(p.parent_table, p.child_name) as child\n"
          "      from pgpm.part p\n"
          "     where p.attached and pgpm._regrain_capture_active(p.parent_table, p.child_name)\n",
          "    select c.oid::regclass as child\n"
          "      from pgpm.part p join pg_class pc on pc.oid = p.parent_table\n"
          "      join pg_class c on c.relname = p.child_name and c.relnamespace = pc.relnamespace\n"
          "     where p.attached and pgpm._regrain_capture_active(p.parent_table, p.child_name)\n", 1)],
    ),
    "regrain_names_fit_part_name": (
        "bench/regrain_names_fit_clamped_cell.sh",
        "Pre-#815 (F3-06) _regrain_names_fit: each sub-range is named with _part_name at the target step's "
        "granularity, not through _regrain_sub_name as regrain_step names it, so a clamped first cell's "
        "finer (longer) label is never checked: a table name that fits the day label but not the hour one "
        "passes set_regrain and every auto-regrain tick then fails the 63-byte limit. One site. tests/238 "
        "catches it at the call-time refusal and at the regrain_to it leaves set.",
        [("        perform pgpm._regrain_sub_name(p_rel, cfg, p_step, v, h);\n",
          "        perform pgpm._part_name(p_rel, k, p_step, v, null, z);\n", 1)],
    ),
    "regrain_calendar_name_by_lattice": (
        "bench/regrain_calendar_clamped_name.sh",
        "Pre-#904 _regrain_sub_name: a calendar target step (month, year) is left to _part_name, so a sub-range "
        "clamped to a child's off-lattice lo is labelled at the step's own granularity, the label of the "
        "lattice cell it sits in. A '1 year' lattice starts in the month the anchor reads in partition_tz "
        "(December west of UTC with the default anchor), so a monthly New York monolith starting 2023-03-01 "
        "clamps [2023-03-01, 2023-12-01) under 2023, the name of the cell after it, and regrain_history(.., "
        "'1 year') refuses its own first copy. One site, the early return restored for calendar steps; "
        "tests/260 parts A, B and C catch it.",
        [("  v_from := case when v_months > 0 and v_months % 12 = 0 then 1 when v_months > 0 then 2\n",
          "  if v_months > 0 then\n"
          "    return pgpm._part_name(p_relname, cfg.control_kind, p_step, p_lo, p_hi, cfg.partition_tz);\n"
          "  end if;\n"
          "  v_from := case when v_months > 0 and v_months % 12 = 0 then 1 when v_months > 0 then 2\n", 1)],
    ),
    # Issue #872, the recorded-identity lever: one mutation per site, each putting that site back to the
    # parent's current schema or to a name recorded before a move. bench/recorded_identity.sh runs tests/239
    # (the moved-parent conformance suite) and tests/240 against each.
    "regrain_copy_rel_parent_schema": (
        "bench/recorded_identity.sh",
        "Issue #872 bullet 1 put back in _regrain_copy_rel: a regrain copy is looked up as <the parent's CURRENT "
        "schema>.<name>, not in the schema its recorded oid sits in. After ALTER TABLE <parent> SET SCHEMA the "
        "copies stay where regrain_step made them, so the swap gate refuses every tick ('no longer names the "
        "copy', logged skip_regrain) and the run never swaps. One site, the helper the swap gate, the attach "
        "and the reconcile all ask. tests/239 S2 catches it.",
        [("  v_nsp := pgpm._child_nsp(p_parent, p_child);   -- #872: the copy's own schema, by its recorded oid\n",
          "  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace\n"
          "   where c.oid = p_parent;   -- MUTANT: the parent's current schema\n", 1)],
    ),
    "regrain_copy_branch_parent_schema": (
        "bench/recorded_identity.sh",
        "Issue #872 bullet 1 put back in regrain_step's copy branch: a sub-range's copy is looked for, and a new "
        "one made, in the parent's CURRENT schema. A copy part-filled before the parent moved is then a "
        "namesake's name (refused every tick) or nothing (a second copy is made and re-anchored, the first left "
        "full of rows). One site. tests/239 S2 catches it.",
        [("    v_sub_nsp := coalesce((select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace\n"
          "                            where c.oid = v_sub_oid), v_src_nsp);\n",
          "    v_sub_nsp := v_nsp;   -- MUTANT: the parent's current schema\n", 1)],
    ),
    "regrain_coverage_reset_parent_schema": (
        "bench/recorded_identity.sh",
        "Issue #872 bullet 1 put back in the swap's archive_coverage_reset line: the source whose coverage is "
        "discarded is named <the parent's CURRENT schema>.<source>, a relation that never existed once the "
        "parent moved. One site. tests/239 S2 catches it at the logged method.",
        [("                     v_rec, v_src_nsp, v_child_name, v_made));   -- #872: where the source was\n",
          "                     v_rec, v_nsp, v_child_name, v_made));\n", 1)],
    ),
    "restore_fk_replays_recorded_definition": (
        "bench/recorded_identity.sh",
        "Issue #872 bullet 2 put back in restore_incoming_fks: the recorded definition is replayed verbatim, "
        "its REFERENCES naming the parent as it was at the conversion. After a SET SCHEMA or RENAME the key "
        "comes back against a namesake at the old name (logged restore_incoming_fk) or dies 42P01, which inside "
        "regrain's swap leaves it off. Both branches of the one site (a partitioned and a plain referencer). "
        "tests/239 S1, S2 and S5 and tests/240 A to C catch it.",
        [("                       pgpm._fk_readd_definition(r.definition, p_parent));   -- #872: the parent by oid\n",
          "                       r.definition);\n", 2)],
    ),
    "untransmute_fk_replays_recorded_definition": (
        "bench/recorded_identity.sh",
        "Issue #872 bullet 2 put back in untransmute: each preserved key is re-added from its recorded text "
        "verbatim, so a table renamed since its conversion gets its key back against whatever now holds the "
        "old name, or the reverse dies 42P01. Both branches of the one site. tests/239 S4 and tests/240 D "
        "catch it.",
        [("                     pgpm._fk_readd_definition(r.definition, v_restored));   -- #872: the restored table by oid\n",
          "                     r.definition);\n", 2)],
    ),
    "uninstall_fk_exempt_by_name": (
        "bench/recorded_identity.sh",
        "Issue #872 bullet 3 put back in uninstall.sql: a suspended key is exempted from the refusal when ANY "
        "foreign key of its name is live on the referencing table, against whatever table. A namesake key "
        "suppresses the refusal and the schema drop takes the only record of the real one. One site. "
        "tests/240 E catches it.",
        [("                        where c.conrelid = d.referencing_table and c.conname = d.constraint_name and c.contype = 'f'\n"
          "                          and c.confrelid = d.parent_table);\n",
          "                        where c.conrelid = d.referencing_table and c.conname = d.constraint_name and c.contype = 'f');\n",
          1)],
    ),
    "hypertable_copy_key_tmp_by_name": (
        "bench/hypertable_key_index_on_destination.sh",
        "Issue #872 bullet 4 put back in from_hypertable_copy: the tracked key's index is pre-built under the "
        "bare temp name <conname>_pgpm_new whatever holds it, so after an abandoned tracking copy and a RENAME "
        "of the hypertable (whose key keeps its name) the copy dies 'already exists' before copying a row. One "
        "site. tests/timescale/db/45 catches it.",
        [("    v_keytmp := pgpm._from_hypertable_key_tmp(v_keyconname, v_keyidx, v_nsp, v_destreg);\n",
          "    v_keytmp := pgpm._from_hypertable_tmp_name(v_keyconname, v_keyidx);   -- MUTANT: by name\n", 1)],
    ),
    "hypertable_cutover_key_tmp_unshared": (
        "bench/hypertable_key_index_on_destination.sh",
        "Issue #872 bullet 4, the half-fix: the copy takes the oid form when an abandoned copy holds the temp "
        "name, but the cutover keeps its #768 choice, which builds under the oid form without asking whether "
        "the copy already put that index on the destination, so the cutover of the renamed table dies 'already "
        "exists' after the whole copy. One site. tests/timescale/db/45 catches it.",
        [(HT_CUTOVER_KEY_TMP_BLOCK, """    v_tmp := pgpm._from_hypertable_tmp_name(k.conname, k.conindid);
    v_tmp_oid := to_regclass(format('%I.%I', v_nsp, v_tmp));
    if not exists (select 1 from pg_index i where i.indexrelid = v_tmp_oid and i.indrelid = v_dest_oid) then
      if v_tmp_oid is not null then
        v_tmp := 'pgpm_new_' || k.conindid::text;
      end if;
      execute pgpm._from_hypertable_index_ddl(k.conindid, v_tmp, v_nsp, v_dest);
    end if;
""", 1)],
    ),
    "transmute_id_frontier_non_finite": (
        "bench/transmute_non_finite_id_key.sh",
        "Issue #895 put back: transmute's id-kind frontier read takes a numeric column's NaN or Infinity "
        "maximum (and a -Infinity minimum) into the monolith bound unchecked, so phase 1 commits a "
        "pgpm_monolith_bound CHECK and a claim with hi = NaN and the re-run after the bad row's deletion "
        "completes a monolith [0, NaN) that takes every future id. One site, the refusal both arms share. "
        "tests/247's pinned NaN, Infinity and -Infinity refusals catch it.",
        [("  if p_control_kind = 'id'\n     and (v_max_raw::numeric in ('NaN', 'Infinity', '-Infinity')\n",
          "  if false and p_control_kind = 'id'   -- MUTANT: no finiteness check\n     and (v_max_raw::numeric in ('NaN', 'Infinity', '-Infinity')\n",
          1)],
    ),
    "hypertable_scratch_dbatch_drop_unqualified": (
        "bench/hypertable_scratch_tables_in_pg_temp.sh",
        "Pre-#894 from_hypertable_drain_delta_step: the batch's scratch table is dropped first by an "
        "UNQUALIFIED name, and a fresh transaction has no temp pgpm_dbatch, so the drop falls through the "
        "search_path and takes the operator's own public.pgpm_dbatch with its rows on the first batch (the "
        "drain procedure and a tracked cutover's pre-drain call the step too). tests/timescale/db/47 parts A, "
        "B and D catch it.",
        [("  execute 'drop table if exists pg_temp.pgpm_dbatch';\n",
          "  execute 'drop table if exists pgpm_dbatch';   -- MUTANT: resolved through the search_path\n", 1)],
    ),
    "hypertable_scratch_htail_drop_unqualified": (
        "bench/hypertable_scratch_tables_in_pg_temp.sh",
        "Pre-#894 from_hypertable_cutover: the keyed append-only catch-up drops its tail table by an "
        "UNQUALIFIED name, so the cutover's transaction, which has no temp pgpm_htail yet, drops the "
        "operator's own public.pgpm_htail with its rows. tests/timescale/db/47 parts C and D catch it.",
        [("      execute 'drop table if exists pg_temp.pgpm_htail';\n",
          "      execute 'drop table if exists pgpm_htail';   -- MUTANT: resolved through the search_path\n", 1)],
    ),
    "hypertable_scratch_reads_unqualified": (
        "bench/hypertable_scratch_tables_in_pg_temp.sh",
        "The half-fix of #894: the drops and creates name pg_temp but the reads do not, so under a "
        "search_path that names pg_temp after a schema holding a table of the scratch name, the drain step "
        "reads the operator's pgpm_dbatch as its batch (the real batch's keys are deleted from the delta and "
        "never applied) and the cutover inserts the operator's pgpm_htail rows as its tail (the conservation "
        "check then refuses the swap). tests/timescale/db/47 part D catches it.",
        [("from pg_temp.pgpm_dbatch", "from pgpm_dbatch", 4),
         ("      analyze pg_temp.pgpm_htail;\n", "      analyze pgpm_htail;\n", 1),
         ("select %s from pg_temp.pgpm_htail s where", "select %s from pgpm_htail s where", 1)],
    ),
    "transmute_null_arguments_accepted": (
        "bench/null_arguments_refused.sh",
        "Pre-#896 _transmute: no up-front null check, so three-valued logic reads each null as not true: "
        "p_force_frontier, p_force_uuidv7 and p_force_text_time => null act as true, p_incoming_fks => null "
        "leaves the incoming key on the monolith, and p_regrain_batch, p_paused and p_tt_epoch => null commit "
        "the write-rejecting bound before failing. The check is handed its arguments with every null "
        "stripped (two lines of one site). tests/248 parts A to D and tests/249 parts B and C catch it.",
        [("  perform pgpm._refuse_null_arguments('transmute', json_build_object(\n",
          "  perform pgpm._refuse_null_arguments('transmute', json_strip_nulls(json_build_object(\n", 1),
         ("    'p_tt_epoch', p_tt_epoch, 'p_force_frontier', p_force_frontier));\n",
          "    'p_tt_epoch', p_tt_epoch, 'p_force_frontier', p_force_frontier)));\n", 1)],
    ),
    "extend_to_null_arguments_accepted": (
        "bench/null_arguments_refused.sh",
        "Pre-#896 extend_to: no up-front null check, so p_max => null makes every cap test null and a far "
        "p_value is walked step by step, and p_value => null never ends the walk. One site: the check is "
        "handed its arguments with every null stripped. tests/249 part A catches it.",
        [("    json_build_object('p_parent', p_parent, 'p_value', p_value, 'p_max', p_max));\n",
          "    json_strip_nulls(json_build_object('p_parent', p_parent, 'p_value', p_value, 'p_max', p_max)));\n", 1)],
    ),
    "transmute_refuses_null_retain": (
        "bench/null_arguments_refused.sh",
        "Issue #896, the over-correction: every transmute argument is refused when null, p_retain included, "
        "whose null is documented (keep everything) and is also its default, so every conversion that does "
        "not set a retention is refused. One site, the argument list. tests/248 catches it: each refusal "
        "names p_retain too, and the liveness conversions, which pass p_retain => null, are refused.",
        [("    'p_anchor', p_anchor, 'p_obtain', p_obtain, 'p_regrain_batch', p_regrain_batch, 'p_paused', p_paused,\n",
          "    'p_anchor', p_anchor, 'p_obtain', p_obtain, 'p_retain', p_retain, 'p_regrain_batch', p_regrain_batch, 'p_paused', p_paused,\n", 1)],
    ),
    # Issue #890, "Archive object keys" bullet 1: one mutation per site of the whole-key claim. All break
    # bench/archive_key_full_claim.sh through tests/archive/db/40.
    "archive_object_key_whole_unclaimed": (
        "bench/archive_key_full_claim.sh",
        "Pre-#890 key: archive._owned_key claims the key's BASE only, so a synchronous export of an untracked "
        "relation named <table>_<stem> (archive._resolve_child accepts any relation in the parent's schema) "
        "spells <prefix><schema>.<table>_<stem><ext>, a chunk key of <table>, under a base of its own, and "
        "PUTs over the chunk retire() left as the only copy of its rows; the other way round a chunk PUTs over "
        "the export. One site, the one function that assembles every key. tests/archive/db/40 parts A to D "
        "catch it (the chunk object reads 7:export,8:export; the chunk of part B overwrites the export).",
        [("  v_held := archive._claim_object_key(v_key, p_parent, v_kind, v_relation);\n"
          "  if (v_held.parent_oid, v_held.kind) is distinct from (p_parent::oid, v_kind) and v_owner = p_parent::oid then\n"
          "    v_key := v_base_q || '.' || p_parent::oid::text || p_tail;\n"
          "    v_held := archive._claim_object_key(v_key, p_parent, v_kind, v_relation);\n"
          "  end if;\n"
          "  if (v_held.parent_oid, v_held.kind) is distinct from (p_parent::oid, v_kind) then\n",
          "  if false then   -- MUTANT: the whole key is never claimed\n", 1),
         # #976's relation check reads the claim too; with no claim it would refuse every call
         ("  if v_held.relation_oid is distinct from v_relation then\n", "  if false then\n", 1)],
    ),
    "archive_ndjson_gz_outside_claim": (
        "bench/archive_key_full_claim.sh",
        "The NDJSON archive_fn transport asks for its key with the `.ndjson` tail and appends `.gz` after the "
        "claim, the pre-#890 shape, so a compressed chunk claims <key>.ndjson while it writes <key>.ndjson.gz, "
        "and a compressed export spelling that object finds the whole key free and PUTs over it. One site. "
        "tests/archive/db/40 part C catches it (the claim does not name the object; its bytes change).",
        [("  v_key := archive._object_key(p_parent, cfg.prefix, pcfg.control_kind, p_lo,\n"
          "                               case when p_compress then '.ndjson.gz' else '.ndjson' end);\n"
          "  -- #975: never over a recorded chunk this read does not reproduce\n"
          "  perform archive._refuse_recorded_chunk_overwrite('archive_to_s3_ndjson', p_parent, pcfg.control_kind, v_key, p_lo, p_hi, v_rows);\n"
          "  if p_compress then\n",
          "  v_key := archive._object_key(p_parent, cfg.prefix, pcfg.control_kind, p_lo, '.ndjson');\n"
          "  -- #975: never over a recorded chunk this read does not reproduce\n"
          "  perform archive._refuse_recorded_chunk_overwrite('archive_to_s3_ndjson', p_parent, pcfg.control_kind, v_key, p_lo, p_hi, v_rows);\n"
          "  if p_compress then\n"
          "    v_key := v_key || '.gz';   -- MUTANT: after the claim\n", 1)],
    ),
    "archive_object_key_claim_unseeded": (
        "bench/archive_key_full_claim.sh",
        "Install claims no whole key from pgpm.archive_ledger: an installation upgraded to the release with "
        "archive.object_key_claim starts with none, so a chunk archived before the upgrade is unprotected, and "
        "an export whose key spells it PUTs over the only copy of its rows. tests/archive/db/40 part E re-runs "
        "the seed the way a re-install does and requires the claim it makes.",
        [("     where l.s3_key is not null\n"
          "     order by l.s3_key, l.archived_at, l.parent_table::oid\n",
          "     where false\n"
          "     order by l.s3_key, l.archived_at, l.parent_table::oid\n", 1)],
    ),
    # Issue #890, "Reads under RLS" bullet 1: retire()'s crossing DELETE reads the parent as the caller.
    # Breaks bench/retire_crossing_parent_rls.sh through tests/266.
    "retire_crossing_parent_rls_unasked": (
        "bench/retire_crossing_parent_rls.sh",
        "Pre-#890 retire(): the crossing DELETE reads the parent under the caller's row-level security and "
        "nothing asks pgpm._refuse_filtered_reads of the parent first (on a time grid the frontier is now(), "
        "so nothing else reads it). A non-BYPASSRLS owner of a FORCE'd parent deletes only the referenced "
        "rows its policy admits, the declared CASCADE reaches their referencing rows alone, and the detach it "
        "dispatches is refused forever by the hidden keys' references. One site. tests/266 catches it (no "
        "refusal; id 1 and its referencing row are gone; retain_crossing and retain_detach are logged).",
        [("        perform pgpm._refuse_filtered_reads(p_parent, 'delete the referenced rows of a retiring partition from',\n"
          "          'retention would honour the declared ON DELETE for the referencing rows of those alone, and the detach "
          "would then be refused by the others');\n", "", 1)],
    ),
    "regrain_step_retarget_unchecked": (
        "bench/regrain_retarget_in_flight.sh",
        "Issue #905 put back: regrain_step no longer asks whether the run in flight on the child was cut on "
        "the requested step's grid, so the #267 check (which skips the child itself) is all that stands, a "
        "hand regrain_step or regrain() at another target on the child an auto-regrain is splitting mints a "
        "copy overlapping the run's, and every later swap fails 'would overlap' until regrain_cancel. One "
        "site, the call of _regrain_off_grid. tests/261 parts A and B catch it.",
        [("    v_off := pgpm._regrain_off_grid(p_parent, cfg, v_step, v_lo, v_hi);\n",
          "    v_off := null;   -- MUTANT: the run's grid is not asked\n", 1)],
    ),
    "regrain_capture_grant_acl_only": (
        "bench/regrain_capture_owner_grant.sh",
        "Pre-#906 _regrain_capture_grant: INSERT on the delta goes to the roles an ACL of the parent or the "
        "source lists, never to their owners, whose rights are implicit. After ALTER TABLE <parent> OWNER TO "
        "the old owner still owns the source and gets 42501 on the delta on every write into it until the "
        "swap, and a parent re-owned mid-regrain leaves its new owner the same. One site, the owners' arm of "
        "the grantee union. tests/262 catches it at the delta's grantee list and at every owner's write.",
        [("               and att.attacl is not null and a.privilege_type in ('INSERT', 'UPDATE')\n"
          "            union\n"
          "            select c.relowner from pg_class c where c.oid in (p_parent, p_source)) g   -- #906: the owners\n",
          "               and att.attacl is not null and a.privilege_type in ('INSERT', 'UPDATE')) g   -- MUTANT: no owners\n",
          1)],
    ),
    "incoming_fk_orphans_simple_only": (
        "bench/incoming_fk_orphans_match_type.sh",
        "Issue #909, the pre-fix shape: incoming_fk_orphans counts with MATCH SIMPLE's predicate (every key "
        "column non-null and no parent row) for every key, never reading confmatchtype. A MATCH FULL key's "
        "partly-null rows, which VALIDATE refuses, are not counted: the key reads 1 orphan where it has 3, and "
        "0 while VALIDATE still refuses it. One site, the branch on the match type. tests/265 catches it.",
        [("    if c.confmatchtype = 'f' then\n"
          "      v_orphan := format('not (%1$s) and (not (%2$s) or not exists",
          "    if false then\n"
          "      v_orphan := format('not (%1$s) and (not (%2$s) or not exists", 1)],
    ),
    "incoming_fk_orphans_full_everywhere": (
        "bench/incoming_fk_orphans_match_type.sh",
        "Issue #909, the plausible over-fix: apply MATCH FULL's predicate (a partly-null row is an orphan) to "
        "every key. A MATCH SIMPLE key exempts a row with any key column null, so its null-bearing rows are "
        "counted though VALIDATE accepts them: the key reads 3 orphans where it has 2, and never reaches 0 "
        "while it validates. One site, the branch on the match type. tests/265 catches it.",
        [("    if c.confmatchtype = 'f' then\n"
          "      v_orphan := format('not (%1$s) and (not (%2$s) or not exists",
          "    if true then\n"
          "      v_orphan := format('not (%1$s) and (not (%2$s) or not exists", 1)],
    ),
    "acl_carry_drops_grantor": (
        "bench/acl_grantor_owner_partitions.sh",
        "Issue #903, the pre-fix shape: _acl_carry_ddl replays every grant as the converting role, so one a "
        "role made through its grant option is recorded under the owner and its maker's REVOKE on the converted "
        "table takes nothing away. One site, the grantor's replay; transmute's parent, untransmute's restored "
        "table and the hypertable's copy all carry through it. tests/254 parts A, B and D catch it.",
        [("    v_ddl := v_ddl || case when r.by_owner then v_grant_q\n"
          "                           else format('select pgpm._acl_grant_as(%s, %L)', r.grantor, v_grant_q) end;\n",
          "    v_ddl := v_ddl || v_grant_q;   -- MUTANT: every grant replayed by the converting role\n", 1)],
    ),
    "untransmute_acl_reset_spares_owner": (
        "bench/acl_grantor_owner_partitions.sh",
        "Issue #875 bullet 2, the pre-fix shape: untransmute resets the restored table with its own loop, which "
        "revokes only from the grantees the monolith's ACL names, never from the owner, so on a monolith at the "
        "NULL default it revokes nobody and the first replayed grant materialises the owner's implicit "
        "everything, a privilege the owner revoked from itself on the managed table included. The old loop "
        "back in place of _acl_reset, three sites (its two locals, the NULL read, the reset). tests/255 part A "
        "catches it.",
        [("  v_grantdefs text[] := '{}'; v_poldefs text[] := '{}'; v_rls boolean; v_rls_force boolean;\n"
          "  v_g record;\n",
          "  v_grantdefs text[] := '{}'; v_poldefs text[] := '{}'; v_rls boolean; v_rls_force boolean;\n"
          "  v_g record; v_acl_default boolean; v_revoked boolean := false;   -- MUTANT\n", 1),
         ("  select relrowsecurity, relforcerowsecurity into v_rls, v_rls_force\n"
          "    from pg_class where oid = p_parent;\n",
          "  select relrowsecurity, relforcerowsecurity, relacl is null into v_rls, v_rls_force, v_acl_default\n"
          "    from pg_class where oid = p_parent;   -- MUTANT\n", 1),
         ("  foreach v_tdef in array v_grantdefs loop\n"
          "    execute v_tdef;\n"
          "  end loop;\n",
          """  for v_g in   -- MUTANT: the pre-#875 reset, the grantees the ACL names and never the owner
    select a.grantee
      from pg_class c, aclexplode(c.relacl) a where c.oid = v_restored and c.relacl is not null
    union
    select a.grantee
      from pg_attribute att, aclexplode(att.attacl) a
     where att.attrelid = v_restored and att.attnum > 0 and not att.attisdropped and att.attacl is not null
  loop
    execute format('revoke all on %s from %s cascade', v_restored::text,
                   case when v_g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(v_g.grantee)) end);
    v_revoked := true;
  end loop;
  if v_acl_default and v_revoked then
    execute format('grant all on %s to %I', v_restored::text,
                   (select pg_get_userbyid(relowner) from pg_class where oid = v_restored));
  end if;
  foreach v_tdef in array v_grantdefs[2:] loop
    execute v_tdef;
  end loop;
""", 1)],
    ),
    "partition_acl_unreset": (
        "bench/acl_grantor_owner_partitions.sh",
        "Issue #875 bullet 1, the pre-fix shape in _create_partition: a partition obtain, extend_to or "
        "transmute's forward grid mints keeps the maintaining role's ALTER DEFAULT PRIVILEGES, so a role revoked "
        "on the table reads it by naming it. One site. tests/256 catches it on the transmute, obtain and "
        "extend_to partitions.",
        [("  perform pgpm._acl_reset(format('%I.%I', p_nsp, p_name)::regclass, true);   -- #875: the owner's alone\n",
          "", 1)],
    ),
    "regrain_fine_child_acl_unreset": (
        "bench/acl_grantor_owner_partitions.sh",
        "Issue #875 bullet 1, the pre-fix shape in regrain_step: a fine child keeps the default privileges of "
        "the role that ran the regrain, and the swap attaches it so. One site. tests/256 catches it on the "
        "regrain's two fine children. Since #949 the child is minted owner-only at its creation too, so both "
        "resets go (the creation-time one is owned like the parent instead, as before #949).",
        [("      perform pgpm._acl_reset(format('%I.%I', v_sub_nsp, v_sub_name)::regclass, true);   -- #875\n",
          "", 1),
         ("      perform pgpm._scratch_mint(p_parent, format('%I.%I', v_sub_nsp, v_sub_name)::regclass);\n",
          "      perform pgpm._own_like_parent(p_parent, format('%I.%I', v_sub_nsp, v_sub_name)::regclass);   -- MUTANT\n", 1)],
    ),
    "transmute_incoming_gate_accepts_not_valid": (
        "bench/incoming_not_valid_refused.sh",
        "Issue #902, the pre-fix shape: the incoming gate does not look at convalidated, so under 'preserve' "
        "(or 'drop') a NOT VALID incoming key is dropped and recorded by the cutover, re-added NOT VALID by "
        "restore_incoming_fks, and VALIDATEd by maintain's validate_incoming_fks: a clean key is silently "
        "promoted, and one over tolerated orphans logs fail_validate_incoming_fk every five minutes for good. "
        "One site, the NOT VALID arm of pgpm._refuse_unconvertible_keys (the gate transmute shares with "
        "from_hypertable since #959), which covers both of transmute's askings (the preflight and the cutover "
        "under its lock). tests/259 parts A, B and C catch it.",
        [("   where c.confrelid = p_rel and c.contype = 'f' and c.conparentid = 0 and not c.convalidated;\n",
          "   where c.confrelid = p_rel and c.contype = 'f' and c.conparentid = 0 and not c.convalidated and false;\n", 1)],
    ),
    # The shared-preflight lever (#966; issues #951, #952, #959): one mutation per site it changed. The
    # null checks, one site per routine, are generated with their sources and tracks above def main().
    "transmute_null_obtain_unlisted": (
        "bench/shared_preflight_conformance.sh",
        "transmute's p_obtain left out of its null list again (pre-#951): #581's own check answers a null "
        "p_obtain with its own message, so the one refusal every public routine shares does not cover it. "
        "One site, the argument list. tests/268 part A's sweep catches it on both transmute overloads.",
        [("'p_anchor', p_anchor, 'p_obtain', p_obtain, 'p_regrain_batch', p_regrain_batch,",
          "'p_anchor', p_anchor, 'p_regrain_batch', p_regrain_batch,", 1)],
    ),
    "set_retain_refuses_null_retain": (
        "bench/shared_preflight_conformance.sh",
        "The over-correction of #951: set_retain refuses p_retain => null, whose null is documented (keep "
        "everything) and is its default, so retention could no longer be switched off. tests/268 part A's "
        "documented-null assertion catches it.",
        [("perform pgpm._refuse_null_arguments('set_retain', json_build_object('p_parent', p_parent));",
          "perform pgpm._refuse_null_arguments('set_retain', json_build_object('p_parent', p_parent, 'p_retain', p_retain));",
          1)],
    ),
    "id_step_contract_dropped": (
        "bench/shared_preflight_conformance.sh",
        "Issue #952 bullet 1, the pre-fix shape: transmute does not ask _id_step_contract, so a numeric(6,-2) "
        "key with step 10 passes the id-kind preflight, phases 1 and 2 commit the bound CHECK and the claim, "
        "and the cutover's ATTACH (which rounds 2010 to 2000) dies raw on every retry, the table rejecting "
        "every write past hi. One site. tests/268 part B2 catches it.",
        [("    perform pgpm._id_step_contract(p_parent, p_control, p_step, p_anchor);\n", "", 1)],
    ),
    "bound_contract_call_dropped": (
        "bench/shared_preflight_conformance.sh",
        "Issue #952, the pre-fix shape: transmute does not ask _control_bound_contract of the claim's bound, "
        "so a fresh bound past the column's precision (numeric(4,0), hi 10000) commits and dies in the "
        "cutover, and a resumed one is reused as recorded (a pre-#922 claim's hi = NaN completes a monolith "
        "[0, NaN)). One site. tests/268 part B3 and tests/269 parts A and B catch it.",
        [("  perform pgpm._control_bound_contract(p_parent, p_control, p_control_kind, v_lo_native, v_hi_native, v_resumed);\n",
          "", 1)],
    ),
    "bound_contract_finiteness_dropped": (
        "bench/shared_preflight_conformance.sh",
        "Issue #952 bullet 2, half the contract: its finiteness arm skipped, so a resumed claim with hi = NaN "
        "passes (NaN survives the round trip through numeric, and NaN = NaN in PostgreSQL) and the resume "
        "completes a monolith [0, NaN) that takes every future id. tests/269 part A catches it.",
        [("      if v_v::numeric in ('NaN', 'Infinity', '-Infinity') then\n",
          "      if false and v_v::numeric in ('NaN', 'Infinity', '-Infinity') then   -- MUTANT\n", 1)],
    ),
    "bound_contract_representability_dropped": (
        "bench/shared_preflight_conformance.sh",
        "Issue #952, the other half: the round trip through the column's declared type skipped, so a bound "
        "the column cannot hold (numeric(4,0), hi 10000), fresh or recorded, goes on to the cutover's ATTACH "
        "and dies there after the bound has been committed. tests/268 part B3 and tests/269 part B catch it.",
        [("""        begin
          execute format('select %L::%s::numeric', v_v, v_type) into v_back;
          if v_back <> v_v::numeric then
            v_why := format('%s would be stored as %s', v_v, v_back);
          end if;
        exception when others then
          v_why := format('%s cannot be stored in it at all (%s)', v_v, sqlerrm);
        end;
""", "        null;   -- MUTANT: no round trip through the column's type\n", 1)],
    ),
    "incoming_gate_shared_check_dropped": (
        "bench/shared_preflight_conformance.sh",
        "Issue #959's lever undone on the transmute side: _transmute_incoming_gate no longer calls the shared "
        "key gate, so a NOT VALID incoming key under 'preserve' is dropped by the cutover and promoted by the "
        "next tick's validate (#902 put back). One site, the call, which covers both of transmute's askings. "
        "tests/268 part B4 catches it.",
        [("  perform pgpm._refuse_unconvertible_keys(p_parent, 'transmute', 'transmute');\n", "", 1)],
    ),
    "hypertable_preflight_key_gate_dropped": (
        "bench/hypertable_shared_preflight.sh",
        "Issue #959 bullet 1, the pre-fix shape: from_hypertable_preflight never asks the shared key gate, so "
        "a NOT VALID incoming key passes, the copy runs, and the swap drops and records the key for the "
        "handoff to re-add and validate (a clean key promoted, one over tolerated orphans failing every tick). "
        "One site, the preflight's call (the cutover's own asking still stands). tests/timescale/db/50 part B "
        "catches it.",
        [("  -- Asked here, so before the copy, and again by the cutover under its lock. See pgpm._refuse_unconvertible_keys.\n"
          "  perform pgpm._refuse_unconvertible_keys(p_hypertable, 'migrate hypertable', 'from_hypertable');\n",
          "  -- Asked here, so before the copy, and again by the cutover under its lock. See pgpm._refuse_unconvertible_keys.\n",
          1)],
    ),
    "hypertable_cutover_key_gate_dropped": (
        "bench/hypertable_shared_preflight.sh",
        "Issue #959 bullet 1, the window half: the cutover does not ask the shared key gate under its lock, so "
        "a NOT VALID incoming key added after the copy's preflight is dropped and recorded by the swap and "
        "promoted by the handoff. One site. tests/timescale/db/50 part C catches it.",
        [("  -- excludes, so this answer is final. See pgpm._refuse_unconvertible_keys.\n"
          "  perform pgpm._refuse_unconvertible_keys(p_hypertable, 'migrate hypertable', 'from_hypertable');\n",
          "  -- excludes, so this answer is final. See pgpm._refuse_unconvertible_keys.\n", 1)],
    ),
    # The scratch-relation lever (#966 W1: #949, #950, #955): one mutation per site, each putting that site's
    # defect back; bench/scratch_relations.sh runs tests/267 (core) or tests/timescale/db/49 (the module,
    # uninstall.sql) against it.
    "scratch_regrain_delta_minted_default_acl": (
        "bench/scratch_relations.sh",
        "Pre-#949 _regrain_capture_install: the delta is re-owned like the parent but its ACL is never reset, "
        "so it keeps the tick role's ALTER DEFAULT PRIVILEGES and a role they name (on Supabase anon and "
        "authenticated) reads the captured keys of a parent it holds no grant on. tests/267 stage A catches it.",
        [("  perform pgpm._scratch_mint(p_parent, v_delta_reg);\n",
          "  perform pgpm._own_like_parent(p_parent, v_delta_reg);   -- MUTANT: no ACL reset\n", 1)],
    ),
    "scratch_regrain_capture_fn_tick_owner": (
        "bench/scratch_relations.sh",
        "Pre-#950 _regrain_capture_install: the capture function stays owned by the role that ran the prepare "
        "tick, so the role owning the parent when the next regrain re-mints capture cannot drop it, and a "
        "hand-over cannot follow it. tests/267 stages A and C catch it.",
        [("  perform pgpm._scratch_mint_fn(p_parent, format('%I.%I()', v_nsp, v_fn)::regprocedure);\n", "", 1)],
    ),
    "scratch_fine_child_minted_default_acl": (
        "bench/scratch_relations.sh",
        "Pre-#949 regrain_step: a fine child keeps the creating role's default privileges from its CREATE until "
        "its sub-range's last short batch, so between ticks a role they name reads every row copied so far, "
        "past the parent's row security. tests/267 stage A catches it.",
        [("      perform pgpm._scratch_mint(p_parent, format('%I.%I', v_sub_nsp, v_sub_name)::regclass);\n", "", 1)],
    ),
    "scratch_regrain_owner_not_followed": (
        "bench/scratch_relations.sh",
        "Pre-#950 regrain_step: a resuming tick never re-checks the scratch objects' owner, so a table handed to "
        "a new owner mid-regrain leaves its delta, capture function and copies with the old one, and every "
        "tick a non-superuser new owner runs fails 'permission denied' on the delta. tests/267 stages C and D "
        "catch it.",
        [("  perform pgpm._scratch_owner_follow(p_parent, 'the regrain');\n", "", 1)],
    ),
    "scratch_owner_refusal_swallowed": (
        "bench/scratch_relations.sh",
        "_scratch_owner_follow without its refusal: a tick that can neither re-own the old owner's delta nor act "
        "as that owner goes on, and fails 'permission denied' on the delta every tick, which is what an "
        "operator saw before #950 instead of the hand-over step. tests/267 stage D catches it.",
        [("  if cardinality(v_stuck) > 0 then\n", "  if false and cardinality(v_stuck) > 0 then   -- MUTANT: never refuse\n", 1)],
    ),
    "regrain_capture_names_derived_fallback": (
        "bench/scratch_relations.sh",
        "Pre-#955 _regrain_capture_names: with nothing recorded (a parent that never regrained) the delta and "
        "the capture function fall back to the names derived from the parent's, so regrain_cancel TRUNCATEs an "
        "operator's <rel>_pgpm_regrain_delta and untransmute DROPs it with <rel>_pgpm_regrain_capture(). "
        "tests/267 stage B catches it.",
        [("  select * into d from pgpm._regrain_capture_derive(p_parent);\n  nsp := d.nsp;\n",
          "  select * into d from pgpm._regrain_capture_derive(p_parent);\n"
          "  nsp := d.nsp; delta := d.delta; fn := d.fn;   -- MUTANT: the derived names, unconditionally\n", 1)],
    ),
    "hypertable_copy_drops_dest_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_copy (bullet 1, Tier 1): no check on the copy's name, and `drop table if "
        "exists <rel>_pgpm_dest` before building it, so an operator's table of that name is dropped with its "
        "rows. tests/timescale/db/49 stage B catches it.",
        [("  if v_held is not null and v_held is distinct from pgpm._scratch_rel(p_hypertable, 'hypertable_dest') then\n",
          "  if false and v_held is not null and v_held is distinct from pgpm._scratch_rel(p_hypertable, 'hypertable_dest') then\n", 1),
         ("  v_prev := pgpm._scratch_rel(p_hypertable, 'hypertable_dest');\n"
          "  if v_prev is not null and v_prev = to_regclass(format('%I.%I', v_nsp, v_dest)) then\n"
          "    execute format('drop table %s', v_prev::text);\n"
          "  end if;\n",
          "  execute format('drop table if exists %I.%I', v_nsp, v_dest);   -- MUTANT: by name\n", 1)],
    ),
    "hypertable_copy_drops_delta_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_copy (bullet 1, Tier 1): no check on the delta's name, and `drop table if "
        "exists <rel>_pgpm_delta` before a tracking copy builds it, so an operator's table of that name is "
        "dropped with its rows. tests/timescale/db/49 stage B catches it.",
        [("  if v_held is not null and v_held is distinct from pgpm._scratch_rel(p_hypertable, 'hypertable_delta') then\n",
          "  if false and v_held is not null and v_held is distinct from pgpm._scratch_rel(p_hypertable, 'hypertable_delta') then\n", 1),
         ("  v_prev := pgpm._scratch_rel(p_hypertable, 'hypertable_delta');\n"
          "  if v_prev is not null and v_prev = to_regclass(format('%I.%I', v_nsp, v_delta)) then\n"
          "    execute format('drop table %s', v_prev::text);\n"
          "  end if;\n",
          "  if p_track_changes then execute format('drop table if exists %I.%I', v_nsp, v_delta); end if;   -- MUTANT: by name\n", 1)],
    ),
    "hypertable_copy_replaces_fn_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_copy: no check on the capture function's name, and `create or replace "
        "function <rel>_pgpm_delta_fn()`, so an operator's function of that name has its body replaced. "
        "tests/timescale/db/49 stage B catches it.",
        [("  if v_held_fn is not null and v_held_fn::oid is distinct from v_fn then\n",
          "  if false and v_held_fn is not null and v_held_fn::oid is distinct from v_fn then\n", 1),
         ("    execute format('create function %I.%I() returns trigger language plpgsql as $pgpm$\n",
          "    execute format('create or replace function %I.%I() returns trigger language plpgsql as $pgpm$\n", 1)],
    ),
    "hypertable_copy_drops_trigger_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_copy: no check on the capture trigger's name, and `drop trigger if exists "
        "<rel>_pgpm_delta_trg` on the hypertable before creating it, so an operator's trigger of that name is "
        "dropped. tests/timescale/db/49 stage B catches it.",
        [("  if found and v_trg_fn is distinct from v_fn then\n",
          "  if false and found and v_trg_fn is distinct from v_fn then\n", 1),
         ("    perform pgpm._scratch_mint_fn(p_hypertable, format('%I.%I()', v_nsp, v_trgfn)::regprocedure);\n",
          "    perform pgpm._scratch_mint_fn(p_hypertable, format('%I.%I()', v_nsp, v_trgfn)::regprocedure);\n"
          "    execute format('drop trigger if exists %I on %I.%I', v_trg, v_nsp, v_rel);   -- MUTANT: by name\n", 1)],
    ),
    "hypertable_dest_minted_default_acl": (
        "bench/scratch_relations.sh",
        "Pre-#949 from_hypertable_copy (bullet 3): the copy keeps the migrating role's default privileges for "
        "the whole online window (and the migrating role as its owner), so a role they name reads every "
        "copied row of a hypertable it holds no grant on. tests/timescale/db/49 stage A catches it.",
        [("  perform pgpm._scratch_mint(p_hypertable, format('%I.%I', v_nsp, v_dest)::regclass);\n", "", 1)],
    ),
    "hypertable_delta_minted_default_acl": (
        "bench/scratch_relations.sh",
        "Pre-#949 from_hypertable_copy: a tracking copy's delta keeps the migrating role's default privileges "
        "(and that role as its owner), so a role they name reads the keys of every write to the hypertable. "
        "tests/timescale/db/49 stage A catches it.",
        [("    perform pgpm._scratch_mint(p_hypertable, format('%I.%I', v_nsp, v_delta)::regclass);\n", "", 1)],
    ),
    "hypertable_delta_writers_ungranted": (
        "bench/scratch_relations.sh",
        "The delta minted owner-only with no grant for the hypertable's writers: the capture trigger inserts as "
        "the writer, so every write to the hypertable by a role that is not its owner fails 42501 for the "
        "whole online window. tests/timescale/db/49 stage A catches it.",
        [("    perform pgpm._regrain_capture_grant(p_hypertable, format('%I.%I', v_nsp, v_delta)::regclass, p_hypertable);\n", "", 1)],
    ),
    "hypertable_drain_delta_step_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_drain_delta_step: the copy and the delta are <rel>_pgpm_dest and "
        "<rel>_pgpm_delta by name, so with no copy recorded it drains an operator's table of the delta's name, "
        "deleting its rows. tests/timescale/db/49 stage B catches it.",
        [("  v_dest := pgpm._from_hypertable_scratch(p_hypertable, 'hypertable_dest');     -- #955: by record (drain_delta_step)\n"
          "  v_delta := pgpm._from_hypertable_scratch(p_hypertable, 'hypertable_delta');   -- #955: by record (drain_delta_step)\n",
          "  v_dest := v_rel || '_pgpm_dest';    -- MUTANT: by name\n  v_delta := v_rel || '_pgpm_delta';\n", 1)],
    ),
    "hypertable_drain_delta_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_drain_delta: the delta is <rel>_pgpm_delta by name, so with none recorded it "
        "reads an operator's table of that name as the backlog and drives the step at it. "
        "tests/timescale/db/49 stage B catches it (the refusal is not its own).",
        [("  v_dest := pgpm._from_hypertable_scratch(p_hypertable, 'hypertable_dest');     -- #955: by record (drain_delta)\n"
          "  v_delta := pgpm._from_hypertable_scratch(p_hypertable, 'hypertable_delta');   -- #955: by record (drain_delta)\n",
          "  v_dest := v_rel || '_pgpm_dest';    -- MUTANT: by name\n  v_delta := v_rel || '_pgpm_delta';\n", 1)],
    ),
    "hypertable_drain_appends_step_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_drain_appends_step: the copy is <rel>_pgpm_dest by name and nothing checks it "
        "exists, so with no copy recorded it inserts the hypertable's rows into an operator's table of that "
        "name. tests/timescale/db/49 stage B catches it.",
        [("  v_dest := pgpm._from_hypertable_scratch(p_hypertable, 'hypertable_dest');   -- #955: by record (drain_appends_step)\n"
          "  if v_dest is null then\n",
          "  v_dest := v_rel || '_pgpm_dest';   -- MUTANT: by name, unchecked\n  if false then\n", 1)],
    ),
    "hypertable_drain_appends_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_drain_appends: the copy is <rel>_pgpm_dest by name, so with none recorded it "
        "takes an operator's table of that name for the copy, reads its watermark and drives the step at it. "
        "tests/timescale/db/49 stage B catches it (the refusal is not its own).",
        [("  v_dest := pgpm._from_hypertable_scratch(p_hypertable, 'hypertable_dest');   -- #955: by record (drain_appends)\n"
          "  if v_dest is null then\n",
          "  v_dest := v_rel || '_pgpm_dest';   -- MUTANT: by name\n  if to_regclass(format('%I.%I', v_nsp, v_dest)) is null then\n", 1)],
    ),
    "hypertable_cutover_dest_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_cutover: the copy is whatever answers to <rel>_pgpm_dest, so with none "
        "recorded an operator's table of the hypertable's shape is checked as the copy and, holding its rows, "
        "renamed into its place. tests/timescale/db/49 stage B catches it.",
        [("  v_dest := pgpm._from_hypertable_scratch(p_hypertable, 'hypertable_dest');   -- #955: by record (cutover)\n"
          "  v_dest_oid := case when v_dest is not null then format('%I.%I', v_nsp, v_dest)::regclass end;\n",
          "  v_dest := v_rel || '_pgpm_dest';   -- MUTANT: by name\n  v_dest_oid := to_regclass(format('%I.%I', v_nsp, v_dest));\n", 1)],
    ),
    "hypertable_cutover_delta_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_cutover: change tracking is detected by <rel>_pgpm_delta's existence, so after "
        "an append-only copy an operator's table of that name is taken for the change log (its pre-drain "
        "refuses, or its keys reconcile the copy and the swap drops it). tests/timescale/db/49 stage B catches it.",
        [("  v_delta := pgpm._from_hypertable_scratch(p_hypertable, 'hypertable_delta');   -- #955: by record (cutover)\n",
          "  v_delta := v_rel || '_pgpm_delta';   -- MUTANT: by name\n", 1),
         ("  v_track := v_delta is not null;\n",
          "  v_track := to_regclass(format('%I.%I', v_nsp, v_delta)) is not null;\n", 1)],
    ),
    "hypertable_cutover_drops_fn_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#955 from_hypertable_cutover: the swap drops <rel>_pgpm_delta_fn() by the hypertable's CURRENT name, "
        "so after a RENAME since the copy it drops an operator's function of the new name and leaves the "
        "copy's. tests/timescale/db/49 stage B catches it.",
        [("    if v_trgfn_oid is not null and exists (select 1 from pg_proc where oid = v_trgfn_oid) then\n"
          "      execute format('drop function %s', v_trgfn_oid::regprocedure::text);\n"
          "    end if;\n",
          "    execute format('drop function if exists %I.%I()', v_nsp, v_rel || '_pgpm_delta_fn');   -- MUTANT: by name\n", 1)],
    ),
    "hypertable_swap_keeps_scratch_record": (
        "bench/scratch_relations.sh",
        "The swap without forgetting the record: pgpm.scratch keeps naming the copy, which is now the migrated "
        "table (and transmute's monolith), as the hypertable's scratch, where uninstall.sql reads it. "
        "tests/timescale/db/49 stage A catches it.",
        [("  delete from pgpm.scratch where parent_oid = p_hypertable::oid;\n", "", 1)],
    ),
    "uninstall_scratch_record_unread": (
        "bench/scratch_relations.sh",
        "uninstall.sql sweeping by the comments alone (pre-#955): a recorded copy, delta and function whose "
        "comment record is gone are left, the trigger logging every write into a delta nothing drains. "
        "tests/timescale/db/49 stage C catches it.",
        [("      select s.parent_oid, s.kind, s.obj from pgpm.scratch s\n       order by s.kind desc, s.obj\n",
          "      select s.parent_oid, s.kind, s.obj from pgpm.scratch s\n       where false\n"
          "       order by s.kind desc, s.obj\n", 1)],
    ),
    "scratch_upgrade_fill_dropped": (
        "bench/upgrade_in_place.sh",
        "pgpm.scratch with no upgrade fill (#955): a from_hypertable copy made before the record existed is "
        "not recorded by the upgrade, though it carries the module's comment record, so the cutover refuses "
        "it and uninstall.sql's record sweep never sees it. bench/upgrade_in_place.sh's scratch-record "
        "assertion catches it.",
        [(re.compile(r"^-- Upgrade path: a copy made before the record existed is recorded.*?\nend \$\$;\n",
                     re.MULTILINE | re.DOTALL),
          "-- MUTANT: no upgrade fill of pgpm.scratch\n", 1)],
    ),
    # The lever's residue (#969, W1b): one mutation per site, each putting that site's defect back.
    "scratch_upgrade_adopts_namesake": (
        "bench/upgrade_in_place.sh",
        "Pre-#969 #496 upgrade backfill: whatever plain table holds <rel>_pgpm_regrain_delta is recorded as the "
        "parent's regrain delta by its name alone, so a re-run of install.sql (the documented upgrade, on a "
        "fresh install too) adopts an operator's table beside a parent that never regrained, and the next "
        "prepare DROPs it with its rows. The proof that pgpm minted the pair is removed. "
        "bench/upgrade_in_place.sh's namesake assertions catch it (and tests/270).",
        [(REGRAIN_CAPTURE_BACKFILL_PROOF, "", 1)],
    ),
    "scratch_prepare_owner_not_followed": (
        "bench/scratch_relations.sh",
        "Pre-#969 regrain_step: the PREPARE tick tears down the previous run's capture function, delta and copies "
        "without asking whether this session can own them, so after a hand-over every tick the new owner (a "
        "non-superuser) runs fails 'must be owner of function <rel>_pgpm_regrain_capture'. tests/267 stage E "
        "(E1) catches it.",
        [("    perform pgpm._scratch_owner_follow(p_parent, 'the regrain');   -- #969: the prepare tick\n", "", 1)],
    ),
    "scratch_cancel_owner_not_followed": (
        "bench/scratch_relations.sh",
        "Pre-#969 regrain_cancel: it truncates the delta and drops the copies without asking, so after a "
        "hand-over the new owner's cancel fails 'permission denied for table <rel>_pgpm_regrain_delta' instead "
        "of naming the hand-over step. tests/267 stage E (E2) catches it.",
        [("  perform pgpm._scratch_owner_follow(p_parent, 'regrain_cancel');\n", "", 1)],
    ),
    "scratch_reclaim_owner_not_followed": (
        "bench/scratch_relations.sh",
        "Pre-#969 _regrain_reclaim (retire's): it drops the copies and empties the delta of a regrain whose source "
        "retention is dropping without asking, so after a hand-over the retirement fails 'permission denied'. "
        "Both of its checks are removed. tests/267 stage E (E3) catches it.",
        [("    if v_dropped = 0 then perform pgpm._scratch_owner_follow(p_parent, 'the retirement'); end if;\n", "", 1),
         ("    perform pgpm._scratch_owner_follow(p_parent, 'the retirement');   -- #969: before the delta is emptied\n",
          "", 1)],
    ),
    "scratch_untransmute_owner_not_followed": (
        "bench/scratch_relations.sh",
        "Pre-#969 untransmute: it drops the regrain's delta and capture function at the end without asking, so "
        "after a hand-over the new owner's untransmute fails 'must be owner of table'. tests/267 stage E (E4) "
        "catches it.",
        [("  perform pgpm._scratch_owner_follow(p_parent, 'untransmute');\n", "", 1)],
    ),
    "scratch_owner_refusal_not_42501": (
        "bench/scratch_relations.sh",
        "_scratch_owner_follow's refusal raised as P0001 rather than 42501: uninstall.sql's per-parent sweep, "
        "which calls regrain_cancel and handles only insufficient_privilege, then aborts the whole uninstall on "
        "a table handed to a new owner instead of warning and going on. tests/267 stage E pins the SQLSTATE.",
        [("      quote_ident(v_want_n), quote_ident(current_user)\n"
          "      using errcode = 'insufficient_privilege';   -- #969: what it is, so a caller's 42501 handler still sees it\n",
          "      quote_ident(v_want_n), quote_ident(current_user);   -- MUTANT: P0001\n", 1)],
    ),
    "hypertable_carried_ddl_by_name": (
        "bench/scratch_relations.sh",
        "Pre-#969 _from_hypertable_carried_ddl: a trigger whose function is <rel>_pgpm_delta_fn is left out by "
        "that NAME alone, so an operator's own trigger whose function carries it is not carried by an untracked "
        "migration and goes with the hypertable. The proof-gated arm loses its proof. tests/timescale/db/49 "
        "stage D (D1) catches it.",
        [(HT_CAPTURE_ARM_PROOF,
          "       and not (fn.nspname = v_nsp and f.proname = v_rel || '_pgpm_delta_fn')   -- MUTANT: by name\n", 1)],
    ),
    "hypertable_carried_ddl_record_unread": (
        "bench/scratch_relations.sh",
        "_from_hypertable_carried_ddl without pgpm.scratch's record: a tracking copy's capture on a hypertable "
        "renamed since, whose delta's comment the operator replaced, matches neither the proof nor the comment, "
        "is carried, and the replay dies on the function the cutover just dropped. tests/timescale/db/49 stage "
        "D (D2) catches it.",
        [(HT_CAPTURE_ARM_RECORD, "", 1)],
    ),
    "archive_covered_hi_verbatim": (
        "bench/archive_covered_hi_canonical.sh",
        "Pre-#977 _archive_step: the ledger row takes the archive_fn's covered_hi as the strategy wrote it, not "
        "the canonical text of the instant the contract check accepted. An offset-less value checked in a UTC "
        "tick as three hours short of hi reads as past hi from an America/New_York session, and retire() there "
        "drops the partition with rows the strategy was never handed. One site, the canonicalising assignment "
        "and its note. tests/273 parts A and B catch it.",
        [("      -- Record the instant the check above accepted, not the strategy's text (issue #977). The check parsed\n"
          "      -- covered_hi in THIS session, and the ledger row is read back by every other one (retire() from an\n"
          "      -- operator's session, the next chunk's lo, status()): an offset-less value checked here as three hours\n"
          "      -- short of hi, stored verbatim, read as past hi from a session west of UTC, and retire() dropped the\n"
          "      -- partition with the rows of those three hours never archived. The other bounds this row and the\n"
          "      -- check rest on are pgpm's own and already canonical: v_range.lo and v_range.hi come from pgpm.part\n"
          "      -- and from _next_archive_chunk's _ts_text/_col_to_native renders, and _archive_fully_covered compares\n"
          "      -- through _max_hi_native, which is exact over canonical text.\n"
          "      v_result.covered_hi := pgpm._native_text(cfg.control_kind, v_result.covered_hi);\n", "", 1)],
    ),
    # #974: the lever's mint reaches the sequences a minted relation owns. One mutation per site of the class;
    # bench/scratch_sequences.sh runs tests/272 (core) or tests/timescale/db/51 (the module) against it.
    "scratch_mint_sequence_default_acl": (
        "bench/scratch_sequences.sh",
        "Pre-#974 _scratch_mint: the minted relation's ACL is reset but not that of the sequences it owns, so "
        "the regrain delta's pgpm_seq identity sequence keeps the tick role's ALTER DEFAULT PRIVILEGES and a "
        "role they name, holding nothing on the parent, can setval it into duplicate pgpm_seq values: one tick "
        "consumes a key it never applied and the swap drops rows 60..89 with the source. tests/272 catches it.",
        [("  perform pgpm._acl_reset(p_rel, true);\n"
          "  for v_seq in\n"
          "    select d.objid::regclass from pg_depend d join pg_class s on s.oid = d.objid\n"
          "     where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass\n"
          "       and d.refobjid = p_rel and d.deptype in ('a', 'i') and s.relkind = 'S'\n"
          "     order by d.objid\n"
          "  loop\n"
          "    perform pgpm._acl_reset(v_seq, true);\n"
          "  end loop;\n",
          "  perform pgpm._acl_reset(p_rel, true);\n", 1)],
    ),
    "hypertable_delta_sequence_default_acl": (
        "bench/scratch_sequences.sh",
        "Pre-#974 from_hypertable_copy: a tracking copy's delta is re-owned and its own ACL reset, the lever as "
        "it stood, but its pgpm_seq identity sequence keeps the migrating role's default privileges, so a role "
        "they name reads the change counter and can setval the sequence the online drains batch by. "
        "tests/timescale/db/51 catches it.",
        [("    perform pgpm._scratch_mint(p_hypertable, format('%I.%I', v_nsp, v_delta)::regclass);\n",
          "    perform pgpm._own_like_parent(p_hypertable, format('%I.%I', v_nsp, v_delta)::regclass);\n"
          "    perform pgpm._acl_reset(format('%I.%I', v_nsp, v_delta)::regclass, true);\n", 1)],
    ),
    "hypertable_carry_capture_proof_by_current_name": (
        "bench/hypertable_carry_capture_by_provenance.sh",
        "Pre-#988 _from_hypertable_carried_ddl: the proof that a trigger is a capture pgpm 0.6.0 minted (no record, "
        "no comment) derives <x>_pgpm_delta_fn and <x>_pgpm_delta from the hypertable's CURRENT schema and relname, "
        "so after a RENAME or SET SCHEMA the 0.6.0 capture reads as a user trigger, is carried onto the migrated "
        "table and cloned onto every partition, and logs every write into an orphaned delta. "
        "tests/timescale/db/55's r55n and app55.s55 carry the capture and their deltas grow.",
        [(HT_CAPTURE_ARM_PROOF,
          "       and not (fn.nspname = v_nsp and f.proname = v_rel || '_pgpm_delta_fn'   -- #969: 0.6.0's, on proof\n"
          "                and strpos(f.prosrc, format('insert into %I.%I (', v_nsp, v_rel || '_pgpm_delta')) > 0)\n", 1)],
    ),
    "install_drops_surface_unconditionally": (
        "bench/install_keeps_dependent_views.sh",
        "Pre-#983 install.sql: status(), progress(regclass), observe_window(regclass, interval), check_uuidv7 "
        "and check_text_time are dropped unconditionally on every run, whatever is installed, so a view over any "
        "of them makes the documented re-run fail at that drop with PostgreSQL's raw dependency error. One site, "
        "the call of pgpm._surface_prepare(). tests/281 dies at its first re-run, and the guard's stage B stops "
        "at the raw error instead of pgpm's refusal.",
        [("select pgpm._surface_prepare();\n",
          "drop function if exists pgpm.check_uuidv7(regclass, name, int);\n"
          "drop function if exists pgpm.check_text_time(regclass, name, text, int, int, text, int, text, int, timestamptz);\n"
          "drop function if exists pgpm.status();\n"
          "drop function if exists pgpm.progress(regclass);\n"
          "drop function if exists pgpm.observe_window(regclass, interval);\n", 1)],
    ),
    "surface_shape_ignores_result": (
        "bench/install_keeps_dependent_views.sh",
        "pgpm._surface_unreplaceable compares the argument list and the defaults but not the result, so an "
        "installed function whose arguments match its declaration and whose result does not is taken as "
        "replaceable: nothing is refused or dropped up front, the run goes on until that function's CREATE OR "
        "REPLACE rejects the result, and everything the file did before it is done. One site. The guard's "
        "stage B (the marker the file removes near its top is gone) and tests/281 part B catch it.",
        [("      or pg_get_function_identity_arguments(p.oid) <> s.args\n"
          "      or pg_get_function_result(p.oid) <> s.result\n",
          "      or pg_get_function_identity_arguments(p.oid) <> s.args\n", 1)],
    ),
    "text_time_anchor_unit_unchecked": (
        "bench/text_time_anchor_unit.sh",
        "Issue #989, the pre-fix shape: transmute's text_time preflight no longer asks _text_time_unit_contract, "
        "so an anchor half a second off an ObjectId seconds grid (or a step with a sub-unit part) is accepted, "
        "_ts_to_text_time floors every bound to the second, and pgpm.part records bounds half a second above the "
        "catalog's. One site, the call. tests/284 assertions 1 to 4 catch it.",
        [("    -- #989: and an anchor and a step the encoding can express. See _text_time_unit_contract.\n"
          "    perform pgpm._text_time_unit_contract(p_parent, p_control, p_step, p_anchor, p_tt_unit, p_tt_epoch);\n",
          "", 1)],
    ),
    "text_time_unit_unix_epoch": (
        "bench/text_time_anchor_unit.sh",
        "Issue #989, the plausible-but-wrong check: the anchor is measured in whole units from the Unix epoch "
        "rather than from p_tt_epoch, which _ts_to_text_time counts from, so a whole-second anchor against an "
        "epoch carrying a fraction passes and every bound floors to a different instant than the one recorded. "
        "tests/284 assertion 4 catches it.",
        [("  if mod((extract(epoch from p_anchor::timestamptz) - extract(epoch from p_epoch)) * 1000000, v_us) <> 0\n",
          "  if mod(extract(epoch from p_anchor::timestamptz) * 1000000, v_us) <> 0\n", 1)],
    ),
    "text_time_radix_no_lower_bound": (
        "bench/text_time_radix_lower_bound.sh",
        "Issue #990, the pre-fix shape: with p_tt_alphabet supplied, transmute checks only the alphabet's length "
        "and repeats, so p_tt_radix => 1 with alphabet 'x' passes and _radix_encode's div(v, 1) loop never ends: "
        "transmute spins at the frontier encode until statement_timeout. tests/285 assertions 2 and 3 catch it "
        "(the file sets statement_timeout around both, so the mutant fails rather than hangs).",
        [("      if p_tt_radix < 2 then\n"
          "        raise exception 'pg_partition_magician: p_tt_radix must be at least 2 (got %) -- a base-% encoding "
          "has no place value to order bounds by; supply an alphabet of two or more characters, one per digit', "
          "p_tt_radix, p_tt_radix;\n"
          "      end if;\n",
          "", 1)],
    ),
    "transmute_time_unit_contract_dropped": (
        "bench/transmute_step_precision.sh",
        "Issue #1039 bullet 1, the pre-fix shape: transmute's preflight no longer asks _time_unit_contract, so "
        "'500 milliseconds' on a timestamptz(0) key passes, phases 1 and 2 commit and validate the monolith's "
        "bound CHECK, and the cutover's obtain dies on 'empty range bound' with the table rejecting every current "
        "write; '1500 milliseconds' converts with pgpm.part bounds the catalog rounded to other instants. One "
        "site, the call. tests/287 parts A, B, D and E catch it.",
        [("    -- #1039: and a timestamp(p) key holds whole multiples of 10^-p seconds, so the step and the anchor must\n"
          "    -- be too, or the cutover's ATTACH rounds a bound between two of them. See _time_unit_contract.\n"
          "    perform pgpm._time_unit_contract(p_parent, p_control, p_step, p_anchor);\n",
          "    null;\n", 1)],
    ),
    "time_unit_anchor_unchecked": (
        "bench/transmute_step_precision.sh",
        "Issue #1039 bullet 1, the half rule: _time_unit_breach asks the step and not the anchor, so an anchor "
        "half a second off a timestamptz(0) key's seconds converts, every bound pgpm records sits half a second "
        "from the one the catalog rounded it to, and a row in that half second is in a partition whose recorded "
        "range does not hold it. tests/287 part D catches it.",
        [("     or (p_anchor is not null and (extract(epoch from p_anchor::timestamptz) * 1000000) % v_unit_us <> 0) then\n",
          "     then\n", 1)],
    ),
    # pass 9 G17: tests/267 at its three wrong-reason sites (#993) and tests/timescale/db/05's catch-up (#996),
    # each the file's pre-fix text; bench/tests_fail_on_defect.sh judges 267 against the defect each accepted,
    # bench/hypertable_catchup_identity.sh judges 05 (on the timescale track).
    "scratch_suite_delta_owner_after_copy": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#993 tests/267 stage A: the regrain delta's owner is read only after the copy tick, whose "
        "_scratch_owner_follow re-owns it to the parent's owner, so a prepare tick that mints the delta under "
        "the tick's role (the #949 half the file's header promises 'right after the prepare tick') passes every "
        "assertion. The exact pre-fix assertion.",
        [("""select is(:'delta_owner_at_prepare' || '/' || (select pg_get_userbyid(relowner)::text from pg_class where oid = :'delta'::oid),
  'w267_owner/w267_owner',
  'regrain_delta: owned like the parent from the prepare tick that creates it, and after the copy tick');
""", """select is((select pg_get_userbyid(relowner)::text from pg_class where oid = :'delta'::oid), 'w267_owner',
  'regrain_delta: owned like the parent');
""", 1)],
    ),
    "scratch_suite_restored_rows_by_count": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#993 tests/267 stage E4: the table untransmute hands back is judged by count(*) = 299, so a "
        "restored s267i that lost a row and kept the deleted 450 (the key the cancelled regrain captured) "
        "passes. The exact pre-fix assertion.",
        [("""-- the rows by identity, not by count: what the restored table lacks of ids 1..299 ('-') and holds beyond them
-- ('+'), so a lost row offset by the resurrected 450 (the key the cancelled regrain captured) is named
select is(:'untr_i2' || '/' || (select relkind::text from pg_class where oid = 'public.s267i'::regclass)
          || '/' || (select count(*) from pg_class where oid = :'i_delta'::oid)
          || '/' || (select count(*) from pg_proc where oid = :'i_fn'::oid)
          || '/' || coalesce((select string_agg(d, ',' order by d) from (
                       (select '-' || g || ':i' || g as d from generate_series(1, 299) g
                        except select '-' || id || ':' || payload from public.s267i)
                       union all
                       (select '+' || id || ':' || payload from public.s267i
                        except select '+' || g || ':i' || g from generate_series(1, 299) g)) x), 'same'),
  'ok:s267i/r/0/0/same', 'untransmute: after the remedy, s267i is a plain table holding exactly its rows 1..299 (and not the deleted 450), the delta and the function gone');
""", """select is(:'untr_i2' || '/' || (select relkind::text from pg_class where oid = 'public.s267i'::regclass)
          || '/' || (select count(*) from pg_class where oid = :'i_delta'::oid)
          || '/' || (select count(*) from pg_proc where oid = :'i_fn'::oid)
          || '/' || (select count(*) from public.s267i),
  'ok:s267i/r/0/0/299', 'untransmute: after the remedy, s267i is a plain table with its 299 rows, the delta and the function gone');
""", 1)],
    ),
    "scratch_suite_list_tables_only": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#993 tests/267 stage A: 'the list is complete' snapshots and compares pg_class at relkind r and p "
        "only, so a sequence, view or matview the prepare tick mints unrecorded in the parent's schema is no "
        "omission it can see. The exact pre-fix snapshot, comparison and plan.",
        [("select plan(69);\n", "select plan(67);\n", 1),
         ("""-- every relation of every kind (a sequence, a view, a matview is as much an omission as a table), and every
-- function, in the parent's schema before the regrain
create temp table w267_before as
  select oid, 'r' as k from pg_class where relnamespace = 'public'::regnamespace
""", """create temp table w267_before as
  select oid, 'r' as k from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p')
""", 1),
         ("""-- THE LIST AGAINST WHAT WAS CREATED: every new relation in the parent's schema, of whatever kind, is a
-- scratch relation pgpm recorded (pgpm._scratch_objects reads every record: pgpm.config, pgpm.part,
-- pgpm.scratch) or a part of one that PostgreSQL makes and drops with it (its indexes, its identity sequence),
-- and every recorded one is new. Read from the records rather than from a name or a list of kinds, so an
-- unrecorded sequence, view or matview the prepare mints fails here as surely as an unrecorded table.
create temp table w267_new as
  select c.oid, c.relkind::text as kind from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.oid not in (select oid from w267_before where k = 'r');
create temp table w267_recorded as
  select o as oid from unnest((pgpm._scratch_objects('public.s267'::regclass)).rels) o;
select is((select array_agg(distinct kind collate "C" order by kind collate "C") from w267_new), array['S', 'i', 'r'],
  'LIVENESS: the snapshot sees every kind of relation the regrain made, not only tables (the copy''s and the delta''s indexes, the delta''s identity sequence)');
select is(
  (select array_agg(oid order by oid) from w267_new),
  (select array_agg(o order by o) from (
     select oid as o from w267_recorded
     union select i.indexrelid from pg_index i where i.indrelid in (select oid from w267_recorded)
     union select d.objid from pg_depend d
            where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype = 'i'
              and d.refobjid in (select oid from w267_recorded)
              and (select relnamespace from pg_class where oid = d.objid) = 'public'::regnamespace) x),
  'the list is complete: every relation the regrain created, of any kind, is a recorded scratch relation or an index or identity sequence of one');
select ok(array[:'delta'::oid, :'fine'::oid] <@ (select array_agg(oid) from w267_recorded),
  'the list is complete: what is recorded holds the delta (regrain_delta) and the copy (regrain_fine_child)');
""", """-- THE LIST AGAINST WHAT WAS CREATED: every new relation and function in the parent's schema is a recorded
-- scratch object, and every recorded one is new.
select is(
  (select array_agg(c.oid order by c.oid) from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
      and c.oid not in (select oid from w267_before where k = 'r')),
  (select array_agg(o order by o) from unnest(array[:'delta'::oid, :'fine'::oid]) o),
  'the list is complete: the only relations the regrain created are the recorded delta (regrain_delta) and the recorded copy (regrain_fine_child)');
""", 1)],
    ),
    "hypertable_catchup_rows_by_count": (
        "bench/hypertable_catchup_identity.sh",
        "Pre-#996 tests/timescale/db/05: the keyless append-only catch-up judged by count(*) = 245, with no "
        "snapshot of the source, so a migrated table that lost one copied row and held another twice passes. "
        "The exact pre-fix text, plan included.",
        [("""-- late appends between them, asserting they land in the migrated table. The rows are judged by identity
-- against a snapshot of the source taken right before the cutover (a bag: a keyless table can hold a row
-- twice), never by count: a catch-up that lost one copied row and held another twice keeps the count.
-- Autocommit, disposable-db.
select plan(5);
""", """-- late appends between them, asserting they land in the migrated table. Autocommit, disposable-db.
select plan(4);
""", 1),
         ("""-- the source as it stands before the cutover, the 240 copied rows and the 5 late appends: what the migrated
-- table must hold, row for row
create temp table hp_d1_before as select * from hp_d1;
select is((select count(*) || '/' || string_agg(device_id::text, ',' order by device_id) filter (where device_id >= 1000)
             from hp_d1_before),
  '245/1001,1002,1003,1004,1005',
  'LIVENESS: the snapshot holds the 240 copied rows and the 5 late appends, 1001 to 1005');

""", "", 1),
         ("""select bag_eq('select * from hp_d1', 'select * from hp_d1_before',
  'every row of the source, the 240 copied and the 5 late appends, is in the migrated table exactly as often as it was in the source: none lost, none held twice, none altered');
""", """select is((select count(*)::int from hp_d1), 245, 'all 245 rows present (240 copied + 5 late appends)');
""", 1)],
    ),
}

# name -> source file (repo-relative), for mutations that don't touch pgpm_core/install.sql.
# bench/discriminate.sh reads this via --list to know which base file AND which container a
# mutation's guard needs; anything not listed here defaults to the core install + core container.
# The source need not be an install.sql: a guard that judges the TESTS (bench/throws_pinned.sh) has
# its defect put back into the test file it judges, and discriminate.sh hands the guard that mutant
# exactly as it hands the others theirs.
MUTATION_SRC = {
    "throws_ok_null_pattern": "tests/72_transmute_attributes_test.sql",
    "throws_ok_null_pattern_113": "tests/113_pk_excluding_control_refused_test.sql",
    "hypertable_cutover_unverified_source": "pgpm_hypertable/install.sql",
    "hypertable_cutover_unverified_dest": "pgpm_hypertable/install.sql",
    "hypertable_catchup_strict_watermark": "pgpm_hypertable/install.sql",
    "hypertable_cutover_no_conservation": "pgpm_hypertable/install.sql",
    "hypertable_cutover_conservation_by_count": "pgpm_hypertable/install.sql",
    "hypertable_swap_fk_record_after_handoff": "pgpm_hypertable/install.sql",
    "hypertable_swap_identity_from_one": "pgpm_hypertable/install.sql",
    "hypertable_derived_names_unchecked": "pgpm_hypertable/install.sql",
    "hypertable_cutover_untracked_unchecked": "pgpm_hypertable/install.sql",
    "hypertable_cutover_no_horizon_trusted": "pgpm_hypertable/install.sql",
    "hypertable_cutover_refusals_reordered": "pgpm_hypertable/install.sql",
    "hypertable_cutover_no_lock_timeout": "pgpm_hypertable/install.sql",
    "hypertable_handoff_validate_no_lock_timeout": "pgpm_hypertable/install.sql",
    "hypertable_preflight_no_exclusion_check": "pgpm_hypertable/install.sql",
    "hypertable_cutover_no_exclusion_check": "pgpm_hypertable/install.sql",
    "hypertable_cutover_exclusion_unchecked_under_lock": "pgpm_hypertable/install.sql",
    "hypertable_cutover_serial_sequence_kept_by_source": "pgpm_hypertable/install.sql",
    "hypertable_shape_ignores_foreign_keys": "pgpm_hypertable/install.sql",
    "hypertable_index_ddl_by_pattern": "pgpm_hypertable/install.sql",
    "hypertable_tmp_name_cut": "pgpm_hypertable/install.sql",
    "hypertable_handoff_unchecked": "pgpm_hypertable/install.sql",
    "hypertable_empty_watermark_nothing_past": "pgpm_hypertable/install.sql",
    "hypertable_cutover_watermark_timestamptz": "pgpm_hypertable/install.sql",
    "hypertable_chunk_bounds_session_datestyle": "pgpm_hypertable/install.sql",
    "hypertable_ctl_text_session_datestyle": "pgpm_hypertable/install.sql",
    "hypertable_cutover_identity_by_default": "pgpm_hypertable/install.sql",
    "hypertable_cutover_shape_unchecked_up_front": "pgpm_hypertable/install.sql",
    "hypertable_cutover_shape_unchecked_under_lock": "pgpm_hypertable/install.sql",
    "hypertable_cutover_access_not_carried": "pgpm_hypertable/install.sql",
    "hypertable_acl_carry_unreset": "pgpm_hypertable/install.sql",
    "hypertable_cutover_carries_insert_blocker": "pgpm_hypertable/install.sql",
    "hypertable_cutover_carries_capture": "pgpm_hypertable/install.sql",
    "hypertable_carry_capture_by_name": "pgpm_hypertable/install.sql",
    "hypertable_carry_capture_unrecorded": "pgpm_hypertable/install.sql",
    "hypertable_swap_drops_publications": "pgpm_hypertable/install.sql",
    "hypertable_swap_drops_replica_identity": "pgpm_hypertable/install.sql",
    "hypertable_publications_unchecked_up_front": "pgpm_hypertable/install.sql",
    "hypertable_cutover_publications_unchecked": "pgpm_hypertable/install.sql",
    "hypertable_key_index_by_name": "pgpm_hypertable/install.sql",
    "hypertable_key_unchecked": "pgpm_hypertable/install.sql",
    "hypertable_cutover_key_unchecked_under_lock": "pgpm_hypertable/install.sql",
    "hypertable_frontier_unchecked_up_front": "pgpm_hypertable/install.sql",
    "hypertable_cutover_frontier_unchecked": "pgpm_hypertable/install.sql",
    "hypertable_cutover_force_frontier_dropped": "pgpm_hypertable/install.sql",
    "hypertable_force_frontier_not_to_cutover": "pgpm_hypertable/install.sql",
    "archive_lz77_hash_scratch": "pgpm_archive/install.sql",
    "archive_encode_array_agg_unnest": "pgpm_archive/install.sql",
    "archive_deflate_six_arrays": "pgpm_archive/install.sql",
    "archive_encode_raises": "pgpm_archive/install.sql",
    "archive_lz77_range_raises": "pgpm_archive/install.sql",
    "archive_lz77_repeat_differs": "pgpm_archive/install.sql",
    "archive_deflate_raises": "pgpm_archive/install.sql",
    "archive_from_item_raw_splice": "pgpm_archive/install.sql",
    "archive_order_by_raw_splice": "pgpm_archive/install.sql",
    "parquet_per_column_statements": "pgpm_archive/install.sql",
    "archive_encode_no_partition_tz": "pgpm_archive/install.sql",
    "archive_object_key_digits_only": "pgpm_archive/install.sql",
    "archive_object_key_search_path_parent": "pgpm_archive/install.sql",
    "archive_object_key_session_zone": "pgpm_archive/install.sql",
    "archive_object_key_reusable_name": "pgpm_archive/install.sql",
    "archive_object_key_owner_unseeded": "pgpm_archive/install.sql",
    "archive_object_key_whole_unclaimed": "pgpm_archive/install.sql",
    "archive_ndjson_gz_outside_claim": "pgpm_archive/install.sql",
    "archive_object_key_claim_unseeded": "pgpm_archive/install.sql",
    "archive_child_key_unclaimed": "pgpm_archive/install.sql",
    "archive_object_key_unclaimed": "pgpm_archive/install.sql",
    "archive_to_s3_key_inline": "pgpm_archive/install.sql",
    "archive_to_s3_gz_key_inline": "pgpm_archive/install.sql",
    "archive_to_s3_parquet_key_inline": "pgpm_archive/install.sql",
    "archive_ndjson_strategy_key_inline": "pgpm_archive/install.sql",
    "archive_parquet_strategy_key_inline": "pgpm_archive/install.sql",
    "archive_put_site_helper_named_in_comment": "pgpm_archive/install.sql",
    "archive_put_site_verb_in_variable": "pgpm_archive/install.sql",
    "archive_to_s3_parquet_second_put_inline": "pgpm_archive/install.sql",
    "archive_key_prefix_by_subquery": "pgpm_archive/install.sql",
    "archive_key_prefix_by_renamed_param": "pgpm_archive/install.sql",
    "archive_key_prefix_by_execute": "pgpm_archive/install.sql",
    "archive_object_stem_drops_era": "pgpm_archive/install.sql",
    "sigv4_transaction_start_stamp": "pgpm_archive/install.sql",
    "to_s3_compress_unread": "pgpm_archive/install.sql",
    "parquet_numeric_scale_unsigned": "pgpm_archive/install.sql",
    "parquet_timestamp_no_infinity": "pgpm_archive/install.sql",
    "parquet_timestamp_no_ceiling": "pgpm_archive/install.sql",
    "parquet_decimal_scale_above_precision": "pgpm_archive/install.sql",
    "parquet_range_refuses_keyless": "pgpm_archive/install.sql",
    "archive_huffman_temp_table": "pgpm_archive/install.sql",
    "uninstall_drops_pending_fk": "pgpm_core/uninstall.sql",
    "uninstall_keeps_regrain_copies": "pgpm_core/uninstall.sql",
    "uninstall_keeps_hypertable_capture": "pgpm_core/uninstall.sql",
    "uninstall_hypertable_capture_by_name": "pgpm_core/uninstall.sql",
    "uninstall_keeps_hypertable_copy": "pgpm_core/uninstall.sql",
    "uninstall_hypertable_copy_by_name": "pgpm_core/uninstall.sql",
    "uninstall_drops_orphaned_copy": "pgpm_core/uninstall.sql",
    "hypertable_swap_keeps_copy_record": "pgpm_hypertable/install.sql",
    "uninstall_fk_exempt_by_name": "pgpm_core/uninstall.sql",
    "hypertable_copy_key_tmp_by_name": "pgpm_hypertable/install.sql",
    "hypertable_cutover_key_tmp_unshared": "pgpm_hypertable/install.sql",
    "to_s3_part_bytes_unbounded": "pgpm_archive/install.sql",
    "to_s3_abort_misses_cancel": "pgpm_archive/install.sql",
    "to_s3_conservation_by_count": "pgpm_archive/install.sql",
    "to_s3_initiate_orphan_unaborted": "pgpm_archive/install.sql",
    "configure_part_bytes_under_s3_min": "pgpm_archive/install.sql",
    "configure_fetch_rows_unbounded": "pgpm_archive/install.sql",
    "signer_text_sends_server_encoding": "pgpm_archive/install.sql",
    "to_s3_sync_key_bare_child": "pgpm_archive/install.sql",
    "parquet_tstz_no_logical_type": "pgpm_archive/install.sql",
    "abort_sweep_one_page": "pgpm_archive/install.sql",
    "abort_sweep_no_exact_key_filter": "pgpm_archive/install.sql",
    "parquet_decimal_nan_raises": "pgpm_archive/install.sql",
    "archive_ndjson_single_float_digits_unpinned": "pgpm_archive/install.sql",
    "to_s3_float_digits_unpinned": "pgpm_archive/install.sql",
    "parquet_array_float_digits_unpinned": "pgpm_archive/install.sql",
    "archive_ndjson_single_row_alias_shadowed": "pgpm_archive/install.sql",
    "to_s3_row_alias_shadowed": "pgpm_archive/install.sql",
    "to_s3_fingerprint_row_alias_shadowed": "pgpm_archive/install.sql",
    "to_s3_cursor_session_text": "pgpm_archive/install.sql",
    "parquet_snapshot_per_encode_table": "pgpm_archive/install.sql",
    # The harness and review tooling guard themselves too (#598 to #601): their defects live in the
    # scripts, a doc and a test file, so that is what these mutate.
    "keep_both_two_way_only": "scripts/review/keep_both.py",
    "onboarding_ts_versions": "ONBOARDING.md",
    "onboarding_unread_knob_first": "ONBOARDING.md",
    "runbook_retain_count_of_intervals": "docs/runbook.md",
    "reference_archive_identity_forget_missing": "docs/reference.md",
    "reference_fks_suspended_dead_swap": "docs/reference.md",
    "reference_keyless_monolith_dormant": "docs/reference.md",
    "readme_transmute_fresh_default": "README.md",
    "runbook_fk_validate_by_restore": "docs/runbook.md",
    "runbook_dropped_table_syntax_symptom": "docs/runbook.md",
    "classify_tap_needs_description": "scripts/review/classify_claims.py",
    "classify_sh_exit_code_only": "scripts/review/classify_claims.py",
    "classify_premise_bare_word": "scripts/review/classify_claims.py",
    "throws_ok_one_argument": "tests/72_transmute_attributes_test.sql",
    "throws_ilike_unpinned": "tests/72_transmute_attributes_test.sql",
    "throws_ok_null_pattern_var_desc": "tests/72_transmute_attributes_test.sql",
    "tap_verdict_misses_plan_shortfall": "test.sh",
    "tap_verdict_ignores_psql_exit": "test.sh",
    "tap_verdict_reads_finish_only": "test.sh",
    "tap_verdict_count_ends_track": "test.sh",
    # #917: a guard with mutations left out of every track's clean-code run.
    "clean_run_perf_entry_dropped": "test.sh",
    "clean_run_timescale_call_commented": "test.sh",
    # #795 and #712: a timescale wrapper's own verdict block, judged by the guard that evaluates it.
    "wrapper_verdict_reads_finish_only": "bench/hypertable_index_names.sh",
    "wrapper_verdict_no_shortfall_check": "bench/hypertable_late_appends.sh",
    "wrapper_verdict_ignores_exit": "bench/hypertable_cutover_identity.sh",
    "wrapper_verdict_time_rendering_hand_rolled": "bench/hypertable_time_rendering.sh",
    "discriminate_counts_uninstallable": "bench/discriminate.sh",
    "discriminate_list_on_stdin": "bench/discriminate.sh",
    "discriminate_counts_liveness_only": "bench/discriminate.sh",
    # #742 to #744: a lint's document and three test files, each judged by the guard that runs it.
    "runbook_phantom_alert_action": "docs/runbook.md",
    "runbook_alert_on_method": "docs/runbook.md",
    "orphan_refusal_sqlstate_only": "tests/18_orphan_child_guard_test.sql",
    "radix_length_refusal_unpinned": "tests/90_text_time_alphabet_codec_test.sql",
    "id_conservation_after_migration": "tests/11_id_kind_test.sql",
    "uuid_conservation_after_migration": "tests/12_uuidv7_kind_test.sql",
    "regrain_survivors_by_count": "tests/92_regrain_outgoing_fk_test.sql",
    # #881: text_time's drought immunity, judged by the same guard against a text_time-only frontier mutant.
    "text_time_drought_coverage_only": "tests/88_text_time_transmute_test.sql",
    "text_time_drought_coverage_only_ulid_ksuid": "tests/91_text_time_ulid_ksuid_transmute_test.sql",
    "hypertable_preflight_reads_under_caller_rls": "pgpm_hypertable/install.sql",
    "hypertable_cutover_reads_under_caller_rls": "pgpm_hypertable/install.sql",
    "rls_to_s3_unchecked": "pgpm_archive/install.sql",
    "rls_to_s3_parquet_unchecked": "pgpm_archive/install.sql",
    "rls_archive_ndjson_unchecked": "pgpm_archive/install.sql",
    "rls_archive_parquet_unchecked": "pgpm_archive/install.sql",
    "rls_cutover_unchecked_under_lock": "pgpm_hypertable/install.sql",
    "rls_drain_appends_step_unchecked": "pgpm_hypertable/install.sql",
    "rls_drain_appends_unchecked": "pgpm_hypertable/install.sql",
    "rls_drain_delta_step_unchecked": "pgpm_hypertable/install.sql",
    "hypertable_scratch_dbatch_drop_unqualified": "pgpm_hypertable/install.sql",
    "hypertable_scratch_htail_drop_unqualified": "pgpm_hypertable/install.sql",
    "hypertable_scratch_reads_unqualified": "pgpm_hypertable/install.sql",
    # #966 W1, the scratch-relation lever
    "hypertable_copy_drops_dest_by_name": "pgpm_hypertable/install.sql",
    "hypertable_copy_drops_delta_by_name": "pgpm_hypertable/install.sql",
    "hypertable_copy_replaces_fn_by_name": "pgpm_hypertable/install.sql",
    "hypertable_copy_drops_trigger_by_name": "pgpm_hypertable/install.sql",
    "hypertable_dest_minted_default_acl": "pgpm_hypertable/install.sql",
    "hypertable_delta_minted_default_acl": "pgpm_hypertable/install.sql",
    "hypertable_delta_writers_ungranted": "pgpm_hypertable/install.sql",
    "hypertable_drain_delta_step_by_name": "pgpm_hypertable/install.sql",
    "hypertable_drain_delta_by_name": "pgpm_hypertable/install.sql",
    "hypertable_drain_appends_step_by_name": "pgpm_hypertable/install.sql",
    "hypertable_drain_appends_by_name": "pgpm_hypertable/install.sql",
    "hypertable_cutover_dest_by_name": "pgpm_hypertable/install.sql",
    "hypertable_cutover_delta_by_name": "pgpm_hypertable/install.sql",
    "hypertable_cutover_drops_fn_by_name": "pgpm_hypertable/install.sql",
    "hypertable_swap_keeps_scratch_record": "pgpm_hypertable/install.sql",
    "uninstall_scratch_record_unread": "pgpm_core/uninstall.sql",
    "hypertable_carried_ddl_by_name": "pgpm_hypertable/install.sql",
    "hypertable_carried_ddl_record_unread": "pgpm_hypertable/install.sql",
    "hypertable_carry_capture_proof_by_current_name": "pgpm_hypertable/install.sql",
    # pass 9 G17
    "scratch_suite_delta_owner_after_copy": "tests/267_scratch_relations_test.sql",
    "scratch_suite_restored_rows_by_count": "tests/267_scratch_relations_test.sql",
    "scratch_suite_list_tables_only": "tests/267_scratch_relations_test.sql",
    "hypertable_catchup_rows_by_count": "tests/timescale/db/05_from_hypertable_catchup_test.sql",
}

# name -> the CI track whose job runs it; anything not listed here belongs to the default `perf`
# track, which is what `./test.sh discriminate` runs.
#
# This exists so one mutation framework can serve a track that not every machine can run.
# bench/lock_trace.sh needs eBPF, which needs a privileged container and host kernel headers --
# available on Linux and on GitHub's runners, and structurally impossible on Docker Desktop for Mac,
# whose linuxkit VM publishes no headers for its own kernel. Issue #383 is explicit that local
# development must not start requiring that on any platform. Listing the mutation here keeps it out
# of the default listing, so `./test.sh discriminate` stays runnable on a laptop, while
# `--track=locktrace` still runs it under the same mutate/assert-it-FAILS machinery as every other
# guard. A track of its own, not an exemption: the mutation is still mandatory, still built from the
# same patterns, and still has to break its guard.
MUTATION_TRACK = {
    "maintain_no_commits_trace": "locktrace",
    # The hypertable cutover's guard needs a real TimescaleDB, which is a separate image and a
    # separate track for the same reason locktrace is: `./test.sh discriminate` must stay runnable
    # without it. run_timescale invokes these while its own container is already up.
    "hypertable_cutover_unverified_source": "timescale",
    "hypertable_cutover_unverified_dest": "timescale",
    "hypertable_catchup_strict_watermark": "timescale",
    "hypertable_cutover_no_conservation": "timescale",
    "hypertable_derived_names_unchecked": "timescale",
    "hypertable_cutover_untracked_unchecked": "timescale",
    "hypertable_cutover_no_horizon_trusted": "timescale",
    "hypertable_cutover_refusals_reordered": "timescale",
    "hypertable_cutover_conservation_by_count": "timescale",
    "hypertable_preflight_no_exclusion_check": "timescale",
    "hypertable_cutover_no_exclusion_check": "timescale",
    "hypertable_cutover_exclusion_unchecked_under_lock": "timescale",
    "hypertable_cutover_serial_sequence_kept_by_source": "timescale",
    "hypertable_shape_ignores_foreign_keys": "timescale",
    "hypertable_index_ddl_by_pattern": "timescale",
    "hypertable_tmp_name_cut": "timescale",
    "hypertable_handoff_unchecked": "timescale",
    "hypertable_empty_watermark_nothing_past": "timescale",
    "hypertable_cutover_watermark_timestamptz": "timescale",
    "hypertable_chunk_bounds_session_datestyle": "timescale",
    "hypertable_ctl_text_session_datestyle": "timescale",
    "hypertable_cutover_identity_by_default": "timescale",
    "hypertable_cutover_shape_unchecked_up_front": "timescale",
    "hypertable_cutover_shape_unchecked_under_lock": "timescale",
    "hypertable_cutover_access_not_carried": "timescale",
    "hypertable_cutover_carries_insert_blocker": "timescale",
    "hypertable_cutover_carries_capture": "timescale",
    "hypertable_acl_carry_unreset": "timescale",
    "hypertable_carry_capture_by_name": "timescale",
    "hypertable_carry_capture_unrecorded": "timescale",
    "hypertable_swap_drops_publications": "timescale",
    "hypertable_swap_drops_replica_identity": "timescale",
    "hypertable_publications_unchecked_up_front": "timescale",
    "hypertable_cutover_publications_unchecked": "timescale",
    "hypertable_key_index_by_name": "timescale",
    "hypertable_copy_key_tmp_by_name": "timescale",
    "hypertable_cutover_key_tmp_unshared": "timescale",
    "hypertable_key_unchecked": "timescale",
    "hypertable_cutover_key_unchecked_under_lock": "timescale",
    "hypertable_frontier_unchecked_up_front": "timescale",
    "hypertable_cutover_frontier_unchecked": "timescale",
    "hypertable_cutover_force_frontier_dropped": "timescale",
    "hypertable_force_frontier_not_to_cutover": "timescale",
    # A core uninstall.sql mutation on this track because the capture it must sweep exists only where
    # from_hypertable_copy can run, which needs a real TimescaleDB.
    "uninstall_keeps_hypertable_capture": "timescale",
    "uninstall_hypertable_capture_by_name": "timescale",
    # #773's, the same reason: the copy it must sweep exists only where from_hypertable_copy can run.
    "uninstall_keeps_hypertable_copy": "timescale",
    "uninstall_hypertable_copy_by_name": "timescale",
    "uninstall_drops_orphaned_copy": "timescale",
    "hypertable_swap_keeps_copy_record": "timescale",
    "hypertable_preflight_reads_under_caller_rls": "timescale",
    "hypertable_cutover_reads_under_caller_rls": "timescale",
    "rls_cutover_unchecked_under_lock": "timescale",
    "rls_drain_appends_step_unchecked": "timescale",
    "rls_drain_appends_unchecked": "timescale",
    "rls_drain_delta_step_unchecked": "timescale",
    "hypertable_scratch_dbatch_drop_unqualified": "timescale",
    "hypertable_scratch_htail_drop_unqualified": "timescale",
    "hypertable_scratch_reads_unqualified": "timescale",
    # #966 W1: the module's sites, and uninstall.sql's, exist only where from_hypertable_copy can run
    "hypertable_copy_drops_dest_by_name": "timescale",
    "hypertable_copy_drops_delta_by_name": "timescale",
    "hypertable_copy_replaces_fn_by_name": "timescale",
    "hypertable_copy_drops_trigger_by_name": "timescale",
    "hypertable_dest_minted_default_acl": "timescale",
    "hypertable_delta_minted_default_acl": "timescale",
    "hypertable_delta_writers_ungranted": "timescale",
    "hypertable_drain_delta_step_by_name": "timescale",
    "hypertable_drain_delta_by_name": "timescale",
    "hypertable_drain_appends_step_by_name": "timescale",
    "hypertable_drain_appends_by_name": "timescale",
    "hypertable_cutover_dest_by_name": "timescale",
    "hypertable_cutover_delta_by_name": "timescale",
    "hypertable_cutover_drops_fn_by_name": "timescale",
    "hypertable_swap_keeps_scratch_record": "timescale",
    "uninstall_scratch_record_unread": "timescale",
    "hypertable_carried_ddl_by_name": "timescale",
    "hypertable_carried_ddl_record_unread": "timescale",
    "hypertable_carry_capture_proof_by_current_name": "timescale",
    # pass 9 G17
    "hypertable_catchup_rows_by_count": "timescale",
}


# The shared-preflight lever (#966; issues #951, #952, #959). One mutation per site it changed, each putting
# that site's defect back. The null checks are one site per routine, all of one shape, so they are generated:
# each neutralises the routine's up-front pgpm._refuse_null_arguments call by handing the same arguments to
# json_build_array, which evaluates them and refuses nothing (the pre-#951 shape: the null reaches whatever
# the routine does next). The core's are caught by tests/268 part A's catalog sweep (bench/
# shared_preflight_conformance.sh), the module's by tests/timescale/db/50 part A's (bench/
# hypertable_shared_preflight.sh, on the timescale track).
_NULL_REFUSAL_CORE = (
    "obtain", "retire", "retain", "regrain_cancel", "regrain_step", "regrain", "regrain_history",
    "transmute_abort", "untransmute", "set_regrain", "set_obtain", "set_retain", "set_partition_tz",
    "set_archive_fn", "resume", "pause", "maintain", "maintain_obtain", "schedule", "check_uuidv7",
    "check_text_time", "check_time_monotonic", "impact_report", "restore_incoming_fks", "validate_incoming_fks",
    "incoming_fk_orphans", "suspend_incoming_fks", "observe_window",
)
_NULL_REFUSAL_HYPERTABLE = (
    "from_hypertable_disk_estimate", "from_hypertable_time_estimate", "from_hypertable_preflight",
    "from_hypertable_copy", "from_hypertable_drain_delta_step", "from_hypertable_drain_delta",
    "from_hypertable_drain_appends_step", "from_hypertable_drain_appends", "from_hypertable_cutover",
    "from_hypertable",
)
for _r in _NULL_REFUSAL_CORE:
    _lead = "select" if _r == "observe_window" else "perform"   # observe_window is a SQL function
    MUTATIONS[f"null_refusal_dropped_{_r}"] = (
        "bench/shared_preflight_conformance.sh",
        f"Pre-#951 pgpm.{_r}: no up-front null check, so a null argument with no meaning reaches what the "
        f"routine does next (three-valued logic reads it as not true, or it splices into SQL, or it matches "
        f"nothing). One site, the routine's _refuse_null_arguments call, neutralised. tests/268 part A's "
        f"catalog sweep catches it" + (", and part A1 (p_force => null drops the live key)"
                                       if _r == "suspend_incoming_fks" else "") + ".",
        [(f"  {_lead} pgpm._refuse_null_arguments('{_r}',", f"  {_lead} json_build_array('{_r}',", 1)],
    )
for _r in _NULL_REFUSAL_HYPERTABLE:
    MUTATIONS[f"null_refusal_dropped_{_r}"] = (
        "bench/hypertable_shared_preflight.sh",
        f"Pre-#951 pgpm.{_r}: no up-front null check, so a null argument with no meaning reaches what the "
        f"routine does next (from_hypertable's p_paused => null was refused by transmute only after the swap "
        f"had dropped the hypertable; p_lock_timeout => null left the swap's lock wait unbounded). One site, "
        f"the routine's _refuse_null_arguments call, neutralised. tests/timescale/db/50 part A's catalog sweep "
        f"catches it" + (", and part A1" if _r == "from_hypertable" else "") + ".",
        [(f"  perform pgpm._refuse_null_arguments('{_r}',", f"  perform json_build_array('{_r}',", 1)],
    )
MUTATION_SRC.update({f"null_refusal_dropped_{_r}": "pgpm_hypertable/install.sql" for _r in _NULL_REFUSAL_HYPERTABLE})
MUTATION_SRC.update({"hypertable_preflight_key_gate_dropped": "pgpm_hypertable/install.sql",
                     "hypertable_cutover_key_gate_dropped": "pgpm_hypertable/install.sql"})
MUTATION_TRACK.update({f"null_refusal_dropped_{_r}": "timescale" for _r in _NULL_REFUSAL_HYPERTABLE})
MUTATION_TRACK.update({"hypertable_preflight_key_gate_dropped": "timescale",
                       "hypertable_cutover_key_gate_dropped": "timescale"})
MUTATION_SRC["hypertable_delta_sequence_default_acl"] = "pgpm_hypertable/install.sql"   # #974
MUTATION_TRACK["hypertable_delta_sequence_default_acl"] = "timescale"

# The shared-preflight lever's residue (#969 bullet 9): pgpm_archive's public routines. One mutation per routine,
# each neutralising its up-front pgpm._refuse_null_arguments call the way the core's are (above), and one per
# site of the archive_fn strategies' empty-range refusal. All are caught by tests/archive/db/41
# (bench/archive_null_arguments.sh, against the archive image and MinIO): part A's catalog sweep for the null
# checks, part B's read-back of the objects [1, 10) was archived to for the strategies'.
_NULL_REFUSAL_ARCHIVE = (
    # (name the refusal gives the routine, mutation name, the routine's lead keyword)
    ("archive.configure", "archive_null_refusal_dropped_configure", "perform"),
    ("archive.unconfigure", "archive_null_refusal_dropped_unconfigure", "perform"),
    ("archive.s3_url_encode", "archive_null_refusal_dropped_s3_url_encode", "select"),   # a SQL function
    ("archive.s3_signed_request", "archive_null_refusal_dropped_s3_signed_request", "perform"),
    ("archive.s3_signed_request_bytea", "archive_null_refusal_dropped_s3_signed_request_bytea", "perform"),
    ("archive.to_s3", "archive_null_refusal_dropped_to_s3", "perform"),
    ("archive.to_s3_parquet", "archive_null_refusal_dropped_to_s3_parquet", "perform"),
    ("archive_to_s3_ndjson", "null_refusal_dropped_archive_to_s3_ndjson", "perform"),
    ("archive_to_s3_parquet", "null_refusal_dropped_archive_to_s3_parquet", "perform"),
)
for _label, _name, _lead in _NULL_REFUSAL_ARCHIVE:
    MUTATIONS[_name] = (
        "bench/archive_null_arguments.sh",
        f"Pre-#969 {_label if '.' in _label else 'pgpm.' + _label}: no up-front null check, so a null argument with no "
        f"meaning reaches what the routine does next (a strategy's null p_hi read no row and PUT an empty object "
        f"over the key [lo, hi) was archived to; a null p_lo died raw on archive.object_key_claim's NOT NULL; a "
        f"signer's null made the request or its signature null). One site, the routine's _refuse_null_arguments "
        f"call, neutralised. tests/archive/db/41 part A's catalog sweep catches it"
        + (", and part B (the object [1, 10) was archived to is overwritten)" if "." not in _label else "") + ".",
        [(f"  {_lead} pgpm._refuse_null_arguments('{_label}',", f"  {_lead} json_build_array('{_label}',", 1)],
    )
    MUTATION_SRC[_name] = "pgpm_archive/install.sql"
for _fmt in ("ndjson", "parquet"):
    MUTATIONS[f"archive_{_fmt}_empty_range_unrefused"] = (
        "bench/archive_null_arguments.sh",
        f"Pre-#969 pgpm.archive_to_s3_{_fmt}: no range check, so a direct call for [lo, lo) or [lo, below lo) "
        f"reads no row and PUTs an empty object over the key the chunk [lo, hi) was archived to (the key is "
        f"derived from lo alone), which after retire() is the only copy of its rows. One site, the strategy's "
        f"call of archive._refuse_empty_range. tests/archive/db/41 part B catches it (the object no longer holds "
        f"what its PUT wrote).",
        [(f"  perform archive._refuse_empty_range('archive_to_s3_{_fmt}', p_parent, p_lo, p_hi);\n", "", 1)],
    )
    MUTATION_SRC[f"archive_{_fmt}_empty_range_unrefused"] = "pgpm_archive/install.sql"
MUTATIONS["archive_empty_range_compared_as_text"] = (
    "bench/archive_null_arguments.sh",
    "archive._refuse_empty_range compares the bounds as text, not as the grid's native type: on an id grid '10' "
    "sorts before '9', so the chunk [9, 10) is refused as inverted and a strategy can no longer archive it (and "
    "an inverted numeric range such as [10, 9) would pass). One site. tests/archive/db/41 part B's control "
    "catches it ([9, 10) archives row 9).",
    [("  if not pgpm._native_gt(v_kind, p_hi, p_lo) then\n", "  if not (p_hi > p_lo) then   -- MUTANT: as text\n", 1)],
)
MUTATION_SRC["archive_empty_range_compared_as_text"] = "pgpm_archive/install.sql"
# #979 and #986: the hypertable module's steps (every drain, drain step and the cutover) re-sync the delta's
# writer grants and follow the hypertable's owner first, through _from_hypertable_scratch_follow. One mutation
# per half, each at the helper, so it takes the half away from every step at once.
MUTATIONS["hypertable_delta_grants_not_resynced"] = (
    "bench/hypertable_delta_writer_grants.sh",
    "Pre-#979 pgpm_hypertable: the tracking delta's INSERT grants are the ones from_hypertable_copy made for "
    "the writers it saw, and no drain or cutover grants again, so a role granted DML on the hypertable during "
    "the online window has every write refused 'permission denied for table <rel>_pgpm_delta' by the capture "
    "trigger until the cutover. _from_hypertable_scratch_follow keeps the owner half and drops the grant "
    "re-sync; tests/timescale/db/52 fails where the late writers write after the next step.",
    [("  if v_delta is not null then\n    perform pgpm._regrain_capture_grant(p_hypertable, v_delta, p_hypertable);\n  end if;\n",
      "  if v_delta is null then\n    return;\n  end if;\n", 1)],
)
MUTATION_SRC["hypertable_delta_grants_not_resynced"] = "pgpm_hypertable/install.sql"
MUTATION_TRACK["hypertable_delta_grants_not_resynced"] = "timescale"
MUTATIONS["hypertable_drains_owner_not_followed"] = (
    "bench/hypertable_scratch_owner_follow.sh",
    "Pre-#986 pgpm_hypertable: no drain, drain step or cutover calls _scratch_owner_follow, so after ALTER "
    "TABLE <hypertable> OWNER TO the new owner's step dies raw 'permission denied for table <rel>_pgpm_delta' "
    "(or _pgpm_dest) on the old owner's object, naming no remedy, instead of the up-front 42501 refusal that "
    "leads with pgpm.hand_over_scratch. _from_hypertable_scratch_follow keeps the grant half and drops the "
    "follow; every refusal in part A of tests/timescale/db/53 fails.",
    [("  perform pgpm._scratch_owner_follow(p_hypertable, p_what);\n  v_delta := pgpm._scratch_rel(p_hypertable, 'hypertable_delta');\n",
      "  v_delta := pgpm._scratch_rel(p_hypertable, 'hypertable_delta');\n", 1)],
)
MUTATION_SRC["hypertable_drains_owner_not_followed"] = "pgpm_hypertable/install.sql"
MUTATION_TRACK["hypertable_drains_owner_not_followed"] = "timescale"
# #987: hand_over_scratch refuses when the follow left any object with another owner. The plausible wrong fix
# applies the follow's rule for a tick (go on while this session can act as that owner) to the hand-over too.
MUTATIONS["hand_over_scratch_unverified"] = (
    "bench/hand_over_scratch_reports.sh",
    "Pre-#987 pgpm.hand_over_scratch: an object the follow could not hand over is let through whenever this "
    "session can act as its owner, the rule _scratch_owner_follow applies for a tick, so a member of the old "
    "owner alone (the old owner itself included) hands nothing over and is not refused. Part A of tests/276 "
    "fails (no exception where 42501 is pinned).",
    [("  if cardinality(v_left) > 0 then\n",
      "  if cardinality(v_left) > 0 and not pg_has_role(current_user, v_left[1], 'USAGE') then\n", 1)],
)

# Issue #976: an export's whole-key claim names the relation it exports. One mutation per site, both caught by
# tests/archive/db/43 (bench/archive_export_key_by_relation.sh, against the archive image and MinIO).
MUTATIONS["archive_export_claim_relation_unchecked"] = (
    "bench/archive_export_key_by_relation.sh",
    "Pre-#976 archive._owned_key: the claim is checked by parent and kind only, so after archive.to_s3 of a "
    "relation, its DROP and a new relation taking its name, the same parent's export of the new one reads as a "
    "re-run and PUTs over the first export, the only copy of the dropped relation's rows. One site, the "
    "relation check. tests/archive/db/43 parts A to C catch it (the namesake's export is not refused, and the "
    "first object then holds 10:second,11:second).",
    [("  if v_held.relation_oid is distinct from v_relation then\n", "  if false then\n", 1)],
)
MUTATION_SRC["archive_export_claim_relation_unchecked"] = "pgpm_archive/install.sql"
MUTATIONS["archive_chunk_claim_relation_unrecorded"] = (
    "bench/archive_export_key_by_relation.sh",
    "Install records no relation for a whole-key claim made before archive.object_key_claim had the column, so "
    "a chunk claimed then stays unrecorded and archive._owned_key refuses every retry of that chunk by its own "
    "table. One site, archive._record_claim_relations. tests/archive/db/43 part C catches it (the seed records "
    "no claim, and the chunk claim's relation stays null).",
    [("     where kind = 'chunk' and relation_oid is null\n", "     where false\n", 1)],
)
MUTATION_SRC["archive_chunk_claim_relation_unrecorded"] = "pgpm_archive/install.sql"

# #975 (pass 9 F5-03, F5-04): an archive_fn strategy writes over the object pgpm.archive_ledger records a chunk at
# only when the call reproduces that chunk. One mutation per encoder's call of the shared refusal, and one per rule
# of it. All are caught by tests/archive/db/42 (bench/archive_recorded_chunk.sh, against the archive image and
# MinIO), each by a refusal it no longer makes and, for the first three, by the object read back afterwards.
for _fmt, _routine in (("ndjson", "archive_to_s3_ndjson"), ("parquet", "archive_to_s3_parquet")):
    MUTATIONS[f"archive_{_fmt}_recorded_chunk_unchecked"] = (
        "bench/archive_recorded_chunk.sh",
        f"Pre-#975 pgpm.{_routine}: the encoder PUTs without asking what pgpm.archive_ledger records at the key, so "
        f"a direct call with a recorded chunk's lo and a shorter hi writes a subset over the chunk's object while the "
        f"ledger still records [lo, hi) there, and after retire() a call with the chunk's own [lo, hi) writes an empty "
        f"object over the only copy of its rows. One site, the encoder's call of "
        f"archive._refuse_recorded_chunk_overwrite. tests/archive/db/42 catches it (F5-04 and F5-03: the object no "
        f"longer holds the chunk).",
        [(f"  perform archive._refuse_recorded_chunk_overwrite('{_routine}', p_parent, pcfg.control_kind, v_key, p_lo, p_hi, v_rows);\n",
          "", 1)],
    )
    MUTATION_SRC[f"archive_{_fmt}_recorded_chunk_unchecked"] = "pgpm_archive/install.sql"
MUTATIONS["archive_recorded_chunk_rows_unchecked"] = (
    "bench/archive_recorded_chunk.sh",
    "archive._refuse_recorded_chunk_overwrite compares a recorded chunk's range and never its rows, so after retire() "
    "dropped the partition a direct call with the chunk's own [lo, hi) reads no row and PUTs an empty object over the "
    "only copy (#975 F5-03). One site, the rows rule. tests/archive/db/42 catches it (F5-03: the retired chunk's "
    "objects no longer hold its rows).",
    [("    elsif (l.rows_archived is null and coalesce(p_rows, 0) = 0)\n"
      "          or (l.rows_archived is not null and p_rows is distinct from l.rows_archived) then\n",
      "    elsif false then\n", 1)],
)
MUTATION_SRC["archive_recorded_chunk_rows_unchecked"] = "pgpm_archive/install.sql"
MUTATIONS["archive_recorded_chunk_range_unchecked"] = (
    "bench/archive_recorded_chunk.sh",
    "archive._refuse_recorded_chunk_overwrite compares a recorded chunk's rows and never its range, so a direct call "
    "whose range is not the chunk's but reads the same rows (a shorter hi past the last row, or a hi past the "
    "chunk's) is written over the object while the ledger still records [lo, hi) there (#975 F5-04). One site, the "
    "range rule. tests/archive/db/42 catches it ([0, 95) and [0, 200) over the chunk [0, 100) are not refused).",
    [("    if pgpm._native_gt(p_kind, l.lo, p_lo) or pgpm._native_gt(p_kind, p_lo, l.lo)\n"
      "       or pgpm._native_gt(p_kind, l.hi, p_hi) or pgpm._native_gt(p_kind, p_hi, l.hi) then\n",
      "    if false then\n", 1)],
)
MUTATION_SRC["archive_recorded_chunk_range_unchecked"] = "pgpm_archive/install.sql"

# pgpm_archive reaches pgcrypto and the http extension in their own schemas, never through the caller's
# search_path (#984). All three are caught by tests/archive/db/44 (bench/archive_extension_resolution.sh,
# against the archive image and MinIO): part A's shadows ahead of the extensions, owned by another role, for
# the first two; part B's tick under `set search_path = app` for the third.
_EXTRES_SIGNER_PIN = (
    ") returns http_response language plpgsql set search_path = pg_catalog, pg_temp as $$   -- #984, above\n",
    ") returns http_response language plpgsql as $$\n",
    2,
)
MUTATIONS["archive_signer_hmac_through_search_path"] = (
    "bench/archive_extension_resolution.sh",
    "Pre-#984 SigV4 signers: neither pins its search_path, and HMAC is pgcrypto's hmac() called unqualified, so "
    "it resolves through the CALLER's path and a function hmac(bytea, bytea, text) any role created in a schema "
    "ahead of pgcrypto's is handed 'AWS4' || the S3 secret key and runs as the caller (a maintain() tick, a "
    "pg_cron job). Two sites: both signers' pin, and archive._hmac_sha256's pin and qualified call. "
    "tests/archive/db/44 part A catches it (the shadow hmac recorded the key).",
    [
        _EXTRES_SIGNER_PIN,
        ("create or replace function archive._hmac_sha256(p_data bytea, p_key bytea)\n"
         "returns bytea language plpgsql stable set search_path = pg_catalog, pg_temp as $$\n"
         "declare v_out bytea;\n"
         "begin\n"
         "  execute format('select %I.hmac($1, $2, %L)', archive._extension_schema('pgcrypto'), 'sha256') into v_out using p_data, p_key;\n",
         "create or replace function archive._hmac_sha256(p_data bytea, p_key bytea)\n"
         "returns bytea language plpgsql stable as $$\n"
         "declare v_out bytea;\n"
         "begin\n"
         "  v_out := hmac(p_data, p_key, 'sha256');\n",
         1),
    ],
)
MUTATION_SRC["archive_signer_hmac_through_search_path"] = "pgpm_archive/install.sql"
MUTATIONS["archive_signer_search_path_unpinned"] = (
    "bench/archive_extension_resolution.sh",
    "The #984 signers with their search_path pin taken out and every extension call still made in the "
    "extension's own schema: the builtins they call resolve through the caller's path, so a convert_to(text, "
    "name) in a schema ahead of an explicitly listed pg_catalog is handed 'AWS4' || the S3 secret key and runs "
    "as the caller. One site, both signers' pin. tests/archive/db/44 part A catches it (the shadow convert_to "
    "recorded the key).",
    [_EXTRES_SIGNER_PIN],
)
MUTATION_SRC["archive_signer_search_path_unpinned"] = "pgpm_archive/install.sql"
MUTATIONS["archive_upload_names_http_types"] = (
    "bench/archive_extension_resolution.sh",
    "Pre-#984 archive._encode_upload_ndjson_single: it declares its response as http_response and its header "
    "as http_header, names PL/pgSQL resolves through the session's search_path when it compiles the function, "
    "so a maintain() tick under an application path that does not name the http extension's schema (`set "
    "search_path = app`) fails every chunk with `type \"http_response\" does not exist`, logs skip_archive and "
    "never archives or retires. One site. tests/archive/db/44 part B catches it (no ledger row for the NDJSON "
    "table, and the skip_archive rows).",
    [("  v_key_id text; v_secret text; v_resp record; h record; v_etag text; v_rows bigint;   -- records: no http type named (#984)\n",
      "  v_key_id text; v_secret text; v_resp http_response; h http_header; v_etag text; v_rows bigint;\n",
      1)],
)
MUTATION_SRC["archive_upload_names_http_types"] = "pgpm_archive/install.sql"

# Issue #985: uninstall.sql's record sweep takes EVERY object pgpm.scratch records, by its oid, whatever it is
# called now; the comment sweeps are left only a copy made before the record. One mutation per way the sweep
# can fall short, each of pgpm_core/uninstall.sql.
MUTATIONS["uninstall_scratch_record_defers_commented"] = (
    "bench/uninstall_scratch_by_record.sh",
    "Pre-#985 uninstall.sql: the record sweep takes only a recorded object that has lost the copy's comment and "
    "leaves every commented one to the comment sweeps, which also need the <rel>_pgpm_delta / <rel>_pgpm_dest "
    "name, so a recorded copy, delta and function the operator renamed survive with the capture trigger on the "
    "live table. tests/282 catches it (A's four objects survive, and the table refuses a write).",
    [("      select s.parent_oid, s.kind, s.obj from pgpm.scratch s\n       order by s.kind desc, s.obj\n",
      """      select s.parent_oid, s.kind, s.obj from pgpm.scratch s
       where not exists (
               select 1 from pg_description d
                where d.classoid = 'pg_class'::regclass and d.objsubid = 0
                  and ((s.kind = 'hypertable_dest' and d.objoid = s.obj
                        and d.description = 'pgpm from_hypertable copy of ' || s.parent_oid)
                       or (s.kind <> 'hypertable_dest' and d.description ~ '^pgpm from_hypertable horizon [0-9]+$'
                           and d.objoid = (select s2.obj from pgpm.scratch s2
                                            where s2.parent_oid = s.parent_oid and s2.kind = 'hypertable_delta'))))
       order by s.kind desc, s.obj
""", 1)],
)
MUTATION_SRC["uninstall_scratch_record_defers_commented"] = "pgpm_core/uninstall.sql"
MUTATIONS["uninstall_scratch_record_drops_orphaned_copy"] = (
    "bench/uninstall_scratch_by_record.sh",
    "#985's record sweep without its source check: a recorded copy whose table the operator has since dropped is "
    "dropped too, although it may be the only home of those rows (#773's rule, which the comment sweep keeps). "
    "tests/282's B (a renamed recorded copy of a dropped table) is gone with its two rows.",
    [("""        elsif not exists (select 1 from pg_class where oid = r.parent_oid) then
          raise warning 'pg_partition_magician: left behind %, a from_hypertable copy that was never cut over: the hypertable it was copied from (oid %) no longer exists, so this table may hold the only copy of those rows. Drop it once you have checked.',
            r.obj::regclass::text, r.parent_oid;
""", "", 1)],
)
MUTATION_SRC["uninstall_scratch_record_drops_orphaned_copy"] = "pgpm_core/uninstall.sql"
MUTATIONS["uninstall_scratch_record_skips_capture_fn"] = (
    "bench/uninstall_hypertable_scratch_by_record.sh",
    "#985's record sweep taking the copy and the delta by oid but leaving the capture function to the comment "
    "sweep, which derives it from the delta's name: once the delta is renamed (or dropped here first) nothing "
    "finds the function, and it and its trigger on the live hypertable and every chunk survive. "
    "tests/timescale/db/54 catches it (the trigger and u985_a_capture() survive, and the hypertable refuses a "
    "write).",
    [("      select s.parent_oid, s.kind, s.obj from pgpm.scratch s\n       order by s.kind desc, s.obj\n",
      "      select s.parent_oid, s.kind, s.obj from pgpm.scratch s\n       where s.kind <> 'hypertable_delta_fn'\n"
      "       order by s.kind desc, s.obj\n", 1)],
)
MUTATION_SRC["uninstall_scratch_record_skips_capture_fn"] = "pgpm_core/uninstall.sql"
MUTATION_TRACK["uninstall_scratch_record_skips_capture_fn"] = "timescale"

# pass 9 G18: #994, #995, #1002. Four test files that counted where their own comments promised to name, each
# judged by bench/tests_fail_on_defect.sh against a defect it plants in install.sql. One mutation per site, each
# the site's exact pre-fix text, so the file under it passes against that defect.
MUTATIONS.update({
    "transmute_log_summed_count_247": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#994 tests/247: 'A, D: each conversion logged its own transmute' asserted as count(*) = 2 summed over "
        "t247_nan and t247_int, which a log holding two t247_nan rows and no t247_int row satisfies. The exact "
        "pre-#994 assertion; the guard's defect logs every conversion under the first parent ever logged.",
        [("""-- Identity, not cardinality (#994): one transmute row under EACH converted table's name. A count summed
-- over both would accept t247_nan logged twice and t247_int never.
select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.log
            where parent_table in ('public.t247_nan'::regclass, 'public.t247_int'::regclass) and action = 'transmute'),
  array['t247_int', 't247_nan'],
""", """select is((select count(*)::int from pgpm.log where parent_table in ('public.t247_nan'::regclass, 'public.t247_int'::regclass)
                                               and action = 'transmute'), 2,
""", 1)],
    ),
    "transmute_log_summed_count_178": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#994 tests/178: 'B, C, D, F: each conversion logged its own transmute' asserted as count(*) = 4 "
        "summed over nb, nc, fd and ff, which a log naming nb four times and the others never satisfies. The "
        "exact pre-#994 assertion.",
        [("""-- Identity, not cardinality (#994): one transmute row under EACH converted table's name. A count summed
-- over the four would accept nb logged twice and nc never.
select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.log
            where parent_table in ('public.nb'::regclass, 'public.nc'::regclass,
                                   'public.fd'::regclass, 'public.ff'::regclass)
              and action = 'transmute'),
  array['fd', 'ff', 'nb', 'nc'],
""", """select is((select count(*)::int from pgpm.log where parent_table in ('public.nb'::regclass, 'public.nc'::regclass,
                                                                   'public.fd'::regclass, 'public.ff'::regclass)
                                               and action = 'transmute'), 4,
""", 1)],
    ),
    "reap_kept_rows_by_count": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#995 tests/140: 'rn_old kept every row it had, and the new one' asserted as count(*) = 22, which a "
        "reaper that rewrites id 1 to -1 after dropping the bound satisfies. The exact pre-#995 assertion.",
        [("""-- Identity, not cardinality (#995): the ids rn_old holds, by name. A count of 22 would accept a reap that
-- rewrote one of them (id 1 read back as -1) or lost one and gained another.
select is((select array_agg(id order by id) from public.rn_old),
  (select array_agg(g::bigint order by g) from generate_series(1, 20) g) || array[100, 200]::bigint[],
  'rn_old kept every row it had, and the new one');
""", """select is((select count(*)::int from public.rn_old), 22, 'rn_old kept every row it had, and the new one');
""", 1)],
    ),
    "retiring_partition_attachment_only": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#1002 tests/77 line 98: 'the partition is still attached, and still holds its rows, until the detach "
        "actually happens' asserted as one pg_inherits row under the partition's NAME, reading none of its rows, "
        "which a retire() that empties the partition when it dispatches the detach satisfies. The exact pre-#1002 "
        "text of that site, plan and oid capture included.",
        [("select plan(50);\n", "select plan(48);\n", 1),
         ("""-- and its oid, before anything touches it: "still attached" below is judged on THIS relation, not on
-- whatever holds the name by then
select format('public.%I', :'doomed')::regclass::oid as doomed_oid \\gset
""", "", 1),
         ("""-- Nothing may be destroyed on the way. Identity, not cardinality: name the partition and its rows
-- (#1002). Attachment alone reads no row, so it would pass a retire() that emptied the partition when it
-- dispatched the detach. Rows are read THROUGH the parent, from that partition: ids 1, 25000 and 50000
-- by name, then every one of 1..50000.
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rw77'::regclass
                   and inhrelid = :'doomed_oid'::oid and not inhdetachpending),
  'the partition is still attached, the same relation by oid and not detach-pending');
select is(
  (select array_agg(id order by id) from public.rw77
    where tableoid = to_regclass(format('public.%I', :'doomed')) and id in (1, 25000, 50000)),
  array[1, 25000, 50000]::bigint[],
  'the partition still holds its rows (ids 1, 25000 and 50000), until the detach actually happens');
select ok(
  (select array_agg(id order by id) from public.rw77 where tableoid = :'doomed_oid'::oid)
    = (select array_agg(g::bigint order by g) from generate_series(1, 50000) g),
  'and every one of them: exactly ids 1 to 50000, none lost, none invented');
""", """-- Nothing may be destroyed on the way. Identity, not cardinality: name the partition and its rows.
select is(
  (select count(*)::int from pg_inherits i join pg_class c on c.oid = i.inhrelid
    where i.inhparent = 'public.rw77'::regclass and c.relname = :'doomed'),
  1, 'the partition is still attached, and still holds its rows, until the detach actually happens');
""", 1)],
    ),
    "crossing_refusal_attachment_only": (
        "bench/tests_fail_on_defect.sh",
        "Pre-#1002 tests/77 line 218: 'and the partition is left INTACT and attached, not half-retired' (the NO "
        "ACTION crossing) asserted as one pg_inherits row under the partition's NAME, reading none of its rows, "
        "which a refused retire() that has already deleted the rows nothing references satisfies. The exact "
        "pre-#1002 text of that site, plan and oid capture included.",
        [("select plan(50);\n", "select plan(48);\n", 1),
         ("select format('public.%I', :'nx_doomed')::regclass::oid as nx_doomed_oid \\gset\n", "", 1),
         ("""-- INTACT is about its rows, not only its attachment (#1002): a refused retire() that had already deleted
-- the rows nothing references would leave it attached and half-retired. Ids 1, 42 (the referenced one),
-- 25000 and 50000 by name, then every one of 1..50000.
select ok(exists (select 1 from pg_inherits where inhparent = 'public.nx77'::regclass
                   and inhrelid = :'nx_doomed_oid'::oid and not inhdetachpending),
  'and the partition is left attached, the same relation by oid and not detach-pending');
select is(
  (select array_agg(id order by id) from public.nx77
    where tableoid = to_regclass(format('public.%I', :'nx_doomed')) and id in (1, 42, 25000, 50000)),
  array[1, 42, 25000, 50000]::bigint[],
  'and the partition is left INTACT and attached, not half-retired: ids 1, 42, 25000 and 50000 are there');
select ok(
  (select array_agg(id order by id) from public.nx77 where tableoid = :'nx_doomed_oid'::oid)
    = (select array_agg(g::bigint order by g) from generate_series(1, 50000) g),
  'and every one of its rows: exactly ids 1 to 50000, none lost, none invented');
""", """select is(
  (select count(*)::int from pg_inherits i join pg_class c on c.oid = i.inhrelid
    where i.inhparent = 'public.nx77'::regclass and c.relname = :'nx_doomed'),
  1, 'and the partition is left INTACT and attached, not half-retired');
""", 1)],
    ),
})
MUTATION_SRC.update({
    "transmute_log_summed_count_247": "tests/247_transmute_non_finite_id_key_test.sql",
    "transmute_log_summed_count_178": "tests/178_transmute_time_future_maximum_test.sql",
    "reap_kept_rows_by_count": "tests/140_transmute_reap_identity_test.sql",
    "retiring_partition_attachment_only": "tests/77_retain_incoming_fk_test.sql",
    "crossing_refusal_attachment_only": "tests/77_retain_incoming_fk_test.sql",
})
# pass 9 G19 (#997, #998): ten conservation tests and tests/79, each back to its count; judged by
# bench/tests_fail_on_defect.sh against a value-rewriting transmute or regrain copy, or a forget_missing()
# that rewrites the survivors' pgpm.part rows. Each mutant keeps the file's now distinct payloads.
MUTATIONS['transmute_conservation_by_count_15'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/15: transmute's row conservation asserted only by count(*) = 500 ('all rows conserved'), which a transmute that rewrites a row's value keeps. The fixture keeps its distinct payloads; a count cannot read them.",
    [
        ('select plan(6);\n',
         'select plan(5);\n', 1),
        ("\nselect bag_eq(\n  'select id, payload from public.reuse_pk',\n  'select id, payload from _reuse_pk_before',\n  'every row survives the transmute by identity: the same (id, payload) rows, none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['transmute_conservation_by_count_15'] = 'tests/15_pk_reuse_test.sql'
MUTATIONS['transmute_conservation_by_count_49'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/49: transmute's row conservation on both reused-UNIQUE-constraint paths asserted only by count(*) (40 and 30), which a transmute that rewrites a row's value keeps. Both identity checks removed.",
    [
        ('select plan(12);\n',
         'select plan(10);\n', 1),
        ("\nselect bag_eq(\n  'select ts, id, body from public.uq_lead',\n  'select ts, id, body from _uq_lead_before',\n  'every row survives the transmute by identity: the same (ts, id, body) rows, none lost, none added, none altered');\n",
         '\n', 1),
        ("\nselect bag_eq(\n  'select device_id, ts, body from public.uq_mid',\n  'select device_id, ts, body from _uq_mid_before',\n  'every row survives by identity (non-leading control): none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['transmute_conservation_by_count_49'] = 'tests/49_unique_constraint_reuse_test.sql'
MUTATIONS['regrain_conservation_by_count_43'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/43: the regrain's conservation asserted only by count(*) = 50001 ('all rows conserved'), which a copy that rewrites a copied row's value keeps.",
    [
        ('select plan(9);\n',
         'select plan(8);\n', 1),
        ("\nselect bag_eq(\n  'select id, payload from public.rf',\n  $$ select id, payload from _rf_before union all select 65000::bigint, 'frontier' $$,\n  'every row survives the regrain by identity: the same (id, payload) rows, none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['regrain_conservation_by_count_43'] = 'tests/43_regrain_test.sql'
MUTATIONS['regrain_conservation_by_count_45'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/45: the feathered regrain's conservation asserted only by count(*) = 120, which a copy that rewrites a copied row's value keeps.",
    [
        ('select plan(5);\n',
         'select plan(4);\n', 1),
        ("\nselect bag_eq(\n  'select id, payload from public.fw where id < 150',\n  'select id, payload from _fw_before',\n  'every history row survives the feathered regrain by identity: none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['regrain_conservation_by_count_45'] = 'tests/45_regrain_feathered_test.sql'
MUTATIONS['regrain_conservation_by_count_46'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/46: the cross-tick regrain's conservation asserted only by count(*) = 200, which a copy that rewrites a copied row's value keeps.",
    [
        ('select plan(7);\n',
         'select plan(6);\n', 1),
        ("\nselect bag_eq(\n  'select id, payload from public.ar where id < 250',\n  'select id, payload from _ar_before',\n  'every history row survives the cross-tick regrain by identity: none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['regrain_conservation_by_count_46'] = 'tests/46_auto_regrain_maintain_test.sql'
MUTATIONS['regrain_conservation_by_count_48'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/48: the feathered copy-regrain's conservation asserted only by count(*) = 300, which a copy that rewrites a copied row's value keeps.",
    [
        ('select plan(9);\n',
         'select plan(8);\n', 1),
        ("\nselect bag_eq(\n  'select id, payload from public.cc where id <= 300',\n  'select id, payload from _cc_before',\n  'every history row survives the feathered copy-regrain by identity: none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['regrain_conservation_by_count_48'] = 'tests/48_regrain_copy_contract_test.sql'
MUTATIONS['regrain_conservation_by_count_53'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/53: the unique-constraint regrain's conservation asserted only by count(*) = 5001, which a copy that rewrites a copied row's value keeps.",
    [
        ('select plan(6);\n',
         'select plan(5);\n', 1),
        ("\n-- Identity, not cardinality (#997): every row carries its own body, so a copy that rewrites a value\n-- while keeping the count is caught here.\nselect bag_eq(\n  'select id, batch, body from public.ruq',\n  $$ select g::bigint, 1::bigint, 'b' || g from generate_series(1, 5000) g\n     union all select 20000::bigint, 1::bigint, 'frontier' $$,\n  'every row survives the regrain by identity: the same (id, batch, body) rows, none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['regrain_conservation_by_count_53'] = 'tests/53_regrain_reused_key_test.sql'
MUTATIONS['regrain_conservation_by_count_54'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/54: the regrain's conservation asserted only by count(*) = 5001 and the generated column's consistency, both of which a copy that rewrites a copied row's amount keeps (cents recomputes from it).",
    [
        ('select plan(4);\n',
         'select plan(3);\n', 1),
        ("\n-- Identity, not cardinality (#997): the fixture writes amount = id, so a copy that rewrites a value\n-- while keeping the count (and the generated column consistent with it) is caught here.\nselect bag_eq(\n  'select id, amount from public.gc',\n  $$ select g::bigint as id, g::numeric as amount from generate_series(1, 5000) g\n     union all select 20000::bigint, 100000::numeric $$,\n  'every row survives the regrain by identity: the same (id, amount) rows, none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['regrain_conservation_by_count_54'] = 'tests/54_generated_column_test.sql'
MUTATIONS['regrain_conservation_by_count_67'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/67: 'the regrain is lossless' asserted only by count(*) = 401 and the presence of ids 1..99, which a copy that rewrites a copied row's value keeps.",
    [
        ('select plan(15);\n',
         'select plan(14);\n', 1),
        ("\n-- Identity, not cardinality (#997): every row carries its own payload, so a copy that rewrites a value\n-- while keeping the count is caught here.\nselect bag_eq(\n  'select id, payload from public.rnc',\n  $$ select g::bigint, 'p' || g from generate_series(1, 400) g union all select 20000::bigint, 'frontier' $$,\n  'the regrain is lossless by identity: the same (id, payload) rows, none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['regrain_conservation_by_count_67'] = 'tests/67_regrain_name_collision_test.sql'
MUTATIONS['regrain_conservation_by_count_68'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#997 tests/68: the control regrain's 'lossless' asserted only by count(*) = 251, which a copy that rewrites a copied row's value keeps.",
    [
        ('select plan(11);\n',
         'select plan(10);\n', 1),
        ("\n-- Identity, not cardinality (#997): every row carries its own payload, so a copy that rewrites a value\n-- while keeping the count is caught here.\nselect bag_eq(\n  'select id, payload from public.wc0',\n  $$ select (g*10)::bigint, 'p' || g*10 from generate_series(1, 250) g union all select 20000::bigint, 'frontier' $$,\n  'control: the same (id, payload) rows survive the regrain, none lost, none added, none altered');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['regrain_conservation_by_count_68'] = 'tests/68_regrain_write_contract_test.sql'
MUTATIONS['forget_missing_survivors_by_count'] = (
    "bench/tests_fail_on_defect.sh",
    "Pre-#998 tests/79: 'the healthy table keeps every one of its pgpm.part rows' asserted only by count, under its own 'Identity, not cardinality' comment, which a forget_missing() that rewrites every surviving row's child_name and child_oid keeps. The snapshot table stays; nothing reads it.",
    [
        ('select plan(27);\n',
         'select plan(26);\n', 1),
        ("\nselect bag_eq(\n  $$ select child_name, child_oid, lo, hi from pgpm.part where parent_table = 'public.keep79'::regclass $$,\n  'select child_name, child_oid, lo, hi from pgpm_t79_keep_parts',\n  'and each of them as it was: the same (child_name, child_oid, lo, hi), none rewritten, none added');\n",
         '\n', 1),
    ],
)
MUTATION_SRC['forget_missing_survivors_by_count'] = 'tests/79_status_survives_dropped_parent_test.sql'

# #1037 bullet 1: the hypertable capture writes its delta through the recorded oid.
MUTATIONS["hypertable_capture_delta_by_name"] = (
    "bench/hypertable_capture_delta_by_record.sh",
    "Pre-#1037 from_hypertable_copy: the capture function it mints inserts into <schema>.<rel>_pgpm_delta by "
    "NAME alone (the fast path without the by-oid fallback), while the drains, the cutover and uninstall find the delta by the oid pgpm.scratch recorded (#955). "
    "Rename the recorded delta during the online window and every insert, update and delete on the live "
    "hypertable dies 42P01; a table the operator then creates under the freed name takes the captured keys, "
    "which nothing drains, and the cutover refuses the swap. tests/timescale/db/56 catches it: the three "
    "writes after the rename die, the renamed delta holds no keys, the operator's table holds 100002, and a56 "
    "is never cut over.",
    [("    execute format('create function %I.%I() returns trigger language plpgsql as $pgpm$\n"
      "      declare\n"
      "        d regclass;\n"
      "      begin\n"
      "        if pg_catalog.to_regclass(%L) is distinct from %s::pg_catalog.oid::pg_catalog.regclass then\n"
      "          select c.oid::pg_catalog.regclass into d from pg_catalog.pg_class c where c.oid = %s;\n"
      "          if d is null then\n"
      "            raise exception using errcode = ''undefined_table'', message = %L;\n"
      "          end if;\n"
      "          if tg_op = ''DELETE'' then\n"
      "            execute ''insert into '' || d::text || %L using %s; return old;\n"
      "          elsif tg_op = ''UPDATE'' then\n"
      "            execute ''insert into '' || d::text || %L using %s, %s; return new;\n"
      "          else\n"
      "            execute ''insert into '' || d::text || %L using %s; return new;\n"
      "          end if;\n"
      "        end if;\n"
      "        if tg_op = ''DELETE'' then\n"
      "          insert into %I.%I (%s) values (%s); return old;\n"
      "        elsif tg_op = ''UPDATE'' then\n"
      "          insert into %I.%I (%s) values (%s), (%s); return new;   -- old + new: a key change dirties both\n"
      "        else\n"
      "          insert into %I.%I (%s) values (%s); return new;\n"
      "        end if;\n"
      "      end $pgpm$',\n"
      "      v_nsp, v_trgfn,\n"
      "      format('%I.%I', v_nsp, v_delta), v_delta_oid, v_delta_oid,\n"
      "      format('pg_partition_magician: the change capture of %s.%s has lost the delta from_hypertable_copy recorded for it (oid %s), so no write to the table can be logged. Re-run pgpm.from_hypertable_copy with p_track_changes => true, which mints a fresh delta and capture.',\n"
      "             quote_ident(v_nsp), quote_ident(v_rel), v_delta_oid),\n"
      "      format(' (%s) values (%s)', v_keycols_q, v_oldargs), v_oldvals_q,\n"
      "      format(' (%s) values (%s), (%s)', v_keycols_q, v_oldargs, v_newargs), v_oldvals_q, v_newvals_q,\n"
      "      format(' (%s) values (%s)', v_keycols_q, v_oldargs), v_newvals_q,\n"
      "      v_nsp, v_delta, v_keycols_q, v_oldvals_q,\n"
      "      v_nsp, v_delta, v_keycols_q, v_oldvals_q, v_newvals_q,\n"
      "      v_nsp, v_delta, v_keycols_q, v_newvals_q);\n",
      "    execute format('create function %I.%I() returns trigger language plpgsql as $pgpm$\n"
      "      begin\n"
      "        if tg_op = ''DELETE'' then\n"
      "          insert into %I.%I (%s) values (%s); return old;\n"
      "        elsif tg_op = ''UPDATE'' then\n"
      "          insert into %I.%I (%s) values (%s), (%s); return new;   -- old + new: a key change dirties both\n"
      "        else\n"
      "          insert into %I.%I (%s) values (%s); return new;\n"
      "        end if;\n"
      "      end $pgpm$',\n"
      "      v_nsp, v_trgfn,\n"
      "      v_nsp, v_delta, v_keycols_q, v_oldvals_q,\n"
      "      v_nsp, v_delta, v_keycols_q, v_oldvals_q, v_newvals_q,\n"
      "      v_nsp, v_delta, v_keycols_q, v_newvals_q);\n", 1)],
)
MUTATION_SRC["hypertable_capture_delta_by_name"] = "pgpm_hypertable/install.sql"
MUTATION_TRACK["hypertable_capture_delta_by_name"] = "timescale"



# How long a mutation takes bench/discriminate.sh to prove, in seconds, for the ones that take long
# enough to matter. `--list` prints the catalogue heaviest first (stable: catalogue order within a
# cost), and discriminate.sh's --shard=I/N interleaves that list, so the heavy ones spread over the
# shards instead of landing wherever the catalogue put them. Measured on the pr-1029 merge group
# (2026-10-07): 548 mutations, 45.5 minutes of work, median 2 s; in catalogue order the four shards
# took 12, 14, 12 and 17 minutes because the 240 s lz77 probe and two 100 s deflate probes shared one;
# heavy-first over six shards, the slowest is about 11. A mutation not listed here counts as
# MUTATION_COST_DEFAULT. A name here that is not in MUTATIONS fails `--list` loudly: a stale entry
# would silently stop balancing the mutation it was measured for.
MUTATION_COST_DEFAULT = 2
MUTATION_COST = {
    "archive_lz77_hash_scratch": 240,
    "archive_deflate_raises": 112,
    "archive_deflate_six_arrays": 94,
    "retire_inline_detach": 91,
    "regrain_no_outgoing_fk": 82,
    "archive_lz77_range_raises": 64,
    "transmute_no_lock_timeout": 61,
    "hypertable_cutover_no_lock_timeout": 41,
    "transmute_abort_no_lock_timeout": 37,
    "detach_reap_no_lock_timeout": 37,
    "archive_lz77_repeat_differs": 32,
    "transmute_reap_no_lock_timeout": 30,
    "restore_fk_inline_validate": 30,
    "parquet_per_column_statements": 29,
    "maintain_no_commits": 27,
    "transmute_no_commits": 25,
    "hypertable_handoff_validate_no_lock_timeout": 25,
    "upgrade_backfill_drops_not_null": 22,
    "upgrade_regrain_capture_backfill_noop": 22,
    "upgrade_child_oid_backfill_noop": 21,
    "upgrade_regrain_mark_block_noop": 21,
    "scratch_upgrade_fill_dropped": 20,
}


def listing_order():
    """The catalogue heaviest first, catalogue order within a cost (see MUTATION_COST)."""
    stale = sorted(set(MUTATION_COST) - set(MUTATIONS))
    if stale:
        raise SystemExit(
            f"mutate.py: MUTATION_COST names mutations the catalogue does not have: {', '.join(stale)}.\n"
            f"  A renamed or retired mutation must be renamed or removed there too, or the shards stop\n"
            f"  balancing the one it was measured for."
        )
    return sorted(MUTATIONS.items(), key=lambda kv: -MUTATION_COST.get(kv[0], MUTATION_COST_DEFAULT))


def main() -> int:
    if len(sys.argv) in (2, 3) and sys.argv[1] == "--list":
        track = "perf"
        if len(sys.argv) == 3:
            if not sys.argv[2].startswith("--track="):
                print(__doc__, file=sys.stderr)
                return 2
            track = sys.argv[2].split("=", 1)[1]

        # An unknown track must be an ERROR, never an empty listing. A silent empty listing is the
        # worst possible output from this file: bench/discriminate.sh would run zero mutations and
        # report "PASS (0 guard(s) verified against their defects)", a green check that verified
        # nothing -- in the very machinery whose entire purpose is to prove that a green check means
        # something. Same discipline as a stale pattern below: fail loudly rather than hand back a
        # result that looks like success.
        known = {"perf"} | set(MUTATION_TRACK.values())
        if track not in known:
            print(
                f"mutate.py: unknown track {track!r}; known tracks are "
                f"{', '.join(sorted(known))}.\n"
                f"  Refusing to print an empty listing, which would make discriminate.sh report a\n"
                f"  PASS having verified nothing at all.",
                file=sys.stderr,
            )
            return 2

        listed = 0
        for name, (guard, why, _) in listing_order():
            if MUTATION_TRACK.get(name, "perf") != track:
                continue
            listed += 1
            src = MUTATION_SRC.get(name, "pgpm_core/install.sql")
            print(f"{name}\t{guard}\t{why}\t{src}")
        if listed == 0:
            # Reachable only if a track is registered in MUTATION_TRACK and then has its last
            # mutation removed. That leaves a CI job running happily against nothing, so it is a
            # failure here rather than a discovery months later.
            print(
                f"mutate.py: track {track!r} selected no mutations. A registered track with no\n"
                f"  mutation left in it is a guard that nothing verifies -- add one back, or remove\n"
                f"  the track and the job that runs it.",
                file=sys.stderr,
            )
            return 1
        return 0
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2

    name, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    if name not in MUTATIONS:
        print(f"mutate.py: unknown mutation {name!r}; try --list", file=sys.stderr)
        return 2

    _, _, edits = MUTATIONS[name]
    with open(src) as fh:
        text = fh.read()

    for find, replace, expected in edits:
        is_re = hasattr(find, "sub")
        got = len(find.findall(text)) if is_re else text.count(find)
        if got != expected:
            print(
                f"mutate.py: {name}: pattern matched {got} time(s), expected {expected}.\n"
                f"  The code has moved and this mutation is stale. Fix the pattern -- do NOT let it\n"
                f"  write an unmutated copy, which would make its guard look broken when it is fine.\n"
                f"  Pattern begins: "
                f"{(find.pattern if is_re else find).strip().splitlines()[0][:90]!r}",
                file=sys.stderr,
            )
            return 1
        text = find.sub(replace, text) if is_re else text.replace(find, replace)

    with open(dst, "w") as fh:
        fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
