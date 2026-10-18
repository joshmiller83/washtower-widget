#!/usr/bin/env python3
"""Watch an LG WashTower's cycle progress through the official ThinQ Connect API.

The appliance itself exposes nothing on the LAN (it only talks TLS/MQTT to LG's
cloud), so this reads the same state the ThinQ app shows.

Setup (once):
  1. Create a Personal Access Token at https://connect-pat.lgthinq.com
     (scopes: "Permission to view all devices" and "Permission to view all
     device statuses"; control scopes aren't needed).
  2. Copy it, then:   python3 washtower.py set-token --clipboard
     (or plain `set-token` to paste at a hidden prompt; stored in
     ~/.config/thinq/pat, mode 600; or set LG_THINQ_PAT instead)

Usage:
  python3 washtower.py list            # devices on the account
  python3 washtower.py status          # one-shot washer/dryer status
  python3 washtower.py watch [secs]    # live countdown, refresh every N secs (default 60)
  python3 washtower.py watch --notify  # also post a macOS notification when a cycle ends
  python3 washtower.py raw             # dump the raw state JSON (to check field names)

No third-party packages needed.
"""
import base64
import datetime as dt
import getpass
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

API = "https://api-aic.lgthinq.com"  # Americas region (US maps to "aic")
API_KEY = "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3"  # public key from LG's own SDK
COUNTRY = os.environ.get("LG_THINQ_COUNTRY", "US")
CONF = Path.home() / ".config" / "thinq"

LAUNDRY_TYPES = ("WASH", "DRYER")  # matches DEVICE_WASHER, DEVICE_DRYER, DEVICE_WASHTOWER*, ...
IDLE_STATES = {"POWER_OFF", "INITIAL", "SLEEP", "END", "STANDBY", None}


def token():
    t = os.environ.get("LG_THINQ_PAT")
    if not t and (CONF / "pat").exists():
        t = (CONF / "pat").read_text().strip()
    if not t:
        sys.exit("No token. Run `python3 washtower.py set-token` first (see header for setup).")
    return t


def client_id():
    # LG wants a stable client id per integration, so make one once and reuse it.
    f = CONF / "client_id"
    if not f.exists():
        CONF.mkdir(parents=True, exist_ok=True)
        f.write_text(f"thinq-open-{uuid.uuid4()}")
    return f.read_text().strip()


def api(path):
    req = urllib.request.Request(f"{API}/{path}", headers={
        "Authorization": f"Bearer {token()}",
        "x-country": COUNTRY,
        "x-message-id": base64.urlsafe_b64encode(uuid.uuid4().bytes)[:-2].decode(),
        "x-client-id": client_id(),
        "x-api-key": API_KEY,
        "x-service-phase": "OP",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r).get("response")
    except urllib.error.HTTPError as e:
        try:
            err = json.load(e).get("error", {})
        except Exception:
            err = {}
        raise SystemExit(f"ThinQ API {e.code}: {err.get('message', e.reason)} (code {err.get('code', '?')})")


def is_laundry(device_type):
    return any(t in device_type for t in LAUNDRY_TYPES) and "DISH" not in device_type


def laundry_devices():
    devs = api("devices") or []
    return [d for d in devs if is_laundry(d.get("deviceInfo", {}).get("deviceType", ""))]


def units(device_type, state):
    """Yield (label, unit_state) for every drum in a device's state payload.

    A WashTower comes back as {"washer": {...}, "dryer": {...}}; a lone washer or
    dryer is the state dict itself; multi-drum units are a list tagged by location.
    """
    if isinstance(state, dict) and ("washer" in state or "dryer" in state):
        for key in ("washer", "dryer"):
            if key in state:
                for label, s in units(key.upper(), state[key]):
                    yield label, s
        return
    items = state if isinstance(state, list) else [state]
    for s in items:
        if not isinstance(s, dict):
            continue
        loc = s.get("location", {}).get("locationName")
        label = device_type.replace("DEVICE_", "").replace("WASHTOWER_", "").replace("_", " ").title()
        yield (f"{label} ({loc})" if loc and loc != "MAIN" else label), s


def summarize(s):
    run = (s.get("runState") or {}).get("currentState")
    t = s.get("timer") or {}
    rem = None
    if "remainHour" in t or "remainMinute" in t:
        rem = int(t.get("remainHour") or 0) * 60 + int(t.get("remainMinute") or 0)
    total = None
    if "totalHour" in t or "totalMinute" in t:
        total = int(t.get("totalHour") or 0) * 60 + int(t.get("totalMinute") or 0)
    return run, rem, total


def fmt(label, run, rem, total):
    line = f"{label:<14} {(run or 'unknown').replace('_', ' ').lower():<16}"
    if run not in IDLE_STATES and rem is not None:
        eta = (dt.datetime.now() + dt.timedelta(minutes=rem)).strftime("%-I:%M %p")
        line += f" {rem // 60}:{rem % 60:02d} left  (done ~{eta})"
        if total:
            done = max(0.0, min(1.0, 1 - rem / total))
            line += f"  [{'#' * round(done * 20):<20}] {done:.0%}"
    return line


def snapshot():
    out = []
    for d in laundry_devices():
        info = d["deviceInfo"]
        state = api(f"devices/{d['deviceId']}/state")
        for label, s in units(info["deviceType"], state):
            out.append((f"{d['deviceId']}:{label}", label, *summarize(s)))
    return out


def notify(msg):
    subprocess.run(["osascript", "-e", f'display notification "{msg}" with title "WashTower"'], check=False)


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "status"

    if cmd == "set-token":
        if "--clipboard" in args:
            t = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout.strip()
        elif not sys.stdin.isatty():
            t = sys.stdin.read().strip()
        else:
            try:
                t = getpass.getpass("Paste ThinQ personal access token (input stays hidden), then Enter: ").strip()
            except KeyboardInterrupt:
                sys.exit("\nCancelled, nothing saved.")
        if len(t) < 20 or any(c.isspace() for c in t):
            sys.exit(f"That doesn't look like a token ({len(t)} chars). Nothing saved.")
        CONF.mkdir(parents=True, exist_ok=True)
        f = CONF / "pat"
        f.write_text(t)
        f.chmod(0o600)
        print(f"Saved token ending …{t[-4:]} ({len(t)} chars) to {f}")
    elif cmd == "list":
        for d in api("devices") or []:
            i = d.get("deviceInfo", {})
            print(f"{i.get('deviceType', '?'):<26} {i.get('alias', ''):<24} {i.get('modelName', '')}  id={d['deviceId']}")
    elif cmd == "raw":
        for d in laundry_devices():
            print(f"# {d['deviceInfo'].get('alias')} ({d['deviceInfo'].get('deviceType')})")
            print(json.dumps(api(f"devices/{d['deviceId']}/state"), indent=2))
    elif cmd == "status":
        rows = snapshot()
        if not rows:
            print("No washer/dryer found on this account. Try `list`.")
        for _, label, run, rem, total in rows:
            print(fmt(label, run, rem, total))
    elif cmd == "watch":
        nums = [a for a in args[1:] if a.isdigit()]
        every = max(30, int(nums[0])) if nums else 60
        want_notify = "--notify" in args
        last = {}
        while True:
            rows = snapshot()
            print(f"\n{dt.datetime.now():%-I:%M:%S %p}")
            for key, label, run, rem, total in rows:
                print("  " + fmt(label, run, rem, total))
                was = last.get(key)
                if want_notify and was not in IDLE_STATES and run in ("END", "POWER_OFF"):
                    notify(f"{label} finished")
                last[key] = run
            time.sleep(every)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
