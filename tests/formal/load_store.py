#!/usr/bin/env python3
"""Read the archive bucket for the invariant oracle's ArchiveNoClobber (formal methods Phase 3 W4,
docs/formal/phase3-design.md "The checks").

SQL cannot read an object, and judging the archive with pgpm_archive's own code would be the code under test
grading itself, so the objects are fetched with curl (SigV4, from the curl image the archive track already uses for
its bucket setup, on the track's network) and decoded here: Parquet with pyarrow, the reader
scripts/verify_parquet*.py hold pgpm_archive's writer to, and NDJSON (gzip or plain) with the standard library.

  load_store.py <docker network> <curl image>   < keys.tsv   > stage.csv

keys.tsv, one line per retired chunk with a key, plus one per configured parent with an empty key:
  <parent oid> <TAB> <endpoint> <TAB> <bucket> <TAB> <key>
stage.csv, for tests/formal/report.sql's \\copy (parent oid, s3 key, ok, row as jsonb):
  one row per decoded row: (parent, key, t, the row as a JSON object over the column names)
  one marker per parent:   (parent, NULL, t, NULL) when every object of it was read, (parent, NULL, f, "reason") if not
An object that answers 404 was read: it holds nothing, which is what ArchiveNoClobber must see. Any other failure
leaves its parent unlisted, so the oracle says it did not judge it rather than reporting a clobber.

Rows are not rendered to identities here. Each value is handed to PostgreSQL as JSON and rendered there, through
jsonb_populate_record over the parent's row type and the oracle's own identity SQL, so a store identity and a ledger
identity are the same text by construction, not by two renderers agreeing.
"""
import base64
import csv
import datetime
import decimal
import gzip
import io
import json
import math
import subprocess
import sys
import urllib.parse
import uuid

FETCH = r'''for u; do
  code=$(curl -s -o /tmp/o -w '%{http_code}' --aws-sigv4 aws:amz:us-east-1:s3 -u minioadmin:minioadmin "$u") || code=000
  printf '%s\t' "$code"
  if [ "$code" = 200 ]; then base64 -w0 /tmp/o; fi
  echo
done'''

EPOCH = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)


def jsonable(v):
    if v is None or isinstance(v, (bool, int, str)):
        return v
    if isinstance(v, float):
        if math.isnan(v):
            return "NaN"
        if math.isinf(v):
            return "Infinity" if v > 0 else "-Infinity"
        return v
    if isinstance(v, decimal.Decimal):
        return str(v)
    if isinstance(v, (datetime.datetime, datetime.date, datetime.time)):
        return v.isoformat()
    if isinstance(v, uuid.UUID):
        return str(v)
    if isinstance(v, (bytes, bytearray)):
        return str(uuid.UUID(bytes=bytes(v))) if len(v) == 16 else "\\x" + bytes(v).hex()
    if isinstance(v, (list, tuple)):
        return [jsonable(x) for x in v]
    if isinstance(v, dict):
        return {k: jsonable(x) for k, x in v.items()}
    return str(v)


def timestamp_column(col):
    """A timestamp column whose values may lie past Python's datetime (pgpm writes +-infinity as the int64 ends)."""
    import pyarrow as pa
    unit = col.type.unit
    per = {"s": 1, "ms": 1000, "us": 1000000, "ns": 1000000000}[unit]
    aware = col.type.tz is not None
    out = []
    for raw in col.cast(pa.int64()).to_pylist():
        if raw is None:
            out.append(None)
            continue
        try:
            t = EPOCH + datetime.timedelta(microseconds=raw * 1000000 // per)
            out.append((t if aware else t.replace(tzinfo=None)).isoformat())
        except OverflowError:
            out.append("infinity" if raw > 0 else "-infinity")
    return out


def json_columns(raw):
    """The leaves annotated JSON. pgpm_archive writes json, jsonb and array columns as JSON text under that
    annotation (scripts/verify_parquet.py: "array as JSON text", test_jsonb), and pyarrow hands them back as str."""
    import pyarrow.parquet as pq
    schema = pq.ParquetFile(io.BytesIO(raw)).schema
    return {schema.column(i).name for i in range(len(schema))
            if schema.column(i).converted_type == "JSON" or "JSON" in str(schema.column(i).logical_type)}


def parquet_rows(raw):
    import pyarrow as pa
    import pyarrow.parquet as pq
    t = pq.read_table(io.BytesIO(raw), use_threads=False)  # threads: the interpreter hung at exit after a 0-row file
    as_json = json_columns(raw)
    cols = {}
    for name in t.column_names:
        col = t.column(name)
        if pa.types.is_timestamp(col.type):
            cols[name] = timestamp_column(col)
        elif name in as_json:
            # the JSON text decoded to its value: staged as a string it would reach jsonb_populate_record as a JSON
            # string, which an array column refuses and a jsonb column reads as a string scalar (Codex, #1486)
            cols[name] = [None if v is None else json.loads(v) for v in col.to_pylist()]
        else:
            cols[name] = [jsonable(v) for v in col.to_pylist()]
    for i in range(t.num_rows):
        yield {n: cols[n][i] for n in t.column_names}


def ndjson_rows(raw):
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    for line in raw.decode("utf-8").splitlines():
        if line.strip():
            yield json.loads(line)


def main():
    net, image = sys.argv[1], sys.argv[2]
    parents, keys = {}, []
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        parent, endpoint, bucket, key = (line.split("\t") + ["", "", "", ""])[:4]
        parents.setdefault(parent, None)
        if key:
            url = "%s/%s/%s" % (endpoint.rstrip("/"), urllib.parse.quote(bucket, safe=""),
                                urllib.parse.quote(key, safe="/-_.~"))
            keys.append((parent, key, url))
    out = csv.writer(sys.stdout)
    if keys:
        p = subprocess.run(["docker", "run", "--rm", "--network", net, "--entrypoint", "sh", image, "-c", FETCH, "sh"]
                           + [u for _, _, u in keys], capture_output=True, text=True, timeout=600)
        answers = p.stdout.splitlines()
        if p.returncode != 0 or len(answers) != len(keys):
            reason = "the fetch ran %d of %d objects (exit %d): %s" % (len(answers), len(keys), p.returncode,
                                                                    p.stderr.strip()[-300:])
            for parent in parents:
                parents[parent] = reason
            answers = []
        for (parent, key, _), ans in zip(keys, answers):
            code, _, body = ans.partition("\t")
            if code == "404":
                continue
            if code != "200":
                parents[parent] = parents[parent] or "%s answered %s" % (key, code)
                continue
            raw = base64.b64decode(body)
            try:
                rows = list(parquet_rows(raw) if raw[:4] == b"PAR1" else ndjson_rows(raw))
            except Exception as e:  # a reader that cannot decode the object leaves the parent unjudged, and says why
                parents[parent] = parents[parent] or "%s did not decode: %s" % (key, e)
                continue
            for r in rows:
                out.writerow([parent, key, "t", json.dumps(r)])
    for parent, reason in parents.items():
        out.writerow([parent, "", "t", ""] if reason is None else [parent, "", "f", json.dumps(reason)])


def selftest():
    """A Parquet file with a JSON-annotated column and a plain text one holding the same JSON-looking text: only the
    annotated one is decoded."""
    import pyarrow as pa
    import pyarrow.parquet as pq
    buf = io.BytesIO()
    pq.write_table(pa.table({"id": pa.array([1, 2], pa.int64()),
                             "ids": pa.array(['[1,2]', '[]'], pa.json_()),
                             "doc": pa.array(['{"a": 1}', None], pa.json_()),
                             "note": pa.array(['[1,2]', '{"a": 1}'], pa.string())}), buf)
    raw = buf.getvalue()
    got = list(parquet_rows(raw))
    want = [{"id": 1, "ids": [1, 2], "doc": {"a": 1}, "note": "[1,2]"},
            {"id": 2, "ids": [], "doc": None, "note": '{"a": 1}'}]
    ok = True
    if json_columns(raw) != {"ids", "doc"}:
        print("selftest FAIL: the JSON-annotated leaves read as %r, want ids and doc" % sorted(json_columns(raw)))
        ok = False
    if got != want:
        print("selftest FAIL: rows decoded as %r, want %r" % (got, want))
        ok = False
    print("load_store.py selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        sys.exit(selftest())
    main()
