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
| Harbor | 私有 Container Registry | 規劃中 |
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
│   │   └── data/          # 持久化資料（執行時建立，不納入版本控制）
│   └── k8s/               # Kubernetes 原生 Manifests 方案
│       ├── apply.sh
│       ├── delete.sh
│       ├── 00-namespace.yaml
│       ├── 01-pvc.yaml
│       ├── 02-deployment.yaml
│       └── 03-service.yaml
├── harbor/                # Harbor 部署設定（規劃中）
│   └── docker/
│       ├── build.sh
│       ├── Dockerfile
│       └── docker-compose.yaml
└── logs/                  # 各工具運行日誌（執行時建立）
```

## 系統需求

- macOS（Apple Silicon 或 Intel）
- Docker Desktop 或同等容器執行環境
  - 建議分配 ≥ 4 GB RAM 給 Docker（GitLab Omnibus 啟動建議值）
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

- 持久化資料位置：`gitlab/docker/data/{config,logs,data}`（已於 `.gitignore` 排除）

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
./delete.sh              # 刪除 gitlab namespace（連同其下所有 PVC 與資源）
```

> kind / minikube 使用者：
>
> - kind：建立叢集時請在 `kind-config.yaml` 內加上 `extraPortMappings`，將 30080 / 30022 對應到 host。
> - minikube：執行 `minikube service -n gitlab gitlab --url` 取得實際存取 URL。

### 兩種方案的取捨

| 比較項目 | Docker Compose | Kubernetes |
| --- | --- | --- |
| 啟動速度 | 較快 | 較慢（需建立 PVC、拉 image） |
| 資源用量 | 較低 | 較高 |
| 與 K8s 工作流整合 | 否 | 是 |
| 適合情境 | 日常本機開發 | 練習 K8s 操作、模擬叢集環境 |

---

## 使用方式

各工具皆預期提供 `run.sh` 作為啟動入口，使用方式如下：

```bash
# 啟動 GitLab（Docker Compose 方案）
cd gitlab
./run.sh
```

## 授權

尚未指定，預設保留所有權利。

## 維護者

- [@nk7260ynpa](https://github.com/nk7260ynpa)
