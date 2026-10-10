-- Operator utility, not a pgpm feature: archives the OLDEST currently write-blocked,
-- not-yet-archive-covered partition of a managed table in exactly one call -- one file for that
-- partition -- bypassing config.archive_byte_budget/archive_batch's chunker entirely.
--
-- WHY THIS EXISTS. pgpm.maintain()'s automatic archiver (pgpm._archive_step) paces itself by
-- estimating how many rows fit config.archive_byte_budget and archiving that many per tick, which
-- is the right default (a large partition archived as one giant operation risks statement_timeout),
-- but sizing that budget to land on "one file per partition" requires measuring the table's real
-- per-row compression ratio and multiplying by its row count -- fiddly, and easy to get wrong in
-- either direction (too small: many small files; too large: back to the statement_timeout risk the
-- chunker exists to avoid). This sidesteps the sizing problem: instead of tuning a byte budget and
-- hoping it lands on the partition's actual size, it calls the table's configured archive_fn
-- directly on the partition's own [lo, hi) -- one partition, one call, one file -- and leaves only
-- statement_timeout to size (see below).
--
-- ONE PARTITION PER CALL, DELIBERATELY -- NOT A LOOP OVER THE WHOLE BACKLOG. An earlier version of
-- this script looped over every eligible partition inside one PROCEDURE, committing between each,
-- on the theory that the commit would give each partition its own fresh statement_timeout window.
-- That theory is wrong, verified directly: statement_timeout is enforced cumulatively across a
-- whole top-level CALL, and does NOT reset at an internal COMMIT (proved with a 3-segment,
-- 1.5s-each test procedure under a 2s statement_timeout -- it failed at 2.0s total, not 4.5s, even
-- though each individual segment was well under the timeout on its own). A procedure that loops
-- over N partitions internally is exactly as exposed to statement_timeout as if it had no commits
-- at all; the commits only protect against OTHER things (a long-held lock, an aborted transaction
-- losing more than necessary), not against the timeout accumulating.
--
-- The actual fix: this is a FUNCTION that processes exactly the single oldest eligible partition
-- and returns. To drain a backlog of several partitions, call it repeatedly -- each invocation is a
-- genuinely separate top-level statement, and only a separate top-level statement actually gets a
-- fresh statement_timeout clock. Options for repeating it:
--   - by hand: run the SELECT again, read the returned status, repeat until it says nothing is left.
--   - psql's \watch, which re-issues a query as a new statement each time (waits for one to finish
--     before starting the next, so calls never overlap):
--       select pgpm_archive_next_partition_whole('myschema.mytable'::regclass) \watch 5
--   - a shell loop invoking `psql -c "select ..."` repeatedly -- each psql invocation is its own
--     connection, trivially a fresh statement_timeout each time.
--
-- SAFE TO RE-RUN, AND SAFE ALONGSIDE maintain(). Resumes from wherever pgpm.archive_ledger's
-- coverage of the chosen partition already left off (the same watermark pgpm._next_archive_chunk
-- itself reads), not always from the partition's own lo -- so if maintain()'s own byte-budget
-- chunker already made partial progress on it (normal, not a conflict), this picks up from there
-- instead of re-archiving already-covered rows or hitting archive_ledger's (parent_table, lo)
-- primary key. Returns a plain status message when nothing is eligible, rather than an error, so
-- repeated calls are always safe to make (e.g. from \watch) without checking state first.
--
-- THE STRATEGY'S RETURN IS HELD TO THE ARCHIVE CONTRACT, the one pgpm._archive_step holds it to
-- (issue #454): a covered_hi that is null, not above the range's lo, past its hi, or not a value of
-- the control's type (on an id grid, of the control column's own type: a fraction on an integer key, #1071)
-- is refused BEFORE anything is written to pgpm.archive_ledger (retire()'s drop
-- precondition), logged fail_archive_contract, and reported in the returned message. Nothing is
-- recorded, so the partition stays unarchived and undroppable until the strategy is fixed. And a
-- caller whose reads of the parent or the partition row-level security filters is refused before the
-- strategy runs, as _archive_step refuses it, logged skip_archive: run it as a role with BYPASSRLS (or
-- a superuser) on a table with FORCE ROW LEVEL SECURITY.
--
-- STATEMENT_TIMEOUT IS THE ONE THING LEFT TO SIZE, AND IT'S ON YOU: pgpm never manages
-- statement_timeout itself. Size it from a real measured single-partition archive time, not a
-- guess. A partition too large to finish inside it (or too large for Parquet's own ~1 GiB bytea
-- ceiling -- the whole file is built in memory before upload) reports a partial result and needs
-- another call, or a smaller-than-"whole-partition" approach instead (config.archive_byte_budget's
-- ordinary chunking).
--
-- Requires pgpm_core (any version that ships pgpm._run_archive_strategy/_is_write_blocked/
-- _archive_fully_covered/_native_type/_native_gt -- these predate this script, not new in any
-- particular release), plus pgpm._archive_contract_breach (issue #454; the five-argument form that takes the
-- parent and holds an id grid's covered_hi to the control column's type, issue #1071), pgpm._native_text (issue
-- #977) and pgpm._refuse_filtered_reads (issue #873) for the contract check, the ledger's canonical
-- hi and the row-level security refusal, pgpm._max_hi_native (issue #500) for the canonical resume
-- watermark, pgpm._child_nsp (issue #727) for the partition's own schema, pgpm.archive_ledger.retired_at and
-- pgpm._over_retired_chunks and pgpm.archive_ledger.child_oid (issue #1141) to leave retired chunks and the partitions over them alone, pgpm._part_detached_by_hand (issue #705) and pgpm._archive_hold_partition to leave a table the operator detached by hand alone, before or during the call (issue #1159), plus pgpm.part.child_oid for the identity check below (issue #421; added after this
-- script, so an older core needs that check removed along with the column reference). Not part of pgpm_core/install.sql and never will be without a real feature proposal
-- and its own issue/PR -- this is scratch space for an operator to paste into a session and run,
-- not a shipped, versioned function.
--
-- Usage:
--   \i scripts/archive_partition_whole.sql          -- defines the function, once per session
--   set statement_timeout = '...';                  -- sized from a real measured single-partition archive time
--   select pgpm_archive_next_partition_whole('myschema.mytable'::regclass);   -- repeat until it says nothing is left

create or replace function pgpm_archive_next_partition_whole(p_parent regclass)
returns text language plpgsql as $$
declare
  cfg pgpm.config;
  r record;
  v_resume_lo text;
  v_ncast text;
  v_nsp name;
  v_now regclass;
  v_result pgpm.archive_result;
  v_breach text;
  v_found int;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then
    raise exception 'pg_partition_magician: % is not managed', p_parent;
  end if;
  if cfg.archive_fn is null then
    return format('%s has no archive_fn configured -- nothing to do', p_parent);
  end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  -- #1141: chunks whose relation was dropped outside retire() are marked retired first, as a tick marks them,
  -- so the partition over their range is held below rather than written over their objects
  perform pgpm._mark_gone_chunks(p_parent);

  -- Oldest first in the control's NATIVE order, as pgpm._archive_step orders its candidates: pgpm.part.lo is
  -- text, and as text '1000' sorts before '200', so an id grid crossing a power of ten handed out a newer
  -- partition ahead of an older one (issue #1054). EXECUTE does not set FOUND, so the row count says whether
  -- anything was eligible. A partition over the range of a chunk retire() marked retired is not one, as it is
  -- not one of _archive_step's (#1141): archived, it would go to the retired chunk's object key, over the only
  -- copy of the rows that drop removed; the tick logs skip_archive_retired_range for it, with the remedy. Nor is a
  -- table the operator DETACHed by hand (#705, #1159, pgpm._part_detached_by_hand), which keeps its attached
  -- pgpm.part row and pgpm's write block: a strategy reading the range through the parent finds none of its rows,
  -- and the coverage recorded for it would let retire() drop it, rows and all, once it is attached back. As in
  -- _archive_step it is never handed to the strategy and no coverage is recorded for it; left out here, before
  -- `limit 1`, the call goes to the next eligible partition.
  execute format(
    'select p.child_name, p.lo, p.hi, p.child_oid, p.retiring_at from pgpm.part p
      where p.parent_table = %L::regclass and p.attached
        and not pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
        and pgpm._is_write_blocked(%L::regclass, p.child_name)
        and not pgpm._archive_fully_covered(%L::regclass, p.child_name)
        and p.child_name not in (select o.child_name from pgpm._over_retired_chunks(%L::regclass) o)
      order by p.lo::%s
      limit 1',
    p_parent::text, p_parent::text, p_parent::text, p_parent::text, v_ncast)
    into r;
  get diagnostics v_found = row_count;

  if v_found = 0 then
    return format('nothing eligible left to archive for %s', p_parent);
  end if;

  -- The same identity check pgpm._archive_step makes, for the same reason (#421), because this
  -- writes the same kind of pgpm.archive_ledger row and that ledger is retire()'s drop precondition:
  -- a coverage claim built by reading whatever answers to child_name is what authorises dropping the
  -- partition that name was recorded for. Returned as a message rather than logged as
  -- fail_archive_identity -- this is a hand-run function, so its caller is reading the output. tests/289
  -- guards where it looks (parts C and D: a moved parent's partition is archived, a relation that took
  -- the name in the partition's own schema is refused). The name is resolved in the PARTITION's own schema, through pgpm._child_nsp, as _archive_step
  -- resolves it (#727): ALTER TABLE <parent> SET SCHEMA moves the parent alone, and looking in the
  -- parent's schema found nothing under the name and refused the intact partition (issue #1054).
  v_nsp := pgpm._child_nsp(p_parent, r.child_name);
  v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));
  if r.child_oid is not null and v_now::oid is distinct from r.child_oid then
    return format('%I.%I is oid %s now, not the oid %s recorded for this partition -- REFUSING to archive it. '
                  'Something took the name. Put the intended relation back under it, or clear the stale pgpm.part row.',
                  v_nsp, r.child_name, coalesce(v_now::oid::text, 'nothing'), r.child_oid);
  end if;

  -- Hold the parent against a DETACH and ask again under that hold, before anything reads the partition: the
  -- call pgpm._archive_step makes at the same point (#1159; pgpm._archive_hold_partition says why). An operator's
  -- DETACH PARTITION in flight when the candidate query ran was invisible to it; without the hold the strategy's
  -- read through the parent waited for it and, once it committed, found none of the table's rows, and the range
  -- was recorded as covered. A table that left the parent while this waited is not archived and nothing is
  -- recorded. No lock_timeout is set here, unlike maintain()'s 200 ms: this is a hand-run call whose wait the
  -- caller can see and cancel, it waited just as long before (the strategy's read queued behind the same lock),
  -- and the header leaves statement_timeout, the bound on the whole call, to the caller.
  if not pgpm._archive_hold_partition(p_parent, r.child_oid, r.retiring_at) then
    return format('%I.%I left %s while this call waited for its lock (detached or dropped by hand), so it was not '
                  'archived and nothing was recorded for it. Call again for the next partition.',
                  v_nsp, r.child_name, p_parent);
  end if;

  -- Refuse a caller whose reads row-level security filters, BEFORE the strategy runs: the lever (#873)
  -- pgpm._archive_step applies to the same two relations, with the same calls. The strategy reads the rows as
  -- this caller, through the parent (pgpm_archive's transports) or the partition itself, and the ledger row it
  -- leads to opens retire()'s drop gate; under a FORCE ROW LEVEL SECURITY policy the strategy would archive
  -- only the rows the policy admits, report the whole range covered, and retire() would drop the others with
  -- the partition. Logged as the skip_archive _archive_step's handler writes for this refusal, over the
  -- partition's range, and returned as the message; nothing is read or recorded.
  begin
    perform pgpm._refuse_filtered_reads(p_parent, 'archive a partition of',
      'an archive strategy reading the partition through it would archive only those rows, and retention would drop the others with the partition');
    perform pgpm._refuse_filtered_reads(v_now, 'archive',
      'the partition would be archived from those rows alone, and retention would drop the others with the partition');
  exception when raise_exception then
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'skip_archive', r.lo, r.hi, left(sqlerrm, 200));
    return format('%s: REFUSING to archive it: %s', r.child_name, sqlerrm);
  end;

  -- resume from wherever this child's ledger coverage already left off, the same watermark
  -- _next_archive_chunk itself reads -- NOT always the child's own lo -- and in the same canonical text,
  -- through pgpm._max_hi_native (#500): it is written below as the next ledger row's lo, which every other
  -- session reads back. A bare ::text rendered it in the CALLER's DateStyle ('13/08/2026 12:00:00 UTC'
  -- under SQL, DMY), and once the partition was retired _archive_step's #511 discard query cast that lo
  -- under the default DateStyle and raised on every tick (issue #1054). A retired chunk is no live
  -- partition's coverage, as _next_archive_chunk reads it (#1141), and neither is a chunk read from another
  -- relation of the name (its child_oid is not this relation's).
  execute format('select %s from pgpm.archive_ledger where parent_table = %L::regclass and child_name = %L and retired_at is null
                    and (child_oid is null or child_oid = %L::oid)',
                 pgpm._max_hi_native(cfg.control_kind), p_parent::text, r.child_name, v_now::oid)
    into v_resume_lo;
  v_resume_lo := coalesce(v_resume_lo, r.lo);

  v_result := pgpm._run_archive_strategy(p_parent, r.child_name, v_resume_lo, r.hi);

  -- Hold the return to the range it was handed, BEFORE any ledger write: the same contract, through the same
  -- function, that pgpm._archive_step holds it to (issue #454; issue #1030). The ledger row is retire()'s drop
  -- precondition, so a covered_hi past hi, which a strategy that archived nothing can return, would open the
  -- drop gate on rows nothing archived, and a covered_hi at lo would write the (lo, lo) row that wedges the
  -- ledger on its primary key. Unlike the identity refusal above this one IS logged, as the
  -- fail_archive_contract _archive_step writes: the defect is the configured strategy's, maintain()'s next
  -- tick meets it too, and status() counts the action whichever path met it first.
  v_breach := pgpm._archive_contract_breach(p_parent, cfg.control_kind, v_resume_lo, r.hi, v_result.covered_hi);
  if v_breach is not null then
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'fail_archive_contract', v_resume_lo, r.hi,
              format('%s returned covered_hi %s for %I.%I chunk [%s, %s): %s; refusing to record it',
                     cfg.archive_fn::text, coalesce(quote_literal(v_result.covered_hi), 'null'),
                     v_nsp, r.child_name, v_resume_lo, r.hi, v_breach));
    return format('%s: REFUSING to record what %s returned for [%s, %s) (covered_hi %s): %s. Nothing was recorded '
                  'and the partition stays unarchived; fix the strategy (pgpm.set_archive_fn) and call again.',
                  r.child_name, cfg.archive_fn::text, v_resume_lo, r.hi,
                  coalesce(quote_literal(v_result.covered_hi), 'null'), v_breach);
  end if;

  -- the instant this session reads, in canonical text, as pgpm._archive_step records it (#977): a strategy's
  -- offset-less text stored verbatim reads as a different instant, past hi, from a session in another zone
  v_result.covered_hi := pgpm._native_text(cfg.control_kind, v_result.covered_hi);

  insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, etag, rows_archived, child_oid)
  values (p_parent, v_resume_lo, v_result.covered_hi, r.child_name, v_result.s3_key, v_result.etag, v_result.rows_archived,
          v_now::oid);

  -- partial or whole by VALUE: the check above holds covered_hi at or below hi, and the same value can be
  -- spelt more than one way ('1000.0' is hi 1000; a timestamp in another zone or DateStyle), so text
  -- inequality would report a whole cover as partial
  if pgpm._native_gt(cfg.control_kind, r.hi, v_result.covered_hi) then
    return format('%s: PARTIAL only (requested hi %s, got %s) -- probably hit statement_timeout or a size limit; call again',
      r.child_name, r.hi, v_result.covered_hi);
  end if;

  return format('%s: fully archived in one file (%s rows, s3_key=%s)',
    r.child_name, v_result.rows_archived, coalesce(v_result.s3_key, '<none>'));
end;
$$;
