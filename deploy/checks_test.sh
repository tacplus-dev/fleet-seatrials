#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/checks.sh against stub kubectl, curl and openssl (and the real
# opa, jq and yq): each check passes on a healthy fleet and fails, saying
# what, on a pod not Ready, a certificate near expiry or that does not verify,
# an empty JWKS or a foreign issuer, a provider missing or sent to the wrong
# IdP, and a routing policy that sends a claim to the wrong tenant.
#
#   deploy/checks_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/http"

cat > "$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "get pods -A -o json" ] || { echo "unexpected kubectl $*" >&2; exit 3; }
cat "$STUB_PODS"
EOF
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
data="" url=""
while [ $# -gt 0 ]; do
  case "$1" in -d) data=$2; shift 2 ;; -X|-H) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac
done
path=${url#https://*/}
[ -n "$data" ] && [ "$path" = oauth/Auth/Authorize ] && path="$path-$(jq -r .provider_index <<<"$data")"
f="$STUB_HTTP/$(tr '/' '_' <<<"$path")"
[ -f "$f" ] || exit 22
cat "$f"
EOF
cat > "$work/bin/openssl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  s_client*) [ "${STUB_VERIFY:-ok}" = ok ] && echo PEM ;;
  "x509") read -r l; [ "$l" = PEM ] && echo PEM ;;
  *-checkend*) [ "${STUB_EXPIRING:-}" != 1 ] ;;
  *-subject*) echo "subject=CN=seatrials.tacplus.dev"; echo "notAfter=Jan 23 07:22:18 2027 GMT" ;;
esac
EOF
chmod +x "$work/bin/"*

pod() { # NAMESPACE NAME PHASE READY
  jq -n --arg ns "$1" --arg n "$2" --arg p "$3" --arg r "$4" \
    '{metadata: {namespace: $ns, name: $n}, status: {phase: $p, conditions: [{type: "Ready", status: $r}]}}'
}
{ pod schematic kernel0-a Running True; pod schematic tenantecho-1 Running True; pod pigeons job-x Succeeded False
  pod kube-system dns Running False; } | jq -s '{items: .}' > "$work/pods-ok.json"
{ pod schematic kernel0-a Running True; pod schematic gateway0-b Running False; } | jq -s '{items: .}' > "$work/pods-bad.json"
echo '{"items": []}' > "$work/pods-none.json"

h=$work/http
echo '{"issuer":"https://seatrials.tacplus.dev","jwks_uri":"https://seatrials.tacplus.dev/.well-known/jwks.json"}' \
  > "$h/.well-known_openid-configuration"
echo '{"keys":[{"kty":"EC","kid":"k1"}]}' > "$h/.well-known_jwks.json"
echo '{"providers":[{"name":"Google"},{"name":"Microsoft","providerIndex":1},{"name":"Apple","providerIndex":2},
  {"name":"Test Google","providerIndex":3},{"name":"Test Microsoft","providerIndex":4},{"name":"Test Apple","providerIndex":5}]}' \
  > "$h/oauth_Auth_ListProviders"
for i in 3:google 4:microsoft 5:apple; do
  echo "{\"redirectUrl\":\"https://idp.test.tacplus.dev:8443/realms/${i#*:}/protocol/openid-connect/auth?client_id=tacplus-dev&state=s\"}" \
    > "$h/oauth_Auth_Authorize-${i%%:*}"
done
echo '{"redirectUrl":"https://accounts.google.com/o/oauth2/v2/auth?client_id=23279701427-3nm40dmid06nd3niqufrq88sbl90p0n3.apps.googleusercontent.com&state=s"}' \
  > "$h/oauth_Auth_Authorize-0"
echo '{"redirectUrl":"https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=deee63f8-1d3b-46c8-aa3a-f7b2d7eb3f85&state=s"}' \
  > "$h/oauth_Auth_Authorize-1"
echo '{"redirectUrl":"https://appleid.apple.com/auth/authorize?client_id=dev.tacplus.seatrials.web&state=s"}' \
  > "$h/oauth_Auth_Authorize-2"

# The routing policy as the operator renders it into the bootstrap config.
rego() { # ALPHA_DOMAIN
  cat <<EOF
package entitlements.tenants

default namespace := ""

namespace := "/tenants/alpha" if {
	input.claims.provider_iss == "https://accounts.google.com"
	input.claims["email_domain"] == "$1"
}

namespace := "/tenants/beta" if {
	input.claims.provider_iss == "https://login.microsoftonline.com/common/v2.0"
	input.claims["tid"] == "ec3604c3-01c7-4537-aa2b-c39874000664"
}

namespace := "/tenants/beta" if {
	input.claims.provider_iss == "https://idp.test.tacplus.dev:8443/realms/microsoft"
	input.claims["email_domain"] == "beta.test"
}
EOF
}
mkdir -p "$work/configs-text" "$work/configs-b64" "$work/configs-wrong" "$work/configs-none"
echo 'kind: other' > "$work/configs-text/a.yaml"
rego thescottsweb.com | jq -Rs '{opa: {files: [{name: "namespace.rego", content: .}]}}' | yq -P > "$work/configs-text/bootstrap0.yaml"
rego thescottsweb.com | base64 | tr -d '\n' | jq -Rs '{opa: {files: [{name: "namespace.rego", content: .}]}}' |
  yq -P > "$work/configs-b64/bootstrap0.yaml"
rego example.com | jq -Rs '{files: [{content: .}]}' | yq -P > "$work/configs-wrong/bootstrap0.yaml"
echo 'kind: other' > "$work/configs-none/bootstrap0.yaml"

failures=0
# run NAME WANT(pass|fail) EXPECT CHECK... [-- VAR=VALUE...]: EXPECT must be in the output.
run() {
  local name=$1 want=$2 expect=$3 out status; shift 3
  local args=() envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1:-}" = -- ] && { shift; envs=("$@"); }
  out=$(env PATH="$work/bin:$PATH" STUB_PODS="$work/pods-ok.json" STUB_HTTP="$work/http" "${envs[@]}" \
    "$here/checks.sh" "${args[@]}" 2>&1)
  status=$?
  if { [ "$want" = pass ] && [ "$status" -ne 0 ]; } || { [ "$want" = fail ] && [ "$status" -eq 0 ]; } ||
     [[ "$out" != *"$expect"* ]]; then
    echo "FAIL $name: status=$status out=[$out]"; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}

run "pods: all Ready (other namespaces and finished Jobs aside)" pass "all 2 Ready" pods
run "pods: one not Ready" fail "schematic/gateway0-b" pods -- STUB_PODS="$work/pods-bad.json"
run "pods: none at all" fail "none in namespaces" pods -- STUB_PODS="$work/pods-none.json"
run "cert: verifies, not expiring" pass "subject=CN=seatrials.tacplus.dev" cert
run "cert: expiring" fail "expires within 14 days" cert -- STUB_EXPIRING=1
run "cert: does not verify" fail "does not serve a certificate that verifies" cert -- STUB_VERIFY=no
run "jwks: keys" pass "EC k1" jwks
echo '{"keys":[]}' > "$work/empty-jwks"; mkdir -p "$work/http2"; cp -a "$h/." "$work/http2/"; cp "$work/empty-jwks" "$work/http2/.well-known_jwks.json"
run "jwks: no key" fail "holds no usable key" jwks -- STUB_HTTP="$work/http2"
mkdir -p "$work/http3"; cp -a "$h/." "$work/http3/"
echo '{"issuer":"https://local.dev","jwks_uri":"https://seatrials.tacplus.dev/.well-known/jwks.json"}' > "$work/http3/.well-known_openid-configuration"
run "jwks: another issuer" fail "names issuer [https://local.dev]" jwks -- STUB_HTTP="$work/http3"
run "signin: every provider to its IdP" pass "Apple -> appleid.apple.com" signin
mkdir -p "$work/http4"; cp -a "$h/." "$work/http4/"
echo '{"providers":[{"name":"Google"},{"name":"Microsoft","providerIndex":1}]}' > "$work/http4/oauth_Auth_ListProviders"
run "signin: a provider not listed" fail "Apple is not listed" signin -- STUB_HTTP="$work/http4"
mkdir -p "$work/http6"; cp -a "$h/." "$work/http6/"
echo '{"providers":[{"name":"Google"},{"name":"Microsoft","providerIndex":1},{"name":"Apple","providerIndex":2}]}' > "$work/http6/oauth_Auth_ListProviders"
run "signin: the test IdP's providers off are no failure" pass "Test Google is off" signin -- STUB_HTTP="$work/http6"
run "signin: the test IdP's providers to its realms" pass "Test Apple -> idp.test.tacplus.dev:8443" signin
run "opa: the test IdP's domain claimed by beta" pass "email_domain=beta.test -> /tenants/beta" opa "$work/configs-text"
mkdir -p "$work/http5"; cp -a "$h/." "$work/http5/"
echo '{"redirectUrl":"https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=other&state=s"}' > "$work/http5/oauth_Auth_Authorize-1"
run "signin: a provider with another client id" fail "Microsoft's Authorize does not send" signin -- STUB_HTTP="$work/http5"
run "opa: the policy as text" pass "email_domain=thescottsweb.com -> /tenants/alpha" opa "$work/configs-text"
run "opa: the policy as base64" pass "tid=ec3604c3-01c7-4537-aa2b-c39874000664 -> /tenants/beta" opa "$work/configs-b64"
run "opa: another claim value routes nowhere" pass "email_domain=other-thescottsweb.com -> no tenant" opa "$work/configs-text"
run "opa: a policy routing the wrong domain" fail "want /tenants/alpha" opa "$work/configs-wrong"
run "opa: no policy" fail "no tenants routing policy" opa "$work/configs-none"
run "all: one failure fails the whole" fail "FAIL pods" all "$work/configs-text" -- STUB_PODS="$work/pods-bad.json"

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
