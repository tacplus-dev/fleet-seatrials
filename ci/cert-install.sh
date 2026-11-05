#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Installs the fleet's public certificate, one version of the cert job's
# secret (ci/cert.sh: the leaf, its chain and the key, in PEM), as
# crypto.yaml's pki.edge_tls[0]: the gateway's external certificate, which the
# operator serves in CERT_CHAIN mode and the gateway hot-swaps when its config
# changes. crypto.yaml is the job's copy of the fleet's key material
# (ci_crypto), so the certificate reaches the cluster only in the deployment's
# own delivery. Each PEM is kept as base64, as the operator keeps its own.
# It prints nothing.
#
#   ci/cert-install.sh PAYLOAD CRYPTO_YAML
set -euo pipefail
[ $# = 2 ] || { echo "usage: $0 PAYLOAD CRYPTO_YAML" >&2; exit 2; }
payload=$1 crypto=$2
die() { echo "cert-install: $*" >&2; exit 1; }
[ -f "$crypto" ] || die "no $crypto"
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
awk -v dir="$work" '
  /^-----BEGIN CERTIFICATE-----/ { out = sprintf("%s/cert%d.pem", dir, n++) }
  /^-----BEGIN ([A-Z]+ )?PRIVATE KEY-----/ { out = dir "/key.pem" }
  out { print > out }
  /^-----END / { close(out); out = "" }' "$payload"
[ -f "$work/cert0.pem" ] || die "no certificate in the payload"
[ -f "$work/key.pem" ] || die "no private key in the payload"

serial=$(openssl x509 -in "$work/cert0.pem" -noout -serial | cut -d= -f2)
created=$(date -u -d "$(openssl x509 -in "$work/cert0.pem" -noout -startdate | cut -d= -f2)" +%s)
chain=$(for c in $(ls "$work"/cert*.pem | sort -V); do base64 -w0 < "$c"; echo; done |
  jq -R . | jq -sc --arg id "$serial" 'to_entries | map({base64: .value, id: (if .key == 0 then $id else "chain-\(.key)" end)})')
EDGE_CHAIN=$chain EDGE_KEY=$(base64 -w0 < "$work/key.pem") EDGE_ID=$serial EDGE_CREATED=$created \
  yq -i '.pki.edge_tls[0] = {"chain": (strenv(EDGE_CHAIN) | from_json),
    "key": {"base64": strenv(EDGE_KEY), "created": (strenv(EDGE_CREATED) | to_number), "id": strenv(EDGE_ID)}}' "$crypto"
chmod 600 "$crypto"
