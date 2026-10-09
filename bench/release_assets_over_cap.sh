#!/usr/bin/env bash
# Prove that a v* tag publishes the GitHub Release while the dbdev package is over database.dev's
# 250,000-character cap, and that the strict refusal of that package stays in publish-dbdev.yml, by RUNNING
# both workflows' build steps rather than reading their spelling.
#
# WHY THIS GUARD EXISTS (issue #1077). #764 made the cap advisory everywhere the merge gate builds the
# package (test.sh, the Lint minifier job, the Test Suite's size job all pass PGPM_DBDEV_CAP=warn), so a
# tree over the cap merges by design, and RELEASING.md says a tag "publishes the GitHub Release, and then
# publishes to database.dev", with only publish-dbdev.yml refusing the oversized package. release.yml's
# "Build release assets" step was never moved to warn mode: it ran build_dbdev_package.sh in its default
# strict mode, which exits 1 over the cap, so the step failed before "Publish GitHub Release" and a tag cut
# from such a tree published no release at all (no bundle, no tarball, no notes).
#
# HOW. Each step's `run:` script is read out of the parsed workflow, `${{ steps.v.outputs.version }}` is
# substituted (v9.9.9 for release.yml, 9.9.9 for publish-dbdev.yml, the shapes each receives), and the
# script is run the way a runner runs it (`bash -e`, or `-eo pipefail` for `shell: bash`) with the env the
# workflow, the job and the step declare, in a scratch copy of the files it reads. The scratch
# pgpm_core/install.sql is this checkout's plus one padding statement whose string literal the minifier
# keeps, so the package is over the cap whatever the real install.sql weighs (it is over today; the remedy
# in #765 would otherwise starve this guard). PGPM_DBDEV_CAP is removed from the inherited environment, so
# only what the workflow itself sets can choose the mode.
#   LIVENESS  release.yml's release job builds its assets and then publishes the GitHub Release (a later
#             step uses softprops/action-gh-release), so the build step is on the release's path;
#   LIVENESS  build_dbdev_package.sh in its default mode refuses the scratch package (the condition the
#             defect needs: a strict build of it fails);
#   CHECK     release.yml's Build release assets step succeeds on that tree and leaves all three assets
#             (bundle, dbdev package, tarball), the dbdev one being the over-cap package it built;
#   CHECK     publish-dbdev.yml's Build the dbdev package step refuses the same tree, with the cap message:
#             the strict refusal stays where RELEASING.md puts it.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   release_dbdev_build_strict -- release.yml's dbdev build put back in strict mode: pre-#1077
#
# Usage: release_assets_over_cap.sh <container> <db> [release.yml]
# With no third argument it reads this checkout's .github/workflows/release.yml; with one it reads THAT
# file, which is how bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this
# checkout). Needs python3 with PyYAML on the host (as scripts/check_track_filters.py does) and nothing
# else; <container> and <db> are accepted so discriminate.sh can call it the way it calls every guard, and
# are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="${3:-$ROOT/.github/workflows/release.yml}"
WF="${WF/#\/repo\//$ROOT/}"
PUB="$ROOT/.github/workflows/publish-dbdev.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$ROOT" "$WF" "$PUB" "$WORK" <<'PY'
import os, shutil, subprocess, sys
import yaml

root, wf, pub, work = sys.argv[1:5]
CAP = 250000
fail = 0


def say(ok, what, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<90} {detail}")


def stop(what, detail=""):
    say(False, what, detail)
    sys.exit(1)


def load(path):
    try:
        with open(path) as fh:
            return yaml.safe_load(fh)
    except Exception as e:  # a mutant that does not parse verifies nothing
        stop("GUARD: the workflow parses", f"{path}: {e}")


def step_of(doc, job, name):
    """(the job's steps, the index of the step called name), or a GUARD failure."""
    steps = (((doc or {}).get("jobs") or {}).get(job) or {}).get("steps") or []
    names = [s.get("name") for s in steps]
    if name not in names:
        stop(f"GUARD: job {job!r} has a step named {name!r}", f"steps: {names}")
    return steps, names.index(name)


def runnable(doc, job, step, version):
    """The step's script with the version expression substituted, its env, and the runner's shell flags."""
    script = step.get("run") or ""
    script = script.replace("${{ steps.v.outputs.version }}", version)
    if "${{" in script:
        stop(f"GUARD: every expression in the {job} step is one this guard substitutes", script.split("${{")[1][:60])
    env = {k: v for k, v in os.environ.items() if k != "PGPM_DBDEV_CAP"}
    for scope in (doc.get("env"), (doc["jobs"][job] or {}).get("env"), step.get("env")):
        for k, v in (scope or {}).items():
            v = str(v)
            if "${{" in v:   # a secret or an expression: nothing a build step's mode can hang on here
                continue
            env[str(k)] = v
    shell = step.get("shell") or ((doc["jobs"][job].get("defaults") or {}).get("run") or {}).get("shell") \
        or ((doc.get("defaults") or {}).get("run") or {}).get("shell")
    flags = ["--noprofile", "--norc", "-eo", "pipefail"] if shell == "bash" else ["-e"]
    if shell not in (None, "bash"):
        stop(f"GUARD: the {job} step runs in bash", f"shell: {shell}")
    return script, env, flags


def scratch(tag):
    """A copy of what the steps read, with an install.sql whose minified package is over the cap."""
    d = os.path.join(work, tag)
    os.makedirs(d)
    for sub in ("scripts", "pgpm_core"):
        shutil.copytree(os.path.join(root, sub), os.path.join(d, sub))
    for f in ("README.md", "ONBOARDING.md", "CHANGELOG.md"):
        if os.path.exists(os.path.join(root, f)):
            shutil.copy(os.path.join(root, f), d)
    with open(os.path.join(d, "pgpm_core", "install.sql"), "a") as fh:
        fh.write("\nselect '" + "x" * (CAP + 10000) + "' as release_guard_padding;\n")
    return d


def run(script, env, flags, cwd):
    path = os.path.join(cwd, ".step.sh")
    with open(path, "w") as fh:
        fh.write(script)
    p = subprocess.run(["bash", *flags, path], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout


# 1. The build step is on the release's path.
rel = load(wf)
steps, i = step_of(rel, "release", "Build release assets")
later = [s.get("uses") or "" for s in steps[i + 1:]]
if any(u.startswith("softprops/action-gh-release") for u in later):
    say(True, "LIVENESS: the release job builds its assets, then publishes the GitHub Release")
else:
    stop("LIVENESS: the release job builds its assets, then publishes the GitHub Release", f"later uses: {later}")

# 2. The scratch package is one a strict build refuses.
probe = scratch("probe")
penv = {k: v for k, v in os.environ.items() if k != "PGPM_DBDEV_CAP"}
p = subprocess.run(["scripts/build_dbdev_package.sh", "pgpm_core/install.sql", "probe.sql"], cwd=probe, env=penv,
                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
size = os.path.getsize(os.path.join(probe, "probe.sql")) if os.path.exists(os.path.join(probe, "probe.sql")) else 0
if p.returncode != 0 and "exceeds" in p.stdout and size > CAP:
    say(True, "LIVENESS: a default-mode dbdev build refuses the scratch package", f"{size} chars")
else:
    stop("LIVENESS: a default-mode dbdev build refuses the scratch package",
         f"exit {p.returncode}, {size} chars: {p.stdout.strip()[-200:]}")

# 3. release.yml's step publishes over the cap.
d = scratch("release")
script, env, flags = runnable(rel, "release", steps[i], "v9.9.9")
rc, out = run(script, env, flags, d)
assets = ["pg_partition_magician-v9.9.9-bundle.sql", "pg_partition_magician--9.9.9.sql",
          "pg_partition_magician-v9.9.9.tar.gz"]
sizes = {a: (os.path.getsize(os.path.join(d, "release-assets", a))
             if os.path.exists(os.path.join(d, "release-assets", a)) else 0) for a in assets}
if rc == 0 and all(sizes.values()):
    say(True, "release.yml's Build release assets step succeeds over the cap, all three assets built")
else:
    errs = [ln for ln in out.splitlines() if "ERROR" in ln or "error" in ln][:2]
    say(False, "release.yml's Build release assets step succeeds over the cap, all three assets built",
        f"exit {rc}, sizes {sizes}: {' | '.join(errs) or out.strip()[-200:]}")
    fail = 1
if rc == 0:
    pkg = sizes["pg_partition_magician--9.9.9.sql"]
    if pkg > CAP:
        say(True, "LIVENESS: the dbdev asset the step built is the over-cap package", f"{pkg} chars")
    else:
        say(False, "LIVENESS: the dbdev asset the step built is the over-cap package", f"{pkg} chars")
        fail = 1

# 4. publish-dbdev.yml still refuses the same package.
pdoc = load(pub)
psteps, j = step_of(pdoc, "publish", "Build the dbdev package")
d = scratch("publish")
script, env, flags = runnable(pdoc, "publish", psteps[j], "9.9.9")
rc, out = run(script, env, flags, d)
if rc != 0 and "exceeds" in out:
    say(True, "publish-dbdev.yml's Build the dbdev package step refuses the over-cap package")
else:
    say(False, "publish-dbdev.yml's Build the dbdev package step refuses the over-cap package",
        f"exit {rc}: {out.strip()[-200:]}")
    fail = 1

sys.exit(fail)
PY
rc=$?
if [ "$rc" = 0 ]; then echo "release_assets_over_cap: PASS"; else echo "release_assets_over_cap: FAIL"; fi
exit "$rc"
