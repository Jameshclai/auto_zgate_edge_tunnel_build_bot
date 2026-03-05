#!/usr/bin/env bash
# Uninstall auto_zgate_edge_tunnel_build_bot: stop/disable systemd services, remove unit files.
# Optional: --remove-data to delete state/, latest_version/, .env (no default secrets left).
# Copyright (c) eCloudseal Inc.  All rights reserved.  Author: Lai Hou Chang (James Lai)
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOVE_DATA=0
for arg in "$@"; do
    if [[ "$arg" == "--remove-data" ]]; then
        REMOVE_DATA=1
        break
    fi
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "請使用 sudo 執行此反安裝腳本，例如: sudo ./uninstall.sh"
    exit 1
fi

echo "=== auto_zgate_edge_tunnel_build_bot 反安裝 ==="
echo "安裝目錄: ${INSTALL_DIR}"
echo ""

# Stop and disable services
echo ">>> 停止並停用 systemd 服務..."
systemctl stop auto_zgate_edge_tunnel_build_bot_telegram.service 2>/dev/null || true
systemctl disable --now auto_zgate_edge_tunnel_build_bot.timer 2>/dev/null || true
echo "  已停止 Telegram 服務與定時檢查。"

# Remove unit files
echo ">>> 移除 systemd unit 檔..."
for unit in auto_zgate_edge_tunnel_build_bot.service auto_zgate_edge_tunnel_build_bot.timer auto_zgate_edge_tunnel_build_bot_telegram.service; do
    dst="/etc/systemd/system/${unit}"
    if [[ -f "${dst}" ]]; then
        rm -f "${dst}"
        echo "  已移除 ${unit}"
    fi
done

echo ">>> 重新載入 systemd..."
systemctl daemon-reload

# Optional: remove state, latest_version, .env
if [[ "$REMOVE_DATA" -eq 1 ]]; then
    echo ">>> 移除本機資料 (state/, latest_version/, .env)..."
    [[ -d "${INSTALL_DIR}/state" ]]       && rm -rf "${INSTALL_DIR}/state"       && echo "  已刪除 state/"
    [[ -d "${INSTALL_DIR}/latest_version" ]] && rm -rf "${INSTALL_DIR}/latest_version" && echo "  已刪除 latest_version/"
    [[ -f "${INSTALL_DIR}/.env" ]]         && rm -f "${INSTALL_DIR}/.env"        && echo "  已刪除 .env"
fi

echo ""
echo "=== 反安裝完成 ==="
echo "systemd 服務與 unit 已移除。"
if [[ "$REMOVE_DATA" -eq 1 ]]; then
    echo "本機資料 (state、latest_version、.env) 已刪除。"
fi
echo "專案目錄保留: ${INSTALL_DIR}"
echo "若要完全刪除，請手動執行: rm -rf \"${INSTALL_DIR}\""
echo ""
