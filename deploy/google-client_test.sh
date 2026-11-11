#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/google-client.sh against a stub curl that answers as Google's
# endpoints did on 2026-11-10 (#46): authorize redirects to the sign-in page
# for a known client and a registered redirect URI, and to /signin/oauth/error
# with authError (base64url of a message whose first string is the error) for
# an unknown client or an unregistered redirect URI; the token endpoint answers
# a bad secret with invalid_client and a good one with invalid_grant (the code
# is bogus). `client` passes only when the client exists and every redirect URI
# oauth.yaml lets Google send back to is registered; `secret FILE` passes only
# when Google takes the secret. Google refusing is exit 1, Google not answering
# exit 3. The secret is never on a command line or in the output. Needs bash,
# jq and base64.
#
#   deploy/google-client_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/yq" <<'EOF'
#!/usr/bin/env bash
echo '[{"name":"Google","issuer":"https://accounts.google.com","client_id":"the-client.apps.googleusercontent.com","enable":true,
  "allowed_redirect_uri_prefixes":["https://seatrials.tacplus.dev/","https://other.tacplus.dev/cb"]},
  {"name":"Microsoft","client_id":"m","enable":true}]'
EOF
# STUB_GOOGLE: up (default), down; STUB_CLIENT: known (default), unknown;
# STUB_UNREGISTERED: a redirect URI Google does not know; STUB_SECRET_OK: the
# secret Google takes.
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
[ "${STUB_GOOGLE:-up}" = up ] || exit 7
err() { { printf '\n'; printf "\\x$(printf %02x "${#1}")"; printf '%s\x12\x05about' "$1"; } | base64 -w0 | tr '/+' '_-' | tr -d '='; }
redirect= secret=
for a in "$@"; do
  case "$a" in
    redirect_uri=*) redirect=${a#redirect_uri=} ;;
    client_secret@*) secret=$(cat "${a#client_secret@}") ;;
  esac
done
case "$*" in
  *accounts.google.com/o/oauth2/v2/auth*)
    if [ "${STUB_CLIENT:-known}" != known ]; then
      echo "302 https://accounts.google.com/signin/oauth/error?authError=$(err invalid_client)&flowName=GeneralOAuthFlow"
    elif [ "$redirect" = "${STUB_UNREGISTERED:-}" ]; then
      echo "302 https://accounts.google.com/signin/oauth/error?authError=$(err redirect_uri_mismatch)&flowName=GeneralOAuthFlow"
    else
      echo "302 https://accounts.google.com/v3/signin/identifier?client_id=x&flowName=GeneralOAuthLite"
    fi ;;
  *oauth2.googleapis.com/token*)
    if [ "${STUB_CLIENT:-known}" != known ]; then
      echo '{"error": "invalid_client", "error_description": "The OAuth client was not found."}'
    elif [ "$secret" = "${STUB_SECRET_OK:-}" ]; then
      echo '{"error": "invalid_grant", "error_description": "Malformed auth code."}'
    else
      echo '{"error": "invalid_client", "error_description": "The provided client secret is invalid."}'
    fi ;;
  *) exit 6 ;;
esac
EOF
chmod +x "$work/bin/"*

failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
# run NAME WANT_STATUS WANT_TEXT ARGS... [-- VAR=VALUE...]
run() {
  local name=$1 want=$2 text=$3 args=() out status
  shift 3
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  : > "$work/log"
  out=$(env PATH="$work/bin:$PATH" STUB_LOG="$work/log" "$@" "$here/google-client.sh" "${args[@]}" 2>&1)
  status=$?
  if [ "$status" -ne "$want" ] || [[ "$out" != *"$text"* ]]; then
    fail "$name: status=$status (want $want) out=[$out]"; return 1
  fi
  if grep -q -- GOCSPX "$work/log" || [[ "$out" == *GOCSPX* ]]; then
    fail "$name: the secret is on a command line or in the output"; return 1
  fi
  echo "ok   $name"
}

run "the client and both redirect URIs are known" 0 "ok   google: https://other.tacplus.dev/cb is registered" client
run "an unknown client is refused" 1 "invalid_client" client -- STUB_CLIENT=unknown
run "an unregistered redirect URI is refused, by name" 1 \
  "FAIL google: https://other.tacplus.dev/cb is not a redirect URI of the-client.apps.googleusercontent.com (redirect_uri_mismatch)" \
  client -- STUB_UNREGISTERED=https://other.tacplus.dev/cb
run "Google not answering is 3" 3 "Google does not answer" client -- STUB_GOOGLE=down

printf 'GOCSPX-the-good-one' > "$work/good"
printf 'GOCSPX-a-bad-one' > "$work/bad"
run "a secret Google takes passes" 0 "ok   google: Google takes the secret of the-client.apps.googleusercontent.com" \
  secret "$work/good" -- STUB_SECRET_OK=GOCSPX-the-good-one
run "a secret Google refuses fails" 1 "The provided client secret is invalid." \
  secret "$work/bad" -- STUB_SECRET_OK=GOCSPX-the-good-one
run "a deleted client fails the secret too" 1 "The OAuth client was not found." \
  secret "$work/good" -- STUB_SECRET_OK=GOCSPX-the-good-one STUB_CLIENT=unknown
run "Google not answering the secret check is 3" 3 "Google does not answer" secret "$work/good" -- STUB_GOOGLE=down
run "no secret file is a usage error" 2 "usage" secret "$work/none"
run "no mode is a usage error" 2 "usage"

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
