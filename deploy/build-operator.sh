#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Builds this fleet's operator from the operator library (github.com/tacplus-dev/
# operator at the pinned commit) against this fleet's merged protos, so the
# binary knows exactly the services this fleet runs. Output: bin/schematic-operator.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
commit=$(sed -n 's/^operator_commit: *//p' "$here/images/pins.yaml")
tacplus=${TACPLUS:-tacplus}
src=$(mktemp -d)
git clone -q https://github.com/tacplus-dev/operator.git "$src" && git -C "$src" checkout -q "$commit"
( cd "$src" \
  && "$tacplus" build --src "$here/build/proto" >/dev/null \
  && go generate ./pkg/bootstrap \
  && mkdir -p "$here/bin" \
  && go build -trimpath -o "$here/bin/schematic-operator" ./cmd/cavalier-operator )
rm -rf "$src"
echo "bin/schematic-operator built from operator ${commit:0:12} against this fleet's protos"
