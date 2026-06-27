#!/usr/bin/env bash
#
# 卸載 Harbor 開機自動啟動與守護巡檢 LaunchAgent。
#
# 卸載並移除 ~/Library/LaunchAgents 下的 plist，停用兩個 agent。
# 不影響目前已在執行的 Harbor 容器。
#
# 用法：
#   ./uninstall.sh

set -euo pipefail

readonly GUI_DOMAIN="gui/$(id -u)"
readonly AGENTS_DIR="${HOME}/Library/LaunchAgents"
readonly LABELS=(
  "com.chen.harbor-autostart"
  "com.chen.harbor-watchdog"
)

for label in "${LABELS[@]}"; do
  target="${AGENTS_DIR}/${label}.plist"

  if launchctl print "${GUI_DOMAIN}/${label}" >/dev/null 2>&1; then
    launchctl bootout "${GUI_DOMAIN}/${label}" 2>/dev/null || true
    echo "[uninstall] 已卸載 LaunchAgent：${label}"
  else
    echo "[uninstall] LaunchAgent 未載入，略過卸載：${label}"
  fi

  if [[ -f "${target}" ]]; then
    rm -f "${target}"
    echo "[uninstall] 已移除 ${target}"
  else
    echo "[uninstall] 找不到 ${target}，略過移除"
  fi
done

echo "[uninstall] 完成。開機自動啟動與守護巡檢已停用（不影響執行中的容器）。"
