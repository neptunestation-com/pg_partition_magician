#!/usr/bin/env python3
"""Measure where an install file's minified bytes are, so a size question is answered from the file.

WHY THIS EXISTS. docs/core-growth-analysis-2026-10-14.md asked where pgpm_core/install.sql's growth
since v0.6.0 came from, and built its tables from throwaway scripts that were never committed. Two of
its measurements were wrong in ways a re-run could not show, because there was nothing to re-run: it
classified error-message text by the `raise` LINE alone (4% of the added lines), when a message in this
file runs over the lines that follow it (18% of the minified bytes once the whole statement is counted);
and it reported "not copy-paste" from a line-window clone detector that cannot see the same block written
twice with different variable names, which is the only way this repository duplicates anything.
docs/core-growth-analysis-2026-10-15.md re-did the analysis with the measures below; this script is
those measures, kept, so the next size question starts from a command rather than a rebuild.

WHAT IT MEASURES, on the MINIFIED text (scripts/minify_sql.py's: what the dbdev package ships), per file:
  bytes      every byte as string literal, trailing `--` comment, whitespace or code;
  statements whole `raise`, `insert into pgpm.log` and `execute format` statements, from the keyword to
             the `;` that ends them outside parentheses and literals, so a message's continuation lines
             count as message;
  functions  one row per function or procedure, found by its dollar-quote tag (a `$f$` nested inside a
             `$$` body does not end it): minified lines, literal bytes, raise count;
  families   function bytes grouped by name pattern, with the share that is message or log text;
  toplevel   bytes outside any function body, by statement kind (upgrade `alter table`, `drop if exists`,
             data migrations, install-time calls);
  clones     the share of tokens that lie in a window of W tokens that another function also contains,
             with identifiers wildcarded (literals and numbers too), so a block copied under new variable
             names counts: the measure the line-window detector lacked;
  messages   raise/notice/warning and `message = format(...)` text: count, bytes, median, and the bytes
             inside a 12-word phrase that occurs in two or more messages.

A SPEC is a path, or `<git rev>:<path>` (read with `git show`), so two versions compare in one command:
  scripts/core_growth.py report v0.6.0:pgpm_core/install.sql pgpm_core/install.sql
  scripts/core_growth.py functions pgpm_core/install.sql --top 40
  scripts/core_growth.py clones pgpm_core/install.sql --window 20
  scripts/core_growth.py --selftest

`--selftest` runs every measure on an embedded fixture with known answers, and then on a re-broken copy
of it, and requires each measure to move: a statement counter that counted only the `raise` line, a clone
measure blind to renamed copies, or a function scanner that a nested dollar quote ends early, fails here
rather than quietly shaping the next analysis. The lint workflow runs it before the report.
"""
import os
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from minify_sql import minify  # noqa: E402

CREATE_RE = re.compile(r"^\s*create\s+(?:or\s+replace\s+)?(?:function|procedure)\s+([\w.]+)", re.I)
TAG_RE = re.compile(r"\$[A-Za-z_]*\$")
STMT_RE = {
    "raise exception": r"raise\s+exception\b",
    "raise notice/warning": r"raise\s+(?:notice|warning|debug|log)\b",
    "insert into pgpm.log": r"insert\s+into\s+pgpm\.log\b",
    "execute format": r"execute\s+format\s*\(",
}
# Name patterns, first match wins. "other" is what none of them name.
FAMILIES = [
    ("regrain", r"regrain"),
    ("transmute/untransmute", r"transmute"),
    ("retire/retain/detach/adopt", r"retire|retain|detach|adopt|chunk|disown|vouch"),
    ("refuse", r"refuse"),
    ("contract", r"_contract"),
    ("surface", r"_surface_"),
    ("scratch", r"scratch|capture_definer"),
    ("obtain/extend/maintain/schedule", r"obtain|extend|maintain|schedule|_create_partition|_part_name|_grid|frontier|_cell"),
    ("identity/sequence/acl", r"_identity|_seq|_acl"),
    ("text_time/uuid/encode", r"text_time|radix|uuid|_encode|_decode|_ts_|_native"),
    ("snapshot", r"snapshot"),
    ("status/progress/impact", r"status|progress|impact|observe"),
    ("archive", r"archive"),
    ("write_block", r"write_block"),
    ("fk", r"_fk|fks\b|crossing_keys"),
]
# Tokens kept verbatim by the clone measure: SQL and plpgsql keywords and catalog names, so a window
# holds the STRUCTURE of a block. Anything else that looks like an identifier becomes ID.
KEEP = set("""
select from where and or not in is null into for loop end if then else elsif begin exception when raise
perform execute format return returns declare insert update delete values set on as join left cross lateral
exists case coalesce array any all order by limit distinct group having union with recursive using do
language plpgsql sql stable immutable volatile create or replace function procedure table drop alter add
constraint primary key unique index foreign references check default true false text name int bigint boolean
oid regclass regprocedure record void setof out inout found row_count get diagnostics continue exit while
foreach array_agg string_agg unnest ordinality quote_ident quote_literal to_regclass pg_class pg_namespace
pg_attribute pg_constraint pg_index pg_inherits pg_depend pg_type pg_trigger pg_policy pg_proc pg_roles
pg_publication pg_publication_rel pg_tablespace pg_locks pg_stat_activity relname nspname attname attnum
conname contype conrelid confrelid conindid indexrelid indrelid inhrelid inhparent relnamespace relkind
attrelid attisdropped relowner proowner proname tgname tgrelid polname polrelid relacl now clock_timestamp
current_setting pg_backend_pid lock mode share access exclusive row commit rollback
""".split())
TOKEN_RE = re.compile(r"'(?:[^']|'')*'|\$[A-Za-z_]*\$|\d+(?:\.\d+)?|[A-Za-z_][\w.]*|%[sIL]|[^\s\w]")
PHRASE_WORDS = 12


def load(spec):
    """A SPEC's minified text: a path, or `<rev>:<path>` through git show."""
    if os.path.exists(spec):
        with open(spec) as fh:
            raw = fh.read()
    elif ":" in spec:
        raw = subprocess.run(["git", "show", spec], check=True, capture_output=True, text=True).stdout
    else:
        raise SystemExit(f"core_growth: {spec}: no such file, and not a <rev>:<path>")
    out, _dropped = minify(raw, spec)
    return out


# ---- measures -----------------------------------------------------------------------------------

def classify_bytes(src):
    """Every byte of the minified text, by what it is lexically."""
    n, i = len(src), 0
    c = Counter()
    while i < n:
        ch = src[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if src[j] == "'":
                    if j + 1 < n and src[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            c["literal"] += j - i + 1
            i = j + 1
        elif ch == "-" and i + 1 < n and src[i + 1] == "-":
            j = src.find("\n", i)
            j = n if j < 0 else j
            c["trailing comment"] += j - i
            i = j
        else:
            c["whitespace" if ch in " \t\n" else "code"] += 1
            i += 1
    c["total"] = n
    return c


def statement_end(src, i):
    """Index just past the `;` that ends the statement starting at i (depth 0, outside literals)."""
    depth, j, n = 0, i, len(src)
    while j < n:
        ch = src[j]
        if ch == "'":
            j += 1
            while j < n:
                if src[j] == "'":
                    if j + 1 < n and src[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == ";" and depth == 0:
            return j + 1
        j += 1
    return n


def statements(src):
    """{kind: (count, bytes, median)} for whole statements of each kind."""
    out = {}
    for kind, pat in STMT_RE.items():
        sizes = []
        for m in re.finditer(r"(?im)^\s*" + pat, src):
            sizes.append(statement_end(src, m.start()) - m.start())
        out[kind] = (len(sizes), sum(sizes), int(statistics.median(sizes)) if sizes else 0)
    return out


def functions(src):
    """[(name, first line index, last line index, text)] for every function/procedure, by dollar tag."""
    lines = src.split("\n")
    out, i, n = [], 0, len(lines)
    while i < n:
        m = CREATE_RE.match(lines[i])
        if not m:
            i += 1
            continue
        name, start, tag, j = m.group(1), i, None, i
        # the body's tag: the first dollar quote on or after the create line
        while j < n and tag is None:
            t = TAG_RE.search(lines[j])
            if t:
                tag = t.group(0)
                if tag in lines[j][t.end():]:  # opened and closed on one line (a one-line sql body)
                    break
            j += 1
        else:
            # j is the line after the opener (the loop advanced past it): the closer may be right there
            while j < n and tag not in lines[j]:
                j += 1
        end = min(j, n - 1)
        out.append((name, start, end, "\n".join(lines[start:end + 1]) + "\n"))
        i = end + 1
    return out


def family_of(name):
    for fam, pat in FAMILIES:
        if re.search(pat, name):
            return fam
    return "other"


def families(src):
    """{family: (bytes, message bytes, function count)}."""
    out = defaultdict(lambda: [0, 0, 0])
    for name, _s, _e, text in functions(src):
        msg = 0
        for m in re.finditer(r"(?im)^\s*(?:raise\s+(?:exception|notice|warning)|insert\s+into\s+pgpm\.log)\b", text):
            msg += statement_end(text, m.start()) - m.start()
        row = out[family_of(name)]
        row[0] += len(text)
        row[1] += msg
        row[2] += 1
    return {k: tuple(v) for k, v in out.items()}


def toplevel(src):
    """Bytes outside every function body, by statement kind (a line's first words)."""
    lines = src.split("\n")
    inside = set()
    for _n, s, e, _t in functions(src):
        inside.update(range(s, e + 1))
    out = Counter()
    for i, ln in enumerate(lines):
        if i in inside or not ln.strip():
            continue
        s = ln.strip().lower()
        kind = ("do block" if s.startswith("do $") else
                "drop if exists" if s.startswith("drop ") else
                "alter table (upgrade)" if s.startswith("alter table") else
                "create table/index" if s.startswith(("create table", "create index", "create unique")) else
                "create view/type" if s.startswith(("create or replace view", "create view", "create type")) else
                "grant/revoke" if s.startswith(("grant", "revoke")) else
                "data migration" if s.startswith(("update ", "insert ", "delete ")) else
                "install-time call" if s.startswith("select ") else
                "other")
        out[kind] += len(ln) + 1
    out["total"] = sum(out.values())
    return out


def idioms(src):
    """{idiom: (count, bytes)} for call shapes and queries this file writes out in full at every site."""
    call = r"\((?:[^()]|\([^()]*\))*\)"
    pats = {
        "pgpm._encode(...) call": r"pgpm\._encode" + call,
        "pgpm._decode(...) call": r"pgpm\._decode" + call,
        "pgpm._grid_floor(...) call": r"pgpm\._grid_floor" + call,
        "pgpm._grid_next(...) call": r"pgpm\._grid_next" + call,
        "pgpm._part_name(...) call": r"pgpm\._part_name" + call,
        "pgpm._native_gt(...) call": r"pgpm\._native_gt" + call,
        "cfg.text_time_* seven-column tuple": r"cfg\.text_time_prefix, cfg\.text_time_width, cfg\.text_time_radix, "
                                              r"cfg\.text_time_unit, cfg\.text_time_alphabet, cfg\.text_time_discard_bits, "
                                              r"cfg\.text_time_epoch",
        "config row load": r"select \* into (?:strict )?cfg from pgpm\.config where parent_table = \w+",
        "schema and name lookup": r"select n\.nspname, c\.relname(?:, c\.relkind)? into [^\n]*\n?[^\n]*"
                                  r"from pg_class c join pg_namespace n on n\.oid = c\.relnamespace where c\.oid = \w+",
        "naming statement held-name scaffold": r"when internal_error then\s*\n\s*if sqlerrm = 'tuple concurrently updated'",
        "pgpm.part copies-in-range query": r"from pgpm\.part where parent_table = %L::regclass and not attached",
        "_refuse_null_arguments call": r"perform pgpm\._refuse_null_arguments" + call,
        "lock_timeout set": r"perform set_config\('lock_timeout'",
    }
    return {k: (len(ms), sum(len(m) for m in ms)) for k, ms in ((k, re.findall(p, src)) for k, p in pats.items())}


def tokens(text):
    out = []
    for m in TOKEN_RE.finditer(text):
        t = m.group(0)
        if t.startswith("'"):
            out.append("LIT")
        elif t[0].isdigit():
            out.append("NUM")
        elif re.match(r"[A-Za-z_]", t):
            tl = t.lower()
            out.append(tl if tl in KEEP or tl.startswith("pgpm.") else "ID")
        else:
            out.append(t)
    return out


def clones(src, window):
    """(shared tokens, total tokens, {function: (shared, total)}): tokens in a W-window another function has."""
    toks = {}
    for name, _s, _e, text in functions(src):
        toks[name + "#" + str(len(toks))] = tokens(text)
    owners = defaultdict(set)
    for key, t in toks.items():
        fn = key.split("#")[0]
        for i in range(len(t) - window + 1):
            owners[tuple(t[i:i + window])].add(fn)
    shared, total, per = 0, 0, {}
    for key, t in toks.items():
        mark = [False] * len(t)
        for i in range(len(t) - window + 1):
            if len(owners[tuple(t[i:i + window])]) > 1:
                for j in range(i, i + window):
                    mark[j] = True
        s = sum(mark)
        shared += s
        total += len(t)
        per[key.split("#")[0]] = (s, len(t))
    return shared, total, per


def messages(src):
    """(texts, bytes inside a PHRASE_WORDS-word phrase that two or more messages share)."""
    texts = [m.group(1) for m in re.finditer(r"(?is)raise\s+(?:exception|notice|warning)\s+'((?:[^']|'')*)'", src)]
    texts += [m.group(1) for m in re.finditer(r"(?is)message\s*=\s*format\(\s*'((?:[^']|'')*)'", src)]
    words = [re.sub(r"\s+", " ", t).split(" ") for t in texts]
    seen = Counter()
    for w in words:
        for g in {tuple(w[j:j + PHRASE_WORDS]) for j in range(len(w) - PHRASE_WORDS + 1)}:
            seen[g] += 1
    dup = 0
    for w in words:
        mark = [False] * len(w)
        for j in range(len(w) - PHRASE_WORDS + 1):
            if seen[tuple(w[j:j + PHRASE_WORDS])] > 1:
                for k in range(j, j + PHRASE_WORDS):
                    mark[k] = True
        dup += sum(len(w[k]) + 1 for k in range(len(w)) if mark[k])
    return texts, dup


# ---- reports ------------------------------------------------------------------------------------

def pct(a, b):
    return f"{a / b:.1%}" if b else "n/a"


def report(specs):
    data = [(s, load(s)) for s in specs]
    print("== bytes (minified)")
    for s, src in data:
        c = classify_bytes(src)
        print(f"  {s}: total {c['total']:,}  literal {c['literal']:,} ({pct(c['literal'], c['total'])})  "
              f"trailing comment {c['trailing comment']:,}  whitespace {c['whitespace']:,}  "
              f"code {c['code']:,} ({pct(c['code'], c['total'])})")
    print("== whole statements")
    for s, src in data:
        tot = len(src)
        st = statements(src)
        parts = [f"{k}: n={n} bytes={b:,} ({pct(b, tot)}) median={md}" for k, (n, b, md) in st.items()]
        msg = st["raise exception"][1] + st["raise notice/warning"][1] + st["insert into pgpm.log"][1]
        print(f"  {s}:\n    " + "\n    ".join(parts) + f"\n    message+log text together: {msg:,} ({pct(msg, tot)})")
    print("== functions")
    for s, src in data:
        fs = functions(src)
        print(f"  {s}: {len(fs)} functions, {sum(t.count(chr(10)) for *_, t in fs):,} minified lines, "
              f"{sum(len(t) for *_, t in fs):,} bytes")
    print("== families (bytes, of which message or log text)")
    rows = [(s, families(src)) for s, src in data]
    names = sorted({k for _s, f in rows for k in f}, key=lambda k: -rows[-1][1].get(k, (0,))[0])
    for k in names:
        cells = []
        for s, f in rows:
            b, m, n = f.get(k, (0, 0, 0))
            cells.append(f"{b:8,} ({n:3d} fns, msg {pct(m, b):>5})")
        print(f"  {k:32s} " + "  |  ".join(cells))
    print("== top level (outside every function body)")
    for s, src in data:
        t = toplevel(src)
        print(f"  {s}: total {t['total']:,}  " + "  ".join(f"{k} {v:,}" for k, v in t.most_common() if k != "total"))
    print("== idioms written out in full at every site (count, bytes)")
    rows = [(s, idioms(src)) for s, src in data]
    for k in rows[-1][1]:
        print(f"  {k:38s} " + "  |  ".join(f"{n:4d} x {b:7,}" for _s, d in rows for n, b in [d[k]]))
    print("== clones: tokens in a window another function also contains, identifiers wildcarded")
    base_names = {f[0] for f in functions(data[0][1])} if len(data) > 1 else set()
    for w in (12, 16, 20):
        cells = []
        for s, src in data:
            sh, tot, per = clones(src, w)
            cells.append(f"{s}: {sh:,}/{tot:,} ({pct(sh, tot)})")
            if base_names and s != data[0][0]:
                # the added code itself: functions whose name the first spec does not have, measured
                # against everything in this spec (an edited function's added tokens stay with its old ones)
                new = [v for k, v in per.items() if k not in base_names]
                old = [v for k, v in per.items() if k in base_names]
                cells.append(f"[new fns {sum(a for a, _ in new):,}/{sum(b for _, b in new):,} "
                             f"({pct(sum(a for a, _ in new), sum(b for _, b in new))}); "
                             f"fns also in {data[0][0].split(':')[0]} {sum(a for a, _ in old):,}/{sum(b for _, b in old):,} "
                             f"({pct(sum(a for a, _ in old), sum(b for _, b in old))})]")
        print(f"  window {w}: " + "   ".join(cells))
    print("== messages (raise text and `message = format` text)")
    for s, src in data:
        texts, dup = messages(src)
        sizes = sorted(len(t) for t in texts)
        med = sizes[len(sizes) // 2] if sizes else 0
        p90 = sizes[int(len(sizes) * 0.9)] if sizes else 0
        print(f"  {s}: n={len(texts)} bytes={sum(sizes):,} median={med} p90={p90} max={sizes[-1] if sizes else 0}  "
              f"in a {PHRASE_WORDS}-word phrase shared by two or more messages: {dup:,}")
    return 0


def report_functions(spec, top):
    src = load(spec)
    rows = []
    for name, _s, _e, text in functions(src):
        lit = sum(len(x) for x in re.findall(r"'(?:[^']|'')*'", text))
        raises = len(re.findall(r"(?im)^\s*raise\s+(?:exception|notice|warning)", text))
        rows.append((text.count("\n"), len(text), lit, raises, name))
    rows.sort(reverse=True)
    print(f"{spec}: {len(rows)} functions")
    for ln, b, lit, r, name in rows[:top]:
        print(f"  {ln:5d} lines {b:7,} bytes  literal {lit:6,}  raise {r:3d}  {name}")
    return 0


def report_clones(spec, window):
    src = load(spec)
    sh, tot, per = clones(src, window)
    print(f"{spec}: window {window}: {sh:,}/{tot:,} tokens ({pct(sh, tot)}) shared with another function")
    for name, (s, t) in sorted(per.items(), key=lambda x: -x[1][0])[:15]:
        print(f"  {s:6,}/{t:6,}  {name}")
    return 0


# ---- selftest -----------------------------------------------------------------------------------

FIXTURE = """-- a full-line comment the minifier drops
create table if not exists pgpm.t (a int);
alter table pgpm.t add column if not exists b int;
drop function if exists pgpm.gone(int);
create or replace function pgpm._regrain_alpha(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare v_nsp name; v_rel name; v_n int;
begin
select n.nspname, c.relname into v_nsp, v_rel
from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
select count(*) into v_n from pgpm.part where parent_table = p_parent and child_name = p_child;
if v_n = 0 then
raise exception 'pg_partition_magician: % is not a partition pgpm records for %, so there is nothing to do here',
p_child, p_parent; -- a trailing comment
end if;
insert into pgpm.log (parent_table, action) values (p_parent, 'alpha');
end;
$$;
create or replace function pgpm._transmute_beta(q_tbl regclass, q_kid name)
returns void language plpgsql as $$
declare w_nsp name; w_rel name; w_n int;
begin
select n.nspname, c.relname into w_nsp, w_rel
from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = q_tbl;
select count(*) into w_n from pgpm.part where parent_table = q_tbl and child_name = q_kid;
if w_n = 0 then
raise exception 'pg_partition_magician: % is not a partition pgpm records for %, so there is nothing beta can do',
q_kid, q_tbl;
end if;
end;
$$;
create or replace function pgpm.gamma(p regclass)
returns text language plpgsql as $$
begin
execute format($f$ insert into %s values (1) $f$, p::text);
return 'done';
end;
$$;
create or replace function pgpm.delta() returns int language sql as $$ select 1 $$;
create or replace function pgpm.epsilon() returns int language sql as $$
select 2 $$;
create or replace function pgpm.zeta() returns int language sql as $$
select 3;
$$;
select pgpm.delta();
"""


def selftest():
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)

    src, _ = minify(FIXTURE, "<fixture>")
    # functions: four, found by tag; gamma's nested $f$ does not end it early; delta is one line
    fs = functions(src)
    check([f[0] for f in fs] == ["pgpm._regrain_alpha", "pgpm._transmute_beta", "pgpm.gamma", "pgpm.delta",
                                 "pgpm.epsilon", "pgpm.zeta"],
          f"functions: names {[f[0] for f in fs]}")
    gamma = next(f for f in fs if f[0] == "pgpm.gamma")
    check("return 'done'" in gamma[3], "functions: a nested $f$ ended pgpm.gamma early")
    by = {f[0]: f for f in fs}
    check(by["pgpm.delta"][1] == by["pgpm.delta"][2], "functions: the one-line sql body did not end on its own line")
    # epsilon closes on the line right after its opener; a scanner that skips that line swallows zeta into it
    check(by["pgpm.epsilon"][2] == by["pgpm.epsilon"][1] + 1 and "select 3" not in by["pgpm.epsilon"][3],
          f"functions: a closer on the line after the opener was skipped: {by['pgpm.epsilon'][1:3]}")
    check(by["pgpm.zeta"][2] == by["pgpm.zeta"][1] + 2, f"functions: zeta spans {by['pgpm.zeta'][1:3]}")
    # statements: the whole raise, continuation line included, not the raise line alone
    st = statements(src)
    first = next(m for m in re.finditer(r"(?im)^\s*raise exception", src))
    line_only = src.find("\n", first.start()) - first.start()
    whole = statement_end(src, first.start()) - first.start()
    check(whole > line_only and st["raise exception"][0] == 2 and st["raise exception"][1] >= 2 * line_only,
          f"statements: raise bytes {st['raise exception']} should cover the continuation line ({whole} > {line_only})")
    check(st["insert into pgpm.log"][0] == 1 and st["execute format"][0] == 1, f"statements: {st}")
    # bytes: the literal count moves by exactly what a literal grows by
    c0 = classify_bytes(src)
    grown, _ = minify(FIXTURE.replace("'alpha'", "'alpha-longer'"), "<fixture>")
    c1 = classify_bytes(grown)
    check(c1["literal"] - c0["literal"] == len("-longer"), f"bytes: literal delta {c1['literal'] - c0['literal']}")
    check(c0["trailing comment"] == len("-- a trailing comment"), f"bytes: trailing comment {c0['trailing comment']}")
    check(sum(v for k, v in c0.items() if k != "total") == c0["total"], "bytes: classes do not sum to total")
    # families: alpha and beta land in their families, gamma and delta in other, and the sum is every function byte
    fam = families(src)
    check(set(fam) == {"regrain", "transmute/untransmute", "other"} and fam["other"][2] == 4, f"families: {fam}")
    check(sum(v[0] for v in fam.values()) == sum(len(f[3]) for f in fs), "families: bytes do not sum to function bytes")
    check(fam["regrain"][1] > 0 and fam["transmute/untransmute"][1] > 0, "families: message share missing")
    # toplevel: the drop, the alter, the create table and the install-time select, none of the bodies
    tl = toplevel(src)
    check(tl["drop if exists"] == len("drop function if exists pgpm.gone(int);") + 1, f"toplevel: drop {tl['drop if exists']}")
    check(tl["alter table (upgrade)"] > 0 and tl["create table/index"] > 0 and tl["install-time call"] > 0, f"toplevel: {tl}")
    check("other" not in tl, f"toplevel: a function line leaked out as top level: {tl}")
    # clones: beta is alpha under other names and must register; reworded, it must not
    sh, tot, per = clones(src, 12)
    check(per["pgpm._transmute_beta"][0] > 0 and per["pgpm._regrain_alpha"][0] > 0, f"clones: renamed copy not seen {per}")
    check(per["pgpm.gamma"][0] == 0, f"clones: gamma shares nothing yet reads {per['pgpm.gamma']}")
    reworded = FIXTURE.replace("select count(*) into w_n from pgpm.part where parent_table = q_tbl and child_name = q_kid;",
                               "w_n := (select count(*) from pgpm.part p where p.child_name = q_kid);")
    reworded = reworded.replace("select n.nspname, c.relname into w_nsp, w_rel\nfrom pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = q_tbl;",
                                "w_nsp := 'x'; w_rel := 'y';")
    rsrc, _ = minify(reworded, "<fixture>")
    _sh2, _tot2, per2 = clones(rsrc, 12)
    check(per2["pgpm._transmute_beta"][0] < per["pgpm._transmute_beta"][0], "clones: rewording the copy did not lower its share")
    # messages: alpha and beta share a 12-word phrase; reword beta's and the shared bytes drop to zero
    texts, dup = messages(src)
    check(len(texts) == 2 and dup > 0, f"messages: n={len(texts)} dup={dup}")
    _t2, dup2 = messages(minify(FIXTURE.replace("is not a partition pgpm records for %, so there is nothing beta can do",
                                                "is unknown to beta"), "<f>")[0])
    check(dup2 == 0, f"messages: reworded phrase still counted as shared ({dup2})")
    # idioms: the schema-and-name lookup is written in alpha and in beta; the config load in neither
    idm = idioms(src)
    check(idm["schema and name lookup"][0] == 2, f"idioms: lookup count {idm['schema and name lookup']}")
    check(idm["config row load"][0] == 0, f"idioms: config load count {idm['config row load']}")

    if fails:
        for f in fails:
            print(f"FAIL  {f}")
        return 1
    print("core_growth selftest: ok")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[1], argv[2:]
    if cmd == "report":
        return report(rest)
    if cmd == "functions":
        top = int(rest[rest.index("--top") + 1]) if "--top" in rest else 40
        return report_functions(rest[0], top)
    if cmd == "clones":
        window = int(rest[rest.index("--window") + 1]) if "--window" in rest else 20
        return report_clones(rest[0], window)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
