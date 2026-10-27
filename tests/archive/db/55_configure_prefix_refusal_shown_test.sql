-- pgpm_archive/README.md: "no refusal archive.configure raises quotes a value that holds an '@', whichever check
-- raises it. A refused value with no '@' in it is quoted as given." #1269 routed the endpoint and bucket refusals
-- through archive._configure_shown, and tests/archive/db/53 part J drives each of them; the p_prefix refusal (a
-- '.' or '..' segment, #1260) was not among them and printed its value raw, so a prefix typed as
-- 'user:password@host/../' put the password in the client's error and the server log (issue #1368).
--
-- The contract: the p_prefix refusal shows its value as archive._configure_shown shows one, through the same
-- decision (archive._configure_hides): not at all when it holds an '@', quoted as given otherwise. Each refusal is
-- witnessed as the p_prefix refusal (it names p_prefix and the segment) and as stopping the write (the stored row
-- keeps the prefix configured before), so the absence of the password is the rule's doing and not another
-- refusal's, or no refusal at all. And the remedy the message gives, the prefix spelled without the segment, is
-- typed and stored.
select plan(17);

create schema t55;
create table t55.evt (id bigint primary key, payload text not null);
insert into t55.evt values (1, 'one'), (2, 'two');
call pgpm.transmute('t55.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t55.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => 'before/');

create function t55.cfg(p_prefix text) returns void language sql as $$
  select archive.configure('t55.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => p_prefix) $$;
create function t55.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'no error';
exception when others then
  return sqlerrm;
end $$;
create function t55.stored() returns text language sql as $$
  select prefix from archive.config where parent_table = 't55.evt'::regclass $$;
-- one call's answer, judged: which refusal it is (the witness that the value reached the p_prefix branch), and
-- whether the password typed before the '@' is in it
create function t55.judge(p_prefix text) returns text language sql as $$
  select case when m not like 'archive.configure: p_prefix%has a "." or ".." segment%' then 'another answer: ' || replace(m, 's3cr3t', '<the password>')
              when m like '%s3cr3t%' then 'that refusal, printing the password'
              else 'that refusal, without the password' end
    from t55.err(format('select t55.cfg(%L)', p_prefix)) m $$;

select is(t55.stored(), 'before/', 'LIVENESS: the table is configured with the prefix before/');

-- a value with no '@' is quoted as given, so a refusal that hides one below is the rule's doing
select is(t55.err($$ select t55.cfg('x/../') $$),
  'archive.configure: p_prefix ''x/../'' has a "." or ".." segment; no store can be addressed with one (the HTTP client resolves it before sending, and the request''s signature no longer matches). Spell the prefix without it',
  'the p_prefix refusal quotes a value that holds no ''@'' as given');
select is(t55.err($$ select t55.cfg('./y/') $$) like '%p_prefix ''./y/'' has a%', true,
  'and so for a leading "." segment');

-- the issue's value, and the segment and the credentials in every order
select is(t55.judge('user:s3cr3t@host/../'), 'that refusal, without the password',
  'the p_prefix refusal of user:password@host/../ does not print the password');
select is(t55.judge('../user:s3cr3t@host/'), 'that refusal, without the password',
  'nor that of ../user:password@host/ (the segment first)');
select is(t55.judge('a/./user:s3cr3t@b/c/'), 'that refusal, without the password',
  'nor that of a "." segment before the credentials');
select is(t55.judge('user:s3cr3t@host/./x/'), 'that refusal, without the password',
  'nor that of a "." segment after them');
select is(t55.judge('s3cr3t@/../'), 'that refusal, without the password',
  'nor that of a bare password before the ''@''');
-- the message still says what was refused, and why, and what to do
select ok(t55.err($$ select t55.cfg('user:s3cr3t@host/../') $$)
            like 'archive.configure: p_prefix, a value holding an ''@'' (not shown here: what precedes an ''@'' may be a password), has a "." or ".." segment;%Spell the prefix without it',
  'the hidden refusal names p_prefix, the segment and the remedy, and says why the value is not shown');
select is(t55.stored(), 'before/', 'and none of the refusals stored anything');

-- the remedy, as the message gives it: the prefix spelled without the segment is taken and stored
select lives_ok($$ select t55.cfg('x/') $$, 'the remedy of x/../, the prefix without the segment, is accepted');
select is(t55.stored(), 'x/', 'and stored');
select lives_ok($$ select t55.cfg('user/host/') $$, 'the remedy of a refused value holding an ''@'', spelled without the segment, is accepted');
select is(t55.stored(), 'user/host/', 'and stored');

-- the endpoint and bucket refusals ask the same decision (tests/archive/db/53 part J drives each one): one each
select is(t55.err($$ select archive.configure('t55.evt', 'user:s3cr3t@b/x') $$) like 'archive.configure: p_bucket%', true,
  'LIVENESS: a bucket holding an ''@'' reaches the bucket refusal');
select ok(t55.err($$ select archive.configure('t55.evt', 'user:s3cr3t@b/x') $$) not like '%s3cr3t%',
  'and that refusal does not print the password either');
select is(t55.stored(), 'user/host/', 'and leaves the stored row as it was');

select * from finish();
