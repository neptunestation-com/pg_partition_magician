#!/usr/bin/env bash
# archive.configure accepts an endpoint that spells the scheme's DEFAULT port ('http://host:80',
# 'https://<ref>.supabase.co:443/storage/v1/s3'). Both signers sign 'host:<host>:80' (v_host is the
# endpoint's whole authority) while the client (libcurl, via the http extension) sends 'Host: <host>',
# dropping a default port, so the store refuses every request with 403 SignatureDoesNotMatch: every export
# and every tick's chunk fails after the read. The same signed-host-vs-sent-host mechanism as the userinfo
# endpoint the PR now refuses, and an endpoint "the signers cannot use" the PR's title says configure refuses.
# A store on a default port is simulated by a byte-for-byte TCP relay on port 80 inside the harness container
# to MinIO at minio:9000 (MinIO verifies the signature against the Host header it receives).
set -u
RELAY=/tmp/prv_v_1301r2_relay_$$.pl
cleanup() { docker exec "$CONTAINER" sh -c "kill \$(cat $RELAY.pid 2>/dev/null) 2>/dev/null; rm -f $RELAY $RELAY.pid" >/dev/null 2>&1; }
trap cleanup EXIT
docker exec -i "$CONTAINER" sh -c "cat > $RELAY" <<'PL'
use IO::Socket::INET; use IO::Select; use POSIX ":sys_wait_h";
$SIG{CHLD} = sub { 1 while waitpid(-1, WNOHANG) > 0 };
my $s = IO::Socket::INET->new(LocalPort => 80, Listen => 16, ReuseAddr => 1) or die "listen: $!";
open(my $p, '>', "$ARGV[0].pid"); print $p $$; close $p;
while (1) {
  my $c = $s->accept or next;
  if (fork() == 0) {
    my $u = IO::Socket::INET->new(PeerAddr => 'minio', PeerPort => 9000) or exit 1;
    my $sel = IO::Select->new($c, $u);
    OUTER: while (my @r = $sel->can_read) {
      for my $h (@r) { my $buf; my $n = sysread($h, $buf, 65536); last OUTER unless $n;
        syswrite(($h == $c ? $u : $c), $buf); }
    }
    exit 0;
  }
  close $c;
}
PL
docker exec -d "$CONTAINER" perl "$RELAY" "$RELAY"
sleep 1

out=$($PSQL -tA -v ON_ERROR_STOP=1 -f - 2>&1 <<'SQL'
create extension if not exists pgtap;
select plan(6);
create schema prvv;
create table prvv.evt (id bigint primary key, payload text not null);
insert into prvv.evt values (1, 'one'), (2, 'two');
call pgpm.transmute('prvv.evt', 'id', 10000::bigint, p_paused => true);
select 'prv-v-1301r2-' || current_database() || '/' as p \gset
select set_config('prvv.p', :'p', false);
create function prvv.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function prvv.try(p_endpoint text) returns text language plpgsql as $$
begin
  perform archive.configure('prvv.evt', 'archive-test-bucket', p_endpoint => p_endpoint, p_prefix => current_setting('prvv.p'));
  return 'configured';
exception when others then return sqlerrm;
end $$;
create function prvv.export() returns text language plpgsql as $$
begin
  perform archive.to_s3('prvv.evt', 'evt', null, null);
  return 'ok';
exception when others then return sqlerrm;
end $$;
select (prvv.req('DELETE', :'p' || 'prvv.evt.ndjson')).status as cleared \gset

-- the store on its default port, the endpoint spelled without the port: works end to end
select is(prvv.try('http://localhost'), 'configured', 'LIVENESS: the default-port store spelled without its port is accepted');
select is(prvv.export(), 'ok', 'LIVENESS: the export reaches the store through the relay');
select is((prvv.req('GET', :'p' || 'prvv.evt.ndjson')).status, 200, 'LIVENESS: and its object landed');
select (prvv.req('DELETE', :'p' || 'prvv.evt.ndjson')).status as cleared \gset

-- the same store, the endpoint spelling its default port
select prvv.try('http://localhost:80') as port_cfg \gset
select prvv.export() as port_exp \gset
select (prvv.req('GET', :'p' || 'prvv.evt.ndjson')).status as port_get \gset
select ok(:'port_cfg' = 'configured' or :'port_cfg' ilike '%endpoint%',
  'GUARD: configure either takes the default-port endpoint or refuses it naming the endpoint (got: ' || :'port_cfg' || ')');
select ok(:'port_cfg' <> 'configured' or :'port_exp' = 'ok',
  'archive.to_s3 through an endpoint configured with its default port is not refused by the store (got: ' || :'port_exp' || ')');
select ok(:'port_cfg' <> 'configured' or :'port_get'::int = 200,
  'its object lands at the key, as it does through the endpoint spelled without the port');
select (prvv.req('DELETE', :'p' || 'prvv.evt.ndjson')).status as cleared \gset
select * from finish();
SQL
)
rc=$?
printf '%s\n' "$out"
[ $rc -eq 0 ] || exit 1
printf '%s\n' "$out" | grep -q '^not ok' && exit 1
exit 0
