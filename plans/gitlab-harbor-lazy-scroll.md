# GitLab / Harbor 開機自動啟動

## Context（背景）

使用者希望「電腦重開機後，GitLab 與 Harbor 自動啟動」。

調查現狀：

- **Harbor**：已有完整開機自啟機制 `harbor/boot/`，含 `autostart`（登入後等 Docker daemon
  就緒再依序 `compose up -d`）+ `watchdog`（每 120s 巡檢自我修復）兩層 LaunchAgent，以及
  `install.sh` / `uninstall.sh`。Harbor 需要這套，是因為它有 9 個 service、存在冷啟動競態。
  → **Harbor 已達成需求，本次不改其機制，僅納入頂層一鍵安裝並於 README 一併說明。**

- **GitLab**：單容器，`restart: unless-stopped`，**無 LaunchAgent**。
- **GitLab Runner**：單容器，`restart: unless-stopped`，**無 LaunchAgent**；依賴 GitLab
  （`host.docker.internal:8080`）。

關鍵差異：GitLab / Runner 是單容器，沒有 Harbor 的多 service 排序問題。`restart:
unless-stopped` 在「主機重開機 + Docker Desktop 自啟 + 上次為 running」時即會自動恢復；
本次補上的 `autostart` LaunchAgent 額外涵蓋「上次被 `down`/`stop`、或容器被移除」的盲區，
並與 Harbor 取得一致的管理模式。

**決策（已與使用者確認）**：
1. 範圍：GitLab + GitLab Runner 都做。
2. 機制深度：只做 **autostart 單層**（不加 watchdog；單容器靠 restart policy + autostart 已足夠）。
3. 安裝入口：新增**頂層一鍵** `install-all.sh` / `uninstall-all.sh`，同時各服務保留自己的 `boot/install.sh`。

**前提（非專案檔案可控，需手動確認）**：所有 container 能在重開機後恢復，前提是
**Docker Desktop 本身設為登入時自動啟動**（Docker Desktop → Settings → General → 勾選
"Start Docker Desktop when you sign in"）。計畫的驗證段會再次提醒。

---

## 方案：複製 Harbor 的 autostart 模式至 GitLab / Runner

沿用 `harbor/boot/` 已驗證的範本：plist 用 `__XXX_DIR__` 佔位符，`install.sh` 以
`sed` 替換為實際絕對路徑後寫入 `~/Library/LaunchAgents/` 並 `launchctl bootstrap` 載入。
腳本內補 `PATH`（launchd 環境精簡）、輪詢等待 Docker daemon、寫時間戳 log。

### 1. GitLab：`gitlab/boot/`（新增）

參考 `harbor/boot/harbor-autostart.sh`、`harbor/boot/install.sh`、
`harbor/boot/com.chen.harbor-autostart.plist`，移除 watchdog 與互斥鎖（單層不需要）：

- **`gitlab-autostart.sh`**：補 PATH → 輪詢等 Docker daemon 就緒（上限 300s，間隔 5s）
  → 執行 `gitlab/run.sh`（即 `compose up -d`）→ 全程寫 `gitlab/logs/gitlab-autostart.log`。
- **`com.chen.gitlab-autostart.plist`**：`Label` = `com.chen.gitlab-autostart`、
  `RunAtLoad` = true、`ProcessType` = Background、StandardOut/ErrorPath 指向
  `__GITLAB_DIR__/logs/gitlab-autostart.launchd.log`、佔位符 `__GITLAB_DIR__`。
- **`install.sh` / `uninstall.sh`**：與 Harbor 同邏輯，但 `LABELS` 僅
  `com.chen.gitlab-autostart` 一個、佔位符改 `__GITLAB_DIR__`、目錄變數改 `GITLAB_DIR`。

### 2. GitLab Runner：`gitlab-runner/boot/`（新增）

同上，但 autostart 須處理「依賴 GitLab」與「尚未註冊」兩點：

- **`gitlab-runner-autostart.sh`**：補 PATH → 等 Docker daemon 就緒 → **若無
  `docker/data/config.toml`（尚未 `register`）則寫一筆 log 後靜默結束**（不報錯）→
  輪詢等 GitLab 健康（`curl -fsS http://localhost:8080/-/health`，上限 300s；逾時仍續啟
  動，因 runner 連不上會自行重連）→ 執行 `gitlab-runner/run.sh up` →
  寫 `gitlab-runner/logs/gitlab-runner-autostart.log`。
- **`com.chen.gitlab-runner-autostart.plist`**：`Label` =
  `com.chen.gitlab-runner-autostart`、佔位符 `__RUNNER_DIR__`、其餘同 GitLab。
- **`install.sh` / `uninstall.sh`**：`LABELS` 僅 `com.chen.gitlab-runner-autostart`、
  佔位符 `__RUNNER_DIR__`。

> 啟動順序：三個 LaunchAgent 各自 `RunAtLoad` 並行觸發，不靠 launchd 排序；Runner 對
> GitLab 的依賴由腳本內輪詢 GitLab health 處理，Harbor / GitLab 彼此無依賴可並行。

### 3. 頂層一鍵：`install-all.sh` / `uninstall-all.sh`（專案根，新增）

- **`install-all.sh`**：依序 `bash harbor/boot/install.sh`、`bash gitlab/boot/install.sh`、
  `bash gitlab-runner/boot/install.sh`（各腳本以 `BASH_SOURCE` 自解析路徑，從任何 cwd 呼叫皆可）。
- **`uninstall-all.sh`**：反向依序呼叫三個 `boot/uninstall.sh`。
- 開頭印出提示：本機制僅在 Docker Desktop 已設為登入自啟時生效。

### 4. 文件與設定

- **`README.md`**：在現有「開機自動啟動與守護巡檢」（第 341 行起，Harbor）章節後，補上
  GitLab / Runner 的 `autostart` 說明、`boot/` 檔案表、以及頂層 `install-all.sh` /
  `uninstall-all.sh` 一鍵用法；並標註 Docker Desktop 登入自啟為前提。
- **`.gitignore`**：無需改動。現有 `*.log` 與 `logs/` 規則已涵蓋新增的
  `gitlab/logs/`、`gitlab-runner/logs/` 及其 `*.launchd.log`。

### 檔案清單

新增：
```
gitlab/boot/gitlab-autostart.sh
gitlab/boot/com.chen.gitlab-autostart.plist
gitlab/boot/install.sh
gitlab/boot/uninstall.sh
gitlab-runner/boot/gitlab-runner-autostart.sh
gitlab-runner/boot/com.chen.gitlab-runner-autostart.plist
gitlab-runner/boot/install.sh
gitlab-runner/boot/uninstall.sh
install-all.sh
uninstall-all.sh
```
修改：`README.md`

所有 `.sh` 遵循 Google Shell Style Guide、繁體中文註解；plist 與 install/uninstall 直接
比照 `harbor/boot/` 既有檔案改寫。

---

## 驗證（Verification）

1. **前提確認**：開啟 Docker Desktop → Settings → General，確認已勾選 "Start Docker
   Desktop when you sign in"（未勾則重開機後 daemon 不啟動，任何自啟機制都無效）。

2. **安裝**：於專案根執行 `bash install-all.sh`，確認輸出三個服務皆 `bootstrap` 成功。
   ```bash
   launchctl print gui/$(id -u)/com.chen.gitlab-autostart        # 應列出已載入
   launchctl print gui/$(id -u)/com.chen.gitlab-runner-autostart # 應列出已載入
   ```

3. **不重開機即測試 autostart**（模擬登入觸發）：
   ```bash
   # 先停掉 GitLab，再 kickstart autostart，應被自動拉起
   cd gitlab && ./run.sh stop
   launchctl kickstart -k gui/$(id -u)/com.chen.gitlab-autostart
   tail -f gitlab/logs/gitlab-autostart.log      # 觀察「等待 daemon → 啟動完成」
   cd gitlab && ./run.sh status                  # gitlab 應 Up

   # Runner 同法（需已 register 過，否則應 log「尚未註冊，略過」）
   launchctl kickstart -k gui/$(id -u)/com.chen.gitlab-runner-autostart
   tail -f gitlab-runner/logs/gitlab-runner-autostart.log
   ```

4. **端到端**：實際重開機一次，登入後等數分鐘，確認 `docker ps` 內 Harbor 全部 service、
   GitLab、GitLab Runner 皆自動恢復為 running。

5. **卸載驗證**（可選）：`bash uninstall-all.sh` 後再 `launchctl print` 應查無 agent，
   且執行中的容器不受影響。

完成後依個人偏好：同步更新 `README.md`，檢查通過即 commit（Conventional Commits，繁中）
並 push。
