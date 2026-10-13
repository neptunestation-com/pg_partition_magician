\set ON_ERROR_STOP on
set client_min_messages = warning;
create temporary table rs_budget as
  select slots, slots / 4 as cap
    from (select current_setting('max_locks_per_transaction')::bigint
                 * (current_setting('max_connections')::bigint + current_setting('max_prepared_transactions')::bigint) as slots) s;
select slots, cap from rs_budget \gset
select 'R slots=' || :slots || ' cap=' || :cap;
create table public.rs (id bigint primary key, a text, b int not null default 1);
insert into public.rs (id, a) values (0, 'first'), ((:cap + 1) * 100 - 1, 'last');
call pgpm.transmute('public.rs', 'id', ((:cap + 1) * 50)::bigint, p_obtain => 2);
insert into public.rs (id, a) values ((:cap + 1) * 100 + 1, 'frontier');
-- an archive strategy AND a retention policy: the aged prefix is copied and attached like the rest (#278)
update pgpm.config set archive_fn = 'pgpm._archive_noop(regclass, name, text, text)'::regprocedure, retain = (:cap * 50)::text
 where parent_table = 'public.rs'::regclass;
select 'R fine_count=' || pgpm._regrain_fine_count('public.rs'::regclass, c, '100', '0', ((:cap + 1) * 100)::text, :cap, true)
  from pgpm.config c where c.parent_table = 'public.rs'::regclass;
select pgpm.set_regrain('public.rs', '100');
select 'R warn_rows=' || count(*) from pgpm.log where parent_table = 'public.rs'::regclass and action = 'warn_regrain_lock_budget';
select 'R prepare=' || pgpm.regrain_step('public.rs', (select child_name from pgpm.part where parent_table = 'public.rs'::regclass and attached and lo = '0'), '100');
