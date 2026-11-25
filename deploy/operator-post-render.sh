#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# helm's post-renderer for the operator's release (deploy/apply.sh, #76): reads the operator chart's render on
# stdin and writes it on stdout with its extract-config init container's image, busybox:latest in the chart, set
# to images/pins.yaml's operator_init_image, pinned by digest; it fails if the render has no such container. It
# adds no RBAC: the operator's Role in the platform namespace is the cluster's render's, deployment-operator
# (tacplus-dev/cluster#59, #78).
#
#   helm upgrade --install ... --post-renderer deploy/operator-post-render.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export INIT_IMAGE
INIT_IMAGE=$(sed -n 's/^operator_init_image: *//p' "$here/images/pins.yaml")
[[ "$INIT_IMAGE" == *@sha256:* ]] || { echo "images/pins.yaml: operator_init_image is not pinned by digest" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/in.yaml"
init='select(.kind == "Deployment" and .metadata.name == "schematic-operator") | .spec.template.spec.initContainers[]? | select(.name == "extract-config")'
[ "$(yq ea "[$init] | length" "$tmp/in.yaml")" = 1 ] ||
  { echo "the operator chart's render has no extract-config init container to pin: has the chart changed?" >&2; exit 1; }
yq "($init | .image) = strenv(INIT_IMAGE)" "$tmp/in.yaml"
