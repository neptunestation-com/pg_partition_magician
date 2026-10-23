-- The ATTACH every skip_archive remedy spells attaches the table back as typed, on a grid whose column holds encoded
-- values (issue #1371).
--
-- THE DEFECT. Three skip_archive remedies tell the operator to attach a table back on its bounds: _archive_unheld_reason
-- for a row with no recorded oid over a table detached by hand, the same function for a table pgpm's own retirement
-- detached before archiving was configured, and _archive_left_reason for a table whose detach began while the strategy
-- ran. Each spelled ALTER TABLE ... ATTACH PARTITION ... FOR VALUES FROM (%L) TO (%L) over pgpm.part's NATIVE bounds,
-- never encoded for the control column (_disown_retirement's remedy encodes them, #1272). On a uuidv7 grid the native
-- bound is an instant's text, so the statement as typed is refused (invalid input syntax for type uuid); on a text_time
-- grid it names bounds the column's values never fall in, and the table's rows violate them.
--
-- THE CONTRACT. Each of the three remedies, typed exactly as logged, attaches the table back to its parent on its
-- bounds, after which its rows read through the parent.
--   PART U  a uuidv7 grid, all three remedies, through _archive_step.
--   PART T  a text_time grid (cuid v1 shaped), all three remedies, through _archive_step.
--
-- THE FIXTURE. Per grid, three month partitions in 2020 (aged under retain 1 year) built by hand on encoded bounds and
-- recorded with adopt_partition, then write-blocked by _enforce_write_blocks: _a (ids 1, 2) is unanchored and detached
-- by hand, _b (id 3) carries pgpm's retirement mark with the record of its dispatch and its detach landed (written as
-- retire() writes them; no pg_cron here), and _c (ids 4, 5, 6) is detached by the strategy itself while it runs, the
-- state a DETACH ... CONCURRENTLY under the hold leaves (tests/330 part F races a second session for it). The frontier
-- holds ids 100 and 101. Asymmetric: two, one and three ids, and each check names which ids read through the parent.
-- B's mark is cleared at the end of each part.
--
-- bench/archive_remedy_encoded_bounds.sh runs this file against bench/mutations/mutate.py's
-- archive_remedy_bounds_unencoded.
create extension if not exists pgtap;
set client_min_messages = warning;
set datestyle = 'ISO, MDY';
set timezone = 'UTC';

select plan(24);

create schema t358;
-- a control value of the grid's kind at p_at, distinct per n
create function t358.key(p_kind text, p_at timestamptz, p_n int) returns text language sql stable as $$
  select case when p_kind = 'uuidv7'
              then substr(pgpm._ts_to_uuid(p_at)::text, 1, 14) || '7' || lpad(to_hex(p_n), 3, '0') || '-8'
                   || lpad(to_hex(p_n), 3, '0') || '-' || lpad(to_hex(p_n), 12, '0')
              else pgpm._ts_to_text_time(p_at, 'c', 8, 36, 'ms') || lpad(p_n::text, 16, '0') end
$$;
-- the three hand-built 2020 partitions of p_parent, on encoded bounds, recorded by adopt_partition
create function t358.hand_cells(p_parent regclass, p_kind text) returns void language plpgsql as $$
declare cfg pgpm.config; v_cell text; v_m int := 0; v_lo timestamptz; v_ids int[];
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  foreach v_cell in array array['a', 'b', 'c'] loop
    v_lo := timestamptz '2020-01-01 00:00:00+00' + make_interval(months => v_m);
    execute format('create table %s_%s (like %s including defaults including constraints)', p_parent, v_cell, p_parent);
    execute format('alter table %s attach partition %s_%s for values from (%L) to (%L)', p_parent, p_parent, v_cell,
                   pgpm._encode(cfg.control_kind, pgpm._ts_text(v_lo), cfg.text_time_prefix, cfg.text_time_width,
                                cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet,
                                cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz),
                   pgpm._encode(cfg.control_kind, pgpm._ts_text(v_lo + interval '1 month'), cfg.text_time_prefix,
                                cfg.text_time_width, cfg.text_time_radix, cfg.text_time_unit, cfg.text_time_alphabet,
                                cfg.text_time_discard_bits, cfg.text_time_epoch, cfg.partition_tz));
    v_ids := case v_cell when 'a' then array[1, 2] when 'b' then array[3] else array[4, 5, 6] end;
    execute format('insert into %s select t358.key(%L, %L::timestamptz + interval ''1 day'' * n, n)::%s, n from unnest(%L::int[]) n',
                   p_parent, p_kind, v_lo, case when p_kind = 'uuidv7' then 'uuid' else 'text' end, v_ids);
    perform pgpm.adopt_partition(p_parent, format('%s_%s', p_parent, v_cell)::regclass);
    v_m := v_m + 1;
  end loop;
end $$;
create table t358.calls (parent regclass, p_child name);
-- archives nothing; detaches the _c partition it is handed, as a concurrent detach beginning under the hold would
create function t358.strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into t358.calls values (p_parent, p_child);
  if p_child like '%\_c' then
    execute format('alter table %s detach partition t358.%I', p_parent, p_child);
  end if;
  v.covered_hi := p_hi;
  return v;
end $$;
-- the remedy's ATTACH statement, as the latest skip_archive row of the range logs it ('select 1' when there is none,
-- so the check after it fails rather than the file)
create function t358.remedy(p_parent regclass, p_lo timestamptz, p_says text) returns text language sql stable as $$
  select coalesce((select substring(l.method from 'ALTER TABLE .* FOR VALUES FROM \(''[^'']*''\) TO \(''[^'']*''\)')
                     from pgpm.log l
                    where l.parent_table = p_parent and l.action = 'skip_archive' and l.lo::timestamptz = p_lo
                      and l.method like p_says
                    order by l.id desc limit 1), 'select 1')
$$;

-- ======== PART U: uuidv7 ========
create table t358.u (id uuid primary key, v int not null);
insert into t358.u values (t358.key('uuidv7', now(), 100)::uuid, 100), (t358.key('uuidv7', now(), 101)::uuid, 101);
call pgpm.transmute('t358.u', 'id', interval '1 month', p_obtain => 1, p_retain => interval '1 year', p_paused => true,
                    p_force_uuidv7 => true);
select t358.hand_cells('t358.u', 'uuidv7');
select pgpm._enforce_write_blocks('t358.u');
select ok((select control_kind = 'uuidv7' from pgpm.config where parent_table = 't358.u'::regclass)
          and pgpm._is_write_blocked('t358.u', 'u_a') and pgpm._is_write_blocked('t358.u', 'u_b')
          and pgpm._is_write_blocked('t358.u', 'u_c'),
  'LIVENESS: U: a uuidv7 grid whose three 2020 partitions are recorded, aged and write-blocked');

-- _a: the row unanchored (an upgrade from before #421), the table detached by hand
update pgpm.part set child_oid = null where parent_table = 't358.u'::regclass and child_name = 'u_a';
alter table t358.u detach partition t358.u_a;
-- _b: pgpm's own retirement, its dispatched detach landed
update pgpm.part set retiring_at = now(), retiring_oid = child_oid, detach_dispatched_oid = child_oid
 where parent_table = 't358.u'::regclass and child_name = 'u_b';
alter table t358.u detach partition t358.u_b;
select pgpm.set_archive_fn('t358.u', 't358.strategy(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 't358.u'::regclass;
select pgpm._archive_step('t358.u');

select ok(exists (select 1 from t358.calls where parent = 't358.u'::regclass and p_child = 'u_c')
          and not exists (select 1 from pg_inherits where inhrelid = 't358.u_c'::regclass),
  'LIVENESS: U: the strategy was handed _c and detached it under the hold');
select is((select array_agg(v order by v) from t358.u where v < 100), null::int[],
  'LIVENESS: U: no id of the three partitions reads through the parent');
select t358.remedy('t358.u', '2020-01-01 00:00:00+00', '%records no oid%') as u_a,
       t358.remedy('t358.u', '2020-02-01 00:00:00+00', '%by a retirement of pgpm''s%') as u_b,
       t358.remedy('t358.u', '2020-03-01 00:00:00+00', '%stopped being an attached partition%') as u_c \gset
select ok(:'u_a' like 'ALTER TABLE %u_a FOR VALUES FROM %', 'LIVENESS: U: _a''s skip_archive row (no oid) carries an ATTACH: ' || :'u_a');
select ok(:'u_b' like 'ALTER TABLE %u_b FOR VALUES FROM %', 'LIVENESS: U: _b''s skip_archive row (pgpm''s retirement) carries an ATTACH: ' || :'u_b');
select ok(:'u_c' like 'ALTER TABLE %u_c FOR VALUES FROM %', 'LIVENESS: U: _c''s skip_archive row (left under the hold) carries an ATTACH: ' || :'u_c');

select lives_ok(:'u_a', 'U: the no-oid remedy''s ATTACH runs as typed');
select is((select array_agg(v order by v) from t358.u where v < 100), array[1, 2],
  'U: and _a is a partition again: ids 1 and 2 read through the parent');
select lives_ok(:'u_b', 'U: the retirement remedy''s ATTACH runs as typed');
select is((select array_agg(v order by v) from t358.u where v < 100), array[1, 2, 3],
  'U: and _b is a partition again: id 3 reads through the parent beside 1 and 2');
select lives_ok(:'u_c', 'U: the left-under-the-hold remedy''s ATTACH runs as typed');
select is((select array_agg(v order by v) from t358.u where v < 100), array[1, 2, 3, 4, 5, 6],
  'U: and _c is a partition again: ids 4, 5 and 6 read through the parent beside 1, 2 and 3');
select is((select array_agg(c.relname::text order by c.relname) from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 't358.u'::regclass and c.relname in ('u_a', 'u_b', 'u_c')),
  array['u_a', 'u_b', 'u_c'], 'U: all three tables are attached to t358.u, each by its own remedy');

update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 't358.u'::regclass;

-- ======== PART T: text_time (cuid v1 shaped) ========
create table t358.t (id text collate "C" primary key, v int not null);
insert into t358.t values (t358.key('text_time', now(), 100), 100), (t358.key('text_time', now(), 101), 101);
call pgpm.transmute('t358.t', 'id', interval '1 month', p_obtain => 1, p_retain => interval '1 year', p_paused => true,
                    p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
select t358.hand_cells('t358.t', 'text_time');
select pgpm._enforce_write_blocks('t358.t');
select ok((select control_kind = 'text_time' from pgpm.config where parent_table = 't358.t'::regclass)
          and pgpm._is_write_blocked('t358.t', 't_a') and pgpm._is_write_blocked('t358.t', 't_b')
          and pgpm._is_write_blocked('t358.t', 't_c'),
  'LIVENESS: T: a text_time grid whose three 2020 partitions are recorded, aged and write-blocked');

update pgpm.part set child_oid = null where parent_table = 't358.t'::regclass and child_name = 't_a';
alter table t358.t detach partition t358.t_a;
update pgpm.part set retiring_at = now(), retiring_oid = child_oid, detach_dispatched_oid = child_oid
 where parent_table = 't358.t'::regclass and child_name = 't_b';
alter table t358.t detach partition t358.t_b;
select pgpm.set_archive_fn('t358.t', 't358.strategy(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 't358.t'::regclass;
select pgpm._archive_step('t358.t');

select ok(exists (select 1 from t358.calls where parent = 't358.t'::regclass and p_child = 't_c')
          and not exists (select 1 from pg_inherits where inhrelid = 't358.t_c'::regclass),
  'LIVENESS: T: the strategy was handed _c and detached it under the hold');
select t358.remedy('t358.t', '2020-01-01 00:00:00+00', '%records no oid%') as t_a,
       t358.remedy('t358.t', '2020-02-01 00:00:00+00', '%by a retirement of pgpm''s%') as t_b,
       t358.remedy('t358.t', '2020-03-01 00:00:00+00', '%stopped being an attached partition%') as t_c \gset
select ok(:'t_a' like 'ALTER TABLE %t_a FOR VALUES FROM %'
          and :'t_b' like 'ALTER TABLE %t_b FOR VALUES FROM %'
          and :'t_c' like 'ALTER TABLE %t_c FOR VALUES FROM %',
  'LIVENESS: T: the three skip_archive rows each carry an ATTACH');

select lives_ok(:'t_a', 'T: the no-oid remedy''s ATTACH runs as typed');
select is((select array_agg(v order by v) from t358.t where v < 100), array[1, 2],
  'T: and _a is a partition again: ids 1 and 2 read through the parent');
select lives_ok(:'t_b', 'T: the retirement remedy''s ATTACH runs as typed');
select is((select array_agg(v order by v) from t358.t where v < 100), array[1, 2, 3],
  'T: and _b is a partition again: id 3 reads through the parent beside 1 and 2');
select lives_ok(:'t_c', 'T: the left-under-the-hold remedy''s ATTACH runs as typed');
select is((select array_agg(v order by v) from t358.t where v < 100), array[1, 2, 3, 4, 5, 6],
  'T: and _c is a partition again: ids 4, 5 and 6 read through the parent beside 1, 2 and 3');
select is((select array_agg(c.relname::text order by c.relname) from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 't358.t'::regclass and c.relname in ('t_a', 't_b', 't_c')),
  array['t_a', 't_b', 't_c'], 'T: all three tables are attached to t358.t, each by its own remedy');
-- each remedy's bounds are the partition's own catalog bounds, the encoded text it was built on
select is((select array_agg(pg_get_expr(c.relpartbound, c.oid) order by c.relname) from pg_class c
            where c.relnamespace = 't358'::regnamespace and c.relname in ('t_a', 't_b', 't_c')),
          (select array_agg(substring(r from 'FOR VALUES FROM .*$') order by r) from unnest(array[:'t_a', :'t_b', :'t_c']) r),
  'T: each remedy spelled its partition''s own bounds');

update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 't358.t'::regclass;

select * from finish();
