# _surface_prepare drops a shape-changed surface function and recreates it, losing the operator's grants the install's header promises to keep (pass 12 RC10)

Tier: 3

Age: old | Lens: contracts versus documentation

Found in adversarial review pass 12 at `bd55f84021fc4173034d156a41bc91a3f882560d`, root-cause group RC10: F6-03.

## F6-03

- finder: F6
- location: `pgpm_core/install.sql:117`
- lens: contracts versus documentation
- tier: 3
- scenario: re-running install.sql over an older install whose pgpm.status() has an earlier result shape drops and recreates it (_surface_prepare); _surface_unreplaceable counts only pg_depend dependants, never the ACL, so the operator's REVOKE EXECUTE FROM PUBLIC and GRANT EXECUTE TO f603_mon are silently lost and PUBLIC can execute status() again, where the section header promises the upgrade keeps the function's grants or refuses
- root cause (verifier): _surface_prepare drops a shape-changed surface function (e.g. a pre-#343 status() without regrain_to) and the file recreates it with default ACL; _surface_unreplaceable weighs only pg_depend dependants, never proacl, so an operator's REVOKE FROM PUBLIC / GRANT TO a role is silently reset, against the #983 header (install.sql:52) that says the upgrade keeps the function's grants and refuses rather than lose what depends on it. Reproduced on both trees by the classifier; fixture is the shape the file's own comments say an older install has; no rebuild needed.

Reproduction: `repro.sh`, the finder's, run unchanged by the verifier.

```bash
#!/usr/bin/env bash
# F6-03: re-running install.sql over an older install whose pgpm.status() has an earlier result shape (the
# upgrade path) makes pgpm._surface_prepare() DROP the function and the file recreate it. _surface_unreplaceable
# counts only pg_depend dependants (views), never the function's ACL, so an operator's
# REVOKE EXECUTE ... FROM PUBLIC and GRANT EXECUTE ... TO <monitoring role> on it are silently gone after the
# upgrade: PUBLIC can execute pgpm.status() again and the explicit grant has vanished. The section header says
# the file keeps "its oid, its grants and every view over it", and refuses rather than lose a dependant.
set -u
q() { $PSQL -v ON_ERROR_STOP=1 -tAc "$1"; }
fail=0
check() { if [ "$2" = "t" ]; then echo "ok - $1"; else echo "not ok - $1"; fail=1; fi; }

q "do \$\$ begin if not exists (select 1 from pg_roles where rolname = 'f603_mon') then create role f603_mon; end if; end \$\$" >/dev/null
# the older install's pgpm.status(): the same signature, an earlier result (no regrain_to column)
q "drop function pgpm.status();
   create function pgpm.status()
   returns table (parent regclass, control_kind text, partition_step text, obtain integer, retain text,
     paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
     newest_bound text, fks_suspended bigint, fks_unvalidated bigint, history_unregrained boolean,
     retain_drop_failures bigint, retain_backlog bigint, retain_detaching bigint, parent_missing boolean)
   language sql stable as \$\$ select null::regclass, null::text, null::text, null::int, null::text, null::boolean,
     null::bigint, null::bigint, null::bigint, null::text, null::bigint, null::bigint, null::boolean,
     null::bigint, null::bigint, null::bigint, null::boolean where false \$\$;
   revoke execute on function pgpm.status() from public;
   grant execute on function pgpm.status() to f603_mon;" >/dev/null || { echo "not ok - fixture: older status()"; exit 1; }
check "LIVENESS: before the upgrade, status() has the older shape, PUBLIC cannot execute it and f603_mon can" \
  "$(q "select position('regrain_to' in pg_get_function_result('pgpm.status()'::regprocedure)) = 0
          and not has_function_privilege('public', 'pgpm.status()', 'execute')
          and exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'pgpm.status()'::regprocedure
                       and a.grantee = 'f603_mon'::regrole and a.privilege_type = 'EXECUTE')")"

$PSQL -q -v ON_ERROR_STOP=1 -f - < "$TREE/pgpm_core/install.sql" >/dev/null 2>&1 || { echo "not ok - fixture: re-run install.sql"; exit 1; }

check "LIVENESS: the re-run upgraded status() to the declared shape (it was dropped and recreated)" \
  "$(q "select position('regrain_to' in pg_get_function_result('pgpm.status()'::regprocedure)) > 0")"
check "the operator's REVOKE EXECUTE FROM PUBLIC on pgpm.status() survives the upgrade" \
  "$(q "select not has_function_privilege('public', 'pgpm.status()', 'execute')")"
check "the operator's GRANT EXECUTE on pgpm.status() to f603_mon survives the upgrade" \
  "$(q "select exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'pgpm.status()'::regprocedure
                        and a.grantee = 'f603_mon'::regrole and a.privilege_type = 'EXECUTE')")"
q "revoke all on function pgpm.status() from f603_mon" >/dev/null 2>&1
q "drop role if exists f603_mon" >/dev/null 2>&1
exit $fail
```

Acceptance: the reproduction(s) above fail on bd55f84021fc4173034d156a41bc91a3f882560d and must pass on the fixing commit; the fix carries a bench/ guard and a bench/mutations entry proven by ./test.sh discriminate.



