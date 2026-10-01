#!/usr/bin/env bash
# closure.sh --claims <dir> --out <json> [--wait-fix-prs] [--container pgpm_test-15] [--no-archive]
#
# Re-run every reproduction of a pass against the FIXED main and write classify_claims.py's output. A
# reproduction that now PASSES (class not_reproduced) is the acceptance test met; one that still FAILS
# (candidate) is either unsound or an unfixed defect and is reviewed by hand before its issue is
# touched (close_comments.py renders that review). A verifier's `repro.verified.sql` is used where one
# exists (classify_claims.py prefers it).
#
# Preconditions, checked rather than assumed: the checkout is on `main`, clean, and fast-forwarded to
# origin/main (the run is pinned to that SHA and printed); with --wait-fix-prs the script first waits,
# up to 24 hours, until no open PR has a `fix/` head branch and no land.sh is running, and REFUSES to
# run if the wait ends with any still open, because closure against an incomplete main proves nothing
# (pass 2's first closure run fell through an 8-hour timeout that way).
#
# The harness: the PG15 service (default container pgpm_test-15), unless --no-archive the archive service
# with MinIO (claims that name "container": "pgpm_test-archive" need it), and the timescale service when any
# claim's install list names pgpm_hypertable/install.sql (classify_claims.py routes such a claim to
# pgpm_test-timescale, #719; pass 5's first closure run died on its first claim because nothing had started
# it), all brought up from this checkout's docker-compose.yml. Containers are left running for a rerun;
# `docker compose --profile pg15 --profile archive --profile timescale down -v` removes them.
set -uo pipefail
CLAIMS=""; OUT=""; WAIT=""; CONTAINER="pgpm_test-15"; ARCHIVE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --claims) CLAIMS=$2; shift 2;;
    --out) OUT=$2; shift 2;;
    --wait-fix-prs) WAIT=1; shift;;
    --container) CONTAINER=$2; shift 2;;
    --no-archive) ARCHIVE=""; shift;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option $1"; exit 2;;
  esac
done
[ -n "$CLAIMS" ] && [ -n "$OUT" ] || { echo "usage: closure.sh --claims <dir> --out <json> [--wait-fix-prs] [--container C] [--no-archive]"; exit 2; }
ROOT=$(git rev-parse --show-toplevel) || exit 5
cd "$ROOT" || exit 5
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 5
say() { echo "$(date -u +%H:%M:%SZ) $*"; }

if [ -n "$WAIT" ]; then
  say "waiting for the fix PRs to merge"
  for _ in $(seq 1 1440); do
    open=$(gh pr list --repo "$REPO" --state open --json headRefName --jq '[.[] | select(.headRefName | startswith("fix/"))] | length')
    running=$(pgrep -f 'scripts/review/land.sh' | wc -l | tr -d ' ')
    [ "$open" = "0" ] && [ "$running" = "0" ] && break
    sleep 60
  done
  say "open fix PRs: $open, land.sh running: $running"
  [ "$open" = "0" ] && [ "$running" = "0" ] || { echo "STOPPED: fix PRs still open; closure against an incomplete main proves nothing"; exit 3; }
fi

[ "$(git branch --show-current)" = "main" ] || { echo "STOPPED: checkout is not on main"; exit 3; }
[ -z "$(git status --porcelain)" ] || { echo "STOPPED: checkout is dirty"; exit 3; }
git fetch -q origin main && git merge -q --ff-only origin/main || { echo "STOPPED: main cannot fast-forward to origin/main"; exit 3; }
SHA=$(git rev-parse --short HEAD); say "main $SHA"

profiles=(--profile pg15); [ -n "$ARCHIVE" ] && profiles+=(--profile archive)
TIMESCALE=""; grep -rlq 'pgpm_hypertable/install.sql' "$CLAIMS" --include=claim.json 2>/dev/null && TIMESCALE=1
[ -n "$TIMESCALE" ] && profiles+=(--profile timescale)
docker compose "${profiles[@]}" up -d >/dev/null 2>&1 || { echo "STOPPED: docker compose up failed"; exit 5; }
for _ in $(seq 1 90); do
  docker exec -e PGPASSWORD=postgres "$CONTAINER" psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1 \
    && { [ -z "$ARCHIVE" ] || docker exec -e PGPASSWORD=postgres pgpm_test-archive psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1; } \
    && { [ -z "$TIMESCALE" ] || docker exec -e PGPASSWORD=postgres pgpm_test-timescale psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1; } && break
  sleep 1
done
if [ -n "$ARCHIVE" ]; then
  # the same readiness and bucket setup test.sh's archive track does: /minio/health/cluster (not `live`,
  # which answers before the server can serve), then one SigV4 PUT of the bucket (200 created, 409 exists)
  net=$(docker inspect pgpm_test-archive-minio --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
  for _ in $(seq 1 60); do docker run --rm --network "$net" curlimages/curl -sf http://minio:9000/minio/health/cluster >/dev/null 2>&1 && break; sleep 1; done
  docker run --rm --network "$net" curlimages/curl -s -o /dev/null -w 'bucket %{http_code}\n' --aws-sigv4 aws:amz:us-east-1:s3 -u minioadmin:minioadmin -X PUT http://minio:9000/archive-test-bucket
  docker exec pgpm_test-archive psql -U postgres -qc "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null
fi

sealed=$(mktemp); printf '{"pinned": "%s", "seeds": []}\n' "$(git rev-parse HEAD)" > "$sealed"
say "closure run against $SHA"
python3 scripts/review/classify_claims.py --claims "$CLAIMS" --review-tree "$ROOT" --pristine-tree "$ROOT" \
        --sealed "$sealed" --out "$OUT" --container "$CONTAINER" 2>&1 | tail -30
rc=${PIPESTATUS[0]}; rm -f "$sealed"
[ "$rc" = 0 ] || { echo "STOPPED: classify_claims exited $rc"; exit 4; }
echo "CLOSURE RUN DONE: $OUT (main $SHA)"
