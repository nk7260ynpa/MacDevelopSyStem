# Harbor 本機開發部署用佔位 Dockerfile。
#
# 注意：Harbor 為多 image 微服務架構（proxy/core/portal/jobservice/registry/
# registryctl/redis/db），實際部署以 docker-compose.yaml 多個 service 啟動，
# 並未使用此 Dockerfile build 出來的 image。
#
# 此檔案保留作為符合專案既定 docker/ 結構，以及日後若需客製化單一 service 之
# 進入點（例如改 harbor-core）。
#
# 基底映像版本同樣取自 ../versions.env，不在本檔寫死。真要建置時：
#   docker build --build-arg HARBOR_IMAGE_CORE="$(. ../versions.env; echo "$HARBOR_IMAGE_CORE")" .
ARG HARBOR_IMAGE_CORE
FROM ${HARBOR_IMAGE_CORE}

LABEL maintainer="MacDevelopSyStem"
LABEL purpose="本機 macOS 開發環境之 Harbor Registry（佔位 Dockerfile，實際以多 service compose 啟動）"
