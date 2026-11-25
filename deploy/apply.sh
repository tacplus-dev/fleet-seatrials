#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Applies the fleet to the current kube context (the cluster dev) through its
# operator, in cluster: it installs or upgrades the operator's own chart
# (operator helm/, at images/pins.yaml's operator_commit) in the platform
# namespace as the deploy account, and the operator, as its own account, makes
# the TenantNamespaces, waits for deploymentproxy to report them Ready, and
# applies the render, tenant namespaces' objects included (#76;
# decisions/deploymentproxy-2026-11-02.md). The deploy account's Role is in the
# platform namespace alone, so it applies nothing in a tenant namespace itself.
#
# It applies only the render deploy/diff.sh showed: RENDER_DIGEST, the digest
# diff recorded (#34). It renders again first, and refuses when the render's
# digest is any other. The operator is handed exactly that render's inputs (the
# config directory deploy/bootstrap, generated, and the same images), and the
# apply passes only once the operator's release `schematic` is that render:
# the SHA-256 of its deployed revision's manifest is RENDER_DIGEST.
#
# The operator runs this fleet's own image, built by the images job
# (images/build.sh operator), by digest. The chart's init container is pinned
# by deploy/operator-post-render.sh. The operator's Role in the platform
# namespace, deployment-operator, is the cluster's (tacplus-dev/cluster
# render.sh, cluster#59): apply refuses until it is there (#78). When the
# operator has not applied the render in time, apply names each TenantNamespace
# deploymentproxy has not made Ready, then shows the operator's log.
#
#   RENDER_DIGEST=sha256:<hex> deploy/apply.sh
#   OPERATOR_APPLY_TIMEOUT=900   # seconds to wait for the operator's release to be that render
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export SCHEMATIC_OPERATOR_DIR="$here/deploy/bootstrap"
export SCHEMATIC_LOCAL_IMAGES=${REGISTRY:-us-central1-docker.pkg.dev/tacplus-dev/seatrials}
: "${RENDER_DIGEST:?no RENDER_DIGEST: apply only the render deploy/diff.sh showed (docs/deploy-pipeline.md)}"
timeout=${OPERATOR_APPLY_TIMEOUT:-900} interval=${OPERATOR_APPLY_INTERVAL:-10}
ctx=$(kubectl config current-context)
want_ctx=gke_${GCP_PROJECT:-tacplus-dev}_${ZONE:-us-central1-a}_${CLUSTER:-dev}
[ "$ctx" = "$want_ctx" ] || { echo "kube context is $ctx, not $want_ctx, the cluster seatrials deploys to" >&2; exit 1; }
cd "$here"
ns=$(deploy/namespaces.sh platform)
deployment=$(yq '.deployment // ""' deploy/bootstrap/operator.yaml)
[ -n "$deployment" ] || { echo "deploy/bootstrap/operator.yaml names no deployment: the operator is installed only in a deployment's namespace" >&2; exit 1; }
bin/schematic-operator generate
digest=sha256:$(bin/schematic-operator apply --dry-run | sha256sum | cut -d' ' -f1)
if [ "$digest" != "$RENDER_DIGEST" ]; then
  echo "refused: this render is $digest, not $RENDER_DIGEST, the one diff showed; run the pipeline again" >&2
  exit 1
fi
image=$(images/build.sh operator-ref) || { echo "refused: no operator image for this commit (the images job builds it)" >&2; exit 1; }
kubectl get role/deployment-operator rolebinding/deployment-operator -n "$ns" -o name >/dev/null ||
  { echo "refused: the cluster's render has not granted the operator its Role deployment-operator in $ns" \
      "(tacplus-dev/cluster#59): apply the cluster first" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
commit=$(sed -n 's/^operator_commit: *//p' images/pins.yaml)
git clone -q https://github.com/tacplus-dev/operator.git "$tmp/operator" && git -C "$tmp/operator" checkout -q "$commit"
# The config directory but what the chart mounts on its own (operator.yaml,
# crypto.yaml) and what the operator generates there (configs/), as the
# chart's config.bundle: a base64 tar.gz, the same bytes for the same files.
find deploy/bootstrap -mindepth 1 -maxdepth 1 ! -name operator.yaml ! -name crypto.yaml ! -name configs \
  -printf '%f\n' | LC_ALL=C sort > "$tmp/bundle.list"
tar --format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C deploy/bootstrap -cf - -T "$tmp/bundle.list" |
  gzip -n | base64 -w0 > "$tmp/bundle.b64"

echo "applying render $digest through the operator ($image) in $ns"
helm upgrade --install schematic-operator "$tmp/operator/helm" --namespace "$ns" --wait --timeout 5m \
  --post-renderer "$here/deploy/operator-post-render.sh" \
  --set-string operator.deployment="$deployment" --set-string operator.image="$image" \
  --set-string operator.imagePullSecret= --set-string operator.localImages="$SCHEMATIC_LOCAL_IMAGES" \
  --set-file config.settings=deploy/bootstrap/operator.yaml --set-file config.crypto=deploy/bootstrap/crypto.yaml \
  --set-file config.bundle="$tmp/bundle.b64" ||
  { echo "the operator did not come up in $ns:" >&2
    kubectl logs -n "$ns" deployment/schematic-operator --all-containers --tail=80 2>&1 | sed 's/^/operator| /' >&2
    exit 1; }

# applied: the digest of the manifest of the release schematic's deployed
# revision, "sha256:<hex> <revision>", or nothing while it has none.
applied() {
  local release
  release=$(kubectl get secret -n "$ns" -l owner=helm,name=schematic,status=deployed -o json |
    jq -r '.items | max_by(.metadata.labels.version | tonumber) // {} | (.data.release // "") + " " + (.metadata.labels.version // "")')
  [ -n "${release% *}" ] || return 0
  echo "sha256:$(base64 -d <<<"${release% *}" | base64 -d | gzip -dc | jq -j .manifest | sha256sum | cut -d' ' -f1) ${release##* }"
}
# tenant_report: on stderr, each tenant namespace of this config whose
# TenantNamespace in the platform namespace deploymentproxy has not made Ready
# (its Ready condition's reason and message), or the operator has not made.
# The deploy account reads them there (fleet-deploy, cluster#59), never the
# tenant namespaces themselves.
tenant_report() {
  local tids tns
  tids=$(deploy/namespaces.sh | sed -n "s/^$ns-//p")
  if ! tns=$(kubectl get tenantnamespaces.deploymentproxy.tacplus.dev -n "$ns" -o json --request-timeout=10s 2>&1); then
    echo "the TenantNamespaces in $ns could not be read: $(tail -n1 <<<"$tns")" >&2
    return 0
  fi
  jq -r --arg ns "$ns" --arg tids "$tids" '
    (.items | map({key: .spec.tid, value: ((.status.conditions // []) | map(select(.type == "Ready")) | first)}) | from_entries) as $tn
    | [$tids | split("\n")[] | select(. != "")
       | . as $tid | $tn[$tid] as $ready
       | if ($tn | has($tid)) | not then "\($tid): no TenantNamespace (the operator has not made it)"
         elif $ready.status == "True" then empty
         else "\($tid): not Ready: \($ready.reason // "no Ready condition")\(if ($ready.message // "") != "" then ": " + $ready.message else "" end)"
         end]
    | if length == 0 then "every TenantNamespace in \($ns) is Ready" else .[] end' <<<"$tns" >&2 ||
    echo "the TenantNamespaces in $ns could not be read" >&2
}
start=$SECONDS
while :; do
  seen=$(applied)
  if [ "${seen% *}" = "$RENDER_DIGEST" ]; then
    echo "the operator applied render $RENDER_DIGEST (release schematic, revision ${seen##* })"
    break
  fi
  if [ $((SECONDS - start)) -ge "$timeout" ]; then
    echo "the operator has not applied render $RENDER_DIGEST in ${timeout}s: release schematic is" \
      "${seen:+render ${seen% *} (revision ${seen##* })}${seen:-not deployed}" >&2
    tenant_report
    kubectl logs -n "$ns" deployment/schematic-operator --tail=80 2>&1 | sed 's/^/operator| /' >&2
    exit 1
  fi
  sleep "$interval"
done
kubectl get pods -n "$ns"
