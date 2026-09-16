# Harbor 本機開發部署用佔位 Dockerfile。
#
# 注意：Harbor 為多 image 微服務架構（proxy/core/portal/jobservice/registry/
# registryctl/redis/db），實際部署以 docker-compose.yaml 多個 service 啟動，
# 並未使用此 Dockerfile build 出來的 image。
#
# 此檔案保留作為符合專案既定 docker/ 結構，以及日後若需客製化單一 service 之
# 進入點（例如改 harbor-core）。
FROM goharbor/harbor-core:dev@sha256:fef1f0825017f6fec9c9420dc0766ed3b7a201843f20e1967be28ca99fdb70a3

LABEL maintainer="MacDevelopSyStem"
LABEL purpose="本機 macOS 開發環境之 Harbor Registry（佔位 Dockerfile，實際以多 service compose 啟動）"
