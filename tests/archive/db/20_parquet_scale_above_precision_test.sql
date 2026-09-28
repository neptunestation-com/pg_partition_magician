-- A numeric(p,s) column whose scale is ABOVE its precision in a Parquet file (issue #596).
--
-- PostgreSQL 15 and later accept numeric(2,4), which holds -0.0099..0.0099. Both encoders copied
-- (precision 2, scale 4) straight into the DECIMAL leaf, and Parquet requires scale <= precision:
-- pyarrow refuses the whole file ("Invalid DECIMAL scale 4 cannot be greater than precision 2"), while
-- the upload and the ledger row succeeded. The leaf's shape now comes from archive._pq_decimal_shape,
-- which declares such a column DECIMAL(s, s): its values are below 10^(p-s) <= 1 in magnitude, so
-- their unscaled integers have at most s digits and are written unchanged.
--
-- The values are asserted by identity against big-endian two's complement bytes derived OUTSIDE
-- PostgreSQL, so nothing shares an operator with the code under test:
--
--   for v in (12, -99, 50): print(v, v.to_bytes(2, 'big', signed=True).hex())   # value * 10^4
--   -> 000c, ff9d, 0032        (2 bytes: DECIMAL(4,4)'s 10^4 - 1 needs 14 bits plus the sign)
--
-- Every negative is paired with a witness that its condition was present: the column really is
-- numeric(2,4) by PostgreSQL's own rendering, 0.01 really is outside it (so the widening loses
-- nothing), and the byte match that finds no DECIMAL(2,4) leaf finds the DECIMAL(4,4) twin's leaf. The
-- files are kept in t20.enc for bench/archive_parquet_scale_above_precision.sh, whose pyarrow half is
-- the reader the issue names.
select plan(14);

create schema t20;
create table t20.enc (label text primary key, bytes bytea not null);

create table public.sp20 (id int4 primary key, w numeric(2,4) not null);
insert into public.sp20 values (1, 0.0012), (2, -0.0099), (3, 0.0050);
create table public.twin20 (id int4 primary key, w numeric(4,4) not null);
insert into public.twin20 values (1, 0.0012), (2, -0.0099), (3, 0.0050);

-- ---------------------------------------------------------------------------
-- Witnesses: the column shape, and what it can hold
-- ---------------------------------------------------------------------------

select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.sp20'::regclass and attname = 'w'),
  'numeric(2,4)', 'witness: PostgreSQL itself renders the column as numeric(2,4), scale above precision');

select throws_ok($$ insert into public.sp20 values (9, 0.01) $$, '22003', NULL,
  'witness: 0.01 does not fit numeric(2,4), so every value it holds has at most four digits after the point and none before');

select is((select array_agg(w order by id) from public.sp20), array[0.0012, -0.0099, 0.0050]::numeric[],
  'witness: the column holds 0.0012, -0.0099 and 0.0050');

-- ---------------------------------------------------------------------------
-- The shape the leaf declares
-- ---------------------------------------------------------------------------

select is((select row(d.p_precision, d.p_scale)::text from archive._pq_decimal_shape(
             (select atttypmod from pg_attribute where attrelid = 'public.sp20'::regclass and attname = 'w')) d),
  '(4,4)', 'numeric(2,4) is written as DECIMAL(4,4), a precision that covers its scale');

select is((select row(d.p_precision, d.p_scale)::text from archive._pq_decimal_shape(
             (select atttypmod from pg_attribute where attrelid = 'public.twin20'::regclass and attname = 'w')) d),
  '(4,4)', 'and numeric(4,4) keeps its own shape');

insert into t20.enc values
  ('whole', archive._pq_to_parquet('public.sp20', false)),
  ('range', archive._pq_to_parquet_range('public.sp20', 'id', '0', '10', false)),
  ('twin_whole', archive._pq_to_parquet('public.twin20', false)),
  ('twin_range', archive._pq_to_parquet_range('public.twin20', 'id', '0', '10', false));

select ok(position(archive._pq_build_schema_leaf('w', 7, 5, false, 2, 4, 4) in bytes) > 0,
  'archive._pq_to_parquet declares w as DECIMAL(4,4) in 2 bytes')
  from t20.enc where label = 'whole';
select ok(position(archive._pq_build_schema_leaf('w', 7, 5, false, 2, 4, 4) in bytes) > 0,
  'archive._pq_to_parquet_range declares w as DECIMAL(4,4) in 2 bytes')
  from t20.enc where label = 'range';

-- the witness for the two negatives below: this byte match finds a DECIMAL(4,4) leaf where one is
select ok(position(archive._pq_build_schema_leaf('w', 7, 5, false, 2, 4, 4) in bytes) > 0,
  'witness: the byte match finds the numeric(4,4) twin''s DECIMAL(4,4) leaf')
  from t20.enc where label = 'twin_whole';

select is(position(archive._pq_build_schema_leaf('w', 7, 5, false, 1, 4, 2) in bytes), 0,
  'the DECIMAL(2,4) leaf Parquet forbids is not in archive._pq_to_parquet''s file')
  from t20.enc where label = 'whole';
select is(position(archive._pq_build_schema_leaf('w', 7, 5, false, 1, 4, 2) in bytes), 0,
  'nor in archive._pq_to_parquet_range''s')
  from t20.enc where label = 'range';

-- ---------------------------------------------------------------------------
-- The values, each one exactly
-- ---------------------------------------------------------------------------

-- p_compress => false and both columns NOT NULL: PAR1, then id's page header and 3 x 4 bytes, then
-- w's page header and 3 x 2 bytes.
select 4 + length(archive._pq_build_page_header(3, 12)) + 12 + length(archive._pq_build_page_header(3, 6)) as w_off \gset

select is((select substring(bytes from :w_off + 1 for 6) from t20.enc where label = 'whole'),
  '\x000cff9d0032'::bytea,
  'archive._pq_to_parquet writes 0.0012, -0.0099 and 0.0050 as the unscaled 12, -99 and 50');
select is((select substring(bytes from :w_off + 1 for 6) from t20.enc where label = 'range'),
  '\x000cff9d0032'::bytea,
  'and so does archive._pq_to_parquet_range');

-- the whole file, footer included, is the identity to hold: the two tables differ only in the typmod
select is((select bytes from t20.enc where label = 'whole'), (select bytes from t20.enc where label = 'twin_whole'),
  'archive._pq_to_parquet writes the numeric(2,4) table byte for byte as its numeric(4,4) twin');
select is((select bytes from t20.enc where label = 'range'), (select bytes from t20.enc where label = 'twin_range'),
  'and so does archive._pq_to_parquet_range');

select * from finish();
