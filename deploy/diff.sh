#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# What an apply would change on the seatrials cluster, by object name only, and
# the letsencrypt guard: renders the release the way deploy/apply.sh applies it
# (`schematic-operator apply --dry-run`, from deploy/bootstrap) and runs
# `kubectl diff` on it with deploy/letsencrypt-guard.sh as the diff program, so
# no object's content reaches the output. Fails when the change touches
# letsencrypt (its Deployment, its pods' config, or its removal): letsencrypt
# is never restarted without Jody's explicit OK, which is the pipeline's
# separate manual job, the one that sets SEATRIALS_ALLOW_LETSENCRYPT=1.
#
# It prints the render's digest (sha256:<hex> of the manifest, nothing of its
# content) and writes it as RENDER_DIGEST=... to RENDER_DIGEST_OUT, the diff
# job's dotenv artifact: deploy/apply.sh applies only the render with that
# digest, so what diff showed is what is applied (#34; the uni-config record's
# digest once #28 lands). With RENDER_DIGEST set (the apply jobs), it fails on
# any other render.
#
#   deploy/diff.sh     # exit 0: nothing touches letsencrypt (changes or not)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export SCHEMATIC_OPERATOR_DIR="$here/deploy/bootstrap"
export SCHEMATIC_LOCAL_IMAGES=${REGISTRY:-us-central1-docker.pkg.dev/jody1-328023/seabeam}
operator=${OPERATOR:-$here/bin/schematic-operator}
ns=${NAMESPACE:-schematic}
ctx=$(kubectl config current-context)
case "$ctx" in *seatrials*) ;; *) echo "kube context is $ctx, not the seatrials cluster" >&2; exit 1 ;; esac

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

touched=$tmp/touched
: > "$touched"
status=0
KUBECTL_EXTERNAL_DIFF="$here/deploy/letsencrypt-guard.sh" LETSENCRYPT_GUARD_OUT="$touched" \
  kubectl diff -f "$tmp/manifest.yaml" || status=$?
case "$status" in
  0) echo "no difference: the render matches the cluster" ;;
  1) ;;
  *) echo "kubectl diff failed (exit $status)" >&2; exit "$status" ;;
esac

# kubectl diff sees only what the render holds; the apply (a helm upgrade) also
# removes what it no longer holds, so a render without letsencrypt while it runs
# would remove it.
rendered=$(yq -N 'select(.kind == "Deployment") | .metadata.name' "$tmp/manifest.yaml" | grep letsencrypt || true)
running=$(kubectl get deployments -n "$ns" -o name | sed 's|.*/||' | grep letsencrypt || true)
for d in $running; do
  grep -qx "$d" <<<"$rendered" || echo "apps.v1.Deployment.$ns.$d (removed by the apply)" >> "$touched"
done

if [ -s "$touched" ]; then
  echo "this change touches letsencrypt:"
  sed 's/^/  /' "$touched"
  if [ "${SEATRIALS_ALLOW_LETSENCRYPT:-}" = 1 ]; then
    echo "allowed: this is the letsencrypt job, run with Jody's explicit OK"
  else
    echo "refused: letsencrypt is never restarted without Jody's explicit OK; with it, run the" \
      "apply-letsencrypt job instead of apply (docs/deploy-pipeline.md)" >&2
    exit 1
  fi
fi
