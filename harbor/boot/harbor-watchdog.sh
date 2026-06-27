#!/usr/bin/env bash
#
# Harbor 守護巡檢腳本。
#
# 補強開機自動啟動（com.chen.harbor-autostart）的盲區：
#   autostart 採 LaunchAgent 的 RunAtLoad，僅在「使用者登入（主機重開機）」時觸發。
#   但 Docker daemon 若「單獨重啟」（如 Docker Desktop 更新、手動重啟、daemon 崩潰
#   恢復），並不會重新登入、故不觸發 autostart；此時 daemon 依各容器的 restart:always
#   各自恢復容器，繞過 compose 的 depends_on 編排，致眾 service 搶在 harbor-log 就緒
#   前啟動，syslog logging driver 連不上 1514 而以 ExitCode 128 退出，且重試耗盡後
#   被 docker 放棄——最終僅剩 harbor-log 存活、其餘集體陣亡而無人拉回。
#
# 本腳本由 LaunchAgent（com.chen.harbor-watchdog）依 StartInterval 定期觸發，偵測
# 「容器存在卻未全數 running」即以 run.sh（docker compose up -d）依正確順序補起：
#   - 僅在 Docker daemon 已就緒且設定已產生時動作，否則靜默結束等下次巡檢。
#   - 容器完全不存在（total=0，多為人為 down）時不動作，以免違背使用者意願拉起。
#   - 與 autostart 共用 mkdir 原子鎖，避免登入瞬間兩者同時 compose 而衝突。
#
# 用法：本腳本通常由 launchd 定期觸發，無需手動執行；如需手動測試可直接執行。

set -euo pipefail

# launchd 環境的 PATH 極精簡，補上 Docker Desktop CLI 所在路徑。
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HARBOR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly DOCKER_DIR="${HARBOR_DIR}/docker"
readonly LOG_DIR="${HARBOR_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/harbor-watchdog.log"
readonly DOCKER_BIN="/usr/local/bin/docker"
# autostart 與 watchdog 共用，確保同一時刻僅一個程序在拉起 Harbor。
readonly LOCK_DIR="${LOG_DIR}/.harbor-boot.lock"
readonly LOCK_STALE_SECONDS=600

mkdir -p "${LOG_DIR}"

# 將訊息附帶時間戳寫入 log 檔。
log() {
  printf '%s [harbor-watchdog] %s\n' \
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
  # Docker daemon 未就緒（剛重啟／Docker Desktop 啟動中）→ 靜默結束，等下次巡檢。
  "${DOCKER_BIN}" info >/dev/null 2>&1 || exit 0

  cd "${DOCKER_DIR}"

  # 尚未產生設定（未執行 build.sh）→ 無從啟動，結束。
  [[ -d data/config/core ]] || exit 0

  # 全部 Harbor 容器數與其中 running 數（compose ps 預設僅列 running，-a 列全部）。
  local total running
  total=$("${DOCKER_BIN}" compose ps -aq 2>/dev/null | grep -c . || true)
  running=$("${DOCKER_BIN}" compose ps -q 2>/dev/null | grep -c . || true)

  # 容器完全不存在（多為人為 down）→ 不違背意願拉起。
  (( total == 0 )) && exit 0
  # 全數 running → 健康，結束。
  (( running == total )) && exit 0

  # 有容器存在卻未全數 running → 取鎖後修復。
  if ! acquire_lock; then
    log "另一啟動／巡檢程序進行中，略過本次。"
    exit 0
  fi
  trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

  log "偵測到 Harbor 異常：${running}/${total} 容器 running，以 run.sh 依序補起..."
  if "${HARBOR_DIR}/run.sh" >>"${LOG_FILE}" 2>&1; then
    log "修復完成。"
  else
    log "錯誤：run.sh 執行失敗，詳見上方輸出。"
  fi
}

main "$@"
