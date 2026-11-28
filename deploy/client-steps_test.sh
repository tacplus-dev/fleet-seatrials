#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/client-steps.sh (#77) against a stub seatrials that keeps the
# kernel's tenants and their pairs in a directory: as the root credential
# ci_crypto root placed, it creates operator.yaml's tenants alpha and beta,
# installs a fresh pair of each (ci-alpha, ci-beta), signs in with it and pings,
# and each tenant's ping is served by that tenant. A second run is the same:
# no tenant created twice, one ci- pair per tenant, a person's pair kept. A root
# credential operator.yaml does not register (the pair init-secrets printed
# not committed yet), or whose key is not the registered one, is refused before
# the client is run; no root credential, a refused step, and a ping another
# tenant serves fail, saying which. No private key reaches the output.
#
#   deploy/client-steps_test.sh    # needs bash, jq and yq
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
mkdir -p "$work/bin"

# The client, flags first as Go's flag package takes them. The kernel is
# $STUB_KERNEL: a tenant is a directory, its pairs the files in it. A
# credential is $SEATRIALS_HOME/NAME.cred.json; a token NAME.token. STUB_FAIL
# names a command that fails ("tenant cred"); STUB_CROSS=1 serves every ping
# from alpha.
cat > "$work/bin/seatrials" <<'EOF'
#!/usr/bin/env bash
echo "seatrials $*" >> "$STUB_CALLS"
err() { printf '{"error":"%s"}\n' "$*"; exit 1; }
[ "${STUB_FAIL:-}" != "$1 ${2:-}" ] || err "rpc error: code = PermissionDenied desc = refused"
home=${SEATRIALS_HOME:?}
case "$1 ${2:-}" in
  "keygen --tenant")
    ns=$3 name=$4 id=$4-$RANDOM$RANDOM
    printf '{"key":{"d":"TENANT-PRIVATE-KEY"},"pair":{"id":"%s","tenant_name":"%s"},"pair_id":"%s","tenant":"%s"}\n' \
      "$id" "$ns" "$id" "$ns" > "$home/$name.cred.json"
    printf '{"credential":"%s","cred_pair":{"id":"%s"}}\n' "$name" "$id" ;;
  "login --as")
    [ -f "$home/$3.cred.json" ] || err "no credential $3"
    echo "TOKEN-OF-$3" > "$home/$3.token"
    printf '{"credential":"%s","token_received":true,"namespace":"%s"}\n' "$3" "$(jq -r .tenant "$home/$3.cred.json")" ;;
  "tenant create")
    [ "$3" = --if-missing ] || err "tenant create without --if-missing"
    [ -f "$home/root.token" ] || err "not logged in as root"
    d=$STUB_KERNEL/${4#/tenants/}
    if [ -d "$d" ]; then printf '{"tenant":"%s","exists":true}\n' "$4"; else mkdir -p "$d"; printf '{"tenant_namespace":"%s"}\n' "$4"; fi ;;
  "tenant cred")
    [ "$3" = --replace ] || err "tenant cred without --replace"
    d=$STUB_KERNEL/${4#/tenants/}
    [ -d "$d" ] || err "rpc error: code = NotFound desc = no tenant $4"
    rm -f "$d/$5"-*
    id=$(jq -r .pair_id "$home/$5.cred.json"); : > "$d/$id"
    printf '{"tenant":"%s","cred_pair":"%s","cred_pairs":%d}\n' "$4" "$id" "$(ls "$d" | wc -l)" ;;
  "ping --as")
    [ -f "$home/$3.token" ] || err "not logged in as $3"
    t=$(jq -r .tenant "$home/$3.cred.json"); [ -z "${STUB_CROSS:-}" ] || t=/tenants/alpha
    printf '{"message":"%s","served_by":"tenantecho%s"}\n' "$4" "$t" ;;
  *) err "unexpected seatrials $*" ;;
esac
EOF
chmod +x "$work/bin/seatrials"

# The checkout: client-steps.sh and an operator.yaml registering root-1.
src=$work/src
mkdir -p "$src/deploy/bootstrap"
cp "$here/deploy/client-steps.sh" "$src/deploy/"
pub='{"kty":"KEY_TYPE_EC","crv":"P-256","kid":"root-1","x":"PUBLIC-X","y":"PUBLIC-Y"}'
cat > "$src/deploy/bootstrap/operator.yaml" <<EOF
deployment: seatrials
tenants:
    - alpha
    - beta
root_cred_pairs:
    - {"description": "seatrials client root", "id": "root-1", "public_key": $pub, "tenant_name": "/"}
EOF
# root_cred ID X: the root credential ci_crypto root places.
root_cred() {
  rm -rf "$work/home" && mkdir -p "$work/home"
  printf '{"key":{"d":"THE-ROOT-PRIVATE-KEY"},"pair":{"id":"%s","public_key":{"kty":"KEY_TYPE_EC","crv":"P-256","kid":"%s","x":"%s","y":"PUBLIC-Y"}},"pair_id":"%s","tenant":"/"}\n' \
    "$1" "$1" "${2:-PUBLIC-X}" "$1" > "$work/home/root.cred.json"
}
# run [VAR=VALUE...]: the script, its output in $work/out, its status returned.
run() {
  : > "$work/calls"
  env PATH="$work/bin:$PATH" SEATRIALS_HOME="$work/home" STUB_KERNEL="$work/kernel" STUB_CALLS="$work/calls" "$@" \
    "$src/deploy/client-steps.sh" > "$work/out" 2>&1
}
pairs() { ls "$work/kernel/$1" 2>/dev/null | sort | tr '\n' ' '; } # TENANT: its pairs' ids

rm -rf "$work/kernel"; mkdir -p "$work/kernel"
root_cred root-1
if run; then
  ok "first run passes"
  [ -d "$work/kernel/alpha" ] && [ -d "$work/kernel/beta" ] && ok "first run: tenants alpha and beta created" ||
    fail "first run: tenants: $(ls "$work/kernel")"
  [[ "$(pairs alpha)" == ci-alpha-*" " ]] && [[ "$(pairs beta)" == ci-beta-*" " ]] &&
    ok "first run: one pair of the pipeline's in each tenant" || fail "first run: pairs alpha [$(pairs alpha)] beta [$(pairs beta)]"
  grep -q '^client-steps: /tenants/alpha: ping served by tenantecho/tenants/alpha' "$work/out" &&
    grep -q '^client-steps: /tenants/beta: ping served by tenantecho/tenants/beta' "$work/out" &&
    ok "first run: each tenant's ping is served by that tenant" || fail "first run: $(cat "$work/out")"
  [ "$(head -1 "$work/calls")" = "seatrials login --as root" ] && ok "first run: signs in as root first" ||
    fail "first run: first call $(head -1 "$work/calls")"
else
  fail "first run: $(cat "$work/out")"
fi
! grep -q 'PRIVATE-KEY\|TOKEN-OF' "$work/out" && ok "no private key or token in the output" || fail "a key or token in the output: $(cat "$work/out")"

: > "$work/kernel/alpha/alpha-person"
if run; then
  grep -q '/tenants/alpha: exists' "$work/out" && grep -q '/tenants/beta: exists' "$work/out" &&
    ok "second run: the tenants exist, nothing created twice" || fail "second run: $(cat "$work/out")"
  [ "$(ls "$work/kernel/alpha" | grep -c '^ci-alpha-')/$(ls "$work/kernel/beta" | grep -c '^ci-beta-')" = 1/1 ] &&
    [ -f "$work/kernel/alpha/alpha-person" ] &&
    ok "second run: still one pipeline pair per tenant, a person's pair kept" || fail "second run: pairs alpha [$(pairs alpha)] beta [$(pairs beta)]"
else
  fail "second run: $(cat "$work/out")"
fi

root_cred root-2
if run; then fail "an unregistered root credential: passed: $(cat "$work/out")"; else
  grep -q "the root credential root-2 is not in deploy/bootstrap/operator.yaml's root_cred_pairs" "$work/out" && [ ! -s "$work/calls" ] &&
    ok "an unregistered root credential: refused, saying so, before the client runs" || fail "unregistered: $(cat "$work/out")"
fi
root_cred root-1 OTHER-X
if run; then fail "a root credential whose key is not the registered one: passed: $(cat "$work/out")"; else
  grep -q "root-1's public key is not the one deploy/bootstrap/operator.yaml registers" "$work/out" && [ ! -s "$work/calls" ] &&
    ok "a root credential whose key is not the registered one: refused before the client runs" || fail "other key: $(cat "$work/out")"
fi
rm -rf "$work/home"; mkdir -p "$work/home"
if run; then fail "no root credential: passed"; else
  grep -q 'no root credential in .*root.cred.json: ci_crypto root places it' "$work/out" && [ ! -s "$work/calls" ] &&
    ok "no root credential: refused, naming ci_crypto root" || fail "no root credential: $(cat "$work/out")"
fi

root_cred root-1
if run STUB_FAIL="tenant cred"; then fail "a refused step: passed"; else
  grep -q '^client-steps: seatrials tenant cred --replace /tenants/alpha ci-alpha failed: rpc error: code = PermissionDenied' "$work/out" &&
    ! grep -q 'beta' "$work/out" &&
    ok "a refused step fails the job, naming the step and the client's error" || fail "refused step: $(cat "$work/out")"
fi
if run STUB_CROSS=1; then fail "beta's ping served by alpha: passed"; else
  grep -q "/tenants/beta: ping served by tenantecho/tenants/alpha, not beta's" "$work/out" &&
    ok "a ping another tenant serves fails, saying so" || fail "cross: $(cat "$work/out")"
fi

[ "$failed" = 0 ] && echo "all passed" || { echo "client-steps tests failed"; exit 1; }
