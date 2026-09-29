#!/usr/bin/env python3
"""landing_stats.py <landq.log> | --selftest

Per-PR landing measurements from landq.sh's log, for the pass record's "Landing" table: when each
PR's landing began (its `===== landing` line), when the queue merged it, the minutes between, how many
times it was enqueued, the known flakes met, the stops that needed a hand, and the list files
keep_both.py resolved. A batch line (`===== landing batch 610 612 (tier 1)`) opens every PR it names.

Times in the log are HH:MM:SSZ with no date; the parser rolls the day forward at each decrease, which is
right for a log that runs for less than 24 hours between two of its own lines.
"""
import datetime as dt
import re
import sys

LANDING = re.compile(r"===== landing (?:batch )?((?:#?\d+ ?)+)\(tier (\d)\)")


def parse(text):
    rows = {}
    day = 0
    last = None
    current = []
    for ln in text.split("\n"):
        m = re.match(r"(\d\d:\d\d:\d\dZ)\s+(.*)", ln)
        if m:
            t = dt.datetime.strptime(m.group(1), "%H:%M:%SZ")
            if last is not None and t < last:
                day += 1
            last = t
            t = t + dt.timedelta(days=day)
            msg = m.group(2)
        else:
            t, msg = None, ln.strip()
        mm = LANDING.search(msg)
        if mm:
            current = [int(p) for p in re.findall(r"\d+", mm.group(1))]
            for pr in current:
                r = rows.setdefault(pr, {"tier": int(mm.group(2)), "start": t, "merged": None, "enqueues": 0,
                                         "flakes": 0, "stops": 0, "hands": 0, "auto": 0, "manual": 0})
                if r["start"] is None or (t is not None and t < r["start"]):
                    r["start"] = t
            continue
        if not current:
            continue
        one = re.search(r"#(\d+)", msg)
        targets = [int(one.group(1))] if one and int(one.group(1)) in rows else current
        for pr in targets:
            r = rows[pr]
            if msg.startswith("enqueueing") or msg.startswith("re-enqueueing"):
                r["enqueues"] += 1
            elif msg.startswith("MERGED"):
                r["merged"] = t
            elif msg.startswith("STOPPED at"):
                r["stops"] += 1
            elif msg.startswith("job ") and "known flake" in msg:
                r["flakes"] += 1
            elif msg.startswith("hand:"):
                r["hands"] += 1
            elif msg.startswith("auto-resolved"):
                r["auto"] += 1
            elif msg.startswith("MANUAL:"):
                r["manual"] += 1
    return rows


def render(rows):
    out = ["pr\ttier\tstart\tmerged\tminutes\tenqueues\tflakes\tstops\thands\tauto_resolved\tmanual"]
    mins = []
    for pr, r in sorted(rows.items(), key=lambda kv: kv[1]["start"] or dt.datetime.max):
        m = None
        if r["merged"] and r["start"]:
            m = (r["merged"] - r["start"]).total_seconds() / 60
            mins.append(m)
        out.append("\t".join(str(x) for x in [
            pr, r["tier"], r["start"].strftime("d%d %H:%M") if r["start"] else "",
            r["merged"].strftime("d%d %H:%M") if r["merged"] else "-", f"{m:.0f}" if m is not None else "-",
            r["enqueues"], r["flakes"], r["stops"], r["hands"], r["auto"], r["manual"]]))
    if mins:
        srt = sorted(mins)
        median = srt[len(srt) // 2] if len(srt) % 2 else (srt[len(srt) // 2 - 1] + srt[len(srt) // 2]) / 2
        out.append("")
        out.append(f"merged: {len(mins)}, median {median:.0f} min, mean {sum(mins) / len(mins):.0f} min per PR "
                   f"(start of its landing to merge), total {sum(mins) / 60:.1f} h")
    return "\n".join(out)


def selftest():
    log = "\n".join([
        "===== landq start 22:18:24Z =====",
        "22:18:24Z ===== landing #603 (tier 2) =====",
        "22:18:30Z   auto-resolved CHANGELOG.md (kept both sides)",
        "23:20:59Z   checks n=29 pass:28 pending:1",
        "STOPPED at #603: checks did not complete",
        "23:22:24Z keeper: #603 stopped on a wait timeout (try 1 of 8), rerunning landq.sh",
        "23:22:24Z ===== landing #606 (tier 1) =====",
        "00:19:18Z   enqueueing #606",
        "00:28:44Z   #606 left the queue unmerged",
        "job 109196466698: known flake registry_quota (third-party image pull refused; no test ran)",
        "00:28:48Z   re-enqueueing #606 (known flake, retry 1)",
        "00:40:52Z   MERGED #606",
        "00:40:52Z ===== landing batch 607 610 (tier 1) =====",
        "00:40:56Z   auto-resolved test.sh (kept both sides)",
        "00:56:07Z   enqueueing #607",
        "00:56:09Z   enqueueing #610",
        "01:08:44Z   MERGED #607",
        "01:09:10Z   MERGED #610",
        "01:09:10Z ===== landing #603 (tier 2) =====",
        "01:20:00Z   enqueueing #603",
        "01:30:00Z   MERGED #603",
    ])
    rows = parse(log)
    assert rows[606]["merged"] - rows[606]["start"] == dt.timedelta(hours=1, minutes=18, seconds=28), rows[606]
    assert rows[606]["enqueues"] == 2 and rows[606]["flakes"] == 1, rows[606]
    assert rows[603]["start"].day == 1 and rows[603]["merged"].day == 2, rows[603]  # first start kept across the restart
    assert rows[603]["stops"] == 1, rows[603]
    assert rows[607]["auto"] == 1 and rows[610]["auto"] == 1, "a batch line opens every PR it names"
    assert rows[607]["merged"] is not None and rows[610]["merged"] is not None
    text = render(rows)
    assert "merged: 4, median" in text, text
    print("landing_stats selftest: PASS (midnight rollover, restart keeps the first start, batch lines, flake and stop counts)")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        selftest()
    elif len(sys.argv) == 2:
        print(render(parse(open(sys.argv[1]).read())))
    else:
        print(__doc__.strip().split("\n")[0])
        sys.exit(2)
