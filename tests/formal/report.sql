-- What the invariant oracle says about one test file's database, after the file has run (formal methods Phase 3
-- W4, docs/formal/phase3-design.md "Wiring"). The runners in test.sh call it once per file, in the file's own clone
-- (or in `postgres` for the two pg_cron files), as one psql session:
--
--   psql -qAt -F <tab> -v ON_ERROR_STOP=1 -v file=<label> -v scope=<names> -v load_store=<0|1> -f report.sql
--
-- file        the label every line carries (the test file's path)
-- scope       '' to judge the whole database, or a text[] literal of schema-qualified names, '{public.dp78}', for
--             the files that share `postgres`: each name resolves to the relation that has it now AND to every
--             relation of that name the drop history saw, so a file that dropped its parent at its end still names it
-- load_store  1 on the archive track: psql's standard input carries the bucket's contents as CSV rows
--             (parent oid, s3 key, ok, row as jsonb), written by tests/formal/load_store.py; they are rendered to row
--             identities here, by the oracle's own rendering, into pgpm_formal.store before check() reads it
--
-- One line per fact, tab separated, the first field its kind:
--   L  <file>  <baselined parents>                          the ledger the file left, gone parents included
--   S  <file>  <parents listed>  <objects>  <identities>    the store loaded (archive track only)
--   E  <file>  <message>                                    the store could not be loaded for a parent
--   V  <file>  <invariant>  <parent>  <identity>  <detail>  one per row of pgpm_formal.check()
--   J  <file>  <invariant>  <judged>  <parents>  <identities>  <expected>  <note>   one per row of judged()
--   T  <file>  <ms>                                         the report's server-side time, store load included
-- An ERROR in check() itself stops the session (ON_ERROR_STOP); the runner records psql's stderr as an E line.
-- tests/formal/summarize.py reads every file's lines and prints the track's summary and liveness witness.

set client_min_messages = warning;
set timezone = 'UTC';
set datestyle = 'ISO, MDY';
set intervalstyle = 'postgres';
set extra_float_digits = 1;
set bytea_output = 'hex';
select clock_timestamp() as report_t0 \gset

select 'L', :'file', count(*) from pgpm_formal.ledger_parent;

\if :load_store
create temp table pgpm_formal_stage (parent_table oid, s3_key text, ok boolean, j jsonb);
\copy pgpm_formal_stage from pstdin with (format csv)
-- A row with no key is the parent's listing marker: ok when every object of the parent was read, else j holds the
-- reason. Only a parent read in full is listed; one that is not stays unjudged for ArchiveNoClobber and says why.
do $$
declare r record;
begin
  for r in
    select m.parent_table, lp.key_cols
      from pgpm_formal_stage m
      join lateral (select l.key_cols from pgpm_formal.ledger_parent l
                     where pgpm_formal._current_parent(l.parent_oid) = m.parent_table
                     order by l.baselined_at desc limit 1) lp on true
     where m.s3_key is null and m.ok
       and not exists (select 1 from pgpm_formal_stage f where f.parent_table = m.parent_table and not f.ok)
  loop
    execute format(
      'insert into pgpm_formal.store (parent_table, s3_key, identity)
       select $1, s.s3_key, %s from pgpm_formal_stage s cross join lateral jsonb_populate_record(null::%s, s.j) t
        where s.parent_table = $1 and s.s3_key is not null and s.j is not null',
      pgpm_formal._ident_sql(r.key_cols), r.parent_table::regclass)
    using r.parent_table;
    insert into pgpm_formal.store_listing (parent_table) values (r.parent_table) on conflict do nothing;
  end loop;
end;
$$;
select 'S', :'file', (select count(*) from pgpm_formal.store_listing),
       (select count(distinct (parent_table, s3_key)) from pgpm_formal.store),
       (select count(*) from pgpm_formal.store);
select 'E', :'file', format('store not loaded for %s: %s', parent_table::regclass, coalesce(j #>> '{}', 'unknown'))
  from pgpm_formal_stage where s3_key is null and not ok;
\endif

select 'V', :'file', c.invariant, coalesce(c.parent_table::text, ''), regexp_replace(c.identity, '[\t\n\r]', ' ', 'g'),
       regexp_replace(c.detail, '[\t\n\r]', ' ', 'g')
  from pgpm_formal.check(
         case when :'scope' = '' then null
              else array(select c.oid::regclass from pg_class c join pg_namespace n on n.oid = c.relnamespace
                          where format('%I.%I', n.nspname, c.relname) = any (nullif(:'scope', '')::text[])
                         union
                         select h.objid::regclass from pgpm_formal.drop_history h
                          where format('%I.%I', h.schema_name, h.object_name) = any (nullif(:'scope', '')::text[])) end) c
 order by 3, 5;
select 'J', :'file', j.invariant, j.judged, j.parents, j.identities, j.expected,
       regexp_replace(coalesce(j.note, ''), '[\t\n\r]', ' ', 'g')
  from pgpm_formal.judged() j;
select 'T', :'file', round(extract(epoch from clock_timestamp() - :'report_t0'::timestamptz) * 1000)::bigint;
