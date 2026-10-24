# The image every service build step runs in: tacplus's full build image (every
# language toolchain and protoc plugin, public on ghcr) with this fleet's pinned
# tacplus binary on top. The slim tacplus image has no compilers.
ARG BUILD_IMAGE=ghcr.io/tacplus-dev/tacplus/build:latest
ARG TACPLUS_IMAGE
FROM ${TACPLUS_IMAGE} AS tacplus
FROM ${BUILD_IMAGE}
COPY --from=tacplus /usr/local/bin/tacplus /usr/local/bin/tacplus
WORKDIR /workspace
