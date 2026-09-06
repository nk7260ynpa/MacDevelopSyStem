# 改用 Kubernetes 部署 GitLab 與 Harbor

## Context

依 Notion 任務「[改用k8s建立gitlab服務](https://app.notion.com/p/3d3dfac20953805c9d98f673842f10bc)」，
把 GitLab 與 Harbor 的**預設**部署方式從 Docker Compose 改為 Kubernetes，理由是
Deployment 的 controller 會在 pod 掛掉時自動重建，比 `restart: always` 更可靠。

需求原文六條：

1. 增加 k8s 部署 GitLab 跟 Harbor 的 yaml（原來 docker 部署方式不要刪）
2. 預設部署方式改為 k8s
3. 部署方式要使用 Deployment，這樣掛掉才會自動恢復
4. namespace 設定為 `devops`
5. K8s 版部署上線後，K8s 接手原埠，停掉 docker 版
6. 在 gitlab、harbor 資料夾底下各建一個 `k8s/` 資料夾，其下建 `data/`，將原來的資料遷移到此處

本 repo 曾在 2026-08-21 由 commit `73e8f87` 移除整套 k8s manifests（理由是「版本停止跟進、
與 Compose 長期不同步」，紀錄見 `plans/happy-drifting-ripple.md`）。本次等於重新導入，
但**方向相反**：這次 K8s 是主線、Compose 退為備用，且版本必須與 Compose 方案對齊。
舊 manifest 可用 `git show 73e8f87^:<path>` 取回作為骨架，但多處必須改寫（見下）。

- Repo：`/Users/chen/AI/MacDevelopSyStem`，GitHub，基底分支 `main`，同步後 HEAD `8e12ef1`
- 分支名：`feat/k8s-deployment`（GitHub，不開 issue／PR）

## 已查證的關鍵環境事實

### 一、叢集已切為 kubeadm 模式（本計劃成立的前提）

規劃過程中發現原本是 2 節點 kind 叢集，節點是 docker 容器、**看不到 `/Users`**，
hostPath 無法掛 Mac 目錄，需求第 6 條不可能達成。使用者已把 Docker Desktop 切換為
Kubeadm 佈建方式，現況：

| 項目 | 值 |
| --- | --- |
| 節點 | `docker-desktop`（即 Docker Desktop VM，非容器） |
| 版本 | v1.36.1，containerd 走 `docker://29.7.2` |
| StorageClass | `hostpath`（`docker.io/hostpath`，default） |
| 設定 | `KubernetesMode: kubeadm`、`KubernetesNodesCount: 1` |
| 資源 | Docker Desktop 4 CPU / 8192 MiB |

節點即 VM，VM 透過 virtiofs 掛有 `/Users`，故 hostPath 指向
`/Users/chen/AI/MacDevelopSyStem/*/k8s/data` 可直接生效。

> **實作第一步必須實測這件事**（見〈驗證〉A-0）。若 pod 掛上去看不到檔案，
> 後面全部免談，要停下來重新討論。

### 二、對外埠只能走 LoadBalancer，不能用 NodePort

需求第 5 條要 K8s 接手原埠 8080／2222／8081，但 NodePort 範圍是 30000-32767，
涵蓋不到。Docker Desktop 對 `type: LoadBalancer` 的 Service 會自動綁到 `localhost:<port>`，
這是唯一能用原埠的路。舊 manifest 的 NodePort 30080/30022/30081 全部改掉。

因為要綁同一組埠，**docker 版必須先停**，否則 LoadBalancer 會因埠被佔而起不來。

### 三、GitLab 掛 virtiofs 會重現 socket 崩潰（本計劃最大的坑）

`README.md` L126-226 記錄過：macOS 的 virtiofs bind mount 不支援對 unix socket
`unlink`／`chmod`，也不保留 setgid，曾造成連續 6.5 天全站 502。Compose 方案的解法是
**6 項 omnibus 覆寫把 socket 全部移出掛載區 + 5 個 tmpfs**。

k8s 的 hostPath 掛的就是同一個 virtiofs，**這些 workaround 一項都不能少**，必須逐項移植：

| Compose 的 tmpfs | k8s 對應 | 權限需求 |
| --- | --- | --- |
| `/run/postgresql` | `emptyDir{medium:Memory}` | uid/gid 996，0755 |
| `/run/gitlab-redis` | 同上 | uid/gid 997，0755 |
| `/run/gitlab-workhorse` | 同上 | uid 998 / gid 999，0750 |
| `/run/gitaly` | 同上 | uid/gid 998，**0700，無對應 Chef 資源，全靠掛載決定** |
| `/run/gitaly-runtime` | 同上 + `sizeLimit: 512Mi` | uid/gid 998，0700，需可執行 |

**k8s 的 `emptyDir` 無法指定 uid/gid/mode**（這是與 docker tmpfs 最大的差異），
必須加一個 root 身分的 initContainer 逐一 `chown`／`chmod`。`/run/gitaly-runtime`
要能 exec——kubelet 掛 tmpfs 不帶 `noexec`，這點成立，但仍要在驗證階段實測 git 操作。

另外 `git-data/repositories` 需 2770 setgid，virtiofs 不保留，Compose 是由
`gitlab/run.sh` 的 `clean_stale_state()` **在 macOS 端**修正；k8s 版同樣要在
`apply.sh`（跑在 Mac 上）做，不能寄望容器內 chmod。

### 四、Harbor 的設定可直接沿用，不必重跑 prepare

現行 `harbor/docker/data/config/` 內各服務的位址全部是 compose service 名：

```
POSTGRESQL_HOST=postgresql   REGISTRY_URL=http://registry:5000
_REDIS_URL_CORE=redis://redis:6379   PORTAL_URL=http://portal:8080
CORE_URL=http://core:8080    JOBSERVICE_URL=http://jobservice:8080
REGISTRY_CONTROLLER_URL=http://registryctl:8080
nginx.conf: upstream core:8080 / portal:8080
```

只要 k8s 的 Service 取**完全相同的名字**（`registry`／`registryctl`／`postgresql`／
`redis`／`core`／`portal`／`jobservice`），同 namespace 內短名即可解析，設定一個字都不用改。
`external_url` 也還是 `http://localhost:8081`，與 K8s 接手後的對外埠一致。

因此**捨棄舊方案的 prepare Job 與 init-configmaps Job**（連同 RBAC）：設定直接沿用遷移過來的
`k8s/data/config`，`env` 檔由 `apply.sh` 在 Mac 端用
`kubectl create secret generic --from-env-file` 轉成 Secret，不需要在叢集內跑 Job、
不需要 ServiceAccount 與 Role。舊方案那三個檔案是為「叢集內從零產生設定」設計的，本次用不到；
從零建立的情境改由 `harbor/k8s/build.sh` 在 Mac 端跑 prepare（與 docker 版同一套做法）。

### 五、待遷移的資料量

| 來源 | 大小 | 遷移 |
| --- | --- | --- |
| `gitlab/docker/data/config` | 200K | ✅ 含 `gitlab-secrets.json`，**不帶會導致 DB 內加密欄位全部解不開** |
| `gitlab/docker/data/data` | 463M | ✅ repo、PostgreSQL、Redis |
| `gitlab/docker/data/logs` | 1.1G | ❌ 不遷 |
| `harbor/docker/data/{config,secret}` | 68K | ✅ `secret/keys/secretkey` 與 `secret/core/private_key.pem` 必帶 |
| `harbor/docker/data/{database,registry,redis,psc,ca_download,job_logs}` | 3.65G | ✅ |
| `harbor/docker/data/log` | 119M | ❌ 不遷（harbor-log 已移除） |

## 變更檔案

```text
gitlab/k8s/                    # 新增
├── 00-namespace.yaml          # devops namespace
├── 01-pv.template.yaml        # hostPath PV，__GITLAB_DATA__ 佔位符
├── 02-pvc.yaml
├── 03-deployment.yaml         # Deployment + initContainer + 5 個 emptyDir
├── 04-service.yaml            # LoadBalancer 8080/2222
├── apply.sh
├── delete.sh
├── migrate.sh                 # docker/data → k8s/data
└── data/.keep

harbor/k8s/                    # 新增
├── 00-namespace.yaml          # 與 gitlab 那份內容相同，apply 冪等
├── 01-pv.template.yaml        # __HARBOR_DATA__ 佔位符
├── 02-pvc.yaml
├── 10-redis.yaml   11-postgresql.yaml   12-registry.yaml
├── 13-core.yaml    14-jobservice.yaml   15-portal.yaml
├── 16-proxy.yaml              # LoadBalancer 8081
├── apply.sh
├── build.sh                   # 從零建立時在 Mac 端跑 prepare
├── delete.sh
├── migrate.sh
└── data/.keep

gitlab/run.sh                  # 預設改走 K8s，docker 需明確指定
harbor/run.sh                  # 同上
.gitignore                     # 納入兩個 k8s/data
README.md                      # 目錄樹、部署章節、持久化設計、系統需求、版本升級
plans/inherited-marinating-finch.md   # 本檔
```

**不動**：`gitlab/docker/`、`harbor/docker/` 底下所有檔案（需求第 1 條明令保留）。

## 實作步驟

### 一、`gitlab/k8s/`

**PV / PVC**：三組（config → `/etc/gitlab`、data → `/var/opt/gitlab`、logs →
`/var/log/gitlab`），`storageClassName: manual` 停用動態 provisioner，PV 走 hostPath
指向 `k8s/data/{config,data,logs}`，`type: DirectoryOrCreate`、`reclaimPolicy: Retain`。
路徑不寫死在版控檔——`01-pv.template.yaml` 用 `__GITLAB_DATA__` 佔位，`apply.sh` 以
`sed` 換成絕對路徑後 pipe 給 `kubectl apply -f -`（沿用舊 Harbor 方案的做法）。

**Deployment**（`replicas: 1`、`strategy: Recreate`、`terminationGracePeriodSeconds: 60`）：

- image `gitlab/gitlab-ce:19.2.4-ce.0`——與 `docker/Dockerfile` 的 `FROM` 對齊，
  註解要寫明兩處必須同時改，且沿用該檔的升級停點警語（19.2/19.5/19.8/19.11）。
- `GITLAB_OMNIBUS_CONFIG` 以 Compose 那份為基準逐項照抄（含全部 socket 覆寫與
  `gitaly['configuration']`），另加 k8s 專屬兩項：

  ```ruby
  nginx['listen_port'] = 80                                  # 對外由 LoadBalancer 8080→80
  gitlab_rails['monitoring_whitelist'] = ['0.0.0.0/0']       # 否則 kubelet 探針被擋回 404
  ```

  `external_url` 與 `gitlab_shell_ssh_port` 維持 `http://localhost:8080` / `2222`
  （與 Compose 相同，遷移過來的 DB 內既有的 clone URL 才不會全部失效）。
- initContainer `init-runtime-dirs`（image 同上、`runAsUser: 0`）：對 5 個 emptyDir
  掛載點做 `mkdir -p` + `chown` + `chmod`，數值照上表。
- 5 個 `emptyDir{medium: Memory}`，`/run/gitaly-runtime` 加 `sizeLimit: 512Mi`。
- `resources`：`requests` 250m/1536Mi、`limits` 4Gi，**CPU 不設 limit**（對齊 Compose
  的「首次 reconfigure 吃 CPU，不限可加速初始化」）。`emptyDir{medium:Memory}` 的用量
  計入 memory limit，這是 4Gi 之外要留意的。
- 探針：readiness `/-/readiness` initialDelay 180s / period 30s / failureThreshold 10；
  liveness `/-/health` initialDelay 600s / period 60s / failureThreshold 5。
  `shm_size` 在 k8s 無直接對應，若 reconfigure 因 `/dev/shm` 太小失敗，再補一個
  `emptyDir{medium:Memory, sizeLimit:256Mi}` 掛 `/dev/shm`。

**Service**：`type: LoadBalancer`，`http` 8080→80、`ssh` 2222→22。

**apply.sh**：`command -v kubectl` 檢查 → 印 current-context → **檢查 8080/2222 是否已被
docker 版佔用，佔用就報錯要求先 `./run.sh docker stop`** → 在 Mac 端做
`clean_stale_state`（清殘留 socket、`chmod 2770` repositories）→ 依序 apply。

**delete.sh**：namespace 是與 Harbor **共用**的，絕不可 `kubectl delete namespace`。
改用 `kubectl -n devops delete deploy,svc,pvc -l app.kubernetes.io/name=gitlab`，
PV 另以同一 selector 刪（叢集層級）。`reclaimPolicy: Retain`，`k8s/data` 內資料不受影響。

**migrate.sh**：`rsync -a --delete` 把 `docker/data/{config,data}` 複製到 `k8s/data/`，
`logs/` 只建空目錄。執行前檢查 gitlab 容器已停（未停就報錯退出，避免複製到不一致的狀態）。

### 二、`harbor/k8s/`

**PV / PVC**：六組對應 `k8s/data` 下的 `config`、`secret`、`database`、`registry`、
`redis`、`job_logs`；`psc`、`ca_download` 併入 core 用的 data 掛載。做法與 GitLab 相同
（`__HARBOR_DATA__` 佔位 + `apply.sh` sed）。

**8 個 Deployment**，一律 `replicas: 1` + `Recreate`，Service 名嚴格對齊 compose service 名
（見〈關鍵事實四〉）。掛載逐項對應 `docker-compose.yaml` 的 volumes：單檔掛載用
`subPath`，`securityContext.capabilities` 照抄 compose 的 `cap_drop`／`cap_add`
（registry/registryctl/redis 三項、postgresql 四項、core 兩項、portal/proxy 四項）。
image 全部 `v2.15.2`，redis 用 **`goharbor/valkey-photon`**（v2.15 起改名，不是 redis-photon）。
**不建 `17-log.yaml`**——harbor-log 已從 compose 移除。

`registry` 與 `registryctl` 依舊方案放同一個 Pod（共用 `/storage` 與 `/etc/registry`），
但要拆成兩個 Service（`registry:5000`、`registryctl:8080`）。

**env → Secret**：`apply.sh` 對 `core`／`jobservice`／`registryctl`／`db` 四個
`data/config/<svc>/env` 各跑一次
`kubectl create secret generic harbor-env-<svc> --from-env-file=... --dry-run=client -o yaml | kubectl apply -f -`
（冪等），Deployment 以 `envFrom.secretRef` 取用。

**proxy Service**：`type: LoadBalancer`，8081→8080。

**build.sh**：僅供「從零建立」——在 Mac 端 `docker run goharbor/prepare:v2.15.2`
產生設定到 `k8s/data`，流程與 `harbor/docker/build.sh` 相同（含 `/compose_location`
拋棄式目錄與 `root.crt` 複製兩個既有陷阱）。走遷移路線時不需要執行。

**migrate.sh**：`rsync -a` 複製六個目錄 + `secret/`，跳過 `log/`。同樣先檢查容器已停。

### 三、`run.sh`（兩支，需求第 2 條）

改為 `./run.sh [docker|k8s] [up|logs|stop|status]`，**mode 省略時為 `k8s`**：

```bash
# 用法：
#   ./run.sh              # 以 Kubernetes 部署（預設）
#   ./run.sh logs         # 跟隨 pod log
#   ./run.sh stop         # 移除 K8s 資源（k8s/data 保留）
#   ./run.sh status       # 查看 pod 狀態
#   ./run.sh docker       # 改用 Docker Compose 啟動（備用方案）
#   ./run.sh docker logs  # Docker Compose 的 log
```

解析方式：第一個參數若是 `docker`／`k8s` 就當 mode 並 shift，否則 mode 取預設；
其餘沿用既有的 `action="${1:-up}"` + `case` 結構與 `[run.sh]` 輸出前綴。
Docker 模式的行為（含 GitLab 的 `clean_stale_state`）一字不動地保留。

### 四、`.gitignore`

在「持久化資料」區塊補兩組規則，並把註解改回移除 k8s 前的版本：

```gitignore
# 持久化資料（Docker 與 K8s 各自獨立，僅保留 .keep）
gitlab/docker/data/*
!gitlab/docker/data/.keep
gitlab/k8s/data/*
!gitlab/k8s/data/.keep
harbor/docker/data/*
!harbor/docker/data/.keep
harbor/k8s/data/*
!harbor/k8s/data/.keep
```

### 五、`README.md`

由後往前改，避免行號位移：

| 位置 | 處理 |
| --- | --- |
| L462-486 版本升級 | 補「K8s 的 image tag 在 Deployment，與 `docker/Dockerfile` 必須同步」 |
| L427-440 使用方式 | 改為 `./run.sh` = K8s，`./run.sh docker` = Compose |
| L282-347 開機自啟 | 補一節說明 K8s 由 Deployment controller 負責重建，`restart: always` 那套僅適用備用的 Compose 方案 |
| L228-275 Harbor 部署 | 加「透過 Kubernetes」小節（apply/migrate/存取 URL） |
| L126-226 virtiofs 限制 | 補一句：K8s 走 hostPath 掛的是同一個 virtiofs，因此同一組 workaround 以 emptyDir + initContainer 移植過去 |
| L81-125 GitLab 部署 | 加「透過 Kubernetes」小節，並標明 K8s 為預設 |
| L71-79 系統需求 | 加 kubectl、Docker Desktop Kubernetes（**Kubeadm 佈建方式**，kind 模式不可用） |
| L54-70 資料持久化 | 表格加 K8s 欄（`gitlab/k8s/data/`、`harbor/k8s/data/`） |
| L28-53 目錄樹 | 加兩個 `k8s/` 分支——`docker/` 由 `└──` 改回 `├──`，其子項前導由 4 空白改回 `│   ` |
| L12-27 工具表 | 部署方式一欄註明預設 K8s |

## Commit 拆解

依約定式提交，繁體中文，50/72：

1. `feat(gitlab): 新增 GitLab 的 Kubernetes 部署方案`
2. `feat(harbor): 新增 Harbor 的 Kubernetes 部署方案`
3. `feat(run): run.sh 預設改以 Kubernetes 部署`
4. `chore(gitignore): 納入 K8s 持久化資料目錄`
5. `docs(readme): 補上 Kubernetes 部署方案說明`
6. `docs(plans): 新增改用 K8s 部署的實作計畫紀錄`

## 驗證

### A. 前置實測（**寫 manifest 前先做，不通過就停下來重談**）

- **A-0 hostPath 可見性**：起一個臨時 pod 掛 hostPath 到
  `/Users/chen/AI/MacDevelopSyStem/gitlab/k8s/data`，`ls` 看得到 Mac 端放的測試檔才算過。
- **A-1 LoadBalancer**：建一個 `type: LoadBalancer` 的測試 Service，確認
  `EXTERNAL-IP` 變成 `localhost` 而非停在 `<pending>`，且 `curl localhost:<port>` 通。

### B. 靜態檢查

```bash
~/.claude/verify-toolbox/run.sh exec shellcheck gitlab/k8s/*.sh harbor/k8s/*.sh gitlab/run.sh harbor/run.sh
~/.claude/verify-toolbox/run.sh exec yamllint gitlab/k8s/ harbor/k8s/
kubectl apply --dry-run=client -f gitlab/k8s/00-namespace.yaml -f gitlab/k8s/02-pvc.yaml ...
docker compose -f gitlab/docker/docker-compose.yaml config -q   # 確認沒改壞備用方案
docker compose -f harbor/docker/docker-compose.yaml config -q
```

### C. 切換與部署（需求第 5 條，**服務會中斷**）

```bash
cd ~/AI/MacDevelopSyStem
gitlab/run.sh docker stop && harbor/run.sh docker stop   # 冷停，確保資料一致
gitlab/k8s/migrate.sh && harbor/k8s/migrate.sh           # 約 4.1G，需數分鐘
gitlab/run.sh && harbor/run.sh                           # 預設即 K8s
kubectl -n devops get pods -w
```

### D. 部署後實測

```bash
kubectl -n devops get deploy,svc,pvc
curl -s -o /dev/null -w 'gitlab HTTP %{http_code}\n' http://localhost:8080/
curl -s -o /dev/null -w 'harbor HTTP %{http_code}\n' http://localhost:8081/
ssh -T -p 2222 git@localhost                    # 應回 GitLab 的歡迎訊息
docker login localhost:8081 -u admin            # Harbor 認證仍可用 = secretkey 遷移成功
git clone http://localhost:8080/<既有專案>.git  # 遷移過來的 repo 讀得到
kubectl -n devops exec deploy/gitlab -- gitlab-rake gitlab:check SANITIZE=true
```

- **登入既有帳號成功**即證明 `gitlab-secrets.json` 有正確帶過去。
- **Harbor 既有 image 拉得下來**即證明 `secret/` 與 registry 資料完整。

### E. 自動恢復（需求第 3 條的驗收點）

```bash
kubectl -n devops delete pod -l app.kubernetes.io/name=gitlab   # 應自動重建並回到 Ready
kubectl -n devops delete pod -l app.kubernetes.io/name=harbor,component=core
```

### F. virtiofs 回歸（本計劃最大風險的專門驗證）

```bash
kubectl -n devops rollout restart deploy/gitlab   # 反覆重啟不得出現 502
kubectl -n devops logs deploy/gitlab | grep -iE 'operation not supported|unlinkat|EINVAL'
git push  # 走 gitaly-runtime 的 exec 路徑，確認 tmpfs 可執行
```

## 風險

- **虧在 virtiofs 的機率最高**。GitLab 的 5 個 emptyDir 權限若沒設對，症狀是
  pod Running 但對外 502（正是 README 記載那次 6.5 天事故的樣子），且探針不一定抓得到。
  F 段驗證必須做滿。
- **記憶體吃緊**。Docker Desktop 只有 8 GiB，GitLab limit 4Gi + Harbor 8 個 pod，
  切換期間若 docker 版沒完全停會直接 OOM。C 段的冷停順序不能跳。
- **資料遷移不可逆的部分**：`migrate.sh` 只複製不刪來源，`docker/data` 原封不動，
  隨時可以 `./run.sh docker` 回退——但**回退前要先停 K8s**，否則兩邊搶同一組埠。
  兩邊資料在切換後會各自演進，回退等於丟掉 K8s 期間的所有異動，這點要寫進 README。
- **共用 namespace 的誤刪風險**：`devops` 底下同時有 GitLab 與 Harbor，任何
  `kubectl delete namespace devops` 都會兩個一起殺。delete.sh 一律走 label selector，
  這點要在腳本註解裡寫死。
- Harbor 的 Service 名（`core`、`registry`、`redis`、`postgresql`）在共用 namespace 裡
  很通用，日後若在 `devops` 放別的服務要避開這些名字。

## 不做的事

- 不刪除、不修改 `gitlab/docker/`、`harbor/docker/` 內任何檔案（需求第 1 條）。
- 不改 `harbor/docker/harbor.yml` 或重跑 docker 版的 prepare。
- 不引入 Helm、Ingress Controller 或 Trivy（維持與 Compose 相同的最小可用集合）。
- 不動 `plans/` 既有檔案（歷史紀錄不回頭改寫）。
