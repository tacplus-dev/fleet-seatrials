#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Puts the sign-in providers' secrets in place on the seatrials cluster, without
# them passing through git, a terminal echo or anyone's chat:
#
#   deploy/signin-secrets.sh --microsoft-secret-from-clipboard   # copy the Entra client secret VALUE first
#   deploy/signin-secrets.sh --apple-key ~/Downloads/AuthKey_D9JNT33239.p8
#
# Both flags may be given together; with neither, the override is just brought
# in step with deploy/bootstrap/services/oauth.yaml.
#
# Microsoft: oauth's client secrets ride the kernel-config-override ConfigMap,
# whose configs.oauth_config.providers REPLACES the bundle's provider list. So
# the override is rebuilt from deploy/bootstrap/services/oauth.yaml (every
# provider, in order), carrying each provider's client_secret over from the
# current override and taking Microsoft's from the clipboard. Kernel polls the
# override and installs it; nothing restarts.
#
# Apple: the .p8 key's PEM text goes into the oauth-pipeline-secrets Secret
# (apple_signin_key_p8), which reaches oauth as an environment variable, so
# oauth is restarted to read it — before the override names Apple.
#
# oauth refuses its WHOLE config if any enabled provider lacks its credential
# (a client_secret, or for Apple the .p8 key), which would take Google down
# with it. So a provider whose credential is not in place is written with
# enable: false, and turns on with the run that supplies it.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ns=${NAMESPACE:-schematic}
ctx=$(kubectl config current-context)
case "$ctx" in *seatrials*) ;; *) echo "kube context is $ctx, not the seatrials cluster" >&2; exit 1 ;; esac

ms_from_clipboard=false
apple_key=""
while [ $# -gt 0 ]; do
  case "$1" in
    --microsoft-secret-from-clipboard) ms_from_clipboard=true; shift ;;
    --apple-key) apple_key=$2; shift 2 ;;
    *) echo "usage: $0 [--microsoft-secret-from-clipboard] [--apple-key AuthKey_XXXX.p8]" >&2; exit 2 ;;
  esac
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "$apple_key" ]; then
  grep -q "BEGIN PRIVATE KEY" "$apple_key" || { echo "$apple_key is not a .p8 PEM key" >&2; exit 1; }
  kubectl -n "$ns" create secret generic oauth-pipeline-secrets --from-file=apple_signin_key_p8="$apple_key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$ns" rollout restart deployment/oauth0 >/dev/null
  kubectl -n "$ns" rollout status deployment/oauth0 --timeout=180s >/dev/null
  echo "apple: key loaded into oauth-pipeline-secrets; oauth0 restarted"
fi
# Whether oauth has an Apple key to use, from this run or an earlier one.
apple_ready=false
if [ -n "$(kubectl -n "$ns" get secret oauth-pipeline-secrets -o jsonpath='{.data.apple_signin_key_p8}' 2>/dev/null)" ]; then
  apple_ready=true
fi

yq -o=json '.providers' "$here/deploy/bootstrap/services/oauth.yaml" > "$tmp/bundle.json"
kubectl -n "$ns" get configmap kernel-config-override -o jsonpath='{.data.override\.json}' > "$tmp/current.json"
if $ms_from_clipboard; then
  pbpaste | tr -d '\r\n' > "$tmp/ms_secret"
  [ -s "$tmp/ms_secret" ] || { echo "the clipboard is empty: copy the Entra client secret VALUE first" >&2; exit 1; }
else
  : > "$tmp/ms_secret"
fi
jq --slurpfile bundle "$tmp/bundle.json" --rawfile ms "$tmp/ms_secret" \
   --argjson apple_ready "$apple_ready" --arg now "$(($(date +%s) * 1000))" '
  (.configs.oauth_config.providers // []) as $old
  | .configs.oauth_config.providers = [
      $bundle[0][] as $p
      | ([ $old[] | select(.name == $p.name) | .client_secret // "" ][0] // "") as $kept
      | (if $p.name == "Microsoft" and ($ms | length) > 0 then $ms else $kept end) as $secret
      | (if ($secret | length) > 0 then $p + {client_secret: $secret} else $p end)
      | if .apple then .enable = ($apple_ready and (.enable // false))
        elif ((.client_secret // "") | length) == 0 then .enable = false
        else . end
    ]
  | .paths = ((.paths // []) + ["configs.oauth_config.providers"] | unique)
  | .flipped_by = "jody"
  | .reason = "sign-in provider client secrets (Google, Microsoft); the bundle carries ids only"
  | .flipped_at_ms = ($now | tonumber)
' "$tmp/current.json" > "$tmp/override.json"
kubectl -n "$ns" create configmap kernel-config-override --from-file=override.json="$tmp/override.json" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "override: $(jq -c '[.configs.oauth_config.providers[] | {name, enable, secret: ((.client_secret // "") | length > 0)}]' "$tmp/override.json")"
