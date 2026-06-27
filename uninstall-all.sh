#!/usr/bin/env bash
#
# 一鍵卸載全部服務的開機自動啟動 LaunchAgent。
#
# 反向依序卸載 GitLab Runner、GitLab、Harbor 的 LaunchAgent。
# 不影響目前已在執行的容器。
#
# 用法：
#   ./uninstall-all.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly UNINSTALLERS=(
  "gitlab-runner/boot/uninstall.sh"
  "gitlab/boot/uninstall.sh"
  "harbor/boot/uninstall.sh"
)

for uninstaller in "${UNINSTALLERS[@]}"; do
  echo "=== 執行 ${uninstaller} ==="
  bash "${SCRIPT_DIR}/${uninstaller}"
  echo ""
done

echo "[uninstall-all] 全部完成。開機自動啟動已停用（不影響執行中的容器）。"
