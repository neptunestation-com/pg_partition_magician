-- The invariant oracle (formal methods Phase 3, layer B; docs/formal/phase3-design.md).
--
-- TEST-ONLY. Installed into a test template after pgpm's core, never by any install.sql. Idempotent: a second
-- run replaces every function and keeps the tables (and what they hold).
--
-- The custody spec's invariants (formal/specs/Custody.tla, "Invariants. Names are stable"), as SQL over a real
-- database, judged at the end of a test file:
--
--   NoLostRow        a baselined row that was not deleted by the test and not aged out is visible through its
--                    parent, in a relation the test registered as the operator's, or in pgpm's custody
--   NoDuplicateRow   no baselined identity is visible more times than it was written, through the parent and
--                    across the parent and custody
--   DropOnlyCovered  with an archive strategy, a row retention removed is named by a retired chunk whose
--                    child_oid is a relation the drop history shows pgpm dropped
--   ArchiveNoClobber every retired chunk's object still holds every row of the chunk that is gone (needs
--                    pgpm_formal.store, which only the archive track's harness fills)
--   ResolveByRecord  pgpm neither drops nor detaches a relation the test registered as the operator's, and
--                    every drop pgpm makes is of a relation it recorded
--   NoWedge          the three state conjuncts: a retired chunk's relation is gone; no regrain copy outlives its
--                    source; no dispatched retirement mark stands on a partition nothing will detach
--
-- Entry points:
--   pgpm_formal.baseline(parent)          record every row visible through parent (opt-in row ledger)
--   pgpm_formal.wrote(parent, where)      record rows the test wrote after the baseline
--   pgpm_formal.deleted(parent, where)    record rows the test deleted after the baseline
--   pgpm_formal.operator_owns(rel)        mark a relation as the operator's (ResolveByRecord, NoLostRow)
--   pgpm_formal.expect(inv, identity, reason[, parent])   declare one violation the file builds on purpose
--   pgpm_formal.check([scope])            one row per violation: (invariant, parent_table, identity, detail)
--   pgpm_formal.judged()                  per invariant: judged or not, and how much, for the last check()
--
-- Identities, as check() reports them and expect() matches them:
--   a row     jsonb_build_array(<primary key columns at baseline>)::text, e.g. [42] or [7, "a"]; for a keyless
--             table the whole row, to_jsonb(row)::text. Rendered under the pinned settings below (UTC,
--             ISO), so a timestamptz key reads e.g. ["2026-01-01T00:00:00+00:00"] whatever the test's zone.
--   ResolveByRecord   the relation as schema.name (its name when dropped, or now)
--   NoWedge   'chunk <lo>' for a retired chunk, 'copy <child_name>' for a regrain copy, 'mark <child_name>'
--             for a retirement mark
--   UnusedExpectation '<invariant>:<identity>' of the declaration that matched nothing
--
-- Every function that renders or compares a row identity pins the settings that change a value's text
-- (TimeZone, DateStyle, IntervalStyle, extra_float_digits, bytea_output), so a baseline taken in one session
-- matches a check run in another.

create schema if not exists pgpm_formal;

-- ---------------------------------------------------------------------------------------------- the tables

-- One row per baselined parent. parent_oid is the oid baseline() was handed; parent_name its schema-qualified
-- name then. transmute turns the original table into the monolith partition under a NEW parent of the same
-- name, so the current parent is resolved at check time (pgpm_formal._current_parent).
create table if not exists pgpm_formal.ledger_parent (
  parent_oid   oid primary key,
  parent_name  text not null,
  key_cols     name[] not null,           -- the primary key at baseline; empty: keyless, the whole row is the identity
  baselined_at timestamptz not null default clock_timestamp()
);

create table if not exists pgpm_formal.ledger (
  parent_oid oid not null references pgpm_formal.ledger_parent on delete cascade,
  identity   text collate "C" not null,
  row_data   jsonb not null,                -- the row as last recorded, to_jsonb(row)
  mult       int not null,                  -- copies expected: 1 for a keyed row, the multiplicity for a keyless one
  deleted    boolean not null default false,
  primary key (parent_oid, identity)
);

-- Relations the test made the operator's. parent_oid: the table it was a partition of when registered (null if
-- none), so a later DETACH can be attributed through alter_history from hist_mark on. rows_for: the parent whose
-- rows it counts for.
create table if not exists pgpm_formal.operator_rel (
  rel_oid       oid primary key,
  rel_name      text not null,
  parent_oid    oid,
  rows_for      oid,                      -- the parent whose rows it may hold (NoLostRow); null: none
  hist_mark     bigint not null,
  registered_at timestamptz not null default clock_timestamp()
);

create table if not exists pgpm_formal.expectation (
  invariant  text not null,
  identity   text collate "C" not null,
  parent_oid oid not null default 0,        -- 0: any parent
  reason     text not null check (btrim(reason) <> ''),
  primary key (invariant, identity, parent_oid)
);

-- Every table dropped in this database, written by the sql_drop event trigger below.
--   by_pgpm     the drop ran under a pgpm frame: a PL/pgSQL function or procedure of schema pgpm or archive is on
--               the call stack (GET DIAGNOSTICS PG_CONTEXT), or the backend is pg_cron's. What ResolveByRecord
--               and DropOnlyCovered read.
--   by_query    the top-level statement's text in pg_stat_activity begins `call pgpm.` or `select pgpm.`. The
--               attribution the design note first proposed, kept for the measurement that retired it (see
--               docs/formal/phase3-design.md, "Measured before it is relied on"); nothing reads it.
--   recorded    pgpm's catalog named the oid when the trigger fired (pgpm.part, pgpm.config, pgpm.scratch), or pgpm
--               created the relation (create_history); recorded_as says which. Null: the catalog could not be read
--               (an install mid-way, an older one).
--   xact_start / stmt_start   now() and statement_timestamp() at the drop: a drop in a transaction that began
--               after its top-level statement did ran after a COMMIT inside a procedure.
create table if not exists pgpm_formal.drop_history (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default clock_timestamp(),
  xid          xid8,
  xact_start   timestamptz,
  stmt_start   timestamptz,
  objid        oid not null,
  schema_name  text,
  object_name  text,
  is_temporary boolean,
  by_pgpm      boolean,
  by_query     boolean,
  top_query    text,
  backend_type text,
  parent_oid   oid,
  recorded     boolean,
  recorded_as  text,
  part_row     boolean,                    -- a pgpm.part row anchored to this oid existed when the trigger fired
  context      text
);

-- Every ALTER TABLE, with the table's partitions after it (for a partitioned table): what attributes a DETACH.
create table if not exists pgpm_formal.alter_history (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default clock_timestamp(),
  xid        xid8,
  objid      oid not null,
  by_pgpm    boolean,
  partitions oid[]
);

-- Every table created under a pgpm frame (CREATE TABLE, CREATE TABLE AS, SELECT INTO): what makes a drop of a
-- relation pgpm made itself "recorded" after pgpm has already deleted its own record of it. Measured (W2,
-- tests/formal/oracle_attribution_test.sql): regrain's swap deletes the source's pgpm.part row before it DROPs the
-- source, so at the sql_drop trigger nothing in pgpm's catalog names a coarse child that is not the monolith.
create table if not exists pgpm_formal.create_history (
  id      bigint generated always as identity primary key,
  at      timestamptz not null default clock_timestamp(),
  objid   oid not null,
  by_pgpm boolean
);
create index if not exists create_history_objid_idx on pgpm_formal.create_history (objid);

-- Archive object contents, loaded by the archive track's harness before check() runs (the oracle cannot read a
-- bucket, and judging the archive with pgpm_archive's own code would be the code under test grading itself).
-- store_listing says a parent's bucket WAS listed: without it ArchiveNoClobber is not judged for the parent,
-- which is how an empty object (clobbered to nothing) is told apart from an unlisted bucket.
create table if not exists pgpm_formal.store (
  parent_table oid not null,
  s3_key       text collate "C" not null,
  identity     text collate "C" not null
);
create index if not exists store_key_idx on pgpm_formal.store (parent_table, s3_key, identity);
create table if not exists pgpm_formal.store_listing (
  parent_table oid primary key,
  listed_at    timestamptz not null default clock_timestamp()
);

-- What the most recent check() judged (pgpm_formal.judged() reads it).
create table if not exists pgpm_formal.judged_last (
  invariant  text primary key,
  judged     boolean not null,
  parents    int not null,
  identities bigint not null,
  expected   int not null,
  note       text
);

-- ------------------------------------------------------------------------------------------- attribution

-- Is a PL/pgSQL call stack (GET DIAGNOSTICS ... = PG_CONTEXT) running pgpm's code? A frame reads
-- `PL/pgSQL function pgpm.retire(regclass,name) line 312 at EXECUTE` for a function and for a procedure alike;
-- schema `archive` is pgpm_archive's. The oracle's own frames are pgpm_formal.*, which the pattern does not
-- match (the dot follows the schema name directly).
create or replace function pgpm_formal._ctx_is_pgpm(p_ctx text)
returns boolean language sql immutable as $$
  select coalesce(p_ctx ~ '(^|\n)PL/pgSQL function (pgpm|archive)\.', false);
$$;

-- What pgpm's catalog says about a relation oid, or null. Asked inside the sql_drop trigger, so it must not
-- raise: an older install lacks columns, and an uninstall drops pgpm.part itself mid-statement.
create or replace function pgpm_formal._recorded_as(p_oid oid)
returns text language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v text;
begin
  select string_agg(w, ', ') into v from (
    select 'pgpm.part child_oid' w from pgpm.part where child_oid = p_oid
    union all select 'pgpm.part retiring_oid' from pgpm.part where retiring_oid = p_oid
    union all select 'pgpm.part detach_dispatched_oid' from pgpm.part where detach_dispatched_oid = p_oid
    union all select 'pgpm.config parent_table' from pgpm.config where parent_table = p_oid
    union all select 'pgpm.config monolith_oid' from pgpm.config where monolith_oid = p_oid
    union all select 'pgpm.config regrain_delta_oid' from pgpm.config where regrain_delta_oid = p_oid
    union all select 'pgpm.scratch obj' from pgpm.scratch where obj = p_oid
    union all select 'created by pgpm' from (select h.by_pgpm from pgpm_formal.create_history h where h.objid = p_oid
                                              order by h.id desc limit 1) c where c.by_pgpm
  ) s;
  return coalesce(v, '');
exception when others then
  return null;
end;
$$;

-- The parent pgpm recorded a dropped relation under: by its oid, or (for a row that records no oid, an older
-- install's or an unanchored one's) by its name in its parent's schema.
create or replace function pgpm_formal._part_parent(p_oid oid, p_schema text, p_name text)
returns oid language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v oid;
begin
  select parent_table::oid into v from pgpm.part
   where child_oid = p_oid or retiring_oid = p_oid or detach_dispatched_oid = p_oid limit 1;
  if v is null then
    select p.parent_table::oid into v from pgpm.part p join pg_class c on c.oid = p.parent_table
                                            join pg_namespace n on n.oid = c.relnamespace
     where p.child_name = p_name and n.nspname = p_schema limit 1;
  end if;
  return v;
exception when others then
  return null;
end;
$$;

-- sql_drop: one drop_history row per dropped table. SECURITY DEFINER so a test that drops under SET ROLE still
-- writes its row; it never raises, since an oracle that breaks a DROP changes what the file tests.
create or replace function pgpm_formal._on_sql_drop()
returns event_trigger language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare
  v_ctx text; v_query text; v_btype text; v_app text; v_by_pgpm boolean; r record; v_rec text;
begin
  get diagnostics v_ctx = pg_context;
  select a.query, a.backend_type, a.application_name into v_query, v_btype, v_app
    from pg_stat_activity a where a.pid = pg_backend_pid();
  v_by_pgpm := pgpm_formal._ctx_is_pgpm(v_ctx) or v_btype = 'pg_cron' or v_app = 'pg_cron';
  for r in select * from pg_event_trigger_dropped_objects() where object_type = 'table' loop
    v_rec := pgpm_formal._recorded_as(r.objid);
    insert into pgpm_formal.drop_history
      (xid, xact_start, stmt_start, objid, schema_name, object_name, is_temporary, by_pgpm, by_query, top_query,
       backend_type, parent_oid, recorded, recorded_as, part_row, context)
    values (pg_current_xact_id(), now(), statement_timestamp(), r.objid, r.schema_name, r.object_name,
            r.is_temporary, v_by_pgpm,
            coalesce(v_query ~* '^\s*(call|select)\s+pgpm\.', false), left(v_query, 500), v_btype,
            pgpm_formal._part_parent(r.objid, r.schema_name, r.object_name),
            case when v_rec is null then null else v_rec <> '' end, nullif(v_rec, ''),
            coalesce(v_rec like '%pgpm.part%', false), left(v_ctx, 2000));
  end loop;
exception when others then
  raise warning 'pgpm_formal: drop history not recorded: %', sqlerrm;
end;
$$;

-- ddl_command_end on ALTER TABLE (the partitions after it: what attributes a DETACH) and on the commands that create
-- a table (create_history).
create or replace function pgpm_formal._on_ddl()
returns event_trigger language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare v_ctx text; v_btype text; v_app text; v_by_pgpm boolean; r record;
begin
  get diagnostics v_ctx = pg_context;
  select a.backend_type, a.application_name into v_btype, v_app from pg_stat_activity a where a.pid = pg_backend_pid();
  v_by_pgpm := pgpm_formal._ctx_is_pgpm(v_ctx) or v_btype = 'pg_cron' or v_app = 'pg_cron';
  for r in select distinct c.objid, c.command_tag from pg_event_trigger_ddl_commands() c
            where c.classid = 'pg_class'::regclass and c.object_type = 'table' loop
    if r.command_tag = 'ALTER TABLE' then
      insert into pgpm_formal.alter_history (xid, objid, by_pgpm, partitions)
      values (pg_current_xact_id(), r.objid, v_by_pgpm,
              (select coalesce(array_agg(i.inhrelid order by i.inhrelid), '{}') from pg_inherits i
                where i.inhparent = r.objid and not i.inhdetachpending));
    else
      insert into pgpm_formal.create_history (objid, by_pgpm) values (r.objid, v_by_pgpm);
    end if;
  end loop;
exception when others then
  raise warning 'pgpm_formal: ddl history not recorded: %', sqlerrm;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'pgpm_formal_sql_drop') then
    create event trigger pgpm_formal_sql_drop on sql_drop execute function pgpm_formal._on_sql_drop();
  end if;
  if not exists (select 1 from pg_event_trigger where evtname = 'pgpm_formal_ddl') then
    create event trigger pgpm_formal_ddl on ddl_command_end
      when tag in ('ALTER TABLE', 'CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      execute function pgpm_formal._on_ddl();
  end if;
end $$;

-- ------------------------------------------------------------------------------------------- the ledger

-- The primary key columns of a relation, in key order; empty for a keyless one.
create or replace function pgpm_formal._key_cols(p_rel regclass)
returns name[] language sql stable as $$
  select coalesce((select array_agg(a.attname order by k.ord)
                     from pg_index i
                     cross join lateral unnest(i.indkey) with ordinality k(attnum, ord)
                     join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
                    where i.indrelid = p_rel and i.indisprimary), '{}'::name[]);
$$;

-- The SQL that renders a row's identity, over alias t.
create or replace function pgpm_formal._ident_sql(p_keys name[])
returns text language sql immutable as $$
  select case when coalesce(array_length(p_keys, 1), 0) = 0 then 'to_jsonb(t)::text'
              else format('jsonb_build_array(%s)::text', (select string_agg(format('t.%I', k), ', ') from unnest(p_keys) k))
         end;
$$;

-- Where a baselined parent's rows are now. The oid first: transmute made it the monolith, a partition of the new
-- parent, whose root is the parent now. Else the name: the monolith retention dropped leaves only the name.
create or replace function pgpm_formal._current_parent(p_parent_oid oid)
returns regclass language plpgsql stable as $$
declare v_name text; v_part boolean; v_exists boolean; v_byname regclass; v_relname text;
begin
  select parent_name into v_name from pgpm_formal.ledger_parent where parent_oid = p_parent_oid;
  select true, c.relispartition, format('%I.%I', n.nspname, c.relname) into v_exists, v_part, v_relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent_oid;
  if v_exists and v_part then
    return pg_partition_root(p_parent_oid);
  end if;
  v_byname := to_regclass(v_name);
  if v_exists and (v_byname is null or v_byname = p_parent_oid) then
    return p_parent_oid::regclass;
  end if;
  return v_byname;
end;
$$;

-- The ledger parent a regclass the test names stands for: the one baselined as it, or the one it now resolves to.
create or replace function pgpm_formal._ledger_parent_of(p_parent regclass)
returns oid language plpgsql stable as $$
declare v oid;
begin
  select parent_oid into v from pgpm_formal.ledger_parent where parent_oid = p_parent;
  if v is null then
    select parent_oid into v from pgpm_formal.ledger_parent
     where pgpm_formal._current_parent(parent_oid) = p_parent order by baselined_at desc limit 1;
  end if;
  if v is null then
    raise exception 'pgpm_formal: % has no baseline; call pgpm_formal.baseline(%L) after loading its fixture',
      p_parent, p_parent::text;
  end if;
  return v;
end;
$$;

-- baseline(parent): record every row visible through parent, by identity. A second call replaces the first.
-- Returns the number of rows recorded (with multiplicity), the file's liveness witness that the ledger holds
-- what it wrote.
create or replace function pgpm_formal.baseline(p_parent regclass)
returns bigint language plpgsql
set timezone = 'UTC' set datestyle = 'ISO, MDY' set intervalstyle = 'postgres' set extra_float_digits = 1
set bytea_output = 'hex' as $$
declare v_keys name[]; v_n bigint;
begin
  if p_parent is null then raise exception 'pgpm_formal.baseline: parent is null'; end if;
  v_keys := pgpm_formal._key_cols(p_parent);
  delete from pgpm_formal.ledger_parent where parent_oid = p_parent;
  insert into pgpm_formal.ledger_parent (parent_oid, parent_name, key_cols)
  select p_parent, format('%I.%I', n.nspname, c.relname), v_keys
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  execute format(
    'insert into pgpm_formal.ledger (parent_oid, identity, row_data, mult)
     select $1, i, d, case when $2 then 1 else n end
       from (select %s as i, (array_agg(to_jsonb(t)))[1] as d, count(*)::int as n from %s t group by 1) s',
    pgpm_formal._ident_sql(v_keys), p_parent::text)
  using p_parent::oid, coalesce(array_length(v_keys, 1), 0) > 0;
  select coalesce(sum(mult), 0) into v_n from pgpm_formal.ledger where parent_oid = p_parent;
  return v_n;
end;
$$;

-- wrote(parent, where): record the rows now visible through parent that match the predicate (written over the
-- parent's columns, unqualified, e.g. 'id >= 65000'): a row the test inserted or updated after the baseline. A
-- keyless identity's multiplicity becomes what is visible now. Returns the number of identities recorded.
create or replace function pgpm_formal.wrote(p_parent regclass, p_where text default 'true')
returns bigint language plpgsql
set timezone = 'UTC' set datestyle = 'ISO, MDY' set intervalstyle = 'postgres' set extra_float_digits = 1
set bytea_output = 'hex' as $$
declare v_lp oid; v_keys name[]; v_n bigint;
begin
  v_lp := pgpm_formal._ledger_parent_of(p_parent);
  select key_cols into v_keys from pgpm_formal.ledger_parent where parent_oid = v_lp;
  execute format(
    'insert into pgpm_formal.ledger as l (parent_oid, identity, row_data, mult, deleted)
     select $1, i, d, case when $2 then 1 else n end, false
       from (select %s as i, (array_agg(to_jsonb(t)))[1] as d, count(*)::int as n from %s t where (%s) group by 1) s
     on conflict (parent_oid, identity) do update set row_data = excluded.row_data, mult = excluded.mult, deleted = false',
    pgpm_formal._ident_sql(v_keys), p_parent::text, coalesce(p_where, 'true'))
  using v_lp, coalesce(array_length(v_keys, 1), 0) > 0;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- deleted(parent, where): record that the test deleted the ledger rows matching the predicate, evaluated over each
-- recorded row as the parent's row type. Call it before or after the DELETE: it reads the ledger, not the table.
-- Returns the number of identities marked.
create or replace function pgpm_formal.deleted(p_parent regclass, p_where text)
returns bigint language plpgsql
set timezone = 'UTC' set datestyle = 'ISO, MDY' set intervalstyle = 'postgres' set extra_float_digits = 1
set bytea_output = 'hex' as $$
declare v_lp oid; v_n bigint;
begin
  v_lp := pgpm_formal._ledger_parent_of(p_parent);
  execute format(
    'update pgpm_formal.ledger l set deleted = true
      where l.parent_oid = $1 and not l.deleted
        and exists (select 1 from jsonb_populate_record(null::%s, l.row_data) t where (%s))',
    p_parent::text, p_where)
  using v_lp;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- operator_owns(rel[, parent]): the relation is the operator's. pgpm must neither drop nor detach it
-- (ResolveByRecord), and its rows count as kept for one parent (NoLostRow): the one it is a partition of now, or
-- p_parent for a table that is no partition (a namesake, a copy the operator keeps). A relation that is neither
-- counts for no parent, so an unrelated table holding the same keys can never hide a lost row.
drop function if exists pgpm_formal.operator_owns(regclass);
create or replace function pgpm_formal.operator_owns(p_rel regclass, p_parent regclass default null)
returns void language plpgsql as $$
begin
  insert into pgpm_formal.operator_rel (rel_oid, rel_name, parent_oid, rows_for, hist_mark)
  select c.oid, format('%I.%I', n.nspname, c.relname), i.inhparent, coalesce(p_parent::oid, i.inhparent),
         coalesce((select max(id) from pgpm_formal.alter_history), 0)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    left join pg_inherits i on i.inhrelid = c.oid
   where c.oid = p_rel
  on conflict (rel_oid) do update set rel_name = excluded.rel_name, parent_oid = excluded.parent_oid,
                                      rows_for = excluded.rows_for, hist_mark = excluded.hist_mark;
end;
$$;

-- expect(invariant, identity, reason[, parent]): this file builds that one violation on purpose. One identity per
-- declaration, never an invariant or a file; one that matches no violation is reported as UnusedExpectation.
create or replace function pgpm_formal.expect(p_invariant text, p_identity text, p_reason text,
                                              p_parent regclass default null)
returns void language plpgsql as $$
begin
  if p_invariant is null or p_invariant not in
     ('NoLostRow', 'NoDuplicateRow', 'DropOnlyCovered', 'ArchiveNoClobber', 'ResolveByRecord', 'NoWedge') then
    raise exception 'pgpm_formal.expect: % is not an invariant the oracle judges', p_invariant;
  end if;
  if p_identity is null or p_identity = '' then
    raise exception 'pgpm_formal.expect: a declaration names one identity';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'pgpm_formal.expect: say why the file builds this state';
  end if;
  insert into pgpm_formal.expectation (invariant, identity, parent_oid, reason)
  values (p_invariant, p_identity, coalesce(p_parent::oid, 0), p_reason)
  on conflict (invariant, identity, parent_oid) do update set reason = excluded.reason;
end;
$$;

-- ------------------------------------------------------------------------------------------- the checks

-- A row's control value as pgpm's native grid value (numeric for id, timestamptz text otherwise), or null.
create or replace function pgpm_formal._native_of(p_cfg pgpm.config, p_row jsonb)
returns text language plpgsql stable as $$
begin
  return pgpm._col_to_native(p_cfg, p_row ->> p_cfg.control_column::text);
exception when others then
  return null;
end;
$$;

-- The relations whose rows count for a ledger parent besides the parent itself: 2 = custody (a partition pgpm's
-- own dispatched retirement holds: a mark with detach_dispatched_oid, the relation out of the parent), 3 = the
-- operator's (registered by the test for this parent, or released to the operator by pgpm's recall:
-- retain_disown logged over the row's range, the relation out of the parent).
create or replace function pgpm_formal._side_rels(p_cur regclass)
returns table (rel oid, src int) language sql stable as $$
  select p.detach_dispatched_oid, 2
    from pgpm.part p join pg_class c on c.oid = p.detach_dispatched_oid
   where p.parent_table = p_cur and p.retiring_at is not null
     and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid and i.inhparent = p_cur and not i.inhdetachpending)
  union
  select o.rel_oid, 3 from pgpm_formal.operator_rel o join pg_class c on c.oid = o.rel_oid
   where o.rel_oid <> p_cur::oid and o.rows_for = p_cur::oid
     and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid and i.inhparent = p_cur)
  union
  select p.child_oid, 3
    from pgpm.part p join pg_class c on c.oid = p.child_oid
   where p.parent_table = p_cur and p.retiring_at is null
     and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid and i.inhparent = p_cur)
     and exists (select 1 from pgpm.log g where g.parent_table = p_cur and g.action = 'retain_disown'
                                           and g.lo = p.lo and g.hi = p.hi);
$$;

-- Every ledger row of a parent with how many times it is visible: np through the parent, nc in custody, no in an
-- operator's relation. A side relation that lacks a key column is skipped (its name in p_skipped).
create or replace function pgpm_formal._row_states(p_lp oid, p_cur regclass, out p_sql text, out p_skipped text[])
language plpgsql stable as $$
declare v_keys name[]; v_ident text; v_parts text[] := '{}'; r record;
begin
  select key_cols into v_keys from pgpm_formal.ledger_parent where parent_oid = p_lp;
  v_ident := pgpm_formal._ident_sql(v_keys);
  p_skipped := '{}';
  if p_cur is not null then
    v_parts := v_parts || format('select %s as i, 1 as s from %s t', v_ident, p_cur::text);
    for r in select s.rel, s.src from pgpm_formal._side_rels(p_cur) s loop
      if exists (select 1 from unnest(v_keys) k
                  where not exists (select 1 from pg_attribute a where a.attrelid = r.rel and a.attname = k
                                                                   and a.attnum > 0 and not a.attisdropped)) then
        p_skipped := p_skipped || r.rel::regclass::text;
        continue;
      end if;
      v_parts := v_parts || format('select %s as i, %s as s from %s t', v_ident, r.src, r.rel::regclass::text);
    end loop;
  end if;
  p_sql := format(
    'select l.identity, l.row_data, l.mult, coalesce(v.np, 0) as np, coalesce(v.nc, 0) as nc, coalesce(v.no, 0) as no
       from pgpm_formal.ledger l
       left join (select i, count(*) filter (where s = 1) as np, count(*) filter (where s = 2) as nc,
                         count(*) filter (where s = 3) as no
                    from (%s) u group by i) v on v.i = l.identity
      where l.parent_oid = %s and not l.deleted',
    case when cardinality(v_parts) = 0 then 'select null::text as i, 0 as s where false'
         else array_to_string(v_parts, ' union all ') end,
    p_lp);
end;
$$;

-- All violations, expected ones included, and the judged counts (into judged_last). check() filters.
create or replace function pgpm_formal._violations(p_scope regclass[] default null)
returns table (invariant text, parent_table regclass, identity text, detail text)
language plpgsql
set timezone = 'UTC' set datestyle = 'ISO, MDY' set intervalstyle = 'postgres' set extra_float_digits = 1
set bytea_output = 'hex' as $$
declare
  lp record; r record; v_cur regclass; cfg pgpm.config; v_have_cfg boolean; v_t text; v_bound text;
  v_sql text; v_skipped text[]; v_listed boolean; v_nrows bigint;
  -- judged counters
  n_lost_par int := 0; n_lost_id bigint := 0;
  n_doc_par int := 0; n_doc_id bigint := 0; n_anc_par int := 0; n_anc_id bigint := 0;
  n_rbr_id bigint := 0; n_wedge_id bigint := 0; n_mark_unjudged int := 0;
  v_unjudged_par text[] := '{}'; v_cron text;
begin
  -- -------------------------------------------------- the row invariants, per baselined parent
  for lp in select * from pgpm_formal.ledger_parent order by parent_oid loop
    v_cur := pgpm_formal._current_parent(lp.parent_oid);
    if p_scope is not null and not (lp.parent_oid::regclass = any (p_scope) or v_cur = any (p_scope)) then
      continue;
    end if;
    if v_cur is null then
      -- the promise lasts while the parent does (Custody.tla NoLostRowLive): a dropped parent is not judged
      v_unjudged_par := v_unjudged_par || (lp.parent_name || ' (gone)');
      continue;
    end if;
    v_t := null; v_bound := null;
    select * into cfg from pgpm.config c where c.parent_table = v_cur;
    v_have_cfg := found;
    if v_have_cfg then
      cfg := pgpm._control_followed(cfg);
      v_t := pgpm._native_type(cfg.control_kind);
      begin
        v_bound := pgpm._retain_boundary(cfg);
      exception when others then
        v_bound := null;
      end;
    end if;
    select s.p_sql, s.p_skipped into v_sql, v_skipped from pgpm_formal._row_states(lp.parent_oid, v_cur) s;
    v_listed := exists (select 1 from pgpm_formal.store_listing sl where sl.parent_table = v_cur);
    n_lost_par := n_lost_par + 1;
    if v_have_cfg and cfg.archive_fn is not null then n_doc_par := n_doc_par + 1; end if;
    if v_listed then n_anc_par := n_anc_par + 1; end if;
    select count(*) into v_nrows from pgpm_formal.ledger l where l.parent_oid = lp.parent_oid and not l.deleted;
    n_lost_id := n_lost_id + v_nrows;
    -- One statement per parent: every ledger row that is over- or under-visible, and for an under-visible one its
    -- native control value, whether it is at or past the horizon, whether retention ran over it (retain_drop or
    -- regrain_aged logged over a range holding it), and the retired chunk that holds it (one pgpm dropped first).
    v_sql := format(
      'with st as (%1$s),
            lg as materialized (select g.lo::%2$s as lo, g.hi::%2$s as hi from pgpm.log g
                                 where $3 and g.parent_table = $1 and g.action in (''retain_drop'', ''regrain_aged'')),
            ch as materialized (select l.lo::%2$s as lo_n, l.hi::%2$s as hi_n, l.lo, l.hi, l.s3_key, l.child_oid,
                                       exists (select 1 from pgpm_formal.drop_history h
                                                where h.objid = l.child_oid and h.by_pgpm) as pgpm_dropped
                                  from pgpm.archive_ledger l where $3 and l.parent_table = $1 and l.retired_at is not null),
            bad as (select st.*, case when np + nc + no < mult and $3 then pgpm_formal._native_of($2, row_data) end as nat
                      from st where np + nc > mult or np + nc + no < mult)
       select b.identity, b.mult, b.np, b.nc, b.no, b.nat,
              coalesce(b.nat::%2$s >= $4::%2$s, false) as unaged,
              exists (select 1 from lg where b.nat::%2$s >= lg.lo and b.nat::%2$s < lg.hi) as ran,
              c.lo as c_lo, c.hi as c_hi, c.s3_key as c_key, c.child_oid as c_oid, c.pgpm_dropped as c_pgpm
         from bad b
         left join lateral (select * from ch where b.nat::%2$s >= ch.lo_n and b.nat::%2$s < ch.hi_n
                             order by (ch.child_oid is not null and ch.pgpm_dropped) desc, ch.lo_n limit 1) c on true',
      v_sql, coalesce(v_t, 'numeric'));
    for r in execute v_sql using v_cur, cfg, v_have_cfg, v_bound loop
      -- NoDuplicateRow: through the parent, and across the parent and custody
      if r.np + r.nc > r.mult then
        invariant := 'NoDuplicateRow'; parent_table := v_cur; identity := r.identity;
        detail := format('expected %s, visible %s through %s and %s in custody', r.mult, r.np, v_cur, r.nc);
        return next;
      end if;
      continue when r.np + r.nc + r.no >= r.mult;
      -- not visible anywhere it may be: lost, unless retention removed it
      if r.nat is null or r.unaged or not r.ran then
        invariant := 'NoLostRow'; parent_table := v_cur; identity := r.identity;
        detail := format('visible %s of %s (parent %s, custody %s, operator %s); %s%s', r.np + r.nc + r.no, r.mult,
                         r.np, r.nc, r.no,
                         case when not v_have_cfg then 'the parent is not managed, so no retention applies'
                              when r.nat is null then 'its control value could not be read as a native grid value'
                              when r.unaged then format('its control value %s is at or past the horizon %s', r.nat, v_bound)
                              else format('its control value %s is below the horizon %s, but no retain_drop or regrain_aged covers it',
                                          r.nat, coalesce(v_bound, '(none)')) end,
                         case when cardinality(v_skipped) > 0 then format('; side relations not read: %s', v_skipped) else '' end);
        return next;
        continue;
      end if;
      -- aged out by retention: DropOnlyCovered and ArchiveNoClobber judge how
      if cfg.archive_fn is not null then
        n_doc_id := n_doc_id + 1;
        if r.c_lo is null then
          invariant := 'DropOnlyCovered'; parent_table := v_cur; identity := r.identity;
          detail := format('gone with control value %s below the horizon, and no retired chunk of %s holds it', r.nat, v_cur);
          return next;
        elsif r.c_oid is null or not r.c_pgpm then
          invariant := 'DropOnlyCovered'; parent_table := v_cur; identity := r.identity;
          detail := format('the retired chunk [%s, %s) holding it names %s, which the drop history does not show pgpm dropped',
                           r.c_lo, r.c_hi, coalesce(r.c_oid::text, 'no relation (child_oid null)'));
          return next;
        end if;
      end if;
      if v_listed and r.c_lo is not null then
        n_anc_id := n_anc_id + 1;
        if r.c_key is null or not exists (select 1 from pgpm_formal.store s where s.parent_table = v_cur
                                            and s.s3_key = r.c_key and s.identity = r.identity) then
          invariant := 'ArchiveNoClobber'; parent_table := v_cur; identity := r.identity;
          detail := format('the retired chunk [%s, %s) records it, and its object %s does not hold it',
                           r.c_lo, r.c_hi, coalesce(r.c_key, '(no key recorded)'));
          return next;
        end if;
      end if;
    end loop;
  end loop;

  -- -------------------------------------------------- ResolveByRecord
  -- (1) a relation the test registered as the operator's is gone, or out of its parent, by pgpm's hand
  for r in
    select o.*, c.oid is not null as present,
           (select h from pgpm_formal.drop_history h where h.objid = o.rel_oid order by h.id desc limit 1) as h
      from pgpm_formal.operator_rel o left join pg_class c on c.oid = o.rel_oid
     where p_scope is null or o.parent_oid::regclass = any (p_scope)
  loop
    n_rbr_id := n_rbr_id + 1;
    if not r.present then
      if (r.h).id is null or (r.h).by_pgpm then
        invariant := 'ResolveByRecord'; parent_table := r.parent_oid::regclass;
        identity := coalesce((r.h).schema_name || '.' || (r.h).object_name, r.rel_name);
        detail := case when (r.h).id is null then 'the operator''s relation is gone, and the drop history has no record of its drop'
                       else format('the operator''s relation was dropped by pgpm (statement: %s)', (r.h).top_query) end;
        return next;
      end if;
    elsif r.parent_oid is not null
          and not exists (select 1 from pg_inherits i where i.inhrelid = r.rel_oid and i.inhparent = r.parent_oid
                                                    and not i.inhdetachpending) then
      declare v_a record;
      begin
        select a.* into v_a from pgpm_formal.alter_history a
         where a.objid = r.parent_oid and a.id > r.hist_mark and not (r.rel_oid = any (a.partitions))
         order by a.id limit 1;
        if v_a.id is null or v_a.by_pgpm then
          invariant := 'ResolveByRecord'; parent_table := r.parent_oid::regclass;
          identity := (select format('%I.%I', n.nspname, c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                        where c.oid = r.rel_oid);
          detail := case when v_a.id is null then 'the operator''s relation is out of its parent, and no ALTER TABLE on the parent is recorded since it was registered'
                         else 'the operator''s relation was detached from its parent by pgpm' end;
          return next;
        end if;
      end;
    end if;
  end loop;
  -- (2) every drop pgpm made is of a relation it recorded
  for r in
    select h.* from pgpm_formal.drop_history h
     where h.by_pgpm and not h.is_temporary and h.schema_name not in ('pgpm', 'pgpm_formal', 'archive')
       and (p_scope is null or h.parent_oid::regclass = any (p_scope))
  loop
    n_rbr_id := n_rbr_id + 1;
    if r.recorded is false then
      invariant := 'ResolveByRecord'; parent_table := r.parent_oid::regclass;
      identity := r.schema_name || '.' || r.object_name;
      detail := format('pgpm dropped %s (oid %s), which pgpm did not create and no pgpm.part, pgpm.config or pgpm.scratch row named when it was dropped',
                       identity, r.objid);
      return next;
    end if;
  end loop;

  -- -------------------------------------------------- NoWedge, the state conjuncts
  -- (1) a retired chunk's relation is gone (#1160)
  for r in
    select l.parent_table as par, l.lo, l.hi, l.child_oid, c.oid is not null as present
      from pgpm.archive_ledger l left join pg_class c on c.oid = l.child_oid
     where l.retired_at is not null and (p_scope is null or l.parent_table = any (p_scope))
  loop
    n_wedge_id := n_wedge_id + 1;
    if r.child_oid is not null and r.present then
      invariant := 'NoWedge'; parent_table := r.par; identity := 'chunk ' || r.lo;
      detail := format('the chunk [%s, %s) is marked retired, and the relation it was read from (%s) still exists',
                       r.lo, r.hi, r.child_oid::regclass);
      return next;
    end if;
  end loop;
  -- (2) no regrain copy outlives its source (#519): a not-attached row lies inside an attached row's range
  for r in
    select p.parent_table as par, p.child_name, p.lo, p.hi, c.control_kind
      from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table
     where not p.attached and (p_scope is null or p.parent_table = any (p_scope))
  loop
    n_wedge_id := n_wedge_id + 1;
    declare v_src boolean;
    begin
      execute format(
        'select exists (select 1 from pgpm.part s join pg_class c on c.oid = s.child_oid
                         where s.parent_table = $1 and s.attached
                           and s.lo::%1$s <= $2::%1$s and $3::%1$s <= s.hi::%1$s)', pgpm._native_type(r.control_kind))
        into v_src using r.par, r.lo, r.hi;
      if not v_src then
        invariant := 'NoWedge'; parent_table := r.par; identity := 'copy ' || r.child_name;
        detail := format('the regrain copy %s of [%s, %s) has no attached source partition left to swap it in for',
                         r.child_name, r.lo, r.hi);
        return next;
      end if;
    exception when others then
      invariant := 'NoWedge'; parent_table := r.par; identity := 'copy ' || r.child_name;
      detail := format('the regrain copy %s could not be placed: %s', r.child_name, sqlerrm);
      return next;
    end;
  end loop;
  -- (3) no dispatched retirement mark stands on a partition nothing will detach: still attached, not pending, no
  -- recall in progress, and no pgpm_detach job holding its command. Judged only where cron.job can be read, or
  -- where pg_cron is absent (then no job can hold it).
  v_cron := case when to_regclass('cron.job') is null then 'absent'
                 when has_table_privilege('cron.job', 'select') then 'readable' else 'unreadable' end;
  for r in
    select p.parent_table as par, p.child_name, p.detach_dispatched_oid as rel, n.nspname, c.relname
      from pgpm.part p join pg_class c on c.oid = p.detach_dispatched_oid join pg_namespace n on n.oid = c.relnamespace
     where p.retiring_at is not null and p.recall_idle_at is null and p.recall_idle_xact is null
       and exists (select 1 from pg_inherits i where i.inhrelid = c.oid and i.inhparent = p.parent_table
                                                 and not i.inhdetachpending)
       and (p_scope is null or p.parent_table = any (p_scope))
  loop
    if v_cron = 'unreadable' then
      n_mark_unjudged := n_mark_unjudged + 1;
      continue;
    end if;
    n_wedge_id := n_wedge_id + 1;
    declare v_held boolean := false;
    begin
      if v_cron = 'readable' then
        execute 'select exists (select 1 from cron.job where jobname = ''pgpm_detach'' and command = $1)'
          into v_held using pgpm._detach_cmd(r.par, r.nspname, r.relname);
      end if;
      if not v_held then
        invariant := 'NoWedge'; parent_table := r.par; identity := 'mark ' || r.child_name;
        detail := format('%s is marked retiring with pgpm''s dispatch recorded, is still attached and not pending, and %s',
                         r.child_name, case when v_cron = 'absent' then 'pg_cron is not installed, so no job can detach it'
                                            else 'no pgpm_detach job holds its detach' end);
        return next;
      end if;
    end;
  end loop;

  -- -------------------------------------------------- what was judged
  delete from pgpm_formal.judged_last;
  insert into pgpm_formal.judged_last (invariant, judged, parents, identities, expected, note) values
    ('NoLostRow', n_lost_par > 0, n_lost_par, n_lost_id, 0,
     case when n_lost_par = 0 then 'not judged: no baseline' end
     || case when cardinality(v_unjudged_par) > 0 then format('; parents gone, not judged: %s', v_unjudged_par) else '' end),
    ('NoDuplicateRow', n_lost_par > 0, n_lost_par, n_lost_id, 0, case when n_lost_par = 0 then 'not judged: no baseline' end),
    ('DropOnlyCovered', n_doc_par > 0, n_doc_par, n_doc_id, 0,
     case when n_doc_par = 0 then 'not judged: no baselined parent with an archive strategy' end),
    ('ArchiveNoClobber', n_anc_par > 0, n_anc_par, n_anc_id, 0,
     case when n_anc_par = 0 then 'not judged: no baselined parent whose store was listed' end),
    ('ResolveByRecord', true, 0, n_rbr_id, 0, null),
    ('NoWedge', true, 0, n_wedge_id, 0,
     case when n_mark_unjudged > 0 then format('%s retirement mark(s) not judged: cron.job unreadable', n_mark_unjudged) end);
  update pgpm_formal.judged_last j set expected = (select count(*) from pgpm_formal.expectation e where e.invariant = j.invariant);
end;
$$;

-- check([scope]): one row per violation no expect() declared, plus one UnusedExpectation per declaration that
-- matched nothing. Empty means every invariant held for what it judged; pgpm_formal.judged() says what that was.
-- p_scope: only the parents named (the pg_cron files share `postgres`).
create or replace function pgpm_formal.check(p_scope regclass[] default null)
returns table (invariant text, parent_table regclass, identity text, detail text)
language sql as $$
  with f as materialized (select v.invariant, v.parent_table, v.identity collate "C" as identity, v.detail
                            from pgpm_formal._violations(p_scope) v),
       e as materialized (select x.invariant, x.identity, x.parent_oid, x.reason,
                                 exists (select 1 from f where f.invariant = x.invariant and f.identity = x.identity
                                                          and (x.parent_oid = 0 or x.parent_oid = f.parent_table::oid)) as used
                            from pgpm_formal.expectation x)
  select f.invariant, f.parent_table, f.identity::text, f.detail from f
   where not exists (select 1 from e where e.invariant = f.invariant and e.identity = f.identity
                                       and (e.parent_oid = 0 or e.parent_oid = f.parent_table::oid))
  union all
  select 'UnusedExpectation', nullif(e.parent_oid, 0)::regclass, e.invariant || ':' || e.identity,
         format('declared (%s), and no %s violation has this identity', e.reason, e.invariant)
    from e where not e.used;
$$;

-- judged(): per invariant, whether the last check() judged it, over how many parents and identities, and how many
-- violations of it the file declared. The oracle's liveness witness: a check() that judged nothing is not a pass.
create or replace function pgpm_formal.judged()
returns table (invariant text, judged boolean, parents int, identities bigint, expected int, note text)
language sql stable as $$
  select invariant, judged, parents, identities, expected, note from pgpm_formal.judged_last
   order by array_position(array['NoLostRow', 'NoDuplicateRow', 'DropOnlyCovered', 'ArchiveNoClobber',
                                 'ResolveByRecord', 'NoWedge'], invariant);
$$;
