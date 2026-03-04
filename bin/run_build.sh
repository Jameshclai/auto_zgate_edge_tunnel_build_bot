#!/usr/bin/env bash
# Run full build: zgate-sdk-c-builder then zgate-tunnel-sdk-c-builder.
# Expects: BOT_ROOT, state/building.lock created by caller; updates state/last_build.json on success.
set -euo pipefail
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_ROOT="$(cd "${BIN_DIR}/.." && pwd)"
STATE_DIR="${BOT_ROOT}/state"
LOCK_FILE="${STATE_DIR}/building.lock"

# Load .env if present
if [[ -f "${BOT_ROOT}/.env" ]]; then
    set -a
    source "${BOT_ROOT}/.env"
    set +a
fi

SDK_BUILDER_ROOT="${SDK_BUILDER_ROOT:-$(dirname "${BOT_ROOT}")/zgate-sdk-c-builder}"
TUNNEL_BUILDER_ROOT="${TUNNEL_BUILDER_ROOT:-$(dirname "${BOT_ROOT}")/zgate-tunnel-sdk-c-builder}"
export TUNNEL_PRESETS="${TUNNEL_PRESETS:-ci-linux-x64;ci-windows-x64-mingw}"
export ZGATE_SDK_BUILDER_OUTPUT="${ZGATE_SDK_BUILDER_OUTPUT:-${SDK_BUILDER_ROOT}/output}"

if [[ ! -d "${SDK_BUILDER_ROOT}" ]] || [[ ! -x "${SDK_BUILDER_ROOT}/build.sh" ]]; then
    echo "Error: SDK builder not found at ${SDK_BUILDER_ROOT}" >&2
    exit 1
fi
if [[ ! -d "${TUNNEL_BUILDER_ROOT}" ]] || [[ ! -x "${TUNNEL_BUILDER_ROOT}/build.sh" ]]; then
    echo "Error: Tunnel builder not found at ${TUNNEL_BUILDER_ROOT}" >&2
    exit 1
fi

LOG_FILE="${BOT_ROOT}/state/build.log"
mkdir -p "${STATE_DIR}"
exec 1> >(tee -a "${LOG_FILE}") 2>&1
echo "==> run_build.sh started at $(date -Iseconds)"

# 1) Build SDK
echo "==> Building zgate-sdk-c..."
if ! (cd "${SDK_BUILDER_ROOT}" && ./build.sh); then
    echo "Error: zgate-sdk-c-builder failed" >&2
    rm -f "${LOCK_FILE}"
    exit 1
fi

# 2) Build tunnel (uses SDK output)
echo "==> Building zgate-tunnel-sdk-c..."
export OUTPUT_DIR="${OUTPUT_DIR:-${TUNNEL_BUILDER_ROOT}/output}"
if [[ -f "${TUNNEL_BUILDER_ROOT}/config.env" ]]; then
    set -a
    source "${TUNNEL_BUILDER_ROOT}/config.env"
    set +a
fi
if ! (cd "${TUNNEL_BUILDER_ROOT}" && ./build.sh); then
    echo "Error: zgate-tunnel-sdk-c-builder failed" >&2
    rm -f "${LOCK_FILE}"
    exit 1
fi

# 3) Detect version and artifact paths from tunnel output
# Tunnel output dir: OUTPUT_DIR/zgate-tunnel-sdk-c-{ver}
OUT="${OUTPUT_DIR}"
for dir in "${OUT}"/zgate-tunnel-sdk-c-*; do
    [[ -d "${dir}" ]] || continue
    VER="$(basename "${dir}" | sed 's/^zgate-tunnel-sdk-c-//')"
    LINUX_EXE="${dir}/build-ci-linux-x64/programs/zgate-edge-tunnel/Release/zgate-edge-tunnel"
    WIN_EXE="${dir}/build-ci-windows-x64-mingw/programs/zgate-edge-tunnel/zgate-edge-tunnel.exe"
    if [[ -f "${LINUX_EXE}" ]] && [[ -f "${WIN_EXE}" ]]; then
        echo "==> Build success. Version ${VER}"
        cat > "${STATE_DIR}/last_build.json" << EOF
{
  "last_version": "${VER}",
  "last_build_time": "$(date -Iseconds)",
  "linux_path": "${LINUX_EXE}",
  "windows_path": "${WIN_EXE}"
}
EOF
        break
    fi
done

rm -f "${LOCK_FILE}"
echo "==> run_build.sh finished at $(date -Iseconds)"
