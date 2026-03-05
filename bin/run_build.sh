#!/usr/bin/env bash
# Run full build: zgate-sdk-c-builder then zgate-tunnel-sdk-c-builder.
# Expects: BOT_ROOT, state/building.lock created by caller; updates state/last_build.json on success.
# Copyright (c) eCloudseal Inc.  All rights reserved.  Author: Lai Hou Chang (James Lai)
set -euo pipefail
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_ROOT="$(cd "${BIN_DIR}/.." && pwd)"
STATE_DIR="${BOT_ROOT}/state"
LOCK_FILE="${STATE_DIR}/building.lock"

# Load .env if present (SUDO_PASS 於安裝時寫入 .env，供非互動建置使用)
if [[ -f "${BOT_ROOT}/.env" ]]; then
    set -a
    source "${BOT_ROOT}/.env"
    set +a
fi

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

# 步驟 2 進行中：檢查 zgate-tunnel-sdk-c-builder/latest_version 與 output 已產出平台，即時回報
report_step2_status() {
    local list=""
    local tb_latest="${TUNNEL_BUILDER_ROOT}/latest_version"
    if [[ -d "${tb_latest}" ]]; then
        for vdir in "${tb_latest}"/*/; do
            [[ -d "${vdir}" ]] || continue
            local ver_name
            ver_name="$(basename "${vdir}")"
            local parts=()
            [[ -f "${vdir}linux/x64/zgate-edge-tunnel" ]] && parts+=("linux/x64")
            [[ -f "${vdir}linux/arm64/zgate-edge-tunnel" ]] && parts+=("linux/arm64")
            [[ -f "${vdir}linux/arm/zgate-edge-tunnel" ]] && parts+=("linux/arm")
            [[ -f "${vdir}windows/zgate-edge-tunnel.exe" ]] && parts+=("windows")
            [[ -f "${vdir}macos/x64/zgate-edge-tunnel" ]] && parts+=("macos/x64")
            [[ -f "${vdir}macos/arm64/zgate-edge-tunnel" ]] && parts+=("macos/arm64")
            if [[ ${#parts[@]} -gt 0 ]]; then
                list="版本 ${ver_name}：$(IFS=,; echo "${parts[*]}")"
                break
            fi
        done
    fi
    if [[ -z "${list}" ]] && [[ -d "${TUNNEL_BUILDER_ROOT}/output" ]]; then
        for out_ver in "${TUNNEL_BUILDER_ROOT}/output"/zgate-tunnel-sdk-c-*/; do
            [[ -d "${out_ver}" ]] || continue
            local parts=()
            for p in ci-linux-x64 ci-linux-arm64 ci-linux-arm; do
                [[ -f "${out_ver}build-${p}/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel" ]] && parts+=("${p#ci-}")
            done
            [[ -f "${out_ver}build-ci-windows-x64-mingw/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel.exe" ]] && parts+=("windows")
            [[ -f "${out_ver}build-ci-macOS-x64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel" ]] && parts+=("macos-x64")
            [[ -f "${out_ver}build-ci-macOS-arm64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel" ]] && parts+=("macos-arm64")
            if [[ ${#parts[@]} -gt 0 ]]; then
                list="output 編譯中：$(IFS=,; echo "${parts[*]}")"
                break
            fi
        done
    fi
    if [[ -n "${list}" ]]; then
        notify "📋 步驟 2/4 進行中：${list}"
    else
        notify "📋 步驟 2/4 進行中：編譯中，尚未產出平台…"
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
# 背景執行 tunnel build，每 3 分鐘依 builder/latest_version 與 output 回報已產出平台
(cd "${TUNNEL_BUILDER_ROOT}" && ./build.sh ${TUNNEL_BUILD_ARG}) &
TUNNEL_PID=$!
REPORT_INTERVAL=180
sleep "${REPORT_INTERVAL}"
report_step2_status
while kill -0 "${TUNNEL_PID}" 2>/dev/null; do
    sleep "${REPORT_INTERVAL}"
    kill -0 "${TUNNEL_PID}" 2>/dev/null || break
    report_step2_status
done
wait "${TUNNEL_PID}" || true
TUNNEL_EXIT=$?
if [[ "${TUNNEL_EXIT}" -ne 0 ]]; then
    echo "Error: zgate-tunnel-sdk-c-builder failed (exit ${TUNNEL_EXIT})" >&2
    notify "❌ 建置失敗：zgate-tunnel-sdk-c 編譯錯誤"
    rm -f "${LOCK_FILE}"
    exit 1
fi
notify "✅ 步驟 2/4 完成：zgate-tunnel 建置成功"

# 3) 以 zgate-tunnel-sdk-c-builder/latest_version 為準檢查產出；有則複製到 bot latest_version、寫入 state
notify "📋 步驟 3/4：檢查產出與寫入狀態…"
REQ_PLATFORM="${BUILD_PLATFORM:-all}"
TB_LATEST="${TUNNEL_BUILDER_ROOT}/latest_version"
LATEST_DIR="${BOT_ROOT}/latest_version"
LINUX_NAME="zgate-edge-tunnel"
WIN_NAME="zgate-edge-tunnel.exe"
WINTUN_NAME="wintun.dll"
VER=""
USE_BUILDER_LATEST=0
WINDOWS_DEST=""
WINTUN_COPIED=""

# 優先：檢查 builder 的 latest_version 是否已有符合條件的版本
if [[ -d "${TB_LATEST}" ]]; then
    for vdir in "${TB_LATEST}"/*/; do
        [[ -d "${vdir}" ]] || continue
        ver_cand="$(basename "${vdir}")"
        has_linux=0
        has_win=0
        has_macos=0
        [[ -f "${vdir}linux/x64/${LINUX_NAME}" ]] || [[ -f "${vdir}linux/arm64/${LINUX_NAME}" ]] || [[ -f "${vdir}linux/arm/${LINUX_NAME}" ]] && has_linux=1
        [[ -f "${vdir}windows/${WIN_NAME}" ]] && has_win=1
        [[ -f "${vdir}macos/x64/${LINUX_NAME}" ]] || [[ -f "${vdir}macos/arm64/${LINUX_NAME}" ]] && has_macos=1
        ok=0
        case "${REQ_PLATFORM}" in
            linux)  [[ "${has_linux}" -eq 1 ]] && ok=1 ;;
            windows) [[ "${has_win}" -eq 1 ]] && ok=1 ;;
            macos)  [[ "${has_macos}" -eq 1 ]] && ok=1 ;;
            all|*)  [[ "${has_linux}" -eq 1 ]] && [[ "${has_win}" -eq 1 ]] && ok=1 ;;
        esac
        if [[ "${ok}" -eq 1 ]]; then
            VER="${ver_cand}"
            USE_BUILDER_LATEST=1
            break
        fi
    done
fi

# 若 builder latest_version 有符合條件，直接複製到 bot latest_version
if [[ "${USE_BUILDER_LATEST}" -eq 1 ]] && [[ -n "${VER}" ]]; then
    VERSION_DIR="${LATEST_DIR}/${VER}"
    mkdir -p "${VERSION_DIR}"
    rsync -a --exclude=".git" "${TB_LATEST}/${VER}/" "${VERSION_DIR}/" 2>/dev/null || cp -r "${TB_LATEST}/${VER}/"* "${VERSION_DIR}/" 2>/dev/null || true
    [[ -f "${VERSION_DIR}/windows/${WINTUN_NAME}" ]] && WINTUN_COPIED="${VERSION_DIR}/windows/${WINTUN_NAME}"
    WINDOWS_DEST="${VERSION_DIR}/windows"
    LINUX_EXE="${VERSION_DIR}/linux/x64/${LINUX_NAME}"
    [[ -f "${LINUX_EXE}" ]] || LINUX_EXE="${VERSION_DIR}/linux/arm64/${LINUX_NAME}"
    [[ -f "${LINUX_EXE}" ]] || LINUX_EXE="${VERSION_DIR}/linux/arm/${LINUX_NAME}"
    WIN_EXE="${VERSION_DIR}/windows/${WIN_NAME}"
    echo "==> 已依 builder latest_version 複製至 ${VERSION_DIR}"
fi

# 若未從 builder latest_version 取得，則從 output/ 偵測並複製（原有邏輯）
if [[ -z "${VER}" ]] || [[ "${USE_BUILDER_LATEST}" -eq 0 ]]; then
    OUT="${OUTPUT_DIR}"
    for dir in "${OUT}"/zgate-tunnel-sdk-c-*; do
        [[ -d "${dir}" ]] || continue
        VER="$(basename "${dir}" | sed 's/^zgate-tunnel-sdk-c-//')"
        break
    done
    [[ -n "${VER}" ]] && OUT_DIR="${OUT}/zgate-tunnel-sdk-c-${VER}"
    LINUX_EXE=""
    for preset in ci-linux-x64 ci-linux-arm64 ci-linux-arm; do
        exe="${OUT_DIR}/build-${preset}/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel"
        [[ -f "${exe}" ]] && LINUX_EXE="${exe}" && break
    done
    WIN_EXE="${OUT_DIR}/build-ci-windows-x64-mingw/programs/zgate-edge-tunnel/zgate-edge-tunnel.exe"
    [[ -f "${WIN_EXE}" ]] || WIN_EXE="${OUT_DIR}/build-ci-windows-x64-mingw/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel.exe"
    [[ -f "${WIN_EXE}" ]] || WIN_EXE=""
    ARTIFACT_OK=0
    case "${REQ_PLATFORM}" in
        linux)  [[ -n "${LINUX_EXE}" ]] && [[ -f "${LINUX_EXE}" ]] && ARTIFACT_OK=1 ;;
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
        notify "❌ 建置失敗：未找到符合所選平台（${REQ_PLATFORM}）的二進位檔（請檢查 ${TUNNEL_BUILDER_ROOT}/latest_version 或 output）"
        rm -f "${LOCK_FILE}"
        exit 1
    fi
    VERSION_DIR="${LATEST_DIR}/${VER}"
    WINDOWS_DEST="${VERSION_DIR}/windows"
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
    if [[ -n "${WIN_EXE}" ]] && [[ -f "${WIN_EXE}" ]]; then
        mkdir -p "${WINDOWS_DEST}"
        WIN_SRCDIR="$(dirname "${WIN_EXE}")"
        cp -f "${WIN_EXE}" "${WINDOWS_DEST}/${WIN_NAME}"
        [[ -f "${WIN_SRCDIR}/${WINTUN_NAME}" ]] && cp -f "${WIN_SRCDIR}/${WINTUN_NAME}" "${WINDOWS_DEST}/${WINTUN_NAME}" && WINTUN_COPIED="${WINDOWS_DEST}/${WINTUN_NAME}"
    fi
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
fi

if [[ -z "${VER}" ]]; then
    notify "❌ 建置失敗：latest_version 與 output 皆無符合所選平台（${REQ_PLATFORM}）的產出"
    rm -f "${LOCK_FILE}"
    exit 1
fi

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
