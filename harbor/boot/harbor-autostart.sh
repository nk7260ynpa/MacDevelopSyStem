#!/usr/bin/env bash
#
# Harbor 開機自動啟動腳本。
#
# 由 LaunchAgent（com.chen.harbor-autostart）於使用者登入後呼叫，用以解決
# 主機重開機時的啟動競態：
#   系統重啟時 Docker daemon 會依各容器的 restart:always 各自恢復容器，此路徑
#   「繞過」docker compose 的 depends_on 編排，導致眾 service 搶在 harbor-log
#   就緒前啟動，syslog logging driver 連不上 1514 而以 ExitCode 128 退出。
#
# 本腳本改走正確路徑：
#   1. 等待 Docker daemon 就緒（Docker Desktop 登入後需數十秒才啟動）。
#   2. 執行 harbor/run.sh（docker compose up -d），由 compose 依 depends_on
#      先確保 harbor-log healthy，再依序拉起其餘 service。
#
# 用法：本腳本通常由 launchd 觸發，無需手動執行；如需手動測試可直接執行。

set -euo pipefail

# launchd 環境的 PATH 極精簡，補上 Docker Desktop CLI 所在路徑。
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HARBOR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_DIR="${HARBOR_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/harbor-autostart.log"
readonly DOCKER_BIN="/usr/local/bin/docker"
readonly MAX_WAIT_SECONDS=300
readonly POLL_INTERVAL=5
# 與 watchdog（com.chen.harbor-watchdog）共用，確保同一時刻僅一個程序拉起 Harbor。
readonly LOCK_DIR="${LOG_DIR}/.harbor-boot.lock"
readonly LOCK_STALE_SECONDS=600

mkdir -p "${LOG_DIR}"

# 將訊息附帶時間戳寫入 log 檔。
log() {
  printf '%s [harbor-autostart] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${LOG_FILE}"
}

# 取得互斥鎖（macOS 無內建 flock，改用 mkdir 原子性）。
# 成功取鎖回傳 0；鎖被占用且未過期回傳 1；逾時殘留鎖則回收後重取。
acquire_lock() {
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    return 0
  fi
  local lock_age
  lock_age=$(( $(date +%s) - $(stat -f %m "${LOCK_DIR}" 2>/dev/null || echo 0) ))
  if (( lock_age > LOCK_STALE_SECONDS )); then
    log "偵測到過期鎖（鎖齡 ${lock_age}s），回收後重取。"
    rmdir "${LOCK_DIR}" 2>/dev/null || true
    mkdir "${LOCK_DIR}" 2>/dev/null && return 0
  fi
  return 1
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
  log "Docker daemon 已就緒（等待約 ${waited}s），開始啟動 Harbor..."

  # 取鎖；若 watchdog 已在拉起，略過以免重複 compose。
  if ! acquire_lock; then
    log "另一啟動／巡檢程序進行中，略過本次啟動。"
    exit 0
  fi
  trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

  if "${HARBOR_DIR}/run.sh" >>"${LOG_FILE}" 2>&1; then
    log "Harbor 已透過 run.sh 完成啟動。"
  else
    log "錯誤：run.sh 執行失敗，請檢視上方輸出。"
    exit 1
  fi
}

main "$@"
