#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The deploy pipeline's init-secrets job (#17, #44; Jody, 2026-11-08,
# tacplus-dev/cloud#28 option D): on a deployment's first run, generates the
# fleet's key material and adds it to Google Secret Manager, so no person ever
# holds it and a rebuilt cluster needs nothing from anyone:
#
#   fleet-crypto-seatrials   deploy/bootstrap/crypto.yaml as it is: the root CA and
#   (FLEET_CRYPTO_SECRET)    the cluster PKI (schematic-operator init ca, then init
#                            cluster for operator.yaml's fqdn, as deploy/init.sh)
#   fleet-ca-seatrials       deploy/bootstrap/ca.pem, the root CA's certificate
#   (FLEET_CA_SECRET)
#
# Both in GCP_PROJECT (tacplus-dev), made with no version by tacplus-dev/cloud.
# The job runs as seatrials-init-secrets, through Workload Identity Federation
# (ci_gcp): it may add a version to these two and list their versions, nothing
# else, and no token is stored anywhere. The deploy jobs read them as
# seatrials-deploy (ci_crypto in ci/lib.sh).
#
# Both have an enabled version: nothing is generated or added. One only:
# refused, since a CA and its crypto.yaml are a pair, and the hub disables the
# one that is there (or restores the other). Neither: generated in a scratch
# directory, and one version added to each, the crypto file first. Nothing here
# prints a generated value; the account may not read one.
#
#   deploy/init-secrets.sh    # needs bin/schematic-operator, yq and gcloud logged in (ci_gcp)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
project=${GCP_PROJECT:-tacplus-dev}
crypto_secret=${FLEET_CRYPTO_SECRET:-fleet-crypto-seatrials}
ca_secret=${FLEET_CA_SECRET:-fleet-ca-seatrials}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
umask 077
export CLOUDSDK_CORE_DISABLE_PROMPTS=1
die() { echo "init-secrets: $*" >&2; exit 1; }
gcloud_error() { grep -m1 '^ERROR' "$tmp/err" || head -c 300 "$tmp/err"; }

# version SECRET: the number of the secret's latest enabled version, or nothing.
version() {
  gcloud secrets versions list "$1" --project="$project" --filter=state:enabled --limit=1 \
      --format='value(name.basename())' 2>"$tmp/err" ||
    die "listing the versions of $1 (project $project): $(gcloud_error)"
}
# add SECRET FILE [ON-FAILURE]: FILE as a new version of SECRET.
add() {
  local n
  gcloud secrets versions add "$1" --project="$project" --data-file="$2" >/dev/null 2>"$tmp/err" ||
    die "adding a version to $1 (project $project): $(gcloud_error)${3:-}"
  n=$(sed -n 's/^Created version \[\([0-9]*\)\].*/\1/p' "$tmp/err")
  echo "init-secrets: $1: version ${n:-?} added (project $project)"
  added=$n
}

crypto=$(version "$crypto_secret")
ca=$(version "$ca_secret")
case ${crypto:+1}${ca:+2} in
  12) echo "init-secrets: $crypto_secret (version $crypto) and $ca_secret (version $ca) exist (project $project): nothing to generate"; exit 0 ;;
  1) die "$crypto_secret has a version but $ca_secret has none (project $project): they are a pair; restore $ca_secret, or disable $crypto_secret's versions to generate both" ;;
  2) die "$ca_secret has a version but $crypto_secret has none (project $project): they are a pair; restore $crypto_secret, or disable $ca_secret's versions to generate both" ;;
esac

# A copy of deploy/bootstrap: init rewrites operator.yaml, and the checkout's
# deploy/bootstrap must not hold key material.
mkdir "$tmp/bootstrap"
cp -R "$here/deploy/bootstrap/operator.yaml" "$here/deploy/bootstrap/services" "$tmp/bootstrap/"
fqdn=$(yq '.fqdn' "$here/deploy/bootstrap/operator.yaml")
gateways=$(yq '.topology.gateway_nodes // 1' "$here/deploy/bootstrap/operator.yaml")
export SCHEMATIC_OPERATOR_DIR=$tmp/bootstrap
schematic-operator init ca > "$tmp/init.log" 2>&1 &&
  schematic-operator init cluster --fqdn "$fqdn" --type small --gateways "$gateways" --dev >> "$tmp/init.log" 2>&1 ||
  die "schematic-operator init failed: $(grep -m3 -i 'error' "$tmp/init.log" || echo 'no error line')"
[ -s "$tmp/bootstrap/crypto.yaml" ] && [ -s "$tmp/bootstrap/ca.pem" ] || die "schematic-operator init wrote no crypto.yaml or ca.pem"

# The crypto file first: once it has a version, a run that stops before the
# CA's is refused next time (a half pair), never generated twice.
added=
add "$crypto_secret" "$tmp/bootstrap/crypto.yaml"
add "$ca_secret" "$tmp/bootstrap/ca.pem" \
  "; $crypto_secret has version $added without its CA: disable it (gcloud secrets versions disable $added --secret=$crypto_secret --project=$project) and run this job again"
