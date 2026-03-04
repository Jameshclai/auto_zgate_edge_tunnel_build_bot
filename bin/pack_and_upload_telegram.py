#!/usr/bin/env python3
"""
建置完成後將 latest_version/<ver>/ 打包為 tar.gz，並上傳至觸發建置的 Telegram 對話（sendDocument）。
未設定 BUILD_CHAT_ID 時僅打包不上傳（例如由 timer 觸發的建置）。

Copyright (c) eCloudseal Inc.  All rights reserved.  Author: Lai Hou Chang (James Lai)
"""
import os
import sys
import tarfile
from pathlib import Path

# 載入 .env（與 telegram_bot 一致）
BIN_DIR = Path(__file__).resolve().parent
BOT_ROOT = BIN_DIR.parent
_env = BOT_ROOT / ".env"
if _env.exists():
    for line in _env.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ[k.strip()] = v.strip().strip("'\"")

TOKEN = os.environ.get("TELEGRAM_TOKEN", "").strip()
CHAT_ID = os.environ.get("BUILD_CHAT_ID", "").strip()


def make_tarball(version_dir: Path, version: str, out_dir: Path) -> Path:
    """將 version_dir（含 linux/、windows/）打包為 zgate-edge-tunnel-<ver>.tar.gz，回傳產物路徑。"""
    version_dir = version_dir.resolve()
    if not version_dir.is_dir():
        raise FileNotFoundError(f"Version dir not found: {version_dir}")
    out_dir = out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    tarball_name = f"zgate-edge-tunnel-{version}.tar.gz"
    tarball_path = out_dir / tarball_name
    with tarfile.open(tarball_path, "w:gz") as tar:
        arc_root = version_dir.name
        for item in version_dir.iterdir():
            tar.add(item, arcname=f"{arc_root}/{item.name}")
    return tarball_path


def upload_document(chat_id: str, file_path: Path, caption: str) -> None:
    """以 Telegram Bot API sendDocument 上傳檔案。"""
    import urllib.request

    url = f"https://api.telegram.org/bot{TOKEN}/sendDocument"
    boundary = "----ZGateBuildBotBoundary"
    file_path = file_path.resolve()
    with open(file_path, "rb") as f:
        file_data = f.read()
    filename = file_path.name
    b = boundary.encode("utf-8")
    body = (
        b"--" + b + b"\r\n"
        b'Content-Disposition: form-data; name="chat_id"\r\n\r\n' + chat_id.encode("utf-8") + b"\r\n"
    )
    if caption:
        body += b"--" + b + b"\r\n"
        body += b'Content-Disposition: form-data; name="caption"\r\n\r\n'
        body += caption.encode("utf-8") + b"\r\n"
    body += (
        b"--" + b + b"\r\n"
        b'Content-Disposition: form-data; name="document"; filename="' + filename.encode("utf-8") + b'"\r\n'
        b"Content-Type: application/gzip\r\n\r\n"
    )
    body += file_data + b"\r\n--" + b + b"--\r\n"

    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        out = __import__("json").loads(r.read().decode())
    if not out.get("ok"):
        raise RuntimeError(out.get("description", "sendDocument failed"))


def main():
    if len(sys.argv) < 3:
        print("Usage: pack_and_upload_telegram.py <version_dir> <version>", file=sys.stderr)
        sys.exit(2)
    version_dir = Path(sys.argv[1])
    version = sys.argv[2].strip()
    if not version:
        print("Version must be non-empty", file=sys.stderr)
        sys.exit(2)

    state_dir = BOT_ROOT / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    tarball_path = make_tarball(version_dir, version, state_dir)
    print(f"Created: {tarball_path}", file=sys.stderr)

    if not CHAT_ID or not TOKEN:
        print("BUILD_CHAT_ID or TELEGRAM_TOKEN not set; skip Telegram upload.", file=sys.stderr)
        sys.exit(0)

    caption = (
        f"ZGate Edge Tunnel v{version}\n"
        "內含 linux/ 與 windows/ 目錄，解壓後即可使用。"
    )
    try:
        upload_document(CHAT_ID, tarball_path, caption)
        print(f"Uploaded to Telegram chat {CHAT_ID}.", file=sys.stderr)
        sys.exit(0)
    except Exception as e:
        print(f"Telegram upload failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
