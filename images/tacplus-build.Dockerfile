# The image every service build step runs in: tacplus's full build image (every
# language toolchain and protoc plugin, public on ghcr) with this fleet's pinned
# tacplus and the Java containers' launcher, each built here from its source
# (images/build.sh clones github.com/tacplus-dev/tacplus and launcher at the
# pinned commits into tacplus/ and launcher/ beside this file). There is no
# tacplus image to take tacplus from since tacplus 2.4 (tacplus-dev/tacplus#193;
# #65), and the build image's own tacplus runs a pinned release, not a commit:
# tacplus is built as ci/tools.sh builds bin/tacplus, stamped TACPLUS_VERSION.
# It builds for both platforms whatever it runs on: a launcher per platform, and
# Rust's targets with a C compiler for each (ring and bzip2-sys compile C).
ARG BUILD_IMAGE=ghcr.io/tacplus-dev/tacplus/build:20261123-ef62327@sha256:8cf5ff0891c3bd73121eb7f94df97cfb311cfe55e602b0ae7d1e2b22384a5851
FROM ${BUILD_IMAGE} AS tacplus
ARG TACPLUS_VERSION
ARG TACPLUS_COMMIT
COPY tacplus/ /src/tacplus/
RUN cd /src/tacplus && pkg=github.com/tacplus-dev/tacplus/pkg/buildinfo \
 && go generate ./pkg/internal/proto/spec/... \
 && CGO_ENABLED=0 go build -trimpath \
      -ldflags="-w -s -X $pkg.Version=${TACPLUS_VERSION} -X $pkg.GitSha=${TACPLUS_COMMIT} -X $pkg.BuildID=${TACPLUS_COMMIT} -X $pkg.ProjectPath=tacplus-dev/tacplus" \
      -o /out/tacplus . \
 && /out/tacplus version
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
COPY --from=tacplus /out/tacplus /usr/local/bin/tacplus
COPY --from=launcher /out/ /usr/local/bin/
# The service build steps run as build, not root (#56; Trivy DS-0002): root
# only installs, above. build (uid 1000, gid 1000) is created here: the base
# image has no user but Debian's own, and its ids are fixed because
# service.cloudbuild.yaml's first step chowns to them. The toolchains stay
# root's and readable (rustup's and cargo's homes, from the rust image, writable
# by all); what the steps write is under /workspace (CARGO_HOME and GOCACHE
# included) and $HOME (Go's modules, Maven's and npm's caches), which Cloud
# Build mounts root's: service.cloudbuild.yaml's first step hands both to build.
RUN groupadd --gid 1000 build && useradd --uid 1000 --gid 1000 --create-home build
USER build
WORKDIR /workspace
