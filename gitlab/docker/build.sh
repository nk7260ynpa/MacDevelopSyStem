#!/usr/bin/env bash
#
# 建立 GitLab CE 本地 image。
#
# 用法：
#   ./build.sh
#
# 流程：
#   1. 拉取 docker-compose.yaml 中宣告的官方 base image。
#   2. 從 Dockerfile 建出本地 image macdev/gitlab:latest。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "[build.sh] 拉取官方 GitLab CE image..."
docker compose pull

echo "[build.sh] 建立本地 image macdev/gitlab:latest..."
docker compose build

echo "[build.sh] 完成。可使用 ../run.sh 啟動 GitLab。"
