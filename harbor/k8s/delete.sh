#!/usr/bin/env bash
#
# 移除 Harbor K8s 資源。
#
# 用法：
#   ./delete.sh
#
# 刪除 namespace 會連帶刪除其下所有 PVC、Secret、Job、Deployment、Service。
# hostPath 靜態 PV 為叢集層級資源，不隨 namespace 刪除，需另外移除；
# 其 reclaimPolicy=Retain，刪除 PV 物件不會清除本機 k8s/data 內的實際資料。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[delete.sh] 錯誤：找不到 kubectl，請先安裝。" >&2
  exit 1
fi

echo "[delete.sh] 目前 kubectl context：$(kubectl config current-context)"
echo "[delete.sh] 刪除 namespace harbor（連同其下所有資源）..."
kubectl delete namespace harbor --ignore-not-found=true

echo "[delete.sh] 刪除 hostPath PV（本機 k8s/data 資料保留）..."
kubectl delete pv harbor-config-pv harbor-database-pv harbor-registry-pv \
  harbor-jobservice-pv harbor-redis-pv --ignore-not-found=true

echo "[delete.sh] 完成。"
