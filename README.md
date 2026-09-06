# MacDevelopSyStem

本專案用於在 macOS 上建立基本開發環境，包含常見的開發者工具（如 GitLab、Harbor 等），
透過 Kubernetes 與腳本化部署，快速搭建可重現的本地開發基礎設施。
每個工具都提供 Kubernetes（預設）與 Docker Compose（備用）兩套部署方案。

## 專案目標

- 以容器化方式部署開發者工具，避免污染主機環境。
- 以 Kubernetes Deployment 作為預設方案，讓服務掛掉時由 controller 自動重建。
- 提供一鍵啟動／停止腳本，降低安裝與設定成本。
- 集中管理各工具的設定、資料卷與日誌，方便備份與遷移。

## 預定支援的工具

| 工具 | 用途 | 版本 | 狀態 |
| --- | --- | --- | --- |
| GitLab | 自架 Git 程式碼托管與 CI/CD | `19.2.4-ce.0` | 已支援 |
| Harbor | 私有 Container Registry | `v2.15.2` | 已支援 |
| （後續擴充） | 視需求新增，例如 Jenkins、Nexus、MinIO 等 | — | — |

兩個工具皆預設以 **Kubernetes** 部署（`k8s/`），Docker Compose 方案（`docker/`）
保留為備用，兩者資料各自獨立、同一時間只能啟動其中一套。

各服務的映像版本一律**釘選**，不使用浮動的 `:latest`，且**兩套方案的版本必須一致**
——上一輪的 K8s 方案正是因為版本停止跟進、與 Compose 長期不同步而被整套移除。
釘選位置與升級注意事項見「[版本升級](#版本升級)」（`harbor/docker/Dockerfile`
僅為佔位、不參與部署）。

> **CI Runner**：本 repo 不提供 GitLab Runner。GitLab 本身可正常建立 CI/CD pipeline，
> 但沒有 executor 時 job 會停在 pending——請由各 Group 自行建立並註冊所需的 Runner。

## 專案架構

```text
MacDevelopSyStem/
├── README.md              # 專案說明文件
├── .gitignore             # Git 忽略清單
├── plans/                 # 各次改動的實作計畫紀錄（歷史文件，不參與部署）
├── gitlab/                # GitLab 部署設定
│   ├── run.sh             # 啟動入口（預設 K8s；up/logs/stop/status）
│   ├── k8s/               # Kubernetes 方案（預設）
│   │   ├── 00-namespace.yaml    # devops namespace（與 Harbor 共用）
│   │   ├── 01-pv.template.yaml  # hostPath PV，路徑由 apply.sh 代入
│   │   ├── 02-pvc.yaml
│   │   ├── 03-deployment.yaml   # Deployment + initContainer + emptyDir
│   │   ├── 04-service.yaml      # LoadBalancer 8080／2222
│   │   ├── apply.sh             # 套用資源（含佈建方式與 port 衝突檢查）
│   │   ├── delete.sh            # 移除資源（data 保留）
│   │   ├── migrate.sh           # 自 docker/data 遷移既有資料
│   │   └── data/                # 持久化資料（僅 .keep 納入版控）
│   └── docker/            # Docker Compose 方案（備用）
│       ├── build.sh
│       ├── Dockerfile
│       ├── docker-compose.yaml
│       ├── .env.example
│       └── data/          # 持久化資料（僅 .keep 納入版控）
└── harbor/                # Harbor 部署設定
    ├── run.sh             # 啟動入口（預設 K8s；up/logs/stop/status）
    ├── k8s/               # Kubernetes 方案（預設）
    │   ├── 00-namespace.yaml    # devops namespace（與 GitLab 共用）
    │   ├── 01-pv.template.yaml  # hostPath PV，路徑由 apply.sh 代入
    │   ├── 02-pvc.yaml          # 單一 PVC，各 service 以 subPath 取用
    │   ├── 10-redis.yaml        # 10~16 為 8 個 service 的 Deployment 與 Service
    │   ├── 11-postgresql.yaml
    │   ├── 12-registry.yaml     # registry 與 registryctl 同一 Pod
    │   ├── 13-core.yaml
    │   ├── 14-jobservice.yaml
    │   ├── 15-portal.yaml
    │   ├── 16-proxy.yaml        # LoadBalancer 8081
    │   ├── apply.sh             # 套用資源 + 將 env 檔轉為 Secret
    │   ├── build.sh             # 全新建立時以 prepare 產生設定
    │   ├── delete.sh            # 移除資源（data 保留）
    │   ├── migrate.sh           # 自 docker/data 遷移既有資料
    │   └── data/                # 持久化資料（僅 .keep 納入版控）
    └── docker/            # Docker Compose 方案（備用）
        ├── build.sh       # 拉 image + 用 prepare 產生各 service 設定
        ├── Dockerfile
        ├── docker-compose.yaml
        ├── harbor.yml     # Harbor 設定範本（供 prepare 讀取，兩套方案共用）
        ├── .env.example
        └── data/          # 持久化資料（僅 .keep 納入版控）
```

### 資料持久化設計

每套部署方案的持久化資料各自獨立，皆位於該方案目錄下的 `data` 子目錄：

| 工具 | Kubernetes（預設） | Docker Compose（備用） |
| --- | --- | --- |
| GitLab | `gitlab/k8s/data/` | `gitlab/docker/data/` |
| Harbor | `harbor/k8s/data/` | `harbor/docker/data/` |

- 兩套方案都讓資料落在 macOS 本機、可直接備份與遷移：Compose 走 bind mount，
  K8s 走指向同一種路徑的 hostPath PV（`reclaimPolicy: Retain`，移除資源不會清資料）。
- 各本機 `data` 資料夾以 `.keep` 納入版控，實際內容由 `.gitignore` 排除。
- 要把 Compose 版的資料帶進 K8s，用各自的 `k8s/migrate.sh`（來源只讀不刪）。

> 注意事項：
>
> - **兩套方案的資料不會互相同步**。切換到 K8s 之後，Compose 版的 `docker/data`
>   會停在切換當下的狀態；回退等同放棄 K8s 期間的所有異動。
> - 舊版共用資料夾 `gitlab/git_data/`、`harbor/harbor_data/` 已停用並由 `.gitignore` 整夾忽略，
>   確認無需保留後可手動刪除。

## 系統需求

- macOS（Apple Silicon 或 Intel）
- Docker Desktop 或同等容器執行環境
  - 建議分配 ≥ 4 GB RAM 給 Docker（GitLab Omnibus 建議值）
  - 若同時啟用 Harbor，建議 ≥ 6 GB RAM（Harbor 含 8 個 service）
- Kubernetes（預設部署方案所需）
  - Docker Desktop → Settings → Kubernetes → Enable Kubernetes
  - **Cluster provisioning method 必須選 Kubeadm**：該模式下節點就是 Docker
    Desktop VM，VM 透過 virtiofs 掛有 `/Users`，hostPath 才看得到 macOS 上的
    `k8s/data`。若選 kind，節點是 docker 容器、容器內沒有 `/Users`，hostPath 會
    靜默地建出一個空目錄——服務照樣起得來但讀不到任何既有資料。兩支
    `k8s/apply.sh` 會偵測並擋下這種情況。
  - `kubectl`（Docker Desktop 已內建，或 `brew install kubectl`）
- Bash／Zsh

---

## GitLab 部署

GitLab 使用 8080（HTTP）與 2222（SSH）兩個 port。**預設以 Kubernetes 部署**，
Docker Compose 方案保留為備用。

### GitLab：透過 Kubernetes（預設）

要沿用 Docker Compose 版的既有資料，先做一次遷移（來源只讀不刪）：

```bash
cd gitlab
./run.sh docker stop     # 冷停，熱複製會得到不一致的資料
k8s/migrate.sh           # 複製 config 與 data 到 k8s/data，logs 不遷
```

啟動與其他操作：

```bash
./run.sh                 # 等同 k8s/apply.sh
./run.sh logs            # 跟隨 pod log
./run.sh status          # 查看 pod／service／pvc
./run.sh stop            # 移除 Deployment（k8s/data 內的資料保留）
```

- 網頁：<http://localhost:8080>
- SSH：`ssh -p 2222 git@localhost`
- 取得 root 初始密碼（pod Ready 後可用，沿用既有資料時此檔可能已不存在）：

  ```bash
  kubectl -n devops exec deploy/gitlab -- cat /etc/gitlab/initial_root_password
  ```

- 持久化資料位置：`gitlab/k8s/data/{config,logs,data}`（已於 `.gitignore` 排除）

> **`config/gitlab-secrets.json` 是遷移的關鍵**：資料庫內所有加密欄位（CI 變數、
> 2FA、整合權杖）都靠它解密，漏掉它即使資料庫完整也等於報廢。`migrate.sh` 會連同
> 整個 `config/` 一起複製，不要只挑 `data/` 搬。

### GitLab：透過 Docker Compose（備用）

```bash
cd gitlab
./run.sh docker          # 等同 docker compose up -d
./run.sh docker logs     # 跟隨 container log
./run.sh docker status   # 查看狀態
./run.sh docker stop     # 停止 GitLab
```

若需重新建置本地 image：

```bash
cd gitlab/docker
./build.sh               # 等同 docker compose build --pull
```

- 取得 root 初始密碼：`docker exec gitlab cat /etc/gitlab/initial_root_password`
- 持久化資料位置：`gitlab/docker/data/{config,logs,data}`（已於 `.gitignore` 排除）

> 首次啟動 GitLab 需 3–5 分鐘完成自我初始化。K8s 方案下 pod 會停在 `0/1 Running`
> 直到 readiness 探針通過；Docker Compose 方案下 `docker ps` 會顯示
> `health: starting`。兩者都請耐心等待。

> 資源設定（最小化）：已設容器記憶體上限 4G，並以單進程 Puma 運行、關閉內建
> Registry（改用 Harbor）／KAS／Prometheus 監控，實測常駐約 3–3.3 GB（含 Gitaly
> `runtime_dir` 的 tmpfs 約 130 MB，該用量計入本容器的 cgroup）。適合輕量備份倉庫
> 用途；屬開發取向、非生產規格。

### macOS bind mount 的限制與因應

> **這一節對兩套方案同樣適用。** K8s 方案的 hostPath PV 指向的是
> `gitlab/k8s/data`，掛的仍是同一個 virtiofs，限制一項也沒少。因此
> `03-deployment.yaml` 把 Compose 的六項 socket 覆寫原樣移植，五個 tmpfs 改用
> `emptyDir{medium: Memory}`；`emptyDir` 無法像 docker tmpfs 那樣指定
> uid/gid/mode，權限改由 initContainer 補上。setgid 的修正（第 3 項）同樣無法在
> 容器內完成，改由 `k8s/apply.sh` 在 macOS 端執行。

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

**所有元件的 socket 都已從根本移出 virtiofs**，不再倚賴啟動前清理：

| 元件 | 作法 | 設定位置 |
| --- | --- | --- |
| PostgreSQL | socket 目錄改掛容器內 tmpfs `/run/postgresql` | `docker-compose.yaml` |
| Redis | socket 目錄改掛容器內 tmpfs `/run/gitlab-redis` | `docker-compose.yaml` |
| Rails（Puma） | 停用 unix socket，Workhorse 改連既有的 `tcp://127.0.0.1:8080` | `docker-compose.yaml` |
| Workhorse | `sockets_directory` 改指向 tmpfs `/run/gitlab-workhorse` | `docker-compose.yaml` |
| Gitaly | `socket_path` 改為 tmpfs 上的 `/run/gitaly/gitaly.socket`，`runtime_dir` 改指向 `/run/gitaly-runtime` | `docker-compose.yaml` |

資料庫檔案、Redis 的 RDB、Git repositories 仍留在 `data/data`，持久化不受影響。

### 事故紀錄：Workhorse 與 Gitaly 為何最後才搬

Workhorse 與 Gitaly 原本留在掛載區，理由是「實測可自行重建」。2026-08-22 11:42
至 08-28 16:51 的連續 502（約 6.5 天）推翻了這個判斷：

- Workhorse 以 `shutting down: remove ...: operation not supported` 每秒崩潰一次，
  nginx 的 upstream 就是那個 socket，每個請求都是 502。單日最高 82,377 次失敗。
- Gitaly 撞的是同一個限制（`unable to start the bootstrap: unlinkat ...:
  operation not supported`），單一輪替日誌最高 45,288 次失敗。它靠 runit 每秒重試
  偶爾能撞過去——**那是運氣，不是設計**，先前的「可自行重建」正是誤讀了這個現象。
- 官方 image 的 `clean_stale_pids()` 救不了：它只刪 `pid`、`*.pid` 與 `socket.?`，
  `socket` 與 `gitaly.socket` 兩個檔名都不匹配。
- 容器主行程 `runsvdir` 全程存活，`restart: always` 完全不介入；`run.sh` 的清理
  又只在容器未運行時執行，而 daemon 重啟根本不走 `run.sh`。三層機制同時失效。

搬移 Gitaly 的 `runtime_dir` 有兩個代價，調整設定時務必留意：

- **tmpfs 必須明確加 `exec`。** Docker 的 `tmpfs:` 預設帶 `noexec`，而 gitaly
  每次啟動會把約 129 MB 的輔助執行檔（`gitaly-hooks`、`gitaly-git-*` 等）解壓到
  `runtime_dir`，之後每個 git 操作都要從那裡 exec。漏了 `exec` 會讓 git 全掛。
- **tmpfs 佔用計入容器的 4G cgroup 上限。** 五個 tmpfs 中只有 `/run/gitaly-runtime`
  設了 `size=512m`（其餘只放 socket，用量可忽略）。這道上限是本次新引入的失效模式：
  一旦寫滿，gitaly 解壓輔助執行檔會得到 `ENOSPC` 而起不來，日後 gitaly 版本增加
  輔助執行檔時須同步調高。

搬移後舊的 `data/data/gitaly/run/gitaly-<pid>/` 不會再被使用，但也不會被自動清除
（`clean_stale_state()` 只刪 `-type s`）。確認服務正常後可一次性回收那約 129 MB：

```bash
cd gitlab && ./run.sh stop
rm -rf docker/data/data/gitaly/run docker/data/data/gitlab-workhorse
./run.sh
```

Rails 那一項的細節：GitLab 的 puma 本來就同時 bind unix socket 與
`tcp://127.0.0.1:8080`，因此停用 unix bind 不減少任何能力。設定上
`puma['socket']` 給**空字串**即可（範本以 `!listen_socket.empty?` 決定是否 bind），
並須**明確指定** `gitlab_workhorse['auth_backend']`，omnibus 才會把 workhorse 的
`auth_socket` 設為 `nil`（見容器內 `libraries/puma.rb` 與 `libraries/gitlab_workhorse.rb`）；
該值與內建預設相同，有意義的是「指定」這個動作本身。

`run.sh` 的 `clean_stale_state()` 承擔兩件事：啟動前清除 `data/data` 內殘留的
unix socket，並將 `git-data/repositories` 補回 `2770`。

socket 清理**已降級為防呆**——四個元件的 socket 都搬走後，掛載區正常情況下不會
再出現 socket。保留它是為了回收搬移前的孤兒檔、在設定被回滾時兜底，以及日後若有
元件把 socket 放回掛載區能及早發現。`2770` 那半段則仍然必要：setgid 是 virtiofs
的三項限制中唯一無法從設定面解決的。

注意**這道清理只在手動執行 `run.sh` 時發生**，且**僅在 GitLab 容器未運行時執行**。
guard 一併保留：設定若被回滾，掛載區會重新出現互連用的活 socket，刪掉會使新連線
全數失敗，而 `docker compose up -d` 對運行中的容器不會重啟、不會重建 socket，
服務將無法自癒。

若仍遇到啟動失敗，先檢查這條不變式——**不分容器狀態**，掛載區都不該有任何 socket：

```bash
find gitlab/docker/data/data -type s         # 應無輸出（容器運行中也一樣）
```

> 此不變式要等 `clean_stale_state()` 至少跑過一次才成立。套用上述設定變更時請走
> `./run.sh stop && ./run.sh`——直接 `docker compose up -d` 雖然會 recreate 容器並
> 讓新設定生效，卻會把搬移前的孤兒 socket 原封不動留在掛載區，之後檢查這條不變式
> 就會得到假警報。

有輸出就代表某個元件的 socket 又落回 virtiofs，回頭核對上表的設定。接著確認
socket 確實建在 tmpfs、且 `runtime_dir` 沒有被加上 `noexec`：

```bash
docker exec gitlab ls -l /run/gitlab-workhorse/socket /run/gitaly/gitaly.socket
docker exec gitlab sh -c 'mount | grep -E "/run/(gitlab-workhorse|gitaly)"'
```

---

## Harbor 部署

Harbor 為私有 Container Registry，包含 8 個 service（registry / registryctl /
postgresql / redis / core / portal / jobservice / proxy），版本固定 `v2.15.2`，
對外使用 8081 一個 port。**預設以 Kubernetes 部署**，Docker Compose 方案保留為備用。

### Harbor：透過 Kubernetes（預設）

首次啟動前必須先備妥 `k8s/data`，兩條路擇一：

```bash
cd harbor/k8s
./migrate.sh             # 沿用 Docker Compose 版的既有資料（須先停掉 Compose 版）
# 或
./build.sh               # 全新建立：拉 image 並用 prepare 產生設定與金鑰
```

> 兩者**不可混用**：`build.sh` 會產生全新的加密金鑰，與既有資料庫的內容對不起來。
> 已經有資料要沿用就只跑 `migrate.sh`。

啟動與其他操作：

```bash
cd harbor
./run.sh                 # 等同 k8s/apply.sh
./run.sh logs            # 跟隨所有 pod 的 log
./run.sh status          # 查看 pod／service／pvc
./run.sh stop            # 移除 Deployment（k8s/data 內的資料保留）
```

- 網頁：<http://localhost:8081>
- 持久化資料位置：`harbor/k8s/data/`（已於 `.gitignore` 排除）
- 八個 service 各自是一個 Deployment，全部位於 `devops` namespace

> K8s 的 Service 名嚴格對齊 Compose 的 service 名（`core`、`redis`、`postgresql`…），
> 因為 prepare 產生的設定裡寫的就是這些位址（`core:8080`、`redis:6379`）。
> 改動 Service 名會讓整套設定失效。

### Harbor：透過 Docker Compose（備用）

首次啟動前必須先拉 image 並產生各 service 設定：

```bash
cd harbor/docker
./build.sh               # 拉 v2.15.2 image，並用 prepare 產生 ./data/config/
```

啟動：

```bash
cd harbor
./run.sh docker          # 等同 docker compose up -d
```

其他操作：

```bash
./run.sh docker logs     # 跟隨所有 service log
./run.sh docker status   # 查看狀態
./run.sh docker stop     # 停止 Harbor
```

- 持久化資料位置：`harbor/docker/data/`（已於 `.gitignore` 排除）

### 共通存取資訊

- 網頁：<http://localhost:8081>
- 預設帳號：`admin` / `Harbor12345`
- **⚠ 首次登入後請立即修改密碼。**

> 修改 `harbor/docker/harbor.yml` 後，必須重新執行對應方案的 `build.sh` 讓 prepare
> 重生設定，再 `./run.sh stop && ./run.sh` 才會生效。兩套方案共用同一份 `harbor.yml`
> ——hostname、port 與 external_url 在兩邊完全相同，沒有需要分岔的欄位。

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
在 K8s 方案下兩者共用 `devops` namespace，以 `app.kubernetes.io/name` 標籤區分。

> **注意**：`devops` 是共用的 namespace，`kubectl delete namespace devops` 會把
> GitLab 與 Harbor 一起刪掉。兩邊的 `k8s/delete.sh` 因此一律以 label selector
> 精確指定自己的資源，不碰 namespace 本身。

---

## 開機自動啟動與自動修復

Harbor 與 GitLab 於主機重開機後自動恢復，意外掛掉也會自動重啟。兩套方案各有機制：

| 方案 | 恢復機制 | 涵蓋範圍 |
| --- | --- | --- |
| Kubernetes（預設） | Deployment controller + 探針 | pod 掛掉重建；**探針失敗也會重建** |
| Docker Compose（備用） | `restart: always` | 僅容器主行程退出時重啟 |

差別在最後一欄：K8s 連「行程活著但服務死了」都救得回來，`restart: always` 不會。

改用 K8s 作為預設方案的主因就在最後一欄：GitLab 曾發生過容器 `Up`、對外卻連續
502 長達 6.5 天的事故，正是因為 runsvdir（PID 1）始終存活，`restart: always`
從頭到尾都沒有介入的餘地（見[事故紀錄](#事故紀錄workhorse-與-gitaly-為何最後才搬)）。
K8s 的 liveness 探針打的是 `/-/health`，這種「行程活著但服務死了」的狀態會被判定為
失敗並重建 pod。

以下這一整章描述的是**備用的 Docker Compose 方案**的機制，其設計約束仍然成立，
維護 `docker/` 底下的設定時請一併遵守。K8s 方案不受這些限制（沒有 logging driver
的跨容器依賴，啟動順序也由探針處理），但仍**需要 Docker Desktop 於登入時自啟**，
否則 Kubernetes 叢集本身不會啟動。

Docker Compose 方案的機制**完全依賴 Docker 內建能力**，不需要安裝任何常駐程式或排程工具。

實測結果（2026-08-21，完整重啟 Docker Desktop 驗證，全程未執行任何救援指令）：

| 服務 | 容器自動恢復 | 服務可用 |
| --- | --- | --- |
| Harbor（8 個容器） | ✅ | ✅ UI／API 皆 200，7 個 component 全 healthy |
| GitLab | ✅ | ✅ 約 30 秒後 HTTP 200、healthcheck 轉 healthy |

過程中 `nginx`（Harbor proxy）與 `harbor-jobservice` 因啟動競態各崩潰過
1 次與 3 次（`RestartCount` 為 1、3），皆由 `restart: always` 自動拉回，
無須人工介入——這正是本機制要達成的效果。

兩個構成要件：

| 要件 | 設定位置 | 作用 |
| --- | --- | --- |
| Docker Desktop 登入自啟 | Docker Desktop → Settings → General | 開機後拉起 Docker daemon |
| `restart: always` | 兩個服務的 `docker-compose.yaml` | daemon 就緒後恢復容器；容器內主行程一退出就重啟（不看 exit code） |

> **前提**：Docker Desktop 須勾選 "Start Docker Desktop when you sign in"，
> 否則重開機後 daemon 不會啟動，容器自然無從恢復。這是唯一需要手動確認的設定。

驗證目前狀態：

```bash
# Docker Desktop 是否設為登入自啟（應為 true）
grep AutoStart ~/Library/Group\ Containers/group.com.docker/settings-store.json

# 兩個服務的 restart policy（應全為 always）
docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' \
  gitlab harbor-core
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

現行設定已把**所有元件**的 socket 移出掛載區（見〈[macOS bind mount 的限制與因應](#macos-bind-mount-的限制與因應)〉），
因此 daemon 重啟後 GitLab 可完全自行恢復。

> 判準是「socket 是否落在 `/var/opt/gitlab` 底下」，**不是**「實測有沒有恢復」。
> Gitaly 曾因為靠 runit 每秒重試偶爾能撞過去，被誤判為可自行重建，代價是一次
> 長達 6.5 天的 502（見上述事故紀錄）。

若日後仍遇到啟動後持續 502，依序檢查這幾處即可定位。注意 `current` 會被 svlogd
輪替，用 `grep -c` 比 `tail` 可靠：

| 檢查點 | 指令 | 正常表現 |
| --- | --- | --- |
| 元件是否反覆重啟 | `docker exec gitlab gitlab-ctl status` | 各服務存活秒數持續增長，不會反覆歸零 |
| 掛載區是否又有 socket | `find gitlab/docker/data/data -type s` | 無輸出 |
| Workhorse 自身 socket | `docker exec gitlab grep -c 'shutting down: remove' /var/log/gitlab/gitlab-workhorse/current \|\| true` | `0` |
| Gitaly 自身 socket | `docker exec gitlab grep -c 'unable to start the bootstrap' /var/log/gitlab/gitaly/current \|\| true` | `0` |
| Redis | `docker exec gitlab grep -c 'Failed opening Unix socket' /var/log/gitlab/redis/current \|\| true` | `0` |
| PostgreSQL | `docker exec gitlab grep -c 'could not set permissions' /var/log/gitlab/postgresql/current \|\| true` | `0` |

兩個細節：`grep -c` 在計數為 0 時 exit code 是 `1`，貼進 `set -e` 的腳本會被誤判成
失敗，故上表補了 `|| true`。另外**別用寬鬆的 `operation not supported` 當關鍵字**
——gitaly 每次正常啟動都會記一筆良性的 `Unable to set SO_REUSEPORT`（unix socket
不支援該選項，只影響零停機升級），拿它當判準會恆為 `1`。上表改用各元件實際的
失敗訊息。

真的卡住時，走一次完整流程讓 `run.sh` 的 socket 清理有機會執行：

```bash
cd gitlab && ./run.sh stop && ./run.sh
```

### 查看 log

Harbor 不再有集中式的 `harbor/docker/data/log/*.log`（該目錄下的既有檔案為改版前的殘留，
不再更新）。改用 Docker 原生方式：

Kubernetes（預設）：

```bash
kubectl -n devops logs deploy/core --tail 50    # 單一 service
kubectl -n devops logs -f deploy/gitlab         # 跟隨
cd harbor && ./run.sh logs                      # 該服務全部 pod
```

Docker Compose（備用）：

```bash
docker logs harbor-core --tail 50     # 單一容器
docker logs -f gitlab                 # 跟隨
cd harbor && ./run.sh docker logs     # 該服務全部容器
```

### 手動停用服務

`docker stop` 與 `docker kill` 都會被 daemon 記為「使用者主動停止」，
所以容器**當下不會**被 restart policy 拉回；但 `always` 在 daemon 重啟時會忽略這個標記，
把容器一併恢復——這正是 `always` 與 `unless-stopped` 的唯一差別，也是本專案選 `always` 的理由：
只要曾經手動停過一次，`unless-stopped` 的容器就再也不會在重開機時自己回來。

因此要長期停用某個服務，請用 `run.sh stop`，容器／pod 被移除後就完全不受 restart
policy 或 Deployment controller 影響：

```bash
cd harbor && ./run.sh stop           # Kubernetes：移除 Deployment（資料保留）
cd harbor && ./run.sh docker stop    # Docker Compose：等同 docker compose down
```

這一整段（含下方的崩潰自愈測試）談的是 Docker Compose 方案的 restart policy。
K8s 方案下對應的機制是 Deployment controller：`kubectl delete pod` 會被立刻重建，
要真正停用只能移除 Deployment 本身，也就是 `./run.sh stop` 做的事。

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

各工具皆提供 `run.sh` 作為啟動入口。**預設方案為 Kubernetes**，要操作備用的
Docker Compose 方案就在動作前加上 `docker`：

```bash
# 啟動 GitLab（Kubernetes）
cd gitlab
./run.sh

# 啟動 Harbor（Kubernetes；首次須先 ./k8s/migrate.sh 或 ./k8s/build.sh）
cd harbor
./run.sh

# 改用 Docker Compose 啟動（首次須先 ./docker/build.sh）
./run.sh docker
```

四個動作在兩套方案下語意相同：

| 動作 | Kubernetes（預設） | Docker Compose（`./run.sh docker …`） |
| --- | --- | --- |
| `up`（可省略） | `k8s/apply.sh` | `docker compose up -d` |
| `logs` | `kubectl logs -f` | `docker compose logs -f` |
| `stop` | `k8s/delete.sh`（資料保留） | `docker compose down` |
| `status` | `kubectl get pods,svc,pvc` | `docker compose ps` |

> 兩套方案搶同一組 port（GitLab 8080／2222、Harbor 8081），**同一時間只能啟動其中一套**。
> `k8s/apply.sh` 會在啟動前檢查 Compose 版是否仍在運行，衝突時直接擋下並提示先停掉。

## 版本升級

映像版本在兩套方案中各有釘選位置，升級時**必須同時改**，否則兩邊會跑在不同版本上：

| 服務 | 方案 | 釘選位置 |
| --- | --- | --- |
| GitLab | K8s | `k8s/03-deployment.yaml` 的 `image` |
| GitLab | Compose | `docker/Dockerfile` 的 `FROM` |
| Harbor | K8s | `k8s/1*.yaml` 的各 `image`、`k8s/build.sh` 的 `HARBOR_VERSION` |
| Harbor | Compose | `docker/docker-compose.yaml` 的 8 個 tag 與 `build.sh` |

升級流程：K8s 走「改檔 → `./run.sh stop` → `./run.sh`」；Docker Compose 走
「改檔 → `./docker/build.sh` → `./run.sh docker`」。無論走哪一套，升級前都要把對應的
`data/` 目錄備份到 repo 之外。

### GitLab

GitLab 有**必經升級停點**：跨越停點的一次性升級會導致資料庫遷移失敗。停點清單以官方
repo 的 `config/upgrade_path.yml` 為準（19.x 為 19.2、19.5、19.8、19.11），升級前務必查閱，
必要時分段升級。這也是不使用 `:latest` 的原因——浮動 tag 可能在某次重拉時一口氣跨過停點。

升級前確認背景遷移已全數完成，否則新版遷移會與未完成的舊遷移衝突：

```bash
kubectl -n devops exec deploy/gitlab -- gitlab-rails runner \
  'puts Gitlab::Database::BackgroundMigration::BatchedMigration.where.not(status: 3).count'
```

> Docker Compose 方案下把前綴換成 `docker exec gitlab`，後面的參數完全相同。

升級後同樣以上述指令確認收斂為 `0`（大版本升級後背景遷移可能持續數十分鐘）。

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
  # Kubernetes（預設）
  kubectl -n devops exec deploy/postgresql -- reindexdb --all --username postgres

  # Docker Compose（備用）
  docker exec harbor-db reindexdb --all --username postgres
  ```

  備份對象同樣要看方案：K8s 是 `harbor/k8s/data`，Docker Compose 是 `harbor/docker/data`。

升級期間請用 `./run.sh stop` 停用服務。K8s 方案下這會移除 Deployment，pod 不再被
controller 重建；Docker Compose 方案下等同 `docker compose down`，容器被移除後不受
`restart: always` 影響。兩者都不會在流程中途被拉回；升級完成後再 `./run.sh` 啟動。

## 授權

尚未指定，預設保留所有權利。

## 維護者

- [@nk7260ynpa](https://github.com/nk7260ynpa)
