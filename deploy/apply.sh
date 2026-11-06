#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Renders the charts from deploy/bootstrap against the fleet's images in the
# registry and applies them to the current kube context (the cluster dev).
# It applies only the render deploy/diff.sh showed: RENDER_DIGEST, the digest
# diff recorded (#34). It renders again just before the apply, and it refuses
# when the render's digest is any other.
#
#   RENDER_DIGEST=sha256:<hex> deploy/apply.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export SCHEMATIC_OPERATOR_DIR="$here/deploy/bootstrap"
export SCHEMATIC_LOCAL_IMAGES=${REGISTRY:-us-central1-docker.pkg.dev/tacplus-dev/seatrials}
: "${RENDER_DIGEST:?no RENDER_DIGEST: apply only the render deploy/diff.sh showed (docs/deploy-pipeline.md)}"
ctx=$(kubectl config current-context)
want_ctx=gke_${GCP_PROJECT:-tacplus-dev}_${ZONE:-us-central1-a}_${CLUSTER:-dev}
[ "$ctx" = "$want_ctx" ] || { echo "kube context is $ctx, not $want_ctx, the cluster seatrials deploys to" >&2; exit 1; }
cd "$here"
bin/schematic-operator generate
digest=sha256:$(bin/schematic-operator apply --dry-run | sha256sum | cut -d' ' -f1)
if [ "$digest" != "$RENDER_DIGEST" ]; then
  echo "refused: this render is $digest, not $RENDER_DIGEST, the one diff showed; run the pipeline again" >&2
  exit 1
fi
echo "applying render $digest"
bin/schematic-operator apply
kubectl get pods -n schematic
