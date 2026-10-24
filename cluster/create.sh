#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Creates the sea-trials cluster: small, zonal, amd64, disposable. Destroy it
# with cluster/destroy.sh when the trial is over; nothing here is long-lived.
set -euo pipefail
project=${PROJECT:-jody1-328023}
zone=${ZONE:-us-central1-a}
name=${CLUSTER:-seatrials}
nodes=${NODES:-3}
machine=${MACHINE:-e2-standard-2}
gcloud container clusters create "$name" --project "$project" --zone "$zone" \
  --machine-type "$machine" --num-nodes "$nodes" --disk-size 50 \
  --workload-pool "$project.svc.id.goog" \
  --release-channel regular --no-enable-basic-auth --quiet
gcloud container clusters get-credentials "$name" --project "$project" --zone "$zone"
kubectl get nodes
