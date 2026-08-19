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

#######################################
# 清除前次執行殘留的 unix socket 與修正 git-data 權限。
#
# macOS 的 virtiofs bind mount 有兩項限制，會讓 GitLab 在「非正常關閉」後
# 無法再啟動（開機自動啟動時最常見）：
#   1. 無法 unlink 既有的 socket 檔，Redis/Gitaly/Workhorse 啟動時
#      因刪不掉舊 socket 而失敗（Operation not supported）。
#   2. 無法保留 setgid 位元，reconfigure 檢查 repositories 需為 2770 會失敗。
# 啟動前先行清理與補正，可避免容器陷入無限重啟。
# Globals:
#   DOCKER_DIR
# Arguments:
#   無
# Outputs:
#   清理項目訊息
#######################################
clean_stale_state() {
  local data_dir="${DOCKER_DIR}/data/data"
  [[ -d "${data_dir}" ]] || return 0

  local stale_count
  stale_count="$(find "${data_dir}" -type s 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${stale_count}" -gt 0 ]]; then
    echo "[run.sh] 清除 ${stale_count} 個前次殘留的 unix socket..."
    find "${data_dir}" -type s -delete 2>/dev/null || true
  fi

  # git-data/repositories 需帶 setgid（2770），否則 reconfigure 會中止。
  local repo_dir="${data_dir}/git-data/repositories"
  if [[ -d "${repo_dir}" ]]; then
    local mode
    mode="$(stat -f '%Lp' "${repo_dir}" 2>/dev/null || echo '')"
    if [[ "${mode}" != "2770" ]]; then
      echo "[run.sh] 修正 repositories 權限（${mode:-未知} -> 2770）..."
      chmod 2770 "${repo_dir}" || true
    fi
  fi
}

cd "${DOCKER_DIR}"

action="${1:-up}"

case "${action}" in
  up|"")
    clean_stale_state
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
