-- 'infinity' and '-infinity' in a timestamptz or timestamp column of a Parquet file (issue #586).
--
-- Both are legal values of both types, and the usual "never expires" sentinel. The encoder wrote a
-- timestamp as round(extract(epoch from v) * 1e6)::int8, and extract(epoch) of an infinity is numeric
-- Infinity, which no int8 cast accepts: one such row raised 'cannot convert infinity to bigint' on
-- every encode of its chunk, so pgpm.maintain() logged skip_archive every tick, the partition was never
-- covered or retired, and at archive_batch's default of 1 (oldest first) every younger partition of
-- the table was held up behind it. archive._pq_epoch_micros now writes them as INT64 max and minus
-- INT64 max, the pair DuckDB's reader decodes as infinity and -infinity.
--
-- The encoded values are asserted by identity against little-endian bytes derived OUTSIDE PostgreSQL:
--
--   for v in (2**63 - 1, -(2**63 - 1)): print(v.to_bytes(8, 'little', signed=True).hex())
--   -> ffffffffffffff7f, 0100000000000080
--
-- and the finite row against the microsecond epochs tests/archive/db/14 already pins. The fixture is
-- asymmetric (the two columns hold the two infinities in opposite rows, with a finite row between),
-- and the tick half is the issue's own: two aged partitions, only the OLDER one holding an infinity.
-- Its negative ("no tick skipped the archive step") is paired with witnesses that the conditions for a
-- skip were present: the older partition really holds the infinity, and archive_batch really is 1.
-- The files are kept in t19.enc for bench/archive_parquet_timestamp_infinity.sh, whose pyarrow and
-- DuckDB half reads them back.
select plan(15);

create schema t19;
create table t19.enc (label text primary key, bytes bytea not null);

create table public.inf19 (id int4 primary key, ts timestamp not null, tstz timestamptz not null);
insert into public.inf19 values
  (1, 'infinity',            '-infinity'),
  (2, '2024-01-15 12:00:00', '2024-01-15 18:30:00+00'),
  (3, '-infinity',           'infinity');

-- ---------------------------------------------------------------------------
-- Witness: the hazard is present in this server
-- ---------------------------------------------------------------------------

select throws_ok($$ select round(extract(epoch from 'infinity'::timestamptz) * 1000000)::int8 $$, '0A000', 'cannot convert infinity to bigint',
  'witness: the cast the encoder used raises for an infinite timestamptz');

select is((select array_agg(isfinite(ts) order by id) || array_agg(isfinite(tstz) order by id) from public.inf19),
  array[false, true, false, false, true, false],
  'witness: rows 1 and 3 hold an infinity in both columns, row 2 is finite');

-- ---------------------------------------------------------------------------
-- The encoder writes them, as the sentinels
-- ---------------------------------------------------------------------------

-- (the sentinels themselves are asserted in the pages below, where a raise cannot abort the file)
select is(archive._pq_epoch_micros('2024-01-15 18:30:00+00'), 1705343400000000::int8,
  'and a finite instant is still its microseconds since the Unix epoch');

select lives_ok($$ insert into t19.enc values ('whole', archive._pq_to_parquet('public.inf19', false)) $$,
  'archive._pq_to_parquet encodes the table');
select lives_ok($$ insert into t19.enc values ('range', archive._pq_to_parquet_range('public.inf19', 'id', '0', '10', false)) $$,
  'and so does archive._pq_to_parquet_range');

-- p_compress => false and every column NOT NULL: PAR1, then id's page header and 3 x 4 bytes, ts's
-- page header and 3 x 8 bytes, then tstz's.
select 4 + length(archive._pq_build_page_header(3, 12)) + 12 + length(archive._pq_build_page_header(3, 24)) as ts_off \gset
select :ts_off + 24 + length(archive._pq_build_page_header(3, 24)) as tstz_off \gset

select is((select substring(bytes from :ts_off + 1 for 24) from t19.enc where label = 'whole'),
  '\xffffffffffffff7f'::bytea || archive._pq_plain_int64(1705320000000000) || '\x0100000000000080'::bytea,
  'archive._pq_to_parquet writes ts as infinity, the wall clock read as UTC, and -infinity');
select is((select substring(bytes from :tstz_off + 1 for 24) from t19.enc where label = 'whole'),
  '\x0100000000000080'::bytea || archive._pq_plain_int64(1705343400000000) || '\xffffffffffffff7f'::bytea,
  'and tstz as -infinity, the instant, and infinity');
select is((select substring(bytes from :ts_off + 1 for 24) from t19.enc where label = 'range'),
  '\xffffffffffffff7f'::bytea || archive._pq_plain_int64(1705320000000000) || '\x0100000000000080'::bytea,
  'archive._pq_to_parquet_range writes the same ts page');
select is((select substring(bytes from :tstz_off + 1 for 24) from t19.enc where label = 'range'),
  '\x0100000000000080'::bytea || archive._pq_plain_int64(1705343400000000) || '\xffffffffffffff7f'::bytea,
  'and the same tstz page');

-- ---------------------------------------------------------------------------
-- The issue's tick: the partition holding the infinity is archived, and the one behind it too
-- ---------------------------------------------------------------------------

create table public.infm19 (id bigint primary key, expires_at timestamptz);
insert into public.infm19 select g, now() from generate_series(1, 20) g;
update public.infm19 set expires_at = 'infinity' where id = 7;
call pgpm.transmute('public.infm19', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into public.infm19 select g, now() from generate_series(10000, 10009) g;
insert into public.infm19 values (45000, now());
select mk_archive_config('infm19', false);
update pgpm.config set retain_batch = 0 where parent_table = 'public.infm19'::regclass;
select pgpm.set_archive_fn('public.infm19', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);

select is((select archive_batch from pgpm.config where parent_table = 'public.infm19'::regclass), 1,
  'witness: archive_batch is at its default of 1, so a wedged oldest partition holds up the next');
select is((select array_agg(lo::bigint order by lo::bigint) from pgpm.part
            where parent_table = 'public.infm19'::regclass and lo::bigint in (0, 10000)),
  array[0, 10000]::bigint[], 'witness: partitions [0, 10000) and [10000, 20000) exist below the 40000 horizon');
select is((select expires_at from public.infm19 where id = 7), 'infinity'::timestamptz,
  'witness: row 7, in the older partition, expires at infinity');

call pgpm.maintain('public.infm19');
call pgpm.maintain('public.infm19');

select is((select array_agg(lo::bigint order by lo::bigint) from pgpm.archive_ledger where parent_table = 'public.infm19'::regclass),
  array[0, 10000]::bigint[],
  'two ticks archived [0, 10000), the partition holding the infinity, and then [10000, 20000)');
select is((select array_agg(rows_archived order by lo::bigint) from pgpm.archive_ledger where parent_table = 'public.infm19'::regclass),
  array[20, 10]::bigint[],
  'the older file holds all 20 of its rows, the younger all 10 of its');
select is((select count(*) from pgpm.log where parent_table = 'public.infm19'::regclass and action = 'skip_archive'), 0::bigint,
  'no tick skipped the archive step');

select * from finish();
