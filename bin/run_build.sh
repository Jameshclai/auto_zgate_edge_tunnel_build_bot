#!/usr/bin/env bash
# Run full build: zgate-sdk-c-builder then zgate-tunnel-sdk-c-builder.
# Expects: BOT_ROOT, state/building.lock created by caller; updates state/last_build.json on success.
set -euo pipefail
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_ROOT="$(cd "${BIN_DIR}/.." && pwd)"
STATE_DIR="${BOT_ROOT}/state"
LOCK_FILE="${STATE_DIR}/building.lock"

# Preserve Telegram-provided SUDO_PASS (from /build 回覆) so .env does not override
BUILD_SUDO_PASS="${SUDO_PASS:-}"
# Load .env if present
if [[ -f "${BOT_ROOT}/.env" ]]; then
    set -a
    source "${BOT_ROOT}/.env"
    set +a
fi
# Telegram 詢問的密碼優先於 .env
[[ -n "${BUILD_SUDO_PASS:-}" ]] && export SUDO_PASS="${BUILD_SUDO_PASS}"

SDK_BUILDER_ROOT="${SDK_BUILDER_ROOT:-$(dirname "${BOT_ROOT}")/zgate-sdk-c-builder}"
TUNNEL_BUILDER_ROOT="${TUNNEL_BUILDER_ROOT:-$(dirname "${BOT_ROOT}")/zgate-tunnel-sdk-c-builder}"
export TUNNEL_PRESETS="${TUNNEL_PRESETS:-ci-linux-x64;ci-linux-arm64;ci-linux-arm;ci-macOS-x64;ci-macOS-arm64;ci-windows-x64-mingw}"
export ZGATE_SDK_BUILDER_OUTPUT="${ZGATE_SDK_BUILDER_OUTPUT:-${SDK_BUILDER_ROOT}/output}"

LOG_FILE="${BOT_ROOT}/state/build.log"
mkdir -p "${STATE_DIR}"
exec 1> >(tee -a "${LOG_FILE}") 2>&1

# Notify Telegram if BUILD_CHAT_ID set (e.g. user triggered /build from bot)
notify() {
    if [[ -n "${BUILD_CHAT_ID:-}" ]]; then
        BUILD_CHAT_ID="${BUILD_CHAT_ID}" python3 "${BIN_DIR}/telegram_notify.py" "$@" || true
    fi
}

echo "==> run_build.sh started at $(date -Iseconds)"
notify "🔧 建置開始：準備環境…"

# 從 GitHub 下載兩專案（若目錄不存在），並回報下載成功或失敗
if [[ ! -d "${SDK_BUILDER_ROOT}" ]] || [[ ! -f "${SDK_BUILDER_ROOT}/build.sh" ]]; then
    notify "📥 正在下載 zgate-sdk-c-builder…"
    mkdir -p "$(dirname "${SDK_BUILDER_ROOT}")"
    if git clone --depth 1 https://github.com/Jameshclai/zgate-sdk-c-builder.git "${SDK_BUILDER_ROOT}"; then
        notify "✅ 下載 zgate-sdk-c-builder：成功"
    else
        notify "❌ 下載 zgate-sdk-c-builder：失敗"
        rm -f "${LOCK_FILE}"
        exit 1
    fi
fi
if [[ ! -d "${TUNNEL_BUILDER_ROOT}" ]] || [[ ! -f "${TUNNEL_BUILDER_ROOT}/build.sh" ]]; then
    notify "📥 正在下載 zgate-tunnel-sdk-c-builder…"
    mkdir -p "$(dirname "${TUNNEL_BUILDER_ROOT}")"
    if git clone --depth 1 https://github.com/Jameshclai/zgate-tunnel-sdk-c-builder.git "${TUNNEL_BUILDER_ROOT}"; then
        notify "✅ 下載 zgate-tunnel-sdk-c-builder：成功"
    else
        notify "❌ 下載 zgate-tunnel-sdk-c-builder：失敗"
        rm -f "${LOCK_FILE}"
        exit 1
    fi
fi

if [[ ! -x "${SDK_BUILDER_ROOT}/build.sh" ]]; then
    echo "Error: SDK builder build.sh not executable at ${SDK_BUILDER_ROOT}" >&2
    notify "❌ 建置失敗：zgate-sdk-c-builder 的 build.sh 無法執行"
    rm -f "${LOCK_FILE}"
    exit 1
fi
if [[ ! -x "${TUNNEL_BUILDER_ROOT}/build.sh" ]]; then
    echo "Error: Tunnel builder build.sh not executable at ${TUNNEL_BUILDER_ROOT}" >&2
    notify "❌ 建置失敗：zgate-tunnel-sdk-c-builder 的 build.sh 無法執行"
    rm -f "${LOCK_FILE}"
    exit 1
fi

# 1) 直接呼叫 zgate-sdk-c-builder 的 build 程序（不帶 WORK_DIR/OUTPUT_DIR，使用 builder 內建路徑）
notify "📦 步驟 1/4：正在建置 zgate-sdk-c…"
echo "==> Calling ${SDK_BUILDER_ROOT}/build.sh"
if ! (unset WORK_DIR OUTPUT_DIR; cd "${SDK_BUILDER_ROOT}" && ./build.sh); then
    echo "Error: zgate-sdk-c-builder failed" >&2
    notify "❌ 建置失敗：zgate-sdk-c 編譯錯誤"
    rm -f "${LOCK_FILE}"
    exit 1
fi
notify "✅ 步驟 1/4 完成：zgate-sdk-c 建置成功"

# 2) 完成後，直接呼叫 zgate-tunnel-sdk-c-builder 的 build 程序（需能找到上方 SDK 產出）
# BUILD_PLATFORM：由 Telegram /build 選擇傳入，對應 build.sh -all|-linux|-windows|-macos
TUNNEL_BUILD_ARG="-all"
if [[ -n "${BUILD_PLATFORM:-}" ]]; then
  case "${BUILD_PLATFORM}" in
    all|linux|windows|macos) TUNNEL_BUILD_ARG="-${BUILD_PLATFORM}" ;;
    *) TUNNEL_BUILD_ARG="-all" ;;
  esac
fi
notify "📦 步驟 2/4：正在建置 zgate-tunnel-sdk-c（${BUILD_PLATFORM:-all}）…"
echo "==> Calling ${TUNNEL_BUILDER_ROOT}/build.sh ${TUNNEL_BUILD_ARG}"
export OUTPUT_DIR="${OUTPUT_DIR:-${TUNNEL_BUILDER_ROOT}/output}"
if ! (cd "${TUNNEL_BUILDER_ROOT}" && ./build.sh ${TUNNEL_BUILD_ARG}); then
    echo "Error: zgate-tunnel-sdk-c-builder failed" >&2
    notify "❌ 建置失敗：zgate-tunnel-sdk-c 編譯錯誤"
    rm -f "${LOCK_FILE}"
    exit 1
fi
notify "✅ 步驟 2/4 完成：zgate-tunnel 建置成功"

# 3) Detect version and artifact paths, copy to latest_version/, write state, notify
notify "📋 步驟 3/4：檢查產出與寫入狀態…"
OUT="${OUTPUT_DIR}"
VER=""
LINUX_EXE=""
WIN_EXE=""
for dir in "${OUT}"/zgate-tunnel-sdk-c-*; do
    [[ -d "${dir}" ]] || continue
    VER="$(basename "${dir}" | sed 's/^zgate-tunnel-sdk-c-//')"
    break
done
[[ -n "${VER}" ]] && OUT_DIR="${OUT}/zgate-tunnel-sdk-c-${VER}"
# 依實際產出設定 LINUX_EXE / WIN_EXE（可能只建了單一平台）
LINUX_EXE=""
for preset in ci-linux-x64 ci-linux-arm64 ci-linux-arm; do
  exe="${OUT_DIR}/build-${preset}/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel"
  [[ -f "${exe}" ]] && LINUX_EXE="${exe}" && break
done
WIN_EXE="${OUT_DIR}/build-ci-windows-x64-mingw/programs/zgate-edge-tunnel/zgate-edge-tunnel.exe"
[[ -f "${WIN_EXE}" ]] || WIN_EXE="${OUT_DIR}/build-ci-windows-x64-mingw/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel.exe"
[[ -f "${WIN_EXE}" ]] || WIN_EXE=""
# 依 BUILD_PLATFORM 判斷是否算建置成功
REQ_PLATFORM="${BUILD_PLATFORM:-all}"
ARTIFACT_OK=0
case "${REQ_PLATFORM}" in
  linux) [[ -n "${LINUX_EXE}" ]] && [[ -f "${LINUX_EXE}" ]] && ARTIFACT_OK=1 ;;
  windows) [[ -n "${WIN_EXE}" ]] && [[ -f "${WIN_EXE}" ]] && ARTIFACT_OK=1 ;;
  macos)
    for preset in ci-macOS-x64 ci-macOS-arm64; do
      [[ -f "${OUT_DIR}/build-${preset}/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel" ]] && ARTIFACT_OK=1 && break
    done
    ;;
  all|*)
    [[ -n "${LINUX_EXE}" ]] && [[ -f "${LINUX_EXE}" ]] && [[ -n "${WIN_EXE}" ]] && [[ -f "${WIN_EXE}" ]] && ARTIFACT_OK=1
    ;;
esac
if [[ -z "${VER}" ]] || [[ "${ARTIFACT_OK}" != "1" ]]; then
    notify "❌ 建置失敗：未找到符合所選平台（${REQ_PLATFORM}）的二進位檔"
    rm -f "${LOCK_FILE}"
    exit 1
fi

# 複製到 latest_version/${VER}/；Linux 依平台區分，Windows 單一目錄含 wintun.dll，macOS 依架構
LATEST_DIR="${BOT_ROOT}/latest_version"
VERSION_DIR="${LATEST_DIR}/${VER}"
LINUX_NAME="zgate-edge-tunnel"
WIN_NAME="zgate-edge-tunnel.exe"
WINTUN_NAME="wintun.dll"

# Linux 依平台複製
for preset_arch in "ci-linux-x64:x64" "ci-linux-arm64:arm64" "ci-linux-arm:arm"; do
    preset="${preset_arch%%:*}"
    arch="${preset_arch##*:}"
    src="${OUT_DIR}/build-${preset}/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel"
    if [[ -f "${src}" ]]; then
        dest_dir="${VERSION_DIR}/linux/${arch}"
        mkdir -p "${dest_dir}"
        cp -f "${src}" "${dest_dir}/${LINUX_NAME}"
        echo "==> Linux ${arch}: ${src} -> ${dest_dir}/${LINUX_NAME}"
    fi
done

# Windows 複製（若有）
WINDOWS_DEST="${VERSION_DIR}/windows"
WINTUN_COPIED=""
if [[ -n "${WIN_EXE}" ]] && [[ -f "${WIN_EXE}" ]]; then
    mkdir -p "${WINDOWS_DEST}"
    WIN_SRCDIR="$(dirname "${WIN_EXE}")"
    cp -f "${WIN_EXE}" "${WINDOWS_DEST}/${WIN_NAME}"
    echo "==> Windows: ${WIN_EXE} -> ${WINDOWS_DEST}/${WIN_NAME}"
    if [[ -f "${WIN_SRCDIR}/${WINTUN_NAME}" ]]; then
        cp -f "${WIN_SRCDIR}/${WINTUN_NAME}" "${WINDOWS_DEST}/${WINTUN_NAME}"
        WINTUN_COPIED="${WINDOWS_DEST}/${WINTUN_NAME}"
        echo "==> Windows: ${WIN_SRCDIR}/${WINTUN_NAME} -> ${WINTUN_COPIED}"
    fi
fi

# macOS 依架構複製（若有）
for preset_arch in "ci-macOS-x64:x64" "ci-macOS-arm64:arm64"; do
    preset="${preset_arch%%:*}"
    arch="${preset_arch##*:}"
    src="${OUT_DIR}/build-${preset}/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel"
    if [[ -f "${src}" ]]; then
        dest_dir="${VERSION_DIR}/macos/${arch}"
        mkdir -p "${dest_dir}"
        cp -f "${src}" "${dest_dir}/${LINUX_NAME}"
        echo "==> macOS ${arch}: ${src} -> ${dest_dir}/${LINUX_NAME}"
    fi
done

cat > "${STATE_DIR}/last_build.json" << EOF
{
  "last_version": "${VER}",
  "last_build_time": "$(date -Iseconds)",
  "linux_path": "${LINUX_EXE}",
  "windows_path": "${WIN_EXE}",
  "latest_version_dir": "${VERSION_DIR}",
  "linux_copied": "${VERSION_DIR}/linux",
  "windows_copied": "${WINDOWS_DEST}/${WIN_NAME}",
  "windows_wintun_copied": "${WINTUN_COPIED}"
}
EOF

# 打包建置產物為 tar.gz 並上傳至觸發建置的 Telegram 對話（由 /build 觸發時會有 BUILD_CHAT_ID）
notify "📦 正在打包建置產物並上傳至 Telegram…"
if python3 "${BIN_DIR}/pack_and_upload_telegram.py" "${VERSION_DIR}" "${VER}" 2>> "${LOG_FILE}"; then
    UPLOAD_MSG="📎 建置產物已打包為 tar.gz 並上傳至本對話，請從上方附件下載。"
else
    UPLOAD_MSG="⚠️ 打包完成，但 Telegram 上傳失敗或未由 Bot 觸發（產物已保留於 state/ 與 latest_version/）。"
fi

rm -f "${LOCK_FILE}"
echo "==> run_build.sh finished at $(date -Iseconds)"

# Telegram：列出編譯產出與複製後目錄（依平台）、檔名，以及上傳結果
NOTIFY_MSG="✅ 步驟 4/4 完成：建置成功
版本：${VER}

【編譯產出】
• Linux：${LINUX_EXE}
• Windows：${WIN_EXE}"

NOTIFY_MSG="${NOTIFY_MSG}

【已複製到】${VERSION_DIR}
• linux/x64、arm64、arm（依實際編譯）/${LINUX_NAME}
• windows/${WIN_NAME}"
[[ -n "${WINTUN_COPIED}" ]] && NOTIFY_MSG="${NOTIFY_MSG}
• windows/${WINTUN_NAME}"
NOTIFY_MSG="${NOTIFY_MSG}
"
NOTIFY_MSG="${NOTIFY_MSG}

${UPLOAD_MSG}

可用 /version 或 /status 查詢。"
notify "${NOTIFY_MSG}"
