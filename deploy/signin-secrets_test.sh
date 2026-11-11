#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/signin-secrets.sh against stub kubectl, yq and curl. The secrets
# come from the deploy pipeline's GitLab variables and, Google's, from a version
# of the Secret Manager secret google-signin-seatrials (#46), never from a file
# or clipboard on a laptop: a Microsoft value that is not an Entra secret value,
# or any secret with whitespace in it, is refused (non-zero, saying why, never
# echoing it) and nothing is written to the cluster; well-formed ones are
# written; an unset one keeps the cluster's current secret; the Apple key
# restarts oauth only when it differs from the one in place; the test IdP's
# providers get the secrets derived from their seed and are on only while their
# realm answers. Google's version is the client JSON the Console downloads or a
# bare secret; a JSON for another client than oauth.yaml's, or a secret Google
# refuses, is refused, and the old GitLab variable is no longer read.
# Needs bash, jq and python3.
#
#   deploy/signin-secrets_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  "config current-context") echo gke_tacplus-dev_us-central1-a_dev ;;
  *"get configmap kernel-config-override"*)
    echo '{"configs":{"oauth_config":{"providers":[{"name":"Google","client_secret":"kept-google"},{"name":"Microsoft","client_secret":"kept-microsoft"}]}}}' ;;
  *"get secret"*) printf '%s' "${STUB_APPLE_B64:-}" ;;
  *"create configmap"*"--dry-run=client"*)
    for a in "$@"; do case "$a" in --from-file=override.json=*) cp "${a#*override.json=}" "$STUB_OVERRIDE" ;; esac; done
    echo "kind: rendered" ;;
  *"--dry-run=client"*) echo "kind: rendered" ;;
  *"apply -f -"*) cat > /dev/null; echo "WRITE" >> "$STUB_LOG" ;;
  *"rollout restart"*) echo "RESTART" >> "$STUB_LOG" ;;
esac
EOF
cat > "$work/bin/yq" <<'EOF'
#!/usr/bin/env bash
echo '[{"name":"Google","issuer":"https://accounts.google.com","client_id":"g","allowed_redirect_uri_prefixes":["https://seatrials.tacplus.dev/"],"enable":true},{"name":"Microsoft","client_id":"m","enable":true},{"name":"Apple","client_id":"a","enable":true,"apple":{"key_id":"k"}},{"name":"Test Google","issuer":"https://idp.test.tacplus.dev:8443/realms/google","client_id":"tacplus-dev","enable":true}]'
EOF
# Google's token endpoint (deploy/google-client.sh): takes the secret unless
# STUB_GOOGLE=reject, or does not answer with STUB_GOOGLE=down. The test IdP's
# discovery: up unless STUB_TEST_IDP=down.
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
case "$*" in *https://oauth2.googleapis.com/token*)
  case "${STUB_GOOGLE:-accept}" in
    accept) echo '{"error": "invalid_grant", "error_description": "Malformed auth code."}' ;;
    reject) echo '{"error": "invalid_client", "error_description": "The provided client secret is invalid."}' ;;
    *) exit 7 ;;
  esac
  exit 0 ;;
esac
[ "${STUB_TEST_IDP:-up}" = up ] || exit 22
for a in "$@"; do case "$a" in https://*/.well-known/openid-configuration)
  echo "{\"issuer\":\"${a%/.well-known/openid-configuration}\"}" ;; esac; done
EOF
chmod +x "$work/bin/"*

failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
# run NAME WANT [VAR=VALUE...]: WANT is "refuse" or "write". Every FLEET_*
# variable not given is unset. Leaves the log in $work/log and the override in
# $work/override.json.
run() {
  local name=$1 want=$2 status
  shift 2
  : > "$work/log"; rm -f "$work/override.json"
  out=$(env -u FLEET_MICROSOFT_CLIENT_SECRET -u FLEET_GOOGLE_CLIENT_SECRET -u GOOGLE_SIGNIN_FILE -u FLEET_APPLE_KEY_P8 -u TEST_IDP_CLIENT_SEED \
    PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_OVERRIDE="$work/override.json" "$@" \
    "$here/signin-secrets.sh" 2>&1)
  status=$?
  local wrote=false secret
  grep -q WRITE "$work/log" && wrote=true
  for secret in "$@"; do
    case "$secret" in
      FLEET_*=* | TEST_IDP_*=*) secret=${secret#*=}
        if [ -n "$secret" ] && [[ "$out" == *"$secret"* ]]; then
          fail "$name: echoed a secret: out=[$out]"; return 1
        fi ;;
    esac
  done
  # Google's secrets here all start GOCSPX-: none may be echoed or on a command line.
  if [[ "$out" == *GOCSPX-* ]] || grep -q GOCSPX- "$work/log"; then
    fail "$name: a Google secret is in the output or on a command line: out=[$out]"; return 1
  fi
  case "$want" in
    refuse)
      if [ "$status" -eq 0 ] || $wrote || [ -z "$out" ]; then
        fail "$name: status=$status wrote=$wrote out=[$out]"; return 1
      fi ;;
    write)
      if [ "$status" -ne 0 ] || ! $wrote; then
        fail "$name: status=$status wrote=$wrote out=[$out]"; return 1
      fi ;;
  esac
  echo "ok   $name"
}
# provider NAME FIELD: the field of that provider in the override written.
provider() { jq -r --arg n "$1" ".configs.oauth_config.providers[] | select(.name == \$n) | .$2" "$work/override.json"; }
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else fail "$1: got [$2], want [$3]"; fi; }

value=abc8Q~Zx0_yv.Tq-1rLmNoPqRsTuVwXyZ0123456   # 40 characters, the shape Entra issues today
run "well-formed Microsoft value is written" write FLEET_MICROSOFT_CLIENT_SECRET="$value" &&
  check "the Microsoft value is the variable's" "$(provider Microsoft client_secret)" "$value"
run "a GUID (the Secret ID) is refused" refuse FLEET_MICROSOFT_CLIENT_SECRET=3f2b8c1e-9a4d-4e7b-8c2f-1a2b3c4d5e6f
run "an upper-case GUID is refused" refuse FLEET_MICROSOFT_CLIENT_SECRET=3F2B8C1E-9A4D-4E7B-8C2F-1A2B3C4D5E6F
run "a value with a space is refused" refuse FLEET_MICROSOFT_CLIENT_SECRET="abc8Q~Zx0_yv.Tq-1rLmN PqRsTuVwXyZ0123456"
run "a value with a tab is refused" refuse FLEET_MICROSOFT_CLIENT_SECRET="abc8Q~Zx0_yv.Tq-1rLmN	PqRsTuVwXyZ0123456"
run "a value with a newline is refused" refuse FLEET_MICROSOFT_CLIENT_SECRET="$value"$'\n'
run "a value starting with ~ is refused" refuse FLEET_MICROSOFT_CLIENT_SECRET="~/Downloads/abcdefghijklmnopqrstuvwxyz0123"
run "a value starting with / is refused" refuse FLEET_MICROSOFT_CLIENT_SECRET="/abc8Q~Zx0_yv.Tq-1rLmNoPqRsTuVwXyZ012345"
run "a value starting with . is refused" refuse FLEET_MICROSOFT_CLIENT_SECRET=".abc8Q~Zx0_yv.Tq-1rLmNoPqRsTuVwXyZ012345"
run "29 characters is refused" refuse FLEET_MICROSOFT_CLIENT_SECRET=abcdefghijABCDEFGHIJ012345678
run "61 characters is refused" refuse \
  FLEET_MICROSOFT_CLIENT_SECRET=abcdefghijABCDEFGHIJ0123456789abcdefghijABCDEFGHIJ0123456789x
run "a character outside [A-Za-z0-9_.~-] is refused" refuse \
  FLEET_MICROSOFT_CLIENT_SECRET="abc8Q~Zx0_yv.Tq-1rLmNoPqRsTuVwXyZ01234+6"

run "with no variable, the current secrets are kept" write &&
  check "Google kept" "$(provider Google client_secret)" kept-google &&
  check "Microsoft kept" "$(provider Microsoft client_secret)" kept-microsoft &&
  check "Apple off without a key" "$(provider Apple enable)" false

# Google's secret: a version of google-signin-seatrials (ci_google_signin), the
# client JSON the Console downloads when the client is made, or a bare secret
# (a rotation), never the GitLab variable (#46).
printf 'GOCSPX-bare-secret-0123456789\n' > "$work/google-bare"
printf '{"web":{"client_id":"g","project_id":"tacplus-dev","client_secret":"GOCSPX-json-secret-0123456789","redirect_uris":["https://seatrials.tacplus.dev/"]}}\n' > "$work/google-json"
printf '{"web":{"client_id":"the-new-client.apps.googleusercontent.com","client_secret":"GOCSPX-json-secret-0123456789"}}\n' > "$work/google-other"
printf '{"web":{"client_id":"g"}}\n' > "$work/google-nosecret"
printf 'GOCSPX-a b\n' > "$work/google-space"
run "a bare Google secret from Secret Manager is written" write GOOGLE_SIGNIN_FILE="$work/google-bare" &&
  check "the Google secret is the version's" "$(provider Google client_secret)" GOCSPX-bare-secret-0123456789 &&
  check "Google on" "$(provider Google enable)" true &&
  check "Microsoft still kept" "$(provider Microsoft client_secret)" kept-microsoft &&
  check "Google was asked whether it takes the secret" "$(grep -c 'oauth2.googleapis.com/token' "$work/log")" 1
run "the client JSON the Console downloads is written" write GOOGLE_SIGNIN_FILE="$work/google-json" &&
  check "the Google secret is the JSON's" "$(provider Google client_secret)" GOCSPX-json-secret-0123456789
if run "a client JSON for another client is refused" refuse GOOGLE_SIGNIN_FILE="$work/google-other"; then
  [[ "$out" == *the-new-client.apps.googleusercontent.com*deploy/bootstrap/services/oauth.yaml* ]] &&
    echo "ok   the refusal names the client id to commit" || fail "the refusal does not name the client: [$out]"
fi
run "a client JSON without a secret is refused" refuse GOOGLE_SIGNIN_FILE="$work/google-nosecret"
run "a Google secret with whitespace is refused" refuse GOOGLE_SIGNIN_FILE="$work/google-space"
run "an empty version is refused" refuse GOOGLE_SIGNIN_FILE=/dev/null
run "a secret Google refuses is refused" refuse GOOGLE_SIGNIN_FILE="$work/google-bare" STUB_GOOGLE=reject
printf -- '-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n' > "$work/AuthKey.p8"
run "a Google refusal writes no Apple key either" refuse GOOGLE_SIGNIN_FILE="$work/google-bare" STUB_GOOGLE=reject \
  FLEET_APPLE_KEY_P8="$work/AuthKey.p8"
run "Google not answering: the secret is written, saying so" write GOOGLE_SIGNIN_FILE="$work/google-bare" STUB_GOOGLE=down &&
  check "the Google secret is the version's" "$(provider Google client_secret)" GOCSPX-bare-secret-0123456789
if run "the GitLab variable FLEET_GOOGLE_CLIENT_SECRET is no longer read" write FLEET_GOOGLE_CLIENT_SECRET=GOCSPX-from-gitlab-0123; then
  check "Google kept" "$(provider Google client_secret)" kept-google
  [[ "$out" == *"FLEET_GOOGLE_CLIENT_SECRET is not read"* ]] && echo "ok   it says the variable is not read" ||
    fail "no word on the ignored variable: [$out]"
fi

# The test IdP's providers (test-idp/README.md): each client secret is derived
# from TEST_IDP_CLIENT_SEED, and a provider is on only with its secret and
# while its realm's discovery answers, since oauth refuses its whole config
# over one provider it cannot use.
seed=cccccccccccccccccccccccccccccccccccccccc
test_secret=$(TEST_IDP_CLIENT_SEED=$seed python3 "$here/../test-idp/testidp.py" secret client/google/tacplus-dev)
run "the test IdP's client secret is derived from its seed" write TEST_IDP_CLIENT_SEED=$seed &&
  check "Test Google's secret" "$(provider 'Test Google' client_secret)" "$test_secret" &&
  check "Test Google on" "$(provider 'Test Google' enable)" true &&
  check "the derived secret is in no command line" "$(grep -c -- "$test_secret" "$work/log")" 0
run "without the seed, Test Google is off" write &&
  check "Test Google off" "$(provider 'Test Google' enable)" false
run "with its realm down, Test Google is off" write TEST_IDP_CLIENT_SEED=$seed STUB_TEST_IDP=down &&
  check "Test Google off" "$(provider 'Test Google' enable)" false &&
  check "Google still on" "$(provider Google enable)" true
run "a seed too short is refused" refuse TEST_IDP_CLIENT_SEED=tooshort1

printf -- '-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n' > "$work/AuthKey.p8"
run "a new Apple key is written and oauth restarted" write FLEET_APPLE_KEY_P8="$work/AuthKey.p8" \
  STUB_APPLE_B64="$(printf old | base64)" &&
  check "oauth restarted" "$(grep -c RESTART "$work/log")" 1
run "the Apple key already in place restarts nothing" write FLEET_APPLE_KEY_P8="$work/AuthKey.p8" \
  STUB_APPLE_B64="$(base64 < "$work/AuthKey.p8" | tr -d '\n')" &&
  check "oauth not restarted" "$(grep -c RESTART "$work/log")" 0 &&
  check "Apple on with its key" "$(provider Apple enable)" true
printf 'not a key\n' > "$work/bad.p8"
run "an Apple variable that is not a .p8 key is refused" refuse FLEET_APPLE_KEY_P8="$work/bad.p8"
run "a Microsoft refusal writes no Apple key either" refuse \
  FLEET_MICROSOFT_CLIENT_SECRET=3f2b8c1e-9a4d-4e7b-8c2f-1a2b3c4d5e6f FLEET_APPLE_KEY_P8="$work/AuthKey.p8"

out=$(PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_OVERRIDE="$work/override.json" \
  "$here/signin-secrets.sh" --microsoft-secret-from-clipboard 2>&1) &&
  fail "the old clipboard flag is still taken: [$out]" || echo "ok   the clipboard and file flags are gone"

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
