#!/usr/bin/env python3
"""Claude usage monitor daemon.

Polls Anthropic API rate-limit response headers and writes the current
5h / 7d / overage window state to ~/.claude-usage-monitor/state.json.

Adaptive polling:
  - active on AC      -> every 3 min
  - active on battery -> every 5 min
  - idle (>10 min)    -> every 30 min
  - battery < 30%     -> every 30 min

Run modes:
  monitor.py        # daemon loop
  monitor.py once   # one-shot probe, prints JSON to stdout
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path.home() / ".claude-usage-monitor"
STATE = ROOT / "state.json"
LOG = ROOT / "monitor.log"

API_URL = "https://api.anthropic.com/v1/messages"
KEYCHAIN_SERVICE = "Claude Code-credentials"
MODEL = "claude-haiku-4-5"

INTERVAL_ACTIVE_AC = 180
INTERVAL_ACTIVE_BATT = 300
INTERVAL_IDLE = 1800
INTERVAL_LOW_BATTERY = 1800
IDLE_THRESHOLD_SEC = 600


def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}\n"
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(line)
    if sys.stderr.isatty():
        sys.stderr.write(line)


def get_oauth_token() -> str:
    out = subprocess.check_output(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        text=True,
    ).strip()
    return json.loads(out)["claudeAiOauth"]["accessToken"]


def get_idle_seconds() -> int:
    try:
        out = subprocess.check_output(["ioreg", "-c", "IOHIDSystem"], text=True)
    except Exception:
        return 0
    for line in out.splitlines():
        if "HIDIdleTime" in line:
            try:
                ns = int(line.rsplit("=", 1)[1].strip())
                return ns // 1_000_000_000
            except ValueError:
                return 0
    return 0


def get_power_state() -> tuple[bool, int]:
    try:
        out = subprocess.check_output(["pmset", "-g", "batt"], text=True)
    except Exception:
        return False, 100
    on_battery = "Battery Power" in out
    pct = 100
    for tok in out.split():
        if tok.endswith("%;"):
            try:
                pct = int(tok.rstrip("%;"))
            except ValueError:
                pass
            break
    return on_battery, pct


def pick_interval() -> tuple[int, str]:
    idle = get_idle_seconds()
    on_battery, pct = get_power_state()
    if on_battery and pct < 30:
        return INTERVAL_LOW_BATTERY, f"low-battery ({pct}%)"
    if idle > IDLE_THRESHOLD_SEC:
        return INTERVAL_IDLE, f"idle {idle}s"
    if on_battery:
        return INTERVAL_ACTIVE_BATT, f"active on battery ({pct}%)"
    return INTERVAL_ACTIVE_AC, "active on AC"


def fetch_usage() -> dict:
    token = get_oauth_token()
    body = json.dumps(
        {
            "model": MODEL,
            "max_tokens": 1,
            "messages": [{"role": "user", "content": "."}],
        }
    ).encode()
    req = urllib.request.Request(
        API_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-version": "2023-06-01",
            "anthropic-beta": "oauth-2025-04-20",
            "content-type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            headers = {k.lower(): v for k, v in resp.headers.items()}
    except urllib.error.HTTPError as e:
        if e.code == 429:
            headers = {k.lower(): v for k, v in e.headers.items()}
        else:
            log(f"HTTP {e.code}: {e.reason}")
            raise

    def num(k, conv=float):
        v = headers.get(k)
        try:
            return conv(v) if v is not None else None
        except (ValueError, TypeError):
            return None

    return {
        "fetched_at": int(time.time()),
        "five_hour": {
            "utilization": num("anthropic-ratelimit-unified-5h-utilization"),
            "reset_at": num("anthropic-ratelimit-unified-5h-reset", int),
            "status": headers.get("anthropic-ratelimit-unified-5h-status"),
        },
        "seven_day": {
            "utilization": num("anthropic-ratelimit-unified-7d-utilization"),
            "reset_at": num("anthropic-ratelimit-unified-7d-reset", int),
            "status": headers.get("anthropic-ratelimit-unified-7d-status"),
        },
        "overage": {
            "utilization": num("anthropic-ratelimit-unified-overage-utilization"),
            "reset_at": num("anthropic-ratelimit-unified-overage-reset", int),
            "status": headers.get("anthropic-ratelimit-unified-overage-status"),
        },
        "primary_claim": headers.get("anthropic-ratelimit-unified-representative-claim"),
    }


def write_state(state: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE)


# Set by SIGUSR1 (sent by the floater on system wake) to break out of sleep early.
_wake = threading.Event()

def _on_sigusr1(signum, frame):
    _wake.set()

signal.signal(signal.SIGUSR1, _on_sigusr1)


def loop() -> None:
    log("monitor daemon starting")
    while True:
        interval = 300
        try:
            state = fetch_usage()
            interval, why = pick_interval()
            state["next_poll_in_sec"] = interval
            state["poll_reason"] = why
            write_state(state)
            u5 = state["five_hour"]["utilization"] or 0
            u7 = state["seven_day"]["utilization"] or 0
            log(f"5h={u5:.0%} 7d={u7:.0%} -> sleep {interval}s ({why})")
        except Exception as e:
            log(f"ERROR: {type(e).__name__}: {e}")
            interval, why = pick_interval()
            write_state({
                "fetched_at": int(time.time()),
                "error": f"{type(e).__name__}: {e}",
                "five_hour": {"utilization": None, "reset_at": None, "status": None},
                "seven_day": {"utilization": None, "reset_at": None, "status": None},
                "overage": {"utilization": None, "reset_at": None, "status": None},
                "primary_claim": None,
                "next_poll_in_sec": interval,
                "poll_reason": why,
            })
        # Interruptible sleep: wakes on SIGUSR1 (system wake) or after `interval`
        if _wake.wait(interval):
            _wake.clear()
            log("woken early by SIGUSR1")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "once":
        state = fetch_usage()
        write_state(state)
        print(json.dumps(state, indent=2))
    else:
        loop()
