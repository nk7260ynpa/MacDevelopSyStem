# 導入開機重啟與自動修復

Notion 任務：[導入開機重啟與自動修復](https://app.notion.com/p/3c2dfac209538030b01ee79c3de09d4a)

## Context

現行的開機啟動與自我修復，靠的是本 repo 自製的四支 macOS LaunchAgent
（Harbor 的 `autostart` + `watchdog`、GitLab 與 Runner 各一支 `autostart`），
外加頂層 `install-all.sh` / `uninstall-all.sh` 作為安裝入口。

任務要求改用 Docker 內建能力達成同樣目的，並移除整套 LaunchAgent 機制。

**但單純刪除 boot/ 會讓 Harbor 連開機都起不來**，原因是一個必須一併處理的耦合：

Harbor 全部 8 個服務都以 `syslog` driver 將 log 送往 `harbor-log` 的
`tcp://127.0.0.1:1514`，並用 `depends_on: log / condition: service_healthy`
確保啟動順序。問題在於 **`depends_on` 只在 `docker compose up` 時有效**——
主機重開機或 Docker daemon 單獨重啟時，daemon 是**逐容器依各自 restart policy
恢復，完全不走 compose、不看 `depends_on`**。各服務會搶在 `harbor-log` 就緒前啟動，
syslog driver 連不上 1514 而以 ExitCode 128 退出，重試耗盡後被 docker 放棄，
最終只剩 `harbor-log` 存活。

這正是 watchdog 當初被建立的理由，且 `harbor/logs/harbor-watchdog.log` 顯示
2026-08-18 真的觸發過一次修復。

因此本次要讓「純 Docker 內建機制」真正成立，**必須先拆掉 syslog 依賴**。
拆掉之後各容器彼此獨立，`restart: always` 才會在開機與意外退出兩種情境下都生效，
LaunchAgent 也就沒有存在必要。

預期成果：三個服務靠 Docker Desktop 登入自啟 + `restart: always` 完成開機啟動與
崩潰自愈，repo 內不再有任何 LaunchAgent 相關檔案。

## 影響範圍

單一 repo：`~/AI/MacDevelopSyStem`（GitHub，base branch `main`，同步後 HEAD `e205df5`）

分支：`refactor/native-docker-restart`（GitHub repo，僅建立分支，不開 issue／PR）

## 實作步驟

### 1. 先卸載系統上已安裝的 LaunchAgent

**必須在刪除檔案之前執行**，否則 `uninstall.sh` 沒了得手動 `launchctl bootout`。

```bash
./uninstall-all.sh
launchctl list | grep -i chen   # 應查無 harbor-autostart / harbor-watchdog
```

目前系統上實際載入的只有 `com.chen.harbor-autostart` 與 `com.chen.harbor-watchdog`
（GitLab / Runner 兩支從未安裝），但仍走完整流程確保乾淨。

### 2. `harbor/docker/docker-compose.yaml`：拆除 syslog 耦合

這是本次的核心改動。

- **移除 `log` service 整段**（含 `ports: 127.0.0.1:1514:10514` 與其 volumes）。
- **8 個服務的 `logging:` 區塊**由 syslog 改為 json-file，統一為：

  ```yaml
  logging:
    driver: "json-file"
    options:
      max-size: "50m"
      max-file: "3"
  ```

- **移除各服務 `depends_on` 中的 `log:` 條目**，其餘服務間依賴**原樣保留**：

  | 服務 | `depends_on` 處置 |
  | --- | --- |
  | `registry`、`postgresql`、`redis`、`portal` | 只依賴 log，整段 `depends_on` 移除 |
  | `registryctl` | 保留 `registry` |
  | `core` | 保留 `registry`、`redis`、`postgresql` |
  | `jobservice` | 保留 `core` |
  | `proxy` | 保留 `registry`、`core`、`portal` |

- **更新檔頭註解**（第 3～18 行）：服務組成移除 `log`，並把「所有 service 透過
  syslog driver…」那段設計說明改寫為 json-file 與獨立恢復的理由。
- `restart: always` 全部維持不變。

### 3. GitLab / Runner：restart policy 統一為 `always`

- `gitlab/docker/docker-compose.yaml:18`：`unless-stopped` → `always`
- `gitlab-runner/docker/docker-compose.yaml:12`：`unless-stopped` → `always`

### 4. 刪除整套 LaunchAgent 機制

```
harbor/boot/          （6 檔：autostart.sh、watchdog.sh、2 個 plist、install、uninstall）
gitlab/boot/          （4 檔）
gitlab-runner/boot/   （4 檔）
install-all.sh
uninstall-all.sh
```

順帶清掉 `harbor/logs/` 下四個 boot 產生的 log 檔
（`harbor-autostart.log`、`harbor-watchdog.log` 及兩個 `.launchd.log`；
`.gitignore` 已排除 `*.log`，不在版控內，僅清實體檔案）。

`plans/` 下兩份既有文件是歷史記錄，**不動**。

### 5. `README.md` 改寫

- **目錄樹**（34、35、39、55、77 行）：移除 `install-all.sh`、`uninstall-all.sh`
  與三個 `boot/` 條目。
- **「開機自動啟動與守護巡檢」整章**（約 391～419 行）與**「三服務開機自啟」整章**
  （約 475～518 行）：兩章合併改寫為一節，說明新機制——
  Docker Desktop 登入自啟（前提）+ `restart: always`，並記載 Harbor 改用 json-file
  的原因（daemon 恢復容器不走 compose，故不能有跨容器啟動依賴）。
- **Harbor 升級章節**（589～593 行）：移除 unload/load watchdog 的前後置步驟。
- 補上 log 查看方式的變更：`harbor/docker/data/log/*.log` 不再更新，改用
  `docker logs <容器>` 或 `./run.sh logs`。

### 6. 檢查 `CLAUDE.md`

本 repo 無專案層 `CLAUDE.md`（僅使用者全域），確認後無需更動。

## 部署

Harbor 因 compose 結構變更需重建；GitLab / Runner 僅 restart policy 變更，
`up -d` 即可套用。

```bash
cd ~/AI/MacDevelopSyStem/harbor        && ./run.sh
cd ~/AI/MacDevelopSyStem/gitlab        && ./run.sh
cd ~/AI/MacDevelopSyStem/gitlab-runner && ./run.sh up
```

> 一律用 `up -d --build`，**絕不使用 `docker compose down --remove-orphans`**——
> 各專案 compose 都在自己的 `docker/` 目錄，`--remove-orphans` 會跨專案誤殺容器。

## 驗證

1. **語法與設定**：`docker compose -f harbor/docker/docker-compose.yaml config`
   應無誤，且輸出中不含 `syslog` 與 `log` service。

2. **容器狀態**：部署後 `docker ps`，Harbor 應為 8 個容器（少了 `harbor-log`）
   且全數 healthy，GitLab / Runner 正常。

3. **restart policy 生效**：
   ```bash
   docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' \
     gitlab gitlab-runner harbor-core   # 應全為 always
   ```

4. **服務可用**：Harbor `http://localhost:8081` 可登入、GitLab `http://localhost:8080`
   健康端點正常。

5. **log 可讀**：`docker logs harbor-core --tail 20` 有輸出（確認 json-file 生效）。

6. **崩潰自愈**（對應需求 2）：
   ```bash
   docker kill harbor-core     # 模擬意外掛掉
   sleep 15 && docker ps | grep harbor-core   # 應已自動重啟
   ```

7. **開機恢復**（對應需求 1，本次改動的核心目的）：重啟 Docker Desktop，
   等 daemon 就緒後確認 **Harbor 8 個容器全部自己回來**。這是舊架構會失敗、
   新架構應通過的關鍵情境；若此項不過，代表 syslog 耦合未拆乾淨。

## 風險

| 風險 | 說明與處置 |
| --- | --- |
| 失去集中式 log | `harbor/docker/data/log/*.log` 不再更新（既有檔案保留不刪）。改用 `docker logs`，已於 README 記載。 |
| 偏離 Harbor 官方架構 | 官方 compose 預設用 syslog + harbor-log。本 repo 已是自維護 compose，且此改動是達成需求的必要條件。 |
| `always` 覆寫手動 stop | 手動 `docker stop` 後重開機容器仍會起來。此為選定行為，需長期停用請用 `./run.sh stop`（compose down，容器移除後不受 restart policy 影響）。 |

## Commit 規劃

1. `refactor(harbor): 改用 json-file logging 並移除 log service`
2. `refactor(compose): 統一 gitlab 與 runner 的 restart policy 為 always`
3. `chore: 移除 LaunchAgent 開機啟動與守護巡檢機制`
4. `docs(readme): 改寫開機啟動章節為 Docker 原生機制`
