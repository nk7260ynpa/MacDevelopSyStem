# MacDevelopSyStem

本專案用於在 macOS 上建立基本開發環境，包含常見的開發者工具（如 GitLab、Harbor 等），
透過 Docker 與腳本化部署，快速搭建可重現的本地開發基礎設施。

## 專案目標

- 以容器化（Docker）方式部署開發者工具，避免污染主機環境。
- 提供一鍵啟動／停止腳本，降低安裝與設定成本。
- 集中管理各工具的設定、資料卷與日誌，方便備份與遷移。

## 預定支援的工具

| 工具 | 用途 | 狀態 |
| --- | --- | --- |
| GitLab | 自架 Git 程式碼托管與 CI/CD | 已支援（Docker Compose、K8s） |
| Harbor | 私有 Container Registry | 已支援（Docker Compose、K8s） |
| GitLab Runner | GitLab CI/CD 任務執行器（docker executor） | 已支援（Docker Compose） |
| （後續擴充） | 視需求新增，例如 Jenkins、Nexus、MinIO 等 | — |

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
├── gitlab-runner/         # GitLab Runner 部署設定（CI/CD 執行器）
│   ├── run.sh             # 入口：register/up/logs/stop/status
│   └── docker/            # Docker Compose 方案（docker executor）
│       ├── build.sh
│       ├── Dockerfile
│       ├── docker-compose.yaml
│       ├── .env.example   # CI_SERVER_URL / RUNNER_TOKEN 等
│       └── data/          # Runner 設定 config.toml（僅 .keep 納入版控）
└── logs/                  # 各工具運行日誌（執行時建立）
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
./build.sh               # 等同 docker compose pull && docker compose build
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

Harbor 為私有 Container Registry，包含 8 個 service（log / registry / registryctl /
postgresql / redis / core / portal / jobservice / proxy），與 GitLab 一樣提供
Docker Compose 與 K8s 兩種方案。版本固定 `v2.11.0`。

### 透過 Docker Compose

首次啟動前必須先拉 image 並產生各 service 設定：

```bash
cd harbor/docker
./build.sh               # 拉 v2.11.0 image，並用 prepare 產生 ./data/config/
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
- **log 就緒把關**：各 service 以 syslog driver 將 log 送往 `harbor-log:1514`，故其 `depends_on`
  對 `log` 採 `condition: service_healthy`，等 harbor-log 真正就緒才啟動，避免冷啟動時
  `logging driver: connection refused`（在 Apple Silicon 以模擬執行 amd64 image 時尤其關鍵）。
- **registry 的 `root.crt`**：改由 registry 設定目錄一併掛入，不另以單檔疊掛，以避開
  virtiofs「於目錄掛載上再疊單檔掛載」的 mountpoint 衝突；此複製動作已內建於 `./build.sh`。

#### 開機自動啟動與守護巡檢（選用）

主機重開機時，Docker daemon 會依各容器的 `restart:always` **各自**恢復容器，此路徑
繞過了 compose 的 `depends_on` 編排，導致眾 service 搶在 `harbor-log` 就緒前啟動，
syslog logging driver 連不上 `1514` 而以 `ExitCode 128` 集體退出（即上述「log 就緒把關」
僅在走 `docker compose up` 時生效，daemon 自動恢復時不生效）。

`harbor/boot/` 提供兩個互補的 macOS LaunchAgent 根治此問題：

- **autostart**（`RunAtLoad`）：使用者登入（主機重開機）後等待 Docker daemon 就緒，
  再走 `run.sh`（`docker compose up -d`）以正確順序拉起，確保 `harbor-log` 先 healthy。
- **watchdog**（`StartInterval` 120s）：補強 autostart 的盲區——Docker daemon 若**單獨
  重啟**（Docker Desktop 更新、手動重啟、daemon 崩潰恢復）並不會重新登入、故不觸發
  autostart，此時又落回上述冷啟動競態而僅剩 `harbor-log` 存活、其餘集體陣亡無人拉回。
  watchdog 定期巡檢，偵測「容器存在卻未全數 running」即以 `run.sh` 依正確順序補起；
  容器完全不存在（多為人為 `down`）時則不動作，以免違背意願拉起。兩者共用 mkdir
  原子鎖，避免登入瞬間並發 `compose` 衝突。

```bash
cd harbor/boot
./install.sh             # 安裝並載入兩個 LaunchAgent（autostart + watchdog）
./uninstall.sh           # 停用並移除（不影響執行中的容器）
```

| 檔案 | 說明 |
| --- | --- |
| `harbor-autostart.sh` | 登入觸發：輪詢等待 Docker daemon（上限 300s）後執行 `run.sh` |
| `harbor-watchdog.sh` | 定期巡檢（120s）：容器未全數 running 即以 `run.sh` 補起 |
| `com.chen.harbor-autostart.plist` | autostart 範本（`RunAtLoad`），`__HARBOR_DIR__` 由 `install.sh` 替換 |
| `com.chen.harbor-watchdog.plist` | watchdog 範本（`StartInterval`），同上替換 |
| `install.sh` / `uninstall.sh` | 一併安裝（`launchctl bootstrap`）／卸載（`launchctl bootout`）兩個 agent |

```bash
# 不必重開機，立即手動測試一次（停一個容器，watchdog 應自動補回）
launchctl kickstart -k gui/$(id -u)/com.chen.harbor-watchdog
tail -f harbor/logs/harbor-watchdog.log      # 觀察執行記錄
```

> log 寫於 `harbor/logs/`（已於 `.gitignore` 排除）。

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

## 授權

尚未指定，預設保留所有權利。

## 維護者

- [@nk7260ynpa](https://github.com/nk7260ynpa)
