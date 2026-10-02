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
       mutate.py --list [--track=NAME]
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

# The upgrade backfill of regrain's capture anchors (#496, reshaped by #655), whole. Shared by the mutation
# that deletes it and the one that loosens it, for the reason RETIRE_IDENTITY_BLOCK is a constant.
REGRAIN_CAPTURE_BACKFILL_BLOCK = """do $$
declare r record; v_nsp name; v_rel name; v_delta regclass;
begin
  for r in select parent_table from pgpm.config where regrain_delta_oid is null loop
    select n.nspname, c.relname into v_nsp, v_rel
      from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = r.parent_table;
    if v_nsp is null then continue; end if;
    v_delta := to_regclass(format('%I.%I', v_nsp, left(v_rel || '_pgpm_regrain_delta', 63)::name));
    if v_delta is null
       or not exists (select 1 from pg_class c where c.oid = v_delta and c.relkind = 'r' and not c.relispartition)
    then continue; end if;
    update pgpm.config
       set regrain_delta_oid      = v_delta::oid,
           regrain_capture_fn_oid = to_regprocedure(format('%I.%I()', v_nsp, left(v_rel || '_pgpm_regrain_capture', 63)::name))::oid
     where parent_table = r.parent_table;
  end loop;
end $$;
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
  commit;
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
TRANSMUTE_CUTOVER_HOIST = """  -- #344: everything below that only touches the NEW parent -- not the original/monolith relation -- runs
  -- BEFORE either rename, under a staging name (v_staging, collision-checked earlier alongside the
  -- orphan-name guard). None of it needs the original table's lock: CREATE TABLE ... LIKE only takes
  -- ACCESS SHARE on p_parent (a rename changes no column/default/constraint, so building it from p_parent
  -- now is byte-for-byte the same as building it from the monolith name later), and everything after that
  -- targets the not-yet-visible staging relation. This is what shrinks the outage: previously all of it
  -- ran AFTER the rename, adding directly to how long the live table was unavailable.

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
  -- EXCEPT triggers: that is the one step that needs the LIVE name in place, not just the right OID (see
  -- 0b), so it stays below, after both renames. And except comments, which only the table's ACCESS
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
  -- Policies live on the PARENT and only on the parent (measured: a parent policy governs parent-routed
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
  -- The shape is transmute's 7b, run the other way. v_acl_default: a NULL relacl is the owner's implicit
  -- all-privileges default, which has no grant to replay.
  select relrowsecurity, relforcerowsecurity, relacl is null into v_rls, v_rls_force, v_acl_default
    from pg_class where oid = p_parent;
"""
# The rest of the #667 capture: the table and column grants and the policies. A piece of its own because
# #710 (PR #753) inserts the owner and comment capture between the two, under the lock, where it stays.
UNTRANSMUTE_ACL_CAPTURE_BODY = """  for v_g in
    select a.privilege_type, a.is_grantable,
           case when a.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(a.grantee)) end as role_q
      from pg_class c, aclexplode(c.relacl) a where c.oid = p_parent and c.relacl is not null
  loop
    v_grantdefs := v_grantdefs || format('grant %s on %I.%I to %s%s', v_g.privilege_type, v_nsp, v_rel, v_g.role_q,
                                         case when v_g.is_grantable then ' with grant option' else '' end);
  end loop;
  for v_g in
    select att.attname, a.privilege_type, a.is_grantable,
           case when a.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(a.grantee)) end as role_q
      from pg_attribute att, aclexplode(att.attacl) a
     where att.attrelid = p_parent and att.attnum > 0 and not att.attisdropped and att.attacl is not null
  loop
    v_grantdefs := v_grantdefs || format('grant %s (%I) on %I.%I to %s%s', v_g.privilege_type, v_g.attname, v_nsp, v_rel,
                                         v_g.role_q, case when v_g.is_grantable then ' with grant option' else '' end);
  end loop;
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
                     v_rec, v_nsp, v_child_name, v_made));
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
  -- aclexplode turns relacl into (grantor, grantee, privilege, grantable) rows; a NULL relacl
  -- means the owner's implicit defaults, which the OWNER TO above already restores. grantee = 0 is
  -- PUBLIC, which has no role name.
  for v_g in
    select a.grantee, a.privilege_type, a.is_grantable
      from pg_class c, aclexplode(c.relacl) a where c.oid = p_parent and c.relacl is not null
  loop
    execute format('grant %s on %s to %s%s', v_g.privilege_type, v_parent::text,
                   case when v_g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(v_g.grantee)) end,
                   case when v_g.is_grantable then ' with grant option' else '' end);
  end loop;
  -- COLUMN-level grants, which relacl does not carry at all: they live in pg_attribute.attacl.
  for v_g in
    select att.attname, a.grantee, a.privilege_type, a.is_grantable
      from pg_attribute att, aclexplode(att.attacl) a
     where att.attrelid = p_parent and att.attnum > 0 and not att.attisdropped and att.attacl is not null
  loop
    execute format('grant %s (%I) on %s to %s%s', v_g.privilege_type, v_g.attname, v_parent::text,
                   case when v_g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(v_g.grantee)) end,
                   case when v_g.is_grantable then ' with grant option' else '' end);
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
        [("    v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));\n"
          "    if r.child_oid is not null and v_now::oid is distinct from r.child_oid then\n"
          "      insert into pgpm.log (parent_table, action, lo, hi, method)\n"
          "        values (p_parent, 'fail_archive_identity', r.lo, r.hi,\n"
          "                format('%I.%I is oid %s now, not the oid %s recorded for this "
          "partition; refusing to archive it',\n"
          "                       v_nsp, r.child_name, coalesce(v_now::oid::text, 'nothing'), "
          "r.child_oid));\n"
          "      continue;\n"
          "    end if;\n\n", "", 1)],
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
        [(HT_SWAP_IDENTITY_POSITION, "    end loop;\n  end if;\n  commit;\n", 1)],
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
        "tracked hypertable fails on a raw error, leaving it a hypertable.",
        [("       and not (fn.nspname = v_nsp and f.proname = v_rel || '_pgpm_delta_fn')\n", "", 1)],
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
        "bench/hypertable_exclusion_refusal.sh",
        "Pre-#675 from_hypertable_cutover(): the irreversible phase re-checks the dimension but not an "
        "EXCLUDE constraint, so a destination left by an older version's copy, or made by hand, reaches "
        "the swap and the constraint is dropped with the hypertable. Deletes the cutover's call only, so "
        "only tests/timescale/db/26's cutover assertion fails (the 2D000 of the pre-drain-free "
        "cutover's first COMMIT where the refusal naming both constraints is pinned).",
        [("  perform pgpm._from_hypertable_check_exclusion(p_hypertable);\n  -- Keep the OID this check resolved",
          "  -- Keep the OID this check resolved", 1)],
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
        "'already exists', and the append-only cutover finds the source's own index under the temp name, "
        "skips its build, and fails adopting an index the DROP took. Part B of tests/timescale/db/29 fails.",
        [("""  select (case when octet_length(p_name || '_pgpm_new') <= 63 then p_name || '_pgpm_new'
               else 'pgpm_new_' || p_index::text end)::name""",
          """  select left(p_name || '_pgpm_new', 63)::name   -- MUTANT: cut to 63 bytes""", 1)],
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
    from pg_class where oid = format('%I.%I', v_nsp, v_delta)::regclass;
  if v_reltuples = 0 then
    execute format('select exists (select 1 from %I.%I)', v_nsp, v_delta) into v_delta_has_rows;
  end if;
  if v_reltuples < 0 or (v_reltuples = 0 and v_delta_has_rows) then
    perform pgpm._analyze(format('%I.%I', v_nsp, v_delta)::regclass);
  end if;
""", "", 1)],
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
            ("  v_decoded := pgpm._decode(cfg.control_kind, v_max,\n"
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
             "end;\n", 1),
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
        [("  execute format('delete from %I.%I where pgpm_seq = any($1)', v_nsp, v_delta) using v_seqs;\n",
          "  execute format('delete from %I.%I where pgpm_seq <= %s and %s', v_nsp, v_delta,\n"
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
          "  update pgpm.config set archive_fn = p_archive_fn where parent_table = p_parent;\n", 1)],
    ),
    "regrain_no_outgoing_fk": (
        "bench/regrain_outgoing_fk_lock.sh",
        "Pre-#348 regrain_step: a fine child is created via `like ... including constraints`, "
        "which never copies a FOREIGN KEY, and nothing else gives it one. So the swap's ATTACH "
        "PARTITION forces PostgreSQL to validate the parent's outgoing FK for that partition from "
        "scratch, an O(rows) scan under whatever lock the swap already holds -- exactly what "
        "reached a production statement_timeout.",
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
        execute format('alter table %I.%I add constraint %I %s not valid', v_nsp, v_sub_name, r.conname, r.def);
        execute format('alter table %I.%I validate constraint %I', v_nsp, v_sub_name, r.conname);
      end loop;
""", "", 1)],
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
        [("  perform pgpm._own_like_parent(p_parent, v_delta_reg);\n"
          "  perform pgpm._regrain_capture_grant(p_parent, v_delta_reg);\n", "", 1),
         ("  if v_delta_reg is not null then perform pgpm._regrain_capture_grant(p_parent, v_delta_reg); end if;\n", "", 1)],
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
        "of the child's own schema in the mutant, so the cast is the only thing put back.",
        [("declare v_nsp_oid oid;\nbegin\n  select c.relnamespace into v_nsp_oid from pg_class c where c.oid = p_parent;\n",
          "declare v_nsp name;\nbegin\n  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;\n", 1),
         ("declare v_nsp_oid oid;\nbegin\n"
          "  -- #727: the partition's own schema, not the parent's; matched by name = name, never parsed (#512)\n"
          "  select n.oid into v_nsp_oid from pg_namespace n where n.nspname = pgpm._child_nsp(p_parent, p_child);\n",
          "declare v_nsp name;\nbegin\n  v_nsp := pgpm._child_nsp(p_parent, p_child);\n", 1),
         ("c.relnamespace = v_nsp_oid", "c.relnamespace = v_nsp::regnamespace", 2)],
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
        "to the row next door, in a file every reader accepts. Five sites, all in the snapshot's "
        "lifecycle: the create, the count, and the three drops (the guarded one before the create, "
        "and one at the end of each encoder), so the mutant runs to completion rather than erroring "
        "on `drop table` of a view, which would fail the guard for the wrong reason.",
        [
            ("    'create temp table archive_pq_snapshot on commit drop as\n",
             "    'create temp view archive_pq_snapshot as\n", 1),
            ("  get diagnostics v_num_rows = row_count;\n",
             "  execute 'select count(*) from pg_temp.archive_pq_snapshot' into v_num_rows;\n", 1),
            ("  drop table pg_temp.archive_pq_snapshot;\n",
             "  drop view pg_temp.archive_pq_snapshot;\n", 3),
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
        [("  select case when p_kind = 'id' then p_lo else regexp_replace(p_lo::timestamptz::text, '[^0-9]', '', 'g') end;\n",
          "  select regexp_replace(p_lo, '[^0-9]', '', 'g');\n", 1)],
    ),
    # #551, one mutation per session rendering the fix took out of the key, so a catch names which one
    # came back. Both break bench/archive_object_key_session.sh through tests/archive/db/26.
    "archive_object_key_search_path_parent": (
        "bench/archive_object_key_session.sh",
        "Pre-#551 object key: archive._object_key names the parent p_parent::text, regclass output, "
        "which leaves the schema out whenever the calling session's search_path reaches the relation. "
        "Two parents named `evt` in schemas t26a and t26b, sharing a prefix and each ticked under its "
        "own search_path, both upload to <prefix>evt_0.ndjson (and <prefix>pq_0.parquet): the second "
        "PUT overwrites the first while both ledger rows record the key as archived, and retire() has "
        "already dropped the first table's partition. One site: both transports take the key from the "
        "helper.",
        [("  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(c.relname)\n",
          "  select p_prefix || p_parent::text\n", 1)],
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
          "  select case when p_kind = 'id' then p_lo else regexp_replace(p_lo::timestamptz::text, '[^0-9]', '', 'g') end;\n",
          "returns text language sql immutable as $$\n"
          "  select case when p_kind = 'id' then p_lo else regexp_replace(p_lo, '[^0-9]', '', 'g') end;\n", 1)],
    # #498, one mutation per site of the fix, so a catch names which anchor went missing. All three break
    # bench/dropped_fk_identity.sh: the first two through tests/124's own assertions, the third through
    # the wrapper's upgrade half, which is the only place a second run of install.sql happens.
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
        "Pre-#568 _check_text_time_collation: the probe keeps only its first shape per adjacent digit "
        "pair, '<prefix><d><max>...' < '<prefix><d+1><zero>...', which proves the digits are separated "
        "at the primary level for a collation that compares position by position and says nothing about "
        "one that weighs a run of decimal digits by its value. An ICU collation with numeric ordering "
        "('und-u-kn-true') passes it, since the zero padding extends the higher digit's run (1 < 2000...), "
        "so transmute accepts a cuid column under it and RANGE routing disagrees with base-36 order: late "
        "November rows land in the December partition and retain drops them a month early. The two "
        "probe shapes the fix added (the opposite padding, and a lower cell's string extended by a "
        "suffix digit against the next cell's bound) are removed and nothing else. tests/134's "
        "refusals of a cuid and a decimal column on that collation are what catch it.",
        [("      union all\n"
          "      select x.i, x.c, y.c, 1, %3$L || x.c || %6$L, %3$L || y.c || %4$L\n"
          "        from d x join d y on y.i = x.i + 1\n"
          "      union all\n"
          "      select x.i, x.c, y.c, 2 + s.i, %3$L || x.c || %4$L || s.c, %3$L || y.c || %6$L\n"
          "        from d x join d y on y.i = x.i + 1 cross join d s\n",
          "", 1)],
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
        [("    v_sub_rel := pgpm._regrain_copy_rel(p_parent, v_nsp, v_sub_name, 'reconcile captured changes into');\n",
          "    v_sub_rel := format('%I.%I', v_nsp, v_sub_name)::regclass;\n", 1)],
    ),
    "regrain_swap_attaches_named_relation": (
        "bench/regrain_child_oid_sites.sh",
        "Issue #707 (the swap) put back: the swap attaches each copy by its recorded NAME and drops that "
        "relation's _ck, never asking child_oid. A completed copy renamed aside and a table created LIKE it "
        "INCLUDING ALL under its old name is attached in its place, the source is dropped, and the copied "
        "rows leave the managed table. Two sites: the pre-DETACH identity check goes, and the attach loop "
        "resolves by name. tests/184 (A) catches it at the refusal and at rows 10, 20, 30.",
        [("    perform pgpm._regrain_copy_rel(p_parent, v_nsp, r.child_name, 'attach');\n", "    null;\n", 1),
         ("    v_copy := pgpm._regrain_copy_rel(p_parent, v_nsp, r.child_name, 'attach');   -- #707: by recorded oid\n",
          "    v_copy := format('%I.%I', v_nsp, r.child_name)::regclass;\n", 1)],
    ),
    "regrain_cancel_triggers_by_name": (
        "bench/regrain_child_oid_sites.sh",
        "Issue #707 (regrain_cancel) put back: the capture and TRUNCATE-guard triggers are dropped `on` each "
        "pgpm.part row's NAME, so a source renamed aside keeps both for good and a relation that took its "
        "name loses its own triggers of those names. One site: the recorded-oid branch is never taken. "
        "tests/184 (B) catches it on both relations' trigger lists.",
        [("    if r.child_oid is null then\n      v_rel := to_regclass(format('%I.%I', v_nsp, r.child_name));\n",
          "    if true then\n      v_rel := to_regclass(format('%I.%I', v_nsp, r.child_name));\n", 1)],
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
        "every tick and the partition is never covered or retired. One site, the signer's one send.",
        [("    p_ctype, bytea_to_text(convert_to(p_payload, 'UTF8')))::http_request);\n",
          "    p_ctype, p_payload)::http_request);   -- MUTANT: the pre-#728 send, server-encoding bytes\n", 1)],
    ),
    "to_s3_sync_key_bare_child": (
        "bench/archive_edges_pass5.sh",
        "Pre-#711 archive.to_s3 and archive.to_s3_parquet: the object key is <prefix><child><ext>, the "
        "child's bare relname. Two parents named evt in two schemas sharing a prefix export their [0, 10000) "
        "partitions to one key, and the second export replaces the first. One site, the helper both "
        "functions take their key from.",
        [("  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(p_child) || p_ext\n",
          "  select p_prefix || p_child || p_ext   -- MUTANT: the pre-#711 bare-child key\n", 1)],
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
    "tap_verdict_misses_plan_shortfall": (
        "bench/tap_verdict.sh",
        "Pre-#601 test.sh: the timescale and observe tracks call a pgTAP file failed on `not ok`, "
        "'# Looks like you failed' or ERROR:, and not on '# Looks like you planned N tests but ran M', so a "
        "file whose assertion silently never ran (over zero rows, or deleted without lowering plan()) passes "
        "both tracks while pg_prove fails it. Two sites, one per track, the exact pre-#601 pattern.",
        [("grep -qE '^not ok|^# Looks like you (failed|planned)|ERROR:'",
          "grep -qE '^not ok|^# Looks like you failed|ERROR:'", 2)],
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
        "which re-runs the install, is what catches it.",
        [(REGRAIN_CAPTURE_BACKFILL_BLOCK,
          REGRAIN_CAPTURE_BACKFILL_BLOCK.replace(
              "    if v_delta is null\n"
              "       or not exists (select 1 from pg_class c where c.oid = v_delta and c.relkind = 'r' and not c.relispartition)\n"
              "    then continue; end if;\n",
              "    if v_delta is null then continue; end if;\n"), 1)],
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
        [("""  for v_g in
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
  foreach v_tdef in array v_grantdefs loop
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
        [("  perform pgpm._refuse_oid_bound_dependants(p_parent, false, v_parent);\n", "", 1)],
    ),
    "oid_bound_dependants_no_staging_exemption": (
        "bench/transmute_oid_bound_dependants.sh",
        "Issue #779, overreach: the cutover's re-check counts the policies it has just carried onto the new "
        "parent, so a table whose own policy queries the table itself is refused under the lock, after phases "
        "1 and 2 committed the bound, though the preflight let it through. One site, the staging exemption. "
        "tests/205 part A's conversion of dv205 (policy dv205_self) catches it.",
        [("from pg_policy p where p.oid = d.objid and p.polrelid <> p_rel\n"
          "                         and p.polrelid is distinct from p_staging)",
          "from pg_policy p where p.oid = d.objid and p.polrelid <> p_rel)", 1)],
    ),
    "untransmute_oid_bound_dependants_unrefused": (
        "bench/transmute_oid_bound_dependants.sh",
        "Issue #779's symmetric case put back: untransmute asks nothing about objects over the parent, so its "
        "DROP fails raw ('cannot drop table ... because other objects depend on it') on a view, and drops a "
        "rule on the parent along with it without a word. Both sites, the unlocked ask and the one under the "
        "lock. tests/205 part C catches it.",
        [("  perform pgpm._refuse_oid_bound_dependants(p_parent, true);", "  null;", 2)],
    ),
    "regrain_shape_drift_ignored": (
        "bench/regrain_survives_parent_ddl.sh",
        "Issue #785, the pre-fix shape: regrain_step never compares its copies' columns with the parent's. "
        "An ADD COLUMN on the parent mid-regrain fails every later copy and reconcile ('column ... does not "
        "exist'), a DROP COLUMN or a TYPE change fails the swap's ATTACH, and the run never moves again. One "
        "site, the restart branch, switched off. tests/211 parts A and B catch it.",
        [("  if v_drift is not null then\n"
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
        [("    update pgpm.config set regrain_cursor = v_lo where parent_table = p_parent;\n"
          "    insert into pgpm.log (parent_table, action, lo, hi, rows, method)\n"
          "      values (p_parent, 'regrain_restart', v_lo, v_hi, v_made,\n",
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
    "hypertable_cutover_carries_insert_blocker": "pgpm_hypertable/install.sql",
    "hypertable_cutover_carries_capture": "pgpm_hypertable/install.sql",
    "hypertable_key_unchecked": "pgpm_hypertable/install.sql",
    "hypertable_cutover_key_unchecked_under_lock": "pgpm_hypertable/install.sql",
    "hypertable_frontier_unchecked_up_front": "pgpm_hypertable/install.sql",
    "hypertable_cutover_frontier_unchecked": "pgpm_hypertable/install.sql",
    "hypertable_cutover_force_frontier_dropped": "pgpm_hypertable/install.sql",
    "hypertable_force_frontier_not_to_cutover": "pgpm_hypertable/install.sql",
    "archive_lz77_hash_scratch": "pgpm_archive/install.sql",
    "archive_encode_array_agg_unnest": "pgpm_archive/install.sql",
    "archive_deflate_six_arrays": "pgpm_archive/install.sql",
    "archive_from_item_raw_splice": "pgpm_archive/install.sql",
    "archive_order_by_raw_splice": "pgpm_archive/install.sql",
    "parquet_per_column_statements": "pgpm_archive/install.sql",
    "archive_encode_no_partition_tz": "pgpm_archive/install.sql",
    "archive_object_key_digits_only": "pgpm_archive/install.sql",
    "archive_object_key_search_path_parent": "pgpm_archive/install.sql",
    "archive_object_key_session_zone": "pgpm_archive/install.sql",
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
    # The harness and review tooling guard themselves too (#598 to #601): their defects live in the
    # scripts, a doc and a test file, so that is what these mutate.
    "keep_both_two_way_only": "scripts/review/keep_both.py",
    "onboarding_ts_versions": "ONBOARDING.md",
    "runbook_retain_count_of_intervals": "docs/runbook.md",
    "reference_archive_identity_forget_missing": "docs/reference.md",
    "reference_fks_suspended_dead_swap": "docs/reference.md",
    "reference_keyless_monolith_dormant": "docs/reference.md",
    "classify_tap_needs_description": "scripts/review/classify_claims.py",
    "classify_sh_exit_code_only": "scripts/review/classify_claims.py",
    "classify_premise_bare_word": "scripts/review/classify_claims.py",
    "throws_ok_one_argument": "tests/72_transmute_attributes_test.sql",
    "tap_verdict_misses_plan_shortfall": "test.sh",
    # #795 and #712: a timescale wrapper's own verdict block, judged by the guard that evaluates it.
    "wrapper_verdict_reads_finish_only": "bench/hypertable_index_names.sh",
    "wrapper_verdict_no_shortfall_check": "bench/hypertable_late_appends.sh",
    "wrapper_verdict_ignores_exit": "bench/hypertable_cutover_identity.sh",
    "discriminate_counts_uninstallable": "bench/discriminate.sh",
    "discriminate_list_on_stdin": "bench/discriminate.sh",
    # #742 to #744: a lint's document and three test files, each judged by the guard that runs it.
    "runbook_phantom_alert_action": "docs/runbook.md",
    "orphan_refusal_sqlstate_only": "tests/18_orphan_child_guard_test.sql",
    "radix_length_refusal_unpinned": "tests/90_text_time_alphabet_codec_test.sql",
    "id_conservation_after_migration": "tests/11_id_kind_test.sql",
    "uuid_conservation_after_migration": "tests/12_uuidv7_kind_test.sql",
    "hypertable_preflight_reads_under_caller_rls": "pgpm_hypertable/install.sql",
    "hypertable_cutover_reads_under_caller_rls": "pgpm_hypertable/install.sql",
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
    "hypertable_preflight_reads_under_caller_rls": "timescale",
    "hypertable_cutover_reads_under_caller_rls": "timescale",
}


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
        for name, (guard, why, _) in MUTATIONS.items():
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
