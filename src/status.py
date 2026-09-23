#!/usr/bin/env python3
"""Pretty-print current Claude usage from the daemon state file."""

import json
import sys
import time
from pathlib import Path

STATE = Path.home() / ".uki" / "state.json"


def fmt_remaining(reset_at):
    if not reset_at:
        return "?"
    secs = max(0, reset_at - int(time.time()))
    h, rem = divmod(secs, 3600)
    m, _ = divmod(rem, 60)
    return f"{h}h {m}m" if h else f"{m}m"


def bar(util, width=24):
    util = util or 0
    filled = max(0, min(width, int(util * width)))
    return "█" * filled + "·" * (width - filled)


def main():
    if not STATE.exists():
        print("No state yet. Run: monitor.py once", file=sys.stderr)
        sys.exit(1)
    s = json.loads(STATE.read_text())
    age = int(time.time()) - s["fetched_at"]
    print(f"  Updated {age}s ago  primary={s.get('primary_claim','?')}\n")
    rows = [("5h window", "five_hour"), ("7d window", "seven_day"), ("Overage  ", "overage")]
    for label, key in rows:
        d = s[key]
        u = d.get("utilization") or 0
        r = d.get("reset_at")
        print(f"  {label}  [{bar(u)}] {u*100:>5.1f}%   resets in {fmt_remaining(r)}")


if __name__ == "__main__":
    main()
