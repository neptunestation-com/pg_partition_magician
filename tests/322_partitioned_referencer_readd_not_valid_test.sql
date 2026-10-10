-- Issue #633 (pass 11, F1-01): a preserved incoming key whose referencing table is PARTITIONED -- a
-- self-referential key of the managed table itself, or a key declared on another partitioned table -- was
-- re-added by restore_incoming_fks (maintain's tick, and every regrain swap) and by untransmute in ONE
-- validating step: ADD FOREIGN KEY scanned the whole referencing table while it held SHARE ROW EXCLUSIVE on
-- the managed table (ACCESS EXCLUSIVE in untransmute and in the swap), so every writer waited for an
-- O(rows) scan, against the reference's "re-adds each FK NOT VALID ... the blocking part is instant".
--
-- What PostgreSQL allows decides what pgpm can do, so the contract is per version:
--   * PostgreSQL 18 accepts NOT VALID on a partitioned referencing table. Both sites re-add the key NOT
--     VALID there, exactly as for a plain referencer: it enforces every new write from the re-add on, the
--     rows already there are left for validate_incoming_fks (maintain's later tick, in its own
--     transaction, under locks that block no writes), and an orphan written while the key was suspended
--     no longer keeps the key dropped.
--   * PostgreSQL 15 to 17 refuse it ("cannot add NOT VALID foreign key on partitioned table"), and the only
--     scan-free route there (a NOT VALID key per partition, validated, then adopted by the parent's ADD)
--     costs one pg_constraint row and trigger pair per (referencing partition x referenced partition), so
--     the key is still re-added validated in one step, and the reference says so. This file pins that too,
--     so the documented exception and the behaviour cannot drift apart.
--
-- No row-count assertion here: "nothing was validated in the re-add" is read off the catalog (convalidated
-- false right after the call, which a validating ADD can never leave), and every such negative is paired
-- with a witness that the key is live and enforcing. The fixture is asymmetric: three keys against one
-- managed table (a self-referential one, one on a partitioned referencer that carries an orphan written
-- while it was suspended, one on a plain referencer), so "which keys came back, and which validated" has a
-- different answer for each and cannot be satisfied by counting.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(40);

select current_setting('server_version_num')::int >= 180000 as pg18 \gset

-- ======================================================================================================
-- fixture: t322 references itself, and is referenced by a partitioned table and by a plain one
-- ======================================================================================================
create table public.t322 (id bigint primary key, parent_id bigint constraint t322_parent_fk references public.t322 (id),
                          body text);
insert into public.t322 select g, nullif(g - 1, 0), 'r' || g from generate_series(1, 15) g;
create table public.rp322 (id int, t_id bigint constraint rp322_t_fk references public.t322 (id), k int not null,
                           primary key (id, k)) partition by range (k);
create table public.rp322_a partition of public.rp322 for values from (0) to (10);
create table public.rp322_b partition of public.rp322 for values from (10) to (20);
insert into public.rp322 values (1, 3, 1), (2, 12, 15);
create table public.pl322 (id int primary key, t_id bigint constraint pl322_t_fk references public.t322 (id));
insert into public.pl322 values (1, 7);

call pgpm.transmute('public.t322', 'id', 10::bigint, p_incoming_fks => 'preserve', p_obtain => 2);

select is(
  (select array_agg(referencing_table::text || ':' || constraint_name || ':' || (restored_at is null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322:pl322_t_fk:true', 'rp322:rp322_t_fk:true', 't322:t322_parent_fk:true'],
  'LIVENESS: the conversion dropped and recorded all three keys, the self-referential one against the new parent');
select is((select array_agg(relkind::text order by relname) from pg_class
            where oid in ('public.t322'::regclass, 'public.rp322'::regclass)),
  array['p', 'p'], 'LIVENESS: two of the three referencing tables (t322 itself, rp322) are partitioned');

insert into public.rp322 values (3, 999, 5);   -- an orphan, written into rp322_a while its key is down

-- ======================================================================================================
-- restore_incoming_fks: the maintain path, and regrain's swap
-- ======================================================================================================
\if :pg18
select is(pgpm.restore_incoming_fks('public.t322'), 3,
  'PG 18: restore_incoming_fks re-adds all three keys, the orphaned partitioned referencer''s too');
select is(
  (select array_agg(conrelid::regclass::text || ':' || conname || ':' || convalidated::text order by conname)
     from pg_constraint where contype = 'f' and conparentid = 0 and confrelid = 'public.t322'::regclass),
  array['pl322:pl322_t_fk:false', 'rp322:rp322_t_fk:false', 't322:t322_parent_fk:false'],
  'PG 18: each is back at its table NOT VALID, so the re-add validated nothing: the partitioned two like the plain one');
select is(
  (select array_agg(constraint_name || ':' || (restored_at is not null)::text || ':' || (validated_at is null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322_t_fk:true:true', 'rp322_t_fk:true:true', 't322_parent_fk:true:true'],
  'PG 18: and each is recorded restored and not yet validated');
\else
select is(pgpm.restore_incoming_fks('public.t322'), 2,
  'PG 15-17: restore_incoming_fks re-adds two keys; the orphaned partitioned referencer''s fails its one-step validation');
select is(
  (select array_agg(conrelid::regclass::text || ':' || conname || ':' || convalidated::text order by conname)
     from pg_constraint where contype = 'f' and conparentid = 0 and confrelid = 'public.t322'::regclass),
  array['pl322:pl322_t_fk:false', 't322:t322_parent_fk:true'],
  'PG 15-17: the plain referencer''s is back NOT VALID; the self-referential one validated in one step (PostgreSQL refuses NOT VALID on a partitioned table)');
select is(
  (select array_agg(constraint_name || ':' || (restored_at is not null)::text || ':' || (validated_at is null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322_t_fk:true:true', 'rp322_t_fk:false:true', 't322_parent_fk:true:false'],
  'PG 15-17: and the records say so: rp322_t_fk still suspended, t322_parent_fk already validated');
\endif

-- Live and enforcing, whatever the version: a forward-partition row of t322 whose parent is missing, and a
-- row of rp322_b whose t322 row is missing, are refused; t322's real forward row is accepted. On 15-17 the
-- rp322 key stayed suspended, so the second is the one that differs.
select lives_ok($$ insert into public.t322 values (25, 1, 'forward') $$,
  'LIVENESS: a t322 row routed to a forward partition with a real parent is accepted');
select throws_ok($$ insert into public.t322 values (26, 999, 'orphan') $$, '23503', NULL,
  'the self-referential key enforces new writes on every partition of the managed table');
\if :pg18
select throws_ok($$ insert into public.rp322 values (4, 998, 16) $$, '23503', NULL,
  'PG 18: the partitioned referencer''s key enforces new writes too, the orphan before it notwithstanding');
\else
select lives_ok($$ insert into public.rp322 values (4, 998, 16) $$,
  'PG 15-17: the partitioned referencer''s key is still suspended, so an orphan still goes in');
\endif

-- ======================================================================================================
-- validate_incoming_fks: maintain's later tick, in its own transaction
-- ======================================================================================================
\if :pg18
select is(pgpm.validate_incoming_fks('public.t322'), 2,
  'PG 18: validate_incoming_fks validates the two keys without an orphan');
select is(
  (select array_agg(conrelid::regclass::text || ':' || convalidated::text order by conrelid::regclass::text)
     from pg_constraint where contype = 'f' and conname = 't322_parent_fk'),
  (select array_agg(r || ':true' order by r)
     from (select i.inhrelid::regclass::text from pg_inherits i where i.inhparent = 'public.t322'::regclass
           union all select 't322') as k(r)),
  'PG 18: the self-referential key is validated on t322 and on every one of its partitions');
select is(
  (select array_agg(constraint_name || ':' || (validated_at is not null)::text || ':' || (validate_retry_after is not null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322_t_fk:true:false', 'rp322_t_fk:false:true', 't322_parent_fk:true:false'],
  'PG 18: the orphaned rp322_t_fk stays NOT VALID and backs off, the other two are validated');
\else
select is(pgpm.validate_incoming_fks('public.t322'), 1,
  'PG 15-17: validate_incoming_fks validates the plain referencer''s key, the one left NOT VALID');
select is(
  (select array_agg(conrelid::regclass::text || ':' || convalidated::text order by conrelid::regclass::text)
     from pg_constraint where contype = 'f' and conname = 't322_parent_fk'),
  (select array_agg(r || ':true' order by r)
     from (select i.inhrelid::regclass::text from pg_inherits i where i.inhparent = 'public.t322'::regclass
           union all select 't322') as k(r)),
  'PG 15-17: the self-referential key is validated on t322 and on every one of its partitions');
select is(
  (select array_agg(constraint_name || ':' || (validated_at is not null)::text || ':' || (validate_retry_after is not null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322_t_fk:true:false', 'rp322_t_fk:false:true', 't322_parent_fk:true:false'],
  'PG 15-17: rp322_t_fk was never re-added, and its failed one-step re-add backs off');
\endif

-- ======================================================================================================
-- untransmute: the other site, re-adding a partitioned referencer's key against the restored table
-- ======================================================================================================
create table public.u322 (id bigint primary key, body text);
insert into public.u322 select g, 'u' || g from generate_series(1, 9) g;
create table public.rpu322 (id int, u_id bigint constraint rpu322_u_fk references public.u322 (id), k int not null,
                            primary key (id, k)) partition by range (k);
create table public.rpu322_a partition of public.rpu322 for values from (0) to (10);
create table public.rpu322_b partition of public.rpu322 for values from (10) to (20);
insert into public.rpu322 values (1, 2, 1), (2, 8, 15);
call pgpm.transmute('public.u322', 'id', 10::bigint, p_incoming_fks => 'preserve', p_obtain => 2);
select pgpm.untransmute('public.u322');

select is(
  (select relkind::text || ':' || coalesce((select array_agg(constraint_name)::text from pgpm.dropped_fk
                                             where referencing_table = 'public.rpu322'::regclass), 'none')
     from pg_class where oid = 'public.u322'::regclass),
  'r:none', 'LIVENESS: u322 is a plain table again and pgpm keeps no record of rpu322_u_fk');
\if :pg18
select is(
  (select array_agg(conrelid::regclass::text || ':' || convalidated::text order by conrelid::regclass::text)
     from pg_constraint where contype = 'f' and conname = 'rpu322_u_fk' and confrelid = 'public.u322'::regclass),
  array['rpu322:false', 'rpu322_a:false', 'rpu322_b:false'],
  'PG 18: untransmute re-added the partitioned referencer''s key NOT VALID, on rpu322 and both its partitions');
\else
select is(
  (select array_agg(conrelid::regclass::text || ':' || convalidated::text order by conrelid::regclass::text)
     from pg_constraint where contype = 'f' and conname = 'rpu322_u_fk' and confrelid = 'public.u322'::regclass),
  array['rpu322:true', 'rpu322_a:true', 'rpu322_b:true'],
  'PG 15-17: untransmute re-added the partitioned referencer''s key validated in one step, on rpu322 and both its partitions');
\endif
select throws_ok($$ insert into public.rpu322 values (3, 999, 16) $$, '23503', NULL,
  'and it enforces: an rpu322 row for a missing u322 id is refused');


-- ======================================================================================================
-- E (PR verification P1-01): a pgpm-managed partitioned referencer regrains with the key left NOT VALID
-- ======================================================================================================
-- a322 is referenced by b322, which pgpm converts too; an orphan written into b322 while the key is
-- suspended keeps the key from validating. On 18 restore leaves it NOT VALID on b322, and b322's own regrain
-- must still swap: its copies carry the key NOT VALID, which the swap's ATTACH adopts without validating
-- (a copy without it is validated by the ATTACH, which the orphan fails, on every tick). Before 18 the
-- one-step re-add fails on the orphan and the key stays dropped, so the regrain swaps without it.
create table public.a322 (id bigint primary key, body text);
insert into public.a322 select g, 'a' || g from generate_series(1, 15) g;
create table public.b322 (id bigint primary key, a_id bigint constraint b322_a_fk references public.a322 (id), v text);
insert into public.b322 select g, (g % 15) + 1, 'b' || g from generate_series(1, 45) g;
call pgpm.transmute('public.a322', 'id', 10::bigint, p_incoming_fks => 'preserve', p_obtain => 2);
update public.b322 set a_id = 999 where id = 5;                -- the orphan, written while b322_a_fk is down
call pgpm.transmute('public.b322', 'id', 10::bigint, p_obtain => 2);
insert into public.b322 values (55, 1, 'f'), (65, 2, 'g');     -- frontier past b322's monolith: frozen
select pgpm.restore_incoming_fks('public.a322');
select pgpm.validate_incoming_fks('public.a322');

select is(
  (select referencing_table::text || ':' || (select relkind::text from pg_class where oid = referencing_table)
     from pgpm.dropped_fk where parent_table = 'public.a322'::regclass and constraint_name = 'b322_a_fk'),
  'b322:p', 'LIVENESS (E): a322''s preserved key is recorded against b322, a partitioned pgpm-managed table');
select is(
  (select coalesce(string_agg(conrelid::regclass::text || ':' || convalidated::text, ','), 'none')
     from pg_constraint where contype = 'f' and conparentid = 0 and conname = 'b322_a_fk'),
  case when :'pg18'::boolean then 'b322:false' else 'none' end,
  'LIVENESS (E): the orphan keeps the key NOT VALID on b322 (18) or dropped (15-17) as the regrain starts');
select child_name as mon322 from pgpm.part
 where parent_table = 'public.b322'::regclass
   and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.b322'::regclass) \gset
select lives_ok(format($$ select pgpm.regrain('public.b322', %L, '10') $$, :'mon322'),
  '(E) b322''s regrain swaps its monolith for fine partitions, the orphan and the NOT VALID key notwithstanding');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.b322'::regclass and child_name = :'mon322'),
  '(E) the monolith was replaced by the swap');
select is(
  (select count(*)::int from pg_inherits i where i.inhparent = 'public.b322'::regclass
      and exists (select 1 from pg_constraint k where k.conrelid = i.inhrelid and k.contype = 'f'
                     and k.conname = 'b322_a_fk' and k.conparentid <> 0 and not k.convalidated)),
  case when :'pg18'::boolean then (select count(*)::int from pg_inherits where inhparent = 'public.b322'::regclass) else 0 end,
  '(E) every partition of b322 carries the key as b322 holds it: a NOT VALID clone of b322''s on 18, none before');
select is((select array_agg(id order by id) from public.b322),
  (select array_agg(g::bigint order by g) from generate_series(1, 45) g) || array[55, 65]::bigint[],
  'LIVENESS (E): b322 holds exactly its 47 rows');
update public.b322 set a_id = 1 where id = 5;                  -- the orphan cleared
\if :pg18
select is(pgpm.validate_incoming_fks('public.a322'), 1, '(E) 18: the key validates once the orphan is gone');
\else
select is(pgpm.restore_incoming_fks('public.a322',
            (select array_agg(id) from pgpm.dropped_fk where parent_table = 'public.a322'::regclass)),
  1, '(E) 15-17: the key re-adds once the orphan is gone (named in p_ids, so its back-off does not hold it)');
\endif
select is(
  (select string_agg(distinct convalidated::text, ',') from pg_constraint where contype = 'f' and conname = 'b322_a_fk'),
  'true', '(E) and it is validated on b322 and on every fine partition the swap attached');

-- ======================================================================================================
-- F (PR verification P1-01, mid-run): the key is re-added NOT VALID while the referencer's copies wait
-- ======================================================================================================
-- b2's regrain makes its copies while its key (a2's preserved one) is validated, so each copy carries it
-- validated. a2's own regrain swap then suspends the key and re-adds it, which on 18 is NOT VALID. That is not
-- drift: the next tick goes on with the same copies rather than discarding them, and the swap's ATTACH adopts
-- each copy's validated key under b2's NOT VALID one. Before 18 the re-add is validated, so nothing changes
-- state, and the run swaps the same way.
create table public.a2 (id bigint primary key);
insert into public.a2 select generate_series(1, 15);
create table public.b2 (id bigint primary key, a_id bigint constraint b2_a_fk references public.a2 (id));
insert into public.b2 select g, (g % 15) + 1 from generate_series(1, 45) g;
call pgpm.transmute('public.a2', 'id', 10::bigint, p_incoming_fks => 'preserve', p_obtain => 2);
call pgpm.transmute('public.b2', 'id', 10::bigint, p_obtain => 2);
insert into public.b2 values (55, 1), (65, 2);
select pgpm.restore_incoming_fks('public.a2');
select pgpm.validate_incoming_fks('public.a2');
create function pg_temp.b2_tick() returns text language plpgsql as $f$
declare v name;
begin
  select child_name into v from pgpm.part
   where parent_table = 'public.b2'::regclass
     and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.b2'::regclass);
  if v is null then return 'no monolith'; end if;            -- swapped already
  return pgpm.regrain_step('public.b2', v, '10', 12);
end $f$;
select is(array[pg_temp.b2_tick(), (pg_temp.b2_tick() like 'copied:%')::text], array['prepared', 'true'],
  'LIVENESS (F): b2''s regrain prepared and copied a first batch');
select is(
  (select coalesce(string_agg(distinct k.convalidated::text, ','), 'none')
     from pgpm.part p join pg_constraint k on k.conrelid = p.child_oid and k.contype = 'f' and k.conname = 'b2_a_fk'
    where p.parent_table = 'public.b2'::regclass and not p.attached),
  'true', 'LIVENESS (F): the copies made so far carry b2_a_fk validated, as b2 held it');
select (select array_agg(child_oid order by child_oid) from pgpm.part
         where parent_table = 'public.b2'::regclass and not attached)::text as f_copies \gset
-- what a2's regrain swap does to the keys referencing it, inside its own transaction
select is(array[pgpm.suspend_incoming_fks('public.a2', true),
                pgpm.restore_incoming_fks('public.a2', (select array_agg(id) from pgpm.dropped_fk where parent_table = 'public.a2'::regclass))],
  array[1, 1], 'LIVENESS (F): a2''s swap suspends b2_a_fk and re-adds it');
select is((select convalidated from pg_constraint where conrelid = 'public.b2'::regclass and conname = 'b2_a_fk'),
  not :'pg18'::boolean, 'LIVENESS (F): b2 holds it NOT VALID now on 18, validated before 18');
select unalike(pg_temp.b2_tick(), 'restarted:%', '(F) the next tick goes on with the run rather than restarting it');
select ok((select array_agg(child_oid order by child_oid) from pgpm.part
            where parent_table = 'public.b2'::regclass and not attached and child_oid = any(:'f_copies'::oid[]))::text
          = :'f_copies', '(F) the copies made before the re-add are the ones kept');
select ok((select bool_or(s like 'swapped:%') from (select pg_temp.b2_tick() as s from generate_series(1, 20)) t),
  '(F) and the swap attaches them');
select is(
  (select array_agg(k.convalidated order by k.convalidated)::text from pg_inherits i
     join pg_constraint k on k.conrelid = i.inhrelid and k.contype = 'f' and k.conname = 'b2_a_fk'
    where i.inhparent = 'public.b2'::regclass and i.inhrelid = any(:'f_copies'::oid[])),
  (select array_agg(true)::text from unnest(:'f_copies'::oid[])),
  '(F) each attached copy kept its validated key, adopted under b2''s');
select is(pgpm.validate_incoming_fks('public.a2'), case when :'pg18'::boolean then 1 else 0 end,
  '(F) and b2''s key validates afterwards (on 18; before 18 it never stopped being valid)');
select is((select string_agg(distinct convalidated::text, ',') from pg_constraint where contype = 'f' and conname = 'b2_a_fk'),
  'true', '(F) valid on b2 and every partition');

-- ======================================================================================================
-- G (PR verification P1-02): a failed one-step re-add backs off instead of rescanning every tick
-- ======================================================================================================
-- Before 18 the self-referential key of g322 is re-added validating in one step, and an orphan fails it.
-- That re-add scans all of g322 under SHARE ROW EXCLUSIVE, and maintain calls restore on every tick, so
-- every tick scanned again to fail again. Now the failure parks the key for five minutes, as
-- validate_incoming_fks parks a failing VALIDATE; a call naming the key in p_ids retries it at once. On 18
-- the key comes back NOT VALID and nothing is parked.
create table public.g322 (id bigint primary key, pid bigint constraint g322_parent_fk references public.g322 (id));
insert into public.g322 select g, nullif(g - 1, 0) from generate_series(1, 30) g;
call pgpm.transmute('public.g322', 'id', 100::bigint, p_incoming_fks => 'preserve', p_obtain => 2);
update public.g322 set pid = 999 where id = 10;                -- the orphan
select id as g_fk from pgpm.dropped_fk where parent_table = 'public.g322'::regclass \gset
\if :pg18
select is(pgpm.restore_incoming_fks('public.g322'), 1, 'G 18: the key comes back NOT VALID, the orphan notwithstanding');
select is((select restored_at is not null and validate_retry_after is null from pgpm.dropped_fk where id = :g_fk), true,
  'G 18: restored, and nothing is parked');
select is(pgpm.restore_incoming_fks('public.g322'), 0, 'G 18: a second call has nothing left to re-add');
select is((select count(*)::int from pgpm.log where parent_table = 'public.g322'::regclass and action = 'fail_restore_incoming_fk'),
  0, 'G 18: and no re-add failed');
select is(pgpm.restore_incoming_fks('public.g322', array[:g_fk]::bigint[]), 0, 'G 18: naming it in p_ids finds it restored too');
\else
select is(pgpm.restore_incoming_fks('public.g322'), 0, 'G 15-17: the one-step re-add fails on the orphan');
select ok((select restored_at is null and validate_retry_after > clock_timestamp() + interval '4 minutes'
             from pgpm.dropped_fk where id = :g_fk),
  'G 15-17: the key stays dropped and is parked for five minutes');
select is(pgpm.restore_incoming_fks('public.g322'), 0, 'G 15-17: the next call (the next tick) re-adds nothing');
select is(
  (select array_agg(method like 'g322_parent_fk: retried in 5 minutes (at once if named in p_ids): %violates foreign key constraint%')
     from pgpm.log where parent_table = 'public.g322'::regclass and action = 'fail_restore_incoming_fk'),
  array[true], 'G 15-17: and does not even try: one failure logged, saying when it is retried, not a second');
select is(pgpm.restore_incoming_fks('public.g322', array[:g_fk]::bigint[]), 0,
  'G 15-17: a call naming the key in p_ids retries it at once (and fails again on the orphan)');
\endif
select is((select count(*)::int from pgpm.log where parent_table = 'public.g322'::regclass and action = 'fail_restore_incoming_fk'),
  case when :'pg18'::boolean then 0 else 2 end, '(G) the named retry was a real attempt: a second failure is logged before 18');
update public.g322 set pid = 9 where id = 10;
\if :pg18
select is(pgpm.validate_incoming_fks('public.g322'), 1, 'G 18: with the orphan gone the key validates');
\else
select is(pgpm.restore_incoming_fks('public.g322', array[:g_fk]::bigint[]), 1, 'G 15-17: with the orphan gone, the named retry re-adds it');
\endif
select is((select restored_at is not null and validated_at is not null and validate_retry_after is null
             from pgpm.dropped_fk where id = :g_fk), true,
  '(G) the key ends restored, validated and not parked');

select * from finish();
