ARG GO_IMAGE=golang:1.25-bookworm
ARG RUNTIME_IMAGE=alpine:3.19.1
ARG GOPROXY=https://goproxy.cn,direct
ARG APK_MIRROR=mirrors.aliyun.com

FROM ${GO_IMAGE} AS builder

WORKDIR /src/sealdice-core

ARG GOPROXY
ENV GOPROXY=${GOPROXY}

COPY sealdice-core/go.mod sealdice-core/go.sum ./
RUN go mod download

COPY sealdice-core ./

ARG VERSION=docker
ARG TARGETARCH=amd64
ENV CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH}
RUN go build -trimpath \
    -ldflags "-s -w -X sealdice-core/dice.VERSION_PRERELEASE=-docker -X sealdice-core/dice.VERSION_BUILD_METADATA=+${VERSION}" \
    -o /out/sealdice-core .

FROM ${RUNTIME_IMAGE}

ARG APK_MIRROR
RUN sed -i "s|dl-cdn.alpinelinux.org|${APK_MIRROR}|g" /etc/apk/repositories \
    && apk update \
    && apk add --no-cache tzdata \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
ENV TZ=Asia/Shanghai

WORKDIR /
VOLUME ["/data", "/backups"]

COPY --from=builder /out/sealdice-core /usr/local/bin/sealdice-core
COPY --chmod=0755 docker/entrypoint.sh /entrypoint.sh
COPY sealdice-core/data /opt/sealdice/buildin-data

EXPOSE 3211
ENTRYPOINT ["/entrypoint.sh"]
