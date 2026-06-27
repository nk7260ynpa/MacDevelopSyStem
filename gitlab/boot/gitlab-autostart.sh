#!/usr/bin/env bash
#
# GitLab 開機自動啟動腳本。
#
# 由 LaunchAgent（com.chen.gitlab-autostart）於使用者登入後呼叫。GitLab 為單一容器，
# docker-compose 設 restart: unless-stopped，於「主機重開機 + Docker Desktop 自啟 +
# 上次為 running」時多能自行恢復；本腳本額外涵蓋「上次被 down/stop 或容器被移除」的盲區，
# 確保登入後一定拉起：
#   1. 等待 Docker daemon 就緒（Docker Desktop 登入後需數十秒才啟動）。
#   2. 執行 gitlab/run.sh（docker compose up -d）。
#
# 用法：本腳本通常由 launchd 觸發，無需手動執行；如需手動測試可直接執行。

set -euo pipefail

# launchd 環境的 PATH 極精簡，補上 Docker Desktop CLI 所在路徑。
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly GITLAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_DIR="${GITLAB_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/gitlab-autostart.log"
readonly DOCKER_BIN="/usr/local/bin/docker"
readonly MAX_WAIT_SECONDS=300
readonly POLL_INTERVAL=5

mkdir -p "${LOG_DIR}"

# 將訊息附帶時間戳寫入 log 檔。
log() {
  printf '%s [gitlab-autostart] %s\n' \
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
  log "Docker daemon 已就緒（等待約 ${waited}s），開始啟動 GitLab..."

  if "${GITLAB_DIR}/run.sh" >>"${LOG_FILE}" 2>&1; then
    log "GitLab 已透過 run.sh 完成啟動。"
  else
    log "錯誤：run.sh 執行失敗，請檢視上方輸出。"
    exit 1
  fi
}

main "$@"
