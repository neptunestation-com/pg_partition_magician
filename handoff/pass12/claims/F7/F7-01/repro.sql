-- archive.to_s3 pages a relation by its control column, casting the cursor back as the column's type. The type
-- must be spelled WITH its typmod: char(3) spelled bare is `character`, i.e. char(1), so a cursor of 'abc' casts
-- back as 'a', every page re-reads the row it ended on, and the export never ends. Its own header says "A domain
-- pages as its BASE type, with the domain's typmod", and the function computes v_ctl_mod, but v_ctltype is
-- spelled v_ctl_typ::regtype::text, without it.
create extension if not exists pgtap;
select plan(5);
-- the Vault secrets the archive module signs with, as tests/archive/fixtures.sql stubs them for MinIO
create schema if not exists vault;
create table if not exists vault.decrypted_secrets (name text primary key, decrypted_secret text not null);
insert into vault.decrypted_secrets (name, decrypted_secret) values
  ('s3_archive_access_key_id', 'minioadmin'), ('s3_archive_secret_access_key', 'minioadmin')
on conflict (name) do update set decrypted_secret = excluded.decrypted_secret;
create schema f7t;
create table f7t.evt (id bigint primary key, payload text not null);
insert into f7t.evt values (1, 'evt');
call pgpm.transmute('f7t.evt', 'id', 10000::bigint, p_paused => true);
select current_database() || '-f7t/' as p \gset
select archive.configure('f7t.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);
-- a control witness: a bigint relation, three rows, one per page
create table f7t.big (id bigint, payload text);
insert into f7t.big values (2, 'b'), (1, 'a'), (3, 'c');
-- the subject: a char(3) relation, three rows, one per page
create table f7t.chr (id char(3), payload text);
insert into f7t.chr values ('abd', 'k'), ('abc', 'j'), ('abe', 'l');

create function f7t.try_export(p_child name) returns text language plpgsql as $$
begin
  perform archive.to_s3('f7t.evt'::regclass, p_child, null, null);
  return 'ok';
exception
  when query_canceled then return 'cancelled by statement_timeout: the export did not end';
  when others then return sqlerrm;
end $$;

select is((select format_type(atttypid, atttypmod) from pg_attribute
            where attrelid = 'f7t.chr'::regclass and attname = 'id'),
          'character(3)', 'LIVENESS: the relation''s control column is char(3)');
select is((select string_agg(id || ':' || payload, ',' order by id) from f7t.chr), 'abc:j,abd:k,abe:l',
          'LIVENESS: it holds abc, abd and abe');
set statement_timeout = '30s';
select is(f7t.try_export('big'), 'ok', 'LIVENESS: a bigint relation exports through MinIO, one row per page');
select is(f7t.try_export('chr'), 'ok', 'archive.to_s3 of a char(3) relation, one row per page, ends and completes');
reset statement_timeout;
select is(('abc'::text)::character, 'a'::character,
          'LIVENESS: the bare type character is char(1), so a cursor cast that way is cut');
select * from finish();
