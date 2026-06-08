#!/usr/bin/env bash
#
# 安裝 Harbor 開機自動啟動 LaunchAgent。
#
# 將 plist 範本中的路徑佔位符替換為實際 harbor 目錄後，寫入
# ~/Library/LaunchAgents 並載入，使主機開機（使用者登入）後自動以正確順序
# 拉起 Harbor，避免冷啟動競態。
#
# 用法：
#   ./install.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HARBOR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly LABEL="com.chen.harbor-autostart"
readonly TEMPLATE="${SCRIPT_DIR}/${LABEL}.plist"
readonly AGENTS_DIR="${HOME}/Library/LaunchAgents"
readonly TARGET="${AGENTS_DIR}/${LABEL}.plist"
readonly GUI_DOMAIN="gui/$(id -u)"

mkdir -p "${AGENTS_DIR}"

# 以實際 harbor 目錄絕對路徑替換範本佔位符後寫入目標位置。
sed "s|__HARBOR_DIR__|${HARBOR_DIR}|g" "${TEMPLATE}" >"${TARGET}"
echo "[install] 已產生 ${TARGET}"

# 若已載入舊版本，先卸載確保更新後設定生效。
if launchctl print "${GUI_DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "${GUI_DOMAIN}/${LABEL}" 2>/dev/null || true
  echo "[install] 已卸載既有 LaunchAgent"
fi

launchctl bootstrap "${GUI_DOMAIN}" "${TARGET}"
echo "[install] 已載入 LaunchAgent：${LABEL}"
echo ""
echo "[install] 完成。下次開機（登入）後將自動啟動 Harbor。"
echo "[install] 立即測試一次：launchctl kickstart -k ${GUI_DOMAIN}/${LABEL}"
echo "[install] 查看執行 log：tail -f ${HARBOR_DIR}/logs/harbor-autostart.log"
