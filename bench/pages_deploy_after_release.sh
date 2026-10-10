#!/usr/bin/env bash
# Prove that a Release run which publishes the GitHub Release and then concludes failure, because
# publish-dbdev.yml refuses a package over database.dev's cap, still redeploys the install page, by
# EVALUATING pages.yml's trigger and deploy conditions for that run rather than reading their spelling.
#
# WHY THIS GUARD EXISTS (issue #1169). pages.yml puts the latest release's dashboard bundle and version on
# the install page README sends operators to, and it is re-run after a Release by a workflow_run trigger
# (a `release: published` event created by another workflow's GITHUB_TOKEN does not cascade). Its deploy
# job ran only when that Release run concluded success. Since #1077 a tag cut from a tree whose dbdev
# package is over the 250,000-character cap publishes the GitHub Release and then fails the run by design
# in publish-dbdev.yml's strict build, so the deploy was skipped and the install page kept serving the
# previous release's bundle and version, with nothing in the tag's path to redeploy it.
#
# HOW. Read from the parsed workflows:
#   LIVENESS  release.yml's `release` job publishes the GitHub Release (softprops/action-gh-release), and
#             its publish-dbdev job needs that job and calls publish-dbdev.yml: the Release is out before
#             the dbdev step runs;
#   LIVENESS  publish-dbdev.yml's Build the dbdev package step, RUN as a runner runs it on a scratch copy of
#             this checkout padded over the cap (as bench/release_assets_over_cap.sh builds it), exits
#             non-zero, and the publish-dbdev job is not continue-on-error: the run so concludes failure;
#   LIVENESS  pages.yml's deploy job downloads the latest release's *-bundle.sql and deploys the site: it
#             is the job that puts a release's bundle on the install page;
#   LIVENESS  this guard's expression evaluator can say no: pages.yml's pre-#1169 deploy condition
#             evaluates false for a workflow_run of a Release run that concluded failure, true for success;
#   CHECK     pages.yml has a workflow_run trigger that names release.yml's workflow `name` and fires on
#             `completed`;
#   CHECK     for that workflow_run event, with the conclusion the run above reaches, the deploy job's
#             `if`, the `if` of every job it needs, and the `if` of each of its steps up to the deploy
#             all evaluate true. The same holds for a run that concluded success (the control: a fix that
#             deploys only on failure is not a fix).
# An `if` this evaluator cannot evaluate (a context it does not model, such as `needs.*` or `steps.*`)
# fails as a GUARD line, loudly: extend the model rather than assume the answer.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   pages_deploy_gated_on_release_success -- pages.yml's deploy skipped unless the Release run succeeded:
#                                            pre-#1169
#
# Usage: pages_deploy_after_release.sh <container> <db> [pages.yml]
# With no third argument it reads this checkout's .github/workflows/pages.yml; with one it reads THAT
# file, which is how bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this
# checkout). Needs python3 with PyYAML on the host and nothing else; <container> and <db> are accepted so
# discriminate.sh can call it the way it calls every guard, and are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAGES="${3:-$ROOT/.github/workflows/pages.yml}"
PAGES="${PAGES/#\/repo\//$ROOT/}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$ROOT" "$PAGES" "$WORK" <<'PY'
import math, os, re, shutil, subprocess, sys
import yaml

root, pages_path, work = sys.argv[1:4]
CAP = 250000
fail = 0


def say(ok, what, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<96} {detail}")


def stop(what, detail=""):
    say(False, what, detail)
    sys.exit(1)


def load(path):
    try:
        with open(path) as fh:
            return yaml.safe_load(fh)
    except Exception as e:  # a mutant that does not parse verifies nothing
        stop("GUARD: the workflow parses", f"{path}: {e}")


def on_of(doc):
    # PyYAML reads the bare key `on` as the boolean True.
    return (doc.get(True) if True in doc else doc.get("on")) or {}


# ---- A GitHub Actions expression evaluator, for the subset an `if` here uses -----------------------------
class Unevaluable(Exception):
    pass


TOKEN = re.compile(r"""\s*(?:
    (?P<str>'(?:[^']|'')*')
  | (?P<num>-?\d+(?:\.\d+)?)
  | (?P<op>==|!=|<=|>=|&&|\|\||[()<>!,.\[\]*])
  | (?P<id>[A-Za-z_][A-Za-z0-9_-]*)
)""", re.X)


def tokenize(s):
    out, i = [], 0
    s = s.strip()
    while i < len(s):
        m = TOKEN.match(s, i)
        if not m or m.end() == i:
            raise Unevaluable(f"cannot tokenize at {s[i:i + 20]!r}")
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
        i = m.end()
        while i < len(s) and s[i].isspace():
            i += 1
    return out


def to_num(v):
    if v is None:
        return 0.0
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v.strip()) if v.strip() else 0.0
        except ValueError:
            return math.nan
    return math.nan


def truthy(v):
    if v is None or v is False:
        return False
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return v != 0 and not math.isnan(v)
    if isinstance(v, str):
        return v != ""
    return True


def equal(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.casefold() == b.casefold()   # GitHub compares strings ignoring case
    if isinstance(a, (dict, list)) or isinstance(b, (dict, list)):
        return a is b
    return to_num(a) == to_num(b)            # otherwise both sides are coerced to numbers


class Parser:
    def __init__(self, toks, ctx):
        self.t, self.i, self.ctx = toks, 0, ctx

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def take(self, val=None):
        tok = self.peek()
        if tok[0] is None or (val is not None and tok[1] != val):
            raise Unevaluable(f"expected {val!r}, got {tok[1]!r}")
        self.i += 1
        return tok

    def parse(self):
        v = self.or_()
        if self.i != len(self.t):
            raise Unevaluable(f"trailing {self.t[self.i][1]!r}")
        return v

    def or_(self):
        v = self.and_()
        while self.peek()[1] == "||":
            self.take()
            r = self.and_()
            v = v if truthy(v) else r
        return v

    def and_(self):
        v = self.cmp()
        while self.peek()[1] == "&&":
            self.take()
            r = self.cmp()
            v = r if truthy(v) else v
        return v

    def cmp(self):
        v = self.unary()
        while self.peek()[1] in ("==", "!=", "<", "<=", ">", ">="):
            op = self.take()[1]
            r = self.unary()
            if op == "==":
                v = equal(v, r)
            elif op == "!=":
                v = not equal(v, r)
            else:
                a, b = to_num(v), to_num(r)
                v = {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[op]
        return v

    def unary(self):
        if self.peek()[1] == "!":
            self.take()
            return not truthy(self.unary())
        return self.primary()

    def primary(self):
        kind, val = self.peek()
        if val == "(":
            self.take()
            v = self.or_()
            self.take(")")
            return v
        if kind == "str":
            self.take()
            return val[1:-1].replace("''", "'")
        if kind == "num":
            self.take()
            return float(val)
        if kind == "id":
            self.take()
            low = val.lower()
            if low in ("true", "false"):
                return low == "true"
            if low == "null":
                return None
            if self.peek()[1] == "(":
                return self.call(low)
            return self.path(val)
        raise Unevaluable(f"unexpected {val!r}")

    def call(self, fn):
        self.take("(")
        args = []
        if self.peek()[1] != ")":
            args.append(self.or_())
            while self.peek()[1] == ",":
                self.take()
                args.append(self.or_())
        self.take(")")
        # Status functions, for a job or step whose predecessors all succeeded.
        if fn in ("success", "always") and not args:
            return True
        if fn in ("failure", "cancelled") and not args:
            return False
        if fn in ("contains", "startswith", "endswith") and len(args) == 2:
            a, b = args
            if fn == "contains" and isinstance(a, list):
                return any(equal(x, b) for x in a)
            a, b = str(a if a is not None else "").casefold(), str(b if b is not None else "").casefold()
            return {"contains": b in a, "startswith": a.startswith(b), "endswith": a.endswith(b)}[fn]
        raise Unevaluable(f"function {fn}() is not modelled")

    def path(self, head):
        if head not in self.ctx:
            raise Unevaluable(f"context {head!r} is not modelled")
        cur, name = self.ctx[head], head
        while self.peek()[1] in (".", "["):
            if self.take()[1] == ".":
                key = self.take()[1]
            else:
                kind, key = self.take()
                if kind != "str":
                    raise Unevaluable(f"index {key!r} is not modelled")
                key = key[1:-1]
                self.take("]")
            name += f".{key}"
            if not isinstance(cur, dict) or key not in cur:
                raise Unevaluable(f"{name} is not modelled")
            cur = cur[key]
        if isinstance(cur, dict):
            raise Unevaluable(f"{name} is an object, not a value")
        return cur


def evaluate(expr, ctx):
    """The truth of a job's or step's `if:` (absent means success(), so true here)."""
    if expr is None:
        return True
    if isinstance(expr, bool):
        return expr
    s = str(expr).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", s, re.S)
    if m:
        s = m.group(1)
    return truthy(Parser(tokenize(s), ctx).parse())


def workflow_run_ctx(conclusion, release_name):
    return {"github": {
        "event_name": "workflow_run",
        "ref": "refs/heads/main",
        "ref_name": "main",
        "event": {"workflow_run": {"conclusion": conclusion, "name": release_name, "event": "push",
                                   "status": "completed", "head_branch": "v9.9.9"}},
    }}


# ---- 1. The Release run publishes the GitHub Release, then calls publish-dbdev.yml -----------------------
rel = load(os.path.join(root, ".github/workflows/release.yml"))
rel_name = rel.get("name")
rjobs = rel.get("jobs") or {}
publishes = any((s.get("uses") or "").startswith("softprops/action-gh-release")
                for s in (rjobs.get("release") or {}).get("steps") or [])
pd = rjobs.get("publish-dbdev") or {}
needs = pd.get("needs") or []
needs = [needs] if isinstance(needs, str) else needs
if publishes and "release" in needs and "publish-dbdev.yml" in (pd.get("uses") or ""):
    say(True, "LIVENESS: release.yml publishes the GitHub Release, then calls publish-dbdev.yml after it",
        f"workflow name {rel_name!r}")
else:
    stop("LIVENESS: release.yml publishes the GitHub Release, then calls publish-dbdev.yml after it",
         f"publishes={publishes}, publish-dbdev needs={needs}, uses={pd.get('uses')}")

# ---- 2. ... whose strict build refuses an over-cap package, so the run concludes failure -----------------
pub = load(os.path.join(root, ".github/workflows/publish-dbdev.yml"))
psteps = (((pub.get("jobs") or {}).get("publish") or {}).get("steps")) or []
bstep = next((s for s in psteps if s.get("name") == "Build the dbdev package"), None)
if bstep is None:
    stop("GUARD: publish-dbdev.yml has its Build the dbdev package step")
d = os.path.join(work, "publish")
os.makedirs(d)
for sub in ("scripts", "pgpm_core"):
    shutil.copytree(os.path.join(root, sub), os.path.join(d, sub))
shutil.copy(os.path.join(root, "README.md"), d)
with open(os.path.join(d, "pgpm_core", "install.sql"), "a") as fh:
    fh.write("\nselect '" + "x" * (CAP + 10000) + "' as pages_guard_padding;\n")
script = (bstep.get("run") or "").replace("${{ steps.v.outputs.version }}", "9.9.9")
if "${{" in script:
    stop("GUARD: every expression in the build step is one this guard substitutes", script.split("${{")[1][:60])
with open(os.path.join(d, ".step.sh"), "w") as fh:
    fh.write(script)
env = {k: v for k, v in os.environ.items() if k != "PGPM_DBDEV_CAP"}
p = subprocess.run(["bash", "-e", ".step.sh"], cwd=d, env=env, stdin=subprocess.DEVNULL,
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
coe = str(pd.get("continue-on-error", False)).lower() == "true"
if p.returncode != 0 and "exceed" in p.stdout and not coe:
    conclusion = "failure"
    say(True, "LIVENESS: publish-dbdev refuses an over-cap package after the publish, failing the Release run",
        f"exit {p.returncode}")
else:
    stop("LIVENESS: publish-dbdev refuses an over-cap package after the publish, failing the Release run",
         f"exit {p.returncode}, continue-on-error={coe}: {p.stdout.strip()[-160:]}")

# ---- 3. pages.yml's deploy is the job that puts a release's bundle on the install page -------------------
pages = load(pages_path)
pjobs = pages.get("jobs") or {}
deploy = pjobs.get("deploy") or {}
dsteps = deploy.get("steps") or []
fetch_i = next((i for i, s in enumerate(dsteps)
                if "gh release download" in (s.get("run") or "") and "*-bundle.sql" in (s.get("run") or "")), None)
dep_i = next((i for i, s in enumerate(dsteps) if (s.get("uses") or "").startswith("actions/deploy-pages")), None)
if fetch_i is not None and dep_i is not None and fetch_i < dep_i:
    say(True, "LIVENESS: pages.yml's deploy job downloads the latest release's bundle and deploys the site")
else:
    stop("LIVENESS: pages.yml's deploy job downloads the latest release's bundle and deploys the site",
         f"download step {fetch_i}, deploy-pages step {dep_i}")

# ---- 4. The evaluator can say no ------------------------------------------------------------------------
PRE_1169 = "${{ github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success' }}"
try:
    no = evaluate(PRE_1169, workflow_run_ctx("failure", rel_name))
    yes = evaluate(PRE_1169, workflow_run_ctx("success", rel_name))
except Unevaluable as e:
    stop("LIVENESS: the evaluator reads pages.yml's pre-#1169 condition", str(e))
if no is False and yes is True:
    say(True, "LIVENESS: the evaluator says no: the pre-#1169 condition skips a failed Release run's deploy")
else:
    stop("LIVENESS: the evaluator says no: the pre-#1169 condition skips a failed Release run's deploy",
         f"failure -> {no}, success -> {yes}")

# ---- 5. pages.yml runs after a Release run --------------------------------------------------------------
wr = on_of(pages).get("workflow_run") if isinstance(on_of(pages), dict) else None
wr = wr or {}
names = wr.get("workflows") or []
names = [names] if isinstance(names, str) else names
types = wr.get("types")
types = [types] if isinstance(types, str) else types
if rel_name in names and (types is None or "completed" in types):
    say(True, f"pages.yml runs on workflow_run when the {rel_name!r} workflow completes")
else:
    say(False, f"pages.yml runs on workflow_run when the {rel_name!r} workflow completes",
        f"workflows={names}, types={types}")
    fail = 1


# ---- 6. ... and its deploy runs, for the conclusion that run reaches and for success --------------------
def blockers(job_name, ctx, seen=()):
    """Every `if` on the path to the deploy that evaluates false: the job's, its needs', its steps'."""
    job = pjobs.get(job_name) or {}
    out = []
    if not evaluate(job.get("if"), ctx):
        out.append(f"job {job_name} if: {job.get('if')}")
    jn = job.get("needs") or []
    for n in ([jn] if isinstance(jn, str) else jn):
        if n in seen or n not in pjobs:
            raise Unevaluable(f"job {job_name} needs {n!r}, which is not a job of pages.yml")
        out += blockers(n, ctx, seen + (job_name,))
    if job_name == "deploy":
        for s in dsteps[:dep_i + 1]:
            if not evaluate(s.get("if"), ctx):
                out.append(f"step {s.get('name') or s.get('uses') or s.get('id')} if: {s.get('if')}")
    return out


for concl in (conclusion, "success"):
    what = f"a Release run that concluded {concl} redeploys the install page"
    if concl == conclusion:
        what = (f"a Release run that published the GitHub Release and concluded {concl} at publish-dbdev "
                f"redeploys the install page")
    try:
        b = blockers("deploy", workflow_run_ctx(concl, rel_name))
    except Unevaluable as e:
        stop("GUARD: every condition on the deploy's path is one this guard's evaluator models", str(e))
    if b:
        say(False, what, "; ".join(b))
        fail = 1
    else:
        say(True, what)

sys.exit(fail)
PY
rc=$?
if [ "$rc" = 0 ]; then echo "pages_deploy_after_release: PASS"; else echo "pages_deploy_after_release: FAIL"; fi
exit "$rc"
