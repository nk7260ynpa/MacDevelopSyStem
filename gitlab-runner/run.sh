#!/usr/bin/env bash
#######################################
# GitLab Runner Docker Compose 啟動入口
# 提供 register / up / logs / stop / status 等子命令，
# 統一管理 GitLab Runner 容器的註冊與生命週期。
# Globals:
#   無
# Arguments:
#   子命令：up（預設）、register、logs、stop、status
# Outputs:
#   對應 docker compose 操作之結果
#######################################
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOCKER_DIR="${SCRIPT_DIR}/docker"

cd "${DOCKER_DIR}"

action="${1:-up}"

case "${action}" in
  up|"")
    if [[ ! -f data/config.toml ]]; then
      echo "[run.sh] 尚未註冊 Runner（找不到 data/config.toml）。" >&2
      echo "         請先執行：./run.sh register" >&2
      exit 1
    fi
    echo "[run.sh] 啟動 GitLab Runner..."
    docker compose up -d
    echo ""
    echo "[run.sh] 已啟動。"
    echo "  查看狀態：./run.sh status"
    echo "  跟隨 log：./run.sh logs"
    ;;
  register)
    if [[ ! -f .env ]]; then
      echo "[run.sh] 找不到 docker/.env，請先複製範本並填入權杖：" >&2
      echo "  cp docker/.env.example docker/.env" >&2
      exit 1
    fi
    # 載入 .env（CI_SERVER_URL / RUNNER_TOKEN / RUNNER_DOCKER_IMAGE / RUNNER_DESCRIPTION）
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
    if [[ -z "${RUNNER_TOKEN:-}" || "${RUNNER_TOKEN}" == "glrt-REPLACE_ME" ]]; then
      echo "[run.sh] 請在 docker/.env 設定有效的 RUNNER_TOKEN（glrt- 開頭）。" >&2
      echo "         於 GitLab UI 建立 Runner 後取得，詳見 README「GitLab Runner 部署」。" >&2
      exit 1
    fi
    local_url="${CI_SERVER_URL:-http://host.docker.internal:8080}"
    echo "[run.sh] 註冊 Runner 至 ${local_url} ..."
    # 以 docker executor 註冊（GitLab 17 認證權杖流程）；
    # config.toml 寫入容器內 /etc/gitlab-runner（bind mount 至 docker/data）。
    docker compose run --rm gitlab-runner register \
      --non-interactive \
      --url "${local_url}" \
      --token "${RUNNER_TOKEN}" \
      --executor docker \
      --docker-image "${RUNNER_DOCKER_IMAGE:-alpine:latest}" \
      --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
      --docker-extra-hosts "host.docker.internal:host-gateway" \
      --clone-url "${local_url}" \
      --description "${RUNNER_DESCRIPTION:-mac-local-docker-runner}"
    echo ""
    echo "[run.sh] 註冊完成（設定寫入 docker/data/config.toml）。"
    echo "         接著執行：./run.sh up"
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
    echo "用法：$0 {register|up|logs|stop|status}" >&2
    exit 1
    ;;
esac
