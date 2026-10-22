#!/usr/bin/env python3
"""Stops this instance when the Enshrouded server has had zero players for
IDLE_MINUTES. Players are read from the server's Steam A2S query port.

Safety rules:
  * Only a *successful* query reporting 0 players counts as idle. A failed
    query (server still booting, or query broken) never triggers shutdown.
  * MAX_UPTIME_HOURS is a hard cap on a single run.
  * Discord notifications are best-effort; failures never affect the logic.
"""
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request

IDLE_MINUTES = int(os.environ.get("IDLE_MINUTES", "30"))
MAX_UPTIME_HOURS = float(os.environ.get("MAX_UPTIME_HOURS", "12"))
QUERY_PORT = int(os.environ.get("QUERY_PORT", "15637"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))
PUBLIC_ADDRESS = os.environ.get("PUBLIC_ADDRESS", "")
REGION = os.environ.get("REGION", "us-east-1")
PARAM_PREFIX = os.environ.get("PARAM_PREFIX", "/enshrouded")
NEVER_QUERYABLE_WARN_MIN = 45


def log(msg):
    print(msg, flush=True)


def load_webhook():
    try:
        out = subprocess.run(
            ["aws", "ssm", "get-parameter", "--region", REGION,
             "--name", f"{PARAM_PREFIX}/discord_webhook_url",
             "--with-decryption", "--query", "Parameter.Value", "--output", "text"],
            capture_output=True, text=True, timeout=30, check=True,
        )
        return out.stdout.strip() or None
    except Exception as exc:  # noqa: BLE001
        log(f"webhook unavailable, notifications disabled: {exc}")
        return None


WEBHOOK = load_webhook()


def notify(text):
    log(f"notify: {text}")
    if not WEBHOOK:
        return
    try:
        req = urllib.request.Request(
            WEBHOOK,
            data=json.dumps({"content": text, "allowed_mentions": {"parse": []}}).encode(),
            headers={"Content-Type": "application/json",
                     "User-Agent": "enshrouded-idle-watcher/1.0"},
        )
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as exc:  # noqa: BLE001
        log(f"webhook post failed: {exc}")


def a2s_players(host="127.0.0.1", port=QUERY_PORT, timeout=3):
    """Return player count from A2S_INFO, or None if the query fails."""
    req = b"\xff\xff\xff\xffTSource Engine Query\x00"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(req, (host, port))
        data, _ = sock.recvfrom(4096)
        if data[4:5] == b"\x41":  # challenge response: resend with challenge
            sock.sendto(req + data[5:9], (host, port))
            data, _ = sock.recvfrom(4096)
        if data[4:5] != b"\x49":
            return None
        i = 6  # skip 4-byte header, type byte, protocol byte
        for _ in range(4):  # name, map, folder, game
            i = data.index(b"\x00", i) + 1
        i += 2  # app id
        return data[i]
    except (OSError, ValueError, IndexError):
        return None
    finally:
        sock.close()


# ---- join / leave announcements -------------------------------------------
# The server log announces a join in two lines (a player handle, then the name)
# and a leave with only the handle, so we remember handle -> name.
RE_HANDLE_JOIN = re.compile(r"\[server\] Machine '[^']*': Player '(\d+\(\d+\))' logged in")
RE_NAME_JOIN = re.compile(r"\[server\] Player '(.+)' logged in with Permissions")
RE_LEAVE = re.compile(r"\[session\] Player removed\. Player handle: (\d+\(\d+\))")


def clean_name(name):
    """Make a player name safe to post: no newlines, no backticks, bounded length."""
    name = " ".join(name.split()).replace("`", "'")
    return name[:40] or "(unnamed)"


def parse_event(line, state):
    """Return a message to post for this log line, or None. `state` is a dict."""
    m = RE_HANDLE_JOIN.search(line)
    if m:
        state["pending"] = m.group(1)
        return None
    m = RE_NAME_JOIN.search(line)
    if m:
        handle = state.pop("pending", None)
        name = clean_name(m.group(1))
        if handle:
            state.setdefault("names", {})[handle] = name
        return f"🟢 `{name}` joined."
    m = RE_LEAVE.search(line)
    if m:
        name = state.get("names", {}).pop(m.group(1), None)
        return f"⚪ `{name}` left." if name else None
    return None


def follow_game_log():
    """Tail the container log forever and announce joins and leaves."""
    state = {}
    while True:
        try:
            proc = subprocess.Popen(
                ["docker", "logs", "-f", "--tail", "0", "enshrouded"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
            )
            for line in proc.stdout:
                msg = parse_event(line, state)
                if msg:
                    notify(msg)
            proc.wait()
        except Exception as exc:  # noqa: BLE001
            log(f"log follower error: {exc}")
        time.sleep(5)  # container restarted or not up yet; reattach


def power_off(reason):
    notify(reason)
    subprocess.run(["systemctl", "poweroff"], check=False)
    time.sleep(3600)  # wait for systemd to take us down


def main():
    started = time.monotonic()
    idle_since = None
    announced = False
    warned_unqueryable = False
    warned_cap = False
    log(f"idle watcher up: idle={IDLE_MINUTES}m cap={MAX_UPTIME_HOURS}h port={QUERY_PORT}")
    threading.Thread(target=follow_game_log, daemon=True).start()

    while True:
        now = time.monotonic()
        uptime_min = (now - started) / 60
        players = a2s_players()

        if players is not None:
            if not announced:
                announced = True
                notify(f"🟢 Enshrouded is up. Connect to `{PUBLIC_ADDRESS}:{QUERY_PORT}`.")
            if players == 0:
                idle_since = idle_since or now
                idle_min = (now - idle_since) / 60
                if idle_min >= IDLE_MINUTES:
                    power_off(f"🔴 No players for {IDLE_MINUTES} minutes — shutting down. "
                              "Use `/enshrouded start` to bring it back.")
            else:
                idle_since = None
            log(f"players={players} idle_min={0 if idle_since is None else (now - idle_since) / 60:.1f}")
        else:
            log("query failed (booting or unreachable)")
            idle_since = None  # idle time only counts consecutive successful zero-player readings
            if not announced and not warned_unqueryable and uptime_min >= NEVER_QUERYABLE_WARN_MIN:
                warned_unqueryable = True
                notify("⚠️ Enshrouded still isn't answering queries after "
                       f"{NEVER_QUERYABLE_WARN_MIN} minutes. An admin should check the logs "
                       "(it will be stopped automatically at the uptime cap).")

        cap_min = MAX_UPTIME_HOURS * 60
        if not warned_cap and uptime_min >= cap_min - 15:
            warned_cap = True
            notify("⏰ Uptime cap reached in 15 minutes; the server will stop then. "
                   "It can be started again right after.")
        if uptime_min >= cap_min:
            power_off(f"🔴 Uptime cap of {MAX_UPTIME_HOURS:g}h reached — shutting down.")

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
