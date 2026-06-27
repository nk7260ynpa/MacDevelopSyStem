#!/usr/bin/env bash
#
# 安裝 GitLab 開機自動啟動 LaunchAgent。
#
# 將 plist 範本中的路徑佔位符替換為實際 gitlab 目錄後，寫入
# ~/Library/LaunchAgents 並載入：
#   - com.chen.gitlab-autostart：登入（主機重開機）後等 Docker daemon 就緒再啟動 GitLab。
#
# 前提：Docker Desktop 須設為登入時自動啟動，否則重開機後 daemon 不會啟動。
#
# 用法：
#   ./install.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly GITLAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly AGENTS_DIR="${HOME}/Library/LaunchAgents"
readonly GUI_DOMAIN="gui/$(id -u)"
readonly LABELS=(
  "com.chen.gitlab-autostart"
)

mkdir -p "${AGENTS_DIR}"

for label in "${LABELS[@]}"; do
  template="${SCRIPT_DIR}/${label}.plist"
  target="${AGENTS_DIR}/${label}.plist"

  # 以實際 gitlab 目錄絕對路徑替換範本佔位符後寫入目標位置。
  sed "s|__GITLAB_DIR__|${GITLAB_DIR}|g" "${template}" >"${target}"
  echo "[install] 已產生 ${target}"

  # 若已載入舊版本，先卸載確保更新後設定生效。
  if launchctl print "${GUI_DOMAIN}/${label}" >/dev/null 2>&1; then
    launchctl bootout "${GUI_DOMAIN}/${label}" 2>/dev/null || true
    echo "[install] 已卸載既有 LaunchAgent：${label}"
  fi

  launchctl bootstrap "${GUI_DOMAIN}" "${target}"
  echo "[install] 已載入 LaunchAgent：${label}"
done

echo ""
echo "[install] 完成。"
echo "[install]   - autostart：登入（主機重開機）後等 Docker daemon 就緒再啟動 GitLab。"
echo "[install] 前提：Docker Desktop 須設為登入時自動啟動，否則 daemon 不會啟動。"
echo "[install] 不必重開機，立即測試一次："
echo "[install]   launchctl kickstart -k ${GUI_DOMAIN}/com.chen.gitlab-autostart"
echo "[install] 查看執行 log："
echo "[install]   tail -f ${GITLAB_DIR}/logs/gitlab-autostart.log"
