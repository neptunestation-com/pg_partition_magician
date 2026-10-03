#!/usr/bin/env python3
"""coverage.py --tree <review tree> --slices <slices.json> --claims <claims dir> [--threshold 0.9] [--out <json>]
   coverage.py --selftest

Score each finder's COVERAGE LEDGER against its slice: did the finder read every unit it owns? A unit is a
function or procedure of an install.sql slice (`create or replace function|procedure <schema>.<name>(`), or
a file of a files slice (tests/, bench/, docs/, scripts/). The ledger is `<claims>/<finder>/coverage.md`,
one line per unit: `- <unit> | read: yes|no | <notes>` (the unit as `schema.name` for SQL, the repo path
for files). Prints one row per finder (units, read, coverage, the unread units) and exits 1 when any
finder's coverage is below the threshold, so the coordinator re-runs or splits that slice BEFORE
classification: a missed seed in an unread unit says the slice was not read, not that reading missed it,
and passes 6 and 7 could not tell the two apart (recall 0.56 twice, with the finders' null-results files
naming the seeded functions as "sound" in one case and not at all in the others).

slices.json: {"F1": {"files": ["pgpm_core/install.sql:1-2500", "pgpm_core/uninstall.sql"]},
              "F9": {"files": ["bench/*.sh", "bench/mutations/*.py"], "kind": "files"}, ...}
`kind` defaults to "sql" when every file is an .sql under pgpm_*/ and to "files" otherwise. A line range
on an .sql file keeps only the units whose `create` line falls inside it. The ledger's `read:` answer is
what is scored; notes are for the record. A unit listed twice counts once; a unit the ledger names that
the slice does not contain is reported (it is usually a slice boundary the coordinator drew wrong).
"""
import argparse, glob, json, os, re, sys, tempfile

UNIT_RE = re.compile(r'^\s*create\s+(?:or\s+replace\s+)?(?:function|procedure)\s+([a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)\s*\(', re.I)
LEDGER_RE = re.compile(r'^\s*[-*]\s+`?([^`|]+?)`?\s*\|\s*read:\s*(yes|no)\b', re.I)


def sql_units(path, lo=None, hi=None):
    units = []
    with open(path, errors='replace') as f:
        for n, line in enumerate(f, 1):
            if lo is not None and (n < lo or n > hi):
                continue
            m = UNIT_RE.match(line)
            if m:
                units.append(m.group(1).lower())
    return units


def slice_units(tree, spec):
    files = spec.get('files', [])
    kind = spec.get('kind')
    if kind is None:
        kind = 'sql' if files and all(re.match(r'^pgpm_[a-z]+/.*\.sql(:\d+-\d+)?$', f) for f in files) else 'files'
    units = []
    for f in files:
        lo = hi = None
        m = re.match(r'^(.*?):(\d+)-(\d+)$', f)
        if m:
            f, lo, hi = m.group(1), int(m.group(2)), int(m.group(3))
        for p in sorted(glob.glob(os.path.join(tree, f), recursive=True)):
            rel = os.path.relpath(p, tree)
            if kind == 'sql':
                units += sql_units(p, lo, hi)
            else:
                units.append(rel)
    seen, out = set(), []
    for u in units:
        if u not in seen:
            seen.add(u); out.append(u)
    return kind, out


def read_ledger(path):
    read, unread = set(), set()
    if not os.path.exists(path):
        return None, None
    with open(path, errors='replace') as f:
        for line in f:
            m = LEDGER_RE.match(line)
            if not m:
                continue
            unit = m.group(1).strip().lower()
            (read if m.group(2).lower() == 'yes' else unread).add(unit)
    return read, unread


def score(tree, slices, claims, threshold):
    rows, worst = [], 1.0
    for fid, spec in sorted(slices.items()):
        kind, units = slice_units(tree, spec)
        read, unread = read_ledger(os.path.join(claims, fid, 'coverage.md'))
        if read is None:
            rows.append({'finder': fid, 'kind': kind, 'units': len(units), 'read': 0, 'coverage': 0.0,
                         'unread': units, 'extra': [], 'ledger': 'missing'})
            worst = 0.0
            continue
        uset = set(units)
        hit = [u for u in units if u in read]
        missing = [u for u in units if u not in read]
        extra = sorted((read | unread) - uset)
        cov = (len(hit) / len(units)) if units else 1.0
        worst = min(worst, cov)
        rows.append({'finder': fid, 'kind': kind, 'units': len(units), 'read': len(hit), 'coverage': round(cov, 3),
                     'unread': missing, 'extra': extra, 'ledger': 'present'})
    return rows, worst


def render(rows, threshold):
    out = ['finder  kind   units  read  coverage  verdict']
    for r in rows:
        verdict = 'ledger missing' if r['ledger'] == 'missing' else ('ok' if r['coverage'] >= threshold else f'BELOW {threshold}: re-run or split')
        out.append(f"{r['finder']:<7} {r['kind']:<6} {r['units']:>5} {r['read']:>5}  {r['coverage']:>8.2f}  {verdict}")
        if r['unread'] and r['ledger'] == 'present':
            out.append('        unread: ' + ', '.join(r['unread'][:12]) + (' ...' if len(r['unread']) > 12 else ''))
        if r['extra']:
            out.append('        in the ledger but not in the slice: ' + ', '.join(r['extra'][:8]))
    return '\n'.join(out)


def selftest():
    with tempfile.TemporaryDirectory() as d:
        tree = os.path.join(d, 'tree'); os.makedirs(os.path.join(tree, 'pgpm_core')); os.makedirs(os.path.join(tree, 'bench'))
        with open(os.path.join(tree, 'pgpm_core', 'install.sql'), 'w') as f:
            f.write('create or replace function pgpm.a() returns int language sql as $$ select 1 $$;\n'
                    'select 1;\n'
                    'CREATE OR REPLACE PROCEDURE pgpm.b(p int) language plpgsql as $$ begin end $$;\n'
                    'create function pgpm.c() returns int language sql as $$ select 1 $$;\n'
                    '-- create or replace function pgpm.not_a_unit( : a commented-out create is not a unit\n')
        for name in ('g1.sh', 'g2.sh'):
            open(os.path.join(tree, 'bench', name), 'w').write('#!/bin/sh\n')
        claims = os.path.join(d, 'claims'); os.makedirs(os.path.join(claims, 'F1')); os.makedirs(os.path.join(claims, 'F2'))
        open(os.path.join(claims, 'F1', 'coverage.md'), 'w').write(
            '# ledger\n- pgpm.a | read: yes | identity: fine\n- `pgpm.b` | read: no | out of budget\n- pgpm.zzz | read: yes | not in slice\n')
        open(os.path.join(claims, 'F2', 'coverage.md'), 'w').write('- bench/g1.sh | read: yes |\n- bench/g2.sh | read: yes |\n')
        slices = {'F1': {'files': ['pgpm_core/install.sql:1-4']}, 'F2': {'files': ['bench/*.sh'], 'kind': 'files'}, 'F3': {'files': ['pgpm_core/install.sql']}}
        rows, worst = score(tree, slices, claims, 0.9)
        by = {r['finder']: r for r in rows}
        assert by['F1']['units'] == 3 and by['F1']['read'] == 1 and by['F1']['unread'] == ['pgpm.b', 'pgpm.c'], by['F1']
        assert by['F1']['extra'] == ['pgpm.zzz'], by['F1']
        assert by['F2']['coverage'] == 1.0 and by['F2']['kind'] == 'files', by['F2']
        assert by['F3']['ledger'] == 'missing' and by['F3']['units'] == 3, by['F3']   # the commented create is not a unit
        assert worst == 0.0
        # the line range keeps only units whose create line is inside it
        assert slice_units(tree, {'files': ['pgpm_core/install.sql:3-3']})[1] == ['pgpm.b']
        # a ledger that reads everything passes the threshold
        open(os.path.join(claims, 'F1', 'coverage.md'), 'w').write('- pgpm.a | read: yes |\n- pgpm.b | read: yes |\n- pgpm.c | read: yes |\n')
        rows, worst = score(tree, {'F1': slices['F1']}, claims, 0.9)
        assert rows[0]['coverage'] == 1.0 and worst == 1.0
        text = render(rows, 0.9); assert 'ok' in text
    print('coverage.py selftest: PASS (sql units with ranges, files slices, missing ledger, extra units, threshold)')


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--tree'); ap.add_argument('--slices'); ap.add_argument('--claims')
    ap.add_argument('--threshold', type=float, default=0.9); ap.add_argument('--out')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args(argv)
    if a.selftest:
        selftest(); return 0
    if not (a.tree and a.slices and a.claims):
        ap.error('--tree, --slices and --claims are required (or --selftest)')
    slices = json.load(open(a.slices))
    rows, worst = score(a.tree, slices, a.claims, a.threshold)
    print(render(rows, a.threshold))
    if a.out:
        json.dump({'threshold': a.threshold, 'rows': rows}, open(a.out, 'w'), indent=1)
    low = [r['finder'] for r in rows if r['ledger'] == 'missing' or r['coverage'] < a.threshold]
    if low:
        print(f"coverage below {a.threshold} (or no ledger) for: {', '.join(low)}; re-run or split these slices before classifying")
        return 1
    print('coverage: every slice at or above the threshold')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
