FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90 AS toolchain

# The minimal Ubuntu image has no trust store. Bootstrap only the current snapshot server's root
# from a checksum-pinned Ubuntu package, then install every build dependency from one immutable
# Ubuntu archive snapshot. The package manifest is exported with the binaries.
ADD --checksum=sha256:6bac2a01979e210d9eac1d4d56747ec709ea60654744d66705dc3c36e7629e50 \
  https://snapshot.ubuntu.com/ubuntu/20260713T120000Z/pool/main/c/ca-certificates/ca-certificates_20260601~24.04.1_all.deb \
  /tmp/dory-ca-certificates.deb
RUN mkdir -p /tmp/dory-ca /etc/ssl/certs && \
    dpkg-deb -x /tmp/dory-ca-certificates.deb /tmp/dory-ca && \
    cp /tmp/dory-ca/usr/share/ca-certificates/mozilla/ISRG_Root_X1.crt \
      /etc/ssl/certs/ca-certificates.crt && \
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://snapshot.ubuntu.com/ubuntu/20260713T120000Z' \
      'Suites: noble noble-updates noble-backports noble-security' \
      'Components: main universe restricted multiverse' \
      'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/ubuntu.sources && \
    DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates clang cmake g++ git libcap-dev lld ninja-build pkg-config python3 python3-dev && \
    dpkg-query -W -f='${binary:Package}=${Version}\n' | LC_ALL=C sort \
      > /build-packages.txt && \
    rm -rf /tmp/dory-ca /tmp/dory-ca-certificates.deb /var/lib/apt/lists/*

FROM toolchain AS builder
COPY . /src
WORKDIR /src
ENV SOURCE_DATE_EPOCH=1783039651 TZ=UTC LC_ALL=C LANG=C PYTHONHASHSEED=0 ZERO_AR_DATE=1
RUN CC=clang CXX=clang++ cmake -S . -B Build -G Ninja \
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
      -DCMAKE_EXE_LINKER_FLAGS=-static-pie \
      -DUSE_LINKER=lld && \
    cmake --build Build --target FEX FEXServer --parallel 2

FROM scratch
COPY --from=builder /src/Build/Bin/FEX /FEX
COPY --from=builder /src/Build/Bin/FEXServer /FEXServer
COPY --from=builder /build-packages.txt /build-packages.txt
