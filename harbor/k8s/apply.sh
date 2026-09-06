#!/usr/bin/env bash
#
# 依序套用 Harbor 的 K8s 資源。
#
# 用法：
#   ./apply.sh
#
# 前置條件：
#   - kubectl 已安裝並指向本機叢集
#   - Docker Desktop 的 Kubernetes 需為 Kubeadm 佈建方式（見 check_hostpath_support）
#   - Docker Compose 版的 Harbor 已停止（兩者搶同一個 port）
#   - ./data/config 已就緒——沿用既有資料請先 ./migrate.sh，全新建立請先 ./build.sh
#
# 流程：
#   1. namespace / PV / PVC
#   2. 把 prepare 產生的 env 檔轉成 Secret（Deployment 以 envFrom 取用）
#   3. 依相依順序套用 8 個 service

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
  if docker inspect desktop-control-plane >/dev/null 2>&1; then
    echo "[apply.sh] 錯誤：叢集為 kind 佈建方式，節點看不到 macOS 目錄。" >&2
    echo "  請到 Docker Desktop > Settings > Kubernetes，把 Cluster provisioning" >&2
    echo "  method 改為 Kubeadm 後 Apply & Restart，再重新執行本腳本。" >&2
    return 1
  fi
  return 0
}

#######################################
# 確認對外 port 未被其他程式佔用。
#
# K8s 的 Service 走 LoadBalancer 綁 localhost:8081，與 Compose 版相同。
# port 若已被佔，LoadBalancer 會靜默地停在 <pending> 永遠拿不到位址
# ——沒有錯誤訊息，只是連不上，故在此先擋下來。
#
# 以實際佔埠情形判斷而非只看容器名，確認是 Compose 版佔的話另外給明確指令。
# 注意 Compose 版 proxy 的 container_name 是 nginx，不是 proxy。
# Globals:
#   NAMESPACE
# Arguments:
#   無
# Outputs:
#   偵測到衝突時輸出錯誤訊息並回傳 1
#######################################
check_port_conflict() {
  # 自己已經部署過就跳過：重複執行 apply.sh 是冪等操作，此時 8081 本來就被
  # 自己的 LoadBalancer 佔著，不該把它判成衝突。
  if kubectl -n "${NAMESPACE}" get service harbor >/dev/null 2>&1; then
    return 0
  fi

  if ! lsof -nP -iTCP:8081 -sTCP:LISTEN >/dev/null 2>&1; then
    return 0
  fi

  echo "[apply.sh] 錯誤：port 8081 已被佔用，LoadBalancer 會拿不到位址。" >&2
  local running
  running="$(docker ps --filter 'name=^nginx$' --filter 'status=running' --quiet 2>/dev/null || true)"
  if [[ -n "${running}" ]]; then
    echo "  佔用者是 Docker Compose 版的 Harbor，請先執行：../run.sh docker stop" >&2
  else
    echo "  請以下列指令找出佔用者後自行處理：" >&2
    echo "    lsof -nP -iTCP:8081 -sTCP:LISTEN" >&2
  fi
  return 1
}

#######################################
# 把 prepare 產生的 env 檔轉成 K8s Secret。
#
# Compose 用 env_file 直接讀檔，K8s 沒有對應機制，必須先轉成 Secret 再以
# envFrom 注入。轉換在 macOS 這一側做（apply.sh 本來就看得到這些檔案），
# 不需要在叢集內另外跑 Job，也就省掉 ServiceAccount 與 RBAC。
#
# --dry-run=client + kubectl apply 讓這個動作是冪等的：重複執行只會更新內容。
# Globals:
#   DATA_DIR, NAMESPACE
# Arguments:
#   無
# Outputs:
#   每個 Secret 的建立訊息
#######################################
create_env_secrets() {
  local svc env_path
  for svc in core jobservice registryctl db; do
    env_path="${DATA_DIR}/config/${svc}/env"
    if [[ ! -f "${env_path}" ]]; then
      echo "[apply.sh] 錯誤：找不到 ${env_path}，設定尚未產生。" >&2
      return 1
    fi
    echo "  harbor-env-${svc}"
    kubectl -n "${NAMESPACE}" create secret generic "harbor-env-${svc}" \
      --from-env-file="${env_path}" \
      --dry-run=client -o yaml |
      kubectl label --local -f - \
        app.kubernetes.io/name=harbor \
        app.kubernetes.io/part-of=macdevelopsystem \
        -o yaml |
      kubectl apply -f -
  done
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[apply.sh] 錯誤：找不到 kubectl，請先安裝。" >&2
  exit 1
fi

# check_port_conflict 靠 lsof 判斷佔埠情形。找不到它就等於那道檢查整個失效，
# 而失效的方向是「放行」——會一路跑到 LoadBalancer 靜默停在 <pending>，
# 沒有任何錯誤訊息可循。寧可在這裡就停下來。
if ! command -v lsof >/dev/null 2>&1; then
  echo "[apply.sh] 錯誤：找不到 lsof，無法檢查 port 是否被佔用。" >&2
  exit 1
fi

# 檢查設定與金鑰是否齊備。金鑰特別重要：kubelet 對 hostPath 的 subPath 在來源
# 不存在時會「建出一個目錄」，core 於是拿到目錄而非檔案，錯誤訊息完全對應不到
# 真正的原因（rsync 中斷、只搬了一半）。在這裡擋下來省掉大量除錯時間。
for required in config/core config/nginx config/registry \
                secret/keys/secretkey secret/core/private_key.pem; do
  if [[ ! -e "${DATA_DIR}/${required}" ]]; then
    echo "[apply.sh] 偵測不到 data/${required}，設定或金鑰不完整。請先擇一執行：" >&2
    echo "  ./migrate.sh   # 沿用 Docker Compose 版的既有資料" >&2
    echo "  ./build.sh     # 全新建立（以 harbor.yml 產生設定）" >&2
    exit 1
  fi
done

echo "[apply.sh] 目前 kubectl context：$(kubectl config current-context)"
check_hostpath_support
check_port_conflict

echo "[apply.sh] 建立持久化目錄..."
mkdir -p "${DATA_DIR}"/{config,database,registry,redis,job_logs,ca_download,psc,secret}

echo "[apply.sh] 階段 1：套用 namespace / PV / PVC..."
kubectl apply -f 00-namespace.yaml
# PV 的 hostPath 必須是絕對路徑，且不寫死在版控檔內，故以佔位符 + sed 產生。
sed "s|__HARBOR_DATA__|${DATA_DIR}|g" 01-pv.template.yaml | kubectl apply -f -
kubectl apply -f 02-pvc.yaml

echo "[apply.sh] 階段 2：將 env 檔轉為 Secret..."
create_env_secrets

# 依相依順序套用：資料層先起來，core 才連得上；proxy 最後，它依賴 core 與 portal。
# K8s 本身沒有 depends_on，這個順序只是縮短彼此等待的時間——各 service 的探針
# 會處理實際的就緒判定，順序錯了也只是多幾輪重試而已。
echo "[apply.sh] 階段 3：依序部署 8 個 service..."
for manifest in 10-redis.yaml 11-postgresql.yaml \
                12-registry.yaml \
                13-core.yaml \
                14-jobservice.yaml 15-portal.yaml \
                16-proxy.yaml; do
  echo "  ${manifest}"
  kubectl apply -f "${manifest}"
done

echo ""
echo "[apply.sh] 已套用全部資源（首次啟動需 1-2 分鐘完成初始化）。"
echo "  觀察 pod：kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=harbor -w"
echo "  存取 URL：http://localhost:8081"
echo "  預設帳號：admin / Harbor12345（沿用既有資料時為你原本設定的密碼）"
