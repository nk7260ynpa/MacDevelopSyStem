#!/usr/bin/env bash
#
# GitLab Runner 開機自動啟動腳本。
#
# 由 LaunchAgent（com.chen.gitlab-runner-autostart）於使用者登入後呼叫。Runner 依賴
# GitLab（透過 host.docker.internal:8080 連回），故啟動前需先確認相依條件就緒：
#   1. 等待 Docker daemon 就緒（Docker Desktop 登入後需數十秒才啟動）。
#   2. 若尚未註冊（無 docker/data/config.toml）→ 記一筆 log 後結束，不視為錯誤。
#   3. 輪詢等待 GitLab health 端點就緒（逾時仍續啟動，Runner 連不上會自行重連）。
#   4. 執行 gitlab-runner/run.sh up（docker compose up -d）。
#
# 用法：本腳本通常由 launchd 觸發，無需手動執行；如需手動測試可直接執行。

set -euo pipefail

# launchd 環境的 PATH 極精簡，補上 Docker Desktop CLI 所在路徑。
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNNER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_DIR="${RUNNER_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/gitlab-runner-autostart.log"
readonly CONFIG_FILE="${RUNNER_DIR}/docker/data/config.toml"
readonly DOCKER_BIN="/usr/local/bin/docker"
readonly GITLAB_HEALTH_URL="http://localhost:8080/-/health"
readonly MAX_WAIT_SECONDS=300
readonly POLL_INTERVAL=5

mkdir -p "${LOG_DIR}"

# 將訊息附帶時間戳寫入 log 檔。
log() {
  printf '%s [gitlab-runner-autostart] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${LOG_FILE}"
}

main() {
  log "開機自動啟動觸發，等待 Docker daemon 就緒..."

  local waited=0
  until "${DOCKER_BIN}" info >/dev/null 2>&1; do
    if (( waited >= MAX_WAIT_SECONDS )); then
      log "錯誤：等待 Docker daemon 逾時（${MAX_WAIT_SECONDS}s），放棄啟動。"
      exit 1
    fi
    sleep "${POLL_INTERVAL}"
    waited=$(( waited + POLL_INTERVAL ))
  done
  log "Docker daemon 已就緒（等待約 ${waited}s）。"

  # 尚未註冊 Runner（無 config.toml）→ 無從啟動，記錄後結束（非錯誤）。
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    log "尚未註冊 Runner（找不到 ${CONFIG_FILE}），略過啟動。請先執行 run.sh register。"
    exit 0
  fi

  # 等待 GitLab 就緒（Runner 依賴它）；逾時仍續啟動，Runner 連不上會自行重連。
  log "等待 GitLab health 端點就緒（${GITLAB_HEALTH_URL}）..."
  waited=0
  until curl -fsS "${GITLAB_HEALTH_URL}" >/dev/null 2>&1; do
    if (( waited >= MAX_WAIT_SECONDS )); then
      log "警告：等待 GitLab 逾時（${MAX_WAIT_SECONDS}s），仍續啟動 Runner（將自行重連）。"
      break
    fi
    sleep "${POLL_INTERVAL}"
    waited=$(( waited + POLL_INTERVAL ))
  done
  log "開始啟動 GitLab Runner..."

  if "${RUNNER_DIR}/run.sh" up >>"${LOG_FILE}" 2>&1; then
    log "GitLab Runner 已透過 run.sh 完成啟動。"
  else
    log "錯誤：run.sh 執行失敗，請檢視上方輸出。"
    exit 1
  fi
}

main "$@"
