#!/usr/bin/env python3
"""loop_state.py <state.json> init --loop N --pin <sha> [--force]
   loop_state.py <state.json> set --phase review|fix|record|report|waiting|stop_check|done --step "<text>" [--pr N ...] [--pin <sha>]
   loop_state.py <state.json> progress
   loop_state.py <state.json> show
   loop_state.py <state.json> check [--stale-hours 2] [--dead-hours 6]
   loop_state.py --selftest

The autonomous loop's state file and its dead-man switch (docs/adversarial-review.md, "Running a loop without
a human"). The driver keeps one `loop_state.json` per loop in its durable scratch, so a session that compacts
or restarts can say where it was, and calls `check` FIRST on every wakeup:

    {"loop": 12, "pin": "<sha>", "phase": "fix", "step": "3: landing wave 1", "prs": [1230, 1231],
     "started": "2026-10-11T09:00:00Z", "last_progress": "2026-10-11T13:42:10Z",
     "history": [{"time": "...", "phase": "review", "step": "..."}, ...]}   # the last 50 transitions

`set` records a transition (phase and step), appends any `--pr` to `prs` (once each), may move the pin, and
stamps `last_progress`; `progress` only stamps it. A transition is progress; a wakeup that finds nothing to
do is not, so the driver calls `progress` only when a step actually advanced.

`check` prints the age of the last progress and the verdict while a phase is open (every phase but
`waiting` and `done`): exit 0 ok, 3 STALE when it is older than --stale-hours (push a notification and keep
the wakeup), 4 DEAD when it is older than --dead-hours (stop and report). `waiting` is the loop parked on the
user (loop 12's record PR awaiting the user's merge: `set --phase waiting --step "record PR #N awaits the
user's merge"`, then `set --phase stop_check` once it merged): `check` exits 0 and notes how long it has
waited, since a wait for the user is not a stall. After `set --phase done` it exits 0 and says no phase is
open. Exit 2 is a missing or malformed state file, or an argument refused: never a silent default.
Times are UTC, ISO 8601 with a `Z`.
"""
import argparse
import contextlib
import datetime as dt
import io
import json
import os
import re
import sys
import tempfile

PHASES = ("init", "review", "fix", "record", "report", "waiting", "stop_check", "done")
SETTABLE = PHASES[1:]
HISTORY_MAX = 50
FIELDS = ("loop", "pin", "phase", "step", "prs", "started", "last_progress", "history")
OK, STALE, DEAD = 0, 3, 4


class StateError(Exception):
    pass


def now_utc():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(t):
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(s, field):
    try:
        return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except (TypeError, ValueError):
        raise StateError(f"{field} is not a UTC time of the shape 2026-10-11T09:00:00Z: {s!r}")


def check_sha(pin):
    if not re.fullmatch(r"[0-9a-f]{7,40}", pin or ""):
        raise StateError(f"--pin must be a commit sha (7 to 40 hex digits), got {pin!r}")
    return pin


def load(path):
    if not os.path.exists(path):
        raise StateError(f"{path} does not exist (start the loop with `loop_state.py {path} init`)")
    try:
        with open(path) as f:
            st = json.load(f)
    except json.JSONDecodeError as exc:
        raise StateError(f"{path} is not valid JSON: {exc}")
    missing = [k for k in FIELDS if k not in st]
    if missing:
        raise StateError(f"{path} lacks {', '.join(missing)}")
    if st["phase"] not in PHASES:
        raise StateError(f"{path}: unknown phase {st['phase']!r}")
    if not isinstance(st["prs"], list) or not isinstance(st["history"], list):
        raise StateError(f"{path}: prs and history must be lists")
    parse_time(st["started"], "started")
    parse_time(st["last_progress"], "last_progress")
    return st


def save(path, st):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".loop_state.")
    with os.fdopen(fd, "w") as f:
        json.dump(st, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def transition(st, phase, step, t):
    st["phase"], st["step"] = phase, step
    st["last_progress"] = iso(t)
    st["history"].append({"time": iso(t), "phase": phase, "step": step})
    del st["history"][:-HISTORY_MAX]


def cmd_init(path, loop, pin, force=False, t=None):
    if os.path.exists(path) and not force:
        raise StateError(f"{path} exists (a loop is already recorded there; --force to start over)")
    if loop < 1:
        raise StateError("--loop must be positive")
    t = t or now_utc()
    st = {"loop": loop, "pin": check_sha(pin), "phase": "init", "step": "initialised", "prs": [],
          "started": iso(t), "last_progress": iso(t), "history": []}
    transition(st, "init", "initialised", t)
    save(path, st)
    return st


def cmd_set(path, phase, step, prs=None, pin=None, t=None):
    st = load(path)
    if phase not in SETTABLE:
        raise StateError(f"--phase must be one of {', '.join(SETTABLE)}")
    if not (step or "").strip():
        raise StateError("--step is empty")
    for pr in prs or []:
        if pr not in st["prs"]:
            st["prs"].append(pr)
    if pin is not None:
        st["pin"] = check_sha(pin)
    transition(st, phase, step.strip(), t or now_utc())
    save(path, st)
    return st


def cmd_progress(path, t=None):
    st = load(path)
    st["last_progress"] = iso(t or now_utc())
    save(path, st)
    return st


def verdict(st, stale_hours=2.0, dead_hours=6.0, t=None):
    """(exit code, one line) for the dead-man switch."""
    if not 0 < stale_hours < dead_hours:
        raise StateError("need 0 < --stale-hours < --dead-hours")
    t = t or now_utc()
    last = parse_time(st["last_progress"], "last_progress")
    age = (t - last).total_seconds() / 3600
    where = f"loop {st['loop']}, phase {st['phase']}, step {st['step']!r}"
    head = f"last progress {st['last_progress']}, {age:.2f} h ago ({where})"
    if st["phase"] == "done":
        return OK, f"{head}: ok (no phase open)"
    if st["phase"] == "waiting":
        return OK, f"{head}: ok (waiting on the user for {age:.2f} h; the dead-man switch does not run while waiting)"
    if age < -0.05:
        return OK, f"{head}: ok (last progress is in the future: check the clock)"
    if age > dead_hours:
        return DEAD, f"{head}: DEAD (over {dead_hours:g} h with a phase open: stop and report)"
    if age > stale_hours:
        return STALE, f"{head}: STALE (over {stale_hours:g} h with a phase open: push a notification, keep the wakeup)"
    return OK, f"{head}: ok"


def show(st, t=None):
    t = t or now_utc()
    age = (t - parse_time(st["last_progress"], "last_progress")).total_seconds() / 3600
    lines = [f"loop {st['loop']} pinned {st['pin']}", f"phase {st['phase']}: {st['step']}",
             f"PRs: {', '.join('#%d' % p for p in st['prs']) or 'none'}",
             f"started {st['started']}; last progress {st['last_progress']} ({age:.2f} h ago)",
             "recent transitions:"]
    lines += [f"  {h['time']} {h['phase']}: {h['step']}" for h in st["history"][-10:]]
    return "\n".join(lines)


def selftest():
    t0 = dt.datetime(2026, 10, 11, 9, 0, 0, tzinfo=dt.timezone.utc)
    hours = lambda h: t0 + dt.timedelta(hours=h)  # noqa: E731
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "loop_state.json")
        for bad in (lambda: load(p), lambda: cmd_set(p, "review", "x"), lambda: cmd_init(p, 12, "not-a-sha")):
            try:
                bad()
                raise AssertionError("refused state accepted")
            except StateError:
                pass
        st = cmd_init(p, 12, "60f4ad89", t=t0)
        assert st["phase"] == "init" and st["last_progress"] == "2026-10-11T09:00:00Z" and len(st["history"]) == 1
        try:
            cmd_init(p, 12, "60f4ad89", t=t0)
            raise AssertionError("init over an existing loop must refuse without --force")
        except StateError:
            pass
        st = cmd_set(p, "review", "2: seeds planted", t=hours(1))
        assert st["phase"] == "review" and st["last_progress"] == iso(hours(1))
        st = cmd_set(p, "fix", "2: fixers spawned", prs=[1230, 1231], t=hours(5))
        st = cmd_set(p, "fix", "3: landing", prs=[1231, 1232], pin=None, t=hours(6))
        assert st["prs"] == [1230, 1231, 1232], "each PR once, in order"
        assert [h["phase"] for h in load(p)["history"]] == ["init", "review", "fix", "fix"]
        # the dead-man switch: ok, then STALE past 2 h, then DEAD past 6 h, measured from the last progress
        st = load(p)
        assert verdict(st, t=hours(7.5))[0] == OK
        code, line = verdict(st, t=hours(8.5))
        assert code == STALE and "2.50 h ago" in line and "STALE" in line, line
        code, line = verdict(st, t=hours(12.5))
        assert code == DEAD and "DEAD" in line and "phase fix" in line, line
        assert verdict(st, stale_hours=1, dead_hours=3, t=hours(8.5))[0] == STALE
        cmd_progress(p, t=hours(12))
        assert verdict(load(p), t=hours(12.5))[0] == OK, "progress resets the switch"
        # a loop waiting on the user is never stale or dead, and says how long it has waited; leaving the
        # wait re-arms the switch from that transition
        cmd_set(p, "waiting", "record PR #1240 awaits the user's merge", t=hours(12.25))
        code, line = verdict(load(p), t=hours(30))
        assert code == OK and "waiting on the user for 17.75 h" in line, line
        cmd_set(p, "stop_check", "record PR #1240 merged", t=hours(31))
        assert verdict(load(p), t=hours(33.5))[0] == STALE and verdict(load(p), t=hours(37.5))[0] == DEAD
        # a closed loop is never stale
        cmd_set(p, "done", "stop_check: continue", t=hours(13))
        code, line = verdict(load(p), t=hours(40))
        assert code == OK and "no phase open" in line, line
        # the history is bounded to the last 50 transitions
        for i in range(60):
            cmd_set(p, "fix", f"step {i}", t=hours(14))
        h = load(p)["history"]
        assert len(h) == HISTORY_MAX and h[-1]["step"] == "step 59" and h[0]["step"] == "step 10", h[0]
        # --force starts over; a corrupt or incomplete file is an error, never a fresh state
        assert cmd_init(p, 13, "abcdef1", force=True, t=hours(20))["loop"] == 13
        with open(p, "w") as f:
            f.write("{not json")
        for bad in (lambda: load(p), lambda: cmd_progress(p)):
            try:
                bad()
                raise AssertionError("a corrupt state file was accepted")
            except StateError:
                pass
        with open(p, "w") as f:
            json.dump({"loop": 12, "pin": "abc1234"}, f)
        try:
            load(p)
            raise AssertionError("an incomplete state file was accepted")
        except StateError:
            pass
        try:
            verdict({"loop": 1, "phase": "fix", "step": "x", "last_progress": iso(t0)}, 6, 2)
            raise AssertionError("stale above dead accepted")
        except StateError:
            pass
        # the CLI's exit codes
        q = os.path.join(d, "cli.json")
        sink = io.StringIO()
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            assert main([q, "check"]) == 2
            assert main([q, "init", "--loop", "12", "--pin", "60f4ad89"]) == 0
            assert main([q, "set", "--phase", "review", "--step", "1: pinned", "--pr", "7", "8"]) == 0
            assert main([q, "set", "--phase", "nonsense", "--step", "x"]) == 2
            assert main([q, "progress"]) == 0 and main([q, "show"]) == 0
            assert main([q, "check"]) == OK
        assert load(q)["prs"] == [7, 8] and "phase review: 1: pinned" in sink.getvalue(), sink.getvalue()
    print("loop_state selftest: PASS (init refuses an existing loop, set records transitions and PRs once, "
          "check ok/STALE 3/DEAD 4 from the last progress, progress resets it, waiting and done are never stale, "
          "history bounded at 50, corrupt and incomplete files refused)")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--selftest"]:
        selftest()
        return 0
    ap = argparse.ArgumentParser(prog="loop_state.py", description=__doc__.split("\n\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("state", help="the loop_state.json file")
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("init", help="start a loop")
    i.add_argument("--loop", type=int, required=True)
    i.add_argument("--pin", required=True)
    i.add_argument("--force", action="store_true", help="overwrite an existing state file")
    s = sub.add_parser("set", help="record a phase/step transition (stamps last_progress)")
    s.add_argument("--phase", required=True)
    s.add_argument("--step", required=True)
    s.add_argument("--pr", type=int, nargs="+", action="extend", default=[])
    s.add_argument("--pin")
    sub.add_parser("progress", help="stamp last_progress now")
    sub.add_parser("show", help="print the state")
    c = sub.add_parser("check", help="the dead-man switch: exit 0 ok, 3 stale, 4 dead")
    c.add_argument("--stale-hours", type=float, default=2.0)
    c.add_argument("--dead-hours", type=float, default=6.0)
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    try:
        if args.cmd == "init":
            st = cmd_init(args.state, args.loop, args.pin, args.force)
            print(f"loop {st['loop']} initialised at {st['started']}, pin {st['pin']}")
        elif args.cmd == "set":
            st = cmd_set(args.state, args.phase, args.step, args.pr, args.pin)
            print(f"loop {st['loop']} phase {st['phase']}: {st['step']}")
        elif args.cmd == "progress":
            print(f"last progress {cmd_progress(args.state)['last_progress']}")
        elif args.cmd == "show":
            print(show(load(args.state)))
        elif args.cmd == "check":
            code, line = verdict(load(args.state), args.stale_hours, args.dead_hours)
            print(line)
            return code
    except StateError as exc:
        print(f"loop_state: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
