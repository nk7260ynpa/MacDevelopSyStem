# MacDevelopSyStem

本專案用於在 macOS 上建立基本開發環境，包含常見的開發者工具（如 GitLab、Harbor 等），
透過 Docker 與腳本化部署，快速搭建可重現的本地開發基礎設施。

## 專案目標

- 以容器化（Docker）方式部署開發者工具，避免污染主機環境。
- 提供一鍵啟動／停止腳本，降低安裝與設定成本。
- 集中管理各工具的設定、資料卷與日誌，方便備份與遷移。

## 預定支援的工具

| 工具 | 用途 | 版本 | 狀態 |
| --- | --- | --- | --- |
| GitLab | 自架 Git 程式碼托管與 CI/CD | `19.2.4-ce.0` | 已支援 |
| Harbor | 私有 Container Registry | `v2.15.2` | 已支援 |
| GitLab Runner | GitLab CI/CD 任務執行器（docker executor） | `v19.2.2` | 已支援 |
| （後續擴充） | 視需求新增，例如 Jenkins、Nexus、MinIO 等 | — | — |

各服務的映像版本一律**釘選**，不使用浮動的 `:latest`。GitLab 與 Runner 釘選於各自的
`docker/Dockerfile`；Harbor 為多映像架構，實際生效的是 `docker/docker-compose.yaml`
的 8 個 image tag 與 `docker/build.sh` 的 `HARBOR_VERSION`（`harbor/docker/Dockerfile`
僅為佔位、不參與部署）。升級注意事項見「[版本升級](#版本升級)」。

## 專案架構

```text
MacDevelopSyStem/
├── README.md              # 專案說明文件
├── .gitignore             # Git 忽略清單
├── plans/                 # 各次改動的實作計畫紀錄（歷史文件，不參與部署）
├── gitlab/                # GitLab 部署設定
│   ├── run.sh             # Docker Compose 啟動入口（up/logs/stop/status）
│   └── docker/            # Docker Compose 方案
│       ├── build.sh
│       ├── Dockerfile
│       ├── docker-compose.yaml
│       ├── .env.example
│       └── data/          # 持久化資料（僅 .keep 納入版控）
├── harbor/                # Harbor 部署設定
│   ├── run.sh             # Docker Compose 啟動入口（up/logs/stop/status）
│   └── docker/            # Docker Compose 方案
│       ├── build.sh       # 拉 image + 用 prepare 產生各 service 設定
│       ├── Dockerfile
│       ├── docker-compose.yaml
│       ├── harbor.yml     # Harbor 設定範本（供 prepare 讀取）
│       ├── .env.example
│       └── data/          # 持久化資料（僅 .keep 納入版控）
└── gitlab-runner/         # GitLab Runner 部署設定（CI/CD 執行器）
    ├── run.sh             # 入口：register/up/logs/stop/status
    └── docker/            # Docker Compose 方案（docker executor）
        ├── build.sh
        ├── Dockerfile
        ├── docker-compose.yaml
        ├── .env.example   # CI_SERVER_URL / RUNNER_TOKEN 等
        └── data/          # Runner 設定 config.toml（僅 .keep 納入版控）
```

### 資料持久化設計

各工具的持久化資料皆位於自己的 `docker/data` 子目錄下：

| 工具 | 資料位置 |
| --- | --- |
| GitLab | `gitlab/docker/data/` |
| GitLab Runner | `gitlab-runner/docker/data/`（config.toml） |
| Harbor | `harbor/docker/data/` |

- 以 bind mount 直接掛載各自的 `docker/data`，資料落在 macOS 本機、可直接備份與遷移。
- 各本機 `data` 資料夾以 `.keep` 納入版控，實際內容由 `.gitignore` 排除。

> 注意事項：
>
> - 舊版共用資料夾 `gitlab/git_data/`、`harbor/harbor_data/` 已停用並由 `.gitignore` 整夾忽略，
>   確認無需保留後可手動刪除。

## 系統需求

- macOS（Apple Silicon 或 Intel）
- Docker Desktop 或同等容器執行環境
  - 建議分配 ≥ 4 GB RAM 給 Docker（GitLab Omnibus 建議值）
  - 若同時啟用 Harbor，建議 ≥ 6 GB RAM（Harbor 含 8 個 service）
- Bash／Zsh

---

## GitLab 部署

GitLab 以 Docker Compose 部署，使用 8080（HTTP）與 2222（SSH）兩個 port。

啟動：

```bash
cd gitlab
./run.sh                 # 等同 docker compose up -d
```

其他操作：

```bash
./run.sh logs            # 跟隨 container log
./run.sh status          # 查看狀態
./run.sh stop            # 停止 GitLab
```

若需重新建置本地 image：

```bash
cd gitlab/docker
./build.sh               # 等同 docker compose build --pull
```

存取資訊：

- 網頁：<http://localhost:8080>
- SSH：`ssh -p 2222 git@localhost`
- 取得 root 初始密碼（容器啟動後可用）：

  ```bash
  docker exec gitlab cat /etc/gitlab/initial_root_password
  ```

- 持久化資料位置：`gitlab/docker/data/{config,logs,data}`（已於 `.gitignore` 排除）

> 首次啟動 GitLab 需 3–5 分鐘完成自我初始化，期間 `docker ps` 會顯示 `health: starting`，請耐心等待。

> 資源設定（最小化）：已設容器記憶體上限 4G，並以單進程 Puma 運行、關閉內建
> Registry（改用 Harbor）／KAS／Prometheus 監控，常駐約 2.5–3 GB。適合輕量備份倉庫用途；
> 屬開發取向、非生產規格。

### macOS bind mount 的限制與因應

GitLab 的資料以 bind mount 掛到 `gitlab/docker/data`，而 macOS 上 Docker Desktop
採 virtiofs 分享目錄，對 unix socket 檔案有三項限制：

| 限制 | 症狀 |
| --- | --- |
| 無法 unlink／bind 既有 socket 檔 | 元件啟動時刪不掉前次殘留的 socket，回報 `bind: Operation not supported` |
| 無法對 socket 檔 chmod | PostgreSQL 建立 socket 後設定權限失敗，回報 `could not set permissions ...: Invalid argument` |
| 不保留 setgid 位元 | `gitlab-ctl reconfigure` 檢查 `git-data/repositories` 需為 `2770` 而中止 |

這些限制曾使 GitLab 在「非正常關閉」後無法自行復原：重開機或 daemon 重啟時，
容器是被 daemon 直接 `start` 的，不會經過 `run.sh`，前次殘留的 socket 檔沒被清掉，
元件便無法在同一路徑上重建或連線，對外表現為持續 502。

因應方式分兩類，**主要元件已從根本移出 virtiofs**，不再倚賴啟動前清理：

| 元件 | 作法 | 設定位置 |
| --- | --- | --- |
| PostgreSQL | socket 目錄改掛容器內 tmpfs `/run/postgresql` | `docker-compose.yaml` |
| Redis | socket 目錄改掛容器內 tmpfs `/run/gitlab-redis` | `docker-compose.yaml` |
| Rails（Puma） | 停用 unix socket，Workhorse 改連既有的 `tcp://127.0.0.1:8080` | `docker-compose.yaml` |
| Gitaly、Workhorse | socket 仍在掛載區，但實測可自行重建，由 `run.sh` 的清理兜底 | `run.sh` |

資料庫檔案、Redis 的 RDB 仍留在 `data/data`，持久化不受影響。

Rails 那一項的細節：GitLab 的 puma 本來就同時 bind unix socket 與
`tcp://127.0.0.1:8080`，因此停用 unix bind 不減少任何能力。設定上
`puma['socket']` 給**空字串**即可（範本以 `!listen_socket.empty?` 決定是否 bind），
並須**明確指定** `gitlab_workhorse['auth_backend']`，omnibus 才會把 workhorse 的
`auth_socket` 設為 `nil`（見容器內 `libraries/puma.rb` 與 `libraries/gitlab_workhorse.rb`）；
該值與內建預設相同，有意義的是「指定」這個動作本身。

`run.sh` 另外承擔兩件事：啟動前清除 `data/data` 內殘留的 unix socket，並將
`git-data/repositories` 補回 `2770`。注意**這道清理只在手動執行 `run.sh` 時發生**。
此清理**僅在 GitLab 容器未運行時執行**：容器運行中時那些 socket 全是活的
（Rails→Gitaly 等元件靠它們互連），刪掉會使新連線全數失敗，
而 `docker compose up -d` 對運行中的容器不會重啟、不會重建 socket，服務將無法自癒。

若仍遇到啟動失敗，可先確認殘留 socket 是否清乾淨。**須在容器停止的狀態下檢查**——
服務正常運行時本來就會有數個活的 socket，那是正常現象，不是殘留：

```bash
docker ps --filter 'name=^gitlab$' --quiet   # 應無輸出（確認容器已停止）
find gitlab/docker/data/data -type s         # 應無輸出
```

---

## GitLab Runner 部署

GitLab Runner 為 GitLab CI/CD 的任務執行器。本方案以 Docker Compose 部署單一 runner，採
**docker executor**（每個 CI job 於獨立容器中執行），由 runner 透過主機 Docker daemon 啟動
job 容器（sibling containers），無需 docker-in-docker。註冊採用 GitLab 16.0 以後的
**認證權杖（authentication token，`glrt-` 開頭）**流程。

> 前置：GitLab（Docker Compose 方案）已啟動且可於 <http://localhost:8080> 存取。

### 一、建立 Runner 取得認證權杖

於 GitLab 網頁建立 Runner，依需要的範圍擇一，取得 `glrt-` 開頭的認證權杖：

- 實例層（需 admin）：**Admin Area → CI/CD → Runners → New instance runner**
- 群組層：**群組 → Settings → CI/CD → Runners → New group runner**
- 專案層：**專案 → Settings → CI/CD → Runners → New project runner**

建立時可設定標籤（tags）、是否接受未帶標籤的 job 等；送出後頁面會顯示 `glrt-...` 權杖，請複製備用。

### 二、填入設定

```bash
cd gitlab-runner/docker
cp .env.example .env
# 編輯 .env，將 RUNNER_TOKEN 改為剛剛取得的 glrt- 權杖
```

`.env` 重點欄位：

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `CI_SERVER_URL` | `http://host.docker.internal:8080` | runner 與 job 容器連回主機 GitLab 的網址 |
| `RUNNER_TOKEN` | `glrt-REPLACE_ME` | 認證權杖（必填） |
| `RUNNER_DOCKER_IMAGE` | `alpine:latest` | job 未指定 image 時的預設映像 |
| `RUNNER_DESCRIPTION` | `mac-local-docker-runner` | runner 描述 |

> 為何用 `host.docker.internal`？GitLab 的 `external_url` 是 `http://localhost:8080`，但容器內的
> `localhost` 指向容器自身。`host.docker.internal` 在 Docker Desktop 會解析到主機，故 runner
> 連線、git clone 與 artifact／快取上傳皆走此網址連回主機上發佈的 8080 埠。

### 三、建置、註冊與啟動

```bash
cd gitlab-runner/docker
./build.sh               # 拉 gitlab-runner image 並建立本地 image

cd ..
./run.sh register        # 以 .env 的權杖註冊（設定寫入 docker/data/config.toml）
./run.sh up              # 啟動 runner
```

其他操作：

```bash
./run.sh status          # 查看狀態
./run.sh logs            # 跟隨 log
./run.sh stop            # 停止 runner
```

註冊成功後，於 GitLab 的 Runners 頁面可看到此 runner 上線（綠點）。

### 設計重點

- **executor**：docker；runner 容器掛載主機 `/var/run/docker.sock`，由主機 Docker daemon 啟動
  job 容器，無需 docker-in-docker。
- **網路**：`--url` 與 `--clone-url` 皆設為 `host.docker.internal:8080`，並對 job／helper 容器注入
  `host.docker.internal:host-gateway`，確保 polling、git clone 與 artifact／快取上傳都能連回主機 GitLab。
- **設定持久化**：`docker/data/config.toml`（含權杖）以 bind mount 保存，已由 `.gitignore` 排除，
  不納入版控。
- **compose 專案名**：固定 `name: gitlab-runner`，避免與其他同放在 `docker/` 目錄的專案互相視為 orphan。

---

## Harbor 部署

Harbor 為私有 Container Registry，包含 8 個 service（registry / registryctl /
postgresql / redis / core / portal / jobservice / proxy），與 GitLab 一樣以
Docker Compose 部署，版本固定 `v2.15.2`。

首次啟動前必須先拉 image 並產生各 service 設定：

```bash
cd harbor/docker
./build.sh               # 拉 v2.15.2 image，並用 prepare 產生 ./data/config/
```

啟動：

```bash
cd harbor
./run.sh                 # 等同 docker compose up -d
```

其他操作：

```bash
./run.sh logs            # 跟隨所有 service log
./run.sh status          # 查看狀態
./run.sh stop            # 停止 Harbor
```

存取資訊：

- 網頁：<http://localhost:8081>
- 預設帳號：`admin` / `Harbor12345`
- **⚠ 首次登入後請立即修改密碼。**
- 持久化資料位置：`harbor/docker/data/`（已於 `.gitignore` 排除）

> 修改 `harbor/docker/harbor.yml` 後，必須重新執行 `./build.sh` 讓 prepare 重生設定，
> 再 `./run.sh stop && ./run.sh up` 才會生效。

實作上針對 macOS / Docker Desktop 環境做了三項穩定性處理（皆已內建於設定，平常無需手動介入）：

- **固定 compose 專案名為 `harbor`**：`docker-compose.yaml` 以 `name: harbor` 避免與其他同放在
  `docker/` 目錄、專案名同被推導為 `docker` 的專案互相視為 orphan。
- **log 不跨容器依賴**：各 service 一律以 Docker 內建的 `json-file` driver 寫 log
  （`50m` x 3 輪替），不依賴任何收集用容器。這讓每個容器都能獨立恢復，`restart: always`
  在 daemon 自動恢復時才會真正生效，詳見[開機自動啟動與自動修復](#開機自動啟動與自動修復)。
- **registry 的 `root.crt`**：改由 registry 設定目錄一併掛入，不另以單檔疊掛，以避開
  virtiofs「於目錄掛載上再疊單檔掛載」的 mountpoint 衝突；此複製動作已內建於 `./build.sh`。

### 與 GitLab 同時啟動

Harbor port 8081 已刻意錯開 GitLab 的 8080，兩者可同時運行（記憶體建議 ≥ 6 GB）。

---

## 開機自動啟動與自動修復

Harbor、GitLab、GitLab Runner 於主機重開機後自動恢復，意外掛掉也會自動重啟。
機制**完全依賴 Docker 內建能力**，不需要安裝任何常駐程式或排程工具。

實測結果（2026-08-21，完整重啟 Docker Desktop 驗證，全程未執行任何救援指令）：

| 服務 | 容器自動恢復 | 服務可用 |
| --- | --- | --- |
| Harbor（8 個容器） | ✅ | ✅ UI／API 皆 200，7 個 component 全 healthy |
| GitLab Runner | ✅ | ✅ `gitlab-runner verify` 通過 |
| GitLab | ✅ | ✅ 約 30 秒後 HTTP 200、healthcheck 轉 healthy |

過程中 `nginx`（Harbor proxy）與 `harbor-jobservice` 因啟動競態各崩潰過
1 次與 3 次（`RestartCount` 為 1、3），皆由 `restart: always` 自動拉回，
無須人工介入——這正是本機制要達成的效果。

兩個構成要件：

| 要件 | 設定位置 | 作用 |
| --- | --- | --- |
| Docker Desktop 登入自啟 | Docker Desktop → Settings → General | 開機後拉起 Docker daemon |
| `restart: always` | 三個服務的 `docker-compose.yaml` | daemon 就緒後恢復容器；容器內主行程一退出就重啟（不看 exit code） |

> **前提**：Docker Desktop 須勾選 "Start Docker Desktop when you sign in"，
> 否則重開機後 daemon 不會啟動，容器自然無從恢復。這是唯一需要手動確認的設定。

驗證目前狀態：

```bash
# Docker Desktop 是否設為登入自啟（應為 true）
grep AutoStart ~/Library/Group\ Containers/group.com.docker/settings-store.json

# 三個服務的 restart policy（應全為 always）
docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' \
  gitlab gitlab-runner harbor-core
```

### 為什麼跨容器啟動依賴必須能靠 restart 自愈

這是本專案 compose 設定的一項關鍵約束，理解它才能避免日後改壞。

`depends_on`（含 `condition: service_healthy`）**只在執行 `docker compose up` 時有效**。
主機重開機或 Docker daemon 單獨重啟（Docker Desktop 更新、手動重啟、daemon 崩潰恢復）時，
daemon 是**逐容器依各自 restart policy 恢復，不走 compose、也不讀 `depends_on`**。

早期版本的 Harbor 讓 8 個 service 都以 `syslog` driver 將 log 送往 `harbor-log` 的 `1514` 埠，
並用 `depends_on` 對 `log` 把關。結果在 daemon 恢復容器時，眾 service 搶在 `harbor-log`
就緒前啟動、連不上 `1514`，最終只剩 `harbor-log` 存活——當時必須另外掛一支守護巡檢的
LaunchAgent 才能補救。

關鍵在於**這種失敗 restart policy 救不了**：logging driver 連不上屬於「容器 start 失敗」，
容器根本沒進入運行狀態，restart manager 不接手，`restart: always` 形同虛設。

改用 `json-file` driver 後，log 不再跨容器，這類失敗就消失了。

**新增或修改 service 時，跨容器依賴本身不是問題，「無法靠 restart 自愈的跨容器依賴」才是。**
兩者的差別：

- ✅ 可自愈：`proxy` 的 nginx 設定含 `upstream core { server core:8080; }`，`core` 未運行時
  nginx 會因 DNS 解析失敗而退出——但這是容器**運行後退出**，`restart: always` 會不斷重試，
  等 `core` 起來後自然恢復。
- ❌ 不可自愈：logging driver 連不上收集端，容器**連 start 都失敗**，restart policy 不介入。

`depends_on` 用於表達啟動順序偏好仍然沒問題——它在 `run.sh` 走 compose 的路徑上有效，
只是不能被當成正確性的保證。

### GitLab 在 daemon 重啟後的自癒路徑

GitLab 的自癒比 Harbor 多一層：容器被拉起只是第一步，容器**內部**的元件
（Rails、Workhorse、Gitaly…）還得能彼此連上。這些元件以 unix socket 互連，
而 socket 若落在 virtiofs 掛載區，daemon 直接 `start` 容器時會踩到殘留檔，
出現「容器 `Up`、HTTP 卻持續 502」的狀況——`restart: always` 對此無能為力，
因為容器從頭到尾都是活的，壞掉的是它裡面的連線。

現行設定已把會出事的三段連線全部移出掛載區（見〈[macOS bind mount 的限制與因應](#macos-bind-mount-的限制與因應)〉），
因此 daemon 重啟後 GitLab 可完全自行恢復。若日後仍遇到啟動後持續 502，
依序檢查這三處即可定位：

| 檢查點 | 指令 | 正常表現 |
| --- | --- | --- |
| 元件是否反覆重啟 | `docker exec gitlab gitlab-ctl status` | 各服務存活秒數持續增長，不會反覆歸零 |
| Workhorse→Rails | `docker exec gitlab tail /var/log/gitlab/gitlab-workhorse/current` | 無 `connect: operation not supported` |
| Redis／PostgreSQL | `docker exec gitlab tail /var/log/gitlab/redis/current` | 無 `bind: Operation not supported` |

真的卡住時，走一次完整流程讓 `run.sh` 的 socket 清理有機會執行：

```bash
cd gitlab && ./run.sh stop && ./run.sh
```

### 查看 log

Harbor 不再有集中式的 `harbor/docker/data/log/*.log`（該目錄下的既有檔案為改版前的殘留，
不再更新）。改用 Docker 原生方式：

```bash
docker logs harbor-core --tail 50     # 單一容器
docker logs -f gitlab                 # 跟隨
cd harbor && ./run.sh logs            # 該服務全部容器
```

### 手動停用服務

`docker stop` 與 `docker kill` 都會被 daemon 記為「使用者主動停止」，
所以容器**當下不會**被 restart policy 拉回；但 `always` 在 daemon 重啟時會忽略這個標記，
把容器一併恢復——這正是 `always` 與 `unless-stopped` 的唯一差別，也是本專案選 `always` 的理由：
只要曾經手動停過一次，`unless-stopped` 的容器就再也不會在重開機時自己回來。

因此要長期停用某個服務，請用 `run.sh stop`（等同 `docker compose down`），
容器被移除後就完全不受 restart policy 影響：

```bash
cd harbor && ./run.sh stop
```

> 同理，`docker kill` 無法用來測試崩潰自愈——它會被視為手動停止。
> 要模擬真正的意外退出，請從容器**內部**把主行程結束掉：
>
> ```bash
> docker exec harbor-core kill -TERM 1
> sleep 15   # 留時間讓 daemon 重建容器，立刻查會看到舊值
> docker inspect -f '{{.State.Status}} {{.RestartCount}}' harbor-core   # RestartCount 應遞增
> ```
>
> 若某個容器對此沒有反應，多半是它的 PID 1 忽略 `SIGTERM`（PID 1 不套用預設訊號處置，
> 未自行註冊 handler 的行程收到 `SIGTERM` 不會結束）。改送 `KILL` 即可：
> `docker exec <容器> kill -KILL 1`。

---

## 使用方式

各工具皆預期提供 `run.sh` 作為啟動入口，使用方式如下：

```bash
# 啟動 GitLab（Docker Compose 方案）
cd gitlab
./run.sh

# 啟動 Harbor（Docker Compose 方案，首次須先 ./docker/build.sh）
cd harbor
./run.sh

# 啟動 GitLab Runner（首次須先 ./docker/build.sh，並 ./run.sh register 註冊）
cd gitlab-runner
./run.sh up
```

## 版本升級

各服務的映像版本釘選在各自的 `docker/Dockerfile`（Harbor 另有 `docker-compose.yaml`
與 `build.sh` 中的 `HARBOR_VERSION`）。升級一律「改檔 → `./docker/build.sh` →
`./run.sh`」，並在升級前備份對應的 `docker/data/` 目錄到 repo 之外。

### GitLab

GitLab 有**必經升級停點**：跨越停點的一次性升級會導致資料庫遷移失敗。停點清單以官方
repo 的 `config/upgrade_path.yml` 為準（19.x 為 19.2、19.5、19.8、19.11），升級前務必查閱，
必要時分段升級。這也是不使用 `:latest` 的原因——浮動 tag 可能在某次重拉時一口氣跨過停點。

升級前確認背景遷移已全數完成，否則新版遷移會與未完成的舊遷移衝突：

```bash
docker exec gitlab gitlab-rails runner \
  'puts Gitlab::Database::BackgroundMigration::BatchedMigration.where.not(status: 3).count'
```

升級後同樣以上述指令確認收斂為 `0`（大版本升級後背景遷移可能持續數十分鐘）。

### GitLab Runner

Runner 版本**不得高於** GitLab 主體版本，故跟隨主體的次版本分支（如主體 19.2.x 則取
`v19.2.2`）。`config.toml` 未釘選 `helper_image`，helper 會自動跟隨 Runner 版本，無需另外設定。

### Harbor

Harbor 的資料庫遷移由 core 於啟動時鏈式執行，故可一次跨越數個次版本（本次即自
v2.11.0 直上 v2.15.2，未逐版停留）。但**跨過的每一版都可能帶有破壞性變更**，
升級前必須把區間內所有版本的 release note 讀過一遍，逐項確認。
自 v2.11.0 升至 v2.15.2 時遇到的兩項，記於此供日後參考：

- **快取後端 Redis → Valkey**（v2.15.2）：映像名由 `goharbor/redis-photon` 改為
  `goharbor/valkey-photon`（v2.15.1 為最後一版 redis-photon）。service 名、container_name
  與資料路徑沿用官方樣板不變，故各服務的連線位址（`redis:6379`）不需調整。
- **內建 PostgreSQL 15 → 18**（v2.15.2）：`goharbor/harbor-db` 的 entrypoint 為
  `["/docker-entrypoint.sh", "15", "18"]`（兩個參數即舊／新的 PG 大版本），容器啟動時
  偵測到既有 pg15 資料目錄即自動執行 `pg_upgrade`。
  **升級成功後 entrypoint 會直接刪除舊的 `data/database/pg15`**，容器內不留回退點，
  故升級前務必自行備份整個 `harbor/docker/data`。
  另外 `pg_upgrade` 沿用舊叢集的索引檔，其排序來自升級前的 glibc collation，可能造成
  列表載入不完、robot 帳號權限異常，升級後應重建索引：

  ```bash
  docker exec harbor-db reindexdb --all --username postgres
  ```

升級期間請用 `./run.sh stop`（`docker compose down`）停用服務。容器被移除後不受
`restart: always` 影響，不會在流程中途被 daemon 拉回；升級完成後再 `./run.sh` 啟動。

## 授權

尚未指定，預設保留所有權利。

## 維護者

- [@nk7260ynpa](https://github.com/nk7260ynpa)
