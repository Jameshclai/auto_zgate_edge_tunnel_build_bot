#!/usr/bin/env python3
"""
Telegram bot for zgate-edge-tunnel build bot.
Commands: /version, /latest, /build, /stop_build, /status, /clean_sdk, /clean_tunnel, /clean_all.
Token from .env TELEGRAM_TOKEN or env TELEGRAM_TOKEN.

Copyright (c) eCloudseal Inc.  All rights reserved.  Author: Lai Hou Chang (James Lai)
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
BOT_ROOT = BIN_DIR.parent
STATE_DIR = BOT_ROOT / "state"
STATE_JSON = STATE_DIR / "last_build.json"
LOCK_FILE = STATE_DIR / "building.lock"
AWAIT_SUDO_JSON = STATE_DIR / "telegram_await_sudo.json"
AWAIT_SUDO_EXPIRE_SEC = 300  # 5 分鐘內未回覆則過期

# Load .env (simple KEY=VALUE); .env overrides existing env so token is always from file
_env_path = BOT_ROOT / ".env"
if _env_path.exists():
    for line in _env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ[k.strip()] = v.strip().strip("'\"")
TOKEN = os.environ.get("TELEGRAM_TOKEN", "").strip()
if not TOKEN:
    print("Error: TELEGRAM_TOKEN not set (add to .env or environment).", file=sys.stderr)
    sys.exit(1)

BASE = f"https://api.telegram.org/bot{TOKEN}"


def api(method, timeout_conn=30, **params):
    import urllib.request
    import urllib.parse
    url = f"{BASE}/{method}"
    data = urllib.parse.urlencode(params).encode() if params else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout_conn) as r:
            out = json.loads(r.read().decode())
    except Exception as e:
        print(f"API {method} error: {e}", file=sys.stderr, flush=True)
        raise
    if not out.get("ok"):
        raise RuntimeError(out.get("description", "API error"))
    return out


def send_message(chat_id, text, parse_mode=None, reply_markup=None):
    try:
        params = {"chat_id": chat_id, "text": text}
        if parse_mode:
            params["parse_mode"] = parse_mode
        if reply_markup is not None:
            import json as _json
            params["reply_markup"] = _json.dumps(reply_markup) if isinstance(reply_markup, dict) else reply_markup
        api("sendMessage", **params)
    except Exception as e:
        print(f"send_message to {chat_id} failed: {e}", file=sys.stderr, flush=True)
        raise


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


def _read_await_sudo():
    if not AWAIT_SUDO_JSON.exists():
        return {}
    try:
        return json.loads(AWAIT_SUDO_JSON.read_text())
    except Exception:
        return {}


def _write_await_sudo(data):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    AWAIT_SUDO_JSON.write_text(json.dumps(data, ensure_ascii=False))


def _get_await_entry(chat_id):
    """回傳 (entry_dict 或 None, 'ok'|'expired'|'no')。entry 可能為 awaiting 'platform'、'sudo' 或 'clean_all'，且可有 'platform' 鍵。"""
    from datetime import datetime, timezone
    data = _read_await_sudo()
    entry = data.get(str(chat_id))
    if not entry or entry.get("awaiting") not in ("platform", "clean_all"):
        return None, "no"
    since = entry.get("since", "")
    try:
        dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        if (now - dt).total_seconds() > AWAIT_SUDO_EXPIRE_SEC:
            data.pop(str(chat_id), None)
            _write_await_sudo(data)
            return None, "expired"
    except Exception:
        pass
    return entry, "ok"


def _clear_await_sudo(chat_id):
    data = _read_await_sudo()
    data.pop(str(chat_id), None)
    _write_await_sudo(data)


def _is_build_really_running():
    """若 run_build.sh 未在執行則視為殘留鎖定，移除 building.lock 並回傳 False；有在執行則回傳 True。"""
    try:
        r = subprocess.run(
            ["pgrep", "-f", "run_build.sh"],
            capture_output=True,
            text=True,
            timeout=5,
            cwd=str(BOT_ROOT),
        )
        if r.returncode == 0 and (r.stdout or "").strip():
            return True
    except Exception:
        pass
    if LOCK_FILE.exists():
        try:
            LOCK_FILE.unlink()
        except Exception:
            pass
    return False


def _run_ps_grep():
    """執行 ps 檢查是否仍有 run_build 或 builder 相關程序，回傳 (returncode, stdout 前 800 字)。"""
    try:
        r = subprocess.run(
            ["ps", "aux"],
            capture_output=True,
            text=True,
            timeout=5,
            cwd=str(BOT_ROOT),
        )
        if r.returncode != 0:
            return r.returncode, (r.stderr or "")[:800]
        lines = [line for line in (r.stdout or "").splitlines() if ("run_build" in line or "zgate-sdk-c-builder" in line or "zgate-tunnel-sdk-c-builder" in line) and "grep" not in line]
        return 0, "\n".join(lines)[:800] if lines else "（無相關程序）"
    except Exception as e:
        return -1, str(e)[:400]


def handle_stop_build(chat_id):
    """中斷目前建置：結束所有相關程序、移除鎖定與建置中產物（output/work），以 ps 確認並詳細回報。"""
    if not LOCK_FILE.exists():
        send_message(chat_id, "目前沒有進行中的建置。")
        return
    if not _is_build_really_running():
        try:
            LOCK_FILE.unlink()
        except Exception:
            pass
        send_message(chat_id, "建置已結束或無執行中的程序，已清除鎖定。")
        return

    send_message(chat_id, "🛑 正在中斷建置…")

    # 1) 結束 run_build.sh 與 builder 內建置程序
    try:
        subprocess.run(["pkill", "-f", "run_build.sh"], capture_output=True, timeout=5, cwd=str(BOT_ROOT))
        subprocess.run(["pkill", "-f", "zgate-sdk-c-builder/build.sh"], capture_output=True, timeout=5, cwd=str(BOT_ROOT))
        subprocess.run(["pkill", "-f", "zgate-tunnel-sdk-c-builder/build.sh"], capture_output=True, timeout=5, cwd=str(BOT_ROOT))
    except Exception as e:
        send_message(chat_id, f"❌ 發送中斷信號時發生錯誤：{e}")
        return
    send_message(chat_id, "• 已對 run_build.sh 與兩 builder 的 build.sh 發送終止信號。")

    # 2) 短暫等待後以 ps 確認
    import time
    time.sleep(2)
    rc, ps_out = _run_ps_grep()
    if rc == 0:
        send_message(chat_id, f"【ps 確認】\n{ps_out}")
    else:
        send_message(chat_id, f"【ps 確認】執行異常（code={rc}）：{ps_out}")

    # 3) 移除鎖定
    if LOCK_FILE.exists():
        try:
            LOCK_FILE.unlink()
            send_message(chat_id, "• 已移除 building.lock。")
        except Exception as e:
            send_message(chat_id, f"• 移除 building.lock 失敗：{e}")
    else:
        send_message(chat_id, "• building.lock 已不存在。")

    # 4) 移除建置到一半的 output、work 目錄
    sdk_root, tunnel_root = _builder_roots()
    ok1, msg1 = _clean_builder_output_work(sdk_root, "zgate-sdk-c-builder")
    send_message(chat_id, f"• {msg1}")
    ok2, msg2 = _clean_builder_output_work(tunnel_root, "zgate-tunnel-sdk-c-builder")
    send_message(chat_id, f"• {msg2}")

    # 5) 再次 ps 確認無殘留程序
    time.sleep(1)
    rc2, ps_out2 = _run_ps_grep()
    if "無相關程序" in ps_out2 or (rc2 == 0 and not ps_out2.strip().splitlines()):
        send_message(chat_id, "✅ 建置已完全中斷並清理，所有相關程序已結束，建置中產物已移除。可重新使用 /build 觸發新建置。")
    else:
        send_message(chat_id, f"⚠️ 再次 ps 檢查仍可能有殘留程序，請手動確認：\n{ps_out2}\n\n鎖定與 output/work 已清理，可重新 /build。")


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


def _start_build(chat_id, platform="all"):
    """實際啟動建置，傳入 BUILD_CHAT_ID、BUILD_PLATFORM；SUDO_PASS 由 .env 提供（安裝時設定）。"""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOCK_FILE.touch()
    script = BIN_DIR / "run_build.sh"
    log = STATE_DIR / "build.log"
    env = {**os.environ, "BUILD_CHAT_ID": str(chat_id), "BUILD_PLATFORM": str(platform)}
    with open(log, "a") as f:
        subprocess.Popen(
            [str(script)],
            stdout=f,
            stderr=subprocess.STDOUT,
            cwd=str(BOT_ROOT),
            env=env,
            start_new_session=True,
        )
    build_start_msg = {
        "all": "已開始建置 ZGate Edge Tunnel（全部平台：Linux x64/arm64/arm、Windows、macOS x64/arm64）。每個步驟與依賴安裝／各平台建置進度將推送到此對話。",
        "linux": "已開始建置 ZGate Edge Tunnel（Linux：x64、arm64、arm）。每個步驟與編譯進度將推送到此對話。",
        "windows": "已開始建置 ZGate Edge Tunnel（Windows）。每個步驟與編譯進度將推送到此對話。",
        "macos": "已開始建置 ZGate Edge Tunnel（macOS：x64、arm64）。每個步驟與編譯進度將推送到此對話。",
    }.get(platform, f"已開始建置 ZGate Edge Tunnel（{platform}）。每個步驟會推送到此對話。")
    send_message(
        chat_id,
        f"{build_start_msg}\n可稍後用 /status 或 /version 查詢結果。",
    )


def handle_build(chat_id):
    if LOCK_FILE.exists() and _is_build_really_running():
        send_message(chat_id, "建置進行中，請稍後再試。可傳送 /stop_build 中斷建置。")
        return
    from datetime import datetime, timezone
    # 詢問建置平台；可點選按鈕或直接輸入 all/linux/windows/macos
    _write_await_sudo({
        **(_read_await_sudo()),
        str(chat_id): {"awaiting": "platform", "since": datetime.now(timezone.utc).isoformat()},
    })
    keyboard = {
        "keyboard": [["all", "linux"], ["windows", "macos"]],
        "one_time_keyboard": True,
        "resize_keyboard": True,
    }
    send_message(
        chat_id,
        "請選擇建置平台（點選下方按鈕或直接輸入）：\n"
        "• all — 全部平台（Linux x64/arm64/arm、macOS、Windows）\n"
        "• linux — 僅 Linux（x64、arm64、arm）\n"
        "• windows — 僅 Windows\n"
        "• macos — 僅 macOS\n"
        "（約 5 分鐘內未選擇將取消，可重新發送 /build）",
        reply_markup=keyboard,
    )


def _builder_roots():
    """與 run_build.sh 一致：取得 SDK 與 Tunnel builder 根目錄。"""
    sdk = os.environ.get("SDK_BUILDER_ROOT", "").strip() or str(BOT_ROOT.parent / "zgate-sdk-c-builder")
    tunnel = os.environ.get("TUNNEL_BUILDER_ROOT", "").strip() or str(BOT_ROOT.parent / "zgate-tunnel-sdk-c-builder")
    return Path(sdk).resolve(), Path(tunnel).resolve()


def _allowed_builder_dir(path: Path) -> bool:
    """僅允許 BOT_ROOT 同層的 zgate-sdk-c-builder / zgate-tunnel-sdk-c-builder。"""
    try:
        r = path.resolve()
        return r.parent == BOT_ROOT.parent.resolve() and r.name in (
            "zgate-sdk-c-builder",
            "zgate-tunnel-sdk-c-builder",
        )
    except Exception:
        return False


def _delete_builder_directory(builder_root: Path, label: str):
    """
    刪除整個 builder 專案目錄（僅允許 _allowed_builder_dir 的路徑）。
    回傳 (成功, 訊息文字)。
    """
    import shutil
    try:
        root = Path(builder_root).resolve()
        if not root.is_dir():
            return False, f"{label} 路徑不存在：{root}"
        if not _allowed_builder_dir(root):
            return False, f"不允許刪除此路徑：{root}"
        shutil.rmtree(root)
        return True, f"已刪除 {label} 專案目錄：{root}"
    except Exception as e:
        return False, f"{label} 刪除失敗：{e}"


def _clean_builder_output_work(builder_root: Path, label: str):
    """
    刪除 builder 的 output 與 work 目錄（僅允許此兩目錄）。
    回傳 (成功, 訊息文字)。
    """
    try:
        root = Path(builder_root).resolve()
        if not root.is_dir():
            return False, f"{label} 路徑不存在：{root}"
        removed = []
        for name in ("output", "work"):
            d = root / name
            if d.resolve().parent != root:
                continue
            if d.exists():
                try:
                    import shutil
                    shutil.rmtree(d)
                    removed.append(name)
                except Exception as e:
                    return False, f"刪除 {name} 時錯誤：{e}"
        if not removed:
            return True, f"{label} 的 output 與 work 本來就是空的或不存在，無需刪除。"
        return True, f"已刪除 {label}：{', '.join(removed)}。"
    except Exception as e:
        return False, str(e)


def handle_clean_sdk(chat_id):
    if LOCK_FILE.exists() and _is_build_really_running():
        send_message(chat_id, "建置進行中，無法清理。請等建置完成後再試。")
        return
    sdk_root, _ = _builder_roots()
    ok, msg = _clean_builder_output_work(sdk_root, "zgate-sdk-c-builder")
    send_message(chat_id, f"清理 SDK：{msg}")


def handle_clean_tunnel(chat_id):
    if LOCK_FILE.exists() and _is_build_really_running():
        send_message(chat_id, "建置進行中，無法清理。請等建置完成後再試。")
        return
    _, tunnel_root = _builder_roots()
    ok, msg = _clean_builder_output_work(tunnel_root, "zgate-tunnel-sdk-c-builder")
    send_message(chat_id, f"清理 Tunnel：{msg}")


def _do_clean_all(chat_id):
    """實際執行 clean_all 刪除（兩專案整個目錄）。"""
    sdk_root, tunnel_root = _builder_roots()
    send_message(chat_id, "正在刪除 zgate-sdk-c-builder…")
    ok1, msg1 = _delete_builder_directory(sdk_root, "zgate-sdk-c-builder")
    send_message(chat_id, f"{'✅' if ok1 else '❌'} zgate-sdk-c-builder：{msg1}")
    send_message(chat_id, "正在刪除 zgate-tunnel-sdk-c-builder…")
    ok2, msg2 = _delete_builder_directory(tunnel_root, "zgate-tunnel-sdk-c-builder")
    send_message(chat_id, f"{'✅' if ok2 else '❌'} zgate-tunnel-sdk-c-builder：{msg2}")
    send_message(chat_id, f"清理全部完成。\n• SDK：{msg1}\n• Tunnel：{msg2}")


def handle_clean_all(chat_id):
    """收到 /clean_all 時不立即執行，僅寫入等候確認狀態並送出確認訊息；實際刪除需使用者回覆確認後才執行。"""
    had_lock = LOCK_FILE.exists()
    if had_lock and _is_build_really_running():
        send_message(chat_id, "建置進行中，無法清理。請等建置完成後再試。")
        return
    if had_lock:
        send_message(chat_id, "已清除殘留的建置鎖定檔，繼續清理流程。")
    from datetime import datetime, timezone
    # 僅詢問確認，絕不在此處執行刪除
    _write_await_sudo({
        **(_read_await_sudo()),
        str(chat_id): {"awaiting": "clean_all", "since": datetime.now(timezone.utc).isoformat()},
    })
    send_message(
        chat_id,
        "⚠️ 刪除前請先確認\n\n"
        "即將刪除以下兩專案「整個目錄」：\n"
        "• zgate-sdk-c-builder\n"
        "• zgate-tunnel-sdk-c-builder\n\n"
        "尚未執行任何刪除。請「回覆此訊息」輸入下列其中一項才會動作：\n"
        "• 確認、是、yes — 執行刪除\n"
        "• 取消、否、no — 放棄（不刪除）\n\n"
        "（約 5 分鐘內未回覆將自動取消，可重新發送 /clean_all）",
    )


def _format_latest_version_tree(version_dir):
    """將 latest_version/<ver>/ 目錄格式化成樹狀列出（linux/x64|arm64|arm/、windows/ 與檔名）。"""
    root = Path(version_dir)
    if not root.is_dir():
        return ""
    ver_name = root.name
    lines = [f"【已複製目錄】latest_version/{ver_name}/"]
    for platform in ("linux", "windows", "macos"):
        p = root / platform
        if not p.is_dir():
            continue
        lines.append(f"  {platform}/")
        for item in sorted(p.iterdir()):
            if item.is_dir():
                for f in sorted(item.iterdir()):
                    if f.is_file():
                        lines.append(f"    {item.name}/{f.name}")
            elif item.is_file():
                lines.append(f"    • {item.name}")
    return "\n".join(lines) if len(lines) > 1 else ""


def _status_packages_downloaded():
    """回傳兩行字串：zgate-sdk-c-builder、zgate-tunnel-sdk-c-builder 是否已下載。"""
    sdk_root, tunnel_root = _builder_roots()
    sdk_ok = sdk_root.is_dir() and (sdk_root / "build.sh").exists()
    tunnel_ok = tunnel_root.is_dir() and (tunnel_root / "build.sh").exists()
    return (
        f"• zgate-sdk-c-builder：{'已下載' if sdk_ok else '未下載'}\n"
        f"• zgate-tunnel-sdk-c-builder：{'已下載' if tunnel_ok else '未下載'}"
    )


def _status_build_progress():
    """若正在建置，從 build.log 與 builder 目錄推斷目前步驟與各平台狀態；否則回傳空字串。"""
    if not LOCK_FILE.exists() or not _is_build_really_running():
        return ""
    log_file = BOT_ROOT / "state" / "build.log"
    _, tunnel_root = _builder_roots()
    tb_latest = tunnel_root / "latest_version"
    tb_output = tunnel_root / "output"

    step = ""
    detail = ""
    try:
        if log_file.exists():
            tail = log_file.read_text(encoding="utf-8", errors="ignore").strip()
            last_lines = tail.split("\n")[-100:] if "\n" in tail else [tail]
            for line in reversed(last_lines):
                if "Calling" in line and "build.sh" in line:
                    if "zgate-tunnel-sdk-c" in line or "zgate-tunnel-sdk-c-builder" in line:
                        step = "2"
                        break
                    if "zgate-sdk-c-builder" in line or "zgate-sdk-c" in line:
                        step = "1"
                        break
        if step == "1":
            for line in reversed((log_file.read_text(encoding="utf-8", errors="ignore").split("\n")[-80:])):
                m = re.search(r"Installing\s+(\d+)/(\d+)\s+(\S+)", line)
                if m:
                    detail = f"vcpkg 依賴安裝中：{m.group(1)}/{m.group(2)} {m.group(3)[:40]}"
                    break
                m = re.search(r"Building\s+(\S+)", line)
                if m:
                    detail = f"編譯中：{m.group(1)[:50]}"
                    break
            if not detail:
                detail = "編譯 zgate-sdk-c 與 vcpkg 依賴中…"
        elif step == "2":
            linux_archs, windows_ok, macos_archs = [], False, []
            if tb_latest.is_dir():
                for vdir in tb_latest.iterdir():
                    if not vdir.is_dir():
                        continue
                    v = vdir
                    if (v / "linux/x64/zgate-edge-tunnel").exists():
                        linux_archs.append("x64")
                    if (v / "linux/arm64/zgate-edge-tunnel").exists():
                        linux_archs.append("arm64")
                    if (v / "linux/arm/zgate-edge-tunnel").exists():
                        linux_archs.append("arm")
                    if (v / "windows/zgate-edge-tunnel.exe").exists():
                        windows_ok = True
                    if (v / "macos/x64/zgate-edge-tunnel").exists():
                        macos_archs.append("x64")
                    if (v / "macos/arm64/zgate-edge-tunnel").exists():
                        macos_archs.append("arm64")
                    if linux_archs or windows_ok or macos_archs:
                        break
            if not linux_archs and not windows_ok and not macos_archs and tb_output.is_dir():
                for out_ver in tb_output.glob("zgate-tunnel-sdk-c-*"):
                    if not out_ver.is_dir():
                        continue
                    o = out_ver
                    if (o / "build-ci-linux-x64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel").exists():
                        linux_archs.append("x64")
                    if (o / "build-ci-linux-arm64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel").exists():
                        linux_archs.append("arm64")
                    if (o / "build-ci-linux-arm/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel").exists():
                        linux_archs.append("arm")
                    if (o / "build-ci-windows-x64-mingw/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel.exe").exists():
                        windows_ok = True
                    if (o / "build-ci-macOS-x64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel").exists():
                        macos_archs.append("x64")
                    if (o / "build-ci-macOS-arm64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel").exists():
                        macos_archs.append("arm64")
                    if linux_archs or windows_ok or macos_archs:
                        break
            done_parts = []
            if linux_archs:
                done_parts.append(f"Linux ({','.join(linux_archs)})")
            if windows_ok:
                done_parts.append("Windows")
            if macos_archs:
                done_parts.append(f"macOS ({','.join(macos_archs)})")
            building_parts = []
            if not linux_archs or len(linux_archs) < 3:
                building_parts.append("Linux (x64、arm64、arm)")
            if not windows_ok:
                building_parts.append("Windows")
            if not macos_archs or len(macos_archs) < 2:
                building_parts.append("macOS (x64、arm64)")
            if done_parts:
                detail = f"【已建置完成】{'、'.join(done_parts)}"
                if building_parts:
                    detail += f"；【尚在建置】{'、'.join(building_parts)}"
            else:
                detail = "【尚在建置】Linux (x64、arm64、arm)、Windows、macOS (x64、arm64)，尚未產出二進位。"
    except Exception as e:
        detail = f"（無法讀取進度：{e}）"
    if not step:
        return "【建置中】目前步驟辨識中…（請稍後再查）"
    return f"【步驟 {step}/4 進行中】{detail}"


def handle_status(chat_id):
    try:
        latest = get_latest_version()
    except Exception:
        latest = "取得失敗"
    state = read_state()
    last_ver = state.get("last_version", "—")
    last_time = state.get("last_build_time", "—")
    building = "是" if (LOCK_FILE.exists() and _is_build_really_running()) else "否"
    linux_path = state.get("linux_path", "")
    win_path = state.get("windows_path", "")
    linux_ok = "是" if (linux_path and Path(linux_path).exists()) else "否"
    win_ok = "是" if (win_path and Path(win_path).exists()) else "否"

    blocks = [
        "📋 目前狀態",
        "",
        "【套件下載狀態】",
        _status_packages_downloaded(),
        "",
        "【建置狀態】",
        f"• 正在建置中：{building}",
    ]
    if building == "是":
        progress = _status_build_progress()
        if progress:
            blocks.append(progress)
    blocks.extend([
        "",
        "【版本與產出】",
        f"• OpenZiti tunnel 最新版本：{latest}",
        f"• 上次建置版本：{last_ver}",
        f"• 上次建置時間：{last_time}",
        f"• Linux 二進位存在：{linux_ok}",
        f"• Windows 二進位存在：{win_ok}",
    ])
    version_dir = state.get("latest_version_dir", "")
    tree = _format_latest_version_tree(version_dir)
    if tree:
        blocks.extend(["", "【latest_version 目錄】", "```", tree, "```"])
    msg = "\n".join(blocks)
    if tree:
        send_message(chat_id, msg, parse_mode="Markdown")
    else:
        send_message(chat_id, msg)


def main():
    bot_name = os.environ.get("TELEGRAM_BOT_NAME", "您的 Bot").strip() or "您的 Bot"
    print(f"Bot starting. 請在 Telegram 搜尋並開啟您的機器人「{bot_name}」後傳送 /start", file=sys.stderr, flush=True)
    offset = 0
    while True:
        try:
            # Long poll: server holds up to 65s; client timeout 70s so we get the response
            r = api("getUpdates", offset=offset, timeout=65, timeout_conn=70)
        except Exception as e:
            # Timeout after ~65s with no message is normal
            if "timed out" not in str(e).lower():
                print(f"getUpdates error: {e}", file=sys.stderr, flush=True)
            continue
        for u in r.get("result", []):
            offset = u["update_id"] + 1
            m = u.get("message") or u.get("edited_message")
            if not m:
                continue
            chat_id = m["chat"]["id"]
            text = (m.get("text") or "").strip()
            print(f"Received: chat_id={chat_id} text={text!r}", file=sys.stderr, flush=True)
            try:
                if text in ("/version", "/latest"):
                    handle_version(chat_id)
                elif text == "/build":
                    handle_build(chat_id)
                elif text == "/stop_build":
                    handle_stop_build(chat_id)
                elif text == "/status":
                    handle_status(chat_id)
                elif text == "/clean_sdk":
                    handle_clean_sdk(chat_id)
                elif text == "/clean_tunnel":
                    handle_clean_tunnel(chat_id)
                elif text == "/clean_all":
                    handle_clean_all(chat_id)
                elif text in ("/start", "/help"):
                    send_message(
                        chat_id,
                        "指令：\n"
                        "/version 或 /latest — 查詢最新版本與上次建置\n"
                        "/build — 手動觸發建置（會先詢問平台：all/linux/windows/macos；sudo 使用安裝時設定的 .env）\n"
                        "/stop_build — 中斷目前進行中的建置\n"
                        "/status — 目前狀態\n"
                        "/clean_sdk — 刪除 zgate-sdk-c-builder 的 output 與 work\n"
                        "/clean_tunnel — 刪除 zgate-tunnel-sdk-c-builder 的 output 與 work\n"
                        "/clean_all — 刪除上述兩專案整個目錄（會先詢問確認，回覆「確認」或「是」後才執行；下次 /build 會從 GitHub 重新下載）",
                    )
                else:
                    entry, await_status = _get_await_entry(chat_id)
                    if await_status == "expired":
                        send_message(chat_id, "等候已逾時，請重新發送指令（/build 或 /clean_all）。")
                    elif await_status == "ok" and entry:
                        if entry.get("awaiting") == "platform":
                            plat = (text or "").strip().lower()
                            if plat not in ("all", "linux", "windows", "macos"):
                                send_message(chat_id, "請輸入 all、linux、windows 或 macos 其中一項。")
                            else:
                                _clear_await_sudo(chat_id)
                                if LOCK_FILE.exists() and _is_build_really_running():
                                    send_message(chat_id, "建置進行中，請稍後再試。")
                                else:
                                    _start_build(chat_id, platform=plat)
                        elif entry.get("awaiting") == "clean_all":
                            # 使用者回覆 clean_all 確認
                            reply = (text or "").strip().lower()
                            _clear_await_sudo(chat_id)
                            if reply in ("確認", "是", "yes", "y"):
                                if LOCK_FILE.exists() and _is_build_really_running():
                                    send_message(chat_id, "建置進行中，無法清理。請等建置完成後再試。")
                                else:
                                    if LOCK_FILE.exists():
                                        try:
                                            LOCK_FILE.unlink()
                                        except Exception:
                                            pass
                                    send_message(chat_id, "🗑 清理全部：開始刪除兩專案目錄…")
                                    _do_clean_all(chat_id)
                            elif reply in ("取消", "否", "no", "n", "cancel"):
                                send_message(chat_id, "已取消刪除，未執行任何動作。")
                            else:
                                send_message(chat_id, "請回覆「確認」或「是」執行刪除，或「取消」/「否」放棄。")
                                # 重新寫入狀態，讓使用者可再回覆一次
                                from datetime import datetime, timezone
                                _write_await_sudo({
                                    **(_read_await_sudo()),
                                    str(chat_id): {"awaiting": "clean_all", "since": datetime.now(timezone.utc).isoformat()},
                                })
                        else:
                            # 其他 awaiting 狀態（保留擴充用）
                            _clear_await_sudo(chat_id)
                            send_message(chat_id, "不認識的回覆，請重新發送指令。")
                    else:
                        send_message(chat_id, "不認識的指令，請輸入 /help 查看。")
            except Exception as e:
                print(f"Handler error: {e}", file=sys.stderr, flush=True)
                try:
                    send_message(chat_id, f"處理時發生錯誤：{e}")
                except Exception:
                    pass


if __name__ == "__main__":
    main()
