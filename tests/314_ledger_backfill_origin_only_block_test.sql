-- The upgrade that adds pgpm.archive_ledger.child_oid attributes a pre-existing chunk to the partition it was read
-- from when that partition carries pgpm's write block in the state pgpm itself left it, origin-only included
-- (issue #1160).
--
-- THE DEFECT. pgpm._backfill_chunk_oids (#1141) runs while install.sql is re-run, and attributed a chunk only when
-- pgpm._is_write_blocked held, which counts a block enabled ALWAYS and nothing else. Every released pgpm (v0.6.0
-- and older) created pgpm_write_block origin-only, and the repair to ALWAYS is made by the first maintain tick
-- AFTER install.sql (_install_write_block's #450 comment), so on the ordinary upgrade every chunk of every live,
-- archived partition was marked retired although its pgpm.part row is anchored to the very relation it was read
-- from. From then on _over_retired_chunks held that partition (skip_archive_retired_range): never archived again,
-- never dropped by retention, with a logged remedy (export and drop by hand) that does not fit.
--
-- THE CONTRACT.
--   * The backfill attributes a chunk (child_oid := the oid pgpm.part records) when the name still resolves to that
--     oid and that relation carries pgpm_write_block enabled ALWAYS or origin-only, the two states pgpm installs.
--   * A block an operator disabled by hand is still no block: its chunk is marked retired, as before.
--   * Coverage attributed under an origin-only block is then judged by the first tick exactly as before #1141:
--     discarded (archive_coverage_reset, the #651 rule: nothing guarded it from a replica-role writer), the block
--     put back ALWAYS, the partition archived again from its lo, and retention drops it once that is complete.
--
-- The upgrade is simulated as tests/309 parts L, N, O and S do: the two columns nulled, the trigger put in the
-- older state, the backfill called. bench/upgrade_* and the issue's reproductions re-run install.sql itself.
--
-- ASYMMETRIC FIXTURES. [0, 100) holds ids 1..90 'old<id>' (origin-only block), [100, 200) ids 101..107 'mid<id>'
-- (ALWAYS block, the control), [200, 300) ids 201..203 'far<id>' (block disabled by hand). Two chunks are
-- attributed and one is retired, and every check names which.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(15);

create schema t314;
-- every call the strategy gets, with the rows it was handed
create table t314.calls (n serial, child name, lo text, hi text, handed text);
-- the object store: one body per key, a PUT replaces it
create table t314.objects (key text primary key, body text);
create function t314.strat(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v_body text; v_n bigint; v_key text := p_parent::text || '/' || p_lo; v_r pgpm.archive_result;
begin
  execute format('select string_agg(id || '':'' || payload, '','' order by id), count(*) from %s where id >= %L and id < %L',
                 p_parent, p_lo, p_hi) into v_body, v_n;
  insert into t314.calls (child, lo, hi, handed) values (p_child, p_lo, p_hi, coalesce(v_body, ''));
  insert into t314.objects values (v_key, coalesce(v_body, ''))
    on conflict (key) do update set body = excluded.body;
  v_r.covered_hi := p_hi; v_r.rows_archived := v_n; v_r.s3_key := v_key;
  return v_r;
end $$;
create function t314.expect(p_tag text, p_from int, p_to int) returns text language sql immutable as $$
  select string_agg(g || ':' || p_tag || g, ',' order by g) from generate_series(p_from, p_to) g $$;

create table t314.u (id bigint primary key, payload text not null);
insert into t314.u select g, 'old' || g from generate_series(1, 90) g;
call pgpm.transmute('t314.u', 'id', 100, p_retain => 100::bigint, p_paused => false);
select pgpm.extend_to('t314.u'::regclass, '500');
insert into t314.u select g, 'mid' || g from generate_series(101, 107) g;
insert into t314.u select g, 'far' || g from generate_series(201, 203) g;
insert into t314.u values (450, 'frontier');
update pgpm.config set retain_batch = 0, archive_batch = null where parent_table = 't314.u'::regclass;
select pgpm.set_archive_fn('t314.u'::regclass, 't314.strat(regclass,name,text,text)'::regprocedure);
select child_name as u0 from pgpm.part where parent_table = 't314.u'::regclass and lo = '0' \gset
select child_name as u1 from pgpm.part where parent_table = 't314.u'::regclass and lo = '100' \gset
select child_name as u2 from pgpm.part where parent_table = 't314.u'::regclass and lo = '200' \gset
call pgpm.maintain('t314.u');
select is((select string_agg(format('%s [%s, %s) %s', child, lo, hi, handed), '; ' order by n) from t314.calls),
  format('%s [0, 100) %s; %s [100, 200) %s; %s [200, 300) %s',
         :'u0', t314.expect('old', 1, 90), :'u1', t314.expect('mid', 101, 107), :'u2', t314.expect('far', 201, 203)),
  'LIVENESS: the tick archived [0, 100), [100, 200) and [200, 300) whole, one chunk each');

-- what an install from before the columns, and before #450, leaves: the block origin-only on [0, 100), ALWAYS on
-- [100, 200) (the control), disabled by hand on [200, 300); no chunk attributed or marked
select format('alter table t314.%I enable trigger pgpm_write_block', :'u0') as origin_only \gset
:origin_only;
select format('alter table t314.%I disable trigger pgpm_write_block', :'u2') as disabled \gset
:disabled;
update pgpm.archive_ledger set child_oid = null, retired_at = null where parent_table = 't314.u'::regclass;
select is((select string_agg(format('%s|%s', p.lo, t.tgenabled), '; ' order by p.lo::numeric)
             from pgpm.part p join pg_trigger t on t.tgrelid = p.child_oid and t.tgname = 'pgpm_write_block'
            where p.parent_table = 't314.u'::regclass and p.lo in ('0', '100', '200')),
  '0|O; 100|A; 200|D',
  'LIVENESS: the blocks are origin-only on [0, 100), ALWAYS on [100, 200), disabled on [200, 300)');
select is((select string_agg(format('%s|%s|%s', lo, child_oid is null, retired_at is null), '; ' order by lo::numeric)
             from pgpm.archive_ledger where parent_table = 't314.u'::regclass),
  '0|t|t; 100|t|t; 200|t|t',
  'LIVENESS: the three chunks are unattributed and unmarked, as the upgrade finds them');

select pgpm._backfill_chunk_oids();
select is((select string_agg(format('%s|%s|%s', l.lo,
                                    case when l.child_oid = p.child_oid then 'own' when l.child_oid is null then 'none' else 'other' end,
                                    case when l.retired_at is null then 'live' else 'retired' end), '; ' order by l.lo::numeric)
             from pgpm.archive_ledger l join pgpm.part p on p.parent_table = l.parent_table and p.child_name = l.child_name
            where l.parent_table = 't314.u'::regclass),
  '0|own|live; 100|own|live; 200|none|retired',
  'the backfill attributes the chunk under the origin-only block and the one under the ALWAYS block to their own '
  'relations, and marks only the one under the disabled block retired');
select is((select string_agg(child_name, ',' order by lo::numeric) from pgpm._over_retired_chunks('t314.u')),
  :'u2', 'after the backfill only the partition under the disabled block is over a retired chunk');

-- the first tick after the upgrade
call pgpm.maintain('t314.u');
select is((select string_agg(format('%s|%s', lo, rows), '; ' order by lo::numeric) from pgpm.log
            where parent_table = 't314.u'::regclass and action = 'archive_coverage_reset'),
  '0|1', 'the first tick discards the coverage recorded under the origin-only block, and only that coverage');
select is((select string_agg(lo, ',' order by lo::numeric) from pgpm.log
            where parent_table = 't314.u'::regclass and action = 'write_block_reenable'),
  '0,200', 'LIVENESS: the first tick put the origin-only and the disabled block back to ALWAYS');
select is((select string_agg(format('%s [%s, %s) %s', child, lo, hi, handed), '; ' order by n) from t314.calls where n > 3),
  format('%s [0, 100) %s', :'u0', t314.expect('old', 1, 90)),
  'the same tick archives [0, 100) again from its lo, all 90 rows, and nothing else');
select is((select string_agg(format('%s|%s|%s|%s', lo, hi, retired_at is null,
                                    child_oid = to_regclass('t314.' || quote_ident(:'u0'))::oid), '; ' order by lo::numeric)
             from pgpm.archive_ledger where parent_table = 't314.u'::regclass and child_name = :'u0'),
  '0|100|t|t', '[0, 100)''s coverage is one live chunk again, read from its own relation');
select is((select string_agg(lo, ',' order by lo::numeric) from pgpm.log
            where parent_table = 't314.u'::regclass and action = 'skip_archive_retired_range'),
  '200', 'the first tick holds only [200, 300) over a retired chunk, not [0, 100)');
select is((select string_agg(format('%s|%s', lo, hi), ',' order by lo::numeric) from pgpm.archive_ledger
            where parent_table = 't314.u'::regclass and child_name = :'u1'),
  '100|200', 'CONTROL: [100, 200)''s chunk under the ALWAYS block is kept, not discarded');

-- retention reaches the partitions
update pgpm.config set retain_batch = null where parent_table = 't314.u'::regclass;
call pgpm.maintain('t314.u');
select is((select string_agg(format('%s|%s', lo, hi), '; ' order by lo::numeric) from pgpm.log
            where parent_table = 't314.u'::regclass and action = 'retain_drop'),
  '0|100; 100|200', 'retention drops [0, 100) and [100, 200), and not the held [200, 300)');
select ok(to_regclass('t314.' || quote_ident(:'u2')) is not null,
  'LIVENESS: the held [200, 300) is still there, so the tick did reach retention over a held partition');
select is((select string_agg(format('%s=%s', key, body), '; ' order by key) from t314.objects),
  format('t314.u/0=%s; t314.u/100=%s; t314.u/200=%s',
         t314.expect('old', 1, 90), t314.expect('mid', 101, 107), t314.expect('far', 201, 203)),
  'every object holds its own partition''s rows');
select is((select string_agg(format('%s|%s', lo, retired_at is not null), '; ' order by lo::numeric) from pgpm.archive_ledger
            where parent_table = 't314.u'::regclass),
  '0|t; 100|t; 200|t', 'the dropped partitions'' chunks are marked retired by retire(), and the held one''s stays marked');

select * from finish();
