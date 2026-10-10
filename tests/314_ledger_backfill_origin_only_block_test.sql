-- The upgrade that adds pgpm.archive_ledger.child_oid attributes a pre-existing chunk on IDENTITY: the oid pgpm
-- recorded when it created the partition, still held by the name. Not on the write block's state, and never on an
-- anchor the same upgrade adopted from whatever held the name (issue #1160).
--
-- THE DEFECT. pgpm._backfill_chunk_oids (#1141) attributed a chunk only when pgpm._is_write_blocked held, which
-- counts a block enabled ALWAYS and nothing else. Every release through v0.6.0 created pgpm_write_block origin-only,
-- and the repair to ALWAYS is made by the first maintain tick AFTER install.sql, so the ordinary upgrade marked every
-- live archived partition's chunks retired; _over_retired_chunks then held it for good (skip_archive_retired_range,
-- never archived or dropped). v0.6.0's own tick also REMOVES the block from a partly archived partition that a
-- set_retain loosening took out of retention's reach and keeps its chunk, and that partition was held the same way.
-- Counting the origin-only block as identity instead (the first fix) was wrong the other way: a pgpm before #429
-- blocked a partition re-created by hand under a dropped one's name exactly as it blocked the original, and the
-- #421 backfill adopts that successor's oid, so its predecessor's chunk was attributed to it, the first tick
-- discarded the chunk's row and archived the successor from lo to the same object key, over the only copy.
--
-- THE CONTRACT. The backfill attributes a chunk (child_oid := the oid pgpm.part records) when that oid was NOT
-- adopted by this upgrade (pgpm.upgrade_adopted_anchor, recorded before the #421 backfill) and the name resolves to
-- it, and that relation's pgpm_write_block is ALWAYS, origin-only or absent (states pgpm leaves). It marks retired
-- a chunk under a block disabled or set replica-only (states only an operator leaves), and every chunk under an
-- adopted anchor whatever its block. Attributed coverage under a block that is not ALWAYS is then discarded by the
-- first tick (archive_coverage_reset, the #452/#651 rule), the partition archived again from its lo under a block,
-- and dropped by retention; a held partition's object is never written.
--
-- The upgrade is simulated as tests/309 parts L, N, O and S do: the two columns nulled, the trigger put in the older
-- state, the backfill called. The issue's reproductions and the verifiers' re-run install.sql itself.
--
-- ASYMMETRIC FIXTURES. Parent u: [0, 100) ids 1..90 'old<id>' origin-only; [100, 200) ids 101..107 'mid<id>' ALWAYS
-- (the control); [200, 300) ids 201..203 'far<id>' disabled by hand; [300, 400) ids 301..304 'rep<id>' replica-only;
-- [400, 500) ids 401..405 'lift<id>' with its block removed by pgpm's own lift. Three attributed, two retired.
-- Parent s: [0, 100) ids 1..3 'old<id>' archived, dropped by hand, re-created with ids 5..6 'new<id>' and blocked
-- origin-only, its anchor adopted. Every check names which chunk or rows.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(23);

create schema t314;
-- every call the strategy gets, with the rows it was handed
create table t314.calls (n serial, parent regclass, child name, lo text, hi text, handed text);
-- the object store: one body per key, a PUT replaces it (pgpm_archive's transports key a chunk by parent and lo)
create table t314.objects (key text primary key, body text);
create function t314.strat(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v_body text; v_n bigint; v_key text := p_parent::text || '/' || p_lo; v_r pgpm.archive_result;
begin
  execute format('select string_agg(id || '':'' || payload, '','' order by id), count(*) from %s where id >= %L and id < %L',
                 p_parent, p_lo, p_hi) into v_body, v_n;
  insert into t314.calls (parent, child, lo, hi, handed) values (p_parent, p_child, p_lo, p_hi, coalesce(v_body, ''));
  insert into t314.objects values (v_key, coalesce(v_body, ''))
    on conflict (key) do update set body = excluded.body;
  v_r.covered_hi := p_hi; v_r.rows_archived := v_n; v_r.s3_key := v_key;
  return v_r;
end $$;
create function t314.expect(p_tag text, p_from int, p_to int) returns text language sql immutable as $$
  select string_agg(g || ':' || p_tag || g, ',' order by g) from generate_series(p_from, p_to) g $$;
-- the backfill's verdict per chunk of a parent below p_below: lo|own (attributed to the relation pgpm.part
-- records)/none|live/retired
create function t314.verdict(p_parent regclass, p_below int) returns text language sql as $$
  select string_agg(format('%s|%s|%s', l.lo,
                           case when l.child_oid = p.child_oid then 'own' when l.child_oid is null then 'none' else 'other' end,
                           case when l.retired_at is null then 'live' else 'retired' end), '; ' order by l.lo::numeric)
    from pgpm.archive_ledger l join pgpm.part p on p.parent_table = l.parent_table and p.child_name = l.child_name
   where l.parent_table = p_parent and l.lo::int < p_below $$;
create procedure t314.mk(p_rel text, p_frontier bigint) language plpgsql as $$
begin
  execute format('create table t314.%I (id bigint primary key, payload text not null)', p_rel);
  call pgpm.transmute('t314.' || p_rel, 'id', 100, p_retain => 100::bigint, p_paused => false);
  perform pgpm.extend_to(('t314.' || p_rel)::regclass, (p_frontier + 50)::text);
  execute format('insert into t314.%I values (%s, ''frontier'')', p_rel, p_frontier);
  update pgpm.config set retain_batch = 0, archive_batch = null where parent_table = ('t314.' || p_rel)::regclass;
  perform pgpm.set_archive_fn(('t314.' || p_rel)::regclass, 't314.strat(regclass,name,text,text)'::regprocedure);
end $$;

-- ============================ parent u: five partitions, one per block state ============================
call t314.mk('u', 950);
insert into t314.u select g, 'old' || g from generate_series(1, 90) g;
insert into t314.u select g, 'mid' || g from generate_series(101, 107) g;
insert into t314.u select g, 'far' || g from generate_series(201, 203) g;
insert into t314.u select g, 'rep' || g from generate_series(301, 304) g;
insert into t314.u select g, 'lift' || g from generate_series(401, 405) g;
select child_name as u0 from pgpm.part where parent_table = 't314.u'::regclass and lo = '0' \gset
select child_name as u1 from pgpm.part where parent_table = 't314.u'::regclass and lo = '100' \gset
select child_name as u2 from pgpm.part where parent_table = 't314.u'::regclass and lo = '200' \gset
select child_name as u3 from pgpm.part where parent_table = 't314.u'::regclass and lo = '300' \gset
select child_name as u4 from pgpm.part where parent_table = 't314.u'::regclass and lo = '400' \gset
call pgpm.maintain('t314.u');
select is((select string_agg(format('%s [%s, %s) %s', child, lo, hi, handed), '; ' order by n) from t314.calls
            where parent = 't314.u'::regclass and lo::int < 500),
  format('%s [0, 100) %s; %s [100, 200) %s; %s [200, 300) %s; %s [300, 400) %s; %s [400, 500) %s',
         :'u0', t314.expect('old', 1, 90), :'u1', t314.expect('mid', 101, 107), :'u2', t314.expect('far', 201, 203),
         :'u3', t314.expect('rep', 301, 304), :'u4', t314.expect('lift', 401, 405)),
  'LIVENESS: u: the tick archived [0, 100) to [400, 500) whole, one chunk each');

-- what an install from before the columns leaves: the block origin-only on [0, 100) (every release through v0.6.0),
-- ALWAYS on [100, 200), disabled on [200, 300) and replica-only on [300, 400) by hand, and removed from [400, 500)
-- by pgpm's own lift (what v0.6.0's tick does once retention stops reaching a partition); no chunk attributed
select format('alter table t314.%I enable trigger pgpm_write_block', :'u0') as st0 \gset
:st0;
select format('alter table t314.%I disable trigger pgpm_write_block', :'u2') as st2 \gset
:st2;
select format('alter table t314.%I enable replica trigger pgpm_write_block', :'u3') as st3 \gset
:st3;
select pgpm._remove_write_block('t314.u', :'u4');
update pgpm.archive_ledger set child_oid = null, retired_at = null where parent_table = 't314.u'::regclass;
select is((select string_agg(format('%s|%s', p.lo, coalesce(t.tgenabled::text, 'none')), '; ' order by p.lo::numeric)
             from pgpm.part p left join pg_trigger t on t.tgrelid = p.child_oid and t.tgname = 'pgpm_write_block'
            where p.parent_table = 't314.u'::regclass and p.lo::int < 500),
  '0|O; 100|A; 200|D; 300|R; 400|none',
  'LIVENESS: u: the blocks are origin-only, ALWAYS, disabled, replica-only and absent, in that order');

-- ============================ parent s: a successor the upgrade's #421 backfill adopts ============================
call t314.mk('s', 450);
insert into t314.s select g, 'old' || g from generate_series(1, 3) g;
select child_name as s0 from pgpm.part where parent_table = 't314.s'::regclass and lo = '0' \gset
select to_regclass('t314.' || quote_ident(:'s0'))::oid as s0_old \gset
call pgpm.maintain('t314.s');
select is((select body from t314.objects where key = 't314.s/0'), t314.expect('old', 1, 3),
  'LIVENESS: s: the tick archived [0, 100), and its object holds ids 1..3 old<id>');
-- dropped by hand and re-created under its own name with other rows; an older pgpm (no anchor, no #429 refusal)
-- write-blocks it origin-only; the upgrade records the row as unanchored and its #421 backfill adopts the successor
-- (the anchor is set first here only so that today's _install_write_block, which checks it, lays the block)
select format('drop table t314.%I', :'s0') as drop_s \gset
:drop_s;
select format('create table t314.%I partition of t314.s for values from (0) to (100)', :'s0') as mk_s \gset
:mk_s;
insert into t314.s values (5, 'new5'), (6, 'new6');
update pgpm.part set child_oid = to_regclass('t314.' || quote_ident(:'s0'))::oid
 where parent_table = 't314.s'::regclass and child_name = :'s0';
select pgpm._install_write_block('t314.s', :'s0');
select format('alter table t314.%I enable trigger pgpm_write_block', :'s0') as st_s \gset
:st_s;
update pgpm.archive_ledger set child_oid = null, retired_at = null where parent_table = 't314.s'::regclass and lo = '0';
create table pgpm.upgrade_adopted_anchor (parent_table regclass not null, child_name name not null,
                                          primary key (parent_table, child_name));
insert into pgpm.upgrade_adopted_anchor values ('t314.s', :'s0');
select ok((select child_oid from pgpm.part where parent_table = 't314.s'::regclass and child_name = :'s0') <> :'s0_old'::oid
          and (select tgenabled from pg_trigger where tgrelid = to_regclass('t314.' || quote_ident(:'s0'))
                                                   and tgname = 'pgpm_write_block') = 'O',
  'LIVENESS: s: the name holds a relation other than the one archived, anchored to it and blocked origin-only');

-- ============================ the upgrade's backfill ============================
select is((select count(*)::int from pgpm.archive_ledger where child_oid is null and retired_at is null
            and ((parent_table = 't314.u'::regclass and lo::int < 500) or (parent_table = 't314.s'::regclass and lo = '0'))), 6,
  'LIVENESS: the six chunks are unattributed and unmarked, as the upgrade finds them');
select pgpm._backfill_chunk_oids();
drop table pgpm.upgrade_adopted_anchor;
select is(t314.verdict('t314.u', 500),
  '0|own|live; 100|own|live; 200|none|retired; 300|none|retired; 400|own|live',
  'u: the backfill attributes the chunks under the origin-only, ALWAYS and lifted blocks to their own relations, '
  'and marks the ones under the disabled and replica-only blocks retired');
select is(t314.verdict('t314.s', 100), '0|none|retired',
  's: the backfill does not attribute the predecessor''s chunk to the adopted successor, origin-only block or not');
select is((select string_agg(child_name, ',' order by lo::numeric) from pgpm._over_retired_chunks('t314.u')),
  format('%s,%s', :'u2', :'u3'), 'u: after the backfill only [200, 300) and [300, 400) are over a retired chunk');

-- ============================ the first tick after the upgrade ============================
call pgpm.maintain('t314.u');
call pgpm.maintain('t314.s');
select is((select string_agg(format('%s|%s', lo, rows), '; ' order by lo::numeric) from pgpm.log
            where parent_table = 't314.u'::regclass and action = 'archive_coverage_reset'),
  '0|1; 400|1', 'u: the first tick discards the coverage under the origin-only and the lifted block, and only those');
select is((select string_agg(lo, ',' order by lo::numeric) from pgpm.log
            where parent_table = 't314.u'::regclass and action = 'write_block_reenable'),
  '0,200,300', 'LIVENESS: u: the first tick put the origin-only, disabled and replica-only blocks back to ALWAYS');
select ok(pgpm._is_write_blocked('t314.u', :'u4'),
  'LIVENESS: u: the first tick put a block back on the lifted [400, 500)');
select is((select string_agg(format('%s [%s, %s) %s', child, lo, hi, handed), '; ' order by n) from t314.calls
            where parent = 't314.u'::regclass and n > (select min(n) from t314.calls where parent = 't314.s'::regclass)),
  format('%s [0, 100) %s; %s [400, 500) %s', :'u0', t314.expect('old', 1, 90), :'u4', t314.expect('lift', 401, 405)),
  'u: the same tick archives [0, 100) and [400, 500) again from their lo, every row, and nothing else');
select is((select string_agg(format('%s|%s|%s', lo, retired_at is null,
                                    child_oid = to_regclass('t314.' || quote_ident(child_name))::oid), '; ' order by lo::numeric)
             from pgpm.archive_ledger where parent_table = 't314.u'::regclass and lo in ('0', '400')),
  '0|t|t; 400|t|t', 'u: [0, 100) and [400, 500) are each one live chunk again, read from their own relation');
select is((select string_agg(lo, ',' order by lo::numeric) from pgpm.log
            where parent_table = 't314.u'::regclass and action = 'skip_archive_retired_range'),
  '200,300', 'u: the first tick holds only [200, 300) and [300, 400) over a retired chunk');
select is((select string_agg(format('%s|%s', lo, hi), ',' order by lo::numeric) from pgpm.archive_ledger
            where parent_table = 't314.u'::regclass and child_name = :'u1'),
  '100|200', 'CONTROL: u: [100, 200)''s chunk under the ALWAYS block is kept, not discarded');
select ok(exists (select 1 from pgpm.log where parent_table = 't314.s'::regclass and action = 'skip_archive_retired_range' and lo = '0')
          and pgpm._is_write_blocked('t314.s', :'s0'),
  'LIVENESS: s: the first tick reached the successor (blocked ALWAYS) and held it over the retired chunk');
select is((select count(*)::int from t314.calls where parent = 't314.s'::regclass and handed like '%new%'), 0,
  's: the strategy was never handed the successor''s rows');
select is((select body from t314.objects where key = 't314.s/0'), t314.expect('old', 1, 3),
  's: the object still holds ids 1..3 old<id>, the only copy of the dropped rows');
select is((select format('%s|%s|%s', lo, hi, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't314.s'::regclass and lo = '0'),
  '0|100|t', 's: the predecessor''s chunk is still recorded, marked retired');

-- ============================ retention ============================
update pgpm.config set retain_batch = null where parent_table = 't314.u'::regclass;
call pgpm.maintain('t314.u');
select is((select string_agg(format('%s|%s', lo, hi), '; ' order by lo::numeric) from pgpm.log
            where parent_table = 't314.u'::regclass and action = 'retain_drop' and lo::int < 500),
  '0|100; 100|200; 400|500', 'u: retention drops [0, 100), [100, 200) and [400, 500), and not the held two');
select ok(to_regclass('t314.' || quote_ident(:'u2')) is not null and to_regclass('t314.' || quote_ident(:'u3')) is not null,
  'LIVENESS: u: the held [200, 300) and [300, 400) are still there, so the tick reached retention past them');
select is((select string_agg(format('%s=%s', key, body), '; ' order by key) from t314.objects
            where key like 't314.u/%' and split_part(key, '/', 2)::int < 500),
  format('t314.u/0=%s; t314.u/100=%s; t314.u/200=%s; t314.u/300=%s; t314.u/400=%s',
         t314.expect('old', 1, 90), t314.expect('mid', 101, 107), t314.expect('far', 201, 203),
         t314.expect('rep', 301, 304), t314.expect('lift', 401, 405)),
  'u: every object holds its own partition''s rows');
select is((select string_agg(format('%s|%s', lo, retired_at is not null), '; ' order by lo::numeric) from pgpm.archive_ledger
            where parent_table = 't314.u'::regclass and lo::int < 500),
  '0|t; 100|t; 200|t; 300|t; 400|t', 'u: the dropped partitions'' chunks are marked by retire(), the held ones'' stay marked');

select * from finish();
