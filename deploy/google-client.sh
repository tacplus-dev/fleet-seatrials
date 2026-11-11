#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Checks seatrials' Google OAuth client against Google itself, with no person
# (#46). Google offers no public API to read or write a web client, its
# redirect URIs or its secrets: Jody makes them once in the Console
# (docs/deploy-pipeline.md, The Google sign-in client). What the pipeline can
# do is ask Google's own endpoints:
#
#   deploy/google-client.sh client        # the client oauth.yaml names exists, and every
#                                         # redirect URI it lets Google send back to
#                                         # (allowed_redirect_uri_prefixes) is registered
#   deploy/google-client.sh secret FILE   # Google takes FILE's secret for that client
#
# client: Google's authorize endpoint redirects to its sign-in page for a known
# client and a registered redirect URI, and to /signin/oauth/error, whose
# authError names the error (invalid_client, redirect_uri_mismatch), otherwise.
# secret: the token endpoint, asked to redeem a bogus code, answers
# invalid_grant when the client authenticated and invalid_client when its
# secret (or the client) is wrong. The secret goes to curl from FILE, never on a
# command line, and is never printed.
#
# Exit 0: Google agrees. 1: Google refuses (says why). 2: usage. 3: Google does
# not answer.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
auth=https://accounts.google.com/o/oauth2/v2/auth
token=https://oauth2.googleapis.com/token
usage() { echo "usage: $0 client | secret FILE" >&2; exit 2; }

provider=$(yq -o=json '.providers' "$here/deploy/bootstrap/services/oauth.yaml" |
  jq -c '[.[] | select(.issuer == "https://accounts.google.com")][0] // empty')
[ -n "$provider" ] || { echo "FAIL google: oauth.yaml has no provider with issuer https://accounts.google.com"; exit 1; }
client_id=$(jq -r '.client_id' <<<"$provider")

case "${1:-}" in
  client)
    [ $# -eq 1 ] || usage
    failed=0
    while IFS= read -r uri; do
      answer=$(curl -sS -m 20 -o /dev/null -w '%{http_code} %{redirect_url}' -G "$auth" \
        --data-urlencode "client_id=$client_id" --data-urlencode "redirect_uri=$uri" \
        -d response_type=code -d scope=openid 2>/dev/null) ||
        { echo "google: Google does not answer at $auth"; exit 3; }
      location=${answer#* }
      case "$location" in
        https://accounts.google.com/signin/oauth/error*)
          # authError: base64url of a message whose first string is the error's name.
          e=$(sed -n 's/.*[?&]authError=\([^&]*\).*/\1/p' <<<"$location" | tr '_-' '/+')
          while [ $((${#e} % 4)) -ne 0 ]; do e="$e="; done
          name=$(base64 -d <<<"$e" 2>/dev/null | grep -aoE '[a-z]+(_[a-z]+)+' | head -1 || true)
          if [ "$name" = invalid_client ]; then
            echo "FAIL google: Google knows no client $client_id (invalid_client)"; exit 1
          fi
          echo "FAIL google: $uri is not a redirect URI of $client_id (${name:-an error})"; failed=1 ;;
        https://accounts.google.com/*)
          echo "ok   google: $uri is registered for $client_id" ;;
        *)
          echo "FAIL google: authorize answered $answer for $uri"; failed=1 ;;
      esac
    done < <(jq -r '.allowed_redirect_uri_prefixes[]' <<<"$provider")
    exit "$failed" ;;
  secret)
    [ $# -eq 2 ] && [ -f "$2" ] || usage
    answer=$(curl -sS -m 20 "$token" --data-urlencode "client_id=$client_id" --data-urlencode "client_secret@$2" \
      -d grant_type=authorization_code -d code=seatrials-check -d redirect_uri=https://seatrials.tacplus.dev/ 2>/dev/null) ||
      { echo "google: Google does not answer at $token"; exit 3; }
    error=$(jq -r '.error // empty' <<<"$answer" 2>/dev/null || true)
    case "$error" in
      invalid_grant) echo "ok   google: Google takes the secret of $client_id" ;;
      "") echo "google: Google's token endpoint answered no error JSON"; exit 3 ;;
      *) echo "FAIL google: Google refuses the secret of $client_id: $error, $(jq -r '.error_description // empty' <<<"$answer")"; exit 1 ;;
    esac ;;
  *) usage ;;
esac
