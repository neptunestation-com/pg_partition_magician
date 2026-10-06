-- Uninstall pg_partition_magician.
--
-- Removes the MANAGER, not your data.
--
-- Removed:
--   * schema pgpm and everything in it: config, part, log, the registry tables, every
--     function and view, the version record
--   * every pg_cron job pgpm scheduled (matched by the pgpm prefix)
--   * the pgpm_write_block triggers on frozen children (their function lives in pgpm,
--     so the schema drop takes them)
--   * regrain's change capture, which lives in the PARENT's schema and so is out of the
--     schema drop's reach: the per-parent delta table <rel>_pgpm_regrain_delta (with its
--     identity sequence and index), the trigger function <rel>_pgpm_regrain_capture(),
--     and the pgpm_regrain_capture row trigger it drives on a child being regrained (a
--     name that would exceed 63 bytes is pgpm_regrain_delta_<oid> or
--     pgpm_regrain_capture_<oid>() instead, never cut to 63 bytes: for a 63-byte table
--     name the cut one would be the table itself)
--   * an in-flight regrain's not-yet-attached fine copies, abandoned through
--     pgpm.regrain_cancel (the source still holds every row, so only the copy work is lost)
--   * from_hypertable's change capture, left in the hypertable's schema by a
--     from_hypertable_copy(..., p_track_changes => true) that was never cut over: the delta
--     <rel>_pgpm_delta, the trigger function <rel>_pgpm_delta_fn(), and the <rel>_pgpm_delta_trg
--     row trigger it drives on the live hypertable and its chunks (found by pgpm.scratch, by oid
--     whatever they are called now, or by the comment an earlier release's copy kept on its delta;
--     see the schema drop's block)
--   * from_hypertable's copy, left in the hypertable's schema by a from_hypertable_copy that was never cut
--     over: the table <rel>_pgpm_dest (a full second copy of the hypertable's rows) with its indexes and the
--     outgoing foreign keys the copy replayed on it (found by pgpm.scratch, by oid whatever it is called
--     now, or by the comment an earlier release's copy kept on it, and dropped only while the hypertable it
--     was copied from still exists; see the schema drop's block)
--
-- Put back first:
--   * every incoming foreign key transmute(..., p_incoming_fks => 'preserve') dropped and
--     pgpm has not restored yet (a paused table's are never restored by maintain), through
--     pgpm.restore_incoming_fks, as maintain would. pgpm.dropped_fk is the only record of
--     such a key, so while any of them cannot be restored this script REFUSES and drops
--     nothing; its message carries each key's DDL and why the re-add failed. A key comes
--     back NOT VALID (enforcing every new write), and a WARNING names each key pgpm tracked
--     that is still NOT VALID, since nothing will validate it once pgpm is gone.
--
-- Left in place, on purpose:
--   * every transmuted table, still a partitioned table under its original name, with
--     all of its partitions (the monolith, the forward grid, any fine children a regrain
--     built and attached, the DEFAULT) and every row. Nothing pgpm made survives in your
--     schema except those relations.
--   * a from_hypertable copy that was never cut over whose hypertable no longer exists: it
--     may hold the only copy of those rows, so a WARNING names it and you decide
--
-- The one thing this script cannot undo is a conversion abandoned between transmute's
-- phases: its pgpm_monolith_bound CHECK rejects writes outside the recorded range, and
-- the claim that records it (pgpm.transmute_inflight) goes away with the schema. Run
-- `select pgpm.transmute_abort('schema.table')` for any such table BEFORE this script.
--
-- Run with: psql --single-transaction -f pgpm_core/uninstall.sql

-- Unschedule every pgpm cron job (matched by prefix so this stays correct as the
-- cron surface evolves). Best-effort and tolerant of missing pg_cron / privileges.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobname) from cron.job where jobname like 'pgpm%';
  end if;
exception
  when undefined_table then null;
  when undefined_function then null;
  when insufficient_privilege then null;
end;
$$;

-- Drop regrain's change capture from every managed parent's schema. The delta table and its
-- trigger function are deliberately persistent per parent (a completed regrain keeps them for the
-- next one), and nothing in them depends on pgpm: the function's body names only the delta table.
-- So the schema drop below leaves all three, and a trigger left on a child mid-regrain keeps
-- appending to a delta table nothing will ever drain. untransmute drops the same two objects the
-- same way; this is the other exit. The names come from pgpm._regrain_capture_names, the single
-- resolver every caller uses (the oids pgpm.config recorded at prepare, or failing those the names
-- derived from the parent), which is why this block has to run BEFORE the schema drop.
do $$
declare r record; v_nsp name; v_delta name; v_fn name; v_copies_q text;
begin
  for r in select parent_table from pgpm.config loop
    begin
      select nsp, delta, fn into v_nsp, v_delta, v_fn from pgpm._regrain_capture_names(r.parent_table);
      -- A parent dropped without untransmute has no relation to derive the names from (the lookup
      -- returns nulls, and %I refuses a null). Its partitions went with it, and the trigger with
      -- them, so what it may have left is an inert table and function this script cannot name.
      if v_nsp is null then continue; end if;
      -- An in-flight regrain's fine copies are standalone tables in the parent's schema, recorded
      -- only in pgpm.part (attached = false), so the schema drop takes the one record that says what
      -- they are and leaves the tables. Abandon the regrain the way untransmute and the operator's
      -- own escape do, through regrain_cancel, so the three cannot drift: trigger and TRUNCATE guard
      -- off every child, delta cleared, copies dropped with their part rows, cursor null. The source
      -- still holds every row until the swap, and the swap attaches every copy in one transaction, so
      -- a copy is never the only home of a row. The two tests are the marks an in-flight regrain
      -- leaves in pgpm's own tables (the third, a live capture trigger, goes with the function below).
      select string_agg(format('%I.%I', v_nsp, child_name), ', ' order by child_name) into v_copies_q
        from pgpm.part where parent_table = r.parent_table and not attached;
      if v_copies_q is not null
         or exists (select 1 from pgpm.config where parent_table = r.parent_table and regrain_cursor is not null) then
        perform pgpm.regrain_cancel(r.parent_table);
      end if;
      -- Existence is checked first only to spare the operator a "does not exist, skipping" notice
      -- for every parent that never regrained. The trigger depends on the function, so the cascade
      -- is what removes it; the delta table depends on nothing.
      -- #955: only what pgpm.config recorded (the resolver leaves the names null otherwise), never a relation
      -- or function of the operator's that happens to carry the derived name.
      if v_fn is not null then
        execute format('drop function if exists %I.%I() cascade', v_nsp, v_fn);
      end if;
      if v_delta is not null then
        execute format('drop table if exists %I.%I', v_nsp, v_delta);
      end if;
    exception
      -- Best-effort per parent, like the cron block above: one parent's trouble must not stop the
      -- uninstall or the sweep of the other parents. Only the condition this script can actually
      -- meet is caught, so anything else still surfaces. The capture objects are owned by whoever
      -- ran the regrain (under cron that is the scheduling role), and the role running this script
      -- may not be allowed to drop them; say what is left rather than leaving it silently.
      when insufficient_privilege then
        raise warning 'pg_partition_magician: could not drop the regrain change capture of % (%). Left behind: table %.%, function %.%() and any pgpm_regrain_capture trigger it drives, and the in-flight regrain''s not-yet-attached copies (%). Drop them as their owner.',
          r.parent_table, sqlerrm, v_nsp, v_delta, v_nsp, v_fn, coalesce(v_copies_q, 'none');
    end;
  end loop;
exception
  -- undefined_table: pgpm.config is already gone, so this is a re-run; `drop schema if exists`
  --   below makes a re-run a no-op, and this block has to as well.
  -- undefined_function: an install that predates regrain change capture has no
  --   pgpm._regrain_capture_names, and nothing for this block to remove.
  when undefined_table then null;
  when undefined_function then null;
end;
$$;

-- Put back every incoming foreign key transmute(..., p_incoming_fks => 'preserve') dropped and pgpm has
-- not restored yet, then drop the schema, or refuse. Such a key is dropped at the cutover and re-added by a
-- later maintenance tick, and a paused table (transmute's default) gets no ticks, so it can sit dropped
-- indefinitely with pgpm.dropped_fk as the only record of it; the schema drop used to take that record and
-- the key was gone for good, with no warning. restore_incoming_fks is the path maintain takes, so the key
-- comes back exactly as a tick would bring it, NOT VALID on a plain referencer. It runs after the block
-- above, whose regrain_cancel removes the one thing its gate waits for (a not-yet-attached child).
--
-- A key it cannot restore (an orphan written while RI was off, on a referencer Postgres will only re-add
-- validating; a column since dropped) is REFUSED on rather than lost: the exception stops the schema drop,
-- and under --single-transaction rolls the whole script back. Its message carries the DDL and the reason,
-- because the rollback also takes the pgpm.log row restore_incoming_fks wrote. Deleting the key's row from
-- pgpm.dropped_fk is how an operator says they accept losing it. A record whose referencing table or parent
-- no longer exists is not refused on (there is no key left to lose), nor is one whose key is live again
-- under its name, against its parent, because the operator re-added it by hand.
--
-- The schema drop is inside this block, not after it, so a client that carries on past an error (psql
-- without ON_ERROR_STOP and without --single-transaction, a SQL editor) cannot reach the drop around the
-- refusal.
do $$
declare
  r record; v_mark bigint; v_left_q text; v_unvalidated_q text; v_fn name; v_done oid[] := '{}';
begin
  if to_regnamespace('pgpm') is null then return; end if;          -- a re-run: nothing left to remove
  begin
    select coalesce(max(id), 0) into v_mark from pgpm.log;
    for r in select distinct d.parent_table from pgpm.dropped_fk d
              where d.restored_at is null
                and exists (select 1 from pg_class c where c.oid = d.parent_table)
                and exists (select 1 from pgpm.config c where c.parent_table = d.parent_table) loop
      perform pgpm.restore_incoming_fks(r.parent_table);
    end loop;

    select string_agg(format('alter table %s add constraint %I %s (%s)',
                             d.referencing_table::text, d.constraint_name, d.definition,
                             coalesce((select l.method from pgpm.log l
                                        where l.id > v_mark and l.parent_table = d.parent_table
                                          and l.action = 'fail_restore_incoming_fk'
                                          and starts_with(l.method, d.constraint_name || ': ')
                                        order by l.id desc limit 1),
                                      'not re-added: ' || d.parent_table::text
                                        || ' is no longer managed, or has a child that is not attached yet')),
                      '; ' order by d.id)
      into v_left_q
      from pgpm.dropped_fk d
     where d.restored_at is null
       and exists (select 1 from pg_class c where c.oid = d.parent_table)
       and exists (select 1 from pg_class c where c.oid = d.referencing_table)
       -- re-added by hand since (the message below offers that): the key is live, so nothing is lost. The
       -- key, not its name (#872): a foreign key on that table under that name AGAINST THIS PARENT, the
       -- match _forget_dangling_fks adopts by. A namesake against another table is not this key, and
       -- exempting the record for it let the schema drop take the only record of the real one.
       and not exists (select 1 from pg_constraint c
                        where c.conrelid = d.referencing_table and c.conname = d.constraint_name and c.contype = 'f'
                          and c.confrelid = d.parent_table);
    if v_left_q is not null then
      raise exception 'pg_partition_magician: refusing to uninstall: these incoming foreign keys, dropped by transmute(..., p_incoming_fks => ''preserve''), could not be restored, and pgpm.dropped_fk is the only record of them: %. Clear what blocks each one and re-run this script, or re-add it by hand, or accept losing it by deleting its row from pgpm.dropped_fk; then re-run.',
        v_left_q;
    end if;

    select string_agg(format('alter table %s validate constraint %I', d.referencing_table::text, d.constraint_name),
                      '; ' order by d.id)
      into v_unvalidated_q
      from pgpm.dropped_fk d join pg_constraint c
        on c.conrelid = d.referencing_table and c.conname = d.constraint_name and c.contype = 'f'
     where not c.convalidated;
    if v_unvalidated_q is not null then
      raise warning 'pg_partition_magician: these incoming foreign keys are back NOT VALID: they enforce every new write, but the rows already there are unverified, and nothing will validate them once pgpm is gone. Run, when convenient (it scans the referencing table without blocking writes): %',
        v_unvalidated_q;
    end if;
  exception
    -- An install that predates pgpm.dropped_fk has no key to put back.
    when undefined_table then null;
  end;

  -- Drop EVERY object pgpm.scratch records (#955, #985), by its oid, whatever it is called now and whatever has
  -- become of the comment the copy also puts on it: from_hypertable_copy records the copy, a tracking copy's
  -- delta and its trigger function there, in the transaction that creates each, and the drains and the cutover
  -- find them by that record, so a copy or delta renamed or moved since is still pgpm's. The comment sweeps
  -- below require the <rel>_pgpm_delta / <rel>_pgpm_dest name as well as the comment, so they cannot be what
  -- finds a recorded object: they are for a copy made before the record existed, and skip whatever this sweep
  -- handled (v_done), so a copy this sweep keeps is not warned about twice. The function first (CASCADE takes
  -- its row trigger on the hypertable and every chunk), then the delta, then the copy, dropped only while the
  -- hypertable it was copied from still exists, as the sweep below does it (#773).
  begin
    for r in
      select s.parent_oid, s.kind, s.obj from pgpm.scratch s
       order by s.kind desc, s.obj
    loop
      v_done := v_done || r.obj;
      begin
        if r.kind = 'hypertable_delta_fn' then
          if exists (select 1 from pg_proc where oid = r.obj) then
            execute format('drop function %s cascade', r.obj::regprocedure::text);
          end if;
        elsif not exists (select 1 from pg_class where oid = r.obj) then
          null;
        elsif r.kind = 'hypertable_delta' then
          execute format('drop table %s', r.obj::regclass::text);
        elsif not exists (select 1 from pg_class where oid = r.parent_oid) then
          raise warning 'pg_partition_magician: left behind %, a from_hypertable copy that was never cut over: the hypertable it was copied from (oid %) no longer exists, so this table may hold the only copy of those rows. Drop it once you have checked.',
            r.obj::regclass::text, r.parent_oid;
        else
          execute format('drop table %s', r.obj::regclass::text);
        end if;
      exception
        when insufficient_privilege or dependent_objects_still_exist then
          raise warning 'pg_partition_magician: could not drop %, from_hypertable''s % of the hypertable with oid % (%). It is left behind; drop it as its owner.',
            case when r.kind = 'hypertable_delta_fn' then r.obj::regprocedure::text else r.obj::regclass::text end,
            r.kind, r.parent_oid, sqlerrm;
      end;
    end loop;
  exception
    -- An install that predates pgpm.scratch has recorded nothing; the comment sweeps below cover it.
    when undefined_table then null;
  end;

  -- Drop from_hypertable's change capture (#737). A from_hypertable_copy(..., p_track_changes => true) puts
  -- three objects in the HYPERTABLE's schema, out of the schema drop's reach: the delta <rel>_pgpm_delta,
  -- its trigger function <rel>_pgpm_delta_fn(), and the row trigger <rel>_pgpm_delta_trg on the live
  -- hypertable (TimescaleDB clones it onto every chunk). The cutover drops all three; a copy never cut over
  -- keeps them, and the trigger goes on logging every write of the production table into a delta nothing
  -- will drain.
  --
  -- Found by the module's own record, never by a name pattern (an operator's table can end in
  -- _pgpm_delta): the copy comments its delta `pgpm from_hypertable horizon <xid>` in the transaction that
  -- creates the function and the trigger, so a delta carrying it is the module's, and so is the function
  -- the copy created beside it under the derived name. Dropping that function cascades to the trigger on
  -- the hypertable and on each chunk. Here, past the refusal and beside the schema drop, for the same
  -- reason the drop is: a refused uninstall must leave a copy that can still be cut over with its capture.
  -- A tracking copy made by a release that wrote no such comment (0.6.0 and earlier) has no record; drop
  -- its three objects by hand. A copy pgpm.scratch records is the record sweep's above, by oid (#985): this
  -- sweep is for a delta the record does not name, and skips what that sweep handled.
  for r in
    select n.nspname as nsp, c.relname as delta
      from pg_description d
      join pg_class c on c.oid = d.objoid
      join pg_namespace n on n.oid = c.relnamespace
     where d.classoid = 'pg_class'::regclass and d.objsubid = 0
       and d.description ~ '^pgpm from_hypertable horizon [0-9]+$'
       and c.relkind = 'r' and right(c.relname, 11) = '_pgpm_delta'
       and c.oid <> all (v_done)
     order by n.nspname, c.relname
  loop
    v_fn := left(r.delta, -11) || '_pgpm_delta_fn';
    begin
      -- Existence first only to spare a "does not exist, skipping" notice; the delta depends on nothing.
      if to_regprocedure(format('%I.%I()', r.nsp, v_fn)) is not null then
        execute format('drop function %I.%I() cascade', r.nsp, v_fn);
      end if;
      execute format('drop table %I.%I', r.nsp, r.delta);
    exception
      -- Best-effort per copy, as the regrain sweep above: the objects belong to whoever ran the copy, and
      -- the role running this script may not be allowed to drop them. Say what is left.
      when insufficient_privilege then
        raise warning 'pg_partition_magician: could not drop the from_hypertable change capture %.% (%). Left behind: table %.%, function %.%() and the row trigger it drives on the hypertable and its chunks, which logs every write. Drop them as their owner.',
          quote_ident(r.nsp), quote_ident(r.delta), sqlerrm, quote_ident(r.nsp), quote_ident(r.delta),
          quote_ident(r.nsp), quote_ident(v_fn);
    end;
  end loop;

  -- Drop from_hypertable's copies that were never cut over (#773). from_hypertable_copy builds <rel>_pgpm_dest
  -- in the hypertable's schema, a full second copy of its rows that still holds the outgoing foreign keys the
  -- copy replayed on it (and, for a tracking copy, its pre-built key index), so a referenced row the
  -- hypertable no longer uses could not be deleted. The cutover renames it into the hypertable's place; a
  -- copy never cut over keeps it, out of the schema drop's reach.
  --
  -- Found by the module's own record, never by its name alone (an operator's table can end in _pgpm_dest):
  -- the copy comments the table `pgpm from_hypertable copy of <hypertable oid>` in the transaction that
  -- creates it, and the swap replaces that comment, so a table carrying it is a copy that was never cut over.
  -- Dropped only while the hypertable it names still exists, since the hypertable then holds every row and
  -- only the copy work is lost. A copy whose hypertable is gone may be the only home of those rows, so it is
  -- left, with a WARNING naming it. A copy made by a release that wrote no record (0.6.0 and earlier) is not
  -- found; drop it by hand. A copy pgpm.scratch records is the record sweep's above, by oid (#985): this sweep
  -- is for a copy the record does not name, and skips what that sweep handled.
  for r in
    select n.nspname as nsp, c.relname as dest,
           substring(d.description from '^pgpm from_hypertable copy of ([0-9]+)$')::oid as src
      from pg_description d
      join pg_class c on c.oid = d.objoid
      join pg_namespace n on n.oid = c.relnamespace
     where d.classoid = 'pg_class'::regclass and d.objsubid = 0
       and d.description ~ '^pgpm from_hypertable copy of [0-9]+$'
       and c.relkind = 'r' and right(c.relname, 10) = '_pgpm_dest'
       and c.oid <> all (v_done)
     order by n.nspname, c.relname
  loop
    if not exists (select 1 from pg_class s where s.oid = r.src) then
      raise warning 'pg_partition_magician: left behind %.%, a from_hypertable copy that was never cut over: the hypertable it was copied from (oid %) no longer exists, so this table may hold the only copy of those rows. Drop it once you have checked.',
        quote_ident(r.nsp), quote_ident(r.dest), r.src;
      continue;
    end if;
    begin
      execute format('drop table %I.%I', r.nsp, r.dest);
    exception
      -- Best-effort per copy, as the sweeps above: the copy belongs to whoever ran it, and something of the
      -- operator's (a view) may depend on it. Say what is left.
      when insufficient_privilege or dependent_objects_still_exist then
        raise warning 'pg_partition_magician: could not drop %.%, a from_hypertable copy that was never cut over (%). It is left behind with its rows; drop it as its owner.',
          quote_ident(r.nsp), quote_ident(r.dest), sqlerrm;
    end;
  end loop;

  drop schema if exists pgpm cascade;
end;
$$;
