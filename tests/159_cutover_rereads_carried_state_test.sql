-- Issue #630: the transmute cutover carries what the table has when the cutover holds the lock that
-- protects it, not what an earlier read saw.
--
-- The secondary indexes (9b) and the outgoing foreign keys (7a) were listed in the preflight, before
-- phase 1, and only that list was carried onto the new parent. CREATE INDEX needs SHARE and ADD FOREIGN KEY
-- SHARE ROW EXCLUSIVE, and nothing on the table excludes either until the cutover's ACCESS EXCLUSIVE, so
-- one committed in between followed the rename onto the monolith alone: uniqueness, or the key, held for
-- the rows routed there and for none routed to a forward partition. Step 0b read the owner and the RLS
-- flags before the staging CREATE TABLE ... LIKE, whose ACCESS SHARE is what excludes ALTER OWNER and
-- ENABLE ROW LEVEL SECURITY, and the comments before anything excluded COMMENT ON (SHARE UPDATE EXCLUSIVE).
-- Each is now read under the lock that protects it: the owner and RLS after the LIKE, the policies there
-- too (as they already were), and the comments, indexes and outgoing keys under the ACCESS EXCLUSIVE the
-- cutover takes before the renames (#593's lock). The two up-front refusals that guard what 9b and 7a can
-- carry are asked again there, so a key or index that cannot be carried is refused, not left behind.
--
-- One session, deterministic, as tests/144 made #593's window: an event trigger fires on the cutover's own
-- CREATE TABLE of the staging parent, which runs after the preflight, after the old 0b read, while the
-- LIKE's ACCESS SHARE is held and before the ACCESS EXCLUSIVE, and changes the live table there. A second
-- session's change in that window is the same change: the event trigger stands in for it at the latest
-- point it could commit. bench/cutover_reread_window.sh drives the concurrent version.
--
-- Asymmetric: the table has one carried index and one outgoing key before the conversion, and the window
-- adds one of each, so what the parent ends up with says which list was carried. The behavioural checks
-- write into a FORWARD partition, where only a parent-level index or key applies.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(20);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't159_owner') then create role t159_owner; end if;
end $$;

create table public.region159 (id int primary key);
insert into public.region159 values (1), (2);
create table public.cust159 (id bigint primary key);
insert into public.cust159 values (1), (2);
create table public.ix159 (
  id     bigint not null,
  region int    not null references public.region159 (id),
  cust   bigint not null,
  email  text   not null,
  body   text,
  primary key (id, region)   -- so a duplicate (email, id) can differ in region and pass the key
);
create index ix159_body_idx on public.ix159 (body);
insert into public.ix159 select g, 1, 1, 'e' || g, 'b' || g from generate_series(1, 5) g;

-- The window. Every change is to the LIVE table, made while the cutover runs; relkind is recorded so the
-- witness can say the table was still the plain one when they went on.
create table public.ix159_window (staging text, live_relkind text);
create sequence public.ix159b_window_seq;
create function public.ix159_inject() returns event_trigger language plpgsql as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() where command_tag = 'CREATE TABLE' loop
    if r.object_identity = 'public.ix159_pgpm_new' and not exists (select 1 from public.ix159_window) then
      create unique index ix159_email_id_uq on public.ix159 (email, id);
      alter table public.ix159 add constraint ix159_cust_fk foreign key (cust) references public.cust159 (id);
      alter table public.ix159 owner to t159_owner;
      alter table public.ix159 enable row level security;
      create policy ix159_p on public.ix159 using (region = 1);
      comment on table public.ix159 is 'window table comment';
      comment on column public.ix159.email is 'window column comment';
      insert into public.ix159_window
        values (r.object_identity, (select relkind::text from pg_class where oid = 'public.ix159'::regclass));
    elsif r.object_identity = 'public.ix159b_pgpm_new' then
      -- a rollback undoes an insert but not a nextval, so the witness for (B) is a sequence
      create unique index ix159b_email_uq on public.ix159b (email);
      perform nextval('public.ix159b_window_seq');
    end if;
  end loop;
end $$;
create event trigger ix159_inject on ddl_command_end when tag in ('CREATE TABLE')
  execute function public.ix159_inject();

-- ============================ (A) what the window added is carried ============================
call pgpm.transmute('public.ix159', 'id', 100::bigint, p_obtain => 2);   -- monolith [0, 100)

select is((select array_agg(staging || ':' || live_relkind) from public.ix159_window),
  array['public.ix159_pgpm_new:r'],
  'LIVENESS: the window''s changes were made once, on the cutover''s staging CREATE TABLE, to the plain table');
select is((select relkind::text from pg_class where oid = 'public.ix159'::regclass), 'p',
  'LIVENESS: the table really was converted');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.ix159'::regclass and lo::bigint = 100),
  'LIVENESS: with a forward partition from 100');

select is(
  (select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public.ix159'::regclass and not i.indisprimary),
  array['ix159_body_idx_pgpm', 'ix159_email_id_uq_pgpm'],
  'the parent carries the index it had before AND the unique index created in the window');
select is(
  (select array_agg(conname::text order by conname) from pg_constraint
    where conrelid = 'public.ix159'::regclass and contype = 'f'),
  array['ix159_cust_fk', 'ix159_region_fkey'],
  'the parent carries the outgoing key it had before AND the one added in the window');
select is((select pg_get_userbyid(relowner)::text from pg_class where oid = 'public.ix159'::regclass),
  't159_owner', 'the parent is owned by the owner the table had at the LIKE');
select is((select relrowsecurity from pg_class where oid = 'public.ix159'::regclass), true,
  'the parent has row level security, enabled in the window');
select is((select array_agg(polname::text) from pg_policy where polrelid = 'public.ix159'::regclass),
  array['ix159_p'], 'the parent carries the policy created in the window');
select is(obj_description('public.ix159'::regclass, 'pg_class'), 'window table comment',
  'the parent carries the table comment set in the window');
select is(col_description('public.ix159'::regclass,
    (select attnum from pg_attribute where attrelid = 'public.ix159'::regclass and attname = 'email')),
  'window column comment', 'and the column comment');

-- Behaviour, in a forward partition, where only a parent-level index or key applies.
select lives_ok($$ insert into public.ix159 values (150, 1, 2, 'dup', 'fwd') $$,
  'LIVENESS: a valid row goes into the forward partition');
select is((select relname::text from pg_class where oid = (select tableoid from public.ix159 where id = 150)),
  'ix159_p0000000000000000100', 'LIVENESS: which is where it landed');
-- (150, 2) is a new primary key (id, region), so a 23505 here can only be the (email, id) index's.
select throws_ok($$ insert into public.ix159 values (150, 2, 1, 'dup', 'fwd again') $$, '23505', NULL,
  'a duplicate (email, id) routed to the forward partition is refused by the window''s unique index');
select throws_ok($$ insert into public.ix159 values (151, 1, 999, 'orphan', 'fwd') $$, '23503', NULL,
  'an orphan customer routed to the forward partition is refused by the window''s key');
select throws_ok($$ insert into public.ix159 values (152, 9, 1, 'e152', 'fwd') $$, '23503', NULL,
  'and an orphan region by the key the table had before');

-- ============================ (B) what the window added that cannot be carried is refused ============================
-- A unique index whose key omits the partition key cannot become a partitioned unique index, which the
-- preflight refuses. One created in the window is refused by the cutover, which rolls back to the
-- resumable phase-2 state instead of leaving the index to enforce uniqueness inside the monolith only.
-- Through dblink, so the conversion runs as a top-level CALL whose phases can commit.
create table public.ix159b (id bigint primary key, email text not null);
insert into public.ix159b select g, 'e' || g from generate_series(1, 5) g;
select dblink_connect('t159', 'dbname=' || current_database());
select throws_like(
  $$ select dblink_exec('t159', 'call pgpm.transmute(''public.ix159b'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '%UNIQUE secondary index(es) (ix159b_email_uq) do not include the partition key%',
  'the cutover refuses the unique index created in the window that it cannot carry');
select dblink_disconnect('t159');
select is((select last_value::int || ':' || is_called::text from public.ix159b_window_seq), '1:true',
  'LIVENESS: the window''s index went on once, inside the cutover');
select is((select count(*)::int from pg_class where relname = 'ix159b_email_uq'), 0,
  'and did not survive it: the refusal rolled the cutover back');
select is((select relkind::text from pg_class where oid = 'public.ix159b'::regclass), 'r',
  'ix159b is still the plain table');
select is(
  (select convalidated from pg_constraint where conrelid = 'public.ix159b'::regclass and conname = 'pgpm_monolith_bound'),
  true, 'phases 1 and 2 committed and stand: the refusal came from the cutover, leaving the resumable state');

drop event trigger ix159_inject;

select * from finish();
