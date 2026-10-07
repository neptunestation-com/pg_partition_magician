#!/usr/bin/env bash
# pr_verify.sh: the mechanical steps of per-PR adversarial verification (docs/adversarial-review.md,
# "Per-PR verification"; the /pr-verify skill is the coordinator's checklist that calls these in order).
#
#   pr_verify.sh prepare <pr> --work <dir> [--acceptance <claims dir>] [--plan <seed plan.json>]
#                                          [--mutations a,b] [--finder P1]
#   pr_verify.sh harness up|down [--archive] [--timescale]
#   pr_verify.sh classify --work <dir>
#   pr_verify.sh report --work <dir> [--post] [--budget "<text>"]
#   pr_verify.sh cleanup --work <dir>
#
# prepare resolves the PR's head and merge base, builds the trees a verification runs against, all
# history-less (build_review_tree.sh) so the finder cannot read anything off a diff of the tree:
#   <work>/base      the merge base: the tree WITHOUT the change
#   <work>/head      the PR's head: the tree WITH the change
#   <work>/review    the head plus the seed(s) of --plan (plant_seeds.py; the finder's tree); no plan: a
#                    second copy of the head, and the comment will say the hunt was unwitnessed
#   <work>/mutant    the head with the PR's NEW mutations applied (every name in the head's
#                    bench/mutations/mutate.py that the base's lacks, or --mutations): the defect the PR
#                    says it fixes, put back, so the acceptance reproductions can be shown to fail on it
#   <work>/head_src, base_src   detached worktrees of the two commits WITH bench/mutations, for the
#                    coordinator's and verifiers' use only; the finder is never given these paths
#   <work>/pr.diff   the change AS PRESENTED to the finder: diff -ruN of base against review, so a planted
#                    seed reads as part of the PR, exactly as a defect the PR introduced would
#   <work>/pr.real.diff   base against head, the change itself, for the claims verifier (which reads the
#                    source trees anyway and must not chase the seed as a gap in the PR)
#   <work>/surface/  pr_surface.py's slices.json, units.txt, surface.md, surface.json
#   <work>/claims/ACC/   the acceptance claims copied from --acceptance (claim directories with claim.json
#                    and the issue's verified reproduction; the coordinator writes their install lists)
#   <work>/pr.json   head, base, title, url, mutations, finder id
# The finder's claims go under <work>/claims/<finder>/, the claims verifier's under <work>/claims/V/, the
# per-candidate verdicts under <work>/verdicts/<id>.json.
#
# harness runs the PRIVATE containers a verification uses (pgpm_prv-15, and with --archive pgpm_prv-archive
# with its MinIO, with --timescale pgpm_prv-timescale, on the network pgpm_prv_net): private names, because
# the fixers' gated `./test.sh` runs bring the fixed-name compose containers up and down, and gate.sh exits
# 7 on a fixed-name container it cannot explain. The repository is NOT mounted into them: a reproduction
# reaches the tree under test only through its claim's install list, never through /repo, or every tree
# would read as the same one.
#
# classify runs pr_classify.py over the claims against the four trees in those containers and coverage.py
# over the finder's ledger; report merges the verdicts and renders the comment with pr_comment.py (exit 1 =
# landing blocked); cleanup removes the worktrees.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)" || exit 5
cd "$ROOT" || exit 5
say() { echo "$(date -u +%H:%M:%SZ) $*"; }
die() { echo "pr_verify: $*" >&2; exit "${2:-2}"; }

CMD="${1:-}"; shift || true
WORK=""; ACCEPT=""; PLAN=""; MUTS=""; FINDER="P1"; POST=""; BUDGET=""; ARCHIVE=""; TIMESCALE=""; PR=""; UPDOWN=""
case "$CMD" in
  prepare) PR="${1:?pr number}"; shift;;
  harness) UPDOWN="${1:?up|down}"; shift;;
  classify|report|cleanup) ;;
  -h|--help|"") sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) die "unknown command $CMD";;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --work) WORK=$2; shift 2;;
    --acceptance) ACCEPT=$2; shift 2;;
    --plan) PLAN=$2; shift 2;;
    --mutations) MUTS=$2; shift 2;;
    --finder) FINDER=$2; shift 2;;
    --post) POST=1; shift;;
    --budget) BUDGET=$2; shift 2;;
    --archive) ARCHIVE=1; shift;;
    --timescale) TIMESCALE=1; shift;;
    *) die "unknown option $1";;
  esac
done
[ "$CMD" = harness ] || [ -n "$WORK" ] || die "--work <dir> is required"

NET=pgpm_prv_net
C15=pgpm_prv-15; CARCH=pgpm_prv-archive; CMINIO=pgpm_prv-archive-minio; CTS=pgpm_prv-timescale
MINIO_IMAGE="${PGPM_MINIO_IMAGE:-bitnamilegacy/minio:2025.7.23-debian-12-r5@sha256:6dabb4a2088c9a79908de3bc05f4586c23ad2182c8908e7e3acbf61c1467fb20}"
TS_IMAGE="public.ecr.aws/supabase/postgres:${TS_PG_TAG:-15.14.1.127}"

wait_pg() { # <container> [tcp]
  local _
  for _ in $(seq 1 90); do
    if [ "${2:-}" = tcp ]; then
      docker exec -e PGPASSWORD=postgres "$1" psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1 && return 0
    else
      docker exec "$1" psql -U postgres -tAc 'select 1' >/dev/null 2>&1 && return 0
    fi
    sleep 1
  done
  return 1
}

harness_up() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
  if ! docker ps --format '{{.Names}}' | grep -qx "$C15"; then
    docker rm -f "$C15" >/dev/null 2>&1
    docker run -d --name "$C15" --network "$NET" -e POSTGRES_PASSWORD=postgres pgpm_test:15 >/dev/null || die "could not start $C15" 5
  fi
  wait_pg "$C15" || die "$C15 did not come up" 5
  say "$C15 up"
  if [ -n "$ARCHIVE" ]; then
    if ! docker ps --format '{{.Names}}' | grep -qx "$CMINIO"; then
      docker rm -f "$CMINIO" >/dev/null 2>&1
      # the compose service's exact invocation: the image's entrypoint bypassed, bitnami's data path
      docker run -d --name "$CMINIO" --network "$NET" --network-alias minio \
        -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
        --entrypoint minio "$MINIO_IMAGE" server /bitnami/minio/data --address :9000 >/dev/null || die "could not start $CMINIO" 5
    fi
    local _
    for _ in $(seq 1 60); do docker run --rm --network "$NET" curlimages/curl -sf http://minio:9000/minio/health/cluster >/dev/null 2>&1 && break; sleep 1; done
    docker run --rm --network "$NET" curlimages/curl -s -o /dev/null -w 'bucket %{http_code}\n' --aws-sigv4 aws:amz:us-east-1:s3 \
      -u minioadmin:minioadmin -X PUT http://minio:9000/archive-test-bucket
    if ! docker ps --format '{{.Names}}' | grep -qx "$CARCH"; then
      docker rm -f "$CARCH" >/dev/null 2>&1
      docker run -d --name "$CARCH" --network "$NET" -e POSTGRES_PASSWORD=postgres pgpm_test:17-archive >/dev/null || die "could not start $CARCH" 5
    fi
    wait_pg "$CARCH" || die "$CARCH did not come up" 5
    # the extensions an archive reproduction needs, in template1 so every fresh database inherits them
    # (the compose harness gets them from test.sh's run_archive per database)
    docker exec "$CARCH" psql -U postgres -d template1 -qc "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null
    say "$CARCH up (MinIO at minio:9000, bucket archive-test-bucket)"
  fi
  if [ -n "$TIMESCALE" ]; then
    if ! docker ps --format '{{.Names}}' | grep -qx "$CTS"; then
      docker rm -f "$CTS" >/dev/null 2>&1
      docker run -d --name "$CTS" --network "$NET" -e POSTGRES_PASSWORD=postgres "$TS_IMAGE" >/dev/null || die "could not start $CTS" 5
    fi
    wait_pg "$CTS" tcp || die "$CTS did not come up" 5
    say "$CTS up (TCP only; never grant to current_user in this image)"
  fi
}

harness_down() {
  docker rm -f "$C15" "$CARCH" "$CMINIO" "$CTS" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  say "private harness removed"
}

new_mutations() { # <base_src> <head_src>: names in the head's catalogue that the base's lacks
  python3 - "$1" "$2" <<'PY'
import importlib.util, sys
def names(root):
    spec = importlib.util.spec_from_file_location("m_" + str(abs(hash(root))), root + "/bench/mutations/mutate.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return set(m.MUTATIONS), m.MUTATION_SRC
b, _ = names(sys.argv[1]); h, src = names(sys.argv[2])
for n in sorted(h - b):
    print(n + "\t" + src.get(n, "pgpm_core/install.sql"))
PY
}

case "$CMD" in
  harness)
    case "$UPDOWN" in up) harness_up;; down) harness_down;; *) die "harness up|down";; esac
    ;;
  prepare)
    [ -e "$WORK/head" ] && die "$WORK/head exists; use a fresh --work directory" 3
    mkdir -p "$WORK/claims" "$WORK/verdicts"
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 5
    gh pr view "$PR" --repo "$REPO" --json number,title,url,headRefOid,headRefName,baseRefName > "$WORK/pr.json" || exit 5
    BASEREF=$(jq -r .baseRefName "$WORK/pr.json")
    git fetch -q origin "pull/$PR/head" "$BASEREF" || exit 5
    HEAD=$(git rev-parse FETCH_HEAD)
    [ "$HEAD" = "$(jq -r .headRefOid "$WORK/pr.json")" ] || say "note: fetched head $HEAD differs from the PR's recorded head $(jq -r .headRefOid "$WORK/pr.json")"
    BASE=$(git merge-base "origin/$BASEREF" "$HEAD") || exit 5
    say "#$PR head $HEAD, merge base $BASE (origin/$BASEREF)"
    "$S/build_review_tree.sh" "$BASE" "$WORK/base" >/dev/null || exit 5
    "$S/build_review_tree.sh" "$HEAD" "$WORK/head" >/dev/null || exit 5
    "$S/build_review_tree.sh" "$HEAD" "$WORK/review" >/dev/null || exit 5
    git worktree add -q --detach "$WORK/head_src" "$HEAD" || exit 5
    git worktree add -q --detach "$WORK/base_src" "$BASE" || exit 5
    SEEDS=0
    if [ -n "$PLAN" ]; then
      python3 "$S/plant_seeds.py" --tree "$WORK/review" --pristine "$WORK/head_src" --plan "$PLAN" --sealed "$WORK/sealed.json" || exit 5
      SEEDS=$(jq '.seeds | length' "$WORK/sealed.json")
      say "$SEEDS seed(s) planted in $WORK/review (sealed: $WORK/sealed.json; never shown to the finder)"
    else
      say "no seed plan: the review tree is the head; the comment will say the hunt was unwitnessed"
    fi
    diff -ruN -x .git "$WORK/base" "$WORK/review" > "$WORK/pr.diff"; rc=$?
    [ $rc -le 1 ] || die "diff failed ($rc)" 5
    # the real change, for the claims verifier (it reads the source trees anyway, so the seed is not a
    # secret from it, and a diff that carries the seed would send it chasing the seed as a gap in the PR)
    diff -ruN -x .git "$WORK/base" "$WORK/head" > "$WORK/pr.real.diff"; rc=$?
    [ $rc -le 1 ] || die "diff failed ($rc)" 5
    python3 "$S/pr_surface.py" --base "$WORK/base" --head "$WORK/review" --out "$WORK/surface" --finder "$FINDER" >/dev/null; rc=$?
    [ $rc -eq 0 ] || die "pr_surface exited $rc (3 = the trees are identical)" "$rc"
    if [ -n "$ACCEPT" ]; then
      mkdir -p "$WORK/claims/ACC"
      cp -R "$ACCEPT"/. "$WORK/claims/ACC"/
      say "acceptance claims: $(find "$WORK/claims/ACC" -name claim.json | wc -l | tr -d ' ')"
    fi
    if [ -z "$MUTS" ]; then
      new_mutations "$WORK/base_src" "$WORK/head_src" > "$WORK/mutations.tsv" || exit 5
    else
      : > "$WORK/mutations.tsv"
      for m in ${MUTS//,/ }; do
        src=$(python3 -c "import sys; sys.path.insert(0, '$WORK/head_src/bench/mutations'); import mutate; print(mutate.MUTATION_SRC.get('$m', 'pgpm_core/install.sql'))") || exit 5
        printf '%s\t%s\n' "$m" "$src" >> "$WORK/mutations.tsv"
      done
    fi
    if [ -s "$WORK/mutations.tsv" ]; then
      "$S/build_review_tree.sh" "$HEAD" "$WORK/mutant" >/dev/null || exit 5
      while IFS=$'\t' read -r name src; do
        python3 "$WORK/head_src/bench/mutations/mutate.py" "$name" "$WORK/mutant/$src" "$WORK/mutant/$src" || die "mutation $name did not build against the head" 4
        say "mutant: $name applied to $src"
      done < "$WORK/mutations.tsv"
    else
      say "no new mutation in this PR: no mutant tree (the comment will say the acceptance was not checked against a mutant)"
    fi
    jq --arg head "$HEAD" --arg base "$BASE" --arg finder "$FINDER" --argjson seeds "$SEEDS" \
       --arg muts "$(cut -f1 "$WORK/mutations.tsv" | paste -sd, -)" \
       '. + {head: $head, base: $base, finder: $finder, seeds: $seeds, mutations: $muts}' "$WORK/pr.json" > "$WORK/pr.json.tmp" && mv "$WORK/pr.json.tmp" "$WORK/pr.json"
    echo
    echo "PREPARED #$PR: $(jq -r .title "$WORK/pr.json")"
    echo "  trees: $WORK/base $WORK/head $WORK/review$([ -d "$WORK/mutant" ] && echo " $WORK/mutant")"
    echo "  claims verifier V: $WORK/head_src, $WORK/base_src, real diff $WORK/pr.real.diff"
    echo "  finder $FINDER: tree $WORK/review, diff $WORK/pr.diff, units $WORK/surface/units.txt ($(wc -l < "$WORK/surface/units.txt" | tr -d ' ') units), surface $WORK/surface/surface.md"
    echo "  claims dir $WORK/claims; verdicts dir $WORK/verdicts; mutations: $(cut -f1 "$WORK/mutations.tsv" | paste -sd, -)"
    ;;
  classify)
    [ -f "$WORK/pr.json" ] || die "$WORK has no pr.json; run prepare first" 3
    args=(--claims "$WORK/claims" --base "$WORK/base" --head "$WORK/head" --review "$WORK/review" --out "$WORK/pr_classified.json"
          --container "$C15" --archive-container "$CARCH" --timescale-container "$CTS")
    [ -d "$WORK/mutant" ] && args+=(--mutant "$WORK/mutant")
    [ -f "$WORK/sealed.json" ] && args+=(--sealed "$WORK/sealed.json")
    python3 "$S/pr_classify.py" "${args[@]}" || exit 4
    python3 "$S/coverage.py" --tree "$WORK/review" --slices "$WORK/surface/slices.json" --claims "$WORK/claims" --out "$WORK/coverage.json"
    rc=$?; [ $rc -eq 0 ] || say "coverage below threshold (exit $rc): re-run the finder on its unread units before reporting"
    ;;
  report)
    [ -f "$WORK/pr_classified.json" ] || die "$WORK has no pr_classified.json; run classify first" 3
    if ls "$WORK"/verdicts/*.json >/dev/null 2>&1; then jq -s add "$WORK"/verdicts/*.json > "$WORK/verdicts.json"; else echo '{}' > "$WORK/verdicts.json"; fi
    args=(--classified "$WORK/pr_classified.json" --verdicts "$WORK/verdicts.json" --coverage "$WORK/coverage.json"
          --surface "$WORK/surface/surface.json" --pr "$(jq -r .number "$WORK/pr.json")" --head "$(jq -r .head "$WORK/pr.json")"
          --base "$(jq -r .base "$WORK/pr.json")" --out "$WORK/comment.md")
    [ -f "$WORK/sealed.json" ] && args+=(--sealed "$WORK/sealed.json")
    [ -n "$BUDGET" ] && args+=(--budget "$BUDGET")
    [ -n "$POST" ] && args+=(--post)
    python3 "$S/pr_comment.py" "${args[@]}"
    exit $?
    ;;
  cleanup)
    for w in head_src base_src; do [ -d "$WORK/$w" ] && git worktree remove --force "$WORK/$w"; done
    git worktree prune
    say "worktrees removed; trees and claims kept under $WORK"
    ;;
esac
