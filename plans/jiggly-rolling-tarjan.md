# 修復 Harbor 搬上 k8s 後 docker daemon 取像失敗

## Context

Harbor 從 Docker Compose 搬到 k8s（`devops` namespace、`type: LoadBalancer`）之後，
**docker daemon 拉不到 Harbor 的映像**，所有帶 `tags: [twstock]` 的 CI 部署 job 與
本機 `docker build` 都會失敗：

```text
dial tcp 127.0.0.1:8081: connect: connection refused
```

問題不在 port 而在**位址所處的網路命名空間**。已實測確認（本次於 plan mode 重跑一次）：

| 從哪裡連 `127.0.0.1:8081` | 結果 |
| --- | --- |
| macOS 主機（`curl`） | HTTP 200 |
| Docker Desktop VM（`docker run --network host`） | connection refused |
| VM 內 `127.0.0.1:31981`（NodePort） | `docker pull` 成功 |

根因：Docker Desktop 對 `type: LoadBalancer` 的實作是在 **macOS 主機**開 listener
（`lsof` 顯示佔用者為 `com.docker`），那個 listener 不在 VM 內。Compose 版以
`-p 8081:8080` 發佈時 VM 內是有監聽的，搬進 k8s 後就沒有了。而 daemon 拉映像的
來源解析發生在 VM 那一側，所以連不到。

`host.docker.internal:8081` 在 VM 內連得通，但它不是 loopback、不在 daemon 的
insecure registry 清單（`127.0.0.0/8`）內，會被強制走 HTTPS 而失敗——因此不可用。

預期成果：VM 內 `127.0.0.1:8081` 恢復監聽，**所有現有寫死 `127.0.0.1:8081` 的地方
一個字都不用改**（各 repo 的 Dockerfile `FROM`、CI 的 `HARBOR_REGISTRY`、
runner 的 `data/config.toml`），主機端的 Harbor UI 也不受影響。

> GitLab 沒有同樣的問題：runner 的 `config.toml` 走
> `http://host.docker.internal:8080`，git clone 走 HTTP 沒有 insecure-registry
> 那層限制，已實測可達。本次不動 GitLab。

## 影響的 repo

| 項目 | 值 |
| --- | --- |
| repo | `/Users/chen/AI/MacDevelopSyStem` |
| 遠端 | GitHub `nk7260ynpa/MacDevelopSyStem`（單一 remote） |
| 基底分支 | `main`，同步後 HEAD `91baecb` |
| 分支名 | `fix/harbor-hostport-8081` |
| GitLab issue／MR | 無（GitHub repo 只開分支） |

## 實作

### 1. `harbor/k8s/16-proxy.yaml`：proxy 容器加 `hostPort`

Deployment 的 container ports 由

```yaml
ports:
  - name: http
    containerPort: 8080
```

改為

```yaml
ports:
  - name: http
    containerPort: 8080
    hostPort: 8081
```

kubelet（CNI portmap）會在 node（即 Docker Desktop VM）上綁 8081 轉進容器的 8080，
VM 內 `127.0.0.1:8081` 因此恢復監聽。

**Service 維持 `type: LoadBalancer` 不動**——兩者各負責一條路徑，缺一不可：

- LoadBalancer：macOS 主機 → Harbor（瀏覽器 UI、主機上的 `curl`）
- hostPort：Docker Desktop VM → Harbor（docker daemon 拉映像、`--network host` 的容器）

同時把檔案開頭的區塊註解補上這個「兩條路徑」的說明，並在 ports 處以行內註解寫明
hostPort 的用途與為何不能改用 `host.docker.internal`。既有的 `strategy: Recreate`
正好與 hostPort 相容（hostPort 由單一 pod 獨佔，滾動更新會撞埠），不需更動。

### 2. `README.md`：補上文件

- 第 70 行架構樹的 `16-proxy.yaml # LoadBalancer 8081` 註解改為同時反映 hostPort。
- 〈Harbor：透過 Kubernetes（預設）〉之後新增一小節，說明「主機與 VM 是兩個不同的
  網路命名空間」這個 Docker Desktop 特性、失敗徵狀（`dial tcp 127.0.0.1:8081`）
  與修法，讓下次撞到時查得到。
- 〈在 devops 底下新增 Deployment 時〉補一條守則：**服務若需要被 docker daemon 或
  `--network host` 的容器存取，只有 LoadBalancer 不夠，要另外加 `hostPort`。**

`harbor/k8s/apply.sh` 不需更動：`check_port_conflict` 檢查的是 macOS 主機端的 lsof，
且已在 `harbor` Service 存在時短路，加 hostPort 不影響它。本 repo 無 CLAUDE.md、
無 Python 程式碼，故無測試需新增。

> 執行後追記：`apply.sh` 的**邏輯**確實一字未動，但依 verify-agent 的建議另補了
> 註解與失敗提示，說明這道檢查只涵蓋 macOS 主機端、看不到 VM 內的 hostPort 綁定。

## 部署

```bash
kubectl apply -f harbor/k8s/16-proxy.yaml
kubectl -n devops rollout status deployment/proxy
```

（等同 `cd harbor && ./run.sh`，但只動 proxy 一個資源，影響面較小。）

## 驗證

```bash
# 1. pod 要順利起來（hostPort 撞埠會卡在 Pending）
kubectl -n devops get pods -l app.kubernetes.io/component=proxy

# 2. VM 內（daemon 的網路命名空間）應該連得到
docker run --rm --network host busybox:latest \
  sh -c 'wget -q -T3 -O /dev/null http://127.0.0.1:8081/api/v2.0/ping && echo OK'

# 3. daemon 直接拉映像應該成功
docker pull 127.0.0.1:8081/twstock/runner:helper-production

# 4. 主機端的 Harbor UI 不該受影響（LoadBalancer 仍在）
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:8081/api/v2.0/ping
kubectl -n devops get svc harbor   # EXTERNAL-IP 應仍為 localhost

# 5. 端到端：twstock/runner 觸發一次 smoke job，應該跑完
```

第 5 項是最終驗收——smoke job 目前正是卡在取 `helper-production` 這一步。它屬於
`TwStock/runner` repo，**本次不改該 repo 的任何檔案**，只是觸發一次管線確認。

## 風險

- **主要不確定性**：hostPort 與 LoadBalancer 能否在 Docker Desktop 上並存尚未實測。
  理論上可以（前者綁 VM 內、後者綁 macOS 主機端，兩個不同的網路命名空間），且已確認
  VM 內 8081 目前無人監聽。若 apply 後 pod 卡在 `Pending` 或主機端 8081 反而不通，
  **立即 `git revert` 該次提交並重新 apply 還原**，回報後再議替代方案
  （改各 repo 位址為固定 NodePort，成本明顯較高）。
- proxy 會重啟一次（`Recreate`），Harbor 有數十秒不可用；不影響資料。
