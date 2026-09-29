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
--     and the pgpm_regrain_capture row trigger it drives on a child being regrained
--   * an in-flight regrain's not-yet-attached fine copies, abandoned through
--     pgpm.regrain_cancel (the source still holds every row, so only the copy work is lost)
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
      if to_regprocedure(format('%I.%I()', v_nsp, v_fn)) is not null then
        execute format('drop function if exists %I.%I() cascade', v_nsp, v_fn);
      end if;
      if to_regclass(format('%I.%I', v_nsp, v_delta)) is not null then
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
-- under its name because the operator re-added it by hand.
--
-- The schema drop is inside this block, not after it, so a client that carries on past an error (psql
-- without ON_ERROR_STOP and without --single-transaction, a SQL editor) cannot reach the drop around the
-- refusal.
do $$
declare
  r record; v_mark bigint; v_left_q text; v_unvalidated_q text;
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
       -- re-added by hand since (the message below offers that): the key is live, so nothing is lost
       and not exists (select 1 from pg_constraint c
                        where c.conrelid = d.referencing_table and c.conname = d.constraint_name and c.contype = 'f');
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
  drop schema if exists pgpm cascade;
end;
$$;
