#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Renders the charts from deploy/bootstrap against the fleet's images in the
# registry and applies them to the current kube context (the seatrials cluster).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export SCHEMATIC_OPERATOR_DIR="$here/deploy/bootstrap"
export SCHEMATIC_LOCAL_IMAGES=${REGISTRY:-us-central1-docker.pkg.dev/jody1-328023/seabeam}
ctx=$(kubectl config current-context)
case "$ctx" in *seatrials*) ;; *) echo "kube context is $ctx, not the seatrials cluster" >&2; exit 1 ;; esac
cd "$here"
bin/schematic-operator generate
bin/schematic-operator apply
kubectl get pods -n schematic
