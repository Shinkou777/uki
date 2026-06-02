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
import re
import signal
import socket
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

CONFIG = ROOT / "config.json"


def read_config() -> dict:
    try:
        return json.loads(CONFIG.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


# Claude Code's OAuth client (extracted from the Claude Code CLI binary).
OAUTH_REFRESH_URL = "https://platform.claude.com/v1/oauth/token"
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
# platform.claude.com rejects refresh requests without a claude-cli UA (HTTP 403).
OAUTH_USER_AGENT = "claude-cli/2.1.133 (external, cli)"

INTERVAL_ACTIVE_AC = 180
INTERVAL_ACTIVE_BATT = 300
INTERVAL_IDLE = 1800
INTERVAL_LOW_BATTERY = 1800
IDLE_THRESHOLD_SEC = 600
BACKOFF_INITIAL = 15
BACKOFF_MAX = 120
BACKOFF_MAX_AUTH = 900

# Right after the machine wakes, the network interface is often up while DNS /
# routing is not yet ready (a few seconds). Firing the API call in that window
# fails with a DNS/connection error that has nothing to do with auth. We gate on
# reachability and use a short retry instead of surfacing a scary error banner.
NETWORK_WAIT_RETRY = 8       # fast retry while waiting for the network to return
NETWORK_WAIT_RETRY_MAX = 30  # back off the wait a little if it persists
NETWORK_WAIT_FAST_TRIES = 8  # how many fast tries before slowing to the max


class AuthExpired(Exception):
    """The OAuth refresh token itself was rejected / missing — re-login needed.
    Distinct from a transient network failure during refresh."""


def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}\n"
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(line)
    if sys.stderr.isatty():
        sys.stderr.write(line)


def _detect_keychain_account() -> str:
    """Read the existing keychain entry's 'acct' attribute so writes target
    the same record regardless of which user / machine is running this."""
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE],
            capture_output=True, text=True, check=True,
        ).stdout
        for line in out.splitlines():
            m = re.search(r'"acct"<blob>="([^"]*)"', line)
            if m:
                return m.group(1)
    except Exception:
        pass
    return os.getenv("USER", "")


def read_oauth_record() -> dict:
    out = subprocess.check_output(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        text=True,
    ).strip()
    return json.loads(out)


def write_oauth_record(record: dict) -> None:
    account = _detect_keychain_account()
    if not account:
        raise RuntimeError("could not determine keychain account for write")
    subprocess.run(
        [
            "security", "add-generic-password",
            "-s", KEYCHAIN_SERVICE,
            "-a", account,
            "-w", json.dumps(record),
            "-U",  # update if exists
        ],
        check=True,
        capture_output=True,
    )


def get_oauth_token() -> str:
    return read_oauth_record()["claudeAiOauth"]["accessToken"]


def refresh_oauth_token() -> str:
    """Use the keychain refresh token to mint a new access token, persist
    it back to keychain, and return the new access token. Raises on
    failure."""
    record = read_oauth_record()
    oauth = record.get("claudeAiOauth", {})
    rt = oauth.get("refreshToken")
    if not rt:
        raise RuntimeError("no refreshToken in keychain")
    body = json.dumps({
        "grant_type": "refresh_token",
        "refresh_token": rt,
        "client_id": OAUTH_CLIENT_ID,
    }).encode()
    req = urllib.request.Request(
        OAUTH_REFRESH_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "User-Agent": OAUTH_USER_AGENT,
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        new = json.loads(resp.read().decode())
    if "access_token" not in new:
        raise RuntimeError(f"refresh response missing access_token: {new}")
    oauth["accessToken"] = new["access_token"]
    if new.get("refresh_token"):
        oauth["refreshToken"] = new["refresh_token"]
    if "expires_in" in new:
        oauth["expiresAt"] = int((time.time() + int(new["expires_in"])) * 1000)
    record["claudeAiOauth"] = oauth
    write_oauth_record(record)
    log("OAuth token refreshed via refresh_token")
    return oauth["accessToken"]


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


def _do_fetch(token: str) -> dict:
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
    with urllib.request.urlopen(req, timeout=15) as resp:
        return {k.lower(): v for k, v in resp.headers.items()}


def _do_fetch_apikey(api_key: str) -> dict:
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 1,
        "messages": [{"role": "user", "content": "."}],
    }).encode()
    req = urllib.request.Request(
        API_URL,
        data=body,
        method="POST",
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return {k.lower(): v for k, v in resp.headers.items()}


def _parse_claude_headers(headers: dict) -> dict:
    def num(k, conv=float):
        v = headers.get(k)
        try:
            return conv(v) if v is not None else None
        except (ValueError, TypeError):
            return None

    return {
        "fetched_at": int(time.time()),
        "api_source": "claude",
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


def fetch_usage() -> dict:
    config = read_config()
    source = config.get("api_source", "claude_oauth")

    if source == "claude_apikey":
        key = config.get("api_key", "")
        if not key:
            raise RuntimeError("config.json に Claude API key が未設定")
        try:
            headers = _do_fetch_apikey(key)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                headers = {k.lower(): v for k, v in e.headers.items()}
            else:
                log(f"HTTP {e.code}: {e.reason}")
                raise
        return _parse_claude_headers(headers)

    # claude_oauth (default) — original keychain-based flow
    token = get_oauth_token()
    try:
        headers = _do_fetch(token)
    except urllib.error.HTTPError as e:
        if e.code == 429:
            headers = {k.lower(): v for k, v in e.headers.items()}
        elif e.code == 401:
            log("HTTP 401: refreshing OAuth token and retrying")
            try:
                new_token = refresh_oauth_token()
            except urllib.error.HTTPError as refresh_err:
                # Token endpoint rejected the refresh token (401/403/...) — the
                # refresh token is expired or revoked. Genuine auth expiry.
                log(f"refresh rejected: HTTP {refresh_err.code} -> re-login required")
                raise AuthExpired(f"refresh rejected: HTTP {refresh_err.code}")
            except urllib.error.URLError as refresh_err:
                # Network problem reaching the token endpoint — NOT auth. Let the
                # loop classify it as a transient network error.
                log(f"refresh network error: {refresh_err}")
                raise
            except Exception as refresh_err:
                # e.g. no refreshToken in keychain — re-login required.
                log(f"refresh failed: {type(refresh_err).__name__}: {refresh_err}")
                raise AuthExpired(str(refresh_err))
            try:
                headers = _do_fetch(new_token)
            except urllib.error.HTTPError as retry_err:
                if retry_err.code == 429:
                    headers = {k.lower(): v for k, v in retry_err.headers.items()}
                else:
                    log(f"HTTP {retry_err.code} after refresh: {retry_err.reason}")
                    raise
        else:
            log(f"HTTP {e.code}: {e.reason}")
            raise
    return _parse_claude_headers(headers)


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


def _is_auth_error(e: Exception) -> bool:
    if isinstance(e, AuthExpired):
        return True
    s = str(e)
    return "401" in s or "refreshToken" in s or "no refreshToken" in s


def _is_network_error(e: Exception) -> bool:
    """Transient connectivity failure (DNS not ready, no route, timeout) — the
    kind we see for a few seconds right after the machine wakes. NOT an HTTP
    error from the API (those carry a status code and are handled separately)."""
    if isinstance(e, urllib.error.HTTPError):
        return False
    if isinstance(e, (urllib.error.URLError, socket.gaierror, socket.timeout, TimeoutError, OSError)):
        return True
    s = str(e).lower()
    return any(t in s for t in (
        "urlerror", "nodename nor servname", "not known", "timed out",
        "connection refused", "network is unreachable", "no route to host",
        "temporary failure in name resolution",
    ))


def _network_reachable(host: str = "api.anthropic.com", timeout: float = 3.0) -> bool:
    """Cheap pre-flight: can we resolve + open a TCP socket to the API host?
    Catches the post-wake window where the interface is up but DNS/routing
    isn't, so we never fire a doomed request that looks like a hard error."""
    try:
        infos = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
    except OSError:
        return False
    for family, socktype, proto, _canon, sockaddr in infos:
        s = socket.socket(family, socktype, proto)
        s.settimeout(timeout)
        try:
            s.connect(sockaddr)
            return True
        except OSError:
            continue
        finally:
            s.close()
    return False


def _network_wait_state(interval: int, tries: int) -> dict:
    return {
        "fetched_at": int(time.time()),
        "api_source": "claude",
        "network_wait": True,
        "error": None,
        "auth_expired": False,
        "five_hour": {"utilization": None, "reset_at": None, "status": None},
        "seven_day": {"utilization": None, "reset_at": None, "status": None},
        "overage": {"utilization": None, "reset_at": None, "status": None},
        "primary_claim": None,
        "next_poll_in_sec": interval,
        "poll_reason": f"network-wait #{tries}",
    }


def _notify_auth_expired() -> None:
    try:
        subprocess.run([
            "osascript", "-e",
            'display notification "認証の有効期限が切れました。フローターの「再認証」ボタンを押してください。" '
            'with title "ClaudeFloater" subtitle "認証失敗"'
        ], capture_output=True, timeout=5)
    except Exception:
        pass


def loop() -> None:
    log("monitor daemon starting")
    consecutive_errors = 0
    auth_notified = False
    net_wait_count = 0
    while True:
        interval = 300

        # Reachability gate: skip the doomed request while the network is still
        # coming back (typical for a few seconds after wake). Show a calm
        # "waiting for network" state and retry quickly instead of an error.
        if not _network_reachable():
            net_wait_count += 1
            interval = NETWORK_WAIT_RETRY if net_wait_count <= NETWORK_WAIT_FAST_TRIES else NETWORK_WAIT_RETRY_MAX
            log(f"network unreachable, waiting (#{net_wait_count}, retry {interval}s)")
            write_state(_network_wait_state(interval, net_wait_count))
            if _wake.wait(interval):
                _wake.clear()
            continue
        net_wait_count = 0

        try:
            state = fetch_usage()
            consecutive_errors = 0
            auth_notified = False
            interval, why = pick_interval()
            state["next_poll_in_sec"] = interval
            state["poll_reason"] = why
            write_state(state)
            u5 = state["five_hour"]["utilization"] or 0
            u7 = state["seven_day"]["utilization"] or 0
            log(f"5h={u5:.0%} 7d={u7:.0%} -> sleep {interval}s ({why})")
        except Exception as e:
            # Transient connectivity failure that slipped past the gate (DNS
            # resolved but the TLS connect dropped, etc.) — treat as network-wait,
            # never as a hard/auth error.
            if _is_network_error(e):
                net_wait_count += 1
                interval = NETWORK_WAIT_RETRY if net_wait_count <= NETWORK_WAIT_FAST_TRIES else NETWORK_WAIT_RETRY_MAX
                log(f"network error: {type(e).__name__}: {e} (network-wait #{net_wait_count}, retry {interval}s)")
                write_state(_network_wait_state(interval, net_wait_count))
                if _wake.wait(interval):
                    _wake.clear()
                continue
            net_wait_count = 0
            consecutive_errors += 1
            auth_expired = _is_auth_error(e)
            cap = BACKOFF_MAX_AUTH if auth_expired else BACKOFF_MAX
            backoff = min(BACKOFF_INITIAL * (2 ** (consecutive_errors - 1)), cap)
            interval = int(backoff)
            log(f"ERROR: {type(e).__name__}: {e} (retry #{consecutive_errors} in {interval}s){' [auth_expired]' if auth_expired else ''}")
            if auth_expired and not auth_notified:
                _notify_auth_expired()
                auth_notified = True
            write_state({
                "fetched_at": int(time.time()),
                "api_source": "claude",
                "error": f"{type(e).__name__}: {e}",
                "auth_expired": auth_expired,
                "five_hour": {"utilization": None, "reset_at": None, "status": None},
                "seven_day": {"utilization": None, "reset_at": None, "status": None},
                "overage": {"utilization": None, "reset_at": None, "status": None},
                "primary_claim": None,
                "next_poll_in_sec": interval,
                "poll_reason": f"backoff #{consecutive_errors}" + (" (auth)" if auth_expired else ""),
            })
        # Interruptible sleep: wakes on SIGUSR1 (system wake) or after `interval`
        if _wake.wait(interval):
            _wake.clear()
            consecutive_errors = 0
            log("woken early by SIGUSR1")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "once":
        state = fetch_usage()
        write_state(state)
        print(json.dumps(state, indent=2))
    else:
        loop()
