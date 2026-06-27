#!/usr/bin/env bash
#
# 一鍵安裝全部服務的開機自動啟動 LaunchAgent。
#
# 依序安裝 Harbor（autostart + watchdog）、GitLab（autostart）、GitLab Runner（autostart），
# 讓主機重開機後三者皆自動啟動。各子安裝腳本以 BASH_SOURCE 自解析路徑，從任何位置呼叫皆可。
#
# 前提：Docker Desktop 須設為「登入時自動啟動」，否則重開機後 Docker daemon 不會啟動，
# 任何 LaunchAgent 都將空等逾時。請於 Docker Desktop → Settings → General 勾選
# "Start Docker Desktop when you sign in"。
#
# 用法：
#   ./install-all.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALLERS=(
  "harbor/boot/install.sh"
  "gitlab/boot/install.sh"
  "gitlab-runner/boot/install.sh"
)

echo "[install-all] 前提提醒：請確認 Docker Desktop 已設為「登入時自動啟動」。"
echo ""

for installer in "${INSTALLERS[@]}"; do
  echo "=== 執行 ${installer} ==="
  bash "${SCRIPT_DIR}/${installer}"
  echo ""
done

echo "[install-all] 全部完成。三項服務將於登入（主機重開機）後自動啟動。"
