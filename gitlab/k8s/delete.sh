#!/usr/bin/env bash
#
# 移除 GitLab K8s 資源。
#
# 用法：
#   ./delete.sh
#
# 移除 namespace 會連帶刪除其下所有 PVC、Deployment、Service。
# 實際 PV 是否回收取決於 storage class 的 reclaimPolicy（預設多為 Delete）。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[delete.sh] 錯誤：找不到 kubectl，請先安裝。" >&2
  exit 1
fi

echo "[delete.sh] 目前 kubectl context：$(kubectl config current-context)"
echo "[delete.sh] 刪除 namespace gitlab（連同其下所有資源）..."
kubectl delete namespace gitlab --ignore-not-found=true

echo "[delete.sh] 完成。"
