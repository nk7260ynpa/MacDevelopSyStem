# GitLab Workhorse 與 Gitaly 的 socket 移出 virtiofs

Notion 任務：[GitLab Workhorse 因 virtiofs 殘留 socket 陷入崩潰迴圈（長期 502）](https://app.notion.com/p/3cadfac2095381d78ff4dbdc6d2a7757)
（Group：MacDevelopSyStem，狀態：In progress）

## Context

2026-08-22 11:42 至 08-28 16:51，GitLab 對外連續 502 約 6.5 天。

根因是 `gitlab-workhorse` 對外 listen 的 unix socket 落在 virtiofs bind mount
（`gitlab/docker/data/data` → `/var/opt/gitlab`）。virtiofs 不支援對 socket 檔
unlink，workhorse 啟動時刪不掉上一輪的殘留檔，以
`shutting down: remove ...: operation not supported` 每秒崩潰一次，nginx 沒有
upstream。容器主行程 `runsvdir` 全程存活，`restart: always` 完全不介入；
`gitlab/run.sh` 的 `clean_stale_state()` 又只在容器未運行時清理，而 daemon
重啟是直接 `start` 容器、不走 `run.sh`——三層機制同時失效，服務沒有任何自癒路徑。

`docker-compose.yaml` 已對 PostgreSQL、Redis、Rails(Puma) 用過同一套解法。本次把最後
兩個元件——Workhorse 與 Gitaly——一併收乾，讓掛載區**再也不存在任何 unix socket**。

範圍與部署時機由使用者確認：Workhorse 與 Gitaly 一併處理，本次實際部署驗證。

## 已查證的關鍵事實

### 一、Gitaly 也一直在撞，而且撞得更兇

README L154 記載 Gitaly「實測可自行重建」。日誌推翻了這個說法——同一段期間 Gitaly
也在崩潰迴圈中，單一輪替檔最高 45,288 次：

```
"error":"unable to start the bootstrap: unlinkat /var/opt/gitlab/gitaly/gitaly.socket: operation not supported"
```

差別只是 Gitaly 靠 runit 每秒重試，偶爾會撞過去（最近一次 2026-08-28 16:18）。
**那是運氣不是設計**，不能當成保留現狀的理由。

### 二、掛載區現存 3 個 socket

```
gitlab/docker/data/data/gitaly/gitaly.socket
gitlab/docker/data/data/gitlab-workhorse/sockets/socket
gitlab/docker/data/data/gitaly/run/gitaly-<pid>/sock.d/intern   ← 在 runtime_dir 內
```

要達成「掛載區不再產生 socket」，**必須連 `runtime_dir` 一起搬**。

官方 image 的 `clean_stale_pids()`（`/assets/init-container`）救不了：它只刪
`*.pid` 與 `socket.?`，`socket` 與 `gitaly.socket` 兩個檔名都不匹配。

### 三、Workhorse：`sockets_directory` 是唯一開關

`libraries/gitlab_workhorse.rb:27,35`：

```ruby
Gitlab['gitlab_workhorse']['sockets_directory'] ||= '/var/opt/gitlab/gitlab-workhorse/sockets' if user_listen_addr.nil?
Gitlab['gitlab_workhorse']['listen_addr'] ||= File.join(sockets_dir, 'socket') if network == "unix"
```

設 `sockets_directory` 後 `listen_addr` 自動跟上，下游全部自動更新、**不需手改**：

| 下游 | 產生位置 |
| --- | --- |
| nginx upstream | `recipes/nginx.rb:78-88` + `nginx-gitlab-workhorse-upstream.conf.erb` |
| `gitlab-shell/config.yml` 的 `gitlab_url` | `libraries/helpers/web_server_helper.rb:11-23` |
| `gitaly/config.toml` 的 `[gitlab] url` | 同上，`gitaly/recipes/enable.rb:96` |

反之若只設 `listen_addr`，`sockets_directory` 會維持 `nil`，Chef 就不會建那個目錄。

`recipes/gitlab-workhorse.rb:35-43` 以 `owner git / group gitlab-www / mode 0750`
建立該目錄；tmpfs 選項對齊這組值，Chef 才會判定為 up-to-date 而不多送一次
`notifies :restart`。

### 四、Gitaly：部分覆寫 `gitaly['configuration']` 不會蓋掉套件預設值

1. `package/recipes/config.rb:39` 以 `node.consume_attributes` 寫進 **normal** 層。
2. Chef 18 的 `hash_only_merge!` 對兩邊都是 Hash 的 key **遞迴合併**。
3. `gitaly/recipes/enable.rb:114-116` 的 template 變數取自 `node.dig(...)`（合併後）。

因此只給 `socket_path` 與 `runtime_dir`，`attributes/default.rb:13-25` 的
`prometheus_listen_addr`、`logging`、`storage`、`gitlab.secret_file` 全數保留；
`auth.token` 另由 `libraries/gitaly.rb:38-40` 以 `||=` 補上。Rails 端的
`gitaly_address` 由 `libraries/gitaly.rb:51-63` 從 `socket_path` 推導後寫進
`gitlab.yml` 的 `storages:`。

### 五、`runtime_dir` 的兩個決定性限制

`/var/opt/gitlab/gitaly/run/gitaly-<pid>/` 實測 **129 MB**，內容是 gitaly 每次啟動
解壓出來的輔助執行檔（`gitaly-hooks`、`gitaly-ssh`、`gitaly-git-*`，mode 0500），
`GIT_EXEC_PATH` 與 `core.hooksPath` 都指向這裡。

1. **必須加 `exec`。** Docker 的 `tmpfs:` 預設帶 `noexec`，本機現有掛載已證實：

   ```
   tmpfs /run/postgresql tmpfs rw,nosuid,nodev,noexec,relatime,mode=755,uid=996,gid=996
   ```

   忘了加會讓所有 git 操作直接掛掉。這是本次最大的單一風險。

2. **必須給 `size`。** 不指定時上限是主機記憶體的一半，而 tmpfs 佔用**計入容器
   cgroup**。現況 `memory.current` 3.20 G / max 4.29 G（74.6%）、`shmem` 68 MB。

### 六、容器內 uid/gid 與設定來源

`git` 998:998、`gitlab-www` 999:999、`gitlab-psql` 996、`gitlab-redis` 997。

`/etc/gitlab/gitlab.rb` 有 0 行有效設定（純 omnibus 樣板、未版控），
`GITLAB_OMNIBUS_CONFIG` 是唯一設定來源。每次容器啟動都會 `gitlab-ctl reconfigure`
（`/assets/init-container:167`），tmpfs 重掛後 Chef 會重建並 chown——這正是我們要的
「每次啟動都乾淨」。

## 變更檔案

| 檔案 | 變更 |
| --- | --- |
| `gitlab/docker/docker-compose.yaml` | `GITLAB_OMNIBUS_CONFIG` +2 段；`tmpfs:` +3 條並改寫該區塊註解 |
| `gitlab/run.sh` | 只改 `clean_stale_state()` 的註解，邏輯不動 |
| `README.md` | L147-156 表格、L165-169、L171-177、L383-391 |
| `plans/reactive-roaming-pillow.md` | 本檔 |

## 實作步驟

### 步驟 0：pre-flight，先確認 tmpfs 的 `exec` 真的生效

整個計畫的最大風險就在這裡，改任何東西之前先擋掉：

```bash
docker run --rm --entrypoint /bin/sh \
  --tmpfs /run/probe:exec,size=8m \
  macdev/gitlab:latest -c \
  'mount | grep " /run/probe "; cp /bin/true /run/probe/t && /run/probe/t && echo EXEC_OK'
```

預期 mount 那行**不含 `noexec`**且印出 `EXEC_OK`。若失敗則**跳過步驟 3**
（`runtime_dir` 留在原處），並在計畫中註記降級。

順手記錄對照基準：

```bash
find gitlab/docker/data/data -type s          # 應為上述 3 個
docker exec gitlab cat /sys/fs/cgroup/memory.current
```

### 步驟 1：Workhorse socket 移出掛載區

`gitlab/docker/docker-compose.yaml`，在 `gitlab_workhorse['auth_backend']` 那行之後
插入（註解密度比照該檔既有風格，解釋「為什麼」）：

```yaml
        # Workhorse 自己對外 listen 的 socket 也搬進 tmpfs。2026-08-22 起的 6.5 天全站
        # 502 就源於此：daemon 直接 start 容器（不走 ../run.sh）時，上一輪殘留在
        # virtiofs 上的 socket 無法 unlink，workhorse 以「shutting down: remove ...:
        # operation not supported」每秒崩潰一次，nginx 沒有 upstream。容器主行程
        # runsvdir 從頭到尾都活著，restart: always 完全不介入——這正是「容器 Up、
        # 對外卻 502」的成因。
        # 只需 sockets_directory 這一個開關：listen_addr 未指定時，omnibus 會以
        # File.join(sockets_directory, 'socket') 自動補上（libraries/gitlab_workhorse.rb
        # :27,35），nginx upstream、gitlab-shell 與 gitaly 的 gitlab.url 都由同一組值
        # 衍生，reconfigure 時全數自動跟上。反之若只改 listen_addr，sockets_directory
        # 會維持 nil，Chef 就不會去建那個目錄。
        gitlab_workhorse['sockets_directory'] = '/run/gitlab-workhorse'
```

### 步驟 2：Gitaly socket 移出掛載區

接續插入：

```yaml
        # Gitaly 同理，症狀是「unable to start the bootstrap: unlinkat ...:
        # operation not supported」。它靠 runit 每秒重試偶爾能撞過去（單一輪替日誌
        # 最高 45288 次失敗），先前因此被誤記為「實測可自行重建」——那是運氣不是設計。
        # gitaly['configuration'] 是 hash，這裡只給部分 key 不會蓋掉套件預設值：
        # 設定經 node.consume_attributes 寫進 normal 層（package/recipes/config.rb:39），
        # 與 attributes/default.rb 的 default 層由 Chef 的 hash_only_merge 遞迴合併，
        # 未指定的 prometheus_listen_addr、logging、storage、gitlab.secret_file 一律
        # 保留；auth.token 由 libraries/gitaly.rb:38-40 以 ||= 補上。Rails 端的
        # gitaly_address 也由 socket_path 推導後寫進 gitlab.yml 的 storages:。
        gitaly['configuration'] = {
          socket_path: '/run/gitaly/gitaly.socket',
          runtime_dir: '/run/gitaly-runtime',
        }
```

### 步驟 3：`tmpfs:` 區塊

取代現有的 tmpfs 區塊（含註解）：

```yaml
    # GitLab 元件之間互連用的 unix socket 一律不落在 bind mount：macOS 的 virtiofs
    # 不支援對 socket 檔 unlink／chmod，只要上一輪留下殘留檔，元件就永遠起不來。
    # tmpfs 每次容器 start 都是全新的，連 daemon 繞過 ../run.sh 直接 start 也保證乾淨，
    # restart: always 對 GitLab 才真正成立。
    # uid/gid 皆為 image 內建帳號：gitlab-psql 996、gitlab-redis 997、git 998、
    # gitlab-www 999。mode 一律對齊 omnibus 自己建立該目錄時的權限，reconfigure 才會
    # 判定為已就緒而不去動它（也就不會多送一次 notifies :restart）。
    tmpfs:
      # PostgreSQL／Redis：socket 由 omnibus 以 unixsocketperm 777 建立，目錄給 0755
      # 讓以 git 執行的 Rails、Sidekiq、Workhorse 得以進入連線。
      - /run/postgresql:uid=996,gid=996,mode=0755
      - /run/gitlab-redis:uid=997,gid=997,mode=0755
      # Workhorse：連線方是以 gitlab-www 執行的 nginx，故 group 給 gitlab-www、
      # mode 0750，與 recipes/gitlab-workhorse.rb:35-43 建立此目錄時完全一致。
      - /run/gitlab-workhorse:uid=998,gid=999,mode=0750
      # Gitaly socket：連線方只有以 git 執行的 Rails／Sidekiq／gitlab-shell，0700 即可。
      # 這個目錄沒有對應的 Chef directory 資源，權限完全由這一行決定。
      - /run/gitaly:uid=998,gid=998,mode=0700
      # Gitaly runtime_dir：與上面的 socket 目錄分開掛，因為兩者需求相反。
      # 1. 必須加 exec。gitaly 每次啟動會把約 129 MB 的輔助執行檔（gitaly-hooks、
      #    gitaly-ssh、gitaly-git-* 等，mode 0500）解到這裡，之後每個 git 操作都要
      #    從這裡 exec（GIT_EXEC_PATH 與 core.hooksPath 都指向它）。docker 的 tmpfs
      #    預設帶 noexec，不明確加 exec 會讓所有 git 操作直接掛掉。
      # 2. 必須給 size。tmpfs 不指定時上限是主機記憶體的一半，而其佔用計入本容器的
      #    4G cgroup。單一世代 129 MB、優雅重啟期間新舊並存約 260 MB，取 512m 留餘裕；
      #    日後 gitaly 版本增加輔助執行檔時須同步調高。
      # 順帶解掉兩件事：內部 socket（sock.d/intern）是掛載區最後一個 socket；
      # 以及每次啟動不必再把 129 MB 寫穿 virtiofs。
      - /run/gitaly-runtime:exec,size=512m,uid=998,gid=998,mode=0700
```

**為何 socket 與 runtime_dir 分開兩個 tmpfs**：掛載選項需求相反（前者不該開 exec）；
`runtime_dir` 撐爆容量時不應連帶讓 socket 建不起來；`runtime_dir` 有 Chef `directory`
資源（`enable.rb:48`，`owner git / mode 0700`）會自我校正權限，`/run/gitaly` 沒有。

### 步驟 4：`gitlab/run.sh` 註解

**函式保留，邏輯一行不改，只改註解。**保留的三個理由：清掉本次搬移前留下的孤兒檔；
`chmod 2770` 那半段與 socket 無關且仍然必要（setgid 限制無法從設定面解決）；
設定被回滾時它是唯一兜底，「容器運行中即跳過」的 guard 同理保留。

需要改的是已失效的那句「留在掛載區的只剩 Gitaly 與 Workhorse 的 socket」，改為四個
元件的 socket 皆已移出、socket 清理降級為防呆，並說明保留理由。

### 步驟 5：`README.md`

1. **L147-156**：導語改為「**所有元件的 socket 都已從根本移出 virtiofs**」；表格
   把 `| Gitaly、Workhorse | socket 仍在掛載區… |` 那列拆成 Workhorse 與 Gitaly 兩列，
   指向各自的 tmpfs 路徑。表格後補一段事故紀錄：6.5 天 502 的時間軸、Gitaly 的
   「可自行重建」其實是重試撞運氣、官方 `clean_stale_pids()` 不匹配這兩個檔名、
   以及搬 `runtime_dir` 的代價（129 MB 計入 4G 上限、tmpfs 必須加 `exec`）。
2. **L165-169**：`run.sh` 的 socket 清理改述為「已降級為防呆」，`2770` 那半段仍必要。
3. **L171-177**：疑難排解的前提「須在容器停止的狀態下檢查」已不成立，改為更強的
   不變式——`find gitlab/docker/data/data -type s` **不分容器狀態**都應無輸出；
   並補上確認 socket 落在 tmpfs、且 `/run/gitaly-runtime` 不得出現 `noexec` 的指令。
4. **L383-391**：「已把會出事的三段連線全部移出掛載區，因此可完全自行恢復」這句被本次
   事故推翻，改為「所有元件」並加註引言：判準是「socket 是否落在 `/var/opt/gitlab`
   底下」，不是「實測有沒有恢復」。502 檢查表補上 Workhorse 與 Gitaly 自身 socket 兩列
   （用 `grep -c 'operation not supported'`，因 `current` 會被 svlogd 輪替）。

## Commit 拆解

分支 `fix/gitlab-socket-tmpfs`，基底 `main` @ `2ee1bcf`，遠端 GitHub
`nk7260ynpa/MacDevelopSyStem`（單一 remote）。繁體中文約定式提交，50/72：

1. `fix(gitlab): workhorse socket 移出 virtiofs`
2. `fix(gitlab): gitaly socket 與 runtime_dir 移出 virtiofs`
3. `refactor(gitlab): 收斂 run.sh 的 socket 清理職責`
4. `docs(readme): 更新 socket 全數移出 virtiofs 的說明`
5. `docs(plans): 新增 socket 移出 virtiofs 的實作計畫`

## 驗證

### A. 靜態檢查

```bash
docker compose -f gitlab/docker/docker-compose.yaml config -q
bash -n gitlab/run.sh
```

### B. 部署

```bash
cd gitlab && ./run.sh stop && ./run.sh
```

`./run.sh stop` 走不帶 `--remove-orphans` 的 `docker compose down`，並讓下一次
`./run.sh` 的 `clean_stale_state()` 清掉兩個孤兒 socket。等 healthy（含 reconfigure
約 3-5 分鐘）。

### C. 部署後實測

| 項目 | 指令 | 預期 |
| --- | --- | --- |
| socket 落在 tmpfs | `docker exec gitlab ls -l /run/gitlab-workhorse/socket /run/gitaly/gitaly.socket` | 兩個都存在且型別為 `s` |
| 掛載選項正確 | `docker exec gitlab sh -c 'mount \| grep -E "/run/(gitlab-workhorse\|gitaly)"'` | `/run/gitaly-runtime` **不含 `noexec`**、含 `size=524288k` |
| **掛載區不再有 socket** | `find gitlab/docker/data/data -type s` | **無輸出**（部署前 3 個）——最直接的成功指標 |
| nginx upstream 自動跟上 | `docker exec gitlab cat /var/opt/gitlab/nginx/conf/upstream_definitions/gitlab-workhorse.conf` | `server unix:/run/gitlab-workhorse/socket;` |
| gitaly 預設值未被蓋掉 | `docker exec gitlab cat /var/opt/gitlab/gitaly/config.toml` | `socket_path`／`runtime_dir` 已更新，且仍保有 `prometheus_listen_addr`、`[logging]`、`[[storage]]`、`secret_file` |
| Rails 位址自動跟上 | `docker exec gitlab grep -n 'storages:' /var/opt/gitlab/gitlab-rails/etc/gitlab.yml` | `unix:/run/gitaly/gitaly.socket` |
| 服務正常 | `docker exec gitlab curl -s -o /dev/null -w '%{http_code}' http://localhost/-/health`（與 `/-/readiness`） | 皆 200。**須在容器內 curl**，從主機打會被 monitoring whitelist 擋成 404 |
| 無崩潰迴圈 | `docker exec gitlab grep -c 'operation not supported' /var/log/gitlab/{gitlab-workhorse,gitaly}/current` | 皆 `0` |

**`exec` 生效的實測**（最能證明 `runtime_dir` 沒問題）：

```bash
docker exec gitlab gitlab-rake gitlab:gitaly:check
# 再做一次真正的寫入：clone → 空 commit → push
```

push 會觸發 `pre-receive`／`post-receive`（symlink 指向
`/run/gitaly-runtime/gitaly-<pid>/gitaly-hooks`），**push 成功即證明 `exec` 有效**。
只做 clone 不夠。

### D. 最關鍵：模擬 daemon 直接 start 容器

```bash
docker stop gitlab && docker start gitlab
until [ "$(docker inspect -f '{{.State.Health.Status}}' gitlab)" = healthy ]; do sleep 10; done
```

這一步繞過 `run.sh`（沒有任何 socket 清理），**正是 2026-08-22 那次會爆掉的路徑**。
完整重跑 C 的所有項目，並確認 `gitlab-ctl status` 各服務存活秒數持續增長。

### E. 記憶體回歸

```bash
docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' gitlab
docker exec gitlab grep -E '^(anon|shmem) ' /sys/fs/cgroup/memory.stat
```

基準：改動前 `memory.current` 3.20 G / 4.29 G（74.6%）、`shmem` 68 MB。
預期 `shmem` 升至約 200 MB，`MemPerc` 不應超過 85%。

## 風險與應對

| 風險 | 影響 | 應對 |
| --- | --- | --- |
| **tmpfs `exec` 未生效** | gitaly 所有 git 操作與 hooks 失敗 | 步驟 0 的 pre-flight 先擋；驗證 C 檢查 `mount`、以 push 實測。失敗則放棄 `runtime_dir` 那半段，改回原路徑——代價是掛載區仍有 1 個 socket，但它是 PID 命名、不需同路徑 unlink，不會重演事故 |
| 記憶體吃緊（tmpfs 計入 cgroup） | OOM kill | 現況 74.6%，新增約 129 MB（約 3%）。`size=512m` 是上限不是保留量。逼近 90% 時優先退掉 `runtime_dir`，其次把 `limits.memory` 調到 5G |
| `/run/gitaly` 的 uid 硬編碼 | 升級 image 若 `git` uid 變動，gitaly 建不出 socket | 此目錄無 Chef `directory` 資源會自我校正（另兩個有）。升級後跑 `docker exec gitlab getent passwd git gitlab-www` 對照；症狀明確為 `permission denied` |
| `gitaly['configuration']` 部分覆寫蓋掉預設值 | storage 消失、Prometheus 位址跑掉 | 已從 Chef 18 `hash_only_merge!` 原始碼確認為遞迴合併；驗證 C 逐項核對 `config.toml` |
| reconfigure 期間 5xx | 數分鐘中斷 | 使用者已接受 |
| tmpfs 路徑完全走不通（極端） | — | 降級為 TCP：`gitlab_workhorse['listen_network'] = 'tcp'` + **必須同時給** `listen_addr`（守衛 `if network == "unix"` 會讓 run script 產生空的 `-listenAddr`）；gitaly 則改 `listen_addr: 'localhost:8075'` 並清空 `socket_path` |

**回滾**：改動全在設定層，**沒有動到任何資料**（repositories、PostgreSQL 資料、
Redis RDB 都留在 `data/data` 原處），回滾零資料風險。

```bash
git checkout main -- gitlab/docker/docker-compose.yaml gitlab/run.sh
cd gitlab && ./run.sh stop && ./run.sh
```

## 部署決策

本次**執行實際部署**（使用者已核可）：`cd gitlab && ./run.sh stop && ./run.sh`。

理由：這是純執行期行為的修正，靜態檢查無法證明任何一項驗收條件。特別是驗證 D 的
「`docker stop` / `docker start` 繞過 `run.sh` 後仍能自行恢復」——這是唯一能證明修正
真正生效的實驗，非部署不可。

**不使用** `docker compose down --remove-orphans`。Harbor、GitLab Runner 與其他容器
全程不動。

## 不做的事

- 不改動 PostgreSQL、Redis、Puma 的既有 socket 設定（已驗證有效）。
- 不移除 `clean_stale_state()`，也不改它的執行邏輯（只改註解）。
- 不改 `gitaly['dir']`：`config.toml`、`.gitlab_secret`、`VERSION`、`gitaly.pid`
  仍留在掛載區——它們不是 socket，unlink 正常。
- 不改 `gitlab_workhorse['listen_addr']`／`listen_network`（設了反而會讓
  `sockets_directory` 維持 `nil`）。
- 不動 nginx 設定（upstream 完全由 omnibus 依 `listen_addr` 產生）。
- 不改寫 `plans/` 既有的歷史計畫紀錄。
- 不在 `run.sh` 裡加入舊目錄的一次性刪除。
- 不合併分支、不回寫 Notion `狀態: Done`——留給 `/gitflow2`。
