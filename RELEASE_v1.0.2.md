# Release 1.0.2

**auto_zgate_edge_tunnel_build_bot** 1.0.2：一鍵安裝／反安裝腳本、Telegram Bot 調整（/build 不再詢問 sudo、移除 /build_now）、安裝時互動輸入 Token 與 sudo 密碼，無預設機密寫入 repo。

---

## 功能摘要

- **一鍵安裝（install.sh）**：執行 `sudo ./install.sh` 後依提示輸入 Telegram 機器人名稱（選填）、Bot Token（必填）、預設 sudo 密碼（選填，如 AWS EC2 非互動建置用）；自動安裝系統套件、寫入 .env、安裝並啟用 systemd timer 與 Telegram 服務。不在專案內留下預設 Token 或密碼。
- **反安裝（uninstall.sh）**：`sudo ./uninstall.sh` 停止並移除 systemd 服務與 unit 檔；可選 `--all` 一併刪除 state/、latest_version/、.env。
- **Telegram Bot**：`/build` 僅詢問建置平台（all/linux/windows/macos），不再詢問 sudo 密碼，改由安裝時寫入 .env 的 SUDO_PASS 提供；指令 `/build_now` 已移除。
- **定時檢查、建置流程、產物上傳**：與 1.0.1 一致。

## 修改說明（1.0.2 更新）

- **install.sh**：新增於專案根目錄。互動詢問 TELEGRAM_TOKEN、TELEGRAM_BOT_NAME、SUDO_PASS 後寫入 .env；替換 systemd unit 路徑與 User 後安裝至 /etc/systemd/system/ 並啟用服務。
- **uninstall.sh**：新增。停止 Telegram 服務與 timer、移除三支 systemd unit、daemon-reload；選項 `--all` 刪除 state/、latest_version/、.env。
- **telegram_bot.py**：`/build` 僅詢問平台，選完後直接啟動建置（使用 .env 的 SUDO_PASS）；移除 `/build_now`；啟動訊息改為使用 .env 的 TELEGRAM_BOT_NAME。
- **run_build.sh**：移除「保留 Telegram 回覆的 SUDO_PASS」邏輯，改為僅從 .env 讀取 SUDO_PASS。
- **README.md**：新增一鍵安裝與反安裝說明、目錄結構加入 install.sh／uninstall.sh、Telegram 指令表更新（/build 不問 sudo、移除 /build_now）、設定與 systemd 部署章節標註手動安裝時使用。

## 後續修正與增強（1.0.2 補充）

- **建置通知**：依賴安裝與編譯進度改為**每 1 分鐘**回報。步驟 1/4 從 build.log 擷取 vcpkg／編譯進度並通知；步驟 2/4 明確標示【已建置完成】與【尚在建置】之平台（Linux x64/arm64/arm、Windows、macOS x64/arm64）。步驟 4/4 完成時列出【建置完成平台】與產出路徑。開頭與各步驟文案補齊流程與平台說明，方便操作者掌握執行現況。
- **/build 開始訊息**：依所選平台顯示「ZGate Edge Tunnel（全部平台：Linux x64/arm64/arm、Windows、macOS x64/arm64）」或「Linux：x64、arm64、arm」等明確說明。
- **/status**：回報【套件下載狀態】（zgate-sdk-c-builder、zgate-tunnel-sdk-c-builder 已下載／未下載）、【建置狀態】。若正在建置，顯示目前步驟（1/4 或 2/4）與進度（步驟 1：vcpkg 依賴或編譯中；步驟 2：各平台已建置完成／尚在建置）。並含版本與產出、latest_version 目錄樹（含 macos）。
- **/stop_build**：除中斷 run_build.sh 外，一併終止兩 builder 的 build.sh；移除 building.lock；**移除建置到一半的 output、work 目錄**（兩 builder）；以 **ps** 確認無殘留程序；並將上述過程與結果**詳細回報**至對話。
- **install.sh**：建立 state/、latest_version 後以 chown 設為執行服務使用者，避免 /build 時 Permission denied（telegram_await_sudo.json）。
- **bin/fix_state_permissions.sh**：新增。自動從 systemd unit 偵測執行帳號，修正 state/、latest_version 權限並可重啟 Telegram 服務。
- **bin/diagnose_build.sh**：新增。於主機上執行可輸出 build.log 尾段、鎖定與狀態、run_build 程序、磁碟、builder 產出目錄等，供建置無產出時排查。

## 需求

- 與 1.0.1 相同：Bash、curl、jq 或 Python3；建置依賴由兩 builder 的 build.sh 檢查並可自動安裝。Telegram Bot Token 於 install.sh 互動輸入或手動寫入 .env。

## 授權

- **Copyright (c) eCloudseal Inc.  All rights reserved.**
- **作者：Lai Hou Chang (James Lai)** — 詳見 [COPYRIGHT](COPYRIGHT)。

---

**完整使用說明請見 [README](README.md)。**
