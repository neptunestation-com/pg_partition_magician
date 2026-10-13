-- archive._refuse_recorded_chunk_overwrite admits a re-run of a recorded, live chunk only when the read's
-- digest (archive._row_digest: md5 of each row's JSON text) is the one its claim recorded. The JSON text
-- carries the row's column NAMES, so after ALTER TABLE ... ADD COLUMN on the parent the same rows of the
-- same chunk digest differently, and the documented re-run (the chunk's own [lo, hi) while its rows are
-- still in the write-blocked table) is refused with a message that says the read found other rows than the
-- chunk recorded. The rows are the chunk's; the shape of the table changed. Either the re-run should be
-- admitted (the documented contract), or the refusal should name the shape rather than blame the rows.
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(7);

create schema f19r;
create function f19r.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function f19r.rows(p_key text) returns text language plpgsql as $$
declare v http_response := f19r.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return coalesce((select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
                     from regexp_split_to_table(v.content, e'\n') l where l <> ''), '');
end $$;
create function f19r.try(p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  r := pgpm.archive_to_s3_ndjson('f19r.nd', 'unused', p_lo, p_hi);
  return r.rows_archived || ' ' || r.s3_key;
exception when others then return sqlerrm;
end $$;
select 'f19-04-' || current_database() || '/' || txid_current() || '/' as p \gset

create table f19r.nd (id bigint primary key, payload text not null);
insert into f19r.nd select g, 'n' || g from generate_series(1, 3) g;
call pgpm.transmute('f19r.nd', 'id', 100::bigint, p_retain => 100::bigint, p_paused => false);
insert into f19r.nd values (450, 'frontier');
select archive.configure('f19r.nd', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
update pgpm.config set retain_batch = 0 where parent_table = 'f19r.nd'::regclass;
select pgpm.set_archive_fn('f19r.nd', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
call pgpm.maintain('f19r.nd');
select s3_key as k from pgpm.archive_ledger where parent_table = 'f19r.nd'::regclass and lo = '0' \gset

select is((select '[' || lo || ', ' || hi || ') ' || rows_archived from pgpm.archive_ledger where parent_table = 'f19r.nd'::regclass),
  '[0, 100) 3', 'LIVENESS: maintain() archived [0, 100) as one chunk of 3 rows and ledgered it');
select is(f19r.rows(:'k'), '1:n1,2:n2,3:n3', 'LIVENESS: the chunk''s object holds ids 1, 2 and 3');
select isnt((select rows_digest from archive.object_key_claim where object_key = :'k'), null,
  'LIVENESS: the chunk''s claim recorded the digest of those rows');
select is(f19r.try('0', '100'), '3 ' || :'k',
  'LIVENESS: a re-run of the live chunk''s own [0, 100) is admitted before the table changes shape (3 rows, the same key)');

alter table f19r.nd add column note text;
select is((select string_agg(id || ':' || payload, ',' order by id) from f19r.nd where id < 100), '1:n1,2:n2,3:n3',
  'LIVENESS: after ADD COLUMN the chunk still holds exactly the rows the ledger recorded, unchanged');

-- the defect: the same re-run, over the same rows, is now refused as if the rows were other ones
select is(f19r.try('0', '100'), '3 ' || :'k',
  'a re-run of the live chunk''s own [0, 100) after ALTER TABLE ... ADD COLUMN is admitted (the rows are the chunk''s)');
select is(f19r.rows(:'k'), '1:n1,2:n2,3:n3', 'and the object still holds ids 1, 2 and 3');

select (f19r.req('DELETE', :'k')).status as c \gset
select * from finish();
