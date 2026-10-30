#!/usr/bin/env python3
"""Print a TLC counterexample compactly: the violated property, then each step's action and, for every
variable the step changed, only the entries of it that changed.

A full TLC trace prints every variable of every state, a few hundred lines per step for the custody spec;
a reader triaging a counterexample needs the action and its effect. Functions, sequences and records are
split at their top level and compared entry by entry (one level of records inside them too).

Usage: formal/tlc.sh ... | scripts/formal/trace_diff.py
"""
import re
import sys


def split_top(body, sep):
    """Split body at sep where no bracket is open."""
    out, depth, cur, i = [], 0, '', 0
    while i < len(body):
        c = body[i]
        if body.startswith('<<', i):
            depth += 1; cur += '<<'; i += 2; continue
        if body.startswith('>>', i):
            depth -= 1; cur += '>>'; i += 2; continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        if depth == 0 and body.startswith(sep, i):
            out.append(cur.strip()); cur = ''; i += len(sep); continue
        cur += c; i += 1
    if cur.strip():
        out.append(cur.strip())
    return out


def entries(v):
    """A value as {key: text} when it is a function, sequence or record; else None."""
    v = v.strip()
    if v.startswith('<<') and v.endswith('>>'):
        return {str(i + 1): e for i, e in enumerate(split_top(v[2:-2], ','))}
    if v.startswith('(') and v.endswith(')') and ':>' in v:
        out = {}
        for e in split_top(v[1:-1], '@@'):
            k, _, x = e.partition(':>')
            out[k.strip()] = x.strip()
        return out
    if v.startswith('[') and v.endswith(']') and '|->' in v:
        out = {}
        for e in split_top(v[1:-1], ','):
            k, _, x = e.partition('|->')
            out[k.strip()] = x.strip()
        return out
    return None


def diff(old, new):
    eo, en = entries(old) if old else None, entries(new)
    if eo is None or en is None:
        return new
    parts = []
    for k, x in en.items():
        if eo.get(k) != x:
            sub = diff(eo.get(k), x) if eo.get(k) else x
            parts.append(f'{k}: {sub}')
    return '{' + '; '.join(parts) + '}'


def parse_states(text):
    states, cur, var = [], None, None
    for line in text.splitlines():
        m = re.match(r'^State (\d+): (.*)$', line)
        if m:
            cur = {'action': m.group(2), 'vars': {}}
            states.append(cur); var = None; continue
        if cur is None:
            continue
        m = re.match(r'^/\\ (\w+) = (.*)$', line)
        if m:
            var = m.group(1); cur['vars'][var] = m.group(2).strip()
        elif var and line.strip() and not re.match(r'^\d+ states generated|^The |^Finished|^Progress|^Error', line):
            cur['vars'][var] += ' ' + line.strip()
        else:
            var = None
    return states


def main():
    text = sys.stdin.read()
    for line in text.splitlines():
        if re.search(r'is violated|properties were violated|Deadlock reached|No error has been found|'
                     r'^Error:|states generated, ', line):
            print(line)
    prev = {}
    for i, st in enumerate(parse_states(text)):
        act = re.sub(r' line \d+, col \d+ to line \d+, col \d+ of module \w+', '', st['action'])
        print(f'--- {i + 1}: {act}')
        for k, v in sorted(st['vars'].items()):
            v = re.sub(r'\s+', ' ', v)
            if prev.get(k) != v:
                print(f'   {k} = {diff(prev.get(k), v) if i else v}')
        prev = {k: re.sub(r'\s+', ' ', v) for k, v in st['vars'].items()}


if __name__ == '__main__':
    main()
