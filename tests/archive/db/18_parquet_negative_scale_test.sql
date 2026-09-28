-- A numeric(p,s) column with a NEGATIVE scale in a Parquet file (issue #567).
--
-- Since PostgreSQL 15 a numeric typmod's scale is an 11-bit SIGNED field, and numeric(5,-2) holds
-- whole multiples of 100 with at most five significant digits (up to 9999900). Both encoders read the
-- scale as the unsigned low 16 bits, so that column came out as scale 2046: every value was multiplied
-- by 10^2046 and cut to the column's 3-byte width, which is zero for every value (10^2046 is a
-- multiple of 2^24), and the footer declared a scale above the precision that readers refuse. The file
-- uploaded and was ledgered as archived with the values gone. Both encoders now take the leaf's shape
-- from archive._pq_decimal_shape, which decodes the signed scale and writes a scale -k column as
-- DECIMAL(p + k, 0): every value exactly as itself, in the width that precision needs.
--
-- The values are asserted by identity against big-endian two's complement bytes derived OUTSIDE
-- PostgreSQL, so nothing shares an operator with the code under test:
--
--   for v in (12300, -45600, 9999900): print(v, v.to_bytes(4, 'big', signed=True).hex())
--   -> 0000300c, ffff4de0, 0098961c        (4 bytes: 10^7 - 1 needs 24 bits plus the sign)
--
-- The fixture is asymmetric (three different values, one negative, one the column's maximum), and each
-- negative assertion is paired with a witness that the condition it denies was present: the column
-- really is numeric(5,-2) by PostgreSQL's own rendering, and the old unsigned read of its typmod really
-- is 2046. The files are kept in t18.enc for bench/archive_parquet_negative_scale.sh, whose pyarrow half
-- reads the values back with a reader that shares nothing with the writer.
select plan(16);

create schema t18;
create table t18.enc (label text primary key, bytes bytea not null);

create table public.neg18 (id int4 primary key, v numeric(5,-2) not null);
insert into public.neg18 values (1, 12300), (2, -45600), (3, 9999900);
-- the same values in the non-negative shape a negative scale is written as
create table public.twin18 (id int4 primary key, v numeric(7,0) not null);
insert into public.twin18 values (1, 12300), (2, -45600), (3, 9999900);

-- ---------------------------------------------------------------------------
-- Witnesses: the column shape, and the hazard it reaches
-- ---------------------------------------------------------------------------

select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.neg18'::regclass and attname = 'v'),
  'numeric(5,-2)', 'witness: PostgreSQL itself renders the column as numeric(5,-2)');

select is((select (atttypmod - 4) & 65535 from pg_attribute where attrelid = 'public.neg18'::regclass and attname = 'v'),
  2046, 'witness: the unsigned read of that typmod, the one the encoders used, is scale 2046');

select is((select array_agg(v order by id) from public.neg18), array[12300, -45600, 9999900]::numeric[],
  'witness: the column holds 12300, -45600 and 9999900, the last its largest value');

-- ---------------------------------------------------------------------------
-- The shape the leaf declares
-- ---------------------------------------------------------------------------

select is((select row(d.p_precision, d.p_scale)::text from archive._pq_decimal_shape(
             (select atttypmod from pg_attribute where attrelid = 'public.neg18'::regclass and attname = 'v')) d),
  '(7,0)', 'numeric(5,-2) is written as DECIMAL(7,0): five significant digits and two trailing zeros');

select is((select row(d.p_precision, d.p_scale)::text from archive._pq_decimal_shape(
             (select atttypmod from pg_attribute where attrelid = 'public.twin18'::regclass and attname = 'v')) d),
  '(7,0)', 'and numeric(7,0) keeps its own shape');

select is(archive._pq_decimal_byte_width(7), 4, 'DECIMAL(7,0) is four bytes wide');

insert into t18.enc values
  ('whole', archive._pq_to_parquet('public.neg18', false)),
  ('range', archive._pq_to_parquet_range('public.neg18', 'id', '0', '10', false)),
  ('twin_whole', archive._pq_to_parquet('public.twin18', false)),
  ('twin_range', archive._pq_to_parquet_range('public.twin18', 'id', '0', '10', false));

-- id's leaf is its own; v's leaf is matched as the exact bytes archive._pq_build_schema_leaf emits.
select ok(position(archive._pq_build_schema_leaf('v', 7, 5, false, 4, 0, 7) in bytes) > 0,
  'archive._pq_to_parquet declares v as DECIMAL(7,0) in 4 bytes')
  from t18.enc where label = 'whole';
select ok(position(archive._pq_build_schema_leaf('v', 7, 5, false, 4, 0, 7) in bytes) > 0,
  'archive._pq_to_parquet_range declares v as DECIMAL(7,0) in 4 bytes')
  from t18.enc where label = 'range';

-- the witness for the two negatives below: the same byte match finds the twin's leaf, which is fine
select ok(position(archive._pq_build_schema_leaf('v', 7, 5, false, 4, 0, 7) in bytes) > 0,
  'witness: the byte match finds the numeric(7,0) twin''s DECIMAL(7,0) leaf')
  from t18.enc where label = 'twin_whole';

select is(position(archive._pq_build_schema_leaf('v', 7, 5, false, 3, 2046, 5) in bytes), 0,
  'the scale-2046 leaf the unsigned read produced is not in archive._pq_to_parquet''s file')
  from t18.enc where label = 'whole';
select is(position(archive._pq_build_schema_leaf('v', 7, 5, false, 3, 2046, 5) in bytes), 0,
  'nor in archive._pq_to_parquet_range''s')
  from t18.enc where label = 'range';

-- ---------------------------------------------------------------------------
-- The values: each one exactly, not merely "different from each other"
-- ---------------------------------------------------------------------------

-- p_compress => false and both columns NOT NULL, so a page is exactly its PLAIN values: PAR1, then
-- per column a page header and the page; id is 3 x 4 bytes and v is 3 x 4 bytes.
select 4 + length(archive._pq_build_page_header(3, 12)) + 12 + length(archive._pq_build_page_header(3, 12)) as v_off \gset

select is((select substring(bytes from :v_off + 1 for 12) from t18.enc where label = 'whole'),
  '\x0000300cffff4de00098961c'::bytea,
  'archive._pq_to_parquet writes 12300, -45600 and 9999900 as themselves');
select is((select substring(bytes from :v_off + 1 for 12) from t18.enc where label = 'range'),
  '\x0000300cffff4de00098961c'::bytea,
  'and so does archive._pq_to_parquet_range');

select is((select length(bytes) from t18.enc where label = 'whole'),
          (select length(bytes) from t18.enc where label = 'twin_whole'),
  'witness: the file is exactly as long as the twin''s, so the page read above is the whole v page');

-- A numeric(5,-2) column and a numeric(7,0) column holding the same values are the same Parquet file:
-- the two columns' names and types agree, so the whole file is the identity to hold, footer included.
select is((select bytes from t18.enc where label = 'whole'), (select bytes from t18.enc where label = 'twin_whole'),
  'archive._pq_to_parquet writes the numeric(5,-2) table byte for byte as its numeric(7,0) twin');
select is((select bytes from t18.enc where label = 'range'), (select bytes from t18.enc where label = 'twin_range'),
  'and so does archive._pq_to_parquet_range');

select * from finish();
