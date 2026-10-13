-- F18-02 (verified rebuild): the staging-name refusal's remedy is `drop table <nsp>.<rel>_pgpm_new` whatever holds
-- the name. A sequence holding it is refused with that remedy, and the remedy fails: "is not a table".
-- Rebuilt so the named statement is not itself a premise: a fix that names the holder's kind
-- ('drop sequence ...') or names no statement at all (the monolith refusal's 'Drop or rename it') passes; a
-- refusal that names a statement which fails against the holder it found does not.
create extension if not exists pgtap;
select plan(4);

create table public.f18s (id bigint primary key, ts timestamptz not null);
create sequence public.f18s_pgpm_new;

select is((select relkind::text from pg_class where oid = 'public.f18s_pgpm_new'::regclass), 'S',
          'LIVENESS: a sequence holds the staging name f18s_pgpm_new');

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

-- the statement the refusal names, if it names one (null otherwise)
select (regexp_match(:'msg', '\((drop [^)]+)\)'))[1] as remedy \gset

-- the defect: a statement the refusal tells the operator to type must run against the holder it found
select lives_ok(coalesce(nullif(:'remedy', ''), 'drop sequence public.f18s_pgpm_new'),
                'the remedy the refusal names (or, naming none, the holder''s own drop) runs: ' || coalesce(nullif(:'remedy', ''), '(none named)'));
select is(to_regclass('public.f18s_pgpm_new'), null, 'and the staging name is free afterwards');
select * from finish();
