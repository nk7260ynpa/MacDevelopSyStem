# 移除範例 GitLab Runner 的所有相關程式碼

## Context

本 repo（MacDevelopSyStem）原本內建一份「範例」GitLab Runner 部署方案，作為 GitLab CI/CD
的示範執行器。依 Notion 任務「[範例Runner移除](https://app.notion.com/p/3cbdfac20953800aa478c4ee49fdda4d)」
的決策，Runner 之後改由各 Group 自行建立與管理，不再由本 repo 提供範例，因此要把
`gitlab-runner/` 相關的程式碼、設定與文件段落整份移除。

移除後本 repo 只保留 GitLab 與 Harbor 兩個服務。GitLab 端會失去 CI executor（CI job
會 pending），這是預期結果。

**已確認的執行範圍**（使用者核可）：

- 執行期資源全清：先在 GitLab 註銷 runner，再停容器、刪 image，最後刪目錄。
- 目錄下 gitignored 的本機機密檔（`docker/.env`、`docker/data/config.toml`、`.env`）
    直接連同目錄刪除，不另行備份。

## 影響範圍調查結論

- `gitlab-runner/` 是**獨立的 Compose 專案**（`name: gitlab-runner`），沒有 `networks:`
    也沒有 `depends_on`，與 `gitlab/`、`harbor/` 完全解耦。
- 耦合僅為**單向**：runner 透過 `host.docker.internal:8080` 連回 GitLab。GitLab 與
    Harbor 兩邊的 compose／run.sh 都沒有任何 runner 相關設定。
- 唯一啟動／註冊 runner 的入口就是 `gitlab-runner/run.sh` 與 `gitlab-runner/docker/build.sh`。
- → **刪除 `gitlab-runner/` 不影響 GitLab 與 Harbor 的啟動或運行。**

## 實作步驟

### 一、執行期清理（改檔前先做）

```bash
# 1. 在 GitLab 註銷此 runner（避免 GitLab 端留下孤兒紀錄）
docker exec gitlab-runner gitlab-runner unregister --all-runners

# 2. 停止並移除容器
cd ~/AI/MacDevelopSyStem/gitlab-runner && ./run.sh stop

# 3. 刪除本機 image（496MB）
docker rmi macdev/gitlab-runner:latest
```

驗證：`docker ps -a | grep gitlab-runner` 應無結果；`docker images | grep gitlab-runner`
應無 `macdev/gitlab-runner`。

> 註銷指令必須在容器停止**之前**執行，否則沒有容器可執行 `unregister`。

### 二、刪除 `gitlab-runner/` 整個目錄

```bash
git rm -r gitlab-runner       # 移除 6 個 tracked 檔案
rm -rf gitlab-runner          # 清掉 gitignored 的 .env / data/ 殘留
```

Tracked 檔案（6）：`run.sh`、`docker/{build.sh,Dockerfile,docker-compose.yaml,.env.example}`、
`docker/data/.keep`。Untracked（4，一併刪除）：`docker/.env`、`docker/data/config.toml`、
`docker/data/.runner_system_id`、`.env`。

### 三、`.gitignore`

刪除第 38-39 行：

```text
gitlab-runner/docker/data/*
!gitlab-runner/docker/data/.keep
```

第 25-26 行的 `.env` / `.env.*` 是全域通則，保留不動。

### 四、`README.md`

依序處理下列位置（**行號會隨編輯位移，由後往前改**）：

| 行號 | 處理方式 |
| --- | --- |
| 18 | 刪除「預定支援的工具」表格中的 GitLab Runner 整列 |
| 21-24 | 版本釘選說明改寫：「GitLab 與 Runner 釘選於各自的 `docker/Dockerfile`」→ 只留 GitLab |
| 50-57 | 刪除架構樹的 `gitlab-runner/` 子樹；**同時**把 `harbor/`（41 行）的 `├──` 改為 `└──`，並把 42-49 行的 `│   ` 前綴改為 4 個空白 |
| 67 | 刪除資料持久化表格中的 GitLab Runner 整列 |
| 233-306 | 刪除整章「## GitLab Runner 部署」（含章前的 `---` 分隔線，注意不要留下連續分隔線或空行） |
| 364 | 「Harbor、GitLab、GitLab Runner 於主機重開機後自動恢復」→ 改為「Harbor 與 GitLab…」 |
| 372 | 刪除實測結果表格中的 GitLab Runner 整列 |
| 384 | 「**三個服務**的 `docker-compose.yaml`」→「**兩個服務**」 |
| 395-397 | 註解「三個服務的 restart policy」→「兩個服務」；指令中的 `gitlab-runner` 從 `docker inspect ... gitlab gitlab-runner harbor-core` 移除 |
| 521-523 | 刪除「使用方式」code block 中啟動 Runner 的三行 |
| 547-550 | 刪除「### GitLab Runner」版本升級小節 |

**不可誤刪**：第 541 行的 `docker exec gitlab gitlab-rails runner ...` 是 Rails runner，
與 GitLab Runner 無關。

README 沒有 TOC，也沒有指向 runner 章節的內部錨點，不需修錨點。

### 五、`plans/` 目錄

**不修改**。README 第 32 行明載 plans/ 為「歷史文件，不參與部署」，其中 5 個檔案提到
runner 都是當時的既成事實紀錄；`gitlab-harbor-lazy-scroll.md` 已有「本文僅保留為歷史記錄」
的先例處理方式。本次計畫檔本身即為此變更的紀錄。

## Commit 拆分

依約定式提交，繁體中文，50/72：

1. `chore(gitlab-runner): 移除範例 Runner 部署方案` — `git rm -r gitlab-runner` + `.gitignore`
2. `docs(readme): 移除 GitLab Runner 相關說明` — README 全部段落

## 驗證

```bash
# 1. repo 內不應再有 gitlab-runner 引用（僅允許 plans/ 的歷史文件命中）
grep -rn "gitlab-runner\|GitLab Runner" --exclude-dir=.git --exclude-dir=plans .

# 2. 確認 Rails runner 那行仍在
grep -n "gitlab-rails runner" README.md

# 3. 架構樹縮排正確
sed -n '/^```text/,/^```$/p' README.md

# 4. 兩個服務仍正常運行
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'gitlab|harbor'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080   # GitLab
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081   # Harbor

# 5. restart policy 驗證指令（README 改後的版本）可正常執行
docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' gitlab harbor-core
```

本次不需重新部署 GitLab 或 Harbor——沒有動到它們的任何檔案。

## 風險

- `unregister --all-runners` 不可逆；GitLab 端該 runner 紀錄會消失，日後各 Group 需
    自行重新建立。此為任務本意。
- 刪目錄會一併清掉含明文權杖／Harbor 帳密的本機檔（使用者已確認不需備份）。
- README 架構樹的 box-drawing 前綴容易改錯，需以驗證步驟 3 目視確認。
