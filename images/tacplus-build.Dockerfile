# The image every service build step runs in: tacplus's full build image (every
# language toolchain and protoc plugin, public on ghcr) with this fleet's pinned
# tacplus binary on top, and the Java containers' launcher built from source
# (images/build.sh clones github.com/tacplus-dev/launcher at the pinned commit
# into launcher/ beside this file). The slim tacplus image has no compilers.
# It builds for both platforms whatever it runs on: a launcher per platform, and
# Rust's targets with a C compiler for each (ring and bzip2-sys compile C).
ARG BUILD_IMAGE=ghcr.io/tacplus-dev/tacplus/build:2.3
ARG TACPLUS_IMAGE
FROM ${TACPLUS_IMAGE} AS tacplus
FROM ${BUILD_IMAGE} AS launcher
COPY launcher/ /src/launcher/
RUN cd /src/launcher && for arch in amd64 arm64; do \
      CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -ldflags="-s -w" -o /out/launcher-linux-$arch . ; \
    done
FROM ${BUILD_IMAGE}
RUN rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      gcc-x86-64-linux-gnu libc6-dev-amd64-cross gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
 && rm -rf /var/lib/apt/lists/*
ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
    CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc \
    AR_x86_64_unknown_linux_gnu=x86_64-linux-gnu-ar \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
    AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar
COPY --from=tacplus /usr/local/bin/tacplus /usr/local/bin/tacplus
COPY --from=launcher /out/ /usr/local/bin/
WORKDIR /workspace
