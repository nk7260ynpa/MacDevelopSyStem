#!/usr/bin/env bash
#
# Harbor 啟動入口。
#
# 用法：
#   ./run.sh           # 啟動（背景模式）
#   ./run.sh logs      # 跟隨所有 service log
#   ./run.sh stop      # 停止 Harbor
#   ./run.sh status    # 查看狀態
#
# 採用 Docker Compose 方案；K8s 方案請改用 ./k8s/apply.sh。
# 首次執行前必須先跑 ./docker/build.sh 以拉取 image 並產生各 service 設定。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOCKER_DIR="${SCRIPT_DIR}/docker"

cd "${DOCKER_DIR}"

action="${1:-up}"

case "${action}" in
  up|"")
    if [[ ! -d data/config/core ]]; then
      echo "[run.sh] 偵測不到 data/config，請先執行：" >&2
      echo "  cd docker && ./build.sh" >&2
      exit 1
    fi
    echo "[run.sh] 啟動 Harbor（首次啟動需 1-2 分鐘完成初始化）..."
    docker compose up -d
    echo ""
    echo "[run.sh] 已啟動。"
    echo "  存取 URL：http://localhost:8081"
    echo "  預設帳號：admin / Harbor12345"
    echo "  ※ 首次登入後請立即修改密碼。"
    echo "  跟隨 log：./run.sh logs"
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
    echo "用法：$0 {up|logs|stop|status}" >&2
    exit 1
    ;;
esac
