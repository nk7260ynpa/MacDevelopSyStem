#!/usr/bin/env bash
#
# 移除 GitLab 的 K8s 資源。
#
# 用法：
#   ./delete.sh
#
# 只移除 GitLab 自己的資源，./data 內的實際資料一律保留（PV 的 reclaimPolicy
# 為 Retain），重新 ./apply.sh 即可接續使用。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

readonly NAMESPACE="devops"
readonly SELECTOR="app.kubernetes.io/name=gitlab"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[delete.sh] 錯誤：找不到 kubectl，請先安裝。" >&2
  exit 1
fi

echo "[delete.sh] 目前 kubectl context：$(kubectl config current-context)"

# 絕對不可以用 `kubectl delete namespace devops`——該 namespace 是與 Harbor 共用的，
# 刪掉會把 Harbor 一起殺掉。一律以 label selector 精確指定自己的資源。
echo "[delete.sh] 移除 namespace ${NAMESPACE} 內標記為 ${SELECTOR} 的資源..."
kubectl -n "${NAMESPACE}" delete deployment,service,persistentvolumeclaim \
  -l "${SELECTOR}" --ignore-not-found=true

# PV 是叢集層級資源，不隨 namespace 內的物件一起刪除，需另外移除。
# reclaimPolicy 為 Retain，刪除 PV 物件不會清掉 ./data 內的實際資料。
echo "[delete.sh] 移除 hostPath PV（./data 內資料保留）..."
kubectl delete persistentvolume -l "${SELECTOR}" --ignore-not-found=true

echo "[delete.sh] 完成。namespace ${NAMESPACE} 本身保留（Harbor 仍在使用）。"
