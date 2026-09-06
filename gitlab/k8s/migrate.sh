#!/usr/bin/env bash
#
# 把 Docker Compose 版的 GitLab 資料遷移到 K8s 版的 ./data。
#
# 用法：
#   ./migrate.sh
#
# 來源 ../docker/data 只讀不刪，隨時可以回退到 Compose 版（回退前須先
# ./delete.sh 讓出 port）。但兩邊資料在切換後會各自演進，回退等同放棄
# K8s 期間的所有異動。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

readonly SRC_DIR="${SCRIPT_DIR}/../docker/data"
readonly DST_DIR="${SCRIPT_DIR}/data"

if [[ ! -d "${SRC_DIR}/data" ]]; then
  echo "[migrate.sh] 錯誤：找不到來源 ${SRC_DIR}/data，沒有可遷移的資料。" >&2
  exit 1
fi

# 必須在容器停止的狀態下複製：GitLab 執行中時 PostgreSQL 與 Redis 隨時在寫檔，
# 熱複製會得到不一致的快照（DB 檔與 WAL 對不起來），還原後可能整個起不來。
running="$(docker ps --filter 'name=^gitlab$' --filter 'status=running' --quiet 2>/dev/null || true)"
if [[ -n "${running}" ]]; then
  echo "[migrate.sh] 錯誤：Docker Compose 版的 GitLab 仍在運行，熱複製會得到不一致的資料。" >&2
  echo "  請先執行：../run.sh docker stop" >&2
  exit 1
fi

echo "[migrate.sh] 建立目的地目錄..."
mkdir -p "${DST_DIR}"/{config,logs,data}

# config 含 gitlab-secrets.json，缺了它資料庫內所有加密欄位（CI 變數、2FA、
# 整合權杖等）都解不開，務必一起帶過去。
echo "[migrate.sh] 複製 config（含 gitlab-secrets.json）..."
rsync -a --delete "${SRC_DIR}/config/" "${DST_DIR}/config/"

echo "[migrate.sh] 複製 data（Repository／PostgreSQL／Redis，約 460 MB，需數分鐘）..."
rsync -a --delete "${SRC_DIR}/data/" "${DST_DIR}/data/"

# logs 不遷移：純粹是歷史紀錄，佔 1 GB 以上且對新環境沒有任何作用。
echo "[migrate.sh] 跳過 logs（歷史 log 不遷移，僅建立空目錄）。"

echo ""
echo "[migrate.sh] 完成。接著執行 ./apply.sh 或 ../run.sh 啟動 K8s 版。"
