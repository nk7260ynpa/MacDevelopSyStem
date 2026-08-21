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
# 採用 Docker Compose 方案，設定位於 ./docker/。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOCKER_DIR="${SCRIPT_DIR}/docker"

# 持久化資料夾，以 bind mount 掛入容器。
mkdir -p "${DOCKER_DIR}/data"/{config,logs,data}

#######################################
# 清除前次執行殘留的 unix socket 與修正 git-data 權限。
#
# macOS 的 virtiofs bind mount 有三項限制，會讓 GitLab 在「非正常關閉」後
# 無法再啟動（開機自動啟動時最常見）：
#   1. 無法 unlink／重新 bind 既有的 socket 檔，元件啟動時因處理不掉舊 socket
#      而失敗（Operation not supported）。
#   2. 無法對 socket 檔 chmod，建立後設權限的元件會啟動失敗（EINVAL）。
#   3. 無法保留 setgid 位元，reconfigure 檢查 repositories 需為 2770 會失敗。
# 前兩項對 PostgreSQL、Redis、Rails(Puma) 已由 docker-compose.yaml 從根本解掉
# （前兩者的 socket 移到 tmpfs，Rails 則停用 unix socket 改走 TCP），不再依賴
# 本函式；留在掛載區的只剩 Gitaly 與 Workhorse 的 socket。啟動前先行清理與
# 補正，可避免容器陷入無限重啟。
#
# 僅在容器「未運行」時才動作。GitLab 各元件之間是靠這些 unix socket 互連
# （Workhorse→Rails、Rails→Gitaly 等），容器運行中時它們全是活的，而
# find -type s 只看檔案型別，分不出活的與殘留的。誤刪活 socket 的後果無法
# 自癒：listener 持有的是已開啟的 inode，刪掉路徑名既不會通知它、也不會讓
# 它重建，但連線方是以路徑名 connect；加上 docker compose up -d 對設定未變
# 的運行中容器是 no-op（不會重啟），沒有任何人會把 socket 補回來，於是既有
# 連線照舊而新連線全數失敗（對外表現為 502）。故偵測到運行中即整段跳過。
# Globals:
#   DOCKER_DIR
# Arguments:
#   無
# Outputs:
#   清理項目訊息
#######################################
clean_stale_state() {
  # 以 container_name 精確比對。compose 檔已指定 name: gitlab，compose ps 不再
  # 混入他專案容器，但此處仍用 docker ps：判斷的是「這一個容器是否運行中」，
  # 直接對 container_name 比對語意最精確，也不受未來專案名調整影響。
  local running
  running="$(docker ps --filter 'name=^gitlab$' --filter 'status=running' --quiet 2>/dev/null || true)"
  if [[ -n "${running}" ]]; then
    echo "[run.sh] GitLab 容器運行中，跳過 socket 清理（避免刪除使用中的 socket）。"
    return 0
  fi

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
