-- transmute and untransmute carry a REPLICA IDENTITY USING INDEX whose index was dropped as NOTHING, the identity
-- PostgreSQL gives a table in that state, rather than refusing it as an index neither of them carried (issue #1036).
--
-- PostgreSQL lets DROP INDEX remove a table's replica identity index and leaves relreplident = 'i' with no index
-- marked indisreplident, a state it documents as behaving like NOTHING (the #978 state, which obtain already reads
-- that way: tests/275). Step 9d of transmute read it as an identity index that was not carried onto the
-- partitioned parent, and untransmute as one whose copy on the original table was missing, so both refused with a
-- diagnosis naming an index that does not exist. The reference says the parent takes the table's identity and the
-- restored table the parent's, and the identity either has here is NOTHING, so that is what each now carries.
--
-- Fixtures, asymmetric so a fix that reads every USING INDEX as NOTHING cannot pass:
--   ta376  identity USING INDEX ta376_ident, then ta376_ident dropped, BEFORE transmute (step 9d's state): the
--          parent takes NOTHING, and so does the cell obtain mints past the monolith;
--   tb376  identity USING INDEX on its key, kept: the parent's identity is still the parent's key index;
--   tc376  converted first, then given identity USING INDEX tc376_ident on the parent and the index dropped
--          (untransmute's state): untransmute hands the restored table NOTHING, and its three rows by value.
-- bench/transmute_state_reads.sh runs this file against the mutants that put each refusal back.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(10);

create table public.ta376 (id bigint primary key, v text);
insert into public.ta376 select g, 'a' || g from generate_series(1, 40) g;
create unique index ta376_ident on public.ta376 (id);
alter table public.ta376 replica identity using index ta376_ident;
drop index public.ta376_ident;

create table public.tb376 (id bigint primary key, v text);
insert into public.tb376 select g, 'b' || g from generate_series(1, 30) g;
alter table public.tb376 replica identity using index tb376_pkey;

select ok((select relreplident = 'i' from pg_class where oid = 'public.ta376'::regclass)
          and not exists (select 1 from pg_index where indrelid = 'public.ta376'::regclass and indisreplident),
  'LIVENESS: ta376''s identity is USING INDEX with no identity index left (PostgreSQL allowed the drop)');

-- ==================== A: transmute, step 9d ====================
\set ON_ERROR_STOP 0
call pgpm.transmute('public.ta376', 'id', 100::bigint, p_obtain => 1, p_paused => false);
\set ON_ERROR_STOP 1
select set_config('t376.err', :'LAST_ERROR_MESSAGE', false) is not null as captured \gset
\set ON_ERROR_STOP 0
call pgpm.transmute('public.tb376', 'id', 100::bigint, p_obtain => 1, p_paused => false);
\set ON_ERROR_STOP 1

select is(current_setting('t376.err'), '',
  'transmute converts a table whose identity index was dropped, rather than refusing it as an index it did not carry');
select is((select relkind::text || ':' || relreplident::text from pg_class where oid = 'public.ta376'::regclass),
  'p:n', 'ta376''s partitioned parent takes NOTHING, the identity the table had in effect');
select is((select array_agg(c.relname::text || ':' || c.relreplident::text order by c.relname)
             from pg_inherits h join pg_class c on c.oid = h.inhrelid where h.inhparent = 'public.ta376'::regclass
              and c.relname <> 'ta376_p0000000000000000000'),
  array['ta376_p0000000000000000100:n'],
  'the cell minted past the monolith takes NOTHING from the parent, not the default');
select is((select string_agg(id::text, ',' order by id) from public.ta376 where id in (1, 40)), '1,40',
  'invariant: ta376 holds its rows through the parent');
select is((select relkind::text || ':' || relreplident::text || ':'
                  || (select ic.relname from pg_index i join pg_class ic on ic.oid = i.indexrelid
                       where i.indrelid = 'public.tb376'::regclass and i.indisreplident)
             from pg_class where oid = 'public.tb376'::regclass),
  'p:i:tb376_pkey',
  'LIVENESS: a kept identity index is still carried as USING INDEX, the parent''s key, not as NOTHING');

-- ==================== B: untransmute ====================
create table public.tc376 (id bigint primary key, v text);
insert into public.tc376 values (5, 'five'), (17, 'seventeen'), (230, 'two thirty');
call pgpm.transmute('public.tc376', 'id', 100::bigint, p_obtain => 1, p_paused => false);
create unique index tc376_ident on public.tc376 (id);
alter table public.tc376 replica identity using index tc376_ident;
drop index public.tc376_ident;
select ok((select relkind = 'p' and relreplident = 'i' from pg_class where oid = 'public.tc376'::regclass)
          and not exists (select 1 from pg_index where indrelid = 'public.tc376'::regclass and indisreplident),
  'LIVENESS: tc376 is the managed parent, its identity USING INDEX with no identity index left');

select lives_ok($$ select pgpm.untransmute('public.tc376') $$,
  'untransmute hands back a parent whose identity index was dropped, rather than refusing a copy it cannot find');
select is((select relkind::text || ':' || relreplident::text from pg_class where oid = 'public.tc376'::regclass),
  'r:n', 'the restored tc376 takes NOTHING, the parent''s identity in effect');
select is((select string_agg(id || ':' || v, ',' order by id) from public.tc376),
  '5:five,17:seventeen,230:two thirty', 'invariant: the restored tc376 holds its three rows by value');

select * from finish();
