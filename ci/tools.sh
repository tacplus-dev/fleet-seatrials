#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The deploy pipeline's tools, built natively on the runner from pinned
# sources, into bin/ (the tools job's artifact; none holds a secret):
#
#   bin/tacplus              the fleet's tacplus, images/pins.yaml tacplus_commit
#   bin/schematic-operator   deploy/build-operator.sh with that tacplus
#   bin/yq, bin/opa          pinned module versions (checked against the Go checksum database)
#
#   ci/tools.sh              # needs go and protoc (ghcr.io/tacplus-dev/tacplus/build) and
#                            # git access to the private operator repo (ci_github)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
yq_version=v4.54.1
opa_version=v1.13.1   # dependencies.yaml's github.com/open-policy-agent/opa
mkdir -p "$here/bin"

# tacplus, built as images/tacplus.cloudbuild.yaml builds it.
commit=$(sed -n 's/^tacplus_commit: *//p' "$here/images/pins.yaml")
src=$(mktemp -d)
git clone -q https://github.com/tacplus-dev/tacplus.git "$src" && git -C "$src" checkout -q "$commit"
pkg=github.com/tacplus-dev/tacplus/pkg/buildinfo
( cd "$src" && go generate ./pkg/internal/proto/spec/... \
  && CGO_ENABLED=0 go build -trimpath \
     -ldflags="-w -s -X $pkg.Version=v2.2.0-seatrials -X $pkg.GitSha=$commit -X $pkg.BuildID=$commit -X $pkg.ProjectPath=tacplus-dev/tacplus" \
     -o "$here/bin/tacplus" . )
rm -rf "$src"
"$here/bin/tacplus" version

TACPLUS="$here/bin/tacplus" "$here/deploy/build-operator.sh"

GOBIN="$here/bin" go install "github.com/mikefarah/yq/v4@$yq_version"
GOBIN="$here/bin" go install "github.com/open-policy-agent/opa@$opa_version"
echo "bin/: $(ls "$here/bin" | tr '\n' ' ')"
