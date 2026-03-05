# Release 1.0.2

**auto_zgate_edge_tunnel_build_bot** 1.0.2：一鍵安裝／反安裝腳本、Telegram Bot 調整（/build 不再詢問 sudo、移除 /build_now）、安裝時互動輸入 Token 與 sudo 密碼，無預設機密寫入 repo。

---

## 功能摘要

- **一鍵安裝（install.sh）**：執行 `sudo ./install.sh` 後依提示輸入 Telegram 機器人名稱（選填）、Bot Token（必填）、預設 sudo 密碼（選填，如 AWS EC2 非互動建置用）；自動安裝系統套件、寫入 .env、安裝並啟用 systemd timer 與 Telegram 服務。不在專案內留下預設 Token 或密碼。
- **反安裝（uninstall.sh）**：`sudo ./uninstall.sh` 停止並移除 systemd 服務與 unit 檔；可選 `--remove-data` 一併刪除 state/、latest_version/、.env。
- **Telegram Bot**：`/build` 僅詢問建置平台（all/linux/windows/macos），不再詢問 sudo 密碼，改由安裝時寫入 .env 的 SUDO_PASS 提供；指令 `/build_now` 已移除。
- **定時檢查、建置流程、產物上傳**：與 1.0.1 一致。

## 修改說明（1.0.2 更新）

- **install.sh**：新增於專案根目錄。互動詢問 TELEGRAM_TOKEN、TELEGRAM_BOT_NAME、SUDO_PASS 後寫入 .env；替換 systemd unit 路徑與 User 後安裝至 /etc/systemd/system/ 並啟用服務。
- **uninstall.sh**：新增。停止 Telegram 服務與 timer、移除三支 systemd unit、daemon-reload；選項 `--remove-data` 刪除 state/、latest_version/、.env。
- **telegram_bot.py**：`/build` 僅詢問平台，選完後直接啟動建置（使用 .env 的 SUDO_PASS）；移除 `/build_now`；啟動訊息改為使用 .env 的 TELEGRAM_BOT_NAME。
- **run_build.sh**：移除「保留 Telegram 回覆的 SUDO_PASS」邏輯，改為僅從 .env 讀取 SUDO_PASS。
- **README.md**：新增一鍵安裝與反安裝說明、目錄結構加入 install.sh／uninstall.sh、Telegram 指令表更新（/build 不問 sudo、移除 /build_now）、設定與 systemd 部署章節標註手動安裝時使用。

## 需求

- 與 1.0.1 相同：Bash、curl、jq 或 Python3；建置依賴由兩 builder 的 build.sh 檢查並可自動安裝。Telegram Bot Token 於 install.sh 互動輸入或手動寫入 .env。

## 授權

- **Copyright (c) eCloudseal Inc.  All rights reserved.**
- **作者：Lai Hou Chang (James Lai)** — 詳見 [COPYRIGHT](COPYRIGHT)。

---

**完整使用說明請見 [README](README.md)。**
