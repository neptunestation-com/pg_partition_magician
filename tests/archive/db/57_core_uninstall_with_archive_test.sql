-- pgpm_core's uninstall goes through with pgpm_archive installed and in use: nothing of the module is one of the
-- dependants it refuses over (issue #1040).
--
-- WHY. uninstall.sql refuses, naming them, while anything outside schema pgpm depends on an object in it, and its
-- remedy is the operator's: save the object's definition, drop it, run again, recreate it without pgpm. That remedy
-- is wrong for an object of pgpm's own archive module, which cannot be recreated without pgpm. Today the module has
-- no such object: its archive_fn strategies (pgpm.archive_to_s3_ndjson, pgpm.archive_to_s3_parquet) live in schema
-- pgpm and go with it, and nothing in schema archive (archive.config, the key ledger, the signers and the
-- encoders) has a catalog dependency on pgpm, function bodies being invisible to pg_depend. This file pins that, so
-- the module cannot grow one (a foreign key from archive.config to pgpm.config, a view over pgpm.log) without the
-- uninstall's refusal being made to say the right thing for it first.
--
-- It runs in the archive track's per-file clone (fixtures, core, archive). A table is managed, configured for the
-- module and pointed at one of its strategies, so the module is in use and not merely installed. The core
-- uninstall is read with \ir from pgpm_core/, relative to this file. bench/archive_core_uninstall.sh runs this
-- file against a mutant pgpm_archive/install.sql that gives archive.config a foreign key to pgpm.config.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(6);

call mk_archive_table('u57', 300, 100);
select mk_archive_config('u57');
select pgpm.set_archive_fn('public.u57', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);

select is((select bucket || ':' || prefix from archive.config where parent_table = 'public.u57'::regclass),
  'archive-test-bucket:u57/', 'LIVENESS: the module is in use: archive.config holds u57''s connection settings');
select is((select archive_fn::text from pgpm.config where parent_table = 'public.u57'::regclass),
  'pgpm.archive_to_s3_ndjson(regclass,name,text,text)', 'LIVENESS: and u57 archives through one of the module''s strategies');

\set ON_ERROR_STOP 0
begin;
\ir ../../../pgpm_core/uninstall.sql
commit;
\set ON_ERROR_STOP 1

select is(:'LAST_ERROR_SQLSTATE'::text, '00000',
  'the core uninstall raised nothing: no object of the archive module is a dependant it refuses over');
select is(to_regnamespace('pgpm'), null, 'and it removed schema pgpm');
select is((select bucket || ':' || prefix from archive.config where parent_table = 'public.u57'::regclass),
  'archive-test-bucket:u57/', 'the module''s configuration is left as it was: the core uninstall does not remove the module');
select is((select array_agg(id order by id) from public.u57 where id in (1, 150, 300)), array[1, 150, 300]::bigint[],
  'the managed table keeps its rows');

select * from finish();
