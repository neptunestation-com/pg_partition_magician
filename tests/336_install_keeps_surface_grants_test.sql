-- Re-running install.sql keeps an operator's grants on a pgpm function it has to reshape (issue #1267).
--
-- THE DEFECT. pgpm._surface_prepare(), the first thing install.sql runs, drops each function pgpm._surface_shapes()
-- declares whose installed shape CREATE OR REPLACE cannot replace (a pre-#343 status() without regrain_to, say),
-- and the file creates it afresh further down. _surface_unreplaceable() weighed only what DEPENDS on such a
-- function, never its grants, so the recreated one had its creator's default privileges: an operator's REVOKE
-- EXECUTE ... FROM PUBLIC and GRANT EXECUTE ... TO a monitoring role were gone after the upgrade, and PUBLIC could
-- run status() again, where the section header (#983) promises the upgrade keeps the function's grants.
--
-- THE CONTRACT. A reshaped function that carries grants of its own (a non-default ACL) is not dropped up front but
-- kept aside, renamed pgpm._surface_kept_<name>, and once the file has created the new shape its ACL is made
-- exactly the kept one's (each grant under its own grantor, the owner's under the owner) and the kept function is
-- dropped. One at the default ACL is dropped as before. A run that stops after the prepare keeps the old function,
-- and its grants, until a later run carries them. A grant made through a grant option that this session could not
-- replay as its grantor refuses the run before anything is taken.
--
-- Fixtures, asymmetric: all five declared functions get an older shape, each with a different ACL (PUBLIC
-- revoked plus a monitoring grant; a grant option and a grant made through it; PUBLIC revoked alone; a plain
-- extra grant; the default), so a carry that crossed two functions' ACLs or replayed one as another's would not
-- match. Each ACL is pinned by value before and after.
--
-- bench/install_keeps_surface_grants.sh runs this file against the mutants that drop a granted function again
-- (surface_prepare_drops_granted), that replay every kept grant as the owner (surface_carry_grants_as_owner) and
-- that take a function aside without asking whether its grants can be carried (surface_prepare_grantor_unchecked),
-- so it is also required to FAIL there. install.sql is read with \ir, relative to this file; the psql variable
-- `install` overrides the path, which is how the guard points it at a mutant.
\if :{?install}
\else
\set install ../pgpm_core/install.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(28);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't336_mon') then create role t336_mon; end if;
  if not exists (select 1 from pg_roles where rolname = 't336_ops') then create role t336_ops; end if;
  if not exists (select 1 from pg_roles where rolname = 't336_inst') then create role t336_inst; end if;
end $$;
grant usage on schema pgpm to t336_ops, t336_inst;

-- a function's effective ACL as one line, roles by name, the owner as `owner`, a grant option as `*`
create function pg_temp.t336_acl(p_sig text) returns text language sql as $$
  select coalesce(string_agg(e, ' ' order by e), 'no function')
    from (select format('%s>%s:%s%s',
                        case when a.grantor = p.proowner then 'owner' else pg_get_userbyid(a.grantor)::text end,
                        case when a.grantee = 0 then 'PUBLIC' when a.grantee = p.proowner then 'owner'
                             else pg_get_userbyid(a.grantee)::text end,
                        a.privilege_type, case when a.is_grantable then '*' else '' end) as e
            from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
           where p.oid = to_regprocedure(p_sig)) x
$$;
-- the five declared functions' oids, as one line
create function pg_temp.t336_oids() returns text language sql as $$
  select string_agg(coalesce(to_regprocedure(s.sig)::oid::text, 'none'), ',' order by s.sig)
    from pgpm._surface_shapes() s
$$;
-- the functions pgpm keeps aside for their grants
create function pg_temp.t336_kept() returns text language sql as $$
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text), 'none')
    from pg_proc p where p.pronamespace = 'pgpm'::regnamespace and p.proname like '\_surface\_kept\_%'
$$;

-- ============================== (A) the upgrade: five older shapes, five different ACLs ==============================
drop function pgpm.status();
create function pgpm.status() returns table (parent regclass, paused boolean)
  language sql stable as $$ select null::regclass, null::boolean where false $$;
revoke execute on function pgpm.status() from public;
grant execute on function pgpm.status() to t336_mon;

drop function pgpm.progress(regclass);
create function pgpm.progress(p_parent regclass default null) returns table (parent regclass, frontier text)
  language sql stable as $$ select p_parent, null::text where false $$;
grant execute on function pgpm.progress(regclass) to t336_ops with grant option;
set role t336_ops;
grant execute on function pgpm.progress(regclass) to t336_mon;
reset role;

drop function pgpm.check_uuidv7(regclass, name, integer);
create function pgpm.check_uuidv7(p_table regclass, p_control name, p_sample int default 1000)
  returns table (sampled bigint) language sql stable as $$ select 0::bigint where false $$;
revoke execute on function pgpm.check_uuidv7(regclass, name, integer) from public;

drop function pgpm.check_text_time(regclass, name, text, integer, integer, text, integer, text, integer, timestamptz);
create function pgpm.check_text_time(p_table regclass, p_control name, p_prefix text, p_width int, p_radix int,
    p_unit text, p_sample int default 1000, p_alphabet text default null, p_discard_bits int default 0,
    p_epoch timestamptz default '1970-01-01 00:00:00+00')
  returns table (sampled bigint) language sql stable as $$ select 0::bigint where false $$;
grant execute on function pgpm.check_text_time(regclass, name, text, integer, integer, text, integer, text, integer,
  timestamptz) to t336_mon;

drop function pgpm.observe_window(regclass, interval);
create function pgpm.observe_window(p_parent regclass, p_since interval default '7 days')
  returns table (parent_table regclass, drains bigint) language sql stable as $$ select p_parent, 0::bigint $$;

select is((select string_agg(fn::text || ' <- ' || coalesce(dependants, 'nothing'), '; ' order by fn::text)
             from pgpm._surface_unreplaceable()),
  'pgpm.check_text_time(regclass,name,text,integer,integer,text,integer,text,integer,timestamp with time zone) '
    || '<- nothing; pgpm.check_uuidv7(regclass,name,integer) <- nothing; '
    || 'pgpm.observe_window(regclass,interval) <- nothing; pgpm.progress(regclass) <- nothing; '
    || 'pgpm.status() <- nothing',
  'LIVENESS: all five functions are installed in an older shape CREATE OR REPLACE cannot replace, nothing depending on them');
select is(concat_ws(' | ', pg_temp.t336_acl('pgpm.status()'), pg_temp.t336_acl('pgpm.progress(regclass)'),
                    pg_temp.t336_acl('pgpm.check_uuidv7(regclass,name,integer)'),
                    pg_temp.t336_acl('pgpm.check_text_time(regclass,name,text,integer,integer,text,integer,text,integer,timestamptz)'),
                    pg_temp.t336_acl('pgpm.observe_window(regclass,interval)')),
  'owner>owner:EXECUTE owner>t336_mon:EXECUTE'
    || ' | owner>PUBLIC:EXECUTE owner>owner:EXECUTE owner>t336_ops:EXECUTE* t336_ops>t336_mon:EXECUTE'
    || ' | owner>owner:EXECUTE'
    || ' | owner>PUBLIC:EXECUTE owner>owner:EXECUTE owner>t336_mon:EXECUTE'
    || ' | owner>PUBLIC:EXECUTE owner>owner:EXECUTE',
  'LIVENESS: and each holds the ACL its fixture gave it');
select ok(not has_function_privilege('public', 'pgpm.status()', 'execute')
          and has_function_privilege('t336_mon', 'pgpm.status()', 'execute'),
  'LIVENESS: PUBLIC cannot run the older status() and t336_mon can');

create temp table t336_before as
  select pg_temp.t336_oids() as oids, (select max(id) from pgpm.installed) as installed_max;

\ir :install
set client_min_messages = warning;

select is((select count(*)::int from pgpm.installed where id > (select installed_max from t336_before)), 1,
  'LIVENESS: the re-run of install.sql reached the end of the file');
select is((select count(*)::int from pgpm._surface_unreplaceable()), 0,
  'LIVENESS: every declared function is now in its declared shape');
select ok((select bool_and(o.new <> o.old)
             from unnest(string_to_array((select oids from t336_before), ','),
                         string_to_array(pg_temp.t336_oids(), ',')) as o(old, new)),
  'LIVENESS: each of the five is a new function, the older one gone (none was replaced in place)');

select is(pg_temp.t336_acl('pgpm.status()'), 'owner>owner:EXECUTE owner>t336_mon:EXECUTE',
  'status(): the operator''s REVOKE FROM PUBLIC and GRANT to t336_mon survive the upgrade');
select ok(not has_function_privilege('public', 'pgpm.status()', 'execute')
          and has_function_privilege('t336_mon', 'pgpm.status()', 'execute'),
  'status(): so PUBLIC still cannot run it and t336_mon still can');
select is(pg_temp.t336_acl('pgpm.progress(regclass)'),
  'owner>PUBLIC:EXECUTE owner>owner:EXECUTE owner>t336_ops:EXECUTE* t336_ops>t336_mon:EXECUTE',
  'progress(): the grant option survives, and the grant made through it keeps its grantor');
select is(pg_temp.t336_acl('pgpm.check_uuidv7(regclass,name,integer)'), 'owner>owner:EXECUTE',
  'check_uuidv7(): PUBLIC stays revoked');
select is(pg_temp.t336_acl('pgpm.check_text_time(regclass,name,text,integer,integer,text,integer,text,integer,timestamptz)'),
  'owner>PUBLIC:EXECUTE owner>owner:EXECUTE owner>t336_mon:EXECUTE',
  'check_text_time(): the grant to t336_mon survives');
select is((select p.proacl from pg_proc p where p.oid = 'pgpm.observe_window(regclass,interval)'::regprocedure), null,
  'observe_window(), whose ACL was the default: the new one is at the default too');
select is(pg_temp.t336_kept(), 'none', 'and nothing is left kept aside');

-- the carried grant is the grantor's own: t336_ops can take it back, which a grant recorded under the owner would not allow
set role t336_ops;
revoke execute on function pgpm.progress(regclass) from t336_mon;
reset role;
select is(pg_temp.t336_acl('pgpm.progress(regclass)'),
  'owner>PUBLIC:EXECUTE owner>owner:EXECUTE owner>t336_ops:EXECUTE*',
  'progress(): t336_ops revokes the grant it made, and it is gone');

-- ============================== (B) a run that stopped after the prepare ==============================
-- status() in an older shape again, with other grants, and only the prepare runs (a session that died after it)
drop function pgpm.status();
create function pgpm.status() returns table (parent regclass, paused boolean)
  language sql stable as $$ select null::regclass, null::boolean where false $$;
revoke execute on function pgpm.status() from public;
grant execute on function pgpm.status() to t336_ops;
select is(pg_temp.t336_acl('pgpm.status()'), 'owner>owner:EXECUTE owner>t336_ops:EXECUTE',
  'LIVENESS: status() is in an older shape again, granted to t336_ops and not to PUBLIC');
select pgpm._surface_prepare();
select is(to_regprocedure('pgpm.status()'), null, 'LIVENESS: the prepare took status() away');
select is(pg_temp.t336_kept(), 'pgpm._surface_kept_status()',
  'and kept it aside under another name, nothing else');
select is(pg_temp.t336_acl('pgpm._surface_kept_status()'), 'owner>owner:EXECUTE owner>t336_ops:EXECUTE',
  'with its grants');

\ir :install
set client_min_messages = warning;

select is(pg_get_function_result('pgpm.status()'::regprocedure),
  (select s.result from pgpm._surface_shapes() s where s.sig = 'pgpm.status()'),
  'LIVENESS: the next run created status() in its declared shape');
select is(pg_temp.t336_acl('pgpm.status()'), 'owner>owner:EXECUTE owner>t336_ops:EXECUTE',
  'and gave it the grants the stopped run kept aside');
select is(pg_temp.t336_kept(), 'none', 'and dropped the kept function');
select is(concat_ws(' | ', pg_temp.t336_acl('pgpm.progress(regclass)'),
                    pg_temp.t336_acl('pgpm.check_uuidv7(regclass,name,integer)')),
  'owner>PUBLIC:EXECUTE owner>owner:EXECUTE owner>t336_ops:EXECUTE* | owner>owner:EXECUTE',
  'while the functions already in their declared shape kept their grants, replaced in place');

-- ============================== (C) a function left kept aside fails the install at its end ==============================
-- what a declared function whose CREATE OR REPLACE is not followed by the carry would leave behind
create function pgpm._surface_kept_status() returns int language sql as $$ select 1 $$;
select throws_ok('select pgpm._surface_settled()', 'P0001',
  'pg_partition_magician: install.sql left pgpm._surface_kept_status(), the older pgpm.status() kept aside for its '
    || 'grants, without carrying them onto the new one. Call pgpm._surface_carry_grants(''pgpm.status()'') right '
    || 'after its CREATE OR REPLACE.',
  'a function left kept aside, its grants not carried, fails the install at its end, naming the missing call');
drop function pgpm._surface_kept_status();

-- ============================== (D) a grant this session cannot carry refuses the run up front ==============================
-- status() in an older shape once more, owned by t336_inst, which runs the install: it may take status() aside
-- (its owner, with CREATE on pgpm) but is not a member of t336_ops, so it could not replay the grant t336_ops
-- made through its grant option as t336_ops
drop function pgpm.status();
create function pgpm.status() returns table (parent regclass, paused boolean)
  language sql stable as $$ select null::regclass, null::boolean where false $$;
grant create on schema pgpm to t336_inst;
alter function pgpm.status() owner to t336_inst;
revoke execute on function pgpm.status() from public;
grant execute on function pgpm.status() to t336_ops with grant option;
set role t336_ops;
grant execute on function pgpm.status() to t336_mon;
reset role;
select pg_temp.t336_oids() as oids_d \gset
select is(pg_temp.t336_acl('pgpm.status()'), 'owner>owner:EXECUTE owner>t336_ops:EXECUTE* t336_ops>t336_mon:EXECUTE',
  'LIVENESS: status() is in an older shape, owned by t336_inst, with a grant t336_ops made through its grant option');
set session authorization t336_inst;
select throws_ok('select pgpm._surface_prepare()', '42501',
  'pg_partition_magician: install.sql cannot carry the grants on pgpm.status() (granted to t336_mon by t336_ops) '
    || 'onto the new shape it has to create: each was made through a grant option, and is carried as the role that '
    || 'made it so that role can still revoke it, which takes SET ROLE to that role (and its USAGE on schema pgpm) '
    || 'from this session. Nothing has been changed. Run install.sql as a member of each grantor (a superuser is '
    || 'one), or have each revoke its grant, re-run install.sql, then make the grant again.',
  'a session that cannot act as the grantor is refused before anything is taken, naming the grant');
reset session authorization;
select is(pg_temp.t336_oids() || ' | ' || pg_temp.t336_kept(), :'oids_d' || ' | none',
  'and nothing has been changed: every declared function is the one it was, nothing kept aside');

\ir :install
set client_min_messages = warning;

select is(pg_get_function_result('pgpm.status()'::regprocedure),
  (select s.result from pgpm._surface_shapes() s where s.sig = 'pgpm.status()'),
  'LIVENESS: a session that can act as t336_ops (a superuser) goes through, creating status() in its declared shape');
select is(pg_temp.t336_acl('pgpm.status()'), 'owner>owner:EXECUTE owner>t336_ops:EXECUTE* t336_ops>t336_mon:EXECUTE',
  'and carries the grant under t336_ops');

select * from finish();

-- the roles are the cluster's: take their grants away and drop them
revoke all on function pgpm.status() from t336_ops, t336_mon cascade;
revoke all on function pgpm.progress(regclass) from t336_ops, t336_mon cascade;
revoke all on function pgpm.check_text_time(regclass, name, text, integer, integer, text, integer, text, integer,
  timestamptz) from t336_mon;
revoke usage on schema pgpm from t336_ops, t336_inst;
revoke create on schema pgpm from t336_inst;
drop role if exists t336_mon;
drop role if exists t336_ops;
drop role if exists t336_inst;
