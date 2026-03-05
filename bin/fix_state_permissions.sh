#!/usr/bin/env bash
# Fix state/ and latest_version/ ownership so the Telegram bot (running as User= in systemd) can write.
# Run with sudo from project root or with full path. Auto-detects install user from systemd unit.
# Copyright (c) eCloudseal Inc.  All rights reserved.  Author: Lai Hou Chang (James Lai)
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(cd "${BIN_DIR}/.." && pwd)"

# Auto-detect run user: systemd unit User= > SUDO_USER > owner of install dir
RUN_USER=""
UNIT_FILE="/etc/systemd/system/auto_zgate_edge_tunnel_build_bot_telegram.service"
if [[ -f "${UNIT_FILE}" ]]; then
    RUN_USER="$(grep -E '^User=' "${UNIT_FILE}" 2>/dev/null | cut -d= -f2 | tr -d ' \t')"
fi
if [[ -z "${RUN_USER:-}" ]]; then
    RUN_USER="${SUDO_USER:-}"
fi
if [[ -z "${RUN_USER:-}" ]]; then
    RUN_USER="$(stat -c '%U' "${INSTALL_DIR}" 2>/dev/null)" || true
fi
if [[ -z "${RUN_USER:-}" ]]; then
    echo "無法自動偵測執行使用者。請手動執行： sudo chown -R <帳號>:<帳號> ${INSTALL_DIR}/state ${INSTALL_DIR}/latest_version" >&2
    exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "請使用 sudo 執行，例如: sudo ${BIN_DIR}/fix_state_permissions.sh" >&2
    exit 1
fi

echo "安裝目錄: ${INSTALL_DIR}"
echo "執行服務的使用者: ${RUN_USER}"
mkdir -p "${INSTALL_DIR}/state" "${INSTALL_DIR}/latest_version"
chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}/state" "${INSTALL_DIR}/latest_version"
echo "已將 state/ 與 latest_version/ 擁有者設為 ${RUN_USER}。"
if systemctl is-active --quiet auto_zgate_edge_tunnel_build_bot_telegram.service 2>/dev/null; then
    systemctl restart auto_zgate_edge_tunnel_build_bot_telegram.service
    echo "已重啟 Telegram Bot 服務。"
fi
