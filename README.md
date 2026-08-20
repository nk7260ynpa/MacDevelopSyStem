# MacDevelopSyStem

本專案用於在 macOS 上建立基本開發環境，包含常見的開發者工具（如 GitLab、Harbor 等），
透過 Docker 與腳本化部署，快速搭建可重現的本地開發基礎設施。

## 專案目標

- 以容器化（Docker）方式部署開發者工具，避免污染主機環境。
- 提供一鍵啟動／停止腳本，降低安裝與設定成本。
- 集中管理各工具的設定、資料卷與日誌，方便備份與遷移。

## 預定支援的工具

| 工具 | 用途 | 版本（Docker Compose 方案） | 狀態 |
| --- | --- | --- | --- |
| GitLab | 自架 Git 程式碼托管與 CI/CD | `19.2.4-ce.0` | 已支援（Docker Compose、K8s） |
| Harbor | 私有 Container Registry | `v2.15.2` | 已支援（Docker Compose、K8s） |
| GitLab Runner | GitLab CI/CD 任務執行器（docker executor） | `v19.2.2` | 已支援（Docker Compose） |
| （後續擴充） | 視需求新增，例如 Jenkins、Nexus、MinIO 等 | — | — |

各服務的映像版本一律**釘選**，不使用浮動的 `:latest`。GitLab 與 Runner 釘選於各自的
`docker/Dockerfile`；Harbor 為多映像架構，實際生效的是 `docker/docker-compose.yaml`
的 8 個 image tag 與 `docker/build.sh` 的 `HARBOR_VERSION`（`harbor/docker/Dockerfile`
僅為佔位、不參與部署）。升級注意事項見「[版本升級](#版本升級)」。

K8s 方案的 manifest 版本獨立維護，目前仍停在 Harbor `v2.11.0` 與 `gitlab-ce:latest`，
與上表不同步。

## 專案架構

```text
MacDevelopSyStem/
├── README.md              # 專案說明文件
├── .gitignore             # Git 忽略清單
├── gitlab/                # GitLab 部署設定
│   ├── run.sh             # Docker Compose 啟動入口（up/logs/stop/status）
│   ├── docker/            # Docker Compose 方案
│   │   ├── build.sh
│   │   ├── Dockerfile
│   │   ├── docker-compose.yaml
│   │   ├── .env.example
│   │   └── data/          # Docker 專屬持久化資料（僅 .keep 納入版控）
│   └── k8s/               # Kubernetes 原生 Manifests 方案
│       ├── apply.sh
│       ├── delete.sh
│       ├── 00-namespace.yaml
│       ├── 01-pvc.yaml    # 採叢集預設 StorageClass 動態建立 PV
│       ├── 02-deployment.yaml
│       └── 03-service.yaml
├── harbor/                # Harbor 部署設定
│   ├── run.sh             # Docker Compose 啟動入口（up/logs/stop/status）
│   ├── docker/            # Docker Compose 方案
│   │   ├── build.sh       # 拉 image + 用 prepare 產生各 service 設定
│   │   ├── Dockerfile
│   │   ├── docker-compose.yaml
│   │   ├── harbor.yml     # Harbor 設定範本（供 prepare 讀取）
│   │   ├── .env.example
│   │   └── data/          # Docker 專屬持久化資料（僅 .keep 納入版控）
│   └── k8s/               # Kubernetes 原生 Manifests 方案
│       ├── apply.sh
│       ├── delete.sh
│       ├── pv.template.yaml  # hostPath PV 範本（apply.sh 注入本機絕對路徑）
│       ├── 00-namespace.yaml
│       ├── 01-pvc.yaml
│       ├── 02-secret.yaml
│       ├── 03-prepare-job.yaml
│       ├── 04-rbac.yaml
│       ├── 05-init-configmaps-job.yaml
│       ├── 10~17-*.yaml   # 8 個 service（log/redis/db/registry/core/...）
│       └── data/          # K8s 專屬持久化資料（僅 .keep 納入版控）
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

Docker Compose 與 Kubernetes **各自擁有獨立的 `data` 資料夾，不共用儲存**，皆位於各方案
子目錄下：

| 工具 | Docker 方案 | K8s 方案 |
| --- | --- | --- |
| GitLab | `gitlab/docker/data/` | 動態 PVC（local-path，不對應本機資料夾） |
| GitLab Runner | `gitlab-runner/docker/data/`（config.toml） | — |
| Harbor | `harbor/docker/data/` | `harbor/k8s/data/`（hostPath） |

- **Docker Compose（GitLab、Harbor）**：以 bind mount 直接掛載自己的 `docker/data`。
- **Kubernetes（GitLab）**：採叢集**預設 StorageClass 動態建立 PV**（如 `rancher.io/local-path`），
  資料由 provisioner 在節點本機卷管理，pod 重啟可持久；**不對應 macOS 可見資料夾**。此做法不受
  節點檔案系統限制，kind / minikube / Docker Desktop K8s 皆適用。
- **Kubernetes（Harbor）**：透過 `hostPath` 靜態 PV 綁定自己的 `harbor/k8s/data`；絕對路徑由
  `apply.sh` 於套用時動態注入 `pv.template.yaml`（佔位符 `__HARBOR_DATA__`），PV 採
  `storageClassName: manual` 與 `reclaimPolicy: Retain`，每個 PV 各綁獨立子目錄、互不重疊。
- 各本機 `data` 資料夾以 `.keep` 納入版控，實際內容由 `.gitignore` 排除。

> 限制與注意事項：
>
> - Harbor K8s 的 hostPath 方案僅適用 **Docker Desktop 內建單節點 K8s**（kind / minikube 的
>   節點檔案系統與 macOS 本機不同，無法直接套用）；GitLab K8s 已改用動態 PVC，無此限制。
> - Docker 與 K8s 為兩份獨立資料，可獨立啟動、互不干擾（同工具的兩種方案 port 已錯開），
>   但兩份資料**不會自動同步**；同一工具在不同方案下視為各自獨立的環境。
> - 舊版共用資料夾 `gitlab/git_data/`、`harbor/harbor_data/` 已停用並由 `.gitignore` 整夾忽略，
>   確認無需保留後可手動刪除。

## 系統需求

- macOS（Apple Silicon 或 Intel）
- Docker Desktop 或同等容器執行環境
  - 建議分配 ≥ 4 GB RAM 給 Docker（GitLab Omnibus 建議值）
  - 若同時啟用 Harbor，建議 ≥ 6 GB RAM（Harbor 含 8 個 service）
- Bash／Zsh
- 若使用 K8s 方案，需額外具備：
  - `kubectl`
  - 本機 K8s 叢集（Docker Desktop 內建 K8s、kind 或 minikube 擇一）
  - K8s manifests 已採**最小資源設定**（開發取向、非生產規格）：GitLab 與 Harbor 的記憶體
    limits 合計約 7 GB（壓縮前約 14 GB），Docker 分配 5–7 GB 即可嘗試啟動兩者；詳見各工具
    的 K8s 章節。

---

## GitLab 部署

GitLab 提供兩種互斥的部署方案，請依需求二擇一啟動（兩者皆使用 8080 / 2222 系列 port）。

### 透過 Docker Compose

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

- 持久化資料位置：`gitlab/docker/data/{config,logs,data}`（已於 `.gitignore` 排除；K8s 方案改用動態 PVC，資料不落在本機資料夾）

> 首次啟動 GitLab 需 3–5 分鐘完成自我初始化，期間 `docker ps` 會顯示 `health: starting`，請耐心等待。

> 資源設定（最小化）：已設容器記憶體上限 4G，並比照 K8s 版以單進程 Puma 運行、關閉內建
> Registry（改用 Harbor）／KAS／Prometheus 監控，常駐約 2.5–3 GB。適合輕量備份倉庫用途；
> 屬開發取向、非生產規格。

#### macOS bind mount 的限制與因應

GitLab 的資料以 bind mount 掛到 `gitlab/docker/data`，而 macOS 上 Docker Desktop
採 virtiofs 分享目錄，對 unix socket 檔案有兩項限制，會讓非正常關機後的 GitLab
陷入無限重啟（`docker ps` 顯示 `Restarting`）：

| 限制 | 症狀 |
| --- | --- |
| 無法 unlink 既有 socket 檔 | Redis／Gitaly／Workhorse 啟動時刪不掉前次殘留的 socket，回報 `Operation not supported` |
| 無法對 socket 檔 chmod | PostgreSQL 建立 socket 後設定權限失敗，回報 `could not set permissions ...: Invalid argument` |
| 不保留 setgid 位元 | `gitlab-ctl reconfigure` 檢查 `git-data/repositories` 需為 `2770` 而中止 |

因應方式（皆已內建，無須手動處理）：

- `run.sh` 於啟動前清除 `data/data` 內殘留的 unix socket，並將
  `git-data/repositories` 補回 `2770`。開機自動啟動同樣經由 `run.sh`，故一併涵蓋。
  此清理**僅在 GitLab 容器未運行時執行**：容器運行中時那些 socket 全是活的
  （Workhorse→Rails、Rails→Gitaly 等元件靠它們互連），刪掉會使新連線全數失敗，
  而 `docker compose up -d` 對運行中的容器不會重啟、不會重建 socket，服務將無法自癒。
- `docker-compose.yaml` 將 PostgreSQL 的 socket 目錄改指向容器內 tmpfs
  （`/run/postgresql`），避開 chmod 限制；資料庫檔案仍留在 `data/data`，不影響持久化。

若仍遇到啟動失敗，可先確認殘留 socket 是否清乾淨。**須在容器停止的狀態下檢查**——
服務正常運行時本來就會有數個活的 socket，那是正常現象，不是殘留：

```bash
docker ps --filter 'name=^gitlab$' --quiet   # 應無輸出（確認容器已停止）
find gitlab/docker/data/data -type s         # 應無輸出
```

### 透過 Kubernetes

前置：本機 K8s 叢集已就緒（`kubectl get nodes` 可成功列出節點）。

> 資源設定（最小化）：為節省本機資源，已關閉 GitLab 內建 Container Registry（改用獨立
> Harbor）、監控（Prometheus／exporter）與 KAS，並以單進程 Puma 運行；resources 為
> requests `250m / 1.5Gi`、limits `2 / 4Gi`（記憶體在最小化基礎上保留維運餘裕，避免
> `gitlab-rails runner`／`console`／`rake` 等臨時行程觸發 `OOMKilled`）。屬開發取向、非生產規格。

套用資源：

```bash
cd gitlab/k8s
./apply.sh
```

監看狀態：

```bash
kubectl -n gitlab get pods -w
```

存取資訊：

- 網頁：<http://localhost:30080>（Docker Desktop K8s 可直接從 localhost 存取 NodePort）
- SSH：`ssh -p 30022 git@localhost`
- 取得 root 初始密碼（pod Running 且 Ready 後可用）：

  ```bash
  kubectl -n gitlab exec deploy/gitlab -- cat /etc/gitlab/initial_root_password
  ```

清除全部資源：

```bash
./delete.sh              # 刪除 gitlab namespace（PVC 與其動態 PV、節點本機卷一併清除）
```

> 本方案的 PVC 採叢集**預設 StorageClass 動態建立 PV**（如 `rancher.io/local-path`），資料由
> provisioner 在節點本機卷管理，**不對應 macOS 可見資料夾**；不受節點檔案系統限制，kind /
> minikube / Docker Desktop K8s 皆適用。刪除 namespace 時 PVC 連同 PV 與資料一併清除。

### 兩種方案的取捨

| 比較項目 | Docker Compose | Kubernetes |
| --- | --- | --- |
| 啟動速度 | 較快 | 較慢（需建立 PVC、拉 image） |
| 資源用量 | 較低 | 較高 |
| 與 K8s 工作流整合 | 否 | 是 |
| 適合情境 | 日常本機開發 | 練習 K8s 操作、模擬叢集環境 |

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

Harbor 為私有 Container Registry，包含 9 個 service（log / registry / registryctl /
postgresql / redis / core / portal / jobservice / proxy），與 GitLab 一樣提供
Docker Compose 與 K8s 兩種方案。Docker Compose 方案版本固定 `v2.15.2`。

### 透過 Docker Compose

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
- 持久化資料位置：`harbor/docker/data/`（已於 `.gitignore` 排除；K8s 方案另有獨立的 `harbor/k8s/data`）

> 修改 `harbor/docker/harbor.yml` 後，必須重新執行 `./build.sh` 讓 prepare 重生設定，
> 再 `./run.sh stop && ./run.sh up` 才會生效。

實作上針對 macOS / Docker Desktop 環境做了三項穩定性處理（皆已內建於設定，平常無需手動介入）：

- **固定 compose 專案名為 `harbor`**：`docker-compose.yaml` 以 `name: harbor` 避免與其他同放在
  `docker/` 目錄、專案名同被推導為 `docker` 的專案互相視為 orphan。
- **log 不跨容器依賴**：各 service 一律以 Docker 內建的 `json-file` driver 寫 log
  （`50m` x 3 輪替），不依賴任何收集用容器。這讓每個容器都能獨立恢復，`restart: always`
  在 daemon 自動恢復時才會真正生效，詳見下方〈開機自動啟動與自動修復〉。
- **registry 的 `root.crt`**：改由 registry 設定目錄一併掛入，不另以單檔疊掛，以避開
  virtiofs「於目錄掛載上再疊單檔掛載」的 mountpoint 衝突；此複製動作已內建於 `./build.sh`。

### 透過 Kubernetes

前置：本機 K8s 叢集已就緒、`kubectl get nodes` 可成功。

> 資源設定（最小化）：8 個 service 的 resources 已調降（limits 記憶體合計約 2.9 GB），並降低
> jobservice 背景 worker（10→1）與 PostgreSQL 連線數上限（900→50）。屬開發取向、非生產
> 規格；若某 service 因資源不足而不穩，可回調其對應 limit（如 PostgreSQL 記憶體調回 `1Gi`）。

套用資源：

```bash
cd harbor/k8s
./apply.sh
```

`apply.sh` 共四階段：

1. 建立 Namespace / hostPath PV / PVC / Secret / RBAC
2. 執行 `harbor-prepare` Job（用 `goharbor/prepare` 產生各 service 設定）
3. 執行 `harbor-init-configmaps` Job（將 prepare 產出之 env 檔轉為 K8s Secret）
4. 部署 8 個 service

監看狀態：

```bash
kubectl -n harbor get pods -w
```

存取資訊：

- 網頁：<http://localhost:30081>（Docker Desktop K8s 可直接從 localhost 存取）
- 預設帳號：`admin` / `Harbor12345`

清除全部資源：

```bash
./delete.sh              # 刪除 harbor namespace 與 hostPath PV（本機 k8s/data 資料保留）
```

> 注意：K8s 方案功能完整但流程較長，僅 prepare 與 init Job 即需 1-2 分鐘；後續 8 個 service
> 各自起 pod 需再 2-3 分鐘。若僅作本機日常使用，建議優先選擇 Docker Compose 方案。

### 與 GitLab 同時啟動

Harbor port 8081 / 30081 已刻意錯開 GitLab 的 8080 / 30080，兩者可同時運行
（記憶體建議 ≥ 6 GB）。

---

## 開機自動啟動與自動修復

Harbor、GitLab、GitLab Runner 於主機重開機後自動恢復，意外掛掉也會自動重啟。
機制**完全依賴 Docker 內建能力**，不需要安裝任何常駐程式或排程工具。

兩個構成要件：

| 要件 | 設定位置 | 作用 |
| --- | --- | --- |
| Docker Desktop 登入自啟 | Docker Desktop → Settings → General | 開機後拉起 Docker daemon |
| `restart: always` | 三個服務的 `docker-compose.yaml` | daemon 就緒後恢復容器；容器非正常退出時自動重啟 |

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

### GitLab 的已知限制：重開機後可能需手動救援

GitLab 的 `gitlab/run.sh` 在啟動前會執行 `clean_stale_state()`，清除前次殘留的 unix socket
並修正 `git-data/repositories` 的 setgid 權限——這是 macOS virtiofs 環境的必要處理，
容器內無法自行 unlink 這些 socket。

但**主機重開機時 daemon 是直接 start 既有容器，不會走 `run.sh`**，所以這道清理不會執行。
多數情況下 GitLab 能正常恢復，若不幸落入重啟迴圈（`docker ps` 顯示 gitlab 反覆 Restarting），
手動走一次完整流程即可：

```bash
cd gitlab && ./run.sh stop && ./run.sh
```

Harbor 與 Runner 無此限制。

### 查看 log

Harbor 不再有集中式的 `harbor/docker/data/log/*.log`（該目錄下的既有檔案為改版前的殘留，
不再更新）。改用 Docker 原生方式：

```bash
docker logs harbor-core --tail 50     # 單一容器
docker logs -f gitlab                 # 跟隨
cd harbor && ./run.sh logs            # 該服務全部容器
```

### 手動停用服務

`restart: always` 意味著手動 `docker stop` 後，重開機時容器仍會被拉起。
要長期停用某個服務，請用 `run.sh stop`（等同 `docker compose down`），
容器被移除後就不受 restart policy 影響：

```bash
cd harbor && ./run.sh stop
```

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
