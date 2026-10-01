-- NaN in a numeric(p,s) column of a Parquet file (issue #635).
--
-- NaN is a legal value of numeric(p,s), a type the README lists as supported, and Parquet DECIMAL (an
-- unscaled integer) cannot hold it. archive._pq_plain_decimal raised 'cannot convert NaN to integer' on
-- every encode of a chunk holding one, so the Parquet strategy failed, maintain() logged skip_archive
-- every tick, and the partition was never covered or retired: the wedge #586 closed for infinite
-- timestamps, open on the DECIMAL leaf. NaN is now written as null, and a NOT NULL column holding one
-- gets an OPTIONAL leaf in that file so the null has definition levels to live in. A NOT NULL numeric
-- column holding no NaN keeps its REQUIRED leaf, byte for byte.
--
-- The encoders are checked by identity against the file of the SAME rows with each NaN written as null
-- and the NaN-holding NOT NULL column declared nullable: equal bytes mean every other value, every null
-- and every leaf is what it would have been. The readers' half (pyarrow and DuckDB give back null where
-- the NaN was and every other value exactly) is bench/archive_parquet_decimal_nan.sh's.
--
-- Fixture, asymmetric: amt (nullable) holds one NaN and one real null; req (NOT NULL) holds NaN in two
-- rows of four; fix (NOT NULL) holds none.
select plan(11);

create schema t31;
-- an encode's bytes, or null when it raises: so the file runs to its end against the defect as well, and an
-- assertion comparing with a NaN-free encode (which does not raise) fails instead of stopping the file
create function t31.try(p_sql text) returns bytea language plpgsql as $$
declare b bytea;
begin execute p_sql into b; return b;
exception when others then return null; end $$;

select throws_like($$ select archive._pq_plain_decimal('NaN'::numeric, 2, 3) $$, 'cannot convert NaN to integer',
  'witness: the DECIMAL primitive itself cannot take a NaN, so the encoder must keep NaN away from it');

-- ---------------------------------------------------------------------------
-- The tick: the Parquet strategy archives the chunk instead of deferring it
-- ---------------------------------------------------------------------------

create table public.nt31 (id bigint primary key, amt numeric(5,2), req numeric(7,3) not null);
insert into public.nt31 values (1, 1.50, 2.250), (2, 'NaN', 'NaN'), (3, null, 'NaN');
-- the chunk's rows with each NaN as null and req nullable: the file the object must be
create table public.ntnull31 (id bigint primary key, amt numeric(5,2), req numeric(7,3));
insert into public.ntnull31 values (1, 1.50, 2.250), (2, null, null), (3, null, null);
call pgpm.transmute('public.nt31', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into public.nt31 values (45000, 2.25, 1.000);   -- horizon 40000: [0, 10000) is aged
select archive.configure('public.nt31', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                         p_prefix => current_database() || '-t31/');
select pgpm.set_archive_fn('public.nt31', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);

select is((select archive_batch from pgpm.config where parent_table = 'public.nt31'::regclass), 1,
  'LIVENESS: archive_batch is 1, so a wedged [0, 10000) would hold up every younger partition');

call pgpm.maintain('public.nt31');
call pgpm.maintain('public.nt31');

select is((select string_agg(distinct left(method, 160), ' | ') from pgpm.log
            where parent_table = 'public.nt31'::regclass and action = 'skip_archive'), null,
  'no tick deferred the chunk');
select is((select rows_archived from pgpm.archive_ledger where parent_table = 'public.nt31'::regclass and lo = '0'), 3::bigint,
  'the Parquet strategy archived [0, 10000)''s three rows');
select is((select text_to_bytea((archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', s3_key, '',
                                  'text/plain', '', 'minioadmin', 'minioadmin')).content)
             from pgpm.archive_ledger where parent_table = 'public.nt31'::regclass and lo = '0'),
  archive._pq_to_parquet_range('public.ntnull31', 'id', '0', '10000', false),
  'and the object at its key is that chunk''s file, NaN written as null');

-- ---------------------------------------------------------------------------
-- The encoders, by identity
-- ---------------------------------------------------------------------------

create table public.nan31 (id int4 primary key, amt numeric(5,2), req numeric(7,3) not null, fix numeric(4,1) not null);
insert into public.nan31 values
  (1, 1.50, 2.250, 10.5), (2, 'NaN', 'NaN', -3.0), (3, null, -0.750, 0.1), (4, -12.25, 'NaN', 999.9);
-- the same rows, each NaN as null, req nullable: what the file must equal
create table public.null31 (id int4 primary key, amt numeric(5,2), req numeric(7,3), fix numeric(4,1) not null);
insert into public.null31 values
  (1, 1.50, 2.250, 10.5), (2, null, null, -3.0), (3, null, -0.750, 0.1), (4, -12.25, null, 999.9);

select is((select array_agg(amt::text order by id) || array_agg(req::text order by id) from public.nan31),
  array['1.50', 'NaN', null, '-12.25', '2.250', 'NaN', '-0.750', 'NaN'],
  'LIVENESS: amt holds one NaN and one null, req (NOT NULL) holds NaN in rows 2 and 4');

-- kept in a table: bench/archive_parquet_decimal_nan.sh reads both files back with pyarrow and DuckDB
create table t31.enc as
  select 'whole' as label, t31.try($$ select archive._pq_to_parquet('public.nan31', false) $$) as bytes
  union all
  select 'range', t31.try($$ select archive._pq_to_parquet_range('public.nan31', 'id', '0', '100', true) $$);

select is(t31.try($$ select archive._pq_to_parquet('public.nan31', false) $$), archive._pq_to_parquet('public.null31', false),
  'archive._pq_to_parquet: the file is byte for byte the file of the same rows with each NaN as null');
select is(t31.try($$ select archive._pq_to_parquet_range('public.nan31', 'id', '0', '100', false) $$),
          archive._pq_to_parquet_range('public.null31', 'id', '0', '100', false),
  'archive._pq_to_parquet_range: the same, uncompressed');
select is((select bytes from t31.enc where label = 'range'),
          archive._pq_to_parquet_range('public.null31', 'id', '0', '100', true),
  'and compressed');

-- the leaves, by the builder the encoders use: req OPTIONAL where it holds NaN, fix still REQUIRED
select is((select array_agg(position(l in (select bytes from t31.enc where label = 'whole')) > 0 order by n)
             from (values
               (1, archive._pq_build_schema_leaf('req', 7, 5, true, archive._pq_decimal_byte_width(7), 3, 7)),
               (2, archive._pq_build_schema_leaf('fix', 7, 5, false, archive._pq_decimal_byte_width(4), 1, 4)),
               (3, archive._pq_build_schema_leaf('req', 7, 5, false, archive._pq_decimal_byte_width(7), 3, 7))) v(n, l)),
  array[true, true, false],
  'req''s leaf is OPTIONAL in a file holding its NaN, fix''s stays REQUIRED, and req has no REQUIRED leaf');
select is((select array_agg(position(l in archive._pq_to_parquet_range('public.nan31', 'id', '0', '2', false)) > 0 order by n)
             from (values
               (1, archive._pq_build_schema_leaf('req', 7, 5, false, archive._pq_decimal_byte_width(7), 3, 7)),
               (2, archive._pq_build_schema_leaf('req', 7, 5, true, archive._pq_decimal_byte_width(7), 3, 7))) v(n, l)),
  array[true, false],
  'a chunk in which req holds no NaN (id 1 alone) keeps req''s REQUIRED leaf');

select * from finish();
