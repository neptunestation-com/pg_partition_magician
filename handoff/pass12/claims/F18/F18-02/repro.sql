-- F18-02: the staging-name refusal's remedy is `drop table <nsp>.<rel>_pgpm_new` whatever holds the name.
-- A sequence (or a view) holding it is refused with that remedy, and the remedy fails: "is not a table".
create extension if not exists pgtap;
select plan(5);

create table public.f18s (id bigint primary key, ts timestamptz not null);
create sequence public.f18s_pgpm_new;

select is((select relkind::text from pg_class where oid = 'public.f18s_pgpm_new'::regclass), 'S',
          'LIVENESS: a sequence holds the staging name f18s_pgpm_new');

-- the refusal, and the remedy it names, captured from the message itself
create function pg_temp.f18_refusal() returns text language plpgsql as $f$
begin
  call pgpm.transmute('public.f18s', 'id', 1000::bigint);
  return null;
exception when others then
  return sqlerrm;
end $f$;
select pg_temp.f18_refusal() as msg \gset
select ok(:'msg' like 'pg_partition_magician: public.f18s_pgpm_new already exists%',
          'LIVENESS: transmute refused on the held staging name: ' || coalesce(:'msg', 'no refusal'));
select ok(:'msg' ~ '\((drop [^)]+)\)', 'LIVENESS: the refusal names a statement to type in parentheses');
select (regexp_match(:'msg', '\((drop [^)]+)\)'))[1] as remedy \gset

-- the defect: the named statement must repair the state the message describes
select lives_ok(:'remedy', 'the remedy the refusal names runs against the holder it found: ' || :'remedy');
select is(to_regclass('public.f18s_pgpm_new'), null,
          'and the staging name is free afterwards');
select * from finish();
