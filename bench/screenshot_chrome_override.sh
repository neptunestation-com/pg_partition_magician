#!/usr/bin/env bash
# Prove that scripts/screenshot.sh uses the browser CHROME names, the remedy its own refusal gives.
#
# WHY THIS GUARD EXISTS (issue #1373, F8-01). With no Chrome found, the script refused with "Install one, or
# pass its path via CHROME=...", and then set CHROME="" before its search on every run, so the CHROME= an
# operator passed was discarded and the same refusal came back. The message is the only place CHROME= is
# documented, and it changed what the operator typed to no effect.
#
# HOW. The script is run with PATH holding only the tools it needs, a stand-in browser that records that it
# ran and writes a 2560x1680 PNG header to its --screenshot= path, and a second stand-in, a decoy, as
# `chromium` on PATH where the script's search finds it.
#   CHROME names the stand-in, no browser on PATH: the stand-in runs and the screenshot is written (exit 0)
#   CHROME names the stand-in, the decoy on PATH: the stand-in runs, the decoy does not (the operator's
#     choice is not replaced by the search)
#   CHROME names no executable file: refused, naming CHROME, and neither browser runs
#   CONTROL   CHROME unset, the decoy on PATH: the search still finds and runs it; CHROME unset, nothing on
#             PATH: the "no Chrome/Chromium found" refusal, so the search half is alive and can refuse
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   screenshot_chrome_reset -- CHROME="" before the search again (pre-#1373)
#
# Usage: screenshot_chrome_override.sh <container> <db> [screenshot.sh]
# With no third argument it runs this checkout's scripts/screenshot.sh; with one it runs THAT file, which is
# how bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this checkout). Needs bash
# and python3 on the host; <container> and <db> are accepted so discriminate.sh can call it the way it calls
# every guard, and are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="${3:-$ROOT/scripts/screenshot.sh}"
S="${S/#\/repo\//$ROOT/}"
fail=0
ok()  { printf 'PASS  %-62s %s\n' "$1" "${2:-}"; }
bad() { printf 'FAIL  %-62s %s\n' "$1" "${2:-}"; fail=1; }
if [ ! -f "$S" ]; then bad "fixture: the script under test exists" "$S"; exit 1; fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/decoy"
for tool in dirname mktemp rm seq sleep cat; do
  p=$(command -v "$tool") && ln -s "$p" "$T/bin/$tool"
done
# python3 by the interpreter itself, not by `command -v`: a pyenv or asdf shim on PATH is a script that needs
# bash, its own PATH and HOME, none of which the isolated run below gives it, so linking the shim would fail the
# script's server and PNG check for a reason that has nothing to do with CHROME.
if py=$(python3 -c 'import os, sys; print(os.path.realpath(sys.executable))' 2>/dev/null) && [ -x "$py" ]; then
  ln -s "$py" "$T/bin/python3"
else
  bad "fixture: the real python3 interpreter was resolved" "${py:-python3 did not run}"; exit 1
fi
browser() { # <path> <tag>: a stand-in browser that records <tag> and writes a PNG header to --screenshot=
  cat > "$1" <<FAKE
#!/bin/bash
for a in "\$@"; do case "\$a" in --screenshot=*) out="\${a#--screenshot=}";; esac; done
echo "$2" >> "$T/ran"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x0a\x00\x00\x00\x06\x90\x08\x06\x00\x00\x00\x00\x00' > "\$out"
FAKE
  chmod +x "$1"
}
browser "$T/chosen" chosen
browser "$T/decoy/chromium" decoy

# run <PATH> [CHROME]: the script once; sets rc, out, ran (the stand-ins that ran, in order)
run() {
  rm -f "$T/ran" "$T/out.png"
  local port=$(( 20000 + RANDOM % 20000 ))
  if [ $# -gt 1 ]; then
    out=$(env -i PATH="$1" HOME="$T" PORT="$port" CHROME="$2" /bin/bash "$S" "$T/out.png" 2>&1); rc=$?
  else
    out=$(env -i PATH="$1" HOME="$T" PORT="$port" /bin/bash "$S" "$T/out.png" 2>&1); rc=$?
  fi
  ran=""; if [ -f "$T/ran" ]; then ran=$(tr '\n' ' ' < "$T/ran"); ran=${ran% }; fi
}

if ! PATH="$T/bin" command -v chromium >/dev/null 2>&1 && ! PATH="$T/bin" command -v google-chrome >/dev/null 2>&1 \
   && PATH="$T/decoy:$T/bin" command -v chromium >/dev/null 2>&1; then
  ok "LIVENESS: no browser on the bare PATH, the decoy on the other"
else
  bad "LIVENESS: no browser on the bare PATH, the decoy on the other"; exit 1
fi

run "$T/bin"
if [ "$rc" != 0 ] && grep -q 'no Chrome/Chromium found' <<<"$out" && [ -z "$ran" ]; then
  ok "CONTROL: CHROME unset, nothing on PATH: the search refuses" "exit $rc"
else bad "CONTROL: CHROME unset, nothing on PATH: the search refuses" "exit $rc, ran '$ran': ${out:0:80}"; fi
run "$T/decoy:$T/bin"
if [ "$rc" = 0 ] && [ "$ran" = decoy ]; then ok "CONTROL: CHROME unset, the decoy on PATH: the search finds it" "ran $ran"
else bad "CONTROL: CHROME unset, the decoy on PATH: the search finds it" "exit $rc, ran '$ran': ${out:0:80}"; fi

run "$T/bin" "$T/chosen"
if [ "$rc" = 0 ] && [ "$ran" = chosen ] && [ -s "$T/out.png" ]; then
  ok "CHROME= names the browser, nothing on PATH: it is used" "ran $ran, exit $rc"
else bad "CHROME= names the browser, nothing on PATH: it is used" "exit $rc, ran '${ran:-nothing}': ${out:0:90}"; fi
run "$T/decoy:$T/bin" "$T/chosen"
if [ "$rc" = 0 ] && [ "$ran" = chosen ]; then ok "CHROME= names the browser, the decoy on PATH: CHROME= wins" "ran $ran"
else bad "CHROME= names the browser, the decoy on PATH: CHROME= wins" "exit $rc, ran '${ran:-nothing}'"; fi
run "$T/decoy:$T/bin" "$T/missing"
if [ "$rc" != 0 ] && [ -z "$ran" ] && grep -q "CHROME=$T/missing" <<<"$out"; then
  ok "CHROME= naming no executable is refused, by name, nothing run" "exit $rc"
else bad "CHROME= naming no executable is refused, by name, nothing run" "exit $rc, ran '${ran:-nothing}': ${out:0:90}"; fi

echo "screenshot_chrome_override: $([ "$fail" = 0 ] && echo PASS || echo FAIL)"
exit "$fail"
