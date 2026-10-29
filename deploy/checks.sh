#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The post-deploy checks of seatrials, the deploy pipeline's test stage. Each
# needs no person and prints no secret.
#
#   deploy/checks.sh pods          # every pod of the fleet's namespaces Ready
#   deploy/checks.sh cert          # the gateway serves a publicly trusted certificate
#                                  # for the host, valid for CERT_MIN_DAYS (14) more days
#   deploy/checks.sh jwks          # OIDC discovery names the host as issuer; its JWKS has keys
#   deploy/checks.sh signin        # every provider oauth.yaml enables is listed, and
#                                  # Authorize sends each to its own IdP with its client id
#   deploy/checks.sh opa CONFIGS   # the rendered routing policy (CONFIGS: the configs/
#                                  # directory `schematic-operator generate` writes) sends each
#                                  # tenant's claim matcher to that tenant, and nothing else
#   deploy/checks.sh all [CONFIGS] # all of the above (opa only with CONFIGS)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
host=${SEATRIALS_HOST:-seatrials.tacplus.dev}
namespaces=${CHECK_NAMESPACES:-^schematic}   # a regex over namespace names
min_days=${CERT_MIN_DAYS:-14}
failed=0
bad() { echo "FAIL $*"; failed=1; }
good() { echo "ok   $*"; }

check_pods() {
  local json not_ready total
  json=$(kubectl get pods -A -o json)
  total=$(jq --arg re "$namespaces" '[.items[] | select(.metadata.namespace | test($re))
    | select(.status.phase != "Succeeded")] | length' <<<"$json")
  not_ready=$(jq -r --arg re "$namespaces" '.items[] | select(.metadata.namespace | test($re))
    | select(.status.phase != "Succeeded")
    | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 0)
    | "\(.metadata.namespace)/\(.metadata.name) (\(.status.phase))"' <<<"$json")
  if [ "$total" -eq 0 ]; then bad "pods: none in namespaces matching $namespaces"; return; fi
  if [ -n "$not_ready" ]; then
    bad "pods: not Ready:"; sed 's/^/       /' <<<"$not_ready"; return
  fi
  good "pods: all $total Ready"
}

check_cert() {
  local pem
  pem=$(openssl s_client -connect "$host:443" -servername "$host" -verify_hostname "$host" \
    -verify_return_error </dev/null 2>/dev/null | openssl x509) ||
    { bad "cert: $host:443 does not serve a certificate that verifies for $host"; return; }
  local about; about=$(openssl x509 -noout -subject -issuer -enddate <<<"$pem" | tr '\n' ' ')
  if ! openssl x509 -noout -checkend $((min_days * 86400)) <<<"$pem" >/dev/null; then
    bad "cert: expires within $min_days days (renewal is not happening): $about"; return
  fi
  good "cert: $about"
}

check_jwks() {
  local disc issuer uri jwks
  disc=$(curl -fsS "https://$host/.well-known/openid-configuration") || { bad "jwks: no OIDC discovery"; return; }
  issuer=$(jq -r '.issuer // empty' <<<"$disc"); uri=$(jq -r '.jwks_uri // empty' <<<"$disc")
  [ "$issuer" = "https://$host" ] || { bad "jwks: discovery names issuer [$issuer], not https://$host"; return; }
  jwks=$(curl -fsS "$uri") || { bad "jwks: $uri does not answer"; return; }
  if ! jq -e '(.keys | length) > 0 and all(.keys[]; (.kid // "") != "" and (.kty // "") != "")' <<<"$jwks" >/dev/null; then
    bad "jwks: $uri holds no usable key"; return
  fi
  good "jwks: $(jq -r '[.keys[] | "\(.kty) \(.kid)"] | join(", ")' <<<"$jwks")"
}

check_signin() {
  local want listed name index issuer client redirect rhost ihost
  want=$(yq -o=json '.providers' "$here/deploy/bootstrap/services/oauth.yaml" |
    jq '[.[] | select(.enable == true) | {name, issuer, client_id}]')
  listed=$(curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' "https://$host/oauth/Auth/ListProviders") ||
    { bad "signin: ListProviders does not answer"; return; }
  while IFS=$'\t' read -r name issuer client; do
    # proto3 JSON omits a zero provider_index.
    index=$(jq -r --arg n "$name" 'first(.providers[] | select(.name == $n) | (.providerIndex // 0)) // empty' <<<"$listed")
    [ -n "$index" ] || { bad "signin: $name is not listed (its credential is not in place?)"; continue; }
    redirect=$(curl -fsS -X POST -H 'Content-Type: application/json' \
      -d "{\"provider_index\":$index,\"callback_url\":\"https://$host/\"}" "https://$host/oauth/Auth/Authorize" |
      jq -r '.redirectUrl // empty') || true
    rhost=$(sed -E 's|^https://([^/?]+).*|\1|' <<<"$redirect"); ihost=$(sed -E 's|^https://([^/?]+).*|\1|' <<<"$issuer")
    if [ "$rhost" != "$ihost" ] || [[ "$redirect" != *"client_id=$(jq -rn --arg c "$client" '$c | @uri')"* ]]; then
      bad "signin: $name's Authorize does not send to $ihost with client_id $client"; continue
    fi
    good "signin: $name -> $rhost"
  done < <(jq -r '.[] | [.name, .issuer, .client_id] | @tsv' <<<"$want")
}

check_opa() {
  local configs=$1 tmp policy f tenant iss key value got
  tmp=$(mktemp -d); policy=$tmp/namespace.rego
  # The policy is a file of the bootstrap config, as text or base64.
  for f in "$configs"/*.yaml; do
    yq -o=json '.' "$f" | jq -r '[.. | strings | ., (try @base64d catch "")
      | select(test("(?m)^package entitlements\\.tenants$"))] | first // empty' > "$policy"
    [ -s "$policy" ] && break
  done
  if [ ! -s "$policy" ]; then bad "opa: no tenants routing policy in $configs"; rm -rf "$tmp"; return; fi
  ask() { # input JSON -> the namespace the policy answers
    opa eval --format raw -d "$policy" --stdin-input 'data.entitlements.tenants.namespace' <<<"$1"
  }
  for f in "$here"/deploy/bootstrap/tenants/*/oauth.yaml; do
    tenant=/tenants/$(basename "$(dirname "$f")")
    while IFS=$'\t' read -r iss key value; do
      got=$(ask "$(jq -n --arg i "$iss" --arg k "$key" --arg v "$value" '{claims: {provider_iss: $i, ($k): $v}}')")
      if [ "$got" = "$tenant" ]; then good "opa: $iss $key=$value -> $tenant"
      else bad "opa: $iss $key=$value -> [$got], want $tenant"; fi
      got=$(ask "$(jq -n --arg i "$iss" --arg k "$key" --arg v "other-$value" '{claims: {provider_iss: $i, ($k): $v}}')")
      if [ -z "$got" ]; then good "opa: $iss $key=other-$value -> no tenant"
      else bad "opa: $iss $key=other-$value -> [$got], want no tenant"; fi
    done < <(yq -o=json '.claim_matchers // []' "$f" | jq -r '.[] | [.provider_issuer_url, .claim_key, .claim_value] | @tsv')
  done
  rm -rf "$tmp"
}

case "${1:-}" in
  pods) check_pods ;;
  cert) check_cert ;;
  jwks) check_jwks ;;
  signin) check_signin ;;
  opa) [ -n "${2:-}" ] || { echo "usage: $0 opa CONFIGS_DIR" >&2; exit 2; }; check_opa "$2" ;;
  all) check_pods; check_cert; check_jwks; check_signin; [ -z "${2:-}" ] || check_opa "$2" ;;
  *) echo "usage: $0 pods | cert | jwks | signin | opa CONFIGS_DIR | all [CONFIGS_DIR]" >&2; exit 2 ;;
esac
exit "$failed"
