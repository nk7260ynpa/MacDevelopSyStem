#!/usr/bin/env bash
#
# 依序套用 GitLab K8s 資源。
#
# 用法：
#   ./apply.sh
#
# 前置條件：
#   - kubectl 已安裝並指向本機叢集（Docker Desktop K8s / kind / minikube）

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[apply.sh] 錯誤：找不到 kubectl，請先安裝。" >&2
  exit 1
fi

echo "[apply.sh] 目前 kubectl context：$(kubectl config current-context)"

# 建立 K8s 專屬本機持久化資料夾（與 Docker Compose 各自獨立，不共用），並解析絕對路徑。
readonly DATA_DIR="${SCRIPT_DIR}/data"
mkdir -p "${DATA_DIR}"/{config,logs,data}
readonly DATA_ABS="$(cd "${DATA_DIR}" && pwd)"

echo "[apply.sh] 套用 hostPath PV（綁定 ${DATA_ABS}）..."
kubectl apply -f 00-namespace.yaml
sed "s|__GITLAB_DATA__|${DATA_ABS}|g" pv.template.yaml | kubectl apply -f -

for manifest in 01-pvc.yaml 02-deployment.yaml 03-service.yaml; do
  echo "[apply.sh] 套用 ${manifest}..."
  kubectl apply -f "${manifest}"
done

echo ""
echo "[apply.sh] 已套用全部資源。"
echo "  觀察 pod：kubectl -n gitlab get pods -w"
echo "  存取 URL：http://localhost:30080（Docker Desktop K8s）"
echo "  SSH：    ssh -p 30022 git@localhost"
echo "  root 初始密碼（pod Running 且 Ready 後可用）："
echo "    kubectl -n gitlab exec deploy/gitlab -- cat /etc/gitlab/initial_root_password"
