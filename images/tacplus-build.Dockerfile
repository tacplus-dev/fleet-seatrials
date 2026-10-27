# The image every service build step runs in: tacplus's full build image (every
# language toolchain and protoc plugin, public on ghcr) with this fleet's pinned
# tacplus binary on top, and the Java containers' launcher built from source
# (images/build.sh clones github.com/tacplus-dev/launcher at the pinned commit
# into launcher/ beside this file). The slim tacplus image has no compilers.
ARG BUILD_IMAGE=ghcr.io/tacplus-dev/tacplus/build:2.3
ARG TACPLUS_IMAGE
FROM ${TACPLUS_IMAGE} AS tacplus
FROM ${BUILD_IMAGE} AS launcher
COPY launcher/ /src/launcher/
RUN cd /src/launcher && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/launcher .
FROM ${BUILD_IMAGE}
COPY --from=tacplus /usr/local/bin/tacplus /usr/local/bin/tacplus
COPY --from=launcher /out/launcher /usr/local/bin/launcher
WORKDIR /workspace
