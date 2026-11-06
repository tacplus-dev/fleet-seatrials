#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Puts the sign-in providers' secrets in place on the cluster dev, from
# the deploy pipeline's protected GitLab variables (docs/deploy-pipeline.md),
# never from git, a file or clipboard on a laptop, a terminal echo or anyone's
# chat. Each is optional; one that is unset keeps what the cluster holds now.
#
#   FLEET_GOOGLE_CLIENT_SECRET      masked variable: the Google client secret
#   FLEET_MICROSOFT_CLIENT_SECRET   masked variable: the Entra client secret VALUE
#   FLEET_APPLE_KEY_P8              file variable: the Sign in with Apple .p8 key
#   TEST_IDP_CLIENT_SEED            masked variable: the seed of the test IdP's client
#                                   secrets (test-idp/README.md), written by its job
#
#   deploy/signin-secrets.sh
#
# With none set, the override is just brought in step with
# deploy/bootstrap/services/oauth.yaml.
#
# Google and Microsoft: oauth's client secrets ride the kernel-config-override
# ConfigMap, whose configs.oauth_config.providers REPLACES the bundle's
# provider list. So the override is rebuilt from
# deploy/bootstrap/services/oauth.yaml (every provider, in order), carrying
# each provider's client_secret over from the current override unless its
# variable gives a new one. Kernel polls the override and installs it; nothing
# restarts.
#
# Apple: the .p8 key's PEM text goes into the oauth-pipeline-secrets Secret
# (apple_signin_key_p8), which reaches oauth as an environment variable, so
# oauth is restarted to read it, before the override names Apple, and only
# when the key differs from the one in place.
#
# The test IdP (#27, test-idp/): each provider whose issuer is one of its realms
# gets the client secret derived from TEST_IDP_CLIENT_SEED for that realm
# (test-idp/testidp.py secret client/<realm>/tacplus-dev), and is on only while
# the realm's discovery answers: the test IdP must never take the real
# providers down with it.
#
# oauth refuses its WHOLE config if any enabled provider lacks its credential
# (a client_secret, or for Apple the .p8 key), which would take Google down
# with it. So a provider whose credential is not in place is written with
# enable: false, and turns on with the run that supplies it.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ns=${NAMESPACE:-schematic}
[ $# -eq 0 ] || { echo "usage: $0 (the secrets come from FLEET_* variables; see the header)" >&2; exit 2; }
ctx=$(kubectl config current-context)
want_ctx=gke_${GCP_PROJECT:-tacplus-dev}_${ZONE:-us-central1-a}_${CLUSTER:-dev}
[ "$ctx" = "$want_ctx" ] || { echo "kube context is $ctx, not $want_ctx, the cluster seatrials deploys to" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Every check runs before anything is written, and none echoes a value.
refuse() { echo "$1: fix the variable in the GitLab project and run again" >&2; exit 1; }
ms_secret=${FLEET_MICROSOFT_CLIENT_SECRET:-}
google_secret=${FLEET_GOOGLE_CLIENT_SECRET:-}
apple_key=${FLEET_APPLE_KEY_P8:-}
# The Entra secret's Secret ID, a command line or a path have been taken for
# its VALUE; Microsoft then refuses the client (AADSTS7000215) and sign-in
# fails with a 500. So refuse a value not shaped like an Entra secret value.
if [ -n "$ms_secret" ]; then
  why="FLEET_MICROSOFT_CLIENT_SECRET"
  [[ "$ms_secret" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] &&
    refuse "$why holds a GUID, which is the Secret ID, not the secret VALUE"
  [[ "$ms_secret" =~ [[:space:]] ]] && refuse "$why holds whitespace or a newline, as a command or a path would"
  case "$ms_secret" in [~/.]*) refuse "$why starts with ~, / or ., as a path or a command would" ;; esac
  [[ "$ms_secret" =~ ^[A-Za-z0-9_.~-]{30,60}$ ]] ||
    refuse "$why is not 30-60 characters of A-Z a-z 0-9 _ . ~ - (Entra secret values are 40)"
fi
printf '%s' "$ms_secret" > "$tmp/ms_secret"
if [ -n "$google_secret" ]; then
  [[ "$google_secret" =~ [[:space:]] ]] && refuse "FLEET_GOOGLE_CLIENT_SECRET holds whitespace or a newline"
fi
printf '%s' "$google_secret" > "$tmp/google_secret"
if [ -n "${TEST_IDP_CLIENT_SEED:-}" ] && [ "${#TEST_IDP_CLIENT_SEED}" -lt 32 ]; then
  refuse "TEST_IDP_CLIENT_SEED is shorter than 32 characters"
fi
if [ -n "$apple_key" ]; then
  [ -f "$apple_key" ] && grep -q "BEGIN PRIVATE KEY" "$apple_key" ||
    refuse "FLEET_APPLE_KEY_P8 is not a file variable holding a .p8 PEM key"
fi

if [ -n "$apple_key" ]; then
  current=$(kubectl -n "$ns" get secret oauth-pipeline-secrets -o jsonpath='{.data.apple_signin_key_p8}' 2>/dev/null || true)
  if [ "$current" = "$(base64 < "$apple_key" | tr -d '\n')" ]; then
    echo "apple: the key in oauth-pipeline-secrets is already this one"
  else
    kubectl -n "$ns" create secret generic oauth-pipeline-secrets --from-file=apple_signin_key_p8="$apple_key" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "$ns" rollout restart deployment/oauth0 >/dev/null
    kubectl -n "$ns" rollout status deployment/oauth0 --timeout=180s >/dev/null
    echo "apple: key loaded into oauth-pipeline-secrets; oauth0 restarted"
  fi
fi
# Whether oauth has an Apple key to use, from this run or an earlier one.
apple_ready=false
if [ -n "$(kubectl -n "$ns" get secret oauth-pipeline-secrets -o jsonpath='{.data.apple_signin_key_p8}' 2>/dev/null)" ]; then
  apple_ready=true
fi

yq -o=json '.providers' "$here/deploy/bootstrap/services/oauth.yaml" > "$tmp/bundle.json"
# The test IdP's providers: {name: secret} for each whose realm answers now.
test_idp=https://idp.test.tacplus.dev/realms/
echo '{}' > "$tmp/test_idp.json"
while IFS=$'\t' read -r name issuer; do
  [ -n "${TEST_IDP_CLIENT_SEED:-}" ] || { echo "test idp: $name off: TEST_IDP_CLIENT_SEED is not set"; continue; }
  if [ "$(curl -fsS -m 10 "$issuer/.well-known/openid-configuration" 2>/dev/null | jq -r '.issuer // empty' 2>/dev/null)" != "$issuer" ]; then
    echo "test idp: $name off: $issuer does not answer"; continue
  fi
  python3 "$here/test-idp/testidp.py" secret "client/${issuer#"$test_idp"}/tacplus-dev" > "$tmp/test_secret" ||
    refuse "TEST_IDP_CLIENT_SEED"
  jq --arg n "$name" --rawfile s "$tmp/test_secret" '. + {($n): $s}' "$tmp/test_idp.json" > "$tmp/t.json"
  mv "$tmp/t.json" "$tmp/test_idp.json"
done < <(jq -r --arg p "$test_idp" '.[] | select((.issuer // "") | startswith($p)) | [.name, .issuer] | @tsv' "$tmp/bundle.json")
kubectl -n "$ns" get configmap kernel-config-override -o jsonpath='{.data.override\.json}' > "$tmp/current.json"
jq --slurpfile bundle "$tmp/bundle.json" --rawfile ms "$tmp/ms_secret" --rawfile google "$tmp/google_secret" \
   --slurpfile test_idp "$tmp/test_idp.json" --arg test_prefix "$test_idp" \
   --argjson apple_ready "$apple_ready" --arg now "$(($(date +%s) * 1000))" '
  (.configs.oauth_config.providers // []) as $old
  | .configs.oauth_config.providers = [
      $bundle[0][] as $p
      | ([ $old[] | select(.name == $p.name) | .client_secret // "" ][0] // "") as $kept
      | (if $p.name == "Microsoft" and ($ms | length) > 0 then $ms
         elif $p.name == "Google" and ($google | length) > 0 then $google
         elif (($p.issuer // "") | startswith($test_prefix)) then ($test_idp[0][$p.name] // "")
         else $kept end) as $secret
      | (if ($secret | length) > 0 then $p + {client_secret: $secret} else $p end)
      | if .apple then .enable = ($apple_ready and (.enable // false))
        elif ((.client_secret // "") | length) == 0 then .enable = false
        else . end
    ]
  | .paths = ((.paths // []) + ["configs.oauth_config.providers"] | unique)
  | .flipped_by = (env.GITLAB_USER_LOGIN // "jody")
  | .reason = "sign-in provider client secrets (Google, Microsoft, the test IdP); the bundle carries ids only"
  | .flipped_at_ms = ($now | tonumber)
' "$tmp/current.json" > "$tmp/override.json"
kubectl -n "$ns" create configmap kernel-config-override --from-file=override.json="$tmp/override.json" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "override: $(jq -c '[.configs.oauth_config.providers[] | {name, enable, secret: ((.client_secret // "") | length > 0)}]' "$tmp/override.json")"
