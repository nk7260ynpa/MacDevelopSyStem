#!/usr/bin/env bash
#
# 依序套用 GitLab 的 K8s 資源。
#
# 用法：
#   ./apply.sh
#
# 前置條件：
#   - kubectl 已安裝並指向本機叢集
#   - Docker Desktop 的 Kubernetes 需為 Kubeadm 佈建方式（見下方 check_hostpath_support）
#   - Docker Compose 版的 GitLab 已停止（兩者搶同一組 port）
#
# 資料來源為 ./data，若要沿用 Docker Compose 版既有的資料，請先執行 ./migrate.sh。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

readonly DATA_DIR="${SCRIPT_DIR}/data"
readonly NAMESPACE="devops"

#######################################
# 確認叢集節點看得到 macOS 的目錄。
#
# Docker Desktop 的 Kubernetes 有兩種佈建方式，只有 Kubeadm 可用：
#   - Kubeadm：節點就是 Docker Desktop VM，VM 透過 virtiofs 掛有 /Users，
#     hostPath 指向 macOS 路徑可直接生效。
#   - kind   ：節點是 docker 容器，容器內根本沒有 /Users，hostPath 會靜默地
#     建出一個空目錄，服務照樣起得來但讀不到任何既有資料——這種失敗很難察覺，
#     故在此明確擋下。
# Globals:
#   無
# Arguments:
#   無
# Outputs:
#   偵測結果；判定為 kind 時輸出錯誤訊息並回傳 1
#######################################
check_hostpath_support() {
  # kind 佈建方式下，節點會以 docker 容器的形式存在（名稱為 desktop-control-plane
  # 或 *-worker）。Kubeadm 佈建方式下查不到這些容器。
  if docker inspect desktop-control-plane >/dev/null 2>&1; then
    echo "[apply.sh] 錯誤：叢集為 kind 佈建方式，節點看不到 macOS 目錄。" >&2
    echo "  請到 Docker Desktop > Settings > Kubernetes，把 Cluster provisioning" >&2
    echo "  method 改為 Kubeadm 後 Apply & Restart，再重新執行本腳本。" >&2
    return 1
  fi
  return 0
}

#######################################
# 確認對外 port 未被 Docker Compose 版佔用。
#
# K8s 的 Service 走 LoadBalancer 綁 localhost:8080 與 localhost:2222，與 Compose
# 版完全相同。Compose 版若還在跑，LoadBalancer 會因 port 被佔而永遠拿不到位址。
# Globals:
#   無
# Arguments:
#   無
# Outputs:
#   偵測到衝突時輸出錯誤訊息並回傳 1
#######################################
check_port_conflict() {
  local running
  running="$(docker ps --filter 'name=^gitlab$' --filter 'status=running' --quiet 2>/dev/null || true)"
  if [[ -n "${running}" ]]; then
    echo "[apply.sh] 錯誤：Docker Compose 版的 GitLab 仍在運行，會搶走 8080／2222。" >&2
    echo "  請先執行：../run.sh docker stop" >&2
    return 1
  fi
  return 0
}

#######################################
# 修正 macOS 端的持久化資料狀態。
#
# 必須在 macOS 這一側做，不能交給容器內的 initContainer：
#   1. socket 殘留——virtiofs 不支援 unlink 既有的 socket 檔，容器內刪不掉。
#      Deployment 已把所有 socket 移到 emptyDir，掛載區理論上不再產生 socket，
#      此處保留為防呆：清掉搬移前留下的孤兒檔，以及設定被回滾時的兜底。
#   2. git-data/repositories 需帶 setgid（2770），否則 reconfigure 會中止。
#      virtiofs 不保留 setgid 位元，只有在 macOS 檔案系統上 chmod 才有效。
# Globals:
#   DATA_DIR
# Arguments:
#   無
# Outputs:
#   清理與修正項目訊息
#######################################
clean_stale_state() {
  local data_dir="${DATA_DIR}/data"
  [[ -d "${data_dir}" ]] || return 0

  local stale_count
  stale_count="$(find "${data_dir}" -type s 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${stale_count}" -gt 0 ]]; then
    echo "[apply.sh] 清除 ${stale_count} 個前次殘留的 unix socket..."
    find "${data_dir}" -type s -delete 2>/dev/null || true
  fi

  local repo_dir="${data_dir}/git-data/repositories"
  if [[ -d "${repo_dir}" ]]; then
    local mode
    mode="$(stat -f '%Lp' "${repo_dir}" 2>/dev/null || echo '')"
    if [[ "${mode}" != "2770" ]]; then
      echo "[apply.sh] 修正 repositories 權限（${mode:-未知} -> 2770）..."
      chmod 2770 "${repo_dir}" || true
    fi
  fi
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[apply.sh] 錯誤：找不到 kubectl，請先安裝。" >&2
  exit 1
fi

echo "[apply.sh] 目前 kubectl context：$(kubectl config current-context)"
check_hostpath_support
check_port_conflict

echo "[apply.sh] 建立持久化目錄..."
mkdir -p "${DATA_DIR}"/{config,logs,data}

clean_stale_state

echo "[apply.sh] 套用 namespace..."
kubectl apply -f 00-namespace.yaml

# PV 的 hostPath 必須是絕對路徑，且不寫死在版控檔內，故以佔位符 + sed 產生。
echo "[apply.sh] 套用 hostPath PV（綁定 ${DATA_DIR}）..."
sed "s|__GITLAB_DATA__|${DATA_DIR}|g" 01-pv.template.yaml | kubectl apply -f -

for manifest in 02-pvc.yaml 03-deployment.yaml 04-service.yaml; do
  echo "[apply.sh] 套用 ${manifest}..."
  kubectl apply -f "${manifest}"
done

echo ""
echo "[apply.sh] 已套用全部資源（首次啟動需 3-5 分鐘完成初始化）。"
echo "  觀察 pod：kubectl -n ${NAMESPACE} get pods -w"
echo "  存取 URL：http://localhost:8080"
echo "  SSH：    ssh -p 2222 git@localhost"
echo "  root 初始密碼（pod Ready 後可用，沿用既有資料時此檔可能已不存在）："
echo "    kubectl -n ${NAMESPACE} exec deploy/gitlab -- cat /etc/gitlab/initial_root_password"
