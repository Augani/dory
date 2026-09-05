# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
ARG XX_IMAGE=tonistiigi/xx:1.9.0@sha256:c64defb9ed5a91eacb37f96ccc3d4cd72521c4bd18d5442905b95e2226b0e707
ARG BUILDER_IMAGE=golang:1.25.9-bookworm@sha256:298734aec230b5f3e8cee450ce6d7eccc39f1797ba548ee90d57e9803030c6c3
FROM --platform=$BUILDPLATFORM ${XX_IMAGE} AS xx

FROM --platform=$BUILDPLATFORM ${BUILDER_IMAGE} AS build
COPY --from=xx / /

ARG TARGETPLATFORM
ARG TARGETARCH
ARG BUILDARCH
ARG VERSION
ARG DOCKER_GITCOMMIT
ARG SOURCE_DATE_EPOCH
ARG PLATFORM_NAME
ARG PRODUCT_NAME
ARG DEFAULT_PRODUCT_LICENSE
ARG DEBIAN_SNAPSHOT

ENV GOTOOLCHAIN=local
ENV PREFIX=/tmp

RUN set -eux; \
    rm -f /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; \
    { \
      echo "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} bookworm main"; \
      echo "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT} bookworm-security main"; \
      echo "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} bookworm-updates main"; \
    } > /etc/apt/sources.list; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends \
      bash \
      binutils \
      ca-certificates \
      file \
      make \
      pkg-config; \
    xx-apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends \
      gcc \
      libc6-dev \
      libnftables-dev \
      libseccomp-dev \
      libsystemd-dev; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    set -eux; \
    xx-go --wrap; \
    export PKG_CONFIG="$(xx-go env PKG_CONFIG)"; \
    export VERSION; \
    export DOCKER_GITCOMMIT; \
    export SOURCE_DATE_EPOCH; \
    export PLATFORM="$PLATFORM_NAME"; \
    export PRODUCT="$PRODUCT_NAME"; \
    export DEFAULT_PRODUCT_LICENSE; \
    export KEEPBUNDLE=1; \
    ./hack/make.sh binary-daemon; \
    install -D -m0755 /tmp/bundles/binary-daemon/dockerd /out/dockerd; \
    file /out/dockerd; \
    xx-verify --static /out/dockerd; \
    if [ "$TARGETARCH" = "$BUILDARCH" ]; then /out/dockerd --version; else echo "skipping build-stage dockerd execution for linux/$TARGETARCH on linux/$BUILDARCH builder"; fi

FROM scratch AS artifact
COPY --from=build /out/dockerd /dockerd
