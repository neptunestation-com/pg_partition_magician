-- Issue #898 (pass 8, F3-03): an outgoing foreign key added to, changed on or dropped from a parent while a
-- regrain is in flight is drift, and restarts the run.
--
-- THE DEFECT. regrain_step gives each copy its own validated copy of every outgoing foreign key the parent
-- has, while the copy is still empty (#348), so that the swap's ATTACH PARTITION adopts the key rather than
-- validating it: docs/reference.md promises the swap never validates one under its lock. But the drift check
-- (_regrain_shape_drift) compared columns and CHECK constraints only. A key added to the parent after a copy
-- was made was not drift, the copy reached the swap without it, and ATTACH cloned the key onto it and
-- validated it by scanning the copy while the swap held ACCESS EXCLUSIVE on the parent: a lock held for a
-- duration that grows with the partition. A key the parent dropped stayed on the copy, so the fine child kept
-- refusing rows the parent now accepts.
--
-- THE FIX. The parent's validated outgoing keys join the comparison, by definition, so a key added, changed
-- or dropped since the copies were made restarts the run (regrain_restart), as #817 does for a CHECK, and
-- every copy is made again born with the keys the parent has now. That the swap then scans no copy is a
-- scan-counter assertion, which needs counters flushed by a later transaction than the swap, so it lives in
-- bench/regrain_fk_drift_swap_scan.sh; this file states the restart and what the swap attaches.
--
-- Fixtures asymmetric on purpose (200, 230, 170 and 140 rows). rg251a has no key and gains one; rg251b keeps
-- its key's name and changes its definition (ON DELETE CASCADE), so a comparison by name alone would miss
-- it; rg251c drops its key and then takes a row the dropped key would refuse, below the cursor. rg251d is the
-- control: a key from the start that references a PARTITIONED table, whose clones onto the referenced
-- partitions (conparentid set) sit on the parent and on every copy and must not read as drift.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(17);

create schema s251;
create table public.ref251 (id int primary key);
insert into public.ref251 select generate_series(1, 400);
create table public.ref251p (id int primary key) partition by range (id);
create table public.ref251p_lo partition of public.ref251p for values from (0) to (200);
create table public.ref251p_hi partition of public.ref251p for values from (200) to (1000);
insert into public.ref251p select generate_series(1, 400);

create function s251.mk(p_rel text, p_n int, p_fk text) returns void language plpgsql as $f$
begin
  execute format('create table public.%I (id bigint primary key, ref_id int, note text)', p_rel);
  execute format('insert into public.%I select g, g, ''old'' || g from generate_series(1, %s) g', p_rel, p_n);
  if p_fk is not null then
    execute format('alter table public.%I add constraint %I foreign key (ref_id) references %s (id)',
                   p_rel, p_rel || '_fk', p_fk);
  end if;
end $f$;
create function s251.start(p_rel text) returns void language plpgsql as $f$
begin
  perform pgpm.obtain(('public.' || p_rel)::regclass);
  execute format('insert into public.%I (id, note) values (450, %L)', p_rel, 'frontier');
  perform pgpm.set_regrain(('public.' || p_rel)::regclass, '50');
end $f$;
create function s251.restarts(p_rel text) returns text[] language sql as $f$
  select array_agg(rows || ':' || method order by id) from pgpm.log
   where parent_table = ('public.' || p_rel)::regclass and action = 'regrain_restart'
$f$;
create function s251.swapped(p_rel text, p_hi text) returns boolean language sql as $f$
  select exists (select 1 from pgpm.log where parent_table = ('public.' || p_rel)::regclass
                  and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = p_hi)
     and (select coarse_partitions from pgpm.status() where parent = ('public.' || p_rel)::regclass) = 0
$f$;
-- Each attached fine child below p_hi, with the outgoing keys it carries: 'clone' for a key whose parent
-- constraint is the parent table's own key (adopted at ATTACH, or cloned there), 'own' for a standalone
-- one, with ' cascade' when it cascades deletes. Clones onto a referenced table's partitions are left out.
-- The parent's rows are fenced off first (MATERIALIZED) and only then cast: pgpm.part also holds the
-- template's time-keyed fixture (public.messages, a monthly grid), and with the parent computed from p_rel
-- the cheaper `lo::numeric < p_hi` qual sorted first, so a sequential scan of pgpm.part cast a timestamptz
-- bound and the file died 'invalid input syntax for type numeric' whenever the planner chose one.
create function s251.child_keys(p_rel text, p_hi numeric) returns text[] language sql as $f$
  with p as materialized (
    select * from pgpm.part where parent_table = ('public.' || p_rel)::regclass and attached)
  select array_agg(p.lo || '-' || p.hi || ':' || coalesce(k.keys, '') order by p.lo::numeric)
    from p
    left join lateral (
      select string_agg(case when pk.oid is not null then 'clone' else 'own' end
                        || case when c.confdeltype = 'c' then ' cascade' else '' end, ',') as keys
        from pg_constraint c
        left join pg_constraint pk on pk.oid = c.conparentid and pk.conrelid = p.parent_table
       where c.conrelid = p.child_oid and c.contype = 'f'
         and (c.conparentid = 0 or pk.oid is not null)) k on true
   where p.lo::numeric < p_hi
$f$;

select s251.mk('rg251a', 200, null);
select s251.mk('rg251b', 230, 'public.ref251');
select s251.mk('rg251c', 170, 'public.ref251');
select s251.mk('rg251d', 140, 'public.ref251p');
call pgpm.transmute('public.rg251a', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
call pgpm.transmute('public.rg251b', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
call pgpm.transmute('public.rg251c', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
call pgpm.transmute('public.rg251d', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select s251.start('rg251a'), s251.start('rg251b'), s251.start('rg251c'), s251.start('rg251d');
call pgpm.maintain('public.rg251a'); call pgpm.maintain('public.rg251a');   -- prepare, copy [0, 50)
call pgpm.maintain('public.rg251b'); call pgpm.maintain('public.rg251b');
call pgpm.maintain('public.rg251c'); call pgpm.maintain('public.rg251c');

create table s251.copies as
  select parent_table, child_oid from pgpm.part
   where parent_table in ('public.rg251a'::regclass, 'public.rg251b'::regclass, 'public.rg251c'::regclass)
     and not attached and lo = '0' and hi = '50';
-- the outgoing keys the copy made before the DDL carries, by definition
create function s251.copy_keys(p_rel text) returns text language sql as $f$
  select coalesce(string_agg(pg_get_constraintdef(k.oid), ' | ' order by k.conname), '')
    from pg_constraint k join s251.copies c on k.conrelid = c.child_oid
   where c.parent_table = ('public.' || p_rel)::regclass and k.contype = 'f' and k.conparentid = 0
$f$;

select ok((select count(*) from s251.copies c join pg_class k on k.oid = c.child_oid) = 3
          and (select array_agg(lo || '-' || hi || ':' || rows order by parent_table::text) from pgpm.log
                where parent_table in ('public.rg251a'::regclass, 'public.rg251b'::regclass, 'public.rg251c'::regclass)
                  and action = 'regrain_copy')
              = array['0-50:49', '0-50:49', '0-50:49'],
          'LIVENESS: all three runs are mid-flight, each with its copy of [0, 50) made and filled');
select is(s251.copy_keys('rg251a') || ' / ' || s251.copy_keys('rg251b') || ' / ' || s251.copy_keys('rg251c'),
          ' / FOREIGN KEY (ref_id) REFERENCES ref251(id) / FOREIGN KEY (ref_id) REFERENCES ref251(id)',
          'LIVENESS: the copies carry the keys their parents had when they were made (none for rg251a)');

-- ---------------------------------------------------------------------------------------------------
-- The DDL, between ticks.
-- ---------------------------------------------------------------------------------------------------
alter table public.rg251a add constraint rg251a_fk foreign key (ref_id) references public.ref251 (id);
alter table public.rg251b drop constraint rg251b_fk;
alter table public.rg251b add constraint rg251b_fk foreign key (ref_id) references public.ref251 (id) on delete cascade;
alter table public.rg251c drop constraint rg251c_fk;
update public.rg251c set ref_id = 9999 where id = 20;                     -- captured, below the cursor
create table s251.want_a as select id, ref_id, note from public.rg251a where id < 300;
create table s251.want_c as select id, ref_id, note from public.rg251c where id < 300;

do $$ declare v text; begin for i in 1..30 loop
  call pgpm.maintain('public.rg251a', v); call pgpm.maintain('public.rg251b', v);
  call pgpm.maintain('public.rg251c', v); call pgpm.maintain('public.rg251d', v);
end loop; end $$;

-- ---------------------------------------------------------------------------------------------------
-- A: a key added.
-- ---------------------------------------------------------------------------------------------------
select is((select array_agg(left(r, 2) || (r like '%the parent has foreign key FOREIGN KEY (ref_id) REFERENCES ref251(id) and the copy %')::text)
             from unnest(s251.restarts('rg251a')) r),
          array['1:true'],
          'A: the run restarts exactly once, discarding the one copy, because the parent gained a foreign key the copy lacks');
select ok(s251.swapped('rg251a', '300')
          and not exists (select 1 from s251.copies c join pg_class k on k.oid = c.child_oid
                           where c.parent_table = 'public.rg251a'::regclass),
          'A: the copy made before the key is discarded and the regrain swaps, leaving no coarse partition');
select is(s251.child_keys('rg251a', 300),
          array['0-50:clone', '50-100:clone', '100-150:clone', '150-200:clone', '200-250:clone', '250-300:clone'],
          'A: every fine child the swap attached carries the parent''s new key as a clone of it, and no key of its own');
select results_eq('select id, ref_id, note from public.rg251a where id < 300 order by id',
                  'select id, ref_id, note from s251.want_a order by id',
                  'A: the regrained range holds exactly the source''s rows');

-- ---------------------------------------------------------------------------------------------------
-- B: a key changed under the same name.
-- ---------------------------------------------------------------------------------------------------
select is((select array_agg(left(r, 2)
                            || (r like '%the parent has foreign key FOREIGN KEY (ref_id) REFERENCES ref251(id) ON DELETE CASCADE and the copy %')::text
                            || (r like '% has foreign key FOREIGN KEY (ref_id) REFERENCES ref251(id) and the parent does not%')::text)
             from unnest(s251.restarts('rg251b')) r),
          array['1:truetrue'],
          'B: the run restarts exactly once, naming the parent''s new definition and the copy''s old one');
select ok(s251.swapped('rg251b', '300'), 'B: the regrain swaps');
select is(s251.child_keys('rg251b', 300),
          array['0-50:clone cascade', '50-100:clone cascade', '100-150:clone cascade', '150-200:clone cascade',
                '200-250:clone cascade', '250-300:clone cascade'],
          'B: every fine child carries the key as the parent defines it now (ON DELETE CASCADE), and not the old one');

-- ---------------------------------------------------------------------------------------------------
-- C: a key dropped, then a row it would have refused.
-- ---------------------------------------------------------------------------------------------------
select is((select string_agg(distinct method, ' | ') from pgpm.log
            where parent_table = 'public.rg251c'::regclass and action = 'skip_regrain'),
          null, 'C: no auto-regrain tick fails after the key is dropped');
select is((select array_agg(left(r, 2) || (r like '% has foreign key FOREIGN KEY (ref_id) REFERENCES ref251(id) and the parent does not%')::text)
             from unnest(s251.restarts('rg251c')) r),
          array['1:true'],
          'C: the run restarts exactly once, discarding the one copy, because it carries a key the parent dropped');
select ok(s251.swapped('rg251c', '200'), 'C: the regrain swaps');
select is(s251.child_keys('rg251c', 200),
          array['0-50:', '50-100:', '100-150:', '150-200:'],
          'C: no fine child the swap attached carries a foreign key');
select results_eq('select id, ref_id, note from public.rg251c where id < 300 order by id',
                  'select id, ref_id, note from s251.want_c order by id',
                  'C: the table holds exactly the source''s rows, row 20 with the ref_id the dropped key would refuse');

-- ---------------------------------------------------------------------------------------------------
-- D (control): a key from the start, referencing a partitioned table, and no DDL.
-- ---------------------------------------------------------------------------------------------------
select ok((select count(*) from pg_constraint where conrelid = 'public.rg251d'::regclass and contype = 'f' and conparentid <> 0) > 0,
          'D LIVENESS: the parent''s key has clones onto the referenced table''s partitions, which the comparison must leave out');
select ok(s251.restarts('rg251d') is null and s251.swapped('rg251d', '200')
          and (select array_agg(lo || '-' || hi || ':' || rows order by id) from pgpm.log
                where parent_table = 'public.rg251d'::regclass and action = 'regrain_copy')
              = array['0-50:49', '50-100:50', '100-150:41'],
          'D: with no DDL the run copies each populated sub-range once, swaps, and never restarts');
select is(s251.child_keys('rg251d', 200),
          array['0-50:clone', '50-100:clone', '100-150:clone', '150-200:clone'],
          'D: every fine child carries the parent''s key as a clone of it');

select * from finish();
