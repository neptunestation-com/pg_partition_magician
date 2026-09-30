-- The cutover names each carried secondary index's partitioned copy by identity, whatever the name holds
-- (issue #669).
--
-- Step 9b rewrote each carried index's definition with regexp_replace(def, '^CREATE (UNIQUE )?INDEX \S+ ON ',
-- ...), and \S+ cannot match a quoted name holding a space. The rewrite silently did nothing, the cutover
-- executed the ORIGINAL CREATE INDEX, which failed with a raw 42P07 because that index is right there on the
-- monolith, and the conversion died after phases 1 and 2 had committed the write-rejecting bound; every
-- re-run failed the same way. The prefix pg_get_indexdef writes (CREATE [UNIQUE] INDEX <quote_ident(name)> ON)
-- is now replaced whole.
--
-- Fixtures, asymmetric on purpose: four secondary indexes on one table whose names a pattern gets wrong in
-- different ways (a space; the text " ON " inside the name; an embedded double quote, which quote_ident
-- doubles; and a UNIQUE one with a space, which takes the other prefix), and one plain lowercase name that
-- any rewrite handles. Each must come out as a partitioned index <name>_pgpm on the parent, with the
-- monolith's ORIGINAL index (the same oid) attached under it, the unique one still unique, and a copy on
-- the forward partitions. A second table with one plain index converts either way (the witness that the
-- shape is convertible at all). bench/carried_index_quoted_name.sh runs this file against a mutant with the
-- pattern put back (carried_index_name_by_pattern), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(14);

set timezone = 'UTC';
create table public.qx (id bigint primary key, body text, tag text);
insert into public.qx select g, 'b' || g, 't' || (g % 3) from generate_series(1, 7) g;
create index "Body Lookup" on public.qx (body);
create index "by tag ON body" on public.qx (tag, body);
create index "quo""te" on public.qx (tag);
create unique index "Uniq Id Body" on public.qx (id, body);
create index qx_plain on public.qx (body, tag);
select array_agg(c.oid order by c.relname::text collate "C") as qx_idx_oids
  from pg_index i join pg_class c on c.oid = i.indexrelid
 where i.indrelid = 'public.qx'::regclass and not i.indisprimary \gset
select oid as qx_oid from pg_class where oid = 'public.qx'::regclass \gset

select is((select array_agg(pg_get_indexdef(c.oid) ~ ('^CREATE (UNIQUE )?INDEX ' || quote_ident(c.relname) || ' ON ') order by c.relname::text collate "C")
             from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.qx'::regclass and not i.indisprimary),
  array[true, true, true, true, true],
  'LIVENESS: each definition starts CREATE [UNIQUE] INDEX <quoted name> ON');
select is((select array_agg(pg_get_indexdef(c.oid) ~ '^CREATE (UNIQUE )?INDEX \S+ ON ' order by c.relname::text collate "C")
             from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.qx'::regclass and not i.indisprimary),
  array[false, false, false, true, true],
  'LIVENESS: the old \S+ pattern misses the three names holding a space (in C order: Body Lookup, Uniq Id Body, by tag ON body, quo"te, qx_plain)');

create table public.qy (id bigint primary key, body text);
insert into public.qy select g, 'b' || g from generate_series(1, 7) g;
create index qy_body on public.qy (body);
call pgpm.transmute('public.qy', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.qy'::regclass), 'p',
  'LIVENESS: the same shape with a plain index name converts');

call pgpm.transmute('public.qx', 'id', 100::bigint, p_obtain => 2);

select is((select relkind::text from pg_class where oid = 'public.qx'::regclass), 'p', 'qx converted');
select is((select array_agg(c.relname::text order by c.relname::text collate "C") from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.qx'::regclass and not i.indisprimary),
  array['Body Lookup_pgpm', 'Uniq Id Body_pgpm', 'by tag ON body_pgpm', 'quo"te_pgpm', 'qx_plain_pgpm'],
  'the parent carries exactly <name>_pgpm for each of the five');
select is((select array_agg(c.relkind::text order by c.relname::text collate "C") from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.qx'::regclass and not i.indisprimary),
  array['I', 'I', 'I', 'I', 'I'], 'each of them is a partitioned index');
select is((select array_agg(ch.oid order by ch.relname::text collate "C")
             from pg_index i join pg_class p on p.oid = i.indexrelid
             join pg_inherits h on h.inhparent = p.oid join pg_class ch on ch.oid = h.inhrelid
            where i.indrelid = 'public.qx'::regclass and not i.indisprimary and ch.relname in
                  ('Body Lookup', 'by tag ON body', 'quo"te', 'Uniq Id Body', 'qx_plain')),
  :'qx_idx_oids'::oid[],
  'the monolith''s own five indexes, by oid, are attached under them');
select is((select array_agg(h.inhparent::regclass::text order by ch.relname::text collate "C")
             from pg_class ch join pg_inherits h on h.inhrelid = ch.oid
            where ch.oid = any(:'qx_idx_oids'::oid[])),
  array['"Body Lookup_pgpm"', '"Uniq Id Body_pgpm"', '"by tag ON body_pgpm"', '"quo""te_pgpm"', 'qx_plain_pgpm'],
  'each original is attached under its OWN copy, not a neighbour''s');
select is((select array_agg(i.indrelid order by i.indrelid) from pg_index i where i.indexrelid = any(:'qx_idx_oids'::oid[])),
  array_fill(:qx_oid::oid, array[5]),
  'the originals still index the monolith (the original table, same oid)');
select is((select indisunique from pg_index where indexrelid = '"Uniq Id Body_pgpm"'::regclass), true,
  'the unique one is still unique on the parent');
select is((select indisunique from pg_index where indexrelid = '"Body Lookup_pgpm"'::regclass), false,
  'and a non-unique one did not become unique');
select is((select count(*)::int from pg_inherits h
            where h.inhparent = '"Body Lookup_pgpm"'::regclass),
          (select count(*)::int from pg_inherits where inhparent = 'public.qx'::regclass),
  'every partition, the forward ones included, has a copy under "Body Lookup_pgpm"');
select cmp_ok((select count(*)::int from pg_inherits where inhparent = 'public.qx'::regclass), '>', 1,
  'LIVENESS: qx has forward partitions besides the monolith');
select ok(not exists (select 1 from pg_constraint where conname = 'pgpm_monolith_bound'
                       and conrelid in ('public.qx'::regclass, :qx_oid::oid::regclass))
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = :qx_oid::oid::regclass),
  'no bound and no claim are left behind');

select * from finish();
