#!/usr/bin/env bash
#
# 安裝 Harbor 開機自動啟動與守護巡檢 LaunchAgent。
#
# 將各 plist 範本中的路徑佔位符替換為實際 harbor 目錄後，寫入
# ~/Library/LaunchAgents 並載入：
#   - com.chen.harbor-autostart：登入（主機重開機）後以正確順序拉起 Harbor。
#   - com.chen.harbor-watchdog ：每 120s 巡檢，補強 Docker daemon「單獨重啟」
#     （不重新登入、故不觸發 autostart）時的自我修復，避免冷啟動競態殘留。
#
# 用法：
#   ./install.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HARBOR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly AGENTS_DIR="${HOME}/Library/LaunchAgents"
readonly GUI_DOMAIN="gui/$(id -u)"
readonly LABELS=(
  "com.chen.harbor-autostart"
  "com.chen.harbor-watchdog"
)

mkdir -p "${AGENTS_DIR}"

for label in "${LABELS[@]}"; do
  template="${SCRIPT_DIR}/${label}.plist"
  target="${AGENTS_DIR}/${label}.plist"

  # 以實際 harbor 目錄絕對路徑替換範本佔位符後寫入目標位置。
  sed "s|__HARBOR_DIR__|${HARBOR_DIR}|g" "${template}" >"${target}"
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
echo "[install]   - autostart：登入（主機重開機）後自動以正確順序啟動 Harbor。"
echo "[install]   - watchdog ：每 120s 巡檢，涵蓋 Docker daemon 單獨重啟後的自我修復。"
echo "[install] 不必重開機，立即測試一次："
echo "[install]   launchctl kickstart -k ${GUI_DOMAIN}/com.chen.harbor-watchdog"
echo "[install] 查看執行 log："
echo "[install]   tail -f ${HARBOR_DIR}/logs/harbor-autostart.log ${HARBOR_DIR}/logs/harbor-watchdog.log"
