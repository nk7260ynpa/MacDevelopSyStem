#!/usr/bin/env bash
#
# 卸載 Harbor 開機自動啟動 LaunchAgent。
#
# 卸載並移除 ~/Library/LaunchAgents 下的 plist，停用開機自動啟動。
# 不影響目前已在執行的 Harbor 容器。
#
# 用法：
#   ./uninstall.sh

set -euo pipefail

readonly LABEL="com.chen.harbor-autostart"
readonly TARGET="${HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly GUI_DOMAIN="gui/$(id -u)"

if launchctl print "${GUI_DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "${GUI_DOMAIN}/${LABEL}" 2>/dev/null || true
  echo "[uninstall] 已卸載 LaunchAgent：${LABEL}"
else
  echo "[uninstall] LaunchAgent 未載入，略過卸載"
fi

if [[ -f "${TARGET}" ]]; then
  rm -f "${TARGET}"
  echo "[uninstall] 已移除 ${TARGET}"
else
  echo "[uninstall] 找不到 ${TARGET}，略過移除"
fi

echo "[uninstall] 完成。開機自動啟動已停用（不影響執行中的容器）。"
