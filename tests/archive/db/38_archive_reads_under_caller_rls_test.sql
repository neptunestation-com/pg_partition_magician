-- The archive module's half of the RLS conformance suite (issue #873; tests/241 is the core's). Each of
-- its readers of user rows read as the CALLER: archive.to_s3 and archive.to_s3_parquet read the partition
-- they are handed, and the archive_fn transports (pgpm.archive_to_s3_ndjson / _parquet) read the chunk
-- through the parent. transmute leaves the monolith its own ENABLE / FORCE ROW LEVEL SECURITY and carries
-- them onto the parent, so for a non-superuser owner without BYPASSRLS each read saw only the rows its
-- policies admit, the object landed holding those, the conservation check (which reads the same way)
-- agreed, and once a ledger row recorded it retention dropped the partition with the others. Each now asks
-- pgpm._refuse_filtered_reads of the relation it reads, before it reads or sends anything. (The automatic
-- path asks it too, in pgpm._archive_step, of the parent and the partition: tests/241 parts C4 and C5.)
--
-- EXHAUSTIVENESS. Part Z enumerates every public routine of this module (archive.*, and the transports it
-- puts in pgpm, pgpm.archive_*) from the catalog and requires each to be classified.
--
-- ASYMMETRIC FIXTURE. ar38: ids 1..40 in one monolith; three of them (3, 17, 33) carry payload 'hidden',
-- which the owner's FORCE'd policy hides, so an object of the owner's rows holds 37, never 40.
--
-- INSTRUMENT. The refused calls run as the owner through a SECURITY DEFINER function the owner owns
-- (pgTAP's temp tables are the harness's; tests/timescale/db/37). The owner is given what each reader needs
-- before its read (archive.config, the vault stub), so a reader that does not refuse reaches its read and
-- its upload rather than stopping at a privilege error. LIVENESS: the same calls by the harness's role,
-- which row-level security does not filter, export every row.
select plan(12);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't38_owner') then
    create role t38_owner nosuperuser nobypassrls;
  end if;
end $$;
grant create, usage on schema public to t38_owner;
grant usage on schema pgpm, archive, vault to t38_owner;
grant all on all tables in schema pgpm to t38_owner;
grant all on all sequences in schema pgpm to t38_owner;
grant all on all tables in schema archive to t38_owner;
grant all on all sequences in schema archive to t38_owner;
grant select on all tables in schema vault to t38_owner;

set role t38_owner;
create table public.ar38 (id bigint primary key, payload text not null);
insert into public.ar38 select g, case when g in (3, 17, 33) then 'hidden' else 'row-' || g end from generate_series(1, 40) g;
alter table public.ar38 enable row level security;
alter table public.ar38 force row level security;
create policy ar38_shown on public.ar38 using (payload <> 'hidden');
create function public.t38_as_owner(p_sql text) returns void language plpgsql security definer as $f$
begin execute p_sql; end $f$;
reset role;

call pgpm.transmute('public.ar38', 'id', 50::bigint);
select archive.configure('public.ar38'::regclass, 'archive-test-bucket',
  p_endpoint => 'http://minio:9000', p_prefix => 'a38_rls/', p_compress => false);
select child_name as mono, lo, hi from pgpm.part where parent_table = 'public.ar38'::regclass and lo = '0' \gset
set role t38_owner;
select (select count(*) from public.ar38) as parent_rows,
       row_security_active('public.ar38')::text as parent_rls,
       row_security_active(format('public.%I', :'mono')::regclass)::text as mono_rls
\gset owner_
reset role;

-- ================= WITNESSES =================
select is((select (not rolsuper and not rolbypassrls)::text from pg_roles where rolname = 't38_owner'), 'true',
  'LIVENESS: t38_owner is neither a superuser nor BYPASSRLS');
select is(:'owner_parent_rows'::text || '/' || (select count(*) from public.ar38)::text, '37/40',
  'LIVENESS: the owner sees 37 of ar38''s 40 rows');
select is(:'owner_parent_rls'::text || '/' || :'owner_mono_rls'::text, 'true/true',
  'LIVENESS: row-level security filters the owner on the parent and on the monolith alike');

-- ================= the synchronous exports: the partition they are handed =================
select throws_like(format($$ select public.t38_as_owner('select archive.to_s3(''public.ar38'', ''%s'', ''%s'', ''%s'')') $$,
                          :'mono', :'lo', :'hi'),
  format('pg_partition_magician: cannot export %s as t38_owner -- row-level security is active on it for that role (FORCE ROW LEVEL SECURITY holds even the table''s owner to the policies, and the role has no BYPASSRLS)%%the object would hold only those rows. Run it as a role with BYPASSRLS (or a superuser); nothing was changed.', :'mono'),
  'archive.to_s3 refuses the owner, naming the partition it would export');
select throws_like(format($$ select public.t38_as_owner('select archive.to_s3_parquet(''public.ar38'', ''%s'', ''%s'', ''%s'')') $$,
                          :'mono', :'lo', :'hi'),
  format('pg_partition_magician: cannot export %s as t38_owner -- row-level security is active on it for that role%%', :'mono'),
  'archive.to_s3_parquet refuses the owner');

-- ================= the archive_fn transports: the chunk, through the parent =================
select throws_like(format($$ select public.t38_as_owner('select pgpm.archive_to_s3_ndjson(''public.ar38'', ''%s'', ''%s'', ''%s'')') $$,
                          :'mono', :'lo', :'hi'),
  'pg_partition_magician: cannot archive a chunk of ar38 as t38_owner -- row-level security is active on it for that role%retention would drop the others once it is recorded%',
  'pgpm.archive_to_s3_ndjson refuses the owner, naming the parent it reads through');
select throws_like(format($$ select public.t38_as_owner('select pgpm.archive_to_s3_parquet(''public.ar38'', ''%s'', ''%s'', ''%s'')') $$,
                          :'mono', :'lo', :'hi'),
  'pg_partition_magician: cannot archive a chunk of ar38 as t38_owner -- row-level security is active on it for that role%',
  'pgpm.archive_to_s3_parquet refuses the owner');

-- ================= LIVENESS: a role the lever passes exports every row =================
select lives_ok(format($$ select archive.to_s3('public.ar38', %L, %L, %L) $$, :'mono', :'lo', :'hi'),
  'LIVENESS: the harness''s role exports the monolith with archive.to_s3');
select lives_ok(format($$ select archive.to_s3_parquet('public.ar38', %L, %L, %L) $$, :'mono', :'lo', :'hi'),
  'LIVENESS: and with archive.to_s3_parquet');
select is((select rows_archived from pgpm.archive_to_s3_ndjson('public.ar38', :'mono', :'lo', :'hi')), 40::bigint,
  'LIVENESS: pgpm.archive_to_s3_ndjson archives all 40 rows for it, the 3 hidden ones included');
select is((select rows_archived from pgpm.archive_to_s3_parquet('public.ar38', :'mono', :'lo', :'hi')), 40::bigint,
  'LIVENESS: and so does pgpm.archive_to_s3_parquet');

-- ================= Z. every public routine of the module is classified =================
create temp table t38_entry (sig text primary key, verdict text not null, what text not null);
insert into t38_entry values
  ('archive.configure(regclass,text,text,text,text,text,text,boolean,bigint,integer)', 'no user rows', 'archive.config'),
  ('archive.unconfigure(regclass)', 'no user rows', 'archive.config'),
  ('archive.s3_signed_request_bytea(text,text,text,text,text,text,text,bytea,text,text)', 'no user rows', 'its arguments'),
  ('archive.s3_signed_request(text,text,text,text,text,text,text,text,text,text)', 'no user rows', 'its arguments'),
  ('archive.s3_url_encode(text)', 'no user rows', 'its argument'),
  ('archive.to_s3(regclass,name,text,text)', 'refuses', 'the partition it exports (above)'),
  ('archive.to_s3_parquet(regclass,name,text,text)', 'refuses', 'the partition it exports (above)'),
  ('pgpm.archive_to_s3_ndjson(regclass,name,text,text)', 'refuses', 'the chunk, through the parent (above; and pgpm._archive_step first, tests/241)'),
  ('pgpm.archive_to_s3_parquet(regclass,name,text,text)', 'refuses', 'the chunk, through the parent (above; and pgpm._archive_step first, tests/241)');
select set_eq(
  $$ select p.oid::regprocedure::text from pg_proc p
      where (p.pronamespace = 'archive'::regnamespace and p.proname !~ '^_')
         or (p.pronamespace = 'pgpm'::regnamespace and p.proname like 'archive\_%') $$,
  $$ select sig from t38_entry $$,
  'Z: every public routine of the archive module is classified here (a new one fails this until it is)');

select * from finish();
