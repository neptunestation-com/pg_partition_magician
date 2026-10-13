#!/usr/bin/env bash
# P1-01: pgpm._surface_prepare() in this tree still DROPS a reshaped declared function whatever its ACL. Its loop
# computes `granted` (proacl is not null) and `kept` for each function _surface_unreplaceable() lists and then runs
# `drop function` unconditionally; no ALTER ROUTINE ... RENAME to pgpm._surface_kept_<name> exists in the file. So
# nothing is ever kept aside, every _surface_carry_grants() call is a no-op, and a re-run of install.sql over an
# older install whose pgpm.status() has an earlier result shape loses the operator's REVOKE EXECUTE FROM PUBLIC and
# GRANT EXECUTE TO <monitoring role>, exactly as the #1267 defect the PR body, the CHANGELOG, the header comment
# (install.sql:56-60) and docs/guide.md say is fixed. Two sides are checked: the prepare alone (it should keep the
# granted function aside under pgpm._surface_kept_status(); it drops it), and the whole upgrade (the grants should
# survive; they do not). Pass = the prepare keeps the function and the re-run carries both grants.
set -u
q() { $PSQL -v ON_ERROR_STOP=1 -tAc "$1"; }
fail=0
check() { if [ "$2" = "t" ]; then echo "ok - $1"; else echo "not ok - $1"; fail=1; fi; }
older_status() {
  q "create function pgpm.status()
     returns table (parent regclass, control_kind text, partition_step text, obtain integer, retain text,
       paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
       newest_bound text, fks_suspended bigint, fks_unvalidated bigint, history_unregrained boolean,
       retain_drop_failures bigint, retain_backlog bigint, retain_detaching bigint, parent_missing boolean)
     language sql stable as \$\$ select null::regclass, null::text, null::text, null::int, null::text, null::boolean,
       null::bigint, null::bigint, null::bigint, null::text, null::bigint, null::bigint, null::boolean,
       null::bigint, null::bigint, null::bigint, null::boolean where false \$\$;
     revoke execute on function pgpm.status() from public;
     grant execute on function pgpm.status() to p101_mon;" >/dev/null
}
acl() { q "select coalesce((select string_agg(format('%s>%s:%s', case when a.grantor = p.proowner then 'owner' else pg_get_userbyid(a.grantor)::text end,
                 case when a.grantee = 0 then 'PUBLIC' when a.grantee = p.proowner then 'owner' else pg_get_userbyid(a.grantee)::text end,
                 a.privilege_type), ' ' order by 1)
          from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where p.oid = to_regprocedure('$1')), 'no function')"; }

q "do \$\$ begin if not exists (select 1 from pg_roles where rolname = 'p101_mon') then create role p101_mon; end if; end \$\$" >/dev/null
q "drop function pgpm.status()" >/dev/null || { echo "not ok - fixture: drop the installed status()"; exit 1; }
older_status || { echo "not ok - fixture: older status()"; exit 1; }
check "LIVENESS: status() has the older shape (no regrain_to), _surface_unreplaceable() lists it with no dependant, PUBLIC cannot execute it and p101_mon can" \
  "$(q "select position('regrain_to' in pg_get_function_result('pgpm.status()'::regprocedure)) = 0
          and (select count(*) from pgpm._surface_unreplaceable() u where u.fn = 'pgpm.status()'::regprocedure and u.dependants is null) = 1
          and not has_function_privilege('public', 'pgpm.status()', 'execute')
          and has_function_privilege('p101_mon', 'pgpm.status()', 'execute')")"
check "LIVENESS: its ACL is non-default: owner>owner:EXECUTE owner>p101_mon:EXECUTE" "$([ "$(acl 'pgpm.status()')" = "owner>owner:EXECUTE owner>p101_mon:EXECUTE" ] && echo t || echo f)"

# (1) the prepare alone, as a stopped run would leave it
q "select pgpm._surface_prepare()" >/dev/null || { echo "not ok - fixture: _surface_prepare() ran"; exit 1; }
check "LIVENESS: the prepare took pgpm.status() away (it is reshaped, so it cannot be replaced in place)" \
  "$(q "select to_regprocedure('pgpm.status()') is null")"
check "the prepare kept the granted status() aside as pgpm._surface_kept_status() rather than dropping it" \
  "$(q "select to_regprocedure('pgpm._surface_kept_status()') is not null")"
check "the kept function holds the operator's ACL (owner>owner:EXECUTE owner>p101_mon:EXECUTE)" \
  "$([ "$(acl 'pgpm._surface_kept_status()')" = "owner>owner:EXECUTE owner>p101_mon:EXECUTE" ] && echo t || echo f)"

# (2) the whole upgrade: reinstate the older granted status() (drop whatever (1) left) and re-run the file
q "drop function if exists pgpm._surface_kept_status(); drop function if exists pgpm.status()" >/dev/null
older_status || { echo "not ok - fixture: older status() again"; exit 1; }
check "LIVENESS: before the re-run status() is the older shape again with the operator's ACL" \
  "$([ "$(acl 'pgpm.status()')" = "owner>owner:EXECUTE owner>p101_mon:EXECUTE" ] && [ "$(q "select position('regrain_to' in pg_get_function_result('pgpm.status()'::regprocedure)) = 0")" = t ] && echo t || echo f)"
$PSQL -q -v ON_ERROR_STOP=1 --single-transaction -f - < "$TREE/pgpm_core/install.sql" >/dev/null 2>&1 || { echo "not ok - fixture: re-run install.sql"; exit 1; }
check "LIVENESS: the re-run created status() in the declared shape (regrain_to present) and left nothing kept aside" \
  "$(q "select position('regrain_to' in pg_get_function_result('pgpm.status()'::regprocedure)) > 0
          and to_regprocedure('pgpm._surface_kept_status()') is null")"
check "after the upgrade status() holds exactly the older one's ACL: owner>owner:EXECUTE owner>p101_mon:EXECUTE (REVOKE FROM PUBLIC and the GRANT to p101_mon carried)" \
  "$([ "$(acl 'pgpm.status()')" = "owner>owner:EXECUTE owner>p101_mon:EXECUTE" ] && echo t || echo f)"
check "PUBLIC still cannot execute pgpm.status() after the upgrade" \
  "$(q "select not has_function_privilege('public', 'pgpm.status()', 'execute')")"

q "revoke all on function pgpm.status() from p101_mon" >/dev/null 2>&1
q "drop role if exists p101_mon" >/dev/null 2>&1
exit $fail
