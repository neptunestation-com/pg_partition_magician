-- =============================================================================
-- pg_partition_magician :: from_hypertable  --  migrate a TimescaleDB hypertable
-- to a pgpm-managed native RANGE partition set.
--
-- OPTIONAL add-on, loaded ON TOP of the core (pgpm_core/install.sql) and
-- ONLY in a database where the timescaledb extension exists. It is kept out of the
-- core install so pgpm's only runtime dependency stays pg_cron.
--
-- Strategy (see from_hypertable_design.md): un-hypertable by a full COPY into a
-- plain table under the original name, then hand to transmute -- version- and
-- catalog-agnostic, which is what the deprecated Apache builds need. The copy is
-- online (source serves traffic, committed per chunk); only the cutover takes a
-- brief lock, and its wait for that lock is bounded by p_lock_timeout (#665).
-- Scope: a single time/RANGE dimension on a timestamptz, timestamp or date
-- column, migrated ON that column (p_control must be the dimension; see
-- _from_hypertable_check_dimension for why); append-only catch-up at
-- cutover. The control column's key is whatever transmute reuses -- a PRIMARY KEY
-- or UNIQUE constraint that includes it, or keyless if it has neither (the common
-- hypertable shape). Identity columns are preserved (re-established before the
-- handoff, since CREATE TABLE LIKE does not carry identity), generated columns are
-- preserved (the copy omits them from its column list and they recompute on
-- insert), and CHECK constraints, defaults, and NOT NULL are carried onto the
-- partitioned parent by transmute. The owner, grants, row-level security, policies,
-- comment and triggers, which LIKE does not carry either, are put back on the copy
-- in the swap (#787) and carried on by transmute. Refused up front: continuous
-- aggregates, space partitioning (>1 dimension), an integer-time dimension, a
-- p_control that is not the dimension column, an exclusion constraint (#675), and
-- two shapes transmute refuses after the swap, a bare unique index as the key and a
-- newest row past its frontier bound unless p_force_frontier (#792); transmute also
-- refuses a nullable control column or a key that excludes it.
--
-- Catch-up has two modes. By default the cutover catches up append-only: rows
-- whose control column is past the copy watermark. That is enough for time-series
-- workloads that only ever append. For workloads that UPDATE or DELETE rows during
-- the online window, pass p_track_changes => true: the copy installs an AFTER
-- INSERT/UPDATE/DELETE row trigger on the source that logs the touched key values
-- to a <rel>_pgpm_delta table, and the cutover reconciles every touched key against
-- the live source (delete-then-reinsert-from-source, which is idempotent and
-- order-independent, and subsumes the append-only catch-up). Reconciliation is by
-- the key transmute reuses (a PRIMARY KEY or UNIQUE constraint), so tracking needs a
-- key: it is refused on a keyless table. The cutover auto-detects the apparatus (the
-- delta table) rather than taking a matching flag, so the two phases cannot disagree.
--
-- NAMING: a local ending in `_q` holds text whose identifiers are already quoted, so it is
-- spliced with `%s` and `%I` would be a bug. See the note at the top of pgpm_core/install.sql;
-- scripts/check_quoted_splices.py enforces it here too.
-- =============================================================================

-- from_hypertable_disk_estimate: the approximate extra disk the online migration needs. The copy writes a
-- full second table (heap, and the indexes/identity rebuilt at cutover), so free roughly the source's
-- current on-disk size -- summed across all chunks (heap + indexes + toast) -- until the old hypertable is
-- dropped at cutover and the space is reclaimed. Callable on its own for sizing a volume ahead of time.
create or replace function pgpm.from_hypertable_disk_estimate(p_hypertable regclass)
returns bigint language plpgsql as $$
declare v_nsp name; v_rel name; v_bytes bigint;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  select coalesce(sum(pg_total_relation_size(format('%I.%I', chunk_schema, chunk_name)::regclass)), 0)
    into v_bytes
    from timescaledb_information.chunks
   where hypertable_schema = v_nsp and hypertable_name = v_rel;
  return v_bytes;
end $$;

-- from_hypertable_time_estimate: a ROUGH order-of-magnitude estimate of the online-copy duration -- the
-- dominant cost of migrating a hypertable. (transmute on a plain table is metadata-only and takes seconds
-- regardless of size, but a hypertable's rows must be physically copied out, which is O(rows).) The copy
-- reads every chunk and writes a second heap, so the time is governed by data volume and effective
-- throughput, which is REGIME-dependent: a working set that fits in cache copies far faster than one that
-- is heap-random-I/O bound. p_copy_mibps overrides the assumed effective throughput (MiB/s of logical data
-- copied); when null it is chosen by comparing the estimated size to effective_cache_size. The defaults
-- (~40 MiB/s cache-resident, ~16 MiB/s disk-bound) are order-of-magnitude figures measured on a Supabase
-- 2XL on gp3 and scale with RAM/IOPS/throughput. This covers ONLY the copy -- the cutover's index rebuild
-- and an optional later regrain are additional. Callable on its own for sizing.
create or replace function pgpm.from_hypertable_time_estimate(
  p_hypertable regclass, p_copy_mibps numeric default null
) returns interval language plpgsql as $$
declare v_bytes bigint; v_cache bigint; v_mibps numeric;
begin
  v_bytes := pgpm.from_hypertable_disk_estimate(p_hypertable);
  v_mibps := p_copy_mibps;
  if v_mibps is null then
    begin v_cache := pg_size_bytes(current_setting('effective_cache_size'));
    exception when others then v_cache := null; end;
    v_mibps := case when v_cache is not null and v_bytes > v_cache then 16 else 40 end;
  end if;
  if v_mibps <= 0 then v_mibps := 16; end if;   -- guard against a nonsensical override
  return make_interval(secs => (v_bytes / (v_mibps * 1048576.0))::double precision);
end $$;

-- _from_hypertable_check_dimension: the two facts the chunk-by-chunk copy silently depends on (issue #458).
-- The copy bounds each chunk with `<p_control> >= range_start and < range_end` read from
-- timescaledb_information.chunks. Those are ranges OF THE DIMENSION COLUMN, and they are populated only for a
-- timestamp-typed dimension: an integer dimension's bounds live in range_start_integer and range_start is
-- NULL for every chunk. So the predicate partitions the table exactly when p_control IS the time dimension
-- AND the dimension is timestamptz/timestamp/date. Anything else copies a strict subset of the rows, or
-- nothing at all (`t >= NULL and t < NULL`), and the cutover then drops the hypertable and reports success
-- over an empty table: no error, no log row. Preflight used to check only that the column exists.
--
-- Factored out of the preflight so the cutover can run it in its own right. The cutover is the irreversible
-- step and required only that a destination exist, which a copy run under an older version (or a table made
-- by hand) satisfies without the copy phase ever having refused. dimension_number = 1 rather than
-- dimension_type = 'Time': Timescale allows a second range dimension, and then 'Time' names two rows while
-- the primary is always number 1 (preflight refuses >1 dimensions anyway). Internal, so no promise attaches.
create or replace function pgpm._from_hypertable_check_dimension(p_hypertable regclass, p_control name)
returns void language plpgsql as $$
declare v_nsp name; v_rel name; v_dim_col name; v_dim_type regtype;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  select column_name, column_type into v_dim_col, v_dim_type
    from timescaledb_information.dimensions
   where hypertable_schema = v_nsp and hypertable_name = v_rel and dimension_number = 1;
  if v_dim_col is null then
    raise exception 'pg_partition_magician: % is not a hypertable', p_hypertable;
  end if;
  if v_dim_col <> p_control then
    raise exception 'pg_partition_magician: cannot migrate hypertable % on column % -- its time dimension is %. The online copy is bounded chunk by chunk on the dimension''s chunk ranges, so it conserves rows only when p_control is the dimension column; on any other column rows would be silently lost. Pass p_control => %.',
      p_hypertable, p_control, v_dim_col, quote_ident(v_dim_col);
  end if;
  if v_dim_type not in ('timestamptz'::regtype, 'timestamp'::regtype, 'date'::regtype) then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- its time dimension % is %: integer-time hypertables are not supported by from_hypertable; only timestamptz, timestamp and date dimensions are. An integer dimension''s chunk ranges live in range_start_integer, which the chunk-by-chunk copy does not read, so the copy would move nothing, and the handoff to transmute is by time interval.',
      p_hypertable, v_dim_col, v_dim_type;
  end if;
end $$;

-- _from_hypertable_check_names: the working relations this module derives from the hypertable's name must
-- fit PostgreSQL's 63-byte identifier limit whole (#552). They are <rel>_pgpm_dest, <rel>_pgpm_delta, its
-- trigger function <rel>_pgpm_delta_fn and its trigger <rel>_pgpm_delta_trg, and the parser used to cut
-- each one to 63 bytes silently. From 55 bytes the destination and the delta cut to the SAME name: the copy
-- created the delta, the destination skeleton's `drop table if exists` dropped it and took its name, and the
-- capture trigger on the LIVE source then inserted key-only rows into the destination, so every write to
-- the production hypertable failed on its first NOT NULL non-key column from the copy onward. Shorter than
-- that the cut names were at least distinct, but each could name a relation this module did not make.
-- Refused, never truncated, as core refuses its own derived names (#510): called by the preflight (so the
-- copy refuses before it installs anything) and by every other entry point that derives the names (the
-- cutover and the two online drains), before any DDL. The longest suffix is 15 bytes, so a hypertable
-- name of up to 48 bytes fits. octet_length, not length: the limit is bytes.
create or replace function pgpm._from_hypertable_check_names(p_hypertable regclass)
returns void language plpgsql stable as $$
declare v_rel name; v_long text;
begin
  select c.relname into v_rel from pg_class c where c.oid = p_hypertable;
  select s.n into v_long
    from unnest(array[v_rel || '_pgpm_dest', v_rel || '_pgpm_delta', v_rel || '_pgpm_delta_fn',
                      v_rel || '_pgpm_delta_trg']) as s(n)
   where octet_length(s.n) > 63
   order by octet_length(s.n) desc limit 1;
  if v_long is not null then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- the working relation name % is % bytes, over PostgreSQL''s 63-byte identifier limit, and pgpm never truncates a name it derives from the table''s (a cut name can collide with another: from 55 bytes the destination and the change-capture delta cut to the same one). Shorten the table name by at least % byte(s) (ALTER TABLE ... RENAME), then re-run.',
      p_hypertable, v_long, octet_length(v_long), octet_length(v_long) - 63;
  end if;
end $$;

-- _from_hypertable_check_exclusion: an EXCLUDE constraint is refused, never dropped (issue #675). Nothing in
-- the migration carries one: the copy's CREATE TABLE ... LIKE takes CHECK and NOT NULL only, the cutover
-- re-adds only primary and unique keys, and its index loop skips every constraint-backed index. Nor could
-- it be carried in general, since PostgreSQL before 17 allows no exclusion constraint on a partitioned table
-- at all. So the migrated table used to accept the rows the constraint had rejected, with no error and no
-- log row. Called by the preflight (and through it from_hypertable and from_hypertable_copy) and by the
-- cutover in its own right, for the reason _from_hypertable_check_dimension gives: a destination left by an
-- older version's copy, or made by hand, reaches the swap without the preflight ever having run. Names
-- every such constraint at once, so an operator with several does not re-run once per constraint.
create or replace function pgpm._from_hypertable_check_exclusion(p_hypertable regclass)
returns void language plpgsql as $$
declare v_excl_q text;
begin
  select string_agg(quote_ident(conname), ', ' order by conname) into v_excl_q
    from pg_constraint where conrelid = p_hypertable and contype = 'x';
  if v_excl_q is not null then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- its exclusion constraint(s) (%) cannot be carried. from_hypertable rebuilds the table as a plain copy and hands it to transmute, and neither carries an EXCLUDE constraint (PostgreSQL before 17 allows none on a partitioned table), so the migrated table would silently accept the rows the constraint rejects. Drop the constraint(s) (ALTER TABLE % DROP CONSTRAINT <name>) if the table can do without them, then re-run from_hypertable.',
      p_hypertable, v_excl_q, p_hypertable::text;
  end if;
end $$;

-- _from_hypertable_tmp_name: the name an index of the hypertable is pre-built under on the destination,
-- before the swap renames it (a secondary index) or adopts it as its constraint (a key). Whole, never cut
-- (#707, the #655 class): it used to be left(<name> || '_pgpm_new', 63), and for a 63-byte name that is the
-- name ITSELF, which the source's index still holds. The tracked copy's key build then died on 'already
-- exists', and the append-only cutover found the source's own index under the temp name, skipped its
-- build, and failed adopting an index the DROP had just taken, after the whole online copy either way.
-- When <name>_pgpm_new does not fit it is pgpm_new_<index oid>: whole, at most 19 bytes, one per index. The
-- copy and the cutover both ask this for the same index and so agree on the name, which is how the cutover
-- finds the key index the tracked copy built (#175).
create or replace function pgpm._from_hypertable_tmp_name(p_name name, p_index oid)
returns name language sql immutable as $$
  select (case when octet_length(p_name || '_pgpm_new') <= 63 then p_name || '_pgpm_new'
               else 'pgpm_new_' || p_index::text end)::name
$$;

-- _from_hypertable_index_ddl: the CREATE INDEX that builds index p_index of the hypertable on the destination
-- p_nsp.p_dest under p_tmp (#735). The name and the table are spliced BY IDENTITY, not matched by pattern:
-- pg_get_indexdef spells them quote_ident(index name) and quote_ident(schema).quote_ident(table), read here
-- from the catalog by the index's oid, so the definition starts with exactly one of two prefixes, and the
-- prefix is replaced whole. The pattern this replaces, '^(CREATE (UNIQUE )?INDEX )[^ ]+ ON [^ ]+', could not
-- span a quoted name holding a space ("f6 metrics_pkey"), did not match, and the statement ran UNREWRITTEN:
-- it tried to build a second "f6 metrics_pkey" on the SOURCE and failed with 'relation already exists' after
-- the whole online copy, though the preflight had accepted the table. The same construction as the core's
-- carried indexes (#669), and a definition that starts with neither prefix is refused rather than run.
create or replace function pgpm._from_hypertable_index_ddl(p_index oid, p_tmp name, p_nsp name, p_dest name)
returns text language plpgsql stable as $$
declare
  v_def text; v_idx name; v_tnsp name; v_trel name;
  v_on_q text;     -- ' ON <schema>.<table> ', as pg_get_indexdef quotes the index's own table
  v_ipfx_q text;   -- the two prefixes the definition can start with
  v_upfx_q text;
  v_to_q text;     -- '<temp name> ON <schema>.<destination> ', what replaces the name and the table
begin
  select pg_get_indexdef(i.indexrelid), ic.relname, tn.nspname, tc.relname into v_def, v_idx, v_tnsp, v_trel
    from pg_index i
    join pg_class ic on ic.oid = i.indexrelid
    join pg_class tc on tc.oid = i.indrelid
    join pg_namespace tn on tn.oid = tc.relnamespace
   where i.indexrelid = p_index;
  v_on_q := ' ON ' || quote_ident(v_tnsp) || '.' || quote_ident(v_trel) || ' ';
  v_ipfx_q := 'CREATE INDEX ' || quote_ident(v_idx) || v_on_q;
  v_upfx_q := 'CREATE UNIQUE INDEX ' || quote_ident(v_idx) || v_on_q;
  v_to_q := quote_ident(p_tmp) || ' ON ' || quote_ident(p_nsp) || '.' || quote_ident(p_dest) || ' ';
  if starts_with(v_def, v_upfx_q) then
    return 'CREATE UNIQUE INDEX ' || v_to_q || substr(v_def, length(v_upfx_q) + 1);
  elsif starts_with(v_def, v_ipfx_q) then
    return 'CREATE INDEX ' || v_to_q || substr(v_def, length(v_ipfx_q) + 1);
  end if;
  raise exception 'pg_partition_magician: cannot rebuild the index % of %.% on the migration''s destination: its definition (%) does not start with CREATE [UNIQUE] INDEX % ON %.%, so it cannot be renamed onto the destination',
    quote_ident(v_idx), quote_ident(v_tnsp), quote_ident(v_trel), v_def, quote_ident(v_idx),
    quote_ident(v_tnsp), quote_ident(v_trel);
end $$;

-- _from_hypertable_check_key: the key transmute will refuse, asked of the hypertable BEFORE anything changes
-- (#792). TimescaleDB's own documented way to add a unique key is CREATE UNIQUE INDEX, and transmute reuses
-- a primary key or a unique CONSTRAINT as the key, never a bare index: it refused one with the hypertable
-- already dropped by the committed swap, leaving a plain unmanaged table. The rule is transmute's own
-- (pgpm._transmute_bare_unique); the message is this module's, because transmute's remedy (ADD CONSTRAINT
-- ... USING INDEX) is one TimescaleDB refuses on a hypertable. A catalog read, which takes no lock on the
-- table. Called by the preflight (and through it from_hypertable and from_hypertable_copy), and by the
-- cutover under its ACCESS EXCLUSIVE, since a destination left by an older version's copy, or made by hand,
-- reaches the swap without the preflight ever having run, and an index can be added after the copy.
create or replace function pgpm._from_hypertable_check_key(p_hypertable regclass, p_control name)
returns void language plpgsql stable as $$
declare v_idx name; v_idx_oid regclass; v_keycols_q text; v_inccols_q text;
begin
  v_idx := pgpm._transmute_bare_unique(p_hypertable, p_control);
  if v_idx is null then return; end if;
  select i.indexrelid::regclass,
         string_agg(quote_ident(a.attname), ', ' order by k.ord) filter (where k.ord <= i.indnkeyatts),
         string_agg(quote_ident(a.attname), ', ' order by k.ord) filter (where k.ord > i.indnkeyatts)
    into v_idx_oid, v_keycols_q, v_inccols_q
    from pg_index i join pg_class c on c.oid = i.indexrelid
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indrelid = p_hypertable and c.relname = v_idx
   group by i.indexrelid;
  raise exception 'pg_partition_magician: cannot migrate hypertable % -- refused before anything is changed, because transmute, which takes the table over once the cutover''s swap has committed, would refuse it: the unique index % includes the control column % but is a bare index, not a constraint, and pgpm reuses a primary key or a unique constraint as the key, never a bare index. TimescaleDB does not allow ADD CONSTRAINT ... USING INDEX on a hypertable, so build the constraint instead: ALTER TABLE % ADD CONSTRAINT % UNIQUE (%)%; then DROP INDEX %; and re-run from_hypertable.',
    p_hypertable, v_idx_oid, quote_ident(p_control), p_hypertable, quote_ident(v_idx || '_key'), v_keycols_q,
    coalesce(' INCLUDE (' || v_inccols_q || ')', ''), v_idx_oid;
end $$;

-- _from_hypertable_check_handoff: the names transmute will derive from the table and p_interval must fit, asked
-- BEFORE anything changes (#707). The cutover hands the plain table to transmute only after its swap has
-- committed, and transmute names the monolith <rel>_p<lo>_to_<hi> at the grid's label granularity (26
-- bytes past the name on a daily grid, so a 38 to 48 byte name, inside _from_hypertable_check_names' own
-- budget, did not fit): its refusal came with the hypertable already dropped, leaving a plain table under
-- the original name. The labels' width depends only on the step, so the explicit-range form of the anchor
-- cell is exactly as long as the monolith's name, and _part_name, which transmute itself asks, is the one
-- source of the rule. A monolith that happens to span a single step takes the shorter fine name, so this
-- can refuse a grid transmute would have accepted for such a table; it cannot pass one transmute refuses.
-- Called by from_hypertable before its copy and by the cutover before its pre-drain.
create or replace function pgpm._from_hypertable_check_handoff(
  p_hypertable regclass, p_interval interval, p_anchor timestamptz
) returns void language plpgsql as $$
declare v_rel name;
begin
  select c.relname into v_rel from pg_class c where c.oid = p_hypertable;
  perform pgpm._part_name(v_rel, 'time', p_interval::text, pgpm._ts_text(p_anchor), pgpm._ts_text(p_anchor),
                          'UTC', true);
exception when others then
  if sqlerrm not like 'pg_partition_magician: cannot name a partition of %' then raise; end if;
  raise exception 'pg_partition_magician: cannot migrate hypertable % with p_interval % -- refused before anything is changed, because transmute, which takes the table over once the cutover''s swap has committed, would refuse it: %',
    p_hypertable, p_interval, regexp_replace(sqlerrm, '^pg_partition_magician: ', '');
end $$;

-- _from_hypertable_check_frontier: transmute's frontier refusal (#457), asked of the hypertable before the
-- swap (#792). A newest row further ahead of now() than one step plus an hour (a device with a wrong clock)
-- is refused by transmute unless p_force_frontier, and that came after the swap had committed, with the
-- hypertable dropped and no way to pass the override through. The bound is transmute's own,
-- pgpm._frontier_skew_limit, and p_force_frontier skips this exactly as it skips transmute's check, to which
-- the cutover passes it. Asked only of a timestamp dimension the column really is: a column that is missing
-- or of another type is the dimension check's to refuse, by name. It reads the table, so it is not asked
-- where the read's ACCESS SHARE would outlive it into a window something else must stay able to write in:
-- from_hypertable asks it before its copy (whose first COMMIT ends that transaction), and the cutover under
-- its ACCESS EXCLUSIVE, where the source is frozen and a row written while the cutover prepared is seen.
create or replace function pgpm._from_hypertable_check_frontier(
  p_hypertable regclass, p_control name, p_interval interval, p_force_frontier boolean
) returns void language plpgsql as $$
declare v_typ regtype; v_max timestamptz; v_limit timestamptz;
begin
  if p_force_frontier then return; end if;
  select a.atttypid into v_typ
    from pg_attribute a where a.attrelid = p_hypertable and a.attname = p_control and not a.attisdropped;
  if v_typ is null or v_typ not in ('timestamptz'::regtype, 'timestamp'::regtype, 'date'::regtype) then
    return;
  end if;
  -- A naive (timestamp, date) value is read as UTC wall time, the zone transmute computes such a grid in (#504).
  execute format('select max(t.%I)%s from %s t', p_control,
                 case when v_typ = 'timestamptz'::regtype then '' else '::timestamp at time zone ''UTC''' end,
                 p_hypertable::text)
    into v_max;
  v_limit := pgpm._frontier_skew_limit(p_interval);
  if v_max > v_limit then
    raise exception 'pg_partition_magician: cannot migrate hypertable % with p_interval % -- refused before anything is changed, because transmute, which takes the table over once the cutover''s swap has committed, would refuse it: its newest % is %, which is % ahead of now() (%), more than one step plus one hour (the most the newest row may lead the clock by, so after %). That one value would fix the monolith''s permanent upper bound past it, and every row written until the clock gets there would land in the monolith, which cannot be regrained. Delete or correct the rows whose % is after %, or re-run with p_force_frontier => true to accept that bound.',
      p_hypertable, p_interval, quote_ident(p_control), v_max, justify_interval(date_trunc('second', v_max - now())),
      now(), v_limit, quote_ident(p_control), v_limit;
  end if;
end $$;

-- _from_hypertable_carried_ddl: what the swap has to put back on the table it renames into the hypertable's
-- place (#787), as the statements that do it. The copy is made by CREATE TABLE ... LIKE, which carries none
-- of the table's owner, its table and column grants, its row-level security (ENABLE and FORCE) and
-- policies, its own comment or its triggers, and the swap drops the hypertable they were on. So none of them
-- reached transmute, which carries exactly these from a plain table onto its parent (#277): every grantee got
-- permission denied once the migration completed, the policies were gone, and the triggers stopped firing.
-- Read off the source by the cutover under its ACCESS EXCLUSIVE, which holds every one of them still except a
-- GRANT or REVOKE (those take no lock on the table), just before the DROP, and replayed in the swap
-- transaction once the copy has the source's name: each statement names the table by that name, and
-- pg_get_triggerdef's text names it the same way, so they replay verbatim, as transmute replays its triggers.
-- Left out, by what they are: TimescaleDB's own insert-blocker trigger (its function lives in a
-- _timescaledb_* schema) and this module's change-capture trigger (<rel>_pgpm_delta_fn, dropped with the
-- source). No trigger state rides along, because TimescaleDB refuses ENABLE and DISABLE TRIGGER on a
-- hypertable, so every user trigger is origin-enabled, which is what CREATE TRIGGER leaves. Not carried
-- either, because transmute does not carry them onto its parent: the replica identity and the storage
-- parameters.
create or replace function pgpm._from_hypertable_carried_ddl(p_hypertable regclass)
returns text[] language plpgsql stable as $$
declare
  v_nsp name; v_rel name; v_tbl_q text; v_ddl text[] := '{}'; r record;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_tbl_q := format('%I.%I', v_nsp, v_rel);
  v_ddl := v_ddl || format('alter table %s owner to %I', v_tbl_q,
                           (select pg_get_userbyid(c.relowner) from pg_class c where c.oid = p_hypertable));
  -- Table grants. A NULL relacl is the owner's implicit default, which the copy has too. grantee 0 is PUBLIC.
  for r in
    select a.grantee, a.privilege_type, a.is_grantable
      from pg_class c, aclexplode(c.relacl) a where c.oid = p_hypertable and c.relacl is not null
     order by a.grantee, a.privilege_type
  loop
    v_ddl := v_ddl || format('grant %s on %s to %s%s', r.privilege_type, v_tbl_q,
                             case when r.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(r.grantee)) end,
                             case when r.is_grantable then ' with grant option' else '' end);
  end loop;
  -- Column grants, which live in pg_attribute.attacl, not relacl.
  for r in
    select att.attname, a.grantee, a.privilege_type, a.is_grantable
      from pg_attribute att, aclexplode(att.attacl) a
     where att.attrelid = p_hypertable and att.attnum > 0 and not att.attisdropped and att.attacl is not null
     order by att.attnum, a.grantee, a.privilege_type
  loop
    v_ddl := v_ddl || format('grant %s (%I) on %s to %s%s', r.privilege_type, r.attname, v_tbl_q,
                             case when r.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(r.grantee)) end,
                             case when r.is_grantable then ' with grant option' else '' end);
  end loop;
  -- Row-level security. FORCE matters as much as ENABLE: without it the owner bypasses every policy.
  if (select c.relrowsecurity from pg_class c where c.oid = p_hypertable) then
    v_ddl := v_ddl || format('alter table %s enable row level security', v_tbl_q);
  end if;
  if (select c.relforcerowsecurity from pg_class c where c.oid = p_hypertable) then
    v_ddl := v_ddl || format('alter table %s force row level security', v_tbl_q);
  end if;
  for r in
    select polname, polcmd, polpermissive,
           case when polroles = '{0}'::oid[] then 'public'
                else (select string_agg(quote_ident(rolname), ', ' order by rolname)
                        from pg_roles where oid = any(polroles)) end as roles_q,
           pg_get_expr(polqual, polrelid) as qual, pg_get_expr(polwithcheck, polrelid) as withcheck
      from pg_policy where polrelid = p_hypertable order by polname
  loop
    v_ddl := v_ddl || format('create policy %I on %s as %s for %s to %s%s%s', r.polname, v_tbl_q,
      case when r.polpermissive then 'permissive' else 'restrictive' end,
      case r.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update'
                    when 'd' then 'delete' else 'all' end,
      r.roles_q,
      case when r.qual is not null then ' using (' || r.qual || ')' else '' end,
      case when r.withcheck is not null then ' with check (' || r.withcheck || ')' else '' end);
  end loop;
  -- The table's own comment. LIKE ... INCLUDING COMMENTS carried the columns' and constraints', not this one.
  if obj_description(p_hypertable, 'pg_class') is not null then
    v_ddl := v_ddl || format('comment on table %s is %L', v_tbl_q, obj_description(p_hypertable, 'pg_class'));
  end if;
  for r in
    select pg_get_triggerdef(t.oid) as def
      from pg_trigger t join pg_proc f on f.oid = t.tgfoid join pg_namespace fn on fn.oid = f.pronamespace
     where t.tgrelid = p_hypertable and not t.tgisinternal
       and fn.nspname not like '\_timescaledb%'
       and not (fn.nspname = v_nsp and f.proname = v_rel || '_pgpm_delta_fn')
     order by t.tgname
  loop
    v_ddl := v_ddl || r.def;
  end loop;
  return v_ddl;
end $$;

-- _from_hypertable_shape_diff: how the copy's shape differs from the source's, or null when it does not
-- (issue #738). from_hypertable_copy fixes the destination's shape once, by CREATE TABLE ... LIKE, and the
-- documented two-phase flow lets the workload run on between the copy and the cutover. DDL on the live
-- hypertable in that window (a column dropped, a default changed, a CHECK added) changed only the source,
-- and the swap renamed the stale copy into its place: the dropped column came back holding its old values,
-- the default reverted and the CHECK was gone, all silently, because the cutover read its column list and
-- its conservation fingerprint from the source alone. Compared here: the set of columns, and for each
-- column its type, NOT NULL, collation and default or generation expression; the CHECK constraints by name
-- and definition; and the column order, when the sets agree. NOT VALID is not compared, because LIKE copies
-- a NOT VALID check as validated (the copy's rows were checked as they were inserted). Not compared,
-- because the cutover carries them from the source under its lock: identity (re-added from the source),
-- the primary and unique keys and the secondary indexes (rebuilt from the source's). Both sides are
-- rendered by this one call, so an expression reads the same on both whatever the search_path.
create or replace function pgpm._from_hypertable_shape_diff(p_src regclass, p_dest regclass)
returns text language sql stable as $$
  with cols as (
    select a.attrelid as rel, a.attnum, a.attname::text as col,
           format_type(a.atttypid, a.atttypmod) as typ,
           case when a.attnotnull then 'NOT NULL' else 'nullable' end as nn,
           coalesce((select 'collation ' || quote_ident(c.collname) from pg_collation c where c.oid = a.attcollation),
                    'no collation') as coll,
           case when a.attgenerated = 's' then 'generated always as (' || pg_get_expr(d.adbin, d.adrelid) || ') stored'
                else coalesce('default ' || pg_get_expr(d.adbin, d.adrelid), 'no default') end as dflt
      from pg_attribute a
      left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
     where a.attrelid in (p_src, p_dest) and a.attnum > 0 and not a.attisdropped),
  s as (select * from cols where rel = p_src),
  d as (select * from cols where rel = p_dest),
  ck as (
    select c.conrelid as rel, c.conname::text as name,
           regexp_replace(pg_get_constraintdef(c.oid), ' NOT VALID$', '') as def
      from pg_constraint c where c.conrelid in (p_src, p_dest) and c.contype = 'c'),
  diffs (k, o, msg) as (
    select 1, s.col, format('column %I is on the source but not on the copy', s.col)
      from s where not exists (select 1 from d where d.col = s.col)
    union all
    select 1, d.col, format('column %I is on the copy but no longer on the source', d.col)
      from d where not exists (select 1 from s where s.col = d.col)
    union all
    select 2, s.col, format('column %I has type %s on the source but %s on the copy', s.col, s.typ, d.typ)
      from s join d using (col) where s.typ <> d.typ
    union all
    select 2, s.col, format('column %I is %s on the source but %s on the copy', s.col, s.nn, d.nn)
      from s join d using (col) where s.nn <> d.nn
    union all
    select 2, s.col, format('column %I has %s on the source but %s on the copy', s.col, s.coll, d.coll)
      from s join d using (col) where s.coll <> d.coll
    union all
    select 2, s.col, format('column %I has %s on the source but %s on the copy', s.col, s.dflt, d.dflt)
      from s join d using (col) where s.dflt <> d.dflt
    union all
    select 3, cs.name, format('CHECK %I (%s) is on the source but not on the copy', cs.name, cs.def)
      from ck cs where cs.rel = p_src
       and not exists (select 1 from ck cd where cd.rel = p_dest and cd.name = cs.name)
    union all
    select 3, cd.name, format('CHECK %I is on the copy but no longer on the source', cd.name)
      from ck cd where cd.rel = p_dest
       and not exists (select 1 from ck cs where cs.rel = p_src and cs.name = cd.name)
    union all
    select 3, cs.name, format('CHECK %I is %s on the source but %s on the copy', cs.name, cs.def, cd.def)
      from ck cs join ck cd on cd.name = cs.name and cd.rel = p_dest
     where cs.rel = p_src and cs.def <> cd.def
    union all
    select 4, '', format('the columns are in a different order (source: %s; copy: %s)',
                         (select string_agg(quote_ident(col), ', ' order by attnum) from s),
                         (select string_agg(quote_ident(col), ', ' order by attnum) from d))
     where (select array_agg(col order by col) from s) = (select array_agg(col order by col) from d)
       and (select array_agg(col order by attnum) from s) <> (select array_agg(col order by attnum) from d))
  select string_agg(msg, '; ' order by k, o, msg) from diffs;
$$;

-- _from_hypertable_check_shape: refuse the swap when the copy's shape is not the source's (issue #738).
-- Called twice by the cutover. First up front, before the pre-drain or the index pre-builds spend anything,
-- which catches DDL made before the call and names it (a column added since the copy would otherwise die
-- raw in the pre-lock reads of the copy, which name it). Then again under the swap's ACCESS EXCLUSIVE on
-- both relations, which is the call that decides: the source is unlocked until then, and DDL can land at
-- any point before it.
-- Refusing rather than adapting, because the copy's rows were written in the old shape and only a fresh
-- copy can say what they are in the new one.
create or replace function pgpm._from_hypertable_check_shape(p_hypertable regclass, p_dest regclass)
returns void language plpgsql stable as $$
declare v_diff text;
begin
  v_diff := pgpm._from_hypertable_shape_diff(p_hypertable, p_dest);
  if v_diff is not null then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) refusing to swap: the copy % no longer has the source''s shape: %. from_hypertable_copy fixed the copy''s columns, defaults and CHECK constraints when it ran, so the swap would put that shape back, reverting the DDL run on the hypertable since. Nothing was dropped and the source is whole. Re-run from_hypertable_copy, which rebuilds the copy in the source''s current shape, then the cutover.',
      p_hypertable, p_dest, v_diff;
  end if;
end $$;

-- from_hypertable_preflight: the refusal checks, factored out so they are callable on their own (a
-- dry-run gate) and unit-testable inside a transaction. Raises a pgpm-prefixed error on any blocker;
-- returns normally when the hypertable is migratable by this version (with a NOTICE estimating the disk).
create or replace function pgpm.from_hypertable_preflight(p_hypertable regclass, p_control name)
returns void language plpgsql as $$
declare
  v_nsp name; v_rel name; v_cagg text; v_dims int; v_ctl_attnum int; v_bytes bigint;
  v_cache bigint; v_mibps numeric; v_regime text; v_eta interval;
  v_bad_fk text; v_reusekey text[]; v_fk record;
begin
  if not exists (select 1 from pg_extension where extname = 'timescaledb') then
    raise exception 'pg_partition_magician: from_hypertable requires the timescaledb extension to be installed';
  end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  if not exists (select 1 from timescaledb_information.hypertables
                  where hypertable_schema = v_nsp and hypertable_name = v_rel) then
    raise exception 'pg_partition_magician: % is not a hypertable', p_hypertable;
  end if;

  -- (0) the names the migration derives from the table's must fit whole (#552)
  perform pgpm._from_hypertable_check_names(p_hypertable);

  -- (1) continuous aggregates: no native-partition equivalent, and dropping them is data-destructive.
  select string_agg(view_name, ', ') into v_cagg from timescaledb_information.continuous_aggregates
   where hypertable_schema = v_nsp and hypertable_name = v_rel;
  if v_cagg is not null then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- it has continuous aggregate(s) (%), which have no native-partition equivalent. Drop them first if you do not need them, then re-run from_hypertable.',
      p_hypertable, v_cagg;
  end if;

  -- (2) more than one dimension (space partitioning via add_dimension): pgpm is single-key RANGE.
  select num_dimensions into v_dims from timescaledb_information.hypertables
   where hypertable_schema = v_nsp and hypertable_name = v_rel;
  if coalesce(v_dims, 1) > 1 then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- it has % dimensions (space partitioning). pgpm is single-key RANGE; drop the extra dimension(s) first.',
      p_hypertable, v_dims;
  end if;

  -- (3) the control column must exist. The key/NOT-NULL contract is left to transmute (the single source
  -- of truth): it reuses a primary key or unique constraint if one includes the control column, and
  -- otherwise partitions the table keyless -- which is exactly the common hypertable shape, since
  -- create_hypertable makes the time column NOT NULL but adds no key. So a keyless hypertable migrates.
  select a.attnum into v_ctl_attnum
    from pg_attribute a where a.attrelid = p_hypertable and a.attname = p_control and not a.attisdropped;
  if v_ctl_attnum is null then
    raise exception 'pg_partition_magician: column % not found on %', p_control, p_hypertable;
  end if;

  -- (3b) ...and it must BE the time dimension, and that dimension must be a timestamp type (issue #458).
  -- Existence is not enough: a second time column passes (3) and migrates to zero rows, because the copy is
  -- bounded on the DIMENSION's chunk ranges; an integer dimension passes (3) and copies nothing, because its
  -- ranges are not in the column the copy reads. See _from_hypertable_check_dimension.
  perform pgpm._from_hypertable_check_dimension(p_hypertable, p_control);

  -- (3b2) a key transmute would refuse after the swap: a bare unique index (issue #792). See
  -- _from_hypertable_check_key.
  perform pgpm._from_hypertable_check_key(p_hypertable, p_control);

  -- (3c) an EXCLUDE constraint, which nothing in the migration carries (issue #675). See
  -- _from_hypertable_check_exclusion.
  perform pgpm._from_hypertable_check_exclusion(p_hypertable);

  -- (4) an outgoing FK the source never validated (issue #264). The migration carries outgoing FKs by
  -- replaying each definition verbatim on the private destination and then VALIDATEing it, so a NOT VALID
  -- constraint would either fail that validation on pre-existing violations or be silently strengthened
  -- into a validated one. Neither is ours to decide, so refuse and name it.
  select string_agg(conname, ', ') into v_bad_fk
    from pg_constraint
   where conrelid = p_hypertable and contype = 'f' and confrelid <> p_hypertable and not convalidated;
  if v_bad_fk is not null then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- its outgoing foreign key(s) (%) are NOT VALID. from_hypertable carries an outgoing key by replaying it on the copy and validating it, which would either fail on the rows the source never checked or silently upgrade the constraint. Run ALTER TABLE % VALIDATE CONSTRAINT <name> first (or drop the constraint), then re-run from_hypertable.',
      p_hypertable, v_bad_fk, p_hypertable::text;
  end if;

  -- (5) an INCOMING FK that does not reference the key transmute will reuse (issue #264). The migration
  -- re-adds each incoming FK against the new partitioned parent, which can only carry a unique key on
  -- exactly the columns transmute reused. Refusing HERE is the single most valuable check in this
  -- function: the alternative is discovering it in the cutover, after the entire online copy has run,
  -- with the populated destination left orphaned behind the rollback.
  --
  -- The reused-key selection mirrors _transmute's, which stays the single source of truth: the PK if it
  -- includes the control column, otherwise a non-partial, non-expression UNIQUE constraint that does.
  -- Drift can only cost a MISSED refusal here, never a false one, because transmute re-checks eligibility
  -- itself -- so this check is allowed to be the more permissive of the two, never the stricter.
  if exists (select 1 from pg_constraint
              where confrelid = p_hypertable and contype = 'f' and conrelid <> p_hypertable) then
    select array_agg(a.attname::text order by k.ord) into v_reusekey
      from pg_constraint con
      cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
     where con.conrelid = p_hypertable and con.contype = 'p' and v_ctl_attnum = any(con.conkey)
     group by con.conname;

    if v_reusekey is null then
      select cols into v_reusekey from (
        select array_agg(a.attname::text order by k.ord) as cols, con.conname
          from pg_constraint con
          join pg_index i on i.indexrelid = con.conindid
          cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
          join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
         where con.conrelid = p_hypertable and con.contype = 'u'
           and i.indpred is null and i.indexprs is null and v_ctl_attnum = any(con.conkey)
         group by con.conname order by con.conname limit 1) s;
    end if;

    for v_fk in
      select c.conname, c.conrelid::regclass as referencing,
             (select array_agg(a.attname::text order by k.ord)
                from unnest(c.confkey) with ordinality as k(attnum, ord)
                join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as rcols
        from pg_constraint c
       where c.confrelid = p_hypertable and c.contype = 'f' and c.conrelid <> p_hypertable
         and c.conparentid = 0
    loop
      if v_reusekey is null
         or (select array_agg(x order by x) from unnest(v_fk.rcols) x)
            is distinct from (select array_agg(x order by x) from unnest(v_reusekey) x) then
        raise exception 'pg_partition_magician: cannot migrate hypertable % -- the incoming foreign key % on % references (%), but the key pgpm would reuse is %. An incoming key can only be re-added against the new partitioned parent when it references exactly that reused key. Drop the foreign key, or give % a primary key or unique constraint on (%) that includes the control column %, then re-run from_hypertable.',
          p_hypertable, v_fk.conname, v_fk.referencing, array_to_string(v_fk.rcols, ', '),
          coalesce('(' || array_to_string(v_reusekey, ', ') || ')', 'none (the table would be partitioned keyless)'),
          p_hypertable::text, array_to_string(v_fk.rcols, ', '), quote_ident(p_control);
      end if;
    end loop;
  end if;

  -- disk: the online copy writes a full second table, so warn how much extra space the migration needs until
  -- cutover drops the old hypertable. Informational (a NOTICE), never a refusal.
  v_bytes := pgpm.from_hypertable_disk_estimate(p_hypertable);
  raise notice 'pg_partition_magician: from_hypertable will copy % into a second table before cutover (about %); ensure that much free disk until the old hypertable is dropped at cutover and the space is reclaimed.',
    p_hypertable, pg_size_pretty(v_bytes);

  -- time: a rough ETA for the online copy (the dominant cost). The regime is guessed from
  -- effective_cache_size; both are order-of-magnitude. Informational, never a refusal.
  begin v_cache := pg_size_bytes(current_setting('effective_cache_size'));
  exception when others then v_cache := null; end;
  if v_cache is not null and v_bytes > v_cache then v_mibps := 16; v_regime := 'disk-bound: estimated size exceeds effective_cache_size';
  else v_mibps := 40; v_regime := 'cache-resident: estimated size fits effective_cache_size'; end if;
  v_eta := pgpm.from_hypertable_time_estimate(p_hypertable, v_mibps);
  raise notice 'pg_partition_magician: estimated online copy time ~ % (% at ~% MiB/s, %). This covers the copy only -- the cutover then rebuilds the primary key and secondary indexes (extra, scales with row count) and a later regrain (if used) is a similar second pass. Rough (measured on a 2XL gp3): more RAM/IOPS/throughput is faster. Override the rate with pgpm.from_hypertable_time_estimate(table, mibps).',
    v_eta, pg_size_pretty(v_bytes), v_mibps, v_regime;
end $$;

-- from_hypertable runs in two phases, exposed as separate procedures so writes can keep arriving between
-- them: from_hypertable_copy does the online bulk copy to a watermark, then from_hypertable_cutover catches
-- up the rows that arrived after it, swaps the copy into place, and hands off to transmute. from_hypertable
-- runs both back to back for the one-shot case. All are procedures because the copy commits per chunk
-- (bounded WAL/txn on a large table) and the cutover commits the swap.

-- Phase 1: build the plain destination and bulk-copy the existing chunks into it, online. The source keeps
-- serving traffic (new appends are caught up by the cutover). Leaves <rel>_pgpm_dest populated; the copy
-- watermark is implicitly max(control) in the destination.
create or replace procedure pgpm.from_hypertable_copy(
  p_hypertable regclass, p_control name, p_track_changes boolean default false
)
language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols_q text; r record;
  v_delta name; v_trgfn name; v_trg name; v_keyidx oid; v_keycols_q text; v_newvals_q text; v_oldvals_q text;
  v_keyconname name; v_keytmp text;
  v_ctl_typid regtype; v_bound_tpl text; v_lo text; v_hi text;
begin
  perform pgpm.from_hypertable_preflight(p_hypertable, p_control);
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped
      and attgenerated = '';   -- omit generated columns: they recompute on insert, never inserted into

  -- The chunk-bound rendering for the dimension's type (see the chunk loop below for why each form is what
  -- it is). Resolved and refused HERE, before anything commits: the tracking apparatus and the destination
  -- skeleton both commit, and a refusal after either would strand an empty <rel>_pgpm_dest for the cutover
  -- to find and rename into place.
  select a.atttypid into v_ctl_typid
    from pg_attribute a where a.attrelid = p_hypertable and a.attname = p_control and not a.attisdropped;
  v_bound_tpl := case v_ctl_typid
    when 'timestamp with time zone'::regtype    then '%L::timestamptz'
    when 'timestamp without time zone'::regtype then '(%L::timestamptz at time zone ''UTC'')'
    when 'date'::regtype                        then '(%L::timestamptz at time zone ''UTC'')::date'
  end;
  if v_bound_tpl is null then
    raise exception 'pg_partition_magician: from_hypertable_copy(%) cannot bound the chunk copy on dimension % of type %: only timestamptz, timestamp and date dimensions are supported',
      p_hypertable, p_control, v_ctl_typid;
  end if;

  -- change tracking (p_track_changes): install an AFTER-ROW trigger on the source BEFORE the copy reads
  -- anything, so every insert/update/delete during the online window is logged by its key into a delta
  -- table. The cutover reconciles those keys against the live source. Reconciliation is by key, so this
  -- needs a key -- the same one transmute reuses: the PRIMARY KEY, else a UNIQUE constraint. A keyless
  -- table has no key to reconcile by, so tracking is refused (rather than silently losing updates/deletes).
  if p_track_changes then
    select coalesce(
             (select i.indexrelid from pg_index i where i.indrelid = p_hypertable and i.indisprimary limit 1),
             (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
               where con.conrelid = p_hypertable and con.contype = 'u'
                 and i.indpred is null and i.indexprs is null limit 1))
      into v_keyidx;
    if v_keyidx is null then
      raise exception 'pg_partition_magician: from_hypertable_copy(%, p_track_changes => true) needs a key to reconcile changes by, but the table has no primary key or unique constraint. Drop p_track_changes to migrate it append-only, or add a key first.',
        p_hypertable;
    end if;
    -- the key columns, and the NEW./OLD. value lists the trigger logs, in key order
    select string_agg(quote_ident(a.attname), ', ' order by k.ord),
           string_agg('new.' || quote_ident(a.attname), ', ' order by k.ord),
           string_agg('old.' || quote_ident(a.attname), ', ' order by k.ord)
      into v_keycols_q, v_newvals_q, v_oldvals_q
      from pg_index i
      cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
     where i.indexrelid = v_keyidx;

    -- Reconciliation matches keys with a row-constructor IN, which never matches a NULL component -- so a
    -- key row with a NULL in any non-control key column could never be reconciled and its change would be
    -- silently lost (both online and under the lock). PK columns are NOT NULL, but a reused UNIQUE key may
    -- have nullable columns; refuse tracking up front rather than lose changes.
    if exists (select 1 from pg_index i
                 cross join lateral unnest(i.indkey) as k(attnum)
                 join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
                where i.indexrelid = v_keyidx and not a.attnotnull and a.attname <> p_control) then
      raise exception 'pg_partition_magician: from_hypertable_copy(%, p_track_changes => true) cannot track by a key with a nullable column -- a NULL key component can never be reconciled (the change would be lost). Add NOT NULL to the key column(s), or drop p_track_changes to migrate append-only.',
        p_hypertable;
    end if;

    v_delta := v_rel || '_pgpm_delta';
    v_trgfn := v_rel || '_pgpm_delta_fn';
    v_trg   := v_rel || '_pgpm_delta_trg';
    execute format('drop table if exists %I.%I', v_nsp, v_delta);
    -- delta holds just the key columns (their types come from the source via WITH NO DATA)
    execute format('create table %I.%I as select %s from %I.%I with no data',
                   v_nsp, v_delta, v_keycols_q, v_nsp, v_rel);
    -- Append a monotonic ordering column (highest attnum) so the online delta-drain (from_hypertable_drain_delta,
    -- issue #170) can batch by a pgpm_seq watermark: a batch processes+deletes rows with pgpm_seq <= watermark,
    -- and any change that arrives mid-batch lands at a higher seq for the next pass. The cutover's key
    -- introspection EXCLUDES pgpm_seq by name so it is not mistaken for a key column; the trigger inserts only
    -- the key columns (by an explicit list), so identity auto-populates pgpm_seq. Indexed so the watermark
    -- offset/limit and the range delete are index-assisted at scale.
    execute format('alter table %I.%I add column pgpm_seq bigint generated always as identity', v_nsp, v_delta);
    execute format('create index on %I.%I (pgpm_seq)', v_nsp, v_delta);
    -- the trigger body is dollar-quoted with a pgpm tag; the format template is single-quoted (inner quotes
    -- doubled) to avoid nesting another dollar-quoted string inside this procedure body.
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
      v_nsp, v_trgfn,
      v_nsp, v_delta, v_keycols_q, v_oldvals_q,
      v_nsp, v_delta, v_keycols_q, v_oldvals_q, v_newvals_q,
      v_nsp, v_delta, v_keycols_q, v_newvals_q);
    execute format('drop trigger if exists %I on %I.%I', v_trg, v_nsp, v_rel);
    execute format('create trigger %I after insert or update or delete on %I.%I for each row execute function %I.%I()',
                   v_trg, v_nsp, v_rel, v_nsp, v_trgfn);
    -- The trigger is origin-only, and cannot be anything else: TimescaleDB refuses ENABLE ALWAYS on a
    -- hypertable and on its chunks, so a write under session_replication_role = replica never reaches the
    -- delta, and an UPDATE changes no count for the cutover's conservation check to see (#654). Record the
    -- xmin horizon of a snapshot taken HERE, before any chunk is read: a source row version older than it
    -- was committed before every chunk copy's snapshot, so the copy holds it as it is. The cutover checks
    -- every row version at or past it against the reconciled destination and refuses the swap on one the
    -- destination does not hold. Kept on the delta itself, which every copy drops and rebuilds, so the
    -- horizon and the apparatus it vouches for always come from the same copy. It is also the module's
    -- record that this delta, its function and its trigger are pgpm's: pgpm_core/uninstall.sql finds a
    -- copy that was never cut over by this comment, not by a name pattern (#737), so keep the two in step.
    execute format('comment on table %I.%I is %L', v_nsp, v_delta,
                   'pgpm from_hypertable horizon ' || pg_snapshot_xmin(pg_current_snapshot())::text);
    commit;   -- the apparatus must survive the phase boundary (copy commits, cutover reads the delta)
  end if;

  -- destination skeleton: structure but no indexes/key, so the bulk load maintains no per-row index.
  execute format('drop table if exists %I.%I', v_nsp, v_dest);
  execute format('create table %I.%I (like %I.%I including defaults including constraints including generated including comments)',
                 v_nsp, v_dest, v_nsp, v_rel);
  commit;

  -- online chunk-bounded copy: one chunk-range per transaction (the time predicate drives chunk exclusion
  -- to a single-chunk read; ORDER BY the control column clusters the destination for cheap transmute/regrain
  -- later). The source keeps serving traffic throughout.
  --
  -- The bounds are rendered in the dimension's OWN type (#459). timescaledb_information.chunks shows every
  -- time dimension's range_start/range_end as timestamptz: the slice's raw microseconds handed to
  -- _timescaledb_functions.to_timestamp(bigint), for a timestamp (no tz) or date dimension exactly as for a
  -- timestamptz one. Spliced with a bare %L, that instant rendered in the SESSION TimeZone
  -- ('2024-01-01 09:00:00+09' under Asia/Tokyo) and, coerced to a timestamp column, DROPPED the offset, so
  -- every chunk range shifted by the UTC offset. East of UTC the oldest chunk's first N hours fell below the
  -- union of the ranges and no chunk copied them, and the cutover's > max(dest) catch-up cannot reach rows
  -- below its watermark, so they were gone after the migration. West of UTC the last chunk's tail was missed
  -- and rescued by the catch-up only by accident, and a date dimension lost its last day.
  --   timestamptz  %L::timestamptz                            the literal carries its offset, so it is exact
  --   timestamp    (%L::timestamptz at time zone 'UTC')       the view is the raw value rendered AS a UTC
  --                                                           instant (to_timestamp_without_timezone is the
  --                                                           same C function with a timestamp result), so
  --                                                           converting back AT UTC returns the exact
  --                                                           wall-clock value the chunk's own CHECK names
  --   date         (%L::timestamptz at time zone 'UTC')::date the same, to the day
  -- Verified against pg_get_constraintdef of the chunk's dimension CHECK. Each is a constant expression, so
  -- the planner still folds it and excludes the other chunks. Any other dimension type has a NULL
  -- range_start in the view (an integer dimension reports range_start_integer instead), and the old
  -- predicate would have copied nothing at all; v_bound_tpl was resolved, and such a dimension refused,
  -- up top before anything committed.
  for r in select range_start, range_end from timescaledb_information.chunks
            where hypertable_schema = v_nsp and hypertable_name = v_rel order by range_start loop
    v_lo := format(v_bound_tpl, r.range_start);
    v_hi := format(v_bound_tpl, r.range_end);
    execute format('insert into %I.%I (%s) select %s from %I.%I where %I >= %s and %I < %s order by %I',
                   v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel,
                   p_control, v_lo, p_control, v_hi, p_control);
    commit;
  end loop;
  -- The destination was just CREATE TABLE LIKE'd and bulk-loaded, so it has no planner stats (reltuples=0).
  -- ANALYZE it now -- while it is still private and unlocked -- so the cutover's delta reconcile plans
  -- against the real row count. Without this the planner thinks the dest is empty and seqscans the whole
  -- table for the reconcile, making the (locked) cutover O(rows) instead of O(delta). pgpm._analyze is the
  -- core's shared mint-then-populate ANALYZE helper (#164).
  perform pgpm._analyze(format('%I.%I', v_nsp, v_dest)::regclass);
  commit;

  -- OUTGOING foreign keys (issue #264). `CREATE TABLE ... LIKE ... INCLUDING CONSTRAINTS` copies CHECK and
  -- NOT NULL only -- no INCLUDING option copies foreign keys -- and nothing later added them, so the source
  -- hypertable was the only relation still holding them and the cutover DROPS it. The migration therefore
  -- used to lose referential integrity silently: no error, nothing in pgpm.log, and orphan rows accepted
  -- afterwards in every partition.
  --
  -- Replayed VERBATIM from pg_get_constraintdef, which carries composite keys, referential actions and
  -- DEFERRABLE-ness without pgpm having to reason about any of them. The destination reaches the cutover
  -- holding a VALIDATED key, so the swap stays metadata-only and the parent-level ADD adopts it.
  --
  -- Two steps in two transactions, and this is the reason the work lives HERE rather than in the cutover: a
  -- validating ADD CONSTRAINT ... FOREIGN KEY holds SHARE ROW EXCLUSIVE on the REFERENCED table for the
  -- whole scan, blocking writes on a table the operator did not ask us to lock. Splitting it means
  -- VALIDATE holds only SHARE UPDATE EXCLUSIVE here and ROW SHARE there, so the referenced table stays
  -- writable. The cutover could not do this at all: its pre-build block shares one transaction with the
  -- swap, so the lock would span the swap. O(rows) work belongs in the copy phase, which is exactly why
  -- the index pre-build lives here too.
  for r in
    select c.conname, pg_get_constraintdef(c.oid) as def
      from pg_constraint c
     where c.conrelid = p_hypertable and c.contype = 'f' and c.confrelid <> p_hypertable
     order by c.conname
  loop
    execute format('alter table %I.%I add constraint %I %s not valid', v_nsp, v_dest, r.conname, r.def);
    commit;
    execute format('alter table %I.%I validate constraint %I', v_nsp, v_dest, r.conname);
    commit;
    insert into pgpm.log (parent_table, action, method)
      values (p_hypertable, 'from_hypertable_carry_fk', r.conname);
  end loop;

  -- #175: when change-tracking is on, build the reused-key index on the dest NOW -- off the lock, while the
  -- dest is still private -- with the SAME temp name and definition the cutover will ADOPT
  -- (_from_hypertable_tmp_name, built by _from_hypertable_index_ddl: #707, #735). The online delta drain then
  -- uses it for its per-batch key lookups (no separate throwaway index), and the cutover adopts it instead of
  -- rebuilding it -- one key-index build instead of two. (v_keyidx was chosen above for tracking; tracking is
  -- refused on a keyless table, so it is always set here.)
  if p_track_changes then
    select conname into v_keyconname from pg_constraint where conindid = v_keyidx;
    v_keytmp := pgpm._from_hypertable_tmp_name(v_keyconname, v_keyidx);
    execute pgpm._from_hypertable_index_ddl(v_keyidx, v_keytmp, v_nsp, v_dest);
    commit;
  end if;
end $$;

-- Online delta drain (issue #170): reconcile the change-capture delta in bounded micro-batches WHILE the
-- source stays live, BEFORE the cutover takes its lock, so the locked window applies only a tiny residual
-- instead of the whole online-copy backlog. The reconcile is idempotent and order-independent per key (drop
-- the key's copied row from the dest, reinsert its current source row -- a deleted key stays absent, an
-- updated key gets its current value, an inserted key appears), which is exactly what makes incremental
-- draining safe: partial progress is always consistent, and any key can be reconciled more than once with no
-- effect. New writes keep appending to the delta during the drain; we chase the backlog down. The final
-- (tiny) residual is applied by the cutover under the brief lock, which is the correctness backstop.

-- from_hypertable_drain_delta_step does ONE micro-batch (no commit; the driver commits per batch). It
-- delete-RETURNS the batch's distinct keys from the delta as the authority and reconciles EXACTLY those keys
-- against the live source: a key the batch does not see (e.g. a write still in flight) is simply left in the
-- delta for the next batch or the under-lock final reconcile, so a change is never deleted-without-applying
-- (the read-then-delete race a two-snapshot approach would have). The batch is bounded by a pgpm_seq
-- watermark; the source read is bounded to the batch's control [min,max] as literal constants so TimescaleDB
-- excludes untouched chunks -- per-batch, even tighter than the one-shot reconcile (#166). Returns the number
-- of distinct keys reconciled this batch (0 = the delta is empty).
create or replace function pgpm.from_hypertable_drain_delta_step(
  p_hypertable regclass, p_control name, p_batch int default 5000
) returns bigint language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_delta name;
  v_keycols_q text; v_dkey_q text; v_skey_q text; v_cols_q text;
  v_ctl_type text; v_min_ctl text; v_max_ctl text; v_watermark bigint; v_keys bigint;
begin
  perform pgpm._from_hypertable_check_names(p_hypertable);   -- #552: before any DDL
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  v_delta := v_rel || '_pgpm_delta';
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then
    raise exception 'pg_partition_magician: from_hypertable_drain_delta_step(%) found no delta -- change tracking was not enabled by from_hypertable_copy', p_hypertable;
  end if;

  -- key columns = every delta column EXCEPT the pgpm_seq ordering column, in attnum order (the same order
  -- the cutover uses, so the row constructors line up). d./s. variants for the dest delete + source insert.
  select string_agg(quote_ident(attname), ', ' order by attnum),
         '(' || string_agg('d.' || quote_ident(attname), ', ' order by attnum) || ')',
         '(' || string_agg('s.' || quote_ident(attname), ', ' order by attnum) || ')'
    into v_keycols_q, v_dkey_q, v_skey_q
    from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
      and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';
  -- the source/dest column list for the reinsert (generated columns omitted: they recompute on insert)
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped and attgenerated = '';

  -- the dest's per-batch delete uses the reused-key index that from_hypertable_copy built on the dest (#175,
  -- the same index the cutover adopts); no separate throwaway index is built here.

  -- batch boundary: the pgpm_seq of the p_batch-th oldest delta row (or max when fewer remain)
  execute format('select coalesce((select pgpm_seq from %I.%I order by pgpm_seq offset %s limit 1), (select max(pgpm_seq) from %I.%I))',
                 v_nsp, v_delta, greatest(p_batch - 1, 0), v_nsp, v_delta) into v_watermark;
  if v_watermark is null then return 0; end if;   -- delta empty

  -- materialize this batch's distinct keys authoritatively by DELETING them: delete-returning is the source
  -- of truth, so we reconcile exactly what we removed (no delete-without-apply race). on commit drop: the
  -- driver commits after each batch (dropping it), a standalone call drops it at autocommit; the drop-if-
  -- exists first guards the rare same-transaction re-call.
  execute 'drop table if exists pgpm_dbatch';
  execute format('create temp table pgpm_dbatch on commit drop as
                  with d as (delete from %I.%I where pgpm_seq <= %s returning %s)
                  select distinct %s from d',
                 v_nsp, v_delta, v_watermark, v_keycols_q, v_keycols_q);
  get diagnostics v_keys = row_count;

  -- bound the source read to the batch's touched control range, as literal constants, for chunk exclusion
  select format_type(atttypid, atttypmod) into v_ctl_type
    from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
  execute format('select min(%I)::text, max(%I)::text from pgpm_dbatch', p_control, p_control)
    into v_min_ctl, v_max_ctl;

  -- reconcile: drop the batch's keys from the dest, then reinsert their current source rows
  execute format('delete from %I.%I d where %s in (select %s from pgpm_dbatch)', v_nsp, v_dest, v_dkey_q, v_keycols_q);
  if v_min_ctl is not null then
    execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (select %s from pgpm_dbatch) and %I >= %L::%s and %I <= %L::%s',
                   v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel, v_skey_q, v_keycols_q,
                   p_control, v_min_ctl, v_ctl_type, p_control, v_max_ctl, v_ctl_type);
  else
    execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (select %s from pgpm_dbatch)',
                   v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel, v_skey_q, v_keycols_q);
  end if;
  return v_keys;
end $$;

-- from_hypertable_drain_delta loops the step with a per-batch COMMIT (so WAL recycles -- the same reason
-- from_hypertable_copy commits per chunk), mirroring drain_all's _step + _all shape. It chases the backlog
-- down until the residual is at/below p_threshold (0 = drain to empty), tested cheaply with an EXISTS at
-- offset (like drain_step's EXISTS-not-count). Under sustained write load the residual may never reach the
-- threshold; p_max_iter bounds the loop -- it raises a loud, actionable error UNLESS p_best_effort, in which
-- case it returns so the caller (the cutover) can take the lock and finish the now-smaller residual under it.
-- The per-batch dest delete uses the reused-key index from_hypertable_copy built on the dest (#175) -- the
-- same index the cutover adopts -- so the drain builds no index of its own.
create or replace procedure pgpm.from_hypertable_drain_delta(
  p_hypertable regclass, p_control name, p_batch int default 5000,
  p_threshold bigint default 0, p_max_iter int default 1000000, p_best_effort boolean default false
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_delta name;
  v_iter int := 0; v_more boolean;
begin
  perform pgpm._from_hypertable_check_names(p_hypertable);   -- #552: before any DDL
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  v_delta := v_rel || '_pgpm_delta';
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then
    raise exception 'pg_partition_magician: from_hypertable_drain_delta(%) found no delta -- change tracking was not enabled by from_hypertable_copy', p_hypertable;
  end if;

  loop
    -- residual <= threshold? EXISTS at offset stops at the first row past the threshold (count > threshold)
    execute format('select exists(select 1 from %I.%I order by pgpm_seq offset %s limit 1)',
                   v_nsp, v_delta, p_threshold) into v_more;
    exit when not v_more;
    perform pgpm.from_hypertable_drain_delta_step(p_hypertable, p_control, p_batch);
    commit;
    v_iter := v_iter + 1;
    if v_iter > p_max_iter then
      if p_best_effort then return; end if;
      raise exception 'pg_partition_magician: from_hypertable_drain_delta(%) did not converge within % iterations -- the workload is dirtying keys faster than the drain clears them. Raise p_batch, raise p_threshold to accept a larger final cutover batch, or pause writes before cutting over.',
        p_hypertable, p_max_iter;
    end if;
  end loop;
end $$;

-- Append-only online pre-drain (issue #174). The non-tracking catch-up (the cutover's append-only branch)
-- copies every row appended past the copy watermark, which grows with the copy duration -- so the locked
-- window grows with the migration, the same wound #170 closed for the tracking path. Pre-drain that tail
-- ONLINE, in bounded batches that advance the watermark, so the locked catch-up applies only the final tail.
-- Simpler than the delta drain: append-only means already-copied rows never change, so it is purely additive
-- -- no delta, no reconcile, no key, no dest index, and no race (the watermark marches forward; an append
-- that lands mid-batch has a higher control value and is taken next pass). It assumes the append-only
-- contract (no updates/deletes to copied rows, and appends arriving in control order), exactly as the
-- under-lock catch-up already does -- use p_track_changes for update/delete workloads and for any
-- workload that can append out of order. What arrives behind the watermark is invisible here and to the
-- under-lock catch-up alike; the cutover's conservation check (#460) refuses the swap rather than lose it.

-- _from_hypertable_past: the predicate "p_control is past the copy watermark", for the append-only catch-ups
-- (the pre-drain, its step, and the cutover's own). p_type casts the watermark literal when given;
-- p_inclusive makes the bound >= (the cutover's keyed catch-up, which anti-joins the tie at the watermark).
-- A NULL watermark is what an EMPTY copy leaves (the hypertable had no rows at from_hypertable_copy), and it
-- means every row is past it (#736). It used to read as "nothing to catch up": the pre-drain returned at
-- once and the cutover skipped its catch-up, so every row appended in order after the copy stayed out of
-- the destination, and the conservation check refused the swap, blaming rows at or below a watermark that
-- does not exist. One helper, so the three catch-ups cannot disagree about it.
create or replace function pgpm._from_hypertable_past(
  p_control name, p_watermark text, p_type text default null, p_inclusive boolean default false
) returns text language sql immutable as $$
  select case when p_watermark is null then 'true'   -- #736: nothing was copied, so every row is past it
              else format('%I %s %L%s', p_control, case when p_inclusive then '>=' else '>' end, p_watermark,
                          coalesce('::' || p_type, ''))
         end
$$;

-- from_hypertable_drain_appends_step copies ONE batch of appends past p_watermark and returns the new
-- watermark (the batch's upper control bound, as text); no commit (the driver commits per batch). The batch
-- is bounded to ~p_batch rows by the control value p_batch rows past the watermark, INCLUSIVE of ties at that
-- bound (a row-count LIMIT with a strict > would drop ties straddling the boundary, the next pass skipping
-- them). Bounds are LITERAL constants so TimescaleDB excludes untouched chunks. A NULL p_watermark is the
-- watermark of an empty copy (#736): nothing was copied, so every row is past it, and the batch starts at
-- the source's first row.
create or replace function pgpm.from_hypertable_drain_appends_step(
  p_hypertable regclass, p_control name, p_batch int, p_watermark text
) returns text language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols_q text; v_ctl_type text; v_hi text;
  v_past text;   -- the predicate "past the watermark", over p_control
begin
  perform pgpm._from_hypertable_check_names(p_hypertable);   -- #552: before any DDL
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  select format_type(atttypid, atttypmod) into v_ctl_type
    from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped and attgenerated = '';

  v_past := pgpm._from_hypertable_past(p_control, p_watermark, v_ctl_type);

  -- the batch's upper control bound: the control value p_batch rows past the watermark (or the source's max
  -- past it when fewer remain). The <= insert below includes ALL rows at this value, so no tie is split.
  execute format('select coalesce(
                    (select %I::text from %I.%I where %s order by %I offset %s limit 1),
                    (select max(%I)::text from %I.%I where %s))',
                 p_control, v_nsp, v_rel, v_past, p_control, greatest(p_batch - 1, 0),
                 p_control, v_nsp, v_rel, v_past) into v_hi;
  if v_hi is null then return p_watermark; end if;   -- nothing past the watermark

  execute format('insert into %I.%I (%s) select %s from %I.%I where %s and %I <= %L::%s order by %I',
                 v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel,
                 v_past, p_control, v_hi, v_ctl_type, p_control);
  return v_hi;
end $$;

-- from_hypertable_drain_appends loops the step with a per-batch COMMIT (WAL recycles), mirroring drain_all
-- and from_hypertable_drain_delta (#170). It carries the watermark across batches (the dest's max control,
-- read once up front, then advanced by each step) so it never re-scans the dest for max(). Stops when the
-- residual past the watermark is at/below p_threshold (EXISTS at offset, chunk-excluded). p_max_iter bounds
-- the loop -- raises a loud error UNLESS p_best_effort, in which case it returns so the caller (the cutover)
-- finishes the residual under the lock.
create or replace procedure pgpm.from_hypertable_drain_appends(
  p_hypertable regclass, p_control name, p_batch int default 5000,
  p_threshold bigint default 0, p_max_iter int default 1000000, p_best_effort boolean default false
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_ctl_type text; v_watermark text; v_more boolean; v_iter int := 0;
begin
  perform pgpm._from_hypertable_check_names(p_hypertable);   -- #552: before any DDL
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  if to_regclass(format('%I.%I', v_nsp, v_dest)) is null then
    raise exception 'pg_partition_magician: from_hypertable_drain_appends(%) found no copy to drain -- run from_hypertable_copy first', p_hypertable;
  end if;
  select format_type(atttypid, atttypmod) into v_ctl_type
    from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
  -- the initial frontier: the copy watermark (max control in the dest). Read once; each step advances it.
  -- NULL when nothing was copied, which puts every source row past it (#736, _from_hypertable_past).
  execute format('select max(%I)::text from %I.%I', p_control, v_nsp, v_dest) into v_watermark;
  loop
    -- residual past the watermark <= threshold? EXISTS at offset (chunk-excluded by control > watermark)
    execute format('select exists(select 1 from %I.%I where %s order by %I offset %s limit 1)',
                   v_nsp, v_rel, pgpm._from_hypertable_past(p_control, v_watermark, v_ctl_type),
                   p_control, p_threshold) into v_more;
    exit when not v_more;
    v_watermark := pgpm.from_hypertable_drain_appends_step(p_hypertable, p_control, p_batch, v_watermark);
    commit;
    v_iter := v_iter + 1;
    if v_iter > p_max_iter then
      if p_best_effort then return; end if;
      raise exception 'pg_partition_magician: from_hypertable_drain_appends(%) did not converge within % iterations -- appends are arriving faster than the drain copies them. Raise p_batch, raise p_threshold to accept a larger final cutover batch, or pause writes before cutting over.',
        p_hypertable, p_max_iter;
    end if;
  end loop;
end $$;

-- Phase 2: the cutover (the one non-online window). ACCESS EXCLUSIVE on the source, waited for no longer
-- than p_lock_timeout (default '5s', transmute's own default, #309 and #665), so a long reader of the
-- hypertable makes the cutover give up and leave everything as it was, to be re-run; an append-only
-- catch-up of rows that arrived after the copy watermark (control >= max copied with a key anti-join on
-- a keyed table, control > max copied on a keyless one); a conservation check that refuses the swap
-- unless the source holds the same rows as the destination, by count AND by a content fingerprint of
-- every row (#460, #653); drop the hypertable
-- (Timescale's event trigger clears its chunks and catalog); rename the copy into place; rebuild the key,
-- secondary indexes, and identity columns (CREATE TABLE LIKE carries none of those) with their original
-- names; then hand off to transmute. The swap + rebuild is one transaction (commits whole or rolls back
-- whole). When the caller leaves p_retain null, the source's drop_chunks policy interval is carried into
-- pgpm's retain. Requires from_hypertable_copy to have run (the destination must exist).
drop procedure if exists pgpm.from_hypertable_cutover(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean);
-- #665 added p_lock_timeout, which CHANGES THE ARGUMENT COUNT: CREATE OR REPLACE does not replace across
-- that, so the previous form must go or both overloads survive and every call becomes ambiguous.
drop procedure if exists pgpm.from_hypertable_cutover(regclass, name, interval, int, interval, int, timestamptz, boolean, boolean);
-- #792 added p_force_frontier, passed through to transmute: the same arg-count hazard again.
drop procedure if exists pgpm.from_hypertable_cutover(regclass, name, interval, int, interval, int, timestamptz, boolean, boolean, text);
create or replace procedure pgpm.from_hypertable_cutover(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_predrain boolean default true,
  p_lock_timeout text default '5s', p_force_frontier boolean default false
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols_q text; v_retain interval;
  v_watermark timestamptz; v_orig regclass; k record;
  v_delta name; v_trgfn name; v_track boolean; v_keycols_q text; v_dkey_q text; v_skey_q text; v_subsel_q text;
  v_ctl_type text; v_min_ctl text; v_max_ctl text;
  v_ident_cols name[]; v_ident_kinds text[]; v_ident_opts text[]; v_ident_next numeric[]; v_srcseq regclass;
  v_pseq regclass; v_i int;
  v_tmp text; v_key_names text[]; v_key_types text[]; v_key_tmps text[]; v_idx_orig text[]; v_idx_tmps text[];
  v_in_names text[];     -- incoming FKs the swap dropped and recorded (#264, #563)
  v_dest_oid regclass;   -- which relation the destination check found, re-verified under lock (#422)
  v_akey oid;            -- the key the append-only catch-up anti-joins by; null on a keyless table (#460)
  v_src_n bigint; v_dest_n bigint; v_n bigint;   -- conservation: source count under lock vs dest baseline + catch-up (#460)
  -- the untracked-write check on the tracking path (#654): the copy's recorded horizon, the predicates it
  -- builds, the source and destination column rows it compares, and what it found
  v_horizon bigint; v_fresh text; v_nomatch_q text; v_scols_q text; v_dcols_q text;
  v_unmatched bigint; v_m bigint; v_kt text; v_first_key text; v_fresh_batch boolean;
  v_src_h numeric; v_dest_h numeric; v_h numeric; -- ...and the same for the content fingerprint, the rows' identity (#653)
  v_fp_q text;           -- the per-row fingerprint expression, over the quoted column list (#653)
  v_prev_lock_timeout text;   -- #665: so validating p_lock_timeout leaves the setting untouched
  v_carried_ddl text[];       -- #787: what LIKE left behind (owner, grants, RLS, policies, comment, triggers)
  v_stmt text;
begin
  -- #665: validate the lock timeout HERE, before the pre-drain commits anything or the index pre-builds
  -- spend their O(rows), exactly as transmute validates its own (#309). The prior value is restored at
  -- once, so the check has no side effect and the set_config at the swap is what applies the bound.
  begin
    v_prev_lock_timeout := current_setting('lock_timeout');
    perform set_config('lock_timeout', p_lock_timeout, true);
    perform set_config('lock_timeout', v_prev_lock_timeout, true);
  exception when others then
    raise exception 'pg_partition_magician: p_lock_timeout must be a valid lock_timeout value (got %): %', p_lock_timeout, sqlerrm;
  end;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  perform pgpm._from_hypertable_check_names(p_hypertable);   -- #552: before any DDL
  -- ...and the monolith name transmute will derive after the swap has committed (#707), before the pre-drain
  perform pgpm._from_hypertable_check_handoff(p_hypertable, p_interval, p_anchor);
  -- The dimension facts the copy depended on are re-checked HERE, in the irreversible phase (issue #458).
  -- This procedure used to require only that a destination exist, and a destination left by a copy that
  -- ran under an older version, or made by hand, reaches the DROP below without preflight ever having run.
  -- Only the two dimension checks, not the whole preflight: its disk and time NOTICEs describe a copy that
  -- has already happened, and its foreign-key eligibility was settled before that copy did any work.
  perform pgpm._from_hypertable_check_dimension(p_hypertable, p_control);
  -- ...and an EXCLUDE constraint, for the same reason (issue #675): the swap below would drop it silently.
  perform pgpm._from_hypertable_check_exclusion(p_hypertable);
  -- Keep the OID this check resolved, not just the fact that something answered (#422). The swap
  -- below renames this relation INTO the source's name, so it is the half of the swap that ends with
  -- a relation BECOMING the production table -- and between here and there the destination is
  -- unlocked (nothing takes a lock on it until the first index pre-build, and the pre-drain's
  -- per-batch commits release even that). Verified under lock at the swap.
  v_dest_oid := to_regclass(format('%I.%I', v_nsp, v_dest));
  if v_dest_oid is null then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) found no copy to cut over -- run from_hypertable_copy first',
      p_hypertable;
  end if;
  -- #738: the copy's shape against the source's, up front, so DDL made since the copy is refused by name
  -- before the pre-drain and the index pre-builds spend anything. Asked again under the lock below.
  perform pgpm._from_hypertable_check_shape(p_hypertable, v_dest_oid);
  -- auto-detect change tracking: the copy phase leaves a <rel>_pgpm_delta table iff p_track_changes was set,
  -- so the two phases cannot disagree about the catch-up mode (no matching flag to pass through).
  v_delta := v_rel || '_pgpm_delta';
  v_trgfn := v_rel || '_pgpm_delta_fn';
  v_track := to_regclass(format('%I.%I', v_nsp, v_delta)) is not null;

  -- retention translation: default from the source's drop_chunks policy when the caller did not set one
  v_retain := p_retain;
  if v_retain is null then
    select (config->>'drop_after')::interval into v_retain from timescaledb_information.jobs
     where proc_name = 'policy_retention' and hypertable_schema = v_nsp and hypertable_name = v_rel limit 1;
  end if;
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped
      and attgenerated = '';   -- omit generated columns: they recompute on insert, never inserted into
  -- The conservation check's per-row fingerprint (#653): a 64-bit hash of the row's text rendering over
  -- exactly the columns the copy moves, summed (as numeric, so it cannot overflow) into an order-free
  -- fingerprint of the multiset of rows. A count alone is invariant under compensating changes: a copied
  -- row deleted and a row appended behind the watermark during the online window left 72 = 72, and the
  -- swap dropped the late row and resurrected the deleted one. The sum moves by h(added) - h(removed), so
  -- it cancels only on a 64-bit hash collision, and a keyless table's legitimate duplicate rows each count
  -- (a sum, not an XOR). Both sides are rendered by this one session inside this one procedure call, so
  -- the text of equal values is equal whatever DateStyle, TimeZone or extra_float_digits says.
  v_fp_q := format('hashtextextended(row(%s)::text, 0)', v_cols_q);

  -- Pre-drain (#170): when change-tracking is on, reconcile the delta ONLINE in micro-batches before taking
  -- the lock, so the locked final reconcile below applies only a tiny residual instead of the whole
  -- online-copy backlog. Best-effort: if the workload outruns the drain it returns and the under-lock
  -- reconcile finishes whatever is left -- correctness never depends on the pre-drain. p_drain_batch sizes
  -- both the micro-batch and the residual threshold (stop online once the residual is within one batch).
  -- (Commits per batch; the swap transaction below starts fresh after it.)
  if p_predrain and v_track then
    call pgpm.from_hypertable_drain_delta(p_hypertable, p_control, p_drain_batch, p_drain_batch,
                                          1000000, p_best_effort => true);
  elsif p_predrain and not v_track then
    -- append-only path: pre-drain the post-watermark tail online too (#174), so the under-lock catch-up
    -- below applies only the final tail instead of the whole copy's worth of appends.
    call pgpm.from_hypertable_drain_appends(p_hypertable, p_control, p_drain_batch, p_drain_batch,
                                            1000000, p_best_effort => true);
  end if;
  -- #665: bound every lock wait of the swap transaction, which starts here (the pre-drain's last COMMIT
  -- ended the one before, and `set local` does not survive a COMMIT). The one that matters is the LOCK
  -- TABLE ... ACCESS EXCLUSIVE on the live hypertable below: unbounded, it queued behind any long reader,
  -- and a PENDING ACCESS EXCLUSIVE blocks every later read and write of the table for as long as that
  -- reader lives. The same bound covers the incoming-FK drops' locks on each referencing table. A timeout
  -- aborts the swap whole, before anything irreversible: the hypertable, the copy and every drained batch
  -- are as they were, and re-running the cutover costs only the index pre-builds.
  perform set_config('lock_timeout', p_lock_timeout, true);
  -- Read the destination BEFORE the lock. It is private and stable from here to the lock (only CREATE INDEX
  -- runs, which does not change rows), so what is read here is what the under-lock work would read -- but
  -- reading it here keeps an O(rows) seqscan of the dest OUT of the locked window (#174). Two things, one
  -- scan: the append-only catch-up watermark (max control; new appends after this read have a higher
  -- control value and are still caught under the lock), and the CONSERVATION BASELINE (#460, #653):
  -- count(*) and the content fingerprint of the dest as it stands, which the catch-up below adjusts by
  -- exactly the rows it adds or removes (their RETURNING) so the check under the lock can compare the two
  -- sides without scanning the dest again.
  if not v_track then
    execute format('select count(*), coalesce(sum(%s), 0), max(%I) from %I.%I', v_fp_q, p_control, v_nsp, v_dest)
      into v_dest_n, v_dest_h, v_watermark;
  else
    execute format('select count(*), coalesce(sum(%s), 0) from %I.%I', v_fp_q, v_nsp, v_dest) into v_dest_n, v_dest_h;
  end if;
  -- The key the append-only catch-up anti-joins by (#460): the PRIMARY KEY, else a UNIQUE constraint, and
  -- every one of its columns NOT NULL -- a row-constructor `=` never matches a NULL component, so a
  -- nullable key could re-copy a watermark row it cannot recognise (the control column itself is NOT NULL
  -- on any hypertable). The same key from_hypertable_copy tracks by; the pre-build just below puts its
  -- index on the destination before the lock, so the probe is indexed. Null means keyless, and the
  -- catch-up keeps its strict `>` there (see the lock).
  if not v_track then
    select i.indexrelid into v_akey
      from pg_index i
      join pg_constraint con on con.conindid = i.indexrelid and con.contype in ('p', 'u')
     where i.indrelid = p_hypertable
       and not exists (select 1 from unnest(i.indkey) as kc(attnum)
                         join pg_attribute a on a.attrelid = i.indrelid and a.attnum = kc.attnum
                        where not a.attnotnull)
     order by con.contype = 'p' desc, con.conname
     limit 1;
    if v_akey is not null then
      -- (kc, not k: this procedure declares a record named k for its loops, and plpgsql would substitute it)
      select '(' || string_agg('d.' || quote_ident(a.attname), ', ' order by kc.ord) || ')',
             '(' || string_agg('s.' || quote_ident(a.attname), ', ' order by kc.ord) || ')'
        into v_dkey_q, v_skey_q
        from pg_index i
        cross join lateral unnest(i.indkey) with ordinality as kc(attnum, ord)
        join pg_attribute a on a.attrelid = i.indrelid and a.attnum = kc.attnum
       where i.indexrelid = v_akey;
    end if;
  end if;

  -- Pre-build the destination's indexes BEFORE taking the exclusive lock, while the destination is still a
  -- private table and the source keeps serving traffic. This is the O(rows) work; doing it OUTSIDE the lock
  -- is what keeps the cutover's ACCESS EXCLUSIVE window brief -- otherwise the PK + secondary index rebuilds
  -- on the whole table run under the lock (minutes of downtime at scale). Each index is built with a temp
  -- name (the source still owns the originals); the locked swap below then ADOPTS the unique ones as their
  -- original PK/UNIQUE constraints (ALTER TABLE ... USING INDEX -- metadata-only, and it renames the index to
  -- the constraint name) and RENAMES the remaining secondary indexes to their original names (metadata-only).
  -- Builds happen in the same transaction as the swap, so an aborted cutover rolls them back with everything.
  -- Names and definitions come from _from_hypertable_tmp_name and _from_hypertable_index_ddl (#707, #735):
  -- a temp name that fits whole, and the index's own name and table replaced by identity.
  for k in select conname, contype, conindid from pg_constraint
            where conrelid = p_hypertable and contype in ('p', 'u') loop
    v_tmp := pgpm._from_hypertable_tmp_name(k.conname, k.conindid);
    -- #175: skip the build if it already exists -- from_hypertable_copy pre-builds the reused-key index
    -- under this same name when tracking, so the drain can use it and the swap below adopts it. Other
    -- constraints (and the append-only / non-tracking path) are built here as before. Always record the
    -- conname -> temp-name mapping so the swap adopts every key index, copy-built or built here.
    if to_regclass(format('%I.%I', v_nsp, v_tmp)) is null then
      execute pgpm._from_hypertable_index_ddl(k.conindid, v_tmp, v_nsp, v_dest);
    end if;
    v_key_names := array_append(v_key_names, k.conname::text);
    v_key_types := array_append(v_key_types, k.contype::text);
    v_key_tmps  := array_append(v_key_tmps, v_tmp);
  end loop;
  for k in select ic.relname as origname, i.indexrelid from pg_index i join pg_class ic on ic.oid = i.indexrelid
            where i.indrelid = p_hypertable and not i.indisprimary
              and not exists (select 1 from pg_constraint con where con.conindid = i.indexrelid) loop
    v_tmp := pgpm._from_hypertable_tmp_name(k.origname, k.indexrelid);
    execute pgpm._from_hypertable_index_ddl(k.indexrelid, v_tmp, v_nsp, v_dest);
    v_idx_orig := array_append(v_idx_orig, k.origname::text);
    v_idx_tmps := array_append(v_idx_tmps, v_tmp);
  end loop;

  -- LOCK, THEN VERIFY (issue #422). Everything above resolved p_hypertable to a name pair ONCE, at
  -- the top, and a great deal happens before this line -- most expensively the index pre-builds,
  -- which are deliberately out here so the locked window stays brief, and which are therefore the
  -- longest stretch in which the name can stop meaning what it meant. LOCK TABLE freezes whatever a
  -- name means AT LOCK TIME, so locking by name is only half the pattern; without the other half the
  -- DROP below destroys a relation this procedure never identified.
  --
  -- Lock the OID, not the resolved name: p_hypertable::text renders the CURRENT name of the relation
  -- the caller passed, so the lock lands on the hypertable actually being cut over even if it has
  -- been renamed, and nothing can slip in between the lock and the check. THEN require the name to
  -- still resolve back to it. Once that holds, the name is pinned for the rest of the transaction --
  -- a rename needs ACCESS EXCLUSIVE, which this now holds -- so every later `%I.%I` on the source is
  -- safe by construction.
  --
  -- Aborts rather than adapting. There is no partial progress worth keeping: the swap is one
  -- transaction and rolls back whole, the online copy and any drained batches survive, and re-running
  -- the cutover once the name is sorted out costs only the index pre-builds. Adapting -- taking the
  -- source's new name and carrying on -- would silently migrate a table the operator did not name.
  execute format('lock table %s in access exclusive mode', p_hypertable::text);
  if to_regclass(format('%I.%I', v_nsp, v_rel)) is distinct from p_hypertable then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) resolved % .% at the start, but that name is oid % now -- something renamed or replaced the source while the cutover was preparing; refusing to drop a relation it did not identify. Re-run the cutover once the name is settled.',
      p_hypertable, quote_ident(v_nsp), quote_ident(v_rel),
      coalesce(to_regclass(format('%I.%I', v_nsp, v_rel))::oid::text, 'nothing');
  end if;

  -- The destination half of the same swap (#422). It is renamed INTO the source's name below, so an
  -- unverified one does not merely get dropped, it BECOMES the table. Lock it by the oid the
  -- existence check resolved and require the name to still mean that, for the same reason and with
  -- the same abort. What this does NOT cover, deliberately: a destination already substituted before
  -- this procedure was ever called. Nothing in this module records what from_hypertable_copy built,
  -- so there is no earlier identity to compare against -- that needs the module-wide oid recording
  -- #422 sketches, which this change does not do.
  execute format('lock table %s in access exclusive mode', v_dest_oid::text);
  if to_regclass(format('%I.%I', v_nsp, v_dest)) is distinct from v_dest_oid then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) found destination % .% as oid % at the start, but that name is oid % now -- something replaced the copy while the cutover was preparing; refusing to rename an unverified relation into %.',
      p_hypertable, quote_ident(v_nsp), quote_ident(v_dest), v_dest_oid::oid,
      coalesce(to_regclass(format('%I.%I', v_nsp, v_dest))::oid::text, 'nothing'), quote_ident(v_rel);
  end if;
  -- THE SHAPE, UNDER THE LOCK (#738). The check up front saw the source as it was then, and the source has
  -- been unlocked from there to here (the pre-drain's commits, the index pre-builds), so DDL can have landed
  -- in between. Both relations are frozen now, and the column list read at the top must still describe both.
  perform pgpm._from_hypertable_check_shape(p_hypertable, v_dest_oid);
  -- ...and two of transmute's refusals the source already shows (#792). Asked here rather than up front, for
  -- two reasons. Nothing can write the source now, so a row dated past the frontier bound, or a bare unique
  -- index, that arrived while the cutover prepared (the pre-drain's commits, the index pre-builds) is refused
  -- with the source whole, not by transmute after the swap. And the frontier's read of the source, made up
  -- front, would hold its ACCESS SHARE from there to here, through the window the online flow keeps open.
  -- The refusal rolls back the catch-up and the pre-builds with it; only a pre-drain's batches stay in the copy.
  perform pgpm._from_hypertable_check_key(p_hypertable, p_control);
  perform pgpm._from_hypertable_check_frontier(p_hypertable, p_control, p_interval, p_force_frontier);
  if v_track then
    -- change-tracking catch-up: reconcile every touched key against the now-frozen source. Delete each
    -- dirty key's copied version from the destination, then re-insert its current source row -- which is
    -- idempotent and order-independent, and covers inserts, updates, and deletes (a deleted key is simply
    -- absent from the source, so it stays gone). Subsumes the append-only catch-up below.
    select '(' || string_agg('d.' || quote_ident(attname), ', ' order by attnum) || ')',
           '(' || string_agg('s.' || quote_ident(attname), ', ' order by attnum) || ')',
           string_agg(quote_ident(attname), ', ' order by attnum)
      into v_dkey_q, v_skey_q, v_keycols_q
      from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
        and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';   -- exclude the ordering column (#170)
    v_subsel_q := format('select distinct %s from %I.%I', v_keycols_q, v_nsp, v_delta);
    -- The delta was just populated by the trigger, so it has no stats; ANALYZE it so the planner sizes
    -- the semi-joins correctly (the dest was already ANALYZEd at the end of the copy). Shared helper (#164).
    perform pgpm._analyze(format('%I.%I', v_nsp, v_delta)::regclass);
    -- Bound the source read to the delta's touched control-column range, as LITERAL constants, so
    -- TimescaleDB excludes untouched chunks at plan time -- the reconcile then reads only the chunks that
    -- actually changed, not the whole hypertable. (A min()/max() subquery is a runtime value and does NOT
    -- prune; only constants do.) This is what keeps the locked cutover O(delta), not O(rows): in-flight
    -- changes are time-clustered (an OLTP workload mostly touches recent rows), so the range is a handful of
    -- chunks. SAFE in general: every delta key's control value lies within [min,max] by construction, so no
    -- needed source row can be excluded -- the worst case (changes spanning all history) just prunes nothing.
    select format_type(atttypid, atttypmod) into v_ctl_type
      from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
    execute format('select min(%I)::text, max(%I)::text from %I.%I', p_control, p_control, v_nsp, v_delta)
      into v_min_ctl, v_max_ctl;
    -- Each write reports what it changed through RETURNING, so the conservation baseline follows the
    -- destination by identity, not only by row_count (#653).
    execute format('with w as (delete from %I.%I d where %s in (%s) returning %s as h) select count(*), coalesce(sum(h), 0) from w',
                   v_nsp, v_dest, v_dkey_q, v_subsel_q, v_fp_q) into v_n, v_h;
    v_dest_n := v_dest_n - v_n; v_dest_h := v_dest_h - v_h;
    if v_min_ctl is not null then
      execute format('with w as (insert into %I.%I (%s) select %s from %I.%I s where %s in (%s) and %I >= %L::%s and %I <= %L::%s returning %s as h) select count(*), coalesce(sum(h), 0) from w',
                     v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel, v_skey_q, v_subsel_q,
                     p_control, v_min_ctl, v_ctl_type, p_control, v_max_ctl, v_ctl_type, v_fp_q) into v_n, v_h;
    else
      execute format('with w as (insert into %I.%I (%s) select %s from %I.%I s where %s in (%s) returning %s as h) select count(*), coalesce(sum(h), 0) from w',
                     v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel, v_skey_q, v_subsel_q, v_fp_q) into v_n, v_h;
    end if;
    v_dest_n := v_dest_n + v_n; v_dest_h := v_dest_h + v_h;
  else
    -- append-only catch-up: insert the tail past the watermark (read pre-lock above, off the locked window;
    -- the pre-drain, if it ran, already advanced the dest to within one batch of the head, so this is small).
    --
    -- On a KEYED table the bound is inclusive and a key anti-join skips what the destination already holds
    -- (#460): a row that landed EXACTLY at the watermark during the window is taken rather than lost, and
    -- the copied row already sitting there is not duplicated. Still bounded to the tail on purpose -- an
    -- unbounded anti-join would put an O(rows) probe under the lock. A KEYLESS table keeps the strict `>`:
    -- it has no key to anti-join by, and an all-columns anti-join would be wrong there, since a duplicate
    -- row is legitimate in a keyless table and it would refuse to copy one. Whatever either form cannot
    -- see -- a row behind the watermark on any table, a row at it on a keyless one -- the conservation
    -- check below refuses on, rather than dropping the source short.
    --
    -- A NULL watermark (an empty copy) puts every source row in the tail (#736, _from_hypertable_past): the
    -- source had no rows when the copy ran, so everything it holds now arrived after it.
    v_n := 0; v_h := 0;
    if v_akey is not null then
      -- Materialise the tail first and ANALYZE it, as the tracking branch above does for its delta (#164):
      -- the anti-join must probe the destination's key index once per tail row, and the planner only
      -- chooses that when it knows the tail is small. Estimated straight off the source, the tail is sized
      -- from the newest chunk's statistics, and an overestimate there makes a hash anti-join that seqscans
      -- the WHOLE destination look cheap -- O(rows) under the lock, on a plan nobody sees. Measured: even
      -- at 20k rows the direct form planned a Seq Scan of the destination. On commit drop: the swap
      -- transaction commits below, or rolls back on the refusal, and either ends the temp table.
      execute 'drop table if exists pgpm_htail';
      execute format('create temp table pgpm_htail on commit drop as select %s from %I.%I where %s',
                     v_cols_q, v_nsp, v_rel,
                     pgpm._from_hypertable_past(p_control, v_watermark::text, p_inclusive => true));
      analyze pgpm_htail;
      execute format('with w as (insert into %I.%I (%s) select %s from pgpm_htail s where not exists (select 1 from %I.%I d where %s = %s) returning %s as h) select count(*), coalesce(sum(h), 0) from w',
                     v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_dest, v_dkey_q, v_skey_q, v_fp_q) into v_n, v_h;
    else
      execute format('with w as (insert into %I.%I (%s) select %s from %I.%I where %s returning %s as h) select count(*), coalesce(sum(h), 0) from w',
                     v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel,
                     pgpm._from_hypertable_past(p_control, v_watermark::text), v_fp_q) into v_n, v_h;
    end if;
    v_dest_n := v_dest_n + v_n; v_dest_h := v_dest_h + v_h;
  end if;

  -- CONSERVATION (#460, #653): the one place the two sides of the swap are compared, and it happens BEFORE
  -- the identity capture, the incoming-FK drops and the DROP TABLE below, so on a mismatch nothing outside
  -- the private destination has been touched and the raise rolls the catch-up and the index pre-builds back
  -- with it: the source is left whole and still a hypertable. Both sides are exact. The source is frozen
  -- under the ACCESS EXCLUSIVE just taken, and the destination's is the pre-lock baseline plus exactly what
  -- the catch-up changed, on a table nothing else writes (the private-destination invariant the watermark
  -- read already rests on). Reading the source is O(rows) under the lock, and there is no bounded read
  -- that could replace it: the rows this exists to find are the ones that landed BELOW the watermark,
  -- anywhere in the table, between the copy and this lock. Reading the destination here too would double
  -- that cost for nothing, which is why its side is carried in rather than taken again.
  --
  -- IDENTITY, not cardinality (#653): the two sides are compared by count AND by the content fingerprint
  -- (v_fp_q above), so the check asks whether the destination holds the SAME rows, not merely as many. A
  -- count alone passed a copied row deleted plus a row appended behind the watermark (72 = 72), and an
  -- update of a copied row, which changes no count at all; the fingerprint refuses both. It costs the
  -- source read a row rendering and a hash per row on top of the count it already paid for.
  --
  -- Refusing beats adapting. The missing rows are below the watermark, so re-running the cutover cannot
  -- find them either; only a copy that tracks changes (or one taken with writes paused) can, and the
  -- message says so. Without this check the loss was silent: no error, no log row, a source dropped short.
  if not v_track then
    execute format('select count(*), coalesce(sum(%s), 0) from %I.%I', v_fp_q, v_nsp, v_rel) into v_src_n, v_src_h;
  else
    -- UNTRACKED WRITES (#654). The capture trigger is origin-only (TimescaleDB refuses ENABLE ALWAYS on a
    -- hypertable and on its chunks), so a write under session_replication_role = replica never reached the
    -- delta. The count check below catches such an INSERT or DELETE; an UPDATE changes no count, and the swap
    -- used to install the copy's stale row over it. The anchor is MVCC, not the trigger: a source row
    -- version older than the horizon from_hypertable_copy recorded was committed before every chunk copy's
    -- snapshot, so the copy holds it unchanged; any other must now sit in the reconciled destination
    -- exactly as it sits in the source. One that does not was written without firing the trigger, and the
    -- swap is refused. A delta without a horizon (built by an older release) has no anchor, so every row
    -- is verified instead. Past 2^31 transactions age() no longer orders xids, so that falls back too.
    --
    -- The same scan counts the source, so the count check costs nothing extra; the destination probes run
    -- only for row versions at or past the horizon, through the key index the copy built. Relation by
    -- relation, because TimescaleDB refuses xmin on a compressed chunk ("transparent decompression only
    -- supports tableoid system column"): a compressed chunk's heap holds the rows written since it was
    -- compressed, and its compressed batches are checked for the same horizon, a fresh batch (compressed
    -- during the window) sending the whole chunk through the decompressing verification. OFFSET 0 keeps
    -- each subquery from being flattened into its aggregates, which would evaluate the probe once per
    -- aggregate that reads kt (twice, measured) instead of once per row.
    v_horizon := substring(obj_description(format('%I.%I', v_nsp, v_delta)::regclass, 'pg_class')
                           from '^pgpm from_hypertable horizon ([0-9]+)$')::bigint;
    if v_horizon is not null
       and pg_snapshot_xmax(pg_current_snapshot())::text::bigint - v_horizon < 2000000000 then
      v_fresh := format('age(s.xmin) <= age(%L::xid)', (v_horizon % 4294967296)::text);
    else
      v_fresh := 'true';
    end if;
    select string_agg('s.' || quote_ident(attname), ', ' order by attnum),
           string_agg('d.' || quote_ident(attname), ', ' order by attnum)
      into v_scols_q, v_dcols_q
      from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped and attgenerated = '';
    v_nomatch_q := format('not exists (select 1 from %I.%I d where %s = %s and row(%s)::text = row(%s)::text)',
                        v_nsp, v_dest, v_dkey_q, v_skey_q, v_dcols_q, v_scols_q);
    v_src_n := 0; v_unmatched := 0;
    for k in
      select r.oid::regclass as rel,
             (select format('%I.%I', z.schema_name, z.table_name)::regclass
                from pg_class rc join pg_namespace rn on rn.oid = rc.relnamespace
                join _timescaledb_catalog.chunk c on c.schema_name = rn.nspname and c.table_name = rc.relname
                join _timescaledb_catalog.chunk z on z.id = c.compressed_chunk_id
               where rc.oid = r.oid) as cmp
        from (select p_hypertable::oid as oid
              union all select inhrelid from pg_inherits where inhparent = p_hypertable) r
    loop
      v_fresh_batch := false;
      if k.cmp is not null then
        execute format('select exists (select 1 from %s s where %s)', k.cmp::text, v_fresh) into v_fresh_batch;
      end if;
      if k.cmp is null then
        execute format('select count(*), count(x.kt), min(x.kt) from (select case when %s then case when %s then row%s::text end end as kt from only %s s offset 0) x',
                       v_fresh, v_nomatch_q, v_skey_q, k.rel::text) into v_n, v_m, v_kt;
      elsif v_fresh_batch then
        execute format('select count(*), count(x.kt), min(x.kt) from (select case when %s then row%s::text end as kt from %s s offset 0) x',
                       v_nomatch_q, v_skey_q, k.rel::text) into v_n, v_m, v_kt;
      else
        execute format('select count(*) from %s', k.rel::text) into v_n;
        execute format('select count(x.kt), min(x.kt) from (select case when %s then case when %s then row%s::text end end as kt from only %s s offset 0) x',
                       v_fresh, v_nomatch_q, v_skey_q, k.rel::text) into v_m, v_kt;
      end if;
      v_src_n := v_src_n + v_n;
      v_unmatched := v_unmatched + v_m;
      v_first_key := least(v_first_key, v_kt);
    end loop;
    -- #653: the source's content fingerprint, the rows' identity, read after the per-relation scan. One more
    -- scan under the lock on this path only (the append-only path takes it with its count above): the
    -- scan above reads relation by relation for xmin's sake, and the fingerprint has to match the one the
    -- destination carried in over the whole table through TimescaleDB's own decompression.
    execute format('select coalesce(sum(%s), 0) from %I.%I', v_fp_q, v_nsp, v_rel) into v_src_h;
  end if;
  -- Two refusals guard the swap, the specific one first. A row the capture trigger never saw (#654) is named by
  -- its key below; the count-and-fingerprint comparison after it (#460, #653) catches everything else, so a
  -- write that bypassed the trigger is reported as what it is rather than as a fingerprint mismatch.
  if v_unmatched > 0 then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) refusing to swap: % source row(s) changed during the online window without firing the change-capture trigger, and the destination does not hold them as the source does (first key %). A write reached the source under session_replication_role = replica (a logical-replication apply worker, a loader silencing triggers) or with the trigger gone, and TimescaleDB cannot enable the trigger ALWAYS on a hypertable, so the delta never saw it. Nothing was dropped and the source is whole. Make every writer fire triggers for the whole window (pause the subscription, or run the loader as origin), then re-run from_hypertable_copy with p_track_changes => true.',
      p_hypertable, v_unmatched, v_first_key;
  end if;
  if v_src_n <> v_dest_n or v_src_h <> v_dest_h then
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
  -- (the key constraints + secondary indexes were captured and pre-built on the destination above, before
  -- the lock; the swap below only adopts/renames them -- metadata-only.)
  -- identity columns: CREATE TABLE (LIKE ...) does NOT carry identity, so the destination's column is a
  -- plain (already-populated) column. Capture, under the lock, which columns are identity on the source, in
  -- what KIND (ALWAYS or BY DEFAULT), with which sequence OPTIONS, and at which sequence position, so the
  -- swap re-adds each one as it was (#640). It used to re-add every one BY DEFAULT with the default options
  -- at last_value + 1: an ALWAYS column stopped refusing a supplied id, an INCREMENT BY 2 sequence stepped
  -- by 1 from an id off its lattice, and a descending one could not be seeded at all. The same helpers carry
  -- the same three things through transmute and untransmute (#308, #670). The position is the sequence's
  -- own next value (_seq_next, last_value plus its INCREMENT), not max(id): a source sequence can sit AHEAD
  -- of max(id) (rolled-back inserts, sequence caching, deleted high rows), and those ids must not be handed
  -- back out.
  for k in select attname, attidentity from pg_attribute
            where attrelid = p_hypertable and attidentity in ('a', 'd') and not attisdropped order by attnum loop
    v_ident_cols := array_append(v_ident_cols, k.attname);
    v_ident_kinds := array_append(v_ident_kinds, k.attidentity::text);
    v_srcseq := pg_get_serial_sequence(p_hypertable::text, k.attname::text)::regclass;
    v_ident_opts := array_append(v_ident_opts, pgpm._identity_options(v_srcseq));
    v_ident_next := array_append(v_ident_next, pgpm._seq_next(v_srcseq));
  end loop;
  -- OUTGOING foreign keys need no work here any more (#263). from_hypertable_copy already added them to
  -- the private destination and VALIDATED them there, off the lock; the destination then becomes the
  -- monolith child, and transmute re-adds every validated outgoing key at the new parent as part of its own
  -- cutover. This used to do that re-add itself (#264, when transmute did not), and doing BOTH now fails
  -- with `constraint "..." already exists`: the copy-phase validation is what makes transmute's adoption
  -- metadata-only, so that half stays and this half goes.

  -- INCOMING foreign keys (issue #264). An FK pointing AT the hypertable puts a constraint on each chunk,
  -- so `drop table <source>` below was refused outright -- and only here, after the entire online copy had
  -- run, leaving the populated destination orphaned behind the rollback:
  --
  --   ERROR: cannot drop table _timescaledb_internal._hyper_2_2_chunk because other objects depend on it
  --   DETAIL: constraint annotations_r_id_r_ts_fkey on table annotations depends on _hyper_2_2_chunk
  --
  -- Capture each definition and drop the constraint, which is what unblocks the drop. The recorded
  -- definition names the referenced table BY NAME, and the new parent takes the source's name, so it
  -- replays verbatim afterwards -- the same property transmute's own preserve path relies on. Captured
  -- through the core's _fk_definition (#498), which pins the search_path so the name is schema-qualified:
  -- a re-add that does not succeed below is retried by maintain in pg_cron's session, whose search_path
  -- is not this one's.
  --
  -- RECORDED HERE, in the swap transaction, beside the drop (#563). The handoff below runs after this
  -- transaction commits and can still refuse (the monolith name a long table derives on a fine grid is
  -- over 63 bytes, a stray row fails its VALIDATE, ...), and the record used to wait in plpgsql locals
  -- until it returned: a refusal left the key gone from the referencing table and written nowhere. Now a
  -- key is gone only in a database where pgpm.dropped_fk says so, which is the rule transmute's own
  -- preserve path follows (#444). Recorded against the table this swap puts in place (v_dest_oid, renamed
  -- into the source's name below), the only relation there is to name: the parent does not exist until
  -- transmute's cutover, which carries every record naming the table it converts onto that parent. So the
  -- record follows the table through this handoff, or through the operator's own re-run after a refusal.
  --
  -- Deliberately NOT re-added here: doing so would leave an incoming FK in place when the plain table is
  -- handed to transmute, which refuses one by default, and asking for 'preserve' would just have transmute
  -- drop it again. The re-add happens after the handoff, through the core's dropped_fk machinery.
  -- The eligibility of these keys was settled in the preflight, before any copy work.
  for k in
    select c.conrelid::regclass as referencing, c.conname, pgpm._fk_definition(c.oid) as def
      from pg_constraint c
     where c.confrelid = p_hypertable and c.contype = 'f' and c.conrelid <> p_hypertable
       and c.conparentid = 0
     order by c.conname
  loop
    v_in_names := array_append(v_in_names, k.conname::text);
    execute format('alter table %s drop constraint %I', k.referencing::text, k.conname);
    insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition)
      values (v_dest_oid, k.referencing, k.conname, k.def);
    insert into pgpm.log (parent_table, action, method) values (v_dest_oid, 'drop_incoming_fk', k.conname);
  end loop;

  -- What CREATE TABLE ... LIKE left off the copy (#787), read here, under the ACCESS EXCLUSIVE and with the
  -- source about to go, and replayed below once the copy has its name. See _from_hypertable_carried_ddl.
  v_carried_ddl := pgpm._from_hypertable_carried_ddl(p_hypertable);
  execute format('drop table %I.%I', v_nsp, v_rel);   -- also drops the change-capture trigger, if any
  if v_track then
    -- the trigger went with the source; drop the now-orphaned delta table and trigger function. This is
    -- inside the swap transaction, so an aborted cutover leaves the apparatus intact with the source.
    execute format('drop table %I.%I', v_nsp, v_delta);
    execute format('drop function if exists %I.%I()', v_nsp, v_trgfn);
  end if;
  execute format('alter table %I.%I rename to %I', v_nsp, v_dest, v_rel);
  -- adopt the pre-built unique indexes as the original PK/UNIQUE constraints (metadata-only; USING INDEX
  -- also renames the adopted index to the constraint name)
  for v_i in 1 .. coalesce(array_length(v_key_names, 1), 0) loop
    execute format('alter table %I.%I add constraint %I %s using index %I',
                   v_nsp, v_rel, v_key_names[v_i],
                   case when v_key_types[v_i] = 'p' then 'primary key' else 'unique' end,
                   v_key_tmps[v_i]);
  end loop;
  -- rename the pre-built secondary indexes to their original names (metadata-only)
  for v_i in 1 .. coalesce(array_length(v_idx_orig, 1), 0) loop
    execute format('alter index %I.%I rename to %I', v_nsp, v_idx_tmps[v_i], v_idx_orig[v_i]);
  end loop;
  -- #787: the source's owner, grants, row-level security, policies, comment and triggers, onto the table now
  -- under its name, in the swap transaction, so transmute finds them there and carries them onto its parent.
  foreach v_stmt in array v_carried_ddl loop
    execute v_stmt;
  end loop;
  -- Identity, re-added in the source's kind and with its sequence's options (#640), at the SOURCE sequence's
  -- position, in this same transaction (#563). A freshly added identity starts at START WITH, and the
  -- handoff below can still refuse after this commits; the position used to be applied only once transmute
  -- had returned, so a refusal left the plain table reissuing 1, 2, 3 over ids it already held (the source's
  -- key includes the time column, so nothing rejects the duplicates). transmute then seeds the parent from
  -- this sequence, kind and options included, so all three survive the conversion as well. Set through
  -- _identity_reseed, which leaves an exhausted sequence exhausted rather than failing the swap on an
  -- out-of-range setval.
  if v_ident_cols is not null then
    for v_i in 1 .. array_length(v_ident_cols, 1) loop
      execute format('alter table %I.%I alter column %I add generated %s as identity %s',
                     v_nsp, v_rel, v_ident_cols[v_i],
                     case when v_ident_kinds[v_i] = 'a' then 'always' else 'by default' end,
                     coalesce(v_ident_opts[v_i], ''));
      if v_ident_next[v_i] is not null then
        perform pgpm._identity_reseed(
          pg_get_serial_sequence(format('%I.%I', v_nsp, v_rel), v_ident_cols[v_i]::text)::regclass,
          v_ident_next[v_i], null, null);
      end if;
    end loop;
  end if;
  commit;

  -- handoff: an ordinary plain table under the original name is exactly transmute's input.
  v_orig := format('%I.%I', v_nsp, v_rel)::regclass;
  -- transmute is a PROCEDURE since #275 (it commits between adding the monolith bound, validating it, and
  -- the cutover, so the O(rows) scan is not held under ACCESS EXCLUSIVE). The commit above at :684 means
  -- this runs in a fresh transaction, so its internal commits are legal here.
  -- p_drain_batch sizes THIS module's migration-delta drain, which still exists; transmute's own batch
  -- knob is regrain's now (#288), so the handoff names it explicitly rather than relying on position.
  call pgpm.transmute(v_orig, p_control, p_interval, p_obtain, v_retain,
                      p_regrain_batch => p_drain_batch, p_anchor => p_anchor, p_paused => p_paused,
                      p_lock_timeout => p_lock_timeout, p_force_frontier => p_force_frontier);

  -- Re-add the incoming FKs the swap dropped, now against the new partitioned parent (issue #264). Handed
  -- to the CORE's existing state machine rather than re-implementing the dance: the swap recorded them in
  -- pgpm.dropped_fk and transmute's cutover moved those records onto the parent (#563), so
  -- restore_incoming_fks re-adds each NOT VALID (O(1), and enforcing every new write immediately) and
  -- validate_incoming_fks does the scan in its own transaction, with the orphan reporting, the validate
  -- back-off, and status().fks_suspended / fks_unvalidated all coming for free. Re-resolved by name because
  -- after transmute v_orig's oid is the monolith child, not the parent.
  --
  -- The window from the drop above to this re-add is real and bounded by the swap plus one transmute. It
  -- cannot be closed by re-adding inside the cutover -- transmute would then refuse the incoming key -- so
  -- it is surfaced rather than hidden, which is what pgpm.dropped_fk and status().fks_suspended are for.
  --
  -- Both waits are bounded by p_lock_timeout (#708), like every other lock this procedure waits for. The
  -- re-add takes SHARE ROW EXCLUSIVE on each referencing table, so behind one open writer there its
  -- PENDING request queued every later write of that table; the VALIDATE takes SHARE UPDATE EXCLUSIVE,
  -- which a running VACUUM, ANALYZE or index build holds. The re-add happens to run in transmute's last
  -- transaction, under the bound transmute set, but the VALIDATE runs after a COMMIT, where `set local`
  -- is gone and the session's own setting (none, by default) applied: the operator's call then waited as
  -- long as the holder lived. Each function already isolates every key in its own handler, so a timeout
  -- is a fail_restore_incoming_fk or fail_validate_incoming_fk row with the lock timeout as its reason,
  -- the key left recorded in pgpm.dropped_fk, and the cutover goes on; maintain's every-tick restore and
  -- validate (or a direct call) finish it. bench/hypertable_handoff_fk_lock_timeout.sh guards the VALIDATE.
  if v_in_names is not null then
    perform set_config('lock_timeout', p_lock_timeout, true);
    perform pgpm.restore_incoming_fks(format('%I.%I', v_nsp, v_rel)::regclass);
    commit;
    perform set_config('lock_timeout', p_lock_timeout, true);   -- `set local` did not survive the COMMIT
    perform pgpm.validate_incoming_fks(format('%I.%I', v_nsp, v_rel)::regclass);
    commit;
  end if;

  -- preserve the source sequence's exact position. The swap already set the plain table's sequence to it
  -- (#563) and transmute seeds the parent from that sequence, so this only ever confirms it; it stays as
  -- the backstop that advances, never rewinds, the parent's sequence to the source's captured next value.
  -- "Advances" is in the sequence's own direction (#640): downward for a negative INCREMENT, which the swap
  -- now carries. (Re-resolve the parent by name: after transmute, v_orig's oid is the monolith child, not
  -- the parent.)
  if v_ident_cols is not null then
    for v_i in 1 .. array_length(v_ident_cols, 1) loop
      if v_ident_next[v_i] is not null then
        v_pseq := pg_get_serial_sequence(format('%I.%I', v_nsp, v_rel), v_ident_cols[v_i]::text)::regclass;
        if v_pseq is not null
           and sign((select seqincrement from pg_sequence where seqrelid = v_pseq))
               * (v_ident_next[v_i] - pgpm._seq_next(v_pseq)) > 0 then
          perform pgpm._identity_reseed(v_pseq, v_ident_next[v_i], null, null);
        end if;
      end if;
    end loop;
  end if;
  commit;
end $$;

-- The one-shot driver: copy then cut over, back to back. Use the two phases directly instead when writes
-- must keep arriving during the migration (copy, let the workload run, then cutover catches up the appends).
drop procedure if exists pgpm.from_hypertable(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, boolean);
-- #288 dropped p_keep_default, so the previous form must go or both overloads survive and every call
-- becomes ambiguous.
drop procedure if exists pgpm.from_hypertable(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, boolean, boolean);
-- #665 added p_lock_timeout, passed through to the cutover: the same arg-count hazard as above.
drop procedure if exists pgpm.from_hypertable(regclass, name, interval, int, interval, int, timestamptz, boolean, boolean, boolean);
-- #792 added p_force_frontier, passed through to the cutover and on to transmute: the same hazard again.
drop procedure if exists pgpm.from_hypertable(regclass, name, interval, int, interval, int, timestamptz, boolean, boolean, boolean, text);
create or replace procedure pgpm.from_hypertable(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_track_changes boolean default false, p_predrain boolean default true,
  p_lock_timeout text default '5s', p_force_frontier boolean default false
) language plpgsql as $$
declare v_prev_lock_timeout text;
begin
  -- #665: refuse a bad p_lock_timeout before the copy, not from inside the cutover once the whole online
  -- copy has been paid for. No side effect: the prior value goes straight back.
  begin
    v_prev_lock_timeout := current_setting('lock_timeout');
    perform set_config('lock_timeout', p_lock_timeout, true);
    perform set_config('lock_timeout', v_prev_lock_timeout, true);
  exception when others then
    raise exception 'pg_partition_magician: p_lock_timeout must be a valid lock_timeout value (got %): %', p_lock_timeout, sqlerrm;
  end;
  -- #707: likewise the monolith name transmute derives from p_interval, which the copy alone cannot check
  -- (after the module's own names, #552, so a name too long for both is told the same thing as by the copy)
  perform pgpm._from_hypertable_check_names(p_hypertable);
  perform pgpm._from_hypertable_check_handoff(p_hypertable, p_interval, p_anchor);
  -- #792: and transmute's frontier bound, which needs p_interval too (the copy's preflight asks the key)
  perform pgpm._from_hypertable_check_frontier(p_hypertable, p_control, p_interval, p_force_frontier);
  call pgpm.from_hypertable_copy(p_hypertable, p_control, p_track_changes);
  call pgpm.from_hypertable_cutover(p_hypertable, p_control, p_interval, p_obtain, p_retain,
                                    p_drain_batch, p_anchor, p_paused, p_predrain, p_lock_timeout,
                                    p_force_frontier);
end $$;
