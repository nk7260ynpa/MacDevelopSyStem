# 版本釘選（勿改回 :latest）：
#   Runner 版本不得高於 GitLab 主體版本，故跟隨主體所在的次版本分支——
#   主體為 19.2.4 時取 19.2 分支最新的 v19.2.2（官方 :latest 目前指向
#   v19.3.0，高於主體，不採用）。升級 GitLab 主體時應一併檢視此處。
#   config.toml 未釘選 helper_image，helper 會自動跟隨 Runner 版本。
FROM gitlab/gitlab-runner:v19.2.2

LABEL maintainer="MacDevelopSyStem"
LABEL purpose="本機 macOS 開發環境之 GitLab Runner（docker executor）"

# 目前直接沿用官方 image，未做修改；保留作為日後客製化進入點。
