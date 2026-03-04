# Release 1.0.1

**auto_zgate_edge_tunnel_build_bot** 1.0.1：首個正式版本，提供定時檢查、Telegram Bot 整合、手動建置與產物上傳；建置步驟 2 即時回報、以 builder 的 latest_version 為準判定成功。

---

## 功能摘要

- **定時檢查**：systemd timer 每分鐘檢查 OpenZiti tunnel SDK 最新版本與產物是否存在；版本變更或產物遺失時自動觸發完整建置。
- **Telegram Bot**：`/version`、`/latest` 查詢版本；`/build` 手動觸發建置（先選平台 all/linux/windows/macos，再詢問 sudo）；`/status` 狀態與 latest_version 目錄樹；`/clean_sdk`、`/clean_tunnel`、`/clean_all`（刪除兩專案目錄前需回覆確認）。
- **建置流程**：依序執行 zgate-sdk-c-builder、zgate-tunnel-sdk-c-builder；若本機無兩專案則從 GitHub clone；每步驟推送到觸發建置的 Telegram 對話。
- **產物**：建置成功後複製至 `latest_version/<版本>/`（linux/windows/macos 分平台），並打包 tar.gz 上傳至該對話供下載。
- **版權**：COPYRIGHT 與各程式版權說明（eCloudseal Inc., Lai Hou Chang (James Lai)）。

## 修改說明（1.0.1 更新）

- **步驟 2/4 即時回報**：tunnel 建置改為背景執行；每 1 分鐘、之後每 2 分鐘檢查 **zgate-tunnel-sdk-c-builder/latest_version** 與 output 已產出平台，並推送「步驟 2/4 進行中：版本 x.x.x：linux/x64, windows, …」至 Telegram，避免畫面卡在步驟 2。
- **步驟 3/4 以 builder latest_version 為準**：成功條件改為檢查 **zgate-tunnel-sdk-c-builder/latest_version/<版本>/** 是否有所選平台產物；若有則直接自該目錄複製至 bot 的 latest_version，再寫入 state、打包上傳。若 builder 的 latest_version 無符合產物，則沿用 output/ 偵測與複製邏輯。

## 需求

- Bash、curl、jq 或 Python3；建置依賴由兩 builder 的 build.sh 檢查並可自動安裝。
- Telegram Bot Token（.env 設定 TELEGRAM_TOKEN）。

## 授權

- **Copyright (c) eCloudseal Inc.  All rights reserved.**
- **作者：Lai Hou Chang (James Lai)** — 詳見 [COPYRIGHT](COPYRIGHT)。

---

**完整使用說明請見 [README](README.md)。**
