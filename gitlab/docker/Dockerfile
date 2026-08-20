# GitLab CE 本機開發部署用 image。
#
# 本檔案保留作為日後客製化的進入點（例如安裝額外套件、注入初始化腳本）；
# 目前直接沿用官方 image，未做任何修改。
#
# 版本釘選（勿改回 :latest）：
#   GitLab 有「必經升級停點」規則，跨越停點的升級會導致資料庫遷移失敗。
#   停點清單以官方 repo 的 config/upgrade_path.yml 為準，19.x 為
#   19.2、19.5、19.8、19.11。浮動的 :latest 有機會在某次重拉時一口氣
#   跨過停點，故一律釘選版本號，讓每次升級都是刻意且可回溯的決定。
#
#   升級前務必：
#     1. 查 upgrade_path.yml 確認自目前版本到目標版本的必經停點。
#     2. 確認背景遷移已全數完成（BatchedMigration 無 status != 3 者）。
#     3. 備份 ./data 目錄。
FROM gitlab/gitlab-ce:19.2.4-ce.0

LABEL maintainer="MacDevelopSyStem"
LABEL purpose="本機 macOS 開發環境之自架 GitLab CE"
