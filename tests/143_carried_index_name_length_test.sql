-- Issue #592: the cutover recreates each carried secondary index on the new parent as <index>_pgpm, and
-- that name was cast to name with no length check. For an index whose name is already 63 bytes, which is
-- exactly what PostgreSQL's own auto-naming produces for a long table and column list, the cast cut the
-- suffix off again and handed back the index's OWN name. The #311 collision guard then found that name
-- taken and refused, calling it a leftover of an interrupted run and telling the operator to drop it: the
-- name resolved to their own index. Shorter overlong names (59 to 62 bytes) truncated to a name that was
-- merely wrong. reference.md promises names pgpm derives are never truncated; transmute's preflight
-- enforced that for the monolith, cell and staging names only. It now refuses an overlong <index>_pgpm
-- up front too, naming the index and the byte budget, before the collision guard can misread it.
--
-- Two secondary indexes, one at the 63-byte auto-named limit and one well inside it, so the refusal has to
-- name WHICH index is too long (a refusal listing both, or neither, is wrong). The refusal is pinned by
-- its message: transmute is a committing procedure, and an unpinned throws_* would accept the 2D000 a
-- conversion that did NOT refuse raises at its first COMMIT inside the pgTAP wrapper. Then the same table,
-- with the long index renamed to 58 bytes (the most <index>_pgpm leaves room for), really converts and
-- carries both indexes under their full _pgpm names.
create extension if not exists pgtap;

select plan(10);
set timezone = 'UTC';

create table public.customer_activity_event_log_archive_v143 (
  id bigint, occurred_at_utc_timestamp timestamptz not null, primary key (id, occurred_at_utc_timestamp));
create index on public.customer_activity_event_log_archive_v143 (occurred_at_utc_timestamp, id);   -- auto-named
create index ev143_short_idx on public.customer_activity_event_log_archive_v143 (id);
insert into public.customer_activity_event_log_archive_v143
  values (1, now() - interval '3 days'), (2, now() - interval '1 day');

-- ============================================== before: the two indexes, and their byte lengths
select is(
  (select array_agg(octet_length(c.relname) order by octet_length(c.relname))
     from pg_index i join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public.customer_activity_event_log_archive_v143'::regclass and not i.indisprimary),
  array[15, 63],
  'LIVENESS: PostgreSQL auto-named one secondary index at the full 63 bytes; the other is 15');
select is(
  (select c.relname::text from pg_index i join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public.customer_activity_event_log_archive_v143'::regclass and not i.indisprimary
      and octet_length(c.relname) = 63),
  'customer_activity_event_log_ar_occurred_at_utc_timestamp_id_idx',
  'LIVENESS: the 63-byte index is the one PostgreSQL named, and <it>_pgpm casts back to exactly it');
select is(('customer_activity_event_log_ar_occurred_at_utc_timestamp_id_idx' || '_pgpm')::name::text,
          'customer_activity_event_log_ar_occurred_at_utc_timestamp_id_idx',
  'LIVENESS: a name cast of <index>_pgpm truncates to the index''s own name');

-- ============================================== the refusal names the long index and the budget
select throws_like(
  $$ call pgpm.transmute('public.customer_activity_event_log_archive_v143', 'occurred_at_utc_timestamp', interval '1 month') $$,
  'pg_partition_magician: cannot transmute customer_activity_event_log_archive_v143 -- the secondary index(es) (customer_activity_event_log_ar_occurred_at_utc_timestamp_id_idx (63 bytes)) have names too long for their partitioned copies%at most 58 bytes%',
  'transmute refuses the 63-byte index as too long to carry, naming it (and not the 15-byte one)');
select is((select relkind::text from pg_class where oid = 'public.customer_activity_event_log_archive_v143'::regclass), 'r',
  'the refused table is untouched: still a plain table');
select ok(to_regclass('public.customer_activity_event_log_ar_occurred_at_utc_timestamp_id_idx') is not null
          and to_regclass('public.ev143_short_idx') is not null,
  'both of the operator''s indexes are still there');

-- ============================================== renamed to fit: the conversion completes
alter index public.customer_activity_event_log_ar_occurred_at_utc_timestamp_id_idx
  rename to customer_activity_event_log_ar_occurred_at_utc_timestamp_i;   -- 58 bytes
select is(octet_length('customer_activity_event_log_ar_occurred_at_utc_timestamp_i'), 58,
  'LIVENESS: the renamed index is 58 bytes, exactly the most <index>_pgpm can carry');
call pgpm.transmute('public.customer_activity_event_log_archive_v143', 'occurred_at_utc_timestamp', interval '1 month');
select is((select relkind::text from pg_class where oid = 'public.customer_activity_event_log_archive_v143'::regclass), 'p',
  'with the index renamed to fit, the table converts');
select is(
  (select array_agg(c.relname::text order by c.relname)
     from pg_index i join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public.customer_activity_event_log_archive_v143'::regclass and not i.indisprimary),
  array['customer_activity_event_log_ar_occurred_at_utc_timestamp_i_pgpm', 'ev143_short_idx_pgpm'],
  'the parent carries both secondary indexes under their full, untruncated _pgpm names');
select ok(exists (select 1 from pg_inherits h
                   where h.inhparent = 'public.customer_activity_event_log_ar_occurred_at_utc_timestamp_i_pgpm'::regclass
                     and h.inhrelid = 'public.customer_activity_event_log_ar_occurred_at_utc_timestamp_i'::regclass),
  'the operator''s own index is attached under its partitioned copy, not dropped');

select * from finish();
