-- transmute must carry the table's owner, grants, RLS, policies, comments and triggers onto the new
-- parent (issue #277).
--
-- CREATE TABLE ... LIKE carries columns, defaults, constraints, storage and generated-ness, and nothing
-- else. Everything here was left on the original, which becomes a child, while the application talks to
-- the parent.
--
-- EVERY ASSERTION BELOW IS BEHAVIOURAL, and that is the whole point. "The policy still exists somewhere"
-- passes against the broken code, because the monolith keeps its copy; what matters is what a role can
-- SEE when it queries the parent. Likewise a trigger is asserted by whether it FIRES for a row routed to
-- a partition minted after the conversion, not by whether pg_trigger has a row.
create extension if not exists pgtap;
select plan(16);

-- Roles are cluster-wide while the test database is per-file, so these are created only if absent and
-- never dropped. DROP ROLE would fail whenever any other database still holds an object they own, which
-- would kill this file before a single assertion ran -- a spurious failure that says nothing about the
-- code under test. Leaving them behind is harmless.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't72_owner')  then create role t72_owner;  end if;
  if not exists (select 1 from pg_roles where rolname = 't72_reader') then create role t72_reader; end if;
  if not exists (select 1 from pg_roles where rolname = 't72_writer') then create role t72_writer; end if;
end $$;

-- Asymmetric on purpose (#1285). Tenant 1, the one the policy below admits, holds every fifth id (400 rows,
-- 5 .. 2000); tenants 2, 3 and 4 hold the ids between, 800, 600 and 200 of them. No other tenant has
-- tenant 1's count, so what a role reads cannot be mistaken for another tenant's rows, and tenant 1's ids
-- are not a range a bound could pick out.
create table public.ev72 (id bigint primary key, tenant int not null, body text);
insert into public.ev72
  select g, case when g % 5 = 0 then 1 when g <= 1000 then 2 when g <= 1750 then 3 else 4 end, 'x'
    from generate_series(1, 2000) g;

comment on table public.ev72 is 'the events table';
comment on column public.ev72.tenant is 'tenant discriminator';

alter table public.ev72 owner to t72_owner;
grant select on public.ev72 to t72_reader;
grant insert, update on public.ev72 to t72_writer;
grant select (id, tenant) on public.ev72 to t72_writer;   -- column-level, which relacl alone does not carry

alter table public.ev72 enable row level security;
alter table public.ev72 force row level security;
create policy tenant_iso on public.ev72 for select to t72_reader using (tenant = 1);

create table public.ev72_fired (id bigint, at text);
create function public.ev72_trg() returns trigger language plpgsql as $$
begin insert into public.ev72_fired values (new.id, 'fired'); return new; end $$;
create trigger ev72_before before insert on public.ev72
  for each row execute function public.ev72_trg();

call pgpm.transmute('public.ev72', 'id', 3000, p_paused => false);

-- ============================ the security assertions ============================
-- The ones that catch the real failure. Under the bug the policy is left on the monolith, the parent has
-- none, and a reader whose grants have been "repaired" sees EVERY row instead of its own tenant's.
--
-- ev72_seen() is what the calling role reads through the parent, BY ID (#1285): a count of 400 is also
-- what 400 rows of other tenants come to. Wrapped so a permission error becomes a FAILED ASSERTION rather
-- than an aborted script. Under the bug the reader has no grant at all, and a bare select would kill the
-- file at this line, leaving every later assertion unreported and the session still SET ROLE. The error
-- reads back as {-1}, never as the empty answer, so "reads no row" below cannot be a role that was
-- refused the table outright.
create function public.ev72_seen() returns bigint[] language plpgsql as $$
begin return coalesce((select array_agg(id order by id) from public.ev72), '{}');
exception when others then return array[-1];
end $$;

-- Asked of BOTH kinds of role (#1285). A policy says who may read as much as what, and asking only the
-- role it names cannot tell `to t72_reader` from `to public`: replayed to every role, the reader still
-- reads tenant 1's rows, and so does everyone else. t72_writer holds SELECT on (id, tenant) and no policy
-- names it, so on the table as it was converted it read no row at all, and it must read none through the
-- parent. The reader's answer just above it is that negative's witness: the same function, the same
-- parent, the rows there to be read and the policy in force.
set role t72_reader;
select is(public.ev72_seen(), array(select g::bigint from generate_series(5, 2000, 5) g),
  'a non-owner sees ONLY the rows its policy allows, queried through the parent');
set role t72_writer;
select is(public.ev72_seen(), '{}'::bigint[],
  'and a role the policy does NOT name still reads no row through the parent');
reset role;

-- ============================ owner, grants, RLS, comments ============================
select is((select pg_get_userbyid(relowner) from pg_class where oid = 'public.ev72'::regclass),
  't72_owner', 'the parent keeps the original owner');

select ok(has_table_privilege('t72_reader', 'public.ev72', 'select'),
  'table grants are replayed onto the parent');

select ok(has_table_privilege('t72_writer', 'public.ev72', 'insert')
      and has_table_privilege('t72_writer', 'public.ev72', 'update'),
  'including grants held by a second role');

select ok(has_column_privilege('t72_writer', 'public.ev72', 'tenant', 'select'),
  'and COLUMN-level grants, which relacl alone does not carry');

select ok((select relrowsecurity from pg_class where oid = 'public.ev72'::regclass),
  'row level security is enabled on the parent');

select ok((select relforcerowsecurity from pg_class where oid = 'public.ev72'::regclass),
  'and FORCE row level security, without which the owner would bypass the policy');

select is((select obj_description('public.ev72'::regclass, 'pg_class')), 'the events table',
  'the table comment survives');

select is((select col_description('public.ev72'::regclass,
             (select attnum from pg_attribute
               where attrelid = 'public.ev72'::regclass and attname = 'tenant'))),
  'tenant discriminator', 'and the column comment');

-- ============================ triggers ============================
-- Routed to the MONOLITH, which had the original trigger. If the recreated parent trigger also clones
-- onto the monolith without its original being dropped first, this row fires twice.
insert into public.ev72 values (2500, 1, 'monolith-bound');
select is((select count(*)::int from public.ev72_fired where id = 2500), 1,
  'a row routed to the monolith fires the trigger exactly ONCE, not twice');

-- Routed to a partition minted AFTER the conversion. This is the assertion that fails under the bug:
-- the trigger lives on the monolith, so anything routed elsewhere fires nothing.
select pgpm.obtain('public.ev72');
insert into public.ev72 values (3500, 1, 'forward-bound');
select is((select count(*)::int from public.ev72_fired where id = 3500), 1,
  'and so does a row routed to a partition minted AFTER the conversion');

-- ============================ minted partitions are owned by the table owner ============================
select is((select count(*)::int from pg_class c
            join pg_inherits i on i.inhrelid = c.oid
           where i.inhparent = 'public.ev72'::regclass
             and pg_get_userbyid(c.relowner) <> 't72_owner'),
  0, 'every partition, including ones minted by obtain, is owned by the table owner');

-- ============================ untransmute round-trips ============================
-- Its own table: untransmute is deliberately a one-way door once the frontier crosses B, and ev72 above
-- has already been obtained and written past it, so it cannot be reversed by design.
--
-- Asserted by whether the trigger FIRES, not by whether pg_trigger has a row. transmute drops the
-- monolith's own trigger in favour of the parent's clone, and DETACH strips clones, so a reversal that
-- forgets this hands back a table that looks intact and silently runs no triggers.
create table public.ev72u (id bigint primary key, body text);
insert into public.ev72u select g, 'x' from generate_series(1, 500) g;
create trigger ev72u_before before insert on public.ev72u
  for each row execute function public.ev72_trg();
call pgpm.transmute('public.ev72u', 'id', 3000, p_paused => false);
select pgpm.untransmute('public.ev72u');

insert into public.ev72u values (9001, 'after the round trip');
select is((select count(*)::int from public.ev72_fired where id = 9001), 1,
  'a trigger still FIRES on the table untransmute hands back, not stripped by the DETACH');

-- ============================ a shape that cannot be carried is REFUSED ============================
-- A partitioned table cannot host a row trigger with a transition table. Converting and dropping it
-- silently would be the same class of defect this issue is about, so it refuses instead.
create table public.ev72t (id bigint primary key, body text);
insert into public.ev72t select g, 'x' from generate_series(1, 100) g;
create function public.ev72t_trg() returns trigger language plpgsql as $$ begin return null; end $$;
create trigger ev72t_after after insert on public.ev72t
  referencing new table as newrows for each row execute function public.ev72t_trg();

-- Pinned to the refusal's own message, down to WHICH trigger it names (#522). throws_like is a
-- function, so a transmute that did NOT refuse would run on to its first COMMIT inside it and die with
-- 2D000 "invalid transaction termination", rolling back into the very unpartitioned state the check
-- below expects. The previous throws_ok(..., NULL, desc) pinned neither SQLSTATE nor message (pgTAP's
-- three-argument overload reads a non-five-octet second argument, NULL included, as the message), so
-- it accepted that too. bench/throws_pinned.sh keeps every assertion of this shape pinned.
select throws_like($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$,
  'pg_partition_magician: cannot transmute % -- the row trigger(s) (ev72t_after) use a transition table%',
  'a row trigger with a transition table is refused rather than silently dropped');

select is((select relkind::text from pg_class where oid = 'public.ev72t'::regclass), 'r',
  'and the refusal mutates nothing: the table is still unpartitioned');

select * from finish();
