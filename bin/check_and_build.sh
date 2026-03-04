#!/usr/bin/env bash
# Check OpenZiti tunnel latest version and artifact existence; trigger run_build.sh if needed.
# Designed to run every minute (e.g. via systemd timer).
set -euo pipefail
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_ROOT="$(cd "${BIN_DIR}/.." && pwd)"
STATE_DIR="${BOT_ROOT}/state"
LOCK_FILE="${STATE_DIR}/building.lock"
STATE_JSON="${STATE_DIR}/last_build.json"

if [[ -f "${BOT_ROOT}/.env" ]]; then
    set -a
    source "${BOT_ROOT}/.env"
    set +a
fi

# GitHub API: get latest release tag for openziti/ziti-tunnel-sdk-c
get_latest_version() {
    local url="https://api.github.com/repos/openziti/ziti-tunnel-sdk-c/releases/latest"
    local tag
    if command -v jq &>/dev/null; then
        tag=$(curl -sSfL "${url}" | jq -r '.tag_name // empty')
    else
        tag=$(curl -sSfL "${url}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    [[ -z "${tag}" ]] && return 1
    echo "${tag#v}"  # normalize v1.10.10 -> 1.10.10
}

mkdir -p "${STATE_DIR}"
LATEST_VER=""
if ! LATEST_VER="$(get_latest_version 2>/dev/null)"; then
    echo "==> check_and_build: failed to get latest version (API limit or network), skip this run." >&2
    exit 0
fi

NEED_BUILD=0
if [[ ! -f "${STATE_JSON}" ]]; then
    NEED_BUILD=1
else
    read_json() {
        local key="$1"
        if command -v jq &>/dev/null; then
            jq -r --arg k "$key" '.[$k] // ""' "${STATE_JSON}" 2>/dev/null
        else
            python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],''))" "${STATE_JSON}" "$key" 2>/dev/null
        fi
    }
    LAST_VER="$(read_json last_version)"
    LINUX_PATH="$(read_json linux_path)"
    WIN_PATH="$(read_json windows_path)"
    if [[ "${LATEST_VER}" != "${LAST_VER}" ]]; then
        NEED_BUILD=1
    fi
    if [[ -n "${LINUX_PATH}" ]] && [[ ! -f "${LINUX_PATH}" ]]; then NEED_BUILD=1; fi
    if [[ -n "${WIN_PATH}" ]] && [[ ! -f "${WIN_PATH}" ]]; then NEED_BUILD=1; fi
fi

if [[ "${NEED_BUILD}" -eq 0 ]]; then
    exit 0
fi

if [[ -f "${LOCK_FILE}" ]]; then
    echo "==> check_and_build: build already in progress (lock exists), skip." >&2
    exit 0
fi

touch "${LOCK_FILE}"
echo "==> check_and_build: triggering build (latest=${LATEST_VER})."
nohup "${BIN_DIR}/run_build.sh" >> "${STATE_DIR}/build.log" 2>&1 &
exit 0
