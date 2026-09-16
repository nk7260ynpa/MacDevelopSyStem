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
# Harbor 映像釘選：正式版至 v2.15.3-rc1 仍只提供 amd64，本機為 arm64，故改用
# 唯一含 arm64 原生映像的 dev 標籤（v2.16.0 開發版）。dev 是每日建置的浮動標籤，
# 而 manifests 皆為 imagePullPolicy: IfNotPresent，單靠標籤會讓各 service 混到
# 不同天的建置，故逐映像釘上 index digest，鎖定同一批（2026-09-16）建置。
# 換版時到 Docker Hub 取同一天的新 index digest，連同 1[0-6]-*.yaml 一起更新。
readonly HARBOR_TAG="dev"
readonly HARBOR_IMAGE_DIGESTS=(
  "registry-photon=sha256:d61f728a88f94f7aa273bc28115030bac17619f452bfe3da66bb48c7e291e827"
  "harbor-registryctl=sha256:bc1c0cd1b4805ed8283ceb3d61345c23c7313d235fa87feef882cfde4e8ba0a7"
  "harbor-db=sha256:caf122ae29d195e66f5f36ca2e6ca2629d897540000b0324a6bebcc3158afc7e"
  "valkey-photon=sha256:c615eac36282e6005b4b829dfac964f3fa957f49011e0db6d15accbe5b3755bc"
  "harbor-core=sha256:fef1f0825017f6fec9c9420dc0766ed3b7a201843f20e1967be28ca99fdb70a3"
  "harbor-portal=sha256:b0747b89ca2c392dc443d0bb4f95a7e94ce4cb5066003fe559ed0becfb596804"
  "harbor-jobservice=sha256:efde3d5cf76ae551954ae312e940e56ff552fccf8ad06bd215280bc1da4d473f"
  "nginx-photon=sha256:8468bf54523cd6189c2b87c5650105b443e098474c0fb76f4abbcfb4ad395825"
)
readonly PREPARE_IMAGE="goharbor/prepare:${HARBOR_TAG}@sha256:453da3cb34e155d58426f7ce508abd78e5fb574b60885c848a6a403c9bb65e3d"
readonly DATA_DIR="${SCRIPT_DIR}/data"
readonly HARBOR_YML="${SCRIPT_DIR}/../docker/harbor.yml"

cd "${SCRIPT_DIR}"

if [[ ! -f "${HARBOR_YML}" ]]; then
  echo "[build.sh] 錯誤：找不到 ${HARBOR_YML}。" >&2
  exit 1
fi

echo "[build.sh] 建立持久化目錄..."
mkdir -p "${DATA_DIR}/config"
mkdir -p "${DATA_DIR}/database" "${DATA_DIR}/registry" "${DATA_DIR}/redis" "${DATA_DIR}/job_logs"
mkdir -p "${DATA_DIR}/ca_download" "${DATA_DIR}/psc" "${DATA_DIR}/secret"

echo "[build.sh] 拉取 Harbor ${HARBOR_TAG} 各 service image..."
for image_spec in "${HARBOR_IMAGE_DIGESTS[@]}"; do
  image_name="${image_spec%%=*}"
  image_digest="${image_spec#*=}"
  docker pull "goharbor/${image_name}:${HARBOR_TAG}@${image_digest}"
done

echo "[build.sh] 使用 ${PREPARE_IMAGE} 產生設定..."
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
  "${PREPARE_IMAGE}" \
  prepare --conf /input/harbor.yml
rm -rf "${COMPOSE_GEN_DIR}"

# prepare 把 registry 的 token 根憑證產生在 secret/registry/root.crt，而
# 12-registry.yaml 是整個 config/registry 目錄一起掛進 /etc/registry，
# 故須在此複製一份進去，/etc/registry/root.crt 才會存在。
echo "[build.sh] 將 root.crt 佈署至 registry 設定目錄..."
cp -f "${DATA_DIR}/secret/registry/root.crt" "${DATA_DIR}/config/registry/root.crt"

echo ""
echo "[build.sh] 完成。可使用 ./apply.sh 或 ../run.sh 啟動 Harbor。"
