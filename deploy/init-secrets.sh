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
#   fleet-root-cred-seatrials  the fleet's root credential, root.cred.json as
#   (FLEET_ROOT_CRED_SECRET)   `seatrials keygen root` writes it: the private key
#                              the client-steps job administers the tenants with,
#                              and its public pair (#77)
#
# All three in GCP_PROJECT (tacplus-dev), made with no version by
# tacplus-dev/cloud (#28, #105). The job runs as seatrials-init-secrets, through
# Workload Identity Federation (ci_gcp): it may add a version to these and list
# their versions, nothing else, and no token is stored anywhere. The deploy jobs
# read them as seatrials-deploy (ci_crypto in ci/lib.sh).
#
# The crypto file and the CA: both have an enabled version at the generation
# deploy/key-generation names, or later: nothing is generated or added. Both
# behind it: generated again, a new version of each (the trust domain changed,
# say: kernel's certificates carry it). One only: refused, since a CA and its
# crypto.yaml are a pair, and the hub disables the one that is there (or
# restores the other). Neither: generated in a scratch directory, and one
# version added to each, the crypto file first. The root credential, on its
# own: an enabled version, nothing is generated; none, a pair is made and
# added, and its public half is printed as the root_cred_pairs entry to commit
# in operator.yaml in place of the one there (the next apply registers it).
# Nothing here prints a private or generated value; the account may not read one.
#
#   deploy/init-secrets.sh    # needs bin/schematic-operator, bin/seatrials, yq, jq and gcloud logged in (ci_gcp)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
project=${GCP_PROJECT:-tacplus-dev}
crypto_secret=${FLEET_CRYPTO_SECRET:-fleet-crypto-seatrials}
ca_secret=${FLEET_CA_SECRET:-fleet-ca-seatrials}
root_secret=${FLEET_ROOT_CRED_SECRET:-fleet-root-cred-seatrials}
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

# The generation of the key material this commit needs (deploy/key-generation: one number). A secret's version
# number is its generation: the pair is generated when neither has an enabled version, and generated again, a new
# version of each, when both are behind the generation. The deploy jobs read the latest version (ci_crypto).
generation=${FLEET_KEY_GENERATION:-$(grep -v '^[[:space:]]*\(#\|$\)' "$here/deploy/key-generation" 2>/dev/null | head -n 1 | tr -d '[:space:]')}
[[ $generation =~ ^[1-9][0-9]*$ ]] || die "deploy/key-generation holds no generation number (a positive integer): [$generation]"

crypto=$(version "$crypto_secret")
ca=$(version "$ca_secret")
root=$(version "$root_secret")

# The root credential (#77): `seatrials keygen root` in a scratch home, its
# file (the private key and the public pair) the secret's version; only the
# public pair is printed, checked to hold no private part.
root_cred() {
  local pair
  if [ -n "$root" ]; then
    echo "init-secrets: $root_secret (version $root) exists (project $project): no root credential to generate"
    return
  fi
  SEATRIALS_HOME=$tmp/seatrials seatrials keygen root > "$tmp/keygen.json" 2>&1 ||
    die "seatrials keygen root failed: $(jq -r '.error // empty' "$tmp/keygen.json" 2>/dev/null || echo 'no error')"
  jq -e '.key and .pair and .pair_id' "$tmp/seatrials/root.cred.json" >/dev/null 2>&1 ||
    die "seatrials keygen root wrote no credential file with a key and its pair"
  pair=$(jq -cS '.cred_pair | select(.public_key.kty and (.public_key | has("d") | not))' "$tmp/keygen.json") &&
    [ -n "$pair" ] || die "seatrials keygen root printed no public pair, or one with a private part"
  add "$root_secret" "$tmp/seatrials/root.cred.json"
  echo "init-secrets: the root credential $(jq -r .id <<<"$pair"): commit this entry in deploy/bootstrap/operator.yaml in place of the one in its root_cred_pairs; the next apply registers it"
  echo "root_cred_pairs:"
  echo "    - $pair"
}

if [ -n "$crypto" ] && [ -n "$ca" ]; then
  if [ "$crypto" -ge "$generation" ] && [ "$ca" -ge "$generation" ]; then
    echo "init-secrets: $crypto_secret (version $crypto) and $ca_secret (version $ca) exist (project $project), at generation $generation or later: nothing to generate"
    root_cred; exit 0
  fi
  [ "$crypto" = "$ca" ] ||
    die "$crypto_secret is at version $crypto and $ca_secret at version $ca, not both behind generation $generation (project $project): they are a pair; disable the newer one's versions past the other's, and run this job again"
  echo "init-secrets: $crypto_secret and $ca_secret are at version $crypto, behind generation $generation (deploy/key-generation): generating the pair again"
fi
case ${crypto:+1}${ca:+2} in
  1) die "$crypto_secret has a version but $ca_secret has none (project $project): they are a pair; restore $ca_secret, or disable $crypto_secret's versions to generate both" ;;
  2) die "$ca_secret has a version but $crypto_secret has none (project $project): they are a pair; restore $crypto_secret, or disable $ca_secret's versions to generate both" ;;
esac

# A copy of deploy/bootstrap: init rewrites operator.yaml, and the checkout's
# deploy/bootstrap must not hold key material.
cp -R "$here/deploy/bootstrap" "$tmp/bootstrap"
rm -rf "$tmp/bootstrap/configs" "$tmp/bootstrap/crypto.yaml" "$tmp/bootstrap/ca.pem"
fqdn=$(yq '.fqdn' "$here/deploy/bootstrap/operator.yaml")
gateways=$(yq '.topology.gateway_nodes // 1' "$here/deploy/bootstrap/operator.yaml")
export SCHEMATIC_OPERATOR_DIR=$tmp/bootstrap
schematic-operator init ca > "$tmp/init.log" 2>&1 &&
  schematic-operator init cluster --fqdn "$fqdn" --type small --gateways "$gateways" --dev >> "$tmp/init.log" 2>&1 ||
  die "schematic-operator init failed: $(grep -m3 -i 'error' "$tmp/init.log" || echo 'no error line')"
[ -s "$tmp/bootstrap/crypto.yaml" ] && [ -s "$tmp/bootstrap/ca.pem" ] || die "schematic-operator init wrote no crypto.yaml or ca.pem"

# The key material as this fleet's config needs it, not as init leaves it. init issues kernel's certificates for
# the default trust domain, and generate issues them again, with new keys, whenever crypto.yaml's are not for the
# config's (operator.yaml's spiffe_prefix). Stored as init left them, every job of the deploy pipeline issued its own
# and no two renders were the same: apply refused each one as "not the one diff showed" (2026-11-26, once the trust
# domain was tacplus.dev). So: the committed operator.yaml back in place of init's, generate once, and what is
# stored is what generate leaves. A second generate must leave it as it is, or the pipeline could never apply.
cp "$here/deploy/bootstrap/operator.yaml" "$tmp/bootstrap/operator.yaml"
export SCHEMATIC_LOCAL_IMAGES=${REGISTRY:-us-central1-docker.pkg.dev/tacplus-dev/seatrials}
schematic-operator generate --output "$tmp/charts" >> "$tmp/init.log" 2>&1 ||
  die "schematic-operator generate failed on the new key material: $(grep -m3 -i 'error' "$tmp/init.log" || echo 'no error line')"
before=$(sha256sum < "$tmp/bootstrap/crypto.yaml")
schematic-operator generate --output "$tmp/charts" >> "$tmp/init.log" 2>&1 ||
  die "schematic-operator generate failed the second time: $(grep -m3 -i 'error' "$tmp/init.log" || echo 'no error line')"
[ "$(sha256sum < "$tmp/bootstrap/crypto.yaml")" = "$before" ] ||
  die "schematic-operator generate changes crypto.yaml every time it runs: no two renders would be the same, and nothing is stored"

# The crypto file first: once it has a version, a run that stops before the
# CA's is refused next time (a half pair), never generated twice.
added=
add "$crypto_secret" "$tmp/bootstrap/crypto.yaml"
add "$ca_secret" "$tmp/bootstrap/ca.pem" \
  "; $crypto_secret has version $added without its CA: disable it (gcloud secrets versions disable $added --secret=$crypto_secret --project=$project) and run this job again"
root_cred
