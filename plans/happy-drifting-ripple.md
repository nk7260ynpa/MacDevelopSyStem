# 移除 Kubernetes 部署方案

## Context

本 repo 目前為 GitLab 與 Harbor 各自維護兩套互斥的部署方案：Docker Compose 與 Kubernetes
原生 manifests。K8s 方案的版本已停止跟進（manifest 仍停在 Harbor `v2.11.0` 與
`gitlab-ce:latest`，與 Docker 方案的 `v2.15.2`／`19.2.4-ce.0` 不同步），實際維護成本落在
兩份不同步的設定與近 90 行的 README 說明上。

Notion 任務〈移除k8s 相關檔案〉（`Group: MacDevelopSyStem`）指定：

1. 移除 gitlab 的 k8s 所有相關檔案
2. 移除 harbor 的 k8s 所有相關檔案
3. 只需留下 docker 相關檔案即可

預期結果：repo 僅保留 Docker Compose 單一部署路徑，`gitlab/`、`harbor/`、`gitlab-runner/`
三者結構一致（`run.sh` + `docker/`），文件與 `.gitignore` 不再殘留 K8s 敘述。

- Notion 頁面：<https://app.notion.com/p/3c2dfac209538030b01ee79c3de09d4a>
- 遠端：GitHub `nk7260ynpa/MacDevelopSyStem`（單一 remote，無 GitLab 鏡像）
- 基底分支：`main` @ `db480b6`（已同步、工作區乾淨）
- 分支：`refactor/remove-k8s-manifests`（GitHub → 只建分支，不開 issue／PR）

## 相依性確認

已全面掃描，**移除 K8s 目錄不會破壞任何執行路徑**：

- `gitlab/run.sh`、`harbor/run.sh`、`gitlab-runner/run.sh`、三個 `docker/build.sh`、三個
  `docker-compose.yaml` 皆未呼叫或 `source` `k8s/` 下的任何檔案。
- `harbor/k8s/02-secret.yaml` 內嵌自己的一份 `harbor.yml`，與 `harbor/docker/harbor.yml`
  互不引用；兩方案的 `data/` 目錄各自獨立。
- repo 內無 Makefile、無 `.github/workflows/`、無 `.gitlab-ci.yml`。
- 唯一「軟性相依」是 `.gitignore` 的兩行規則與若干註解／文件文字。

## 實作步驟

### 步驟 1：刪除 K8s 目錄與失效的 gitignore 規則

```bash
git rm -r gitlab/k8s harbor/k8s
rm -rf harbor/k8s          # 清掉未版控的空 data 子目錄
```

- `gitlab/k8s/`：6 檔（`00-namespace` / `01-pvc` / `02-deployment` / `03-service`、`apply.sh`、`delete.sh`）
- `harbor/k8s/`：19 個版控檔（含 `pv.template.yaml`、`data/.keep`）＋未版控的空目錄
  `data/{config,database,job_logs,redis,registry}`

`.gitignore`：

- 刪除 L42-43（`harbor/k8s/data/*`、`!harbor/k8s/data/.keep`）
- L35 註解 `# 持久化資料（Docker 與 K8s 各自獨立，僅保留 .keep）` → `# 持久化資料（僅保留 .keep）`
- L45-47 舊版共用資料夾（`gitlab/git_data/`、`harbor/harbor_data/`）規則**維持不動**，
  不在本任務範圍內。

### 步驟 2：清除腳本中的 K8s 交叉引用註解

以下皆為**純註解**，無執行語義；逐處改寫成只描述 Docker 方案：

| 檔案 | 行 | 現況 |
| --- | --- | --- |
| `gitlab/run.sh` | 11 | 「採用 Docker Compose 方案；K8s 方案請改用 `./k8s/apply.sh`。」 |
| `gitlab/run.sh` | 18 | 「Docker 專屬持久化資料夾（與 K8s 的 k8s/data 各自獨立，不共用）。」 |
| `harbor/run.sh` | 11 | 同 `gitlab/run.sh:11` |
| `harbor/docker/build.sh` | 21 | 同 `gitlab/run.sh:18` |
| `gitlab/docker/docker-compose.yaml` | 9 | 「K8s 方案有自己獨立的 k8s/data，兩種部署不共用儲存。」 |
| `gitlab/docker/docker-compose.yaml` | 47 | 「…比照 k8s 版 02-deployment.yaml」 |

> `gitlab/docker/docker-compose.yaml:79` 的 `gitlab_kas['enable'] = false` **必須保留**
> ——那是 GitLab Omnibus 自身的功能開關，只有註解文字提到「K8s Agent Server」，與本專案的
> K8s 部署方案無關。

### 步驟 3：改寫 README.md

README 共 651 行，K8s 內容約 90 行。改動分兩類：

**整段刪除**

| 位置 | 內容 |
| --- | --- |
| L26-27 | 「K8s 方案的 manifest 版本獨立維護…與上表不同步」段落 |
| L44-50、L60-71 | 專案架構目錄樹中的兩個 `k8s/` 分支 |
| L118-123 | 系統需求中「若使用 K8s 方案，需額外具備 kubectl／本機叢集／最小資源設定」條列 |
| L220-260 | `### 透過 Kubernetes`（GitLab 完整章節） |
| L262-269 | `### 兩種方案的取捨`（純兩方案比較表，無 Docker 專屬內容可留） |
| L396-436 | `### 透過 Kubernetes`（Harbor 完整章節） |

刪除目錄樹分支時注意樹狀連接線：`gitlab/` 與 `harbor/` 底下 `docker/` 將成為最後一項，
`├── docker/` 需改為 `└── docker/`，其子項前導線由 `│   ` 改為 `    `。

**就地改寫**

| 位置 | 改法 |
| --- | --- |
| L16-17 | 狀態欄「已支援（Docker Compose、K8s）」→「已支援（Docker Compose）」 |
| L82-109 `### 資料持久化設計` | 刪掉表格的「K8s 方案」欄與 GitLab／Harbor 兩條 K8s 條列；blockquote 只保留「舊版共用資料夾已停用」該條 |
| L130 | 「GitLab 提供兩種互斥的部署方案，請依需求二擇一啟動（兩者皆使用 8080 / 2222 系列 port）」→ 改為單一 Docker Compose 方案的敘述 |
| L165 | 移除「；K8s 方案改用動態 PVC，資料不落在本機資料夾」 |
| L169 | 「並比照 K8s 版以單進程 Puma 運行」→ 移除「比照 K8s 版」 |
| L350 | 「與 GitLab 一樣提供 Docker Compose 與 K8s 兩種方案」→ 改為僅 Docker Compose |
| L381 | 移除「；K8s 方案另有獨立的 `harbor/k8s/data`」 |
| L440 | 「Harbor port 8081 / 30081 已刻意錯開 GitLab 的 8080 / 30080」→ 移除 NodePort 30081／30080 |

`### 透過 Docker Compose` 這層標題**保留**，維持 `## GitLab 部署` / `## Harbor 部署` 的既有
層級結構，避免不必要的大幅重排。README 內無指向 K8s 章節的錨點連結（`](#…)` 僅三處，皆與
K8s 無關），不需修正交叉連結。

### 步驟 4：計畫紀錄

本檔 `plans/happy-drifting-ripple.md` 一併納入版控，比照 `plans/` 既有的三份歷史計畫紀錄。
`plans/drifting-mapping-unicorn.md:27-28` 提及 `gitlab/k8s/`、`harbor/k8s/` 的敘述是當時的
事實紀錄，**不回頭改寫**。

### Commit 拆解

依約定式提交（繁體中文，50/72）：

1. `refactor(k8s): 移除 GitLab 與 Harbor 的 Kubernetes manifests` — 刪兩個目錄 + `.gitignore`
2. `refactor(scripts): 清除腳本中的 K8s 交叉引用註解` — 步驟 2
3. `docs(readme): 移除 Kubernetes 部署方案說明` — 步驟 3
4. `docs(plans): 新增移除 k8s 的實作計畫紀錄` — 本檔

推送：`git push -u origin refactor/remove-k8s-manifests`

## 驗證

1. **殘留檢查**（應僅剩 `gitlab_kas` 那行與 `plans/drifting-mapping-unicorn.md`）：

   ```bash
   grep -rn -i -E 'k8s|kubernetes|kubectl|minikube' . --exclude-dir=.git --exclude-dir=plans
   git ls-files | grep -i k8s        # 應無輸出
   ```

2. **腳本語法**：

   ```bash
   bash -n gitlab/run.sh harbor/run.sh gitlab-runner/run.sh harbor/docker/build.sh
   docker compose -f gitlab/docker/docker-compose.yaml config -q
   docker compose -f harbor/docker/docker-compose.yaml config -q
   ```

3. **服務現況**（不重啟）：

   ```bash
   docker ps --format '{{.Names}}\t{{.Status}}'
   ```

   確認 `gitlab`、`harbor-*`、`gitlab-runner` 仍正常運行。

4. **verify-agent 檢查迴圈**：把變更檔案清單與 `git diff main..HEAD` 交給 verify-agent，
   針對正確性、Shell／Markdown 風格、文件一致性回報；最多 3 輪。

### 部署決策

`repo_detect.sh` 對本 repo 回報 `deploy_cmd: null`（根目錄無 `run.sh`，部署入口在各服務
子目錄）。本次改動**只刪除 manifest 與修改註解／文件，未觸及任何 Docker Compose 執行邏輯或
服務定義**，因此不執行 `./run.sh` 重啟三個服務——重啟沒有可驗證的效果，反而有中斷 GitLab／
Harbor 的風險。改以上述第 2、3 點（compose 設定檔語法驗證 + `docker ps` 現況確認）取代。

若需要實際重啟驗證，改跑 `cd gitlab && ./run.sh` 與 `cd harbor && ./run.sh`（`up -d --build`
語義；**不得**使用 `docker compose down --remove-orphans`，會跨專案誤殺容器）。

## 不做的事

- 不刪除 `gitlab/git_data/`、`harbor/harbor_data/`（README 標註「已停用、確認無需保留後可
  手動刪除」，但不在本任務範圍；`.gitignore` 相關規則一併保留）。
- 不改寫 `plans/` 下的歷史計畫紀錄。
- 不合併分支、不回寫 Notion `狀態: Done`——留給 `/gitflow2`。
