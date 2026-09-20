#!/usr/bin/env python3
"""Summarize where an instantOS install spent its time.

Reads one or more install logs and prints:
  * a per-step table (from "Step <Name> completed in Ns" lines)
  * the slow-command list (from "'cmd' finished in Ns" lines)
  * if the timestamped executor log is given: a full RUN/DONE command
    timeline reconstructed from "[ts] RUN: cmd" + "DONE (d): cmd" pairs.

Usage:
  analyze_install_log.py /tmp/install.log [/var/log/instantos/install.log ...]
"""
import re
import sys
from datetime import datetime

STEP_RE = re.compile(r"Step (\w+) completed in (\d+)s")
SLOW_RE = re.compile(r"'(.+?)' finished in (\d+)s")
RUN_RE = re.compile(r"^\[([\d\- :]+)\] (?:RUN WITH INPUT|RUN WITH OUTPUT|RUN): (.*)$")
DONE_RE = re.compile(r"^DONE \(([\d.]+)s\): (.*)$")
TS_FMT = "%Y-%m-%d %H:%M:%S"


def strip_ansi(line):
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line)


def parse(path):
    steps, slows, timeline = [], [], []
    pending = None  # (ts, cmd) waiting for its DONE
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = strip_ansi(raw.rstrip("\n"))
            m = STEP_RE.search(line)
            if m:
                steps.append((m.group(1), int(m.group(2))))
                continue
            m = SLOW_RE.search(line)
            if m:
                slows.append((m.group(1), int(m.group(2))))
                continue
            m = RUN_RE.match(line)
            if m:
                try:
                    ts = datetime.strptime(m.group(1), TS_FMT)
                except ValueError:
                    continue
                pending = (ts, m.group(2))
                continue
            m = DONE_RE.match(line)
            if m and pending:
                timeline.append((pending[0], pending[1], float(m.group(1))))
                pending = None
    return steps, slows, timeline


def fmt_dur(secs):
    return f"{int(secs // 60)}m{secs % 60:04.1f}s" if secs >= 60 else f"{secs:.1f}s"


def main(paths):
    all_steps, all_slows, all_tl = [], [], []
    for p in paths:
        steps, slows, tl = parse(p)
        all_steps += steps
        all_slows += slows
        all_tl += tl

    if all_steps:
        print("== steps (in order seen) ==")
        total = 0
        for name, secs in all_steps:
            print(f"  {name:<12} {fmt_dur(secs):>9}")
            total += secs
        print(f"  {'sum':<12} {fmt_dur(total):>9}  (excludes outer/chroot overhead)")
    else:
        print("no step timing lines found")

    if all_slows:
        print("\n== slow commands (stdout, >=10s) ==")
        for cmd, secs in sorted(all_slows, key=lambda x: -x[1]):
            print(f"  {fmt_dur(secs):>9}  {cmd[:110]}")

    if all_tl:
        print("\n== executor-log command timeline ==")
        t0 = all_tl[0][0]
        for ts, cmd, dur in sorted(all_tl, key=lambda x: x[0]):
            off = (ts - t0).total_seconds()
            print(f"  +{int(off // 60):02d}:{int(off % 60):02d} {fmt_dur(dur):>9}  {cmd[:110]}")


if __name__ == "__main__":
    main(sys.argv[1:])
