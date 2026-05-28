#!/usr/bin/env bash
#
# Harbor 設定產生與 image 拉取。
#
# 用法：
#   ./build.sh
#
# 流程：
#   1. 建立 ./data/ 下所需的各個子目錄
#   2. docker compose pull 拉取所有 service image
#   3. 使用官方 goharbor/prepare image 從 harbor.yml 產生：
#      - 各 service 的設定檔（寫入 ./data/config/<service>/）
#      - 加密金鑰與憑證（寫入 ./data/secret/）
#
# 注意：harbor.yml 修改後，需重新執行本腳本以重生設定。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HARBOR_VERSION="v2.11.0"
# Docker 專屬持久化資料夾（與 K8s 的 k8s/data 各自獨立，不共用）。
readonly DATA_DIR="${SCRIPT_DIR}/data"

cd "${SCRIPT_DIR}"

echo "[build.sh] 建立持久化目錄..."
mkdir -p "${DATA_DIR}/config"
mkdir -p "${DATA_DIR}/database" "${DATA_DIR}/registry" "${DATA_DIR}/redis" "${DATA_DIR}/log" "${DATA_DIR}/job_logs"
mkdir -p "${DATA_DIR}/ca_download" "${DATA_DIR}/psc" "${DATA_DIR}/secret"

echo "[build.sh] 拉取 Harbor ${HARBOR_VERSION} 各 service image..."
docker compose pull

echo "[build.sh] 使用 goharbor/prepare:${HARBOR_VERSION} 從 harbor.yml 產生設定..."
docker run --rm \
  -v "${SCRIPT_DIR}/harbor.yml:/input/harbor.yml" \
  -v "${DATA_DIR}/config:/config" \
  -v "${DATA_DIR}:/data" \
  -v "${DATA_DIR}/secret:/secret" \
  "goharbor/prepare:${HARBOR_VERSION}" \
  prepare --conf /input/harbor.yml

echo ""
echo "[build.sh] 完成。可使用 ../run.sh 啟動 Harbor。"
