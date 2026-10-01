-- Three refusals that used to arrive late or not at all (issue #710).
--
--   A. An EXCLUDE constraint. Its index is not unique, so transmute listed it as a plain secondary index to
--      carry, nothing refused the shape, and the cutover's ATTACH of it under a plain partitioned copy died
--      with a raw "index definitions do not match", after phases 1 and 2 had committed the validated
--      pgpm_monolith_bound CHECK and the claim: the table rejected every write past hi until a
--      transmute_abort. It is now refused up front, before anything is committed, with the remedy.
--   B. A publication the caller does not own. The cutover adds the new parent to every publication naming
--      the table (ALTER PUBLICATION ... ADD TABLE), which only the publication's owner may do, so a role
--      that owns the table but not the publication failed there with a raw "must be owner of publication",
--      the same late failure. Now refused up front too.
--   C. set_regrain's name check probed only the anchor cell's name. On a numeric key a later cell's label is
--      wider (a fraction is appended), so a target whose names do not fit was accepted and every tick then
--      refused the same name from regrain_step. It now probes the cells auto-regrain will actually name.
--
-- INSTRUMENT. The failing conversions run through dblink, as tests/125 explains: a committing procedure
-- inside throws_* dies at its first COMMIT with 2D000, and a mutant that fails LATE must really commit
-- phases 1 and 2 so that the state assertions (no claim, no bound, writes past hi accepted) discriminate
-- instead of being satisfied by a wrapper's rollback. Every refusal is pinned by its message, paired with a
-- witness that the condition it denies was present, and with a witness that the same call succeeds once
-- the condition is removed, so a transmute that refused everything could not pass this file.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(25);

-- Roles are cluster-wide and the database is per-file, so they are created only when absent and never
-- dropped (see tests/72 for why a DROP ROLE here would be the worse choice).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't189_converter') then create role t189_converter; end if;
end $$;

-- ===================================== A. an EXCLUDE constraint =====================================
create extension if not exists btree_gist;
create table public.ex189 (id bigint primary key, room int not null, during tsrange, note text,
                           constraint ex189_no_overlap exclude using gist (room with =, during with &&));
create index ex189_note_idx on public.ex189 (note);
insert into public.ex189 values (1, 1, '[2020-01-01,2020-01-02)', 'a'), (2, 1, '[2020-01-02,2020-01-03)', 'b'),
                                (3, 2, '[2020-01-01,2020-01-05)', 'c');

select ok(exists (select 1 from pg_constraint c join pg_index i on i.indexrelid = c.conindid
                   where c.conrelid = 'public.ex189'::regclass and c.contype = 'x'
                     and c.conname = 'ex189_no_overlap' and not i.indisunique),
  'A WITNESS: ex189 carries the EXCLUDE constraint ex189_no_overlap, whose index is not unique (the shape the carried-index filter let through)');

select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.ex189', 'id', 1000, p_obtain => 1) $c$) $$,
  'pg_partition_magician: cannot transmute ex189 -- its exclusion constraint(s) (ex189_no_overlap) cannot be carried%',
  'A: transmute refuses a table with an EXCLUDE constraint, naming the constraint');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.ex189'::regclass),
  'A: the refusal left no claim on ex189');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.ex189'::regclass and conname = 'pgpm_monolith_bound'),
  'A: the refusal left no pgpm_monolith_bound CHECK on ex189');
select lives_ok($$ insert into public.ex189 values (5000, 3, '[2021-01-01,2021-01-02)', 'past hi') $$,
  'A: a write past the bound the conversion would have chosen is accepted: the table is untouched');
select throws_ok($$ insert into public.ex189 values (6000, 1, '[2020-01-01 12:00,2020-01-01 13:00)', 'overlap') $$,
  '23P01', NULL, 'A: and the constraint is still on the table, refusing an overlapping row');
select is((select relkind::text from pg_class where oid = 'public.ex189'::regclass), 'r',
  'A: ex189 is still a plain table');

-- the same table without the constraint converts: the refusal is about the constraint and nothing else
alter table public.ex189 drop constraint ex189_no_overlap;
call pgpm.transmute('public.ex189', 'id', 1000, p_obtain => 1);
select is((select relkind::text from pg_class where oid = 'public.ex189'::regclass), 'p',
  'A LIVENESS: with the constraint dropped, the same transmute converts ex189');
select ok(exists (select 1 from pg_class where relname = 'ex189_note_idx_pgpm' and relkind = 'I'),
  'A LIVENESS: and carries its plain secondary index (ex189_note_idx_pgpm)');

-- ============================== B. a publication the caller does not own ==============================
create table public.pb189 (id bigint primary key, v text);
insert into public.pb189 values (1, 'a'), (2, 'b'), (3, 'c');
alter table public.pb189 owner to t189_converter;
create publication pub189 for table public.pb189;   -- owned by the superuser running this file
create publication pub189_mine for table public.pb189;
alter publication pub189_mine owner to t189_converter;
grant usage, create on schema public to t189_converter;
grant usage on schema pgpm to t189_converter;
grant all on all tables in schema pgpm to t189_converter;
grant all on all sequences in schema pgpm to t189_converter;

select is((select pg_get_userbyid(relowner)::text from pg_class where oid = 'public.pb189'::regclass), 't189_converter',
  'B WITNESS: t189_converter owns pb189');
select is((select array_agg(p.pubname::text order by p.pubname) from pg_publication_rel r
             join pg_publication p on p.oid = r.prpubid where r.prrelid = 'public.pb189'::regclass),
  array['pub189', 'pub189_mine'],
  'B WITNESS: two publications name pb189');
select ok(not pg_has_role('t189_converter', (select pubowner from pg_publication where pubname = 'pub189'), 'USAGE')
          and pg_has_role('t189_converter', (select pubowner from pg_publication where pubname = 'pub189_mine'), 'USAGE'),
  'B WITNESS: t189_converter owns pub189_mine and not pub189');

select dblink_connect('t189b', 'dbname=' || current_database());
select dblink_exec('t189b', 'set role t189_converter');
select throws_like(
  $$ select dblink_exec('t189b', $c$ call pgpm.transmute('public.pb189', 'id', 1000, p_obtain => 1) $c$) $$,
  'pg_partition_magician: cannot transmute pb189 as t189_converter -- the publication(s) (pub189) name it%',
  'B: transmute refuses up front, naming the one publication the caller does not own');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.pb189'::regclass),
  'B: the refusal left no claim on pb189');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.pb189'::regclass and conname = 'pgpm_monolith_bound'),
  'B: the refusal left no pgpm_monolith_bound CHECK on pb189');
select lives_ok($$ insert into public.pb189 values (5000, 'past hi') $$,
  'B: a write past the bound the conversion would have chosen is accepted: the table is untouched');

-- handed the publication, the same role converts the same table, and the new parent is in both
alter publication pub189 owner to t189_converter;
select dblink_exec('t189b', $c$ call pgpm.transmute('public.pb189', 'id', 1000, p_obtain => 1) $c$);
select dblink_disconnect('t189b');
select is((select relkind::text from pg_class where oid = 'public.pb189'::regclass), 'p',
  'B LIVENESS: owning both publications, t189_converter converts pb189');
select is((select array_agg(p.pubname::text order by p.pubname) from pg_publication_rel r
             join pg_publication p on p.oid = r.prpubid where r.prrelid = 'public.pb189'::regclass),
  array['pub189', 'pub189_mine'],
  'B LIVENESS: and the new parent is in both publications');

-- ============================ C. set_regrain probes the names it will need ============================
-- 19 bytes, so the monolith's name `..._p<19 digits>_to_<19 digits>` is exactly 63: a name that fits at
-- partition_step. A target of 1e-23 gives the anchor cell (0) a 19-digit label and the cell after it a
-- 19-digit label plus `_` and 23 fraction digits, 64 bytes in all.
create table public.rg189_numeric_names (id numeric primary key, v text);
insert into public.rg189_numeric_names values (5, 'a'), (50, 'b'), (1500, 'c');
call pgpm.transmute('public.rg189_numeric_names', 'id', 1000, p_obtain => 1);

select is((select child_name::text from pgpm.part
            where parent_table = 'public.rg189_numeric_names'::regclass and child_oid = (select monolith_oid from pgpm.config
                   where parent_table = 'public.rg189_numeric_names'::regclass)),
  'rg189_numeric_names_p0000000000000000000_to_0000000000000002000',
  'C WITNESS: the monolith is the coarse child [0, 2000), and its 63-byte name fits');
select lives_ok($$ select pgpm._part_name('rg189_numeric_names', 'id', '0.00000000000000000000001', '0', null, 'UTC') $$,
  'C WITNESS: at the target 1e-23 the anchor cell''s name fits (all the old check asked about)');
select throws_like($$ select pgpm._part_name('rg189_numeric_names', 'id', '0.00000000000000000000001',
                                             '0.00000000000000000000001', null, 'UTC') $$,
  'pg_partition_magician: cannot name a partition of rg189_numeric_names -- % is 64 bytes%',
  'C WITNESS: and the second cell''s name is 64 bytes, which regrain_step would refuse on every tick');

select throws_like($$ select pgpm.set_regrain('public.rg189_numeric_names', '0.00000000000000000000001') $$,
  'pg_partition_magician: cannot name a partition of rg189_numeric_names -- % is 64 bytes%',
  'C: set_regrain refuses the target at call time, naming the cell that does not fit');
select is((select regrain_to from pgpm.config where parent_table = 'public.rg189_numeric_names'::regclass), null,
  'C: and records no target');

select lives_ok($$ select pgpm.set_regrain('public.rg189_numeric_names', '0.5') $$,
  'C LIVENESS: a fractional target whose names fit (one fraction digit) is accepted');
select is((select regrain_to from pgpm.config where parent_table = 'public.rg189_numeric_names'::regclass), '0.5',
  'C LIVENESS: and recorded');

select * from finish();
