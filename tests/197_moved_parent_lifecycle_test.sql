-- Every lifecycle step finds a partition in the partition's OWN schema, not the parent's (issue #727).
--
-- THE BUG. The write block (_install_write_block, _remove_write_block, _is_write_blocked), the archive
-- step (_archive_step, _next_archive_chunk, the built-in _archive_noop) and retire() all resolved a
-- partition as <the parent's CURRENT schema>.<pgpm.part.child_name>. A partition's schema is its own:
-- ALTER TABLE <parent> SET SCHEMA moves the parent and leaves every partition where it was, and pgpm tracks
-- the parent by oid, so the table stays managed. From then on no step found an existing partition again:
-- the write block was skipped as "does not exist" (skip_write_block), the archive step and retire() refused
-- every aged partition as an identity mismatch ("oid nothing now", fail_retain_identity), and retention was
-- wedged for good although every partition was still attached, unchanged, under the oid pgpm recorded.
--
-- THE CONTRACT. After the parent moves, each step reaches the pre-move partitions where they are:
--   PART A  the write block goes on, keeps writes out, comes off when retention stops reaching the child,
--           and retire() drops the aged partitions, one per tick under retain_batch 1.
--   PART B  the archive step sizes and archives each aged partition (the strategy counts its rows by
--           name), and retire() drops it once covered.
--   PART C  an unanchored row (child_oid null, an install older than #421) is reached too.
--   PART D  and the identity anchors still hold in the partition's schema: a relation squatting on a
--           partition's name there is refused (fail_retain_identity, fail_write_block_identity) and left
--           alone, while its sibling in the same tick is retired.
--
-- ASYMMETRIC FIXTURES. Each table's aged monolith [0, 20) holds 3 rows (ids 1, 2, 15) and its aged [20, 30)
-- holds 1 (id 22), with the frontier at 55 so the horizon is 30; PART A adds a live [30, 40) of 2 rows (31,
-- 33). A wrong drop, a missed drop and a wrong count cannot cancel into the asserted id sets.
create extension if not exists pgtap;

select plan(41);

set client_min_messages = warning;

create schema pgpm_t197_old;
create schema pgpm_t197_new;

-- The child's oid that pgpm recorded, and whether a relation with that oid still exists.
create function pgpm_t197_old.oid_of(p_parent regclass, p_lo text) returns oid language sql as $$
  select child_oid from pgpm.part where parent_table = p_parent and lo = p_lo
$$;
create function pgpm_t197_old.alive(p_oid oid) returns boolean language sql as $$
  select exists (select 1 from pg_class where oid = p_oid)
$$;
create function pgpm_t197_old.blocked(p_oid oid) returns boolean language sql as $$
  select exists (select 1 from pg_trigger where tgrelid = p_oid and tgname = 'pgpm_write_block' and tgenabled = 'A')
$$;
-- The lifecycle failures this issue produced, plus the archive ones, as EXACT actions (never a prefix match).
create function pgpm_t197_old.wedges(p_parent regclass) returns int language sql as $$
  select count(*)::int from pgpm.log
   where parent_table = p_parent
     and action in ('fail_retain_identity', 'skip_write_block', 'fail_write_block_identity',
                    'fail_archive_identity', 'skip_archive', 'fail_retain_drop')
$$;

-- ================= PART A: write block on, writes refused, block off, retire per tick =================
create table pgpm_t197_old.ra (id bigint primary key, payload text);
insert into pgpm_t197_old.ra values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('pgpm_t197_old.ra', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('pgpm_t197_old.ra', '60');
insert into pgpm_t197_old.ra values (22, 'aged'), (31, 'live'), (33, 'live'), (55, 'frontier');
update pgpm.config set retain_batch = 1 where parent_table = 'pgpm_t197_old.ra'::regclass;

select pgpm_t197_old.oid_of('pgpm_t197_old.ra', '0') as a_mono_oid \gset
select pgpm_t197_old.oid_of('pgpm_t197_old.ra', '20') as a_20_oid \gset
select child_name as a_20 from pgpm.part where parent_table = 'pgpm_t197_old.ra'::regclass and lo = '20' \gset

alter table pgpm_t197_old.ra set schema pgpm_t197_new;

-- SETUP WITNESSES: the parent moved, its aged partitions did not, and they are still its partitions by oid.
select is((select pgpm._retain_boundary(c) from pgpm.config c where parent_table = 'pgpm_t197_new.ra'::regclass),
  '30', 'LIVENESS: (A) the moved table''s horizon is 30, so [0, 20) and [20, 30) are wholly past it');
select is((select count(*)::int from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'pgpm_t197_new.ra'::regclass
              and i.inhrelid in (:a_mono_oid, :a_20_oid)
              and c.relnamespace = 'pgpm_t197_old'::regnamespace),
  2, 'LIVENESS: (A) both aged partitions are attached to the moved parent, under the recorded oids, in the OLD schema');
select ok(to_regclass(format('pgpm_t197_new.%I', :'a_20')) is null,
  'LIVENESS: (A) no relation of that name exists in the parent''s new schema (the state the bug misread)');

call pgpm.maintain('pgpm_t197_new.ra');

select is((select count(*)::int from pgpm.log where parent_table = 'pgpm_t197_new.ra'::regclass
            and action = 'retain_drop' and lo = '0' and hi = '20'),
  1, 'A tick 1: retire() dropped the aged monolith [0, 20)');
select ok(not pgpm_t197_old.alive(:a_mono_oid), 'A tick 1: the monolith pgpm recorded is gone, by oid');
select is((select array_agg(id order by id) from pgpm_t197_new.ra), array[22, 31, 33, 55]::bigint[],
  'A tick 1: exactly the monolith''s rows went (retain_batch 1 kept [20, 30) for the next tick)');
select ok(pgpm_t197_old.blocked(:a_20_oid), 'A tick 1: the write block is on [20, 30), in force, on the recorded relation');
select ok(pgpm._is_write_blocked('pgpm_t197_new.ra', :'a_20'), 'A tick 1: _is_write_blocked sees it');
select throws_like($$ insert into pgpm_t197_new.ra values (25, 'late') $$,
  '%past its retention boundary%', 'A tick 1: and a write routed into [20, 30) is refused by it');
select is(pgpm_t197_old.wedges('pgpm_t197_new.ra'), 0,
  'A tick 1: no step reported an attached, unchanged partition as missing or substituted');

-- retention stops reaching [20, 30): with no archive coverage on it the next tick lifts its block
select pgpm.set_retain('pgpm_t197_new.ra', '40');
select is((select pgpm._retain_boundary(c) from pgpm.config c where parent_table = 'pgpm_t197_new.ra'::regclass),
  '10', 'LIVENESS: (A) the loosened horizon is 10, so [20, 30) is no longer eligible');
call pgpm.maintain('pgpm_t197_new.ra');
select ok(pgpm_t197_old.alive(:a_20_oid) and not pgpm_t197_old.blocked(:a_20_oid),
  'A tick 2: the block came off [20, 30), which is still there');
select lives_ok($$ insert into pgpm_t197_new.ra values (25, 'late') $$,
  'A tick 2: and [20, 30) takes writes again');
select is((select array_agg(id order by id) from pgpm_t197_old.:"a_20"), array[22, 25]::bigint[],
  'A tick 2: the write landed in the old-schema partition');

-- and back: the next tick blocks it again and retires it, rows and all
update pgpm.config set retain = '20' where parent_table = 'pgpm_t197_new.ra'::regclass;
call pgpm.maintain('pgpm_t197_new.ra');
select is((select count(*)::int from pgpm.log where parent_table = 'pgpm_t197_new.ra'::regclass
            and action = 'retain_drop' and lo = '20' and hi = '30'),
  1, 'A tick 3: retire() dropped [20, 30)');
select ok(not pgpm_t197_old.alive(:a_20_oid), 'A tick 3: the [20, 30) pgpm recorded is gone, by oid');
select is((select array_agg(id order by id) from pgpm_t197_new.ra), array[31, 33, 55]::bigint[],
  'A tick 3: exactly ids 22 and 25 went with it');
select is(pgpm_t197_old.wedges('pgpm_t197_new.ra'), 0,
  'A: three ticks, and still no step reported a partition missing or substituted');

-- ================= PART B: the archive step reads and archives the old-schema partition =================
create table pgpm_t197_old.rb (id bigint primary key, payload text);
insert into pgpm_t197_old.rb values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('pgpm_t197_old.rb', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('pgpm_t197_old.rb', '60');
insert into pgpm_t197_old.rb values (22, 'aged'), (55, 'frontier');
select pgpm.set_archive_fn('pgpm_t197_old.rb', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);

select pgpm_t197_old.oid_of('pgpm_t197_old.rb', '0') as b_mono_oid \gset
select pgpm_t197_old.oid_of('pgpm_t197_old.rb', '20') as b_20_oid \gset
select child_name as b_mono from pgpm.part where parent_table = 'pgpm_t197_old.rb'::regclass and lo = '0' \gset
select child_name as b_20 from pgpm.part where parent_table = 'pgpm_t197_old.rb'::regclass and lo = '20' \gset

alter table pgpm_t197_old.rb set schema pgpm_t197_new;

select is((select archive_batch from pgpm.config where parent_table = 'pgpm_t197_new.rb'::regclass), 1,
  'LIVENESS: (B) archive_batch is 1, so each tick archives one partition, oldest first');
select ok(to_regclass(format('pgpm_t197_new.%I', :'b_mono')) is null
          and to_regclass(format('pgpm_t197_old.%I', :'b_mono'))::oid = :b_mono_oid,
  'LIVENESS: (B) the monolith lives in the old schema only');

call pgpm.maintain('pgpm_t197_new.rb');

select results_eq(
  $$ select lo, hi, rows_archived from pgpm.archive_ledger
      where parent_table = 'pgpm_t197_new.rb'::regclass and child_name = $$ || quote_literal(:'b_mono'),
  $$ values ('0'::text, '20'::text, 3::bigint) $$,
  'B tick 1: the monolith was archived whole, its 3 rows counted where they are');
select is((select count(*)::int from pgpm.log where parent_table = 'pgpm_t197_new.rb'::regclass
            and action = 'retain_drop' and lo = '0' and hi = '20'),
  1, 'B tick 1: and retire() dropped it once covered');
select ok(not pgpm_t197_old.alive(:b_mono_oid), 'B tick 1: the monolith pgpm recorded is gone, by oid');
select ok(pgpm_t197_old.alive(:b_20_oid) and pgpm_t197_old.blocked(:b_20_oid),
  'B tick 1: [20, 30) is write-blocked and waits for its own coverage');

call pgpm.maintain('pgpm_t197_new.rb');

select results_eq(
  $$ select lo, hi, rows_archived from pgpm.archive_ledger
      where parent_table = 'pgpm_t197_new.rb'::regclass and child_name = $$ || quote_literal(:'b_20'),
  $$ values ('20'::text, '30'::text, 1::bigint) $$,
  'B tick 2: [20, 30) was archived, its 1 row counted');
select ok(not pgpm_t197_old.alive(:b_20_oid), 'B tick 2: and dropped, by oid');
select is((select array_agg(id order by id) from pgpm_t197_new.rb), array[55]::bigint[],
  'B tick 2: leaving exactly the frontier row');
select is(pgpm_t197_old.wedges('pgpm_t197_new.rb'), 0,
  'B: no archive or retire step reported a partition missing or substituted');

-- ================= PART C: an unanchored row (child_oid null) is reached through the parent =================
create table pgpm_t197_old.rc (id bigint primary key, payload text);
insert into pgpm_t197_old.rc values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('pgpm_t197_old.rc', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('pgpm_t197_old.rc', '60');
insert into pgpm_t197_old.rc values (22, 'aged'), (55, 'frontier');

select pgpm_t197_old.oid_of('pgpm_t197_old.rc', '0') as c_mono_oid \gset
update pgpm.part set child_oid = null where parent_table = 'pgpm_t197_old.rc'::regclass and lo = '0';

alter table pgpm_t197_old.rc set schema pgpm_t197_new;

select ok((select child_oid is null from pgpm.part where parent_table = 'pgpm_t197_new.rc'::regclass and lo = '0')
          and pgpm_t197_old.alive(:c_mono_oid),
  'LIVENESS: (C) the monolith''s row is unanchored, and the monolith is there');

call pgpm.maintain('pgpm_t197_new.rc');

select is((select array_agg(lo order by lo::numeric) from pgpm.log where parent_table = 'pgpm_t197_new.rc'::regclass
            and action = 'retain_drop'),
  array['0', '20'], 'C: retire() dropped the unanchored monolith and the anchored [20, 30)');
select ok(not pgpm_t197_old.alive(:c_mono_oid), 'C: the unanchored monolith is gone, by oid');
select is((select array_agg(id order by id) from pgpm_t197_new.rc), array[55]::bigint[],
  'C: leaving exactly the frontier row');
select is(pgpm_t197_old.wedges('pgpm_t197_new.rc'), 0, 'C: and nothing was reported missing');

-- ================= PART D: the identity anchors still hold in the partition's own schema =================
create table pgpm_t197_old.rd (id bigint primary key, payload text);
insert into pgpm_t197_old.rd values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('pgpm_t197_old.rd', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('pgpm_t197_old.rd', '60');
insert into pgpm_t197_old.rd values (22, 'aged'), (55, 'frontier');

select pgpm_t197_old.oid_of('pgpm_t197_old.rd', '0') as d_mono_oid \gset
select pgpm_t197_old.oid_of('pgpm_t197_old.rd', '20') as d_20_oid \gset
select child_name as d_mono from pgpm.part where parent_table = 'pgpm_t197_old.rd'::regclass and lo = '0' \gset

alter table pgpm_t197_old.rd set schema pgpm_t197_new;
-- the real monolith is renamed aside, and an unrelated table takes its name in ITS schema
select format('alter table pgpm_t197_old.%I rename to rd_mono_aside', :'d_mono') \gexec
select format('create table pgpm_t197_old.%I (id bigint, payload text)', :'d_mono') \gexec
select format('insert into pgpm_t197_old.%I values (999, %L)', :'d_mono', 'squatter') \gexec
select format('pgpm_t197_old.%I', :'d_mono')::regclass::oid as d_squat_oid \gset

select ok(:d_squat_oid <> :d_mono_oid and pgpm_t197_old.alive(:d_mono_oid),
  'LIVENESS: (D) the name now means a different relation, and the real monolith still exists');

call pgpm.maintain('pgpm_t197_new.rd');

select is((select count(*)::int from pgpm.log where parent_table = 'pgpm_t197_new.rd'::regclass
            and action = 'fail_retain_identity' and lo = '0'
            and method like format('%%is oid %s now%%', :d_squat_oid)),
  1, 'D: retire() refuses the squatted name, naming the squatter''s oid');
select is((select count(*)::int from pgpm.log where parent_table = 'pgpm_t197_new.rd'::regclass
            and action = 'fail_write_block_identity' and lo = '0'),
  1, 'D: and the write block refuses it too');
select ok(pgpm_t197_old.alive(:d_squat_oid) and not pgpm_t197_old.blocked(:d_squat_oid),
  'D: the squatter is still there and carries no write block');
select is((select array_agg(id order by id) from pgpm_t197_old.rd_mono_aside), array[1, 2, 15]::bigint[],
  'D: the real monolith, renamed aside, keeps exactly its 3 rows');
select is((select count(*)::int from pgpm.log where parent_table = 'pgpm_t197_new.rd'::regclass
            and action = 'retain_drop' and lo = '20' and hi = '30'),
  1, 'LIVENESS: (D) the same tick retired the unsubstituted [20, 30), so retire() did reach this table');
select ok(not pgpm_t197_old.alive(:d_20_oid), 'D: [20, 30) is gone, by oid');
select is((select array_agg(id order by id) from pgpm_t197_old.:"d_mono"), array[999]::bigint[],
  'D: the squatter holds exactly its own row');

select * from finish();
