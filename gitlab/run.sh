#!/usr/bin/env bash
#
# GitLab 啟動入口。
#
# 用法：
#   ./run.sh           # 啟動（背景模式）
#   ./run.sh logs      # 跟隨 container log
#   ./run.sh stop      # 停止 GitLab
#   ./run.sh status    # 查看狀態
#
# 採用 Docker Compose 方案；K8s 方案請改用 ./k8s/apply.sh。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOCKER_DIR="${SCRIPT_DIR}/docker"

# Docker 專屬持久化資料夾（與 K8s 的 k8s/data 各自獨立，不共用）。
mkdir -p "${DOCKER_DIR}/data"/{config,logs,data}

cd "${DOCKER_DIR}"

action="${1:-up}"

case "${action}" in
  up|"")
    echo "[run.sh] 啟動 GitLab（首次啟動需 3-5 分鐘完成初始化）..."
    docker compose up -d
    echo ""
    echo "[run.sh] 已啟動。"
    echo "  存取 URL：http://localhost:8080"
    echo "  SSH：    ssh -p 2222 git@localhost"
    echo "  root 初始密碼："
    echo "    docker exec gitlab cat /etc/gitlab/initial_root_password"
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
