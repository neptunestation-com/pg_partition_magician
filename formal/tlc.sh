#!/usr/bin/env bash
# Run TLC on a spec and config from a pinned container, so CI and laptops agree (pack 4.5).
#
# Usage: formal/tlc.sh <dir holding the .tla files> <Spec.tla> <config.cfg> [extra TLC args...]
#
# The jar is tla2tools v1.7.4, fetched once into ~/.cache/pgpm-formal and checked against its sha256;
# the JRE is eclipse-temurin 21 by digest. FORMAL_LOCAL_JAVA=1 runs the same jar on the host's java
# instead (faster to iterate; CI never sets it).
set -euo pipefail
TLA_VERSION=1.7.4
TLA_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
JRE_IMAGE=eclipse-temurin@sha256:f37956012e0cb88400e5b3689aeae2d2d735364c1922ae2225536163b5a99f56

dir=$(cd "$1" && pwd); spec=$2; cfg=$3; shift 3
cache=${FORMAL_CACHE:-$HOME/.cache/pgpm-formal}
jar=$cache/tla2tools-$TLA_VERSION.jar
mkdir -p "$cache"
if [ ! -f "$jar" ]; then
  curl -fsSL -o "$jar.part" "https://github.com/tlaplus/tlaplus/releases/download/v$TLA_VERSION/tla2tools.jar"
  mv "$jar.part" "$jar"
fi
echo "$TLA_SHA256  $jar" | sha256sum -c --quiet - || { echo "tla2tools.jar checksum mismatch" >&2; exit 2; }

workers=${FORMAL_WORKERS:-auto}
args=(-XX:+UseParallelGC -Xmx"${FORMAL_HEAP:-4g}" -cp /tla/tla2tools.jar tlc2.TLC -workers "$workers"
      -deadlock -cleanup -metadir /tmp/tlc-meta -config "$cfg" "$@" "$spec")
if [ "${FORMAL_LOCAL_JAVA:-0}" = 1 ]; then
  cd "$dir"
  args=("${args[@]/#\/tla\/tla2tools.jar/$jar}")
  args=("${args[@]/#\/tmp\/tlc-meta/$(mktemp -d)}")
  exec java "${args[@]}"
fi
exec docker run --rm -v "$jar:/tla/tla2tools.jar:ro" -v "$dir:/work" -w /work \
  --user "$(id -u):$(id -g)" "$JRE_IMAGE" java "${args[@]}"
