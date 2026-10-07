#!/usr/bin/env bash
# Print the build key of the pgpm test images, or run --selftest.
#
# WHY. Every CI job that runs a test.sh track built its pgpm_test:<major> image from scratch: about
# 80 s on a GitHub runner (apt, pg_cron and pgTAP from source), plus a pull of the postgres:<major>
# base from Docker Hub, whose anonymous data quota a burst of PRs has exhausted before (#558). The
# image changes only when its inputs do, so CI caches it in the Actions cache under this key and
# test.sh rebuilds only when the local image was built from other inputs (its Dockerfile stamps the
# key into the image as the label org.pg_partition_magician.build_key; test.sh's build_image reads it).
#
# WHAT THE KEY IS. A hash of the Dockerfile and docker-compose.yml (every build input: the base image
# tag, the pinned pg_cron and pgTAP refs, the build args each service passes), and the ISO week, so an
# image built from a FLOATING base (postgres:15 follows point releases) is rebuilt at least weekly
# rather than frozen at whatever the first build pulled. PGPM_IMAGE_KEY_WEEK overrides the week, for
# the self-test and for pinning a key by hand.
#
# Usage: scripts/image_build_key.sh            prints the key, e.g. v1-3f9c2a7d1e0b5c48-2026-W41
#        scripts/image_build_key.sh --selftest proves the key follows each input and nothing else
set -euo pipefail

key_of() {  # <repository root>
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(cat "$1/Dockerfile" "$1/docker-compose.yml" | sha256sum)
  else h=$(cat "$1/Dockerfile" "$1/docker-compose.yml" | shasum -a 256); fi
  echo "v1-${h:0:16}-${PGPM_IMAGE_KEY_WEEK:-$(date -u +%G-W%V)}"
}

root=$(cd "$(dirname "$0")/.." && pwd)

if [ "${1:-}" = "--selftest" ]; then
  fail() { echo "image_build_key selftest: FAIL  $1"; exit 1; }
  t=$(mktemp -d)
  trap 'rm -rf "$t"' EXIT
  cp "$root/Dockerfile" "$root/docker-compose.yml" "$t/"
  a=$(PGPM_IMAGE_KEY_WEEK=2026-W41 key_of "$t"); b=$(PGPM_IMAGE_KEY_WEEK=2026-W41 key_of "$t")
  [ "$a" = "$b" ] || fail "two reads of the same inputs gave different keys ($a, $b)"
  [[ "$a" =~ ^v1-[0-9a-f]{16}-2026-W41$ ]] || fail "key has an unexpected shape: $a"
  echo "# one more line" >> "$t/Dockerfile"
  c=$(PGPM_IMAGE_KEY_WEEK=2026-W41 key_of "$t")
  [ "$a" != "$c" ] || fail "a Dockerfile change did not change the key"
  echo "# one more line" >> "$t/docker-compose.yml"
  d=$(PGPM_IMAGE_KEY_WEEK=2026-W41 key_of "$t")
  [ "$c" != "$d" ] || fail "a docker-compose.yml change did not change the key"
  e=$(PGPM_IMAGE_KEY_WEEK=2026-W42 key_of "$t")
  [ "$d" != "$e" ] || fail "a new week did not change the key"
  [ "${d%-*-*}" = "${e%-*-*}" ] || fail "a new week changed the hash half of the key ($d, $e)"
  # LIVENESS: the real repository's key is what this script prints by default (no override leaking in)
  live=$(key_of "$root")
  [ "$live" = "$(bash "$0")" ] || fail "the default invocation does not print the repository's key"
  echo "image_build_key selftest: PASS  (deterministic; follows the Dockerfile, the compose file and the week; $live)"
  exit 0
fi

key_of "$root"
