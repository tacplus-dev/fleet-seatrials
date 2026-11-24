#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# helm's post-renderer for the operator's release (deploy/apply.sh, #76): reads the operator chart's render on
# stdin and writes it on stdout with
#   - its extract-config init container's image, busybox:latest in the chart, set to images/pins.yaml's
#     operator_init_image, pinned by digest; it fails if the render has no such container;
#   - the operator's Role and RoleBinding in the platform namespace (deploy/operator-role.yaml), which the chart
#     leaves to the cluster pipeline when `deployment` is set, and the cluster pipeline does not grant.
#
#   helm upgrade --install ... --post-renderer deploy/operator-post-render.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export INIT_IMAGE NAMESPACE
INIT_IMAGE=$(sed -n 's/^operator_init_image: *//p' "$here/images/pins.yaml")
[[ "$INIT_IMAGE" == *@sha256:* ]] || { echo "images/pins.yaml: operator_init_image is not pinned by digest" >&2; exit 1; }
NAMESPACE=$("$here/deploy/namespaces.sh" platform)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/in.yaml"
init='select(.kind == "Deployment" and .metadata.name == "schematic-operator") | .spec.template.spec.initContainers[]? | select(.name == "extract-config")'
[ "$(yq ea "[$init] | length" "$tmp/in.yaml")" = 1 ] ||
  { echo "the operator chart's render has no extract-config init container to pin: has the chart changed?" >&2; exit 1; }
yq "($init | .image) = strenv(INIT_IMAGE)" "$tmp/in.yaml"
echo ---
sed 's/\${NAMESPACE}/'"$NAMESPACE"'/g' "$here/deploy/operator-role.yaml"
