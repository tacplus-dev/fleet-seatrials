#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
project=${PROJECT:-jody1-328023}
zone=${ZONE:-us-central1-a}
name=${CLUSTER:-seatrials}
gcloud container clusters delete "$name" --project "$project" --zone "$zone" --quiet
kubectl config delete-context "gke_${project}_${zone}_${name}" 2>/dev/null || true
