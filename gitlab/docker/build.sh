#!/usr/bin/env bash
#
# 建立 GitLab CE 本地 image。
#
# 用法：
#   ./build.sh
#
# 流程：
#   從 Dockerfile 建出本地 image macdev/gitlab:latest，
#   並於建置時以 --pull 取得 Dockerfile 指定的官方基底映像。
#
# 注意：不使用 docker compose pull——compose 中宣告的 service image 名稱為
# 本地自建的 macdev/gitlab，registry 上不存在，pull 必然失敗並中止腳本，
# 導致實際的 build 從未執行（升級版本時會誤以為已更新）。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "[build.sh] 建立本地 image macdev/gitlab:latest（建置時 --pull 拉取最新基底映像）..."
docker compose build --pull

echo "[build.sh] 完成。可使用 ../run.sh docker 啟動 GitLab。"
