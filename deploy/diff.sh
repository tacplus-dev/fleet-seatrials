#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# What an apply would change on the seatrials cluster, by object name only:
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
#   deploy/diff.sh     # exit 0: the diff ran (changes or not)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export SCHEMATIC_OPERATOR_DIR="$here/deploy/bootstrap"
export SCHEMATIC_LOCAL_IMAGES=${REGISTRY:-us-central1-docker.pkg.dev/jody1-328023/seabeam}
operator=${OPERATOR:-$here/bin/schematic-operator}
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

status=0
KUBECTL_EXTERNAL_DIFF="$here/deploy/diff-names.sh" kubectl diff -f "$tmp/manifest.yaml" || status=$?
case "$status" in
  0) echo "no difference: the render matches the cluster" ;;
  1) ;;
  *) echo "kubectl diff failed (exit $status)" >&2; exit "$status" ;;
esac
