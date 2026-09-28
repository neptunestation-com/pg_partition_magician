-- The Parquet range encoder on a KEYLESS parent (issue #597).
--
-- archive._pq_to_parquet_range refused a parent with no primary key or unique constraint, on every
-- chunk, for want of a tiebreak on the control column. pgpm.set_archive_fn accepted
-- pgpm.archive_to_s3_parquet for such a table, and transmute partitions keyless tables as a supported
-- shape, so every maintain() tick logged skip_archive and nothing of the table was ever covered or
-- retired. The tiebreak had bought nothing since #462: every column is read from ONE materialisation
-- whose row ordinal is assigned once, so rows tied on the control column land in some order, the same
-- order in every column. The encoder now orders a keyless parent by the control column alone.
--
-- What the refusal claimed to protect is asserted directly: two rows tie on the control column and
-- differ in both other columns, and the file's pages must pair them the same way in every column
-- (either order of the tie is correct; a mixed one is the misalignment). The fixture is asymmetric
-- (four rows, one tie, values that cannot compensate), and the tick half's negative ("no tick skipped
-- the archive step") is paired with witnesses that the table really is keyless and the partition
-- really is below the horizon. The file is kept in t21.enc for bench/archive_parquet_keyless.sh, whose
-- pyarrow half reads every row back by identity.
select plan(12);

create schema t21;
create table t21.enc (label text primary key, bytes bytea not null);

create table public.nk21 (id bigint not null, tag text not null, n int4 not null);
insert into public.nk21 values (1, 'z', 9), (5, 'a', 1), (5, 'b', 2), (6, 'c', 3);

-- ---------------------------------------------------------------------------
-- Witnesses: no key, and a tie for one to break
-- ---------------------------------------------------------------------------

select is(archive._key_columns('public.nk21'), null::name[],
  'witness: public.nk21 has no primary key or unique constraint');
select is((select count(*) - count(distinct id) from public.nk21), 1::bigint,
  'witness: two of its rows tie on the control column id');

-- ---------------------------------------------------------------------------
-- The encoder archives it, one row per row
-- ---------------------------------------------------------------------------

select lives_ok($$ insert into t21.enc values ('range', archive._pq_to_parquet_range('public.nk21', 'id', '0', '10', false)) $$,
  'archive._pq_to_parquet_range encodes the keyless table');

-- p_compress => false and every column NOT NULL: PAR1, then id's page header and 4 x 8 bytes, tag's
-- page header and 4 x (4-byte length + 1 byte), then n's page header and 4 x 4 bytes.
select 4 + length(archive._pq_build_page_header(4, 32)) as id_off \gset
select :id_off + 32 + length(archive._pq_build_page_header(4, 20)) as tag_off \gset
select :tag_off + 20 + length(archive._pq_build_page_header(4, 16)) as n_off \gset

select is((select substring(bytes from :id_off + 1 for 32) from t21.enc where label = 'range'),
  archive._pq_plain_int64(1) || archive._pq_plain_int64(5) || archive._pq_plain_int64(5) || archive._pq_plain_int64(6),
  'the id page is 1, 5, 5, 6: the control column in order');

select ok(
  (select (substring(bytes from :tag_off + 1 for 20), substring(bytes from :n_off + 1 for 16)) from t21.enc where label = 'range')
    in ((archive._pq_plain_text('z') || archive._pq_plain_text('a') || archive._pq_plain_text('b') || archive._pq_plain_text('c'),
         archive._pq_plain_int32(9) || archive._pq_plain_int32(1) || archive._pq_plain_int32(2) || archive._pq_plain_int32(3)),
        (archive._pq_plain_text('z') || archive._pq_plain_text('b') || archive._pq_plain_text('a') || archive._pq_plain_text('c'),
         archive._pq_plain_int32(9) || archive._pq_plain_int32(2) || archive._pq_plain_int32(1) || archive._pq_plain_int32(3))),
  'the tied rows keep their own values: tag and n are paired (a, 1) and (b, 2) in whichever order the tie took');

select ok((select length(bytes) > :n_off + 16 from t21.enc where label = 'range'),
  'witness: the n page read above lies inside the file, with the footer after it');

-- ---------------------------------------------------------------------------
-- The issue's tick: a keyless partitioned table is archived, not skipped
-- ---------------------------------------------------------------------------

create table public.nkm21 (id bigint not null, payload text);
insert into public.nkm21 select g, 'r' || g from generate_series(1, 20) g;
insert into public.nkm21 values (7, 'dup');
call pgpm.transmute('public.nkm21', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into public.nkm21 values (45000, 'frontier');
select mk_archive_config('nkm21', false);
update pgpm.config set retain_batch = 0 where parent_table = 'public.nkm21'::regclass;

select is(archive._key_columns('public.nkm21'), null::name[],
  'witness: the transmuted parent is keyless too');
select is((select count(*) from pgpm.part where parent_table = 'public.nkm21'::regclass and lo::bigint = 0), 1::bigint,
  'witness: the partition [0, 10000) exists below the 40000 horizon');

select lives_ok($$ select pgpm.set_archive_fn('public.nkm21', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure) $$,
  'pgpm.set_archive_fn accepts the Parquet strategy for the keyless table');

call pgpm.maintain('public.nkm21');

select is((select array_agg(lo::bigint) from pgpm.archive_ledger where parent_table = 'public.nkm21'::regclass),
  array[0]::bigint[], 'the tick archived [0, 10000) as Parquet');
select is((select rows_archived from pgpm.archive_ledger where parent_table = 'public.nkm21'::regclass and lo = '0'),
  21::bigint, 'with all 21 of its rows, the duplicate id 7 included');
select is((select count(*) from pgpm.log where parent_table = 'public.nkm21'::regclass and action = 'skip_archive'), 0::bigint,
  'and did not skip the archive step');

select * from finish();
