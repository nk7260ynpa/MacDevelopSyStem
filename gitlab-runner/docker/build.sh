#!/usr/bin/env bash
#######################################
# GitLab Runner Docker 映像建置腳本
# 拉取官方 GitLab Runner 映像並建立本地 image（macdev/gitlab-runner:latest）。
# Globals:
#   無
# Arguments:
#   無
# Outputs:
#   docker compose pull / build 之結果
#######################################
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "[build.sh] 拉取官方 GitLab Runner 映像..."
docker compose pull

echo "[build.sh] 建立本地 image macdev/gitlab-runner:latest..."
docker compose build

echo "[build.sh] 完成。接著執行 ../run.sh register 註冊，再 ../run.sh up 啟動。"
