-- pgpm._over_retired_chunks reads the retired chunks that can overlap an attached partition, not the parent's
-- whole archive history (issue #1163).
--
-- THE DEFECT. _over_retired_chunks finds the attached partitions over a retired chunk's range (#1141), which the
-- archive step skips and retain() leaves out of its batch. It materialised EVERY retired pgpm.archive_ledger row
-- of the parent, with a pg_class or to_regclass probe per row for the text describing it, and only then filtered
-- by range. A retired row is never discarded (it is the record of the only copy), so the parent's history only
-- grows, and every tick with an archive_fn calls this twice (_archive_step and retain()): at 300,000 retired rows
-- one call read all 300,000 to hold nothing, about 0.4 s, linear beyond.
--
-- THE CONTRACT.
--   * A call reads only the retired rows that end above the lowest attached partition's lo (plus any whose bound
--     has no order key, see below): in the ordinary run of things, where retain() drops oldest first and every
--     retired chunk lies below every attached partition, that is none of them.
--   * What it returns is unchanged: exactly the attached partitions over a retired chunk's range, each with
--     exactly those chunks described, compared in the native type (a time bound's offset counts, its text order
--     does not), from any session's TimeZone and DateStyle.
--   * The index that read goes through rebuilds where PostgreSQL builds it in parallel (part D).
--
-- THE INSTRUMENT. pg_stat_get_xact_tuples_returned/_fetched over pgpm.archive_ledger and its indexes, read before
-- and after the call inside one function, so in the same transaction (the cumulative counters flush only at
-- transaction end; the xact ones count as the scan runs). Its liveness: a plain read of the retired rows moves
-- it by at least their number.
--
-- ASYMMETRIC FIXTURES. t317.a (id) has 30,000 retired chunks far below it, then two over its [0, 100) partition
-- and one over [100, 200); t317.b (time) has 2,000 far below, one just below its first partition whose TEXT
-- sorts above that partition's lo, and two over it, one of them with an offset-less bound. Each check names the
-- partitions and the chunks.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(13);

create schema t317;

-- ledger tuples (heap rows returned or fetched, index entries returned) read so far in this transaction
create function t317.ledger_counter() returns bigint language sql volatile as $$
  select pg_stat_get_xact_tuples_returned('pgpm.archive_ledger'::regclass)
       + pg_stat_get_xact_tuples_fetched('pgpm.archive_ledger'::regclass)
       + coalesce((select sum(pg_stat_get_xact_tuples_returned(i.indexrelid))::bigint
                     from pg_index i where i.indrelid = 'pgpm.archive_ledger'::regclass), 0);
$$;
-- run p_sql and say how many ledger tuples it read, in one transaction
create function t317.reads_of(p_sql text) returns bigint language plpgsql as $$
declare v_before bigint := t317.ledger_counter();
begin
  execute p_sql;
  return t317.ledger_counter() - v_before;
end;
$$;
-- what the call holds, one line per partition, in native order
create function t317.held(p_parent regclass) returns text language sql as $$
  select coalesce(string_agg(format('%s [%s, %s): %s / %s', o.child_name, o.lo, o.hi, o.chunks,
                                    coalesce(o.other_names, '-')), E'\n' order by o.child_name), '')
    from pgpm._over_retired_chunks(p_parent) o;
$$;

-- A. id kind: 30,000 retired chunks, every one below every attached partition.
create table t317.a (id bigint primary key, payload text not null);
insert into t317.a select g, 'old' || g from generate_series(1, 90) g;
call pgpm.transmute('t317.a', 'id', 100, p_retain => 100::bigint, p_paused => true);
insert into t317.a values (450, 'frontier');
select pgpm.set_archive_fn('t317.a', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, retired_at, child_oid)
select 't317.a'::regclass, (-1000000 + g)::text, (-1000000 + g + 1)::text, 'gone_' || (g / 100), now(), 4000000000 + g
  from generate_series(0, 29999) g;

select is((select count(*) from pgpm.archive_ledger l
            where l.parent_table = 't317.a'::regclass and l.retired_at is not null and l.child_name like 'gone\_%'
              and l.hi::numeric <= (select min(p.lo::numeric) from pgpm.part p
                                     where p.parent_table = 't317.a'::regclass and p.attached)),
          30000::bigint,
          'LIVENESS: 30,000 retired chunks are recorded for t317.a, every one ending at or below its lowest attached partition');
select cmp_ok(t317.reads_of($$select count(*) from pgpm.archive_ledger
                               where parent_table = 't317.a'::regclass and retired_at is not null
                                 and child_name like 'gone\_%'$$), '>=', 30000::bigint,
              'LIVENESS: the instrument sees a read of those rows (ledger tuples it counts for one plain read of them)');
select is(t317.held('t317.a'), '', 'LIVENESS: no attached partition of t317.a is over a retired chunk, so the call holds none');
select cmp_ok(t317.reads_of($$select count(*) from pgpm._over_retired_chunks('t317.a')$$), '<', 100::bigint,
              'a call with every retired chunk below every attached partition reads a bounded slice of the ledger, not all 30,000 retired rows');

-- B. Three retired chunks over two of t317.a's attached partitions: two over [0, 100), one over [100, 200).
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid) values
  ('t317.a', '20', '35', 'gone_b1', 'obj/20', now(), 4100000001),
  ('t317.a', '35', '60', 'gone_b2', null, now(), 4100000002),
  ('t317.a', '150', '170', 'gone_b3', 'obj/150', now(), null);
select is(t317.held('t317.a'),
          'a_p0000000000000000000 [0, 100): [20, 35) recorded for gone_b1, whose relation no longer exists, at obj/20; '
            || '[35, 60) recorded for gone_b2, whose relation no longer exists, at no object key / gone_b1, gone_b2' || E'\n'
            || 'a_p0000000000000000100 [100, 200): [150, 170) recorded for gone_b3, whose relation no longer exists, at obj/150 / gone_b3',
          'the call holds exactly [0, 100) over gone_b1 and gone_b2 and [100, 200) over gone_b3, and nothing of the 30,000 below');
select cmp_ok(t317.reads_of($$select count(*) from pgpm._over_retired_chunks('t317.a')$$), '<', 100::bigint,
              'holding two partitions, the call still reads a bounded slice of the ledger');

-- C. time kind, where a bound's text order is not its order: one chunk ends below the first partition's lo as an
-- instant but above it as text, one the reverse, and one has an offset-less bound.
create table t317.b (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into t317.b (ts) select timestamptz '2026-01-05 00:00:00+00' + g * interval '1 hour' from generate_series(1, 90) g;
call pgpm.transmute('t317.b', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select pgpm.set_archive_fn('t317.b', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, retired_at, child_oid)
select 't317.b'::regclass, pgpm._ts_text(timestamptz '2020-01-01 00:00:00+00' + g * interval '1 hour'),
       pgpm._ts_text(timestamptz '2020-01-01 00:00:00+00' + (g + 1) * interval '1 hour'), 'old_' || (g / 100), now(), 4200000000 + g
  from generate_series(0, 1999) g;
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid) values
  ('t317.b', '2025-12-31 20:00:00+00', '2026-01-01 04:00:00+05:30', 'gone_x', 'obj/x', now(), 4290000001),
  ('t317.b', '2025-12-31 18:00:00-05', '2025-12-31 23:00:00-05', 'gone_y', 'obj/y', now(), 4290000002),
  ('t317.b', '2026-01-10 00:00:00', '2026-01-11 00:00:00', 'gone_z', 'obj/z', now(), 4290000003);

select ok((select p.lo = '2026-01-01 00:00:00+00'
                  and '2026-01-01 04:00:00+05:30'::timestamptz <= p.lo::timestamptz and '2026-01-01 04:00:00+05:30' > p.lo
                  and '2025-12-31 23:00:00-05'::timestamptz > p.lo::timestamptz and '2025-12-31 23:00:00-05' < p.lo
             from pgpm.part p where p.parent_table = 't317.b'::regclass and p.child_name = 'b_p2026_01_to_2026_11'),
          'LIVENESS: gone_x ends below the first partition''s lo as an instant and above it as text, gone_y the reverse');
select is(t317.held('t317.b'),
          'b_p2026_01_to_2026_11 [2026-01-01 00:00:00+00, 2026-11-01 00:00:00+00): '
            || '[2025-12-31 18:00:00-05, 2025-12-31 23:00:00-05) recorded for gone_y, whose relation no longer exists, at obj/y; '
            || '[2026-01-10 00:00:00, 2026-01-11 00:00:00) recorded for gone_z, whose relation no longer exists, at obj/z / gone_y, gone_z',
          'the call holds the first partition over gone_y (offset counted) and gone_z (offset-less), not over gone_x');
select cmp_ok(t317.reads_of($$select count(*) from pgpm._over_retired_chunks('t317.b')$$), '<', 100::bigint,
              'on a time parent the call reads a bounded slice of the ledger, not all 2,000 retired rows below it');

-- The same call from a session on another zone and DateStyle holds the same chunks: a bound with an offset is the
-- same instant there, and gone_z's offset-less bound, read in +05:30, still lies inside January.
set timezone = 'Asia/Kolkata';
set datestyle = 'SQL, DMY';
select is(t317.held('t317.b'),
          'b_p2026_01_to_2026_11 [2026-01-01 00:00:00+00, 2026-11-01 00:00:00+00): '
            || '[2025-12-31 18:00:00-05, 2025-12-31 23:00:00-05) recorded for gone_y, whose relation no longer exists, at obj/y; '
            || '[2026-01-10 00:00:00, 2026-01-11 00:00:00) recorded for gone_z, whose relation no longer exists, at obj/z / gone_y, gone_z',
          'from SQL, DMY in Asia/Kolkata the call holds the same partition over the same two chunks');
reset datestyle;
set timezone = 'UTC';

-- An attached partition whose lo is offset-less text (pgpm writes none, an operator's hand might): the call still
-- finds every chunk over it.
update pgpm.part set lo = '2026-01-01 00:00:00'
 where parent_table = 't317.b'::regclass and child_name = 'b_p2026_01_to_2026_11';
select is(t317.held('t317.b'),
          'b_p2026_01_to_2026_11 [2026-01-01 00:00:00, 2026-11-01 00:00:00+00): '
            || '[2025-12-31 18:00:00-05, 2025-12-31 23:00:00-05) recorded for gone_y, whose relation no longer exists, at obj/y; '
            || '[2026-01-10 00:00:00, 2026-01-11 00:00:00) recorded for gone_z, whose relation no longer exists, at obj/z / gone_y, gone_z',
          'with an offset-less lo on the partition, the call holds it over the same two chunks');

-- D. Every build of archive_ledger_retired_hi_key_idx evaluates pgpm._native_order_key, and PostgreSQL builds a btree
-- in parallel once the ledger passes min_parallel_table_scan_size (8 MB by default, about 55,000 rows). The function's
-- EXCEPTION block starts a subtransaction, which parallel mode refuses on PostgreSQL 15 and 16 ('cannot start
-- subtransactions during a parallel operation'), so a function marked parallel safe made the upgrade's CREATE INDEX
-- over a long history and a REINDEX fail there (PR #1189's V-01). 17 and later admit the subtransaction, so there the
-- rebuild passes either way and the declaration is what holds the contract. The threshold is lowered here so this
-- file's 32,000 rows qualify; bench/over_retired_chunks_range_first.sh witnesses that a build over them goes parallel.
select is((select proparallel::text from pg_proc where oid = 'pgpm._native_order_key(text)'::regprocedure), 'u',
          'pgpm._native_order_key is parallel unsafe (its EXCEPTION block starts a subtransaction)');
set min_parallel_table_scan_size = 0;
set max_parallel_maintenance_workers = 2;
set maintenance_work_mem = '256MB';
select lives_ok('reindex index pgpm.archive_ledger_retired_hi_key_idx',
                'archive_ledger_retired_hi_key_idx rebuilds over 32,000 ledger rows with parallel maintenance workers allowed');
reset maintenance_work_mem;
reset max_parallel_maintenance_workers;
reset min_parallel_table_scan_size;

select * from finish();
