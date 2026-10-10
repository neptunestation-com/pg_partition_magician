-- transmute carries a policy whose expression names the table itself (issue #897).
--
-- pg_get_expr renders a policy's expression against the relation it is on, and qualifies a reference to the
-- outer row with the table's own name: a correlated subquery's `m.tenant = t.org` comes back as written, and
-- one written unqualified (`m.tenant = org`, where only the table has an `org`) comes back as `t.org` too.
-- The cutover replayed that text onto the staging parent `<rel>_pgpm_new`, before the renames, where the
-- name means nothing: CREATE POLICY failed raw ("missing FROM-clause entry for table") in phase 3, after
-- phases 1 and 2 had committed the write-rejecting pgpm_monolith_bound and the claim, and every retry failed
-- the same way. Where the name DID resolve, a subquery over the table itself, it resolved to the original
-- oid, which the rename hands to the monolith, so the parent's copy of the policy read one partition. The
-- replay now runs after both renames, when the name means the new parent.
--
-- Fixtures, asymmetric on purpose:
--   (A) pa250 has a SELECT policy with a qualified correlated subquery and an INSERT policy whose WITH CHECK
--       names the outer column unqualified, both over a membership table that admits the role to ONE of two
--       tenants (8 of 15 rows are 'acme', 7 'other'); the conversion runs through dblink so its phases
--       commit and a cutover failure is observed from here rather than ending the file;
--   (B) pb250 has a policy whose subquery reads pb250 itself, uncorrelated: it converted before the fix
--       too, so what is asserted is WHICH relation the parent's copy depends on.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(16);

set client_min_messages = warning;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'r250_app') then create role r250_app nologin; end if;
end $$;

-- ====================================================================================================
-- (A) policies whose expressions qualify the outer row with the table's own name
-- ====================================================================================================
create table public.m250 (tenant text, member text);
insert into public.m250 values ('acme', 'r250_app'), ('other', 'someone_else');
create table public.pa250 (id bigint primary key, org text not null, body text);
insert into public.pa250 select g, case when g % 2 = 1 then 'acme' else 'other' end, 'r' || g
  from generate_series(1, 15) g;
alter table public.pa250 enable row level security;
create policy pa250_sel on public.pa250 for select
  using (exists (select 1 from public.m250 m where m.tenant = pa250.org and m.member = current_user));
create policy pa250_ins on public.pa250 for insert
  with check (exists (select 1 from public.m250 m where m.tenant = org and m.member = current_user));
grant select, insert on public.pa250 to r250_app;
grant select on public.m250 to r250_app;

select alike(pg_get_expr(polqual, polrelid), '%pa250.org%',
  'LIVENESS: (A) the SELECT policy''s expression qualifies the outer row with the table''s own name')
  from pg_policy where polrelid = 'public.pa250'::regclass and polname = 'pa250_sel';
select alike(pg_get_expr(polwithcheck, polrelid), '%pa250.org%',
  'LIVENESS: (A) the INSERT policy''s unqualified outer column renders qualified by the table''s own name too')
  from pg_policy where polrelid = 'public.pa250'::regclass and polname = 'pa250_ins';
set role r250_app;
select is((select array_agg(id order by id) from public.pa250), array[1, 3, 5, 7, 9, 11, 13, 15]::bigint[],
  'LIVENESS: (A) before the conversion the role reads exactly its tenant''s eight rows');
reset role;

select dblink_connect('c250', 'dbname=' || current_database());
select is(dblink_exec('c250', $c$ call pgpm.transmute('public.pa250', 'id', 10::bigint, p_obtain => 3) $c$, false),
  'CALL', 'A: the conversion of a table whose policies name it completes (no error from the cutover)');
select is(dblink_error_message('c250'), 'OK', 'A: and the cutover raised nothing');
select dblink_disconnect('c250');

select is((select relkind::text from pg_class where oid = 'public.pa250'::regclass), 'p',
  'A: public.pa250 is the partitioned parent');
select ok(not exists (select 1 from pg_constraint c join pg_inherits i on i.inhrelid = c.conrelid
                        where i.inhparent = 'public.pa250'::regclass and c.conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pg_constraint where conrelid = 'public.pa250'::regclass
                            and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.pa250'::regclass),
  'A: no write-rejecting bound and no claim are left behind');
select is((select array_agg(p.polname::text order by p.polname) from pg_policy p join pg_class c on c.oid = p.polrelid
             where p.polrelid = 'public.pa250'::regclass and c.relkind = 'p'),
  array['pa250_ins', 'pa250_sel'],
  'A: the parent carries exactly the table''s two policies');
select alike((select pg_get_expr(p.polqual, p.polrelid) from pg_policy p join pg_class c on c.oid = p.polrelid
               where p.polrelid = 'public.pa250'::regclass and c.relkind = 'p' and p.polname = 'pa250_sel'), '%pa250.org%',
  'A: the parent''s SELECT policy correlates with the parent''s own row');

-- a forward partition's rows as well as the monolith's: one of each tenant past the monolith
insert into public.pa250 values (25, 'acme', 'fwd'), (26, 'other', 'fwd');
select isnt((select tableoid from public.pa250 where id = 25),
            (select monolith_oid from pgpm.config where parent_table = 'public.pa250'::regclass),
  'LIVENESS: (A) id 25 landed in a forward partition, not the monolith');
set role r250_app;
select is((select array_agg(id order by id) from public.pa250), array[1, 3, 5, 7, 9, 11, 13, 15, 25]::bigint[],
  'A: through the parent the role reads its tenant''s rows in the monolith and in the forward partition, and no other');
select lives_ok($$ insert into public.pa250 values (27, 'acme', 'mine') $$,
  'A: the carried WITH CHECK admits an insert into the role''s tenant');
select throws_ok($$ insert into public.pa250 values (28, 'other', 'theirs') $$, '42501', NULL,
  'A: the carried WITH CHECK refuses an insert into another tenant');
reset role;

-- ====================================================================================================
-- (B) a policy whose subquery reads the table itself binds to the parent, not the monolith
-- ====================================================================================================
create table public.pb250 (id bigint primary key, v text);
insert into public.pb250 select g, 'b' || g from generate_series(1, 12) g;
create policy pb250_self on public.pb250 for delete using (exists (select 1 from public.pb250 s where s.id = 1));
select ok(exists (select 1 from pg_depend d join pg_policy p on p.oid = d.objid
                   where d.classid = 'pg_policy'::regclass and p.polname = 'pb250_self'
                     and d.refobjid = 'public.pb250'::regclass and d.deptype = 'n'),
  'LIVENESS: (B) the original policy depends on the table''s own oid through its subquery');
call pgpm.transmute('public.pb250', 'id', 10::bigint, p_obtain => 2);
select isnt((select monolith_oid from pgpm.config where parent_table = 'public.pb250'::regclass),
            'public.pb250'::regclass::oid,
  'LIVENESS: (B) the conversion handed the original oid to the monolith');
select is((select array_agg(distinct d.refobjid::regclass::text order by d.refobjid::regclass::text)
             from pg_depend d join pg_policy p on p.oid = d.objid
            where d.classid = 'pg_policy'::regclass and d.refclassid = 'pg_class'::regclass
              and d.deptype = 'n' and p.polrelid = 'public.pb250'::regclass and p.polname = 'pb250_self'),
  array['pb250'],
  'B: the parent''s copy of the policy depends on the parent alone, not on the monolith');

select * from finish();

drop table public.pa250, public.pb250, public.m250 cascade;
drop owned by r250_app;
drop role r250_app;
