#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The pipeline secrets the charts reference (Secrets no chart renders: in
# Seabeam's fleet the CI pipeline writes them from its variables). This fleet
# has none of those credentials, so each is created with its keys present and
# empty, which the services read as "not configured". Set a real value with
# `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`.
set -euo pipefail
ns=${NAMESPACE:-schematic}
kubectl create secret generic oauth-pipeline-secrets -n "$ns" \
  --from-literal=apple_signin_key_p8= \
  --dry-run=client -o yaml | kubectl apply -f -
