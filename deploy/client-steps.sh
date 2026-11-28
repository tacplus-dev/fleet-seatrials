#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The deploy pipeline's client-steps job (#77): the README's first-time client
# steps after an apply, from the pipeline, never a laptop, as the fleet's root
# credential, whose key only the pipeline holds (init-secrets made it into the
# Secret Manager secret fleet-root-cred-seatrials; ci_crypto root places it in
# SEATRIALS_HOME as seatrials-deploy). For each tenant operator.yaml names:
#
#   seatrials tenant create --if-missing /tenants/T     made once; one that exists is no error
#   seatrials keygen --tenant /tenants/T ci-T            a fresh pair of the pipeline's, each run
#   seatrials tenant cred --replace /tenants/T ci-T      installed in place of its earlier ci-T pairs
#   seatrials login --as ci-T; seatrials ping --as ci-T  served by /tenants/T's instance
#
# so any number of runs leaves each tenant made once and one ci-T pair, and
# keeps every other pair a tenant holds. The root credential must be the one
# operator.yaml's root_cred_pairs registers (the entry init-secrets printed,
# committed, then applied): otherwise it is refused before anything is asked.
# The client prints no private key or token, and neither does this.
#
#   deploy/client-steps.sh    # needs bin/seatrials, jq, yq and SEATRIALS_HOME/root.cred.json (ci_crypto root)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
op=$here/deploy/bootstrap/operator.yaml
die() { echo "client-steps: $*" >&2; exit 1; }
say() { echo "client-steps: $*"; }

home=${SEATRIALS_HOME:?no SEATRIALS_HOME: ci_crypto root places the root credential there}
cred=$home/root.cred.json
[ -s "$cred" ] || die "no root credential in $cred: ci_crypto root places it (the secret fleet-root-cred-seatrials)"
id=$(jq -r '.pair_id // empty' "$cred") && [ -n "$id" ] || die "$cred holds no pair_id"
registered=$(yq -o=json '.root_cred_pairs // []' "$op" | jq -c --arg id "$id" '.[] | select(.id == $id) | .public_key')
[ -n "$registered" ] ||
  die "the root credential $id is not in deploy/bootstrap/operator.yaml's root_cred_pairs: commit the entry init-secrets printed in place of the one there; the next apply registers it"
jq -e --argjson reg "$registered" '.pair.public_key | .x == $reg.x and .y == $reg.y' "$cred" >/dev/null ||
  die "the root credential $id's public key is not the one deploy/bootstrap/operator.yaml registers for it"

# step ARG...: seatrials ARG..., its JSON answer in $out; a failure ends the job
# with the client's error.
step() {
  out=$(seatrials "$@" 2>&1) ||
    die "seatrials $* failed: $(jq -r '.error // empty' <<<"$out" 2>/dev/null || head -c 300 <<<"$out")"
}

step login --as root
say "signed in as the root credential $id"
for tenant in $(yq '.tenants[]' "$op"); do
  ns=/tenants/$tenant name=ci-$tenant
  step tenant create --if-missing "$ns"
  [ "$(jq -r '.exists // false' <<<"$out")" = true ] && say "$ns: exists" || say "$ns: created"
  step keygen --tenant "$ns" "$name"
  step tenant cred --replace "$ns" "$name"
  say "$ns: the pair $(jq -r '.cred_pair' <<<"$out") installed in place of its earlier $name pairs"
  step login --as "$name"
  step ping --as "$name" "client-steps $tenant"
  served=$(jq -r '.served_by // empty' <<<"$out")
  [[ "$served" =~ (^|[^a-z0-9-])tenants/$tenant($|[^a-z0-9-]) ]] || die "$ns: ping served by ${served:-nobody}, not $tenant's"
  say "$ns: ping served by $served"
done
