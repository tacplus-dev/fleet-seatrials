#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Before and after the apply (ci/deploy.gitlab-ci.yml): a pod that has never started because its volume cannot be
# had gets a new one. Its claims and the pod are deleted, and what owns them makes them again: a StatefulSet from
# its template, the operator's release from the render (which is why this also runs before the apply: Kubernetes
# refuses to change the size of a claim that is not bound, so the release could not put a larger one in its place).
#
# Two ways a volume cannot be had, both seen on seatrials' first deploy on C4A nodes (2026-11-26), which attach
# Hyperdisk only:
#   - its disk is of a type the node cannot attach: a claim made while the cluster's default StorageClass was GKE's
#     pd-balanced stays bound to that disk for good ("pd-balanced disk type cannot be used by c4a-standard-2 machine
#     type"). Such a claim is empty: its disk never attached to anything;
#   - it was never provisioned: the claim is still Pending and the provisioner refused it (a 2Gi claim, below
#     Hyperdisk Balanced's 4Gi minimum, until the operator asked for 4Gi). Such a claim has no disk at all.
#
# Narrow on purpose. Only a pod that is Pending, none of whose containers has ever run, and that has one of those
# two reasons on record (a FailedAttachVolume event naming the disk type, or a Pending claim with a
# ProvisioningFailed event). A pod that has run, even once, is never touched: its volume may hold data.
#
#   deploy/unattachable-volumes.sh     # needs kubectl on the cluster (ci_kube), jq, yq
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ctx=$(kubectl config current-context)
want_ctx=gke_${GCP_PROJECT:-tacplus-dev}_${ZONE:-us-central1-a}_${CLUSTER:-dev}
[ "$ctx" = "$want_ctx" ] || { echo "kube context is $ctx, not $want_ctx, the cluster seatrials deploys to" >&2; exit 1; }
ns=$("$here/deploy/namespaces.sh" platform)

# The pods whose disk type their node cannot attach.
# An event outlives what it is about, and a pod or claim made again has its name: each is matched by uid, so that what
# this step made again a pipeline ago is not deleted for its predecessor's refusal.
attach=$(kubectl get events -n "$ns" --field-selector reason=FailedAttachVolume -o json |
  jq -c '[.items[] | select(.involvedObject.kind == "Pod" and ((.message // "") | test("disk type cannot be used by")))
          | .involvedObject.uid] | unique')
unattachable=$(kubectl get pods -n "$ns" -o json |
  jq -r --argjson uids "$attach" '.items[] | select(.metadata.uid | IN($uids[])) | .metadata.name')
# The pods that mount a claim never provisioned: still Pending, and refused by the provisioner.
refused=$(kubectl get events -n "$ns" --field-selector reason=ProvisioningFailed -o json |
  jq -c '[.items[] | select(.involvedObject.kind == "PersistentVolumeClaim") | .involvedObject.uid] | unique')
unprovisioned=""
if [ "$refused" != "[]" ]; then
  pending=$(kubectl get persistentvolumeclaims -n "$ns" -o json |
    jq -c --argjson refused "$refused" '[.items[] | select(.status.phase == "Pending" and (.metadata.uid | IN($refused[]))) | .metadata.name]')
  if [ "$pending" != "[]" ]; then
    unprovisioned=$(kubectl get pods -n "$ns" -o json |
      jq -r --argjson claims "$pending" '.items[]
        | select([.spec.volumes[]? | .persistentVolumeClaim.claimName // empty | select(IN($claims[]))] | length > 0)
        | .metadata.name')
  fi
fi
pods=$(printf '%s\n%s\n' "$unattachable" "$unprovisioned" | grep . | sort -u || true)
if [ -z "$pods" ]; then echo "volumes: none in $ns that cannot be had"; exit 0; fi
for p in $pods; do
  json=$(kubectl get pod -n "$ns" "$p" -o json 2>/dev/null) || { echo "volumes: $p is gone since"; continue; }
  ran=$(jq '[((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
    | select((.restartCount // 0) > 0 or .state.running != null or .state.terminated != null or .lastState.terminated != null)] | length' <<<"$json")
  if [ "$(jq -r '.status.phase' <<<"$json")" != Pending ] || [ "$ran" != 0 ]; then
    echo "volumes: $p has run: its volume is left as it is"; continue
  fi
  why="is on a disk type its node cannot attach (empty: never attached)"
  grep -qxF "$p" <<<"$unattachable" || why="was never provisioned (no disk)"
  for c in $(jq -r '.spec.volumes[]? | .persistentVolumeClaim.claimName // empty' <<<"$json"); do
    echo "volumes: $p has never started: its claim $c $why: deleting the claim"
    kubectl delete persistentvolumeclaim -n "$ns" "$c" --wait=false
  done
  echo "volumes: deleting the pod $p, so that it and its claim are made again"
  kubectl delete pod -n "$ns" "$p" --wait=false
done
