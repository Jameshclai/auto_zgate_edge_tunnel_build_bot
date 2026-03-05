#!/usr/bin/env bash
# 診斷建置無產出：檢查 build.log、鎖定、程序、磁碟、builder 產出目錄。
# 在專案目錄或指定 BOT_ROOT 下執行，例如: ./bin/diagnose_build.sh 或 BOT_ROOT=/path/to/bot ./bin/diagnose_build.sh
# Copyright (c) eCloudseal Inc.  All rights reserved.  Author: Lai Hou Chang (James Lai)
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_ROOT="${BOT_ROOT:-$(cd "${BIN_DIR}/.." && pwd)}"
STATE_DIR="${BOT_ROOT}/state"
LOG="${STATE_DIR}/build.log"
LOCK="${STATE_DIR}/building.lock"
STATE_JSON="${STATE_DIR}/last_build.json"

echo "=== 建置診斷 (BOT_ROOT=${BOT_ROOT}) ==="
echo ""

echo "--- 1) 建置日誌最後 80 行 ---"
if [[ -f "${LOG}" ]]; then
    tail -n 80 "${LOG}"
else
    echo "（無 build.log）"
fi
echo ""

echo "--- 2) 鎖定與狀態 ---"
echo "building.lock 存在: $([ -f "${LOCK}" ] && echo '是' || echo '否')"
if [[ -f "${STATE_JSON}" ]]; then
    echo "last_build.json:"
    cat "${STATE_JSON}" 2>/dev/null || echo "（無法讀取）"
else
    echo "last_build.json: 不存在"
fi
echo ""

echo "--- 3) run_build.sh 是否在執行 ---"
if pgrep -f "run_build.sh" >/dev/null 2>&1; then
    ps aux | grep -E "[r]un_build.sh" || true
else
    echo "否（目前沒有 run_build.sh 程序）"
fi
echo ""

echo "--- 4) 磁碟空間 (專案與 /tmp) ---"
df -h "${BOT_ROOT}" 2>/dev/null || df -h .
df -h /tmp 2>/dev/null || true
echo ""

# 與 run_build.sh 一致的路徑
SDK_BUILDER_ROOT="${SDK_BUILDER_ROOT:-$(dirname "${BOT_ROOT}")/zgate-sdk-c-builder}"
TUNNEL_BUILDER_ROOT="${TUNNEL_BUILDER_ROOT:-$(dirname "${BOT_ROOT}")/zgate-tunnel-sdk-c-builder}"

echo "--- 5) Builder 目錄與產出 ---"
echo "SDK builder: ${SDK_BUILDER_ROOT}"
echo "  存在: $([ -d "${SDK_BUILDER_ROOT}" ] && echo '是' || echo '否')"
if [[ -d "${SDK_BUILDER_ROOT}/output" ]]; then
    echo "  output: $(du -sh "${SDK_BUILDER_ROOT}/output" 2>/dev/null || echo '?')"
fi
echo "Tunnel builder: ${TUNNEL_BUILDER_ROOT}"
echo "  存在: $([ -d "${TUNNEL_BUILDER_ROOT}" ] && echo '是' || echo '否')"
if [[ -d "${TUNNEL_BUILDER_ROOT}/output" ]]; then
    echo "  output: $(du -sh "${TUNNEL_BUILDER_ROOT}/output" 2>/dev/null || echo '?')"
fi
if [[ -d "${TUNNEL_BUILDER_ROOT}/latest_version" ]]; then
    echo "  latest_version: $(ls -la "${TUNNEL_BUILDER_ROOT}/latest_version" 2>/dev/null || echo '?')"
fi
echo ""

echo "--- 6) Bot latest_version 目錄 ---"
LATEST_DIR="${BOT_ROOT}/latest_version"
if [[ -d "${LATEST_DIR}" ]]; then
    ls -laR "${LATEST_DIR}" 2>/dev/null | head -80
else
    echo "（不存在）"
fi
echo ""

echo "=== 診斷結束 ==="
