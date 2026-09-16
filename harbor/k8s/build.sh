#!/usr/bin/env bash
#
# 為 K8s 方案產生 Harbor 各 service 的設定（首次建立或升級映像時使用）。
#
# 用法：
#   ./build.sh
#
# 流程：
#   1. 建立 ./data/ 下所需的各個子目錄
#   2. 拉取 K8s manifests 用到的所有 image
#   3. 使用官方 goharbor/prepare image 從 ../docker/harbor.yml 產生：
#      - 各 service 的設定檔（寫入 ./data/config/<service>/）
#      - 加密金鑰與憑證（寫入 ./data/secret/）
#
# 沿用 Docker Compose 版既有資料（首次從 Compose 搬到 K8s）的話**不需要**執行
# 本腳本，改跑 ./migrate.sh。
#
# 反之，沿用本方案既有的 ./data/ 時（例如只升級映像版本）可直接執行本腳本：
# prepare 偵測到 ./data/secret/ 已有金鑰便原樣保留，只重生 ./data/config/ 下的
# 設定檔，既有的帳號、robot 權杖與資料庫內容因而仍解得開；只有在 ./data/secret/
# 不存在時才會產生全新的加密金鑰。升級流程正是靠這點把資料與帳號帶到新版本。
#
# 設定來源刻意共用 ../docker/harbor.yml：hostname、http.port 與 external_url
# 在兩套方案下完全相同（對外都是 localhost:8081），沒有任何需要分岔的欄位，
# 共用同一份才不會重蹈兩套設定長期不同步的覆轍。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DATA_DIR="${SCRIPT_DIR}/data"
readonly HARBOR_YML="${SCRIPT_DIR}/../docker/harbor.yml"
readonly VERSIONS_ENV="${SCRIPT_DIR}/../versions.env"

#######################################
# 載入映像版本設定（../versions.env）。
#
# 該檔是 9 個映像（8 個 service 加 prepare）digest 的唯一來源，K8s 與 Compose
# 兩套方案共用；換版只改那一個檔，本腳本與 apply.sh 都跟著走。
# Globals:
#   VERSIONS_ENV
# Arguments:
#   無
# Outputs:
#   檔案不存在時輸出錯誤訊息並回傳 1
#######################################
load_versions() {
  if [[ ! -f "${VERSIONS_ENV}" ]]; then
    echo "[build.sh] 錯誤：找不到 ${VERSIONS_ENV}，取不到映像版本。" >&2
    return 1
  fi
  # shellcheck source=../versions.env disable=SC1091
  source "${VERSIONS_ENV}"
}

cd "${SCRIPT_DIR}"

load_versions

if [[ ! -f "${HARBOR_YML}" ]]; then
  echo "[build.sh] 錯誤：找不到 ${HARBOR_YML}。" >&2
  exit 1
fi

echo "[build.sh] 建立持久化目錄..."
mkdir -p "${DATA_DIR}/config"
mkdir -p "${DATA_DIR}/database" "${DATA_DIR}/registry" "${DATA_DIR}/redis" "${DATA_DIR}/job_logs"
mkdir -p "${DATA_DIR}/ca_download" "${DATA_DIR}/psc" "${DATA_DIR}/secret"

echo "[build.sh] 拉取 Harbor 各 service image（版本見 ../versions.env）..."
# 逐行讀 versions.env，值本身就是完整的映像字串（repo、tag 與 index digest）；
# 連 prepare 共 9 個映像一次拉齊。
while IFS='=' read -r key value; do
  # 只取 KEY=VALUE，跳過空行與 # 註解。
  if [[ -z "${key}" || "${key}" == \#* ]]; then
    continue
  fi
  docker pull "${value}"
done < "${VERSIONS_ENV}"

echo "[build.sh] 使用 ${HARBOR_IMAGE_PREPARE} 產生設定..."
# prepare 最後會額外產生它自己版本的 docker-compose.yml 至 /compose_location；
# 本方案不使用該檔，故掛一個拋棄式目錄承接並忽略，
# 否則 prepare 會因找不到 /compose_location 而以例外中止（即使所需設定皆已產生）。
readonly COMPOSE_GEN_DIR="${DATA_DIR}/.compose_gen"
mkdir -p "${COMPOSE_GEN_DIR}"
docker run --rm \
  -v "${HARBOR_YML}:/input/harbor.yml" \
  -v "${DATA_DIR}/config:/config" \
  -v "${DATA_DIR}:/data" \
  -v "${DATA_DIR}/secret:/secret" \
  -v "${COMPOSE_GEN_DIR}:/compose_location" \
  "${HARBOR_IMAGE_PREPARE}" \
  prepare --conf /input/harbor.yml
rm -rf "${COMPOSE_GEN_DIR}"

# prepare 把 registry 的 token 根憑證產生在 secret/registry/root.crt，而
# 12-registry.template.yaml 是整個 config/registry 目錄一起掛進 /etc/registry，
# 故須在此複製一份進去，/etc/registry/root.crt 才會存在。
echo "[build.sh] 將 root.crt 佈署至 registry 設定目錄..."
cp -f "${DATA_DIR}/secret/registry/root.crt" "${DATA_DIR}/config/registry/root.crt"

echo ""
echo "[build.sh] 完成。可使用 ./apply.sh 或 ../run.sh 啟動 Harbor。"
