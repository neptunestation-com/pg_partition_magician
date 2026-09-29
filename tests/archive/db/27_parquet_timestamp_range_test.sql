-- A FINITE timestamp past the int64 microsecond range in a timestamptz or timestamp column of a Parquet
-- file (issue #664).
--
-- archive._pq_epoch_micros (#586) wrote the infinities as the INT64 sentinels and every finite value as
-- round(extract(epoch from v) * 1e6)::int8. PostgreSQL's range, counted on its year-2000 epoch, runs to
-- 294276 AD, about 30 years past 294247-01-10 04:00:54.775807 UTC, the instant INT64 microseconds since
-- 1970 run out at. Past it the cast raised 22003 'bigint out of range' on every encode of the chunk, so
-- pgpm.maintain() logged skip_archive every tick and the partition was never archived or retired, the
-- #586 wedge again for a finite value. Just past it, before the cast overflows, extract(epoch) had
-- already fallen back to float8 precision, so the encoder returned a number SMALLER than the last exact
-- instant's: out of order, not merely clamped. A finite value past the range is now written as INT64
-- max minus 1, the largest value DuckDB's reader still decodes as finite (INT64 max itself is the
-- +infinity sentinel, which it must not collide with).
--
-- The encoded values are asserted by identity against numbers and little-endian bytes derived OUTSIDE
-- PostgreSQL:
--
--   for v in (2**63 - 1, 2**63 - 2, 2**63 - 3): print(v, v.to_bytes(8, 'little', signed=True).hex())
--   -> ffffffffffffff7f, feffffffffffff7f, fdffffffffffff7f
--
-- and 2**63 - 2 microseconds after 1970-01-01 is 294247-01-10 04:00:54.775806 UTC (days-to-civil over
-- divmod(2**63 - 2, 86400 * 10**6)), while 4713-01-01 BC (proleptic year -4712) is 2440550 days before
-- 1970 (days-from-civil, which also puts Julian day 0, 4714-11-24 BC, at -2440588). The 2024 values are
-- the microsecond epochs tests/archive/db/14 and 19 already pin. The fixture is asymmetric: the
-- far-future value sits in a different row of each column, the other column's value in that row is
-- finite and ordinary, and the third row holds the last exact instant but one, so a clamp that bit one
-- microsecond early would show.
-- The tick half is the issue's own: two aged partitions, only the OLDER one holding the far-future
-- value. Its negative ("no tick skipped the archive step") is paired with witnesses that the conditions
-- for a skip were present. The files are kept in t27.enc for bench/archive_parquet_timestamp_range.sh,
-- whose pyarrow and DuckDB half reads them back.
select plan(17);

create schema t27;
create table t27.enc (label text primary key, bytes bytea not null);

create table public.far27 (id int4 primary key, ts timestamp not null, tstz timestamptz not null);
insert into public.far27 values
  (1, '294276-12-31 23:59:59.999999', '2024-01-15 18:30:00+00'),
  (2, '2024-01-15 12:00:00',          '294247-01-10 04:00:54.775807+00'),
  (3, '294247-01-10 04:00:54.775805', 'infinity');

-- ---------------------------------------------------------------------------
-- Witness: the hazard is present in this server
-- ---------------------------------------------------------------------------

select throws_ok($$ select round(extract(epoch from '294250-01-01 00:00:00+00'::timestamptz) * 1000000)::int8 $$,
  '22003', 'bigint out of range',
  'witness: the cast the encoder used raises for a finite timestamptz past the int64 microsecond range');
select ok((select bool_and(isfinite(ts) and isfinite(tstz)) from public.far27 where id in (1, 2)),
  'witness: the far-future values in rows 1 and 2 are finite, not the infinities #586 already handles');

-- ---------------------------------------------------------------------------
-- The helper: exact up to the last instant, saturated past it, the infinities untouched
-- ---------------------------------------------------------------------------

-- Every value goes through one lives_ok into t27.micros, so a helper that raises fails that assertion
-- and leaves the identities below to fail on an empty table, rather than aborting the file.
create table t27.micros (label text, n int4, micros int8);
select lives_ok($$
  insert into t27.micros
  select 'step', n, archive._pq_epoch_micros('294247-01-10 04:00:54.775803+00'::timestamptz + n * interval '1 microsecond')
    from generate_series(0, 6) n
  union all
  select label, 0, archive._pq_epoch_micros(v::timestamptz)
    from (values ('294250', '294250-01-01 00:00:00+00'), ('294276', '294276-12-31 23:59:59.999999+00'),
                 ('infinity', 'infinity'), ('4713 BC', '4713-01-01 00:00:00+00 BC')) x(label, v) $$,
  'archive._pq_epoch_micros encodes every finite timestamptz PostgreSQL accepts without raising');

-- 294247-01-10 04:00:54.775803 to .775809 UTC, one microsecond apart: 2**63 - 5 to 2**63 - 2 exactly,
-- then held at 2**63 - 2. The pre-fix encoder gave 9223372036854775800 from .775807 on, below .775806's.
select is((select array_agg(micros order by n) from t27.micros where label = 'step'),
  array[9223372036854775803, 9223372036854775804, 9223372036854775805, 9223372036854775806,
        9223372036854775806, 9223372036854775806, 9223372036854775806]::int8[],
  'microseconds across the ceiling: exact up to 294247-01-10 04:00:54.775806 UTC, then held at INT64 max minus 1');
select is((select micros from t27.micros where label = '294250'), 9223372036854775806::int8,
  'a finite timestamptz in 294250 AD is written as INT64 max minus 1');
select is((select micros from t27.micros where label = '294276'), 9223372036854775806::int8,
  'and so is the largest timestamptz PostgreSQL accepts');
select is((select micros from t27.micros where label = 'infinity'), 9223372036854775807::int8,
  'infinity is still INT64 max, one above every finite value');
select is((select micros from t27.micros where label = '4713 BC'), -210863520000000000::int8,
  'the far past needs no clamp: 4713 BC is its exact microseconds, nowhere near the negative sentinel');

-- ---------------------------------------------------------------------------
-- Both encoders write the table, the far-future values as the ceiling
-- ---------------------------------------------------------------------------

select lives_ok($$ insert into t27.enc values ('whole', archive._pq_to_parquet('public.far27', false)) $$,
  'archive._pq_to_parquet encodes the table');
select lives_ok($$ insert into t27.enc values ('range', archive._pq_to_parquet_range('public.far27', 'id', '0', '10', false)) $$,
  'and so does archive._pq_to_parquet_range');

-- p_compress => false and every column NOT NULL: PAR1, then id's page header and 3 x 4 bytes, ts's
-- page header and 3 x 8 bytes, then tstz's.
select 4 + length(archive._pq_build_page_header(3, 12)) + 12 + length(archive._pq_build_page_header(3, 24)) as ts_off \gset
select :ts_off + 24 + length(archive._pq_build_page_header(3, 24)) as tstz_off \gset

select is((select substring(bytes from :ts_off + 1 for 24) from t27.enc where label = 'whole'),
  '\xfeffffffffffff7f'::bytea || '\x0010d4c0fa0e0600'::bytea || '\xfdffffffffffff7f'::bytea,
  'archive._pq_to_parquet writes ts as the ceiling, the 2024 wall clock read as UTC, and INT64 max minus 2');
select is((select substring(bytes from :tstz_off + 1 for 24) from t27.enc where label = 'whole'),
  '\x00ba9333000f0600'::bytea || '\xfeffffffffffff7f'::bytea || '\xffffffffffffff7f'::bytea,
  'and tstz as the 2024 instant, the ceiling, and infinity');
select is((select substring(bytes from :ts_off + 1 for 24) from t27.enc where label = 'range'),
  '\xfeffffffffffff7f'::bytea || '\x0010d4c0fa0e0600'::bytea || '\xfdffffffffffff7f'::bytea,
  'archive._pq_to_parquet_range writes the same ts page');
select is((select substring(bytes from :tstz_off + 1 for 24) from t27.enc where label = 'range'),
  '\x00ba9333000f0600'::bytea || '\xfeffffffffffff7f'::bytea || '\xffffffffffffff7f'::bytea,
  'and the same tstz page');

-- ---------------------------------------------------------------------------
-- The issue's tick: the partition holding the far-future value is archived, and the one behind it too
-- ---------------------------------------------------------------------------

create table public.far27m (id bigint primary key, expires_at timestamptz);
insert into public.far27m select g, now() from generate_series(1, 20) g;
update public.far27m set expires_at = '294250-01-01 00:00:00+00' where id = 7;
call pgpm.transmute('public.far27m', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into public.far27m select g, now() from generate_series(10000, 10009) g;
insert into public.far27m values (45000, now());
select mk_archive_config('far27m', false);
update pgpm.config set retain_batch = 0 where parent_table = 'public.far27m'::regclass;
select pgpm.set_archive_fn('public.far27m', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);

select ok((select archive_batch = 1 from pgpm.config where parent_table = 'public.far27m'::regclass)
          and (select array_agg(lo::bigint order by lo::bigint) from pgpm.part
                where parent_table = 'public.far27m'::regclass and lo::bigint in (0, 10000)) = array[0, 10000]::bigint[]
          and (select expires_at from public.far27m where id = 7) = '294250-01-01 00:00:00+00'::timestamptz,
  'witness: archive_batch is 1, [0, 10000) and [10000, 20000) sit below the 40000 horizon, and row 7 of the older expires in 294250 AD');

call pgpm.maintain('public.far27m');
call pgpm.maintain('public.far27m');

select is((select array_agg(lo::bigint || ':' || rows_archived order by lo::bigint) from pgpm.archive_ledger
            where parent_table = 'public.far27m'::regclass),
  array['0:20', '10000:10'],
  'two ticks archived [0, 10000), the partition holding the far-future row, with all 20 rows, and then [10000, 20000) with its 10');
select is((select count(*) from pgpm.log where parent_table = 'public.far27m'::regclass and action = 'skip_archive'), 0::bigint,
  'no tick skipped the archive step');

select * from finish();
