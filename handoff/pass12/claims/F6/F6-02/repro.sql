-- F6-02: from_hypertable_copy(p_track_changes => true) names the key index it pre-builds after whichever
-- pg_constraint row has conindid = the key's index (`select conname into v_keyconname from pg_constraint where
-- conindid = v_keyidx`, no conrelid/contype filter). An INCOMING foreign key that references the hypertable's
-- primary key (TimescaleDB 2.16 allows one) has that same conindid, so when its row comes first in
-- pg_constraint the copy builds `<fk name>_pgpm_new`. The cutover asks for `<pk name>_pgpm_new` on the copy,
-- does not find it, builds the key a second time, and the copy's index survives the swap as a stray, redundant
-- UNIQUE index on the migrated table (carried by transmute onto every partition). The reference promises the
-- copy's key index "is adopted rather than rebuilt" (one key-index build instead of two).
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(5);

create table public.f602 (id int not null, ts timestamptz not null, v int, constraint f602_pk primary key (id, ts));
select create_hypertable('public.f602', 'ts', chunk_time_interval => interval '1 day');
insert into public.f602 select g, '2026-10-01'::timestamptz + make_interval(hours => g), g from generate_series(1, 50) g;
create table public.f602_ref (rid int primary key, id int, ts timestamptz,
  constraint f602_ref_fk foreign key (id, ts) references public.f602 (id, ts));
insert into public.f602_ref values (1, 5, '2026-10-01'::timestamptz + interval '5 hours');
-- an ordinary rename of the key rewrites its pg_constraint row, so the incoming key's row now comes first
alter table public.f602 rename constraint f602_pk to f602_pkey;

select ok((select array_agg(conname::text order by conname) from pg_constraint
            where conindid = (select indexrelid from pg_index where indrelid = 'public.f602'::regclass and indisprimary))
          = array['f602_pkey', 'f602_ref_fk'],
  'LIVENESS: the hypertable''s primary key index is the conindid of both its own key and the incoming foreign key');

call pgpm.from_hypertable_copy('public.f602', 'ts', true);

select ok(exists (select 1 from pg_index where indrelid = to_regclass('public.f602_pgpm_dest')),
  'LIVENESS: the tracking copy pre-built a key index on the copy');
select is((select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = to_regclass('public.f602_pgpm_dest')),
          array['f602_pkey_pgpm_new'],
  'the tracking copy pre-built the primary key''s index under the primary key''s temp name');

call pgpm.from_hypertable_cutover('public.f602', 'ts', interval '1 day', p_paused => false);

select ok((select count(*) from public.f602) = 50 and exists (select 1 from pgpm.config where parent_table = 'public.f602'::regclass),
  'LIVENESS: the cutover swapped and handed the table to transmute');
select is((select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.f602'::regclass and i.indisunique),
          array['f602_pkey'],
  'the migrated table carries exactly one unique index, its primary key (no stray copy-built duplicate)');
select * from finish();
