#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/init-secrets.sh against a stub GitLab API (curl) and a stub
# schematic-operator: with neither variable in the project it generates both
# and stores each as a protected file variable of the deployment's scope
# (crypto.yaml gzipped, base64-encoded and masked, in parts of at most GitLab's
# 10,000 characters: FLEET_CRYPTO_YAML, then FLEET_CRYPTO_YAML_2...; more than
# nine parts, or a stale part, is refused); with
# both it generates nothing and writes nothing; with one only it refuses (a CA
# and its crypto.yaml are a pair); a refused write fails, saying which; no
# generated value reaches the output or a command line; and no token, no run.
#
#   deploy/init-secrets_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# The GitLab API: GET .../variables/KEY?filter[environment_scope]=S answers 200
# when $STUB_VARS/KEY exists, else 404; POST .../variables stores the form in
# $STUB_VARS/KEY.form and its value in KEY.value (201), or answers $STUB_POST_STATUS. Every call's
# arguments go to $STUB_CALLS.
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_CALLS"
out=/dev/stdout code=200 url="" post=0 form=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -H) [[ "$2" == @* ]] && cat "${2#@}" >> "$STUB_HEADERS"; shift 2 ;;
    -d|--data-urlencode) post=1; form+=("$2"); shift 2 ;;
    -X) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [ "$post" = 1 ]; then
  key="" ; for f in "${form[@]}"; do case "$f" in key=*) key=${f#key=} ;; esac; done
  code=${STUB_POST_STATUS:-201}
  if [ "$code" = 201 ]; then
    for f in "${form[@]}"; do
      case "$f" in value@*) cp "${f#value@}" "$STUB_VARS/$key.value" ;; *) echo "$f" ;; esac
    done > "$STUB_VARS/$key.form"
  fi
  echo '{}' > "$out"
else
  key=${url##*/variables/}; key=${key%%\?*}
  [[ "$url" == *"filter%5Benvironment_scope%5D=seatrials%2A" ]] || { echo "unexpected url $url" >&2; exit 3; }
  [ -f "$STUB_VARS/$key" ] && echo '{"value":"SECRET-FROM-API"}' > "$out" || { code=404; echo '{"message":"404 Variable Not found"}' > "$out"; }
fi
printf '%s' "$code"
EOF
cat > "$work/bin/schematic-operator" <<'EOF'
#!/usr/bin/env bash
echo "schematic-operator $*" >> "$STUB_CALLS"
d=$SCHEMATIC_OPERATOR_DIR
case "$1 $2" in
  "init ca") printf 'pki:\n  root_ca: GENERATED-CA-KEY\n' > "$d/crypto.yaml"; echo GENERATED-CA-CERT > "$d/ca.pem" ;;
  "init cluster") [ -f "$d/crypto.yaml" ] && printf '  cluster: GENERATED-CLUSTER-KEY\n' >> "$d/crypto.yaml"
    # STUB_BIG random bytes, which do not compress: 10,000 encode to over 13,000.
    [ -z "${STUB_BIG:-}" ] || head -c "$STUB_BIG" /dev/urandom | base64 -w0 >> "$d/crypto.yaml"
    printf 'fqdn: rewritten\n' > "$d/operator.yaml" ;;
esac
EOF
chmod +x "$work/bin/"*

failures=0
# run NAME WANT(pass|fail) EXPECT [VAR=VALUE...]: EXPECT must be in the output.
run() {
  local name=$1 want=$2 expect=$3 status; shift 3
  rm -rf "$work/vars"; mkdir "$work/vars"; : > "$work/calls"; : > "$work/headers"
  for v in "${pre[@]}"; do touch "$work/vars/$v"; done
  out=$(env PATH="$work/bin:$PATH" STUB_VARS="$work/vars" STUB_CALLS="$work/calls" STUB_HEADERS="$work/headers" \
    FLEET_INIT_TOKEN=glpat-test-token CI_API_V4_URL=https://gitlab.example/api/v4 CI_PROJECT_ID=42 "$@" \
    "$here/init-secrets.sh" 2>&1)
  status=$?
  if { [ "$want" = pass ] && [ "$status" -ne 0 ]; } || { [ "$want" = fail ] && [ "$status" -eq 0 ]; } ||
     [[ "$out" != *"$expect"* ]]; then
    echo "FAIL $name: status=$status out=[$out]"; failures=$((failures + 1)); return 1
  fi
  echo "ok   $name"
}
# no_leak NAME: no generated or stored value in the output or any command line.
no_leak() {
  if grep -q 'GENERATED\|SECRET-FROM-API\|glpat-test-token' <<<"$out$(cat "$work/calls")"; then
    echo "FAIL $1: a secret in the output or a command line"; failures=$((failures + 1))
  else echo "ok   $1"; fi
}
form() { # KEY FIELD: the stored form's field
  sed -n "s/^$2=//p" "$work/vars/$1.form" 2>/dev/null
}
want() { # NAME CONDITION...
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}

pre=()
run "neither: both generated and stored" pass "FLEET_CA_PEM generated and stored"
want "crypto.yaml stored, gzipped and base64-encoded on one line: the CA and the cluster PKI" \
  test "$(base64 -d < "$work/vars/FLEET_CRYPTO_YAML.value" | gunzip)" = "$(printf 'pki:\n  root_ca: GENERATED-CA-KEY\n  cluster: GENERATED-CLUSTER-KEY')" -a \
    "$(wc -l < "$work/vars/FLEET_CRYPTO_YAML.value")" = 0
want "ca.pem stored as it is" test "$(cat "$work/vars/FLEET_CA_PEM.value")" = GENERATED-CA-CERT
for k in FLEET_CRYPTO_YAML FLEET_CA_PEM; do
  want "$k: a protected file variable of scope seatrials*, raw" \
    test "$(form $k variable_type)/$(form $k protected)/$(form $k environment_scope)/$(form $k raw)" = "file/true/seatrials*/true"
done
want "FLEET_CRYPTO_YAML masked and hidden" test "$(form FLEET_CRYPTO_YAML masked)/$(form FLEET_CRYPTO_YAML masked_and_hidden)" = true/true
want "FLEET_CA_PEM not masked (a PEM is many lines; GitLab cannot)" test "$(form FLEET_CA_PEM masked)" = false
want "the cluster PKI for the committed fqdn" grep -q "init cluster --fqdn seatrials.tacplus.dev" "$work/calls"
want "the token only in a header file" grep -qx "PRIVATE-TOKEN: glpat-test-token" "$work/headers"
no_leak "neither: no secret in the output or a command line"
want "the committed operator.yaml untouched" grep -q "^fqdn: seatrials.tacplus.dev" "$here/bootstrap/operator.yaml"

pre=(FLEET_CRYPTO_YAML FLEET_CA_PEM)
run "both: nothing generated" pass "nothing to generate"
want "both: nothing written" test -z "$(ls "$work/vars"/*.form 2>/dev/null)"
want "both: the operator not run" test -z "$(grep schematic-operator "$work/calls")"
no_leak "both: the API's answer is not printed"

pre=(FLEET_CA_PEM)
run "one only: refused, a pair" fail "FLEET_CA_PEM exists but FLEET_CRYPTO_YAML does not"
want "one only: nothing written" test -z "$(ls "$work/vars"/*.form 2>/dev/null)"

want "a crypto.yaml that fits is one part, FLEET_CRYPTO_YAML" test ! -e "$work/vars/FLEET_CRYPTO_YAML_2.form"

pre=()
run "a crypto.yaml over GitLab's limit encoded is stored in parts" pass "FLEET_CRYPTO_YAML_2 generated and stored" STUB_BIG=10000
want "two parts, each within 10,000 characters" test ! -e "$work/vars/FLEET_CRYPTO_YAML_3.form" -a \
  "$(wc -c < "$work/vars/FLEET_CRYPTO_YAML.value")" -le 10000 -a "$(wc -c < "$work/vars/FLEET_CRYPTO_YAML_2.value")" -le 10000
want "the parts, joined, decode to crypto.yaml" \
  bash -c 'cat "$1/FLEET_CRYPTO_YAML.value" "$1/FLEET_CRYPTO_YAML_2.value" | base64 -d | gunzip | grep -q "^  cluster: GENERATED-CLUSTER-KEY"' _ "$work/vars"
want "FLEET_CRYPTO_YAML_2: a masked, hidden, protected file variable of scope seatrials*" \
  test "$(form FLEET_CRYPTO_YAML_2 variable_type)/$(form FLEET_CRYPTO_YAML_2 protected)/$(form FLEET_CRYPTO_YAML_2 environment_scope)/$(form FLEET_CRYPTO_YAML_2 masked_and_hidden)" = "file/true/seatrials*/true"
no_leak "parts: no secret in the output or a command line"

pre=()
run "a crypto.yaml of more than nine parts is refused, writing nothing" fail "over nine parts" STUB_BIG=100000
want "more than nine parts: nothing written" test -z "$(ls "$work/vars"/*.form 2>/dev/null)"

pre=(FLEET_CRYPTO_YAML_2)
run "a stale part is refused, writing nothing" fail "FLEET_CRYPTO_YAML_2 exists" STUB_BIG=10000
want "a stale part: nothing written" test -z "$(ls "$work/vars"/*.form 2>/dev/null)"

pre=()
run "a refused write fails, saying which" fail "storing FLEET_CRYPTO_YAML (scope seatrials*): HTTP 403" STUB_POST_STATUS=403
no_leak "a refused write: no secret in the output"

out=$(env PATH="$work/bin:$PATH" STUB_CALLS="$work/calls" CI_API_V4_URL=x CI_PROJECT_ID=1 "$here/init-secrets.sh" 2>&1)
if [ $? -ne 0 ] && [[ "$out" == *"FLEET_INIT_TOKEN is not set"* ]]; then echo "ok   no token, no run"
else echo "FAIL no token, no run: out=[$out]"; failures=$((failures + 1)); fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
