-- untransmute hands back the managed table's publication membership at the reverse, not the monolith's
-- from the conversion (#780, the reversal's half of #566).
--
-- After a transmute the parent is the table, so ALTER PUBLICATION ... ADD TABLE / DROP TABLE / SET TABLE
-- naming it lands on the parent (pg_publication_rel records a table by oid). untransmute drops the parent,
-- which takes those rows with it, and it used to keep the monolith's, which date from the conversion: a
-- publication the operator added the table to since stopped publishing it at the reverse (every row
-- written after it silently missing at the subscribers), one they removed it from published it again, and
-- a row filter or column list changed since went back to the old one. The reversal now reads the parent's
-- memberships under its ACCESS EXCLUSIVE, with the grants, RLS and comments (#667, #710), and puts them on
-- the restored table in place of the monolith's, only where the two differ.
--
-- Part A, no window. Five publications, each a different case, so no single wrong behaviour satisfies
-- them all: pub206_kept is unchanged since the conversion (must stay), pub206_old had the table removed
-- (must not come back), pub206_new had it added with a row filter and a column list and also names a
-- second table (the table must come back with exactly that filter and list, and the second table must
-- stay), pub206_reshaped had its column list changed (the restored table must carry the new list, not the
-- conversion-time one), and pub206_other never named it (must gain nothing).
--
-- Part A2: a reverse with nothing changed since the conversion issues no ALTER PUBLICATION ... ADD TABLE
-- (recorded by an event trigger), so it needs no publication's owner and leaves a filter and list alone.
--
-- Part B, the window (#754's placement). A dblink writer holds ROW SHARE on a second table, the reversal
-- queues for ACCESS EXCLUSIVE behind it, and the writer, which already holds a lock on the table and so is
-- granted ahead of the queued request, adds the table to pub206_late and removes it from pub206_gone. The
-- restored table must be in pub206_late and not in pub206_gone; a capture read before the lock sees
-- neither change. pub206_early, added before the reversal started, is the witness that the capture ran.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = error;   -- wal_level is not logical on the test image; the warning is noise

select plan(25);

-- ============================================== Part A: the membership at the reverse
create table public.pb206 (k int8 primary key, v text, w text);
insert into public.pb206 select g, 'v' || g, 'w' || g from generate_series(1, 10) g;
create table public.side206 (id int8 primary key);
create publication pub206_kept for table public.pb206;
create publication pub206_old for table public.pb206;
create publication pub206_reshaped for table public.pb206 with (publish_via_partition_root = true);
create publication pub206_new for table public.side206 with (publish_via_partition_root = true);
create publication pub206_other for table public.side206;
call pgpm.transmute('public.pb206', 'k', 100::bigint, p_obtain => 2);   -- monolith [0, 100)

-- the operator changes the managed table's memberships after the conversion
alter publication pub206_old drop table public.pb206;
alter publication pub206_new add table public.pb206 (k, v) where (k > 3);
-- a DROP and an ADD naming the table touch the parent's row only, so the monolith keeps its full-row one
alter publication pub206_reshaped drop table public.pb206;
alter publication pub206_reshaped add table public.pb206 (k, w);

select is((select relkind::text from pg_class where oid = 'public.pb206'::regclass), 'p',
  'LIVENESS: pb206 was converted');
select is(
  (select array_agg(p.pubname::text order by p.pubname) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid where r.prrelid = 'public.pb206'::regclass),
  array['pub206_kept', 'pub206_new', 'pub206_reshaped'],
  'LIVENESS: before the reverse the managed table is in kept, new and reshaped (the operator''s changes took)');
select is(
  (select array_agg(p.pubname::text order by p.pubname) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid
    where r.prrelid = (select monolith_oid from pgpm.config where parent_table = 'public.pb206'::regclass)),
  array['pub206_kept', 'pub206_old', 'pub206_reshaped'],
  'LIVENESS: and the monolith still carries the conversion-time set (kept, old, reshaped), so there is a difference to hand back');
select is(
  (select r.prattrs is null from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
    where p.pubname = 'pub206_reshaped'
      and r.prrelid = (select monolith_oid from pgpm.config where parent_table = 'public.pb206'::regclass)),
  true, 'LIVENESS: the monolith''s pub206_reshaped membership has no column list (the conversion-time shape)');

-- Every ADD TABLE the reversal issues is recorded (ddl_command_end reports an ADD with the membership it
-- made, and a DROP with none), so which memberships it re-created is asserted by name.
create table public.pubddl206 (seq serial primary key, ident text);
create function public.pubddl206_log() returns event_trigger language plpgsql as $f$
begin
  insert into public.pubddl206 (ident) select object_identity from pg_event_trigger_ddl_commands();
end $f$;
create event trigger pubddl206 on ddl_command_end when tag in ('ALTER PUBLICATION')
  execute function public.pubddl206_log();
create publication pub206_probe;
alter publication pub206_probe add table public.side206;
select is((select array_agg(ident order by seq) from public.pubddl206),
  array['public.side206 in publication pub206_probe'],
  'LIVENESS: the recorder sees an ADD TABLE, by the membership it made');
drop publication pub206_probe;
truncate public.pubddl206;

select is(pgpm.untransmute('public.pb206')::text, 'pb206', 'untransmute returned the restored table');
select is((select relkind::text from pg_class where oid = 'public.pb206'::regclass), 'r',
  'LIVENESS: pb206 is a plain table again');
select is((select count(*)::int from pgpm.config where parent_table::oid = 'public.pb206'::regclass::oid), 0,
  'LIVENESS: and pgpm no longer manages it');

select is(
  (select array_agg(p.pubname::text order by p.pubname) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid where r.prrelid = 'public.pb206'::regclass),
  array['pub206_kept', 'pub206_new', 'pub206_reshaped'],
  'the restored table is in exactly the publications the managed table was in at the reverse');
select is(
  (select pg_get_expr(r.prqual, r.prrelid) from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
    where p.pubname = 'pub206_new' and r.prrelid = 'public.pb206'::regclass),
  '(k > 3)', 'its pub206_new membership carries the row filter the managed table had');
select is(
  (select array_agg(a.attname::text order by a.attnum) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid
     join pg_attribute a on a.attrelid = r.prrelid and a.attnum = any(r.prattrs::int2[])
    where p.pubname = 'pub206_new' and r.prrelid = 'public.pb206'::regclass),
  array['k', 'v'], 'and its column list (w is not published)');
select is(
  (select array_agg(a.attname::text order by a.attnum) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid
     join pg_attribute a on a.attrelid = r.prrelid and a.attnum = any(r.prattrs::int2[])
    where p.pubname = 'pub206_reshaped' and r.prrelid = 'public.pb206'::regclass),
  array['k', 'w'], 'its pub206_reshaped membership carries the column list set since the conversion, not the old full row');
select is(
  (select array_agg(r.prrelid::regclass::text order by r.prrelid::regclass::text) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid where p.pubname in ('pub206_new', 'pub206_other')
    ),
  array['pb206', 'side206', 'side206'],
  'the other table stays in pub206_new and pub206_other, and pub206_other gained nothing');

select is((select array_agg(ident order by ident) from public.pubddl206),
  array['public.pb206 in publication pub206_new', 'public.pb206 in publication pub206_reshaped'],
  'the reversal added the table to pub206_new and pub206_reshaped only; pub206_kept, unchanged, was left alone');

-- Part A2: a reverse with no membership changed since the conversion issues no publication DDL at all, so
-- it needs no publication's owner. The row filter and column list make the comparison non-trivial.
create table public.pu206 (k int8 primary key, v text, w text);
insert into public.pu206 select g, 'v' || g, 'w' || g from generate_series(1, 5) g;
create publication pub206_same for table public.pu206 (k, v) where (k > 1) with (publish_via_partition_root = true);
call pgpm.transmute('public.pu206', 'k', 100::bigint, p_obtain => 2);
truncate public.pubddl206;
select is(pgpm.untransmute('public.pu206')::text, 'pu206', 'LIVENESS: pu206 was reversed');
select is((select count(*)::int from public.pubddl206), 0,
  'a reverse with no membership changed since the conversion issues no ADD TABLE');
select is(
  (select p.pubname::text || ' ' || pg_get_expr(r.prqual, r.prrelid) || ' ' || r.prattrs::text
     from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
    where r.prrelid = 'public.pu206'::regclass),
  'pub206_same (k > 1) 1 2', 'and the restored table keeps its one membership, filter and column list intact');
drop event trigger pubddl206;

-- ============================================== Part B: a change committed while the reversal waits
create table public.pl206 (k int8 primary key, v text);
insert into public.pl206 select g, 'v' || g from generate_series(1, 5) g;
create publication pub206_gone for table public.pl206;
create publication pub206_late;
create publication pub206_early;
call pgpm.transmute('public.pl206', 'k', 100::bigint, p_obtain => 2);
alter publication pub206_early add table public.pl206;

select dblink_connect('w206', 'dbname=' || current_database());
select dblink_exec('w206', $$set application_name = 'pub206_writer'$$);
select dblink_exec('w206', 'begin');
select dblink_exec('w206', 'lock table public.pl206 in row share mode');

select dblink_connect('u206', 'dbname=' || current_database());
select dblink_exec('u206', $$set application_name = 'pub206_untransmute'$$);
select dblink_exec('u206', $$set lock_timeout = '60s'$$);
select dblink_send_query('u206', $$select pgpm.untransmute('public.pl206')::text$$);

-- Poll for the WAIT, bounded at 30 s so a broken fixture fails rather than hangs. pg_stat_activity is read
-- once per transaction and then frozen (a DO block is one transaction), so the loop clears it each turn.
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                       where a.application_name = 'pub206_untransmute' and l.locktype = 'relation'
                         and l.relation = 'public.pl206'::regclass
                         and l.mode = 'AccessExclusiveLock' and not l.granted);
    perform pg_sleep(0.05);
  end loop;
end $$;
select is(
  (select count(*)::int from pg_locks l join pg_stat_activity a on a.pid = l.pid
    where a.application_name = 'pub206_untransmute' and l.locktype = 'relation'
      and l.relation = 'public.pl206'::regclass and l.mode = 'AccessExclusiveLock' and not l.granted),
  1, 'LIVENESS: untransmute passed its first gate and is queued for ACCESS EXCLUSIVE behind the writer');

-- The writer already holds a lock that conflicts with the queued request, so its own SHARE UPDATE EXCLUSIVE
-- is granted ahead of it.
select dblink_exec('w206', 'alter publication pub206_late add table public.pl206');
select dblink_exec('w206', 'alter publication pub206_gone drop table public.pl206');
select is(
  (select count(*)::int from pg_locks l join pg_stat_activity a on a.pid = l.pid
    where a.application_name = 'pub206_untransmute' and l.locktype = 'relation'
      and l.relation = 'public.pl206'::regclass and l.mode = 'AccessExclusiveLock' and not l.granted),
  1, 'LIVENESS: and still queued after the writer''s membership changes, so they came after any pre-lock capture point');
select dblink_exec('w206', 'commit');
select is((select r from dblink_get_result('u206') as t(r text)), 'pl206',
  'untransmute completed once the writer committed');
select dblink_disconnect('u206');
select dblink_disconnect('w206');

select is((select relkind::text from pg_class where oid = 'public.pl206'::regclass), 'r',
  'LIVENESS: pl206 is a plain table again');
select ok(exists (select 1 from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
                   where p.pubname = 'pub206_early' and r.prrelid = 'public.pl206'::regclass),
  'LIVENESS: the restored table is in pub206_early, added before the reversal (the capture ran)');
select ok(exists (select 1 from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
                   where p.pubname = 'pub206_late' and r.prrelid = 'public.pl206'::regclass),
  'the restored table is in pub206_late, which it joined while the reversal was queued for its lock');
select ok(not exists (select 1 from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
                       where p.pubname = 'pub206_gone' and r.prrelid = 'public.pl206'::regclass),
  'and not back in pub206_gone, which it left while the reversal was queued');
select is(
  (select array_agg(p.pubname::text order by p.pubname) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid where r.prrelid = 'public.pl206'::regclass),
  array['pub206_early', 'pub206_late'],
  'exactly those two publications, early and late');

select * from finish();
