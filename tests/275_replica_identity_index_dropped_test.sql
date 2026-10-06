-- A parent whose REPLICA IDENTITY USING INDEX index was dropped still gets its forward grid, and every
-- partition minted for it takes NOTHING, the identity PostgreSQL gives the parent in that state (issue #978).
--
-- PostgreSQL lets DROP INDEX remove a table's replica identity index and leaves relreplident = 'i' with no
-- index marked indisreplident, a state it documents as behaving like NOTHING. _replica_identity_like_parent
-- (#782) read that state as "the child has no index attached under the parent's identity index" and raised,
-- so every _create_partition failed: obtain() raised, maintain_obtain() logged skip_obtain on every tick,
-- extend_to() raised, and once the cells built ahead of the frontier were used up every write past them was
-- refused. Now a parent in that state gives the partition NOTHING, and the transaction that does it logs
-- warn_replica_identity_nothing once for the parent, naming the first partition, because a partition minted
-- then keeps NOTHING after the parent is given an identity again.
--
-- Fixtures, asymmetric so a mutant cannot pass by treating both parents alike:
--   rx  identity USING INDEX rx_ident, then rx_ident dropped: the issue's state. The cells obtain and
--       extend_to mint take NOTHING (not the default, which would publish the key the parent no longer
--       publishes), the existing partitions keep the default they had, and writes land in the new cells;
--   ry  identity USING INDEX ry_ident, left in place: obtain still maps the new cell's identity to its own
--       index attached under ry_ident, and logs no warning, so the fix is not "USING INDEX means NOTHING".
-- bench/replica_identity_index_dropped.sh runs this file against the mutants that put the raise back
-- (replica_identity_index_dropped_raises) and that leave the new cell at the default
-- (replica_identity_index_dropped_default), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(14);

set client_min_messages = warning;

-- every partition of a parent with its identity, in name order: 'name:identity'
create function pg_temp.idents(p regclass) returns text[] language sql as $$
  select array_agg(c.relname::text || ':' || c.relreplident::text order by c.relname)
    from pg_inherits h join pg_class c on c.oid = h.inhrelid where h.inhparent = p
$$;
-- the actions logged for a parent after a mark, in the order they were written
create function pg_temp.actions(p regclass, mark bigint) returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log where parent_table = p and id > mark
$$;

-- ==================== fixtures ====================
create table public.rx (id int8 primary key, body text);
insert into public.rx select g, 'r' from generate_series(1, 500) g;
call pgpm.transmute('public.rx', 'id', 1000::bigint, p_obtain => 2, p_paused => false);
create unique index rx_ident on public.rx (id);
alter table public.rx replica identity using index rx_ident;
drop index public.rx_ident;
insert into public.rx values (2500, 'frontier');

create table public.ry (id int8 primary key, body text);
insert into public.ry select g, 'y' from generate_series(1, 300) g;
call pgpm.transmute('public.ry', 'id', 1000::bigint, p_obtain => 2, p_paused => false);
create unique index ry_ident on public.ry (id);
alter table public.ry replica identity using index ry_ident;
insert into public.ry values (2600, 'frontier');

select ok((select relreplident = 'i' from pg_class where oid = 'public.rx'::regclass)
          and not exists (select 1 from pg_index where indrelid = 'public.rx'::regclass and indisreplident),
  'LIVENESS: rx''s identity is USING INDEX with no identity index left (PostgreSQL allowed the drop)');
select is(pg_temp.idents('public.rx'),
  array['rx_p0000000000000000000:d', 'rx_p0000000000000001000:d', 'rx_p0000000000000002000:d'],
  'LIVENESS: rx has only the monolith and the two cells transmute built, each with the default identity, so the cells above 2500 are obtain''s to build');
select ok((select relreplident = 'i' from pg_class where oid = 'public.ry'::regclass)
          and exists (select 1 from pg_index where indrelid = 'public.ry'::regclass and indisreplident),
  'LIVENESS: ry''s identity is USING INDEX ry_ident, still in place');

select coalesce(max(id), 0) as mark from pgpm.log \gset
call pgpm.maintain_obtain('public.rx');
call pgpm.maintain_obtain('public.ry');

-- ==================== rx: the tick builds, and the cells take NOTHING ====================
select is(pg_temp.actions('public.rx', :mark),
  array['warn_replica_identity_nothing', 'obtain', 'obtain'],
  'rx: the tick logged one warning and built two cells, and no skip_obtain');
select is((select array_agg(lo order by id) from pgpm.log
            where parent_table = 'public.rx'::regclass and id > :mark and action = 'obtain'),
  array['3000', '4000'], 'rx: the cells it built are [3000, 4000) and [4000, 5000)');
select is(pg_temp.idents('public.rx'),
  array['rx_p0000000000000000000:d', 'rx_p0000000000000001000:d', 'rx_p0000000000000002000:d',
        'rx_p0000000000000003000:n', 'rx_p0000000000000004000:n'],
  'rx: the new cells take NOTHING, the identity PostgreSQL gives the parent; the existing partitions keep theirs');
select is((select method from pgpm.log
            where parent_table = 'public.rx'::regclass and id > :mark and action = 'warn_replica_identity_nothing'),
  'rx_p0000000000000003000 took REPLICA IDENTITY NOTHING: the identity index of rx was dropped, which PostgreSQL treats as NOTHING; partitions minted until rx is given a replica identity again keep NOTHING',
  'rx: the warning names the first partition that took NOTHING and why');

-- writes land in the new cells: 3 in, 1 deleted, 1 updated
insert into public.rx values (3100, 'w'), (3200, 'w'), (4100, 'w');
delete from public.rx where id = 3200;
update public.rx set body = 'upd' where id = 3100;
select is((select array_agg(id || ':' || body || ':' || tableoid::regclass::text order by id) from public.rx where id >= 3000),
  array['3100:upd:rx_p0000000000000003000', '4100:w:rx_p0000000000000004000'],
  'rx: writes land in the new cells: 3100 updated, 3200 gone, 4100 kept, each in its own cell');

-- ==================== rx: extend_to, a second transaction, warns once more ====================
select coalesce(max(id), 0) as mark2 from pgpm.log \gset
select is(pgpm.extend_to('public.rx', '6500'), 2, 'rx: extend_to to 6500 builds two cells');
select is(pg_temp.actions('public.rx', :mark2),
  array['warn_replica_identity_nothing', 'obtain', 'obtain'],
  'rx: extend_to logged one warning for its two cells');
select is(pg_temp.idents('public.rx'),
  array['rx_p0000000000000000000:d', 'rx_p0000000000000001000:d', 'rx_p0000000000000002000:d',
        'rx_p0000000000000003000:n', 'rx_p0000000000000004000:n',
        'rx_p0000000000000005000:n', 'rx_p0000000000000006000:n'],
  'rx: the cells extend_to built take NOTHING too');

-- ==================== ry: an identity index still in place maps as before, silently ====================
select is(pg_temp.actions('public.ry', :mark), array['obtain', 'obtain'],
  'ry: the tick built two cells and logged no warning');
select is(pg_temp.idents('public.ry'),
  array['ry_p0000000000000000000:d', 'ry_p0000000000000001000:d', 'ry_p0000000000000002000:d',
        'ry_p0000000000000003000:i', 'ry_p0000000000000004000:i'],
  'ry: the new cells take USING INDEX');
select is((select array_agg(c.relname::text || ':' || ci.relname::text || ':' || pc.relname::text order by c.relname)
             from pg_index i
             join pg_class ci on ci.oid = i.indexrelid
             join pg_class c on c.oid = i.indrelid
             join pg_inherits h on h.inhrelid = i.indexrelid
             join pg_class pc on pc.oid = h.inhparent
            where i.indisreplident and c.relname in ('ry_p0000000000000003000', 'ry_p0000000000000004000')),
  array['ry_p0000000000000003000:ry_p0000000000000003000_id_idx:ry_ident',
        'ry_p0000000000000004000:ry_p0000000000000004000_id_idx:ry_ident'],
  'ry: each new cell''s identity index is its own, attached under ry_ident');

select * from finish();
