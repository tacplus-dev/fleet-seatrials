#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# What an apply would change on the cluster dev, by object name only:
# renders the release the way deploy/apply.sh applies it (`schematic-operator
# apply --dry-run`, from deploy/bootstrap) and runs `kubectl diff` on it with
# deploy/diff-names.sh as the diff program, so no object's content reaches the
# output. (The letsencrypt guard is retired with letsencrypt: the pipeline owns
# the certificate, #35.)
#
# It prints the render's digest (sha256:<hex> of the manifest, nothing of its
# content) and writes it as RENDER_DIGEST=... to RENDER_DIGEST_OUT, the diff
# job's dotenv artifact: deploy/apply.sh applies only the render with that
# digest, so what diff showed is what is applied (#34; the uni-config record's
# digest once #28 lands). With RENDER_DIGEST set (the apply jobs), it fails on
# any other render.
#
# It diffs only the objects outside the tenant namespaces (deploy/namespaces.sh:
# all but the platform one). The deploy account's Role is in the platform
# namespace alone, and the tenant namespaces are deploymentproxy's, where only
# the operator's account is bound, so kubectl could never read their objects
# (#75). It names those objects instead, by name only. The digest is still the
# whole render's.
#
#   deploy/diff.sh     # exit 0: the diff ran (changes or not)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export SCHEMATIC_OPERATOR_DIR="$here/deploy/bootstrap"
export SCHEMATIC_LOCAL_IMAGES=${REGISTRY:-us-central1-docker.pkg.dev/tacplus-dev/seatrials}
operator=${OPERATOR:-$here/bin/schematic-operator}
ctx=$(kubectl config current-context)
want_ctx=gke_${GCP_PROJECT:-tacplus-dev}_${ZONE:-us-central1-a}_${CLUSTER:-dev}
[ "$ctx" = "$want_ctx" ] || { echo "kube context is $ctx, not $want_ctx, the cluster seatrials deploys to" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$here" && "$operator" apply --dry-run) > "$tmp/manifest.yaml"
digest=sha256:$(sha256sum < "$tmp/manifest.yaml" | cut -d' ' -f1)
echo "render $digest"
if [ -n "${RENDER_DIGEST:-}" ] && [ "$digest" != "$RENDER_DIGEST" ]; then
  echo "refused: this render is $digest, not $RENDER_DIGEST, the one diff showed; run the pipeline again" >&2
  exit 1
fi
[ -z "${RENDER_DIGEST_OUT:-}" ] || echo "RENDER_DIGEST=$digest" > "$RENDER_DIGEST_OUT"

# Split the render: the tenant namespaces' objects, and the rest.
export TENANT_NAMESPACES
TENANT_NAMESPACES=$("$here/deploy/namespaces.sh" | tail -n +2 | tr '\n' ' ')
in_tenant='.metadata.namespace as $n | strenv(TENANT_NAMESPACES) | split(" ") | any_c(. == $n)'
yq "select($in_tenant | not)" "$tmp/manifest.yaml" > "$tmp/platform.yaml"
tenant=$(yq "select($in_tenant) | .apiVersion + \".\" + .kind + \".\" + .metadata.namespace + \".\" + .metadata.name" \
  "$tmp/manifest.yaml" | tr / .)
if [ -n "$tenant" ]; then
  echo "in the tenant namespaces, not diffed: the operator applies these through deploymentproxy"
  sed 's/^/  /' <<<"$tenant"
fi
if [ "$(yq ea '[select(.kind != null)] | length' "$tmp/platform.yaml")" -eq 0 ]; then
  echo "nothing outside the tenant namespaces to diff"; exit 0
fi

status=0
KUBECTL_EXTERNAL_DIFF="$here/deploy/diff-names.sh" kubectl diff -f "$tmp/platform.yaml" 2> "$tmp/diff.err" || status=$?
# A StatefulSet whose change Kubernetes forbids patching (a volumeClaimTemplates size, say) cannot be diffed: the
# API refuses the dry run itself. The operator applies such a change by replacing the StatefulSet and keeping its
# pods and claims (its reconciler, before Helm). So it is named as a change, and the rest is diffed without it
# (deploy pipeline 3122546919: kernel's volume went from 2Gi to 4Gi, and this diff ended the deploy).
forbidden='^The StatefulSet "\([^"]*\)" is invalid: spec: Forbidden: updates to statefulset spec for fields other than .*'
if [ "$status" -gt 1 ] && grep -q "$forbidden" "$tmp/diff.err" && ! grep -v "$forbidden" "$tmp/diff.err" | grep -q .; then
  export FORBIDDEN_SETS
  FORBIDDEN_SETS=$(sed -n "s/$forbidden/\\1/p" "$tmp/diff.err" | sort -u | tr '\n' ' ')
  for s in $FORBIDDEN_SETS; do
    echo "changed: StatefulSet $s: fields Kubernetes forbids patching (a volume's size, say); the operator replaces the StatefulSet, keeping its pods and claims"
  done
  yq "select((.kind == \"StatefulSet\" and (.metadata.name as \$n | strenv(FORBIDDEN_SETS) | split(\" \") | any_c(. == \$n))) | not)" \
    "$tmp/platform.yaml" > "$tmp/rest.yaml"
  status=0
  KUBECTL_EXTERNAL_DIFF="$here/deploy/diff-names.sh" kubectl diff -f "$tmp/rest.yaml" 2> "$tmp/diff.err" || status=$?
  [ "$status" -gt 1 ] || status=1
fi
[ ! -s "$tmp/diff.err" ] || cat "$tmp/diff.err" >&2
case "$status" in
  0) echo "no difference: the render matches the cluster" ;;
  1) ;;
  *) echo "kubectl diff failed (exit $status)" >&2; exit "$status" ;;
esac
