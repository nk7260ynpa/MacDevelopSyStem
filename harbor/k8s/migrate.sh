#!/usr/bin/env bash
#
# 把 Docker Compose 版的 Harbor 資料遷移到 K8s 版的 ./data。
#
# 用法：
#   ./migrate.sh
#
# 來源 ../docker/data 只讀不刪，隨時可以回退到 Compose 版（回退前須先
# ./delete.sh 讓出 port）。但兩邊資料在切換後會各自演進，回退等同放棄
# K8s 期間推上去的所有 image。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

readonly SRC_DIR="${SCRIPT_DIR}/../docker/data"
readonly DST_DIR="${SCRIPT_DIR}/data"

if [[ ! -d "${SRC_DIR}/config/core" ]]; then
  echo "[migrate.sh] 錯誤：找不到來源 ${SRC_DIR}/config，沒有可遷移的資料。" >&2
  exit 1
fi

# 必須在所有容器停止的狀態下複製。會寫檔的不只 PostgreSQL：registry 寫 blob、
# redis 寫 RDB 與 jobservice 佇列、core 寫 /data，任何一個還活著都可能讓複製出來
# 的快照彼此對不起來（最典型的是 DB 檔與 WAL 不一致），還原後整套起不來。
running="$(docker ps --filter 'status=running' --format '{{.Names}}' 2>/dev/null |
  grep -xE 'harbor-core|harbor-db|harbor-jobservice|harbor-portal|registry|registryctl|redis|nginx' || true)"
if [[ -n "${running}" ]]; then
  echo "[migrate.sh] 錯誤：Docker Compose 版的 Harbor 仍有容器在運行，熱複製會得到不一致的資料。" >&2
  echo "  仍在運行：$(echo "${running}" | tr '\n' ' ')" >&2
  echo "  請先執行：../run.sh docker stop" >&2
  exit 1
fi

echo "[migrate.sh] 建立目的地目錄..."
mkdir -p "${DST_DIR}"

# config 是各 service 的設定，secret 是加解密的根本——缺了 secret/keys/secretkey
# 與 secret/core/private_key.pem，資料庫內既有的密碼與 robot 帳號權杖全部解不開。
# 兩者都很小但都不能少。
echo "[migrate.sh] 複製 config 與 secret..."
rsync -a --delete "${SRC_DIR}/config/" "${DST_DIR}/config/"
rsync -a --delete "${SRC_DIR}/secret/" "${DST_DIR}/secret/"

echo "[migrate.sh] 複製 database（PostgreSQL，約 50 MB）..."
rsync -a --delete "${SRC_DIR}/database/" "${DST_DIR}/database/"

echo "[migrate.sh] 複製 registry（image blob，約 3.6 GB，需數分鐘）..."
rsync -a --delete "${SRC_DIR}/registry/" "${DST_DIR}/registry/"

echo "[migrate.sh] 複製 redis／psc／ca_download／job_logs..."
for dir in redis psc ca_download job_logs; do
  mkdir -p "${DST_DIR}/${dir}"
  if [[ -d "${SRC_DIR}/${dir}" ]]; then
    rsync -a --delete "${SRC_DIR}/${dir}/" "${DST_DIR}/${dir}/"
  fi
done

# log 不遷移：harbor-log 收集容器早已移除，各 service 改用 stdout，
# 該目錄只剩歷史檔案，對新環境沒有任何作用。
echo "[migrate.sh] 跳過 log（harbor-log 已移除，歷史 log 不遷移）。"

echo ""
echo "[migrate.sh] 完成。接著執行 ./apply.sh 或 ../run.sh 啟動 K8s 版。"
