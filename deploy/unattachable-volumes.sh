#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# After the apply (ci/deploy.gitlab-ci.yml): a pod that has never started because its volume is on a disk type its
# node cannot attach gets a new volume. Its claims and the pod are deleted, and what owns them makes them again, on
# the cluster's default StorageClass.
#
# Why: the cluster's nodes are C4A, which attach Hyperdisk only, and its default StorageClass was GKE's pd-balanced
# until tacplus-dev/cluster made hyperdisk-balanced the default (2026-11-26). A claim made before that stays bound
# to its pd-balanced disk for good: kernel-0, stratum-0..2 and eventbus0 waited for hours on "pd-balanced disk type
# cannot be used by c4a-standard-2 machine type". Such a claim is empty: its disk never attached to anything.
#
# Narrow on purpose. Only a pod that is Pending, none of whose containers has ever run, and that has a
# FailedAttachVolume event saying its disk type cannot be used by its node's machine type. A pod that has run, even
# once, is never touched: its volume may hold data.
#
#   deploy/unattachable-volumes.sh     # needs kubectl on the cluster (ci_kube), jq, yq
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ctx=$(kubectl config current-context)
want_ctx=gke_${GCP_PROJECT:-tacplus-dev}_${ZONE:-us-central1-a}_${CLUSTER:-dev}
[ "$ctx" = "$want_ctx" ] || { echo "kube context is $ctx, not $want_ctx, the cluster seatrials deploys to" >&2; exit 1; }
ns=$("$here/deploy/namespaces.sh" platform)

pods=$(kubectl get events -n "$ns" --field-selector reason=FailedAttachVolume -o json |
  jq -r '[.items[] | select(.involvedObject.kind == "Pod" and ((.message // "") | test("disk type cannot be used by")))
          | .involvedObject.name] | unique | .[]')
if [ -z "$pods" ]; then echo "volumes: none in $ns that its node cannot attach"; exit 0; fi
for p in $pods; do
  json=$(kubectl get pod -n "$ns" "$p" -o json 2>/dev/null) || { echo "volumes: $p is gone since"; continue; }
  ran=$(jq '[((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
    | select((.restartCount // 0) > 0 or .state.running != null or .state.terminated != null or .lastState.terminated != null)] | length' <<<"$json")
  if [ "$(jq -r '.status.phase' <<<"$json")" != Pending ] || [ "$ran" != 0 ]; then
    echo "volumes: $p has run: its volume is left as it is"; continue
  fi
  for c in $(jq -r '.spec.volumes[]? | .persistentVolumeClaim.claimName // empty' <<<"$json"); do
    echo "volumes: $p has never started: its claim $c is on a disk type its node cannot attach (empty: never attached): deleting the claim"
    kubectl delete persistentvolumeclaim -n "$ns" "$c" --wait=false
  done
  echo "volumes: deleting the pod $p, so that it and its claim are made again"
  kubectl delete pod -n "$ns" "$p" --wait=false
done
