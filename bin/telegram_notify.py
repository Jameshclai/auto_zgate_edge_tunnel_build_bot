#!/usr/bin/env python3
"""
Send one Telegram message. Used by run_build.sh to report build steps.
Reads TELEGRAM_TOKEN from .env, BUILD_CHAT_ID from env.
Usage: telegram_notify.py "message"   or   echo "message" | telegram_notify.py
If BUILD_CHAT_ID is not set, exits 0 without sending (e.g. timer-triggered build).

Copyright (c) eCloudseal Inc.  All rights reserved.  Author: Lai Hou Chang (James Lai)
"""
import json
import os
import sys
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
BOT_ROOT = BIN_DIR.parent
_env_path = BOT_ROOT / ".env"
if _env_path.exists():
    for line in _env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ[k.strip()] = v.strip().strip("'\"")

TOKEN = os.environ.get("TELEGRAM_TOKEN", "").strip()
CHAT_ID = os.environ.get("BUILD_CHAT_ID", "").strip()

if not CHAT_ID:
    sys.exit(0)
if not TOKEN:
    sys.exit(0)

def main():
    if len(sys.argv) > 1:
        text = " ".join(sys.argv[1:])
    else:
        text = sys.stdin.read().strip()
    if not text:
        sys.exit(0)
    import urllib.request
    import urllib.parse
    url = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": CHAT_ID, "text": text}).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            out = json.loads(r.read().decode())
        if not out.get("ok"):
            sys.stderr.write(f"telegram_notify: {out.get('description', 'error')}\n")
            sys.exit(1)
    except Exception as e:
        sys.stderr.write(f"telegram_notify: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
