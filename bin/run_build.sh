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

# 步驟 1 進行中：從 build.log 擷取 vcpkg/編譯進度並通知（每 1 分鐘呼叫）
report_step1_status() {
    local elapsed_min=0
    [[ -n "${STEP1_START:-}" ]] && elapsed_min=$(( ($(date +%s) - STEP1_START) / 60 ))
    local progress=""
    if [[ -f "${LOG_FILE}" ]]; then
        progress=$(tail -n 80 "${LOG_FILE}" 2>/dev/null | grep -oE "Installing [0-9]+/[0-9]+ [^[:space:]]+|Building [^[:space:]]+|Configuring [^[:space:]]+|Downloading [^[:space:]]+" | tail -1 | head -c 60)
        [[ -z "${progress}" ]] && progress=$(tail -n 15 "${LOG_FILE}" 2>/dev/null | grep -v "^$" | tail -1 | sed 's/^[[:space:]]*//' | head -c 55)
    fi
    if [[ -n "${progress}" ]]; then
        notify "📋 步驟 1/4 進行中：${progress}（已執行 ${elapsed_min} 分鐘）"
    else
        notify "📋 步驟 1/4 進行中：編譯 zgate-sdk-c 與 vcpkg 依賴中…（已執行 ${elapsed_min} 分鐘）"
    fi
}

# 步驟 2 進行中：檢查各平台（Linux x64/arm64/arm、Windows、macOS x64/arm64）產出，組出明確說明
report_step2_status() {
    local ver_name=""
    local linux_archs=()
    local windows_ok=0
    local macos_archs=()
    local tb_latest="${TUNNEL_BUILDER_ROOT}/latest_version"
    local from_output=0

    if [[ -d "${tb_latest}" ]]; then
        for vdir in "${tb_latest}"/*/; do
            [[ -d "${vdir}" ]] || continue
            ver_name="$(basename "${vdir}")"
            [[ -f "${vdir}linux/x64/zgate-edge-tunnel" ]] && linux_archs+=("x64")
            [[ -f "${vdir}linux/arm64/zgate-edge-tunnel" ]] && linux_archs+=("arm64")
            [[ -f "${vdir}linux/arm/zgate-edge-tunnel" ]] && linux_archs+=("arm")
            [[ -f "${vdir}windows/zgate-edge-tunnel.exe" ]] && windows_ok=1
            [[ -f "${vdir}macos/x64/zgate-edge-tunnel" ]] && macos_archs+=("x64")
            [[ -f "${vdir}macos/arm64/zgate-edge-tunnel" ]] && macos_archs+=("arm64")
            [[ ${#linux_archs[@]} -gt 0 || ${windows_ok} -eq 1 || ${#macos_archs[@]} -gt 0 ]] && break
        done
    fi
    if [[ ${#linux_archs[@]} -eq 0 ]] && [[ ${windows_ok} -eq 0 ]] && [[ ${#macos_archs[@]} -eq 0 ]] && [[ -d "${TUNNEL_BUILDER_ROOT}/output" ]]; then
        from_output=1
        for out_ver in "${TUNNEL_BUILDER_ROOT}/output"/zgate-tunnel-sdk-c-*/; do
            [[ -d "${out_ver}" ]] || continue
            [[ -f "${out_ver}build-ci-linux-x64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel" ]] && linux_archs+=("x64")
            [[ -f "${out_ver}build-ci-linux-arm64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel" ]] && linux_archs+=("arm64")
            [[ -f "${out_ver}build-ci-linux-arm/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel" ]] && linux_archs+=("arm")
            [[ -f "${out_ver}build-ci-windows-x64-mingw/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel.exe" ]] || [[ -f "${out_ver}build-ci-windows-x64-mingw/programs/zgate-edge-tunnel/zgate-edge-tunnel.exe" ]] && windows_ok=1
            [[ -f "${out_ver}build-ci-macOS-x64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel" ]] && macos_archs+=("x64")
            [[ -f "${out_ver}build-ci-macOS-arm64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel" ]] && macos_archs+=("arm64")
            [[ ${#linux_archs[@]} -gt 0 || ${windows_ok} -eq 1 || ${#macos_archs[@]} -gt 0 ]] && break
        done
    fi

    local line1="📋 步驟 2/4 進行中："
    local done_parts=()
    local building_parts=()
    if [[ ${#linux_archs[@]} -gt 0 ]]; then
        done_parts+=("Linux ($(IFS=,; echo "${linux_archs[*]}"))")
    else
        building_parts+=("Linux (x64、arm64、arm)")
    fi
    if [[ ${windows_ok} -eq 1 ]]; then
        done_parts+=("Windows")
    else
        building_parts+=("Windows")
    fi
    if [[ ${#macos_archs[@]} -gt 0 ]]; then
        done_parts+=("macOS ($(IFS=,; echo "${macos_archs[*]}"))")
    else
        building_parts+=("macOS (x64、arm64)")
    fi

    if [[ ${#done_parts[@]} -gt 0 ]]; then
        line1="${line1}【已建置完成】$(IFS=、; echo "${done_parts[*]}")"
        if [[ ${#building_parts[@]} -gt 0 ]]; then
            line1="${line1}；【尚在建置】$(IFS=、; echo "${building_parts[*]}")"
        fi
        [[ -n "${ver_name}" ]] && line1="${line1}（版本 ${ver_name}）"
        [[ ${from_output} -eq 1 ]] && line1="${line1}（output 編譯中）"
    else
        line1="${line1}【尚在建置】Linux (x64、arm64、arm)、Windows、macOS (x64、arm64)，尚未產出二進位。"
    fi
    notify "${line1}"
}

REPORT_INTERVAL=60
echo "==> run_build.sh started at $(date -Iseconds)"
notify "🔧 建置開始：準備環境。
流程：步驟 1/4 編譯 zgate-sdk-c → 步驟 2/4 編譯各平台 zgate-edge-tunnel（Linux x64/arm64/arm、Windows、macOS x64/arm64）→ 步驟 3/4 檢查複製 → 步驟 4/4 打包上傳。
依賴安裝與編譯進度將每 1 分鐘回報一次。"

# 從 GitHub 下載兩專案（若目錄不存在），並回報下載成功或失敗
if [[ ! -d "${SDK_BUILDER_ROOT}" ]] || [[ ! -f "${SDK_BUILDER_ROOT}/build.sh" ]]; then
    notify "📥 正在下載 zgate-sdk-c-builder…"
    mkdir -p "$(dirname "${SDK_BUILDER_ROOT}")"
    if git clone --depth 1 https://github.com/Jameshclai/zgate-sdk-c-builder.git "${SDK_BUILDER_ROOT}"; then
        notify "✅ 下載 zgate-sdk-c-builder：成功。完成後將進入步驟 1/4（編譯 zgate-sdk-c）。"
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
        notify "✅ 下載 zgate-tunnel-sdk-c-builder：成功。將於步驟 2/4 用於編譯各平台二進位。"
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

# 1) 背景執行 zgate-sdk-c-builder，每 1 分鐘依 build.log 回報依賴/編譯進度
notify "📦 步驟 1/4：正在建置 zgate-sdk-c（含 vcpkg 依賴，可能需 30 分鐘以上）。
本步驟產出將供步驟 2/4 編譯下列平台使用：Linux (x64、arm64、arm)、Windows、macOS (x64、arm64)。"
echo "==> Calling ${SDK_BUILDER_ROOT}/build.sh"
STEP1_START=$(date +%s)
(unset WORK_DIR OUTPUT_DIR; cd "${SDK_BUILDER_ROOT}" && ./build.sh) &
SDK_PID=$!
sleep "${REPORT_INTERVAL:-60}"
report_step1_status
while kill -0 "${SDK_PID}" 2>/dev/null; do
    sleep "${REPORT_INTERVAL:-60}"
    kill -0 "${SDK_PID}" 2>/dev/null || break
    report_step1_status
done
wait "${SDK_PID}" || true
SDK_EXIT=$?
if [[ "${SDK_EXIT}" -ne 0 ]]; then
    echo "Error: zgate-sdk-c-builder failed (exit ${SDK_EXIT})" >&2
    notify "❌ 步驟 1/4 失敗：zgate-sdk-c 編譯錯誤（exit ${SDK_EXIT}）。無法繼續步驟 2/4 各平台建置，請檢查 build.log。"
    rm -f "${LOCK_FILE}"
    exit 1
fi
notify "✅ 步驟 1/4 完成：zgate-sdk-c 建置成功。即將進入步驟 2/4：編譯所選平台之 zgate-edge-tunnel。"

# 2) 完成後，直接呼叫 zgate-tunnel-sdk-c-builder 的 build 程序（需能找到上方 SDK 產出）
# BUILD_PLATFORM：由 Telegram /build 選擇傳入，對應 build.sh -all|-linux|-windows|-macos
TUNNEL_BUILD_ARG="-all"
if [[ -n "${BUILD_PLATFORM:-}" ]]; then
  case "${BUILD_PLATFORM}" in
    all|linux|windows|macos) TUNNEL_BUILD_ARG="-${BUILD_PLATFORM}" ;;
    *) TUNNEL_BUILD_ARG="-all" ;;
  esac
fi
# 依所選平台組出明確的「即將建置平台」說明
case "${BUILD_PLATFORM:-all}" in
  all)   PLATFORM_DESC="Linux (x64、arm64、arm)、Windows、macOS (x64、arm64)" ;;
  linux) PLATFORM_DESC="Linux (x64、arm64、arm)" ;;
  windows) PLATFORM_DESC="Windows" ;;
  macos) PLATFORM_DESC="macOS (x64、arm64)" ;;
  *)     PLATFORM_DESC="Linux (x64、arm64、arm)、Windows、macOS (x64、arm64)" ;;
esac
notify "📦 步驟 2/4：正在建置 zgate-tunnel-sdk-c。
【即將建置平台】${PLATFORM_DESC}
進度將每 1 分鐘回報（已建置完成／尚在建置）。"
echo "==> Calling ${TUNNEL_BUILDER_ROOT}/build.sh ${TUNNEL_BUILD_ARG}"
export OUTPUT_DIR="${OUTPUT_DIR:-${TUNNEL_BUILDER_ROOT}/output}"
# 背景執行 tunnel build，每 1 分鐘依 builder/latest_version 與 output 回報已產出平台
(cd "${TUNNEL_BUILDER_ROOT}" && ./build.sh ${TUNNEL_BUILD_ARG}) &
TUNNEL_PID=$!
sleep "${REPORT_INTERVAL}"
report_step2_status
while kill -0 "${TUNNEL_PID}" 2>/dev/null; do
    sleep "${REPORT_INTERVAL:-60}"
    kill -0 "${TUNNEL_PID}" 2>/dev/null || break
    report_step2_status
done
wait "${TUNNEL_PID}" || true
TUNNEL_EXIT=$?
if [[ "${TUNNEL_EXIT}" -ne 0 ]]; then
    echo "Error: zgate-tunnel-sdk-c-builder failed (exit ${TUNNEL_EXIT})" >&2
    notify "❌ 步驟 2/4 失敗：zgate-tunnel-sdk-c 編譯錯誤（exit ${TUNNEL_EXIT}）。所選平台（Linux x64/arm64/arm、Windows、macOS x64/arm64）未完全產出，請檢查 build.log。"
    rm -f "${LOCK_FILE}"
    exit 1
fi
notify "✅ 步驟 2/4 完成：zgate-tunnel 各選定平台二進位已產出。即將進入步驟 3/4：檢查產出並複製至 latest_version。"

# 3) 以 zgate-tunnel-sdk-c-builder/latest_version 為準檢查產出；有則複製到 bot latest_version、寫入 state
notify "📋 步驟 3/4：正在檢查產出並複製至 latest_version（依所選平台：Linux x64/arm64/arm、Windows、macOS x64/arm64）。"
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
        notify "❌ 步驟 3/4 失敗：未找到符合所選平台（${REQ_PLATFORM}）的二進位檔。
預期產出：Linux (x64、arm64、arm)、Windows、macOS (x64、arm64) 之一或全部。請檢查 ${TUNNEL_BUILDER_ROOT}/latest_version 或 output。"
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
    notify "❌ 建置失敗：未找到符合所選平台（${REQ_PLATFORM}）的產出。
預期產出：Linux (x64、arm64、arm)、Windows、macOS (x64、arm64) 之一或全部，請檢查 builder 的 latest_version 或 output。"
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
notify "📦 步驟 4/4：正在打包上述建置完成平台產物為 tar.gz 並上傳至本對話…"
if python3 "${BIN_DIR}/pack_and_upload_telegram.py" "${VERSION_DIR}" "${VER}" 2>> "${LOG_FILE}"; then
    UPLOAD_MSG="📎 建置產物已打包為 tar.gz 並上傳至本對話，請從上方附件下載。"
else
    UPLOAD_MSG="⚠️ 打包完成，但 Telegram 上傳失敗或未由 Bot 觸發（產物已保留於 state/ 與 latest_version/）。"
fi

rm -f "${LOCK_FILE}"
echo "==> run_build.sh finished at $(date -Iseconds)"

# 依實際產出組出【建置完成平台】說明
PLATFORM_PARTS=()
[[ -f "${VERSION_DIR}/linux/x64/${LINUX_NAME}" ]] || [[ -f "${VERSION_DIR}/linux/arm64/${LINUX_NAME}" ]] || [[ -f "${VERSION_DIR}/linux/arm/${LINUX_NAME}" ]] && {
    LINUX_ARCHS=()
    [[ -f "${VERSION_DIR}/linux/x64/${LINUX_NAME}" ]] && LINUX_ARCHS+=("x64")
    [[ -f "${VERSION_DIR}/linux/arm64/${LINUX_NAME}" ]] && LINUX_ARCHS+=("arm64")
    [[ -f "${VERSION_DIR}/linux/arm/${LINUX_NAME}" ]] && LINUX_ARCHS+=("arm")
    PLATFORM_PARTS+=("Linux ($(IFS=,; echo "${LINUX_ARCHS[*]}"))")
}
[[ -f "${VERSION_DIR}/windows/${WIN_NAME}" ]] && PLATFORM_PARTS+=("Windows")
[[ -f "${VERSION_DIR}/macos/x64/${LINUX_NAME}" ]] || [[ -f "${VERSION_DIR}/macos/arm64/${LINUX_NAME}" ]] && {
    MACOS_ARCHS=()
    [[ -f "${VERSION_DIR}/macos/x64/${LINUX_NAME}" ]] && MACOS_ARCHS+=("x64")
    [[ -f "${VERSION_DIR}/macos/arm64/${LINUX_NAME}" ]] && MACOS_ARCHS+=("arm64")
    PLATFORM_PARTS+=("macOS ($(IFS=,; echo "${MACOS_ARCHS[*]}"))")
}
PLATFORM_LINE="【建置完成平台】$(IFS=、; echo "${PLATFORM_PARTS[*]}")"

# Telegram：列出建置完成平台、產出路徑與上傳結果（讓操作者清楚執行現況與產出）
NOTIFY_MSG="✅ 步驟 4/4 完成：建置成功

${PLATFORM_LINE}
版本：${VER}

【產出路徑】
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

可用 /version 或 /status 查詢目前狀態。"
notify "${NOTIFY_MSG}"
