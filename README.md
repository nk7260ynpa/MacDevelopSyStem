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
| （後續擴充） | 視需求新增，例如 Jenkins、Nexus、MinIO 等 | — |

## 專案架構

```text
MacDevelopSyStem/
├── README.md              # 專案說明文件
├── .gitignore             # Git 忽略清單
├── gitlab/                # GitLab 部署設定
│   ├── run.sh             # Docker Compose 啟動入口（up/logs/stop/status）
│   ├── git_data/          # 持久化資料（Docker 與 K8s 共用，僅 .keep 納入版控）
│   ├── docker/            # Docker Compose 方案
│   │   ├── build.sh
│   │   ├── Dockerfile
│   │   ├── docker-compose.yaml
│   │   └── .env.example
│   └── k8s/               # Kubernetes 原生 Manifests 方案
│       ├── apply.sh
│       ├── delete.sh
│       ├── pv.template.yaml  # hostPath PV 範本（apply.sh 注入本機絕對路徑）
│       ├── 00-namespace.yaml
│       ├── 01-pvc.yaml
│       ├── 02-deployment.yaml
│       └── 03-service.yaml
├── harbor/                # Harbor 部署設定
│   ├── run.sh             # Docker Compose 啟動入口（up/logs/stop/status）
│   ├── harbor_data/       # 持久化資料（Docker 與 K8s 共用，僅 .keep 納入版控）
│   ├── docker/            # Docker Compose 方案
│   │   ├── build.sh       # 拉 image + 用 prepare 產生各 service 設定
│   │   ├── Dockerfile
│   │   ├── docker-compose.yaml
│   │   ├── harbor.yml     # Harbor 設定範本（供 prepare 讀取）
│   │   └── .env.example
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
│       └── 10~17-*.yaml   # 8 個 service（log/redis/db/registry/core/...）
└── logs/                  # 各工具運行日誌（執行時建立）
```

### 資料持久化設計

每個工具的持久化資料集中於服務目錄下的專屬資料夾（GitLab → `gitlab/git_data/`、
Harbor → `harbor/harbor_data/`），便於集中備份與遷移：

- **Docker Compose**：以 bind mount 直接掛載該資料夾。
- **Kubernetes**：透過 `hostPath` 靜態 PV 綁定「同一份」資料夾；絕對路徑由 `apply.sh`
  於套用時動態注入 `pv.template.yaml`（佔位符 `__GITLAB_DATA__` / `__HARBOR_DATA__`），
  PV 採 `storageClassName: manual` 與 `reclaimPolicy: Retain`。
- 資料夾以 `.keep` 納入版控，實際內容由 `.gitignore` 排除。

> 限制與注意事項：
>
> - K8s 的 hostPath 方案僅適用 **Docker Desktop 內建單節點 K8s**（kind / minikube 的
>   節點檔案系統與 macOS 本機不同，無法直接套用）。
> - Docker 與 K8s 共用同一份資料夾，**請勿同時啟動兩種部署**指向同一工具，避免資料衝突。

## 系統需求

- macOS（Apple Silicon 或 Intel）
- Docker Desktop 或同等容器執行環境
  - 建議分配 ≥ 4 GB RAM 給 Docker（GitLab Omnibus 建議值）
  - 若同時啟用 Harbor，建議 ≥ 6 GB RAM（Harbor 含 8 個 service）
- Bash／Zsh
- 若使用 K8s 方案，需額外具備：
  - `kubectl`
  - 本機 K8s 叢集（Docker Desktop 內建 K8s、kind 或 minikube 擇一）

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

- 持久化資料位置：`gitlab/git_data/{config,logs,data}`（已於 `.gitignore` 排除，K8s 方案共用同一份）

> 首次啟動 GitLab 需 3–5 分鐘完成自我初始化，期間 `docker ps` 會顯示 `health: starting`，請耐心等待。

### 透過 Kubernetes

前置：本機 K8s 叢集已就緒（`kubectl get nodes` 可成功列出節點）。

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
./delete.sh              # 刪除 gitlab namespace 與 hostPath PV（本機 git_data 資料保留）
```

> 本方案的 hostPath PV 綁定 macOS 本機 `gitlab/git_data`，僅適用 **Docker Desktop 內建 K8s**；
> kind / minikube 的節點檔案系統與本機不同，無法直接套用此 PV 設定。

### 兩種方案的取捨

| 比較項目 | Docker Compose | Kubernetes |
| --- | --- | --- |
| 啟動速度 | 較快 | 較慢（需建立 PVC、拉 image） |
| 資源用量 | 較低 | 較高 |
| 與 K8s 工作流整合 | 否 | 是 |
| 適合情境 | 日常本機開發 | 練習 K8s 操作、模擬叢集環境 |

---

## Harbor 部署

Harbor 為私有 Container Registry，包含 8 個 service（log / registry / registryctl /
postgresql / redis / core / portal / jobservice / proxy），與 GitLab 一樣提供
Docker Compose 與 K8s 兩種方案。版本固定 `v2.11.0`。

### 透過 Docker Compose

首次啟動前必須先拉 image 並產生各 service 設定：

```bash
cd harbor/docker
./build.sh               # 拉 v2.11.0 image，並用 prepare 產生 ../harbor_data/config/
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
- 持久化資料位置：`harbor/harbor_data/`（已於 `.gitignore` 排除，K8s 方案共用同一份）

> 修改 `harbor/docker/harbor.yml` 後，必須重新執行 `./build.sh` 讓 prepare 重生設定，
> 再 `./run.sh stop && ./run.sh up` 才會生效。

### 透過 Kubernetes

前置：本機 K8s 叢集已就緒、`kubectl get nodes` 可成功。

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
./delete.sh              # 刪除 harbor namespace 與 hostPath PV（本機 harbor_data 資料保留）
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
```

## 授權

尚未指定，預設保留所有權利。

## 維護者

- [@nk7260ynpa](https://github.com/nk7260ynpa)
