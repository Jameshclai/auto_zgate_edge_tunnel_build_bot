# auto_zgate_edge_tunnel_build_bot

自動檢查 OpenZiti 版本，並在「有新版本」或「上次建置產出遺失」時觸發建置，產出 Linux 與 Windows 的 **zgate-edge-tunnel** 二進位。可搭配 Telegram Bot 查詢版本與手動觸發建置。

## 需求

- Bash、curl、jq 或 Python3（用於解析 `state/last_build.json`）
- 已存在 **zgate-sdk-c-builder** 與 **zgate-tunnel-sdk-c-builder** 專案（同層或透過 `.env` 指定路徑）
- 建置需 git、cmake、ninja、gcc、vcpkg 等（由 builder 的 `build.sh` / `setup-build-env.sh` 檢查並可自動安裝）

## 目錄結構

```
auto_zgate_edge_tunnel_build_bot/
├── .env                 # TELEGRAM_TOKEN、路徑等（勿提交）
├── .env.example
├── .gitignore
├── README.md
├── state/
│   ├── last_build.json  # 上次建置版本與產出路徑
│   └── build.log
├── latest_version/     # 建置成功後複製的 Linux/Windows 二進位（按版本分子目錄）
├── bin/
│   ├── check_and_build.sh   # 每分鐘檢查、必要時觸發建置
│   ├── run_build.sh         # 依序執行 SDK + Tunnel build.sh（可依 BUILD_CHAT_ID 推送步驟）
│   ├── pack_and_upload_telegram.py  # 建置完成後打包 tar.gz 並上傳至觸發建置的 Telegram 對話
│   ├── telegram_notify.py   # 建置步驟通知（由 run_build.sh 呼叫）
│   └── telegram_bot.py     # Telegram 指令：/version、/build、/status
└── systemd/
    ├── auto_zgate_edge_tunnel_build_bot.service      # oneshot 檢查
    ├── auto_zgate_edge_tunnel_build_bot.timer        # 每 1 分鐘觸發
    └── auto_zgate_edge_tunnel_build_bot_telegram.service  # Telegram Bot 常駐
```

## 設定

1. 複製 `.env.example` 為 `.env`：
   ```bash
   cp .env.example .env
   ```
2. 編輯 `.env`，至少設定：
   - `TELEGRAM_TOKEN` — Telegram Bot API token（由 BotFather 取得）
   - 若 builder 不在專案同層，設定 `SDK_BUILDER_ROOT`、`TUNNEL_BUILDER_ROOT`、`ZGATE_SDK_BUILDER_OUTPUT`
3. 若專案不在 `/home/zgate/auto_zgate_edge_tunnel_build_bot`，請編輯 `systemd/*.service` 與 `systemd/*.timer` 內的路徑與 `User=`。

## 手動執行

- **僅檢查（不建置）**：`./bin/check_and_build.sh`
- **強制建置**：`./bin/run_build.sh`（會先建 SDK 再建 Tunnel）
- **Telegram Bot**：`python3 bin/telegram_bot.py`（常駐 long polling）

## Telegram 指令

| 指令 | 說明 |
|------|------|
| `/version` 或 `/latest` | 查詢 OpenZiti tunnel 目前最新版本、上次建置版本與二進位是否存在 |
| `/build` 或 `/build_now` | 手動觸發建置；若本機尚無兩專案則會從 GitHub 下載（並回報下載成功/失敗），Bot 會先詢問 sudo 密碼（回覆「跳過」或「無」可略過），再開始建置並推送每個步驟；建置成功後會自動將產物打包為 tar.gz 並上傳至該對話，操作者可從 Telegram 下載 |
| `/status` | 目前狀態：最新版、上次建置、是否建置中、Linux/Windows 產出是否存在 |
| `/clean_sdk` | 刪除 zgate-sdk-c-builder 的 output 與 work 目錄 |
| `/clean_tunnel` | 刪除 zgate-tunnel-sdk-c-builder 的 output 與 work 目錄 |
| `/clean_all` | 刪除 zgate-sdk-c-builder 與 zgate-tunnel-sdk-c-builder 兩專案整個目錄（下次 /build 會從 GitHub 重新下載） |
| `/start` 或 `/help` | 顯示指令說明 |

## systemd 服務（每 1 分鐘檢查）

1. 複製 unit 檔到 systemd（請依實際路徑修改 unit 內的路徑與 User）：
   ```bash
   sudo cp systemd/auto_zgate_edge_tunnel_build_bot.service systemd/auto_zgate_edge_tunnel_build_bot.timer systemd/auto_zgate_edge_tunnel_build_bot_telegram.service /etc/systemd/system/
   ```
2. 啟用 timer（每分鐘跑一次檢查）：
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now auto_zgate_edge_tunnel_build_bot.timer
   ```
3. 啟用 Telegram Bot（可選）：
   ```bash
   sudo systemctl enable --now auto_zgate_edge_tunnel_build_bot_telegram.service
   ```
4. 檢視狀態：
   ```bash
   systemctl status auto_zgate_edge_tunnel_build_bot.timer
   systemctl list-timers --all | grep zgate
   journalctl -u auto_zgate_edge_tunnel_build_bot.service -f
   ```

## 觸發條件（自動建置）

下列任一成立時，`check_and_build.sh` 會觸發 `run_build.sh`（且無建置鎖定時）：

- GitHub `openziti/ziti-tunnel-sdk-c` 的 **releases/latest** 版本與 `state/last_build.json` 的 `last_version` 不同
- `last_build.json` 記錄的 Linux 或 Windows 二進位路徑不存在

建置在背景執行，完成後由 `run_build.sh` 更新 `state/last_build.json` 並移除鎖定。

## 授權與作者

可依專案需求標註版權與作者。
