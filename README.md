# MacDevelopSyStem

本專案用於在 macOS 上建立基本開發環境，包含常見的開發者工具（如 GitLab、Harbor 等），
透過 Docker 與腳本化部署，快速搭建可重現的本地開發基礎設施。

## 專案目標

- 以容器化（Docker）方式部署開發者工具，避免污染主機環境。
- 提供一鍵啟動／停止腳本，降低安裝與設定成本。
- 集中管理各工具的設定、資料卷與日誌，方便備份與遷移。

## 預定支援的工具

| 工具 | 用途 |
| --- | --- |
| GitLab | 自架 Git 程式碼托管與 CI/CD |
| Harbor | 私有 Container Registry |
| （後續擴充） | 視需求新增，例如 Jenkins、Nexus、MinIO 等 |

## 專案架構

```text
MacDevelopSyStem/
├── README.md              # 專案說明文件
├── .gitignore             # Git 忽略清單
├── gitlab/                # GitLab 部署設定（規劃中）
│   └── docker/
│       ├── build.sh
│       ├── Dockerfile
│       └── docker-compose.yaml
├── harbor/                # Harbor 部署設定（規劃中）
│   └── docker/
│       ├── build.sh
│       ├── Dockerfile
│       └── docker-compose.yaml
└── logs/                  # 各工具運行日誌（執行時建立）
```

> 注意：各工具的子目錄將在後續逐步補上，目前僅完成 repo 初始化。

## 系統需求

- macOS（Apple Silicon 或 Intel）
- Docker Desktop 或同等容器執行環境
- Bash／Zsh

## 使用方式

各工具皆預期提供 `run.sh` 作為啟動入口，使用方式如下：

```bash
# 範例：啟動 GitLab（待實作）
cd gitlab
./run.sh
```

## 授權

尚未指定，預設保留所有權利。

## 維護者

- [@nk7260ynpa](https://github.com/nk7260ynpa)
