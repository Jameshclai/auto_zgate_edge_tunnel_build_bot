# auto_zgate_edge_tunnel_build_bot

**zgate-edge-tunnel** 自動建置機器人：監測 OpenZiti tunnel SDK 版本、依條件觸發編譯，並透過 **Telegram Bot** 查詢狀態、手動建置、下載產物與清理環境。

**Copyright (c) eCloudseal Inc.  All rights reserved.**  
**Author: Lai Hou Chang (James Lai)** — 詳見 [COPYRIGHT](COPYRIGHT)。

---

## 專案用途

本專案用於在 Linux 主機上：

1. **自動建置**：依 systemd timer 每分鐘檢查 [openziti/ziti-tunnel-sdk-c](https://github.com/openziti/ziti-tunnel-sdk-c) 最新 release；若版本變更或既有產物遺失，則自動觸發完整建置流程。
2. **產出二進位**：依賴 [zgate-sdk-c-builder](https://github.com/Jameshclai/zgate-sdk-c-builder) 與 [zgate-tunnel-sdk-c-builder](https://github.com/Jameshclai/zgate-tunnel-sdk-c-builder)，產出 **zgate-edge-tunnel** 可執行檔（Linux x64/arm64/arm、Windows x64、macOS x64/arm64，依建置設定）。
3. **Telegram 整合**：透過 Bot 查詢版本與建置狀態、手動選擇平台觸發建置、接收每步通知，建置完成後可從對話下載打包好的 tar.gz。

適用於需持續取得最新 **zgate-edge-tunnel** 二進位、或希望透過 Telegram 遠端觸發建置與下載的維運情境。

---

## 主要功能

| 功能 | 說明 |
|------|------|
| **定時檢查** | systemd timer 每 1 分鐘執行檢查腳本；版本變更或產物遺失時自動觸發建置（背景執行）。 |
| **手動建置** | 透過 Telegram `/build` 或本機執行 `run_build.sh`；可指定平台（all / linux / windows / macos）。 |
| **建置步驟通知** | 由 Bot 觸發建置時，每步驟（下載專案、SDK 建置、Tunnel 建置、產出檢查、打包上傳）即時推送到該對話。 |
| **產物打包上傳** | 建置成功後自動將 `latest_version/<版本>/` 打包為 tar.gz，上傳至觸發建置的 Telegram 對話，供下載。 |
| **專案自動取得** | 若本機尚無兩 builder 專案，建置前會從 GitHub clone，並以 Telegram 回報下載成功或失敗。 |
| **清理指令** | `/clean_sdk`、`/clean_tunnel` 刪除各 builder 的 output/work；`/clean_all` 刪除兩專案整個目錄（**需回覆確認後才執行**）。 |

---

## 需求

- **執行環境**：Bash、curl、jq 或 Python3（用於讀取 `state/last_build.json`）。
- **建置依賴**：由 [zgate-sdk-c-builder](https://github.com/Jameshclai/zgate-sdk-c-builder) 與 [zgate-tunnel-sdk-c-builder](https://github.com/Jameshclai/zgate-tunnel-sdk-c-builder) 的 `build.sh` / `setup-build-env.sh` 檢查並可自動安裝（git、cmake、ninja、gcc、vcpkg 等）。
- **Telegram**：需向 [@BotFather](https://t.me/BotFather) 申請 Bot，取得 API Token 並填入 `.env`。

---

## 目錄結構

```
auto_zgate_edge_tunnel_build_bot/
├── .env                    # 設定（TELEGRAM_TOKEN、路徑等）；勿提交版控；一鍵安裝時由 install.sh 互動寫入
├── .env.example
├── install.sh              # 一鍵安裝腳本（Ubuntu 24.04）：互動輸入 Token／sudo 密碼後安裝服務
├── uninstall.sh            # 反安裝腳本：停止並移除 systemd 服務；可選 --all 清除 state/.env
├── .gitignore
├── COPYRIGHT               # 版權與法律聲明（eCloudseal Inc.）
├── README.md
├── state/
│   ├── last_build.json     # 上次建置版本、產出路徑、latest_version 目錄
│   ├── build.log           # 建置日誌
│   ├── building.lock       # 建置中鎖定檔
│   └── telegram_await_sudo.json  # Bot 等候回覆狀態（平台選擇、clean_all 確認）
├── latest_version/         # 建置成功後複製的產物（按版本與平台分子目錄）
│   └── <版本>/
│       ├── linux/x64|arm64|arm/
│       ├── windows/        # zgate-edge-tunnel.exe、wintun.dll
│       └── macos/x64|arm64/
├── bin/
│   ├── check_and_build.sh  # 定時檢查：版本與產物存在與否，必要時觸發 run_build.sh
│   ├── run_build.sh        # 完整建置：SDK → Tunnel（可傳 BUILD_PLATFORM）、產出複製、打包上傳 Telegram
│   ├── telegram_bot.py     # Telegram Bot（long polling）：指令處理與建置觸發
│   ├── telegram_notify.py  # 建置步驟通知（由 run_build.sh 呼叫）
│   ├── pack_and_upload_telegram.py  # 建置完成後打包 tar.gz 並上傳至觸發建置的對話
│   └── fix_state_permissions.sh    # 修正 state/ 權限（自動偵測執行帳號，需 sudo）
└── systemd/
    ├── auto_zgate_edge_tunnel_build_bot.service       # oneshot：執行 check_and_build.sh
    ├── auto_zgate_edge_tunnel_build_bot.timer         # 每 1 分鐘觸發上述 service
    └── auto_zgate_edge_tunnel_build_bot_telegram.service  # 常駐：Telegram Bot
```

---

## 一鍵安裝（Ubuntu 24.04）

從 GitHub 下載後執行安裝腳本，**依提示輸入** Telegram 機器人名稱（選填）、Bot Token（必填）、預設 sudo 密碼（選填，例如 AWS EC2 以 `sudo -s` 提權建置時使用）。不會在專案內留下預設 Token 或密碼，降低資安風險。

```bash
git clone https://github.com/Jameshclai/auto_zgate_edge_tunnel_build_bot.git
cd auto_zgate_edge_tunnel_build_bot
sudo ./install.sh
```

安裝過程會：安裝系統套件（curl、jq、python3）、建立 `.env`（由您輸入的設定寫入）、安裝並啟用 systemd timer 與 Telegram 服務。若已存在 `.env`，可選擇保留或覆寫並重新輸入。

### 反安裝

執行反安裝腳本可停止並移除 systemd 服務與 unit 檔；可選清除本機資料（state、建置產物、.env）。

```bash
sudo ./uninstall.sh        # 僅移除服務，保留專案目錄與 state/.env（可再 install）
sudo ./uninstall.sh --all  # 並刪除 state/、latest_version/、.env（不留建置產物與機密）
```

專案目錄不會被刪除；若要完全移除請手動 `rm -rf` 該目錄。

若執行 `/build` 時出現 `Permission denied: .../state/telegram_await_sudo.json`，表示 `state/` 目錄權限不屬於執行 Bot 的使用者。請在專案目錄下執行（會自動從 systemd unit 偵測執行帳號）：

```bash
cd /path/to/auto_zgate_edge_tunnel_build_bot
sudo ./bin/fix_state_permissions.sh
```

---

## 設定（手動安裝時）

1. **複製環境範本並編輯**：
   ```bash
   cp .env.example .env
   ```
2. **必填**：於 `.env` 設定 `TELEGRAM_TOKEN`（BotFather 取得）。
3. **選填**：
   - `TELEGRAM_BOT_NAME`：機器人名稱（僅供顯示）。
   - `SDK_BUILDER_ROOT`、`TUNNEL_BUILDER_ROOT`：兩 builder 專案路徑（預設為本專案同層目錄）。
   - `ZGATE_SDK_BUILDER_OUTPUT`：zgate-sdk-c 產出目錄（供 tunnel builder 依賴）。
   - `VCPKG_ROOT`：vcpkg 根目錄（傳入 builder）。
   - `SUDO_PASS`：非互動建置用 sudo 密碼（安裝時可一併設定；**勿將 .env 提交版控**）。
4. **systemd**：若專案或使用者路徑非預設，請編輯 `systemd/*.service` 與 `systemd/*.timer` 內之路徑與 `User=`。

---

## Telegram Bot 指令

| 指令 | 說明 |
|------|------|
| `/version`、`/latest` | 查詢 OpenZiti tunnel 目前最新版本、上次建置版本與時間、Linux/Windows 二進位是否存在。 |
| `/build` | 手動觸發建置。Bot 會**先詢問建置平台**（點選按鈕或輸入 `all` / `linux` / `windows` / `macos`）後開始建置；sudo 使用安裝時寫入 `.env` 的 `SUDO_PASS`（若有）。若本機尚無兩 builder 專案會先從 GitHub 下載並回報結果。**依賴安裝與編譯進度每 1 分鐘推送到此對話**（步驟 1：vcpkg/編譯進度；步驟 2：已產出平台）；完成後自動打包 tar.gz 並上傳，可從對話下載。 |
| `/stop_build` | 中斷目前進行中的建置（結束 run_build.sh 並清除鎖定）。 |
| `/status` | 目前狀態：最新版、上次建置版本、是否建置中、Linux/Windows 產出是否存在，以及 `latest_version/` 目錄樹。 |
| `/clean_sdk` | 刪除 **zgate-sdk-c-builder** 的 `output` 與 `work` 目錄。 |
| `/clean_tunnel` | 刪除 **zgate-tunnel-sdk-c-builder** 的 `output` 與 `work` 目錄。 |
| `/clean_all` | 刪除上述兩專案**整個目錄**（下次 `/build` 會重新從 GitHub clone）。**不會立即執行**：Bot 會先送出確認訊息，您需回覆「**確認**」「**是**」或「**yes**」才會執行；回覆「取消」「否」或「no」即放棄。約 5 分鐘內未回覆則自動取消。 |
| `/start`、`/help` | 顯示指令說明。 |

---

## 自動建置觸發條件

`check_and_build.sh`（由 systemd timer 每分鐘呼叫）在**未處於建置鎖定**時，若下列任一成立即觸發 `run_build.sh`：

- GitHub **openziti/ziti-tunnel-sdk-c** `releases/latest` 版本與 `state/last_build.json` 的 `last_version` 不同；
- `last_build.json` 內記錄的 Linux 或 Windows 二進位路徑不存在。

建置在背景執行；完成後由 `run_build.sh` 更新 `last_build.json`、複製產物至 `latest_version/`，並移除鎖定。

---

## 手動執行

| 指令 | 說明 |
|------|------|
| `./bin/check_and_build.sh` | 僅執行一次檢查；符合條件時觸發建置，否則結束。 |
| `./bin/run_build.sh` | 強制執行完整建置（SDK → Tunnel）。可設定環境變數 `BUILD_PLATFORM=all|linux|windows|macos`、`BUILD_CHAT_ID=<chat_id>` 以指定平台與 Telegram 通知對象。 |
| `python3 bin/telegram_bot.py` | 啟動 Telegram Bot（常駐 long polling）。可搭配 `nohup` 或 systemd 常駐。 |

---

## systemd 部署（手動安裝時）

若未使用 `install.sh` 一鍵安裝，可手動部署：

1. **複製 unit 檔**（請依實際路徑與使用者修改 unit 內容）：
   ```bash
   sudo cp systemd/auto_zgate_edge_tunnel_build_bot.service \
            systemd/auto_zgate_edge_tunnel_build_bot.timer \
            systemd/auto_zgate_edge_tunnel_build_bot_telegram.service \
            /etc/systemd/system/
   ```
   並編輯上述檔案，將 `/home/zgate/auto_zgate_edge_tunnel_build_bot` 改為實際安裝路徑、`User=zgate` 改為實際執行使用者。
2. **重新載入並啟用**：
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now auto_zgate_edge_tunnel_build_bot.timer
   sudo systemctl enable --now auto_zgate_edge_tunnel_build_bot_telegram.service
   ```
3. **檢視狀態與日誌**：
   ```bash
   systemctl status auto_zgate_edge_tunnel_build_bot.timer
   systemctl list-timers --all | grep zgate
   journalctl -u auto_zgate_edge_tunnel_build_bot.service -f
   journalctl -u auto_zgate_edge_tunnel_build_bot_telegram.service -f
   ```

---

## 建置產出與 latest_version

- 建置成功後，產物會複製到 **`latest_version/<版本>/`**，結構與 [zgate-tunnel-sdk-c-builder](https://github.com/Jameshclai/zgate-tunnel-sdk-c-builder) 的 `latest_version` 一致：
  - `linux/x64/`、`linux/arm64/`、`linux/arm/`：`zgate-edge-tunnel`
  - `windows/`：`zgate-edge-tunnel.exe`、`wintun.dll`
  - `macos/x64/`、`macos/arm64/`：`zgate-edge-tunnel`
- 由 Telegram `/build` 觸發且成功時，會再將該目錄打包為 **tar.gz** 並上傳至觸發建置的對話。

---

## 注意事項

- **`.env`** 已列於 `.gitignore`，請勿提交；內含 `TELEGRAM_TOKEN` 或 `SUDO_PASS` 時務必妥善保管。
- **`/clean_all`** 會刪除兩 builder 專案整個目錄，僅在回覆確認後執行，請謹慎使用。
- 建置進行中（存在 `state/building.lock`）時，無法執行清理指令與再次觸發建置。

---

## 授權與作者

- **Copyright (c) eCloudseal Inc.  All rights reserved.**
- **作者 (Author): Lai Hou Chang (James Lai)**
- 完整版權與法律聲明請見 [COPYRIGHT](COPYRIGHT)。
