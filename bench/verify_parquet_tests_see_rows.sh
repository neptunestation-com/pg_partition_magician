#!/usr/bin/env bash
# Prove that the independent-reader checks of the Parquet writer (scripts/verify_parquet.py and
# scripts/verify_parquet_range.py) FAIL a file that holds a row its table does not, or whose tied rows have
# their columns paired wrongly, by running their own test functions against a writer that does exactly that.
#
# WHY THIS GUARD EXISTS (issue #1388, review pass 13 F8-05 and F8-03). The two scripts are the only check of
# archive._pq_to_parquet and _pq_to_parquet_range that runs outside the encoder (pyarrow and DuckDB), and two
# of their shapes passed a writer that was wrong:
#   * verify_parquet.py's test_timestamptz, test_uuid and test_uuid_nullable, and test_timestamp_naive beside
#     them, compared the file's rows one by one over the EXPECTED list and never compared the counts (check()
#     does), so a file holding a spurious extra row printed PASS;
#   * verify_parquet_range.py's test_range_keyless_archived says rows tied on the control column keep their own
#     values in every column, but its fixture had one column besides the control, so a writer that read each
#     column in its own order (the #462 misalignment) wrote the same rows a correct one does.
# Each comparison now asks the counts first (same_count, which check() shares), and the keyless fixture's tied
# rows differ in two columns, tag and n.
#
# HOW. No database and no Parquet reader: each test function is run as it is, with the four things it reaches
# outside itself stood in for (bench/discriminate.sh hands this guard the core container, where neither
# pgpm_archive nor pyarrow is). run() is a small in-memory table store that answers the statements these tests
# send; the writer (to_parquet_bytes / to_parquet_range_bytes) and the two readers (read_with_both_readers) are
# replaced by one that hands back the table's rows as a writer under test would have written them; and
# pyarrow.parquet and duckdb answer test_timestamp_naive's schema questions as the real module's file does.
#   CONTROL   each test passes a FAITHFUL writer, the table's rows exactly (so the stand-ins are right, and a
#             failure below is about the rows);
#   DEFECT    each verify_parquet.py test fails a writer that adds a copy of the first row (EXTRA), and one that
#             drops the last (MISSING; a raise counts, as main() counts it); test_range_keyless_archived fails a
#             writer that rotates each non-control column of a run of tied rows by its own position (MISALIGN);
#   LIVENESS  each test ran over its table (rows inserted, the writer called on them); check() of each file
#             fails a surplus and a deficit; and MISALIGN, given a tie whose rows differ in two columns, writes
#             a row the source does not hold, so a keyless test that passes it is blind, not lucky.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each a site's pre-fix shape:
#   verify_parquet_timestamptz_rows_uncounted   -- test_timestamptz walks the expected rows, no count
#   verify_parquet_uuid_rows_uncounted          -- test_uuid the same
#   verify_parquet_uuid_nullable_rows_uncounted -- test_uuid_nullable the same
#   verify_parquet_naive_rows_uncounted         -- test_timestamp_naive the same
#   verify_parquet_range_keyless_one_column     -- the keyless fixture's tied rows differ in tag alone
#
# Usage: verify_parquet_tests_see_rows.sh <container> <db> [script.py]
# The container and database are accepted for the shape bench/discriminate.sh calls every guard with and are
# not used. With no third argument both scripts are taken from this checkout. A third argument is a copy of ONE
# of them (discriminate.sh hands it a mutant, under a .sql name, at a /repo/ path that is mapped to this
# checkout); which one is read from the tests it defines, and the other is taken from the checkout.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_C="${1:?container}"; _DB="${2:?db}"; UNDER="${3:-}"
UNDER="${UNDER/#\/repo\//$ROOT/}"
if [ -n "$UNDER" ] && [ ! -s "$UNDER" ]; then
  printf 'FAIL  %-62s %s\n' "GUARD: the script under test is readable" "$UNDER"
  exit 1
fi
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT

ROOT="$ROOT" UNDER="$UNDER" STUB="$STUB" python3 -I - <<'PY'
import contextlib
import datetime
import importlib.machinery
import importlib.util
import io
import os
import re
import sys
import types
import uuid

ROOT, UNDER, STUB = os.environ["ROOT"], os.environ["UNDER"], os.environ["STUB"]
fail = 0


def report(ok, label, detail=""):
    global fail
    print(f"{'PASS' if ok else 'FAIL'}  {label:<62} {detail}")
    fail |= not ok


# --- stand-ins for the modules the scripts import -------------------------------------------------------
# test_timestamp_naive asks pyarrow and DuckDB about the file's schema; they answer what the real module's file
# says (verify_parquet.py checks those answers against the module's own contract, #465 and #711).
class _Typ:
    def __init__(self, s):
        self.s = s

    def __str__(self):
        return self.s


class _ArrowSchema:
    TYPES = {"ts": "timestamp[us]", "tstz": "timestamp[us, tz=UTC]"}

    def field(self, name):
        return types.SimpleNamespace(type=_Typ(self.TYPES.get(name, "unknown")))


class _Leaf:
    def __init__(self, name, logical, converted):
        self.name, self.logical_type, self.converted_type = name, logical, converted


class _ParquetSchema:
    LEAVES = [_Leaf("ts", "Timestamp(isAdjustedToUTC=false, timeUnit=microseconds, is_from_converted_type=false, "
                          "force_set_converted_type=false)", "NONE"),
              _Leaf("tstz", "Timestamp(isAdjustedToUTC=true, timeUnit=microseconds, is_from_converted_type=false, "
                            "force_set_converted_type=false)", "TIMESTAMP_MICROS")]

    def __len__(self):
        return len(self.LEAVES)

    def column(self, i):
        return self.LEAVES[i]


class _Rel:
    def __init__(self, rows, description=(), types_=()):
        self.rows, self.description, self.types = rows, description, list(types_)

    def fetchall(self):
        return list(self.rows)


def _duck_sql(q, *a, **k):
    if "parquet_schema(" in q:
        unit = "TimeUnit(MILLIS=<null>, MICROS=MicroSeconds(), NANOS=<null>)"
        return _Rel([("schema", None, None),
                     ("ts", "TIMESTAMP_MICROS", f"TimestampType(isAdjustedToUTC=0, unit={unit})"),
                     ("tstz", "TIMESTAMP_MICROS", f"TimestampType(isAdjustedToUTC=1, unit={unit})")])
    return _Rel([], [("ts",), ("tstz",)], ["TIMESTAMP", "TIMESTAMP WITH TIME ZONE"])


os.makedirs(os.path.join(STUB, "pyarrow"), exist_ok=True)
open(os.path.join(STUB, "duckdb.py"), "w").write("def sql(*a, **k): raise RuntimeError('replaced by the guard')\n")
open(os.path.join(STUB, "psycopg2.py"), "w").write("class Error(Exception): pass\n")
open(os.path.join(STUB, "pyarrow", "__init__.py"), "w").write("")
open(os.path.join(STUB, "pyarrow", "parquet.py"), "w").write("class ParquetFile: pass\n")
sys.path.insert(0, STUB)


def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    mod.pq = types.SimpleNamespace(read_table=lambda p: types.SimpleNamespace(schema=_ArrowSchema()),
                                   ParquetFile=lambda p: types.SimpleNamespace(schema=_ParquetSchema()))
    mod.duckdb = types.SimpleNamespace(sql=_duck_sql)
    return mod


vp_path = os.path.join(ROOT, "scripts/verify_parquet.py")
vpr_path = os.path.join(ROOT, "scripts/verify_parquet_range.py")
if UNDER:
    try:
        under = load(UNDER, "under_test")
    except Exception as e:  # a mutant that is not Python verifies nothing
        report(False, "GUARD: the script under test loads", f"{type(e).__name__}: {e}")
        sys.exit(1)
    if hasattr(under, "test_range_keyless_archived"):
        vpr_path = UNDER
    elif hasattr(under, "test_uuid_nullable") and hasattr(under, "test_timestamptz"):
        vp_path = UNDER
    else:
        report(False, "GUARD: the script under test is one of the two", UNDER)
        sys.exit(1)
try:
    vp, vpr = load(vp_path, "vp"), load(vpr_path, "vpr")
except Exception as e:
    report(False, "fixture: both scripts load", f"{type(e).__name__}: {e}")
    sys.exit(1)
print(f"# verify_parquet: {vp_path}\n# verify_parquet_range: {vpr_path}")

# --- the table store: what run() answers --------------------------------------------------------------
LIT = re.compile(r"\s*('(?:[^']|'')*'|-?\d+(?:\.\d+)?|null|true|false)\s*", re.I)


def lit(tok):
    t = tok.strip()
    if t.startswith("'"):
        return t[1:-1].replace("''", "'")
    if t.lower() == "null":
        return None
    if t.lower() in ("true", "false"):
        return t.lower() == "true"
    return float(t) if "." in t else int(t)


def tuples(s):
    out, i = [], 0
    while True:
        m = re.compile(r"\s*\(").match(s, i)
        if not m:
            return out
        i, vals = m.end(), []
        while True:
            v = LIT.match(s, i)
            if not v:
                raise ValueError(f"the guard cannot read a value at {s[i:i + 30]!r}")
            vals.append(lit(v.group(1)))
            i = v.end()
            if s[i] == ",":
                i += 1
                continue
            i += 1
            break
        out.append(vals)
        c = re.compile(r"\s*,").match(s, i)
        if not c:
            return out
        i = c.end()


def instant(v):
    """A timestamptz text as Postgres hands it back to psycopg2: an aware datetime."""
    d = datetime.datetime.fromisoformat(re.sub(r"\+00$", "+00:00", v))
    return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)


class Store:
    def __init__(self):
        self.tables, self.zone = {}, "UTC"

    def run(self, conn, sql, params=None):
        s = " ".join(sql.split())
        if re.match(r"(?i)drop table if exists (\w+)", s):
            self.tables.pop(re.match(r"(?i)drop table if exists (\w+)", s).group(1), None)
            return None
        m = re.match(r"(?i)create table (\w+) \((.*)\)( partition by range \(\w+\))?$", s)
        if m:
            cols = [c.strip().split()[0] for c in m.group(2).split(",") if not c.strip().lower().startswith("primary")]
            self.tables[m.group(1)] = (cols, [])
            return None
        if re.match(r"(?i)create table \w+ partition of", s):
            return None
        m = re.match(r"(?i)insert into (\w+) \(([^)]*)\) values (.*)$", s)
        if m:
            cols = [c.strip() for c in m.group(2).split(",")]
            vals = [list(params)] if params else tuples(m.group(3))
            self.tables[m.group(1)][1].extend(dict(zip(cols, v)) for v in vals)
            return None
        m = re.match(r"(?i)set timezone to %s$", s)
        if m:
            self.zone = params[0]
            return None
        if re.match(r"(?i)reset timezone$", s):
            self.zone = "UTC"
            return None
        if re.match(r"(?i)select current_setting\('TimeZone'\)$", s):
            return [(self.zone,)]
        m = re.match(r"(?i)select uuid_send\((\w+)\) from (\w+) order by ctid$", s)
        if m:
            return [((uuid.UUID(r[m.group(1)]).bytes if r[m.group(1)] is not None else None),)
                    for r in self.tables[m.group(2)][1]]
        m = re.match(r"(?i)select (\w+) from (\w+) order by ctid$", s)
        if m:
            return [(instant(r[m.group(1)]),) for r in self.tables[m.group(2)][1]]
        m = re.match(r"(?i)select (.+?) from (\w+) where (\w+) >= %s and \3 < %s order by (.+)$", s)
        if m:
            sel = [c.strip() for c in m.group(1).split(",")]
            order = [c.strip() for c in m.group(4).split(",")]
            lo, hi = params
            rows = [r for r in self.tables[m.group(2)][1] if str(lo) <= str(r[m.group(3)]) < str(hi)]
            rows.sort(key=lambda r: tuple(str(r[c]) for c in order))
            return [tuple(r[c] for c in sel) for r in rows]
        if re.match(r"(?i)select archive\._key_columns", s):
            return [(None,)]
        raise ValueError(f"the guard's table store does not answer: {s[:90]!r}")


class Conn:
    def commit(self):
        pass

    def rollback(self):
        pass


# --- the writers under test --------------------------------------------------------------------------
def as_file_value(table, col, v):
    """A stored value as the readers hand it back from the module's file."""
    if v is None:
        return None
    if table.startswith("t_uuid"):
        return uuid.UUID(v).bytes
    if table == "t_ts_naive" and col == "ts":
        return datetime.datetime.fromisoformat(v)
    if table.startswith("t_ts"):
        return instant(v).astimezone(datetime.timezone.utc)
    return v   # a range table's values, ts included, are compared as the store holds them, on both sides


def faithful(rows, ctl=None):
    return [dict(r) for r in rows]


def extra(rows, ctl=None):
    return [dict(r) for r in rows] + ([dict(rows[0])] if rows else [{}])


def missing(rows, ctl=None):
    return [dict(r) for r in rows[:-1]]


def misalign(rows, ctl):
    """Every non-control column read in its own order: inside a run of rows tied on the control column, the
    j-th such column lands j places further on (the #462 misalignment)."""
    rows = [dict(r) for r in rows]
    others = [c for c in (rows[0].keys() if rows else []) if c != ctl]
    groups = {}
    for i, r in enumerate(rows):
        groups.setdefault(str(r[ctl]), []).append(i)
    out = [dict(r) for r in rows]
    for idx in groups.values():
        for j, c in enumerate(others, 1):
            for k, i in enumerate(idx):
                out[i][c] = rows[idx[(k + j) % len(idx)]][c]
    return out


def run_test(mod, fn_name, writer, ranged):
    """Run mod.<fn_name> once with <writer> between the table and the readers. Returns (rows the writer was
    handed, the failures recorded, the exception raised or None, what it printed)."""
    store, seen = Store(), {}
    mod.run = store.run

    def bytes_of(conn, table, *rest):
        seen["table"] = table
        if ranged:
            seen["control"], seen["lo"], seen["hi"] = rest[0], rest[1], rest[2]
        return b"stand-in"

    def read(raw):
        table = seen["table"]
        rows = store.tables[table][1]
        if ranged:
            c = seen["control"]
            rows = [r for r in rows if str(seen["lo"]) <= str(r[c]) < str(seen["hi"])]
        file_rows = [{k: as_file_value(table, k, v) for k, v in r.items()} for r in rows]
        seen["rows"] = len(file_rows)
        out = writer(file_rows, seen.get("control"))
        return [dict(r) for r in out], [dict(r) for r in out]

    if ranged:
        mod.to_parquet_range_bytes = bytes_of
    else:
        mod.to_parquet_bytes = bytes_of
    mod.read_with_both_readers = read
    mod.FAILURES.clear()
    buf, err = io.StringIO(), None
    with contextlib.redirect_stdout(buf):
        try:
            getattr(mod, fn_name)(Conn())
        except Exception as e:
            err = e
    return seen.get("rows", 0), list(mod.FAILURES), err, buf.getvalue().strip().replace("\n", " | ")


# --- LIVENESS: each file's check() fails a surplus and a deficit -------------------------------------------
for name, mod in (("verify_parquet", vp), ("verify_parquet_range", vpr)):
    mod.FAILURES.clear()
    with contextlib.redirect_stdout(io.StringIO()):
        mod.check("probe", [{"n": 1}, {"n": 2}], [{"n": 1}, {"n": 2}, {"n": 1}], [{"n": 1}, {"n": 2}, {"n": 1}])
        surplus = bool(mod.FAILURES)
        mod.FAILURES.clear()
        mod.check("probe", [{"n": 1}, {"n": 2}], [{"n": 1}], [{"n": 1}])
        deficit = bool(mod.FAILURES)
    report(surplus and deficit, f"LIVENESS: {name}'s check() fails a surplus and a deficit",
           f"surplus {surplus}, deficit {deficit}")

# --- verify_parquet.py: the tests that compare their rows by hand ------------------------------------------
for fn in ("test_timestamptz", "test_uuid", "test_uuid_nullable", "test_timestamp_naive"):
    if not hasattr(vp, fn):
        report(False, f"GUARD: verify_parquet.py defines {fn}")
        continue
    n, f, err, out = run_test(vp, fn, faithful, False)
    report(n > 0, f"LIVENESS: {fn} ran over its table", f"{n} rows")
    report(not f and err is None, f"CONTROL: {fn} passes a faithful file",
           f"{out}" if not f and err is None else f"{err!r} {f[:2]}")
    n, f, err, out = run_test(vp, fn, extra, False)
    report(bool(f) or err is not None, f"{fn} fails a file holding a row its table does not",
           f"{len(f)} failure(s)" if f else (f"raised {err!r}" if err else f"it printed: {out}"))
    n, f, err, out = run_test(vp, fn, missing, False)
    report(bool(f) or err is not None, f"{fn} fails a file missing one of its table's rows",
           f"{len(f)} failure(s)" if f else (f"raised {type(err).__name__}" if err else f"it printed: {out}"))

# --- verify_parquet_range.py: the keyless tie ----------------------------------------------------------
probe = [{"ts": "t", "tag": "a", "n": 1}, {"ts": "t", "tag": "b", "n": 2}]
report(any(r not in probe for r in misalign(probe, "ts")),
       "LIVENESS: MISALIGN writes a row the source does not hold, given two distinguishing columns")
if not hasattr(vpr, "test_range_keyless_archived"):
    report(False, "GUARD: verify_parquet_range.py defines test_range_keyless_archived")
else:
    fn = "test_range_keyless_archived"
    n, f, err, out = run_test(vpr, fn, faithful, True)
    report(n > 1, f"LIVENESS: {fn} ran over its fixture", f"{n} rows")
    report(not f and err is None, f"CONTROL: {fn} passes a faithful file",
           f"{out}" if not f and err is None else f"{err!r} {f[:2]}")
    n, f, err, out = run_test(vpr, fn, misalign, True)
    report(bool(f) or err is not None, f"{fn} fails a writer that misaligns the tied rows",
           f"{len(f)} failure(s)" if f else (f"raised {err!r}" if err else f"it printed: {out}"))

print(f"{'PASS' if not fail else 'FAIL'}  {'the independent-reader tests see a wrong row':<62}")
sys.exit(1 if fail else 0)
PY
