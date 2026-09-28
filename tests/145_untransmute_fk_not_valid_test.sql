-- untransmute re-adds a preserved incoming FK NOT VALID and does not VALIDATE it (issue #577).
--
-- untransmute is a function: everything it does shares one transaction, and by the time it re-adds the
-- preserved incoming FKs it has held ACCESS EXCLUSIVE on the parent (and so on the monolith it hands
-- back) since the second gate. It used to re-add each key NOT VALID and then VALIDATE it right there,
-- which scans the whole REFERENCING table while that lock is still held: every reader and writer of the
-- table waited out an O(referencing rows) scan in what docs/reference.md calls a metadata-only reverse.
-- And a key whose referencing table had picked up an orphan while the key was suspended failed that
-- VALIDATE and rolled the whole reverse back.
--
-- Now the key comes back NOT VALID, which enforces every new write at once, and the VALIDATE is the
-- operator's, in a later transaction, where it holds only SHARE UPDATE EXCLUSIVE on the referencing table
-- and ROW SHARE on the restored one. The same recipe restore_incoming_fks follows (#265).
--
-- The contract is checked as LOCKS HELD BY THIS TRANSACTION rather than by timing: VALIDATE CONSTRAINT is
-- the one statement in the reverse that takes SHARE UPDATE EXCLUSIVE on a referencing table, locks are
-- held to transaction end, so after the call inside an explicit transaction that lock is present exactly
-- when the scan ran under the ACCESS EXCLUSIVE the same transaction still holds. Both of those are
-- witnessed alongside the negative (the ACCESS EXCLUSIVE on the restored table, the SHARE ROW EXCLUSIVE the
-- ADD took on each referencing table), and convalidated = false is asserted on each key by name, which
-- catches a validation by any other route (an ADD without NOT VALID scans too).
--
-- Two reverses, kept apart so neither failure can mask the other. (A) is the lock contract on clean
-- data, asymmetric: items' key was restored and validated before the reverse, tags' key was never
-- restored. (B) is the orphan: notes picked one up while its key was suspended, which used to roll the
-- whole reverse back; the operator's VALIDATE afterwards is refused there and succeeds on items, so the
-- two cannot be confused.
create extension if not exists pgtap;
select plan(23);

create schema uv577;

-- ======================================================================================================
-- (A) no VALIDATE under the reverse's ACCESS EXCLUSIVE
-- ======================================================================================================
create table uv577.ev (id bigint primary key, body text);
insert into uv577.ev select g, 'row ' || g from generate_series(1, 5) g;
create table uv577.items (id int primary key, ev_id bigint references uv577.ev (id));
insert into uv577.items values (10, 1), (11, 1), (12, 2);
create table uv577.tags (id int primary key, ev_id bigint references uv577.ev (id));
insert into uv577.tags values (30, 4);

call pgpm.transmute('uv577.ev', 'id', 100::bigint, p_incoming_fks => 'preserve', p_paused => false);

-- items' key back on the parent and validated there; tags' key left suspended.
select is(pgpm.restore_incoming_fks('uv577.ev',
            array(select id from pgpm.dropped_fk where parent_table = 'uv577.ev'::regclass
                     and referencing_table = 'uv577.items'::regclass)),
  1, 'LIVENESS: items'' preserved key was re-added on the parent');
select is(pgpm.validate_incoming_fks('uv577.ev'), 1, 'LIVENESS: and validated there');
select ok((select restored_at is not null and validated_at is not null from pgpm.dropped_fk
            where parent_table = 'uv577.ev'::regclass and constraint_name = 'items_ev_id_fkey'),
  'LIVENESS: items_ev_id_fkey is recorded restored AND validated before the reverse');
select ok((select restored_at is null from pgpm.dropped_fk
            where parent_table = 'uv577.ev'::regclass and constraint_name = 'tags_ev_id_fkey'),
  'LIVENESS: tags_ev_id_fkey is recorded as still suspended before the reverse');
select is((select convalidated from pg_constraint
            where conrelid = 'uv577.items'::regclass and conname = 'items_ev_id_fkey' and contype = 'f'),
  true, 'LIVENESS: items_ev_id_fkey is a VALID constraint before the reverse');

create table uv577.mon as select tableoid::oid as mon from uv577.ev limit 1;

-- The reverse, in an explicit transaction, so the locks it took are still there to read afterwards.
begin;
select lives_ok($$ select pgpm.untransmute('uv577.ev') $$, 'untransmute reverses uv577.ev');
select is('uv577.ev'::regclass::oid, (select mon from uv577.mon),
  'LIVENESS: the restored uv577.ev is the monolith, not a copy');
select ok(exists (select 1 from pg_locks where pid = pg_backend_pid() and locktype = 'relation'
                   and relation = 'uv577.ev'::regclass and mode = 'AccessExclusiveLock' and granted),
  'LIVENESS: this transaction still holds the ACCESS EXCLUSIVE the reverse took on the table');
select ok(exists (select 1 from pg_locks where pid = pg_backend_pid() and locktype = 'relation'
                   and relation = 'uv577.items'::regclass and mode = 'ShareRowExclusiveLock' and granted)
          and exists (select 1 from pg_locks where pid = pg_backend_pid() and locktype = 'relation'
                   and relation = 'uv577.tags'::regclass and mode = 'ShareRowExclusiveLock' and granted),
  'LIVENESS: the key was re-added on items and on tags in this transaction (the ADD''s SHARE ROW EXCLUSIVE)');
select is((select string_agg(relation::regclass::text, ', ' order by relation::regclass::text) from pg_locks
            where pid = pg_backend_pid() and locktype = 'relation' and mode = 'ShareUpdateExclusiveLock'
              and relation in ('uv577.items'::regclass, 'uv577.tags'::regclass)),
  null, 'no referencing table was VALIDATEd under that lock (no SHARE UPDATE EXCLUSIVE on either)');
commit;

select is((select (confrelid::regclass::text, convalidated)::text from pg_constraint
            where conrelid = 'uv577.items'::regclass and conname = 'items_ev_id_fkey' and contype = 'f'),
  '(uv577.ev,f)', 'items_ev_id_fkey is back against the restored uv577.ev, NOT VALID');
select is((select (confrelid::regclass::text, convalidated)::text from pg_constraint
            where conrelid = 'uv577.tags'::regclass and conname = 'tags_ev_id_fkey' and contype = 'f'),
  '(uv577.ev,f)', 'tags_ev_id_fkey is back against the restored uv577.ev, NOT VALID');
select is((select action from pgpm.log where parent_table = 'uv577.ev'::regclass order by id desc limit 1),
  'untransmute', 'LIVENESS: the reverse logged exactly untransmute against the restored table');

-- NOT VALID still enforces every new write.
select throws_ok($$ insert into uv577.items values (13, 998) $$, '23503', null,
  'a new row referencing a missing ev id is refused by the NOT VALID key');
select lives_ok($$ insert into uv577.items values (14, 5) $$,
  'LIVENESS: a new row referencing an existing ev id is accepted');

-- The operator's VALIDATE, in its own transaction, is where the scan happens now.
select lives_ok($$ alter table uv577.items validate constraint items_ev_id_fkey $$,
  'the operator validates items_ev_id_fkey afterwards');
select is((select convalidated from pg_constraint
            where conrelid = 'uv577.items'::regclass and conname = 'items_ev_id_fkey'),
  true, 'and it is VALID then');

-- ======================================================================================================
-- (B) an orphan written while the key was suspended no longer rolls the reverse back
-- ======================================================================================================
create table uv577.ev2 (id bigint primary key);
insert into uv577.ev2 select generate_series(1, 3);
create table uv577.notes (id int primary key, ev_id bigint references uv577.ev2 (id));
insert into uv577.notes values (20, 3);
call pgpm.transmute('uv577.ev2', 'id', 100::bigint, p_incoming_fks => 'preserve', p_paused => false);
insert into uv577.notes values (21, 999);   -- no ev2 row 999: an orphan, possible only while the key is off
select ok((select restored_at is null from pgpm.dropped_fk
            where parent_table = 'uv577.ev2'::regclass and constraint_name = 'notes_ev_id_fkey'),
  'LIVENESS: notes_ev_id_fkey is suspended, which is what let the orphan in');

select lives_ok($$ select pgpm.untransmute('uv577.ev2') $$,
  'untransmute completes, the orphan in notes notwithstanding');
select is((select relkind::text from pg_class where oid = 'uv577.ev2'::regclass), 'r',
  'LIVENESS: uv577.ev2 is an ordinary table again');
select is((select (confrelid::regclass::text, convalidated)::text from pg_constraint
            where conrelid = 'uv577.notes'::regclass and conname = 'notes_ev_id_fkey' and contype = 'f'),
  '(uv577.ev2,f)', 'notes_ev_id_fkey is back against the restored uv577.ev2, NOT VALID');
select is((select array_agg(id order by id) from uv577.notes), array[20, 21],
  'the reverse deleted nothing from notes, orphan included');
select throws_ok($$ alter table uv577.notes validate constraint notes_ev_id_fkey $$, '23503', null,
  'the operator''s VALIDATE of notes_ev_id_fkey is refused on the orphan, which the reverse no longer trips over');

select * from finish();
