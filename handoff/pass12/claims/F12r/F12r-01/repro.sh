#!/usr/bin/env bash
# F12r-01: CHANGELOG.md's Unreleased section carries an unresolved merge of #1161's bullet (and others): after the
# bullet that says set_regrain WARNS and stores the target, a second copy of its tail says `set_regrain` now
# REFUSES such a run. The code warns and stores (docs/reference.md agrees with the code). Several bullets are also
# present twice verbatim (#1157, #1170, #1171, #1172).
# Env: PSQL (fresh db with pgpm_core installed), TREE.
set -uo pipefail
fail=0
say() { echo "$1"; }
CL="$TREE/CHANGELOG.md"
# the Unreleased section: from '## [Unreleased]' to the next '## ['
unrel=$(awk '/^## \[Unreleased\]/{on=1; next} on && /^## \[/{exit} on' "$CL")
[ -n "$unrel" ] && say "ok - fixture: the CHANGELOG has an Unreleased section" || { say "not ok - fixture: no Unreleased section"; exit 1; }

# --- the code: set_regrain on a run past the lock budget warns and STORES the target (it does not refuse) ---
cap=$($PSQL -tAc "select (current_setting('max_locks_per_transaction')::bigint * (current_setting('max_connections')::bigint + current_setting('max_prepared_transactions')::bigint)) / 4")
$PSQL -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
set client_min_messages = warning;
create table public.f12r_over (id bigint primary key, a text);
insert into public.f12r_over values (0, 'first'), ($(( (cap + 1) * 100 - 1 )), 'last');
call pgpm.transmute('public.f12r_over', 'id', $(( (cap + 1) * 50 ))::bigint, p_obtain => 2);
insert into public.f12r_over values ($(( (cap + 1) * 100 + 1 )), 'frontier');
SQL
out=$($PSQL -c "select pgpm.set_regrain('public.f12r_over', '100')" 2>&1); rc=$?
stored=$($PSQL -tAc "select regrain_to from pgpm.config where parent_table = 'public.f12r_over'::regclass")
warned=$($PSQL -tAc "select count(*) from pgpm.log where parent_table = 'public.f12r_over'::regclass and action = 'warn_regrain_lock_budget'")
if [ "$rc" = 0 ] && [ "$stored" = "100" ] && [ "$warned" = "1" ] && grep -q "WARNING" <<<"$out"; then
  say "ok - LIVENESS: set_regrain on a run of cap+1 children warns, logs warn_regrain_lock_budget and stores the target (rc=$rc stored=$stored)"
else
  say "not ok - LIVENESS: set_regrain did not warn-and-store as reference.md says (rc=$rc stored=$stored warned=$warned): $out"; fail=1
fi

# --- the defect checks: the Unreleased section must not say the opposite, nor carry bullets twice ---
if grep -q '`set_regrain` now refuse a run whose fine children' <<<"$unrel"; then
  say "not ok - CHANGELOG Unreleased says \`set_regrain\` now refuses a run over the lock budget, which the code warns about and stores: $(grep -n '`set_regrain` now refuse' "$CL" | head -1 | cut -c1-120)"
  fail=1
else
  say "ok - CHANGELOG Unreleased does not say set_regrain refuses an over-budget run"
fi
dups=$(grep -E '^- \*\*' <<<"$unrel" | sort | uniq -d)
if [ -n "$dups" ]; then
  say "not ok - CHANGELOG Unreleased carries these bullets twice (an unresolved merge): $(cut -c1-90 <<<"$dups" | tr '\n' '|')"
  fail=1
else
  say "ok - no Unreleased bullet appears twice"
fi
$PSQL -qc "drop table if exists public.f12r_over cascade" >/dev/null 2>&1
exit $fail
