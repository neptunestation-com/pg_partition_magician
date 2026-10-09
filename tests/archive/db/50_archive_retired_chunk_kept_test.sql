-- A retired chunk's object stays the only copy of its rows when a partition is re-created over its range
-- (issue #1141 bullet 1), against the real transport and MinIO.
--
-- THE DEFECT. After maintain() archived [0, 100) of a table and retire() dropped the partition, the object was
-- the only copy of ids 1..90, and its ledger row the record of where they went. A partition re-created over
-- [0, 100) by plain DDL and recorded with pgpm.adopt_partition made the next tick's orphan discard in
-- _archive_step delete that ledger row (archive_coverage_reset, "no longer a tracked partition ... over a range
-- a tracked partition now holds"). archive._refuse_recorded_chunk_overwrite protects only keys the ledger
-- records, and a chunk's key is parent + lo, so the same tick PUT the re-created partition's 40 rows over the
-- object: ids 1..90 were then in no table and no object. maintain() alone did it.
--
-- THE CONTRACT. retire() marks the dropped partition's chunks (pgpm.archive_ledger.retired_at), no coverage
-- reset discards a marked row, and a partition over a retired chunk's range is not archived: the tick logs
-- skip_archive_retired_range once, naming the chunk's object key, and archives the parent's next partition in
-- its place. The object keeps ids 1..90. A direct strategy call at the key is still refused by the digest
-- check (#1069), the second layer, and the documented remedy, an export of the re-created partition with
-- archive.to_s3, writes to a key of its own and leaves the retired chunk's object as it was.
-- tests/309 holds the same contract at every reset site on the core image; bench/archive_retired_chunk_kept.sh
-- runs that file against the mutations.
--
-- ASYMMETRIC FIXTURES. 90 retired rows 'old<id>', 40 re-created rows 'late<id>' with the same ids 1..40, and
-- 7 rows 'mid<id>' (ids 101..107) in the parent's next partition. Each object is read back by its rows.
set client_min_messages = warning;
select plan(15);
create schema t50;
create function t50.req(p_key text) returns http_response language sql as $$
  select archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- what an NDJSON object holds, as 'id:payload' items sorted by id (null when there is no object)
create function t50.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t50.req(p_key);
begin
  if v.status <> 200 then return null; end if;
  return coalesce((select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
                     from regexp_split_to_table(v.content, e'\n') l where l <> ''), '');
end $$;
create function t50.expect(p_tag text, p_from int, p_to int) returns text language sql immutable as $$
  select string_agg(g || ':' || p_tag || g, ',' order by g) from generate_series(p_from, p_to) g $$;

select current_database() || '/t50/' || txid_current() || '/' as p \gset

create table t50.ev (id bigint primary key, payload text not null);
insert into t50.ev select g, 'old' || g from generate_series(1, 90) g;
call pgpm.transmute('t50.ev', 'id', 100::bigint, p_retain => 100::bigint, p_paused => false);
insert into t50.ev select g, 'mid' || g from generate_series(101, 107) g;
insert into t50.ev values (450, 'frontier');
select archive.configure('t50.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
update pgpm.config set retain_batch = 0 where parent_table = 't50.ev'::regclass;
select pgpm.set_archive_fn('t50.ev', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select child_name as a0 from pgpm.part where parent_table = 't50.ev'::regclass and lo = '0' \gset
select child_name as a1 from pgpm.part where parent_table = 't50.ev'::regclass and lo = '100' \gset

call pgpm.maintain('t50.ev');
select s3_key as k0 from pgpm.archive_ledger where parent_table = 't50.ev'::regclass and lo = '0' \gset
select is(t50.rows(:'k0'), t50.expect('old', 1, 90),
  'LIVENESS: maintain() archived [0, 100) and its object holds exactly ids 1..90 old<id>');
select pgpm.retire('t50.ev', :'a0') as retired \gset
select ok(:'retired'::boolean and to_regclass('t50.' || quote_ident(:'a0')) is null
          and not exists (select 1 from t50.ev where id < 100),
  'LIVENESS: retire() dropped the partition; the object is the only copy of ids 1..90');
select is((select format('%s|%s|%s|%s|%s', lo, hi, child_name, s3_key = :'k0', rows_archived) from pgpm.archive_ledger
            where parent_table = 't50.ev'::regclass and retired_at is not null),
          format('0|100|%s|t|90', :'a0'),
  'retire() marked that chunk retired, and only that one');

-- late rows for the retired range, in a partition created by plain DDL and adopted
create table t50.ev_late partition of t50.ev for values from (0) to (100);
insert into t50.ev select g, 'late' || g from generate_series(1, 40) g;
select lives_ok($$ select pgpm.adopt_partition('t50.ev', 't50.ev_late') $$,
  'LIVENESS: adopt_partition records the re-created partition over [0, 100)');
call pgpm.maintain('t50.ev');
select ok(pgpm._is_write_blocked('t50.ev', 'ev_late'),
  'LIVENESS: the tick write-blocked the re-created partition, which makes it an archive candidate');

select is(t50.rows(:'k0'), t50.expect('old', 1, 90),
  'the object the retired chunk was archived to still holds ids 1..90 old<id> (the only copy of those rows)');
select is((select format('%s|%s|%s|%s|%s|%s', lo, hi, child_name, s3_key = :'k0', rows_archived,
                          (select count(*) from pgpm.archive_ledger where parent_table = 't50.ev'::regclass and child_name = 'ev_late'))
             from pgpm.archive_ledger where parent_table = 't50.ev'::regclass and lo = '0'),
          format('0|100|%s|t|90|0', :'a0'),
  'the retired chunk''s ledger row is where retire() left it, and nothing is recorded for the re-created partition');
select is((select format('%s|%s|%s', child_name, rows_archived, t50.rows(s3_key)) from pgpm.archive_ledger
            where parent_table = 't50.ev'::regclass and lo = '100'),
          format('%s|7|%s', :'a1', t50.expect('mid', 101, 107)),
  'the same tick archived the parent''s next partition [100, 200) instead: ids 101..107 mid<id> (no wedge)');
select is((select string_agg(format('%s|%s|%s', lo, hi, strpos(method, :'k0') > 0), ',') from pgpm.log
            where parent_table = 't50.ev'::regclass and action = 'skip_archive_retired_range'),
  '0|100|t', 'the tick logged skip_archive_retired_range once over [0, 100), naming the retired chunk''s object key');
select is((select array_agg(method) from pgpm.log where parent_table = 't50.ev'::regclass and action = 'archive_coverage_reset'),
  null::text[], 'no archive_coverage_reset was logged');

-- the second layer: a direct strategy call at the retired chunk's key is refused by the digest check (#1069)
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t50.ev', 'unused', '0', '100') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses to write [0, 100) of t50.ev to the object key ' || :'k0'
  || ': pgpm.archive_ledger records the chunk [0, 100) of 90 row(s) there, and the read found 40 row(s) in it now%',
  'a direct archive_to_s3_ndjson call at the retired chunk''s key is refused, naming the recorded chunk');
select is(t50.rows(:'k0'), t50.expect('old', 1, 90), 'and the object still holds ids 1..90 old<id>');

-- the remedy the skip names: export the re-created partition with archive.to_s3, to a key named after it
select lives_ok($$ select archive.to_s3('t50.ev', 'ev_late', '0', '100') $$,
  'LIVENESS: archive.to_s3 exports the re-created partition');
select is(t50.rows(:'p' || 't50.ev_late.ndjson'), t50.expect('late', 1, 40),
  'the export holds ids 1..40 late<id>, at a key of its own');
select is(t50.rows(:'k0'), t50.expect('old', 1, 90),
  'and the retired chunk''s object still holds ids 1..90 old<id>');
select * from finish();
