#!/usr/bin/env python3
"""
Telegram bot for zgate-edge-tunnel build bot.
Commands: /version, /latest, /build, /build_now, /status.
Token from .env TELEGRAM_TOKEN or env TELEGRAM_TOKEN.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
BOT_ROOT = BIN_DIR.parent
STATE_DIR = BOT_ROOT / "state"
STATE_JSON = STATE_DIR / "last_build.json"
LOCK_FILE = STATE_DIR / "building.lock"

# Load .env (simple KEY=VALUE)
_env_path = BOT_ROOT / ".env"
if _env_path.exists():
    for line in _env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip().strip("'\""))
TOKEN = os.environ.get("TELEGRAM_TOKEN", "").strip()
if not TOKEN:
    print("Error: TELEGRAM_TOKEN not set (add to .env or environment).", file=sys.stderr)
    sys.exit(1)

BASE = f"https://api.telegram.org/bot{TOKEN}"


def api(method, **params):
    import urllib.request
    import urllib.parse
    url = f"{BASE}/{method}"
    data = urllib.parse.urlencode(params).encode() if params else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def send_message(chat_id, text):
    api("sendMessage", chat_id=chat_id, text=text)


def get_latest_version():
    import urllib.request
    url = "https://api.github.com/repos/openziti/ziti-tunnel-sdk-c/releases/latest"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.loads(r.read().decode())
    tag = data.get("tag_name", "")
    return tag.lstrip("v") if tag else "unknown"


def read_state():
    if not STATE_JSON.exists():
        return {}
    try:
        return json.loads(STATE_JSON.read_text())
    except Exception:
        return {}


def handle_version(chat_id):
    try:
        latest = get_latest_version()
    except Exception as e:
        send_message(chat_id, f"取得最新版本失敗: {e}")
        return
    state = read_state()
    last_ver = state.get("last_version", "—")
    last_time = state.get("last_build_time", "—")
    linux_ok = "是" if (state.get("linux_path") and Path(state["linux_path"]).exists()) else "否"
    win_ok = "是" if (state.get("windows_path") and Path(state["windows_path"]).exists()) else "否"
    msg = (
        f"目前最新版本（OpenZiti tunnel）: {latest}\n"
        f"上次建置版本: {last_ver}\n"
        f"上次建置時間: {last_time}\n"
        f"Linux 二進位存在: {linux_ok}\n"
        f"Windows 二進位存在: {win_ok}"
    )
    send_message(chat_id, msg)


def handle_build(chat_id):
    if LOCK_FILE.exists():
        send_message(chat_id, "建置進行中，請稍後再試。")
        return
    # Create lock and run run_build.sh in background
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOCK_FILE.touch()
    script = BIN_DIR / "run_build.sh"
    log = STATE_DIR / "build.log"
    with open(log, "a") as f:
        subprocess.Popen(
            [str(script)],
            stdout=f,
            stderr=subprocess.STDOUT,
            cwd=str(BOT_ROOT),
            env={**os.environ},
            start_new_session=True,
        )
    send_message(chat_id, "已開始建置，完成後會更新狀態。可稍後用 /status 或 /version 查詢。")


def handle_status(chat_id):
    try:
        latest = get_latest_version()
    except Exception:
        latest = "取得失敗"
    state = read_state()
    last_ver = state.get("last_version", "—")
    building = "是" if LOCK_FILE.exists() else "否"
    linux_path = state.get("linux_path", "")
    win_path = state.get("windows_path", "")
    linux_ok = "是" if (linux_path and Path(linux_path).exists()) else "否"
    win_ok = "是" if (win_path and Path(win_path).exists()) else "否"
    msg = (
        f"最新版本: {latest}\n"
        f"上次建置版本: {last_ver}\n"
        f"正在建置中: {building}\n"
        f"Linux 二進位: {linux_ok}\n"
        f"Windows 二進位: {win_ok}"
    )
    send_message(chat_id, msg)


def main():
    offset = 0
    while True:
        try:
            r = api("getUpdates", offset=offset, timeout=60)
        except Exception as e:
            print(f"getUpdates error: {e}", file=sys.stderr)
            continue
        for u in r.get("result", []):
            offset = u["update_id"] + 1
            m = u.get("message") or u.get("edited_message")
            if not m:
                continue
            chat_id = m["chat"]["id"]
            text = (m.get("text") or "").strip()
            if text in ("/version", "/latest"):
                handle_version(chat_id)
            elif text in ("/build", "/build_now"):
                handle_build(chat_id)
            elif text == "/status":
                handle_status(chat_id)
            elif text in ("/start", "/help"):
                send_message(
                    chat_id,
                    "指令：\n/version 或 /latest — 查詢目前最新版本與上次建置\n"
                    "/build 或 /build_now — 手動觸發建置\n/status — 目前狀態",
                )


if __name__ == "__main__":
    main()
