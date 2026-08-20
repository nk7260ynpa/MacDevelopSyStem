# 更新 GitLab 與 Harbor 版本

> **注意**：本文中與 `launchctl unload/load com.chen.harbor-watchdog.plist` 相關的
> 前後置步驟已失效——整套 LaunchAgent 機制已於 `refactor/native-docker-restart` 廢止，
> 改用 Docker 內建的 `restart: always`。升級前後改用 `./run.sh stop` 與 `./run.sh`。

Notion 任務：[更新gitlab 與 Harbor版本](https://app.notion.com/p/3c0dfac20953801c968bf8a08204a6f8)
（Group：MacDevelopSyStem，狀態：In progress）

## Context

本機自架的三項服務版本已落後，其中 Harbor 落後約兩年：

| 服務 | 目前 | 目標 | 落差 |
| --- | --- | --- | --- |
| GitLab CE | 19.0.1（`:latest`，2026-05-27 拉取） | **19.2.4-ce.0** | 2 個 minor |
| Harbor | v2.11.0（2024-06 建置） | **v2.15.2** | 4 個 minor、約 2 年 |
| GitLab Runner | 19.0.1（`:latest`） | **v19.2.2** | 對齊 GitLab 主體 |

任務要求「上網抓取最新版本的 image → 重啟服務」。調查後發現這不是單純換 tag：
Harbor v2.15.2 帶有兩項破壞性變更，必須在升級流程中特別處理（見下方風險章節）。

同時把 GitLab 與 Runner 的 `:latest` 改為釘選版本號——GitLab 有「必經升級停點」
規則（19.x 為 19.2、19.5、19.8、19.11），浮動 tag 有機會在某次重拉時一口氣跨過
停點而導致資料庫遷移失敗；釘選後每次升級都是刻意、可審查、可回溯的決定。

**範圍**：僅 Docker Compose 方案（實際運行中）。`harbor/k8s/`、`gitlab/k8s/`
底下的 manifest 維持 v2.11.0 / `:latest`，本次不動（使用者決定）。

## 已查證的關鍵事實

- GitLab Docker Hub `latest` 的 digest 與 `19.2.4-ce.0` 完全相同
  （`sha256:1ac3eab1…`），確認最新穩定版即 19.2.4。
- GitLab 必經停點取自 `gitlab-org/gitlab` 的 `config/upgrade_path.yml`：
  19.0.1 → 19.2.4 中間唯一的停點就是 19.2 本身，**單跳升級合法**。
- Harbor v2.15.2 的 `goharbor/redis-photon:v2.15.2` 回 **404**，
  `goharbor/valkey-photon:v2.15.2` 回 200 —— v2.15.2 正是切換分界
  （v2.15.1 仍是 redis-photon）。官方 compose 樣板中 service 名、container_name
  （皆為 `redis`）與 volume 路徑（`/var/lib/redis`）**都沒變**，只有 image 名稱換掉。
- `goharbor/harbor-db:v2.15.2` 的 ENTRYPOINT 是 `["/docker-entrypoint.sh", "15", "18"]`；
  本機 PGDATA 現況為 `/var/lib/postgresql/data/pg15/`（PostgreSQL 15.7），
  正好落在官方支援的升級來源，容器啟動時會自動跑 `pg_upgrade`（**非** `--link` 模式，
  採複製，較適合 macOS virtiofs）。DB 僅 65MB，磁碟餘 208GB，空間無虞。
- `goharbor/prepare` 的 `prepare` 指令**不驗證** `_version`，且新增的
  `max_job_duration_hours` 有預設值 24，故舊 harbor.yml 不會讓 prepare 失敗；
  仍應同步版本號以免日後混淆。
- v2.15.2 的 prepare 樣板仍會產生我們 compose 綁定掛載的每一個設定檔
  （`log/logrotate.conf`、`log/rsyslog_docker.conf`、`registry/config.yml`、
  `registryctl/config.yml`、`core/app.conf`、`portal/nginx.conf`、
  `jobservice/config.yml`、`nginx/`），掛載點不需調整。
- Harbor 各映像在 v2.15.2 仍僅發佈 **amd64**，與現況相同（Apple Silicon 上照舊模擬執行）。
- `com.chen.harbor-watchdog` LaunchAgent 每 120 秒巡檢一次，容器存在但未全數 running
  時會自行執行 `harbor/run.sh`。升級期間需先卸載，避免與手動流程互踩。

## 變更檔案

### Harbor（`harbor/docker/`）

- **`docker-compose.yaml`**：9 個 image tag `v2.11.0` → `v2.15.2`；
  其中 `redis` service 的 image 由 `goharbor/redis-photon` 改為
  `goharbor/valkey-photon`（service 名、container_name、volume 均不動）。
  同步更新檔頭註解的版本字樣，並在 `redis` service 加註記說明 v2.15.2 起
  快取後端改用 Valkey、但服務名沿用 `redis` 以維持設定相容。
- **`build.sh`**：`readonly HARBOR_VERSION="v2.15.2"`。
- **`Dockerfile`**：`FROM goharbor/harbor-core:v2.15.2`。
- **`harbor.yml`**：`_version: 2.11.0` → `2.15.0`（此為 v2.15.2 樣板的宣告值），
  並補上 v2.15 新增的 `jobservice.max_job_duration_hours: 24`。

### GitLab（`gitlab/docker/Dockerfile`）

`FROM gitlab/gitlab-ce:latest` → `FROM gitlab/gitlab-ce:19.2.4-ce.0`，
並在註解說明釘選理由與必經停點規則，讓下次升級的人知道要查 `upgrade_path.yml`。

### GitLab Runner（`gitlab-runner/docker/Dockerfile`）

`FROM gitlab/gitlab-runner:latest` → `FROM gitlab/gitlab-runner:v19.2.2`。
註記：Runner 版本不得高於 GitLab 主體，故取 19.2 分支最新的 v19.2.2
（`latest` 於 2026-08-20 當下觀測指向 v19.3.0，高於主體 19.2.4，不採用；
Dockerfile 內的註解已改為描述規則而非當下版本號，以免隨時間過期）。
`config.toml` 未釘選 `helper_image`，helper 會自動跟隨 Runner 版本，無需改設定。

### 文件

- **`README.md`**：第 325、333 行的「版本固定 `v2.11.0`」字樣更新為 `v2.15.2`；
  補一段 Harbor 升級注意事項（PG 15→18 自動遷移、redis→valkey 改名）。
- **`CLAUDE.md`**：專案根目錄目前無此檔，不需更新。

## 執行步驟

依服務拆成獨立提交，每個服務「改檔 → 建置 → 部署 → 驗證」走完才進下一個。

### 0. 前置

```bash
mkdir -p ~/AI/_backups                      # 備份放在 repo 外，避免污染版控
launchctl unload ~/Library/LaunchAgents/com.chen.harbor-watchdog.plist
```

### 1. Harbor v2.11.0 → v2.15.2

```bash
cd ~/AI/MacDevelopSyStem/harbor
./run.sh stop                               # docker compose down（容器移除，watchdog 亦不會誤觸）
cp -a docker/data ~/AI/_backups/harbor-data-$(date +%Y%m%d)    # 242MB
# —— 改檔（見上方清單）——
cd docker && ./build.sh                     # 拉 v2.15.2 映像 + prepare 重生設定
cd .. && ./run.sh
docker logs -f harbor-db                    # 觀察 pg_upgrade 完成
```

`build.sh` 的 prepare 會清空並重生 `data/config/`，但 `data/secret/`
（含 secretkey 與 registry 根憑證）會被沿用，既有 registry 內容不受影響。

### 2. GitLab 19.0.1 → 19.2.4

```bash
cd ~/AI/MacDevelopSyStem/gitlab
./run.sh stop
cp -a docker/data ~/AI/_backups/gitlab-data-$(date +%Y%m%d)    # 1.3GB
# —— 改檔 ——
cd docker && ./build.sh
cd .. && ./run.sh
docker logs -f gitlab                       # 觀察 reconfigure 與 DB migration
```

### 3. GitLab Runner 19.0.1 → v19.2.2

```bash
cd ~/AI/MacDevelopSyStem/gitlab-runner
./run.sh stop
cd docker && ./build.sh
cd .. && ./run.sh
```

### 4. 收尾

```bash
launchctl load ~/Library/LaunchAgents/com.chen.harbor-watchdog.plist
```

## 驗證

| 項目 | 指令 | 預期 |
| --- | --- | --- |
| Harbor 容器 | `docker compose -f harbor/docker/docker-compose.yaml ps` | 9 個 service 全 `healthy` |
| PG 已升到 18 | `docker exec harbor-db postgres --version` | `PostgreSQL 18.x` |
| PG 舊資料保留 | `docker exec harbor-db ls /var/lib/postgresql/data` | ~~同時有 `pg15`、`pg18`~~ **此預期有誤，實際只剩 `pg18`，見文末〈實作後修訂〉** |
| Harbor UI | `curl -sI http://localhost:8081` | `200`，登入 admin 可見既有 project |
| Harbor registry | `docker login localhost:8081` → `push`/`pull` 一個小 image | 成功 |
| GitLab 版本 | `docker exec gitlab cat /opt/gitlab/embedded/service/gitlab-rails/VERSION` | `19.2.4` |
| GitLab 健康 | `curl -sf http://localhost:8080/-/health` | `GitLab OK` |
| GitLab 背景遷移 | `docker exec gitlab gitlab-rails runner 'puts Gitlab::Database::BackgroundMigration::BatchedMigration.where.not(status: 3).count'` | 最終收斂為 `0` |
| Git 操作 | `git ls-remote http://127.0.0.1:8080/<既有專案>.git` | 列出 ref |
| Runner 版本 | `docker exec gitlab-runner gitlab-runner --version` | `19.2.2` |
| Runner 註冊 | `docker exec gitlab-runner gitlab-runner verify` | 既有 runner 仍有效 |
| CI 端到端 | 於 GitLab 觸發一次既有專案的 pipeline | job 成功 |

## 風險與應對

| 風險 | 應對 |
| --- | --- |
| **pg_upgrade 失敗** | ~~舊 `pg15` 目錄不會被刪除，容器內仍在。~~**此前提有誤：升級成功後 entrypoint 會直接刪除 `pg15`，容器內沒有回退點，只能還原備份，見文末〈實作後修訂〉。** 停服務、還原 `~/AI/_backups/harbor-data-*`、把 image 改回 v2.15.1（仍用 PG 15 且仍是 redis-photon），即可回到可用狀態。 |
| **升級後 UI 列表空白／robot 權限異常** | v2.15.2 release note 明列此症狀源自 PG 大版本間 collation 變更導致 B-Tree 索引失效。應對：`docker exec harbor-db reindexdb --all --username postgres`。升級腳本只刷新 collation 中繼資料、不重建索引。 |
| **`harbor-log` 健康檢查失效導致 compose 卡住** | 我們的 compose 對 log 用 `condition: service_healthy`，而該 healthcheck 依賴 `netstat`。v2.15.2 的 log base 改用 `goharbor/photon:5.0-legacy`（未顯式安裝 net-tools）。啟動後立即檢查 `docker inspect harbor-log --format '{{.State.Health.Status}}'`；若持續 `unhealthy`，改為 `condition: service_started` 並保留現有的 log 先行啟動順序。 |
| **GitLab 資料庫遷移耗時** | 19.0→19.2 的 reconfigure 加 migration 可能耗時 10 分鐘以上，屬正常。以 `docker logs -f gitlab` 觀察，不要中途 kill。 |
| **v2.14.0 破壞性變更：replication adapter 白名單** | 本機未設定任何 replication 端點，不受影響。 |
| **watchdog 於升級中途插手** | 步驟 0 已先 unload，步驟 4 再 load 回來。 |

## 提交規劃

分支 `chore/upgrade-gitlab-harbor`（GitHub remote，依 gitflow 規則只建分支、不開 PR）：

1. `chore(harbor): 升級 Harbor 至 v2.15.2`
2. `chore(gitlab): 釘選並升級 GitLab 至 19.2.4`
3. `chore(gitlab-runner): 升級 Runner 至 v19.2.2`
4. `docs(readme): 更新服務版本與 Harbor 升級注意事項`

部署驗證通過後，再依 gitflow 步驟 8 交 verify-agent 檢查，最後寫入
`~/.claude/gitflow/current.json` 並停止，把合併與 Notion 回寫留給 `/gitflow2`。

---

## 實作後修訂

執行過程中有兩項與計畫不符的事實，記錄於此（相關檔案的註解與 README 均已依實況更正）：

1. **pg15 不會保留**。計畫假設 `pg_upgrade` 採複製模式故舊叢集可留作回退，實際上
   `goharbor/harbor-db:v2.15.2` 的 entrypoint 在升級成功後會直接 `rm -rf` 舊的
   `data/database/pg15`（log 明載 `remove the /var/lib/postgresql/data/pg15 after
   upgrade success.`），容器內不留回退點。回退只能依賴事前備份
   `~/AI/_backups/harbor-data-20260820-210523`（238M，含完整 pg15）。

2. **索引已重建**。升級後 `pg_database.datcollversion` 雖已標為 2.43、無 mismatch 警告，
   但 `pg_upgrade` 是沿用舊叢集的索引檔，排序仍出自升級前的 glibc 2.36，正是 release
   note 警示的情境，故仍執行了 `reindexdb --all --username postgres`（0.7 秒完成，
   事後資料筆數不變）。

另外修正了一項與升級無直接關係、但會讓升級失效的既有缺陷：`gitlab/docker/build.sh`
原本的 `docker compose pull` 會去 registry 拉本地自建的 `macdev/gitlab`，必然失敗並
中止腳本，導致 `docker compose build` 從未執行——首次執行升級時即因此仍在用舊 image。
已改為 `docker compose build --pull`，與 `gitlab-runner/docker/build.sh` 一致。

實際提交為 6 筆，較原規劃的 4 筆多出兩筆文件修正——皆源自 verify-agent 兩輪審查的
回饋（版本敘述與註解精確度、以及本節所在文件自身的補正）。

驗證結果：Harbor 9 個 service 全 healthy、PG 18.3、既有 2 專案 5 artifacts 完整、
push/pull 端到端通過；GitLab 19.2.4 healthy、22 個專案與 5 位使用者完整、Gitaly 讀取
正常、背景遷移於 22:01 收斂為 0；Runner v19.2.2 註冊有效且於 GitLab 端顯示 online。
