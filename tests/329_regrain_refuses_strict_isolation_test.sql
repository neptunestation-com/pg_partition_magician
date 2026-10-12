-- Every regrain driver runs only in a READ COMMITTED transaction (issue #1258).
--
-- THE BUG. transmute, untransmute and from_hypertable refuse a REPEATABLE READ or SERIALIZABLE caller; regrain(),
-- regrain_history() and regrain_step() did not. Under a stricter level every statement of the transaction reads
-- through its first snapshot, so:
--   * regrain() / regrain_history() copied the monolith through the caller's old snapshot. A row another session
--     committed after that snapshot, before the call installed change capture, was in the source and in no fine
--     child, and the swap dropped it with the source (F3-02: {10,20} left of {10,20,500}).
--   * a hand regrain_step at the swap (or a maintain tick under a database default_transaction_isolation that its
--     transactions inherit) read the captured delta through the tick's first snapshot, so a writer's change
--     captured after it was invisible to the residual reconcile and the final count, and the source was dropped
--     with the change unapplied (F3-04: a committed UPDATE reverted).
--
-- THE CONTRACT.
--   PART A  regrain_history() in a REPEATABLE READ transaction, with a row committed by another session after the
--           caller's snapshot: refused up front, in pgpm's words, naming the call; nothing changed (the same source
--           attached by oid, no capture on it, every row in place). The remedy as the message types it (the same
--           call in a READ COMMITTED transaction) regrains, and every row survives with its payload.
--   PART B  regrain() in a SERIALIZABLE transaction: refused the same way, naming regrain; the remedy regrains.
--   PART C  a hand regrain_step at the swap tick in a REPEATABLE READ transaction whose snapshot predates a writer's
--           committed UPDATE of one row and DELETE of another (both captured in the delta): refused, nothing
--           swapped; driven on in READ COMMITTED it applies both and swaps: row 10 updated, row 30 gone, row 20
--           untouched.
--   PART D  maintain from a session whose default_transaction_isolation is REPEATABLE READ, auto-regrain on: the
--           tick's regrain step is refused and logged skip_regrain with the message (the 200 characters the log keeps
--           carry the remedy), nothing is copied; after SET default_transaction_isolation = 'read committed' in that
--           session, as the message says, the ticks regrain the child and every row survives.
--
-- Every negative is paired with its premise: the row or change the stale snapshot misses was committed and is
-- visible to a fresh session, the caller's snapshot does not see it, and the call ran at the isolation level named.
-- regrain(), regrain_history() and regrain_step() are functions, not committing procedures, so their refusals are
-- pinned by message.
--
-- ASYMMETRIC FIXTURES. A holds 10 and 20 and gains 500 after the snapshot; B holds 11, 22, 33; C holds 1..100 and
-- the writer updates 10 and deletes 30 (one in, one out, so a lost update and a resurrected row cannot cancel); D
-- holds the multiples of 7 below 1000. Each has its own frontier row, and every row check names the ids.
--
-- bench/regrain_refuses_strict_isolation.sh runs this file against a mutant, for the discriminate track.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(38);

select dblink_connect('w329', 'dbname=' || current_database() || ' user=postgres');

-- ============================================ PART A ============================================
create table public.t329a (id bigint primary key, payload text);
insert into public.t329a values (10, 'a-10'), (20, 'a-20');
call pgpm.transmute('public.t329a', 'id', 1000);
select pgpm.obtain('public.t329a');
insert into public.t329a values (5000, 'a-frontier');   -- the monolith [0, 1000) is frozen
create temp table t329a_src as
  with p as materialized (select * from pgpm.part where parent_table = 'public.t329a'::regclass)
  select child_name, child_oid from p where attached and lo = '0';
select is((select count(*) from t329a_src), 1::bigint, 'LIVENESS: (A) the monolith [0, 1000) is attached');

begin isolation level repeatable read;
select is((select array_agg(id order by id) from public.t329a), array[10, 20, 5000]::bigint[],
  'LIVENESS: (A) the caller''s snapshot is taken: 10, 20 and the frontier');
select dblink_exec('w329', $$insert into public.t329a values (500, 'a-500-after-snapshot')$$);
select is((select n from dblink('w329', 'select count(*) from public.t329a where id = 500') as t(n bigint)), 1::bigint,
  'LIVENESS: (A) row 500 is committed and visible to a fresh session');
select is((select count(*) from public.t329a where id = 500), 0::bigint,
  'LIVENESS: (A) the caller''s REPEATABLE READ snapshot predates row 500');
select is(current_setting('transaction_isolation'), 'repeatable read', 'LIVENESS: (A) the call runs in REPEATABLE READ');
select throws_like(
  $$ select pgpm.regrain_history('public.t329a', '100') $$,
  'pg_partition_magician: regrain_history must run in a READ COMMITTED transaction (this one is repeatable read): set default_transaction_isolation = ''read committed''%open no REPEATABLE READ or SERIALIZABLE transaction around it, and re-run. It was to regrain t329a:%',
  '(A) regrain_history refuses a REPEATABLE READ caller up front, in pgpm''s words');
commit;

select is((with p as materialized (select * from pgpm.part where parent_table = 'public.t329a'::regclass)
           select p.child_oid from p, t329a_src s where p.attached and p.child_name = s.child_name),
  (select child_oid from t329a_src), '(A) the same source is still attached, by oid');
select ok(not exists (select 1 from pg_trigger where tgrelid = (select child_oid from t329a_src) and not tgisinternal
                         and tgname = 'pgpm_regrain_capture'),
  '(A) no change capture was installed on it');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.t329a'::regclass), null,
  '(A) no regrain run was begun');

-- the remedy, as typed in the message: the same call in a READ COMMITTED transaction
begin isolation level read committed;
select lives_ok($$ select pgpm.regrain_history('public.t329a', '100') $$, '(A) the same call in READ COMMITTED regrains');
commit;
select bag_eq($$ with p as materialized (select lo, hi from pgpm.part where parent_table = 'public.t329a'::regclass and attached)
     select lo::bigint from p where hi::bigint <= 1000 $$,
  $$ select g::bigint from generate_series(0, 900, 100) g $$, '(A) ten fine children of 100 are attached in its place');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.t329a),
  '10=a-10,20=a-20,500=a-500-after-snapshot,5000=a-frontier',
  '(A) every row survives with its payload: 10 and 20 from before, 500 committed after the refused call''s snapshot');
select ok(not exists (select 1 from pg_class c, t329a_src s where c.oid = s.child_oid), '(A) and the source is dropped');

-- ============================================ PART B ============================================
create table public.t329b (id bigint primary key, payload text);
insert into public.t329b values (11, 'b-11'), (22, 'b-22'), (33, 'b-33');
call pgpm.transmute('public.t329b', 'id', 1000);
select pgpm.obtain('public.t329b');
insert into public.t329b values (5000, 'b-frontier');
create temp table t329b_src as
  with p as materialized (select * from pgpm.part where parent_table = 'public.t329b'::regclass)
  select child_name, child_oid from p where attached and lo = '0';

begin isolation level serializable;
select is(current_setting('transaction_isolation'), 'serializable', 'LIVENESS: (B) the call runs in SERIALIZABLE');
select throws_like(
  format('select pgpm.regrain(%L, %L, %L)', 'public.t329b', (select child_name from t329b_src), '250'),
  'pg_partition_magician: regrain must run in a READ COMMITTED transaction (this one is serializable): set default_transaction_isolation = ''read committed''%It was to regrain t329b:%',
  '(B) regrain refuses a SERIALIZABLE caller up front, in pgpm''s words');
commit;
select is((with p as materialized (select * from pgpm.part where parent_table = 'public.t329b'::regclass)
           select p.child_oid from p, t329b_src s where p.attached and p.child_name = s.child_name),
  (select child_oid from t329b_src), '(B) the same source is still attached, by oid');
select lives_ok(format('select pgpm.regrain(%L, %L, %L)', 'public.t329b', (select child_name from t329b_src), '250'),
  '(B) the same call in READ COMMITTED regrains');
select bag_eq($$ with p as materialized (select lo, hi from pgpm.part where parent_table = 'public.t329b'::regclass and attached)
     select lo::bigint from p where hi::bigint <= 1000 $$,
  $$ values (0::bigint), (250), (500), (750) $$, '(B) four fine children of 250 are attached in its place');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.t329b),
  '11=b-11,22=b-22,33=b-33,5000=b-frontier', '(B) every row survives with its payload');

-- ============================================ PART C ============================================
create table public.t329c (id bigint primary key, payload text);
insert into public.t329c select g, 'orig' from generate_series(1, 100) g;
call pgpm.transmute('public.t329c', 'id', 1000);
select pgpm.obtain('public.t329c');
insert into public.t329c values (5000, 'c-frontier');
create temp table t329c_src as
  with p as materialized (select * from pgpm.part where parent_table = 'public.t329c'::regclass)
  select child_name, child_oid from p where attached and lo = '0';

-- the run, by hand, each step its own READ COMMITTED transaction, until the cursor is at hi: the next step swaps
do $$
declare v_child name;
begin
  for i in 1..40 loop
    exit when (select regrain_cursor from pgpm.config where parent_table = 'public.t329c'::regclass) = '1000';
    with p as materialized (select * from pgpm.part where parent_table = 'public.t329c'::regclass)
    select child_name into v_child from p where attached and child_oid = (select child_oid from t329c_src);
    perform pgpm.regrain_step('public.t329c', v_child, '100');
    commit;
  end loop;
end $$;
select is((select regrain_cursor from pgpm.config where parent_table = 'public.t329c'::regclass), '1000',
  'LIVENESS: (C) the run is copied and its cursor is at hi: the next step is the swap');

begin isolation level repeatable read;
select is((select string_agg(id || '=' || payload, ',' order by id) from public.t329c where id in (10, 20, 30)),
  '10=orig,20=orig,30=orig', 'LIVENESS: (C) the caller''s snapshot is taken: 10, 20 and 30 as they were');
-- the writer: an UPDATE of 10 and a DELETE of 30, committed after that snapshot, captured into the run's delta
select dblink_exec('w329', $$update public.t329c set payload = 'updated' where id = 10$$);
select dblink_exec('w329', $$delete from public.t329c where id = 30$$);
select is((select s from dblink('w329', $q$select string_agg(id || '=' || payload, ',' order by id) from public.t329c
                                            where id in (10, 20, 30)$q$) as t(s text)),
  '10=updated,20=orig', 'LIVENESS: (C) the writer''s UPDATE and DELETE are committed and visible to a fresh session');
select ok((select n from dblink('w329', 'select pgpm._regrain_delta_count(''public.t329c''::regclass)') as t(n bigint)) > 0,
  'LIVENESS: (C) the writer''s changes are captured in the run''s delta, as a fresh snapshot sees it');
select is((select pgpm._regrain_delta_count('public.t329c'::regclass)), 0::bigint,
  'LIVENESS: (C) the caller''s REPEATABLE READ snapshot sees none of them');
select throws_like(
  format('select pgpm.regrain_step(%L, %L, %L)', 'public.t329c',
         (select p.child_name from pgpm.part p, t329c_src s where p.parent_table = 'public.t329c'::regclass
             and p.child_oid = s.child_oid), '100'),
  'pg_partition_magician: regrain_step must run in a READ COMMITTED transaction (this one is repeatable read): set default_transaction_isolation = ''read committed''%It was to regrain t329c:%',
  '(C) the hand swap step refuses a REPEATABLE READ caller up front, in pgpm''s words');
commit;
select is((select count(*) from pgpm.log where parent_table = 'public.t329c'::regclass and action = 'regrain'), 0::bigint,
  '(C) nothing was swapped');
select is((with p as materialized (select * from pgpm.part where parent_table = 'public.t329c'::regclass)
           select p.child_oid from p, t329c_src s where p.attached and p.child_oid = s.child_oid),
  (select child_oid from t329c_src), '(C) the same source is still attached, by oid');

-- the remedy: the step driven on in READ COMMITTED applies the captured changes and swaps
do $$
declare v_child name;
begin
  for i in 1..10 loop
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t329c'::regclass and action = 'regrain');
    with p as materialized (select * from pgpm.part where parent_table = 'public.t329c'::regclass)
    select child_name into v_child from p where attached and child_oid = (select child_oid from t329c_src);
    perform pgpm.regrain_step('public.t329c', v_child, '100');
    commit;
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t329c'::regclass and action = 'regrain'), 1::bigint,
  '(C) driven on in READ COMMITTED, the run swapped');
select is((select string_agg(id || '=' || payload, ',' order by id) from public.t329c where id in (10, 20, 30)),
  '10=updated,20=orig', '(C) the writer''s committed UPDATE of 10 and DELETE of 30 both stand; 20 is untouched');
select is((select count(*) from public.t329c where id < 1000), 99::bigint, '(C) and the other 97 rows of the range are all there');

-- ============================================ PART D ============================================
create table public.t329d (id bigint primary key, payload text);
insert into public.t329d select g, 'd-' || g from generate_series(7, 994, 7) g;
call pgpm.transmute('public.t329d', 'id', 100, p_paused => false);   -- monolith [0, 1000), ten steps wide
select pgpm.obtain('public.t329d');
insert into public.t329d values (2500, 'd-frontier');
select pgpm.set_regrain('public.t329d', '100');
create temp table t329d_src as
  with p as materialized (select * from pgpm.part where parent_table = 'public.t329d'::regclass)
  select child_name, child_oid from p where attached and lo = '0';

select dblink_connect('m329', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('m329', 'set default_transaction_isolation = ''repeatable read''');
select is((select s from dblink('m329', 'select current_setting(''transaction_isolation'')') as t(s text)),
  'repeatable read', 'LIVENESS: (D) the maintain session''s transactions are REPEATABLE READ');
select matches((select s from dblink('m329', 'call pgpm.maintain(''public.t329d'')') as t(s text)),
  ' regrain=deferred regrain_deferred', '(D) the tick defers its regrain step');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.t329d'::regclass and action = 'skip_regrain'
                   and method like 'pg_partition_magician: regrain_step must run in a READ COMMITTED transaction (this one is repeatable read): set default_transaction_isolation = ''read committed''%'),
  '(D) logged skip_regrain with the refusal, its remedy inside the 200 characters the log keeps');
select is((select count(*) from pgpm.log where parent_table = 'public.t329d'::regclass
            and action in ('regrain_copy', 'regrain_prepare', 'regrain')), 0::bigint,
  '(D) nothing was copied');
select ok(not exists (select 1 from pg_trigger where tgrelid = (select child_oid from t329d_src) and not tgisinternal
                         and tgname = 'pgpm_regrain_capture'),
  '(D) no change capture was installed on the source');

-- the remedy, as typed in the message
select dblink_exec('m329', 'set default_transaction_isolation = ''read committed''');
select is((select s from dblink('m329', 'select current_setting(''transaction_isolation'')') as t(s text)),
  'read committed', 'LIVENESS: (D) the maintain session''s transactions are READ COMMITTED now');
do $$
begin
  for i in 1..40 loop
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t329d'::regclass and action = 'regrain');
    perform * from dblink('m329', 'call pgpm.maintain(''public.t329d'')') as t(s text);
    commit;   -- no snapshot of this session is held across the next tick's swap
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t329d'::regclass and action = 'regrain'), 1::bigint,
  '(D) after SET default_transaction_isolation = ''read committed'', the ticks regrain the child');
select bag_eq($$ select id from public.t329d $$,
  $$ select g::bigint from generate_series(7, 994, 7) g union all select 2500 $$,
  '(D) every row survives: the multiples of 7 below 1000, and the frontier');

select dblink_disconnect('m329');
select dblink_disconnect('w329');
select * from finish();
