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

echo "[build.sh] 建立本地 image macdev/gitlab-runner:latest（建置時 --pull 拉取最新基底映像）..."
# 不使用 docker compose pull：服務 image 名稱為本地自建的 macdev/gitlab-runner，
# registry 上不存在，pull 會失敗。改以 build --pull 於建置時更新基底映像。
docker compose build --pull

echo "[build.sh] 完成。接著執行 ../run.sh register 註冊，再 ../run.sh up 啟動。"
