-- from_hypertable_copy's change capture wrote into its delta by NAME (issue #1037, bullet 1). Since #955 the
-- drains, the cutover and uninstall find the delta by the oid the copy recorded in pgpm.scratch, and
-- docs/guide.md says so ("one you renamed or moved since is still found"), but the capture function the copy
-- minted carried `insert into <schema>.<rel>_pgpm_delta` in its body. So renaming the recorded delta during
-- the online window refused EVERY write to the live hypertable (42P01, relation "<rel>_pgpm_delta" does not
-- exist) until it was renamed back, cut over or uninstalled; and a table of the operator's later created under
-- the name the delta gave up took the capture's keys, which the drains and the cutover never read. The capture
-- now reaches the delta by the oid the copy recorded, as everything else does.
--
-- ASYMMETRIC FIXTURE. Two hypertables with a tracking copy each. a56 (6 devices): its recorded delta is
-- renamed, then three writes land (insert device 100001, update device 2, delete device 3); then the operator
-- creates a table of the delta's shape under the name it gave up, and one more write lands (insert device
-- 100002). b56 (4 devices), the control: its delta keeps its name and takes one write (insert device 200001).
-- Each delta's keys are asserted by identity, the operator's table is asserted empty (with a witness that it
-- accepts rows of that shape), and the cutover of each is asserted by the rows it leaves, by device and value,
-- which is the proof that what the capture wrote is what the cutover reconciled. c56 (3 devices): its recorded
-- delta is dropped, and a write is refused by pgpm's own 42P01, naming the remedy, not as a syntax error at the
-- bare oid the capture now carries.
select plan(18);

select mk_keyed_hypertable('a56', 6, '1 day', '4 days');
select mk_keyed_hypertable('b56', 4, '1 day', '4 days');
update a56 set temp = device_id * 10;
update b56 set temp = device_id * 10;
call pgpm.from_hypertable_copy('a56'::regclass, 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('b56'::regclass, 'ts', p_track_changes => true);

select is(pgpm._from_hypertable_scratch('a56'::regclass, 'hypertable_delta')::text
          || ',' || pgpm._from_hypertable_scratch('b56'::regclass, 'hypertable_delta')::text,
          'a56_pgpm_delta,b56_pgpm_delta',
          'LIVENESS: each tracking copy minted and recorded its delta under its own name');
select is((select string_agg(t.tgrelid::regclass::text || ':' || t.tgname, ',' order by t.tgname)
             from pg_trigger t where t.tgrelid in ('a56'::regclass, 'b56'::regclass) and not t.tgisinternal
              and t.tgname like '%\_pgpm\_delta\_trg'),
          'a56:a56_pgpm_delta_trg,b56:b56_pgpm_delta_trg',
          'LIVENESS: each capture trigger is on its live hypertable');

-- the operator renames a56's recorded delta during the online window
alter table a56_pgpm_delta rename to a56_renamed_delta;
select is(pgpm._from_hypertable_scratch('a56'::regclass, 'hypertable_delta')::text, 'a56_renamed_delta',
          'LIVENESS: pgpm still finds the renamed delta by its recorded oid');

select lives_ok($$insert into a56 (ts, device_id, temp) values (now() - interval '1 hour', 100001, 1.0)$$,
                'an insert into the live hypertable succeeds after its recorded delta is renamed');
select lives_ok($$update a56 set temp = 222 where device_id = 2$$,
                'an update of the live hypertable succeeds after its recorded delta is renamed');
select lives_ok($$delete from a56 where device_id = 3$$,
                'a delete from the live hypertable succeeds after its recorded delta is renamed');
insert into b56 (ts, device_id, temp) values (now() - interval '2 hours', 200001, 2.0);

-- the operator then takes the name the delta gave up, for a table of the same shape
create table public.a56_pgpm_delta (ts timestamptz, device_id bigint);
insert into public.a56_pgpm_delta (device_id, ts) values (-1, now());
select is((select string_agg(device_id::text, ',' order by device_id) from public.a56_pgpm_delta), '-1',
          'LIVENESS: the operator''s a56_pgpm_delta accepts a row of the capture''s shape');
delete from public.a56_pgpm_delta;
insert into a56 (ts, device_id, temp) values (now() - interval '3 hours', 100002, 3.0);

select is((select string_agg(device_id::text, ',' order by device_id, pgpm_seq) from a56_renamed_delta),
          '2,2,3,100001,100002',
          'every write to a56 after the rename is captured in the recorded (renamed) delta, by key');
select is((select count(*)::int from public.a56_pgpm_delta), 0,
          'and none in the operator''s table under the name the delta gave up');
select is((select string_agg(device_id::text, ',' order by device_id, pgpm_seq) from b56_pgpm_delta),
          '200001', 'the control: b56''s capture, its delta never renamed, logs its write');

-- the cutover reconciles each capture by the delta it recorded
call pgpm.from_hypertable_cutover('a56'::regclass, 'ts', interval '1 day', p_paused => true);
call pgpm.from_hypertable_cutover('b56'::regclass, 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'a56'::regclass)
          || '/' || (select relkind::text from pg_class where oid = 'b56'::regclass), 'p/p',
          'LIVENESS: both hypertables were cut over to partitioned tables');
select is((select string_agg(device_id || '=' || temp, ',' order by device_id) from a56),
          '1=10,2=222,4=40,5=50,6=60,100001=1,100002=3',
          'a56 holds every write made after the rename: device 2 updated, device 3 deleted, 100001 and 100002 inserted');
select is((select string_agg(device_id || '=' || temp, ',' order by device_id) from b56),
          '1=10,2=20,3=30,4=40,200001=2', 'the control: b56 holds its four devices and its insert');
select ok(to_regclass('public.a56_renamed_delta') is null and to_regclass('public.b56_pgpm_delta') is null,
          'the cutover dropped each recorded delta');
select is((select count(*)::int from public.a56_pgpm_delta), 0,
          'the operator''s a56_pgpm_delta survives the cutover, untouched');
select is((select count(*)::int from pg_trigger t
            where t.tgname in ('a56_pgpm_delta_trg', 'b56_pgpm_delta_trg')), 0,
          'and no capture trigger is left anywhere');

-- a capture whose recorded delta is gone refuses the write by name
select mk_keyed_hypertable('c56', 3, '1 day', '4 days');
call pgpm.from_hypertable_copy('c56'::regclass, 'ts', p_track_changes => true);
insert into c56 (ts, device_id, temp) values (now() - interval '1 hour', 300001, 4.0);
select is((select string_agg(device_id::text, ',') from c56_pgpm_delta), '300001',
          'LIVENESS: c56''s capture logs a write into its delta before the delta is dropped');
drop table c56_pgpm_delta;
select throws_like($$insert into c56 (ts, device_id, temp) values (now() - interval '2 hours', 300002, 5.0)$$,
                   'pg_partition_magician: the change capture of public.c56 has lost the delta from_hypertable_copy recorded for it%Re-run pgpm.from_hypertable_copy%',
                   'a write to a hypertable whose recorded delta is gone is refused by pgpm, naming the remedy');

select * from finish();
