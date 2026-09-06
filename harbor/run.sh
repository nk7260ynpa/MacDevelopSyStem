#!/usr/bin/env bash
#
# Harbor 啟動入口。
#
# 用法：
#   ./run.sh              # 啟動（Kubernetes，預設方案）
#   ./run.sh logs         # 跟隨所有 pod 的 log
#   ./run.sh stop         # 移除 K8s 資源（k8s/data 內的資料保留）
#   ./run.sh status       # 查看 pod 狀態
#   ./run.sh docker       # 改以 Docker Compose 啟動（備用方案）
#   ./run.sh docker logs  # Docker Compose 的 log，stop／status 同理
#
# 預設方案為 Kubernetes，設定位於 ./k8s/：Deployment 的 controller 會在 pod
# 掛掉時自動重建，補上 restart: always 只看主行程存活的不足。
# Docker Compose 方案保留於 ./docker/ 作為備用，兩者資料各自獨立。
#
# 兩套方案搶同一個 port（8081），同一時間只能啟動其中一套。
#
# 首次執行前必須先產生各 service 設定：K8s 走 ./k8s/migrate.sh（沿用既有資料）
# 或 ./k8s/build.sh（全新建立）；Docker Compose 走 ./docker/build.sh。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOCKER_DIR="${SCRIPT_DIR}/docker"
readonly K8S_DIR="${SCRIPT_DIR}/k8s"

#######################################
# 以 Docker Compose 方案執行指定動作（備用方案）。
# Globals:
#   DOCKER_DIR
# Arguments:
#   動作名稱：up／logs／stop／status
# Outputs:
#   各動作的執行結果；未知動作輸出用法並回傳 1
#######################################
run_docker() {
  local action="$1"

  cd "${DOCKER_DIR}"

  case "${action}" in
    up|"")
      if [[ ! -d data/config/core ]]; then
        echo "[run.sh] 偵測不到 data/config，請先執行：" >&2
        echo "  cd docker && ./build.sh" >&2
        return 1
      fi
      echo "[run.sh] 以 Docker Compose 啟動 Harbor（首次啟動需 1-2 分鐘完成初始化）..."
      docker compose up -d
      echo ""
      echo "[run.sh] 已啟動。"
      echo "  存取 URL：http://localhost:8081"
      echo "  預設帳號：admin / Harbor12345"
      echo "  ※ 首次登入後請立即修改密碼。"
      echo "  跟隨 log：./run.sh docker logs"
      ;;
    logs)
      docker compose logs -f
      ;;
    stop|down)
      docker compose down
      ;;
    status|ps)
      docker compose ps
      ;;
    *)
      echo "用法：$0 docker {up|logs|stop|status}" >&2
      return 1
      ;;
  esac
}

#######################################
# 以 Kubernetes 方案執行指定動作（預設方案）。
#
# up 與 stop 委由 k8s/apply.sh 與 k8s/delete.sh 處理——前置檢查（佈建方式、
# port 衝突、設定是否就緒）都寫在那裡，這裡只負責轉發。
# Globals:
#   K8S_DIR
# Arguments:
#   動作名稱：up／logs／stop／status
# Outputs:
#   各動作的執行結果；未知動作輸出用法並回傳 1
#######################################
run_k8s() {
  local action="$1"
  local namespace="devops"
  local selector="app.kubernetes.io/name=harbor"

  case "${action}" in
    up|"")
      "${K8S_DIR}/apply.sh"
      ;;
    logs)
      # Harbor 是多 service 架構，--prefix 讓輸出標明來自哪一個 pod。
      kubectl -n "${namespace}" logs -f -l "${selector}" --prefix --tail=50 --max-log-requests=10
      ;;
    stop|down)
      "${K8S_DIR}/delete.sh"
      ;;
    status|ps)
      kubectl -n "${namespace}" get pods,svc,pvc -l "${selector}"
      ;;
    *)
      echo "用法：$0 [docker|k8s] {up|logs|stop|status}" >&2
      return 1
      ;;
  esac
}

# 第一個參數若是方案名就當方案用並移除，否則沿用預設的 k8s。
# 這樣既有的 `./run.sh logs`／`./run.sh stop` 等用法不必改寫，只是改為作用在
# K8s 上；要操作 Docker Compose 版就明確寫成 `./run.sh docker logs`。
mode="k8s"
case "${1:-}" in
  docker|k8s)
    mode="$1"
    shift
    ;;
esac

action="${1:-up}"

case "${mode}" in
  k8s)
    run_k8s "${action}"
    ;;
  docker)
    run_docker "${action}"
    ;;
esac
