-- =============================================================================
-- pg_partition_magician  --  a lightweight, pure-SQL range-partition manager
--
--   * Only runtime dependency: pg_cron (and only for scheduling). No compiled
--     extension. Install with: psql -f this_file.sql.  Schema: pgpm.
--   * Manages the full lifecycle of native RANGE-partitioned tables: transmute an
--     existing (possibly huge, live) table online, obtain ahead of the write
--     frontier, archive, retain, regrain, all via maintenance.
--
-- Control-type contract -- a column works as the partition key if it is:
--   (a) RANGE-partitionable (btree-ordered),
--   (b) monotonic with insertion within a bounded lag,
--   (c) has EXACT, reproducible grid arithmetic (gapless, stable boundaries),
--   (d) free of unordered/extreme values that poison the frontier (NaN/Inf/wrap).
--
-- Supported control_kind:
--   'time'      -- timestamptz/timestamp/date, interval step (calendar-aligned)
--   'id'        -- int/bigint/NUMERIC, integer step (covers Snowflake-style ids)
--   'uuidv7'    -- uuid whose leading 48 bits are a ms timestamp (also ULID-as-uuid);
--                  time grid, boundaries encoded as uuids
--   'text_time' -- text/varchar shaped <constant prefix><fixed-width base-N encoded
--                  count>: classic cuid, KSUID, ULID-as-text, MongoDB ObjectId. The
--                  shape is declared (p_tt_prefix/width/radix/unit, plus
--                  p_tt_alphabet/discard_bits/epoch for formats that need them), not
--                  detected.
-- float/double are explicitly rejected (imprecise boundaries; NaN/Inf).
--
-- The engine is kind-agnostic: all type-specific logic lives in a small adapter
-- (_grid_floor/_grid_next/_encode/_decode/_frontier_native/_part_name). Bounds are
-- carried as text so one code path serves every kind. Calendar arithmetic is done in
-- pgpm.config.partition_tz, recorded at transmute, never in the session's TimeZone (#455).
--
-- NAMING: a local ending in `_q` holds text whose identifiers are ALREADY QUOTED --
-- typically `string_agg(quote_ident(attname), ', ')` over a column list. Splice those
-- with `%s`; `%I` would quote them a second time, into garbage. A local WITHOUT the
-- suffix is raw and needs `%I`. The suffix exists because the two look identical at
-- the call site, so an edit could swap one for the other and nothing would read as
-- wrong (issue #409). scripts/check_quoted_splices.py enforces it in both directions
-- across this file, pgpm_hypertable and pgpm_archive, and CI runs it.
-- =============================================================================

create schema if not exists pgpm;

create table if not exists pgpm.config (
  parent_table     regclass    primary key,
  control_column   name        not null,
  control_kind     text        not null default 'time'
                   check (control_kind in ('time', 'id', 'uuidv7', 'text_time')),
  partition_step   text        not null,    -- '1 month' (time/uuidv7/text_time) | '10000000' (id)
  partition_anchor text        not null,    -- '2000-01-01...' (time/uuidv7/text_time) | '0' (id)
  -- The zone every calendar step is computed in, and every partition name rendered in (#455). Recorded
  -- from the transmuting session's TimeZone, so the grid the operator saw at conversion is the grid for
  -- the life of the table, whatever zone pg_cron's session runs in. A month boundary is midnight on the
  -- 1st IN THIS ZONE. 'UTC' for id grids, which have no calendar, and for a naive (timestamp / date)
  -- control column, which has no zone: its grid is the column's own wall clock, which is the UTC lattice
  -- (#504), and set_partition_tz refuses to move it. Change it with pgpm.set_partition_tz, never by hand.
  partition_tz     text        not null default 'UTC',
  obtain          int         not null default 30,
  retain        text,                    -- interval (time/uuidv7) | bigint count (id); null = keep
  regrain_batch    int         not null default 5000,   -- rows per regrain COPY microbatch
  paused           boolean     not null default true,
  created_at       timestamptz not null default now(),
  -- when maintenance may next attempt obtain for this parent. Under sustained write contention obtain
  -- keeps losing the ACCESS EXCLUSIVE race on the parent, so on a deferral maintenance backs it off
  -- instead of retrying every tick. null = attempt now.
  obtain_retry_after timestamptz,
  -- optional block budget for a regrain microbatch: cap it at ~this many heap+TOAST blocks (translated
  -- to a row limit via the coarse child's average bytes/row), so wide rows cannot make a single batch
  -- huge. null = cap by regrain_batch rows only (default).
  regrain_max_blocks int,
  -- text_time only (general opaque-sortable-TEXT-id support: cuid, KSUID, ULID-as-text, ObjectId): the
  -- value is <text_time_prefix><fixed-width base-text_time_radix encoded count>. Null for every other
  -- kind. _encode/_decode are the only functions that ever read these -- grid math operates on the
  -- already decoded native timestamptz, identically to time/uuidv7, so nothing else needs them.
  text_time_prefix       text,
  text_time_width        int,
  text_time_radix        int,
  text_time_unit         text,       -- 'ms' or 's'
  -- alphabet/discard_bits/epoch cover formats the plain cuid/ULID case does not need: a custom digit
  -- alphabet (null = the default contiguous 0-9a-z convention; ULID's Crockford base32 and KSUID's
  -- base62 are NOT that), and a timestamp that is the top bits of a WIDER encoded value rather than the
  -- whole field (KSUID base62-encodes its entire 160-bit payload as one number and a non-Unix epoch;
  -- discard_bits drops the low bits after decoding the whole field, epoch is the zero-point).
  text_time_alphabet     text,
  text_time_discard_bits int,
  text_time_epoch        timestamptz
);
-- upgrade path for installs that predate these columns
-- partition_tz (#455) backfills to 'UTC' because nothing in the catalog records which zone an existing
-- grid was built in. An install whose tables were transmuted from a non-UTC session must set it with
-- pgpm.set_partition_tz(parent, zone), which refuses unless the grid built so far is on that zone's lattice.
alter table pgpm.config add column if not exists partition_tz text not null default 'UTC';
alter table pgpm.config add column if not exists obtain_retry_after timestamptz;
alter table pgpm.config add column if not exists text_time_prefix text;
alter table pgpm.config add column if not exists text_time_width  int;
alter table pgpm.config add column if not exists text_time_radix  int;
alter table pgpm.config add column if not exists text_time_unit   text;
alter table pgpm.config add column if not exists text_time_alphabet text;
alter table pgpm.config add column if not exists text_time_discard_bits int;
alter table pgpm.config add column if not exists text_time_epoch timestamptz;
-- the control_kind check predates 'text_time' (issue #325 follow-up); widen it for installs that
-- already have the narrower constraint. Named per Postgres's default inline-CHECK convention
-- (<table>_<column>_check), which is what a fresh pre-text_time install actually produced.
alter table pgpm.config drop constraint if exists config_control_kind_check;
alter table pgpm.config add constraint config_control_kind_check
  check (control_kind in ('time', 'id', 'uuidv7', 'text_time'));
-- #288: the fourteen adaptive-feathering columns are gone with the closed loop they fed, and so are
-- keep_default and default_table. drain_batch/drain_max_blocks survive under regrain_* names: they are
-- regrain's microbatch knobs now, and the old names described a machine that no longer exists.
alter table pgpm.config drop column if exists drain_adaptive;
alter table pgpm.config drop column if exists drain_budget;
alter table pgpm.config drop column if exists drain_ckpt_seen;
alter table pgpm.config drop column if exists drain_wal_lsn;
alter table pgpm.config drop column if exists drain_wal_at;
alter table pgpm.config drop column if exists drain_wal_high_water;
alter table pgpm.config drop column if exists drain_ambient_max_waiters;
alter table pgpm.config drop column if exists drain_ambient_factor;
alter table pgpm.config drop column if exists drain_ambient_alpha;
alter table pgpm.config drop column if exists drain_ambient_floor;
alter table pgpm.config drop column if exists drain_ambient_baseline;
alter table pgpm.config drop column if exists drain_ambient_io_baseline;
alter table pgpm.config drop column if exists drain_io_read_time;
alter table pgpm.config drop column if exists drain_io_blks_read;
alter table pgpm.config drop column if exists keep_default;
alter table pgpm.config drop column if exists default_table;
alter table pgpm.config add column if not exists regrain_batch int not null default 5000;
alter table pgpm.config add column if not exists regrain_max_blocks int;
-- auto-regrain (REDESIGN.md section 12): when set, maintenance feathers the oldest frozen coarse child
-- toward this target step, one budget-sized microbatch per tick. null = off (regrain is operator-driven).
alter table pgpm.config add column if not exists regrain_to text;
-- regrain copy progress (REDESIGN.md section 10): the NATIVE-grid lo of the sub-range currently being
-- copied out of the coarse child under regraining -- a cross-tick high-water mark. regrain COPIES (never
-- deletes), so the source never shrinks and cannot drive progress the way deletes would; this
-- cursor is the explicit progress state instead. null = no regrain in flight; reset to null at the swap.
alter table pgpm.config add column if not exists regrain_cursor text;
-- regrain change capture's anchors (#496): the oids of the per-parent delta table and of the trigger
-- function the prepare tick minted, recorded so that every reader of the delta (the reconcile, the swap
-- gate, the swap, status) resolves the relation the source's trigger actually writes, whatever the parent
-- is called by then. Null until the parent's first regrain; the relations persist between regrains and
-- prepare re-mints them, recording the new oids. Backfilled for an older install where
-- _regrain_capture_derive is defined, below.
alter table pgpm.config add column if not exists regrain_delta_oid oid;
alter table pgpm.config add column if not exists regrain_capture_fn_oid oid;
-- retain() pacing (issue #189): cap how many eligible partitions ONE retain() call will attempt
-- (write-block, archive-coverage check, drop), so an aged-out backlog spreads across maintenance
-- ticks (each tick its own transaction via pg_cron) instead of one call carrying the whole backlog
-- -- the drain_batch shape, applied to drops. The cap bounds ATTEMPTS, oldest first: with an
-- unexpected drop failure at the head, the partitions behind it are not attempted that call
-- (bounded per-tick work is the point; the wedge is surfaced by status().retain_drop_failures
-- alongside a flat retain_backlog -- issue #238). null = unbounded (prior behavior). A table whose
-- chunked archiving is genuinely still catching up on a large backlog is not a wedge at all: that is
-- retain_backlog falling tick over tick with retain_drop_failures flat at zero.
alter table pgpm.config add column if not exists retain_batch int;
-- the pluggable archive strategy (issue #236): null = strategy 'none' (no archiving, drop as soon as
-- write-blocked). regprocedure (not text/regproc) so a bad reference is refused right here at
-- assignment, not discovered later when a maintenance tick tries to call it. Contract:
-- archive_fn(p_parent regclass, p_child name, p_lo text, p_hi text) returns pgpm.archive_result,
-- called once per tick, expected to make bounded incremental progress and report how much of
-- [lo, hi) is now durably archived (not to finish the whole range in one call). retire()'s drop
-- precondition consults this via pgpm._archive_fully_covered (#238) -- see
-- pgpm._run_archive_strategy and pgpm._archive_noop below.
alter table pgpm.config add column if not exists archive_fn regprocedure;
-- byte-budget chunking knobs (issue #237, porting archive._next_range_byte_budget's own
-- c_byte_budget/c_probe_sample constants): archive_byte_budget estimates how many rows make up
-- roughly this many bytes (via a sampled average row width), and archive_probe_sample caps how many
-- rows that sample scans. Same defaults as the original. Ignored entirely by a 'none' strategy.
alter table pgpm.config add column if not exists archive_byte_budget bigint not null default 8 * 1024 * 1024;
alter table pgpm.config add column if not exists archive_probe_sample int not null default 1000;
-- caps how many DIFFERENT partitions one _archive_step call touches (issue #351; same shape as
-- retain_batch, same "caps attempts, not successes" semantics, and the same null-means-unlimited
-- escape hatch), but a different default: retain_batch's own unlimited default is safe because DROP TABLE is
-- cheap and roughly constant-cost regardless of how many run per tick. Archiving is not -- each
-- partition costs a real read, encode and (with compress on) CPU-bound compression pass, so
-- fanning out over every eligible partition in one tick makes a single maintain() call's duration
-- scale with the SIZE OF THE BACKLOG, not just archive_byte_budget's own per-partition cost. That
-- is invisible until a bulk regrain or backfill leaves many partitions simultaneously eligible at
-- once, at which point it can itself cross statement_timeout regardless of how conservatively
-- archive_byte_budget is tuned. Defaulting to 1 makes archiving strictly sequential -- one
-- partition fully archived (and so retirable) before the next one is even touched -- at the cost
-- of a large backlog taking longer to fully catch up than fanning out would. Raise it (or set it
-- null for the old unlimited behavior) if faster catch-up matters more than that bound.
alter table pgpm.config add column if not exists archive_batch int default 1;
-- maintain_all's turn order (#579): when this parent last had its turn in a sweep. A sweep is ONE
-- top-level statement (`call pgpm.maintain_all()`), and statement_timeout runs from the start of the
-- statement, not from each internal COMMIT, so every parent in a sweep shares one clock. In a fixed order
-- a backlog early in the list (each of its ticks documented-size) spent that clock tick after tick and the
-- parents behind it were cancelled every time, never archived or retired. The sweep visits the parent
-- whose turn is oldest first instead; see maintain_all. null = never had one, which goes first.
alter table pgpm.config add column if not exists sweep_turn_at timestamptz;
-- WHICH partition is the original table (#672): its oid, recorded by transmute's cutover, where the table
-- becomes the monolith child. Nothing else marks the monolith. It is named on the same grid as every forward
-- partition, and "the attached partition with the smallest lo", which untransmute used to take for it, is
-- the original only while the original is still attached: after retention has retired it, or a regrain's
-- swap has replaced it with finer children, that is some other relation, which untransmute then handed back
-- under the table's name as though it were the original. A rename does not change an oid, so regrain's
-- transitional rename of the monolith leaves this correct. Null means "not recorded": an install that
-- predates the column, where the backfill below could not tell which partition it is. untransmute refuses
-- such a table rather than guess.
alter table pgpm.config add column if not exists monolith_oid oid;

-- Registry of managed partitions (excludes the DEFAULT). lo/hi are NATIVE-grid
-- values as text (timestamptz for time/uuidv7, numeric for id).
create table if not exists pgpm.part (
  parent_table regclass    not null,
  child_name   name        not null,
  lo           text        not null,
  hi           text        not null,
  created_at   timestamptz not null default now(),
  -- false while regrain is still copying rows into this child (created standalone, not yet ATTACHed to
  -- the parent); flipped true at the swap. Lets an in-flight (or stalled, or interrupted) regrain child
  -- be tracked in pgpm's catalog and surfaced by status(), instead of being discoverable only by
  -- scanning pg_class for the name pattern. obtain creates partitions already attached, so the default
  -- is true; only regrain inserts a row with attached=false. (issue #94)
  attached     boolean     not null default true,
  -- When retirement of this child BEGAN -- set as retire() dispatches a CONCURRENT DETACH for it, never
  -- refreshed by a retry, and cleared with the row when the drop completes (issue #268). It doubles as
  -- the tiebreak that keeps exactly one detach in flight, which is why it must not move. Retiring a REFERENCED partition cannot happen in one step: a bare
  -- DROP is refused on the referencing table's per-partition constraint, and the DETACH that severs
  -- it must be CONCURRENT (a plain one holds ACCESS EXCLUSIVE on the managed parent for the whole
  -- O(referencing table) scan) -- which PostgreSQL refuses to run from a function, so pgpm dispatches
  -- it to pg_cron and finishes on a later tick. This marker is what makes that recoverable: a detach
  -- left pending by a dead backend is finalized by _detach_reap, and this says whether the retirement
  -- behind it was pgpm's to complete or an operator's to keep. null for every unreferenced partition,
  -- which never leaves the one-step bare-DROP path at all.
  retiring_at  timestamptz,
  -- WHICH object that retirement meant, by OID, recorded in the same transaction that dispatches the
  -- detach (issue #407). The dispatched command is a fully-formed `ALTER TABLE ... DETACH PARTITION
  -- schema.child CONCURRENTLY` sitting on cron.job until pg_cron's scheduler picks it up a tick or
  -- more later, in a session of its own, and a NAME is all a command text can carry: nothing bridges
  -- that gap, no lock is held on the child across it. If the object answering to schema.child at
  -- execution time is not the one pgpm resolved at dispatch, the detach acts on whatever now holds
  -- the name and the executing session cannot tell the difference -- the same shape as the
  -- SPLIT/MERGE time-of-check/time-of-use bug the #346 audit was about.
  --
  -- Preventing the substitution inside that window is not available to pgpm (see _dispatch_detach for
  -- why the statement has to leave the process at all), so this makes it DETECTABLE at the two points
  -- that still belong to pgpm: retire() refuses to re-dispatch, and refuses the DROP that follows a
  -- successful detach, unless the name still resolves to exactly this OID. The DROP is the
  -- destructive half, and it is the half this anchors.
  --
  -- Null means "no OID was recorded", which is true of every partition on the ordinary one-step drop
  -- path and of a retirement that was already in flight when this column was added. Both read as
  -- unanchored and are left to behave exactly as they did before, rather than wedging an upgrade
  -- mid-retirement on a check that has nothing to compare against.
  retiring_oid oid,
  -- WHICH RELATION this row is about, by OID, recorded where the partition ENTERS this catalog --
  -- obtain's _create_partition, regrain's standalone child, transmute's monolith (issue #421).
  -- child_name is a NAME, and every consumer of it re-resolves that name independently: the archive
  -- step picks a candidate out of this table, _is_write_blocked matches it against pg_class,
  -- _next_archive_chunk reads %I.%I to size the chunk, and the archive_fn is handed the bare string.
  -- None of them could tell that the relation answering to it is the one this row was written for.
  --
  -- That needs no race to go wrong. A name that has stopped meaning what it meant -- an operator
  -- renamed the partition aside, something else took the name -- is a state pgpm already knows is
  -- reachable, which is why pgpm.forget_missing exists; #346 accepted forget_missing's own name-only
  -- matching precisely BECAUSE it is read-only reporting. The archive path is not: a chunk sized
  -- from a substitute's rows becomes a pgpm.archive_ledger row claiming coverage of a range those
  -- rows never came from, and _archive_fully_covered consults that ledger as retire()'s drop
  -- precondition. A bad export therefore does not merely put a wrong object in the bucket -- it
  -- satisfies the gate that authorises a DROP.
  --
  -- Recorded at CREATION rather than at retirement, which is what separates this from retiring_oid
  -- above: that one is set as retire() dispatches a detach, so it is null for every partition the
  -- archive step ever touches. A rename does not change an OID, so regrain's own transitional rename
  -- (#266) updates child_name and leaves this correct with nothing to do.
  --
  -- Null means "no OID was recorded", which reads as unanchored and behaves exactly as before. The
  -- backfill below fills it for every row an upgrade finds resolvable, so an existing install is
  -- anchored from the moment it upgrades rather than only for partitions minted afterward -- but it
  -- can only adopt what is true AT THAT MOMENT. An install upgraded after a substitution has already
  -- happened records the substitute; there is nothing in the catalog that could tell it otherwise.
  child_oid    oid,
  primary key (parent_table, child_name)
);
-- upgrade path for installs that predate these columns
alter table pgpm.part add column if not exists attached boolean not null default true;
alter table pgpm.part add column if not exists retiring_at timestamptz;
alter table pgpm.part add column if not exists retiring_oid oid;
alter table pgpm.part add column if not exists child_oid oid;

-- Backfill child_oid (issue #421). `where child_oid is null` makes this a one-time adoption per row:
-- re-running this installer never re-adopts, so a row anchored at one upgrade is not silently
-- re-pointed at whatever holds its name at the next one.
--
-- An ATTACHED partition is resolved through pg_inherits, not by name, so what gets adopted is a
-- partition OF THIS PARENT by construction -- strictly better than to_regclass, which would take any
-- relation of that name in the schema. A not-yet-attached regrain child is not in pg_inherits at all
-- (it is standalone until the swap), so it has nothing but its name to go on; a row whose name does
-- not resolve is left null and stays unanchored, which is exactly the state forget_missing clears.
update pgpm.part p set child_oid = i.inhrelid
  from pg_inherits i join pg_class c on c.oid = i.inhrelid
 where i.inhparent = p.parent_table and c.relname = p.child_name
   and p.attached and p.child_oid is null;
update pgpm.part p set child_oid = to_regclass(format('%I.%I', n.nspname, p.child_name))::oid
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.oid = p.parent_table and not p.attached and p.child_oid is null;

-- The per-parent regrain lock (#554): one row per managed parent, locked FOR UPDATE by every call that
-- drives or reconfigures a regrain (see pgpm._regrain_lock). Nothing is ever written to it after the row
-- exists; the ROW LOCK is the whole point. It is its own table rather than a lock on the pgpm.config row
-- because the config row is also written by the obtain job (obtain_retry_after, sweep_turn_at) and by
-- maintain_all (sweep_turn_at), and holding that row across a regrain copy batch would make obtain, the
-- one step standing between the workload and a write with nowhere to go, wait on a regrain. And it is a table
-- rather than an advisory lock for the reason #405 retired transmute's: an advisory key is computable by
-- any role that can connect, and carries no ACL, so any such role could take it and hold every regrain of
-- the table hostage. This table is pgpm-owned and carries no GRANTs.
create table if not exists pgpm.regrain_lock (
  parent_table regclass not null primary key
);
-- Backfill config.monolith_oid (#672), once per row, from the one fact an older install still carries: the
-- monolith is the only partition that EXISTED BEFORE ITS PARENT. transmute builds the parent in its cutover,
-- from the table that becomes the monolith, and every forward partition and fine child is created after it,
-- so the monolith is the one attached partition with an oid below the parent's. Adopted only when exactly
-- one qualifies, so a table whose monolith retention has already retired, or a regrain has already replaced,
-- is left null (no attached partition predates the parent) and untransmute refuses it. oids wrap at 2^32;
-- a wrap between the table's creation and its conversion leaves this null as well, which fails closed.
update pgpm.config c set monolith_oid = m.child_oid
  from (select p.parent_table, min(p.child_oid) as child_oid
          from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid and i.inhparent = p.parent_table
         where p.attached and p.child_oid < p.parent_table::oid
         group by p.parent_table having count(*) = 1) m
 where m.parent_table = c.parent_table and c.monolith_oid is null;

-- In-flight conversions (issue #275). transmute runs in three transactions -- add the bound, validate it,
-- cut over -- so that the O(rows) validation scan is not held under the ACCESS EXCLUSIVE lock the ADD
-- takes. The cost of that split is that a failure between phases leaves a live `pgpm_monolith_bound` CHECK
-- on the operator's table, which REJECTS any write outside [lo, hi) (a NOT VALID check still enforces new
-- rows). This table is what lets maintenance find and undo that: a half-converted table is not in
-- pgpm.config yet, because registration happens in the cutover, so there is nothing else to look it up by.
--
-- lo/hi are recorded so a resumed transmute reuses the SAME bound rather than recomputing one against a
-- frontier that has since moved.
--
-- owner_pid/owner_backend_start identify the session that claimed the conversion (#405). The row itself is
-- the exclusion -- one per parent_table, by the primary key -- and these two columns are what make the claim
-- releasable without a heartbeat. See pgpm._session_alive.
create table if not exists pgpm.transmute_inflight (
  parent_table  regclass    not null primary key,
  nsp           name        not null,
  rel           name        not null,
  control_kind  text        not null,
  lo            text        not null,
  hi            text        not null,
  -- #506: the zone lo and hi were computed in (the claiming session's, #455). A resume reuses the bound,
  -- so it has to reuse this too, whatever zone the resuming session runs in; null on a claim recorded
  -- before the column existed, which a resume reads as "keep this session's zone", the old behaviour.
  partition_tz  text,
  -- #628: the control column lo and hi were computed on (and the pgpm_monolith_bound CHECK constrains), by
  -- attribute number so a rename between attempts is still the same column. A resume on another column is
  -- refused; null on a claim recorded before the column existed, which a resume reads as "not checked",
  -- the old behaviour.
  control_attnum smallint,
  started_at    timestamptz not null default now(),
  owner_pid           int,
  owner_backend_start timestamptz
);
-- upgrade path for installs that predate these columns. A claim recorded before they existed has both null,
-- which pgpm._session_alive reads as "no live owner" -- so an old abandoned claim stays reapable rather than
-- becoming permanently stuck behind a liveness check it has no data for.
alter table pgpm.transmute_inflight add column if not exists owner_pid int;
alter table pgpm.transmute_inflight add column if not exists owner_backend_start timestamptz;
alter table pgpm.transmute_inflight add column if not exists partition_tz text;
alter table pgpm.transmute_inflight add column if not exists control_attnum smallint;

-- Is the session that claimed a conversion still alive? (#405)
--
-- This is the liveness signal transmute's claim protocol rests on. It has to tell "the conversion is still
-- running" from "its session died mid-way" with no heartbeat and no timeout guess -- exactly what the session
-- advisory lock it replaces gave for free, since PostgreSQL released that automatically when the session
-- ended, however it ended.
--
-- The trap, measured on stock PostgreSQL 17.10: backend_start is MASKED for a backend owned by ANOTHER role.
-- It reads NULL rather than the real value (pid and usename stay visible; backend_start, backend_type and
-- query do not). The reaper runs from pg_cron under whatever role scheduled it, which need not be the role
-- that ran transmute, so a plain `backend_start = p_backend_start` evaluates to NULL for a perfectly live
-- cross-role conversion -- and the reaper would then undo it out from under itself, dropping the bound and
-- deleting the claim while phase 2's validation scan is still running.
--
-- So the match DEGRADES instead of failing: pid AND backend_start where backend_start is visible to us, pid
-- alone where it is not. The residual failure is UNDER-reaping -- a recycled pid can look like a live
-- conversion, leaving an abandoned bound for an operator's transmute_abort -- and never OVER-reaping a live
-- one. That is the same discipline #98 established for the ambient sensors: read what every role can see,
-- never a column pg_monitor masks (tests/41_no_pg_monitor_dep_test.sql pins it).
--
-- A null p_pid is never alive: there is no session to be alive. That covers both a pre-#405 claim and a row
-- constructed by a test to stand in for a died-mid-run conversion.
create or replace function pgpm._session_alive(p_pid int, p_backend_start timestamptz)
returns boolean language sql stable as $$
  select p_pid is not null
     and exists (select 1 from pg_stat_activity
                  where pid = p_pid
                    and (backend_start = p_backend_start or backend_start is null));
$$;

-- A pg_class relkind as an English noun, for a refusal that names the relation standing in the way of a
-- name transmute needs (#509). "already exists as a standalone table ... drop table it" is wrong advice
-- when the thing in the way is a sequence or a view, so the message says what it actually found.
create or replace function pgpm._relkind_noun(p_relkind "char")
returns text language sql immutable as $$
  select case p_relkind
           when 'r' then 'table'            when 'p' then 'partitioned table'
           when 'v' then 'view'             when 'm' then 'materialized view'
           when 'f' then 'foreign table'    when 'S' then 'sequence'
           when 'i' then 'index'            when 'I' then 'partitioned index'
           when 'c' then 'composite type'   when 't' then 'TOAST table'
           else 'relation of kind ' || p_relkind::text
         end;
$$;

-- The non-relation TYPE, if any, holding a name transmute is about to give a table (#671), as an English
-- noun with its article; null when no such type exists. CREATE TABLE and ALTER TABLE ... RENAME need the
-- name free in pg_type as well as in pg_class, because every table has a row type of its own name, so an
-- enum, domain, range or base type holding it makes either statement fail with a raw 42710. to_regclass, which the
-- name guards asked, sees relations only. A relation's own row type (typrelid <> 0) is left to those
-- guards, which already see the relation and say what it is. An implicit array type (the `_name` one
-- PostgreSQL mints for every type) is not in the way: CREATE TABLE and RENAME move it aside themselves.
create or replace function pgpm._type_squatter(p_nsp name, p_name name)
returns text language sql stable as $$
  select case t.typtype when 'e' then 'an enum type' when 'd' then 'a domain'
                        when 'r' then 'a range type' when 'm' then 'a multirange type'
                        when 'b' then 'a base type' when 'p' then 'a pseudo-type'
                        else 'a type of kind ' || t.typtype::text end
    from pg_type t join pg_namespace n on n.oid = t.typnamespace
   where n.nspname = p_nsp and t.typname = p_name and t.typrelid = 0
     and not (t.typelem <> 0 and exists (select 1 from pg_type e where e.oid = t.typelem and e.typarray = t.oid))
   limit 1;
$$;

-- An identity column's sequence options, as the parenthesised clause ADD GENERATED ... AS IDENTITY takes
-- (#670). Re-adding identity with its kind alone gave the new sequence the DEFAULT options, so an
-- identity declared INCREMENT BY 2 (odd ids only, the usual two-writer interleave), a bounded
-- MINVALUE/MAXVALUE, CYCLE or a CACHE came back as a plain ascending sequence and handed out ids the
-- original never would. Everything pg_sequence records except the type, which ADD GENERATED takes from the
-- column (it refuses an AS clause) and the column is the same one. START WITH is carried too: it is the
-- lattice a positive or negative INCREMENT counts from, and what RESTART goes back to. Null for null.
create or replace function pgpm._identity_options(p_seq regclass)
returns text language sql stable as $$
  select format('(increment by %s minvalue %s maxvalue %s start with %s cache %s %s)',
                s.seqincrement, s.seqmin, s.seqmax, s.seqstart, s.seqcache,
                case when s.seqcycle then 'cycle' else 'no cycle' end)
    from pg_sequence s where s.seqrelid = p_seq;
$$;

-- The same clause, read under a lock on the sequence that ALTER SEQUENCE has to wait for (#732), and held to
-- the end of the caller's transaction. No lock on the TABLE stops an ALTER SEQUENCE on its identity
-- sequence: that statement takes SHARE ROW EXCLUSIVE on the sequence alone, so transmute's cutover and
-- untransmute, which read the options and then carry them onto a sequence they create, lost an INCREMENT BY
-- committed after the read even with the table's ACCESS EXCLUSIVE held. LOCK TABLE refuses a sequence, and
-- pg_sequence_last_value is the side-effect-free statement that takes ROW EXCLUSIVE on one (the lock nextval
-- takes, measured on PG 15 to 18), which conflicts with SHARE ROW EXCLUSIVE and with nothing a writer takes.
-- So an ALTER SEQUENCE committed before this call is in what it returns, and one that has not committed by
-- then waits for the caller. Null for null.
create or replace function pgpm._identity_options_locked(p_seq regclass)
returns text language plpgsql volatile as $$
begin
  if p_seq is null then return null; end if;
  perform pg_sequence_last_value(p_seq);
  return pgpm._identity_options(p_seq);
end;
$$;

-- The value a sequence would hand out next (#670): last_value until the first nextval, then last_value plus
-- its INCREMENT, which is not always 1. Numeric, because one step past an exhausted bigint sequence is not
-- a bigint. Null for a null sequence.
create or replace function pgpm._seq_next(p_seq regclass)
returns numeric language plpgsql stable as $$
declare v_last bigint; v_called boolean;
begin
  if p_seq is null then return null; end if;
  execute format('select last_value, is_called from %s', p_seq::text) into v_last, v_called;
  return case when v_called
              then v_last::numeric + (select seqincrement from pg_sequence where seqrelid = p_seq)
              else v_last end;
end;
$$;

-- Reseed an identity sequence that transmute or untransmute has just re-created with the original's options
-- (#670), so the next id it hands out is the one the original would have: p_next (the original's next
-- value, _seq_next), moved on along the sequence's OWN lattice (start + k * increment) until it clears every
-- id already in the table, p_max for an ascending sequence and p_min for a descending one. It used to be
-- greatest(max + 1, next), which is off the lattice for any increment but 1 and wrong in direction for a
-- negative one. A value past the sequence's bound means the original was exhausted (or the rows are): the
-- sequence is left AT the bound, called, so the next nextval does what the original's would, CYCLE or
-- "reached maximum value". A null p_next (no original position) counts from START WITH.
create or replace function pgpm._identity_reseed(p_seq regclass, p_next numeric, p_max bigint, p_min bigint)
returns void language plpgsql as $$
declare s record; v numeric;
begin
  select seqincrement, seqmin, seqmax, seqstart into s from pg_sequence where seqrelid = p_seq;
  v := coalesce(p_next, s.seqstart);
  if s.seqincrement > 0 and p_max is not null and v <= p_max then
    v := v + ceil((p_max - v + 1) / s.seqincrement) * s.seqincrement;
  elsif s.seqincrement < 0 and p_min is not null and v >= p_min then
    v := v - ceil((v - p_min + 1) / -s.seqincrement) * -s.seqincrement;
  end if;
  if v > s.seqmax or v < s.seqmin then
    perform setval(p_seq, case when s.seqincrement > 0 then s.seqmax else s.seqmin end, true);
  else
    perform setval(p_seq, v::bigint, false);
  end if;
end;
$$;

-- The audit trail. NAMING RULE for `action`: non-success events are PREFIXED, never suffixed --
-- `skip_<mechanism>` for a deferral, `fail_<mechanism>` for a failure. So no non-success action is ever
-- a prefix-extension of the success it corresponds to, and both query styles are safe: `action =
-- 'obtain'` and `action like 'drain%'` match successes only, while `action like 'skip_%'` collects every
-- deferral across all mechanisms without enumerating them.
--
-- This was the other way round (`drain_skip`) and it bit: a guard asserting a tick had drained matched
-- `drain%`, which also matched `drain_skip` -- the exact row a tick writes when it was starved of its
-- locks and did nothing. The guard passed on a tick that had done no work. Do not reintroduce a suffix.
create table if not exists pgpm.log (
  id           bigint generated always as identity primary key,
  parent_table regclass,
  action       text,
  lo           text,
  hi           text,
  method       text,
  rows         bigint,
  at           timestamptz not null default now()
);

create table if not exists pgpm.dropped_fk (
  id                  bigint generated always as identity primary key,
  parent_table        regclass    not null,
  referencing_table   regclass    not null,
  constraint_name     name        not null,
  definition          text        not null,
  -- lifecycle markers for a preserve-managed incoming FK (issue #95):
  --   restored_at null                     => DROPPED (RI off: after the transmute cutover, until restored).
  --   restored_at set, validated_at null   => RE-ADDED as NOT VALID: enforces RI for all NEW writes, but
  --                                            pre-existing rows are not yet verified (orphans, if any,
  --                                            are tolerated-but-flagged -- surfaced by status().fks_unvalidated
  --                                            and pgpm.incoming_fk_orphans(), cleared via validate_incoming_fks()).
  --   restored_at set, validated_at set    => fully VALIDATED.
  -- The FK is dropped once, by the cutover, and re-added by restore_incoming_fks on a later tick; nothing
  -- in a maintenance tick suspends it again (#288 removed the drain that used to). Regrain's swap is the
  -- one remaining suspend/restore, and it does both inside one transaction. Splitting the re-add from the VALIDATE
  -- is what stops a pre-existing orphan from permanently bricking restoration: the FK comes back
  -- enforcing new writes immediately, and validation is a separate, loud step.
  restored_at         timestamptz,
  validated_at        timestamptz,
  dropped_at          timestamptz not null default now()
);
-- upgrade path for installs that predate these columns
alter table pgpm.dropped_fk add column if not exists restored_at timestamptz;
alter table pgpm.dropped_fk add column if not exists validated_at timestamptz;
-- #265: when a VALIDATE fails on a pre-existing orphan, do not retry it on the very next tick -- the
-- attempt re-scans the whole referencing table each time. Set a window instead, like config.obtain_retry_after.
alter table pgpm.dropped_fk add column if not exists validate_retry_after timestamptz;
-- backfill validated_at for FKs already re-added by an older pgpm (which validated in one step): mark
-- them validated iff the actual constraint is currently convalidated. Keyed off pg_constraint, not a
-- blanket update, so a genuinely re-added-NOT-VALID FK (convalidated = false) is never wrongly marked.
update pgpm.dropped_fk d set validated_at = d.restored_at
 where d.restored_at is not null and d.validated_at is null
   and exists (select 1 from pg_constraint c
                where c.conrelid = d.referencing_table and c.conname = d.constraint_name
                  and c.contype = 'f' and c.convalidated);

-- _fk_definition(): pg_get_constraintdef() with the search_path pinned to pg_catalog, so the referenced
-- table is ALWAYS schema-qualified (#498). A dropped_fk.definition is captured in the transmuting session
-- and replayed in another: pg_cron's, with the default search_path, on a later maintenance tick or inside
-- a regrain swap. pg_get_constraintdef qualifies the referenced table only when the CALLING session's
-- search_path cannot see it, so a conversion run under `set search_path = app, public` recorded
-- `REFERENCES orders(id)`, and the tick that replayed it resolved `orders` in ITS search_path: to an
-- unrelated public.orders (the key came back against the wrong table, logged restore_incoming_fk) or to
-- nothing (fail_restore_incoming_fk every tick, RI off for good). Pinned to pg_catalog no user relation is
-- visible, so the name is written out in full and resolves to the same relation from any session. The
-- function-level SET is scoped to this call and leaves the caller's search_path exactly as it was.
create or replace function pgpm._fk_definition(p_con oid)
returns text language plpgsql stable set search_path = pg_catalog as $$
begin
  return pg_get_constraintdef(p_con);
end;
$$;
-- backfill (#498): a record captured by an earlier pgpm may carry the unqualified form. The referenced
-- table is the record's own parent_table, so the qualified spelling is known exactly; rewrite the one
-- place the name appears (` REFERENCES <rel>(`) and nothing else. A row already qualified does not match
-- the pattern (the name follows a `.` there, not a space), so this is idempotent, and a row whose parent
-- is gone joins nothing and is left alone.
update pgpm.dropped_fk d
   set definition = replace(d.definition,
                            ' REFERENCES ' || quote_ident(c.relname) || '(',
                            ' REFERENCES ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || '(')
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.oid = d.parent_table
   and position(' REFERENCES ' || quote_ident(c.relname) || '(' in d.definition) > 0;

-- _forget_dangling_fks(): reconcile p_parent's pgpm.dropped_fk records with the catalog (#658), and
-- return how many it forgot. A record names its referencing table by oid, and nothing ties the two
-- together afterwards: the application can drop the referencing table (ordinary DDL), or drop a restored
-- key by hand, and the record goes on naming it. Every path that acts on the records then died on it,
-- every time: untransmute's and suspend_incoming_fks's `alter table <referencing> drop constraint` with
-- 42601 on the bare oid a dropped table's regclass renders as (or 42704 on the hand-dropped key), so the
-- table could be neither reversed nor regrained, while restore_incoming_fks and validate_incoming_fks
-- logged a failure for it on every tick for good. Each of those four calls this first.
--
-- Two cases, and only these. The referencing table is gone: nothing pgpm could do with the record has
-- anything to act on. Or the record says the key is LIVE (restored_at set) and the referencing table has
-- no foreign key of that name against this parent: the operator dropped it, and putting it back would
-- overrule them. A SUSPENDED record (restored_at null) whose key is absent is the normal state between the
-- cutover and the restore, not a dangling one, and is left alone. Each forget is logged
-- forget_incoming_fk, `method` naming the key and why.
create or replace function pgpm._forget_dangling_fks(p_parent regclass)
returns int language plpgsql as $$
declare r record; v_n int := 0;
begin
  for r in
    delete from pgpm.dropped_fk d
     where d.parent_table = p_parent
       and (not exists (select 1 from pg_class c where c.oid = d.referencing_table)
            or (d.restored_at is not null
                and not exists (select 1 from pg_constraint k
                                 where k.conrelid = d.referencing_table and k.conname = d.constraint_name
                                   and k.contype = 'f' and k.confrelid = d.parent_table)))
    returning d.referencing_table::oid as rel_oid, d.constraint_name,
              exists (select 1 from pg_class c where c.oid = d.referencing_table) as rel_exists
  loop
    insert into pgpm.log (parent_table, action, method)
      values (p_parent, 'forget_incoming_fk',
              r.constraint_name || ': ' ||
              case when r.rel_exists
                   then format('recorded as re-added, but %s has no such key against this table any more', r.rel_oid::regclass)
                   else format('its referencing table (oid %s) no longer exists', r.rel_oid) end);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- the lifecycle hook registry (issue #236's pre_drop event, superseded by config.archive_fn) is
-- fully retired (issue #240): retire() stopped consulting it at all in #238, and #239 gave
-- pgpm_archive's gate-only architecture (archive.file_gate, the registry's last real registrant) a
-- replacement on the archive_fn contract. Nothing depends on it anymore.
drop function if exists pgpm.hook_register(regclass, text, regprocedure, boolean);
drop function if exists pgpm.hook_unregister(regclass, text, regprocedure);
drop table if exists pgpm.hook;

-- =============================== adapter layer ===============================

-- uuidv7/ULID codec (pure SQL; works on PG 15 -- no native uuidv7() needed):
-- the leading 48 bits are a Unix-ms timestamp, compared byte-wise == time order.
create or replace function pgpm._uuid_to_ts(p_uuid uuid)
returns timestamptz language sql stable as $$
  select to_timestamp(
    ('x' || lpad(substr(replace(p_uuid::text, '-', ''), 1, 12), 16, '0'))::bit(64)::bigint / 1000.0
  );
$$;

-- A UUIDv7 carries its timestamp in the leading 48 bits, so the grid it can express STOPS at
-- 2^48 - 1 ms after the epoch: 10889-08-02 05:31:50.65504+00. Past that, `to_hex` returns 13 hex digits
-- and `lpad(..., 12, '0')` TRUNCATES rather than pads -- silently dropping the high nibble, so a LATER
-- timestamp encodes as a SMALLER uuid (issue #299):
--
--   _ts_to_uuid(ceiling)         -> ffffffff-ffff-0000-0000-000000000000
--   _ts_to_uuid(ceiling + 1 ms)  -> 10000000-0000-0000-0000-000000000000
--
-- Monotonicity is the one property every caller assumes, and losing it silently produced partition
-- bounds with lo > hi -- surfacing as PostgreSQL's `empty range bound specified for partition`, an error
-- that names neither the cause nor the ceiling. Refusing here fixes it once for every caller instead of
-- at each bound-computing site.
--
-- Note the inverse can never overflow: a uuid's leading 48 bits cannot exceed the 48-bit maximum, so
-- _uuid_to_ts always returns a representable timestamp. Only stepping FORWARD off the end is possible.
create or replace function pgpm._ts_to_uuid(p_ts timestamptz)
returns uuid language plpgsql stable as $$
declare v_ms numeric; v_h text;
begin
  v_ms := floor(extract(epoch from p_ts) * 1000);
  if v_ms < 0 or v_ms > 281474976710655 then
    raise exception 'pg_partition_magician: % is outside the range a UUIDv7 timestamp can express (the leading 48 bits stop at 10889-08-02 05:31:50.65504+00); a uuidv7 grid cannot reach it', p_ts
      using errcode = 'datetime_field_overflow';
  end if;
  v_h := lpad(to_hex(v_ms::bigint), 12, '0') || repeat('0', 20);
  return (substr(v_h,1,8)||'-'||substr(v_h,9,4)||'-'||substr(v_h,13,4)||'-'||substr(v_h,17,4)||'-'||substr(v_h,21,12))::uuid;
end;
$$;

-- The exact integer floor of p_a / p_b, at any magnitude (#659). floor(p_a / p_b) is NOT this: general
-- numeric division computes a non-terminating quotient to a bounded scale (about 16 digits), and double
-- precision to 15 to 17 significant digits, so a quotient a hair below an integer rounds UP to it before
-- floor() sees it, and the floor lands above its input (1799999999999999999 / 3e16 is 60.0000000000000000,
-- and a KSUID payload whose random low bits are all ones divides to the NEXT second). div() and mod() are
-- exact; div() truncates toward zero, so a quotient that is negative and inexact steps down one to be a
-- floor. Every floor of a quotient that places a value on a grid goes through this: _grid_floor's id and
-- fixed-step branches and _text_time_to_ts. The month branch divides month counts (a few thousand) by a
-- step of a few months, whose quotient is never close enough to an integer to round, and keeps floor().
create or replace function pgpm._floor_div(p_a numeric, p_b numeric)
returns numeric language sql immutable strict parallel safe as $$
  select case when mod(p_a, p_b) <> 0 and (p_a < 0) <> (p_b < 0) then div(p_a, p_b) - 1 else div(p_a, p_b) end
$$;

-- text_time codec: an opaque TEXT id shaped <constant prefix><fixed-width base-N encoded epoch>, the
-- general form uuidv7 is one instance of (48 bits, base16-ish, embedded in a uuid type) and classic
-- cuid is another (prefix 'c', 8 base36 digits, ms). _radix_decode/_radix_encode are the bottom
-- primitive; _text_time_to_ts/_ts_to_text_time are the timestamp-shaped wrapper transmute will use.
--
-- Lowercase 0-9a-z only (radix 2-36) for now -- covers cuid outright; a wider alphabet (base62 for
-- KSUID, Crockford base32 for ULID-as-text) is future work, not a redesign, since it only touches the
-- digit<->character mapping here, nothing upstream.
-- p_alphabet overrides the default 0-9a-z digit set (e.g. Crockford base32 for ULID, base62 for
-- KSUID -- neither is contiguous-0-9-then-lowercase, so they cannot use the default). null = the
-- original convention, capped at radix 36; a supplied alphabet's own length IS the radix ceiling, so a
-- wider one (up to base62 and beyond) is exactly as valid as a narrow one. Returns numeric, not bigint:
-- KSUID's whole-payload encoding is a 160-bit number, far past a 64-bit bigint's range.
create or replace function pgpm._radix_decode(p_digits text, p_radix int, p_alphabet text default null)
returns numeric language plpgsql stable as $$
declare v_alphabet text; v_c text; v_d int; v_acc numeric := 0;
begin
  if p_alphabet is not null then
    if length(p_alphabet) <> p_radix then
      raise exception 'pg_partition_magician: alphabet % has length %, which does not match radix %', p_alphabet, length(p_alphabet), p_radix;
    end if;
    v_alphabet := p_alphabet;
  else
    if p_radix < 2 or p_radix > 36 then
      raise exception 'pg_partition_magician: radix % is out of range for the default 0-9a-z alphabet (supported: 2-36; supply p_alphabet for a wider or different one)', p_radix;
    end if;
    v_alphabet := substr('0123456789abcdefghijklmnopqrstuvwxyz', 1, p_radix);
  end if;
  for i in 1..length(p_digits) loop
    v_c := substr(p_digits, i, 1);
    v_d := position(v_c in v_alphabet) - 1;
    if v_d < 0 then
      raise exception 'pg_partition_magician: % is not a valid base-% digit string for alphabet %', p_digits, p_radix, v_alphabet
        using errcode = 'invalid_text_representation';
    end if;
    v_acc := v_acc * p_radix + v_d;
  end loop;
  return v_acc;
end;
$$;

-- The inverse: zero-padded (using the alphabet's own zero-digit character) to EXACTLY p_width
-- characters. Refuses (rather than truncates -- the same issue #299 lesson applied generally) when
-- p_value needs more than p_width base-p_radix digits, since a truncated high end would silently
-- encode a LATER instant as a SMALLER string and break the monotonicity every bound-computing caller
-- assumes.
create or replace function pgpm._radix_encode(p_value numeric, p_radix int, p_width int, p_alphabet text default null)
returns text language plpgsql stable as $$
declare v_alphabet text; v_n numeric := p_value; v_s text := ''; v_d int;
begin
  if p_alphabet is not null then
    if length(p_alphabet) <> p_radix then
      raise exception 'pg_partition_magician: alphabet % has length %, which does not match radix %', p_alphabet, length(p_alphabet), p_radix;
    end if;
    v_alphabet := p_alphabet;
  else
    if p_radix < 2 or p_radix > 36 then
      raise exception 'pg_partition_magician: radix % is out of range for the default 0-9a-z alphabet (supported: 2-36; supply p_alphabet for a wider or different one)', p_radix;
    end if;
    v_alphabet := substr('0123456789abcdefghijklmnopqrstuvwxyz', 1, p_radix);
  end if;
  if p_value < 0 then
    raise exception 'pg_partition_magician: % is negative; _radix_encode only supports non-negative values', p_value;
  end if;
  if v_n = 0 then v_s := substr(v_alphabet, 1, 1); end if;
  -- div()/mod(), not floor(v_n / p_radix): general numeric division computes non-terminating
  -- quotients to a BOUNDED number of decimal digits, and at KSUID scale (~48 decimal digits) that
  -- rounding compounds across the loop into a wrong, sometimes NEGATIVE, digit -- reproduced and
  -- diagnosed by hand while building this. div()/mod() are exact integer operations for numeric
  -- regardless of magnitude, which floor(a/b) is not.
  while v_n > 0 loop
    v_d := mod(v_n, p_radix::numeric)::int;
    v_s := substr(v_alphabet, v_d + 1, 1) || v_s;
    v_n := div(v_n, p_radix::numeric);
  end loop;
  if length(v_s) > p_width then
    raise exception 'pg_partition_magician: % needs % base-% digit(s), which does not fit in the configured width %', p_value, length(v_s), p_radix, p_width
      using errcode = 'numeric_value_out_of_range';
  end if;
  return lpad(v_s, p_width, substr(v_alphabet, 1, 1));
end;
$$;

-- Does p_value have the shape _text_time_to_ts decodes: the prefix, then at least p_width characters
-- every one of which is a digit of the alphabet? The same test check_text_time applies to a sampled
-- value and to the column's maximum before decoding either, as a predicate rather than a raise, for a
-- caller that has a fallback for a value that does not decode (_frontier_native, #661). translate()
-- rather than a regex character class: an alphabet is data, and a regex would read `]`, `^` or `-` in it
-- as syntax. It is case-sensitive, exactly as _radix_decode's position() is.
create or replace function pgpm._text_time_shaped(p_value text, p_prefix text, p_width int, p_radix int,
                                                  p_alphabet text default null)
returns boolean language sql immutable as $$
  select p_value is not null
     and left(p_value, length(p_prefix)) = p_prefix
     and length(p_value) >= length(p_prefix) + p_width
     and translate(substr(p_value, length(p_prefix) + 1, p_width),
                   coalesce(p_alphabet, substr('0123456789abcdefghijklmnopqrstuvwxyz', 1, p_radix)), '') = ''
$$;

-- p_prefix is the CONSTANT literal characters before the timestamp field (e.g. 'c' for classic cuid),
-- verified here rather than assumed: a value that does not start with it is refused, the same
-- discipline as uuidv7's plausibility sampling but at the single-value level.
-- p_discard_bits + p_epoch cover formats (KSUID) whose timestamp is not the WHOLE decoded field but
-- the top bits of a wider one -- KSUID base62-encodes its entire 160-bit payload (32-bit timestamp +
-- 128 bits of random) as one number, so the timestamp is recovered by decoding all of it and discarding
-- the low 128 bits, against a non-Unix epoch. Both default to the cuid/ULID case (the decoded field IS
-- the timestamp already, against the standard epoch), so neither changes behavior when omitted.
create or replace function pgpm._text_time_to_ts(p_value text, p_prefix text, p_width int, p_radix int, p_unit text,
  p_alphabet text default null, p_discard_bits int default 0, p_epoch timestamptz default '1970-01-01 00:00:00+00')
returns timestamptz language plpgsql stable as $$
declare v_digits text; v_wide numeric; v_count numeric;
begin
  if p_unit not in ('ms', 's') then
    raise exception 'pg_partition_magician: unknown text_time unit % (expected ms or s)', p_unit;
  end if;
  if p_value is null or left(p_value, length(p_prefix)) <> p_prefix
     or length(p_value) < length(p_prefix) + p_width then
    raise exception 'pg_partition_magician: % does not have the expected text_time shape (prefix %, % base-% digit(s))', p_value, p_prefix, p_width, p_radix
      using errcode = 'invalid_text_representation';
  end if;
  v_digits := substr(p_value, length(p_prefix) + 1, p_width);
  v_wide := pgpm._radix_decode(v_digits, p_radix, p_alphabet);
  v_count := pgpm._floor_div(v_wide, power(2::numeric, p_discard_bits));   -- exact, not floor(a / b) (#659)
  if p_unit = 'ms' then return p_epoch + (v_count / 1000.0) * interval '1 second';
  else return p_epoch + v_count * interval '1 second'; end if;
end;
$$;

-- The boundary this produces is deliberately MINIMAL: prefix + the zero-padded digits, nothing
-- appended after. That is still a correct half-open range edge, because any REAL value sharing that
-- exact prefix+timestamp with a nonempty suffix (the counter/fingerprint/random fields real ids carry)
-- sorts strictly after it -- a string is always less than any longer string that extends it. So this
-- needs no knowledge of the source format's total width or trailing fields at all, which is what makes
-- it general rather than cuid-specific.
create or replace function pgpm._ts_to_text_time(p_ts timestamptz, p_prefix text, p_width int, p_radix int, p_unit text,
  p_alphabet text default null, p_discard_bits int default 0, p_epoch timestamptz default '1970-01-01 00:00:00+00')
returns text language plpgsql stable as $$
declare v_count numeric; v_wide numeric;
begin
  if p_unit = 'ms' then v_count := floor(extract(epoch from (p_ts - p_epoch)) * 1000);
  elsif p_unit = 's' then v_count := floor(extract(epoch from (p_ts - p_epoch)));
  else raise exception 'pg_partition_magician: unknown text_time unit % (expected ms or s)', p_unit;
  end if;
  if v_count < 0 then
    raise exception 'pg_partition_magician: % is before % (the configured epoch), which a % text_time encoding cannot express', p_ts, p_epoch, p_unit
      using errcode = 'numeric_value_out_of_range';
  end if;
  v_wide := v_count * power(2::numeric, p_discard_bits);
  return p_prefix || pgpm._radix_encode(v_wide, p_radix, p_width, p_alphabet);
end;
$$;

-- The bounds above are ordered by base-N place value, which is bytewise for every alphabet pgpm
-- documents (0-9 < A-Z < a-z in ASCII). A RANGE partition on a text column compares under the column's
-- COLLATION, and the two agree only when the collation orders the digit alphabet the way the arithmetic
-- does. en_US (glibc and ICU alike) weighs case below letter identity, so 'a' sorts before 'P' while
-- base62 puts a = 36 above P = 25: random-payload KSUIDs on a default-collation database fail the
-- pgpm_monolith_bound CHECK at VALIDATE, and a small table that happens to pass routes rows to the wrong
-- month, where retain drops them early (issue #456). Single-case alphabets (cuid's 0-9a-z, ULID's
-- Crockford upper, ObjectId's hex) order the same way under both. transmute and check_text_time both
-- refuse through this before anything is touched.
--
-- The comparison is of STRINGS at the declared width, not of single characters: the largest string
-- whose first digit is c[i] must sort before the smallest whose first digit is c[i+1], that is
-- '<prefix>c[i]<max digit>...' < '<prefix>c[i+1]<zero digit>...'. A single-character test is not
-- enough, because a multi-level collation can order two characters at a secondary or tertiary level
-- (case, accent) and then let a difference at a LATER position, compared at the primary level first,
-- override it: under en_US 'a' < 'A' and yet 'aZ' > 'Ab'. The string form fails exactly when the two
-- digits are not separated at the primary level, which is the condition fixed-width digit strings
-- need. Adjacent pairs suffice, since primary weights are transitive. The other property the bounds
-- rely on, that a string sorts before any longer string extending it, needs no check here: every
-- collation PostgreSQL offers is deterministic unless created otherwise, and a deterministic collation
-- breaks a tie at every level bytewise, where the shorter string is less.
--
-- That argument assumes the collation compares position by position. An ICU collation with numeric
-- ordering ('und-u-kn-true', or any locale carrying -u-kn-true, possible as a database default on 15+)
-- does not: it weighs a RUN of decimal digits by its value, so 'ck9abcde' < 'ck10000'. The probe above
-- passes it (the zero padding extends the higher digit's run, and 1 < 2000...), and cuid rows were
-- routed a month early (issue #568). Two more probes per adjacent pair catch a run weighed by value:
-- the opposite padding, '<prefix>c[i]<zero>...' < '<prefix>c[i+1]<max>...' (a lower cell's bound
-- against a higher cell's value; under numeric ordering 1000... > 2 when the max digit is a letter),
-- and '<prefix>c[i]<max>...<s>' < '<prefix>c[i+1]<zero>...' for every digit s (a lower cell's value,
-- which a real id always extends with more characters, against the next cell's bound; this is what
-- catches a pure-decimal alphabet, whose paddings are digits either way). Both hold under any collation
-- that compares position by position with the digits separated at the primary level, so neither can
-- refuse a collation the first probe accepts for that reason.
create or replace function pgpm._check_text_time_collation(
  p_table regclass, p_control name, p_prefix text, p_width int, p_radix int, p_alphabet text default null)
returns void language plpgsql as $$
declare
  v_alphabet text; v_collnsp name; v_collname name; v_coll_q text; v_dbloc text; v_coltype text; v_pad int;
  v_bad_i int; v_bad_c1 text; v_bad_c2 text; v_bad_lo text; v_bad_hi text;
begin
  v_alphabet := coalesce(p_alphabet, substr('0123456789abcdefghijklmnopqrstuvwxyz', 1, p_radix));
  v_pad := greatest(coalesce(p_width, 1), 1) - 1;
  select n.nspname, co.collname, format_type(a.atttypid, a.atttypmod)
    into v_collnsp, v_collname, v_coltype
    from pg_attribute a
    join pg_collation co on co.oid = a.attcollation
    join pg_namespace n on n.oid = co.collnamespace
   where a.attrelid = p_table and a.attname = p_control and not a.attisdropped;
  if v_collname is null then
    return;   -- no collation on the column (not a collatable type), so nothing but bytes orders the bounds
  end if;
  v_coll_q := format('%I.%I', v_collnsp, v_collname);
  -- A text column declared without COLLATE carries the "default" pseudo-collation, which resolves to
  -- the database's own. The message names that effective locale, since "default" alone tells the
  -- operator nothing. pg_database's column for the provider locale is daticulocale on 15/16 and
  -- datlocale on 17+, and is null under libc, hence the row-as-jsonb read.
  if v_collnsp = 'pg_catalog' and v_collname = 'default' then
    select coalesce(j->>'datlocale', j->>'daticulocale', j->>'datcollate') into v_dbloc
      from (select to_jsonb(d) as j from pg_database d where d.datname = current_database()) x;
  end if;
  -- %4$s is the max-digit padding, %6$s the zero-digit padding; each probe row is (pair, lower string,
  -- higher string), and the first pair with any probe the collation does not order strictly is reported.
  execute format($q$
    with d(i, c) as (select i, substr(%1$L, i, 1) from generate_series(1, %2$s) as i),
    probe(i, c1, c2, n, lo, hi) as (
      select x.i, x.c, y.c, 0, %3$L || x.c || %4$L, %3$L || y.c || %6$L
        from d x join d y on y.i = x.i + 1
      union all
      select x.i, x.c, y.c, 1, %3$L || x.c || %6$L, %3$L || y.c || %4$L
        from d x join d y on y.i = x.i + 1
      union all
      select x.i, x.c, y.c, 2 + s.i, %3$L || x.c || %4$L || s.c, %3$L || y.c || %6$L
        from d x join d y on y.i = x.i + 1 cross join d s
    )
    select i, c1, c2, lo, hi
      from probe
     where not ((lo::text collate %5$s) < (hi::text collate %5$s))
     order by i, n limit 1
  $q$, v_alphabet, length(v_alphabet), coalesce(p_prefix, ''),
       repeat(substr(v_alphabet, length(v_alphabet), 1), v_pad), v_coll_q, repeat(substr(v_alphabet, 1, 1), v_pad))
  into v_bad_i, v_bad_c1, v_bad_c2, v_bad_lo, v_bad_hi;
  if v_bad_i is not null then
    raise exception 'pg_partition_magician: column %.% has collation %, which does not order the text_time digit alphabet the way base-% place value does: digit % (value %) must sort before digit % (value %) in every position, and under that collation it does not (% does not sort before %). RANGE bounds on a text column compare under the column''s collation while the encoded timestamp orders bytewise, so rows would be routed to the wrong partition: the pgpm_monolith_bound check fails at VALIDATE, or on a table that passes it, rows land in a neighbouring partition and retention drops them early. Give the column a bytewise collation: alter table % alter column % type % collate "C" (rewrites the table), or create the column with collate "C" to begin with.',
      p_table::text, quote_ident(p_control),
      case when v_dbloc is not null then format('"default" (the database default, %s)', v_dbloc) else quote_ident(v_collname) end,
      length(v_alphabet), quote_literal(v_bad_c1), v_bad_i - 1, quote_literal(v_bad_c2), v_bad_i,
      quote_literal(v_bad_lo), quote_literal(v_bad_hi),
      p_table::text, quote_ident(p_control), v_coltype;
  end if;
end;
$$;

-- native grid type for comparisons: numeric for id, timestamptz otherwise
create or replace function pgpm._native_type(p_kind text)
returns text language sql immutable as $$
  select case when p_kind = 'id' then 'numeric' else 'timestamptz' end;
$$;

create or replace function pgpm._native_gt(p_kind text, a text, b text)
returns boolean language plpgsql immutable as $$
begin
  if p_kind = 'id' then return a::numeric > b::numeric;
  else return a::timestamptz > b::timestamptz; end if;
end;
$$;

-- A native timestamptz as TEXT, rendered the same way from every session (#500). Every native time value
-- pgpm stores (pgpm.part.lo/hi, pgpm.log.lo/hi, config.partition_anchor, transmute_inflight.lo/hi, the
-- archive ledger's bounds) is text written by one session and read back with ::timestamptz by another:
-- the operator's transmute writes, pg_cron's maintain reads. A bare ::text renders in the WRITING
-- session's DateStyle, and under 'SQL, DMY' 1 October 2026 is '01/10/2026 00:00:00 UTC', which a session
-- on the default 'ISO, MDY' reads back as 10 January. Every bound then meant a different instant to
-- maintenance than it meant to the operator, and retain() dropped a monolith whose real hi was next
-- month, today's rows included. ISO 8601 output ('2026-10-01 00:00:00+00') is the one form the parser
-- reads identically under every DateStyle, so the SET clause pins it for the duration of this call and
-- this call only. Parses are deliberately NOT pinned: a caller's own parse (now()::text handed straight
-- back to _grid_floor, a control value read in the caller's session) still honours the caller's setting,
-- which is what lets session-rendered text go INTO the adapter and canonical text come OUT of it.
--
-- Every site where a timestamptz becomes native text goes through here (the four dynamic max(hi) reads
-- over pgpm.part and pgpm.archive_ledger through _max_hi_native below); a bare `::text` on such a value
-- IS the defect. Pinned to ISO only, not to a zone: the offset carried in the text makes the instant
-- exact whatever zone rendered it. bench/mutations/mutate.py's datestyle_session_render removes the
-- clause to put the defect back.
create or replace function pgpm._ts_text(p_ts timestamptz)
returns text language sql stable set datestyle = 'ISO, MDY' as $$
  select p_ts::text;
$$;

-- The SQL for "the greatest hi among the rows a query selects, as canonical native text" (#500): the
-- dynamic counterpart of _ts_text for the four max(hi) reads over pgpm.part and pgpm.archive_ledger,
-- whose native type is only known at run time. Cast BEFORE max() so the comparison is numeric or
-- temporal, never lexicographic ('91' > '1000'), and render the time kinds through _ts_text so what
-- comes back (and, in _next_archive_chunk, goes on to be stored as the next chunk's lo) is canonical
-- whichever session runs the read. Spliced with %s: a fixed expression over the column hi, with no
-- identifier in it that could need quoting.
create or replace function pgpm._max_hi_native(p_kind text)
returns text language sql immutable as $$
  select case when p_kind = 'id' then 'max(hi::numeric)::text' else 'pgpm._ts_text(max(hi::timestamptz))' end;
$$;

-- is a retain value non-negative on its kind's scale (#451)? A count of ids for id, an interval for
-- everything else: the same split _retain_boundary makes. A negative value is never a valid retention
-- policy: it puts the horizon PAST the partition taking writes, so every partition is drop-eligible at once
-- and the first tick takes the table offline. Zero is legitimate: its horizon is the write partition's own
-- floor, so it keeps exactly that partition and ages everything behind it (tests/63 relies on it). Null is
-- null here (no policy); callers decide what that means for them.
--
-- #565: an interval is judged FIELD BY FIELD (months, days, time), never with `>= interval '0'`. Interval
-- comparison normalises a month to 30 days and a year to 360, while the horizon this protects is calendar
-- arithmetic on the wall clock (_retain_boundary), where a year is 365 or 366 days and a month 28 to 31: so
-- '-1 year 360 days' compared equal to zero and was accepted, and its horizon sat five or six days in the
-- future. A mixed-sign value has no calendar-independent sign at all ('-1 mon 30 days' is a day ahead of now
-- from a 31-day month and two behind from February), while a value with no negative field moves the wall
-- clock back, or leaves it, on every date. The mixed-sign values that happen to net positive ('1 mon -1 day')
-- are refused with the rest; no retention policy needs one.
--
-- #649: numeric has a NaN, and PostgreSQL orders it ABOVE every number, so `>= 0` alone accepted 'NaN' as
-- non-negative. Its horizon is frontier - NaN = NaN, every partition's hi sorts below that, and one tick
-- dropped every partition, the one taking writes included. NaN is refused with the negative values.
create or replace function pgpm._retain_nonnegative(p_kind text, p_retain text)
returns boolean language plpgsql immutable as $$
declare v_i interval;
begin
  if p_kind = 'id' then return p_retain::numeric >= 0 and p_retain::numeric <> 'NaN'::numeric; end if;
  v_i := p_retain::interval;
  -- date_trunc keeps the months, then the months and days; the differences isolate one field each, and a
  -- single-field interval compares exactly
  return date_trunc('month', v_i) >= interval '0'
     and date_trunc('day', v_i) - date_trunc('month', v_i) >= interval '0'
     and v_i - date_trunc('day', v_i) >= interval '0';
end;
$$;

-- where x sits between lo and hi on the native grid, as a fraction: (x - lo) / (hi - lo). The one place
-- pgpm subtracts native values rather than comparing them; progress() uses it to turn config.regrain_cursor
-- into an exact fraction of the coarse child's RANGE (issue #343). null for an empty range (hi <= lo), so
-- a caller never divides by zero. Deliberately not clamped: the cursor is within [lo, hi] by construction,
-- and a value outside it would be a bug worth seeing rather than one worth hiding.
create or replace function pgpm._native_frac(p_kind text, p_lo text, p_hi text, p_x text)
returns numeric language plpgsql immutable as $$
declare v_span numeric; v_off numeric;
begin
  if p_kind = 'id' then
    v_span := p_hi::numeric - p_lo::numeric;
    v_off  := p_x::numeric  - p_lo::numeric;
  else
    v_span := extract(epoch from (p_hi::timestamptz - p_lo::timestamptz));
    v_off  := extract(epoch from (p_x::timestamptz  - p_lo::timestamptz));
  end if;
  if v_span <= 0 then return null; end if;
  return v_off / v_span;
end;
$$;

-- ==================== the zone the grid lives in (#455) ====================
--
-- Every function below that does calendar arithmetic or renders a calendar label takes the zone as a
-- PARAMETER (config.partition_tz) and never consults the session's TimeZone. Before this, a transmute
-- under America/New_York built children on the 00:00-04/-05 lattice while pg_cron, under the server's
-- UTC, computed obtain's candidates on the 00:00+00 lattice, found each half-overlapping an existing
-- child, skipped it, and left a permanent hole about p_obtain steps out with nothing logged.
--
-- The shape of every calendar step is: instant -> wall time in p_tz (`at time zone p_tz` on a
-- timestamptz gives a timestamp) -> the arithmetic -> back to an instant (`at time zone p_tz` on a
-- timestamp). date_trunc and `+ interval` on a plain timestamp are zone-free, which is the point.

-- The canonical spelling of a zone name, or null when pg_timezone_names does not list it. Only names
-- from that view are ever stored: an abbreviation ('EST') or a POSIX rule ('EST5EDT', 'XYZ5') is also
-- accepted by `set timezone`, but the stored value has to mean the same instants for the life of the
-- table, and only a named zone carries its own rules.
create or replace function pgpm._canonical_tz(p_tz text)
returns text language sql stable as $$
  select name from pg_timezone_names where lower(name) = lower(p_tz) order by name limit 1;
$$;

-- Is the control column NAIVE: timestamp without time zone, or date? Such a value carries no zone of
-- its own, so its grid is the column's own wall clock: partition_tz is 'UTC' for it (#504) and
-- _col_to_native reads it as wall time in that zone. false for every other column type, and for a
-- missing column.
create or replace function pgpm._control_naive(p_parent regclass, p_control name)
returns boolean language sql stable as $$
  select coalesce((select t.typname in ('timestamp', 'date')
                     from pg_attribute a join pg_type t on t.oid = a.atttypid
                    where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped), false);
$$;

-- An instant as a literal that means the same thing in every column type the `time` kind accepts.
-- Rendered as wall time in p_tz WITH that instant's numeric offset: a timestamptz column reads the
-- exact instant from the offset; a timestamp or date column ignores the offset (PostgreSQL's documented
-- rule for zone-carrying input to a zoneless type) and keeps the wall time in p_tz, which is precisely
-- what a naive value means here (p_tz is 'UTC' for such a column, #504, so that wall time is the
-- column's own reading of the lattice instant). So one literal serves `for values from`, the monolith's
-- bound CHECK and every `ctl >= lo and ctl < hi` predicate, from any session, for all three column types.
create or replace function pgpm._time_literal(p_ts timestamptz, p_tz text)
returns text language plpgsql immutable as $$
declare v_wall timestamp; v_off int; v_us text;
begin
  v_wall := p_ts at time zone p_tz;
  v_off  := extract(epoch from (v_wall - (p_ts at time zone 'UTC')))::int;
  v_us   := rtrim(to_char(v_wall, 'US'), '0');
  return to_char(v_wall, 'YYYY-MM-DD HH24:MI:SS')
      || case when v_us = '' then '' else '.' || v_us end
      || case when v_off < 0 then '-' else '+' end
      || lpad((abs(v_off) / 3600)::text, 2, '0') || ':' || lpad(((abs(v_off) % 3600) / 60)::text, 2, '0')
      || case when abs(v_off) % 60 = 0 then '' else ':' || lpad((abs(v_off) % 60)::text, 2, '0') end
      -- #733: 'YYYY' prints the year without its era, so an instant before 1 AD read back as an AD year
      -- about 2 x |year| later (100 BC became 0100, i.e. 100 AD). The era goes last, where PostgreSQL's
      -- own output puts it and where every DateStyle's input reads it, for all three column types.
      || case when v_wall < timestamp '0001-01-01 00:00:00' then ' BC' else '' end;
end;
$$;

-- The zone-explicit signatures below replace these. Dropped, not left behind: an upgrade that kept the
-- old overload would let a stale caller bind to it by arity and compute in the session zone again.
drop function if exists pgpm._grid_floor(text, text, text, text);
drop function if exists pgpm._grid_next(text, text, text);
drop function if exists pgpm._part_name(name, text, text, text, text);
drop function if exists pgpm._encode(text, text, text, int, int, text, text, int, timestamptz);

-- floor a native value to the partition-grid lower bound, computed in p_tz
--
-- The fixed branch adds the offset k steps from the anchor exactly (#710). make_interval(secs => k * v_secs)
-- converted the product to double precision, which carries a microsecond exactly only below 2^53 us (about
-- 285 years): exact for a whole-second step at any distance, but a fractional-second step far from the
-- anchor ('1.000001 seconds' from a year-1 anchor) came back microseconds off the lattice, so _grid_next of
-- one cell missed the floor of the next. Whole hours carry the bulk as integers (in two halves, so the
-- full timestamp range fits make_interval's int), and only the sub-hour remainder, under 3.6e9 us, goes
-- through double precision. An absolute offset like the old one, never days (a day added to a timestamptz
-- is a calendar day in the session's zone).
create or replace function pgpm._grid_floor(p_kind text, p_step text, p_anchor text, p_native text, p_tz text)
returns text language plpgsql immutable as $$
declare
  v_months int; v_fixsecs double precision; v_secs numeric;
  k bigint; ts timestamptz; anc timestamptz; ts_wall timestamp; anc_wall timestamp; v_out timestamptz;
  v_us numeric; v_h numeric;
begin
  if p_kind in ('time', 'uuidv7', 'text_time') then
    anc := p_anchor::timestamptz; ts := p_native::timestamptz;
    v_months  := (extract(year from p_step::interval) * 12 + extract(month from p_step::interval))::int;
    v_fixsecs := extract(epoch from (p_step::interval - make_interval(months => v_months)));
    v_secs    := extract(epoch from p_step::interval);
    if v_months > 0 then
      if v_fixsecs <> 0 then
        raise exception 'pg_partition_magician: mixed month + duration interval unsupported (%)', p_step;
      end if;
      -- calendar step: count months on the WALL clock in p_tz, so a month boundary is midnight on the
      -- 1st in that zone whatever zone this session happens to be in
      ts_wall := ts at time zone p_tz; anc_wall := anc at time zone p_tz;
      k := ((extract(year from ts_wall) - extract(year from anc_wall)) * 12
          + (extract(month from ts_wall) - extract(month from anc_wall)))::bigint;
      k := (floor(k::numeric / v_months) * v_months)::bigint;
      v_out := (date_trunc('month', anc_wall) + make_interval(months => k::int)) at time zone p_tz;
      -- #584: a floor never exceeds its input. Where a fall-back repeats midnight on the 1st (America/Havana
      -- at 01:00 CDT back to 00:00 CST on 2020-11-01 and 2026-11-01), `at time zone` resolves the repeated
      -- 00:00 to its LATER occurrence, and that is where the grid's boundary is: _grid_next converts the
      -- same way, so every grid ever built in such a zone has its cell edge there. A value in the FIRST
      -- occurrence of the hour reads November on the wall clock but lies before that edge, in the October
      -- cell, and this used to return the November edge for it, above the value: transmute took it as the
      -- monolith's lo, the bound CHECK excluded the oldest row, and VALIDATE failed on every run. So such
      -- a value floors to the boundary before, the greatest grid point at or below it. Moving the
      -- boundary to the earlier midnight instead would have moved it under every existing grid in such a
      -- zone, leaving each existing cell that spans it an hour wider than one step of the moved lattice.
      -- In a gap (#505) the boundary is the first instant after the gap and
      -- no value reads that month before it, so this never fires there.
      if v_out > ts then
        k := k - v_months;
        v_out := (date_trunc('month', anc_wall) + make_interval(months => k::int)) at time zone p_tz;
      end if;
      return pgpm._ts_text(v_out);
    else
      -- fixed step: an absolute lattice of v_secs from the anchor instant. Zone-free by construction,
      -- and _grid_next's fixed branch adds the same v_secs, so the two can never disagree. The count is
      -- exact numeric (#659): in double precision a value one microsecond below a boundary far from the
      -- anchor (an anchor in year 1, a daily step) divided to the boundary's own count, above its input.
      k := pgpm._floor_div(extract(epoch from (ts - anc)), v_secs)::bigint;
      -- and the offset added exactly (#710, see above)
      v_us := k * v_secs * 1000000;
      v_h  := floor(v_us / 3600000000);
      return pgpm._ts_text(anc + make_interval(hours => trunc(v_h / 2)::int)
                               + make_interval(hours => (v_h - trunc(v_h / 2))::int,
                                               secs => ((v_us - v_h * 3600000000) / 1000000)::double precision));
    end if;
  elsif p_kind = 'id' then
    return (pgpm._floor_div(p_native::numeric - p_anchor::numeric, p_step::numeric) * p_step::numeric + p_anchor::numeric)::text;
  else
    raise exception 'pg_partition_magician: unknown control_kind %', p_kind;
  end if;
end;
$$;

-- the next grid boundary after p_lo, computed in p_tz
create or replace function pgpm._grid_next(p_kind text, p_step text, p_lo text, p_tz text)
returns text language plpgsql immutable as $$
declare v_months int; v_wall timestamp;
begin
  if p_kind in ('time', 'uuidv7', 'text_time') then
    v_months := (extract(year from p_step::interval) * 12 + extract(month from p_step::interval))::int;
    if v_months > 0 then
      -- calendar step, on the wall clock in p_tz: the same arithmetic _grid_floor's month branch does.
      -- Snapped first (#505). A grid value is the first instant of its month in p_tz, and where midnight
      -- on the 1st fell in a DST gap (America/Asuncion 2023-10-01, Asia/Amman 2016-04-01) that instant
      -- reads 01:00 on the wall clock: adding the months to the reading as it stands lands an hour past
      -- the next boundary, next(floor(Oct)) <> floor(Nov), and regrain_step's consecutive sub-ranges
      -- overlap by that hour (the swap's ATTACH fails "would overlap", skip_regrain on every tick). The
      -- snap applies only to an instant that IS its month's first instant (the wall midnight of its
      -- month converts back to exactly it); an off-grid value, such as the anchor set_regrain steps from
      -- to compare two widths, still moves by a plain calendar month from its own reading.
      v_wall := p_lo::timestamptz at time zone p_tz;
      if (date_trunc('month', v_wall) at time zone p_tz) = p_lo::timestamptz then
        v_wall := date_trunc('month', v_wall);
      end if;
      return pgpm._ts_text((v_wall + make_interval(months => v_months)) at time zone p_tz);
    end if;
    -- Fixed step: an absolute number of seconds, NOT `+ p_step::interval`. On a timestamptz, `+ '1 day'`
    -- is a calendar day in the session zone (23 or 25 hours across a DST transition) while _grid_floor's
    -- fixed branch is an absolute 86400 s lattice, and the hour they disagreed by every autumn was a hole
    -- in the grid: each lattice candidate half-overlapped a chain child and was skipped. So a "day" step
    -- is 86400 seconds here, a "week" 604800, and in a DST-observing partition_tz a daily boundary drifts
    -- an hour against local midnight twice a year. That is the price of a contiguous grid; UTC pays nothing.
    return pgpm._ts_text(p_lo::timestamptz + make_interval(secs => extract(epoch from p_step::interval)));
  elsif p_kind = 'id' then return (p_lo::numeric + p_step::numeric)::text;
  else raise exception 'pg_partition_magician: unknown control_kind %', p_kind; end if;
end;
$$;

-- native grid value -> a literal of the COLUMN type. The text_time_* params are text_time-only (default
-- null for every other kind, which never reads them) -- see pgpm.config's text_time_* columns. p_tz is
-- read by the `time` kind only, whose literal is rendered in it (_time_literal, #455). Every caller in
-- this file and in pgpm_archive passes config.partition_tz; the archive transports did not until #501,
-- and read a naive column's chunk in the wrong hour for it. The 'UTC' default stays only so that a
-- pgpm_archive older than this parameter still installs and runs: on a timestamptz column any offset
-- rendering is exact, so it is only wrong for a naive column in a non-UTC zone. Do not lean on it.
-- the two-argument shape shipped in 0.1.0 and 0.2.0; kept beside this one, a two-argument call is ambiguous (#441)
drop function if exists pgpm._encode(text, text);
create or replace function pgpm._encode(p_kind text, p_native text,
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00',
  p_tz text default 'UTC')
returns text language plpgsql immutable as $$
begin
  if p_kind = 'uuidv7' then return pgpm._ts_to_uuid(p_native::timestamptz)::text;
  elsif p_kind = 'text_time' then
    return pgpm._ts_to_text_time(p_native::timestamptz, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit,
                                  p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);
  elsif p_kind = 'time' then return pgpm._time_literal(p_native::timestamptz, p_tz);
  else return p_native; end if;
end;
$$;

-- a stored COLUMN value -> native grid value. Same text_time_* trailing params as _encode.
-- the two-argument shape shipped in 0.1.0 and 0.2.0; same hazard as _encode (#441)
drop function if exists pgpm._decode(text, text);
create or replace function pgpm._decode(p_kind text, p_colvalue text,
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00')
returns text language plpgsql immutable as $$
begin
  if p_colvalue is null then return null; end if;
  if p_kind = 'uuidv7' then return pgpm._ts_text(pgpm._uuid_to_ts(p_colvalue::uuid));
  elsif p_kind = 'text_time' then
    return pgpm._ts_text(pgpm._text_time_to_ts(p_colvalue, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit,
                                               p_tt_alphabet, p_tt_discard_bits, p_tt_epoch));
  else return p_colvalue; end if;
end;
$$;

-- A raw control-column value (its ::text) as a native-grid value: _decode, plus the one rule the `time`
-- kind adds (#455). A NAIVE column (timestamp without time zone, date) carries no zone, and its text cast
-- through ::timestamptz would take the SESSION's zone, so the same stored value would decode to one
-- instant in an operator's session and another in pg_cron's. It is read as wall time in partition_tz
-- instead, which is exactly what _time_literal writes back; and partition_tz is 'UTC' for such a column
-- (#504), so this maps the column's own reading onto the lattice unchanged. A timestamptz column's text carries its
-- offset, but it round-trips exactly only when it was rendered through _ts_text (ISO): a bare ::text under
-- a DateStyle that renders zone abbreviations (SQL, Postgres) can name another zone ('IST' under
-- Europe/Dublin or Asia/Kolkata reads as Israel), so callers hand this _ts_text of the value (#788).
-- Always ::timestamp first: `date at time zone` casts the date to a timestamptz in the session zone and
-- converts the WRONG way. Per-row SQL (regrain's reconcile) inlines
-- the same rule as an expression rather than calling this, which does a catalog lookup.
create or replace function pgpm._col_to_native(p_cfg pgpm.config, p_raw text)
returns text language plpgsql stable as $$
begin
  if p_raw is null then return null; end if;
  if p_cfg.control_kind = 'time' then
    if pgpm._control_naive(p_cfg.parent_table, p_cfg.control_column) then
      return pgpm._ts_text(p_raw::timestamp at time zone p_cfg.partition_tz);
    end if;
    return pgpm._ts_text(p_raw::timestamptz);
  end if;
  return pgpm._decode(p_cfg.control_kind, p_raw,
                      p_cfg.text_time_prefix, p_cfg.text_time_width, p_cfg.text_time_radix, p_cfg.text_time_unit,
                      p_cfg.text_time_alphabet, p_cfg.text_time_discard_bits, p_cfg.text_time_epoch);
end;
$$;

-- An id grid value as a label (#582). Zero-padded to 19 digits so the names of a bigint grid sort in
-- grid order and keep the form they have always had; a longer value (a numeric key at or past 10^19, or at
-- or below -10^18) is left WHOLE, because lpad truncates a string longer than its width and the
-- cell at 10^19 rendered the cell at 10^18's name. A non-integral value (a regrain toward a fractional
-- step on a numeric column) keeps its fraction as `_<digits>`, trailing zeros dropped so that one value has
-- one label whatever scale its text was written at; floor() alone put 1 and 1.5 under one name. Injective:
-- a padded label begins with 0 and an unpadded one never does, and the fraction is the only `_`.
create or replace function pgpm._id_label(p_native text)
returns text language sql immutable as $$
  select case when length(i.whole) < 19 then lpad(i.whole, 19, '0') else i.whole end
      || case when i.frac = 0 then '' else '_' || rtrim(substr(i.frac::text, 3), '0') end
    from (select floor(p_native::numeric)::text as whole,
                 p_native::numeric - floor(p_native::numeric) as frac) i
$$;

-- Is p_suffix (a relation's name with its "<rel>_p" prefix cut off) the label of one FINE child of a grid
-- of this kind? transmute's orphan guard and restore_incoming_fks's in-flight gate both ask, and both
-- call this, so the two cannot drift apart (#726). An id suffix is recognised by the round trip through
-- _id_label itself, not by a pattern of its shape: both sites matched '^[0-9]{19}$', the label before
-- #582, so an orphan named for a cell at or past 10^19 (20 or more digits), for a fractional cell
-- (`_<frac>`) or for a short negative one (lpad puts the zeros before the sign) passed the guard, the
-- conversion completed, obtain left that cell unbuilt with nothing logged, and every write into it was
-- refused. Read back as the value it names (zeros, sign, whole, fraction) and relabelled, a suffix is a
-- label exactly when it comes back unchanged, so whatever _id_label produces is recognised and a string
-- it never produces (a trailing zero in the fraction, an extra leading zero) is not. The pattern below
-- only keeps the cast to numeric safe; it decides nothing. A time label is digits in groups, the first
-- of four (the year); the coarse and explicit-range forms (_to_) are neither, and are checked elsewhere.
create or replace function pgpm._is_fine_child_label(p_kind text, p_suffix text)
returns boolean language plpgsql immutable as $$
declare v_whole text; v_frac text;
begin
  if p_kind <> 'id' then
    return p_suffix ~ '^[0-9]{4}(_[0-9]+)*$';
  end if;
  if p_suffix !~ '^(0*-)?[0-9]+(_[0-9]+)?$' then
    return false;
  end if;
  v_whole := split_part(p_suffix, '_', 1);
  v_frac  := split_part(p_suffix, '_', 2);
  if position('-' in v_whole) > 0 then
    v_whole := '-' || split_part(v_whole, '-', 2);
  end if;
  return pgpm._id_label((v_whole::numeric
                         + case when v_frac = '' then 0 else ('0.' || v_frac)::numeric end)::text) = p_suffix;
end;
$$;

-- _part_name maps a partition's NATIVE [lo, hi) to its child table name. A one-step range (hi is the
-- next grid value after lo, the common fine partition) keeps the historical name _p<lo>; a wider range
-- (a coarse / monolith child, REDESIGN.md section 6) is named _p<lo>_to_<hi> so it can never collide
-- with the fine child at its low edge. Both bounds are formatted at the step's granularity. hi is
-- optional: omitted (or equal to the one-step value) yields the fine name, so existing callers are
-- unchanged. The name is a human-facing LABEL (pgpm.part holds the authoritative bounds), but it is also
-- how obtain, extend_to and regrain_step ask whether a child ALREADY EXISTS (to_regclass on this name), so
-- it has to be unique per range: a name that would exceed PostgreSQL's 63-byte identifier limit is
-- REFUSED rather than truncated (#510, below).
--
-- The label's zone follows the cell's definition. A calendar cell (month, year) is defined on the wall
-- clock in p_tz, so it is labelled by its wall month there (#455): "the month it is in partition_tz",
-- which is what the operator who chose the zone reads off the name. A fixed-second cell (day, week,
-- hour, minute) is an absolute lattice from the anchor instant, zone-free by construction, and is
-- labelled by the UTC reading of its start (#503): two instants a whole number of days apart never share
-- a UTC date, and two an hour apart never share a UTC hour. The wall clock of a DST-observing zone does
-- both. It repeats an hour every autumn, which is why sub-day labels were in UTC from the start; and the
-- day lattice drifts an hour against local midnight twice a year, so the two day cells straddling a
-- fall-back could start on the same wall date (00:00 EDT and 23:00 EST of the same Sunday when the
-- anchor is a summer midnight; the 00:00Z cells of the Sunday and the Monday in Atlantic/Azores). obtain
-- skips a candidate whose name already exists, so a shared label was a permanent one-day hole, and it
-- also meant set_partition_tz on a day grid moved every label onto its neighbour's. Labelled in UTC, a
-- day grid's zone changes nothing about it at all: bounds and names are both absolute.
--
-- p_explicit asks for the explicit-range form _p<lo>_to_<hi> even for a one-step range (#572). No caller
-- asks for it unless the plain name is taken by another range's partition of the same parent, which only
-- an upgrade can arrange: a day or week child named before #503 carries its WALL date in partition_tz,
-- and east of UTC with a local-midnight anchor that is exactly the UTC date of the cell after it. See
-- _obtain_name. A one-step explicit name never equals a plain name (no `_to_`) nor a coarse one (its two
-- labels are one step apart, a coarse child's at least two).
-- And the label has to be fine enough for the step (#582). Two cells of a fixed step are at least one step
-- apart, so a label at the step's own granularity (or finer) never repeats: a minute label for a step of
-- a minute or more, a second label (HH24MISS) for a step under a minute, a microsecond label for a step
-- under a second. The finest label used to be the minute, so the two cells of a 30-second step shared a
-- name, obtain built every other cell and regrain copied the second cell's rows into the first cell's
-- child. An id label is _id_label's: zero-padded to 19 digits and never cut, with a non-integral value's
-- fraction appended. Every label that was already injective keeps its historical form, so no existing
-- grid's names move.
-- And a BC year is marked (#710). to_char's YYYY renders the year's number without its era, so year N BC
-- and year N AD read alike: 1 BC and 1 AD shared every label at every granularity, and on a grid whose data
-- crosses the era the second cell found the first's name taken. A BC label carries a `_bc` suffix; an AD
-- label, which is every label any existing grid has, is unchanged.
drop function if exists pgpm._part_name(name, text, text, text);
drop function if exists pgpm._part_name(name, text, text, text, text, text);
create or replace function pgpm._part_name(p_relname name, p_kind text, p_step text, p_lo_native text,
                                           p_hi_native text, p_tz text, p_explicit boolean default false)
returns name language plpgsql immutable as $$
declare v_months int; v_secs double precision; fmt text; v_coarse boolean; v_lo text; v_hi text; v_label_tz text;
        v_name text;
begin
  v_coarse := p_hi_native is not null
          and (p_explicit
               or pgpm._native_gt(p_kind, p_hi_native, pgpm._grid_next(p_kind, p_step, p_lo_native, p_tz)));
  if p_kind in ('time', 'uuidv7', 'text_time') then
    v_months := (extract(year from p_step::interval) * 12 + extract(month from p_step::interval))::int;
    v_secs   := extract(epoch from p_step::interval);
    v_label_tz := case when v_months > 0 then p_tz else 'UTC' end;
    if    v_months >= 12 and v_months % 12 = 0 then fmt := 'YYYY';
    elsif v_months > 0                          then fmt := 'YYYY_MM';
    elsif v_secs  >= 86400                       then fmt := 'YYYY_MM_DD';
    elsif v_secs  >= 3600                        then fmt := 'YYYY_MM_DD_HH24';
    elsif v_secs  >= 60                          then fmt := 'YYYY_MM_DD_HH24MI';
    elsif v_secs  >= 1                           then fmt := 'YYYY_MM_DD_HH24MISS';
    else                                              fmt := 'YYYY_MM_DD_HH24MISS_US';
    end if;
    -- a BC year is marked (#710, see above)
    v_lo := to_char(p_lo_native::timestamptz at time zone v_label_tz, fmt)
         || case when extract(year from p_lo_native::timestamptz at time zone v_label_tz) < 0 then '_bc' else '' end;
    if v_coarse then
      v_hi := to_char(p_hi_native::timestamptz at time zone v_label_tz, fmt)
           || case when extract(year from p_hi_native::timestamptz at time zone v_label_tz) < 0 then '_bc' else '' end;
    end if;
  else
    v_lo := pgpm._id_label(p_lo_native);
    if v_coarse then v_hi := pgpm._id_label(p_hi_native); end if;
  end if;
  v_name := p_relname || '_p' || v_lo || case when v_coarse then '_to_' || v_hi else '' end;

  -- #510: refuse, never truncate. The cast to name below silently cuts the text to 63 bytes, and an
  -- earlier comment here called that cosmetic because pgpm.part holds the bounds. It is not: obtain,
  -- extend_to and regrain_step decide whether a child already exists BY THIS NAME, so once the label is
  -- cut every candidate renders the same 63 bytes, the monolith takes that name at transmute, every forward
  -- cell is skipped as existing, nothing is logged, and the first write past the monolith's hi is refused
  -- by PostgreSQL with "no partition of relation found for row". Raising here covers every caller at once,
  -- and every caller can afford it: transmute names the monolith before it has claimed or committed
  -- anything, set_regrain asks at call time, and obtain, extend_to and regrain_step are functions, so a
  -- raise unwinds them whole. octet_length, not length: the limit is bytes, and a name may be multibyte.
  if octet_length(v_name) > 63 then
    raise exception 'pg_partition_magician: cannot name a partition of % -- % is % bytes, over PostgreSQL''s 63-byte identifier limit, and pgpm never truncates a partition name (obtain and regrain decide whether a partition already exists by name, so truncated names collide and the forward grid silently stops growing). Shorten the table name by at least % byte(s), or use a coarser step, whose labels are shorter.',
      p_relname, v_name, octet_length(v_name), octet_length(v_name) - 63;
  end if;
  return v_name::name;
end;
$$;

-- _regrain_sub_name: the name regrain_step creates the fine child for sub-range [p_lo, p_hi) of target step
-- p_step under (#783). A sub-range whose lo is ON the target's lattice is a lattice cell and takes the name
-- _part_name gives every cell of that step, unchanged. One whose lo is OFF the lattice is CLAMPED to a
-- child's own lo (only the first sub-range of a child can be), and _part_name's label for it is the label
-- of the lattice cell it sits in, which can be the next cell's: a fixed step is labelled by the UTC reading
-- of its start at the step's granularity (#503, #582), and that reading is the floor of the instant, not
-- the instant. On a monthly grid in America/New_York regrained to '1 day', January's last cell
-- [02-01 00:00Z, 05:00Z) and February's clamped first cell [02-01 05:00Z, 02-02 00:00Z) both read 2024_02_01,
-- so after January was split, every regrain of February was refused for a name January held; a monthly Los
-- Angeles monolith anchored at local midnight clamped [07:00Z, 08:00Z) under the name of the cell after it
-- and wedged auto-regrain the same way, capture left on.
--
-- So a clamped sub-range is labelled at the coarsest granularity, no coarser than the step's own, at which
-- BOTH its bounds read exactly (an hour for a whole-hour zone offset, a minute for Asia/Kolkata, down to the
-- microsecond, which always does), in the plain _p<lo> form. No name of another partition of the parent can
-- equal it unless that partition overlaps it, so none can coexist with it: a name with the same label has
-- its lo in [lo, lo + one unit of that granularity), and since hi also reads exactly, hi is at least one unit
-- past lo, so that lo lies inside [lo, hi). A label of another granularity has another length, and an
-- explicit or coarse name has `_to_`. The one partition a copy overlaps is its own source, which the #266
-- rename in regrain_step already handles through this same function.
--
-- When the step's own granularity already reads both bounds exactly, this IS _part_name's name, so every
-- name that was already injective keeps its form and no existing grid's names move (#582): a weekly
-- regrain of a UTC monthly grid still clamps [2024-03-01, 2024-03-02) under _p2024_03_01. A calendar step
-- (month, year) is left to _part_name, since a child edge of a calendar grid is a calendar edge of the
-- same zone and anchor; and an id label is exact already (_id_label never rounds).
create or replace function pgpm._regrain_sub_name(p_relname name, cfg pgpm.config, p_step text, p_lo text, p_hi text)
returns name language plpgsql stable as $$
declare v_units text[] := array['day', 'hour', 'minute', 'second', 'microseconds'];
        v_label_steps text[] := array['1 day', '1 hour', '1 minute', '1 second', '1 microsecond'];
        v_secs numeric; v_from int; v_lo timestamp; v_hi timestamp;
begin
  if cfg.control_kind not in ('time', 'uuidv7', 'text_time')
     or extract(year from p_step::interval) * 12 + extract(month from p_step::interval) <> 0
     or not pgpm._native_gt(cfg.control_kind, p_lo,
                            pgpm._grid_floor(cfg.control_kind, p_step, cfg.partition_anchor, p_lo, cfg.partition_tz)) then
    return pgpm._part_name(p_relname, cfg.control_kind, p_step, p_lo, p_hi, cfg.partition_tz);
  end if;
  v_secs := extract(epoch from p_step::interval);
  v_from := case when v_secs >= 86400 then 1 when v_secs >= 3600 then 2 when v_secs >= 60 then 3
                 when v_secs >= 1 then 4 else 5 end;   -- _part_name's label granularity for the step
  v_lo := p_lo::timestamptz at time zone 'UTC';
  v_hi := p_hi::timestamptz at time zone 'UTC';
  for i in v_from .. 5 loop
    if date_trunc(v_units[i], v_lo) = v_lo and date_trunc(v_units[i], v_hi) = v_hi then
      if i = v_from then
        return pgpm._part_name(p_relname, cfg.control_kind, p_step, p_lo, p_hi, cfg.partition_tz);
      end if;
      return pgpm._part_name(p_relname, cfg.control_kind, v_label_steps[i], p_lo, null, cfg.partition_tz);
    end if;
  end loop;
  raise exception 'pg_partition_magician: internal error naming sub-range [%, %) of % -- no label granularity reads its bounds exactly',
    p_lo, p_hi, p_relname;
end;
$$;

-- _obtain_name: the name obtain and extend_to build a MISSING cell [p_lo, p_hi) under, or null to leave it
-- unbuilt. Callers ask only after their overlap check has found no attached partition over the range, so
-- a relation holding the plain name is never this cell.
--
-- #572: #503 relabelled day and week cells from the wall date of their start in partition_tz to the UTC
-- date, and left the names of existing children alone. East of UTC with the grid anchored at local
-- midnight (Asia/Tokyo: cells start 15:00Z), a cell's wall date is its UTC date plus one, so the new
-- label of every cell is the old label of the cell before it, and on an upgraded grid the first cell
-- past the last pre-#503 child renders the name that child carries. Both callers used to take that for
-- "already built" and skip the cell: a one-day hole that refused every write into it, nothing logged,
-- while the cells after it were built. So when the plain name belongs to one of THIS parent's own
-- partitions (by identity: pgpm.part.child_oid) over a DIFFERENT range, the cell is built under its
-- explicit-range name instead, and the legacy child is left exactly as it is: no rename, no lock on it.
-- A name held by anything else is left alone as before: that is a relation pgpm does not own.
--
-- #663: the explicit-range name is 14 bytes longer than a day or week cell's plain one (`_to_` and a second
-- label), so for a table name that fits the plain label and not the explicit one (38 to 51 bytes on a day
-- grid), _part_name refuses it (#510). That refusal used to escape from here, and obtain and
-- extend_to are single functions, so it unwound every cell the call would have built: on every tick the
-- whole forward grid stopped growing, not the one cell. The refusal is caught for exactly that name, and
-- the cell is left unbuilt like one whose name a relation pgpm does not own holds: never truncated, and
-- never taking the whole call down with it. Shortening the table name frees the cell.
--
-- #707: a TYPE holding the name is in the way too. CREATE TABLE needs the name free in pg_type as well as
-- in pg_class (a table's row type takes its name), and to_regclass sees relations only, so an enum or
-- domain under a cell's name passed the check and the CREATE died with 42710, unwinding every other cell
-- of the call on every tick: the whole forward grid stopped growing. A type holding the name is treated
-- as a relation pgpm does not own: that one cell is left unbuilt, the rest are built. transmute's
-- orphan-child guard refuses such a type up front (_type_squatter, #671), so only one created after the
-- conversion gets here.
--
-- A null here is a hole in the forward grid, so both callers log it (fail_obtain_name, #710) through
-- _log_unbuilt_cell; this function stays a stable one that only decides.
create or replace function pgpm._obtain_name(p_parent regclass, cfg pgpm.config, p_nsp name, p_rel name,
                                             p_lo text, p_hi text)
returns name language plpgsql stable as $$
declare v_name name; v_held regclass;
begin
  v_name := pgpm._part_name(p_rel, cfg.control_kind, cfg.partition_step, p_lo, p_hi, cfg.partition_tz);
  v_held := to_regclass(format('%I.%I', p_nsp, v_name));
  if v_held is null then
    if pgpm._type_squatter(p_nsp, v_name) is not null then return null; end if;   -- #707
    return v_name;
  end if;
  if not exists (
       select 1 from pgpm.part p
        where p.parent_table = p_parent and p.child_oid = v_held::oid
          and not (pgpm._native_gt(cfg.control_kind, p.hi, p_lo)
                   and pgpm._native_gt(cfg.control_kind, p_hi, p.lo))) then
    return null;
  end if;
  begin
    v_name := pgpm._part_name(p_rel, cfg.control_kind, cfg.partition_step, p_lo, p_hi, cfg.partition_tz, true);
  exception when raise_exception then
    if sqlerrm not like 'pg_partition_magician: cannot name a partition of %' then raise; end if;
    return null;
  end;
  if to_regclass(format('%I.%I', p_nsp, v_name)) is not null then return null; end if;
  if pgpm._type_squatter(p_nsp, v_name) is not null then return null; end if;   -- #707
  return v_name;
end;
$$;

-- _log_unbuilt_cell: what obtain and extend_to log when _obtain_name leaves a cell unbuilt (#710). The cell
-- is a hole in the forward grid: every write into [p_lo, p_hi) is refused with "no partition of relation
-- found for row" until its name is freed, and nothing used to say so, so the operator found it through the
-- refused writes. Logged as fail_obtain_name, because no later tick clears it on its own, naming what holds
-- the cell's plain name: a relation that is not one of this table's partitions, or one of its partitions
-- over another range, in which case the explicit-range name that would have stood in was taken or over 63
-- bytes (see _obtain_name). _obtain_name itself stays a STABLE function that decides and writes nothing; the
-- two callers log, both through this one function. Repeats once per tick while the cell stays unbuilt, the
-- way every other refusal a tick meets does.
create or replace function pgpm._log_unbuilt_cell(p_parent regclass, cfg pgpm.config, p_nsp name, p_rel name,
                                                  p_lo text, p_hi text)
returns void language plpgsql as $$
declare v_name name := pgpm._part_name(p_rel, cfg.control_kind, cfg.partition_step, p_lo, p_hi, cfg.partition_tz);
        v_held regclass := to_regclass(format('%I.%I', p_nsp, v_name));
begin
  insert into pgpm.log (parent_table, action, lo, hi, method)
    values (p_parent, 'fail_obtain_name', p_lo, p_hi,
            format('left unbuilt, so writes into it are refused: its name %I.%I is held by %s',
                   p_nsp, v_name,
                   case when exists (select 1 from pgpm.part p where p.parent_table = p_parent and p.child_oid = v_held::oid)
                        then 'another of this table''s partitions, and its explicit-range name is taken or over 63 bytes'
                        else (select pgpm._relkind_noun(c.relkind) from pg_class c where c.oid = v_held) || ' ' || v_held::text
                             || ', which is not a partition of this table' end));
end;
$$;

-- the write frontier in native terms: now() (time), max(control) (id/uuidv7)
create or replace function pgpm._frontier_native(p_parent regclass)
returns text language plpgsql as $$
declare cfg pgpm.config; v_max text; v_decoded text;
begin
  -- The relation can be gone: pgpm.config.parent_table is a regclass, and DROP TABLE on a managed parent
  -- leaves the row pointing at an oid with no pg_class entry (only untransmute clears pgpm state). A dead
  -- regclass renders as its BARE OID, which the EXECUTE below would interpolate into a FROM clause, so
  -- Postgres reported `syntax error at or near "17379"` -- blaming a syntax error on an integer, with
  -- nothing to tell an operator what actually happened (#296). Checked here rather than in each of the
  -- four callers, so obtain, _retain_boundary, regrain_step and maintain all inherit the real message.
  -- Deliberately BEFORE the control_kind branch: a `time` table returns now() without touching the
  -- relation, so it used to sail past this point and fail further downstream instead.
  if not exists (select 1 from pg_class c where c.oid = p_parent) then
    raise exception 'pg_partition_magician: managed table with oid % no longer exists (dropped without pgpm.untransmute); run pgpm.forget_missing() to clear its pgpm state', p_parent::oid;
  end if;
  select * into cfg from pgpm.config where parent_table = p_parent;
  if cfg.control_kind = 'time' then return pgpm._ts_text(now()); end if;
  -- ORDER BY ... LIMIT 1 (not max()) so it works for uuid too; uses the index.
  -- Qualify with an alias so ORDER BY binds to the (typed) column, not the ::text projection.
  execute format('select t.%I::text from %s t order by t.%I desc limit 1',
                 cfg.control_column, p_parent::text, cfg.control_column) into v_max;
  if v_max is null then
    return case when cfg.control_kind = 'id' then cfg.partition_anchor else pgpm._ts_text(now()) end;
  end if;
  -- #661: a text_time maximum that does not have the declared shape cannot be decoded, and is the clock's
  -- business rather than an error. The bounds are strings, so PostgreSQL routes such a value (a digit
  -- outside the alphabet, a field shorter than the width) into an existing partition by string order, and
  -- once it is max(control) a raising _decode made every obtain tick a skip_obtain: the forward grid
  -- stopped growing and every write past the lookahead was refused, the stall #325 exists to prevent. The
  -- frontier falls back to now(), the same greatest() below with nothing from the data, the way
  -- check_text_time reports an undecodable maximum as null rather than raising.
  if cfg.control_kind = 'text_time'
     and not pgpm._text_time_shaped(v_max, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix,
                                    cfg.text_time_alphabet) then
    return pgpm._ts_text(now());
  end if;
  v_decoded := pgpm._decode(cfg.control_kind, v_max,
                             cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch);
  -- #325: uuidv7 (and text_time, the same shape of thing) is a TIME grid fed by DATA. Left as plain
  -- max(control), a table whose writes go quiet (a restored dump, a stale clone, a drought) has a
  -- frontier stuck wherever the data ended while now() keeps moving -- obtain measures itself against
  -- its own past output and finds nothing to do, so the grid stalls exactly where the drought began and
  -- every write past it is refused, permanently and silently. greatest() with now() makes both kinds
  -- self-healing the same way `time` already is: the grid can never fall further behind the clock than
  -- one maintenance tick, drought or not. `id` is untouched below -- it has no clock, so its frontier
  -- can only be where the data actually put it.
  if cfg.control_kind in ('uuidv7', 'text_time') then
    return pgpm._ts_text(greatest(v_decoded::timestamptz, now()));
  end if;
  return v_decoded;
end;
$$;

-- ============================== engine ==============================

-- ANALYZE a freshly minted + bulk-loaded table so the planner has real row stats before anything relies
-- on it. A CREATE TABLE LIKE'd child that has just been INSERT'd into still shows reltuples = -1 (unknown)
-- until autovacuum catches up, so any plan that touches it in the interim -- a later regrain batch,
-- the swap/attach, or a user query right after -- misplans against a phantom-empty table. That is exactly
-- the seqscan that made the from_hypertable cutover reconcile O(rows) (#164/#166). ANALYZE is sampled, so
-- its cost is bounded by default_statistics_target, not the table size; call it everywhere a table is
-- minted-then-populated, and (where possible) on the still-private child before any exclusive lock.
create or replace function pgpm._analyze(p_rel regclass)
returns void language plpgsql as $$
begin
  execute format('analyze %s', p_rel::text);
end;
$$;

-- Give a freshly minted child the PARENT's owner (#277). A table belongs to whoever created it, and
-- anything minted after the conversion is created by whatever role runs maintenance, so without this a
-- table's partitions drift into being owned by the maintenance role while the parent keeps the real owner.
--
-- The no-op guard is not just an optimisation: when maintenance already runs AS the owner the roles match
-- and no DDL is issued at all, so this never needs a privilege the caller lacks. When they differ, the
-- caller necessarily owns the parent already (adding a partition requires it), so the ALTER is permitted.
create or replace function pgpm._own_like_parent(p_parent regclass, p_child regclass)
returns void language plpgsql as $$
declare v_owner name;
begin
  select pg_get_userbyid(relowner) into v_owner from pg_class where oid = p_parent;
  if v_owner is distinct from (select pg_get_userbyid(relowner) from pg_class where oid = p_child) then
    execute format('alter table %s owner to %I', p_child::text, v_owner);
  end if;
end;
$$;

-- Give a freshly minted partition the PARENT's replica identity (#782). PostgreSQL neither recurses ALTER
-- TABLE ... REPLICA IDENTITY on a partitioned table to its partitions nor gives a new partition its
-- parent's, and a published partition is what UPDATE and DELETE check: a keyless FULL table's partitions
-- were left with none, so every UPDATE and DELETE routed to one failed with 55000, and a keyed FULL (or
-- NOTHING) table's published the key instead. The parent is the source of truth, as it is for the owner
-- above: transmute's cutover gives it the original table's identity, and every child minted afterwards
-- takes the parent's as it is at that moment. USING INDEX names an index, so the child's is its own index
-- attached under the parent's identity index, found by identity in pg_inherits. A child that already
-- matches gets no DDL, so the default identity costs nothing. The child is freshly created or just
-- attached by the caller, which holds ACCESS EXCLUSIVE on it already: this takes no new lock.
create or replace function pgpm._replica_identity_like_parent(p_parent regclass, p_child regclass)
returns void language plpgsql as $$
declare v_want "char"; v_have "char"; v_idx name;
begin
  select relreplident into v_want from pg_class where oid = p_parent;
  select relreplident into v_have from pg_class where oid = p_child;
  if v_want = 'i' then
    select ci.relname into v_idx
      from pg_index pi
      join pg_inherits h on h.inhparent = pi.indexrelid
      join pg_index i on i.indexrelid = h.inhrelid and i.indrelid = p_child
      join pg_class ci on ci.oid = i.indexrelid
     where pi.indrelid = p_parent and pi.indisreplident;
    if v_idx is null then
      raise exception 'pg_partition_magician: cannot give % the replica identity of %: the parent''s identity is USING INDEX, and % has no index attached under it',
        p_child, p_parent, p_child;
    end if;
    if v_have = 'i' and exists (select 1 from pg_index i join pg_class ci on ci.oid = i.indexrelid
                                 where i.indrelid = p_child and i.indisreplident and ci.relname = v_idx) then
      return;
    end if;
    execute format('alter table %s replica identity using index %I', p_child::text, v_idx);
  elsif v_want is distinct from v_have then
    execute format('alter table %s replica identity %s', p_child::text,
                   case v_want when 'f' then 'full' when 'n' then 'nothing' else 'default' end);
  end if;
end;
$$;

-- Create an EMPTY partition for native [p_lo, p_hi).
--
-- One statement. With the DEFAULT gone (#288) there is nothing to prove empty, so the whole
-- NOT VALID/VALIDATE exclusion dance is gone with it, along with the phase commits, the fixed
-- pgpm_obtain_excl name and the restart-on-leftover logic that #280 needed. CREATE TABLE ... PARTITION OF
-- against a parent with no default partition is pure catalog work: it takes a brief ACCESS EXCLUSIVE on
-- the parent and scans nothing.
create or replace function pgpm._create_partition(
  p_cfg pgpm.config, p_nsp name, p_rel name, p_default regclass, p_name name, p_lo text, p_hi text
)
returns void language plpgsql as $$
declare v_lo_lit text; v_hi_lit text;
begin
  v_lo_lit := pgpm._encode(p_cfg.control_kind, p_lo,
                            p_cfg.text_time_prefix, p_cfg.text_time_width, p_cfg.text_time_radix, p_cfg.text_time_unit, p_cfg.text_time_alphabet, p_cfg.text_time_discard_bits, p_cfg.text_time_epoch, p_cfg.partition_tz);
  v_hi_lit := pgpm._encode(p_cfg.control_kind, p_hi,
                            p_cfg.text_time_prefix, p_cfg.text_time_width, p_cfg.text_time_radix, p_cfg.text_time_unit, p_cfg.text_time_alphabet, p_cfg.text_time_discard_bits, p_cfg.text_time_epoch, p_cfg.partition_tz);
  execute format('create table %I.%I partition of %I.%I for values from (%L) to (%L)',
                 p_nsp, p_name, p_nsp, p_rel, v_lo_lit, v_hi_lit);
  perform pgpm._own_like_parent(format('%I.%I', p_nsp, p_rel)::regclass,
                                format('%I.%I', p_nsp, p_name)::regclass);
  perform pgpm._replica_identity_like_parent(format('%I.%I', p_nsp, p_rel)::regclass,
                                             format('%I.%I', p_nsp, p_name)::regclass);   -- #782
  -- child_oid: WHICH relation this row is about (#421), recorded in the same statement that first
  -- names it, resolved from the CREATE TABLE two lines up rather than trusted from anywhere else.
  insert into pgpm.part (parent_table, child_name, lo, hi, child_oid)
    values (format('%I.%I', p_nsp, p_rel)::regclass, p_name, p_lo, p_hi,
            format('%I.%I', p_nsp, p_name)::regclass::oid) on conflict do nothing;
  insert into pgpm.log (parent_table, action, lo, hi, method)
    values (format('%I.%I', p_nsp, p_rel)::regclass, 'obtain', p_lo, p_hi, 'plain');
end;
$$;

-- #280: obtain became a PROCEDURE because _create_partition commits. Drop the old function first.
-- #288: obtain is a plain FUNCTION again. It became a procedure for #280 only so _create_partition could
-- commit between the phases of its exclusion-constraint dance; with the DEFAULT gone there is no dance,
-- nothing to prove empty, and nothing to recover from. The advisory lock, the stranded-constraint sweep
-- and the deferral reporting all went with it.
drop procedure if exists pgpm.obtain(regclass, int, boolean);

-- obtain(): build the empty forward partitions ahead of the frontier.
--
-- This is now pgpm's ONLY defence against a write with nowhere to go, since there is no DEFAULT to catch
-- one. config.obtain x partition_step is therefore both the slack for maintenance falling behind and a
-- hard ceiling on how far ahead an application may write. The default is 30 steps for that reason.
--
-- The lock budget (#786), extend_to's (#591) applied to the creation loop. obtain is a function too, so
-- every partition one call creates holds its locks (the table, its indexes, its TOAST table) to the
-- transaction's end, and set_obtain bounds only the sign of the lookahead: a lookahead past ~2000 missing
-- cells on a stock server died with 53200 `out of shared memory` on every tick, rolled back every cell it
-- had built, and the grid never advanced. The same measurement as extend_to's: once two partitions exist,
-- the first's cost and the second's (in non-fast-path pg_locks rows, counted from just after the frontier
-- read so its locks on the existing partitions are not charged to them) project what the next one would
-- hold, and the call stops before the next creation would take its partitions past HALF the nominal
-- table, max_locks_per_transaction x (max_connections + max_prepared_transactions). It STOPS rather than
-- refuses, unlike extend_to: the lookahead is opportunistic, so a call returns what fit and the next tick
-- builds on from there, while extend_to's caller named a value it needs covered and a short walk would
-- hide that it was not.
create or replace function pgpm.obtain(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name;
  v_frontier text; v_lo text; v_hi text; v_name name;
  v_coltype text; v_hi_lit text;
  v_made int := 0; k int;
  v_slots bigint := current_setting('max_locks_per_transaction')::bigint
                    * (current_setting('max_connections')::bigint + current_setting('max_prepared_transactions')::bigint);
  v_locks0 bigint; v_locks1 bigint; v_locks2 bigint;
begin
  -- FOR KEY SHARE (#725): held to the end of this transaction, so set_partition_tz (which reads the row
  -- FOR UPDATE before it judges the grid) waits for the cells this call builds to commit, and this read
  -- waits for a zone change in flight and then sees the zone it committed. See pgpm.set_partition_tz.
  select * into cfg from pgpm.config where parent_table = p_parent for key share;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  -- the control column's own type, for the ceiling check below (#578)
  select format_type(a.atttypid, a.atttypmod) into v_coltype
    from pg_attribute a where a.attrelid = p_parent and a.attname = cfg.control_column;

  v_frontier := pgpm._frontier_native(p_parent);
  v_lo       := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier, cfg.partition_tz);
  -- the budget's zero (#786): after the frontier read, so the locks it holds on every existing partition
  -- are not charged to the cells this call builds, and before the walk, so everything the walk itself
  -- takes is (the first partition's cost includes the walk's own reads up to it)
  select count(*) into v_locks0 from pg_locks where pid = pg_backend_pid() and not fastpath;

  for k in 0 .. cfg.obtain loop
    if k > 0 then v_lo := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo, cfg.partition_tz); end if;
    v_hi   := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo, cfg.partition_tz);
    -- The grid can RUN OUT (issue #299). A uuidv7 grid stops at the 48-bit ceiling, and no uuid can
    -- express a bound past it. That is a terminal state, not a failure: EXIT with whatever was built
    -- rather than raising, so a tick keeps working and the lookahead is simply shorter. transmute
    -- refuses up front when the monolith's own bound is unreachable, so a table only gets here by
    -- legitimately advancing toward the ceiling over its lifetime. Deliberately NOT logged: obtain runs
    -- every tick and the condition is permanent, so logging it would bury real failures under identical
    -- rows forever. A write past the grid is already refused loudly by PostgreSQL.
    --
    -- The bound is checked against the CONTROL COLUMN'S TYPE, not just encoded (#578). _encode is a
    -- passthrough for `id`, so it cannot see that an int or smallint column runs out at 2^31-1 or 2^15-1;
    -- left to CREATE TABLE ... PARTITION OF, that out-of-range bound raised and rolled back every
    -- partition this call had built, and every later tick failed the same way (skip_obtain). Casting the
    -- literal is the same coercion the partition bound gets, so it fails exactly when CREATE TABLE would.
    begin
      v_hi_lit := pgpm._encode(cfg.control_kind, v_hi,
                            cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);
      execute format('select %L::%s', v_hi_lit, v_coltype);
    exception when datetime_field_overflow or numeric_value_out_of_range then
      exit;
    end;
    -- skip a candidate that overlaps an EXISTING attached partition (e.g. the coarse monolith that
    -- covers the active interval, REDESIGN.md section 7). Half-open [v_lo,v_hi) overlaps [p.lo,p.hi)
    -- iff p.hi > v_lo and v_hi > p.lo. Creating it would error on an overlapping partition; pgpm.part
    -- is the source of truth, and the non-overlap invariant holds over attached rows only. Asked BEFORE
    -- the name (#572): a taken name does not mean the cell is built, see _obtain_name.
    continue when exists (
      select 1 from pgpm.part p
       where p.parent_table = p_parent and p.attached
         and pgpm._native_gt(cfg.control_kind, p.hi, v_lo)
         and pgpm._native_gt(cfg.control_kind, v_hi, p.lo));
    v_name := pgpm._obtain_name(p_parent, cfg, v_nsp, v_rel, v_lo, v_hi);
    -- a hole in the grid, so it is logged (#710)
    if v_name is null then
      perform pgpm._log_unbuilt_cell(p_parent, cfg, v_nsp, v_rel, v_lo, v_hi);
    end if;
    continue when v_name is null;

    -- the lock budget (#786, see above): what the next partition would leave this call holding, the
    -- first one's cost plus the second one's for every partition after it, past half the table ends the call
    exit when v_made >= 2
              and (v_locks1 - v_locks0) + greatest(v_locks2 - v_locks1, 1) * v_made > v_slots / 2;
    perform pgpm._create_partition(cfg, v_nsp, v_rel, null, v_name, v_lo, v_hi);
    v_made := v_made + 1;
    if v_made = 1 then
      select count(*) into v_locks1 from pg_locks where pid = pg_backend_pid() and not fastpath;
    elsif v_made = 2 then
      select count(*) into v_locks2 from pg_locks where pid = pg_backend_pid() and not fastpath;
    end if;
  end loop;
  return v_made;
end;
$$;

-- extend_to(): pre-extend the forward grid to cover a known future value (issue #290).
--
-- obtain() is pgpm's ONLY defence against a write with nowhere to go, and its lookahead
-- (config.obtain x partition_step) is a hard ceiling since the DEFAULT partition is gone (#288). That
-- ceiling is fine for `time`/`uuidv7`/`text_time` grids, whose frontier is wall-clock driven and advances
-- predictably, but an `id` grid's frontier is DATA-driven and can jump arbitrarily (a sequence restart, a
-- non-dense Snowflake/ULID generator, a bulk import, a backfill) -- and the write that would advance the
-- frontier past the ceiling is the write that fails, permanently, with no recovery path. extend_to is the
-- relief valve: an operator or application names a value it KNOWS is coming, and pgpm builds every
-- missing partition on the existing grid up to and including the range that would hold it. It never moves
-- the frontier or touches data -- it only makes a future write legal.
--
-- p_value is in the CONTROL COLUMN's own representation (a uuid literal, a text_time id, a bigint id, a
-- timestamptz-parseable string) -- decoded the same way pgpm._frontier_native decodes max(control), so a
-- caller passes exactly what it would have inserted. For a timestamp or date column the value is read
-- as wall time in config.partition_tz, which is 'UTC' for such a column (#504): the same rule every
-- other read of that column follows (#455).
--
-- p_max caps how many NEW partitions this call may create. The check runs BEFORE any DDL: a wildly-off
-- p_value (a typo, an off-by-a-few-zeros id) is refused loudly and immediately, creating nothing, rather
-- than silently truncated to p_max partitions short of the requested value -- the house rule about not
-- trading a loud failure for a silent one.
--
-- The lock budget (#591). extend_to is a function, so every partition it creates is created in ONE
-- transaction, and each CREATE TABLE ... PARTITION OF holds its locks (the new table, its indexes, its
-- TOAST table) to that transaction's end, in the lock table every backend shares. p_max alone did not
-- bound that: on a stock server a call a few thousand cells out passed its own dry count and died with
-- 53200 `out of shared memory` after ~2100 partitions, filling the shared table on the way. So once two
-- partitions exist the call measures what one costs, in non-fast-path pg_locks rows (the fast-path slots
-- live in the backend's own PGPROC, not the shared table), projects the rest of the walk, and refuses when
-- the call's partitions would hold more than HALF the nominal table, max_locks_per_transaction x
-- (max_connections + max_prepared_transactions), leaving the other half to every other session. Measured
-- rather than estimated from the catalog, because the cost depends on the table (~8 slots a partition for
-- a primary key and a TOASTable column, one more per index). Counted from the first CREATE, not from the
-- call's start: the frontier read above locks every existing partition of the parent, and a table that
-- simply has many partitions must still be extendable by a few. The refusal raises, so the two partitions
-- that paid for the measurement roll back with the rest: a refused call creates nothing, as p_max's does.
create or replace function pgpm.extend_to(p_parent regclass, p_value text, p_max int default 10000)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name;
  v_native text; v_target_lo text;
  v_frontier text; v_lo text; v_hi text; v_name name;
  v_needed int := 0; v_made int := 0; v_walked int := 0;
  v_slots bigint := current_setting('max_locks_per_transaction')::bigint
                    * (current_setting('max_connections')::bigint + current_setting('max_prepared_transactions')::bigint);
  v_locks0 bigint; v_locks1 bigint; v_locks2 bigint; v_projected bigint;
begin
  -- FOR KEY SHARE (#725), for the reason obtain() takes it: the zone this walk is computed in cannot
  -- change under it, and set_partition_tz cannot judge the grid around the cells it has not committed.
  select * into cfg from pgpm.config where parent_table = p_parent for key share;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  v_native := pgpm._col_to_native(cfg, p_value);
  v_target_lo := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_native, cfg.partition_tz);

  v_frontier := pgpm._frontier_native(p_parent);
  v_lo       := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier, cfg.partition_tz);

  -- count-only dry run: how many grid steps stand between the current forward edge and the target.
  -- Deliberately ignorant of which of those already exist (a conservative, cheap upper bound) -- the
  -- point is refusing BEFORE touching the catalog, not computing the tightest possible cap.
  while pgpm._native_gt(cfg.control_kind, v_target_lo, v_lo) loop
    v_lo := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo, cfg.partition_tz);
    v_needed := v_needed + 1;
    exit when v_needed > p_max;
  end loop;
  if v_needed > p_max then
    raise exception 'pg_partition_magician: extend_to(%, %) would need more than % new partitions to reach it; refusing rather than partially extending (raise p_max, or check p_value for a typo)',
      p_parent, p_value, p_max;
  end if;

  v_lo := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier, cfg.partition_tz);
  loop
    v_hi := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo, cfg.partition_tz);
    -- the grid can run out (#299): a uuidv7 grid stops at the 48-bit ceiling. obtain() exits quietly
    -- there because its lookahead is opportunistic, but here the caller named a specific value it needs
    -- covered, so silence would hide a real failure -- raise instead.
    begin
      perform pgpm._encode(cfg.control_kind, v_hi,
                            cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);
    exception when datetime_field_overflow or numeric_value_out_of_range then
      raise exception 'pg_partition_magician: extend_to(%, %) reaches the % grid''s ceiling before covering it; cannot extend that far',
        p_parent, p_value, cfg.control_kind;
    end;
    -- overlap first, then the name (#572, see _obtain_name), exactly as obtain asks
    if not exists (
         select 1 from pgpm.part p
          where p.parent_table = p_parent and p.attached
            and pgpm._native_gt(cfg.control_kind, p.hi, v_lo)
            and pgpm._native_gt(cfg.control_kind, v_hi, p.lo))
    then
      v_name := pgpm._obtain_name(p_parent, cfg, v_nsp, v_rel, v_lo, v_hi);
      -- a hole in the grid, so it is logged (#710), as obtain does
      if v_name is null then
        perform pgpm._log_unbuilt_cell(p_parent, cfg, v_nsp, v_rel, v_lo, v_hi);
      end if;
      if v_name is not null then
        if v_made = 0 then
          select count(*) into v_locks0 from pg_locks where pid = pg_backend_pid() and not fastpath;
        end if;
        perform pgpm._create_partition(cfg, v_nsp, v_rel, null, v_name, v_lo, v_hi);
        v_made := v_made + 1;
        if v_made = 1 then
          select count(*) into v_locks1 from pg_locks where pid = pg_backend_pid() and not fastpath;
        elsif v_made = 2 then
          select count(*) into v_locks2 from pg_locks where pid = pg_backend_pid() and not fastpath;
          -- the rest of the walk is at most v_needed + 1 cells (the dry count's steps plus the edge's own
          -- cell) less the ones walked so far, each costing what the second partition did
          v_projected := (v_locks2 - v_locks0)
                         + greatest(v_locks2 - v_locks1, 1) * greatest(v_needed + 1 - (v_walked + 1), 0);
          if v_projected > v_slots / 2 then
            raise exception 'pg_partition_magician: extend_to(%, %) would hold about % lock-table slots in its one transaction (about % per partition), more than half the shared lock table''s % (max_locks_per_transaction % x (max_connections % + max_prepared_transactions %)); refusing rather than exhausting it for every other session. Extend in steps, each call in its own transaction, of at most about % partitions, or raise max_locks_per_transaction',
              p_parent, p_value, v_projected, greatest(v_locks2 - v_locks1, 1), v_slots,
              current_setting('max_locks_per_transaction'), current_setting('max_connections'),
              current_setting('max_prepared_transactions'),
              greatest((v_slots / 2 - (v_locks1 - v_locks0)) / greatest(v_locks2 - v_locks1, 1) + 1, 1);
          end if;
        end if;
      end if;
    end if;
    v_walked := v_walked + 1;
    exit when not pgpm._native_gt(cfg.control_kind, v_target_lo, v_lo);
    v_lo := v_hi;
  end loop;

  return v_made;
end;
$$;

-- drain_step / drain_all removed with the DEFAULT partition (#288). With a complete forward grid there
-- is nothing for a row to land in except a real partition, so there is nothing to evacuate.

-- #288: both drain routines are gone; drop whichever form a prior version left behind.
drop function  if exists pgpm.drain_all(regclass, int, boolean);
drop procedure if exists pgpm.drain_all(regclass, int, boolean, int);
drop function  if exists pgpm.drain_step(regclass, int, boolean);



-- the retention horizon on the native grid: the grid-floored boundary at/below which a partition's
-- whole range has aged out. null = no retention policy. Shared by retain() (what to drop now) and
-- status() (retain_backlog: what is eligible but not yet dropped).
create or replace function pgpm._retain_boundary(cfg pgpm.config)
returns text language plpgsql as $$
begin
  if cfg.retain is null then return null; end if;
  -- #451: defence in depth for a config.retain that never went through transmute or set_retain (a hand
  -- edit; both refuse this up front). A negative value puts the horizon past the partition taking writes,
  -- which makes every attached partition drop-eligible at once, and "everything is aged" is never a valid
  -- state for a live table, so no horizon is produced at all. (Zero is fine: its horizon is the write
  -- partition's own floor, which keeps that partition and ages the rest.) Inside a maintenance tick this
  -- surfaces as skip_write_block and skip_retain rows carrying this message, and the table keeps every
  -- partition it has; status() catches it and reports retain_backlog as null for the table; set_retain
  -- compares the old value as null so the repair is not blocked by the thing it repairs.
  if not pgpm._retain_nonnegative(cfg.control_kind, cfg.retain) then
    raise exception 'pg_partition_magician: config.retain % on % is negative -- refusing to compute a retention horizon past the partition taking writes, which would make every partition drop-eligible, that one included; repair it with pgpm.set_retain', cfg.retain, cfg.parent_table;
  end if;
  if cfg.control_kind = 'id' then
    return pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                            (pgpm._frontier_native(cfg.parent_table)::numeric - cfg.retain::numeric)::text,
                            cfg.partition_tz);
  else
    -- a calendar step back from now, taken on the wall clock in partition_tz (#455): on a timestamptz,
    -- `- interval '1 month'` or `- '1 day'` is calendar arithmetic in the SESSION's zone, so two sessions
    -- could put the horizon on different sides of a grid boundary
    return pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                            pgpm._ts_text(((now() at time zone cfg.partition_tz) - cfg.retain::interval) at time zone cfg.partition_tz),
                            cfg.partition_tz);
  end if;
end;
$$;

-- ==================== retiring a REFERENCED partition (issue #268) ====================
--
-- `p_incoming_fks => 'preserve'` and a `retain` policy were both supported and both documented, and
-- the combination never reclaimed anything: every retain() failed on the oldest eligible partition and
-- returned 0, forever, while the write block was already installed. Frozen AND unreclaimable.
--
-- `DROP TABLE <partition>` is refused on a pure CATALOG dependency. An FK against a partitioned parent
-- puts one pg_constraint row per referenced partition ON the referencing table, and the refusal is
-- data-INDEPENDENT: identical whether one row references, zero rows reference, or the referencing
-- table is empty. DETACH is the only phase that consults data, and a successful one severs the
-- per-partition constraint, after which the DROP is completely unguarded. So: detach, then drop. The
-- referencing table's own FK survives and still enforces.
--
-- The detach must be CONCURRENT. Measured on PG 17.10, 8M-row referencing table:
--
--   ALTER TABLE ... DETACH PARTITION               AccessExclusiveLock on the MANAGED PARENT, ~1.5 s;
--                                                  a concurrent read of the parent dies with 55P03
--   ALTER TABLE ... DETACH PARTITION CONCURRENTLY  ShareUpdateExclusiveLock; the parent stays readable
--                                                  and writable throughout
--
-- Plain DETACH would make retention block the table pgpm exists to keep online, for a duration set by
-- the size of a table pgpm does not own. That is exactly the shape the project's acceptance rule
-- forbids. And PostgreSQL refuses to run the concurrent form from any of the contexts pgpm has:
--
--   ERROR:  ALTER TABLE ... DETACH CONCURRENTLY cannot be executed from a function
--
-- not from a procedure that has already committed, not from a DO block, and not via dynamic EXECUTE:
-- it is a check on execution CONTEXT, and pgpm is pure SQL. So pgpm DISPATCHES it. pg_cron is already
-- pgpm's one runtime dependency, and a cron job's command runs as a top-level statement in its own
-- session, where the statement is legal. retire() repoints a single standing job at the specific
-- detach and completes the DROP on a later tick.
--
-- ONE STANDING JOB, rewritten in place, not one job per retirement: pg_cron has no one-shot schedule,
-- so a per-retirement job would keep firing after it succeeded and log `is not a partition` failures
-- until something unscheduled it. pgpm.schedule() creates `pgpm_detach` idle (`select 1`); retire()
-- points it at a detach when it needs one and returns it to idle once the drop lands. At most one
-- detach is in flight, which retention's existing retain_batch pacing already assumes.
--
-- What this costs, stated plainly: retirement of a REFERENCED partition is asynchronous, spanning at
-- least one cron tick, and it requires pgpm.schedule() to have been run. Retention was already
-- eventual, so this lengthens a delay rather than introducing one. Writes to the REFERENCING table are
-- blocked for O(that table) by the detach's ShareLock, once per retirement -- readers of it, and the
-- managed parent entirely, are unaffected. That part is irreducible: it is PostgreSQL proving the FK
-- still holds. An index on the referencing FK column does NOT reduce it (measured: 1368 ms without,
-- 1634 ms with).
--
-- And what it costs in IDENTITY, which is the other half of the bill (issue #407). Dispatching means
-- the statement leaves this process as TEXT and is re-resolved BY NAME, later, somewhere else, with
-- no lock held on the child in between -- the time-of-check/time-of-use shape the #346 audit went
-- looking for. pgpm cannot close that window: the reason the statement is dispatched at all is that
-- PostgreSQL will not let pgpm hold anything while it runs. So the retirement is anchored to the
-- child's OID instead (pgpm.part.retiring_oid), and the two steps that remain pgpm's -- re-dispatching
-- on a later tick, and the DROP that follows a successful detach -- refuse to act unless the name
-- still resolves to it. The detach itself can still land on a substitute; the DROP, which is the
-- irreversible half, cannot.

-- _crossing_keys: the control-column values inside [p_lo, p_hi) that some incoming foreign key still
-- references -- the rows where the operator's two promises, the FK and the retention horizon,
-- genuinely contradict.
--
-- Identification runs FIRST and unconditionally, rather than attempting the detach and catching its
-- error, because a FAILING detach is only cheap when the referencing FK column happens to be indexed.
-- Measured, 8M-row referencing table: identifying costs 0.7 ms indexed and 141.9 ms unindexed, against
-- a failing DETACH's 1.9 ms indexed but 1176 ms unindexed -- a near-full scan under ShareLock paid
-- purely to discover the operation cannot proceed, with the locks already taken. Pre-identifying also
-- reports every crossing key at once, where PostgreSQL names one at a time.
create or replace function pgpm._crossing_keys(p_parent regclass, p_lo text, p_hi text)
returns text[] language plpgsql as $$
declare
  cfg pgpm.config; r record;
  v_ctrl_attnum smallint; v_refcol name; v_pos int;
  v_lo_lit text; v_hi_lit text; v_vals text[] := '{}'; v_more text[];
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;

  select a.attnum into v_ctrl_attnum from pg_attribute a
   where a.attrelid = p_parent and a.attname = cfg.control_column and not a.attisdropped;

  v_lo_lit := pgpm._encode(cfg.control_kind, p_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);
  v_hi_lit := pgpm._encode(cfg.control_kind, p_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);

  -- conparentid = 0 picks the top-level constraint. An FK referencing a PARTITIONED table also gets
  -- one pg_constraint row per partition of the referenced side, so an unfiltered scan would visit the
  -- same foreign key once per partition.
  for r in
    select c.conname, c.conrelid::regclass as referencing, c.conkey, c.confkey
      from pg_constraint c
     where c.confrelid = p_parent and c.contype = 'f' and c.conparentid = 0
  loop
    -- Which referencing column maps to the CONTROL column? A foreign key can only reference a unique
    -- constraint, and every unique constraint on a partitioned table must include the partition key,
    -- so this position always exists in pgpm's shape. Say so loudly if it ever does not, rather than
    -- silently reporting no crossing and going on to a detach that will refuse.
    v_pos := array_position(r.confkey, v_ctrl_attnum);
    if v_pos is null then
      raise exception 'pg_partition_magician: foreign key % on % references % without its control column %, so pgpm cannot tell which rows cross the retention horizon',
        r.conname, r.referencing, p_parent, cfg.control_column;
    end if;
    select a.attname into v_refcol from pg_attribute a
     where a.attrelid = r.referencing and a.attnum = (r.conkey)[v_pos];

    -- A plain range predicate: a row whose key falls in [lo, hi) references a row in THIS partition,
    -- by the definition of range partitioning, whatever else the key carries.
    execute format(
      'select coalesce(array_agg(distinct %I::text), ''{}''::text[]) from %s where %I >= %L and %I < %L',
      v_refcol, r.referencing::text, v_refcol, v_lo_lit, v_refcol, v_hi_lit)
      into v_more;
    v_vals := v_vals || v_more;
  end loop;
  return v_vals;
end;
$$;

-- #407 changed p_child from `name` to `regclass`, and gave _idle_detach_job a parameter.
-- `create or replace` cannot change either, so the old signatures would otherwise stay installed
-- beside the new ones on an upgrade -- and a zero-argument call would then be AMBIGUOUS against a
-- one-argument version with a default, which is why _idle_detach_job's parameter has none.
drop function if exists pgpm._dispatch_detach(regclass, name);
drop function if exists pgpm._idle_detach_job();

-- The one place the dispatched command's text is built. Both _dispatch_detach (which arms the job)
-- and retire() (which disarms it, and has to recognise its own command to do that safely) go through
-- here, so the two cannot drift into disagreeing about what was armed.
--
-- Returns null for a p_parent with no pg_class row, which _idle_detach_job reads as "disarm
-- unconditionally" -- degrading to exactly the pre-#407 behaviour, not to something worse. retire()
-- cannot reach it that way regardless: it resolves the parent's schema, and reads the frontier off
-- the relation, well before either call site.
create or replace function pgpm._detach_cmd(p_parent regclass, p_child_nsp name, p_child_rel name)
returns text language sql stable as $$
  select format('alter table %I.%I detach partition %I.%I concurrently',
                n.nspname, c.relname, p_child_nsp, p_child_rel)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
$$;

-- _dispatch_detach: point the standing `pgpm_detach` job at this partition's concurrent detach.
-- Returns null on success, or the REASON it could not dispatch -- pg_cron not installed, pgpm.schedule()
-- never run, no privilege on cron.job. All three are configuration problems the operator has to see and
-- fix, so the reason is carried back verbatim to be logged rather than flattened into a bare false.
--
-- Dynamic EXECUTE because the `cron` schema is only resolved at call time, so this file still installs
-- cleanly where pg_cron is not enabled. Both relations are schema-qualified in the command: the cron
-- job runs in its own session, with its own search_path.
--
-- BOTH RELATIONS ARE PASSED AS OIDS AND RENDERED FROM THEM (issue #407), so the text that lands on
-- cron.job can only ever name relations the caller actually resolved in its own transaction. That is
-- the most this function can do about the gap it opens: the command it writes is picked up by pg_cron
-- a tick or more later, in another session, and re-resolved BY NAME there, with no lock held on
-- either relation across the interval and no way for a command text to carry an OID. The rest of the
-- defence is pgpm.part.retiring_oid, which lets retire() DETECT at its next two decision points that
-- the name no longer means what it meant here. See the column's comment.
create or replace function pgpm._dispatch_detach(p_parent regclass, p_child regclass)
returns text language plpgsql as $$
declare v_cnsp name; v_crel name; v_cmd_q text; v_n int;
begin
  select n.nspname, c.relname into v_cnsp, v_crel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_child;
  v_cmd_q := pgpm._detach_cmd(p_parent, v_cnsp, v_crel);
  begin
    execute format(
      'select count(*)::int from (select cron.alter_job(jobid, command => %L) from cron.job'
      || ' where jobname = ''pgpm_detach'' and database = current_database()) s', v_cmd_q)
      into v_n;
  exception when others then
    return left(sqlerrm, 160);
  end;
  if v_n > 0 then return null; end if;
  return 'no pgpm_detach cron job in this database; run pgpm.schedule()';
end;
$$;

-- the reverse: put the standing job back to idle once a retirement completes, so it is not left
-- re-running a detach that has already happened (which logs `is not a partition` every tick).
--
-- p_cmd null disarms whatever is there. Pass a command instead to disarm ONLY IF THAT IS STILL WHAT
-- IS ARMED (issue #407). At most one detach is in flight, so the caller completing a retirement is
-- normally the owner of the armed command and null is right; but a retirement WEDGED on an identity
-- mismatch revisits this on every tick forever, and an unconditional disarm there would clobber some
-- other parent's freshly-dispatched detach every tick for as long as the wedge lasts. Build p_cmd
-- through pgpm._detach_cmd, the same function that armed it. A mismatch skips the disarm, which is
-- the safe direction: the next successful dispatch overwrites the command anyway.
create or replace function pgpm._idle_detach_job(p_cmd text)
returns void language plpgsql as $$
begin
  if p_cmd is null then
    execute 'select cron.alter_job(jobid, command => ''select 1'') from cron.job'
         || ' where jobname = ''pgpm_detach'' and database = current_database()';
  else
    execute 'select cron.alter_job(jobid, command => ''select 1'') from cron.job'
         || ' where jobname = ''pgpm_detach'' and database = current_database() and command = $1'
      using p_cmd;
  end if;
exception when others then
  null;   -- no pg_cron, or no such job: there is nothing to quiesce
end;
$$;

-- WHICH SCHEMA A PARTITION LIVES IN (issue #727): its own, read off the relation pgpm recorded. A
-- partition's schema is not its parent's. ALTER TABLE <parent> SET SCHEMA moves the parent and leaves every
-- partition where it was, and pgpm tracks the parent by oid, so the table stays managed. The lifecycle
-- steps (the write block, the archive step, retire) used to resolve a partition as <the parent's CURRENT
-- schema>.<child_name>, so after such a move none of them found an existing partition again: the write
-- block was skipped as "does not exist", the archive step and retire() refused every aged partition as an
-- identity mismatch ("oid nothing now"), and retention was wedged for good with every partition still
-- attached under the oid pgpm recorded. Each of those steps takes its schema from here instead.
--
-- Only the SCHEMA comes from the anchor, never the relation. Every caller still resolves
-- <schema>.<child_name> by name and, where it acts on what it finds, compares that against
-- pgpm.part.child_oid, so the identity refusals (#421, #428, #429, #518) mean exactly what they did: a
-- partition renamed aside keeps its schema, the name resolves there to whatever took it, and the step
-- refuses. In order, when the anchor has nothing to say:
--   child_oid           the schema of the relation pgpm recorded for this row (#421), wherever it is now.
--   pg_inherits         an unanchored row (child_oid null: an install older than #421, or a backfill that
--                       could not resolve it) takes the schema of the partition OF THIS PARENT that carries
--                       the name, so a moved parent's legacy rows are reached too.
--   the parent          a row whose relation is gone takes the parent's schema, the answer every step gave
--                       before this, so a vanished partition is reported as the identity failure it is.
create or replace function pgpm._child_nsp(p_parent regclass, p_child name)
returns name language sql stable as $$
  select coalesce(
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
$$;

-- retire(): the sanctioned single-partition drop (issue #195) -- retain()'s per-partition body,
-- public and claim-guarded, so an external assistant (e.g. an archive-then-drop scanner) or several
-- cooperating ones can drive retirement themselves through the same protocol retain() uses: claim,
-- ensure write-blocked, gate on archive coverage, DROP, catalog + log. It never widens what
-- retention may drop: the child's whole range must sit at/below the retention horizon, so a caller
-- only picks WHICH eligible partition and WHEN. Returns true iff this call dropped the partition.
--
-- Drop precondition, as of issue #238: past the retention horizon (as before), write-blocked, and
-- pgpm._archive_fully_covered. Write-blocking is ENSURED here (pgpm._install_write_block is
-- idempotent), not merely asserted: retire() is called by more than one path -- retain()'s own loop,
-- an external assistant, pgpm_archive's self-driving sweep -- and only maintain() is guaranteed to
-- have run _enforce_write_blocks first. Asserting (raising) instead would make retire() fail for
-- every caller that reaches an eligible partition some other way, which defeats the entire point of
-- retire() being independently callable. Archive coverage is different: a child mid-chunked-archive
-- is a normal, expected, RETRYABLE state, not a failure -- retire() just returns false, the same way
-- it already does for a concurrently-claimed partition, so retain()'s batch loop skips it this cycle
-- without logging anything.
--
-- The pgpm.hook pre_drop registry this used to consult (hooks ran in registration order
-- immediately before the DROP) is gone entirely as of issue #240 -- archive coverage via
-- config.archive_fn is the only gate a drop precondition has now.
--
-- Returns false, without side effects, when the pgpm.part row is absent (already retired by another
-- actor) or claimed by a concurrent transaction: FOR UPDATE SKIP LOCKED (issue #188) gives each
-- partition exactly one owner at a time. The claim is taken OUTSIDE the DROP's own subtransaction,
-- so an unexpected drop failure (retain_drop_fail, logged, retried on a later call) keeps the row
-- claimed until the caller's transaction ends.
--
-- IDENTITY ACROSS THE DISPATCH GAP (issue #407). A referenced partition's retirement spans sessions:
-- this function dispatches a detach as command TEXT, pg_cron runs it a tick or more later, and a
-- later call of this function completes the DROP. p_child is a name for the whole of that, so every
-- step after the first re-resolves it, and the object it lands on is only the object pgpm meant if
-- nothing took the name in between. pgpm.part.retiring_oid records which object that was, and the
-- check below -- once, before the first side effect of a call, so it covers re-dispatch and DROP
-- alike -- refuses to go on when the name has stopped resolving to it.
create or replace function pgpm.retire(p_parent regclass, p_child name)
returns boolean language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_boundary text; r record;
  v_referenced boolean; v_child regclass; v_now regclass; v_why text;
  v_cross text[]; v_coltype text; v_lo_lit text; v_hi_lit text; v_deleted int; v_reason text;
  v_chunks bigint;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.retain is null then
    raise exception 'pg_partition_magician: % has no retention policy (config.retain is null); retire() drops only what retention allows', p_parent;
  end if;

  -- the claim: one owner per partition at a time
  select p.lo, p.hi, p.attached, p.retiring_at, p.retiring_oid, p.child_oid into r
    from pgpm.part p
   where p.parent_table = p_parent and p.child_name = p_child
     for update skip locked;
  if not found then return false; end if;
  if not r.attached then
    raise exception 'pg_partition_magician: %.% is not an attached partition (an in-flight regrain child is not retirable)', p_parent, p_child;
  end if;

  v_boundary := pgpm._retain_boundary(cfg);
  if pgpm._native_gt(cfg.control_kind, r.hi, v_boundary) then
    raise exception 'pg_partition_magician: % is not entirely past the retention horizon (hi %, horizon %)', p_child, r.hi, v_boundary;
  end if;

  v_nsp := pgpm._child_nsp(p_parent, p_child);   -- #727: the partition's own schema, not the parent's

  -- IDENTITY, BEFORE ANY SIDE EFFECT (issues #407 and #428). Everything from here down acts on
  -- p_child by NAME -- installing the write block, deleting crossing keys, re-pointing the cron job,
  -- and finally the DROP -- so the name has to be proved to still mean the right relation before the
  -- first of them, not just before the last.
  --
  -- TWO ANCHORS, CHECKED INDEPENDENTLY, because they record different things and each catches a
  -- substitution the other cannot see:
  --
  --   retiring_oid (#407) is which object THIS RETIREMENT dispatched a detach for. It exists because
  --   the detach leaves the session as command TEXT and is re-resolved by pg_cron later, with no
  --   lock held across the gap. It is null for every partition not being retired through a detach --
  --   which is every unreferenced one, i.e. the ordinary one-step DROP path.
  --
  --   child_oid (#421) is which object this pgpm.part ROW has always been about, recorded when the
  --   partition entered the catalog. It is populated for every partition, so it is what covers the
  --   one-step path retiring_oid leaves open (#428) -- the path that ends in a bare `drop table
  --   schema.child` with nothing else between it and the write block.
  --
  -- Coalescing them would be wrong, not merely weaker. retiring_oid is itself resolved BY NAME, out
  -- of pg_inherits at dispatch time, so a substitution that landed BEFORE the dispatch is adopted by
  -- that anchor: comparing the name against it then passes forever, and `coalesce(retiring_oid,
  -- child_oid)` would never reach the one anchor that still remembers the original. Checking both
  -- means a disagreement with EITHER refuses, and the message says which, so an operator is not left
  -- to guess whether they are looking at a stale dispatch or a stale row.
  --
  -- In each case two independent facts have to agree: the name resolves, and it resolves to the
  -- recorded OID. Either alone is forgeable -- a name can be taken by a new relation, and a pg_class
  -- OID can in principle be reused once its original is gone. `is distinct from` so a name that
  -- resolves to nothing at all trips this too. A null anchor is unanchored and is simply not
  -- consulted, which is what keeps an upgrade from wedging a partition it has nothing to compare.
  --
  -- Fails closed and STAYS closed: logged, false, partition untouched, every tick. There is no later
  -- tick on which the name goes back to meaning the right object, so this is a wedge an operator has
  -- to look at, not a deferral -- and status() counts it as one. On the way out the standing job is
  -- disarmed IF it is still holding this retirement's own command, which by now names the
  -- substitute; conditionally, because this branch runs on every tick for as long as the wedge
  -- lasts, and an unconditional disarm would clobber another parent's dispatch just as often. Only
  -- when retiring_oid is set, because that is the only case in which a detach was ever armed -- on
  -- the one-step path there is nothing to disarm and nothing that could be holding the job.
  if r.retiring_oid is not null or r.child_oid is not null then
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

  -- DETACHED BY SOMETHING OTHER THAN RETIREMENT, ON EITHER PATH (issue #652), before any side effect.
  -- pgpm.part.attached says what pgpm did, not what the catalog holds: an operator's own `DETACH
  -- PARTITION` (to keep a table, or to archive it by hand) never touches it. Only a child that pgpm's
  -- own retirement detached carries retiring_at, so a child that is no longer a partition of this parent
  -- and has none is someone else's table now, and it is left alone: no write block, no DROP, logged
  -- every call so status() counts it. This used to be asked only inside the referenced branch below,
  -- so the one-step path, which every table without an incoming FK takes, write-blocked and DROPPED an
  -- operator-detached table with its rows. One rule for both paths, and it is one-directional: a child
  -- detached WITH retiring_at is this retirement's own and goes on to the DROP. By oid, through the
  -- same name resolution the identity check above just vouched for.
  if r.retiring_at is null and not exists (
       select 1 from pg_inherits i
        where i.inhparent = p_parent
          and i.inhrelid = to_regclass(format('%I.%I', v_nsp, p_child))::oid) then
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'fail_retain_drop', r.lo, r.hi,
              'detached from the parent by something other than retirement; not dropping it');
    return false;
  end if;

  -- COVERAGE FOUND WITHOUT ITS BLOCK IS DISCARDED HERE TOO (issue #564), before the block goes on.
  -- _enforce_write_blocks makes the same discard (#452, where the reasoning lives), but only maintain()
  -- is guaranteed to have run it, and a direct caller reaches this point on a child whose trigger may
  -- have left by a path pgpm did not guard: dropped by hand, or lifted by a pgpm older than #452. The
  -- install below would put the block back and _archive_fully_covered would then read the stale
  -- watermark as full coverage, so the partition dropped with a row written while it was unblocked that
  -- no strategy was ever handed. Discarding first makes the gate below read false; archiving starts
  -- over from lo under the restored block, and a later call drops it once that coverage is complete.
  -- Same order as _enforce_write_blocks and for the same reason: the ledger first, then the trigger, so
  -- coverage found alongside a missing trigger was recorded before the trigger left. The identity check
  -- above already refused a substituted name, so this cannot discard the coverage of a relation that
  -- has merely been renamed aside (#518).
  select count(*) into v_chunks from pgpm.archive_ledger
   where parent_table = p_parent and child_name = p_child;
  if v_chunks > 0 and not pgpm._is_write_blocked(p_parent, p_child) then
    delete from pgpm.archive_ledger where parent_table = p_parent and child_name = p_child;
    insert into pgpm.log (parent_table, action, lo, hi, rows, method)
      values (p_parent, 'archive_coverage_reset', r.lo, r.hi, v_chunks,
              format('%s archived chunk(s) were recorded for %I.%I under a write block that was no longer on it, or no longer enabled ALWAYS, when retire() reached it, so they no longer describe its contents; discarded, and archiving starts over from %s under the block retire() puts back',
                     v_chunks, v_nsp, p_child, r.lo));
  end if;

  perform pgpm._install_write_block(p_parent, p_child);

  if not pgpm._archive_fully_covered(p_parent, p_child) then
    return false;
  end if;

  -- Is anything pointing at this parent at all (issue #268)? With an incoming FK a bare DROP is refused
  -- on the referencing table's per-partition constraint row, whether or not any row references this
  -- child (see the section header above; the operator docs state only the consequence). Without one
  -- the bare DROP below works and costs nothing, so the overwhelmingly common path stays
  -- byte-identical: no marker, no cron round trip, no waiting a tick. Gating here also confines the
  -- concurrent detach, and the reaper hazard that comes with it, to the tables that actually need them.
  v_referenced := exists (select 1 from pg_constraint
                           where confrelid = p_parent and contype = 'f' and conparentid = 0);

  if v_referenced then
    -- Resolved to an OID, not merely counted (#407). This is both the "is it still attached?" test it
    -- has always been AND the value recorded in retiring_oid below, which is what the check at the top
    -- of every later call compares against -- so the identity being retired is pinned once, here,
    -- read out of pg_inherits and therefore a partition OF THIS PARENT by construction.
    select i.inhrelid into v_child
      from pg_inherits i join pg_class c on c.oid = i.inhrelid
     where i.inhparent = p_parent and c.relname = p_child;

    if v_child is not null then
      -- ONE DETACH IN FLIGHT AT A TIME, database-wide. There is a single standing cron job, so a
      -- second dispatch would overwrite the first and silently abandon it -- leaving a partition
      -- marked retiring_at that nothing is detaching. retain()'s batch loop walks every eligible
      -- partition, and maintain_all walks every managed parent, so this is the common case, not an
      -- exotic race: without this guard one retain() call marks the whole backlog and only the last
      -- one is real. A retirement stops holding the job the moment its partition is detached, so this
      -- yields rather than blocks: the next tick takes the next partition. Silent and retryable, like
      -- the archive-coverage gate above.
      -- Yield only to a STRICTLY OLDER in-flight retirement, on a total order. "Yield to any other" is
      -- the obvious formulation and it deadlocks: two concurrent retire() calls can both pass the check
      -- and both mark, after which each sees the other in flight and neither ever proceeds again. With a
      -- total order the oldest marker always wins, so there is always exactly one partition able to make
      -- progress and the loser simply retries. An unmarked candidate sorts last (`infinity`), so a fresh
      -- retirement always yields to one already under way.
      if exists (
        select 1 from pgpm.part p
         where p.retiring_at is not null
           and not (p.parent_table = p_parent and p.child_name = p_child)
           and (p.retiring_at, p.parent_table::text, p.child_name)
             < (coalesce(r.retiring_at, 'infinity'::timestamptz), p_parent::text, p_child)
           and exists (select 1 from pg_inherits i join pg_class c on c.oid = i.inhrelid
                        where i.inhparent = p.parent_table and c.relname = p.child_name))
      then
        return false;
      end if;

      -- THE CROSSING. A live row genuinely referencing a doomed row is the one case where retention
      -- and referential integrity contradict, and pgpm has NO policy decision to make here: the
      -- operator already chose, per constraint, in the FK's ON DELETE clause. DELETE lets PostgreSQL
      -- apply whatever was declared, with no branching -- CASCADE clears the referencing rows, SET
      -- NULL and SET DEFAULT sever them in place, NO ACTION and RESTRICT refuse and therefore block
      -- retention exactly as specified, surfacing the operator's own error rather than a pgpm one.
      -- (DETACH cannot be left to do this: it is structural, so no action triggers fire, and it
      -- unilaterally refuses for every constraint -- correct by coincidence for NO ACTION, an override
      -- of an explicit instruction for CASCADE.)
      v_cross := pgpm._crossing_keys(p_parent, r.lo, r.hi);
      if coalesce(array_length(v_cross, 1), 0) > 0 then
        select format_type(a.atttypid, a.atttypmod) into v_coltype
          from pg_attribute a where a.attrelid = p_parent and a.attname = cfg.control_column;
        v_lo_lit := pgpm._encode(cfg.control_kind, r.lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);
        v_hi_lit := pgpm._encode(cfg.control_kind, r.hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);
        begin
          -- The write block installed above is a BEFORE ROW trigger on this child covering DELETE
          -- too, so it would refuse this. Lift it for the delete and put it straight back: DDL is
          -- transactional and retire() does not commit, so no other session ever observes the child
          -- unblocked. Disabling triggers wholesale is NOT an option -- that would switch off the RI
          -- triggers whose actions are the entire point of doing this as a DELETE.
          perform pgpm._remove_write_block(p_parent, p_child);
          execute format(
            'delete from %s where %I >= %L and %I < %L and %I = any (%L::text[]::%s[])',
            p_parent::text, cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit,
            cfg.control_column, v_cross, v_coltype);
          get diagnostics v_deleted = row_count;
          perform pgpm._install_write_block(p_parent, p_child);
          -- Logged loudly and separately: this fires referential actions on tables pgpm was not
          -- handed, which is the one thing retirement does beyond its own partition.
          insert into pgpm.log (parent_table, action, lo, hi, method)
            values (p_parent, 'retain_crossing', r.lo, r.hi,
                    format('%s referenced key(s), %s row(s) deleted to honour the declared ON DELETE',
                           array_length(v_cross, 1), v_deleted));
        exception when others then
          insert into pgpm.log (parent_table, action, lo, hi, method)
            values (p_parent, 'fail_retain_crossing', r.lo, r.hi, left(sqlerrm, 200));
          return false;
        end;
      end if;

      -- Mark, then dispatch, in one transaction: the marker and the job's new command become visible
      -- together, so there is never a detach in flight that recovery cannot attribute.
      -- coalesce, NOT an unconditional stamp: retiring_at is when this retirement BEGAN, and a retry
      -- must not refresh it. Re-stamping makes the winner perpetually the newest marker, so it stops
      -- being the winner, and the total order above degenerates into no order at all -- two partitions
      -- then dispatch in the same tick and one clobbers the other's job.
      -- retiring_oid is coalesced for the same reason and records the same instant: it is the object
      -- the FIRST dispatch chose, and a retry that refreshed it would simply adopt whatever holds the
      -- name now -- which is precisely the substitution the check above exists to catch.
      update pgpm.part set retiring_at = coalesce(retiring_at, clock_timestamp()),
                           retiring_oid = coalesce(retiring_oid, v_child::oid)
       where parent_table = p_parent and child_name = p_child;

      v_reason := pgpm._dispatch_detach(p_parent, v_child);
      if v_reason is null then
        insert into pgpm.log (parent_table, action, lo, hi, method)
          values (p_parent, 'retain_detach', r.lo, r.hi,
                  'concurrent detach dispatched; the drop completes on a later tick');
      else
        insert into pgpm.log (parent_table, action, lo, hi, method)
          values (p_parent, 'fail_retain_detach', r.lo, r.hi,
                  format('%s -- a referenced partition cannot be retired without it', v_reason));
      end if;
      return false;   -- retirement is under way, not done
    end if;

    -- Detached but not yet dropped. Complete it only if this was pgpm's retirement: an operator's own
    -- interrupted DETACH CONCURRENTLY gets finalized by _detach_reap and then left alone, rather than
    -- having pgpm drop a table it was never asked to drop.
    if r.retiring_at is null then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_retain_drop', r.lo, r.hi,
                'detached from the parent by something other than retirement; not dropping it');
      return false;
    end if;

    -- DISARM BEFORE THE DROP, not after it (#407). The standing job still carries this partition's
    -- detach command and fires it every tick until something resets it, so the window in which a
    -- stale name sits armed is not one cron interval: it lasts until the drop SUCCEEDS, and a drop
    -- that keeps failing extends it indefinitely. Out here rather than inside the DROP's own
    -- subtransaction for the same reason -- a rolled-back drop must not roll back the disarming.
    -- Unconditional here, unlike the wedge above: this runs once per retirement rather than on every
    -- tick forever, and the identity check has just proved the name means what it meant, so the
    -- detach that landed was this retirement's and the armed command is its own.
    perform pgpm._idle_detach_job(null);
  end if;

  begin
    -- THE REGRAIN THIS DROP WOULD ORPHAN GOES WITH IT (issue #519). If this partition is the source of
    -- an in-flight regrain, its fine copies, its captured changes and config.regrain_cursor would
    -- outlive it with nothing left to reclaim them: auto-regrain answers 'none' once no coarse child
    -- remains, and the janitor only tears down capture the cursor does not cover. _regrain_reclaim
    -- takes exactly that regrain's state and no other's (see there for why reclaiming beats refusing,
    -- and why it is not regrain_cancel). In the drop's own subtransaction, ahead of the DROP, so a lock
    -- lost on a copy leaves the source whole and this retirement retried next tick, and so the cancel
    -- is recorded before the drop it makes room for.
    perform pgpm._regrain_reclaim(p_parent, p_child, r.lo, r.hi);
    execute format('drop table %I.%I', v_nsp, p_child);
    delete from pgpm.part where parent_table = p_parent and child_name = p_child;
    insert into pgpm.log (parent_table, action, lo, hi) values (p_parent, 'retain_drop', r.lo, r.hi);
    return true;
  exception when others then
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'fail_retain_drop', r.lo, r.hi, left(sqlerrm, 200));
    return false;
  end;
end;
$$;

-- _retain_recall(): take back a retirement retention no longer reaches (issue #724).
--
-- retire() marks a referenced partition (retiring_at) and arms the standing pgpm_detach job with its
-- concurrent detach, and a later retire() call finishes it with a DROP. Retention can stop reaching the
-- partition in between: set_retain loosens it (a longer value, or null), or an id table's frontier, which
-- is max(control), moves back when its newest rows are deleted. retire() is then never called on it again,
-- because retain() walks only what the horizon reaches, so nothing ever looked at the armed command: cron
-- ran it, the partition left the parent with every row the policy now keeps, writes into its range were
-- refused for want of a partition, pgpm.part still said attached and status() counted no failure. The
-- retirement belongs to the policy that started it, so when the policy no longer reaches the partition
-- the retirement is undone, from whichever of its three states it is in:
--
--   ARMED, still attached: the job is returned to idle, conditionally on still holding THIS partition's
--   command (the #407 rule: never clobber another parent's dispatch), logged retain_recall. The marker is
--   KEPT by that call and cleared only by a later one that finds the job no longer armed with it and no
--   detach of it running. A detach pg_cron had already picked up when the recall landed still runs, and a
--   marker cleared in the same transaction as the recall would leave it landing on a partition that looks
--   detached by an operator, which this function and retire() both leave alone (#652). Keeping the marker
--   one call longer is what lets the next branch recognise the late detach as this retirement's own.
--
--   DETACHED by this retirement (marker set, no longer a partition of the parent): re-attached on its own
--   bounds, logged retain_reattach. The job is disarmed first, or its next run would detach it again. The
--   CHECK constraint DETACH ... CONCURRENTLY leaves on the detached table is dropped once the partition
--   bound enforces the same thing again, as transmute does with the monolith's: identified as exactly the
--   partition constraint, which is what the detach adds. A re-attach that fails (a lock timeout in the
--   tick, something else now holding the range) is logged fail_retain_reattach and counted in
--   status().retain_drop_failures; the table and its rows are left whole and the next call tries again.
--
--   PENDING (inhdetachpending): a detach in its wait phase, or one _detach_reap will finalize. Left for a
--   later call, silently, as _detach_reap leaves a live one.
--
-- A name that no longer resolves to the relation either anchor recorded is not acted on beyond disarming
-- its own command: logged fail_retain_identity, as retire() does for the same mismatch.
--
-- p_reattach false is set_retain's call: recall only. set_retain is an operator's call with no
-- lock_timeout of its own, and an ATTACH there would queue behind whatever holds the parent; the tick
-- that follows re-attaches under maintain's 200 ms lock_timeout, and confirms the recall.
create or replace function pgpm._retain_recall(p_parent regclass, p_reattach boolean)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; v_nsp name; r record; v_now regclass; v_cmd_q text;
  v_armed boolean; v_pending boolean; v_check name; v_n int := 0;
  v_db oid := (select oid from pg_database where datname = current_database());
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  -- nothing under way, nothing to take back: the ordinary tick reads no frontier here
  if not exists (select 1 from pgpm.part where parent_table = p_parent and attached and retiring_at is not null) then
    return 0;
  end if;
  v_boundary := pgpm._retain_boundary(cfg);

  for r in select child_name, lo, hi, retiring_oid, child_oid from pgpm.part
            where parent_table = p_parent and attached and retiring_at is not null
  loop
    -- still reached: the retirement stands, and retire() finishes it
    continue when v_boundary is not null and not pgpm._native_gt(cfg.control_kind, r.hi, v_boundary);

    -- #778: the partition's own schema, not the parent's (#727). retire() armed the job with
    -- <own schema>.<child>, so the identity check, the disarm, the ATTACH and the constraint drop below
    -- all have to name it there, or a moved parent's recall finds nothing and leaves the detach armed.
    v_nsp := pgpm._child_nsp(p_parent, r.child_name);
    v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));
    v_cmd_q := pgpm._detach_cmd(p_parent, v_nsp, r.child_name);
    if (r.retiring_oid is not null and v_now::oid is distinct from r.retiring_oid)
       or (r.child_oid is not null and v_now::oid is distinct from r.child_oid) then
      perform pgpm._idle_detach_job(v_cmd_q);
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_retain_identity', r.lo, r.hi,
                format('%I.%I is oid %s now, not the relation whose retirement retention no longer reaches; refusing to re-attach it',
                       v_nsp, r.child_name, coalesce(v_now::oid::text, 'nothing')));
      continue;
    end if;

    begin
      execute 'select exists (select 1 from cron.job where jobname = ''pgpm_detach'''
           || ' and database = current_database() and command = $1)'
        into v_armed using v_cmd_q;
    exception when others then
      v_armed := false;   -- no pg_cron, or no such job: nothing can be armed
    end;

    select i.inhdetachpending into v_pending
      from pg_inherits i where i.inhparent = p_parent and i.inhrelid = v_now;
    if found then
      continue when v_pending;
      if v_armed then
        perform pgpm._idle_detach_job(v_cmd_q);
        insert into pgpm.log (parent_table, action, lo, hi, method)
          values (p_parent, 'retain_recall', r.lo, r.hi,
                  format('retention no longer reaches %I.%I (horizon %s); its dispatched concurrent detach was recalled and the partition stays attached',
                         v_nsp, r.child_name, coalesce(v_boundary, 'none')));
        v_n := v_n + 1;
        continue;
      end if;
      -- not armed: clear the marker unless a detach of it is still on its way (_detach_reap's signals 1
      -- and 2: a lock on the partition held or awaited, or the statement itself)
      continue when p_reattach is not true
        or exists (select 1 from pg_locks l
                    where l.locktype = 'relation' and l.database = v_db and l.relation = v_now::oid
                      and l.mode in ('ShareUpdateExclusiveLock', 'AccessExclusiveLock')
                      and l.pid <> pg_backend_pid())
        or exists (select 1 from pg_stat_activity a
                    where a.datname = current_database() and a.pid <> pg_backend_pid() and a.state = 'active'
                      and a.query ~* 'detach[[:space:]]+partition' and a.query ~* 'concurrently'
                      and position(lower(r.child_name) in lower(a.query)) > 0);
      update pgpm.part set retiring_at = null, retiring_oid = null
       where parent_table = p_parent and child_name = r.child_name;
      continue;
    end if;

    -- the dispatched detach landed
    continue when p_reattach is not true or v_now is null;
    perform pgpm._idle_detach_job(v_cmd_q);
    begin
      execute format('alter table %s attach partition %I.%I for values from (%L) to (%L)',
                     p_parent::text, v_nsp, r.child_name,
                     pgpm._encode(cfg.control_kind, r.lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz),
                     pgpm._encode(cfg.control_kind, r.hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz));
      for v_check in
        select c.conname from pg_constraint c
         where c.conrelid = v_now and c.contype = 'c' and c.conislocal and c.coninhcount = 0
           and pg_get_constraintdef(c.oid) = format('CHECK (%s)', pg_get_partition_constraintdef(v_now))
      loop
        execute format('alter table %I.%I drop constraint %I', v_nsp, r.child_name, v_check);
      end loop;
      update pgpm.part set retiring_at = null, retiring_oid = null
       where parent_table = p_parent and child_name = r.child_name;
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'retain_reattach', r.lo, r.hi,
                format('retention no longer reaches %I.%I (horizon %s), but its dispatched detach had already landed; re-attached',
                       v_nsp, r.child_name, coalesce(v_boundary, 'none')));
      v_n := v_n + 1;
    exception when others then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_retain_reattach', r.lo, r.hi,
                left(format('retention no longer reaches %I.%I, which its dispatched detach took out of the parent, and re-attaching it failed: %s',
                            v_nsp, r.child_name, sqlerrm), 200));
    end;
  end loop;
  return v_n;
end;
$$;

create or replace function pgpm.retain(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; v_ncast text; r record; v_dropped int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  -- #724: first, take back any retirement this horizon no longer reaches (recall its armed detach, or
  -- re-attach the partition it already took out of the parent). Ahead of the null check, because null
  -- (keep everything) is the widest loosening of all.
  perform pgpm._retain_recall(p_parent, true);
  if cfg.retain is null then return 0; end if;

  v_boundary := pgpm._retain_boundary(cfg);
  v_ncast := pgpm._native_type(cfg.control_kind);

  -- retire() carries the per-partition protocol (claim, write-block, archive-coverage gate, drop,
  -- bookkeeping -- see there); this loop only picks the eligible set, oldest first, capped by
  -- retain_batch (issue #189; 'limit all' when null). A retire() that returns false (archive
  -- coverage not yet complete -- a normal, retryable state, not a failure -- or claimed/retired by a
  -- concurrent assistant) still consumed its batch slot: the cap bounds ATTEMPTS, not successes.
  for r in execute format(
    'select child_name from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s order by lo::%s limit %s',
    p_parent::text, v_ncast, v_boundary, v_ncast, v_ncast, coalesce(cfg.retain_batch::text, 'all'))
  loop
    if pgpm.retire(p_parent, r.child_name) then v_dropped := v_dropped + 1; end if;
  end loop;
  return v_dropped;
end;
$$;

-- write-block on retain-eligibility (issue #235). A
-- partition past _retain_boundary() is drop-eligible, and for however long it takes chunked
-- archiving to finish covering it (or forever, for a table with no archive strategy at all), it
-- should not accept writes either -- a backdated write into that span, including into a range some
-- earlier archive chunk already covered, would silently diverge the archive from what is live. Two
-- alternatives were ruled out empirically, not on paper: REVOKEing INSERT/UPDATE/DELETE on the
-- child does nothing, because a parent-routed write is checked against the PARENT's ACL, never the
-- child's; and a lock spanning the whole (unbounded, chunked) archiving window defeats the reason
-- chunking exists. A BEFORE ROW trigger on the specific child is checked regardless of routing,
-- can't be bypassed by an owner or superuser the way a privilege check can, and is torn down for
-- free by the eventual DROP TABLE.
create or replace function pgpm._write_block_raise() returns trigger
language plpgsql as $$
begin
  raise exception 'pg_partition_magician: % is past its retention boundary and is no longer writable', tg_table_name;
end;
$$;

-- idempotent: on a child that is already blocked it only checks the trigger's enable state (the #450
-- note below), so a repeat _enforce_write_blocks tick (every maintain() call revisits every attached
-- child) never raises a duplicate-trigger error.
--
-- IDENTITY, BEFORE THE DDL (issue #429). This resolves p_child by NAME and then issues CREATE
-- TRIGGER against whatever comes back, and _enforce_write_blocks calls it for every attached child
-- on every maintain() tick. Without the check below, a relation that has taken a partition's name
-- gets a pgpm trigger rejecting all of its INSERTs, UPDATEs and DELETEs -- DDL against a relation
-- pgpm never identified, on a table it was never handed, recorded nowhere in its own catalog.
--
-- The second consequence is the one that made #421 reachable rather than theoretical:
-- _archive_step's candidate query gates on _is_write_blocked, so a substituted name is only ever
-- ELIGIBLE for archiving because this step made it so. Maintenance manufactured its own candidate.
-- Refusing here is therefore not redundant with #421's own check, it is upstream of it.
--
-- The check lives HERE rather than in _enforce_write_blocks' loop, even though that loop already
-- holds the pgpm.part row this has to re-read. The loop is only one of the callers; retire() has two
-- more, and they are safe today only because #430's identity check happens to sit upstream of them.
-- A check in the function cannot be reintroduced by a caller that did not know to make it.
--
-- Logged and RETURNS, never raises. Raising would propagate out through retire(), which calls this
-- outside any handler, and turn a wedge into an error; it would also reach _enforce_write_blocks'
-- per-child handler, which would log it as skip_write_block -- and `skip_` means a deferral a later
-- tick clears, which this is precisely not. There is no later tick on which the name goes back to
-- meaning the right relation, so it gets its own prefixed action and status() counts it with the
-- other things that stall retention: no write block means no archiving, and no drop.
--
-- A null child_oid is unanchored and skips the check, same as everywhere else, so an upgrade never
-- wedges a partition it has nothing to compare against.
--
-- `v_now is not null and ... <> ...`, NOT the `is distinct from` used by the identity checks in
-- retire() and _archive_step, and the difference is deliberate. Those two fire on a name that
-- resolves to NOTHING as well, because there the next thing they would do is act on the relation --
-- read it, or DROP it -- and failing closed is the whole point. Here there is no wrong relation to
-- act on: if the name resolves to nothing, the `::regclass` cast below raises, _enforce_write_blocks'
-- per-child handler catches it, and `skip_write_block` is logged carrying the real error. That path
-- predates this check (issue #360, and tests/94 is built on it), and intercepting it here would
-- replace a tested, accurate report with a misleading one -- this refusal means "something else
-- holds the name", which is not what a dropped partition is. A pgpm.part row whose relation is gone
-- is forget_missing's business, and retire() already counts it via fail_retain_identity.
--
-- A block found not ENABLE ALWAYS is put back, and LOGGED (#710): the same ALTER that upgrades a pre-#450
-- origin-only block also re-enables one an operator DISABLEd (or set to ENABLE REPLICA), and that used to
-- happen with nothing logged, so the partition went read-only again on the next tick and pgpm.log had
-- nothing to say why. Re-enabling stays right, since the block is retention's fence and archive coverage is
-- only true while it holds, but it overrides a change made by hand, so write_block_reenable records it,
-- once per re-enable, naming the state it found.
create or replace function pgpm._install_write_block(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare v_nsp name; v_child regclass; v_now regclass; v_enabled "char"; r record;
begin
  v_nsp := pgpm._child_nsp(p_parent, p_child);   -- #727: the partition's own schema, not the parent's

  select p.lo, p.hi, p.child_oid into r
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

  v_child := format('%I.%I', v_nsp, p_child)::regclass;
  select tgenabled into v_enabled from pg_trigger where tgrelid = v_child and tgname = 'pgpm_write_block';
  if found then
    -- The upgrade path for #450. A block installed by an older pgpm is origin-only, and re-running
    -- install.sql touches no trigger, so the revisit every tick already makes is where it gets fixed:
    -- one ALTER, once, on the first tick after the upgrade.
    -- And logged (#710, see above).
    if v_enabled <> 'A' then
      execute format('alter table %I.%I enable always trigger pgpm_write_block', v_nsp, p_child);
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'write_block_reenable', r.lo, r.hi,
                format('%I.%I: pgpm_write_block was %s and is ENABLE ALWAYS again (retention''s fence)',
                       v_nsp, p_child,
                       case v_enabled when 'D' then 'disabled' when 'R' then 'replica-only' else 'origin-only' end));
    end if;
    return;
  end if;
  execute format(
    'create trigger pgpm_write_block before insert or update or delete on %I.%I'
    || ' for each row execute function pgpm._write_block_raise()', v_nsp, p_child);
  -- ENABLE ALWAYS (#450). CREATE TRIGGER leaves a trigger origin-only, which a session running as
  -- session_replication_role = replica (a logical-replication apply worker, a loader silencing triggers)
  -- skips. That default is for triggers that are replication side effects; this one is retention's
  -- fence, and a row that gets past it lands in a partition whose archive coverage is already complete
  -- and is dropped unarchived.
  execute format('alter table %I.%I enable always trigger pgpm_write_block', v_nsp, p_child);
end;
$$;

-- the reverse: an operator loosening config.retain can make a previously-eligible partition
-- ineligible again, so this needs to run just as often as _install_write_block. drop ... if exists
-- makes it just as idempotent on a child that was never blocked.
--
-- UNCONDITIONAL, on purpose. The rule that a block is not lifted from a child pgpm.archive_ledger
-- covers (issue #452) lives in _enforce_write_blocks below, the one caller that lifts a block
-- observably. retire()'s crossing path removes and reinstalls the trigger inside a single transaction,
-- on a child whose coverage is complete by then, and relies on this removing it regardless.
--
-- DELIBERATELY NOT ANCHORED, unlike the install above (issue #429). The asymmetry is the point.
-- Refusing to install on a relation pgpm has not identified is protective; refusing to REMOVE from
-- one is the opposite. A pre-#429 pgpm installed this trigger on whatever held the name, so an
-- install upgrading into that fix can already have one sitting on a relation it never managed,
-- rejecting every write to it -- and an anchored removal would refuse to touch the very trigger
-- pgpm itself wrongly created, leaving that relation read-only permanently. Resolving by name is
-- what lets an upgraded pgpm clean up after an older one. The statement is `drop trigger if
-- exists`, so on anything pgpm never blocked it remains a no-op.
create or replace function pgpm._remove_write_block(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare v_nsp name;
begin
  v_nsp := pgpm._child_nsp(p_parent, p_child);   -- #727: the partition's own schema, not the parent's
  execute format('drop trigger if exists pgpm_write_block on %I.%I', v_nsp, p_child);
end;
$$;

-- reconciles every attached child's write-block state against current eligibility in one pass,
-- reusing the exact _retain_boundary() retire() itself checks so "eligible to write-block" and
-- "eligible to drop" can never disagree. A table with no retention policy (config.retain null) has
-- no boundary at all, so nothing is ever eligible and nothing is ever blocked.
--
-- Each child's install/remove attempt is isolated in its own exception scope (issue #360): a lock
-- timeout (or any other failure) on one child logs skip_write_block for that child alone and moves
-- on, rather than raising out of the whole loop and leaving every child after it -- lock-contended
-- or not -- untouched for the entire tick. `order by hi asc` means that even when repeated
-- contention does limit how far one tick's pass gets, the oldest (most overdue) children are always
-- the ones attempted first, matching _archive_step's existing oldest-first convention (#237).
--
-- A BLOCK IS NOT LIFTED FROM A CHILD THE LEDGER COVERS (issue #452). pgpm.archive_ledger is a
-- watermark: _next_archive_chunk resumes from max(hi), and _archive_fully_covered is true once that
-- reaches the child's own hi. The watermark describes the child's CONTENTS only because the trigger
-- has been on the child since the first chunk was recorded, so nothing can have been written into,
-- or deleted out of, a covered range. Eligibility, though, regresses: an `id` table's frontier is
-- max(control), so deleting the newest rows moves the horizon back, and set_retain loosening moves
-- it back for every kind. Lifting the block on regression let a late write land in a range the
-- ledger already called done; when the block came back archiving resumed from the watermark,
-- retire() saw full coverage, and the partition dropped with that row in it and no strategy ever
-- handed it. So the block stays while coverage exists. The child keeps being archived to completion
-- under it (_archive_step gates on the trigger, not on the boundary), and whether it is dropped is
-- retire()'s decision alone, which is no while retention does not reach it. What an operator sees is
-- a partition still read-only after loosening retain, so the first tick that keeps a block it would
-- otherwise have lifted logs skip_write_block_lift for that child, ONCE per child: the state lasts as
-- long as the coverage does, and a row per tick would be noise. The documented way to make the
-- partition writable is to discard its coverage (delete its pgpm.archive_ledger rows); the next tick
-- lifts the block, and archiving starts over from lo if the child is ever blocked again. `skip_`,
-- not `fail_`: nothing is wedged and nothing is wrong, the lift is deferred until the coverage is
-- gone, and status() must not count it with the things that stall retention.
--
-- The guard is HERE and not in _remove_write_block because this is the one caller that lifts a block
-- observably. retire()'s crossing path removes and reinstalls the trigger inside a single transaction,
-- on a child whose coverage is complete by then, and must keep doing so unconditionally.
--
-- COVERAGE FOUND WITHOUT ITS BLOCK IS DISCARDED: the same invariant, approached from the other side.
-- Under the rule above a covered child is always blocked, so ledger rows on an unblocked child can
-- only mean the block left by a path pgpm did not guard: a pgpm older than this rule lifted it before
-- an upgrade, an operator dropped the trigger by hand, or the rows are left over from an earlier
-- incarnation of the name (retire() and untransmute both leave ledger rows in place). In each case
-- the watermark is a claim about contents nothing has been guarding, and trusting it is exactly the
-- defect, so the rows go, logged as archive_coverage_reset with how many, and archiving restarts from
-- lo once the child is blocked again (this same tick, if it is eligible). The ledger is read FIRST
-- and the trigger second, on purpose: a chunk is only ever recorded after the transaction that
-- installed its trigger committed, so a read that finds coverage and then finds no trigger has found
-- a trigger that left AFTER the coverage was recorded, never one that has simply not landed yet.
--
-- AND THE DISCARD IS ANCHORED TO IDENTITY (issue #518). "Without its block" was decided by NAME,
-- _is_write_blocked(child_name), while the #429 identity check sat further down the loop body inside
-- _install_write_block. A relation squatting on a partition's name has no trigger, so the tick read
-- the REAL partition's coverage as unguarded and deleted its ledger rows, in the same tick that then
-- refused to write-block the squatter as fail_write_block_identity. The rows described a relation
-- that was still attached, still blocked and unchanged; only the name had moved. So each child's
-- name is resolved against pgpm.part.child_oid before anything the loop decides by that name, with
-- exactly _install_write_block's predicate (a null anchor compares as nothing; a name resolving to
-- nothing stays on the skip_write_block path, for the reasons given above that function), and a
-- substituted name suppresses the discard: the identity refusal, logged by _install_write_block when
-- the child is eligible, is then the whole of what the tick does for that child. The predicate is
-- computed here rather than by anchoring _is_write_blocked, which _archive_step and retire() share
-- and each follow with an identity refusal of their own one step later, and because the remove arm
-- below must keep resolving by name: _remove_write_block is deliberately unanchored (#429), so that
-- an upgraded pgpm can lift a trigger an older one left on whatever held the name.
create or replace function pgpm._enforce_write_blocks(p_parent regclass)
returns void language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; v_nsp name; r record; v_eligible boolean; v_chunks bigint;
  v_now regclass; v_substituted boolean;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  v_boundary := pgpm._retain_boundary(cfg);

  for r in select child_name, lo, hi, child_oid from pgpm.part where parent_table = p_parent and attached
    order by hi asc
  loop
    begin
      v_nsp := pgpm._child_nsp(p_parent, r.child_name);   -- #727: the partition's own schema, not the parent's
      v_eligible := v_boundary is not null and not pgpm._native_gt(cfg.control_kind, r.hi, v_boundary);

      -- identity first (#518): does the name still mean the relation pgpm recorded?
      v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));
      v_substituted := r.child_oid is not null and v_now is not null and v_now::oid <> r.child_oid;

      select count(*) into v_chunks from pgpm.archive_ledger
       where parent_table = p_parent and child_name = r.child_name;
      if v_chunks > 0 and not v_substituted and not pgpm._is_write_blocked(p_parent, r.child_name) then
        delete from pgpm.archive_ledger where parent_table = p_parent and child_name = r.child_name;
        insert into pgpm.log (parent_table, action, lo, hi, rows, method)
          values (p_parent, 'archive_coverage_reset', r.lo, r.hi, v_chunks,
                  format('%s archived chunk(s) were recorded for %I.%I under a write block that is no longer on it or no longer enabled ALWAYS, so they no longer describe its contents; discarded, and archiving starts over from %s once it is blocked again',
                         v_chunks, v_nsp, r.child_name, r.lo));
        v_chunks := 0;
      end if;

      if v_eligible then
        perform pgpm._install_write_block(p_parent, r.child_name);
      elsif v_chunks > 0 then
        if not exists (select 1 from pgpm.log
                        where parent_table = p_parent and action = 'skip_write_block_lift'
                          and lo = r.lo and hi = r.hi) then
          insert into pgpm.log (parent_table, action, lo, hi, method)
            values (p_parent, 'skip_write_block_lift', r.lo, r.hi,
                    format('retention no longer reaches %I.%I (horizon %s), but %s archived chunk(s) are recorded for it and that coverage is only true while nothing can write to it; keeping the write block. To make the partition writable again, delete its pgpm.archive_ledger rows',
                           v_nsp, r.child_name, coalesce(v_boundary, 'none'), v_chunks));
        end if;
      else
        perform pgpm._remove_write_block(p_parent, r.child_name);
      end if;
    exception when others then
      insert into pgpm.log (parent_table, action, hi, method)
        values (p_parent, 'skip_write_block', r.hi, left(sqlerrm, 200));
    end;
  end loop;
end;
$$;

-- true iff the write-block trigger is actually installed on this child right now (checked directly
-- against pg_trigger, not re-derived from the boundary formula) -- shared by _archive_step (issue
-- #237, only ever archives an already-blocked child) and retire() (issue #238) below.
--
-- AND IN FORCE: enabled ALWAYS, tgenabled = 'A' (issue #651). A trigger that exists and does not fire
-- is no block. A pre-#450 pgpm installed it origin-only, which a session running as
-- session_replication_role = replica writes straight through, and an operator can disable it by hand.
-- Presence alone let coverage recorded under either state survive the tick on which _install_write_block
-- repaired the trigger to ALWAYS: the #452/#564 discard in _enforce_write_blocks and retire() asks this
-- function, read the repaired-to-be block as a block, and kept a watermark over rows no strategy was
-- handed. With the state in the test, both discard that coverage before the repair, and _archive_step
-- never records coverage under a block that is not in force. The repair itself stays keyed on presence
-- (_install_write_block's own pg_trigger lookup), so a block in any other state is fixed in place, not
-- stacked.
--
-- The schema is matched by OID, never parsed back out of its name (#512). This used to select the
-- parent's nspname and cast it back with `::regnamespace`, whose input parses its text as an SQL
-- identifier: a schema whose name needs quoting ("Sales") was downcased, so the lookup raised `schema
-- "sales" does not exist` on every archive tick (nothing archived, the aged child never retired), or, once
-- a lower-case twin existed, silently answered for the twin's same-named child. _regrain_capture_active
-- had the same shape. And it is the CHILD's schema (#727), from pgpm._child_nsp, compared to pg_namespace
-- by exact name equality, which parses nothing: a parent moved with SET SCHEMA leaves its partitions behind.
create or replace function pgpm._is_write_blocked(p_parent regclass, p_child name)
returns boolean language plpgsql as $$
declare v_nsp_oid oid;
begin
  -- #727: the partition's own schema, not the parent's; matched by name = name, never parsed (#512)
  select n.oid into v_nsp_oid from pg_namespace n where n.nspname = pgpm._child_nsp(p_parent, p_child);
  return exists (
    select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
     where t.tgname = 'pgpm_write_block' and c.relname = p_child and c.relnamespace = v_nsp_oid
       and t.tgenabled = 'A'
  );
end;
$$;

-- ===================== pluggable archive strategy (issue #236) =====================
-- One archive strategy per managed table (config.archive_fn), superseding the old generic
-- pgpm.hook pre_drop registry (removed entirely, issue #240) -- archiving before a drop was its
-- only real use. pgpm._archive_step (below) drives this every maintain() tick, and retire()'s drop
-- precondition gates on pgpm._archive_fully_covered.

-- archive_fn's return shape: how much of a requested [lo, hi) a single call durably archived.
-- covered_hi is the native-grid value up to which [lo, ...) is now durably archived by THIS call --
-- may be less than hi, since a real strategy is expected to be resumable (called again next tick to
-- make further bounded progress, not to finish the whole range at once), but it must be ABOVE lo and
-- AT MOST hi: _archive_step holds it to that before a ledger row is written from it (issue #454, see
-- _archive_contract_breach below), since that row is what opens retire()'s drop gate. A strategy that
-- can make no progress on a call (the object store is unreachable, say) should RAISE rather than
-- return: maintain() logs a skip_archive deferral and hands it the same chunk next tick. rows_archived
-- is how many rows this call actually archived; null when nothing was actually archived (the 'none'
-- strategy, or a range that held no rows). s3_key/etag are optional identifiers a transport
-- strategy (e.g. pgpm_archive's pgpm.archive_to_s3_ndjson/archive_to_s3_parquet, issue #239) can
-- report back for the ledger row; null for a strategy with nothing object-store-shaped to name (the
-- 'none' strategy, pgpm._archive_noop, a user-authored strategy that doesn't use S3). No CREATE OR
-- REPLACE TYPE exists in PostgreSQL, so guard creation the same way the rest of this file guards
-- idempotent DDL.
do $$ begin
  if not exists (
    select 1 from pg_type where typname = 'archive_result' and typnamespace = 'pgpm'::regnamespace
  ) then
    create type pgpm.archive_result as (covered_hi text, rows_archived bigint, s3_key text, etag text);
  end if;
end $$;

-- the trivial built-in strategy: exists only to exercise real dispatch (a real regprocedure call,
-- not a null-strategy special case) in tests. Always reports the whole requested range archived
-- immediately -- functionally what a 'none'-strategy table already gets from
-- _run_archive_strategy's null handling below, just reached via a real archive_fn call.
create or replace function pgpm._archive_noop(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_rows bigint; v_result pgpm.archive_result;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  v_nsp := pgpm._child_nsp(p_parent, p_child);   -- #727: the partition's own schema, not the parent's
  execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                 v_nsp, p_child, cfg.control_column, pgpm._encode(cfg.control_kind, p_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz),
                 cfg.control_column, pgpm._encode(cfg.control_kind, p_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz))
    into v_rows;
  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  return v_result;
end;
$$;

-- the dispatch stub: looks up config.archive_fn and calls it. A null archive_fn (strategy 'none')
-- never actually archives anything, so the requested range is trivially "already fully covered" --
-- there is nothing to protect against a drop.
create or replace function pgpm._run_archive_strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare cfg pgpm.config; v_result pgpm.archive_result;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.archive_fn is null then
    v_result.covered_hi := p_hi;
    v_result.rows_archived := null;
    return v_result;
  end if;
  -- select * from fn(...), not select fn(...): the latter returns the composite as ONE column,
  -- which EXECUTE ... INTO a named-composite variable maps positionally (1 source column against
  -- pgpm.archive_result's 2 fields) rather than assigning the whole value -- covered_hi would end
  -- up holding the composite's own text form and rows_archived would stay null. Calling it as a
  -- FROM-item expands its fields into real output columns first.
  execute format('select * from %s($1,$2,$3,$4)', (cfg.archive_fn::oid::regproc)::text)
    into v_result using p_parent, p_child, p_lo, p_hi;
  return v_result;
end;
$$;

-- ============= byte-budget chunked archiving on the archive_fn contract (issue #237) =============
-- Ports archive._next_range_byte_budget/archive.archive_range/archive.ledger (#213, #221) -- the
-- mechanism that makes archiving a large partition safe without one giant transaction -- onto the
-- archive_fn contract, unchanged in intent. The one real adaptation: the original picked a range
-- across the WHOLE table, bounded by the frontier and the retention horizon directly, because
-- nothing else gated eligibility yet. Here that gating is already done per child by the write-block
-- trigger (#235) -- a child only becomes a candidate once _enforce_write_blocks has actually
-- installed it -- so the chunk picker only ever needs to work within ONE already-eligible child's
-- own [lo, hi), never across partition boundaries. archive.ledger/archive.archive_range/archive.tick
-- in pgpm_archive are untouched and keep working exactly as before; they are deleted only once this
-- path is proven out (#240).

-- successor to archive.ledger, same shape (parent_table, lo, hi, child_name nullable, s3_key, etag,
-- rows_archived, archived_at), primary key (parent_table, lo) since a chunk always belongs to
-- exactly one child and one parent's chunks never overlap. s3_key/etag come straight from
-- pgpm.archive_result (issue #239 widened the contract to carry them) -- populated for a real
-- transport strategy (e.g. pgpm_archive's pgpm.archive_to_s3_ndjson/archive_to_s3_parquet), still
-- null for a strategy with nothing object-store-shaped to name (pgpm._archive_noop, the 'none'
-- strategy). rows_archived is nullable (unlike the original's not null): the contract explicitly
-- allows a call to report no rows archived (a range that held none). hi, though, is never lo itself
-- and never past the chunk the strategy was handed: _archive_step refuses such a return before it
-- gets here (issue #454).
create table if not exists pgpm.archive_ledger (
  parent_table  regclass    not null,
  lo            text        not null,
  hi            text        not null,
  child_name    name,
  s3_key        text,
  etag          text,
  rows_archived bigint,
  archived_at   timestamptz not null default now(),
  primary key (parent_table, lo)
);
create index if not exists archive_ledger_parent_child_hi_idx on pgpm.archive_ledger (parent_table, child_name, hi desc);

-- picks the next chunk to archive within ONE child: resumes from wherever pgpm.archive_ledger's
-- coverage of THIS child left off (or the child's own lo, on the first call), estimates how many
-- rows fit config.archive_byte_budget via a sampled average row width (config.archive_probe_sample
-- rows), then extends to the next distinct control value past the probed boundary so a run of ties
-- never splits across two chunks -- identical reasoning to the original, just scoped to the child's
-- own table instead of the parent. Returns no rows once the child is fully covered. Resuming from
-- the watermark rather than re-reading from lo is sound only while the write block has been on the
-- child since the first chunk, which _enforce_write_blocks guarantees (issue #452): it never lifts a
-- block from a covered child, and discards coverage it finds on an unblocked one.
create or replace function pgpm._next_archive_chunk(p_parent regclass, p_child name)
returns table(lo text, hi text)
language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name;
  v_child_lo text; v_child_hi text; v_lo text;
  v_avg numeric; v_batch int; v_batch_count int; v_probe_hi_col text; v_probe_hi text;
  v_next_distinct_col text; v_stop text; v_unit text; v_cval_q text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  v_nsp := pgpm._child_nsp(p_parent, p_child);   -- #727: the partition's own schema, not the parent's
  select p.lo, p.hi into v_child_lo, v_child_hi from pgpm.part p
   where p.parent_table = p_parent and p.child_name = p_child;
  if not found then raise exception 'pg_partition_magician: %.% is not a tracked partition', p_parent, p_child; end if;

  -- hi is stored as text; a plain max() would compare lexicographically ('91' > '1000'), not
  -- numerically/temporally -- cast to the native type first, the same fix archive._file_watermark
  -- already needed for this exact reason.
  execute format('select %s from pgpm.archive_ledger where parent_table = %L::regclass and child_name = %L',
                 pgpm._max_hi_native(cfg.control_kind), p_parent::text, p_child)
    into v_lo;
  v_lo := coalesce(v_lo, v_child_lo);

  if not pgpm._native_gt(cfg.control_kind, v_child_hi, v_lo) then
    return;   -- already fully covered
  end if;

  execute format(
    'select avg(pg_column_size(t.*))::numeric from (select * from %I.%I t where t.%I >= %L order by t.%I limit %s) t',
    v_nsp, p_child, cfg.control_column, pgpm._encode(cfg.control_kind, v_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz), cfg.control_column, cfg.archive_probe_sample)
    into v_avg;
  if coalesce(v_avg, 0) <= 0 then
    -- no rows remain in [v_lo, child_hi) for this child. Unlike the original (which read ahead of a
    -- still-moving frontier, where "nothing yet" could mean "not yet arrived"), this child is
    -- already write-blocked and frozen -- nothing will EVER land here again, so the rest of its
    -- range is trivially covered with zero rows archived.
    lo := v_lo; hi := v_child_hi;
    return next;
    return;
  end if;
  v_batch := greatest(1, floor(cfg.archive_byte_budget::numeric / v_avg))::int;

  -- How a row's control value is read back as text (#788): an instant through _ts_text, never a bare
  -- ::text. Each value read here is parsed again in this session, by _col_to_native and, as a literal, by
  -- the next-distinct probe, and under a DateStyle that renders zone abbreviations (SQL, Postgres) a bare
  -- render does not round-trip: Europe/Dublin's summer 'IST' reads as Israel (+02), so every value read an
  -- hour early, the stop fell at or below lo, no chunk was ever returned and the aged child was skipped
  -- silently every tick, never archived and so never retired. The #570 rule, as regrain's reconcile
  -- applies it per row. A naive column's own text carries no zone and parses back to itself in the session
  -- that rendered it, and the other kinds' columns (numeric, uuid, text) render the same under every
  -- DateStyle, so they stay ::text.
  v_cval_q := case when cfg.control_kind = 'time' and not pgpm._control_naive(p_parent, cfg.control_column)
                   then format('pgpm._ts_text(t.%I)', cfg.control_column)
                   else format('t.%I::text', cfg.control_column) end;

  -- The window's size and its newest control value, in one scan (a CTE read twice is materialised once).
  -- The newest value is read with ORDER BY ... DESC LIMIT 1 and NOT max(), and the tie extension below
  -- with ORDER BY ... ASC LIMIT 1 and NOT min(): PostgreSQL has no max(uuid) or min(uuid) before 18, so
  -- as aggregates both raised 42883 on every uuidv7 table with an archive_fn, every tick's archive step
  -- was logged as skip_archive, no ledger row was ever written and the aged partition was never
  -- retired (#507). Same reasoning, and the same shape, as _frontier_native's read of the frontier.
  execute format(
    'with w as (select t.%I as c, %s as c_text from %I.%I t where t.%I >= %L order by t.%I limit %s)
     select (select count(*) from w), (select w.c_text from w order by w.c desc limit 1)',
    cfg.control_column, v_cval_q, v_nsp, p_child, cfg.control_column,
    pgpm._encode(cfg.control_kind, v_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz), cfg.control_column, v_batch)
    into v_batch_count, v_probe_hi_col;

  if v_batch_count < v_batch then
    v_stop := v_child_hi;   -- the byte budget reaches past this child's own live end
  else
    v_probe_hi := pgpm._col_to_native(cfg, v_probe_hi_col);
    -- extend to the next distinct value past the boundary, so hi never splits a run of ties (a
    -- child's own CHECK bounds every row here to < v_child_hi already, so this can never overshoot it)
    execute format('select %s from %I.%I t where t.%I > %L order by t.%I asc limit 1',
                   v_cval_q, v_nsp, p_child, cfg.control_column, v_probe_hi_col, cfg.control_column)
      into v_next_distinct_col;
    v_stop := case when v_next_distinct_col is null then v_child_hi
                   else pgpm._col_to_native(cfg, v_next_distinct_col) end;
    -- The tie that matters is on the NATIVE grid, not the column (#513). A chunk's bounds are native
    -- values, and for text_time and uuidv7 the decode truncates to the encoding's unit (a second for
    -- ObjectId and KSUID, a millisecond for uuidv7, ULID and cuid), so when one unit holds at least a
    -- chunk's worth of rows (a bulk import minted within one second) the next distinct COLUMN value
    -- decodes to v_lo itself and v_stop = v_lo. Returning nothing here was permanent: every later tick
    -- resumed from the same v_lo and stopped there again, with no log row, and the child was never
    -- covered nor retired. A run of rows at one native value can no more be split than a run at one
    -- column value (the strategy is handed native bounds, which fall only on unit boundaries), so extend
    -- past the unit: the chunk ends at the first row minted after v_lo's unit, or at the child's hi if
    -- there is none, and it exceeds archive_byte_budget by construction, which is the documented price
    -- of never splitting a tie. The lookup is an index probe on the unit's minimal literal, not a decode
    -- per row. The identity codecs (time, id) decode distinct values distinctly and cannot get here;
    -- their unit is their type's own resolution, so the same step would still be right if they did.
    -- The row past the unit is read with ORDER BY ... ASC LIMIT 1 and NOT min(), for #507's reason:
    -- there is no min(uuid) before PostgreSQL 18, and as an aggregate this read raised 42883 on every
    -- uuidv7 pick that reached it, so the burst it exists for wedged the child instead (#571).
    if not pgpm._native_gt(cfg.control_kind, v_stop, v_lo) then
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
  end if;

  if not pgpm._native_gt(cfg.control_kind, v_stop, v_lo) then
    return;   -- no progress possible this call
  end if;

  lo := v_lo; hi := v_stop;
  return next;
end;
$$;

-- true once pgpm.archive_ledger's recorded ranges for this child reach its own hi, or the strategy
-- is 'none' (nothing to protect against a drop). Chunks for a given child are gapless and
-- monotonically forward by construction (_next_archive_chunk always resumes exactly where the last
-- one left off), so the ledger's own max(hi) reaching the child's hi is exactly "the union covers
-- [lo, hi)" -- the same watermark reasoning archive._file_watermark already relied on. That union
-- describes the child's CONTENTS only because the write block has been on it throughout:
-- _enforce_write_blocks keeps the block on a covered child even when retention stops reaching it, and
-- discards coverage it finds without one (issue #452), as does retire() before it puts a missing block
-- back (issue #564), so a row present at the drop was handed to the strategy.
create or replace function pgpm._archive_fully_covered(p_parent regclass, p_child name)
returns boolean language plpgsql as $$
declare cfg pgpm.config; v_child_hi text; v_watermark text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.archive_fn is null then return true; end if;

  select p.hi into v_child_hi from pgpm.part p where p.parent_table = p_parent and p.child_name = p_child;
  if not found then raise exception 'pg_partition_magician: %.% is not a tracked partition', p_parent, p_child; end if;

  -- hi is text; cast to the native type before max()'ing, same reasoning (and the same fix) as
  -- _next_archive_chunk above -- a plain max() would compare lexicographically.
  execute format('select %s from pgpm.archive_ledger where parent_table = %L::regclass and child_name = %L',
                 pgpm._max_hi_native(cfg.control_kind), p_parent::text, p_child)
    into v_watermark;

  return v_watermark is not null and not pgpm._native_gt(cfg.control_kind, v_child_hi, v_watermark);
end;
$$;

-- THE STRATEGY'S RETURN IS A CLAIM, NOT A FACT (issue #454). archive_fn is a published extension
-- point, and the covered_hi it returns is written into pgpm.archive_ledger, which is what
-- _archive_fully_covered reads as retire()'s drop precondition. Recorded verbatim, a strategy bug that
-- answers chunk [0, 15) with covered_hi 15000 marks the whole partition covered on the spot and the
-- next retain() drops it with nothing archived. So hold the return to the promise the call made: a
-- native value with p_lo < covered_hi <= p_hi. Returns null when it keeps that promise, else the rule
-- it broke, in words an operator can act on.
--
-- Each bound closes a different hole. Above p_hi is the drop-with-nothing-archived defect itself.
-- The lower bound is STRICT on purpose: covered_hi = p_lo is "no progress", and recorded as a
-- (lo, lo) ledger row it wedges the ledger for good, because _next_archive_chunk resumes from max(hi)
-- = lo, hands the strategy the identical chunk, and the insert collides on the ledger's primary key
-- every tick from then on. Null is refused for the same reason (a null hi is not a watermark). And a
-- value that is not even a native value is caught here, by a class-22 data_exception on the cast,
-- rather than left to poison the text hi column and raise out of every later max(hi::numeric) over
-- the ledger, which maintain() would have reported as a skip_archive deferral, tick after tick, for
-- what is a permanent strategy bug. A strategy that genuinely cannot make progress on a call should
-- raise (see pgpm.archive_result's note): that IS the deferral path, and it retries the same chunk.
create or replace function pgpm._archive_contract_breach(p_kind text, p_lo text, p_hi text, p_covered_hi text)
returns text language plpgsql immutable as $$
begin
  if p_covered_hi is null then
    return 'covered_hi is null; the contract requires the native value up to which [lo, ...) is now archived';
  end if;
  begin
    if not pgpm._native_gt(p_kind, p_covered_hi, p_lo) then
      return 'covered_hi must be above lo: a call that covered nothing is not a chunk, and a (lo, lo) ledger row would collide with the next tick''s on the primary key';
    end if;
    if pgpm._native_gt(p_kind, p_covered_hi, p_hi) then
      return 'covered_hi must not exceed hi: the strategy is claiming coverage of a range it was not handed';
    end if;
  exception when data_exception then
    return format('covered_hi is not a %s value (%s)', pgpm._native_type(p_kind), sqlerrm);
  end;
  return null;
end;
$$;

-- one maintenance tick's worth of chunked archiving: picks up to config.archive_batch (default 1;
-- null = unlimited, same escape hatch retain_batch already has -- issue #351) attached children
-- that ALREADY have the write-block trigger installed (checked directly against pg_trigger, not
-- re-derived from the boundary formula -- this is what keeps archiving from ever running ahead of
-- write-blocking) and are not yet fully covered, oldest first, and for each picks its next chunk,
-- runs the configured strategy, holds its return to the contract (_archive_contract_breach above),
-- and records progress. Returns how many chunks were recorded this call. A 'none' strategy (archive_fn null) has nothing to do -- every child is already "covered"
-- per _archive_fully_covered above.
--
-- IDENTITY, BEFORE ANY READ OF THE CHILD (issue #421). What this loop selects out of pgpm.part is a
-- NAME, and everything downstream of it re-resolves that name independently and by itself: the
-- eligibility test above matches it against pg_class, _next_archive_chunk reads %I.%I three times to
-- size the chunk, and archive_fn is handed the bare string (its signature takes `p_child name`, a
-- published extension point that pgpm.set_archive_fn type-checks, so widening it to carry an OID is
-- not available). The check below is therefore made ONCE here, at the top of each candidate's turn,
-- which is the only place that covers all of them.
create or replace function pgpm._archive_step(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_ncast text; v_nsp name; v_now regclass;
  r record; v_range record; v_result pgpm.archive_result; v_breach text; v_count int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.archive_fn is null then return 0; end if;

  v_ncast := pgpm._native_type(cfg.control_kind);
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- COVERAGE UNDER A NAME NO LONGER TRACKED IS DISCARDED (issue #511). The ledger is keyed
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

  -- oldest first, matching retain()'s own convention -- archiving history in age order. The
  -- eligibility checks live in the WHERE clause (not a `continue` inside the loop, the old shape)
  -- specifically so `limit` bounds the right set: every row this query returns is a genuine
  -- candidate, so archive_batch caps how many DIFFERENT partitions get a turn this call, not how
  -- many rows happen to be scanned before finding that many.
  for r in execute format(
    'select p.child_name, p.child_oid, p.lo, p.hi from pgpm.part p
      where p.parent_table = %L::regclass and p.attached
        and pgpm._is_write_blocked(%L::regclass, p.child_name)
        and not pgpm._archive_fully_covered(%L::regclass, p.child_name)
      order by p.lo::%s
      limit %s',
    p_parent::text, p_parent::text, p_parent::text, v_ncast, coalesce(cfg.archive_batch::text, 'all'))
  loop
    -- #727: the partition's own schema, not the parent's (the discard above names an untracked name, so
    -- it can only guess the parent's)
    v_nsp := pgpm._child_nsp(p_parent, r.child_name);

    -- Two independent facts have to agree, exactly as in retire()'s own identity check (#407): the
    -- name resolves, and it resolves to the OID recorded when this partition entered pgpm.part.
    -- `is distinct from` so a name that resolves to nothing at all trips this too. A null child_oid
    -- is unanchored (see the column's own note) and is left to behave as it did before.
    --
    -- `continue`, not a raise or a return: one partition whose name has stopped meaning what it
    -- meant is not a reason to abandon the tick, and the loop above is already the per-candidate
    -- shape that makes skipping one of them the natural thing to do. It is still fail-CLOSED for the
    -- partition itself -- no chunk is read, no ledger row is written, so _archive_fully_covered
    -- stays false and retire()'s drop precondition stays shut -- and it stays closed, because there
    -- is no later tick on which the name goes back to meaning the right relation. That makes it a
    -- wedge an operator has to resolve (pgpm.forget_missing, or putting the name back), which is why
    -- it is logged as a prefixed non-success action and counted by status() alongside the other
    -- things that stall retention. At archive_batch's default of 1 it also stops this parent's
    -- archiving behind it, which is the correct reading: pgpm's catalog is provably wrong about
    -- which relation is which, and retention should not march on past that.
    v_now := to_regclass(format('%I.%I', v_nsp, r.child_name));
    if r.child_oid is not null and v_now::oid is distinct from r.child_oid then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_archive_identity', r.lo, r.hi,
                format('%I.%I is oid %s now, not the oid %s recorded for this partition; refusing to archive it',
                       v_nsp, r.child_name, coalesce(v_now::oid::text, 'nothing'), r.child_oid));
      continue;
    end if;

    select * into v_range from pgpm._next_archive_chunk(p_parent, r.child_name);
    if not found then continue; end if;

    v_result := pgpm._run_archive_strategy(p_parent, r.child_name, v_range.lo, v_range.hi);

    -- Hold the return to the chunk it was handed (issue #454; the rules are _archive_contract_breach's
    -- own comment). Same shape as the identity refusal above: `continue`, and no ledger row, so the
    -- child's coverage stays exactly where it was and retire()'s drop precondition stays shut. Unlike
    -- that refusal this one IS retryable, and by construction: nothing advanced, so the next tick hands
    -- the strategy the very same chunk, and a corrected strategy (pgpm.set_archive_fn) resumes from
    -- where the ledger honestly stands. Until then it logs once per tick, counts in
    -- status().retain_drop_failures, and at archive_batch's default of 1 holds up this parent's other
    -- partitions, which is right: the strategy is provably wrong about what it archived.
    v_breach := pgpm._archive_contract_breach(cfg.control_kind, v_range.lo, v_range.hi, v_result.covered_hi);
    if v_breach is not null then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_archive_contract', v_range.lo, v_range.hi,
                format('%s returned covered_hi %s for %I.%I chunk [%s, %s): %s; refusing to record it',
                       cfg.archive_fn::text, coalesce(quote_literal(v_result.covered_hi), 'null'),
                       v_nsp, r.child_name, v_range.lo, v_range.hi, v_breach));
      continue;
    end if;

    insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, etag, rows_archived)
    values (p_parent, v_range.lo, v_result.covered_hi, r.child_name, v_result.s3_key, v_result.etag, v_result.rows_archived);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ============================== regrain ==============================

-- regrain splits a FROZEN coarse child (the monolith, or a coarser child from a prior pass) into finer
-- children, by COPYING the rows into standalone children in budget-sized microbatches, then in ONE atomic
-- step detaching the coarse source, attaching the fine children, and DROPping the source. It never deletes
-- a row out of the source -- the source stays whole and ATTACHED until the swap, so every row remains
-- visible through the parent the entire time. The product has no dead tuples (the fine children only ever
-- receive inserts) and no vacuum (the source's space is reclaimed by the DROP, not by DELETE). Because the
-- rows are never moved through an unattached child, regrain NEVER opens the snapshot() read gap, and the
-- multi-tick COPY needs no FK leash (only a delete-and-move design would need one) -- REDESIGN.md
-- sections 9 and 10. The one exception is the swap's DETACH itself: Postgres refuses to detach a partition
-- whose rows are still referenced by an incoming FK (the keys leave the parent between detach and the
-- re-attach of the copies, which it will not look past), so the swap transiently drops the incoming FK(s)
-- and re-adds them within its ONE atomic transaction -- invisible to other sessions, so RI is never visibly
-- off, unlike the move-model's whole-regrain suspension. Retention-aware: a sub-range entirely below the
-- retention horizon is NOT copied (it is discarded with the source at the DROP), so retention costs no delete.
-- The swap re-checks each such sub-range against the horizon in force at that moment and refuses if one is
-- no longer below it (#448), so a retain loosened mid-regrain cannot turn that discard into data loss.
--
-- The work is a series of resumable microbatches (regrain_step). Because the source is frozen and is never
-- deleted from, it cannot drive progress the way a shrinking source would, so progress is tracked
-- explicitly by config.regrain_cursor: the native-grid lo of the sub-range currently being copied. A child is
-- built to completion (one budget batch at a time, resumed from its own high-water mark) before the cursor
-- advances to the next sub-range; when the cursor reaches the coarse hi every sub-range is copied (or aged
-- and skipped) and the swap runs. regrain() loops regrain_step in ONE transaction (atomic, gap-free) -- the
-- operator's "do it now". maintain() calls regrain_step ONCE per tick when auto-regrain is on (REDESIGN.md sec
-- 12), feathering the copy under the live workload across ticks. The cross-tick path leaves copies in
-- not-yet-attached children between ticks, but since the source still holds those rows, the parent's count
-- is never short and snapshot() must NOT union those copies (it would double-count).

-- ===================== regrain change capture and reconcile (issue #267) =====================
--
-- regrain COPIES, and its copy is resume-safe three ways: a `>= max(dest.ctl)` high-water bound, a
-- `not exists` anti-join on the reused key, and a cursor that advances past a completed sub-range and
-- never returns. NONE of the three is a reconcile -- the copy only ever ADDS rows and only ever moves
-- FORWARD -- and the swap then drops the source, so without this apparatus the copy silently becomes the
-- authority for everything that changed after it ran: a committed INSERT is destroyed, a committed DELETE
-- comes back, a committed UPDATE reverts.
--
-- "Frozen" (regrain_step's precondition) does NOT mean immutable: it only says the write frontier has
-- moved past the child. A backdated INSERT or an explicit low id routes straight into it, a
-- cross-partition UPDATE can move a row in, and DELETE/payload-UPDATE of history never involved the
-- frontier at all. So capture must be correct however much arrives, not merely for a well-behaved
-- append-only workload.
--
-- Shape: the delta table and its trigger function are PER PARENT and persistent; only the trigger on the
-- source child is per regrain. Lifecycle therefore reduces to rows, not relations, and an abandoned regrain
-- leaks a trigger the janitor removes rather than an orphan table. They are NAMED from the parent (naming
-- from the child would break, since #266's fix renames the source mid-flight) but FOUND by identity (#496):
-- the prepare tick records their oids in pgpm.config and every reader resolves them from there, because the
-- parent's name is not stable either. An operator's ALTER TABLE ... RENAME mid-regrain used to leave the
-- trigger writing the delta it was given while the reconcile, the swap gate and the swap all derived a fresh
-- name from the new relname, found nothing, counted 0 pending and swapped: every change captured since the
-- copy went with the source. The delta is also RE-MINTED at every prepare rather than reused: its columns are
-- the key as of that regrain and the trigger function is generated from the key as it is now, so a key
-- column renamed between two regrains made every write into the source raise for the life of the next one
-- while the old delta was kept.

-- The names this parent's capture relations are MINTED under: derived from the parent's current relname.
-- Only _regrain_capture_install creates under these; every other caller goes through
-- _regrain_capture_names, which prefers what pgpm.config recorded.
--
-- #655: never cut to 63 bytes. They used to be left(<rel> || suffix, 63), and for a parent named 63 bytes
-- (an ALTER TABLE ... RENAME to anything that long lands there, since PostgreSQL cuts it) that is the
-- PARENT'S OWN NAME. A parent that never regrained has nothing recorded, so the readers fell back to it:
-- regrain_cancel TRUNCATEd the managed table, untransmute DROPped the restored one, and uninstall.sql
-- DROPped it with every partition. When <rel>_pgpm_regrain_delta or <rel>_pgpm_regrain_capture does not
-- fit, the name is pgpm_regrain_delta_<parent oid> or pgpm_regrain_capture_<parent oid> instead: whole, at
-- most 31 bytes, one per parent, and never the name of the parent or of one of its partitions (the form is
-- taken only for a parent name over 42 bytes, and theirs start with it). Refusing instead would have
-- stopped every parent over 42 bytes from regraining at all, where the cut forms worked at every length
-- but one; the readers find the relations by oid either way (#496), so the name only has to fit and be
-- pgpm's.
create or replace function pgpm._regrain_capture_derive(
  p_parent regclass, out nsp name, out delta name, out fn name
) returns record language plpgsql stable as $$
declare v_rel name;
begin
  select n.nspname, c.relname into nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  if v_rel is null then return; end if;   -- a parent dropped without untransmute: nothing to name
  delta := case when octet_length(v_rel || '_pgpm_regrain_delta') <= 63 then v_rel || '_pgpm_regrain_delta'
                else 'pgpm_regrain_delta_' || p_parent::oid end;
  fn    := case when octet_length(v_rel || '_pgpm_regrain_capture') <= 63 then v_rel || '_pgpm_regrain_capture'
                else 'pgpm_regrain_capture_' || p_parent::oid end;
end;
$$;

-- The parent's LIVE capture relations, by identity (#496): the delta and the function whose oids the prepare
-- tick recorded in pgpm.config, under whatever names they carry now. Falls back to the derived names when
-- nothing is recorded, which is a parent that has never regrained (its readers then find no relation and
-- count 0) or a capture minted before the oids were recorded (it sits under the derived name, and a legacy
-- trigger writes there); and likewise when a recorded relation is gone (dropped by hand), since the derived
-- name is where the next prepare will mint. The two are resolved independently, so a function dropped by
-- hand does not lose the delta.
create or replace function pgpm._regrain_capture_names(
  p_parent regclass, out nsp name, out delta name, out fn name
) returns record language plpgsql stable as $$
declare cfg record; v_nsp name; v_rel name;
begin
  select d.nsp, d.delta, d.fn into nsp, delta, fn from pgpm._regrain_capture_derive(p_parent) d;
  select regrain_delta_oid, regrain_capture_fn_oid into cfg from pgpm.config where parent_table = p_parent;
  if not found then return; end if;
  if cfg.regrain_delta_oid is not null then
    select n.nspname, c.relname into v_nsp, v_rel
      from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = cfg.regrain_delta_oid;
    if found then nsp := v_nsp; delta := v_rel; end if;
  end if;
  if cfg.regrain_capture_fn_oid is not null then
    select p.proname into v_rel from pg_proc p
     where p.oid = cfg.regrain_capture_fn_oid and p.pronamespace = (select oid from pg_namespace where nspname = nsp);
    if found then fn := v_rel; end if;
  end if;
end;
$$;

-- Upgrade path (#496): an install that predates the two anchor columns found its capture relations by name
-- alone. Record them now for every parent whose derived-name delta exists, so a regrain in flight across
-- this upgrade is anchored from here on and a later prepare knows the delta it finds is this parent's own.
-- Only rows with nothing recorded, so a re-run changes nothing.
--
-- The names looked for are the ones those releases MINTED under, left(<rel> || suffix, 63), not what
-- _regrain_capture_derive says now (#655): for a parent over 44 bytes the two differ, and a regrain in
-- flight across the upgrade has its trigger writing the cut name. Only a plain table that is not a
-- partition is taken for a delta, because for a parent named 63 bytes the cut name is the parent itself,
-- and recording it as its own delta is the defect #655 removed.
do $$
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

-- TRUNCATE is the one write the row trigger cannot see (issue #449). It fires no row trigger, so a truncate
-- of the source mid-regrain leaves the delta empty, and TRUNCATE parent never reaches the standalone copies
-- (they are not partitions until the swap), so the swap would attach copies of every row the operator just
-- removed: 9,999 rows back from the dead in the hunt that found it. Refuse it instead, the way the write
-- ceiling does: loud refusal over silent divergence. This is the function behind a BEFORE TRUNCATE
-- statement trigger that _regrain_capture_install puts on the source child beside the row trigger and that
-- every teardown of the row trigger (swap, regrain_cancel, the janitor) removes with it, so its presence IS
-- the in-flight marker and it needs no state of its own. BEFORE, so the whole statement fails before
-- anything is truncated. TRUNCATE parent cascades to the source as a partition and fires the partition's
-- own statement trigger, so both spellings are refused. Installed ENABLE ALWAYS: an ordinary trigger is
-- skipped under session_replication_role = replica, and a truncate slipping past there would be the same
-- resurrection. One shared function rather than a per-parent one: the message needs nothing the trigger
-- context does not already carry, and the parent is one pg_inherits lookup away.
create or replace function pgpm._regrain_truncate_guard() returns trigger
language plpgsql as $$
declare v_parent text;
begin
  select i.inhparent::regclass::text into v_parent from pg_inherits i where i.inhrelid = tg_relid;
  raise exception 'pg_partition_magician: cannot TRUNCATE %.% -- a regrain is in flight on it (parent %). TRUNCATE fires no row trigger, so the rows it removes cannot be captured, and the swap would attach copies of them. Cancel the regrain first with pgpm.regrain_cancel(%), or truncate after the swap completes.',
    tg_table_schema, tg_table_name, coalesce(v_parent, '?'), coalesce(v_parent, '<parent>');
end;
$$;

-- Put the #449 guard on an in-flight source that lacks it (issue #650), returning whether it did. The prepare
-- tick installs the guard, but prepare runs only when the capture trigger is absent, so a source carrying
-- capture and no guard stayed unguarded until its swap: a regrain begun under 0.6.0 (whose prepare installed
-- none) and resumed after the upgrade, or a guard dropped by hand. TRUNCATE then went through and the swap
-- attached copies of every truncated row. Called from the two places that meet such a source first:
-- install.sql's upgrade path (below _regrain_capture_active), before any tick runs, and every resuming tick
-- of regrain_step. Only when missing, so a steady tick issues no DDL and takes no SHARE ROW EXCLUSIVE on the
-- source; installed exactly as _regrain_capture_install does it, ENABLE ALWAYS included.
create or replace function pgpm._regrain_truncate_guard_ensure(p_child regclass)
returns boolean language plpgsql as $$
begin
  if exists (select 1 from pg_trigger where tgrelid = p_child and tgname = 'pgpm_regrain_truncate_guard') then
    return false;
  end if;
  execute format('create trigger pgpm_regrain_truncate_guard before truncate on %s for each statement execute function pgpm._regrain_truncate_guard()',
                 p_child::text);
  execute format('alter table %s enable always trigger pgpm_regrain_truncate_guard', p_child::text);
  return true;
end;
$$;

-- Give the parent's writers INSERT on the delta (#496). The capture trigger inserts into the delta with the
-- WRITER's privileges: pgpm has no SECURITY DEFINER anywhere, and the delta used to be created by whoever
-- ran the tick, with no grants, so every non-owner role holding DML on the parent got 42501 on every write
-- into the regraining child for the life of the regrain. Every grantee of INSERT, UPDATE or DELETE on the
-- parent, table- or column-level (PUBLIC included), gets INSERT on the delta; the owner's implicit rights
-- come from _own_like_parent, called beside this. Grants only what is missing, so a steady-state tick
-- issues no DDL, and regrain_step calls it on every tick so a grant made mid-regrain is honoured from the
-- next one.
create or replace function pgpm._regrain_capture_grant(p_parent regclass, p_delta regclass)
returns void language plpgsql as $$
declare r record;
begin
  for r in
    select g.grantee
      from (select a.grantee from pg_class c cross join lateral aclexplode(c.relacl) a
             where c.oid = p_parent and c.relacl is not null
               and a.privilege_type in ('INSERT', 'UPDATE', 'DELETE')
            union
            select a.grantee from pg_attribute att cross join lateral aclexplode(att.attacl) a
             where att.attrelid = p_parent and att.attnum > 0 and not att.attisdropped and att.attacl is not null
               and a.privilege_type in ('INSERT', 'UPDATE')) g
     where not exists (select 1 from pg_class d cross join lateral aclexplode(d.relacl) b
                        where d.oid = p_delta and d.relacl is not null
                          and b.grantee = g.grantee and b.privilege_type = 'INSERT')
  loop
    execute format('grant insert on %s to %s', p_delta::text,
                   case when r.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(r.grantee)) end);
  end loop;
end;
$$;

-- Install capture for a regrain of p_child: mint the per-parent delta table and trigger function (tearing
-- down what an earlier regrain of this parent left, by the oids pgpm.config recorded) and put the trigger on
-- the source child. CREATE TRIGGER takes SHARE ROW EXCLUSIVE, which conflicts with ROW EXCLUSIVE, so
-- in-flight DML blocks the install and DML afterwards sees the trigger: once this commits nothing can have
-- slipped past uncaptured. That lock is why this is its own tick -- sharing a transaction with a copy batch
-- would hold it across the batch instead of for an O(1) statement.
create or replace function pgpm._regrain_capture_install(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_delta name; v_fn name; v_delta_reg regclass; v_taken regclass; v_taken_fn regprocedure;
  v_keyidx oid; v_keycols_q text; v_newvals_q text; v_oldvals_q text; v_bad_q text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  select nsp, delta, fn into v_nsp, v_delta, v_fn from pgpm._regrain_capture_derive(p_parent);

  select coalesce(
           (select i.indexrelid from pg_index i where i.indrelid = p_parent and i.indisprimary limit 1),
           (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
             where con.conrelid = p_parent and con.contype = 'u'
               and i.indpred is null and i.indexprs is null limit 1))
    into v_keyidx;
  if v_keyidx is null then
    raise exception 'pg_partition_magician: cannot capture regrain changes on % -- no primary key or unique constraint', p_parent;
  end if;

  -- A NULL key component can never be matched by the row-constructor reconcile below, so its change would
  -- be silently lost -- the exact failure this apparatus exists to prevent. PK columns are NOT NULL, but a
  -- reused UNIQUE key may legitimately permit nulls, so refuse rather than lose the change.
  select string_agg(quote_ident(a.attname), ', ') into v_bad_q
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indexrelid = v_keyidx and not a.attnotnull;
  if v_bad_q is not null then
    raise exception 'pg_partition_magician: cannot regrain % -- its reused key has nullable column(s) (%), and a NULL key component cannot be reconciled, so a concurrent change to such a row would be lost. Add NOT NULL to those columns, then re-run.',
      p_parent, v_bad_q;
  end if;

  select string_agg(quote_ident(a.attname), ', ' order by k.ord),
         string_agg('new.' || quote_ident(a.attname), ', ' order by k.ord),
         string_agg('old.' || quote_ident(a.attname), ', ' order by k.ord)
    into v_keycols_q, v_newvals_q, v_oldvals_q
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indexrelid = v_keyidx;

  -- The names are the parent's current relname plus a suffix, and a relation already under one of them that
  -- is not the one this parent recorded is somebody else's (#496): refuse rather than adopt it. Before,
  -- whatever sat under the derived name was taken for the delta and TRUNCATED.
  v_taken := to_regclass(format('%I.%I', v_nsp, v_delta));
  if v_taken is not null and v_taken::oid is distinct from cfg.regrain_delta_oid then
    raise exception 'pg_partition_magician: cannot regrain % -- change capture would mint its delta table as %.%, and that name is held by relation % (oid %), which this parent did not mint. Drop or rename that relation, then re-run.',
      p_parent, quote_ident(v_nsp), quote_ident(v_delta), v_taken::text, v_taken::oid;
  end if;
  v_taken_fn := to_regprocedure(format('%I.%I()', v_nsp, v_fn));
  if v_taken_fn is not null and v_taken_fn::oid is distinct from cfg.regrain_capture_fn_oid then
    raise exception 'pg_partition_magician: cannot regrain % -- change capture would mint its trigger function as %.%(), and that name is held by function % (oid %), which this parent did not mint. Drop or rename that function, then re-run.',
      p_parent, quote_ident(v_nsp), quote_ident(v_fn), v_taken_fn::text, v_taken_fn::oid;
  end if;

  -- Tear down the previous regrain's relations, by identity, and mint fresh ones (#496). Fresh, not reused:
  -- the delta's columns are the key as of THIS regrain and the trigger function below inserts the current
  -- key's column names, so keeping a delta minted under an earlier key (a key column renamed in between)
  -- made every write into the source raise for the life of the regrain. Dropping by recorded oid rather than
  -- by name is what reaches a delta left under an earlier relname of the parent. The function first: nothing
  -- depends on the delta, and no trigger can reference the function here, since regrain_step has already
  -- refused a second in-flight regrain on this parent.
  if exists (select 1 from pg_proc where oid = cfg.regrain_capture_fn_oid) then
    execute format('drop function %s', cfg.regrain_capture_fn_oid::regprocedure::text);
  end if;
  if exists (select 1 from pg_class where oid = cfg.regrain_delta_oid) then
    execute format('drop table %s', cfg.regrain_delta_oid::regclass::text);
  end if;
  execute format('create table %I.%I as select %s from %s with no data', v_nsp, v_delta, v_keycols_q, p_parent::text);
  -- monotonic ordering column so a reconcile pass can batch the oldest captures first: a batch is the
  -- first N eligible rows by pgpm_seq that ONE snapshot can see, and the pass consumes exactly those rows
  -- (#497), never "everything at or below a watermark". The value is assigned when the trigger fires,
  -- inside the writer's transaction, so a row can commit later than rows carrying higher values; a
  -- pass addresses the delta by the identity of the rows it saw, and a late-committing row waits for
  -- the next pass. Excluded by name wherever key columns are introspected.
  execute format('alter table %I.%I add column pgpm_seq bigint generated always as identity', v_nsp, v_delta);
  execute format('create index on %I.%I (pgpm_seq)', v_nsp, v_delta);
  v_delta_reg := format('%I.%I', v_nsp, v_delta)::regclass;
  -- The trigger runs as the WRITER, so the delta is owned like the parent and every role that can write the
  -- parent gets INSERT on it (#496; see _regrain_capture_grant).
  perform pgpm._own_like_parent(p_parent, v_delta_reg);
  perform pgpm._regrain_capture_grant(p_parent, v_delta_reg);

  execute format('create or replace function %I.%I() returns trigger language plpgsql as $pgpm$
    begin
      if tg_op = ''DELETE'' then
        insert into %I.%I (%s) values (%s); return old;
      elsif tg_op = ''UPDATE'' then
        insert into %I.%I (%s) values (%s), (%s); return new;   -- old + new: a key change dirties both
      else
        insert into %I.%I (%s) values (%s); return new;
      end if;
    end $pgpm$',
    v_nsp, v_fn,
    v_nsp, v_delta, v_keycols_q, v_oldvals_q,
    v_nsp, v_delta, v_keycols_q, v_oldvals_q, v_newvals_q,
    v_nsp, v_delta, v_keycols_q, v_newvals_q);

  execute format('drop trigger if exists pgpm_regrain_capture on %I.%I', v_nsp, p_child);
  execute format('create trigger pgpm_regrain_capture after insert or update or delete on %I.%I for each row execute function %I.%I()',
                 v_nsp, p_child, v_nsp, v_fn);
  -- ENABLE ALWAYS (#450). CREATE TRIGGER leaves a trigger origin-only, which a session running as
  -- session_replication_role = replica (a logical-replication apply worker, a loader silencing triggers)
  -- skips. That default is for triggers that are replication side effects; this one is what keeps a
  -- mid-regrain write from being reverted, lost or resurrected by the swap, and a change it does not see
  -- is a change the reconcile cannot honour. Re-created per regrain, so a regrain begun after the upgrade
  -- gets it without a repair step; one already in flight keeps its origin-only trigger until it swaps.
  execute format('alter table %I.%I enable always trigger pgpm_regrain_capture', v_nsp, p_child);
  -- #449: TRUNCATE fires no row trigger, so it is refused for as long as the row trigger is up (see
  -- _regrain_truncate_guard). Same lock, same tick, torn down wherever the row trigger is.
  execute format('drop trigger if exists pgpm_regrain_truncate_guard on %I.%I', v_nsp, p_child);
  execute format('create trigger pgpm_regrain_truncate_guard before truncate on %I.%I for each statement execute function pgpm._regrain_truncate_guard()',
                 v_nsp, p_child);
  execute format('alter table %I.%I enable always trigger pgpm_regrain_truncate_guard', v_nsp, p_child);
  -- Record what was minted, by oid (#496): every reader resolves the delta and the function through
  -- pgpm.config from here on, so a rename of the parent mid-regrain changes what _regrain_capture_derive
  -- would say and nothing else.
  update pgpm.config
     set regrain_delta_oid      = v_delta_reg::oid,
         regrain_capture_fn_oid = format('%I.%I()', v_nsp, v_fn)::regprocedure::oid
   where parent_table = p_parent;
end;
$$;

-- true iff p_child currently carries the capture trigger. Schema matched by OID, not by re-parsing its
-- name (#512, same defect and fix as _is_write_blocked).
create or replace function pgpm._regrain_capture_active(p_parent regclass, p_child name)
returns boolean language plpgsql stable as $$
declare v_nsp_oid oid;
begin
  select c.relnamespace into v_nsp_oid from pg_class c where c.oid = p_parent;
  return exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                  where t.tgname = 'pgpm_regrain_capture' and c.relname = p_child
                    and c.relnamespace = v_nsp_oid);
end;
$$;

-- Upgrade path (#650): a regrain in flight across the upgrade has a source carrying the capture trigger and,
-- from a release before #449, no TRUNCATE guard. Put the guard on every such source now, so a TRUNCATE
-- between this upgrade and the regrain's next tick is refused too; the tick would put it back itself (see
-- regrain_step), but only from that tick on. Only a managed, attached child with capture active is touched,
-- and _regrain_truncate_guard_ensure leaves a present guard alone, so a re-run changes nothing.
do $$
declare r record;
begin
  for r in
    select c.oid::regclass as child
      from pgpm.part p join pg_class pc on pc.oid = p.parent_table
      join pg_class c on c.relname = p.child_name and c.relnamespace = pc.relnamespace
     where p.attached and pgpm._regrain_capture_active(p.parent_table, p.child_name)
  loop
    perform pgpm._regrain_truncate_guard_ensure(r.child);
  end loop;
end $$;

-- how many captured changes are still outstanding (used by the swap gate and by status)
create or replace function pgpm._regrain_delta_count(p_parent regclass)
returns bigint language plpgsql stable as $$
declare v_nsp name; v_delta name; v_n bigint;
begin
  select nsp, delta into v_nsp, v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return 0; end if;
  execute format('select count(*) from %I.%I', v_nsp, v_delta) into v_n;
  return v_n;
end;
$$;

-- ...and how many of them lie in [p_lo, p_hi): the swap's pre-drop check (#447). Range-scoped, unlike the
-- gate's count above, because a cross-partition UPDATE's NEW key can sit outside the child being split
-- (see _regrain_delta_purge), and that key is not this swap's to apply. Compared in ENCODED space
-- against _encode'd boundaries, as the purge and the reconcile do, so the control column's own type
-- does the comparing.
create or replace function pgpm._regrain_delta_count(p_parent regclass, p_lo text, p_hi text)
returns bigint language plpgsql stable as $$
declare cfg pgpm.config; v_nsp name; v_delta name; v_n bigint;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  select nsp, delta into v_nsp, v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return 0; end if;
  execute format('select count(*) from %I.%I where %3$s >= %4$L and %3$s < %5$L',
                 v_nsp, v_delta, quote_ident(cfg.control_column),
                 pgpm._encode(cfg.control_kind, p_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz),
                 pgpm._encode(cfg.control_kind, p_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz))
    into v_n;
  return v_n;
end;
$$;

-- Discard captured keys whose control has left this child's range: a cross-partition UPDATE moved the row
-- out, and its OLD-key entry (still in range) already covers the removal here. Such an entry can never
-- apply AND can never become eligible, so leaving it forever would wedge the swap gate, which counts every
-- delta row.
--
-- Deliberately NOT part of the per-tick reconcile. The predicate is a negated range, which no index serves,
-- so running it per tick meant a seq scan of the whole delta on every tick -- O(delta) work per tick and
-- O(delta^2 / batch) overall, which is the same shape #272 removed from the watermark query and which the
-- bench/regrain_perf.sh guard caught still present here. It is only the swap gate that these rows can
-- affect, so it runs once, immediately before that gate.
create or replace function pgpm._regrain_delta_purge(p_parent regclass, p_lo text, p_hi text)
returns void language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_delta name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select delta into v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return; end if;
  execute format('delete from %I.%I where not (%3$s >= %4$L and %3$s < %5$L)',
                 v_nsp, v_delta, quote_ident(cfg.control_column),
                 pgpm._encode(cfg.control_kind, p_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz), pgpm._encode(cfg.control_kind, p_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz));
end;
$$;

-- Reconcile up to p_batch captured keys, returning how many were consumed.
--
-- The delta is ANALYZEd when it has never been, reltuples < 0, and not `<= 0` (#710): ANALYZE of an EMPTY
-- delta records reltuples = 0, so the old test re-ANALYZEd it on every step for as long as it stayed empty,
-- each time taking SHARE UPDATE EXCLUSIVE on it. An analyzed empty delta is ANALYZEd once more when a row has
-- arrived (reltuples = 0 and a row present): the planner scales its row count from the delta's size, but the
-- empty table's column statistics misplan the first tick over a full delta into seq scans of it
-- (bench/regrain_perf.sh); after that one ANALYZE the estimate keeps up as the delta grows.
-- TRUNCATE (regrain_cancel) resets reltuples to -1, so each run still analyzes its delta once.
--
-- THE CONTRACT: for each captured key the SOURCE is the authority, not the recorded change. Delete the
-- key's row from its fine child, then reinsert the source's current row for that key if it still exists.
-- One rule covers all three defects, and critically it covers keys the copy has NEVER SEEN, which the
-- INSERT case needs and which any replay-the-change design would miss. It is idempotent and
-- order-independent per key, which is what makes it safe under READ COMMITTED: a synchronous
-- apply-the-change trigger is not, because it can fire against a copy that does not hold the row yet and
-- then be overwritten by a copy statement running from an earlier snapshot.
--
-- ELIGIBILITY: only keys whose control value lies strictly BELOW the cursor, i.e. in a sub-range the copy
-- has already finished. Two reasons. The copy can still reach anything at or above the cursor by itself,
-- so reconciling there is wasted work; and writing into the sub-range currently being copied would move
-- max(dest.ctl), which the copy uses as its resume point, making it skip the rows in between. At the swap
-- the cursor is at hi, so everything becomes eligible.
create or replace function pgpm._regrain_reconcile(
  p_parent regclass, p_child name, p_lo text, p_hi text, p_step text, p_cursor text, p_batch int
) returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_delta name; v_ncast text; v_keycols_q text; v_dkey_q text;
  v_skey_q text; v_cols_q text; v_seqs bigint[]; v_elig text; v_ctl_q text; v_sub_name name; v_n int := 0; r record;
  v_sub_rel regclass;     -- the fine child pgpm.part recorded, never whatever bears its name (#723)
  v_kctl_native_q text;   -- a delta row's control value, read as a NATIVE grid value (#455)
  v_lo_lit text; v_hi_lit text; v_cur_lit text; v_sub_lo text; v_sub_hi text; v_boundary text;
  v_reltuples real; v_delta_has_rows boolean;   -- the delta's row estimate, and whether it holds a row (#710)
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  select n.nspname into v_nsp
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select delta into v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return 0; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  select string_agg(quote_ident(attname), ', ' order by attnum),
         '(' || string_agg('d.' || quote_ident(attname), ', ' order by attnum) || ')',
         '(' || string_agg('s.' || quote_ident(attname), ', ' order by attnum) || ')'
    into v_keycols_q, v_dkey_q, v_skey_q
    from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
      and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';
  -- generated columns are omitted from the reinsert: they recompute, they are never inserted into
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped and attgenerated = '';

  -- The delta is populated by a trigger and nothing analyzes it, so on its first ticks it carries no usable
  -- row estimate and the planner misplans one of the statements below into a seq scan of the WHOLE delta.
  -- Measured: 1 seq scan reading every delta row per tick without stats, 0 with them. Same failure #164
  -- fixed for freshly minted children ("it sits at reltuples = -1 until autovacuum, and anything touching
  -- it misplans"), so it gets the same treatment. One-time: once analyzed the estimate stays good enough
  -- as the delta grows (47k estimated against 50k actual still planned correctly).
  -- Never analyzed is `< 0`, not `<= 0` (#710, see above). Analyzed while EMPTY (reltuples = 0) is analyzed
  -- once more when a row has arrived: the statistics of an empty table misplan the first tick over a full
  -- delta into seq scans of it (bench/regrain_perf.sh measured five scans of a 50,000-row delta on the
  -- `< 0` test alone), and after that one ANALYZE the estimate keeps up as the delta grows.
  select coalesce(reltuples, -1) into v_reltuples
    from pg_class where oid = format('%I.%I', v_nsp, v_delta)::regclass;
  if v_reltuples = 0 then
    execute format('select exists (select 1 from %I.%I)', v_nsp, v_delta) into v_delta_has_rows;
  end if;
  if v_reltuples < 0 or (v_reltuples = 0 and v_delta_has_rows) then
    perform pgpm._analyze(format('%I.%I', v_nsp, v_delta)::regclass);
  end if;

  -- Compare in ENCODED space -- the control column's own type, against _encode'd boundaries -- exactly as
  -- the copy does with its v_lo_lit/v_hi_lit. Decoding per row instead (pgpm._decode(...)::native) is a
  -- function call the planner cannot index, which silently turned every reconcile tick into a seq scan of
  -- the WHOLE delta rather than an indexed read of one batch: measured 272 ms to pick 5000 rows out of a
  -- 300k delta, against 1.0 ms once the pgpm_seq index is usable. That made the tick scale with the delta
  -- instead of with the budget, so draining a large delta cost O(delta^2 / batch). uuidv7 compares
  -- correctly this way because a UUIDv7 sorts by its embedded timestamp, which is why the copy can do it too.
  v_ctl_q   := quote_ident(cfg.control_column);
  -- how a delta row's control value reads as a native grid value, per row (#455): a naive column is wall
  -- time in partition_tz (the rule _col_to_native applies one value at a time), anything else its own text.
  -- An instant is rendered through _ts_text, never a bare ::text (#570): _grid_floor parses the text back
  -- with ::timestamptz, and under a DateStyle that renders zone abbreviations (SQL, Postgres) that round
  -- trip is not the identity. Asia/Kolkata renders 'IST', which the default timezone_abbreviations read
  -- as Israel (+02), so every key read 3.5 hours late, a captured DELETE was applied to a fine child up
  -- the range and consumed, and the swap attached the real child still holding the deleted row. The
  -- other kinds' columns (numeric, uuid, text) render the same under every DateStyle and stay ::text.
  v_kctl_native_q := case when pgpm._control_naive(p_parent, cfg.control_column)
                          then format('pgpm._ts_text(k.%I::timestamp at time zone %L)', cfg.control_column, cfg.partition_tz)
                          when cfg.control_kind = 'time'
                          then format('pgpm._ts_text(k.%I)', cfg.control_column)
                          else format('k.%I::text', cfg.control_column) end;
  v_lo_lit  := pgpm._encode(cfg.control_kind, p_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);
  v_hi_lit  := pgpm._encode(cfg.control_kind, p_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);
  v_cur_lit := pgpm._encode(cfg.control_kind, p_cursor, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);

  -- eligible: in this child's range AND behind the cursor
  v_elig := format('%1$s >= %2$L and %1$s < %3$L and %1$s < %4$L', v_ctl_q, v_lo_lit, v_hi_lit, v_cur_lit);

  -- ONE snapshot decides the batch (#497). pgpm_seq is an identity column, assigned when the capture
  -- trigger fires INSIDE the writer's transaction, so a row can commit later than rows that already
  -- carry higher values: a writer that captured a change and then held its transaction open across
  -- this tick commits a row whose pgpm_seq is below everything the batch was cut from. Every statement
  -- below runs under READ COMMITTED in its own snapshot, so a batch described by a watermark
  -- ("pgpm_seq <= wm and eligible") was a different set of rows in each of them: the apply statements
  -- could not see that late-committing row, the final delete could, and it took the row unapplied. The
  -- fine child kept the pre-change row and the swap attached it: a committed UPDATE reverted, measured.
  -- So the batch is materialised here as the pgpm_seq values of the eligible rows visible NOW, and every
  -- later statement, the final delete included, addresses the delta by that set and nothing else. A
  -- delta row is never updated, only inserted and (here) deleted, so a row in the set stays visible to
  -- every statement of this tick; a row not in the set is neither applied nor consumed, and waits for
  -- the next tick, which is the tick that applies it.
  execute format('select array_agg(pgpm_seq) from (select pgpm_seq from %I.%I where %s order by pgpm_seq limit %s) t',
                 v_nsp, v_delta, v_elig, greatest(p_batch, 1)) into v_seqs;
  if v_seqs is null then return 0; end if;

  -- one pair of set-based statements per distinct fine child touched, not per key
  for r in execute format(
    'select distinct pgpm._grid_floor(%L, %L, %L, pgpm._decode(%L, %s, %L, %L, %L, %L, %L, %L, %L), %L) as sub_lo
       from %I.%I k where k.pgpm_seq = any($1)',
    cfg.control_kind, p_step, cfg.partition_anchor, cfg.control_kind, v_kctl_native_q,
    cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit,
    cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz,
    v_nsp, v_delta) using v_seqs
  loop
    -- #446: find the fine child by RANGE in pgpm.part, never by re-rendering its name. regrain_step
    -- clamps the first sub-range to the coarse child's own lo when that lo is off the target grid (a
    -- weekly target on a monthly monolith; a 7000 target on a child starting at 20000) and names the
    -- child from the clamped value, so a name rendered from grid_floor(ctl) alone ([14000, 21000) ->
    -- _p14000) belongs to a child that never existed. This loop used to take "no such relation" for
    -- "skipped as aged", log it, and delete the captured keys anyway; the swap then dropped the source
    -- with them, so every UPDATE in that sub-range reverted, every DELETE came back and every INSERT
    -- vanished. pgpm.part holds the authoritative bounds (the name is a label, see _part_name), so ask
    -- it which child of this regrain contains the sub-range. The probe point is the sub-range's lo as
    -- regrain_step clamps it, which every eligible key in this group lies at or above; the source itself
    -- contains that point too and is excluded by name.
    v_sub_lo := case when pgpm._native_gt(cfg.control_kind, p_lo, r.sub_lo) then p_lo else r.sub_lo end;
    v_sub_hi := pgpm._grid_next(cfg.control_kind, p_step, r.sub_lo, cfg.partition_tz);
    if pgpm._native_gt(cfg.control_kind, v_sub_hi, p_hi) then v_sub_hi := p_hi; end if;
    select child_name into v_sub_name from pgpm.part
     where parent_table = p_parent and child_name <> p_child
       and not pgpm._native_gt(cfg.control_kind, p_lo, lo)        -- p_lo <= lo: a child of this regrain,
       and not pgpm._native_gt(cfg.control_kind, hi, p_hi)        -- hi <= p_hi   attached or not
       and not pgpm._native_gt(cfg.control_kind, lo, v_sub_lo)    -- lo <= sub_lo: it contains the probe
       and pgpm._native_gt(cfg.control_kind, hi, v_sub_lo);       -- sub_lo < hi
    if v_sub_name is null then
      -- No fine child. The one legitimate reason is that regrain_step skipped the sub-range as aged
      -- (regrain_aged): it is never materialized and its rows go with the source, so there is nothing to
      -- reconcile into and the captured keys are discarded. Counted, not silent. That is decided by the
      -- retention horizon, exactly as regrain_step decided it, and NOT by a relation's absence: a missing
      -- child for a sub-range that is not below the horizon is captured DML with nowhere to land, and
      -- discarding it is the loss above under another name. Refuse instead, so the tick fails loudly
      -- (maintain logs it as skip_regrain) and the delta keeps the keys. The horizon is read only on this
      -- path, and it only ever moves up, so a sub-range aged when regrain_step skipped it is still aged here.
      v_boundary := pgpm._retain_boundary(cfg);
      if v_boundary is null or pgpm._native_gt(cfg.control_kind, v_sub_hi, v_boundary) then
        raise exception 'pg_partition_magician: internal error reconciling % -- captured changes in sub-range [%, %) have no fine child to land in, and the range is not below the retention horizon (%); refusing rather than discarding them.',
          p_child, v_sub_lo, v_sub_hi, coalesce(v_boundary, 'no retention policy');
      end if;
      insert into pgpm.log (parent_table, action, lo, hi)
        values (p_parent, 'regrain_reconcile_aged', v_sub_lo, v_sub_hi);
      continue;
    end if;
    -- #723: the relation written is the one pgpm.part recorded for this fine child (child_oid, #421), and
    -- the tick refuses when its name now resolves to anything else. Both statements below used to write
    -- `%I.%I` of the name, so a completed copy renamed aside and an unrelated table created under its
    -- old name lost its row with a captured key and gained the managed table's. The refusal raises
    -- before either statement and before the delta is consumed, so every captured key waits for the
    -- tick after the copy has its name back.
    v_sub_rel := pgpm._regrain_copy_rel(p_parent, v_nsp, v_sub_name, 'reconcile captured changes into');
    execute format(
      'delete from %s d where %s in (select %s from %I.%I k where k.pgpm_seq = any($1)
          and pgpm._grid_floor(%L, %L, %L, pgpm._decode(%L, %s, %L, %L, %L, %L, %L, %L, %L), %L) = %L)',
      v_sub_rel::text, v_dkey_q, v_keycols_q, v_nsp, v_delta,
      cfg.control_kind, p_step, cfg.partition_anchor, cfg.control_kind, v_kctl_native_q,
      cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit,
      cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz, r.sub_lo)
      using v_seqs;
    execute format(
      'insert into %s (%s) select %s from %I.%I s where %s in (select %s from %I.%I k where k.pgpm_seq = any($1)
          and pgpm._grid_floor(%L, %L, %L, pgpm._decode(%L, %s, %L, %L, %L, %L, %L, %L, %L), %L) = %L)',
      v_sub_rel::text, v_cols_q, v_cols_q, v_nsp, p_child, v_skey_q, v_keycols_q, v_nsp, v_delta,
      cfg.control_kind, p_step, cfg.partition_anchor, cfg.control_kind, v_kctl_native_q,
      cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit,
      cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz, r.sub_lo)
      using v_seqs;
  end loop;

  -- consume exactly the rows the statements above addressed: by identity, never by watermark (#497)
  execute format('delete from %I.%I where pgpm_seq = any($1)', v_nsp, v_delta) using v_seqs;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into pgpm.log (parent_table, action, lo, hi, rows)
      values (p_parent, 'regrain_reconcile', p_lo, p_hi, v_n);
  end if;
  return v_n;
end;
$$;

-- The janitor (#267). Change capture is installed per regrain and normally dies with the source at the
-- swap, but a regrain can be abandoned silently, leaving a trigger that taxes every write to that child and
-- fills a delta nobody reads. The two abandonments it was built for are closed at their source now: a
-- second regrain on the same parent is refused rather than clobbering the shared cursor (#267), and
-- set_regrain(parent, null) mid-flight cancels the run outright through regrain_cancel (#516) rather than
-- leaving the cursor set, which this janitor read as "still live" and so never swept. What remains is the
-- backstop for a cursor cleared by any other route (a hand edit, say).
--
-- The child that legitimately carries capture is derivable with no extra state: the attached child whose
-- range covers regrain_cursor, and none at all when the cursor is null. `hi` is inclusive here because a
-- regrain awaiting its swap sits with the cursor exactly at hi. Deliberately conservative: it only tears
-- down capture it can prove is orphaned, never one that might still be live.
--
-- Mirrors _enforce_write_blocks: reconcile every child's state against current policy, once per tick.
-- Same per-child isolation as _enforce_write_blocks (issue #360), and for the same reason: the
-- `drop trigger` below takes a lock, and one child's failure to acquire it must not stop the janitor
-- from reaching every other child this tick. Logged as skip_regrain_capture, distinct from
-- skip_write_block, so pgpm.log does not conflate which of the two actually failed.
create or replace function pgpm._enforce_regrain_capture(p_parent regclass)
returns void language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_keep boolean; r record;
begin
  -- #706: judge only a regrain's COMMITTED marks, under the lock every regrain driver takes first (#554).
  -- Read without it, the cursor could predate a prepare that committed before the capture check below, and
  -- the janitor tore that live capture down as orphaned (logged regrain_capture_orphan), forcing a restart.
  -- Tried, not waited for: a driver holding the lock is a live regrain whose marks are its own, so this tick
  -- leaves them to it and logs the skip, and maintain's write blocks, done in the same step, are not lost to
  -- a lock wait.
  if not pgpm._regrain_try_lock(p_parent) then
    if exists (select 1 from pgpm.config where parent_table = p_parent) then
      insert into pgpm.log (parent_table, action, method)
        values (p_parent, 'skip_regrain_capture', 'a regrain driver holds pgpm.regrain_lock for this table; its capture is judged on a later tick');
    end if;
    return;
  end if;
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then return; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  for r in select child_name, lo, hi from pgpm.part where parent_table = p_parent
  loop
    begin
      if not pgpm._regrain_capture_active(p_parent, r.child_name) then continue; end if;
      v_keep := cfg.regrain_cursor is not null
            and not pgpm._native_gt(cfg.control_kind, r.lo, cfg.regrain_cursor)       -- lo <= cursor
            and not pgpm._native_gt(cfg.control_kind, cfg.regrain_cursor, r.hi);      -- cursor <= hi
      if not v_keep then
        execute format('drop trigger if exists pgpm_regrain_capture on %I.%I', v_nsp, r.child_name);
        execute format('drop trigger if exists pgpm_regrain_truncate_guard on %I.%I', v_nsp, r.child_name);   -- #449
        insert into pgpm.log (parent_table, action, lo, hi, method)
          values (p_parent, 'regrain_capture_orphan', r.lo, r.hi, r.child_name);
      end if;
    exception when others then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'skip_regrain_capture', r.lo, r.hi, left(sqlerrm, 200));
    end;
  end loop;
end;
$$;

-- Drop one not-yet-attached regrain copy and its pgpm.part row (#631). The relation dropped is the one
-- the row's child_oid recorded when regrain_step created it (#421), found by oid wherever it now sits and
-- whatever it is now called, never whatever currently bears the row's name: a copy renamed aside and an
-- unrelated table created under its old name made regrain_cancel's `drop table %I.%I` destroy the
-- stranger and leave the copy behind. A recorded oid that names nothing any more drops nothing (the copy
-- is already gone, and whatever holds the name is not it); a null child_oid predates the anchor and falls
-- back to the name, as every other identity check here lets an unanchored row through. Every path that
-- discards copies comes through here: regrain_cancel, regrain_step's restart of copies that predate
-- capture, and _regrain_reclaim when retention drops the source.
create or replace function pgpm._regrain_drop_copy(p_parent regclass, p_nsp name, p_child name)
returns void language plpgsql as $$
declare v_oid oid; v_rel regclass;
begin
  select child_oid into v_oid from pgpm.part
   where parent_table = p_parent and child_name = p_child and not attached;
  if v_oid is null then
    execute format('drop table if exists %I.%I', p_nsp, p_child);
  else
    select c.oid::regclass into v_rel from pg_class c where c.oid = v_oid;
    if v_rel is not null then
      execute format('drop table %s', v_rel::text);
    end if;
  end if;
  delete from pgpm.part where parent_table = p_parent and child_name = p_child and not attached;
end;
$$;

-- How the first of a regrain's copies whose columns differ from its parent's differs (#785), or null when
-- every copy matches. Each side's columns are compared as name, type, collation (when not the type's
-- own), NOT NULL and generated: the properties regrain_step's copy and reconcile statements and the
-- swap's ATTACH PARTITION depend on. Defaults, statistics targets and storage are not compared: the
-- copy's rows are inserted with explicit values and ATTACH does not ask. A copy is made LIKE its parent,
-- so the two differ only when the parent has been altered since; regrain_step restarts the run when they
-- do. One statement over every copy, comparing each relation's column list as one string, and the
-- difference spelt out for the first that differs only: asked on every resumed tick, and a run toward a
-- daily grid on a yearly partition has 365 copies (measured 4 ms for those, against 32 ms asking them
-- one call at a time). A recorded oid that names nothing has no columns here and is not compared.
create or replace function pgpm._regrain_shape_drift(p_parent regclass, p_copies oid[])
returns text language sql stable as $$
  with cols as (
    select a.attrelid,
           format('%I %s%s%s%s', a.attname, format_type(a.atttypid, a.atttypmod),
                  case when a.attcollation <> 0 and a.attcollation <> t.typcollation
                       then ' collate ' || a.attcollation::regcollation::text else '' end,
                  case when a.attnotnull then ' not null' else '' end,
                  case when a.attgenerated <> '' then ' generated' else '' end) as col
      from pg_attribute a join pg_type t on t.oid = a.atttypid
     where (a.attrelid = p_parent or a.attrelid = any(p_copies)) and a.attnum > 0 and not a.attisdropped
  ),
  sig as (select attrelid, string_agg(col, ', ' order by col) as s from cols group by attrelid),
  drifted as (
    select c.attrelid from sig c join sig p on p.attrelid = p_parent
     where c.attrelid <> p_parent and c.s is distinct from p.s
     order by c.attrelid limit 1
  )
  select concat_ws('; ', 'the parent has ' || g.s || ' and the copy ' || d.attrelid::regclass::text || ' does not',
                         'the copy ' || d.attrelid::regclass::text || ' has ' || l.s || ' and the parent does not')
    from drifted d
    cross join lateral (select string_agg(col, ', ' order by col) as s
                          from (select col from cols where attrelid = p_parent
                                except select col from cols where attrelid = d.attrelid) x) g
    cross join lateral (select string_agg(col, ', ' order by col) as s
                          from (select col from cols where attrelid = d.attrelid
                                except select col from cols where attrelid = p_parent) x) l;
$$;

-- Resolve one regrain copy, a not-attached pgpm.part row of p_parent named p_child, to the relation its
-- child_oid recorded when regrain_step created it (#421), refusing when the name no longer resolves to
-- that relation (#723, #707). The copy branch has checked this since #631; the reconcile and the swap
-- wrote and attached `%I.%I` of the recorded name, so a completed copy renamed aside and an unrelated
-- table created under its old name had a captured key's delete-and-reinsert applied to the stranger
-- (#723), and was attached in the copy's place while the source and its rows were dropped (#707: with
-- the squatter built LIKE the copy INCLUDING ALL it carries the `_ck` and the ATTACH goes through).
-- Refused rather than followed to wherever the oid now sits: attaching a relation under a name pgpm.part
-- does not record would leave the row describing something else, and renaming it back is the operator's
-- call, as in the copy branch. Every caller asks before it writes or attaches (the swap before its FK
-- suspend and DETACH, so before it locks anything), so the source stays attached and the delta keeps
-- every captured key. A null child_oid predates the anchor and
-- is resolved by name, as every other identity check here lets an unanchored row through. p_doing names
-- the step for the message.
create or replace function pgpm._regrain_copy_rel(p_parent regclass, p_nsp name, p_child name, p_doing text)
returns regclass language plpgsql stable as $$
declare v_oid oid; v_lo text; v_hi text; v_now regclass; v_parent_q text; v_was_q text;
begin
  select child_oid, lo, hi into v_oid, v_lo, v_hi from pgpm.part
   where parent_table = p_parent and child_name = p_child and not attached;
  v_now := to_regclass(format('%I.%I', p_nsp, p_child));
  if v_now is not null and (v_oid is null or v_now::oid = v_oid) then return v_now; end if;
  select format('%I.%I', n.nspname, c.relname) into v_parent_q
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select format('%I.%I', n.nspname, c.relname) into v_was_q
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = v_oid;
  raise exception 'pg_partition_magician: cannot % the regrain copy %.% of % for [%, %) -- that name resolves to %, and no longer names the copy this regrain created (oid %, now %). Writing into or attaching it would put this table''s rows in a relation pgpm does not own, so nothing was changed: the source stays attached and every captured change is kept. Give the copy its name back (rename or drop whatever holds the name first) and the next tick carries on, or abandon the regrain with pgpm.regrain_cancel(%), which drops the copy by its recorded oid.',
    p_doing, p_nsp, p_child, v_parent_q, v_lo, v_hi,
    coalesce('oid ' || v_now::oid::text, 'no relation'), coalesce(v_oid::text, 'not recorded'),
    coalesce(v_was_q, 'gone'), v_parent_q;
end;
$$;

-- Serialise everything that drives or reconfigures a regrain of p_parent (#554): regrain_step (and so
-- maintain's auto-regrain, regrain() and regrain_history()), regrain_cancel, set_regrain and
-- set_partition_tz all call this FIRST, before they read pgpm.config, and hold it to the end of their
-- transaction. Without it nothing in the regrain path held a per-parent lock across a step, so two
-- drivers could act on one run: a hand-driven regrain_step and a maintain tick computed their batches
-- from the same cursor and copied the same rows into the same fine child, the second dying on the
-- child's key once the first committed; a step that had read the run's state before a regrain_cancel
-- committed carried on from the state the cancel had torn down; and a setter judging "is a run in
-- flight" read around a prepare another session had not committed yet, and let the change through. With
-- it, the second caller waits for the first to commit and then reads what it left. A maintain tick waits
-- under its own lock_timeout like any other lock, so a long operator regrain() defers the tick
-- (skip_regrain, retried next tick) instead of racing it.
--
-- A row lock on pgpm.regrain_lock (see the table for why not the config row, and why not an advisory
-- lock). The row is created on first use; nothing for a parent pgpm does not manage, so the caller's own
-- "is not managed" refusal still speaks. Re-entrant: regrain() takes it and then calls regrain_step,
-- which takes it again in the same transaction, and set_regrain's #516 path calls regrain_cancel.
create or replace function pgpm._regrain_lock(p_parent regclass)
returns void language plpgsql as $$
begin
  insert into pgpm.regrain_lock (parent_table)
    select p_parent where exists (select 1 from pgpm.config where parent_table = p_parent)
  on conflict (parent_table) do nothing;
  perform 1 from pgpm.regrain_lock where parent_table = p_parent for update;
end;
$$;

-- _regrain_lock, tried rather than waited for (#706): true when this transaction holds it (taken now, or
-- already), false when another one does. For the janitor, which runs inside maintain's write-block step:
-- a wait there could only end in that step's lock_timeout and roll the write blocks back with it, and a
-- regrain holding the lock is live, so there is nothing for the janitor to judge until it lets go. The
-- row's first-use insert can itself wait on another session inserting it; that wait is the same "held".
create or replace function pgpm._regrain_try_lock(p_parent regclass)
returns boolean language plpgsql as $$
begin
  insert into pgpm.regrain_lock (parent_table)
    select p_parent where exists (select 1 from pgpm.config where parent_table = p_parent)
  on conflict (parent_table) do nothing;
  perform 1 from pgpm.regrain_lock where parent_table = p_parent for update skip locked;
  return found;
exception when lock_not_available then
  return false;
end;
$$;

-- Is a regrain of p_parent in flight? The three places a run leaves a mark, any one of which is enough:
-- the cursor, a not-yet-attached copy (only regrain inserts one, #94), or capture on a child. The same
-- three tests set_regrain's #516 branch makes. Asked by the setters that refuse to change what an
-- in-flight run was started under (#554, #660), after they have taken _regrain_lock, so a concurrent
-- step has either committed its marks or not started.
create or replace function pgpm._regrain_in_flight(p_parent regclass)
returns boolean language sql stable as $$
  select exists (select 1 from pgpm.config where parent_table = p_parent and regrain_cursor is not null)
      or exists (select 1 from pgpm.part where parent_table = p_parent and not attached)
      or exists (select 1 from pgpm.part p where p.parent_table = p_parent
                  and pgpm._regrain_capture_active(p_parent, p.child_name));
$$;

-- Stop an in-flight regrain and reclaim what it has built. Returns the number of in-flight fine children
-- dropped. The janitor above handles the silent abandonments; this is the operator's deliberate escape.
--
-- The copies MUST be dropped, not kept. Keeping them looks thriftier, but a later regrain would resume from
-- copies made before this cancel and therefore never reconciled, which is exactly the bug #267 closes. The
-- source still holds every row, so discarding them costs only the work, never data.
create or replace function pgpm.regrain_cancel(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_delta name; v_dropped int := 0; r record; v_rel regclass;
begin
  perform pgpm._regrain_lock(p_parent);   -- #554: waits for a step in flight, and holds the next one off
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- #707: from the relation each row's child_oid recorded (#421), wherever it now sits and whatever it is
  -- called, never from whatever bears the row's name. By name, a source renamed aside kept its capture
  -- trigger and TRUNCATE guard for good, and a relation that took its name lost its own triggers of
  -- those names. A recorded oid that names nothing any more has nothing to drop; a null child_oid
  -- predates the anchor and falls back to the name, as _regrain_drop_copy does.
  for r in select child_name, child_oid from pgpm.part where parent_table = p_parent loop
    if r.child_oid is null then
      v_rel := to_regclass(format('%I.%I', v_nsp, r.child_name));
    else
      select c.oid::regclass into v_rel from pg_class c where c.oid = r.child_oid;
    end if;
    continue when v_rel is null;
    execute format('drop trigger if exists pgpm_regrain_capture on %s', v_rel::text);
    execute format('drop trigger if exists pgpm_regrain_truncate_guard on %s', v_rel::text);   -- #449
  end loop;

  select delta into v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is not null then
    execute format('truncate %I.%I', v_nsp, v_delta);
  end if;

  for r in select child_name from pgpm.part where parent_table = p_parent and not attached loop
    perform pgpm._regrain_drop_copy(p_parent, v_nsp, r.child_name);   -- #631: by recorded oid
    v_dropped := v_dropped + 1;
  end loop;

  update pgpm.config set regrain_cursor = null where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, rows) values (p_parent, 'regrain_cancel', v_dropped);
  return v_dropped;
end;
$$;

-- retire()'s counterpart to regrain_cancel (issue #519): reclaim the state of a regrain whose SOURCE
-- retention is about to drop, and nothing else.
--
-- With auto-regrain, an archive_fn and retention all on, two pipelines work a wholly-aged coarse child
-- at once: _archive_step covers it so that retire() can drop it whole, and regrain_step copies it so
-- that the swap can replace it with fine children. Whichever finishes first wins, and when archiving
-- won, retire dropped the source and left everything the regrain had built behind: not-attached
-- pgpm.part rows no partition covers, real tables still holding the rows retention had just dropped,
-- config.regrain_cursor pointing into a range that no longer existed, and no later tick able to
-- reclaim any of it -- auto-regrain answers 'none' with no coarse child left, the janitor only tears
-- down capture the cursor does not cover, and regrain_cancel is an operator verb nobody is told to
-- run. The rows were archived from the source, so nothing was lost, but the documented pipeline (a
-- materialized sub-range is blocked, archived and dropped after the swap) was not kept, and the
-- leftovers held disk and misreported status().inflight_partitions for good.
--
-- Reclaim rather than refuse, because a refusal is a wedge with no exit: set_regrain(parent, null)
-- leaves the cursor and the capture in place (the documented way to abandon an auto-regrain), and the
-- janitor keeps a trigger the cursor covers, so a retire that waited for the regrain would wait
-- forever on a table whose operator was told abandoning was safe. And there is nothing to wait FOR: a
-- coarse child whose whole range is past the horizon drops in one step (retain's contract), and every
-- fine child this regrain could produce would be retire-eligible the moment it attached, archived a
-- second time and dropped. The copies hold nothing the archive does not.
--
-- SCOPED TO THE SOURCE, not the parent, which is why this is not a call to regrain_cancel: that verb
-- tears capture off every child and drops every not-attached row of the parent, which is right for an
-- operator abandoning "the regrain" and wrong here, where the regrain in flight may be on a different
-- child than the one retiring. Three effects, each gated by its own evidence:
--   copies  -- every not-attached pgpm.part row whose range lies inside [p_lo, p_hi) was copied out of
--              this child and can never be attached once it is gone (the swap needs its source),
--              whichever regrain made it.
--   delta   -- only when THIS child carries the capture trigger. The delta is per parent and its writer
--              is that trigger; pgpm runs one regrain per parent, so the trigger's presence here means
--              every captured key is a change to this source, whose archive already reflects it and
--              whose copies are going. Never otherwise: a delta belonging to a regrain of another child
--              is that regrain's to reconcile, and discarding it is the #267 loss.
--   cursor  -- when this child carries the capture, or when the cursor lies STRICTLY inside
--              (p_lo, p_hi). A cursor exactly at a bound is ambiguous: a regrain just prepared on the
--              neighbour above sits at this child's hi, one awaiting its swap on the neighbour below
--              sits at this child's lo (the janitor's inclusive-hi rule has the same seam), so at a
--              bound only the capture says whose it is.
-- The capture and TRUNCATE-guard triggers on the child would go with the child; they are dropped here
-- explicitly so the function is complete on its own, and so a source that is detached but not yet
-- dropped is covered too. The delta is cleared with DELETE, not TRUNCATE: this runs inside a retention
-- tick under lock_timeout, and there is no writer left to fence.
--
-- Logged as regrain_cancel with `method` naming retire, because that is what it is: the same statement
-- the operator verb makes, made by retention. `rows` is the number of copies discarded, so a reader of
-- pgpm.log can tell a cancel that reclaimed real work from one that cleared a stale cursor.
create or replace function pgpm._regrain_reclaim(p_parent regclass, p_child name, p_lo text, p_hi text)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_ncast text; v_delta name; v_capture boolean; v_cursor_in boolean;
  v_dropped int := 0; v_purged bigint := 0; r record;
begin
  -- #706: under the lock every regrain driver takes first (#554), before the cursor and the copies are read.
  -- Without it a step in flight could commit a new copy, or move the cursor, after this read and before the
  -- DROP of the source that follows (which waits on the step's lock on the source and then proceeds), and
  -- what that step left outlived the source with nothing to reclaim it: the #519 leftovers. Waited for under
  -- the caller's lock_timeout; in a maintenance tick a wait that runs out fails this retirement's DROP
  -- subtransaction (fail_retain_drop) and the next tick retries it.
  perform pgpm._regrain_lock(p_parent);
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then return 0; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_ncast := pgpm._native_type(cfg.control_kind);

  v_capture := pgpm._regrain_capture_active(p_parent, p_child);
  v_cursor_in := cfg.regrain_cursor is not null
             and (v_capture
                  or (pgpm._native_gt(cfg.control_kind, cfg.regrain_cursor, p_lo)         -- lo < cursor
                      and pgpm._native_gt(cfg.control_kind, p_hi, cfg.regrain_cursor)));  -- cursor < hi

  for r in execute format(
    'select child_name from pgpm.part where parent_table = %L::regclass and not attached'
    || ' and lo::%s >= %L::%s and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, p_lo, v_ncast, v_ncast, p_hi, v_ncast, v_ncast)
  loop
    perform pgpm._regrain_drop_copy(p_parent, v_nsp, r.child_name);   -- #631: by recorded oid
    v_dropped := v_dropped + 1;
  end loop;

  if v_capture then
    execute format('drop trigger if exists pgpm_regrain_capture on %I.%I', v_nsp, p_child);
    execute format('drop trigger if exists pgpm_regrain_truncate_guard on %I.%I', v_nsp, p_child);
    select delta into v_delta from pgpm._regrain_capture_names(p_parent);
    if to_regclass(format('%I.%I', v_nsp, v_delta)) is not null then
      execute format('delete from %I.%I', v_nsp, v_delta);
      get diagnostics v_purged = row_count;
    end if;
  end if;

  if v_cursor_in then
    update pgpm.config set regrain_cursor = null where parent_table = p_parent;
  end if;

  if v_capture or v_cursor_in or v_dropped > 0 then
    insert into pgpm.log (parent_table, action, lo, hi, rows, method)
      values (p_parent, 'regrain_cancel', p_lo, p_hi, v_dropped,
              format('retire dropped %I.%I, the source of this regrain, whole: its range is past the retention horizon and archiving covers it, so the regrain had nothing left to win for retention; %s fine cop%s discarded, %s captured change%s discarded, regrain_cursor %s',
                     v_nsp, p_child, v_dropped, case when v_dropped = 1 then 'y' else 'ies' end,
                     v_purged, case when v_purged = 1 then '' else 's' end,
                     case when v_cursor_in then 'cleared' else 'left alone (it is not this child''s)' end));
  end if;
  return v_dropped;
end;
$$;

-- Does a not-yet-attached fine child with EXACTLY these bounds exist for p_parent? pgpm.part is the
-- authority here, not the relation name: the swap attaches from pgpm.part, so this is precisely "will the
-- swap attach a partition covering this sub-range". Exact bounds, compared natively (bounds are text),
-- because a not-attached row with other bounds is not this sub-range's child. regrain_step asks it twice
-- (#448): in the aged-skip loop, so a skip never fires on a sub-range whose copy has already started, and
-- in the swap's re-check, to find the sub-ranges whose rows are about to go with the source.
create or replace function pgpm._regrain_has_child(p_parent regclass, p_lo text, p_hi text)
returns boolean language plpgsql stable as $$
declare v_kind text;
begin
  select control_kind into v_kind from pgpm.config where parent_table = p_parent;
  return exists (
    select 1 from pgpm.part p
     where p.parent_table = p_parent and not p.attached
       and not pgpm._native_gt(v_kind, p.lo, p_lo) and not pgpm._native_gt(v_kind, p_lo, p.lo)
       and not pgpm._native_gt(v_kind, p.hi, p_hi) and not pgpm._native_gt(v_kind, p_hi, p.hi));
end;
$$;

-- #674, #641: refuse a regrain target step whose SHAPE the grid cannot place, with the rules transmute's
-- preflight applies to a partition_step. _regrain_step_forward asks only "does grid_next move forward", and
-- grid_next reads a step the way the grid does, so it cannot see a step the grid half-ignores:
--   * a month count mixed with a duration ('1 month 1 day', '1 month -40 days', '-1 month 40 days').
--     grid_next's calendar branch keeps the months and drops the rest, so it moved forward and the step
--     passed, while _grid_floor raises 'mixed month + duration interval unsupported' on it, so every tick's
--     regrain_step failed and logged skip_regrain once a coarse child froze. '1 month -40 days' is even below
--     zero by interval ordering, which the forward test was meant to refuse. transmute refuses the shape.
--   * a step finer than a day on a date column. The fine cells' bounds truncate to dates, as transmute's
--     #581 date rule says of a partition_step: two consecutive cells read as one date.
--   * a non-integral step on an integer column (int2, int4, int8). #582 made fractional labels distinct so
--     a numeric column can regrain toward '0.5', but on a bigint column the first fine cell's bound
--     ('0.0' rendered for a bigint) is invalid input and every tick logged skip_regrain with the capture
--     trigger left on the source. transmute's id step is a bigint by signature, so the rule matches it.
-- Called from _regrain_step_forward, so set_regrain (at call time) and regrain_step (which regrain(),
-- regrain_history() and maintain go through) refuse it alike.
create or replace function pgpm._regrain_step_shape(p_parent regclass, p_step text)
returns void language plpgsql stable as $$
declare cfg pgpm.config; v_typname name; v_months numeric; v_rest interval;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  select t.typname into v_typname
    from pg_attribute a join pg_type t on t.oid = a.atttypid
   where a.attrelid = p_parent and a.attname = cfg.control_column and not a.attisdropped;
  if cfg.control_kind = 'id' then
    if v_typname in ('int2', 'int4', 'int8') and p_step::numeric <> trunc(p_step::numeric) then
      raise exception 'pg_partition_magician: regrain target step % for % is not a whole number, but its control column % is %, which holds whole numbers only -- the fine cells'' bounds could not be written as that type, so every tick would fail creating the first one; give a whole-number step (a fractional one is for a numeric column)',
        p_step, p_parent, quote_ident(cfg.control_column), v_typname;
    end if;
    -- #784: and a whole step must be SPELLED whole. The test above is of the value, which '10.0' passes,
    -- but the grid's arithmetic is numeric and carries the step's scale into every bound it renders, so a
    -- '10.0' grid writes its fine cells' bounds as '0.0', '10.0', ...: the same invalid bigint input, the
    -- same skip_regrain on every tick. Refused rather than rewritten, so every entry point (set_regrain,
    -- regrain_step, and a target an older install stored) behaves alike.
    if v_typname in ('int2', 'int4', 'int8') and p_step::numeric = trunc(p_step::numeric) and scale(p_step::numeric) > 0 then
      raise exception 'pg_partition_magician: regrain target step % for % is a whole number written with a fractional part, but its control column % is %, which holds whole numbers only -- the grid would write every fine cell''s bound with that fraction, which is not valid input for that type, so every tick would fail creating the first one; write it as %',
        p_step, p_parent, quote_ident(cfg.control_column), v_typname, trunc(p_step::numeric);
    end if;
  else
    v_months := extract(year from p_step::interval) * 12 + extract(month from p_step::interval);
    v_rest   := p_step::interval - make_interval(months => v_months::int);
    if v_months <> 0 and v_rest <> interval '0' then
      raise exception 'pg_partition_magician: regrain target step % for % mixes a month count with a duration (mixed month + duration interval unsupported) -- the grid steps by calendar months or by a fixed number of seconds, never both, so no tick could floor it, and transmute refuses the same shape as a partition_step; give a whole number of months or a pure duration',
        p_step, p_parent;
    end if;
    if v_typname = 'date' and v_months = 0 and extract(epoch from p_step::interval)::numeric % 86400 <> 0 then
      raise exception 'pg_partition_magician: regrain target step % for % is not a whole number of days, but its control column % is a date, which holds whole days -- the fine cells'' bounds would truncate to dates and two cells would read as one; give a whole number of days or months',
        p_step, p_parent, quote_ident(cfg.control_column);
    end if;
  end if;
end;
$$;

-- #588: refuse a regrain target step that does not move the grid forward. Every regrain precondition
-- compares widths ("coarser than partition_step", "subdivides the child"), and a step of zero or below is
-- narrower than anything, so it passed them all: '0' divides by zero in _grid_floor on every tick, and a
-- negative step makes 'nosubdiv' (hi > lo + step) trivially true, mints a fine child with inverted bounds
-- and walks the cursor BELOW lo, so auto-regrain churns prepare / orphan / restart forever and regrain()
-- spins toward its iteration limit. "Forward" is asked of the grid itself, grid_next(step, anchor) past
-- anchor, so the one test covers an id step, a fixed interval and a calendar one alike ('-1 month' has no
-- positive month count and falls to the fixed branch with negative seconds). set_regrain calls it before
-- storing a target, and regrain_step before anything else, which regrain(), regrain_history() and
-- maintain all go through.
create or replace function pgpm._regrain_step_forward(p_parent regclass, p_step text)
returns void language plpgsql stable as $$
declare cfg pgpm.config;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not pgpm._native_gt(cfg.control_kind,
                         pgpm._grid_next(cfg.control_kind, p_step, cfg.partition_anchor, cfg.partition_tz),
                         cfg.partition_anchor) then
    raise exception 'pg_partition_magician: regrain target step % for % is not positive -- a step of zero or below cannot split anything (zero divides by zero on every tick, a negative one walks the copy cursor backwards); give a step greater than zero and no coarser than partition_step %',
      p_step, p_parent, cfg.partition_step;
  end if;
  perform pgpm._regrain_step_shape(p_parent, p_step);   -- #674, #641: and a step the grid can place
end;
$$;

-- one resumable microbatch of regrain work on coarse child p_child toward target step p_target_step.
-- Returns: 'copied:N' (copied N rows into the current fine child), 'swapped:K' (cursor reached hi -> detached
-- the source, attached K fine children, dropped it: regrain done), or a soft no-progress status ('active' =
-- not frozen yet, 'nosubdiv' = the step does not subdivide).
create or replace function pgpm.regrain_step(
  p_parent regclass, p_child name, p_target_step text default null, p_batch int default null
) returns text language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_child regclass; v_cols_q text; v_ncast text; v_pkjoin_q text; v_keyidx oid;
  v_lo text; v_hi text; v_step text; v_frontier text; v_floor text; v_has boolean; v_walk text;
  v_retain_boundary text; v_batch int; v_reltuples real; v_avg numeric;
  v_cursor text; v_grid_lo text; v_sub_lo text; v_sub_hi text; v_sub_name name;
  v_lo_lit text; v_hi_lit text; v_moved bigint := 0; v_aged boolean; v_made int := 0; v_fk int := 0; r record;
  v_fk_ids bigint[];
  v_child_name name; v_src_name name; v_rec int; v_delta_n bigint; v_delta_name name; v_busy name;
  v_delta_reg regclass; v_sub_known boolean; v_sub_oid oid; v_sub_now regclass; v_copy regclass;
  v_held_lo text; v_held_hi text; v_drift text; v_copies oid[];
begin
  -- #554: before the config read below, so a second driver of this parent (a tick, a hand-driven step, a
  -- cancel) waits for this step to commit and this step reads what the last one left
  perform pgpm._regrain_lock(p_parent);
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_ncast := pgpm._native_type(cfg.control_kind);
  v_step  := coalesce(p_target_step, cfg.partition_step);
  perform pgpm._regrain_step_forward(p_parent, v_step);   -- #588: before anything reads or mutates

  select lo, hi into v_lo, v_hi from pgpm.part
   where parent_table = p_parent and child_name = p_child and attached;
  if not found then
    raise exception 'pg_partition_magician: % is not an attached managed partition of %', p_child, p_parent;
  end if;
  v_child      := format('%I.%I', v_nsp, p_child)::regclass;
  v_child_name := p_child;   -- may be renamed below (#266); v_child is an oid and follows it for free
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped
      and attgenerated = '';   -- omit generated columns: they recompute on insert, never inserted into
  -- the reused-key equijoin (d.<key> = s.<key>, every key column): the copy is an anti-join against it, so
  -- a resumed batch never re-copies a row already in the child even when the control column is non-unique.
  -- The key is whatever transmute reused: a PRIMARY KEY, or (relaxed key contract) a UNIQUE constraint.
  -- A truly KEYLESS monolith has no key to identify rows by, so a resumable copy cannot dedup -- regrain is
  -- refused for it below ('nokey'); the coarse monolith stays a correct, queryable permanent state.
  select coalesce(
           (select i.indexrelid from pg_index i where i.indrelid = p_parent and i.indisprimary limit 1),
           (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
             where con.conrelid = p_parent and con.contype = 'u'
               and i.indpred is null and i.indexprs is null limit 1))
    into v_keyidx;
  if v_keyidx is not null then
    select string_agg(format('d.%I = s.%I', a.attname, a.attname), ' and ' order by k.ord) into v_pkjoin_q
      from pg_index i
      cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
     where i.indexrelid = v_keyidx;
  end if;
  if v_pkjoin_q is null then return 'nokey'; end if;

  -- frozen? (whole range at/below the current grid floor, so no live write still lands in it)
  v_frontier := pgpm._frontier_native(p_parent);
  v_floor    := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier, cfg.partition_tz);
  if pgpm._native_gt(cfg.control_kind, v_hi, v_floor) then return 'active'; end if;
  -- the target step must actually subdivide the child
  if not pgpm._native_gt(cfg.control_kind, v_hi, pgpm._grid_next(cfg.control_kind, v_step, v_lo, cfg.partition_tz)) then
    return 'nosubdiv';
  end if;
  -- ONE regrain per parent at a time (#267). This is a correctness guard, not tidiness: both
  -- config.regrain_cursor and the change-capture delta are per parent, so a second regrain starting on a
  -- different child would reset the first one's cursor AND truncate its delta at prepare, silently
  -- discarding captured changes the first regrain had not applied yet. That is the same class of loss this
  -- apparatus exists to prevent. The cursor thrash alone predates capture (each child resets the cursor
  -- into its own range), so this refusal closes a pre-existing hazard too.
  --
  -- Placed BEFORE the #266 rename below, so a refused regrain mutates nothing at all -- not even the
  -- transitional rename of the child it was never going to split. After the soft statuses above, so a
  -- not-yet-frozen child still answers 'active' rather than raising.
  select p.child_name into v_busy from pgpm.part p
   where p.parent_table = p_parent and p.child_name <> v_child_name
     and pgpm._regrain_capture_active(p_parent, p.child_name)
   limit 1;
  if v_busy is not null then
    raise exception 'pg_partition_magician: cannot regrain % -- a regrain of % is already in flight on this parent, and pgpm runs one regrain per parent (config.regrain_cursor and the change-capture delta are both per parent). Let it finish, or abandon it with pgpm.regrain_cancel(%), then re-run.',
      v_child_name, v_busy, p_parent;
  end if;

  -- ...and the source must not be named as its own first fine sub-range (issue #266). _part_name gives a
  -- one-step range the bare _p<lo> and a wider one the explicit _p<lo>_to_<hi>, and the note above it says
  -- why: the wide form exists "so it can never collide with the fine child at its low edge". But "wider"
  -- was judged on the child's OWN grid. A child exactly one step wide is not wide there, so it kept _p<lo>
  -- -- and regrain then reinterprets it on a FINER grid, where its own first sub-range renders _p<lo> too.
  -- That was silent data loss, not a cosmetic clash: the "does the destination exist yet?" check below
  -- found the SOURCE, took it for an already-created destination, the anti-join copy moved nothing,
  -- v_moved < v_batch advanced the cursor as though the sub-range were done, and the swap's DROP TABLE took
  -- those rows with it.
  --
  -- Finish the design instead of refusing: rename the source to its own name as rendered on the TARGET
  -- grid. `nosubdiv` above already established v_hi > grid_next(v_step, v_lo), so on that grid the source
  -- IS wider than one step and always takes the explicit _to_ form, which no one-step sub-range can equal.
  -- This is safe precisely because of the other half of that note: the name is a human-facing LABEL and
  -- pgpm.part holds the authoritative bounds. v_child is an oid, so every later statement here follows the
  -- table with no re-resolution. Derived from v_lo rather than the cursor, so it also fires for a regrain
  -- resumed past its first sub-range instead of reaching the swap with the collision still ahead of it.
  v_grid_lo := pgpm._grid_floor(cfg.control_kind, v_step, cfg.partition_anchor, v_lo, cfg.partition_tz);
  v_sub_lo  := case when pgpm._native_gt(cfg.control_kind, v_lo, v_grid_lo) then v_lo else v_grid_lo end;
  v_sub_hi  := pgpm._grid_next(cfg.control_kind, v_step, v_grid_lo, cfg.partition_tz);
  if pgpm._native_gt(cfg.control_kind, v_sub_hi, v_hi) then v_sub_hi := v_hi; end if;
  if pgpm._regrain_sub_name(v_rel, cfg, v_step, v_sub_lo, v_sub_hi) = v_child_name then   -- #783: as named below
    v_src_name := pgpm._part_name(v_rel, cfg.control_kind, v_step, v_lo, v_hi, cfg.partition_tz);
    if to_regclass(format('%I.%I', v_nsp, v_src_name)) is not null then
      raise exception 'pg_partition_magician: cannot regrain % at target step % -- splitting it needs the transitional name %, which is already taken by another relation. Drop or rename that relation, then re-run.',
        v_child_name, v_step, v_src_name;
    end if;
    execute format('alter table %s rename to %I', v_child::text, v_src_name);
    update pgpm.part set child_name = v_src_name
     where parent_table = p_parent and child_name = v_child_name;
    -- ...and its archive coverage with it (#511). pgpm.archive_ledger matches chunks to their partition
    -- by child_name, so rows left under the old name are coverage nothing tracks: _archive_step's
    -- orphan discard would throw them away on the next tick and re-export the prefix, and the old bare
    -- name is exactly what the first fine sub-range is about to be called, so after the swap they
    -- would sit under a live partition's name as a watermark recorded for a different relation, with
    -- only the #452 no-block reset between them and adoption. Same relation, same transaction, block
    -- untouched, so carrying the rows keeps every #452 invariant.
    update pgpm.archive_ledger set child_name = v_src_name
     where parent_table = p_parent and child_name = v_child_name;
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'regrain_rename', v_lo, v_hi, v_child_name || ' -> ' || v_src_name);
    v_child_name := v_src_name;
  end if;
  -- The 'default_dirty' gate is gone with the DEFAULT (#288). It guarded against a stray sitting in the
  -- range, which would make a fine-child ATTACH fail at the swap; with a complete forward grid there is
  -- nowhere for a stray to sit except a real partition of the range being regrained.

  -- #267: change capture must be installed AND COMMITTED before any copy reads the source, or every change
  -- made during the first batch is lost. Its own tick, so CREATE TRIGGER's SHARE ROW EXCLUSIVE is an O(1)
  -- hold rather than one spanning a copy batch. Setting the cursor here too keeps the janitor's invariant
  -- ("cursor null => no child carries the trigger") true from the first tick, so it cannot tear down a
  -- regrain that is one tick old.
  if not pgpm._regrain_capture_active(p_parent, v_child_name) then
    -- No capture installed means every copy of this source that exists was made WITHOUT capture: an
    -- interrupted regrain from before this apparatus, or one the janitor cleaned up mid-flight. Those
    -- copies are unreconciled, so resuming from them would reintroduce exactly this bug. Discard and
    -- restart, which is cheap: the source still holds every row.
    --
    -- Decided by the copies, NOT by the cursor (#569). The janitor's documented backstop is a cursor
    -- cleared by some other route (a hand edit): it tears the capture down and leaves the copies, so
    -- the state this branch exists for arrives here with regrain_cursor NULL. Gated on the cursor, the
    -- next run resumed from those copies and the swap attached them: every UPDATE made while capture
    -- was off reverted, every DELETE came back, every INSERT vanished. Only regrain inserts a
    -- not-attached pgpm.part row (#94), so a not-attached row inside this source's range is one of its
    -- copies whatever the cursor says. A set cursor with no copies still restarts (and logs) as before.
    for r in execute format(
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
    perform pgpm._regrain_capture_install(p_parent, v_child_name);
    update pgpm.config set regrain_cursor = v_lo where parent_table = p_parent;
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'regrain_prepare', v_lo, v_hi, v_child_name);
    return 'prepared';
  end if;
  -- #650: capture is up, so this tick resumes and prepare will not run again for this regrain. A source
  -- that carries capture but no TRUNCATE guard (a regrain begun before #449, a guard dropped by hand) gets
  -- it here, from the first tick that meets it. A no-op whenever the guard is present.
  perform pgpm._regrain_truncate_guard_ensure(v_child);
  -- #496: a role granted DML on the parent after the prepare tick gets INSERT on the delta from the next
  -- tick on, rather than 42501 until the swap. Grants only what is missing, so this is a no-op most ticks.
  select delta into v_delta_name from pgpm._regrain_capture_names(p_parent);
  v_delta_reg := to_regclass(format('%I.%I', v_nsp, v_delta_name));
  if v_delta_reg is not null then perform pgpm._regrain_capture_grant(p_parent, v_delta_reg); end if;

  -- #785: the copies must still have the parent's columns. They are standalone tables made LIKE the
  -- parent as it stood when each was created, and ALTER TABLE on the parent reaches the attached source
  -- but never them, while the copy and the reconcile below list the parent's CURRENT columns and the
  -- swap's ATTACH requires the same columns, types and NOT NULLs. An ADD COLUMN mid-regrain therefore
  -- failed every later tick ('column ... does not exist', logged skip_regrain), a DROP COLUMN or a TYPE
  -- change failed at the swap, and the run never moved again. Asked before the reconcile, the copy and
  -- the swap, so every one of them meets copies of the parent's current shape.
  --
  -- A drifted run restarts from the source, as the prepare tick restarts copies that predate capture:
  -- the copies are discarded and the range is copied again, LIKE the parent as it is now. Not an ADD
  -- COLUMN on each copy instead, because that is right only for a constant default: the source's rows
  -- got the new column's value when the ALTER ran (a volatile default rewrote them with one value per
  -- row, now() was evaluated once at that instant), and re-evaluating the default in the copy gives its
  -- rows different values, which the swap would then attach. Only rereading every copied row from the
  -- source gets them right, and that is what the restart does. Capture stays on and its delta is kept:
  -- every captured key is at or past the reset cursor now, so it waits until the copy has passed it and
  -- is then applied from the source, which is harmless for a row the copy already took because the
  -- reconcile deletes and reinserts it from the source.
  -- Each copy by the oid regrain_step recorded (#421); a null child_oid predates the anchor and is read by
  -- name.
  v_copies := '{}';
  for r in execute format(
    'select child_name, child_oid from pgpm.part where parent_table = %L::regclass and not attached'
    || ' and lo::%s >= %L::%s and hi::%s <= %L::%s',
    p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast)
  loop
    v_copies := v_copies || coalesce(r.child_oid, to_regclass(format('%I.%I', v_nsp, r.child_name))::oid);
  end loop;
  v_drift := pgpm._regrain_shape_drift(p_parent, v_copies);
  if v_drift is not null then
    for r in execute format(
      'select child_name from pgpm.part where parent_table = %L::regclass and not attached'
      || ' and lo::%s >= %L::%s and hi::%s <= %L::%s',
      p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast)
    loop
      perform pgpm._regrain_drop_copy(p_parent, v_nsp, r.child_name);   -- #631: by recorded oid
      v_made := v_made + 1;
    end loop;
    update pgpm.config set regrain_cursor = v_lo where parent_table = p_parent;
    insert into pgpm.log (parent_table, action, lo, hi, rows, method)
      values (p_parent, 'regrain_restart', v_lo, v_hi, v_made,
              format('the parent''s columns changed since the copies were made (%s); the copies are discarded and the range is copied again from the source',
                     v_drift));
    return 'restarted:' || v_made;
  end if;

  -- retention horizon (matches retain(), issue #91)
  if cfg.retain is not null then
    -- #451: the refusal _retain_boundary makes, restated here because this is the one other place the horizon
    -- is computed. Against a negative retain every sub-range is "aged", and an aged sub-range is skipped and
    -- its rows DISCARDED with the coarse source at the swap, never copied: the whole child, gone.
    if not pgpm._retain_nonnegative(cfg.control_kind, cfg.retain) then
      raise exception 'pg_partition_magician: config.retain % on % is negative -- refusing to regrain against a retention horizon past the partition taking writes, which would discard every sub-range as aged; repair it with pgpm.set_retain', cfg.retain, p_parent;
    end if;
    if cfg.control_kind = 'id'
      then v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  (v_frontier::numeric - cfg.retain::numeric)::text, cfg.partition_tz);
      else v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  pgpm._ts_text(((now() at time zone cfg.partition_tz) - cfg.retain::interval) at time zone cfg.partition_tz),
                                  cfg.partition_tz);   -- on the wall clock in partition_tz, as _retain_boundary (#455)
    end if;
  end if;

  -- budget (rows per microbatch): regrain_batch, capped by regrain_max_blocks via the coarse child's stats
  v_batch := coalesce(p_batch, cfg.regrain_batch, 5000);
  if cfg.regrain_max_blocks is not null then
    select c.reltuples into v_reltuples from pg_class c where c.oid = v_child;
    if coalesce(v_reltuples, 0) > 0 then v_avg := pg_table_size(v_child)::numeric / v_reltuples;
    else execute format('select avg(pg_column_size(t))::numeric from (select * from %s limit 1000) t', v_child::text) into v_avg;
    end if;
    if coalesce(v_avg, 0) > 0 then
      v_batch := least(v_batch, greatest(1, floor(cfg.regrain_max_blocks::numeric * 8192 / v_avg))::int);
    end if;
  end if;
  v_batch := greatest(1, v_batch);   -- a copied:0 batch must advance the cursor (0 < batch), never stall

  -- progress cursor: the lo of the sub-range currently being copied. null (fresh) or stale (out of this
  -- child's [lo,hi)) -> start at the coarse lo. The cursor only ever advances, one grid sub-range at a time.
  v_cursor := cfg.regrain_cursor;
  if v_cursor is null
     or pgpm._native_gt(cfg.control_kind, v_lo, v_cursor)        -- cursor < coarse lo
     or pgpm._native_gt(cfg.control_kind, v_cursor, v_hi) then   -- cursor > coarse hi
    v_cursor := v_lo;
  end if;

  -- #267: reconcile captured changes before copying more. Only sub-ranges the copy has already finished
  -- are eligible (see _regrain_reconcile), so this never disturbs max(dest.ctl) in the sub-range being
  -- copied. Bounded by the same budget as the copy, and it takes the tick when there is work, so a burst
  -- of DML paces itself instead of landing in the swap.
  v_rec := pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_cursor, v_batch);
  if v_rec > 0 then return 'reconciled:' || v_rec; end if;

  -- Advance over any aged (below-horizon) sub-ranges without copying them: they would be dropped by retain()
  -- the instant they became partitions, so they are simply discarded with the source at the swap (never
  -- materialized, and never deleted out of the source either). Aged ranges are the lowest in control order, a
  -- contiguous prefix, so this loop only runs at the bottom of the child. One regrain_aged per skipped range.
  --
  -- ONLY when there is nothing to archive (#278). That "they would be dropped by retain() anyway" reasoning
  -- was written before #238 gave retire a coverage gate, and stopped being true then: with archive_fn set,
  -- retire refuses to drop a partition until archiving has fully covered it, so discarding these rows
  -- destroys exactly what the gate is holding back, unarchived. Measured: 2000 rows gone, archive ledger
  -- empty.
  --
  -- So with archive_fn set the sub-range is materialized like any other, and the EXISTING pipeline takes it
  -- from there in the right order: _enforce_write_blocks blocks it (its whole range is below the horizon
  -- now that it is a partition), _archive_step archives it, retire drops it once covered. That also closes
  -- the write-block asymmetry, since a late backdated write lands in a partition that gets archived.
  --
  -- Not "wait for coverage before skipping", which cannot work: a PARTIALLY aged child straddles the
  -- horizon, so it is never write-blocked and therefore never archived, and the regrain would wait forever
  -- for coverage nothing produces.
  --
  -- The cost when archive_fn is set is copying rows that are about to be dropped. They have to be read to
  -- archive them regardless, so it is one extra write of doomed data, and only on tables that archive.
  --
  -- And NEVER on a sub-range that already has a fine child (#448). A range half-copied in one tick can
  -- age before the next (the frontier moved, for an id grid; the clock, for time), and skipping it then
  -- left its partial child in pgpm.part for the swap to ATTACH holding a fraction of its rows, which the
  -- parent then served as the whole range until retain got to it. Finishing the copy costs the rest of
  -- one doomed sub-range, and it is what lets the swap below treat "a child exists" as "its copy is
  -- complete": the cursor only ever passes a sub-range on a short batch (complete) or on a skip, and a
  -- skip now requires that there is nothing to leave behind.
  loop
    exit when not pgpm._native_gt(cfg.control_kind, v_hi, v_cursor);   -- cursor >= hi: nothing left to copy
    v_grid_lo := pgpm._grid_floor(cfg.control_kind, v_step, cfg.partition_anchor, v_cursor, cfg.partition_tz);
    v_sub_lo  := case when pgpm._native_gt(cfg.control_kind, v_lo, v_grid_lo) then v_lo else v_grid_lo end;
    v_sub_hi  := pgpm._grid_next(cfg.control_kind, v_step, v_grid_lo, cfg.partition_tz);
    if pgpm._native_gt(cfg.control_kind, v_sub_hi, v_hi) then v_sub_hi := v_hi; end if;
    v_aged := v_retain_boundary is not null
              and cfg.archive_fn is null                                  -- #278: see above
              and not pgpm._native_gt(cfg.control_kind, v_sub_hi, v_retain_boundary)
              and not pgpm._regrain_has_child(p_parent, v_sub_lo, v_sub_hi);   -- #448: see above
    exit when not v_aged;                                             -- found a sub-range to copy
    insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'regrain_aged', v_sub_lo, v_sub_hi, 0);
    v_cursor := v_sub_hi;                                             -- skip the aged sub-range (no copy, no delete)
  end loop;

  -- still a sub-range to copy: ensure its fine child exists (standalone, born with its validated bound
  -- CHECK), then COPY one budget batch into it. The copy is an anti-join against the child's PK, resumed from
  -- the child's current newest control value, so it never re-copies and never deletes. row_count < batch means
  -- the remaining rows fit in this batch -> the sub-range is complete, advance the cursor to the next one.
  -- That resume point is read with ORDER BY ... DESC LIMIT 1 and NOT max(): PostgreSQL has no max(uuid)
  -- before 18, so as max() it raised 42883 on every copy batch of a uuidv7 table, which made a uuidv7
  -- monolith impossible to regrain and left auto-regrain logging skip_regrain every tick (#507). Same
  -- reasoning, and the same shape, as _frontier_native's read of the frontier.
  if pgpm._native_gt(cfg.control_kind, v_hi, v_cursor) then
    v_lo_lit := pgpm._encode(cfg.control_kind, v_sub_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);
    v_hi_lit := pgpm._encode(cfg.control_kind, v_sub_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz);
    -- #585: a sub-range whose copy has already started is found by its BOUNDS in pgpm.part, never by
    -- re-rendering its name. The name is rendered from the parent's CURRENT relname, so an ALTER TABLE
    -- ... RENAME of the parent mid-regrain (harmless by contract, see #496) made the child the copy had
    -- already filled invisible to a lookup by name: the next tick minted a second not-attached child for
    -- the same [lo, hi) and the swap, which attaches from pgpm.part, failed "would overlap" on every tick.
    -- pgpm.part is the swap's own authority (the same one _regrain_has_child and the reconcile, #446, ask),
    -- so asking it here is "will the swap attach this child for this sub-range". A name is rendered only
    -- to CREATE a child the sub-range does not have yet.
    select p.child_name into v_sub_name from pgpm.part p
     where p.parent_table = p_parent and not p.attached
       and not pgpm._native_gt(cfg.control_kind, p.lo, v_sub_lo) and not pgpm._native_gt(cfg.control_kind, v_sub_lo, p.lo)
       and not pgpm._native_gt(cfg.control_kind, p.hi, v_sub_hi) and not pgpm._native_gt(cfg.control_kind, v_sub_hi, p.hi);
    v_sub_name := coalesce(v_sub_name,
                           pgpm._regrain_sub_name(v_rel, cfg, v_step, v_sub_lo, v_sub_hi));   -- #783
    -- invariant (#266): the rename above makes this unreachable. Assert it anyway -- when it was false the
    -- failure was silent row destruction, so a future change to _part_name must break loudly here.
    if v_sub_name = v_child_name then
      raise exception 'pg_partition_magician: internal error regraining % -- sub-range [%, %) resolves to the source child itself; refusing rather than copying into the table about to be dropped.',
        v_child_name, v_sub_lo, v_sub_hi;
    end if;
    -- #631: the relation under that name must be the copy THIS regrain made, or nothing. The create below
    -- is skipped whenever the name resolves, and the copy then inserts into whatever it resolves to, so a
    -- name held by some other relation took this table's rows: a managed table renamed aside keeps its
    -- partitions' names, and regraining a new table created under the old name copied 49 of its rows into
    -- the OLD table's attached partition (F3-05). Two ways to be the wrong relation, both refused before a
    -- row moves. With no pgpm.part row for this sub-range, any relation at the name is one this regrain
    -- did not create: only the create below mints a not-attached row (#94), in the same statement group
    -- that creates the table. With a row, the name must still resolve to the oid it recorded (child_oid,
    -- #421); a null child_oid predates the anchor and is not checked, as everywhere else. Refused rather
    -- than renamed around, because the rename would be a label pgpm chose for someone else's relation; the
    -- operator renames or drops it (nothing has been copied into it) and the next tick carries on.
    select true, p.child_oid into v_sub_known, v_sub_oid from pgpm.part p
     where p.parent_table = p_parent and not p.attached and p.child_name = v_sub_name
       and not pgpm._native_gt(cfg.control_kind, p.lo, v_sub_lo) and not pgpm._native_gt(cfg.control_kind, v_sub_lo, p.lo)
       and not pgpm._native_gt(cfg.control_kind, p.hi, v_sub_hi) and not pgpm._native_gt(cfg.control_kind, v_sub_hi, p.hi);
    v_sub_known := coalesce(v_sub_known, false);
    v_sub_now := to_regclass(format('%I.%I', v_nsp, v_sub_name));
    if v_sub_now is not null and not v_sub_known then
      raise exception 'pg_partition_magician: cannot regrain % -- the fine child for sub-range [%, %) would be %.%, but a relation named %.% already exists and this regrain did not create it (no pgpm.part row of % records it as that sub-range''s copy). Copying into it would put this table''s rows in a relation pgpm does not own. Nothing has been copied into it: rename or drop that relation and re-run, or abandon the regrain with pgpm.regrain_cancel(%).',
        v_child_name, v_sub_lo, v_sub_hi, v_nsp, v_sub_name, v_nsp, v_sub_name, p_parent, p_parent;
    end if;
    if v_sub_now is not null and v_sub_oid is not null and v_sub_now::oid <> v_sub_oid then
      raise exception 'pg_partition_magician: cannot regrain % -- %.% is oid % now, and no longer names the copy this regrain created for sub-range [%, %) (oid %). Copying into it would put this table''s rows in a relation pgpm does not own. Nothing has been copied into it: rename or drop that relation and re-run, or abandon the regrain with pgpm.regrain_cancel(%), which drops the copy by its recorded oid.',
        v_child_name, v_nsp, v_sub_name, v_sub_now::oid, v_sub_lo, v_sub_hi, v_sub_oid, p_parent;
    end if;
    -- #707: and no other pgpm.part row of this parent may hold the name. The create below records the new
    -- copy `on conflict do nothing`, which is right only for the row this sub-range already has (a copy
    -- dropped by hand and recreated, re-anchored just after); against a row over OTHER bounds it left that
    -- row describing a different range while the copy filled the new table, and the swap then attached it
    -- with the wrong bounds or found the sub-range childless. Refused before anything is created.
    if not v_sub_known then
      select p.lo, p.hi into v_held_lo, v_held_hi from pgpm.part p
       where p.parent_table = p_parent and p.child_name = v_sub_name;
      if found then
        raise exception 'pg_partition_magician: cannot regrain % -- the fine child for sub-range [%, %) would be %.%, but pgpm.part already records that name for %.% over [%, %), so the copy''s row could not be recorded. Nothing has been created or copied: remove or correct that pgpm.part row and re-run, or abandon the regrain with pgpm.regrain_cancel(%).',
          v_child_name, v_sub_lo, v_sub_hi, v_nsp, v_sub_name, v_nsp, v_rel, v_held_lo, v_held_hi, p_parent;
      end if;
    end if;
    if to_regclass(format('%I.%I', v_nsp, v_sub_name)) is null then
      execute format('create table %I.%I (like %I.%I including defaults including generated including storage including indexes including constraints excluding identity)',
                     v_nsp, v_sub_name, v_nsp, v_rel);
      execute format('alter table %I.%I add constraint %I check (%I >= %L and %I < %L)',
                     v_nsp, v_sub_name, (v_sub_name || '_ck'), cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit);
      -- #348: give the fine child its own already-validated copy of every outgoing FK the parent
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
      -- child_oid (#421): the fine child is standalone here and joins pg_inherits only at the swap,
      -- so this is the only point at which its identity can be recorded from the CREATE that made it.
      insert into pgpm.part (parent_table, child_name, lo, hi, attached, child_oid)
        values (p_parent, v_sub_name, v_sub_lo, v_sub_hi, false,
                format('%I.%I', v_nsp, v_sub_name)::regclass::oid)
        on conflict (parent_table, child_name) do nothing;
      -- #631: a row that outlived its relation (the copy was dropped by hand) now names this one, so
      -- regrain_cancel's drop by recorded oid reaches the table just created rather than nothing.
      if v_sub_known then
        update pgpm.part set child_oid = format('%I.%I', v_nsp, v_sub_name)::regclass::oid
         where parent_table = p_parent and child_name = v_sub_name and not attached;
      end if;
    end if;
    execute format($f$
      insert into %7$I.%8$I (%6$s)
      select %6$s from %1$s s
       where s.%2$I >= coalesce((select d2.%2$I from %7$I.%8$I d2 order by d2.%2$I desc limit 1), %3$L)
         and s.%2$I < %4$L
         and not exists (select 1 from %7$I.%8$I d where %9$s)
       order by s.%2$I
       limit %5$s
    $f$, v_child::text, cfg.control_column, v_lo_lit, v_hi_lit, v_batch, v_cols_q, v_nsp, v_sub_name, v_pkjoin_q);
    get diagnostics v_moved = row_count;
    if v_moved > 0 then
      insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'regrain_copy', v_sub_lo, v_sub_hi, v_moved);
    end if;
    if v_moved < v_batch then
      v_cursor := v_sub_hi;                                          -- sub-range fully copied: advance
      -- the fine child holds all its rows now and is still standalone (it is attached later, at the swap):
      -- ANALYZE it here, off the swap's exclusive-lock window, so the swap and any query that hits it after
      -- see real stats, not reltuples = -1 (#164).
      perform pgpm._own_like_parent(p_parent, format('%I.%I', v_nsp, v_sub_name)::regclass);   -- #277
      perform pgpm._analyze(format('%I.%I', v_nsp, v_sub_name)::regclass);
    end if;
    update pgpm.config set regrain_cursor = v_cursor where parent_table = p_parent;
    return 'copied:' || v_moved;
  end if;

  -- #267: do not ENTER the swap carrying a backlog. The residual reconcile below runs inside the swap
  -- transaction, so it must be small; the gate is what keeps it so. Checked before the DETACH, because once
  -- that holds ACCESS EXCLUSIVE no further writes can arrive and the residual is only what was in flight at
  -- that instant. Deliberately no forcing: if writes outpace reconciliation the regrain stalls here
  -- indefinitely, which is correct -- the source stays attached, reads are unaffected, the table is
  -- consistent, and status() shows it. Forcing would put an unbounded reconcile under the lock.
  perform pgpm._regrain_delta_purge(p_parent, v_lo, v_hi);   -- junk cannot be allowed to wedge the gate
  v_delta_n := pgpm._regrain_delta_count(p_parent);
  if v_delta_n > v_batch then return 'reconciling:' || v_delta_n; end if;

  -- #448: re-check every aged skip against the retention policy in force NOW, before anything is locked
  -- or mutated. A sub-range the cursor advanced over as aged left no trace but the advanced cursor, and
  -- its rows are about to go with the source at the DROP below. That is only right if the range is STILL
  -- entirely below the horizon: pgpm.set_retain(parent, null), or a longer value, between the skip and
  -- the swap makes the policy say keep while the rows are still visible through the attached source, so
  -- the DROP would destroy rows the table is now configured to retain (39,999 in the hunt that found
  -- this). Same walk as the skip loop above (same grid, same clamped first sub-range) and the same
  -- predicate as v_aged, so the two can only disagree when the policy changed in between.
  --
  -- Refuse rather than re-materialize: copying the range here would be an unbounded copy inside the
  -- swap tick, and the choice (put retain back, or cancel and re-run under the new policy) belongs to
  -- the operator. Placed BEFORE the incoming-FK suspend and the DETACH, so a refused swap takes no
  -- ACCESS EXCLUSIVE and mutates nothing; the cursor stays at hi, so the very next tick swaps once retain
  -- is restored. Only childless sub-ranges are checked: one with a fine child is complete by
  -- construction (the skip loop never fires on a range with a child, and the copy branch only advances
  -- the cursor on a short batch), so at the swap every not-attached child holds its whole range.
  v_walk := v_lo;
  loop
    exit when not pgpm._native_gt(cfg.control_kind, v_hi, v_walk);   -- walk >= hi: every sub-range checked
    v_grid_lo := pgpm._grid_floor(cfg.control_kind, v_step, cfg.partition_anchor, v_walk, cfg.partition_tz);
    v_sub_lo  := case when pgpm._native_gt(cfg.control_kind, v_lo, v_grid_lo) then v_lo else v_grid_lo end;
    v_sub_hi  := pgpm._grid_next(cfg.control_kind, v_step, v_grid_lo, cfg.partition_tz);
    if pgpm._native_gt(cfg.control_kind, v_sub_hi, v_hi) then v_sub_hi := v_hi; end if;
    v_has := pgpm._regrain_has_child(p_parent, v_sub_lo, v_sub_hi);
    if not v_has then
      v_aged := v_retain_boundary is not null
                and cfg.archive_fn is null
                and not pgpm._native_gt(cfg.control_kind, v_sub_hi, v_retain_boundary);
      if not v_aged then
        raise exception 'pg_partition_magician: refusing to swap the regrain of %: sub-range [%, %) has no fine child to attach (it was skipped as aged when the cursor passed it) and is no longer entirely below the current retention horizon (%), so the swap''s DROP of the source would destroy rows the table is now configured to keep: retention was loosened mid-regrain (pgpm.set_retain to a longer value or null, or archive_fn set, after the skip). The source stays attached and the run stays resumable. Restore the earlier retain with pgpm.set_retain(%, ...) and the next tick swaps, or abandon this run with pgpm.regrain_cancel(%) and re-run it under the new policy.',
          v_child_name, v_sub_lo, v_sub_hi, coalesce(v_retain_boundary, 'none: retain is null'), p_parent, p_parent;
      end if;
    end if;
    v_walk := v_sub_hi;
  end loop;
  -- #707: and every copy about to be attached must still be the relation pgpm.part recorded for it. The
  -- attach loop below used to ATTACH `%I.%I` of each recorded name, so a completed copy renamed aside and
  -- a table created under its old name LIKE it INCLUDING ALL (which carries the `_ck`) was attached in
  -- its place, the source was dropped, and that sub-range's rows left the managed table. Asked here,
  -- before the incoming-FK suspend and the DETACH, so a refused swap takes no ACCESS EXCLUSIVE and
  -- mutates nothing; the attach loop then attaches the relation resolved by the same helper.
  for r in execute format(
    'select child_name from pgpm.part where parent_table = %L::regclass and not attached and lo::%s >= %L::%s and hi::%s <= %L::%s',
    p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast)
  loop
    perform pgpm._regrain_copy_rel(p_parent, v_nsp, r.child_name, 'attach');
  end loop;

  -- cursor reached hi: every sub-range is copied (or aged and skipped). Swap atomically -- detach the source,
  -- attach every not-yet-attached fine child within its range (metadata-only via each child's validated
  -- CHECK), drop the source whole (no DELETE; the aged rows that were never copied go with it).
  --
  -- DETACH is refused while an incoming FK still references the source's rows (they leave the parent between
  -- detach and the re-attach of the copies). Drop the incoming FK(s) for the swap and re-add them, all inside
  -- THIS one transaction, so no other session ever observes RI off. force=true since the copy did not
  -- suspend; v_fk=0 means there was no live preserve-managed FK to drop -- either the table has none, or
  -- the conversion's drop has not been restored yet -- so leave the re-add to restore_incoming_fks.
  --
  -- #378: snapshot exactly which rows are about to be suspended, BEFORE suspending them, and pass
  -- that exact set to restore_incoming_fks below -- not every not-yet-restored row for the parent.
  -- Without this, a pre-existing "stale" FK (one this swap never suspended, e.g. left unrestored by
  -- an earlier failed restore attempt) gets swept up by restore_incoming_fks's own "restore
  -- everything unrestored" default, and re-adding it needs a FRESH lock on its referencing table,
  -- taken while the managed parent is already under ACCESS EXCLUSIVE from the DETACH below -- so a
  -- contended referencing table blocks every other session on the parent too. Scoping to what THIS
  -- call suspended costs nothing (those tables' locks are already held by the suspend below, so
  -- restoring them is never a fresh acquisition) and leaves the stale FK for the next tick's own
  -- restore_incoming_fks call, exactly like the existing v_fk=0 case already does above.
  select array_agg(id) into v_fk_ids from pgpm.dropped_fk
   where parent_table = p_parent and restored_at is not null;
  v_fk := pgpm.suspend_incoming_fks(p_parent, true);
  execute format('alter table %s detach partition %s', p_parent::text, v_child::text);
  -- #267: the correctness backstop. The cursor is at hi, so every captured key is now eligible, and the
  -- DETACH above holds ACCESS EXCLUSIVE on the source, so no further writes can arrive: the delta is
  -- finite from here and every pass consumes at least one key, which is what makes this loop terminate.
  -- It runs until the reconcile finds nothing, NOT for a fixed number of passes (#447). The gate bounds
  -- only what had committed before it ran; a writer already holding a row in the source keeps the DETACH
  -- waiting, and everything it commits during that wait lands in the delta after the gate. The earlier
  -- `for v_i in 1 .. 100` bound dropped everything past 100 * greatest(batch, 1000) such keys with the
  -- source, silently: measured, 49,851 committed rows gone after a clean `swapped:30`.
  loop
    exit when pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_hi, greatest(v_batch, 1000)) = 0;
  end loop;
  -- ...and prove it before the DROP. The source is the authority for every captured key, so dropping it
  -- with one still pending is data loss with no error anywhere. Raising here rolls the swap back whole,
  -- which is its documented atomicity: the source stays attached, the captured keys stay in the delta,
  -- and the next tick reconciles them and swaps. Scoped to [lo, hi), for the reason given on the
  -- three-argument _regrain_delta_count.
  v_delta_n := pgpm._regrain_delta_count(p_parent, v_lo, v_hi);
  if v_delta_n > 0 then
    raise exception 'pg_partition_magician: internal error regraining % -- % captured change(s) in [%, %) are still pending after the swap''s residual reconcile; refusing to drop the source with changes unapplied. The swap rolls back whole: the source stays attached and the next tick reconciles the backlog before swapping.',
      v_child_name, v_delta_n, v_lo, v_hi;
  end if;
  for r in execute format(
    'select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and not attached and lo::%s >= %L::%s and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast, v_ncast)
  loop
    v_copy := pgpm._regrain_copy_rel(p_parent, v_nsp, r.child_name, 'attach');   -- #707: by recorded oid
    execute format('alter table %s attach partition %s for values from (%L) to (%L)',
                   p_parent::text, v_copy::text,
                   pgpm._encode(cfg.control_kind, r.lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz), pgpm._encode(cfg.control_kind, r.hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz));
    execute format('alter table %s drop constraint %I', v_copy::text, (r.child_name || '_ck'));
    -- #782: a LIKE copy has the default identity whatever the parent's; after the attach, so a USING INDEX
    -- identity maps to the copy's own index under the parent's
    perform pgpm._replica_identity_like_parent(p_parent, v_copy);
    update pgpm.part set attached = true where parent_table = p_parent and child_name = r.child_name;
    insert into pgpm.log (parent_table, action, lo, hi, method) values (p_parent, 'regrain_attach', r.lo, r.hi, 'check_skip');
    v_made := v_made + 1;
  end loop;
  delete from pgpm.part where parent_table = p_parent and child_name = v_child_name;   -- not p_child: #266 may have renamed it
  -- The source's archive coverage goes with it (#511). A partly archived child can be regrained
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
  execute format('drop table %s', v_child::text);
  -- the capture trigger (#267) and the TRUNCATE guard (#449) went with the dropped source; clear the delta
  -- so the next regrain of this parent starts from an empty one and status() does not report a phantom
  -- backlog.
  select delta into v_delta_name from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta_name)) is not null then
    execute format('truncate %I.%I', v_nsp, v_delta_name);
  end if;
  -- re-add the FK(s) this swap dropped, against the new parent (the copies now hold every key). Only if WE
  -- dropped them (v_fk > 0): v_fk = 0 means there was nothing live to drop, so there is nothing here to put
  -- back -- restore_incoming_fks owns any FK still suspended from the conversion. Scoped to v_fk_ids (#378):
  -- exactly what was snapshotted above, before the suspend -- not every not-yet-restored row for the parent.
  if v_fk > 0 then perform pgpm.restore_incoming_fks(p_parent, v_fk_ids); end if;
  update pgpm.config set regrain_cursor = null where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, lo, hi, rows, method) values (p_parent, 'regrain', v_lo, v_hi, v_made, 'copy_swap_drop');
  return 'swapped:' || v_made;
end;
$$;

-- regrain(): the synchronous "do it now" driver -- loops regrain_step in ONE transaction (atomic, gap-free)
-- until the coarse child is fully split, and returns the number of fine children created. Soft no-progress
-- statuses become a hard error here (the operator gets a clear refusal); maintain() instead just skips.
create or replace function pgpm.regrain(p_parent regclass, p_child name, p_target_step text default null)
returns int language plpgsql as $$
declare v_status text; v_iter int := 0; v_child name := p_child; v_next name; v_lo text;
begin
  -- regrain_step may rename the source child on its first pass (#266: a child exactly one step wide is
  -- renamed to its coarse-form name on the target grid so its own first sub-range can take _p<lo>). Follow
  -- it by lo, which never changes, and re-resolve the name each iteration -- otherwise every iteration after
  -- the first would look up a name that no longer exists. Only the source is attached at that lo during the
  -- copy phase (fine children stay attached = false until the swap), so the lookup is unambiguous.
  select lo into v_lo from pgpm.part
   where parent_table = p_parent and child_name = p_child and attached;
  -- #580: take SHARE on the parent, and ONLY the parent, before the first step, so a writer waits at
  -- the parent rather than deadlocking with the swap. Every step runs in this one transaction, so the
  -- capture trigger's SHARE ROW EXCLUSIVE on the source (the prepare step's CREATE TRIGGER) is held to
  -- the end of the call. Without this, a write into the source's range took ROW EXCLUSIVE on the parent
  -- (nothing conflicted with it there), then queued on the source still holding it, and the swap's
  -- DETACH, needing ACCESS EXCLUSIVE on the parent, waited on the writer that waited on it: 40P01,
  -- aborting the write or the whole regrain after all its copying. Under SHARE the writer queues at the
  -- parent holding nothing the swap needs, the swap's upgrade to ACCESS EXCLUSIVE goes ahead of it, and
  -- the write lands in the fine children once this commits. Reads are unaffected (SHARE admits ACCESS
  -- SHARE and ROW SHARE, so FK checks against the parent proceed too); every write to the table waits
  -- for the call, which is the price of one transaction. Auto-regrain (maintain, one regrain_step per
  -- committed tick) takes no such lock, and is the path for a table under live writes.
  --
  -- #554: the regrain lock comes FIRST, before SHARE, so every regrain driver takes the two in one order.
  -- Taken after, a regrain() queued behind a maintain tick's swap would hold SHARE on the parent while
  -- the swap's DETACH waited on it for ACCESS EXCLUSIVE.
  perform pgpm._regrain_lock(p_parent);
  execute format('lock table only %s in share mode', p_parent::text);
  loop
    v_status := pgpm.regrain_step(p_parent, v_child, p_target_step, null);
    if v_status like 'swapped:%' then return split_part(v_status, ':', 2)::int; end if;
    if v_status in ('active', 'nosubdiv', 'nokey', 'idle') then
      raise exception 'pg_partition_magician: cannot regrain % -- %', p_child,
        case v_status
          when 'active' then 'it is still active (not frozen); wait until the frontier passes its upper bound'
          when 'nosubdiv' then 'the target step does not subdivide its range'
          when 'nokey' then 'it has no primary key or unique constraint, so a resumable copy cannot identify rows; regrain is unavailable for keyless tables (the coarse monolith remains a valid, queryable state)'
          else 'nothing to regrain' end;
    end if;
    v_iter := v_iter + 1;
    if v_iter > 10000000 then raise exception 'pg_partition_magician: regrain safety limit'; end if;
    if v_lo is not null then
      select p.child_name into v_next from pgpm.part p
       where p.parent_table = p_parent and p.lo = v_lo and p.attached;
      v_child := coalesce(v_next, v_child);
    end if;
  end loop;
end;
$$;

-- regrain_history(): convenience -- regrain the oldest coarse child (the monolith: the smallest-lo attached
-- partition) to p_target_step (default: the configured partition_step). Hierarchical regraining is just
-- repeated regrain() calls with chosen steps.
create or replace function pgpm.regrain_history(p_parent regclass, p_target_step text default null)
returns int language plpgsql as $$
declare cfg pgpm.config; v_ncast text; v_mon name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  execute format('select child_name from pgpm.part where parent_table = %L::regclass and attached order by lo::%s asc limit 1',
                 p_parent::text, v_ncast) into v_mon;
  if v_mon is null then raise exception 'pg_partition_magician: % has no partitions to regrain', p_parent; end if;
  return pgpm.regrain(p_parent, v_mon, p_target_step);
end;
$$;

-- The secondary indexes transmute carries onto the new parent (step 9b recreates each as a partitioned
-- index and attaches the monolith's), and the refusals for the ones it cannot carry. Asked twice by
-- _transmute (#630): in the preflight, so that a shape it cannot carry is refused before anything is
-- committed, and again in the cutover under the table's ACCESS EXCLUSIVE, whose answer is the list 9b
-- carries. CREATE INDEX needs only SHARE, which nothing on the table excludes between the two, and an
-- index committed there followed the rename onto the monolith alone: a UNIQUE one then enforced its
-- uniqueness only for rows routed to the monolith, and none routed to a forward partition. A refusal from
-- the second asking rolls the cutover back to the resumable phase-2 state, as any cutover failure does.
--
-- Refuse an EXCLUDE constraint (#710). Its index is not unique, so the list below took it for a plain
-- secondary to carry, and step 9b rebuilt it as a plain partitioned index and tried to attach the
-- constraint's own index under it: PostgreSQL refused ("index definitions do not match") inside the
-- cutover, after phases 1 and 2 had committed the validated pgpm_monolith_bound CHECK and the claim, so
-- the table rejected every write past hi until a transmute_abort. Nothing in the conversion can carry
-- the constraint either: PostgreSQL before 17 allows no exclusion constraint on a partitioned table, and
-- the shapes 17 allows are not ones transmute builds. So it is refused HERE, up front and again under the
-- cutover's lock like every other shape this function refuses, the way from_hypertable already refuses
-- it (#675), and the way an un-carryable UNIQUE secondary is refused just below: with the remedy, before
-- anything is committed.
create or replace function pgpm._transmute_carried_indexes(
  p_parent regclass, p_nsp name, p_control name, p_ctl_attnum int, p_reuse_idx oid,
  out o_names text[], out o_defs text[])
language plpgsql as $$
declare
  v_uniq_bad text;
  v_pgpm_clash_q text;   -- #311: existing relations occupying the <index>_pgpm names step 9b needs
  v_long_idx_q text;     -- #592: carried secondary indexes whose <index>_pgpm name would exceed 63 bytes
  v_key_clash text;      -- #789: pgpm_key_<index oid>, the monolith key's name in step 8, when already taken
  v_excl_q text;
begin
  -- an EXCLUDE constraint is refused (#710, see above)
  select string_agg(quote_ident(conname), ', ' order by conname) into v_excl_q
    from pg_constraint where conrelid = p_parent and contype = 'x';
  if v_excl_q is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- its exclusion constraint(s) (%) cannot be carried onto a partitioned table (an EXCLUDE constraint''s index cannot be attached under a partitioned index). Drop them (ALTER TABLE % DROP CONSTRAINT <name>) if the table can do without them, then re-run transmute.',
      p_parent, v_excl_q, p_parent;
  end if;

  select array_agg(c.relname::text), array_agg(pg_get_indexdef(i.indexrelid)) into o_names, o_defs
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p_parent and i.indislive and not i.indisprimary
     and i.indexrelid <> coalesce(p_reuse_idx, 0::oid)
     and (not i.indisunique
          or (i.indpred is null and i.indexprs is null
              and p_ctl_attnum = any((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts])));
  -- Refuse any non-PK UNIQUE secondary that CANNOT be carried (its key omits the partition key, or it is
  -- partial / on an expression): global uniqueness cannot be enforced on the partitioned table, so this
  -- is the same refuse-with-guidance contract as the PK and incoming-FK cases, not a silent drop.
  select string_agg(c.relname, ', ' order by c.relname) into v_uniq_bad
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p_parent and i.indislive and i.indisunique and not i.indisprimary
     and not (i.indpred is null and i.indexprs is null
              and p_ctl_attnum = any((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts]));
  if v_uniq_bad is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the UNIQUE secondary index(es) (%) do not include the partition key % in their key columns (or are partial/expression indexes), so global uniqueness cannot be enforced on a partitioned table. Add % to the key of each, or drop them, then re-run transmute. A unique index that already includes % is carried automatically.',
      p_parent, v_uniq_bad, quote_ident(p_control), quote_ident(p_control), quote_ident(p_control);
  end if;

  -- Refuse a colliding <index>_pgpm name (#311). Step 9b recreates each carried secondary as a
  -- PARTITIONED index on the parent named <original>_pgpm, then attaches the monolith's original under
  -- it. Nothing checked that name was free, so a pre-existing relation by it -- a leftover from an
  -- interrupted run, or an operator's own index that happens to be named that way -- made the CREATE
  -- INDEX fail with a raw 42P07 from inside the cutover: no pgpm prefix, no guidance, and no hint that
  -- the fix is `drop index ..._pgpm`.
  --
  -- The cutover is one transaction, so that failure rolled back rather than losing anything; the cost
  -- was a confusing error and a conversion the operator then had to abort by hand. Every sibling shape
  -- here (a key that excludes the control column, a bare unique index, an un-carryable UNIQUE secondary,
  -- a transition-table trigger, an orphaned child table) refuses UP FRONT with the remedy. This was the
  -- one hole in that contract.
  --
  -- Names every collision at once: one per retry would make an operator with several re-run the
  -- conversion once per index to discover them.
  --
  -- First, the names that cannot exist at all (#592). <index>_pgpm is a name pgpm derives, so it is held
  -- to the rule every derived name is (see _part_name and the staging-name check): never truncated. An
  -- index name of 59 bytes or more leaves no room for the suffix, and the cast to name in step 9b cut it
  -- back to 63 silently. At exactly 63 bytes, which is what PostgreSQL's own auto-naming produces for a
  -- long table and column list, the cut name IS the index's own name, so the collision check below found
  -- it taken and told the operator to drop it as a leftover: advice that drops their own index. Refused
  -- here, before that check can misread it, and every offender named at once for the same reason.
  select string_agg(quote_ident(n) || ' (' || octet_length(n) || ' bytes)', ', ' order by n) into v_long_idx_q
    from unnest(coalesce(o_names, '{}'::text[])) as n
   where octet_length(n || '_pgpm') > 63;
  if v_long_idx_q is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the secondary index(es) (%) have names too long for their partitioned copies: transmute recreates each on the parent as <index>_pgpm, which would exceed PostgreSQL''s 63-byte identifier limit, and pgpm never truncates a name it derives (a truncated one names the index itself or collides with another). Give each a name of at most 58 bytes (ALTER INDEX ... RENAME), then re-run transmute.',
      p_parent, v_long_idx_q;
  end if;
  select string_agg(quote_ident(n || '_pgpm'), ', ' order by n) into v_pgpm_clash_q
    from unnest(coalesce(o_names, '{}'::text[])) as n
   where to_regclass(format('%I.%I', p_nsp, n || '_pgpm')) is not null;
  if v_pgpm_clash_q is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the name(s) (%) are already taken, and transmute needs them for the partitioned copies of this table''s secondary indexes. Most likely leftovers from an interrupted run. Drop them, then re-run transmute.',
      p_parent, v_pgpm_clash_q;
  end if;
  -- And the name step 8 gives the monolith's copy of the reused key (#789): the parent takes the key's own
  -- name, so the monolith's is renamed pgpm_key_<its index oid> first. Taken, that rename would fail raw
  -- inside the cutover, after phases 1 and 2 committed the bound and the claim. The primary key, else the
  -- reused unique constraint's index; none on a keyless table.
  select k.n into v_key_clash
    from (select 'pgpm_key_' || i.indexrelid::text as n
            from pg_index i
           where i.indrelid = p_parent and (i.indisprimary or i.indexrelid = coalesce(p_reuse_idx, 0::oid))) k
   where to_regclass(format('%I.%I', p_nsp, k.n)) is not null
   limit 1;
  if v_key_clash is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the name % is already taken, and transmute needs it for the monolith''s copy of this table''s key (the partitioned parent takes the key''s own name, so that every statement naming the key keeps working). Rename or drop %, then re-run transmute.',
      p_parent, v_key_clash, v_key_clash;
  end if;
end;
$$;

-- transmute's OUTGOING foreign keys (#263): the validated ones step 7a re-adds at the new parent, and the
-- refusal of a NOT VALID one. Asked twice by _transmute for the reason _transmute_carried_indexes is
-- (#630): up front, and under the cutover's ACCESS EXCLUSIVE, since ADD FOREIGN KEY takes only SHARE ROW
-- EXCLUSIVE and a key added in between would otherwise stay on the monolith, where every row routed to a
-- forward partition escapes it.
create or replace function pgpm._transmute_outgoing_fks(p_parent regclass, out o_names text[], out o_defs text[])
language plpgsql as $$
declare v_bad_out text;
begin
  select array_agg(c.conname::text order by c.conname),
         array_agg(pg_get_constraintdef(c.oid) order by c.conname)
    into o_names, o_defs
    from pg_constraint c
   where c.conrelid = p_parent and c.contype = 'f' and c.confrelid <> p_parent and c.conparentid = 0
     and c.convalidated;

  -- A NOT VALID outgoing key is refused, because re-adding it at the parent could not then be
  -- metadata-only. Measured on PG 17.10: adopting a VALIDATED child constraint costs 0.8 ms against a
  -- 200k-row monolith, while the same ADD over a NOT VALID one SCANS (seq_tup_read +400,000) and takes
  -- 89 ms at 2M rows -- an O(rows) scan holding SHARE ROW EXCLUSIVE on the table AND on the referenced
  -- table, which is the data-coupled blocking lock this project's acceptance rule forbids. Validating it
  -- first is the operator's call, not ours: it would either fail on rows they never checked or silently
  -- promote a constraint they deliberately left unvalidated.
  select string_agg(conname, ', ') into v_bad_out
    from pg_constraint
   where conrelid = p_parent and contype = 'f' and confrelid <> p_parent and conparentid = 0
     and not convalidated;
  if v_bad_out is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- its outgoing foreign key(s) (%) are NOT VALID. pgpm re-adds an outgoing key on the new parent, which is metadata-only only when the key is already validated; over a NOT VALID one PostgreSQL would rescan the whole table under a lock that blocks writes on it and on the referenced table. Run ALTER TABLE % VALIDATE CONSTRAINT <name> first (or drop the constraint), then re-run transmute.',
      p_parent, v_bad_out, p_parent::text;
  end if;
end;
$$;

-- #656: where an identity sequence resumes so that it re-issues nothing, read under the lock. transmute's
-- cutover and untransmute call it under the ACCESS EXCLUSIVE that stops every writer of p_rel, which is
-- what makes the answer final. Both used to read these values before that lock, and an id handed out in
-- between was handed out again by the reseeded sequence: the next inserts failed with a duplicate key, one
-- per re-issued id. It returns the three values _identity_reseed (#670) walks the sequence's lattice from:
-- o_next, the sequence's own next value (last_value plus its INCREMENT, _seq_next), and o_max and o_min,
-- the ids it has to clear (max for an ascending sequence, min for a descending one).
--
-- The max and min are read here only when an index answers them in one descent each (a valid, non-partial
-- btree whose leading key is the column), because an O(rows) scan under that lock is the data-coupled
-- outage this project refuses. Otherwise p_max and p_min, the ones the caller read before the lock, where
-- a scan blocks no writer, stand in for them. The sequence's position is read here either way (p_next, the
-- caller's earlier read, only when there is no sequence), and it covers every id the sequence issued, which
-- is every id an insert did not supply itself.
drop function if exists pgpm._identity_resume_at(regclass, name, bigint);   -- #670: the pre-lattice shape
create or replace function pgpm._identity_resume_at(p_rel regclass, p_col name,
                                                    p_next numeric, p_max bigint, p_min bigint,
                                                    out o_next numeric, out o_max bigint, out o_min bigint)
language plpgsql as $$
declare v_max bigint; v_min bigint;
begin
  o_max := p_max;
  o_min := p_min;
  if exists (select 1 from pg_index i
               join pg_class ic on ic.oid = i.indexrelid
               join pg_am am on am.oid = ic.relam and am.amname = 'btree'
               join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
              where i.indrelid = p_rel and i.indisvalid and i.indpred is null and a.attname = p_col) then
    execute format('select max(%1$I)::bigint, min(%1$I)::bigint from %2$s', p_col, p_rel::text) into v_max, v_min;
    o_max := greatest(v_max, p_max);   -- greatest/least ignore a null: an empty table clears nothing
    o_min := least(v_min, p_min);
  end if;
  o_next := coalesce(pgpm._seq_next(pg_get_serial_sequence(p_rel::text, p_col)::regclass), p_next);
end;
$$;

-- transmute's gate on incoming foreign keys (step 0), asked twice by _transmute (#706): in the preflight, so
-- that a key it cannot keep is refused before anything is committed, and again in the cutover under the
-- table's ACCESS EXCLUSIVE, just before 0c acts on what is live. ADD FOREIGN KEY takes only SHARE ROW
-- EXCLUSIVE on the referenced table, which nothing on it excludes between the two, so with p_incoming_fks
-- => 'error' a key committed there was neither refused nor dropped (0c runs for 'preserve' only) and
-- followed the rename onto the monolith: the referencing table was left keyed against ONE PARTITION, and a
-- reference to a row routed to a forward partition was refused. A refusal from the second asking rolls the
-- cutover back to the resumable phase-2 state, as any cutover failure does. p_keycols is the reused key
-- (null for a keyless table), which an incoming key must reference exactly to be preserved.
create or replace function pgpm._transmute_incoming_gate(p_parent regclass, p_incoming_fks text, p_keycols text[])
returns void language plpgsql stable as $$
declare v_fk record;
begin
  if not exists (select 1 from pg_constraint where confrelid = p_parent and contype = 'f') then
    return;
  end if;
  if p_incoming_fks = 'error' then
    raise exception
      'pg_partition_magician: % has incoming foreign key(s) (%). Re-run with p_incoming_fks => ''preserve'' to keep them: pgpm drops each for the conversion and re-adds it against the new parent on a later maintenance tick (or call pgpm.restore_incoming_fks to do it now).',
      p_parent,
      (select string_agg(conname || ' on ' || conrelid::regclass::text, ', ')
         from pg_constraint where confrelid = p_parent and contype = 'f');
  end if;
  -- 'preserve' (and 'drop'): preservable iff the parent keeps a unique key on EXACTLY this FK's referenced
  -- columns. pgpm reuses the existing key verbatim (the PK, or a unique constraint when there is no usable
  -- PK), so the FK must reference that reused key -- both a PK and a unique constraint are valid FK
  -- targets. The only way it can't is an FK referencing a different unique key that cannot survive
  -- partitioning (one not including the partition key) -- refuse with guidance.
  for v_fk in
    select c.conrelid::regclass as reltbl, c.conname,
           (select array_agg(a.attname::text order by k.ord) from unnest(c.confkey) with ordinality as k(attnum, ord)
              join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as rcols
      from pg_constraint c where c.confrelid = p_parent and c.contype = 'f'
  loop
    if not (p_keycols is not null
            and (select array_agg(x order by x) from unnest(v_fk.rcols) x)
              = (select array_agg(x order by x) from unnest(p_keycols) x)) then
      raise exception 'pg_partition_magician: cannot preserve incoming FK % on % -- it references (%), but the parent''s reused key is (%). An incoming FK must reference the reused primary key or unique constraint to be preserved.',
        v_fk.conname, v_fk.reltbl, array_to_string(v_fk.rcols, ', '), array_to_string(coalesce(p_keycols, '{}'), ', ');
    end if;
  end loop;
end;
$$;

-- The one trigger shape a partitioned table cannot host (#277), refused. Asked twice by _transmute (#706):
-- in the preflight, and again in the cutover under the table's ACCESS EXCLUSIVE, beside the trigger capture.
-- CREATE TRIGGER takes only SHARE ROW EXCLUSIVE, so a row trigger with a transition table committed in
-- between was captured and replayed onto the parent, where PostgreSQL refused it with a raw error naming
-- neither pgpm nor the remedy.
create or replace function pgpm._transmute_refuse_transition_triggers(p_parent regclass)
returns void language plpgsql stable as $$
declare v_bad_trg text;
begin
  -- Measured on PG 17.10: this is the ONLY refusal needed. Constraint triggers, statement triggers, WHEN
  -- clauses, UPDATE OF, and even statement triggers WITH transition tables all transfer to a partitioned
  -- parent; only a FOR EACH ROW trigger with a transition table is rejected. Refusing beats converting and
  -- dropping it, which is the silent-loss failure this whole issue is about.
  select string_agg(tgname, ', ' order by tgname) into v_bad_trg
    from pg_trigger
   where tgrelid = p_parent and not tgisinternal
     and (tgoldtable is not null or tgnewtable is not null)
     and (tgtype & 1) = 1;   -- TRIGGER_TYPE_ROW
  if v_bad_trg is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the row trigger(s) (%) use a transition table (REFERENCING OLD/NEW TABLE), which PostgreSQL does not allow on a partitioned table. Rewrite them as statement triggers (those DO carry a transition table) or drop them, then re-run transmute. pgpm refuses rather than converting and leaving the trigger behind on one child.',
      p_parent, v_bad_trg;
  end if;
end;
$$;

-- Objects that name a table by its OID, refused (#779). A view's query, a materialized view's, a rule's
-- action, a SQL-standard function body (BEGIN ATOMIC) and a policy's expression are stored as parse
-- trees that name each relation by oid, not by name. transmute's cutover renames the original table, and
-- with it that oid, into the monolith partition, so every one of them followed it there: a view over the
-- table read the monolith's rows alone and missed every row routed to a forward partition, with no error
-- and nothing logged, and a materialized view refreshed to the same narrowed answer. A rule on the table
-- itself stayed on the monolith and stopped firing for writes through the parent.
--
-- Refused rather than carried. Re-pointing them would mean replaying each definition against the parent
-- inside the cutover's lock: in dependency order across chains of views, with a materialized view dropped,
-- re-created and refreshed (a scan of the whole table under ACCESS EXCLUSIVE), and its indexes, grants and
-- comments rebuilt, and a function or a policy on another table re-created by hand. Each of those is a
-- shape that could be wrong without failing. A refusal names them all and changes nothing.
--
-- Asked by transmute in the preflight, before anything is committed, and again in the cutover under the
-- table's ACCESS EXCLUSIVE, which every one of these statements has to wait for (each takes at least
-- ACCESS SHARE on the table it parses), so one created in between is refused there and rolls the cutover
-- back to the resumable phase-2 state. Asked by untransmute for the symmetric case: an object created over
-- the PARENT after the conversion names the parent's oid, and untransmute drops the parent, which either
-- fails raw on it ("other objects depend on it") or, for a rule on the parent, takes it along silently.
--
-- A policy on the table itself is not one of these: both directions carry the table's own policies by
-- re-parsing their text against the table that takes the name. Nor is one on p_staging, the cutover's new
-- parent, which holds those carried copies by the time the cutover asks.
create or replace function pgpm._refuse_oid_bound_dependants(p_rel regclass, p_untransmute boolean,
                                                             p_staging regclass default null)
returns void language plpgsql stable as $$
declare v_deps_q text;
begin
  select string_agg(o.what_q, ', ' order by o.what_q) into v_deps_q
    from (select distinct
                 case d.classid
                   when 'pg_rewrite'::regclass then
                     (select case when c.relkind = 'v' then 'view ' || c.oid::regclass::text
                                  when c.relkind = 'm' then 'materialized view ' || c.oid::regclass::text
                                  else 'rule ' || quote_ident(r.rulename) || ' on ' || c.oid::regclass::text end
                        from pg_rewrite r join pg_class c on c.oid = r.ev_class where r.oid = d.objid)
                   when 'pg_proc'::regclass then 'function ' || d.objid::regprocedure::text
                   when 'pg_policy'::regclass then
                     (select 'policy ' || quote_ident(p.polname) || ' on ' || p.polrelid::regclass::text
                        from pg_policy p where p.oid = d.objid and p.polrelid <> p_rel
                         and p.polrelid is distinct from p_staging)
                 end as what_q
            from pg_depend d
           where d.refclassid = 'pg_class'::regclass and d.refobjid = p_rel
             and d.classid in ('pg_rewrite'::regclass, 'pg_proc'::regclass, 'pg_policy'::regclass)) o
   where o.what_q is not null;
  if v_deps_q is null then
    return;
  end if;
  if p_untransmute then
    raise exception 'pg_partition_magician: cannot untransmute % -- the object(s) (%) name the partitioned table by its oid, and untransmute drops that table to hand the original back under its name, so the DROP would fail on them, or take a rule on the table along with it. Drop them, run untransmute, then re-create them against the restored table.',
      p_rel, v_deps_q;
  end if;
  raise exception 'pg_partition_magician: cannot transmute % -- the object(s) (%) name it by its oid, and the conversion hands that oid to the monolith partition, so each would go on reading or writing the monolith alone and silently miss every row routed to a forward partition. Drop them, run transmute, then re-create them against the converted table, where they name the new parent and see every partition (pg_get_viewdef, pg_get_ruledef and pg_get_functiondef give their definitions). pgpm refuses rather than leaving them bound to one partition.',
    p_rel, v_deps_q;
end;
$$;

-- What transmute's preflight plans the key and the identity from (#706): the primary key and unique
-- constraints (columns and backing index), the identity columns and their kinds, and whether the control
-- column is NOT NULL. Compared by _transmute after the staging LIKE, whose ACCESS SHARE excludes every
-- statement that changes any of it (ADD/DROP CONSTRAINT, ADD/SET/DROP IDENTITY, SET/DROP NOT NULL all take
-- ACCESS EXCLUSIVE). Between the preflight and that LIKE, phases 1 and 2 commit and let go of the table, so
-- a key replaced or an identity re-declared there was unseen: step 6 re-added identity in the preflight's
-- form (an identity made ALWAYS came back BY DEFAULT) and step 8 declared the preflight's key, building an
-- index on the monolith under the outage for a key the table no longer had.
create or replace function pgpm._transmute_key_shape(p_parent regclass, p_control name)
returns text language sql stable as $$
  select concat_ws(' / ',
    (select string_agg(c.contype::text || '(' || c.conkey::text || ')@' || c.conindid::text, ',' order by c.contype, c.conkey::text, c.conindid)
       from pg_constraint c where c.conrelid = p_parent and c.contype in ('p', 'u')),
    (select string_agg(a.attnum::text || ':' || a.attidentity::text, ',' order by a.attnum)
       from pg_attribute a where a.attrelid = p_parent and a.attidentity in ('a', 'd') and not a.attisdropped),
    (select 'notnull:' || a.attnotnull::text
       from pg_attribute a where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped));
$$;

-- The bare unique index transmute refuses to take as the key (#792): a live, non-partial, non-expression
-- unique index, not the primary key and backing no constraint, whose key columns include the control
-- column, on a table with no primary key and no unique constraint transmute would reuse instead (the
-- branch of _transmute's key selection that raises "is a bare index, not a constraint"). Null when
-- transmute would reuse a key, or partition the table keyless. Shared by _transmute and by pgpm_hypertable,
-- whose cutover drops the hypertable before transmute asks, so it asks first.
create or replace function pgpm._transmute_bare_unique(p_parent regclass, p_control name)
returns name language sql stable as $$
  select c.relname
    from pg_index i join pg_class c on c.oid = i.indexrelid
    join pg_attribute a on a.attrelid = i.indrelid and a.attname = p_control and not a.attisdropped
   where i.indrelid = p_parent and i.indislive and i.indisunique and not i.indisprimary
     and i.indpred is null and i.indexprs is null
     and a.attnum = any((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts])
     and not exists (select 1 from pg_constraint con where con.conindid = i.indexrelid)
     and not exists (select 1 from pg_constraint con where con.conrelid = p_parent and con.contype = 'p')
     and not exists (select 1 from pg_constraint con join pg_index ui on ui.indexrelid = con.conindid
                      where con.conrelid = p_parent and con.contype = 'u'
                        and ui.indpred is null and ui.indexprs is null and a.attnum = any(con.conkey))
   limit 1;
$$;

-- The latest a time-ordered table's newest row may sit before transmute refuses its frontier (#457): one
-- step plus one hour past now() (the reasoning is at the check in _transmute). Shared with pgpm_hypertable,
-- which asks it before its swap (#792). now() is the transaction's start, so a later transaction's limit is
-- never earlier: a table that passes here passes transmute's own check too, unless a newer row arrives.
create or replace function pgpm._frontier_skew_limit(p_step interval)
returns timestamptz language sql stable as $$
  select now() + p_step + interval '1 hour';
$$;

-- ============================== transmute ==============================

-- #275 turned these from FUNCTIONs into PROCEDUREs. CREATE OR REPLACE cannot change that, so the old
-- forms have to go first; an existing install upgrades cleanly through this.
drop function if exists pgpm._transmute(regclass, name, text, text, text, int, text, boolean, int, boolean, text, boolean, boolean);
drop function  if exists pgpm.transmute(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text, boolean, boolean);
drop function  if exists pgpm.transmute(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text, boolean);
-- #288 dropped p_keep_default and p_drain_adaptive and renamed p_drain_batch, so the previous PROCEDURE
-- forms must go as well or an upgrade leaves two overloads and every call becomes ambiguous.
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text, boolean, boolean, int);
drop procedure if exists pgpm.transmute(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text, boolean, int);
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, boolean, int, boolean, text, boolean, boolean, int);

-- _transmute: a publication naming the table that the caller does not own is refused up front. The
-- cutover's ALTER PUBLICATION ... ADD TABLE needs the caller to own each of those publications
-- (#710). A role that may convert the table (it owns the table) but not alter a publication naming it,
-- one a replication administrator created, failed there with a raw "must be owner of publication",
-- after phases 1 and 2 had committed the validated bound and the claim, so the table rejected every
-- write past hi until a transmute_abort. Leaving the parent out of the publication is the #566 defect
-- itself, so this is a refusal, not a skip, and it costs nothing here. pg_has_role(..., 'USAGE') is the
-- test PostgreSQL's ownership check applies: superuser, or the owner role's privileges by inheritance.
create or replace procedure pgpm._transmute(
  p_parent regclass, p_control name, p_control_kind text,
  p_step text, p_anchor text, p_obtain int, p_retain text,
  p_regrain_batch int, p_paused boolean, p_incoming_fks text,
  p_force_uuidv7 boolean default false, p_bound_headroom int default 0,
  p_lock_timeout text default '5s',
  -- text_time only (issue #325 follow-up): a general opaque-sortable-TEXT id, e.g. classic cuid
  -- (p_tt_prefix 'c', p_tt_width 8, p_tt_radix 36, p_tt_unit 'ms'). Null for every other kind.
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_force_text_time boolean default false,
  -- covers formats the plain cuid case does not need: a custom digit alphabet (ULID's Crockford
  -- base32, KSUID's base62 -- neither is the default contiguous 0-9a-z), and a timestamp that is the
  -- top bits of a WIDER encoded value against a non-Unix epoch (KSUID: discard the low 128 bits of its
  -- whole-payload base62 encoding, epoch 2014-05-13 16:53:20+00).
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00',
  -- time/uuidv7/text_time (#457, time since #668): accept a data-driven frontier that sits far ahead of the
  -- clock, and with it a monolith hi pinned that far out. Ignored for id, whose frontier has no clock.
  p_force_frontier boolean default false
)
language plpgsql as $$
declare
  v_nsp name; v_rel name; v_relkind "char"; v_default name; v_staging name; v_parent regclass;
  v_resumed boolean := false;
  v_typname text; v_oldpk text[]; v_pkcols text[]; v_idcols name[]; v_pkname name; v_col name;
  v_idkinds text[];   -- #308: 'a' (ALWAYS) or 'd' (BY DEFAULT) per v_idcols entry, same order
  v_idx_names text[]; v_idx_defs text[]; v_ctl_attnum int; v_old name; v_new name; v_pdef_q text; j int;
  v_ipfx_q text; v_upfx_q text;   -- #669: the two prefixes pg_get_indexdef can start a carried index's definition with
  v_add_pk boolean := false; v_add_uniq boolean := false; v_reuse_idx oid; v_reuse_conname name;
  v_uq_cols text[]; v_bare_uq text;
  v_fk record;
  v_out_names text[]; v_out_defs text[]; v_i2 int;   -- outgoing FKs (#263), listed by _transmute_outgoing_fks
  v_uchk_n bigint; v_uchk_frac numeric;
  v_idmax bigint[]; v_m bigint; v_i int; v_idnext numeric[];   -- #656: all three refreshed under the cutover's lock
  v_idmin bigint[]; v_mmin bigint;   -- #670: min(identity), for a descending identity's reseed
  v_idopts text[]; v_opt text;      -- #732: the sequence options step 6 used, and their re-read under the lock
  v_keyshape text;                  -- #706: what the preflight planned the key and identity from
  v_ra record;                       -- #656/#670: one identity column's refreshed (next, max, min)
  v_monolith name; v_monreg regclass;
  v_tz text;   -- #455: the zone the grid is computed in, recorded in config.partition_tz
  v_claim_tz text;   -- #506: the zone recorded with the claim, which a resume adopts along with the bound
  v_claim_attnum smallint;   -- #628: the control column recorded with the claim, which a resume must match
  v_frontier_native text; v_min_raw text; v_max_raw text; v_min_native text; v_lo_native text; v_hi_native text;
  v_max_ts timestamptz; v_skew_limit timestamptz;   -- #457: the decoded data maximum and how far ahead of now() it may sit
  -- #277: everything CREATE TABLE ... LIKE does NOT carry, captured before the rename and replayed onto
  -- the new parent inside the cutover transaction.
  v_owner name; v_acl aclitem[]; v_rls boolean; v_rls_force boolean;
  v_comment text; v_colcom record; v_pol record; v_trg record;
  v_prev_lock_timeout text;   -- #309: so validating p_lock_timeout leaves the setting untouched
  v_trgdefs text[] := '{}'; v_grant text; v_g record;
  v_trgnames text[] := '{}'; v_trgstates text[] := '{}';   -- #499: tgname and tgenabled, index-aligned with v_trgdefs
  v_bad_pub text; v_pub record;   -- #566: publication membership, refused or carried
  v_bad_con text;                 -- #730: constraints the cutover cannot carry (NOT VALID, NO INHERIT)
  v_key_defer text := '';         -- #731: the reused key's DEFERRABLE / INITIALLY DEFERRED, carried onto the parent
  v_key_name name; v_key_idx oid; -- #789: the reused key's constraint name, which the parent takes, and its index
  v_replident "char"; v_ri_idx name;   -- #782: the table's replica identity, and the parent index it maps to
  v_unowned_pub_q text;
  v_sq record;                    -- #573: sequences the table owns through a column
begin
  if p_control_kind not in ('time', 'id', 'uuidv7', 'text_time') then
    raise exception 'pg_partition_magician: unknown control_kind %', p_control_kind;
  end if;
  if p_incoming_fks not in ('error', 'drop', 'preserve') then
    raise exception 'pg_partition_magician: p_incoming_fks must be ''error'', ''drop'', or ''preserve'' (got %)', p_incoming_fks;
  end if;
  -- #451: retain cannot be negative. Nothing checked its sign, so `p_retain => interval '-1 day'` (a typo
  -- away from the intended value) registered a horizon in the FUTURE, and the first maintenance tick
  -- write-blocked and dropped every partition, the one taking writes included; the next insert failed with
  -- `no partition of relation ... found for row`. Refused HERE, before anything is committed, for the same
  -- reason the lock-timeout check below is: a typo should cost nothing. Zero is allowed: it keeps only the
  -- partition taking writes. set_retain applies the same rule, and _retain_boundary refuses a value that
  -- reached config by any other route (a hand edit).
  if p_retain is not null and not pgpm._retain_nonnegative(p_control_kind, p_retain) then
    raise exception 'pg_partition_magician: p_retain cannot be negative (got %) -- a negative retain puts the retention horizon past the partition taking writes, so the first maintenance tick would drop every partition, that one included; zero keeps only the partition taking writes, null keeps everything', p_retain;
  end if;
  -- #581: the step must be positive, which nothing checked either. A negative one made _grid_floor and
  -- _grid_next yield lo > hi, so phase 1 committed an unsatisfiable pgpm_monolith_bound CHECK, phase 2's
  -- VALIDATE failed, and the live table rejected every write until an abort (a corrected re-run resumed
  -- the same recorded bound and failed again); a zero one divided by zero. "Positive" is read the way the
  -- grid functions read the step: a whole number of months (a calendar step), or else a duration whose
  -- length in seconds is positive. A negative month count is refused whatever else the interval holds.
  if p_control_kind = 'id' then
    if p_step::numeric <= 0 then
      raise exception 'pg_partition_magician: the partition step must be positive (got %) -- a step that is not makes every partition''s lower bound its upper one or past it, so the monolith''s bound CHECK could admit no row and the table would reject every write', p_step;
    end if;
  elsif (extract(year from p_step::interval) * 12 + extract(month from p_step::interval)) < 0
     or ((extract(year from p_step::interval) * 12 + extract(month from p_step::interval)) = 0
         and extract(epoch from p_step::interval) <= 0) then
    raise exception 'pg_partition_magician: the partition step must be positive (got %) -- a step that is not makes every partition''s lower bound its upper one or past it, so the monolith''s bound CHECK could admit no row and the table would reject every write', p_step;
  end if;
  -- #581: and the lookahead cannot be negative or null, the rule set_obtain applies. obtain's
  -- `for k in 0 .. cfg.obtain` never runs for a negative value, so the conversion completed with no forward
  -- partition, no tick ever built one, and the first write past the monolith's hi failed.
  if p_obtain is null or p_obtain < 0 then
    raise exception 'pg_partition_magician: p_obtain must be a non-negative integer (got %)', p_obtain;
  end if;
  -- #309: validate the lock timeout HERE, before anything is committed. set_config raises on a bad value
  -- anyway, but it would do so from inside phase 1 or, worse, phase 3 -- after the O(rows) validation
  -- scan the operator has already waited through. A typo should cost nothing.
  --
  -- The prior value is restored immediately, so this check has NO side effect. That is not tidiness: the
  -- phases below share this transaction with the check, so a validation that left the setting applied
  -- would silently do phase 1's job for it. The mutation that proves bench/transmute_lock_timeout.sh
  -- discriminates strips the per-phase set_config calls, and it would strip them onto a transaction that
  -- was already correctly configured -- a guard that passed against its own defect.
  begin
    v_prev_lock_timeout := current_setting('lock_timeout');
    perform set_config('lock_timeout', p_lock_timeout, true);
    perform set_config('lock_timeout', v_prev_lock_timeout, true);
  exception when others then
    raise exception 'pg_partition_magician: p_lock_timeout must be a valid lock_timeout value (got %): %', p_lock_timeout, sqlerrm;
  end;

  select n.nspname, c.relname, c.relkind into v_nsp, v_rel, v_relkind
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- #509: transmute converts an ORDINARY table, once. Nothing checked either, and every shape refused here
  -- was discovered by the cutover instead, AFTER phases 1 and 2 had committed a validated, write-rejecting
  -- pgpm_monolith_bound CHECK and the claim. The worst case was a re-run against an already converted
  -- table, which is the documented remedy after any failure and what a client that lost its connection
  -- after the cutover committed will do: phase 1 added the bound to the live PARTITIONED parent, where it
  -- propagates to every partition including the forward ones taking writes; phase 2 validated it; the
  -- cutover then failed on the monolith's name, and the bound stayed, rejecting every write past the
  -- ORIGINAL monolith's hi, i.e. every current write, until an abort or the sweep. With the frontier past
  -- the monolith it instead succeeded and nested the whole table under a second parent. The other shapes
  -- fail the cutover's ATTACH ("is already a partition", "cannot attach inheritance parent") the same way.
  -- All four cost nothing to refuse here, before anything is committed.
  if exists (select 1 from pgpm.config where parent_table = p_parent) then
    raise exception 'pg_partition_magician: % is already converted and managed by pgpm (it has a pgpm.config row), so there is nothing to convert or resume: transmute converts a table once. If this is a retry after an error, the earlier run''s cutover did commit; see pgpm.status(). A re-run would have added a second write-rejecting pgpm_monolith_bound CHECK to the live partitioned parent.',
      p_parent;
  end if;
  if v_relkind <> 'r' then
    raise exception 'pg_partition_magician: % is a %, not a plain table. transmute converts an ordinary table only: neither partitioned nor a member of an inheritance tree.',
      p_parent, pgpm._relkind_noun(v_relkind);
  end if;
  if exists (select 1 from pg_inherits where inhrelid = p_parent) then
    raise exception 'pg_partition_magician: % is already a partition of % (or an inheritance child of it). transmute converts a standalone table only: its cutover attaches the table to a new parent, and a table can be attached to one parent at a time. Convert the parent instead, or detach % first.',
      p_parent, (select string_agg(inhparent::regclass::text, ', ') from pg_inherits where inhrelid = p_parent), p_parent;
  end if;
  if exists (select 1 from pg_inherits where inhparent = p_parent) then
    raise exception 'pg_partition_magician: % has inheritance children (%). transmute converts a standalone table only: its cutover attaches the table to a new parent, and PostgreSQL refuses to attach an inheritance parent as a partition.',
      p_parent, (select string_agg(inhrelid::regclass::text, ', ' order by inhrelid) from pg_inherits where inhparent = p_parent);
  end if;

  v_default := (v_rel || '_default')::name;
  -- #510: the staging name is held to the same rule as every partition name (see _part_name): never
  -- truncated. The cast to name below silently cuts it to 63 bytes, and at a 61-character table name the
  -- cut staging name equalled the cut monolith name, so phase 3's RENAME failed after phases 1 and 2 had
  -- committed. _part_name refuses the monolith's own name before anything is committed (further down);
  -- this is the one derived name it never sees, so it is checked here, first, for the same up-front refusal.
  if octet_length(v_rel || '_pgpm_new') > 63 then
    raise exception 'pg_partition_magician: cannot transmute % -- its staging name % is % bytes, over PostgreSQL''s 63-byte identifier limit, and pgpm never truncates a name it derives from the table''s (a truncated one can collide with another). Shorten the table name by at least % byte(s).',
      p_parent, v_rel || '_pgpm_new', octet_length(v_rel || '_pgpm_new'), octet_length(v_rel || '_pgpm_new') - 63;
  end if;
  v_staging := (v_rel || '_pgpm_new')::name;

  -- control column type vs kind (and the float guard)
  select t.typname into v_typname
    from pg_attribute a join pg_type t on t.oid = a.atttypid
   where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped;
  if v_typname is null then
    raise exception 'pg_partition_magician: column % not found on %', p_control, p_parent;
  end if;
  -- #730: and a column PostgreSQL can partition by at all. A GENERATED one (STORED, or VIRTUAL on 18)
  -- passed the type check below, phases 1 and 2 committed the validated bound on it and the claim, and the
  -- cutover's CREATE TABLE ... PARTITION BY RANGE died with a raw "cannot use generated column in partition
  -- key", on every retry, leaving the table rejecting each write past hi until an abort or the sweep.
  if (select a.attgenerated from pg_attribute a
       where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) <> '' then
    raise exception 'pg_partition_magician: cannot partition % on % -- it is a generated column, and PostgreSQL cannot use a generated column in a partition key. Partition on a plain column instead (the one it is computed from, when that is time-ordered), then re-run transmute.',
      p_parent, quote_ident(p_control);
  end if;
  if p_control_kind = 'time' and v_typname not in ('timestamptz', 'timestamp', 'date') then
    raise exception 'pg_partition_magician: control_kind time needs a timestamp/date column (got %)', v_typname;
  elsif p_control_kind = 'time' and v_typname = 'date'
        and (extract(year from p_step::interval) * 12 + extract(month from p_step::interval)) = 0
        and extract(epoch from p_step::interval)::numeric % 86400 <> 0 then
    -- #581: a date holds whole days, and every bound literal a finer step renders is truncated to its date,
    -- so the monolith's CHECK became dt < current_date (validated in phase 2) and the cutover died on the
    -- first hourly cell, whose two bounds read as the same date, leaving the table rejecting every row
    -- dated today. A calendar step (months) is whole days by construction; a duration has to be a whole
    -- number of 86400 s days.
    raise exception 'pg_partition_magician: the date column % holds whole days, so its partition step must be a whole number of days or months (got %) -- a finer step''s bounds truncate to dates, so the monolith''s bound CHECK would reject every row dated today and the cutover would fail on an empty partition range', quote_ident(p_control), p_step;
  elsif p_control_kind = 'id' then
    if v_typname in ('float4', 'float8') then
      raise exception 'pg_partition_magician: float/double control columns are unsupported (imprecise boundaries; NaN/Inf poison the frontier) -- use bigint or numeric';
    elsif v_typname not in ('int2', 'int4', 'int8', 'numeric') then
      raise exception 'pg_partition_magician: control_kind id needs an integer or numeric column (got %)', v_typname;
    end if;
  elsif p_control_kind = 'uuidv7' and v_typname <> 'uuid' then
    raise exception 'pg_partition_magician: control_kind uuidv7 needs a uuid column (got %)', v_typname;
  elsif p_control_kind = 'text_time' then
    if v_typname not in ('text', 'varchar') then
      raise exception 'pg_partition_magician: control_kind text_time needs a text or varchar column (got %)', v_typname;
    end if;
    if p_tt_prefix is null or p_tt_width is null or p_tt_radix is null or p_tt_unit is null then
      raise exception 'pg_partition_magician: control_kind text_time needs p_tt_prefix, p_tt_width, p_tt_radix and p_tt_unit all set -- e.g. classic cuid: prefix ''c'', width 8, radix 36, unit ''ms''';
    end if;
    -- p_tt_alphabet's own length IS the radix ceiling when supplied (ULID needs 32, KSUID needs 62);
    -- without one, the default contiguous 0-9a-z convention caps out at 36.
    if p_tt_alphabet is not null then
      if length(p_tt_alphabet) <> p_tt_radix then
        raise exception 'pg_partition_magician: p_tt_alphabet % has length %, which does not match p_tt_radix %', p_tt_alphabet, length(p_tt_alphabet), p_tt_radix;
      end if;
      if length(p_tt_alphabet) <> (select count(distinct c) from unnest(regexp_split_to_array(p_tt_alphabet, '')) c) then
        raise exception 'pg_partition_magician: p_tt_alphabet % has a repeated character, which makes decoding ambiguous', p_tt_alphabet;
      end if;
    elsif p_tt_radix < 2 or p_tt_radix > 36 then
      raise exception 'pg_partition_magician: p_tt_radix must be 2-36 for the default 0-9a-z alphabet (got %); supply p_tt_alphabet for a wider or different one', p_tt_radix;
    end if;
    if p_tt_width < 1 then
      raise exception 'pg_partition_magician: p_tt_width must be positive (got %)', p_tt_width;
    end if;
    if p_tt_unit not in ('ms', 's') then
      raise exception 'pg_partition_magician: p_tt_unit must be ''ms'' or ''s'' (got %)', p_tt_unit;
    end if;
    if p_tt_discard_bits < 0 then
      raise exception 'pg_partition_magician: p_tt_discard_bits must not be negative (got %)', p_tt_discard_bits;
    end if;
    -- #456: the alphabet has to order the way base-N place value does UNDER THE COLUMN'S COLLATION, or
    -- the bounds this kind computes route rows to the wrong partition (see _check_text_time_collation).
    -- Not gated by p_force_text_time: that flag overrides a sampling heuristic, and this is arithmetic.
    perform pgpm._check_text_time_collation(p_parent, p_control, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_alphabet);
  end if;

  -- #455: the zone the grid is computed in, for the life of the table. The transmuting session's, so the
  -- grid the operator sees at conversion is the grid maintenance keeps extending whatever zone pg_cron's
  -- session runs in. Only a pg_timezone_names name is recorded (see _canonical_tz), and this is checked
  -- before anything is committed, so a refusal costs nothing.
  --
  -- 'UTC' for an id grid, which has no calendar, and for a NAIVE control column (timestamp without time
  -- zone, date), which has no zone (#504): its values are wall readings, and the grid is computed on that
  -- wall clock directly, so a day is [D 00:00, D+1 00:00) in the column's own values, an hour
  -- [H:00, H+1:00), a month [1st 00:00, next 1st 00:00), and every bound literal is that reading with no
  -- offset. That is exactly the UTC lattice. Reading the column as wall time in the session's zone
  -- instead put the absolute day and hour lattices off the column's clock: a New York session rendered
  -- the 00:00Z day boundary as 20:00 the previous day, which a date column read as the previous DATE, so
  -- the monolith's CHECK excluded every row dated today and phase 2's VALIDATE failed after phase 1 had
  -- committed; and the two hourly cells either side of a fall-back rendered to the same naive wall time,
  -- an empty range CREATE TABLE refused, so the grid could never extend past that hour. set_partition_tz
  -- refuses to change it for such a column, because the zone also decides how its literals are read.
  if p_control_kind = 'id' or (p_control_kind = 'time' and v_typname in ('timestamp', 'date')) then
    v_tz := 'UTC';
  else
    v_tz := pgpm._canonical_tz(current_setting('TimeZone'));
    if v_tz is null then
      raise exception 'pg_partition_magician: this session''s TimeZone (%) is not a name in pg_timezone_names, and pgpm records the transmuting session''s zone as the one the partition grid is computed in for the life of the table. Set a named zone first (set timezone = ''UTC'' for UTC-aligned boundaries, the usual choice) and re-run.', current_setting('TimeZone');
    end if;
  end if;

  -- Orphaned-child guard (REDESIGN.md): regrain creates each fine child as a standalone table
  -- (CREATE TABLE ... LIKE) and only ATTACHes it at the swap. An interrupted regrain therefore
  -- leaves an un-attached child -- which DROP TABLE <parent> CASCADE does NOT remove (an
  -- un-attached table has no dependency on the parent). If the table is later recreated/reloaded
  -- and re-transmuted, the next regrain reuses the orphan by name and INSERTs rows whose keys
  -- already live in it: a cryptic mid-regrain "duplicate key" deep inside regrain_step.
  -- Refuse up front -- any standalone (un-attached) table in this schema whose name matches this
  -- parent's child-partition naming (<rel>_p<label>) is an orphan. starts_with handles the
  -- (un-escaped) rel prefix; _is_fine_child_label decides whether the suffix is a fine child's label,
  -- the same helper restore_incoming_fks's in-flight gate asks (#726).
  --
  -- Any relkind, not tables only (#509): a sequence, view or index holding a child's name occupies that
  -- name just the same, and the relkind filter this once had let it through to obtain, which skips any
  -- candidate whose name is taken (`continue when to_regclass(...) is not null`, its way of recognising
  -- a partition it already made). The conversion then COMPLETED with no forward partition and nothing
  -- logged: the first write past hi failed with "no partition of relation ... found for row", and every
  -- later tick skipped the name again. Only a table can be a regrain orphan, so only a table gets that
  -- diagnosis; anything else is named for what it is. The monolith's own coarse name is a different
  -- shape (<rel>_p<lo>_to_<hi>) and is checked separately, just before phase 1, once the bound that
  -- determines it is final.
  declare v_orphan name; v_orphan_kind "char";
  begin
    select c.relname, c.relkind into v_orphan, v_orphan_kind
      from pg_class c
     where c.relnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)
       and starts_with(c.relname, v_rel || '_p')
       and pgpm._is_fine_child_label(p_control_kind, substr(c.relname, length(v_rel) + 3))
       and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
     limit 1;
    if v_orphan is not null and v_orphan_kind = 'r' then
      raise exception 'pg_partition_magician: %.% already exists as a standalone table matching this parent''s partition naming -- most likely an orphan left by an interrupted regrain. Drop it (drop table %.%) and retry transmute.',
        v_nsp, v_orphan, quote_ident(v_nsp), quote_ident(v_orphan);
    elsif v_orphan is not null then
      raise exception 'pg_partition_magician: %.% already exists as a % matching this parent''s partition naming, and the conversion would collide with it when it creates that partition. Drop or rename it and retry transmute.',
        v_nsp, v_orphan, pgpm._relkind_noun(v_orphan_kind);
    end if;
    -- #707: and in pg_type. A partition's CREATE TABLE needs its name free there too (a table's row type
    -- takes its name), which pg_class cannot show, so an enum or domain named like a child passed this
    -- guard and obtain's CREATE TABLE met it with 42710. The same name shape, asked of _type_squatter
    -- (#671), which leaves a relation's own row type and an implicit array type alone.
    select t.typname into v_orphan
      from pg_type t
     where t.typnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)
       and starts_with(t.typname, v_rel || '_p')
       and case when p_control_kind = 'id'
                then substr(t.typname, length(v_rel) + 3) ~ '^[0-9]{19}$'
                else substr(t.typname, length(v_rel) + 3) ~ '^[0-9]{4}(_[0-9]+)*$'
           end
       and pgpm._type_squatter(v_nsp, t.typname) is not null
     limit 1;
    if v_orphan is not null then
      raise exception 'pg_partition_magician: %.% already exists as % matching this parent''s partition naming, and the conversion would collide with it when it creates that partition (a table''s row type takes its name, so no type may hold it). Drop or rename the type, then retry transmute.',
        v_nsp, v_orphan, pgpm._type_squatter(v_nsp, v_orphan);
    end if;
  end;

  -- Staging-name collision guard (#344): phase 3 builds the new parent under a temporary name BEFORE
  -- either rename (so that none of its setup work adds to the outage), which means that name must be
  -- free. Refuse up front, same shape as the orphan-child check just above and the <index>_pgpm check
  -- below -- most likely a leftover from an interrupted prior attempt.
  if to_regclass(format('%I.%I', v_nsp, v_staging)) is not null then
    raise exception 'pg_partition_magician: %.% already exists, and transmute needs it as a staging name for the new parent. Most likely a leftover from an interrupted run. Drop it (drop table %.%) and retry transmute.',
      v_nsp, v_staging, quote_ident(v_nsp), quote_ident(v_staging);
  end if;
  -- #671: and free as a TYPE name. The CREATE TABLE in phase 3 needs it free in pg_type too (a table's row
  -- type takes its name), which to_regclass cannot see, so an enum or domain holding it passed this guard
  -- and the cutover died on a raw 42710 after phases 1 and 2 had committed the bound and the claim.
  if pgpm._type_squatter(v_nsp, v_staging) is not null then
    raise exception 'pg_partition_magician: %.% already exists as %, and transmute needs that name as a staging name for the new parent (a table''s row type takes its name, so no type may hold it). Drop or rename the type, then retry transmute.',
      v_nsp, v_staging, pgpm._type_squatter(v_nsp, v_staging);
  end if;

  -- uuidv7 sanity check (issue #96): a uuid control column is TREATED as uuidv7 on assumption, so we
  -- sample it. Genuine UUIDv7/ULID decodes to plausible recent timestamps (~1.0); random UUIDv4 scores
  -- ~0. Below a hard floor (0.5) the column is overwhelmingly random, so range-partitioning it would
  -- scatter rows across meaningless partitions on a garbage frontier -- so REFUSE, mirroring the
  -- float-key and PK refusals, unless the operator overrides with p_force_uuidv7. Between the floor and
  -- 0.95 we warn but proceed (mostly time-ordered with some noise, within the bounded-lag contract).
  if p_control_kind = 'uuidv7' then
    select sampled, fraction into v_uchk_n, v_uchk_frac from pgpm.check_uuidv7(p_parent, p_control, 1000);
    if coalesce(v_uchk_n, 0) > 0 then
      if v_uchk_frac < 0.5 and not p_force_uuidv7 then
        raise exception 'pg_partition_magician: only % of % sampled % values decode to plausible recent timestamps -- the column looks random (UUIDv4), not time-ordered (UUIDv7/ULID), so range-partitioning it would scatter rows across meaningless partitions on a garbage frontier. If you are certain it is time-ordered, re-run with p_force_uuidv7 => true; otherwise partition on a genuinely time-ordered key. Inspect with pgpm.check_uuidv7().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control);
      elsif v_uchk_frac < 0.95 then
        raise notice 'pg_partition_magician: only % of % sampled % values decode to plausible recent timestamps; the column may be random (UUIDv4) rather than time-ordered (UUIDv7/ULID) -- partitioning may misbehave. Proceeding; verify with pgpm.check_uuidv7().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control);
      end if;
    end if;

  end if;

  -- text_time sanity check, same shape and same floor/warn thresholds as the uuidv7 one above: the
  -- shape (prefix/width/radix/unit) is supplied by the operator, not detected, so this is what verifies
  -- real data actually matches it before anything is partitioned on it.
  if p_control_kind = 'text_time' then
    select sampled, fraction into v_uchk_n, v_uchk_frac
      from pgpm.check_text_time(p_parent, p_control, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, 1000,
                                 p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);
    if coalesce(v_uchk_n, 0) > 0 then
      if v_uchk_frac < 0.5 and not p_force_text_time then
        raise exception 'pg_partition_magician: only % of % sampled % values match the declared text_time shape (prefix %, % base-% digit(s)) and decode to plausible recent timestamps -- range-partitioning it would scatter rows across meaningless partitions on a garbage frontier. If you are certain of the shape, re-run with p_force_text_time => true; otherwise check p_tt_prefix/p_tt_width/p_tt_radix/p_tt_unit. Inspect with pgpm.check_text_time().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control), p_tt_prefix, p_tt_width, p_tt_radix;
      elsif v_uchk_frac < 0.95 then
        raise notice 'pg_partition_magician: only % of % sampled % values match the declared text_time shape and decode to plausible recent timestamps -- partitioning may misbehave. Proceeding; verify with pgpm.check_text_time().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control);
      end if;
    end if;
  end if;

  -- #706: what the key and identity reads below plan from, taken FIRST, so a change landing between it and
  -- them makes the cutover's comparison refuse rather than pass. Compared again after the staging LIKE.
  v_keyshape := pgpm._transmute_key_shape(p_parent, p_control);

  -- existing PK columns and identity columns
  select array_agg(a.attname::text order by k.ord) into v_oldpk
    from pg_constraint con
    cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
   where con.conrelid = p_parent and con.contype = 'p';
  select conname into v_pkname from pg_constraint where conrelid = p_parent and contype = 'p';
  -- #308: capture the identity KIND alongside the column, in the same order. GENERATED ALWAYS rejects an
  -- insert that supplies the column unless it says OVERRIDING SYSTEM VALUE; re-adding it BY DEFAULT would
  -- accept those writes silently, revoking a constraint the operator declared without saying so.
  select array_agg(a.attname order by a.attnum), array_agg(a.attidentity::text order by a.attnum)
    into v_idcols, v_idkinds
    from pg_attribute a where a.attrelid = p_parent and a.attidentity in ('a','d') and not a.attisdropped;

  -- Capture max(identity), min(identity) and the original sequence's next value: the FLOORS of where the
  -- parent's freshly-recreated identity sequence resumes. Identity is moved from the table to the parent
  -- (whose sequence restarts at START WITH), so without them the next insert would collide. Only floors
  -- (#656): the values the reseed uses are read again in the cutover, under its ACCESS EXCLUSIVE, by
  -- _identity_resume_at, since writers run on between here and there and every id they take would
  -- otherwise be issued again. That read takes the max and min again when an index answers them, and the
  -- sequence's position always; these are what stand in when no index does, read here because a scan here
  -- blocks no writer. min() is for a DESCENDING identity (#670), whose next id has to clear the smallest
  -- one instead; max and min are null for an empty table, which clears nothing.
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('select max(%1$I)::bigint, min(%1$I)::bigint from %2$s', v_col, p_parent::text) into v_m, v_mmin;
      v_idmax := array_append(v_idmax, v_m);
      v_idmin := array_append(v_idmin, v_mmin);
      -- the sequence's next value is last_value plus its INCREMENT, not plus 1 (#670)
      v_idnext := array_append(v_idnext, pgpm._seq_next(pg_get_serial_sequence(p_parent::text, v_col)::regclass));
    end loop;
  end if;

  -- pgpm NEVER rewrites the key (REDESIGN.md): it REUSES an existing CONSTRAINT-backed unique key whose
  -- columns include the control column, so the parent (step 8) adopts the monolith's kept index in place,
  -- no drop, no O(rows) rebuild. Postgres only requires a partitioned table's PK/unique key to INCLUDE
  -- the partition key (column order is irrelevant). Preference: the PRIMARY KEY when it includes the
  -- control column (ADD PRIMARY KEY adopts the child PK index), else, when the table has NO primary key,
  -- a UNIQUE CONSTRAINT that includes it (ADD UNIQUE adopts the child unique-constraint index). A primary
  -- key that EXCLUDES the control column is refused outright, whatever unique constraints sit beside it
  -- (#445): it cannot be carried onto a partitioned parent, and adopting a different key in its place
  -- would leave it confined to the monolith, enforcing nothing for any row written to a forward
  -- partition, with no error or log row to say so. A *bare* unique index is deliberately NOT usable --
  -- ADD UNIQUE would REBUILD it rather than adopt it -- so it is refused with the one metadata-only
  -- promotion the operator runs first. The reused key makes the control column NOT NULL (a PK guarantees
  -- it; for a unique constraint we require it, checked not scanned), so the per-column SET NOT NULL
  -- below stays a metadata no-op. Several shapes are refused up front (before the rename, table left
  -- untouched) rather than partitioned on a weak key.
  select a.attnum into v_ctl_attnum
    from pg_attribute a where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped;

  if v_oldpk is not null and (p_control::text = any(v_oldpk)) then
    v_pkcols := v_oldpk;   -- reuse the existing PK verbatim (it already includes the partition key)
    v_add_pk := true;
  elsif v_oldpk is not null then
    -- A PRIMARY KEY that excludes the control column: refuse before any UNIQUE constraint is considered
    -- (#445). This used to fall through to the unique-constraint branch below, so a PK on (id) beside a
    -- UNIQUE on (tenant, created_at) transmuted on created_at with the parent adopting the UNIQUE and the
    -- PK left on the monolith; every forward partition then accepted duplicate ids silently. The message
    -- names the constraint and the control column, and prescribes the widening the docs describe. Adding
    -- a unique constraint is deliberately NOT offered as a remedy: it is exactly the shape this refuses.
    raise exception 'pg_partition_magician: cannot partition % on % -- pgpm does not rewrite keys, and the primary key % (%) does not include %. A primary key cannot be carried onto a partitioned table unless it includes the partition key, whatever other unique constraints the table has, so make % part of the primary key first, then re-run transmute: the simplest modern data model is a single-column time-ordered key (bigint/Snowflake, UUIDv7, or ULID); to retrofit an existing key, widen it via CREATE UNIQUE INDEX CONCURRENTLY on the new columns, then ALTER TABLE % DROP CONSTRAINT %, ADD PRIMARY KEY USING INDEX <idx>.',
      p_parent, p_control, v_pkname, array_to_string(v_oldpk, ', '), p_control, p_control, p_parent::text, v_pkname;
  else
    -- no PK at all: look for a UNIQUE CONSTRAINT whose key includes the control column and is neither
    -- partial nor on an expression (the same shape pgpm can enforce on a partitioned table).
    select con.conname, con.conindid, array_agg(a.attname::text order by k.ord)
      into v_reuse_conname, v_reuse_idx, v_uq_cols
      from pg_constraint con
      join pg_index i on i.indexrelid = con.conindid
      cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
     where con.conrelid = p_parent and con.contype = 'u'
       and i.indpred is null and i.indexprs is null and v_ctl_attnum = any(con.conkey)
     group by con.conname, con.conindid
     order by con.conname limit 1;

    if v_reuse_conname is not null then
      if not (select a.attnotnull from pg_attribute a
                where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) then
        raise exception 'pg_partition_magician: cannot transmute % on % -- the unique constraint % includes the control column, but % is nullable and a partition key must be NOT NULL. Run ALTER TABLE % ALTER COLUMN % SET NOT NULL first, then re-run transmute.',
          p_parent, p_control, v_reuse_conname, p_control, p_parent::text, p_control;
      end if;
      v_pkcols := v_uq_cols;   -- reuse the unique constraint (drives FK eligibility and the parent ADD UNIQUE)
      v_add_uniq := true;
    else
      -- nothing reusable: give the operator a specific reason and the prep step that unblocks it.
      -- (the rule is shared with pgpm_hypertable, which asks it of a hypertable before its swap, #792)
      v_bare_uq := pgpm._transmute_bare_unique(p_parent, p_control);
      if v_bare_uq is not null then
        raise exception 'pg_partition_magician: cannot transmute % on % -- the unique index % includes the control column but is a bare index, not a constraint, so pgpm cannot adopt it without an O(rows) rebuild. Promote it to a constraint first: ALTER TABLE % ADD CONSTRAINT %_key UNIQUE USING INDEX %; then re-run transmute. (pgpm reuses a primary key or a unique constraint, never a bare index, to keep the conversion metadata-only.)',
          p_parent, p_control, v_bare_uq, p_parent::text, v_bare_uq, v_bare_uq;
      else
        -- truly keyless (a PK that excludes the control column was refused above, so v_oldpk is null
        -- here): no key to reuse. pgpm still partitions it -- the parent gets no primary key or
        -- unique constraint, faithful to a keyless source (e.g. a plain hypertable un-hypertabled by
        -- from_hypertable). The one requirement is that the control column be NOT NULL: a partition key
        -- cannot be null, and pgpm never scans to enforce it, so a nullable control column is refused.
        -- (regrain is unavailable for a keyless monolith -- it has no key to dedup a resumed copy -- but
        -- the coarse monolith is a correct, queryable permanent state; see regrain_step.)
        if not (select a.attnotnull from pg_attribute a
                  where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) then
          raise exception 'pg_partition_magician: cannot transmute % on % -- the table has no primary key or unique constraint to reuse, and % is nullable. A partition key must be NOT NULL: run ALTER TABLE % ALTER COLUMN % SET NOT NULL first, then re-run transmute. (A primary key or unique constraint including % would also satisfy this.)',
            p_parent, p_control, p_control, p_parent::text, p_control, p_control;
        end if;
        -- proceed keyless: v_pkcols stays null, v_add_pk and v_add_uniq stay false.
      end if;
    end if;
  end if;

  -- Secondary indexes to carry onto the parent (step 9b recreates them as partitioned, attaching the
  -- default's). NON-unique secondaries always carry. A non-PK UNIQUE secondary can only become a
  -- partitioned unique index if its KEY columns include the partition key (Postgres's rule), so we carry
  -- those too -- global uniqueness genuinely preserved, exactly as the PK is reused when it covers the
  -- partition key -- and REFUSE the rest below, never silently dropping a uniqueness guarantee (issue
  -- #90). indkey casts via its text form (int2vector is 0-based; string_to_array gives a 1-based array),
  -- sliced to indnkeyatts so INCLUDE columns don't count; partial / expression unique indexes can't be
  -- carried either, so they fall to the refusal.
  -- (v_ctl_attnum was resolved with the key selection above). Exclude the reused unique-constraint index
  -- (v_reuse_idx): step 8 produces it via ADD UNIQUE, so it must not also be carried as a secondary.
  -- The list and its refusals live in _transmute_carried_indexes, because the cutover asks again under
  -- its ACCESS EXCLUSIVE (#630) and that answer is the one 9b carries; this one refuses up front.
  select o_names, o_defs into v_idx_names, v_idx_defs
    from pgpm._transmute_carried_indexes(p_parent, v_nsp, p_control, v_ctl_attnum, v_reuse_idx);

  -- Refuse the one trigger shape a partitioned table cannot host (#277): a row trigger with a transition
  -- table. Asked again in the cutover under its ACCESS EXCLUSIVE (#706), beside the trigger capture.
  perform pgpm._transmute_refuse_transition_triggers(p_parent);

  -- Objects that name the table by its oid (#779): views, materialized views, rules, SQL-standard function
  -- bodies, other tables' policies. The rename hands that oid to the monolith, so each would silently
  -- narrow to it. Asked again in the cutover under its ACCESS EXCLUSIVE, which no CREATE VIEW can pass.
  perform pgpm._refuse_oid_bound_dependants(p_parent, false);

  -- Publication membership (#566): the cutover adds the new parent to every publication that names this
  -- table (step 7c), and PostgreSQL refuses a row filter or a column list on a PARTITIONED table in a
  -- publication with publish_via_partition_root = false ("cannot use publication WHERE clause for
  -- relation"). There is no faithful way to carry that shape: dropping the filter or the list would
  -- start replicating rows or columns the operator excluded, and leaving the parent out is the defect
  -- itself. So it is refused HERE, before anything is committed, rather than failing inside the cutover.
  -- A publication FOR ALL TABLES or FOR TABLES IN SCHEMA needs nothing: the parent is covered by it the
  -- moment it exists, in the same schema.
  select string_agg(p.pubname::text, ', ' order by p.pubname) into v_bad_pub
    from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
   where r.prrelid = p_parent and not p.pubviaroot
     and (r.prqual is not null or r.prattrs is not null);
  if v_bad_pub is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the publication(s) (%) name it with a row filter or a column list and publish_via_partition_root = false, which PostgreSQL does not allow for a partitioned table, so the new parent could not take the table''s place in them. Set publish_via_partition_root = true on them (ALTER PUBLICATION ... SET (publish_via_partition_root = true)), or drop the filter and column list, then re-run transmute.',
      p_parent, v_bad_pub;
  end if;
  -- and a publication the caller cannot alter is refused (#710, see above _transmute)
  select string_agg(quote_ident(p.pubname), ', ' order by p.pubname) into v_unowned_pub_q
    from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
   where r.prrelid = p_parent and not pg_has_role(current_user, p.pubowner, 'USAGE');
  if v_unowned_pub_q is not null then
    raise exception 'pg_partition_magician: cannot transmute % as % -- the publication(s) (%) name it, and adding the new parent to them (ALTER PUBLICATION ... ADD TABLE) needs their owner. Run transmute as a role that owns them, or have their owner hand them over (ALTER PUBLICATION ... OWNER TO), then re-run transmute.',
      p_parent, quote_ident(current_user), v_unowned_pub_q;
  end if;

  -- Constraints the cutover cannot carry (#730). Its CREATE TABLE ... LIKE INCLUDING CONSTRAINTS copies
  -- every CHECK (and, on 18, every NOT NULL constraint) onto the new parent, and two shapes cannot make
  -- that trip. Neither was checked, so each surfaced as a raw error from inside the cutover, after phases
  -- 1 and 2 had committed the validated, write-rejecting bound and the claim, and every retry failed the
  -- same way. Both cost nothing to refuse here, before anything is committed, as #509 does for every other
  -- shape the cutover cannot convert.
  --
  -- A NOT VALID one: LIKE gives the parent a VALIDATED copy, and the ATTACH then refuses the table under
  -- it ("conflicts with NOT VALID constraint on child table"). pgpm's own bound is excluded by name: a
  -- resume after phase 1 committed and phase 2 did not finds it NOT VALID, and phase 2 validates it.
  select string_agg(conname, ', ' order by conname) into v_bad_con
    from pg_constraint
   where conrelid = p_parent and contype in ('c', 'n') and not convalidated
     and conname <> 'pgpm_monolith_bound';
  if v_bad_con is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- its constraint(s) (%) are NOT VALID, and the cutover cannot carry a NOT VALID constraint: the new parent gets a validated copy, under which PostgreSQL refuses to attach the table. Validate them first (ALTER TABLE % VALIDATE CONSTRAINT <name>, which takes SHARE UPDATE EXCLUSIVE and so blocks no reader or writer), or drop them, then re-run transmute.',
      p_parent, v_bad_con, p_parent::text;
  end if;
  -- A CHECK ... NO INHERIT: PostgreSQL does not allow one on a partitioned table ("cannot add NO INHERIT
  -- constraint to partitioned table"), and leaving it on the monolith alone would check only the rows
  -- routed there. CHECK only: a NOT NULL constraint the LIKE does not copy as NO INHERIT, and 18 marks a
  -- primary key connoinherit too.
  select string_agg(conname, ', ' order by conname) into v_bad_con
    from pg_constraint
   where conrelid = p_parent and contype = 'c' and connoinherit;
  if v_bad_con is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- its CHECK constraint(s) (%) are NO INHERIT, which PostgreSQL does not allow on a partitioned table, and left on the original table alone they would check only the rows routed into it. Drop them, or re-create them without NO INHERIT (ADD CONSTRAINT ... CHECK (...) NOT VALID, then VALIDATE CONSTRAINT), then re-run transmute.',
      p_parent, v_bad_con;
  end if;

  -- 0. incoming FKs: the GATE, and only the gate. pgpm never rewrites the PK, so the referenced unique
  -- key (the reused PK) always survives and an incoming FK can be re-pointed at the new parent verbatim on
  -- a later tick -- the 'preserve' lifecycle. It cannot ride through in place: the cutover's rename makes
  -- the ORIGINAL table the monolith child, so a surviving FK would go on referencing that partition instead
  -- of the new parent, silently narrowing to one partition. We refuse by default (the operator opts into
  -- the drop-and-restore dance), and a key that could not be re-added afterwards is refused here too,
  -- before anything is committed.
  --
  -- What this step does NOT do is drop anything (#444). The drop lives in the cutover (step 0c), in the
  -- same transaction as the pgpm.dropped_fk row that lets restore_incoming_fks re-add it. It used to be
  -- here, which was harmless while transmute was one transaction and became a data-loss path when #275
  -- split it into three: the drop committed with phase 1, the record waited for phase 3, and a failure in
  -- between (a stray row past the bound failing phase 2's VALIDATE, a lock timeout in the cutover) left
  -- the key gone from the referencing table with nothing anywhere to say it had existed. transmute_abort
  -- then reported the table restored, the referencing table accepted orphans, and a clean re-run found no
  -- key to record. Nothing in phase 1 or 2 needs the key gone -- ADD CONSTRAINT NOT VALID and VALIDATE
  -- touch only this table -- so there was never a reason for it to be early.
  --
  -- The gate lives in _transmute_incoming_gate because the cutover asks it again under its ACCESS
  -- EXCLUSIVE, just before 0c (#706): a key added in between is refused there, not carried into the monolith.
  perform pgpm._transmute_incoming_gate(p_parent, p_incoming_fks, v_pkcols);

  -- OUTGOING foreign keys (issue #263). The conversion renames the original table aside to become the
  -- monolith child, and a foreign key follows the table it is defined ON, so the constraint lands on the
  -- monolith and NOT on the new parent. It keeps enforcing there, which is what made the loss so easy to
  -- miss: rows routed into the monolith are still checked, and only rows in a FORWARD partition escape.
  -- Measured before this fix: an insert referencing a row that does not exist was accepted into
  -- ev263_p0000000000000030000 with no error and nothing in pgpm.log. Partial enforcement is worse than
  -- none, because the obvious post-conversion check ("is my foreign key still there?") passes.
  --
  -- Listed here so a NOT VALID one is refused before anything is committed, and listed AGAIN in the cutover
  -- under its ACCESS EXCLUSIVE, which is the list 7a re-adds at the parent (#630): ADD FOREIGN KEY takes
  -- only SHARE ROW EXCLUSIVE, which nothing excludes between here and that lock. Self-referential keys are
  -- excluded on purpose: confrelid = p_parent makes them INCOMING as well, so the incoming gate above has
  -- already decided their fate (refuse, or drop-and-restore under 'preserve').
  select o_names, o_defs into v_out_names, v_out_defs from pgpm._transmute_outgoing_fks(p_parent);

  -- ===== monolith cutover (REDESIGN.md sections 1, 2, 11) =====
  -- Bounds for the bounded coarse child the original table becomes: lo = grid_floor(min(control)),
  -- hi = B = the grid boundary just above the frontier. The monolith covers all history AND the
  -- current interval, so live writes keep landing in it until the frontier crosses B (then obtain's
  -- forward partitions take over and the monolith freezes). Every row satisfies [lo, B): lo <= min and
  -- B > frontier >= every row. An empty table anchors lo at the frontier's grid floor (empty monolith).
  -- frontier (max(control) for id, greatest(max(control), now()) for uuidv7 (#325), text_time and time
  -- (#668)) and min(control), computed directly:
  -- pgpm.config does not exist yet, so _frontier_native (which reads config) cannot be used here.
  if p_control_kind = 'time' then
    -- #668: the data maximum counts for `time` too. The frontier used to be now() alone, so a table holding
    -- one future-dated row (a scheduled event, a client with a wrong clock) got a hi below that row: phase 1
    -- committed a write-rejecting pgpm_monolith_bound CHECK and the claim, and only phase 2's VALIDATE
    -- found the row, with a raw 23514. The newer of the maximum and the clock covers every row, and the
    -- #457 refusal below keeps one far-future row from pinning hi where the clock is not going for years.
    -- max(), not ORDER BY ... LIMIT 1: it skips nulls and still walks an index backward. A naive column's
    -- reading is wall time in v_tz (UTC for such a column, #504), the rule v_min_raw follows below.
    if v_typname in ('timestamp', 'date') then
      execute format('select max(t.%I)::timestamp at time zone %L from %s t', p_control, v_tz, p_parent::text) into v_max_ts;
    else
      execute format('select max(t.%I) from %s t', p_control, p_parent::text) into v_max_ts;
    end if;
    if v_max_ts is not null and not isfinite(v_max_ts) then
      -- no range bound covers it (the upper bound is exclusive), so there is nothing p_force_frontier could accept
      raise exception 'pg_partition_magician: % cannot be partitioned on a time grid using %: its newest value is infinity, and no partition can hold it (a range partition''s upper bound is exclusive, and the monolith''s would have to lie past it). Delete or correct the rows whose % is infinity and re-run.',
        p_parent, quote_ident(p_control), quote_ident(p_control);
    end if;
    v_max_raw := pgpm._ts_text(v_max_ts);
    v_frontier_native := pgpm._ts_text(greatest(v_max_ts, now()));
  else
    execute format('select t.%I::text from %s t order by t.%I desc limit 1', p_control, p_parent::text, p_control)
      into v_max_raw;
    if v_max_raw is null then
      v_frontier_native := case when p_control_kind = 'id' then p_anchor else pgpm._ts_text(now()) end;
    elsif p_control_kind in ('uuidv7', 'text_time') then
      -- #325: mirrors _frontier_native's greatest(decoded, now()) here too. pgpm.config does not exist
      -- yet (see the note above), so this cannot just call the shared function -- and fixing only that
      -- one would leave THIS bound stuck at the data-driven value, opening a gap between the
      -- monolith's frozen upper edge and obtain's now()-anchored forward grid on the very next tick.
      -- Confirmed the hard way while building text_time support: adding the kind to _frontier_native
      -- but not here reproduces exactly that gap (an unfixed [2025-07,2025-10) monolith with the next
      -- partition not starting until 2026-08 -- ten covered months missing entirely).
      v_frontier_native := pgpm._ts_text(greatest(pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch)::timestamptz, now()));
    else
      v_frontier_native := pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch);
    end if;
  end if;
  -- #788: a timestamptz minimum is rendered through _ts_text, never a bare ::text, because it is parsed
  -- back with ::timestamptz below. Under a DateStyle that renders zone abbreviations (SQL, Postgres)
  -- Asia/Kolkata's 'IST' reads as Israel (+02), so the minimum read 3.5 hours late, an oldest row in a
  -- month's last 3.5 hours floored into the next month, and phase 2's VALIDATE failed on the table's own
  -- row with the NOT VALID bound left behind. Any other column's text parses back to itself here.
  execute format('select %s from %s t order by t.%I asc limit 1',
                 case when p_control_kind = 'time' and v_typname not in ('timestamp', 'date')
                      then format('pgpm._ts_text(t.%I)', p_control) else format('t.%I::text', p_control) end,
                 p_parent::text, p_control)
    into v_min_raw;
  -- #455: a naive (timestamp / date) control value has no zone; read it as wall time in v_tz (which is
  -- 'UTC' for such a column, #504), the rule _col_to_native applies everywhere else, so the monolith's
  -- lower bound is the one every later session would compute. A timestamptz minimum is already canonical
  -- text carrying its offset. pgpm.config does not exist yet, so this is the inline form of that rule,
  -- with v_typname already looked up above.
  if p_control_kind = 'time' and v_min_raw is not null then
    v_min_raw := case when v_typname in ('timestamp', 'date') then pgpm._ts_text(v_min_raw::timestamp at time zone v_tz)
                      else pgpm._ts_text(v_min_raw::timestamptz) end;
  end if;
  v_min_native := coalesce(pgpm._decode(p_control_kind, v_min_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch),
                           pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_frontier_native, v_tz));
  v_lo_native  := pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_min_native, v_tz);
  v_hi_native  := pgpm._grid_next(p_control_kind, p_step,
                    pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_frontier_native, v_tz), v_tz);
  v_monolith   := pgpm._part_name(v_rel, p_control_kind, p_step, v_lo_native, v_hi_native, v_tz);

  -- Refuse, before touching anything, when the monolith's own upper bound cannot be expressed (#299).
  -- B is the grid boundary ABOVE the frontier, so a frontier sitting in the last partial step puts B past
  -- the 48-bit UUIDv7 ceiling and no uuid can carry it. This is arithmetic, not a heuristic, which is why
  -- p_force_uuidv7 does NOT override it: that override exists to let an operator vouch for a column the
  -- SAMPLING misjudged, not to ask for a bound that cannot exist.
  --
  -- In practice it catches the same garbage column the sampling check does, from the other side: random
  -- uuids have their maximum near the top of the 128-bit space, so the frontier decodes to within a
  -- whisker of the ceiling and every step forward overflows. Before this, the overflow was silently
  -- truncated into a SMALLER uuid and surfaced much later as PostgreSQL's `empty range bound specified for
  -- partition`, naming neither the cause nor the ceiling -- and only on the runs where the random maximum
  -- happened to land close enough, which made it a CI flake rather than a reproducible bug.
  if p_control_kind in ('uuidv7', 'text_time') then
    begin
      perform pgpm._encode(p_control_kind, v_hi_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch, v_tz);
    exception when datetime_field_overflow or numeric_value_out_of_range then
      if p_control_kind = 'uuidv7' then
        raise exception 'pg_partition_magician: % cannot be partitioned on a uuidv7 grid using %: its newest value decodes to %, so the next grid boundary lands past 10889-08-02 05:31:50.65504+00, the newest instant a UUIDv7 timestamp can express. A column whose frontier sits at that ceiling is almost certainly random (UUIDv4) rather than time-ordered -- inspect it with pgpm.check_uuidv7(). p_force_uuidv7 does not override this, because no uuid can express the bound.',
          p_parent, quote_ident(p_control), v_frontier_native;
      else
        raise exception 'pg_partition_magician: % cannot be partitioned on a text_time grid using %: its newest value decodes to %, so the next grid boundary would need more than p_tt_width (%) base-% digit(s) to express. Either the column''s newest value is implausibly far in the future for this encoding, or p_tt_width/p_tt_radix do not match its actual shape -- inspect it before overriding anything.',
          p_parent, quote_ident(p_control), v_frontier_native, p_tt_width, p_tt_radix;
      end if;
    end;
  end if;

  -- Refuse a DATA maximum that sits far ahead of the clock (#457). For these two kinds the frontier is
  -- greatest(max(control), now()), so one row minted by a client with a wrong clock sets the frontier, and
  -- with it the monolith's PERMANENT hi, as far out as that clock was wrong: every row written until then
  -- lands in the monolith, status() shows nothing abnormal, and the monolith cannot be regrained nor
  -- anything behind it dropped until now() really passes hi. The sampling gate above cannot see it (one bad
  -- row in 402 is fraction 0.9975). `time` was thought immune because its frontier was now(), but that only
  -- moved the failure to phase 2's VALIDATE, after the bound had been committed (#668); its frontier is
  -- the newer of the data and the clock now, so the same allowance applies to it.
  --
  -- The allowance is one partition step plus one hour, measured from now() and NOT from the
  -- headroom-adjusted bound: p_bound_headroom is the operator asking for a farther hi on purpose, and it
  -- must not also widen what the data is allowed to impose. One step because the cost of a maximum inside
  -- the allowance is bounded to what p_bound_headroom => 1 (2 in the worst alignment) would have cost, a
  -- documented and survivable amount that scales with the granularity the operator chose; one hour on top
  -- because a fine grid (minutes) must still tolerate ordinary clock skew and small timezone mistakes,
  -- which are absolute, not proportional to the step. This is a policy refusal about a cost, not
  -- arithmetic like the ceiling check above, so unlike that one it has an override: p_force_frontier
  -- accepts the bound knowingly, the same way p_bound_headroom asks for one. The check sits AFTER the
  -- ceiling refusal on purpose: a random (v4) column forced past the sampling gate decodes to year ~10000
  -- and must keep getting the ceiling's message, which names the real cause.
  if p_control_kind in ('time', 'uuidv7', 'text_time') and v_max_raw is not null then
    if p_control_kind <> 'time' then   -- the time kind's v_max_ts is the maximum itself, read above
      v_max_ts := pgpm._decode(p_control_kind, v_max_raw, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch)::timestamptz;
    end if;
    v_skew_limit := pgpm._frontier_skew_limit(p_step::interval);   -- shared with pgpm_hypertable (#792)
    if v_max_ts > v_skew_limit then
      if not p_force_frontier and p_control_kind = 'time' then
        raise exception 'pg_partition_magician: % cannot be partitioned on a time grid using %: its newest value is %, which is % ahead of now() (%). The monolith''s upper bound has to lie past every row, so that one value would fix the monolith''s permanent upper bound at % instead of %: every row written until then lands in the monolith, which cannot be regrained, and nothing behind it can be dropped, until the clock actually gets there. Delete or correct the rows whose % is after % (now() + one step + one hour, the most the newest row may lead the clock by) and re-run, or re-run with p_force_frontier => true to accept that bound.',
          p_parent, quote_ident(p_control), v_max_ts, justify_interval(date_trunc('second', v_max_ts - now())), now(),
          v_hi_native, pgpm._grid_next(p_control_kind, p_step, pgpm._grid_floor(p_control_kind, p_step, p_anchor, pgpm._ts_text(now()), v_tz), v_tz),
          quote_ident(p_control), v_skew_limit;
      elsif not p_force_frontier then
        raise exception 'pg_partition_magician: % cannot be partitioned on a % grid using %: its newest value % decodes to %, which is % ahead of now() (%). A time-ordered id dated that far ahead is almost always a client with a wrong clock, and because the frontier is the newer of the data and the clock, that one value would fix the monolith''s permanent upper bound at % instead of %: every row written until then lands in the monolith, which cannot be regrained, and nothing behind it can be dropped, until the clock actually gets there. Delete or correct the rows whose % sorts above % (the value encoding now() + one step + one hour, the most a maximum may lead the clock by) and re-run, or re-run with p_force_frontier => true to accept that bound.',
          p_parent, p_control_kind, quote_ident(p_control), v_max_raw, v_max_ts, justify_interval(date_trunc('second', v_max_ts - now())), now(),
          v_hi_native, pgpm._grid_next(p_control_kind, p_step, pgpm._grid_floor(p_control_kind, p_step, p_anchor, pgpm._ts_text(now()), v_tz), v_tz),
          quote_ident(p_control), pgpm._encode(p_control_kind, v_skew_limit::text, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch, v_tz);
      end if;
      raise notice 'pg_partition_magician: the newest % value % in % decodes to %, % ahead of now(); p_force_frontier accepted it, so the monolith''s permanent upper bound is % rather than %. Rows written until then land in the monolith, and it cannot be regrained until the clock passes that bound.',
        quote_ident(p_control), v_max_raw, p_parent, v_max_ts, justify_interval(date_trunc('second', v_max_ts - now())),
        v_hi_native, pgpm._grid_next(p_control_kind, p_step, pgpm._grid_floor(p_control_kind, p_step, p_anchor, pgpm._ts_text(now()), v_tz), v_tz);
    end if;
  end if;

  -- ============================ PHASE 1: add the bound (#275) ============================
  --
  -- Certify the monolith's bound BEFORE the rename so the ATTACH below is metadata-only. This is the one
  -- O(rows) read of the conversion, and it gets its own transaction so it is not held under the ACCESS
  -- EXCLUSIVE lock the ADD takes. Measured before the split: the table was fully locked (ACCESS EXCLUSIVE
  -- conflicts with everything, reads included) for 30 ms at 1M rows, 173 ms at 5M, 492 ms at 10M, cached.
  --
  -- THE CLAIM (#405). pgpm.transmute_inflight's primary key on parent_table IS the exclusion: one row per
  -- table, taken here and deleted by the cutover, so a second conversion cannot register while a first holds
  -- it. Liveness -- "still running" against "its session died mid-way", with no heartbeat and no timeout
  -- guess -- comes from the claiming session's identity recorded alongside it (see pgpm._session_alive).
  --
  -- This REPLACES a session advisory lock keyed on hashtextextended('pgpm_transmute:' || oid). That key was
  -- computable by anyone -- the formula is in this file and the oid is in pg_class -- and advisory locks
  -- carry no ACL of any kind, so any role that could merely CONNECT could take it: either pre-emptively, to
  -- block every transmute of that table outright, or the instant a crashed conversion released it, which
  -- starved the reaper below and pinned a write-rejecting bound on the operator's table with no way back,
  -- since transmute_abort consulted the same lock. The claim row lives in a pgpm-owned table carrying no
  -- GRANTs, so an unprivileged role cannot take or hold it at all.
  --
  -- Optional headroom is applied to the candidate hi FIRST, because the claim itself decides fresh-vs-resume
  -- and a resume must reuse the recorded bound. It pushes hi further out so a fast writer cannot cross it
  -- while the scan runs: the bound rejects writes at or past hi for as long as it is in place, which with
  -- the phase split is the whole conversion rather than a single locked statement.
  --
  -- The headroom is PERMANENT, not scoped to the conversion; the operator docs state only that consequence,
  -- and this is why. The zero-scan ATTACH requires the already-validated CHECK to exactly imply the attached
  -- bound, so whatever hi is certified here is the only bound the cutover can attach with, and it becomes
  -- the monolith's partition bound. There is no cheaper way to widen the transient write-ceiling protection
  -- without also widening the monolith's permanent range. regrain_step's frozen precondition is a
  -- whole-child test against that same hi, so headroom sized to cover a write-ceiling window of seconds
  -- also delays regrain eligibility for the ENTIRE monolith by the same number of grid steps.
  for v_i in 1 .. greatest(coalesce(p_bound_headroom, 0), 0) loop
    v_hi_native := pgpm._grid_next(p_control_kind, p_step, v_hi_native, v_tz);
  end loop;

  -- One atomic take-or-take-over. `do update` fires only when the recorded owner is gone, OR is this very
  -- session, so the statement returns a row exactly when the claim is ours and nothing at all when a live
  -- conversion in another session holds it. It deliberately leaves lo/hi untouched, which is what makes
  -- RETURNING hand back the ORIGINAL bound on a take-over rather than the candidates passed in above.
  --
  -- The second arm is #509. A cutover failure (a lock_timeout in phase 3, say) leaves the claim owned by
  -- the operator's still-connected session, which _session_alive correctly reads as alive, so with the
  -- first arm alone the documented remedy, "re-run transmute: it resumes from the recorded bound", was
  -- refused as "already in progress in another session" to the very session that owned it, and the
  -- write-rejecting bound stayed until that session disconnected, which no document said. A session runs
  -- one thing at a time, so a claim recorded by THIS backend can only be this backend's own earlier,
  -- failed attempt: resuming it is exactly what a take-over does. Matched on both columns, the identity
  -- we are about to record; a recycled pid with an older backend_start fails the match and is caught by
  -- the first arm instead, because its owner is dead.
  insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz,
                                       control_attnum, owner_pid, owner_backend_start)
  values (p_parent, v_nsp, v_rel, p_control_kind, v_lo_native, v_hi_native, v_tz, v_ctl_attnum,
          pg_backend_pid(), (select backend_start from pg_stat_activity where pid = pg_backend_pid()))
      on conflict (parent_table) do update
         set owner_pid           = excluded.owner_pid,
             owner_backend_start = excluded.owner_backend_start
       where not pgpm._session_alive(transmute_inflight.owner_pid, transmute_inflight.owner_backend_start)
          or (transmute_inflight.owner_pid = excluded.owner_pid
              and transmute_inflight.owner_backend_start = excluded.owner_backend_start)
  returning lo, hi, partition_tz, control_attnum, (xmax <> 0)
       into v_lo_native, v_hi_native, v_claim_tz, v_claim_attnum, v_resumed;

  if not found then
    raise exception 'pg_partition_magician: a transmute of % is already in progress in another session', p_parent;
  end if;

  -- Resume: the row was already there and its session is gone, so we took it over. Reuse its bound rather
  -- than recomputing one -- the frontier has moved on since, but no row can have landed outside the recorded
  -- range, because the CHECK was rejecting exactly those the whole time. xmax is 0 on an insert and the
  -- updating xid on an update, which is what distinguishes the two here.
  --
  -- And reuse the ZONE that bound was computed in (#506). The bound sits on the claiming session's lattice
  -- (#455); registering THIS session's zone instead put the monolith on one lattice and every later grid
  -- computation on another, so obtain's first candidates half-overlapped the monolith and were skipped, a
  -- hole one whole step wide was left right past its hi (writes there failed), and set_partition_tz
  -- refused the repair because the grid built past the hole was on the wrong lattice for the original
  -- zone. A claim recorded before the column existed carries null and keeps this session's zone.
  if v_resumed then
    v_tz := coalesce(v_claim_tz, v_tz);
  end if;
  -- #628: and the bound has to be on the column THIS call partitions by. The claim records the bound and
  -- its zone, and #574's check below holds a resume to its grid, but it did not record the column: a
  -- re-run on another column took the claim over, skipped phase 1 (a constraint by that name exists) and
  -- phase 2 (it is validated), and partitioned by the new column: the CHECK is on the old one, so it does
  -- not imply the new partition bound, and the cutover's ATTACH scanned the whole table under ACCESS
  -- EXCLUSIVE, the outage the phase split exists to avoid (or failed there, on a row outside the old
  -- column's bound).
  -- Compared by attribute number, the identity the CHECK itself holds: a column renamed between attempts
  -- is still the column the bound constrains and resumes. A claim recorded before the column existed
  -- carries null and is not checked. Still the first transaction: the raise rolls the take-over back.
  if v_resumed and v_claim_attnum is not null and v_claim_attnum is distinct from v_ctl_attnum then
    raise exception 'pg_partition_magician: cannot resume the transmute of % on %: the bound [%, %) an earlier attempt recorded (and put in the pgpm_monolith_bound CHECK) is on %, and a CHECK on another column cannot certify a partition bound on this one, so the cutover would scan the whole table under ACCESS EXCLUSIVE. Re-run on the column of the attempt that recorded the bound, or call pgpm.transmute_abort(%) to drop the bound and start over.',
      p_parent, quote_ident(p_control), v_lo_native, v_hi_native,
      coalesce((select quote_ident(a.attname) from pg_attribute a
                 where a.attrelid = p_parent and a.attnum = v_claim_attnum and not a.attisdropped),
               'a column since dropped'),
      p_parent;
  end if;
  -- #574: and the bound has to lie on the grid THIS call registers. The claim records the bound and its
  -- zone but not the step and anchor it was computed on, and a re-run given another step reused the bound
  -- and registered the new step: the recorded hi was not a boundary of the new grid, so obtain skipped the
  -- new grid's cell overlapping the monolith and the forward grid started one cell later, a permanent hole
  -- right past the monolith's hi where every write failed. What matters is the lattice, not the spelling,
  -- so this asks whether lo and hi are boundaries of (p_step, p_anchor) in the claim's zone: a step the
  -- bound is flush with resumes, one it is not is refused. A fresh claim's bound is computed on this grid,
  -- so only a resume can fail it. Still the first transaction: the raise rolls the take-over back.
  if v_resumed
     and (pgpm._native_gt(p_control_kind, v_lo_native, pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_lo_native, v_tz))
          or pgpm._native_gt(p_control_kind, v_hi_native, pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_hi_native, v_tz))) then
    raise exception 'pg_partition_magician: cannot resume the transmute of % with step % and anchor %: the bound [%, %) an earlier attempt recorded (and put in the pgpm_monolith_bound CHECK) does not lie on that grid in % (floored to it, lo % is % and hi % is %), and registering it would leave a hole past the monolith''s hi that no partition covers. Re-run with the step and anchor of the attempt that recorded the bound, or call pgpm.transmute_abort(%) to drop the bound and start over.',
      p_parent, p_step, p_anchor, v_lo_native, v_hi_native, v_tz,
      v_lo_native, pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_lo_native, v_tz),
      v_hi_native, pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_hi_native, v_tz), p_parent;
  end if;
  v_monolith := pgpm._part_name(v_rel, p_control_kind, p_step, v_lo_native, v_hi_native, v_tz);

  -- #509: the cutover RENAMEs the table to this name, so the name has to be free, and nothing before this
  -- checked it. The orphan guard above matches CHILD names (<rel>_p<digits>...), and the monolith's coarse
  -- <rel>_p<lo>_to_<hi> matches neither of its regexes, so a relation already holding it (a monolith
  -- detached from an earlier conversion of a table by this name, or one that outlived a DROP) surfaced as
  -- a raw 42P07 from inside the cutover, after phases 1 and 2 had committed the validated bound and the
  -- claim, where reference.md promises the collision is refused up front with the table untouched.
  -- Checked HERE rather than beside the other name guards because the name depends on the bound, and the
  -- bound is only final once the claim has decided fresh-vs-resume and headroom has been applied. This is
  -- still the first transaction: nothing is committed, and the raise rolls the claim row back with it.
  if to_regclass(format('%I.%I', v_nsp, v_monolith)) is not null then
    raise exception 'pg_partition_magician: %.% already exists, and transmute needs that name for the monolith (the partition the converted table becomes, covering [%, %)). Most likely a leftover from an earlier conversion of a table by this name. Drop or rename it and retry transmute.',
      v_nsp, v_monolith, v_lo_native, v_hi_native;
  end if;
  -- #671: the RENAME renames the table's row type with it, so the name has to be free in pg_type as well,
  -- which to_regclass cannot see: a type holding it failed the cutover with a raw 42710, same as above.
  if pgpm._type_squatter(v_nsp, v_monolith) is not null then
    raise exception 'pg_partition_magician: %.% already exists as %, and transmute needs that name for the monolith (the partition the converted table becomes, covering [%, %)); a table''s row type takes its name, so no type may hold it. Drop or rename the type, then retry transmute.',
      v_nsp, v_monolith, pgpm._type_squatter(v_nsp, v_monolith), v_lo_native, v_hi_native;
  end if;

  -- #309: bound the wait for the ADD's ACCESS EXCLUSIVE. Re-applied per phase rather than set once,
  -- because `set local` does not survive a COMMIT -- the same caution maintain() records at its own
  -- boundaries. Without it this statement waits indefinitely, and a PENDING AccessExclusive request
  -- blocks every lock request queued behind it, so one long-running query turns the wait into an outage
  -- of the whole table. Failing here costs nothing: nothing is committed yet.
  perform set_config('lock_timeout', p_lock_timeout, true);
  if not exists (select 1 from pg_constraint
                  where conrelid = p_parent and conname = 'pgpm_monolith_bound') then
    execute format('alter table %s add constraint pgpm_monolith_bound check (%I >= %L and %I < %L) not valid',
                   p_parent::text, p_control, pgpm._encode(p_control_kind, v_lo_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch, v_tz),
                   p_control, pgpm._encode(p_control_kind, v_hi_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch, v_tz));
  end if;
  commit;   -- releases the ADD's ACCESS EXCLUSIVE before the scan; the claim row survives (it is committed)

  -- ============================ PHASE 2: validate it (#275) ============================
  -- VALIDATE takes only SHARE UPDATE EXCLUSIVE, which blocks nobody. Skipped when a previous attempt
  -- already validated it. It still needs the timeout: SHARE UPDATE EXCLUSIVE conflicts with itself, so
  -- an autovacuum or a concurrent ALTER on the same table can queue this behind them.
  perform set_config('lock_timeout', p_lock_timeout, true);   -- `set local` did not survive the COMMIT
  if not (select convalidated from pg_constraint
           where conrelid = p_parent and conname = 'pgpm_monolith_bound') then
    execute format('alter table %s validate constraint pgpm_monolith_bound', p_parent::text);
  end if;
  commit;

  -- ============================ PHASE 3: the cutover ============================
  -- Metadata only, and atomic: a raise from here rolls the whole cutover back.
  --
  -- One set_config covers every wait in this phase, since it is one transaction: the RENAME's ACCESS
  -- EXCLUSIVE on the live table, the incoming-FK drops' ACCESS EXCLUSIVE on each REFERENCING table
  -- (#444), and the outgoing-FK re-add's SHARE ROW EXCLUSIVE on each REFERENCED table (#263), which
  -- queues behind writers there rather than on the table being converted. A timeout
  -- here aborts the cutover whole and leaves the phase-1 bound in place -- the recorded, resumable state
  -- transmute_abort and maintain_all's sweep already handle.
  perform set_config('lock_timeout', p_lock_timeout, true);   -- `set local` did not survive the COMMIT

  -- 0b. capture what CREATE TABLE ... LIKE will NOT carry (#277): owner, grants, RLS, policies, comments
  -- and triggers, each replayed below in this same transaction. Both halves have to be inside the cutover:
  -- a parent that is briefly reachable with RLS off is the same security defect as one that never gets its
  -- policies, with a shorter fuse. And each is read under the lock that stops it changing before the
  -- rename carries the table away (#630, the rule #593 set for the triggers): the owner, the RLS flags and
  -- the policies just after the staging LIKE, whose ACCESS SHARE excludes ALTER OWNER, ENABLE/FORCE ROW
  -- LEVEL SECURITY and CREATE/ALTER/DROP POLICY (all ACCESS EXCLUSIVE); the comments, the triggers, the
  -- carried indexes, the outgoing keys and the identity reseed under the table's ACCESS EXCLUSIVE, further
  -- down, since COMMENT (SHARE UPDATE EXCLUSIVE), CREATE TRIGGER and ADD FOREIGN KEY (SHARE ROW EXCLUSIVE),
  -- CREATE INDEX (SHARE) and every writer's nextval are all compatible with ACCESS SHARE. They used to be
  -- read here, before the LIKE, or in the preflight, and whatever changed in between was lost.
  --
  -- Trigger definitions get a free ride, but only once BOTH renames have happened (#344): pg_get_triggerdef
  -- emits "... ON public.<original name>", and that name only resolves to the new parent once the staging
  -- parent has taken it, so the captured text replays verbatim with no rewriting. Policies get no such
  -- help (there is no pg_get_policydef) and are rebuilt from pg_policy.

  -- #344: everything below that only touches the NEW parent -- not the original/monolith relation -- runs
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

  -- 0b (triggers). The outage starts HERE, and the triggers are captured under it (#593). They used to be
  -- captured at 0b above, with nothing on the table stronger than the ACCESS SHARE the staging LIKE takes,
  -- and CREATE TRIGGER needs only SHARE ROW EXCLUSIVE, which that does not exclude. A trigger another
  -- session committed between the capture and the rename was therefore never replayed: 7b dropped it
  -- from the monolith along with the triggers it had captured (or, with nothing captured, left it on the
  -- monolith alone), and every row routed to a forward partition escaped it with nothing logged. ENABLE
  -- and DISABLE TRIGGER take the same SHARE ROW EXCLUSIVE, so the captured states raced the same way.
  --
  -- The fix is the lock, not a re-read. ACCESS EXCLUSIVE is what the incoming-FK drop and the rename take
  -- next anyway, so taking it one statement earlier, explicitly, starts the outage no sooner than before
  -- in any sense that matters (a catalog read, then the same statements). From here to the commit nothing
  -- can create, drop, enable or disable a trigger on the table, so what is captured is what the rename
  -- carries. Under this phase's lock_timeout like every other wait in it. Still before the renames, so
  -- pg_get_triggerdef names the ORIGINAL table and the text replays verbatim (see 0b).
  --
  -- The free ride does not include the enabled state (#499): pg_get_triggerdef never emits tgenabled, so
  -- the replayed CREATE TRIGGER leaves every trigger origin-only ('O') whatever it was. A DISABLED trigger
  -- would fire again on the next write, and an ENABLE ALWAYS or ENABLE REPLICA one would silently change
  -- when it fires under session_replication_role. So the name and the state ride alongside, index-aligned
  -- by the same ORDER BY, and 7b re-applies every non-default state after the replay.
  execute format('lock table %s in access exclusive mode', p_parent::text);
  select coalesce(array_agg(pg_get_triggerdef(oid) order by tgname), '{}'),
         coalesce(array_agg(tgname::text order by tgname), '{}'),
         coalesce(array_agg(tgenabled::text order by tgname), '{}')
    into v_trgdefs, v_trgnames, v_trgstates
    from pg_trigger where tgrelid = p_parent and not tgisinternal;
  -- and the one trigger shape the parent cannot take, refused again now that none can be created (#706):
  -- one committed since the preflight would otherwise reach the replay in 7b and fail it with a raw error.
  perform pgpm._transmute_refuse_transition_triggers(p_parent);
  -- and the objects that name the table by its oid (#779), refused again now that none can be created: one
  -- committed since the preflight would otherwise follow the rename into the monolith. The new parent's
  -- policies, carried above, are pgpm's own and exempt.
  perform pgpm._refuse_oid_bound_dependants(p_parent, false, v_parent);

  -- 0b (under the lock, #630 and #656). What the preflight listed, listed again now that nothing can change
  -- it: the secondary indexes 9b carries, the outgoing keys 7a re-adds, and where 8b resumes each identity
  -- sequence. The preflight's lists were only its refusals' business; these are the ones carried. A shape
  -- the preflight would have refused, created since, is refused here the same way and rolls the cutover
  -- back to the resumable phase-2 state. Before the renames, so p_parent still resolves by its own name.
  select o_names, o_defs into v_idx_names, v_idx_defs
    from pgpm._transmute_carried_indexes(p_parent, v_nsp, p_control, v_ctl_attnum, v_reuse_idx);
  select o_names, o_defs into v_out_names, v_out_defs from pgpm._transmute_outgoing_fks(p_parent);
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      v_ra := pgpm._identity_resume_at(p_parent, v_idcols[v_i], v_idnext[v_i], v_idmax[v_i], v_idmin[v_i]);
      v_idnext[v_i] := v_ra.o_next; v_idmax[v_i] := v_ra.o_max; v_idmin[v_i] := v_ra.o_min;
    end loop;
  end if;
  -- #732: and each identity sequence's options. ALTER SEQUENCE takes no lock on the table, so the table's
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

  -- 0c. drop the incoming FKs and record each, HERE (#444). Eligibility was settled by the gate at step 0,
  -- before anything was committed; this drops whatever is live NOW rather than replaying a list captured
  -- then, so a key the operator dropped during the validation scan is not recorded as ours to restore,
  -- and one they added is not left behind to follow the rename into the monolith. (The hypertable
  -- module's swap works the same way: preflight settles eligibility, the cutover drops what is live.)
  --
  -- Before the rename, for two reasons. The captured definition names the referenced table by its CURRENT
  -- name, and it is that name, not the monolith's, that restore_incoming_fks replays verbatim against the
  -- new parent. And a foreign key tracks the table it references by OID, so left in place through the
  -- rename it would reference the monolith partition, the silent narrowing the gate describes.
  --
  -- Captured through _fk_definition, not pg_get_constraintdef directly (#498): the text is replayed in
  -- another session, so the referenced table has to be schema-qualified whatever THIS session's
  -- search_path can see. A self-referential key's conrelid is p_parent, the oid this cutover is about to
  -- rename into the monolith child; it is recorded as captured and 0d below moves it, with every other
  -- record in which this table is the referencer, onto v_parent, the new parent that inherits the name.
  -- Left on the monolith it was restored onto that one partition, every row routed to a forward
  -- partition escaped it, and the log said restore_incoming_fk.
  --
  -- Immediately before the rename, not earlier in the phase. Dropping an FK takes ACCESS EXCLUSIVE on the
  -- REFERENCED table too (measured on PG 17: AccessExclusiveLock on both relations), so it belongs inside
  -- the outage the explicit lock above opens (#593) and no earlier; placed any earlier it
  -- would hold that lock across the staging work above, which #344 moved ahead of the rename precisely so
  -- that it would run under no such lock. Here it adds one metadata-only statement to the window. It also
  -- puts the wait for the referencing table's lock under this phase's lock_timeout, which the step 0 drop
  -- never was: a long read of the referencing table used to stall the conversion indefinitely, before
  -- anything had been claimed.
  --
  -- Recorded against v_parent, the new parent, which is why the record could never have been written in
  -- phase 1: the parent did not exist yet. Sharing this transaction with the drop is the whole fix. A
  -- failure anywhere in the cutover rolls the drop back along with everything else, so a key is gone from
  -- the referencing table only in a database where pgpm.dropped_fk says so.
  --
  -- Top-level keys only (conparentid = 0, #576). A key declared on a PARTITIONED referencing table has one
  -- pg_constraint row per partition as well, each a clone of the declared key, and dropping the declared
  -- key drops its clones with it. Iterating them too failed the cutover at the first clone ("constraint
  -- ... does not exist"), every time, leaving the bound and the claim behind; recording them would ask
  -- restore_incoming_fks to re-add, on a partition, a key that the re-added parent key clones there itself.
  --
  -- The gate is asked again first, here under the lock (#706). With p_incoming_fks => 'error' the loop below
  -- does not run, so a key added since the preflight (ADD FOREIGN KEY takes only SHARE ROW EXCLUSIVE, which
  -- nothing excluded until the lock above) used to follow the rename onto the monolith, keyed against one
  -- partition. Now it is refused, and under 'preserve' a key added since is held to the same eligibility
  -- rule before it is dropped and recorded.
  perform pgpm._transmute_incoming_gate(p_parent, p_incoming_fks, v_pkcols);
  if p_incoming_fks <> 'error' then
    for v_fk in
      select c.conrelid::regclass as reltbl, c.conname, pgpm._fk_definition(c.oid) as def
        from pg_constraint c where c.confrelid = p_parent and c.contype = 'f' and c.conparentid = 0
       order by c.conname
    loop
      execute format('alter table %s drop constraint %I', v_fk.reltbl::text, v_fk.conname);
      insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition)
        values (v_parent, v_fk.reltbl, v_fk.conname, v_fk.def);
      insert into pgpm.log (parent_table, action, method) values (v_parent, 'drop_incoming_fk', v_fk.conname);
    end loop;
  end if;

  -- 0d. The records in which THIS table is the REFERENCER (#498). pgpm.dropped_fk.referencing_table is an
  -- oid, and the rename below turns p_parent into the monolith child of this conversion. A key another
  -- managed parent preserved against this table, whether still dropped or already restored, must keep
  -- naming the TABLE, which is v_parent from the rename on: restore_incoming_fks would otherwise re-add
  -- it on the monolith partition alone (relkind 'r', logged restore_incoming_fk) and every row routed to
  -- a forward partition would escape it, while suspend_incoming_fks would try to drop, from that
  -- partition, a key that 7a below re-adds at the parent and clones down as inherited. Same transaction
  -- as the rename, so no session observes a record naming a relation that is no longer the table.
  update pgpm.dropped_fk set referencing_table = v_parent where referencing_table = p_parent;
  -- 0e. The records in which THIS table is the REFERENCED side, written before this conversion (#563).
  -- from_hypertable_cutover drops a hypertable's incoming keys in its swap and records them against the
  -- plain table it puts in place, because the parent that will hold them does not exist until this
  -- cutover; the same holds whether this is its own handoff or the operator's re-run after that handoff
  -- refused. restore_incoming_fks reads records by parent_table, and the rename below makes p_parent
  -- the monolith child, so a record left naming it would never be restored and the key would stay gone.
  -- The records name the referenced table by NAME in their definition, and v_parent takes that name, so
  -- moving the anchor is all a replay against the parent needs. Same transaction as the rename.
  update pgpm.dropped_fk set parent_table = v_parent where parent_table = p_parent;

  -- 1. THE TWO RENAMES, BACK-TO-BACK (#344). The outage is already running: the explicit lock before the
  -- trigger capture above took the ACCESS EXCLUSIVE these would otherwise acquire (#593); doing the second
  -- immediately after -- before anything else runs -- means the live
  -- name already resolves to the correctly-positioned parent by the time the trigger replay below (the one
  -- step that needs the literal name, not just the OID) executes.
  execute format('alter table %s rename to %I', p_parent::text, v_monolith);
  v_monreg := format('%I.%I', v_nsp, v_monolith)::regclass;
  execute format('alter table %s rename to %I', v_parent::text, v_rel);

  -- 2. the existing PK is KEPT in place; step 8 reconciles the monolith's promoted index (metadata-only).

  -- 3. drop identity on the monolith; key columns NOT NULL (metadata no-ops: PK => NOT NULL)
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('alter table %s alter column %I drop identity if exists', v_monreg::text, v_col);
    end loop;
  end if;
  execute format('alter table %s alter column %I set not null', v_monreg::text, p_control);
  -- 3b. hand every sequence the table OWNS through a column (a serial, or an explicit OWNED BY) to the
  -- same column of the new parent (#573). CREATE TABLE ... LIKE INCLUDING DEFAULTS copied the column's
  -- nextval() default onto the parent, but the ownership stayed with the oid the rename just made the
  -- monolith, so DROP of the aged-out monolith took the sequence the parent's default still calls:
  -- "cannot drop table ... because other objects depend on it", fail_retain_drop on every tick, and a
  -- monolith that could never be retired. deptype 'a' is OWNED BY; an identity column's sequence is 'i'
  -- and went with the drop identity above. After the renames, not before: ALTER SEQUENCE takes SHARE
  -- ROW EXCLUSIVE on the sequence, which queues every nextval, and the rename's ACCESS EXCLUSIVE on the
  -- table is what already stops those writers here.
  for v_sq in
    select d.objid::regclass as seq, a.attname
      from pg_depend d
      join pg_class s on s.oid = d.objid and s.relkind = 'S'
      join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
     where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass
       and d.refobjid = p_parent and d.refobjsubid > 0 and d.deptype = 'a'
     order by a.attnum
  loop
    execute format('alter sequence %s owned by %s.%I', v_sq.seq::text, v_parent::text, v_sq.attname);
  end loop;
  -- only a reused PRIMARY KEY makes its other columns NOT NULL; a reused UNIQUE constraint legitimately
  -- permits nullable non-control columns, so leave those as they are (and never scan them).
  if v_add_pk and v_pkcols is not null then
    foreach v_col in array v_pkcols loop
      execute format('alter table %s alter column %I set not null', v_monreg::text, v_col);
    end loop;
  end if;

  -- 7. attach the original as the bounded MONOLITH child (metadata-only via the validated CHECK), then
  -- drop the now-redundant CHECK (the partition bound enforces it).
  execute format('alter table %s attach partition %s for values from (%L) to (%L)',
                 v_parent::text, v_monreg::text,
                 pgpm._encode(p_control_kind, v_lo_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch, v_tz), pgpm._encode(p_control_kind, v_hi_native, p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch, v_tz));
  execute format('alter table %s drop constraint pgpm_monolith_bound', v_monreg::text);

  -- 7b (grants), HERE, after the rename and the attach (#706). GRANT and REVOKE take no lock on the table at
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

  -- 7a. re-add the outgoing foreign keys at the PARENT (#263), so they cover every partition instead of
  -- only the monolith. This is metadata-only: PostgreSQL ADOPTS a partition's equivalent already-validated
  -- key rather than rescanning, and the monolith's copy is the original, validated constraint. Measured on
  -- PG 17.10: 0.8 ms against a 200k-row monolith, and the resulting parent constraint is convalidated with
  -- the monolith's demoted to a child (conparentid <> 0). Empty forward partitions cost nothing either.
  -- Same transaction as the attach, so no session ever observes the parent without its keys.
  if v_out_names is not null then
    for v_i2 in 1 .. array_length(v_out_names, 1) loop
      execute format('alter table %s add constraint %I %s',
                     v_parent::text, v_out_names[v_i2], v_out_defs[v_i2]);
    end loop;
  end if;

  -- 7b (triggers). Last of the replay from 0b, and only now that both renames are done: the captured text
  -- names the ORIGINAL table, which only resolves to the parent once the live name is in place. The
  -- monolith's own originals are dropped FIRST -- creating on the parent clones the trigger onto every
  -- partition including the monolith, so leaving the original in place would give the monolith two and
  -- fire it twice for every row routed there. Order is the whole correctness argument.
  if array_length(v_trgdefs, 1) > 0 then
    for v_trg in select tgname from pg_trigger where tgrelid = v_monreg and not tgisinternal loop
      execute format('drop trigger %I on %s', v_trg.tgname, v_monreg::text);
    end loop;
    foreach v_grant in array v_trgdefs loop
      execute v_grant;   -- names the ORIGINAL table, which is now the parent: replays verbatim
    end loop;
    -- #499: the verbatim text carries no tgenabled, so every trigger just created is origin-only. Put
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
  end if;

  -- 7b (comments). Read and replayed under the lock (see 0b): COMMENT takes only SHARE UPDATE EXCLUSIVE,
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

  -- 7c. publication membership (#566). pg_publication_rel names a table by oid, and the rename made that
  -- oid the monolith, so without this every publication FOR TABLE <this table> went on publishing the
  -- monolith alone: the parent and every forward partition obtain creates were in none of them, and each
  -- row written past the monolith was silently not replicated. Add the parent to each, with the same row
  -- filter and column list (the up-front check refused the shapes a partitioned table cannot take), so
  -- every partition present and future is covered through it. The monolith's own membership is KEPT on
  -- purpose: an untransmute hands back the parent's memberships and touches only the ones that differ
  -- from it (#780), so an unchanged table comes back published with no DDL, and while it is a partition it
  -- adds nothing (publish_via_partition_root = false publishes it as a leaf of the parent anyway; true
  -- publishes it through the parent). Retention's drop of the monolith removes it with the table.
  -- Column names, not prattrs' attnums: the parent's attnums are dense, the original's may have holes
  -- where a column was dropped.
  for v_pub in
    select p.pubname, pg_get_expr(r.prqual, r.prrelid) as qual,
           (select string_agg(quote_ident(a.attname), ', ' order by a.attnum)
              from pg_attribute a where a.attrelid = r.prrelid and a.attnum = any(r.prattrs::int2[])) as cols_q
      from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
     where r.prrelid = p_parent
     order by p.pubname
  loop
    execute format('alter publication %I add table %s%s%s', v_pub.pubname, v_parent::text,
                   case when v_pub.cols_q is not null then ' (' || v_pub.cols_q || ')' else '' end,
                   case when v_pub.qual is not null then ' where (' || v_pub.qual || ')' else '' end);
  end loop;

  -- 8. parent key -- adopts the monolith's kept constraint index (metadata-only, no rebuild): a PRIMARY
  -- KEY when the reused key was the PK, a UNIQUE constraint when it was a unique constraint.
  --
  -- With the key's deferrability (#731). A bare ADD PRIMARY KEY / ADD UNIQUE is immediate, and it still
  -- adopted a DEFERRABLE monolith key, so the monolith kept its deferred check while every forward
  -- partition got an immediate clone of the parent's: a key swap inside one statement, which the table
  -- accepted before, failed with a duplicate key once its rows were past the monolith. The flags are
  -- read off the monolith's own constraint here, under the cutover's lock (p_parent is the monolith's oid
  -- by now), and the adopted index is the same one either way. The %s carries keywords only.
  --
  -- Under the table's own constraint name (#789). Declared anonymously, the parent's key took an
  -- auto-name (t_pkey came back as t_pkey1, since the monolith's index still held t_pkey, and a named
  -- ev_pk as ev_pkey), so every statement naming the key failed with 42704 on the managed table: INSERT
  -- ... ON CONFLICT ON CONSTRAINT, and migrations that ALTER, COMMENT ON or DROP it. The parent is what
  -- every statement names, so it takes the name, and the monolith's copy is renamed out of its way first
  -- (the name is also the index's, and an index name is unique in the schema). Its new name is
  -- pgpm_key_<its index oid>: whole at any key length, where <name>_pgpm cannot fit beside a 59 to 63
  -- byte name (from_hypertable hands such keys to this cutover), and recognisable by identity, which is
  -- how untransmute knows to hand the original name back. _transmute_carried_indexes refused it up front
  -- if taken. Name, index and flags are read together, off the monolith's constraint, under the lock.
  select c.conname, c.conindid,
         case when c.condeferrable and c.condeferred then ' deferrable initially deferred'
              when c.condeferrable then ' deferrable'
              else '' end
    into v_key_name, v_key_idx, v_key_defer
    from pg_constraint c
   where c.conrelid = p_parent
     and ((v_add_pk and c.contype = 'p') or (v_add_uniq and c.contype = 'u' and c.conindid = v_reuse_idx));
  if v_add_pk or v_add_uniq then
    execute format('alter table %s rename constraint %I to %I', v_monreg::text, v_key_name, 'pgpm_key_' || v_key_idx);
  end if;
  if v_add_pk then
    execute format('alter table %s add constraint %I primary key (%s)%s', v_parent::text, v_key_name,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x), coalesce(v_key_defer, ''));
  elsif v_add_uniq then
    execute format('alter table %s add constraint %I unique (%s)%s', v_parent::text, v_key_name,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x), coalesce(v_key_defer, ''));
  end if;

  -- 8b. advance each identity sequence to the original sequence's own next value (no re-issue of ids it
  -- already handed out past max), moved on along its lattice until it clears every existing id (no
  -- collision with existing rows): see _identity_reseed (#670). All three read under the lock at 0b by
  -- _identity_resume_at (#656), before step 3 dropped the original sequence.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      perform pgpm._identity_reseed(pg_get_serial_sequence(v_parent::text, v_idcols[v_i])::regclass,
                                    v_idnext[v_i], v_idmax[v_i], v_idmin[v_i]);
    end loop;
  end if;

  -- 9b. recreate secondary indexes as partitioned indexes, attaching the monolith's
  if v_idx_names is not null then
    for j in 1 .. array_length(v_idx_names, 1) loop
      v_old  := v_idx_names[j]::name;
      v_new  := (v_old || '_pgpm')::name;
      -- #669: the name is spliced by identity, not matched by pattern. pg_get_indexdef spells it
      -- quote_ident(relname), so the definition starts with exactly one of these two prefixes, and the
      -- rewrite replaces that prefix whole. A pattern (`\S+` for the name) cannot match a quoted name holding
      -- a space, and it no-oped silently: the cutover re-ran the ORIGINAL CREATE INDEX and died on a raw
      -- 42P07 after phases 1 and 2 had committed the bound. A definition that starts with neither is refused
      -- rather than executed as it stands, for the same reason.
      v_ipfx_q := 'CREATE INDEX ' || quote_ident(v_old) || ' ON ';
      v_upfx_q := 'CREATE UNIQUE INDEX ' || quote_ident(v_old) || ' ON ';
      if starts_with(v_idx_defs[j], v_upfx_q) then
        v_pdef_q := 'CREATE UNIQUE INDEX ' || quote_ident(v_new) || ' ON ONLY ' || substr(v_idx_defs[j], length(v_upfx_q) + 1);
      elsif starts_with(v_idx_defs[j], v_ipfx_q) then
        v_pdef_q := 'CREATE INDEX ' || quote_ident(v_new) || ' ON ONLY ' || substr(v_idx_defs[j], length(v_ipfx_q) + 1);
      else
        raise exception 'pg_partition_magician: cannot carry the index % of %: its definition (%) does not start with CREATE [UNIQUE] INDEX % ON, so its partitioned copy cannot be named',
          quote_ident(v_old), p_parent, v_idx_defs[j], quote_ident(v_old);
      end if;
      execute v_pdef_q;
      execute format('alter index %I.%I attach partition %I.%I', v_nsp, v_new, v_nsp, v_old);
    end loop;
  end if;

  -- 9d. REPLICA IDENTITY (#782), after 8 and 9b, so that every index it can name is on the parent. 7c
  -- carried the table's publication membership and nothing carried its replica identity, which a
  -- partitioned table's partitions do not inherit: a keyless REPLICA IDENTITY FULL table in a publication
  -- of updates and deletes got forward partitions with none, and every UPDATE and DELETE routed to one
  -- failed with 55000; a keyed one published key-only before-images instead. The parent takes the table's
  -- identity here, and every partition minted from it on (obtain below, extend_to, a regrain's fine
  -- children) takes the parent's through _replica_identity_like_parent. USING INDEX names an index: the
  -- parent's is the one the original's identity index is attached under (the key 8 adopted, or a 9b
  -- copy; an identity index is unique and plain, and _transmute_carried_indexes refuses every unique
  -- index it would not carry). The monolith is the original table and keeps its own. ALTER ... REPLICA
  -- IDENTITY takes ACCESS EXCLUSIVE, which this cutover holds, so the value read is the one carried.
  select c.relreplident into v_replident from pg_class c where c.oid = p_parent;
  if v_replident = 'i' then
    select pc.relname into v_ri_idx
      from pg_index i
      join pg_inherits h on h.inhrelid = i.indexrelid
      join pg_class pc on pc.oid = h.inhparent
     where i.indrelid = p_parent and i.indisreplident;
    if v_ri_idx is null then
      raise exception 'pg_partition_magician: cannot transmute % -- its replica identity is USING INDEX, and that index was not carried onto the partitioned parent, so the identity cannot be carried either. Set the table''s REPLICA IDENTITY to DEFAULT, FULL or an index transmute carries, then re-run transmute.',
        v_parent;
    end if;
    execute format('alter table %s replica identity using index %I', v_parent::text, v_ri_idx);
  elsif v_replident in ('f', 'n') then
    execute format('alter table %s replica identity %s', v_parent::text,
                   case v_replident when 'f' then 'full' else 'nothing' end);
  end if;

  -- 9c. NO default partition (#288). It used to sit here as the leading-edge safety net, and the drain
  -- existed to evacuate it. Instead the forward grid is built below, after registration, so a write past
  -- the monolith lands in a real bounded partition. A write past the GRID now fails outright, which is
  -- the accepted cost: obtain x partition_step is both the slack and a hard write-ahead ceiling.

  -- 10. register
  insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor,
                           partition_tz, obtain, retain, regrain_batch, paused,
                           text_time_prefix, text_time_width, text_time_radix, text_time_unit,
                           text_time_alphabet, text_time_discard_bits, text_time_epoch, monolith_oid)
  values (v_parent, p_control, p_control_kind, p_step, p_anchor, v_tz, p_obtain, p_retain,
          p_regrain_batch, p_paused,
          p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch,
          p_parent::oid)   -- #672: the original table, now the monolith (see the pgpm.part insert below)
  on conflict (parent_table) do update set
    control_column = excluded.control_column, control_kind = excluded.control_kind,
    partition_step = excluded.partition_step, partition_anchor = excluded.partition_anchor,
    partition_tz = excluded.partition_tz, obtain = excluded.obtain, retain = excluded.retain,
    regrain_batch = excluded.regrain_batch, paused = excluded.paused,
    text_time_prefix = excluded.text_time_prefix, text_time_width = excluded.text_time_width,
    text_time_radix = excluded.text_time_radix, text_time_unit = excluded.text_time_unit,
    text_time_alphabet = excluded.text_time_alphabet, text_time_discard_bits = excluded.text_time_discard_bits,
    text_time_epoch = excluded.text_time_epoch, monolith_oid = excluded.monolith_oid;

  insert into pgpm.log (parent_table, action) values (v_parent, 'transmute');
  -- keyed on v_parent, not p_parent: after the rename p_parent's oid is the monolith's, so an operator
  -- looking the table up by name would never see it (#275).
  if v_resumed then
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (v_parent, 'transmute_resume', v_lo_native, v_hi_native,
              'reused the recorded bound' || case when v_claim_tz is null then '' else ', computed in ' || v_claim_tz end);
  end if;

  -- record the original table, now the bounded MONOLITH coarse child, as an attached partition
  -- (REDESIGN.md section 7) so obtain's overlap check and status() see it.
  -- child_oid (#421). p_parent, not a fresh lookup of v_monolith: a regclass argument resolved to an
  -- OID at call time, and the rename above moved that OID to the monolith name (the same fact the
  -- note on v_parent records) -- so this is the original relation's identity carried through the
  -- conversion, not a re-resolution of the name it now answers to.
  insert into pgpm.part (parent_table, child_name, lo, hi, attached, child_oid)
    values (v_parent, v_monolith, v_lo_native, v_hi_native, true, p_parent::oid);

  -- Build the forward grid (#288). With no DEFAULT, a write past the monolith has nowhere to go until
  -- these exist, so they are created here rather than waiting for the first maintenance tick. obtain needs
  -- no special casing: the frontier sits inside the monolith, so its k=0 candidate overlaps and is skipped,
  -- and k=1 onward lays down [B, B + obtain x step) flush against the monolith's upper bound.
  perform pgpm.obtain(v_parent);

  -- the conversion is complete: deleting the claim row IS releasing the claim, and nothing is left for the
  -- reaper to undo.
  delete from pgpm.transmute_inflight where parent_table = p_parent;
end;
$$;

-- One transmute, two type-safe overloads on the width parameter (REDESIGN.md). The integer-grid and
-- time-grid families used to be three functions (transmute / transmute_by_id / transmute_by_uuidv7); they collapse
-- into a single `transmute` whose overload is chosen by the width type, with the kind read from the
-- control column. The old by_ names are removed (hard replace).
drop function if exists pgpm.transmute_by_id(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text);
drop function if exists pgpm.transmute_by_uuidv7(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text);
-- removed in the redesign (no PK rewrite -> no online PK build, no composite-FK recovery)
drop procedure if exists pgpm.build_pk_concurrently(regclass, name, interval, interval);
drop function if exists pgpm.generate_fk_recovery(regclass);

-- #309 added p_lock_timeout, which CHANGES THE ARGUMENT COUNT. CREATE OR REPLACE does not replace across
-- a different arg count, even when the new parameter has a default: re-running install.sql over a prior
-- install would leave BOTH arities defined, and every existing call site would then be ambiguous
-- (`function pgpm.transmute(...) is not unique`). That is #209/#210 exactly. Drop the old arities first.
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, int, boolean, text, boolean, int);
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, int, timestamptz, boolean, text, boolean, int);
drop procedure if exists pgpm.transmute(regclass, name, bigint, int, bigint, int, bigint, boolean, text, int);

-- text_time (issue #325 follow-up) added 4 trailing params to _transmute and to the interval-width
-- transmute overload, same #209/#210 arg-count hazard as #309's p_lock_timeout above. The bigint (id)
-- overload is untouched -- text_time has nothing to do with it -- so no drop needed for it.
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, int, boolean, text, boolean, int, text);
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, int, timestamptz, boolean, text, boolean, int, text);

-- The ULID/KSUID follow-up added 3 more trailing params (alphabet/discard_bits/epoch) to both. Same
-- #209/#210 arg-count hazard again.
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, int, boolean, text, boolean, int, text, text, int, int, text, boolean);
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, int, timestamptz, boolean, text, boolean, int, text, text, int, int, text, boolean);

-- #457 added one trailing param (p_force_frontier) to both. Same #209/#210 arg-count hazard again: without
-- these two lines the previous shapes survive an upgrade and every 3-argument call becomes ambiguous
-- (issue #441). The bigint (id) overload is untouched: an id frontier has no clock to skew against.
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, int, boolean, text, boolean, int, text, text, int, int, text, boolean, text, int, timestamptz);
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, int, timestamptz, boolean, text, boolean, int, text, text, int, int, text, boolean, text, int, timestamptz);

-- Time grid: interval width. The control column's type selects the kind -- a uuid column is TREATED as
-- uuidv7 (ULIDs stored as uuid included; PostgreSQL has no UUIDv7 type to detect, so this is an
-- assumption check_uuidv7 samples to gate, not a verification: a column that samples as overwhelmingly
-- random (UUIDv4) is refused unless p_force_uuidv7 => true), a text/varchar column is TREATED as
-- text_time (a general opaque-sortable-TEXT id, e.g. classic cuid -- _transmute is what actually
-- requires p_tt_prefix/p_tt_width/p_tt_radix/p_tt_unit to all be set for it), anything else is time
-- (timestamptz/timestamp/date; _transmute rejects anything that fits none of these). A bare interval
-- literal is ambiguous against the bigint overload, so callers cast: transmute(t, c, interval '1 month').
create or replace procedure pgpm.transmute(
  p_parent regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_regrain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_force_uuidv7 boolean default false,
  p_bound_headroom int default 0,
  p_lock_timeout text default '5s',
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_force_text_time boolean default false,
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00',
  p_force_frontier boolean default false
) language plpgsql as $$
declare v_kind text;
begin
  -- resolved into a variable first: a CALL argument may not contain a subquery
  select case when t.typname = 'uuid' then 'uuidv7'
              when t.typname in ('text', 'varchar') then 'text_time'
              else 'time' end into v_kind
    from pg_attribute a join pg_type t on t.oid = a.atttypid
   where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped;
  call pgpm._transmute(p_parent, p_control, coalesce(v_kind, 'time'),
    p_interval::text, pgpm._ts_text(p_anchor), p_obtain,
    p_retain::text, p_regrain_batch, p_paused, p_incoming_fks, p_force_uuidv7,
    p_bound_headroom, p_lock_timeout,
    p_tt_prefix, p_tt_width, p_tt_radix, p_tt_unit, p_force_text_time,
    p_tt_alphabet, p_tt_discard_bits, p_tt_epoch, p_force_frontier);
end;
$$;

-- Integer grid: bigint width. Covers int/bigint/numeric keys, including Snowflake-style ids.
create or replace procedure pgpm.transmute(
  p_parent regclass, p_control name, p_step bigint,
  p_obtain int default 30, p_retain bigint default null,
  p_regrain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_bound_headroom int default 0,
  p_lock_timeout text default '5s'
) language plpgsql as $$
begin
  -- plpgsql, not sql: a SQL-bodied routine cannot host a callee's transaction control
  call pgpm._transmute(p_parent, p_control, 'id', p_step::text, p_anchor::text, p_obtain,
                     p_retain::text, p_regrain_batch, p_paused, p_incoming_fks,
                     false, p_bound_headroom, p_lock_timeout);
end;
$$;

-- Abandon a half-finished conversion (issue #275). transmute runs in three transactions, so a failure
-- between them leaves a validated-or-not `pgpm_monolith_bound` CHECK on the operator's table, and that
-- CHECK REJECTS every write outside [lo, hi) for as long as it is there. This puts the table back exactly
-- as it was.
--
-- It ABANDONS, it does not resume: finishing someone's half-done conversion of a production table
-- unattended is too large an action to take on their behalf. Re-run transmute to try again; it will resume
-- from the recorded bound.
--
-- The lock wait is bounded (#708), with transmute's own parameter and default (p_lock_timeout, #309). The
-- DROP CONSTRAINT takes ACCESS EXCLUSIVE on the operator's live table, and under a session with no
-- lock_timeout one long reader of the table parked it, with its PENDING request queueing every other read
-- and write of the table behind it for the reader's whole life. A timeout refuses with lock_not_available
-- and changes nothing: the bound and the claim stay, and the call can simply be repeated.
-- p_lock_timeout CHANGES THE ARGUMENT COUNT, so the one-argument form has to go first or both survive and
-- every one-argument call becomes ambiguous (the #209/#210 hazard transmute's own p_lock_timeout met).
drop function if exists pgpm.transmute_abort(regclass);
create or replace function pgpm.transmute_abort(p_parent regclass, p_lock_timeout text default '5s')
returns boolean language plpgsql as $$
declare r pgpm.transmute_inflight%rowtype; v_prev_lock_timeout text;
begin
  -- a bad p_lock_timeout is refused before anything is read or changed, and leaves the setting untouched
  begin
    v_prev_lock_timeout := current_setting('lock_timeout');
    perform set_config('lock_timeout', p_lock_timeout, true);
    perform set_config('lock_timeout', v_prev_lock_timeout, true);
  exception when others then
    raise exception 'pg_partition_magician: p_lock_timeout must be a valid lock_timeout value (got %): %', p_lock_timeout, sqlerrm;
  end;
  select * into r from pgpm.transmute_inflight where parent_table = p_parent;
  if not found then return false; end if;
  -- #405: the claim's recorded session decides this, not an advisory lock anyone could have taken. When that
  -- lock gated the abort, a squatter holding it left the operator with no way to clear a bound at all --
  -- this path and the reaper both refused, for the same wrong reason.
  --
  -- #509: and "alive" alone is not "running in another session". After a cutover failure the claim's owner
  -- is the operator's own still-connected session, so this refused the operator's abort of their own failed
  -- attempt, the other documented remedy, for as long as they stayed connected. A session runs one thing at
  -- a time, so a claim this backend recorded cannot be a conversion still running: pid alone is enough
  -- here, because a recycled pid belongs to a dead owner, which _session_alive already rules out. The
  -- reaper keeps the plain liveness test on purpose: an operator whose session is still open keeps the
  -- right to retry, and a maintain_all run by hand from that session must not undo their bound.
  if pgpm._session_alive(r.owner_pid, r.owner_backend_start) and r.owner_pid <> pg_backend_pid() then
    raise exception 'pg_partition_magician: cannot abort the transmute of % -- it is still running in another session', p_parent;
  end if;
  -- #575: by the claim's oid (p_parent resolved to it, which is how the claim was found), not the name the
  -- claim recorded: after a rename or a SET SCHEMA that name is another relation or none at all.
  -- #708: under p_lock_timeout, and the caller's own setting back the moment the lock is had.
  v_prev_lock_timeout := current_setting('lock_timeout');
  perform set_config('lock_timeout', p_lock_timeout, true);
  begin
    execute format('alter table %s drop constraint if exists pgpm_monolith_bound', p_parent::text);
  exception when lock_not_available then
    raise exception 'pg_partition_magician: transmute_abort(%) could not take ACCESS EXCLUSIVE on % within % (another transaction holds a lock on it); nothing was changed, the bound and the claim are as they were. Retry when that transaction has finished, or pass a longer p_lock_timeout.',
      p_parent, p_parent, p_lock_timeout
      using errcode = 'lock_not_available';
  end;
  perform set_config('lock_timeout', v_prev_lock_timeout, true);
  delete from pgpm.transmute_inflight where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, lo, hi, method)
    values (p_parent, 'transmute_abort', r.lo, r.hi, 'bound dropped, table restored');
  return true;
end;
$$;

-- The reaper (issue #275). A conversion whose session died leaves the bound behind, and the table goes on
-- rejecting out-of-range writes until someone notices. Rather than leave that to the operator, every
-- maintain_all tick sweeps for abandoned conversions and undoes them.
--
-- "Abandoned" is decided by the claiming session's recorded identity, not by a timeout: if that session is
-- gone, the conversion is gone, whatever the reason. A long validation scan is therefore never mistaken for
-- a dead one, and an operator whose session is still open keeps the right to retry -- the sweep waits until
-- they disconnect. Before #405 this asked whether a session advisory lock could be taken, which any role
-- that could connect was free to hold: squatting the key the moment a crashed conversion released it made
-- this sweep read "still running" forever, so the bound it exists to undo never got undone.
--
-- Deliberately independent of pgpm.config: a half-converted table is not registered yet, because
-- registration happens in the cutover. That is exactly why this lives in maintain_all rather than maintain.
--
-- The lock wait is bounded (#657). The DROP CONSTRAINT takes ACCESS EXCLUSIVE on the operator's live table,
-- and this runs first in every maintain_all, before any lock_timeout is set, under pg_cron's session
-- default of 0. One long reader of the table then parked the reaper, and its PENDING ACCESS EXCLUSIVE
-- queued every other read and write of the table behind it for the reader's whole life, with the sweep
-- stalled behind it too. So the function carries transmute's own default bound (p_lock_timeout, #309),
-- for the lock that undoes the one transmute's phase 1 took: a SET clause, so it applies to every wait in
-- here and the caller's setting is back the moment this returns (the _detach_reap after it carries its own, #708).
-- A timeout DEFERS that table alone: skip_transmute_reap is logged, the claim and the bound stay exactly
-- as they were, and the next tick tries again. Any other error still propagates, as it always has.
-- bench/transmute_reap_lock_timeout.sh guards it.
create or replace function pgpm._transmute_reap()
returns int language plpgsql
set lock_timeout = '5s'
as $$
declare r pgpm.transmute_inflight%rowtype; v_n int := 0;
begin
  for r in select * from pgpm.transmute_inflight loop
    -- the relation itself is gone: nothing to undo, just forget it. Decided by the claim's oid (#575), not
    -- by the schema and name it recorded: a half-converted table renamed or moved to another schema after
    -- its conversion failed is still there under that oid, still carrying the bound, and reading it as
    -- gone deleted the one row that recorded the bound and left the CHECK rejecting writes for good.
    if not exists (select 1 from pg_class c where c.oid = r.parent_table) then
      delete from pgpm.transmute_inflight where parent_table = r.parent_table;
      v_n := v_n + 1;
      continue;
    end if;
    if pgpm._session_alive(r.owner_pid, r.owner_backend_start) then
      continue;   -- still running; leave it alone
    end if;
    begin
      execute format('alter table %s drop constraint if exists pgpm_monolith_bound', r.parent_table::text);
      delete from pgpm.transmute_inflight where parent_table = r.parent_table;
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (r.parent_table, 'transmute_reap', r.lo, r.hi,
                'abandoned conversion undone: the bound was rejecting out-of-range writes');
      v_n := v_n + 1;
    exception when lock_not_available then   -- #657: defer this table to the next tick, never stall on it
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (r.parent_table, 'skip_transmute_reap', r.lo, r.hi, left(sqlerrm, 200));
    end;
  end loop;
  return v_n;
end;
$$;

-- _detach_reap(): finish any concurrent detach whose session died part-way (issue #268).
--
-- Retiring a referenced partition dispatches `DETACH PARTITION ... CONCURRENTLY` to pg_cron, so the
-- detach genuinely runs in another session, and that session can die. Measured: a backend killed
-- during the detach's SCAN phase rolls back cleanly and leaves nothing behind, but one killed during
-- its WAIT phase -- reachable whenever any concurrent transaction still holds a snapshot on the parent
-- -- leaves the partition flagged `pg_inherits.inhdetachpending` AND its rows already invisible
-- through the parent (a 2,000,000-row parent read 1,000,000). The partition is then neither detached
-- nor dropped, and rows have silently vanished from the user's table: strictly worse than the wedge
-- this all exists to fix. `DETACH ... FINALIZE` completes it and clears the flag.
--
-- So this runs BEFORE the per-parent loop in maintain_all, like _transmute_reap: it is the most urgent
-- thing in a tick. It DROPS nothing -- retire() completes its own retirements on the normal path (it can
-- tell, from pgpm.part.retiring_at, which detach was its own), and an operator's hand-run detach that
-- was interrupted is finished and then left alone.
--
-- But a pending flag is NOT by itself an abandoned detach (issue #453). It is also the normal state of a
-- LIVE one for the whole of its wait phase, which lasts as long as the longest transaction holding a
-- lock on the parent; and the pgpm_detach job and maintain_all share a cadence, so this used to meet a
-- live detach routinely and finalize it. PostgreSQL's wait-for-old-snapshots phase was skipped, and the
-- real detacher then failed with "is not a partition", once per tick, into cron.job_run_details.
--
-- The liveness test is shaped by a measured fact about DETACH CONCURRENTLY: the detacher holds NO
-- relation lock during its wait phase. Its first transaction (SHARE UPDATE EXCLUSIVE on parent and
-- partition, set the flag) COMMITS before it starts waiting, and the wait is a bare VirtualXactLock()
-- on each lock holder's vxid, so "somebody holds a lock on the partition" cannot see the phase the bug
-- lives in. Three signals instead, any one of which means the detach is live and the row is skipped:
--   1. some other backend holds or awaits SHARE UPDATE EXCLUSIVE or ACCESS EXCLUSIVE on the partition:
--      the detacher's finalizing transaction (or anyone else's DDL on it). pg_locks, any role.
--   2. some other backend in this database is executing a DETACH PARTITION ... CONCURRENTLY that names
--      the partition. Every phase, including the instants between one wait and the next, but
--      pg_stat_activity.query is masked for a backend owned by another role, so this is only what the
--      deployment's two cron jobs (one role, both created by schedule()) see of each other.
--   3. some other backend is parked on the vxid of a transaction that holds a lock on the parent: the
--      wait phase itself, in pg_locks only, so from any role. This is what covers an operator's
--      hand-run detach under a role whose statement text this session cannot read.
-- A false positive is a one-tick deferral; a false negative is the bug. So the residual failure is
-- UNDER-reaping, never over-reaping a live one: the same discipline as _session_alive, and tests/41's
-- rule that no pgpm function reads cross-role wait_event holds (none of the three needs it).
--
-- A skipped row is NOT logged. It is the expected state of every concurrent detach for its whole
-- duration, and maintain_all would otherwise write a row per tick for as long as the longest open
-- transaction on the parent. A deferral row is for work pgpm wanted to do and could not; here there is
-- no work of pgpm's, the detach belongs to the session running it, and status().retain_detaching
-- already counts pgpm's own in-flight retirements.
--
-- The FINALIZE's lock wait is bounded (#708), exactly as _transmute_reap's is (#657) and for the same
-- reason. It takes ACCESS EXCLUSIVE on the partition, and this runs in every maintain_all before any
-- lock_timeout is set, under pg_cron's session default of 0. One ordinary reader of the abandoned
-- partition (a report, a pg_dump) then parked the reaper for that reader's whole life: the sweep never
-- reached a single parent, and every later access to the partition queued behind the pending request. So
-- the function carries transmute's default bound as a SET clause, which applies to every wait in here and
-- puts the caller's setting back the moment this returns. A timeout lands in the per-row handler below:
-- fail_detach_reap with the lock timeout as its reason, that partition left pending, the other rows still
-- reaped, and the next tick tries again. bench/reap_and_abort_lock_timeout.sh guards it.
create or replace function pgpm._detach_reap()
returns int language plpgsql
set lock_timeout = '5s'
as $$
declare
  r record; v_n int := 0;
  v_db oid := (select oid from pg_database where datname = current_database());
begin
  for r in
    select pn.nspname as pnsp, pc.relname as prel,
           cn.nspname as cnsp, cc.relname as crel,
           i.inhparent::regclass as parent, i.inhparent as parent_oid, i.inhrelid as child_oid
      from pg_inherits i
      join pg_class cc on cc.oid = i.inhrelid
      join pg_namespace cn on cn.oid = cc.relnamespace
      join pg_class pc on pc.oid = i.inhparent
      join pg_namespace pn on pn.oid = pc.relnamespace
     where i.inhdetachpending
       and i.inhparent in (select parent_table from pgpm.config)
  loop
    -- Live, not abandoned: the session running this detach is still here (see the header). Leave the
    -- row to it, silently.
    continue when
         -- 1. its finalizing transaction: SHARE UPDATE EXCLUSIVE or ACCESS EXCLUSIVE on the partition,
         --    held or awaited
         exists (select 1 from pg_locks l
                  where l.locktype = 'relation' and l.database = v_db and l.relation = r.child_oid
                    and l.mode in ('ShareUpdateExclusiveLock', 'AccessExclusiveLock')
                    and l.pid <> pg_backend_pid())
         -- 2. its statement, where this role is allowed to read it
      or exists (select 1 from pg_stat_activity a
                  where a.datname = current_database() and a.pid <> pg_backend_pid()
                    and a.state = 'active'
                    and a.query ~* 'detach[[:space:]]+partition' and a.query ~* 'concurrently'
                    and position(lower(r.crel) in lower(a.query)) > 0)
         -- 3. its wait phase: parked on the vxid of a transaction that holds a lock on the parent
      or exists (select 1
                   from pg_locks w
                   join pg_locks h on h.locktype = 'virtualxid' and h.granted
                                  and h.virtualxid = w.virtualxid
                   join pg_locks p on p.pid = h.pid and p.locktype = 'relation' and p.granted
                                  and p.database = v_db and p.relation = r.parent_oid
                  where w.locktype = 'virtualxid' and not w.granted and w.pid <> pg_backend_pid());
    begin
      execute format('alter table %I.%I detach partition %I.%I finalize',
                     r.pnsp, r.prel, r.cnsp, r.crel);
      insert into pgpm.log (parent_table, action, lo, hi, method)
        select r.parent, 'detach_reap', p.lo, p.hi,
               'an abandoned concurrent detach was finalized; its rows were already invisible through the parent'
          from pgpm.part p
         where p.parent_table = r.parent and p.child_name = r.crel;
      v_n := v_n + 1;
    exception when others then
      insert into pgpm.log (parent_table, action, method)
        values (r.parent, 'fail_detach_reap', left(sqlerrm, 200));
    end;
  end loop;
  return v_n;
end;
$$;

-- One ALTER PUBLICATION ... ADD TABLE per publication that names p_of explicitly (pg_publication_rel), naming
-- p_nsp.p_name instead, with the same column list and row filter (#780). untransmute builds these off the
-- parent under its lock, as the memberships to hand back, and off the restored table, as the ones it already
-- has; equal text means an equal membership, so only the ones that differ cost any DDL. Column names, not
-- prattrs' attnums, as in transmute's 7c: the two tables' attnums differ where a column was dropped.
create or replace function pgpm._publication_adds(p_of regclass, p_nsp name, p_name name)
returns table (o_pub name, o_def text) language sql stable as $$
  select p.pubname,
         format('alter publication %I add table %I.%I%s%s', p.pubname, p_nsp, p_name,
                case when m.cols_q is not null then ' (' || m.cols_q || ')' else '' end,
                case when m.qual is not null then ' where (' || m.qual || ')' else '' end)
    from pg_publication_rel r
    join pg_publication p on p.oid = r.prpubid
    cross join lateral (
      select pg_get_expr(r.prqual, r.prrelid) as qual,
             (select string_agg(quote_ident(a.attname), ', ' order by a.attnum)
                from pg_attribute a where a.attrelid = r.prrelid and a.attnum = any(r.prattrs::int2[])) as cols_q) m
   where r.prrelid = p_of
   order by p.pubname;
$$;

-- Reverse a transmute, exactly while it is still reversible. transmute's cutover moves no data: the
-- original table is attached intact as the monolith, merely renamed. As long as every row still lives
-- inside the monolith's [lo, hi), untransmute exploits that: detach the monolith (it is a complete
-- standalone table again the instant it detaches, because transmute never drops its PK), drop the
-- parent and its empty forward partitions, rename the monolith back, and undo the few things transmute
-- changed on it (identity moved to the parent, triggers, preserved incoming FKs) and the few things
-- maintenance may have put on it since (retention's write block, an in-flight regrain's change capture,
-- #508). It is a one-way door the moment any row lives outside the monolith: once the frontier crosses its
-- upper bound, live writes route into forward partitions, and a regrain's swap replaces the monolith with
-- its fine children -- untransmute then refuses. So it does once the monolith is gone at all, retired by
-- retention or replaced by a swap (#672): the monolith is the relation transmute recorded
-- (pgpm.config.monolith_oid), never whichever partition happens to have the smallest lo. A regrain that
-- has not swapped yet is abandoned instead, as regrain_cancel would abandon it: the monolith still holds
-- every row, so the reverse loses nothing. Returns the restored table.
--
-- Fidelity notes: an identity column comes back in the form it had, ALWAYS or BY DEFAULT (#308), and the
-- control column is left NOT NULL (transmute set it; a nullable partition key is a foot-gun, and we do
-- not record prior nullability). A preserved incoming FK on an unpartitioned referencing table comes
-- back NOT VALID (#577): validating it here would scan the referencing table under ACCESS EXCLUSIVE.
-- The table's privileges and row security come back as the PARENT had them, not as the monolith kept them
-- from the conversion (#667): table and column grants, ENABLE / FORCE ROW LEVEL SECURITY, and policies.
-- Everything else -- rows, PK, secondary indexes, their names -- is byte-for-byte.
-- untransmute carries back the parent's OWNER and COMMENTs as well as its grants (#710), for the same reason: ALTER TABLE ... OWNER TO and COMMENT ON a
-- partitioned table do not reach its partitions, so after either the monolith still carries the
-- conversion-time owner and comments, and the reverse handed the table back to an owner the operator had
-- replaced (the role that owned the managed table was left with no privilege on it at all) with the
-- comments it had before. Every column of the parent gets a statement, a null comment included, so a
-- comment removed since the conversion is removed from the restored table too; columns are matched by
-- name, which ALTER TABLE ... RENAME COLUMN on the parent keeps in step on every partition.
-- The owner is applied first, so that the reset below works on the
-- ACL the new owner holds (ALTER OWNER moves the old owner's entries to the new one) and a default ACL is
-- re-granted to the right role. Only when it differs: the same owner needs no DDL and no privilege.
-- And its PUBLICATION memberships (#780), for the same reason once more: ALTER PUBLICATION ... ADD, DROP or
-- SET TABLE naming the managed table lands on the parent's pg_publication_rel rows, which the DROP takes
-- with it, and the monolith's date from the conversion. A publication the table joined since stopped
-- publishing it at the reverse (every later write missing at its subscribers, #566's consequence) and one
-- it left published it again. The restored table leaves each publication it is in that the parent was not
-- in with the same column list and row filter, and joins each the parent was in that it is not; a
-- membership that matches costs no DDL, so a reverse with nothing changed needs no publication's owner.
create or replace function pgpm.untransmute(p_parent regclass)
returns regclass language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_monreg regclass; v_restored regclass;
  v_mon name; v_mon_lo text; v_mon_hi text; v_outside boolean;
  v_gate_q text; v_door text;   -- #443: the outside-rows check and its refusal, asked twice
  v_idcols name[]; v_idmax bigint[]; v_col name; v_m bigint; v_i int; v_idnext numeric[]; v_seq regclass;
  v_idmin bigint[]; v_mmin bigint; v_idopts text[];   -- #670: min(identity) and the sequence options, per column
  v_ra record;                                        -- #656/#670: one identity column's refreshed (next, max, min)
  v_idkinds text[];   -- #308: 'a' (ALWAYS) or 'd' (BY DEFAULT) per v_idcols entry, same order
  r pgpm.dropped_fk%rowtype; v_cdelta name; v_cfn name;
  v_trgdefs text[] := '{}'; v_tdef text;   -- #277
  v_trgnames text[] := '{}'; v_trgstates text[] := '{}';   -- #499: tgname and tgenabled, index-aligned with v_trgdefs
  v_sq record;   -- #573: serial sequences the parent owns, handed back before it is dropped
  -- #667: the parent's grants and policies as statements naming the restored table, and its RLS flags
  v_grantdefs text[] := '{}'; v_poldefs text[] := '{}'; v_rls boolean; v_rls_force boolean;
  v_acl_default boolean; v_revoked boolean := false; v_g record;
  v_owner oid; v_comdefs text[] := '{}';
  v_pubdefs text[] := '{}';   -- #780: the parent's publication memberships, as ADD TABLEs naming the restored table
  v_key_name name; v_key_mon name;   -- #789: the parent's key name, and the monolith copy's pgpm_key_<oid>
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then
    raise exception 'pg_partition_magician: % is not managed by pgpm (nothing to untransmute)', p_parent;
  end if;

  -- #443: the gate below is asked a second time under ACCESS EXCLUSIVE, and that second answer is only
  -- worth something if its snapshot postdates the lock. READ COMMITTED takes a fresh snapshot per
  -- statement, so it does; REPEATABLE READ and SERIALIZABLE pin the transaction's first snapshot, taken
  -- before this function was even entered, and the re-check would be blind to exactly the row it exists
  -- to see. Refuse rather than proceed on a stale one. (READ UNCOMMITTED is READ COMMITTED in PostgreSQL
  -- and passes too.) Nothing in pgpm calls untransmute, so only a direct caller ever meets this.
  if current_setting('transaction_isolation') not in ('read committed', 'read uncommitted') then
    raise exception 'pg_partition_magician: untransmute(%) must run in a READ COMMITTED transaction (this one is %): its outside-rows check is repeated under ACCESS EXCLUSIVE and needs a snapshot taken after that lock is granted, which a stricter isolation level cannot provide',
      p_parent, current_setting('transaction_isolation');
  end if;

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  -- resolve the regrain change-capture names (#267) NOW, while the parent and its config row still exist:
  -- they come from the oids recorded there at prepare (#496), or failing that from the parent's own name,
  -- and both are gone by the time the drop below runs.
  select delta, fn into v_cdelta, v_cfn from pgpm._regrain_capture_names(p_parent);

  -- THE GATE (REDESIGN.md section 13): a clean (metadata-only) reverse needs the original table still
  -- intact as the MONOLITH, holding the whole table, with nothing landed outside it. The reverse is a
  -- one-way door once any row lives outside the monolith's [lo, hi): a forward partition after the
  -- frontier crosses B, a backdated stray in the DEFAULT, or finer children from a regraining (Tier 2
  -- foldback / Tier 3 merge not built).
  --
  -- The monolith is the relation transmute RECORDED as the original table (#672), still an attached
  -- partition of this parent and still in pgpm.part: found by oid, never by position. It used to be "the
  -- attached partition with the smallest lo", which is the original only while the original is attached.
  -- Once retention has retired it, that is a forward partition obtain minted; once a regrain has swapped,
  -- the first fine child. With every remaining row inside the stand-in, the door below passed, and the
  -- stand-in was handed back under the table's name as the restored original, with none of the table's
  -- grants, comment or index names. The original gone is the door shut, so refuse.
  if cfg.monolith_oid is null then
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
  -- Built once and asked twice (#443): here, unlocked, as the cheap refusal that takes no lock a writer
  -- would feel when the door is already shut; and again under ACCESS EXCLUSIVE just before the DETACH,
  -- which is the answer that is acted on.
  v_gate_q := format('select exists (select 1 from %s where %I >= %L or %I < %L)',
                 p_parent::text, cfg.control_column, pgpm._encode(cfg.control_kind, v_mon_hi, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz),
                 cfg.control_column, pgpm._encode(cfg.control_kind, v_mon_lo, cfg.text_time_prefix, cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet, cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz));
  v_door := format('pg_partition_magician: cannot untransmute %s -- rows now live outside the original monolith (a forward partition past B, a backdated stray, or a regraining has split it), so a metadata-only reverse would lose data. This is a one-way door once the frontier crosses B or a regrain has split the monolith.',
                   p_parent::text);
  execute v_gate_q into v_outside;
  if v_outside then
    raise exception '%', v_door;
  end if;
  -- An object over the parent that names it by its oid (#779) would stop the DROP below, or ride it out of
  -- existence. Refused here, unlocked, as the cheap answer; and again under the lock, as the final one.
  perform pgpm._refuse_oid_bound_dependants(p_parent, true);

  -- capture the identity columns and their current max BEFORE dropping anything (transmute moved
  -- identity from the table to the parent; dropping the parent loses it, so we re-establish it on the
  -- restored monolith). The max, min and sequence position read here are only the FLOORS of where the
  -- restored sequence resumes (#656): the values used are read under the lock below, by _identity_resume_at,
  -- because writers keep taking ids until that lock is granted. Read here as well because a scan here blocks
  -- no writer, and under the lock the max and min are re-read only when an index answers them.
  select array_agg(a.attname order by a.attnum), array_agg(a.attidentity::text order by a.attnum)
    into v_idcols, v_idkinds
    from pg_attribute a where a.attrelid = p_parent and a.attidentity in ('a', 'd') and not a.attisdropped;
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('select max(%1$I)::bigint, min(%1$I)::bigint from %2$s', v_col, p_parent::text) into v_m, v_mmin;
      v_idmax := array_append(v_idmax, v_m);
      v_idmin := array_append(v_idmin, v_mmin);
      -- the parent sequence's position too (it holds whatever transmute preserved), as a floor like the max.
      -- Its options (#670) are read under the lock below (#732).
      v_seq := pg_get_serial_sequence(p_parent::text, v_col)::regclass;
      v_idnext := array_append(v_idnext, pgpm._seq_next(v_seq));
    end loop;
  end if;

  -- preserved incoming FKs: drop any currently LIVE on the parent so the parent can be dropped (an
  -- incoming FK is a constraint on the referencing table pointing AT the parent). All recorded FKs are
  -- re-added against the restored table at the end. A record the catalog no longer backs (its referencing
  -- table dropped, or its key dropped by hand) is forgotten first (#658), or the drop dies on it.
  perform pgpm._forget_dangling_fks(p_parent);
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null order by id loop
    execute format('alter table %s drop constraint %I', r.referencing_table::text, r.constraint_name);
  end loop;

  -- THE GATE, AGAIN, UNDER THE LOCK (#443). The check above ran under ACCESS SHARE, which excludes no
  -- writer: an insert into a forward partition that was uncommitted when it ran was invisible to it, and
  -- if that insert commits before the DETACH below is granted its ACCESS EXCLUSIVE, the parent is
  -- dropped with the row in it and the log calls that a success. So take the lock the DETACH is about
  -- to take anyway, explicitly and one statement early, and ask the question again under it: nothing
  -- can commit into the parent now, and READ COMMITTED (required at the top) gives this statement a
  -- snapshot taken after the lock was granted, so what it sees is final. A refusal here rolls the whole
  -- call back, and the caller's lock_timeout bounds the wait exactly as it bounded the DETACH's.
  --
  -- Locking HERE rather than before the first check is the choice that keeps the exclusive window
  -- where it was: it opens on the same line it always did (the DETACH took this very lock) and grows by
  -- one probe of partitions that are empty whenever it passes, the trigger capture and the identity read
  -- below, all catalog reads or index descents. Named through p_parent, whose ACCESS SHARE from the first
  -- check is held to the end of this transaction and so pins the name against a concurrent rename.
  execute format('lock table %s in access exclusive mode', p_parent::text);
  execute v_gate_q into v_outside;
  if v_outside then
    raise exception '%', v_door;
  end if;
  perform pgpm._refuse_oid_bound_dependants(p_parent, true);   -- #779, final: no CREATE VIEW passes this lock

  -- Capture the parent's triggers before it is dropped (#277). transmute dropped the monolith's own
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

  -- Where each restored identity sequence resumes, read under the lock for the same reason (#656): an id a
  -- writer took while the lock was queued is past any earlier read, and the restored sequence would hand
  -- it out again. Before the DROP below, which takes the parent's sequence with it.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      v_ra := pgpm._identity_resume_at(p_parent, v_idcols[v_i], v_idnext[v_i], v_idmax[v_i], v_idmin[v_i]);
      v_idnext[v_i] := v_ra.o_next; v_idmax[v_i] := v_ra.o_max; v_idmin[v_i] := v_ra.o_min;
    end loop;
  end if;
  -- And each parent sequence's options (#670), which go with the parent's sequence when the parent is
  -- dropped below, read here (#732) under a lock on the sequence itself: ALTER SEQUENCE takes no lock on the
  -- table, so the table's ACCESS EXCLUSIVE does not hold them still, and an INCREMENT BY committed while the
  -- lock above was queued, read before it, was lost with the parent. _identity_options_locked's lock is held
  -- to the commit, so one that has not committed by now waits for this reversal.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      v_idopts[v_i] := pgpm._identity_options_locked(pg_get_serial_sequence(p_parent::text, v_idcols[v_i])::regclass);
    end loop;
  end if;
  -- Capture the parent's privileges and row security (#667), here, under the lock: GRANT, REVOKE and the
  -- RLS and policy DDL all change the parent, the table the application uses by name, and none of them
  -- recurses to a partition, so the monolith still carries whatever the table had at the conversion. The
  -- parent's state is what gets handed back, replayed below onto the restored table once it has the name
  -- again, as statements built here with the name it will have (the monolith's own copy is reset first).
  -- The shape is transmute's 7b, run the other way. v_acl_default: a NULL relacl is the owner's implicit
  -- all-privileges default, which has no grant to replay.
  select relrowsecurity, relforcerowsecurity, relacl is null into v_rls, v_rls_force, v_acl_default
    from pg_class where oid = p_parent;
  -- and its owner and comments (#710, see above)
  select relowner into v_owner from pg_class where oid = p_parent;
  v_comdefs := v_comdefs || format('comment on table %I.%I is %L', v_nsp, v_rel, obj_description(p_parent, 'pg_class'));
  for v_g in
    select a.attname, col_description(p_parent, a.attnum) as c
      from pg_attribute a
     where a.attrelid = p_parent and a.attnum > 0 and not a.attisdropped
     order by a.attnum
  loop
    v_comdefs := v_comdefs || format('comment on column %I.%I.%I is %L', v_nsp, v_rel, v_g.attname, v_g.c);
  end loop;
  for v_g in
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

  -- and its publication memberships (#780, see above), under the lock for the same reason: ALTER PUBLICATION
  -- ... ADD or DROP TABLE takes SHARE UPDATE EXCLUSIVE on the table, which the first gate's ACCESS SHARE does
  -- not exclude, so one committed while the lock was queued was in neither a capture read before it nor the
  -- monolith's rows. From here none can commit.
  select coalesce(array_agg(o_def order by o_pub), '{}') into v_pubdefs
    from pgpm._publication_adds(p_parent, v_nsp, v_rel);

  -- Strip what MAINTENANCE put on the monolith before handing it back (#508). The trigger capture above
  -- reads the PARENT's pg_trigger, and DETACH strips only the clones of the parent's triggers; pgpm's own
  -- triggers sit on the CHILD, so without this the restored table carried them out of pgpm's reach:
  -- config and part are gone by the end of this call, so no tick could ever lift them. Here, under the
  -- lock and after the gate, because both helpers resolve names through p_parent, which the DROP below
  -- takes away. Two live on the monolith:
  --
  -- pgpm_write_block, retention's fence (_install_write_block). A monolith retention has reached but not
  -- dropped carries it, whether archiving was deferred (skip_archive) or the frontier regressed and the
  -- ledger's coverage kept the block (#452, skip_write_block_lift); left on, ENABLE ALWAYS, the restored
  -- table rejected every INSERT, UPDATE and DELETE with "past its retention boundary". Lifting it here is
  -- safe: the block exists to keep archive coverage truthful for the DROP retire() would do, and there is
  -- no retire() after this. Any ledger rows stay, as retire()'s do, and a later transmute that mints a
  -- child of the same name finds coverage without its block and discards it (archive_coverage_reset).
  -- _remove_write_block resolves by name and is drop-if-exists, so on a never-blocked monolith it is a no-op.
  perform pgpm._remove_write_block(p_parent, v_mon);

  -- pgpm_regrain_capture and pgpm_regrain_truncate_guard, an in-flight regrain's apparatus (#267, #449).
  -- Before its swap the monolith still holds every row and the fine copies are unreconciled duplicates,
  -- so the door is open and a metadata-only reverse loses nothing; but the capture trigger depends on the
  -- per-parent function this call drops at the end, so left on it turned the reverse into "cannot drop
  -- function ... because other objects depend on it", rolled back whole, and the copies are standalone
  -- relations the parent's DROP never reaches. Abandon the regrain the way the operator's own escape does
  -- and through the same code, so the two cannot drift: regrain_cancel takes the trigger and the guard off
  -- every child, truncates the delta, drops the copies with their part rows, clears the cursor and logs
  -- regrain_cancel once. Only when one is in flight, so a reverse of a never-regrained table logs nothing
  -- it did not do. The three tests are the three places an in-flight regrain leaves a mark, any one of
  -- which is enough to warrant the cleanup.
  if exists (select 1 from pgpm.config where parent_table = p_parent and regrain_cursor is not null)
     or exists (select 1 from pgpm.part where parent_table = p_parent and not attached)
     or pgpm._regrain_capture_active(p_parent, v_mon) then
    perform pgpm.regrain_cancel(p_parent);
  end if;

  -- detach the MONOLITH (the original table, holding everything; PK + secondary indexes intact), then
  -- drop the childless parent -- which cascades the empty DEFAULT and any empty forward partitions, and
  -- takes the parent PK, the partitioned _pgpm indexes, and the parent's identity sequence with it.
  -- DETACH FIRST: dropping a partitioned parent cascades to its partitions, which would destroy the data.
  --
  -- The key's name first (#789): the parent carries it, and transmute's step 8 renamed the monolith's copy
  -- pgpm_key_<its index oid> out of its way. Found by that identity (the name embeds the index's own oid)
  -- under the parent's key it is attached to, so a conversion from before the fix, whose monolith kept the
  -- original name while the parent took an auto-name, matches nothing and keeps its name as it was.
  select p.conname, c.conname into v_key_name, v_key_mon
    from pg_constraint c join pg_constraint p on p.oid = c.conparentid
   where c.conrelid = v_monreg and c.contype in ('p', 'u') and c.conname = 'pgpm_key_' || c.conindid::text;
  execute format('alter table %s detach partition %s', p_parent::text, v_monreg::text);
  -- The mirror of transmute's 3b (#573): the parent owns the serial sequences the monolith's column
  -- defaults still call, so dropping it would take them too ("other objects depend on it"). Hand each
  -- back to the same column of the table being restored first. Identity sequences ('i') are not these:
  -- they go with the parent and are re-created below.
  for v_sq in
    select d.objid::regclass as seq, a.attname
      from pg_depend d
      join pg_class s on s.oid = d.objid and s.relkind = 'S'
      join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
     where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass
       and d.refobjid = p_parent and d.refobjsubid > 0 and d.deptype = 'a'
     order by a.attnum
  loop
    execute format('alter sequence %s owned by %s.%I', v_sq.seq::text, v_monreg::text, v_sq.attname);
  end loop;
  execute format('drop table %s', p_parent::text);
  -- the parent's key went with it, which frees its name for the table's own key again (#789)
  if v_key_mon is not null then
    execute format('alter table %s rename constraint %I to %I', v_monreg::text, v_key_mon, v_key_name);
  end if;

  -- re-establish identity on the restored monolith, with the parent sequence's options (#670), and reseed
  -- from the parent sequence's position, clearing every existing id on its lattice (mirrors transmute's
  -- step 6/8b, applied back to the table), all read under the lock above; without the reseed the next
  -- insert would collide.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      execute format('alter table %s alter column %I add generated %s as identity %s',
                     v_monreg::text, v_idcols[v_i],
                     case when v_idkinds[v_i] = 'a' then 'always' else 'by default' end,
                     coalesce(v_idopts[v_i], ''));
      perform pgpm._identity_reseed(pg_get_serial_sequence(v_monreg::text, v_idcols[v_i])::regclass,
                                    v_idnext[v_i], v_idmax[v_i], v_idmin[v_i]);
    end loop;
  end if;

  -- rename the monolith back to the original table name. (transmute never renamed the secondary
  -- indexes, so those names are already the originals; the key's was handed back above.)
  execute format('alter table %s rename to %I', v_monreg::text, v_rel);
  v_restored := format('%I.%I', v_nsp, v_rel)::regclass;

  -- The mirror of transmute's 0d (#498): every dropped_fk record in which THIS table was the referencer
  -- named the parent, which is gone; the table is v_restored now. That covers a key another managed
  -- parent preserved against this table (the DETACH above left the parent's key on the monolith as a
  -- constraint of its own, under the recorded name, so the referenced parent's suspend and validate keep
  -- finding it) and a self-referential key of this parent's own, which the loop below re-adds on
  -- v_restored through the same column before the delete at the end forgets its record.
  update pgpm.dropped_fk set referencing_table = v_restored where referencing_table = p_parent;

  -- Replay the captured triggers onto the restored table, now that it carries the original name again,
  -- then put back each one's enabled state (#499): the replayed text leaves them all origin-only.
  foreach v_tdef in array v_trgdefs loop
    execute v_tdef;
  end loop;
  for v_i in 1 .. coalesce(array_length(v_trgdefs, 1), 0) loop
    if v_trgstates[v_i] <> 'O' then
      execute format('alter table %s %s trigger %I', v_restored::text,
                     case v_trgstates[v_i] when 'D' then 'disable'
                                           when 'A' then 'enable always'
                                           when 'R' then 'enable replica' end,
                     v_trgnames[v_i]);
    end if;
  end loop;

  -- the parent's owner before the ACL reset, and its comments (#710, see above)
  if (select relowner from pg_class where oid = v_restored) <> v_owner then
    execute format('alter table %s owner to %I', v_restored::text, pg_get_userbyid(v_owner));
  end if;
  foreach v_tdef in array v_comdefs loop
    execute v_tdef;
  end loop;

  -- Put the parent's privileges and row security on the restored table in place of the monolith's
  -- conversion-time copy (#667; captured under the lock, above). First reset that copy: every role holding
  -- anything on it, at table or column level, has it revoked (a table-level REVOKE takes the column grants
  -- with it, and CASCADE the grants made through a grant option), and every policy on it is dropped. Then
  -- the parent's grants, or with a default (NULL) ACL the owner's own privileges, which the revoke took;
  -- then its RLS flags, both directions, and its policies.
  for v_g in
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

  -- Put the parent's publication memberships on the restored table in place of the monolith's (#780;
  -- captured under the lock, above). The two are compared as the statements that would create them: one the
  -- restored table has and the parent did not, or has with another column list or row filter, is dropped;
  -- one the parent had is then added, unless the restored table already has it exactly. FOR ALL TABLES and
  -- FOR TABLES IN SCHEMA name no table, so they cover the restored table as they covered the parent.
  for v_g in select o_pub, o_def from pgpm._publication_adds(v_restored, v_nsp, v_rel) loop
    if v_g.o_def = any(v_pubdefs) then
      v_pubdefs := array_remove(v_pubdefs, v_g.o_def);
    else
      execute format('alter publication %I drop table %s', v_g.o_pub, v_restored::text);
    end if;
  end loop;
  foreach v_tdef in array v_pubdefs loop
    execute v_tdef;
  end loop;

  -- re-add every preserved incoming FK against the restored table. The recorded definition names the
  -- parent, schema-qualified, whose name the restored table now carries again. Mirror restore_incoming_fks:
  -- a partitioned referencer validates in one step (Postgres forbids NOT VALID there), anything else
  -- comes back NOT VALID, which enforces every new write from this statement on.
  --
  -- And stays NOT VALID (#577). The VALIDATE used to follow here, and it scans the whole REFERENCING
  -- table: this is a function, one transaction, holding ACCESS EXCLUSIVE on the restored table since the
  -- second gate, so every reader and writer of it waited out an O(referencing rows) scan inside what is
  -- otherwise a metadata-only reverse; and an orphan written while the key was suspended failed it and
  -- rolled the whole reverse back. restore_incoming_fks stops at NOT VALID for the same reason (#265),
  -- but there a later maintain() tick validates; here pgpm is forgetting the table, so the VALIDATE is
  -- the operator's, run in its own transaction after this one, where it takes only SHARE UPDATE EXCLUSIVE
  -- on the referencing table and ROW SHARE on this one and blocks neither. The notice names it.
  for r in select * from pgpm.dropped_fk where parent_table = p_parent order by id loop
    if (select relkind from pg_class where oid = r.referencing_table) = 'p' then
      execute format('alter table %s add constraint %I %s',
                     r.referencing_table::text, r.constraint_name, r.definition);
    else
      execute format('alter table %s add constraint %I %s not valid',
                     r.referencing_table::text, r.constraint_name, r.definition);
      raise notice 'pg_partition_magician: untransmute re-added % on % NOT VALID; validate it outside this transaction with: ALTER TABLE % VALIDATE CONSTRAINT %',
        quote_ident(r.constraint_name), r.referencing_table::text, r.referencing_table::text, quote_ident(r.constraint_name);
    end if;
  end loop;

  -- the per-parent regrain change-capture apparatus (#267) is a side relation, not a partition, so the
  -- parent's DROP above does not take it. Drop it here or untransmute leaves it orphaned. Names were
  -- resolved up front, before the parent went away.
  execute format('drop table if exists %I.%I', v_nsp, v_cdelta);
  execute format('drop function if exists %I.%I()', v_nsp, v_cfn);

  -- forget all pgpm state for this table (matched by the dropped parent's oid, which p_parent still
  -- carries), and log the reversal against the restored table.
  delete from pgpm.dropped_fk where parent_table = p_parent;
  delete from pgpm.part where parent_table = p_parent;
  delete from pgpm.regrain_lock where parent_table = p_parent;   -- #554
  delete from pgpm.config where parent_table = p_parent;
  insert into pgpm.log (parent_table, action) values (v_restored, 'untransmute');

  return v_restored;
end;
$$;

-- ============================== maintenance / observability ==============================

-- Adaptive feathering was removed with the drain it paced (#288); its measurement and reporting surface
-- followed (#304). The AIMD controller, the WAL/checkpoint/ambient sensors and feathering_validation all
-- analysed a `drain_budget` log signal that nothing emits any more, so they could only ever report
-- nothing. Nothing left in pgpm is paced by row volume: regrain has a fixed batch and obtain is pure
-- metadata.
drop function if exists pgpm._wal_sustainable_bps();
drop function if exists pgpm._feather_congested(numeric, numeric, numeric, boolean);
drop function if exists pgpm._ambient_lock_waiters();
drop function if exists pgpm._ambient_io_latency(numeric, bigint, numeric, bigint);
drop function if exists pgpm._ambient_io_surge(numeric, numeric, numeric, numeric);
drop function if exists pgpm._ambient_congested(int, int);
drop function if exists pgpm._ambient_surge(int, numeric, numeric, int);
drop function if exists pgpm._forced_checkpoints();
drop function if exists pgpm._aimd_next(int, boolean, int, int, int);
drop function if exists pgpm.feathering_validation(regclass, interval, interval);

-- set_drain_adaptive / set_drain_ambient removed with adaptive feathering (#288). They tuned the closed
-- loop that paced the drain's microbatches against WAL supply and ambient I/O. Nothing left in pgpm is
-- paced by row volume: regrain has its own fixed batch, and obtain is pure metadata.


-- _regrain_names_fit: refuse, at set_regrain time, a target step whose fine names would not fit for a
-- child auto-regrain will split (#710). set_regrain's #510 check asked _part_name for the ANCHOR cell's name
-- only, which stands for every cell of a time grid (a time label is fixed-width per granularity) but not of
-- an id grid: _id_label leaves a value at or past 10^19 unpadded and appends a fraction, so a later cell's
-- name could still be refused at tick time, by regrain_step, logged skip_regrain on every tick (#641's
-- note). A fractional target on a numeric key is the reachable case: the anchor 0 has no fraction, the
-- cell after it has every digit of the step's.
--
-- The children are the ones maintain() would pick (attached, wider than one partition_step, and the target
-- subdivides them), and for each the names regrain_step will render for its FIRST TWO and LAST TWO
-- sub-ranges, cut the way it cuts them. That is every name's width: an id label's whole part is widest at
-- one end of the range, and of any two consecutive cells one carries the fraction's full width (the last
-- fractional digit of anchor + k * step is zero for at most one of k and k + 1), so the widest label is
-- among those four; a time label's width only changes with the year, at an end as well. The value just
-- below hi is hi less one microsecond (time) or less a unit finer than any grid value's last digit (id),
-- so its floor is the last cell starting below hi. _part_name raises its own refusal for a name that does
-- not fit, so this returns nothing and only ever raises.
create or replace function pgpm._regrain_names_fit(p_parent regclass, cfg pgpm.config, p_rel name, p_step text)
returns void language plpgsql stable as $$
declare r record; f text; l text; v text; k text := cfg.control_kind; z text := cfg.partition_tz;
begin
  for r in select p.lo, p.hi from pgpm.part p where p.parent_table = p_parent and p.attached
              and pgpm._native_gt(k, p.hi, pgpm._grid_next(k, cfg.partition_step, p.lo, z))
              and pgpm._native_gt(k, p.hi, pgpm._grid_next(k, p_step, p.lo, z)) loop
    f := pgpm._grid_floor(k, p_step, cfg.partition_anchor, r.lo, z);
    l := pgpm._grid_floor(k, p_step, cfg.partition_anchor, pgpm._native_below(k, r.hi, p_step, cfg.partition_anchor), z);
    foreach v in array array[case when pgpm._native_gt(k, r.lo, f) then r.lo else f end, pgpm._grid_next(k, p_step, f, z),
        pgpm._grid_floor(k, p_step, cfg.partition_anchor, pgpm._native_below(k, l, p_step, cfg.partition_anchor), z), l] loop
      if not pgpm._native_gt(k, r.lo, v) and pgpm._native_gt(k, r.hi, v) then
        perform pgpm._part_name(p_rel, k, p_step, v, null, z);
      end if;
    end loop;
  end loop;
end;
$$;

-- the greatest value below p_native that no grid value lies between: p_native less one microsecond for the
-- time kinds (every grid value is a whole microsecond), and for id less a unit one digit finer than the
-- finest of p_native, the step and the anchor (a grid value below p_native is at least a unit of that finest
-- digit below it). Its _grid_floor is the last grid value strictly below p_native. #710.
create or replace function pgpm._native_below(p_kind text, p_native text, p_step text, p_anchor text)
returns text language sql immutable as $$
  select case when p_kind = 'id'
              then (p_native::numeric
                    - power(10::numeric, -(greatest(scale(p_native::numeric), scale(p_step::numeric),
                                                    scale(p_anchor::numeric)) + 1)))::text
              else pgpm._ts_text(p_native::timestamptz - interval '1 microsecond') end
$$;

-- Operator switch for auto-regrain (REDESIGN.md sec 12). p_target_step (an interval for time/uuidv7, a
-- bigint step as text for id) turns it on: each maintenance tick feathers the oldest frozen coarse child
-- one budget-sized microbatch toward that granularity. null turns it off (regrain stays operator-driven via
-- regrain()/regrain_history()). This only PACES regraining across ticks; regrain_step enforces its own
-- preconditions (frozen, default-clear), so enabling it is always safe: a zero or negative target (#588),
-- one the grid cannot place (#674, #641) and one coarser than partition_step (issue #341) are refused (see
-- the guards below), and maintain() only
-- ever selects a child
-- the target subdivides (#515), so no target can wedge it. Changing the target while a run is in flight
-- is refused too (#554): the run's copies belong to the step it was started at.
create or replace function pgpm.set_regrain(p_parent regclass, p_target_step text default null)
returns void language plpgsql as $$
declare
  cfg pgpm.config; v_rel name;
begin
  -- #554: a step of this parent in flight in another session commits (or aborts) before this call reads
  -- config, so the in-flight test below judges a run's committed marks, never around an uncommitted prepare
  perform pgpm._regrain_lock(p_parent);
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;

  -- #588: a zero or negative target is refused first. It is "finer" than any partition_step, so the #341
  -- comparison below would pass it, and it wedges every tick (see _regrain_step_forward). The same call
  -- refuses a shape the grid cannot place (#674, #641: a month count mixed with a duration, a sub-day step
  -- on a date column, a fractional step on an integer column; see _regrain_step_shape), which both
  -- comparisons below read through _grid_next and would pass just the same.
  if p_target_step is not null then perform pgpm._regrain_step_forward(p_parent, p_target_step); end if;

  -- #341: a p_target_step COARSER than partition_step is refused at call time. maintain()'s auto-regrain
  -- candidate query calls a child "coarse" whenever it is wider than one partition_step, and regrain_step's
  -- own 'nosubdiv' guard refuses to split a child already at (or narrower than) p_target_step, so a
  -- coarser target could only ever split each coarse child down to cells that are still "coarse" and
  -- never subdividable: the history left at the wrong grain, for good. Equal-or-finer stays allowed,
  -- matching every existing call site. partition_anchor is on-grid for ANY step (grid_floor(anchor, step,
  -- anchor) = anchor), so it is a shared point at which to compare the two steps' widths without a child
  -- row.
  --
  -- That comparison is exact for two calendar steps or two fixed ones, and only approximate across kinds
  -- (#515): a fixed target on a calendar grid, or the reverse, is compared against the ONE cell that
  -- starts at the anchor, so '30 days' on a '1 month' grid passes here (narrower than a 31-day January)
  -- although a 30-day cell that starts in February is wider than the calendar month from there. That
  -- used to wedge auto-regrain: such a cell was the oldest "coarse" candidate on every tick and
  -- 'nosubdiv' in regrain_step. It cannot any more: maintain() selects only a child the target
  -- subdivides, so the cells a target cannot split are left alone (and stay counted in
  -- status().coarse_partitions). Refusing them here exactly would need the shortest and the longest cell
  -- of a calendar step in partition_tz, DST included; the selection rule closes the wedge for every
  -- target, so this guard stays the loud refusal of the unambiguous case.
  if p_target_step is not null and pgpm._native_gt(
       cfg.control_kind,
       pgpm._grid_next(cfg.control_kind, p_target_step, cfg.partition_anchor, cfg.partition_tz),
       pgpm._grid_next(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, cfg.partition_tz))
  then
    raise exception
      'pg_partition_magician: regrain target step % is coarser than partition_step % for % -- '
      'this would wedge auto-regrain permanently; use regrain()/regrain_history() for a one-off '
      'hierarchical split instead', p_target_step, cfg.partition_step, p_parent;
  end if;

  -- #510: the fine sub-range names at the target step must fit PostgreSQL's 63-byte identifier limit, and
  -- _part_name refuses rather than truncates. Ask it here, at call time, for the anchor cell's name at the
  -- target step (a time label is fixed-width per granularity, so one cell stands for all of them; an id
  -- label is not quite: #582 leaves a value at or past 10^19 unpadded and appends a fraction, so on such
  -- a numeric key a later cell's name could still be refused at tick time, which _regrain_names_fit below
  -- asks about, #710), rather than
  -- letting every later tick raise the same refusal from regrain_step and log skip_regrain forever: the
  -- #341 wedge again, one level down. A finer step has a wider label than partition_step's, so a table
  -- that passed transmute can still be refused here, and the message says by how many bytes.
  if p_target_step is not null then
    select c.relname into v_rel from pg_class c where c.oid = p_parent;
    perform pgpm._part_name(v_rel, cfg.control_kind, p_target_step, cfg.partition_anchor, null, cfg.partition_tz);
  end if;
  -- ...and every name the children auto-regrain will split can need, not only the anchor's (#710)
  if p_target_step is not null then
    perform pgpm._regrain_names_fit(p_parent, cfg, v_rel, p_target_step);
  end if;

  -- #554: a CHANGE of target while a run is in flight is refused. Nothing records the step a run was started
  -- at: its copies were cut on that step's grid and sit in pgpm.part with that grid's bounds and names, and
  -- the cursor is one of its boundaries, while every later tick computes its sub-ranges from regrain_to.
  -- Accepted, the rest of the run walked the half-built copy on the NEW grid: its first sub-range rendered
  -- the old first copy's name and the copy violated that child's bound CHECK, or the swap's re-check found
  -- no child with the new grid's bounds and refused as if retention had been loosened, on every tick until
  -- the operator found regrain_cancel. Refused rather than abandoned (as #516 does for null): a new target
  -- is a request for more regraining, and throwing away the copy work is the operator's call to make. The
  -- target already set is not a change, so re-stating it passes; and with regrain_to null an
  -- operator-driven run is in flight at a step pgpm does not know, so any target is a change.
  if p_target_step is not null and p_target_step is distinct from cfg.regrain_to
     and pgpm._regrain_in_flight(p_parent) then
    raise exception 'pg_partition_magician: set_regrain(%, %) refused -- a regrain of % is in flight (config.regrain_cursor = %) at %, and its copies were cut on that step''s grid; the rest of the run would be computed on the new one, collide with them and wedge every tick. Let it finish, or abandon it with pgpm.regrain_cancel(%) (the source still holds every row) and set the new target then.',
      p_parent, p_target_step, p_parent, coalesce(cfg.regrain_cursor, 'null'),
      coalesce('regrain_to ' || cfg.regrain_to, 'a step it was started at by hand (regrain_to is null)'), p_parent;
  end if;

  -- #516: turning auto-regrain OFF abandons the run it had in flight. maintain dispatches regrain_step only
  -- while regrain_to is set, so once it was null the run was never driven again; and _enforce_regrain_capture
  -- keeps capture on the child whose range covers regrain_cursor, which nothing cleared, so it was never
  -- swept either. Left that way, the capture trigger taxed every write into the source and filled a delta
  -- nobody drained, the not-yet-attached copies stayed on disk, and TRUNCATE of the parent stayed refused as
  -- "a regrain is in flight", until the operator found regrain_cancel. Abandon it the way the operator's
  -- own escape does and through the same code, so the two cannot drift: trigger and TRUNCATE guard off
  -- every child, delta cleared, copies dropped with their part rows, cursor null, one regrain_cancel log
  -- row. The source still holds every row, so only the copy work is lost; completing the run instead would
  -- need its target step, which nothing records once regrain_to is gone. Only when this call actually turns
  -- auto-regrain off: a call that finds it already off changes nothing, so it cannot cancel an
  -- operator-driven regrain. Before the write below, so a lock failure inside the cancel rolls the whole
  -- call back and leaves auto-regrain on and the run intact, to be retried. The three tests are the three
  -- places an in-flight regrain leaves a mark, any one of which is enough to warrant the cleanup.
  if p_target_step is null and cfg.regrain_to is not null
     and (cfg.regrain_cursor is not null
          or exists (select 1 from pgpm.part where parent_table = p_parent and not attached)
          or exists (select 1 from pgpm.part p where p.parent_table = p_parent
                      and pgpm._regrain_capture_active(p_parent, p.child_name))) then
    perform pgpm.regrain_cancel(p_parent);
  end if;

  update pgpm.config set regrain_to = p_target_step where parent_table = p_parent;
end;
$$;

-- Operator switch for obtain's forward lookahead (issue #326). obtain/retain used to be settable
-- only at transmute time, and changing either afterward meant a raw `update pgpm.config`, with no
-- validation. p_obtain < 0 is not merely wrong, it is a SILENT no-op: obtain()'s
-- `for k in 0 .. cfg.obtain loop` never executes when cfg.obtain is negative (plpgsql's `lo .. hi`
-- is empty once lo > hi), so a negative value quietly disables all future lookahead with nothing
-- raised, ever. Refuse it here instead, before it reaches config.
create or replace function pgpm.set_obtain(p_parent regclass, p_obtain int)
returns void language plpgsql as $$
begin
  if p_obtain is null or p_obtain < 0 then
    raise exception 'pg_partition_magician: p_obtain must be a non-negative integer (got %)', p_obtain;
  end if;
  update pgpm.config set obtain = p_obtain where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- Operator switch for retention (issue #326). retain is the DESTRUCTIVE knob: it decides what
-- retain() DROPs, and a hand-written `update pgpm.config set retain = ...` has no validation at all
-- -- not the units check transmute applies (numeric for id, an interval everywhere else -- see
-- _retain_boundary), and no protection against a value that arms the very next maintain/retain tick
-- to drop a partition the current value still keeps.
--
-- Locked-in decision: REFUSE that case, not merely warn. This matches the house rule already applied
-- to set_regrain's coarser-target refusal and extend_to's p_max cap -- loud failure over a silently
-- armed destructive change. Loosening (a bigger interval/count, or null = keep forever) can never
-- trip it: a wider horizon only ever keeps a superset of what the narrower one kept, so the check
-- below is comparing _retain_boundary of the OLD config against the same function on a HYPOTHETICAL
-- one with p_retain substituted in, before anything is written.
create or replace function pgpm.set_retain(p_parent regclass, p_retain text default null)
returns void language plpgsql as $$
declare
  cfg pgpm.config;
  v_old_boundary text;
  v_new_boundary text;
  v_old_retain text;
  v_hit name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;

  if p_retain is not null then
    if cfg.control_kind = 'id' then
      begin
        perform p_retain::numeric;
      exception when others then
        raise exception 'pg_partition_magician: p_retain must be numeric for control_kind id (got %): %', p_retain, sqlerrm;
      end;
    else
      begin
        perform p_retain::interval;
      exception when others then
        raise exception 'pg_partition_magician: p_retain must be a valid interval for control_kind % (got %): %', cfg.control_kind, p_retain, sqlerrm;
      end;
    end if;
    -- #451: unconditional, whatever the current value and whatever is attached. The would-drop guard below
    -- compares BOUNDARIES, so a negative value whose boundary grid-floors to the same place as the current
    -- one (retain 0 -> -400 at a frontier of 2501, step 1000: both floor to 2000) sailed through it, and the
    -- horizon then jumped past the partition taking writes as soon as the frontier moved. Zero is allowed:
    -- it keeps only the partition taking writes.
    if not pgpm._retain_nonnegative(cfg.control_kind, p_retain) then
      raise exception 'pg_partition_magician: p_retain cannot be negative (got %) -- a negative retain puts the retention horizon past the partition taking writes, so the next maintenance tick would drop every partition, that one included; zero keeps only the partition taking writes, null keeps everything', p_retain;
    end if;
  end if;

  -- #451: a config.retain written by hand to a negative value has no honest horizon (_retain_boundary
  -- refuses it, and every tick since has kept everything), so it is compared as null here: the repair is
  -- held to the same arm-from-null rule as any other bounded value, rather than blocked by the bad value.
  v_old_boundary := case when cfg.retain is not null and not pgpm._retain_nonnegative(cfg.control_kind, cfg.retain)
                         then null else pgpm._retain_boundary(cfg) end;
  v_old_retain   := cfg.retain;
  cfg.retain := p_retain;
  v_new_boundary := pgpm._retain_boundary(cfg);

  if v_new_boundary is not null then
    select p.child_name into v_hit
      from pgpm.part p
     where p.parent_table = p_parent and p.attached
       and (v_old_boundary is null or pgpm._native_gt(cfg.control_kind, p.hi, v_old_boundary))
       and not pgpm._native_gt(cfg.control_kind, p.hi, v_new_boundary)
     order by p.lo
     limit 1;
    if found then
      raise exception
        'pg_partition_magician: set_retain(%, %) refused for % -- the next retain() tick would drop '
        '% (and possibly others), which the current retain value still keeps. retain is the '
        'destructive knob, so this is refused rather than silently armed for the next tick.',
        p_parent, p_retain, p_parent, v_hit;
    end if;
  end if;

  -- #448: a regrain in flight has already skipped sub-ranges as aged under the OLD value, and those
  -- decisions survive only as the advanced cursor. regrain_step's swap re-checks every skipped sub-range
  -- against the value in force at that moment and refuses if one is no longer below the horizon, so a
  -- loosening here loses no rows, but it does hold the swap until retain is put back or the run is
  -- cancelled. Say so now, while the operator is still at the keyboard, rather than as a skip_regrain row
  -- hours later. A WARNING and not a refusal: the change itself is safe, and refusing it would make the
  -- retention policy hostage to a background copy. Only a loosening can trip the swap, so only a
  -- loosening warns.
  if cfg.regrain_cursor is not null
     and (v_new_boundary is null
          or (v_old_boundary is not null and pgpm._native_gt(cfg.control_kind, v_old_boundary, v_new_boundary))) then
    raise warning 'pg_partition_magician: a regrain of % is in flight (config.regrain_cursor = %). Sub-ranges it has already skipped as aged under retain = % are re-checked against the new value at the swap, which refuses while any of them is no longer below the horizon. Expect the swap to wait until retain is set back, or abandon the run with pgpm.regrain_cancel(%) and re-run it under the new policy.',
      p_parent, cfg.regrain_cursor, coalesce(v_old_retain, 'null'), p_parent;
  end if;

  update pgpm.config set retain = p_retain where parent_table = p_parent;

  -- #724: a loosening that stops reaching a partition whose retirement is under way recalls its armed
  -- detach NOW, before pg_cron's next run can take the partition out of the parent; the next tick
  -- re-attaches one that a run already in flight took out anyway. See _retain_recall.
  perform pgpm._retain_recall(p_parent, false);
end;
$$;

-- Operator switch for the zone the grid is computed in (issue #455). transmute records the transmuting
-- session's TimeZone in config.partition_tz; this is the one supported way to change it afterwards, and
-- the way an upgraded install says which zone a grid built BEFORE the column existed is actually on
-- (the backfill can only write 'UTC').
--
-- Validated against pg_timezone_names (canonical spelling stored; see _canonical_tz), refused for an id
-- grid (no calendar, so nothing reads it), and REFUSED when the grid built so far is not on the new
-- zone's lattice: the newest attached bound must floor to itself in the new zone. Otherwise obtain's next
-- candidate half-overlaps the current tail child, is skipped, and every later candidate is created past
-- it, which is issue #455's permanent hole, self-inflicted. A day-denominated step is an absolute lattice
-- in every zone, so its zone can always change (only the names move); a month or year step is on a
-- different lattice in every zone with a different offset, so changing it is only possible when the grid
-- was in fact built in the new zone all along, which is exactly the upgrade case this exists for.
--
-- The newest bound alone does not establish that (#583). Two zones can agree at the top and disagree
-- further down: UTC and Europe/London share every month edge from November to March and none from April
-- to October, so a UTC grid whose monolith ends on October 1 and whose top is December 1 passed, and the
-- monolith could then never be regrained. regrain_step clamps its sub-ranges to the child's own bounds,
-- so the last one was [September 30 23:00Z, October 1 00:00Z), which renders the label of the forward
-- cell that starts at October 1, gets no fine child, and makes the swap refuse on every attempt, blaming
-- a retention change that never happened. So every attached bound that is a grid boundary in the zone
-- the grid is recorded in must be one in the new zone too. Only those: a bound the recorded zone does not
-- put on the lattice is either a finer regrain's (a day child inside a month grid, on no month lattice in
-- any zone) or, in the upgrade case, one the recorded 'UTC' never described, and neither is evidence
-- against the new zone. The top check above stays unconditional, since it is the one that judges a grid
-- whose recorded zone is wrong.
--
-- Every check judges COMMITTED pgpm.part, so the setter serialises against what builds it (#725). Without
-- a lock both sides take, a change accepted while another session's obtain() or extend_to() had built
-- cells on the old lattice and not yet committed them, or one those calls read around before it
-- committed, left the grid's top off the new zone's lattice: the one-hour hole above, which serially is
-- refused. obtain() and extend_to() read the config row FOR KEY SHARE and this reads it FOR UPDATE, the
-- one row lock that conflicts with KEY SHARE, so each waits for the other's transaction. KEY SHARE, not
-- SHARE, so neither ever waits on the plain UPDATEs other setters and a sweep's _config_try_lock make.
-- tests/195 and bench/set_partition_tz_grid_lock.sh guard both orders.
create or replace function pgpm.set_partition_tz(p_parent regclass, p_tz text)
returns void language plpgsql as $$
declare cfg pgpm.config; v_tz text; v_top text; v_off_child name; v_off_bound text;
begin
  perform pgpm._regrain_lock(p_parent);   -- #660: judge a regrain's committed marks, never around a step in flight
  -- #725: and never around an obtain() or extend_to() in flight. Both read this row FOR KEY SHARE and hold
  -- it to their transaction's end, which FOR UPDATE waits for, so the grid judged below includes every
  -- cell they built; and while this holds it, they wait and then compute in the zone it committed.
  select * into cfg from pgpm.config where parent_table = p_parent for update;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.control_kind = 'id' then
    raise exception 'pg_partition_magician: % is an id grid, which has no calendar; partition_tz is never consulted for it and stays ''UTC''', p_parent;
  end if;
  -- #504: a naive column has no zone either. Its grid is its own wall clock (partition_tz is 'UTC' for
  -- it, see _transmute), and because the zone also decides how its bound literals are rendered and read,
  -- a change would put every new partition's catalog bound off by the offset against the existing ones:
  -- pgpm.part and pg_class disagreeing, and a wall-clock hole in the forward grid that refuses writes.
  if cfg.control_kind = 'time' and pgpm._control_naive(p_parent, cfg.control_column) then
    raise exception 'pg_partition_magician: set_partition_tz(%, %) refused -- column % of % is a timestamp or date column, which carries no zone: its grid and its bound literals are the column''s own wall clock (recorded as ''UTC''), and rendering new bounds in another zone would shift them by that zone''s offset against every existing partition', p_parent, p_tz, cfg.control_column, p_parent;
  end if;
  v_tz := pgpm._canonical_tz(p_tz);
  if v_tz is null then
    raise exception 'pg_partition_magician: % is not a time zone name in pg_timezone_names', p_tz;
  end if;
  -- #660: a zone CHANGE while a regrain is in flight is refused. The checks below judge only the ATTACHED
  -- bounds; a run's copies are not attached, they sit in pgpm.part on the lattice of the zone the run was
  -- started in, and its cursor is one of that lattice's boundaries, while every later step computes its
  -- sub-ranges in whatever zone config holds by then. Accepted, a UTC month grid switched to a zone that
  -- agrees with UTC at every attached bound and disagrees inside the monolith (Africa/Sao_Tome, UTC+1
  -- through 2018) computed its next sub-range overlapping the last copy with a hole beside it, and the
  -- swap refused on every attempt, blaming a retention change. Same rule as set_regrain's (#554): the run
  -- belongs to what it was started under. Re-stating the recorded zone is not a change.
  if v_tz is distinct from cfg.partition_tz and pgpm._regrain_in_flight(p_parent) then
    raise exception 'pg_partition_magician: set_partition_tz(%, %) refused -- a regrain of % is in flight (config.regrain_cursor = %), and its copies and cursor sit on the grid as computed in %; the rest of the run would be computed in %, overlap them and leave a hole the swap refuses on every attempt. Let it finish, or abandon it with pgpm.regrain_cancel(%) (the source still holds every row) and change the zone then.',
      p_parent, p_tz, p_parent, coalesce(cfg.regrain_cursor, 'null'), cfg.partition_tz, v_tz, p_parent;
  end if;
  select pgpm._ts_text(max(hi::timestamptz)) into v_top from pgpm.part where parent_table = p_parent and attached;
  if v_top is not null
     and pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_top, v_tz)::timestamptz
         <> v_top::timestamptz then
    raise exception 'pg_partition_magician: set_partition_tz(%, %) refused -- the grid built so far ends at %, which is not a % grid boundary in %; obtain() would skip every candidate that half-overlaps an existing partition and leave a permanent hole from there to the next boundary in the new zone. The zone is fixed by the grid already built: if that grid was built in a zone pgpm had not yet recorded (an upgrade), name THAT zone.',
      p_parent, p_tz, v_top, cfg.partition_step, v_tz;
  end if;
  -- #583: every recorded-zone boundary among the attached bounds, not just the newest; the oldest one off
  -- the new lattice is named
  select p.child_name, b.bound into v_off_child, v_off_bound
    from pgpm.part p cross join lateral (values (p.lo), (p.hi)) b(bound)
   where p.parent_table = p_parent and p.attached
     and pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, b.bound, cfg.partition_tz)::timestamptz
         = b.bound::timestamptz
     and pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, b.bound, v_tz)::timestamptz
         <> b.bound::timestamptz
   order by b.bound::timestamptz, p.child_name
   limit 1;
  if found then
    raise exception 'pg_partition_magician: set_partition_tz(%, %) refused -- partition % has a bound at %, which is a % grid boundary in % (the zone the grid is recorded in) but not in %. The newest bound agrees, and that is not enough: a regrain in the new zone clamps a sub-range to that bound, the clamped sub-range renders the label of the neighbouring cell, gets no fine child, and the swap refuses on every attempt. The zone is fixed by the grid already built: if that grid was built in a zone pgpm had not yet recorded (an upgrade), name THAT zone.',
      p_parent, p_tz, v_off_child, v_off_bound, cfg.partition_step, cfg.partition_tz, v_tz;
  end if;
  update pgpm.config set partition_tz = v_tz where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, method)
    values (p_parent, 'set_partition_tz', cfg.partition_tz || ' -> ' || v_tz);
end;
$$;

-- Operator switch for the archive-before-drop strategy (issue #236's config.archive_fn contract).
-- p_archive_fn names any (p_parent regclass, p_child name, p_lo text, p_hi text) returns
-- pgpm.archive_result function -- pgpm_archive ships two (pgpm.archive_to_s3_ndjson/
-- archive_to_s3_parquet), or bring your own. Casting the argument to regprocedure validates that
-- the function exists with exactly these ARGUMENT types right away, not later when a maintenance
-- tick tries to call it; the check below does the same for what it RETURNS, which the cast never
-- looks at (#517). null (the default) turns archiving off: retire()'s drop precondition then only
-- waits on the write-block, never on coverage.
create or replace function pgpm.set_archive_fn(p_parent regclass, p_archive_fn regprocedure default null)
returns void language plpgsql as $$
declare v_rettype regtype; v_retset boolean;
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
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- pause/resume the scheduled lifecycle for one table. transmute registers a table paused by default
-- (the deliberate two-step: convert, inspect, then go live), and maintenance is a no-op while paused.
-- These are the first-class way to flip config.paused, so operators never hand-edit the catalog.
create or replace function pgpm.resume(p_parent regclass)
returns void language plpgsql as $$
begin
  update pgpm.config set paused = false where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

create or replace function pgpm.pause(p_parent regclass)
returns void language plpgsql as $$
begin
  update pgpm.config set paused = true where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- renamed maintenance -> maintain / maintenance_all -> maintain_all (completes the obtain/drain/retain
-- rhyme). Drop the old names so re-running the installer over a prior version does not strand them.
drop function if exists pgpm.maintenance(regclass);
drop procedure if exists pgpm.maintenance_all();

-- #279: maintain became a PROCEDURE. CREATE OR REPLACE cannot turn a function into a procedure, so the
-- old function has to go first or the installer fails on an upgrade with "cannot change routine kind".
drop function if exists pgpm.maintain(regclass);

-- maintain(): one tick of the lifecycle for one table.
--
-- A PROCEDURE, not a function, because a tick MUST NOT be one transaction (issue #279). obtain takes
-- ACCESS EXCLUSIVE on the parent (CREATE TABLE ... PARTITION OF) and on the DEFAULT. Locks release only
-- at transaction end, so in a single-transaction tick those were held across everything that followed,
-- including the drain -- whose duration is proportional to drain_batch. On the PARENT that blocks readers
-- too, so the whole table stalled for the length of a drain batch on every tick where obtain happened to
-- create a partition. Measured at 926 ms for a 400k batch against 96 ms for a 5k one: 10x the batch, 10x
-- the stall. That is the shape issue #263's acceptance rule exists to forbid.
--
-- So each step commits before the next begins, and no step's locks outlive it. The COMMITs sit at the top
-- level between the steps, never inside one: transaction control is illegal inside a block with an
-- EXCEPTION handler, and each step keeps its handler so a lock race still DEFERS that step alone rather
-- than aborting the tick.
--
-- The status is reported through an INOUT parameter, which is how a procedure returns anything. Callers
-- that do not care can `call pgpm.maintain(t)` and ignore it.
--
-- CAUTION for anyone adding a step: `set local` dies at COMMIT. lock_timeout is therefore re-applied
-- after every boundary below, and a new step placed after a COMMIT without re-applying it silently runs
-- with the session default -- which for obtain means waiting indefinitely for a lock it is designed to
-- fail fast on. This has happened once already (#514): the retain boundary went without its re-apply,
-- and auto-regrain's swap DETACH waited on a writer with no timeout while every read of the parent
-- queued behind it. bench/maintain_regrain_lock_timeout.sh guards that boundary; a new one needs the
-- same pairing.
create or replace procedure pgpm.maintain(p_parent regclass, inout p_status text default null)
language plpgsql as $$
declare
  cfg pgpm.config;
  v_archived int := 0; v_dropped int := 0; v_restored int := 0;
  v_regrain text := 'skipped'; v_regrain_child name; v_validated int := 0;
  v_note text := '';
  v_batch int := null;
  v_regrain_to text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.paused then p_status := 'paused'; return; end if;

  -- Maintenance is a background janitor; it must NEVER block -- let alone deadlock -- the live
  -- workload. Each step is isolated in its own subtransaction, and a step that loses a lock race
  -- is DEFERRED (retried next tick) WITHOUT aborting the tick. obtain has its own procedure and
  -- its own cron job now (maintain_obtain(), issue #347), so a slow step here never delays it in
  -- turn; what remains -- write-block, archive, retain, auto-regrain, FK restore/validate -- still
  -- gets the same short lock_timeout treatment.
  perform set_config('lock_timeout', '200ms', true);

  -- Write-block on retain-eligibility (issue #235), ahead of retain()'s own drop logic: a partition
  -- is blocked from writes the instant it crosses the boundary, whether or not (or how far along)
  -- it is being archived. One of retire()'s two drop preconditions (#238; the other is archive
  -- coverage, below).
  begin
    perform pgpm._enforce_write_blocks(p_parent);
    perform pgpm._enforce_regrain_capture(p_parent);   -- #267: reap capture left by an abandoned regrain
  exception when others then
    v_note := v_note || ' write_block_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_write_block', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#279). Installing a write-block trigger takes ACCESS EXCLUSIVE on the child. The archive
  -- step below then reads that same child for a whole byte budget, which is O(bytes), so without this
  -- the trigger's lock would cover the read.
  commit;
  perform set_config('lock_timeout', '200ms', true);

  -- Byte-budget chunked archiving (issue #237), one tick's worth per write-blocked, not-yet-covered
  -- child: only ever runs after the write-block step above, on children that step has already
  -- protected. retire()'s other drop precondition (#238) -- a child only drops once this has fully
  -- covered it.
  begin
    v_archived := pgpm._archive_step(p_parent);
  exception when others then
    v_note := v_note || ' archive_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_archive', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#279): make a whole tick's archived bytes durable before anything else runs. Chunked
  -- archiving exists so a large child is covered over many ticks; folding a tick's chunk into the same
  -- transaction as the steps after it would mean a later failure discards archive progress already paid for.
  commit;
  perform set_config('lock_timeout', '200ms', true);

  begin
    v_dropped := pgpm.retain(p_parent);
  exception when others then
    v_note := v_note || ' retain_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_retain', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#279). retain DROPs partitions, which takes ACCESS EXCLUSIVE on the parent. Also releases
  -- the FOR UPDATE SKIP LOCKED claim retain holds on each pgpm.part row it worked, which would otherwise
  -- be held against other retirement actors for the rest of the tick.
  --
  -- #514: this was the one boundary that did NOT re-apply lock_timeout, so the auto-regrain block below
  -- ran under the session default (0: wait forever). Its swap's DETACH takes ACCESS EXCLUSIVE on the
  -- parent, so a writer holding one row in the source kept that request queued for its whole
  -- transaction, every read of the parent queued behind the request, and the tick swapped when the
  -- writer let go instead of logging skip_regrain and retrying, which is what docs/reference.md promises.
  -- bench/maintain_regrain_lock_timeout.sh holds the line below in place.
  commit;
  perform set_config('lock_timeout', '200ms', true);   -- #514: the auto-regrain below is a step too

  -- Adaptive feathering, the drain step, and the FK suspension that guarded it are all gone (#288).
  -- They existed to pace and protect the evacuation of the DEFAULT partition; with a complete forward
  -- grid there is nothing to evacuate. What remains of a tick is obtain, archive, retain, regrain and the
  -- FK restore -- none of which is paced by row volume.

  -- Auto-regrain target: the oldest FROZEN coarse child that the target step SUBDIVIDES (if auto-regrain
  -- is on). A coarse child (hi > one step past lo) is frozen once its whole range is at/below the current
  -- grid floor (no live write still lands in it). Found here so the auto-regrain block below can use it.
  --
  -- "The target subdivides it" (hi > one regrain_to past lo) is regrain_step's own 'nosubdiv' precondition,
  -- verbatim, and it is REQUIRED here rather than assumed (#515). Assumed, it held only while regrain_to
  -- was no wider than partition_step at every lo, which set_regrain's #341 guard checks once, at the
  -- anchor: exact for two calendar steps or two fixed ones, not across kinds. '30 days' on a '1 month'
  -- grid is narrower than the anchor's 31-day January and was accepted, yet a 30-day cell that starts in
  -- February is wider than the calendar month from there. Once the first coarse child had been split into
  -- such cells, that one was "coarse" here and 'nosubdiv' in regrain_step, so it was the oldest candidate
  -- on every later tick, forever, and the coarse children behind it were never reached. With the second
  -- predicate here a child the target cannot split is skipped, not reselected: it stays as it is, and
  -- stays counted in status().coarse_partitions. progress().coarse_frozen mirrors this test.
  --
  -- The search runs INSIDE the regrain step's handler (#590), not ahead of it: the grid floor below
  -- comes from pgpm._frontier_native, which reads the parent under the 200 ms lock_timeout, so while
  -- another session holds a lock on the parent the 55P03 surfaces here. Outside the handler it raised out
  -- of maintain() into maintain_all(), which has no handler by design, and the sweep stopped before every
  -- parent ordered after this one. Inside it, it is this step's deferral like any other: skip_regrain,
  -- regrain=deferred, retried next tick. bench/regrain_candidate_lock_race.sh guards it.
  --
  -- The target is the one in force once the regrain lock is held (#729), not cfg.regrain_to: that was read
  -- at the top of the tick, three COMMITs ago, and an operator's set_regrain(p, null) may have committed
  -- since (the archive step alone can take seconds). Dispatched from the stale read, the tick prepared a
  -- new run (capture trigger, TRUNCATE guard, cursor) on a table whose auto-regrain was now off, which
  -- nothing drives and which a second set_regrain(p, null), finding auto-regrain already off, by design
  -- does not cancel. regrain_step re-checks nothing (it is also the operator's own entry point, for any
  -- target), so the re-read is here, under the lock set_regrain takes before it reads: a set_regrain that
  -- committed first is seen below, and one that comes after waits for this tick to commit and then cancels
  -- the run it finds (#516). The lock is regrain_step's own (re-entrant), taken a few statements earlier,
  -- and inside the handler so a holder defers the step like any other lock race. Only while the top-of-tick
  -- read had auto-regrain on: a parent that never had it takes no regrain lock, and one turned on mid-tick
  -- starts next tick. tests/191 and bench/maintain_sweep_reads_tap.sh guard it.
  if cfg.regrain_to is not null then
    begin   -- #590: the candidate search is part of the regrain step
      perform pgpm._regrain_lock(p_parent);   -- #729: before the re-read
      select regrain_to into v_regrain_to from pgpm.config where parent_table = p_parent;
      if v_regrain_to is not null then   -- #729: off since the top of the tick, so no candidate either
        execute format(
        'select child_name from pgpm.part p where p.parent_table = %L::regclass and p.attached'
        || ' and pgpm._native_gt(%L, p.hi, pgpm._grid_next(%L, %L, p.lo, %L))'
        || ' and pgpm._native_gt(%L, p.hi, pgpm._grid_next(%L, %L, p.lo, %L))'   -- #515: the target subdivides it
        || ' and not pgpm._native_gt(%L, p.hi, %L) order by p.lo::%s asc limit 1',
        p_parent::text, cfg.control_kind, cfg.control_kind, cfg.partition_step, cfg.partition_tz,
        cfg.control_kind, cfg.control_kind, v_regrain_to, cfg.partition_tz,
        cfg.control_kind,
        pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, pgpm._frontier_native(p_parent), cfg.partition_tz),
        pgpm._native_type(cfg.control_kind))
        into v_regrain_child;
      end if;
      v_batch := cfg.regrain_batch;   -- regrain's own microbatch size

      -- Auto-regrain (REDESIGN.md sec 12): feather the oldest frozen coarse child (v_regrain_child, found
      -- just above) one COPY microbatch (sized by regrain_batch) toward regrain_to per tick. Isolated in
      -- its own subtransaction; a lock race or a soft status just retries next tick. regrain COPIES and
      -- never deletes: the source stays whole and attached until the atomic swap, so it never moves a
      -- referenced row out of the parent, never opens the snapshot() gap, and needs NO FK leash -- it is
      -- NOT gated on a live preserve FK and runs whether or not one is suspended.
      if v_regrain_to is null then
        v_regrain := 'skipped';   -- #729: auto-regrain was turned off during this tick
      elsif v_regrain_child is not null then
        v_regrain := pgpm.regrain_step(p_parent, v_regrain_child, v_regrain_to, v_batch);
      else
        v_regrain := 'none';   -- auto-regrain on, but no frozen coarse child to work
      end if;
    exception when others then
      v_regrain := 'deferred';
      v_note := v_note || ' regrain_deferred';
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_regrain', left(sqlerrm, 200));
    end;
  end if;

  -- BOUNDARY (#279). regrain_step's swap is atomic within itself; this only stops its locks reaching
  -- the FK restore below, which re-adds a foreign key and so takes locks of its own on both sides.
  commit;
  perform set_config('lock_timeout', '3s', true);

  -- Re-add any incoming FKs that transmute(..., 'preserve') dropped, now against the new parent, AFTER
  -- the regrain has moved this tick. restore_incoming_fks self-gates on quiescence (no in-flight,
  -- not-yet-attached child), so while a multi-tick regrain is mid-flight it stays a no-op and
  -- the FK remains suspended (RI off, surfaced by status().fks_suspended), re-adding only once the regrain
  -- has swapped in its fine children. Isolated: a hiccup here never aborts progress.
  begin
    v_restored := pgpm.restore_incoming_fks(p_parent);
  exception when others then
    v_note := v_note || ' restore_fk_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_restore_fk', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#265). The restore above re-adds the FK NOT VALID and stops, which takes SHARE ROW
  -- EXCLUSIVE on the managed parent -- briefly, since NOT VALID scans nothing. This drops that lock
  -- BEFORE the validation scan below, which is the entire point: the two used to share a transaction and
  -- the scan ran under the ADD's lock, blocking writes on the parent for O(referencing table).
  commit;
  perform set_config('lock_timeout', '3s', true);

  -- Finish the validation, in its own transaction, where the VALIDATE holds only SHARE UPDATE EXCLUSIVE
  -- on the referencing table and ROW SHARE on the parent -- neither of which blocks writes. Usually the
  -- tick after the restore. p_respect_backoff so an FK blocked by a pre-existing orphan parks for five
  -- minutes rather than re-scanning the referencing table every tick to learn the same thing.
  begin
    v_validated := pgpm.validate_incoming_fks(p_parent, p_respect_backoff => true);
    if v_validated > 0 then v_note := v_note || format(' validated_fk[%s]', v_validated); end if;
  exception when others then
    v_note := v_note || ' validate_fk_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_validate_fk', left(sqlerrm, 200));
  end;

  p_status := format('archived=%s dropped=%s restored_fk=%s regrain=%s%s',
                     v_archived, v_dropped, v_restored, v_regrain, v_note);
end;
$$;

-- A sweep's bookkeeping write to a parent's pgpm.config row goes through this (#662): it takes the row
-- with SKIP LOCKED and says whether it has it. The row lock is then this transaction's own, so the UPDATE
-- that follows cannot wait. While another transaction holds the row (an operator's open transaction around
-- a setter, a synchronous regrain() advancing regrain_cursor), the answer is false and the caller skips the
-- write: the stamps it guards are bookkeeping, and without this they were plain UPDATEs outside any
-- handler, so a held row raised 55P03 out of the sweep under a lock_timeout, or with none (the first
-- parent's turn stamp) waited for as long as the holder stayed open, and every parent behind it went
-- unmaintained. Each caller says why its write may be skipped. FOR NO KEY UPDATE is the lock the UPDATE
-- itself takes, so this conflicts with nothing that UPDATE would not (a foreign key's KEY SHARE, say).
-- tests/167 and bench/config_stamp_lock.sh guard it.
create or replace function pgpm._config_try_lock(p_parent regclass)
returns boolean language plpgsql as $$
begin
  perform 1 from pgpm.config where parent_table = p_parent for no key update skip locked;
  return found;
end;
$$;

create or replace procedure pgpm.maintain_all()
language plpgsql as $$
-- v_status exists only to receive maintain()'s INOUT: PL/pgSQL requires a writable argument for an
-- output parameter, so the parameter's default cannot be relied on here. The sweep discards it; the
-- per-parent detail is already in pgpm.log.
declare r record; v_status text; v_warn boolean; v_first boolean := true;
begin
  -- #275: undo any conversion whose session died mid-way, before anything else. Independent of
  -- pgpm.config on purpose: a half-converted table is not registered yet.
  perform pgpm._transmute_reap();
  -- #268: and any concurrent detach whose session died mid-way, for the same reason and with more
  -- urgency -- a partition left pending has its rows already invisible through the parent.
  perform pgpm._detach_reap();
  commit;

  -- #347: maintain() no longer obtains at all -- obtain() only still runs if the 'pgpm_obtain' job
  -- also got scheduled. schedule() is operator-invoked, never automatic, so an installation that
  -- already called it before upgrading past this change will NOT pick up the new job on its own.
  -- Warn once per sweep rather than silently obtaining here as a fallback: a fallback would just
  -- reintroduce, hidden, the exact "one slow table hostages another's obtain" problem this issue
  -- removes. Dynamic EXECUTE: cron.job is only resolved at call time, so this file still installs
  -- cleanly where pg_cron is not enabled (see pgpm._dispatch_detach).
  begin
    execute 'select exists (select 1 from cron.job where jobname = ''pgpm'' and database = current_database())'
         || ' and not exists (select 1 from cron.job where jobname = ''pgpm_obtain'' and database = current_database())'
      into v_warn;
  exception when others then
    v_warn := false;   -- no pg_cron, or no privilege on cron.job: nothing to warn about
  end;
  if v_warn then
    insert into pgpm.log (action, method)
      values ('warn_obtain_unscheduled',
              'pgpm_obtain cron job missing; re-run pgpm.schedule() to restore obtain (issue #347)');
  end if;

  -- One transaction per parent, not one for the whole sweep (#279). Two reasons. Locks: without it,
  -- every parent's locks accumulate until the last one is done, so a ten-table sweep ends holding ten
  -- tables' worth. Progress: a parent that raises no longer costs the parents before it their work.
  --
  -- Ordered by whose turn is oldest (#579), not by a fixed key. The whole sweep is one top-level
  -- statement, so statement_timeout runs across every parent in it, and the query_canceled that ends a
  -- sweep escapes maintain()'s `when others` (by PostgreSQL's design, rightly). In a fixed order a parent
  -- with a backlog near the front spent the shared clock on every tick and the parents behind it were
  -- cancelled on every tick, though each one's own maintain() fits the timeout comfortably. A parent's
  -- turn is stamped (config.sweep_turn_at) when its maintain() returns, so one cut short keeps its old
  -- stamp and leads the next sweep. The FIRST parent of a sweep is stamped before it starts as well: it
  -- runs on the whole clock, so if even that is not enough it has had its fair turn, and without the
  -- early stamp a parent whose own tick overruns the timeout would lead, and cancel, every sweep. So each
  -- sweep moves its first parent to the back, and within N sweeps (N managed parents) every parent has
  -- led one with the whole clock to itself: one whose own tick fits the timeout is never starved. Still
  -- reproducible: with nothing cut short the order is the same every tick (ties by oid), which keeps
  -- pgpm.log readable and a partial sweep's stopping point meaningful. The order is read once, when the
  -- loop opens, so the stamps below do not reorder the sweep in flight.
  -- bench/maintain_all_sweep_turns.sh guards it.
  --
  -- Deliberately NO exception handler around the call. One would abort the whole sweep on the first
  -- failing parent -- and worse, transaction control is illegal anywhere below an EXCEPTION handler, so
  -- wrapping this would silently disable every COMMIT inside maintain() and put the locks straight back.
  -- maintain() already isolates each of its own steps, so the raises that reach here are the ones that
  -- should stop a sweep: a table that is not managed, or a config row pointing at something gone.
  --
  -- The turn stamps are the one thing here that is not maintain()'s, so they are the one thing that must
  -- not stop a sweep either (#662): each is taken through _config_try_lock and skipped while another
  -- transaction holds the parent's config row. A skipped stamp costs only the order: a parent whose turn
  -- was not stamped after its maintain() leads the next sweep, and one whose first-parent stamp was
  -- skipped may lead it again, once per sweep that finds its row held.
  for r in select parent_table from pgpm.config order by sweep_turn_at asc nulls first, parent_table loop
    if v_first then   -- #579: the sweep's first parent has had its turn once it starts
      if pgpm._config_try_lock(r.parent_table) then
        update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;
      end if;
      commit;
      v_first := false;
    end if;
    call pgpm.maintain(r.parent_table, v_status);
    if pgpm._config_try_lock(r.parent_table) then
      update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;
    end if;
    commit;
  end loop;
end;
$$;

-- maintain_obtain()/maintain_obtain_all() (issue #347): obtain, pulled out of maintain()/maintain_all()
-- into its own procedure and its own cron job. maintain_all() loops over every managed table
-- sequentially in one session; a slow archive/retain/regrain for one table used to delay obtain for
-- every table after it in the same tick, and unlike those other steps, a late obtain has a hard
-- consequence -- with no DEFAULT partition (#288), a write past the forward grid is rejected outright,
-- not queued. obtain's own backoff (cfg.obtain_retry_after) is per-parent, persisted state, not
-- in-memory, so it already coordinates correctly regardless of which session calls pgpm.obtain(); this
-- split introduces no new coordination problem. pgpm.obtain() itself is untouched -- it stays the pure
-- engine underneath, same as retain()/_archive_step()/regrain_step() are underneath maintain().
create or replace procedure pgpm.maintain_obtain(p_parent regclass, inout p_status text default null)
language plpgsql as $$
declare
  cfg pgpm.config;
  v_made int := 0;
  v_note text := '';
  v_try boolean;
  v_ahead int;
  v_cell text;
  v_top text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  -- Independently honor paused: this now runs on its own cadence and cannot assume maintain() ran
  -- first, or at all, in the same tick.
  if cfg.paused then p_status := 'paused'; return; end if;

  -- obtain gets a VERY SHORT lock_timeout. Its _create_partition is a single
  -- `CREATE TABLE ... PARTITION OF`, taking ACCESS EXCLUSIVE on the PARENT (issue #288 -- there is
  -- no DEFAULT partition to hold anything anymore) and scanning nothing. That ACCESS EXCLUSIVE still
  -- blocks every ordinary read or write through the parent for as long as the wait lasts, and a
  -- pending one queues every new locker behind it, so failing fast keeps a deferral nearly free: no
  -- long block, and obtain simply retries once this next has a gap. obtain is pgpm's only defence
  -- against a write with nowhere to go (there is no DEFAULT to catch one), but the future cells it
  -- creates aren't written yet, so deferring one tick costs nothing but time.
  perform set_config('lock_timeout', '200ms', true);

  -- obtain back-off: once a deferral happens, don't retry every tick -- under sustained write contention
  -- obtain can lose the lock race tick after tick, and each attempt queues an ACCESS EXCLUSIVE behind the
  -- workload for up to lock_timeout. A successful obtain clears the back-off.
  --
  -- The back-off must never outlast the grid. It dates from when a DEFAULT partition caught writes past
  -- the grid, which made deferring obtain harmless; since #288 such a write is refused. A load test at
  -- ~42k ids/s against a 3-partition lookahead (~14 s) lost one race, backed off 30 s, and every client
  -- aborted. So the back-off is honored only while at least ceil(obtain / 2) complete grid steps of attached
  -- coverage remain beyond the frontier's own grid cell; below that, obtain runs regardless.
  --
  -- COVERAGE, not a count of partitions that start past the frontier: transmute's p_bound_headroom gives
  -- the monolith a permanent hi several steps beyond the frontier, and that room is real even though the
  -- monolith's lo is far behind. Counting only partitions whose lo is ahead saw none of it, so such a table
  -- bypassed the back-off every tick and retried obtain's ACCESS EXCLUSIVE while it still had room (review
  -- on #386). Steps are walked from the frontier's cell up to max(hi), which assumes attached coverage is
  -- contiguous there: obtain and extend_to build it end to end, and retain only drops the oldest cells.
  -- The walk stops at the threshold, so it costs at most ceil(obtain / 2) grid steps. Counted only while a
  -- back-off is active, so a healthy tick pays nothing extra, and guarded so a failure to count (a dropped
  -- parent, say) falls back to the back-off rather than aborting the sweep.
  v_try := coalesce(cfg.obtain_retry_after, '-infinity'::timestamptz) <= clock_timestamp();
  if not v_try then
    begin
      -- the first grid boundary past the frontier's own cell, and the top of attached coverage
      v_cell := pgpm._grid_next(cfg.control_kind, cfg.partition_step,
                  pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                   pgpm._frontier_native(p_parent), cfg.partition_tz), cfg.partition_tz);
      execute format('select %s from pgpm.part where parent_table = %L::regclass and attached',
                     pgpm._max_hi_native(cfg.control_kind), p_parent::text) into v_top;
      v_ahead := 0;
      while v_top is not null and v_ahead < ceil(cfg.obtain / 2.0)
            and not pgpm._native_gt(cfg.control_kind,
                  pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_cell, cfg.partition_tz), v_top) loop
        v_ahead := v_ahead + 1;
        v_cell := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_cell, cfg.partition_tz);
      end loop;
      v_try := v_ahead < ceil(cfg.obtain / 2.0);
      if v_try then v_note := v_note || ' obtain_backoff_bypassed'; end if;
    exception when others then
      v_try := false;
    end;
  end if;
  if v_try then
    -- Back inside a handler (#288). obtain no longer commits -- with no DEFAULT there is no
    -- exclusion-constraint dance and no phases -- so the wrapper is legal again, and a lock race here
    -- is deferred like any other step. This is the ONLY thing standing between the workload and a
    -- write with nowhere to go, so a deferral also starts the back-off rather than retrying every tick.
    --
    -- Both back-off writes go through _config_try_lock (#662) and are skipped while another transaction
    -- holds this parent's config row. Unguarded, the clearing UPDATE hit the 200 ms lock_timeout, the
    -- handler's own UPDATE hit it again with nothing around it, and the 55P03 escaped into
    -- maintain_obtain_all(), which has no handler, so every parent behind this one was denied obtain. A
    -- clear that is skipped leaves a back-off that has already expired or been bypassed; an arming that is
    -- skipped means obtain retries on the next tick, the direction that protects the grid.
    begin
      v_made := pgpm.obtain(p_parent);
      if cfg.obtain_retry_after is not null then
        if pgpm._config_try_lock(p_parent) then
          update pgpm.config set obtain_retry_after = null where parent_table = p_parent;
        end if;
      end if;
    exception when others then
      v_note := v_note || ' obtain_deferred';
      if pgpm._config_try_lock(p_parent) then
        update pgpm.config set obtain_retry_after = clock_timestamp() + interval '30 seconds'
          where parent_table = p_parent;
      end if;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_obtain', left(sqlerrm, 200));
    end;
  else
    v_note := v_note || ' obtain_backoff';
  end if;

  -- Drops obtain's ACCESS EXCLUSIVE on the parent (and, before #288, the DEFAULT) promptly rather
  -- than holding it until whatever calls this next commits.
  commit;

  p_status := format('obtained=%s%s', v_made, v_note);
end;
$$;

create or replace procedure pgpm.maintain_obtain_all()
language plpgsql as $$
-- Mirrors maintain_all()'s loop shape exactly (no exception handler around the call --
-- maintain_obtain() already isolates its own failure). Deliberately does NOT duplicate maintain_all()'s
-- crash-recovery reaping (_transmute_reap()/_detach_reap()): obtain does not depend on either having
-- run, and the main maintain_all() job still performs them on its own cadence regardless of whether this
-- job also runs.
--
-- And in maintain_all()'s turn order, with its turn stamps (#634): oldest config.sweep_turn_at first, the
-- sweep's first parent stamped before it starts, every parent stamped when its maintain_obtain() returns,
-- each stamp through _config_try_lock (#662). This sweep is one top-level statement too, so
-- statement_timeout runs across every parent in it and the query_canceled that ends it escapes
-- maintain_obtain()'s `when others`. In the fixed `order by parent_table` it used to follow, a parent
-- whose obtain overran the clock was first on every sweep and every parent behind it was denied obtain on
-- every sweep, and a late obtain is the one late step that refuses writes. See maintain_all() for why
-- the rule starves no parent whose own step fits the timeout. The two sweeps share the one turn record
-- on purpose: a sweep that completes stamps every parent in the order it visited them, which leaves the
-- order as it found it, so only a sweep that was cut short moves anyone, and a parent either sweep cut
-- short leads the next sweep of both. tests/192 and bench/maintain_sweep_reads_tap.sh guard it.
declare r record; v_status text; v_first boolean := true;
begin
  for r in select parent_table from pgpm.config
            order by sweep_turn_at asc nulls first, parent_table loop   -- #634: maintain_all()'s order
    if v_first then   -- #634: as in maintain_all(), the first parent has had its turn once it starts
      if pgpm._config_try_lock(r.parent_table) then
        update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;
      end if;
      commit;
      v_first := false;
    end if;
    call pgpm.maintain_obtain(r.parent_table, v_status);
    if pgpm._config_try_lock(r.parent_table) then
      update pgpm.config set sweep_turn_at = clock_timestamp() where parent_table = r.parent_table;
    end if;
    commit;
  end loop;
end;
$$;

-- schedule()/unschedule(): a thin convenience wrapper around pg_cron for the three jobs pgpm needs, so the
-- operator does not hand-write the cron incantation. pgpm never schedules on its own (transmute stays
-- pg_cron-free, and a tick can be driven by hand with maintain/maintain_all/maintain_obtain_all); this
-- is the deliberate, discoverable way to turn the scheduled lifecycle on. One canonical job named 'pgpm'
-- calls maintain_all() for ALL managed tables, so it is scheduled once, not per table, and re-scheduling
-- updates the interval rather than duplicating. 'pgpm_obtain' (issue #347) calls maintain_obtain_all()
-- on its own, independent cadence (p_obtain_every), so a slow archive/retain/regrain for one table can
-- never delay obtain for another. The third, 'pgpm_detach', is idle machinery for issue #268 and is
-- described at its creation below; it is required only for retiring a partition that an incoming
-- foreign key references, and its cadence stays tied to p_every, not p_obtain_every. All three target
-- current_database() via schedule_in_database, so they run against the database pgpm lives in whether
-- or not that is the cron database. The cron calls are dynamic (EXECUTE) on purpose: the cron schema is
-- only resolved at call time, so this file still installs cleanly where pg_cron is not enabled yet. Run
-- it FROM the database where pg_cron is installed (its `cron` schema must be present); uninstall.sql
-- already unschedules every 'pgpm%' job. p_every/p_obtain_every are pg_cron schedules: standard 5-field
-- cron ('* * * * *' = every minute, the default; '*/5 * * * *' = every 5 min) or pg_cron's seconds
-- interval ('30 seconds'). Note pg_cron does NOT accept '1 minute'-style interval strings; minute
-- cadence goes through cron syntax.
--
-- UPGRADE HAZARD (issue #347): schedule() is operator-invoked, never automatic. An installation that
-- already called pgpm.schedule() before upgrading to a version with this split will NOT pick up the new
-- 'pgpm_obtain' job just by installing a newer install.sql -- maintain() no longer obtains at all, so
-- obtain silently stops running for that installation until the forward grid runs out and writes start
-- failing. There is no automatic migration for this, by design (a fallback that ran obtain from
-- maintain_all() when 'pgpm_obtain' is missing would just reintroduce the same hostage problem, hidden).
-- ANYONE UPGRADING PAST THIS CHANGE WHO HAS ALREADY RUN pgpm.schedule() MUST RE-RUN IT. maintain_all()
-- also logs a 'warn_obtain_unscheduled' row to pgpm.log once per sweep as a backstop for anyone who
-- misses this note.
-- schedule(text) shipped in 0.2.0 through 0.4.0; kept beside this shape, pgpm.schedule() is ambiguous (#441)
drop function if exists pgpm.schedule(text);
create or replace function pgpm.schedule(p_every text default '* * * * *',
                                          p_obtain_every text default '* * * * *')
returns bigint language plpgsql as $$
declare v_jobid bigint;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'pg_partition_magician: pg_cron is not installed in this database; enable it (create extension pg_cron) to schedule maintenance, or call pgpm.maintain_all() and pgpm.maintain_obtain_all() by hand';
  end if;
  execute format('select cron.schedule_in_database(%L, %L, %L, %L)',
                 'pgpm', p_every, 'call pgpm.maintain_all()', current_database())
    into v_jobid;
  -- Independent cadence from 'pgpm' on purpose (issue #347): obtain is the one step where falling
  -- behind has a hard consequence (no DEFAULT partition since #288, so a late write is rejected
  -- outright, not queued), so it gets its own job rather than sharing the main sweep's schedule.
  execute format('select cron.schedule_in_database(%L, %L, %L, %L)',
                 'pgpm_obtain', p_obtain_every, 'call pgpm.maintain_obtain_all()', current_database());
  -- This job exists solely as a place for retire() to put a `DETACH PARTITION ... CONCURRENTLY`
  -- (issue #268), which PostgreSQL refuses to execute from a function but a cron job runs as a
  -- top-level statement. It is created IDLE and stays idle until a REFERENCED partition needs
  -- retiring, at which point retire() rewrites its command in place and returns it to `select 1` once
  -- the drop lands. One standing job, rewritten, rather than one per retirement: pg_cron has no
  -- one-shot schedule, so a per-retirement job would keep firing after it succeeded.
  execute format('select cron.schedule_in_database(%L, %L, %L, %L)',
                 'pgpm_detach', p_every, 'select 1', current_database());
  return v_jobid;
end;
$$;

create or replace function pgpm.unschedule()
returns int language plpgsql as $$
declare v_n int := 0;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    return 0;   -- nothing scheduled if pg_cron is not here
  end if;
  execute 'select count(*)::int from (select cron.unschedule(jobid) from cron.job '
       || 'where jobname in (''pgpm'', ''pgpm_obtain'', ''pgpm_detach'') and database = current_database()) s' into v_n;
  return v_n;
end;
$$;

-- forget_missing(): clear pgpm's state for managed tables whose relation no longer exists (issue #296).
--
-- `pgpm.untransmute` is the sanctioned way to stop managing a table, and it deletes the pgpm rows. A plain
-- `DROP TABLE` does not: pgpm.config.parent_table is a regclass, which carries no dependency, so the row
-- survives pointing at a dead oid. Nothing then cleans it up, ever, and the consequences are permanent --
-- every maintenance tick logs skip_obtain / skip_write_block / skip_retain for it, and (before #296)
-- status() raised rather than reporting anything at all. There is a second, quieter reason not to leave it
-- sitting: pg_class oids are recycled, so a stale row is a standing chance of pgpm one day believing it
-- manages an unrelated table that happens to land on that oid.
--
-- Takes NO ARGUMENT deliberately. The relation is gone, so there is no name to pass, and an oid parameter
-- would be a foot-gun; with no argument the function can only ever match rows whose relation is ALREADY
-- absent, so by construction it cannot touch a live managed table. That is why this is safe to expose and
-- safe to re-run.
--
-- It DELETES pgpm's own bookkeeping and DROPS NOTHING. A detached partition survives its parent's DROP
-- still holding its rows (measured on PG 17.10) -- and "detached, not yet dropped" is exactly the state a
-- referenced partition's retirement sits in between the cron detach and the completing drop (#268). Those
-- tables are REPORTED in orphan_tables, by name, and left alone: destroying data as a side effect of a
-- cleanup command would be the worst possible reading of "forget". pgpm.log is left intact too -- it is an
-- append-only audit trail, and the history of a table that once existed is still history.
create or replace function pgpm.forget_missing()
returns table (parent_oid oid, partitions_forgotten int, orphan_tables text[])
language plpgsql as $$
declare r record; v_orphans text[]; v_parts int;
begin
  for r in
    select c.parent_table, c.parent_table::oid as oid
      from pgpm.config c
     where not exists (select 1 from pg_class k where k.oid = c.parent_table)
     order by c.parent_table::oid
  loop
    -- Children pgpm still has a row for that are STILL PRESENT on disk: everything attached went with the
    -- parent's DROP, so anything left here was detached first and is holding data nobody agreed to lose.
    --
    -- Matched on the child NAME alone, because pgpm.part records no namespace and the dropped parent's oid
    -- can no longer supply one. So this can in principle name a same-named table in an unrelated schema.
    -- Reported SCHEMA-QUALIFIED for exactly that reason: an operator acting on this list has to be able to
    -- see which table is meant, and if two schemas collide both are listed rather than one being guessed
    -- at. relkind filtered to tables/partitioned tables so an index or sequence sharing the name cannot
    -- appear as data at risk.
    select coalesce(array_agg(format('%I.%I', n.nspname, k.relname) order by n.nspname, k.relname),
                    '{}'::text[])
      into v_orphans
      from pgpm.part p
      join pg_class k on k.relname = p.child_name and k.relkind in ('r', 'p')
      join pg_namespace n on n.oid = k.relnamespace
     where p.parent_table = r.parent_table;

    select count(*)::int into v_parts from pgpm.part where parent_table = r.parent_table;

    delete from pgpm.transmute_inflight where parent_table = r.parent_table;
    delete from pgpm.archive_ledger     where parent_table = r.parent_table;
    delete from pgpm.dropped_fk         where parent_table = r.parent_table;
    delete from pgpm.part               where parent_table = r.parent_table;
    delete from pgpm.regrain_lock       where parent_table = r.parent_table;   -- #554
    delete from pgpm.config             where parent_table = r.parent_table;

    insert into pgpm.log (parent_table, action, rows, method)
      values (r.parent_table, 'forget_missing', v_parts,
              case when coalesce(array_length(v_orphans, 1), 0) = 0
                   then 'relation was gone; pgpm state cleared'
                   else format('relation was gone; pgpm state cleared. LEFT IN PLACE (still hold data): %s',
                               array_to_string(v_orphans, ', ')) end);

    parent_oid := r.oid; partitions_forgotten := v_parts; orphan_tables := v_orphans;
    return next;
  end loop;
end;
$$;

-- check_default removed with the DEFAULT partition (#288).

-- check_uuidv7(): sanity-sample a uuid column. Genuine UUIDv7/ULID values decode
-- (via their leading 48-bit ms prefix) to plausible recent timestamps and score
-- ~1.0; random UUIDv4 columns score near 0. A heuristic, not a proof.
--
-- sampled/plausible/fraction/oldest/newest are over the SAMPLE (the first p_sample rows in whatever order
-- the scan returns them). newest_decoded is not: it is the column's actual maximum, found the way
-- transmute finds its frontier (ORDER BY ... DESC LIMIT 1, an index scan when the control column is the
-- key), decoded. That is the value one future-dated row hides behind a passing fraction (#457): 1 bad row
-- in 402 samples at 0.9975, and the sample max only sees it if the row happened to be in the sample.
-- #734: the read skips NULLs in its WHERE clause. DESC sorts NULLs FIRST, so one NULL in the column (it is
-- sampled before converting, when it may still be nullable) was "the maximum", and both columns came back
-- null with a row years ahead in the table. Not max(): there is no max(uuid) before PostgreSQL 18, and
-- `IS NOT NULL` is an index condition, so the backward index scan survives where NULLS LAST would sort.
-- newest_in_future is that maximum more than one hour past now(), the fixed clock-skew tolerance transmute
-- also applies; transmute additionally allows one partition step, which this function does not know.
drop function if exists pgpm.check_uuidv7(regclass, name, int);
create or replace function pgpm.check_uuidv7(p_table regclass, p_control name, p_sample int default 1000)
returns table (sampled bigint, plausible bigint, fraction numeric, oldest timestamptz, newest timestamptz,
               newest_decoded timestamptz, newest_in_future boolean)
language plpgsql as $$
begin
  return query execute format($q$
    with s as (select pgpm._uuid_to_ts(%1$I) as ts from %2$s limit %3$s),
         m as (select pgpm._uuid_to_ts(t.%1$I) as ts from %2$s t where t.%1$I is not null
                order by t.%1$I desc limit 1)
    select count(*)::bigint,
           count(*) filter (where ts between timestamptz '2015-01-01' and now() + interval '1 day')::bigint,
           round(coalesce(count(*) filter (where ts between timestamptz '2015-01-01' and now() + interval '1 day')::numeric
                          / nullif(count(*), 0), 0), 4),
           min(ts), max(ts),
           (select ts from m),
           (select ts > now() + interval '1 hour' from m)
    from s
  $q$, p_control, p_table::text, p_sample);
end;
$$;

-- check_text_time(): sanity-sample a text/varchar column against a DECLARED shape (prefix, width,
-- radix, unit) -- the text_time analogue of check_uuidv7, needed for the same reason: transmute treats
-- a text/varchar control column as text_time on assumption (the shape is supplied by the operator, not
-- detected), so this is what verifies real data actually matches it before anything is partitioned on
-- it. A row that does not even have the right prefix/width/alphabet is counted implausible directly
-- (never passed to _text_time_to_ts, which would raise on it -- one bad row must not abort the sample);
-- a row that IS shaped correctly is further checked for decoding to a plausible recent timestamp,
-- exactly as check_uuidv7 does. Heuristic, not a proof.
--
-- newest_decoded / newest_in_future are check_uuidv7's (#457): the column's ACTUAL maximum (not the
-- sample's), found the way transmute finds its frontier and decoded, and whether it sits more than one hour
-- past now(). A maximum that does not match the declared shape reports null rather than raising, for the
-- same reason a malformed sampled row counts as implausible rather than aborting the sample. NULLs are
-- skipped in the read's WHERE clause, as in check_uuidv7 and for its reason (#734).
drop function if exists pgpm.check_text_time(regclass, name, text, int, int, text, int, text, int, timestamptz);
create or replace function pgpm.check_text_time(
  p_table regclass, p_control name, p_prefix text, p_width int, p_radix int, p_unit text,
  p_sample int default 1000,
  p_alphabet text default null, p_discard_bits int default 0,
  p_epoch timestamptz default '1970-01-01 00:00:00+00'
) returns table (sampled bigint, plausible bigint, fraction numeric,
                 newest_decoded timestamptz, newest_in_future boolean)
language plpgsql as $$
declare v_class text;
begin
  if p_alphabet is not null then
    if length(p_alphabet) <> p_radix then
      raise exception 'pg_partition_magician: alphabet % has length %, which does not match radix %', p_alphabet, length(p_alphabet), p_radix;
    end if;
    v_class := p_alphabet;
  else
    if p_radix < 2 or p_radix > 36 then
      raise exception 'pg_partition_magician: radix % is out of range for the default 0-9a-z alphabet (supported: 2-36; supply p_alphabet for a wider or different one)', p_radix;
    end if;
    v_class := substr('0123456789abcdefghijklmnopqrstuvwxyz', 1, p_radix);
  end if;
  -- #456: the same refusal transmute makes, so an operator who samples first hears it first, instead
  -- of a plausible fraction for a column whose collation would misroute every mixed-case value.
  perform pgpm._check_text_time_collation(p_table, p_control, p_prefix, p_width, p_radix, p_alphabet);
  return query execute format($q$
    with s as (select %1$I::text as v from %2$s limit %3$s),
         shaped as (
           select v from s
            where v is not null
              and left(v, length(%4$L)) = %4$L
              and length(v) >= length(%4$L) + %5$s
              and substr(v, length(%4$L) + 1, %5$s) !~ %6$L
         ),
         decoded as (
           select pgpm._text_time_to_ts(v, %4$L, %5$s, %7$s, %8$L, %9$L, %10$s, %11$L) as ts from shaped
         ),
         m as (select t.%1$I::text as v from %2$s t where t.%1$I is not null order by t.%1$I desc limit 1),
         m_decoded as (
           select case when left(v, length(%4$L)) = %4$L
                        and length(v) >= length(%4$L) + %5$s
                        and substr(v, length(%4$L) + 1, %5$s) !~ %6$L
                       then pgpm._text_time_to_ts(v, %4$L, %5$s, %7$s, %8$L, %9$L, %10$s, %11$L)
                  end as ts
             from m
         )
    select (select count(*) from s where v is not null)::bigint,
           (select count(*) from decoded
             where ts between timestamptz '2015-01-01' and now() + interval '1 day')::bigint,
           round(coalesce(
             (select count(*) from decoded
               where ts between timestamptz '2015-01-01' and now() + interval '1 day')::numeric
               / nullif((select count(*) from s where v is not null), 0), 0), 4),
           (select ts from m_decoded),
           (select ts > now() + interval '1 hour' from m_decoded)
  $q$, p_control, p_table::text, p_sample, p_prefix, p_width, '[^' || v_class || ']', p_radix, p_unit,
      p_alphabet, p_discard_bits, p_epoch);
end;
$$;

-- check_time_monotonic: how co-monotonic is an id column with a timestamp column? Samples p_sample
-- rows at random, orders them by the id, and reports the fraction of adjacent pairs whose time is
-- non-decreasing. ~1.0 means id and time co-increase; backfills and out-of-order arrival drive it
-- down. This is the tier-2 safety check for retaining by time against an id partition
-- key (REDESIGN.md): mapping "older than T" to an id boundary is only sound when id and
-- time co-increase. Heuristic, not a proof -- mirrors check_uuidv7's plausibility sampling.
create or replace function pgpm.check_time_monotonic(
  p_table regclass, p_id name, p_time name, p_sample int default 1000
) returns table (sampled bigint, monotonic bigint, fraction numeric)
language plpgsql as $$
begin
  return query execute format($q$
    with s as (select %2$I::timestamptz as t, %1$I as idv from %3$s order by random() limit %4$s),
         o as (select t, lag(t) over (order by idv) as prev from s)
    select count(*) filter (where prev is not null)::bigint,
           count(*) filter (where prev is not null and t >= prev)::bigint,
           round(coalesce(count(*) filter (where prev is not null and t >= prev)::numeric
                          / nullif(count(*) filter (where prev is not null), 0), 0), 4)
    from o
  $q$, p_id, p_time, p_table::text, p_sample);
end;
$$;

-- status(): the operator's at-a-glance view.
--
-- The drain-wedge columns are gone with the drain (#288): default_rows, closed_rows, default_oldest,
-- last_drained and drain_skips all described a backlog in a DEFAULT partition that no longer exists.
-- inflight_partitions stays, but now counts only REGRAIN copy-children not yet attached.
--
-- fks_suspended / fks_unvalidated surface preserve-managed incoming FK state (issue #95):
-- fks_suspended = incoming FKs currently DROPPED (RI off on the referencing table). That is now a
-- transient, sub-transaction state inside regrain's swap rather than something spanning a drain
-- campaign, so a standing non-zero value means a swap died mid-flight. fks_unvalidated = FKs re-added
-- NOT VALID (enforcing new writes) but blocked from full validation by pre-existing orphans (see
-- incoming_fk_orphans() / validate_incoming_fks()).
-- parent_missing (#296) says the managed relation itself is gone -- dropped without untransmute, so the
-- config row is pointing at an oid with no pg_class entry. status() used to RAISE on such a row and
-- therefore return nothing for any table; now it reports it, since naming the dead table is the most
-- useful thing it can do. pgpm.forget_missing() clears the state.
-- regrain_to (#343) is config.regrain_to, the auto-regrain target. Whether the history is being split at
-- all is the first question when coarse_partitions looks stalled, and this was the one field that had to
-- be read from pgpm.config separately to answer it -- easy to forget next to the more visible counters.
--
-- dropped/recreated (not CREATE OR REPLACE) because the redesign widens the return shape with
-- coarse_partitions + history_unregrained (REDESIGN.md section 14), again for parent_missing (#296), and
-- again for regrain_to (#343).
drop function if exists pgpm.status();
create or replace function pgpm.status()
returns table (
  parent regclass, control_kind text, partition_step text, obtain int, retain text,
  paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
  newest_bound text,
  fks_suspended bigint, fks_unvalidated bigint, history_unregrained boolean, retain_drop_failures bigint,
  retain_backlog bigint, retain_detaching bigint, parent_missing boolean, regrain_to text
)
language plpgsql as $$
declare
  r pgpm.config; v_nsp name; v_np bigint; v_coarse bigint; v_inflight bigint; v_new text;
  v_missing boolean;

  v_fks_susp bigint; v_fks_unval bigint;
  v_last_retain_id bigint; v_drop_fails bigint; v_detaching bigint;
  v_retain_boundary text; v_retain_backlog bigint;
begin
  for r in select * from pgpm.config loop
    select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = r.parent_table;

    -- Has the managed relation been dropped out from under us (#296)? status() is the DIAGNOSTIC, so it
    -- must never be the thing that dies: one config row pointing at a vanished oid used to raise out of
    -- this whole set-returning function, so a single dropped table returned NOTHING for every managed
    -- table, healthy ones included. Everything below except retain_backlog comes from pgpm.part /
    -- pgpm.config / pgpm.log, so a dead parent still gets a full, useful row -- and the flag says which
    -- one it is, which is the single most actionable thing to report here.
    v_missing := not exists (select 1 from pg_class c where c.oid = r.parent_table);

    -- n_partitions = attached (real) partitions; coarse_partitions = the un-regrained coarse children (a
    -- wider-than-one-step range, REDESIGN.md section 14) -- the regraining backlog; inflight = the
    -- not-yet-attached regrain children.
    select count(*) filter (where attached),
           count(*) filter (where attached
                            and pgpm._native_gt(r.control_kind, hi, pgpm._grid_next(r.control_kind, r.partition_step, lo, r.partition_tz))),
           count(*) filter (where not attached)
      into v_np, v_coarse, v_inflight from pgpm.part where parent_table = r.parent_table;
    execute format('select %s from pgpm.part where parent_table = %L::regclass and attached',
                   pgpm._max_hi_native(r.control_kind), r.parent_table::text) into v_new;
    -- preserve-managed incoming FK state: dropped (RI off) vs re-added-but-not-validated (orphan-blocked)
    select count(*) filter (where restored_at is null),
           count(*) filter (where restored_at is not null and validated_at is null)
      into v_fks_susp, v_fks_unval
      from pgpm.dropped_fk where parent_table = r.parent_table;
    -- retain_drop_failures: unexpected DROP failures (issue #238; previously pre_drop hook
    -- failures, before pgpm.hook stopped being consulted here) logged AFTER the last successful
    -- drop (a since-last-progress count). Archive coverage not yet complete
    -- is NOT a failure and is never logged here -- it is the normal, expected reason retain_backlog
    -- stays non-zero while chunked archiving catches up (see retain_backlog below).
    select max(id) into v_last_retain_id from pgpm.log
      where parent_table = r.parent_table and action = 'retain_drop';
    -- Exact action values, never a prefix match: `fail_retain_crossing` (issue #268, a live row
    -- references a doomed one and the FK's own ON DELETE refused the delete), `fail_retain_detach`
    -- (no pgpm_detach cron job to dispatch to) and `fail_retain_identity` (issue #407, the child's
    -- name no longer resolves to the object whose detach was dispatched) wedge retention exactly as a
    -- failed drop does, so they belong in the same since-last-progress count.
    -- `fail_archive_identity` (issue #421) is here for the same reason one step earlier in the
    -- lifecycle: the archive step refused a candidate whose name no longer resolves to the relation
    -- pgpm.part recorded, so no chunk is ever written for it, _archive_fully_covered never goes true,
    -- and retire()'s drop precondition never opens. Retention is stalled just as hard as by a failed
    -- drop, and like fail_retain_identity it never clears itself.
    -- `fail_write_block_identity` (issue #429) is the same mismatch one step earlier again, and it
    -- stalls the same chain from the top: a partition that never gets its write block is never an
    -- archive candidate, so it is never covered, so it is never dropped.
    -- `fail_archive_contract` (issue #454) is the archive step refusing a strategy's return that
    -- broke the contract (covered_hi null, not above the chunk's lo, past its hi, or not a native
    -- value), so no ledger row is written and coverage does not advance. Retention is stalled the
    -- same way, on every tick until the strategy is corrected, which is the one thing that separates
    -- it from the identity refusals: it clears itself once a correct strategy is handed the same chunk.
    -- `fail_retain_reattach` (issue #724) is a retirement retention no longer reaches whose detach had
    -- already landed and could not be put back: the partition's rows are out of the parent until it is,
    -- which is louder than any stall, so it is counted with them.
    select count(*) into v_drop_fails from pgpm.log
      where parent_table = r.parent_table
        and action in ('fail_retain_drop', 'fail_retain_crossing', 'fail_retain_detach',
                       'fail_retain_identity', 'fail_archive_identity', 'fail_write_block_identity',
                       'fail_archive_contract', 'fail_retain_reattach')
        and id > coalesce(v_last_retain_id, 0);
    -- Partitions whose concurrent detach has been dispatched and not yet completed (issue #268).
    -- Non-zero is normal for a tick or two while cron performs the detach; persistently non-zero with
    -- retain_drop_failures climbing means the dispatch has nowhere to go.
    select count(*) into v_detaching from pgpm.part
      where parent_table = r.parent_table and retiring_at is not null;
    -- retain_backlog: eligible-but-undropped partitions (whole range at/below the retention horizon,
    -- issue #189). Non-zero is normal while retain_batch paces a backlog across ticks, or while
    -- chunked archiving is still catching up on a write-blocked child -- it should fall tick over
    -- tick; flat with retain_drop_failures climbing = wedged on an unexpected drop failure.
    -- null, not 0, for a dead parent: the horizon is derived from the frontier, and the frontier is
    -- max(control) READ FROM THE RELATION. With the relation gone there is no honest answer, and 0 would
    -- read as "nothing is eligible" -- a claim status() cannot make. This is also the one branch that
    -- would raise, via _retain_boundary -> _frontier_native, so skipping it is what keeps status() alive.
    v_retain_backlog := case when v_missing then null else 0 end;
    -- #451: _retain_boundary refuses a hand-edited negative retain (see there). status() is what an
    -- operator reads to find that out, so it stays alive and reports the backlog as null for that table,
    -- the same no-honest-answer null as the dead-parent case; pgpm.log carries the reason.
    begin
      v_retain_boundary := case when v_missing then null else pgpm._retain_boundary(r) end;
    exception when others then
      v_retain_boundary := null; v_retain_backlog := null;
    end;
    if v_retain_boundary is not null then
      execute format(
        'select count(*) from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s',
        r.parent_table::text, pgpm._native_type(r.control_kind), v_retain_boundary, pgpm._native_type(r.control_kind))
        into v_retain_backlog;
    end if;
    parent := r.parent_table; control_kind := r.control_kind; partition_step := r.partition_step;
    obtain := r.obtain; retain := r.retain; paused := r.paused; n_partitions := v_np;
    coarse_partitions := v_coarse; inflight_partitions := v_inflight; history_unregrained := v_coarse > 0;
    newest_bound := v_new;
    fks_suspended := v_fks_susp; fks_unvalidated := v_fks_unval; retain_drop_failures := v_drop_fails;
    retain_backlog := v_retain_backlog; retain_detaching := v_detaching;
    parent_missing := v_missing; regrain_to := r.regrain_to;
    return next;
  end loop;
end;
$$;
-- snapshot() removed with the drain (#288). It existed to paper over the drain's VISIBILITY GAP: during a
-- multi-batch drain the already-moved rows lived in an unattached child, so a plain read of the parent
-- undercounted the interval being drained, and snapshot() UNIONed those children back in. regrain never
-- opened that gap (it copies and swaps atomically) and there is no drain, so a read of the parent is
-- never short and there is nothing to union.

-- progress(): the drill-down status() is not (issue #343). status() is one row per table at a glance; this
-- answers the two questions an operator watching ONE table through transmute -> freeze -> regrain actually
-- asks, which until now meant triangulating pgpm.part, pgpm.config, pgpm.log and grid arithmetic by hand.
--
--   "When will the monolith freeze?" A coarse child can only be regrained once the frontier has left it,
--   and its upper bound is the product of the anchor, the step and any p_bound_headroom -- derivable from
--   this file, and derived wrong in production once (a two-hour anchor mixup, noticed only against
--   pgpm.part). write_child is the attached child the frontier sits in, write_ceiling its hi, and
--   freeze_margin the distance left. freeze_in is that margin as an interval, populated ONLY for the
--   time-grid kinds: their frontier is a timestamptz (now(), or greatest(max(control), now())), so the
--   arithmetic is exact. An `id` frontier is max(control), pgpm keeps no history of it, and a rate to
--   divide by would be a guess dressed as a measurement -- so freeze_in is null for `id` and the count in
--   freeze_margin is what there honestly is. coarse_frozen counts the coarse children already past the
--   frontier and eligible, so "regrain_to is null and nothing will ever happen" reads as coarse_frozen > 0
--   beside a null regrain_to.
--
--   "How far along is the regrain, and when does it finish?" pgpm already keeps the answer, in
--   config.regrain_cursor: the native lo of the sub-range being copied, which only ever advances (see the
--   design note above _regrain_capture_names). (cursor - lo) / (hi - lo) is therefore an exact, monotonic
--   fraction of the RANGE, costing no scan and no new bookkeeping, and the regrain_prepare log row dates
--   the start. regrain_eta is elapsed * (1 - pct) / pct: extrapolated from observed progress rather than
--   computed from rows / batch / cadence, so it needs no per-tick timing on the hot path and never
--   confuses a whole maintenance tick with the copy inside it.
--
-- Three numbers here would be lies if fused, so they are kept apart. regrain_pct_range is a fraction of
-- the RANGE, not of the rows: rows are not uniform across a range, the cursor sits still until a whole
-- sub-range completes (so it lags while rows pile up), and an aged sub-range is advanced over WITHOUT
-- being copied (so it leads). regrain_rows_copied is exact, summed from this run's regrain_copy rows, and
-- regrain_rows_total_est is reltuples, named for what it is. There is no "N of M rows" column, because
-- one cannot be produced honestly without a full scan. And regrain_eta is null until pct_range > 0: at
-- prepare, and through every tick of the first sub-range, there is nothing to extrapolate from, and a
-- fabricated tick-one figure is exactly the kind of number this function exists to replace.
--
-- Survives a parent dropped without untransmute the way status() learned to (#296): the row is reported
-- with parent_missing = true and every frontier-derived column null, rather than one dead table taking
-- the diagnostic down for every healthy one.
drop function if exists pgpm.progress(regclass);
create or replace function pgpm.progress(p_parent regclass default null)
returns table (
  parent regclass, control_kind text, parent_missing boolean,
  frontier text, write_child name, write_ceiling text, freeze_margin text, freeze_in interval,
  coarse_frozen bigint,
  regrain_to text, regrain_child name, regrain_cursor text, regrain_pct_range numeric,
  regrain_rows_copied bigint, regrain_rows_total_est bigint, regrain_delta_pending bigint,
  regrain_started_at timestamptz, regrain_elapsed interval, regrain_eta interval
)
language plpgsql as $$
declare
  r pgpm.config; v_nsp name; v_missing boolean; v_frontier text; v_floor text;
  v_wc_name name; v_wc_hi text;
  v_rc_name name; v_rc_lo text; v_rc_hi text; v_rc_oid oid; v_reltuples real;
  v_prep_id bigint; v_prep_at timestamptz;
begin
  -- an explicit argument that names an unmanaged table is refused, not answered with zero rows: a typo'd
  -- name silently returning nothing is the wrong shape for the tool you reach for at 2am
  if p_parent is not null and not exists (select 1 from pgpm.config c where c.parent_table = p_parent) then
    raise exception 'pg_partition_magician: % is not managed', p_parent;
  end if;
  for r in select * from pgpm.config c where p_parent is null or c.parent_table = p_parent loop
    -- every output is assigned on every iteration: RETURN NEXT reads the variables as they stand, and a
    -- value left over from the previous row would be reported as this one's
    parent := r.parent_table; control_kind := r.control_kind;
    frontier := null; write_child := null; write_ceiling := null; freeze_margin := null; freeze_in := null;
    coarse_frozen := null;
    regrain_to := r.regrain_to; regrain_child := null; regrain_cursor := r.regrain_cursor;
    regrain_pct_range := null; regrain_rows_copied := null; regrain_rows_total_est := null;
    regrain_delta_pending := null; regrain_started_at := null; regrain_elapsed := null; regrain_eta := null;

    v_missing := not exists (select 1 from pg_class c where c.oid = r.parent_table);
    parent_missing := v_missing;
    if not v_missing then
      select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where c.oid = r.parent_table;
      -- _frontier_native reads the relation for every kind but `time`, and raises for a dead one, which
      -- is why the missing check gates everything from here down
      v_frontier := pgpm._frontier_native(r.parent_table);
      frontier   := v_frontier;

      -- the child taking writes: the attached one with lo <= frontier < hi. At most one, by the
      -- non-overlap invariant over attached rows; none if the grid has fallen behind the frontier.
      select p.child_name, p.hi into v_wc_name, v_wc_hi from pgpm.part p
       where p.parent_table = r.parent_table and p.attached
         and not pgpm._native_gt(r.control_kind, p.lo, v_frontier)
         and pgpm._native_gt(r.control_kind, p.hi, v_frontier)
       limit 1;
      write_child := v_wc_name; write_ceiling := v_wc_hi;
      if v_wc_hi is not null then
        if r.control_kind = 'id' then
          freeze_margin := (v_wc_hi::numeric - v_frontier::numeric)::text;   -- a count; freeze_in stays null
        else
          freeze_in     := v_wc_hi::timestamptz - v_frontier::timestamptz;
          freeze_margin := freeze_in::text;
        end if;
      end if;

      -- coarse children already frozen: whole range at/below the current grid floor, and (with auto-regrain
      -- on) ones its target subdivides, which together is exactly maintain()'s auto-regrain candidate test
      -- (#515). With regrain_to null the second clause repeats the first, so every frozen coarse child
      -- counts, as before. A frozen coarse child a set regrain_to cannot split is not counted here, because
      -- it is not going to be worked; it stays in status().coarse_partitions, which counts by the grid's
      -- step alone.
      v_floor := pgpm._grid_floor(r.control_kind, r.partition_step, r.partition_anchor, v_frontier, r.partition_tz);
      select count(*) into coarse_frozen from pgpm.part p
       where p.parent_table = r.parent_table and p.attached
         and pgpm._native_gt(r.control_kind, p.hi, pgpm._grid_next(r.control_kind, r.partition_step, p.lo, r.partition_tz))
         and pgpm._native_gt(r.control_kind, p.hi, pgpm._grid_next(r.control_kind, coalesce(r.regrain_to, r.partition_step), p.lo, r.partition_tz))
         and not pgpm._native_gt(r.control_kind, p.hi, v_floor);

      regrain_delta_pending := pgpm._regrain_delta_count(r.parent_table);
    end if;

    -- In flight? The cursor says so, and the child carrying the change-capture trigger says WHICH (exactly
    -- one per parent, #267). Range-matching the cursor alone would not: at a sub-range boundary the cursor
    -- equals one child's hi and the next one's lo, and a regrain freshly prepared on the second sits at
    -- exactly that value.
    if r.regrain_cursor is not null and not v_missing then
      select p.child_name, p.lo, p.hi, p.child_oid into v_rc_name, v_rc_lo, v_rc_hi, v_rc_oid from pgpm.part p
       where p.parent_table = r.parent_table and p.attached
         and not pgpm._native_gt(r.control_kind, p.lo, r.regrain_cursor)   -- lo <= cursor
         and not pgpm._native_gt(r.control_kind, r.regrain_cursor, p.hi)   -- cursor <= hi
         and pgpm._regrain_capture_active(r.parent_table, p.child_name)
       limit 1;
      if v_rc_name is not null then
        regrain_child     := v_rc_name;
        regrain_pct_range := pgpm._native_frac(r.control_kind, v_rc_lo, v_rc_hi, r.regrain_cursor);
        -- reltuples, by the oid pgpm.part recorded for the child (#421), falling back to the name for a
        -- row that predates child_oid. An estimate, and a never-analyzed relation carries -1: null then.
        select c.reltuples into v_reltuples from pg_class c
         where c.oid = coalesce(v_rc_oid, to_regclass(format('%I.%I', v_nsp, v_rc_name))::oid);
        if v_reltuples >= 0 then regrain_rows_total_est := v_reltuples::bigint; end if;
        -- this run began at its regrain_prepare row (a restart re-prepares, so the latest is always the
        -- current run's), and the rows copied since it are this run's and no earlier one's
        select l.id, l.at into v_prep_id, v_prep_at from pgpm.log l
         where l.parent_table = r.parent_table and l.action = 'regrain_prepare'
         order by l.id desc limit 1;
        if v_prep_id is not null then
          regrain_started_at := v_prep_at;
          regrain_elapsed    := now() - v_prep_at;
          select coalesce(sum(l.rows), 0) into regrain_rows_copied from pgpm.log l
           where l.parent_table = r.parent_table and l.action = 'regrain_copy' and l.id > v_prep_id;
          if regrain_pct_range > 0 then
            -- the ratio first, in numeric, then ONE interval multiplication: two roundings would make the
            -- figure disagree with the same arithmetic done by hand from the columns beside it
            regrain_eta := regrain_elapsed * ((1 - regrain_pct_range) / regrain_pct_range);
          end if;
        end if;
      end if;
    end if;
    return next;
  end loop;
end;
$$;


-- ===================== observability: pg_flight_recorder correlation =====================
--
-- pgpm.log records exactly when pgpm ran each operation, but pgpm keeps no history of what the
-- rest of the database was doing during it. The optional pg_flight_recorder (PGFR) extension
-- samples that history continuously (wait events, locks, checkpoints, WAL, I/O, query latency) but
-- does not know which spikes were pgpm's. The two functions below bridge the two over a
-- pgpm.log time window. The integration is strictly READ-ONLY and ONE-DIRECTIONAL (pgpm writes
-- nothing into PGFR, and PGFR needs no changes), and PGFR is NEVER a dependency: observe_window
-- works standalone from pure pgpm.log, and the PGFR-delegating function (impact_report) raises a
-- clear, catchable error when PGFR is absent rather than failing on a raw
-- "function pgfr_analyze.* does not exist".

-- _observe_has_pgfr: is pg_flight_recorder's analysis layer present? Gates on the pgfr_analyze
-- SCHEMA, not pg_extension: PGFR's script install (the common path) creates the schema and its
-- objects without CREATE EXTENSION; only the dbdev/TLE channel registers an extension. The schema
-- is present either way.
create or replace function pgpm._observe_has_pgfr()
returns boolean language sql stable as $$
  select exists (select 1 from pg_namespace where nspname = 'pgfr_analyze');
$$;

-- observe_window: the span pgpm was active on p_parent within the last p_since, plus a summary of what it
-- did. PURE pgpm.log -- no PGFR dependency, so it is useful and testable on its own. Always returns exactly
-- one row; when there is no activity, the window bounds are null and the counts are 0.
--
-- Narrowed in #304: it used to report `drains`, `adaptive_ticks` and a per-signal `backoffs` breakdown,
-- all counted from `drain_move` / `drain_budget` log actions. Neither action has been written since the
-- drain and its adaptive feathering were removed (#288), so those columns could only ever read 0 -- a
-- reported zero that means "this never happens" is worse than no column at all, because it looks like
-- a measurement.
drop function if exists pgpm.observe_window(regclass, interval);
create or replace function pgpm.observe_window(
  p_parent regclass, p_since interval default '7 days'
) returns table (
  parent_table   regclass,
  window_start   timestamptz,
  window_end     timestamptz,
  duration       interval,
  log_rows       bigint,
  rows_copied    bigint,
  regrains       bigint,
  retains        bigint
) language sql stable as $$
  select
    p_parent,
    min(l.at),
    max(l.at),
    max(l.at) - min(l.at),
    count(*),
    coalesce(sum(l.rows) filter (where l.action = 'regrain_copy'), 0),
    count(*) filter (where l.action = 'regrain'),
    count(*) filter (where l.action = 'retain_drop')
  from pgpm.log l
  where l.parent_table = p_parent
    and l.at >= now() - p_since;
$$;

-- impact_report: "what did my conversion do to the workload?" Derives the active window from
-- pgpm.log (observe_window) and asks pgfr_analyze what the database was doing during it. Sections
-- degrade independently: a section whose PGFR call has too little data (e.g. fewer than two
-- snapshots, or pg_stat_statements reset) reports that rather than failing the whole report.
create or replace function pgpm.impact_report(
  p_parent regclass, p_since interval default '7 days'
) returns text language plpgsql stable as $$
declare
  w        record;
  cmp      record;
  ln       text[] := '{}';
  sect     text;
begin
  if not pgpm._observe_has_pgfr() then
    raise exception 'pg_partition_magician: impact_report requires pg_flight_recorder (the pgfr_analyze extension). Install it to correlate pgpm operations against database telemetry, or use pgpm.observe_window() for the pgpm-only summary.';
  end if;

  select * into w from pgpm.observe_window(p_parent, p_since);
  if w.window_start is null then
    return format('pg_partition_magician impact report: no pgpm activity for %s in the last %s.', p_parent, p_since);
  end if;

  ln := ln || format('pg_partition_magician :: impact report for %s', p_parent);
  ln := ln || format('  window:   %s  ->  %s  (%s)', w.window_start, w.window_end, w.duration);
  ln := ln || format('  pgpm did: %s log rows, %s rows copied; %s regrains, %s retains',
                     w.log_rows, w.rows_copied, w.regrains, w.retains);
  ln := ln || ''::text;

  -- Checkpoints / WAL / temp / I/O over the window (pgfr_analyze.compare brackets
  -- the window with the nearest snapshots and returns the deltas).
  begin
    select * into cmp from pgfr_analyze.compare(w.window_start, w.window_end);
    if not found then   -- FOUND, not "cmp is null": a record with any null field is neither IS NULL nor IS NOT NULL
      ln := ln || '  database impact: insufficient snapshots in the window (need at least two).'::text;
    else
      ln := ln || format('  forced checkpoints: %s (timed: %s)', cmp.ckpt_requested_delta, cmp.ckpt_timed_delta);
      ln := ln || format('  WAL generated:      %s', cmp.wal_bytes_pretty);
      ln := ln || format('  temp spilled:       %s', cmp.temp_bytes_pretty);
      ln := ln || format('  client read time:   %s ms', round(coalesce(cmp.io_client_read_time_ms, 0), 1));
    end if;
  exception when others then
    ln := ln || format('  database impact: unavailable (%s)', left(sqlerrm, 120));
  end;
  ln := ln || ''::text;

  -- Top wait events in the window.
  begin
    sect := '';
    for cmp in
      select wait_event_type, wait_event, total_waiters, pct_of_samples
        from pgfr_analyze.wait_summary(w.window_start, w.window_end)
       where wait_event is not null
       order by total_waiters desc nulls last
       limit 5
    loop
      sect := sect || format('    %-28s waiters=%s  (%s%% of samples)' || chr(10),
                             cmp.wait_event_type || '/' || cmp.wait_event, cmp.total_waiters, round(cmp.pct_of_samples, 1));
    end loop;
    ln := ln || 'top wait events:'::text;
    ln := ln || coalesce(nullif(rtrim(sect, chr(10)), ''), '    (none sampled)');
  exception when others then
    ln := ln || format('top wait events: unavailable (%s)', left(sqlerrm, 120));
  end;
  ln := ln || ''::text;

  -- Top queries by execution-time delta in the window.
  begin
    sect := '';
    for cmp in
      select queryid, calls_delta, round(total_exec_time_delta_ms::numeric, 1) as exec_ms
        from pgfr_analyze.statement_activity_v2(w.window_start, w.window_end, 5)
       order by total_exec_time_delta_ms desc nulls last
    loop
      sect := sect || format('    queryid=%-22s calls=%s  exec=%s ms' || chr(10), cmp.queryid, cmp.calls_delta, cmp.exec_ms);
    end loop;
    ln := ln || 'top queries by exec-time:'::text;
    ln := ln || coalesce(nullif(rtrim(sect, chr(10)), ''), '    (none; pg_stat_statements may be absent)');
  exception when others then
    ln := ln || format('top queries by exec-time: unavailable (%s)', left(sqlerrm, 120));
  end;

  return array_to_string(ln, chr(10));
end $$;


-- restore_incoming_fks(): re-add the incoming FKs that transmute(..., p_incoming_fks => 'preserve')
-- recorded, pointing them back at the new partitioned parent, but only once it is SAFE. Safe = no
-- in-flight, not-yet-attached child partition exists. (The drained-closed-tail gate this used to carry
-- went with the DEFAULT in #288: there is no tail to drain.) A referenced row inside such a child is
-- outside the visible parent, which a live NO ACTION FK would reject and a CASCADE/SET NULL one would
-- silently honour, so the FK must stay dropped until the child is attached.
-- The re-add is split (issue #95): `ADD CONSTRAINT ... NOT VALID` (enforces every new write, always
-- succeeds) committed separately from `VALIDATE` (scans existing rows, may fail on an orphan written
-- during the suspend window). A failed VALIDATE leaves the FK NOT VALID -- enforcing new writes,
-- surfaced via status().fks_unvalidated -- rather than rolling the re-add back into a permanent silent
-- brick. Returns the number re-added; 0 (a no-op) while a regrain copy-child is still unattached, so
-- `maintain` can call it every tick and it acts only when the table is ready.
-- p_ids (#378): restricts the re-add to specific pgpm.dropped_fk rows, instead of every
-- not-yet-restored row for the parent. Used by regrain_step's swap, which snapshots exactly which
-- rows it is about to suspend and passes that exact set here, so a pre-existing "stale" unrestored
-- FK (one this swap never touched via suspend_incoming_fks) is left for the next tick's own,
-- unscoped call instead of being swept up under the swap's own lock. null (the default) preserves
-- today's "restore everything unrestored for this parent" behavior for every other caller.
-- (regclass) shipped in 0.2.0 through 0.4.0; kept beside this shape, maintain's every-tick call is ambiguous (#441)
drop function if exists pgpm.restore_incoming_fks(regclass);
create or replace function pgpm.restore_incoming_fks(p_parent regclass, p_ids bigint[] default null)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_closed bigint; v_inflight name;
  r pgpm.dropped_fk%rowtype; v_n int := 0; v_is_part boolean; v_readded boolean;
begin
  perform pgpm._forget_dangling_fks(p_parent);   -- #658: a key whose table is gone is not re-added, ever
  if not exists (select 1 from pgpm.dropped_fk
                  where parent_table = p_parent and restored_at is null
                    and (p_ids is null or id = any(p_ids))) then
    return 0;
  end if;
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- gate 1 (the drained-closed-tail gate) is gone with the DEFAULT (#288): there is no tail to drain.
  -- gate 2: no in-flight (un-attached) child mid-regrain, recognised by _is_fine_child_label, the helper
  -- transmute's orphan guard asks too, so the two cannot drift (#726). A regrain copy-child is
  -- EXCLUDED (its range is contained in an attached partition): regrain copies without
  -- deleting, so the referenced rows never leave the visible parent, and a copy-regrain never needs the FK
  -- suspended -- so it must not hold the FK off either (that would reopen the RI window the copy design
  -- closes). Only an un-attached child in no attached partition's range (an orphan) blocks the re-add.
  select c.relname into v_inflight
    from pg_class c
   where c.relnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)
     and c.relkind = 'r'
     and starts_with(c.relname, v_rel || '_p')
     and pgpm._is_fine_child_label(cfg.control_kind, substr(c.relname, length(v_rel) + 3))
     and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
     and not exists (                                            -- a regrain copy is not an absent-row child
           select 1 from pgpm.part cp
            join pgpm.part ap on ap.parent_table = cp.parent_table and ap.attached
           where cp.parent_table = p_parent and cp.child_name = c.relname
             and not pgpm._native_gt(cfg.control_kind, ap.lo, cp.lo)   -- ap.lo <= cp.lo
             and not pgpm._native_gt(cfg.control_kind, cp.hi, ap.hi))  -- cp.hi <= ap.hi
   limit 1;
  if v_inflight is not null then return 0; end if;

  -- Re-add each dropped FK, then attempt to VALIDATE it once -- in SEPARATE subtransactions, so a
  -- VALIDATE that fails on a pre-existing orphan does NOT roll back the re-add (issue #95). A re-added
  -- NOT VALID FK already enforces RI for every NEW write; only pre-existing rows go unverified. So the
  -- FK comes back at the first opportunity and can never be permanently bricked by an orphan
  -- written during the suspend window; the orphans (if any) are surfaced by status().fks_unvalidated /
  -- pgpm.incoming_fk_orphans() and cleared with pgpm.validate_incoming_fks() once the operator removes
  -- them. The recorded definition names the parent (captured before the rename) schema-qualified (#498),
  -- so it resolves to the same relation from this session as from the one that captured it, and
  -- r.referencing_table names the TABLE holding the key: the new parent for a self-referential key, and
  -- for a referencing table converted since, its parent (transmute's 0d moves the record with the rename).
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is null
              and (p_ids is null or id = any(p_ids))
            order by id loop
    v_is_part := (select relkind from pg_class where oid = r.referencing_table) = 'p';
    v_readded := false;
    begin
      if v_is_part then
        -- self-referential / partitioned referencer: Postgres forbids NOT VALID FKs here, so add it
        -- validating in one step (all-or-nothing). A pre-existing orphan leaves it DROPPED and logged,
        -- without bricking the other FKs; self-ref / partitioned-referencer FKs are typically small.
        execute format('alter table %s add constraint %I %s',
                       r.referencing_table::text, r.constraint_name, r.definition);
        update pgpm.dropped_fk set restored_at = now(), validated_at = now() where id = r.id;
      else
        execute format('alter table %s add constraint %I %s not valid',
                       r.referencing_table::text, r.constraint_name, r.definition);
        update pgpm.dropped_fk set restored_at = now(), validated_at = null where id = r.id;
      end if;
      v_readded := true;
      v_n := v_n + 1;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'restore_incoming_fk', r.constraint_name);
    exception when others then
      insert into pgpm.log (parent_table, action, method)
        values (p_parent, 'fail_restore_incoming_fk', left(r.constraint_name || ': ' || sqlerrm, 200));
    end;
    -- The VALIDATE deliberately does NOT happen here (#265). It used to, in its own subtransaction, which
    -- isolated its errors but not its locks: the ADD above takes SHARE ROW EXCLUSIVE on BOTH the
    -- referencing table and the MANAGED PARENT, and a subtransaction releases nothing, so that lock was
    -- held across an O(referencing table) scan. SHARE ROW EXCLUSIVE conflicts with ROW EXCLUSIVE, so
    -- writes to the parent -- the table pgpm exists to keep online -- blocked for the whole scan.
    -- Measured at 224 ms against 4M referencing rows, and linear.
    --
    -- Splitting them by COMMITting here is not available: this function is also called by regrain_step
    -- mid-swap, and regrain_step is a FUNCTION whose driver regrain() loops it in ONE transaction,
    -- atomic and gap-free. Converting this to a committing procedure would cascade into breaking that.
    --
    -- So the FK is left NOT VALID, which already enforces every NEW write, and maintain() validates it on
    -- a later tick in its own transaction -- where the VALIDATE holds only SHARE UPDATE EXCLUSIVE on the
    -- referencing table and ROW SHARE on the parent, neither of which blocks writes.
  end loop;
  return v_n;
end;
$$;

-- validate_incoming_fks(): finish validating any preserve-managed FK that was re-added NOT VALID but
-- not yet validated (its pre-existing orphans blocked it). Run after clearing the orphans
-- (pgpm.incoming_fk_orphans() lists the counts). Each VALIDATE is isolated, so one still-blocked FK
-- does not stop the others; returns the number newly validated.
--
-- maintain() calls this on a later tick with p_respect_backoff => true, which is what completes the
-- validation without operator action now that restore_incoming_fks deliberately stops at NOT VALID
-- (#265). The back-off is what makes that safe: a FAILING validate re-scans the referencing table to
-- discover it still cannot succeed, so a failure parks it for five minutes instead of burning that scan
-- every tick. A successful one sets validated_at and is never revisited.
--
-- Called directly by an operator it ignores the back-off, since the point of running it by hand is that
-- the orphans have just been cleared and the answer should be immediate.
create or replace function pgpm.validate_incoming_fks(
  p_parent regclass, p_respect_backoff boolean default false
)
returns int language plpgsql as $$
declare r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  perform pgpm._forget_dangling_fks(p_parent);   -- #658: nor validated
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null and validated_at is null
              and (not p_respect_backoff
                   or coalesce(validate_retry_after, '-infinity'::timestamptz) <= clock_timestamp())
            order by id loop
    begin
      execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
      update pgpm.dropped_fk set validated_at = now(), validate_retry_after = null where id = r.id;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'validate_incoming_fk', r.constraint_name);
      v_n := v_n + 1;
    exception when others then
      -- A failed VALIDATE re-scanned the referencing table to get here. Wait before doing that again
      -- (#265); the orphans blocking it are cleared by hand, so a tight retry only burns I/O.
      update pgpm.dropped_fk set validate_retry_after = clock_timestamp() + interval '5 minutes'
        where id = r.id;
      insert into pgpm.log (parent_table, action, method)
        values (p_parent, 'fail_validate_incoming_fk', left(r.constraint_name || ': ' || sqlerrm, 200));
    end;
  end loop;
  return v_n;
end;
$$;

-- incoming_fk_orphans(): for each preserve-managed FK that is re-added but not yet validated, count the
-- orphan rows blocking validation -- referencing rows whose (non-null) FK columns match no parent key.
-- The operator uses this to find and clear what blocks validate_incoming_fks(). Reads the column
-- mapping from the live (NOT VALID) constraint in pg_constraint; handles composite FKs.
create or replace function pgpm.incoming_fk_orphans(p_parent regclass)
returns table (referencing_table regclass, constraint_name name, orphan_rows bigint)
language plpgsql as $$
declare r pgpm.dropped_fk%rowtype; c pg_constraint%rowtype; v_join_q text; v_notnull_q text; v_cnt bigint;
begin
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null and validated_at is null order by id loop
    select * into c from pg_constraint
      where conrelid = r.referencing_table and conname = r.constraint_name and contype = 'f';
    if not found then continue; end if;
    select string_agg(format('r.%I = p.%I', fa.attname, pa.attname), ' and '),
           string_agg(format('r.%I is not null', fa.attname), ' and ')
      into v_join_q, v_notnull_q
      from unnest(c.conkey, c.confkey) with ordinality as u(fk_att, pk_att, ord)
      join pg_attribute fa on fa.attrelid = c.conrelid and fa.attnum = u.fk_att
      join pg_attribute pa on pa.attrelid = c.confrelid and pa.attnum = u.pk_att;
    execute format('select count(*)::bigint from %s r where %s and not exists (select 1 from %s p where %s)',
                   c.conrelid::regclass::text, v_notnull_q, c.confrelid::regclass::text, v_join_q) into v_cnt;
    referencing_table := r.referencing_table; constraint_name := r.constraint_name; orphan_rows := v_cnt;
    return next;
  end loop;
end;
$$;

-- KEPT, with a much narrower remit after #288. It used to be called by maintain before every drain,
-- dropping the FK for the whole span of a multi-tick drain campaign -- an RI window other sessions could
-- observe, and pgpm's only one. That caller is gone with the drain. The remaining caller is regrain's
-- SWAP, which suspends and restores INSIDE its own transaction, so no session ever observes RI off.
-- suspend_incoming_fks(): the inverse of restore. Re-drop any preserve-managed FK that is currently live,
-- so a referenced row is never taken out of the visible parent past a live FK. That matters beyond a mere
-- stall: a live ON DELETE CASCADE / SET NULL FK would silently delete or null the referencing rows as
-- their referent leaves the parent (verified on PG 17), which is why regrain's swap drops and re-adds
-- inside one transaction rather than relying on the DETACH being brief.
-- p_force is what regrain's swap passes, since a copy-regrain has no pending work of its own to detect.
create or replace function pgpm.suspend_incoming_fks(p_parent regclass, p_force boolean default false)
returns int language plpgsql as $$
declare v_closed bigint; r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  perform pgpm._forget_dangling_fks(p_parent);   -- #658: nor dropped, which is what wedged regrain's swap
  if not exists (select 1 from pgpm.dropped_fk
                  where parent_table = p_parent and restored_at is not null) then
    return 0;
  end if;
  -- The drain-work gate is gone with the DEFAULT (#288). regrain's swap is the only caller left and it
  -- always passes p_force, so a call with p_force false has no work to justify it and does nothing.
  if not p_force then return 0; end if;
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null order by id loop
    execute format('alter table %s drop constraint %I', r.referencing_table::text, r.constraint_name);
    update pgpm.dropped_fk set restored_at = null, validated_at = null where id = r.id;
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'suspend_incoming_fk', r.constraint_name);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace view pgpm.partitions as
  select parent_table, child_name, lo, hi, created_at, attached from pgpm.part order by parent_table, lo;

-- =============================================================================
-- Identity: what is installed here, and when it got here.
--
-- version() is the version of the CODE in this database, baked in at release time. It is the same
-- string as extension.control's default_version and the git tag; test.sh checks that pairing at the
-- file level, which nothing inside the database can do. Every support conversation starts with this
-- question, and the install.sql channel never reads extension.control, so without this a database
-- installed from install.sql carries no version at all.
--
-- pgpm.installed is the history of install.sql runs, not a single current-version row. Re-running
-- install.sql IS the upgrade path for this channel (hence the `add column if not exists` lines
-- throughout), so each run appends and the table doubles as an upgrade log. One honest limitation: an
-- install predating this table records its first row as the version it was upgraded TO, because the
-- history can only start where the table does.
-- =============================================================================
create or replace function pgpm.version()
returns text language sql immutable as $$ select '0.6.0'::text $$;

create table if not exists pgpm.installed (
  id         bigint      generated always as identity primary key,
  version    text        not null,
  -- The full server_version string, packaging suffix included ('17.10 (Debian 17.10-1.pgdg13+1)'),
  -- because for support the exact build matters as much as the major.
  pg_version text        not null,
  at         timestamptz not null default now()
);

-- THE LAST STATEMENT IN THIS FILE, deliberately. psql -f gives each statement its own transaction
-- unless it is called with --single-transaction, so a file that dies partway leaves a partial install.
-- Appending the row here makes "a row for version V" mean "the V run reached the end of the file",
-- which is the only cheap evidence an operator has that an upgrade completed rather than aborted.
insert into pgpm.installed (version, pg_version)
  values (pgpm.version(), current_setting('server_version'));
