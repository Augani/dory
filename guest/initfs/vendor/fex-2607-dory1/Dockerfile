FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90 AS builder

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates clang cmake git libcap-dev lld ninja-build pkg-config python3 python3-dev && \
    rm -rf /var/lib/apt/lists/* && \
    if [ ! -e /usr/lib/dory/fex/ld-linux-aarch64.so.1 ]; then \
      mkdir -p /usr/lib/dory/fex/lib; \
      ln -s /lib/ld-linux-aarch64.so.1 /usr/lib/dory/fex/ld-linux-aarch64.so.1; \
    fi

COPY . /src
WORKDIR /src
RUN cmake -S . -B Build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DBUILD_FEXCONFIG=False \
      -DBUILD_TESTING=False \
      -DBUILD_THUNKS=False \
      -DENABLE_ASSERTIONS=False \
      -DENABLE_LTO=False \
      -DOVERRIDE_VERSION=FEX-2607 \
      -DOVERRIDE_HASH=1cc4b93e7a71c883ec021b71359f136394dc1f3c \
      -DTUNE_ARCH=generic \
      -DTUNE_CPU=none \
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=True \
      -DCMAKE_INSTALL_RPATH=/usr/lib/dory/fex/lib \
      -DCMAKE_EXE_LINKER_FLAGS=-Wl,--disable-new-dtags,--dynamic-linker=/usr/lib/dory/fex/ld-linux-aarch64.so.1 \
      -DUSE_LINKER=lld && \
    cmake --build Build --target FEX FEXServer --parallel 2

FROM scratch
COPY --from=builder /src/Build/Bin/FEX /FEX
COPY --from=builder /src/Build/Bin/FEXServer /FEXServer
