#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The pipeline secrets the charts reference (Secrets no chart renders: in
# Seabeam's fleet the CI pipeline writes them from its variables). This fleet
# has none of those credentials, so each is created with its keys present and
# empty, which the services read as "not configured", and only where it is
# missing: deploy/signin-secrets.sh puts the real values in place (from the
# deploy pipeline's GitLab variables), and a later run must not empty them.
set -euo pipefail
ns=${NAMESPACE:-schematic}
if kubectl get secret oauth-pipeline-secrets -n "$ns" -o name >/dev/null 2>&1; then
  echo "oauth-pipeline-secrets: in place, left as it is"
else
  kubectl create secret generic oauth-pipeline-secrets -n "$ns" \
    --from-literal=apple_signin_key_p8= \
    --dry-run=client -o yaml | kubectl apply -f -
fi
