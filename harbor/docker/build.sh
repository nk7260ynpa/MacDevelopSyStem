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
# prepare 最後會額外產生它自己版本的 docker-compose.yml 至 /compose_location；
# 本專案改用手寫的 docker-compose.yaml，故掛一個拋棄式目錄承接該檔並忽略，
# 否則 prepare 會因找不到 /compose_location 而以例外中止（即使所需設定皆已產生）。
readonly COMPOSE_GEN_DIR="${DATA_DIR}/.compose_gen"
mkdir -p "${COMPOSE_GEN_DIR}"
docker run --rm \
  -v "${SCRIPT_DIR}/harbor.yml:/input/harbor.yml" \
  -v "${DATA_DIR}/config:/config" \
  -v "${DATA_DIR}:/data" \
  -v "${DATA_DIR}/secret:/secret" \
  -v "${COMPOSE_GEN_DIR}:/compose_location" \
  "goharbor/prepare:${HARBOR_VERSION}" \
  prepare --conf /input/harbor.yml
# 拋棄 prepare 產生的 compose 檔，避免與手寫 docker-compose.yaml 混淆。
rm -rf "${COMPOSE_GEN_DIR}"

# prepare 會把 registry 的 token 根憑證產生在 secret/registry/root.crt。
# 為避開 Docker Desktop（macOS virtiofs）「於目錄掛載上再疊單檔掛載」的衝突，
# docker-compose.yaml 不再單獨疊掛 root.crt，而是改由 registry 設定目錄一併帶入，
# 故在此把 root.crt 複製進 data/config/registry/，使 /etc/registry/root.crt 可用。
echo "[build.sh] 將 root.crt 佈署至 registry 設定目錄..."
cp -f "${DATA_DIR}/secret/registry/root.crt" "${DATA_DIR}/config/registry/root.crt"

echo ""
echo "[build.sh] 完成。可使用 ../run.sh 啟動 Harbor。"
