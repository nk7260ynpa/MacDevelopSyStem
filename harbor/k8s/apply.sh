#!/usr/bin/env bash
#
# 依序套用 Harbor K8s 資源。
#
# 用法：
#   ./apply.sh
#
# 流程：
#   1. 建立 Namespace、PVC、Secret、RBAC
#   2. 執行 prepare Job：用 goharbor/prepare 從 harbor.yml 產生各 service 設定
#      與加密金鑰到 harbor-config PVC
#   3. 執行 init-configmaps Job：將 prepare 產出的 env 檔轉為 K8s Secret
#   4. 依相依順序套用所有 service Deployment

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[apply.sh] 錯誤：找不到 kubectl，請先安裝。" >&2
  exit 1
fi

echo "[apply.sh] 目前 kubectl context：$(kubectl config current-context)"

# 建立本機持久化資料夾（與 Docker Compose 共用同一份），並解析絕對路徑。
readonly DATA_DIR="${SCRIPT_DIR}/../harbor_data"
mkdir -p "${DATA_DIR}"/{config,database,registry,redis,log,job_logs,ca_download,psc,secret}
readonly DATA_ABS="$(cd "${DATA_DIR}" && pwd)"

echo "[apply.sh] 階段 1：建立 namespace / PV / PVC / Secret / RBAC..."
kubectl apply -f 00-namespace.yaml
echo "  套用 hostPath PV（綁定 ${DATA_ABS}）..."
sed "s|__HARBOR_DATA__|${DATA_ABS}|g" pv.template.yaml | kubectl apply -f -
kubectl apply -f 01-pvc.yaml -f 02-secret.yaml -f 04-rbac.yaml

echo "[apply.sh] 階段 2：執行 prepare Job（產生各 service 設定）..."
kubectl apply -f 03-prepare-job.yaml
echo "  等待 harbor-prepare 完成（最多 5 分鐘）..."
kubectl -n harbor wait --for=condition=complete --timeout=300s job/harbor-prepare

echo "[apply.sh] 階段 3：執行 init-configmaps Job（env 檔轉 Secret）..."
kubectl apply -f 05-init-configmaps-job.yaml
echo "  等待 harbor-init-configmaps 完成（最多 3 分鐘）..."
kubectl -n harbor wait --for=condition=complete --timeout=180s job/harbor-init-configmaps

echo "[apply.sh] 階段 4：依序部署 8 個 service..."
for f in 17-log.yaml \
         10-redis.yaml 11-database.yaml \
         12-registry.yaml \
         13-core.yaml \
         14-jobservice.yaml 15-portal.yaml \
         16-proxy.yaml; do
  kubectl apply -f "$f"
done

echo ""
echo "[apply.sh] 已套用全部資源。"
echo "  觀察 pod：kubectl -n harbor get pods -w"
echo "  存取 URL：http://localhost:30081（Docker Desktop K8s）"
echo "  預設帳號：admin / Harbor12345（首次登入後請立即修改）"
