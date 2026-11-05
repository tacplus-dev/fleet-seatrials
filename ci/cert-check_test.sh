#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/cert-check.sh on certificates made here with openssl, under a test
# CA (CERT_CHECK_CAFILE) and at a chosen time (CERT_CHECK_NOW): valid, due
# (inside the last third of its lifetime), expired, a hostname it does not
# cover, the wildcard's one label, a key that is not the leaf's, a chain that
# does not verify, no key, and that it never prints the key. Needs bash and
# openssl.
#
#   ci/cert-check_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

cd "$work"
# ca NAME: a CA, NAME.crt and NAME.key.
ca() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$1.key" -out "$1.crt" \
    -days 3650 -subj "/CN=$1" 2>/dev/null
}
# intermediate NAME CA: an intermediate CA signed by CA.
intermediate() {
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$1" 2>/dev/null
  printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$1.ext"
  openssl x509 -req -in "$1.csr" -CA "$2.crt" -CAkey "$2.key" -CAcreateserial -days 3650 -extfile "$1.ext" -out "$1.crt" 2>/dev/null
}
# leaf NAME CA DAYS SAN...: a 90-day-style leaf (DAYS long) for the SANs, signed by CA; NAME.pem is
# the leaf, CA's certificate (the chain) and the leaf's key: the secret's one payload.
leaf() {
  local name=$1 issuer=$2 days=$3 san; shift 3
  san=$(printf 'DNS:%s,' "$@"); san=${san%,}
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$name.key" -out "$name.csr" -subj "/CN=$1" 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san" > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA "$issuer.crt" -CAkey "$issuer.key" -CAcreateserial -days "$days" \
    -extfile "$name.ext" -out "$name.crt" 2>/dev/null
  cat "$name.crt" "$issuer.crt" "$name.key" > "$name.pem"
}
ca root
intermediate inter root
ca other
leaf good inter 90 tacplus.dev '*.tacplus.dev'
leaf single inter 90 seatrials.tacplus.dev
leaf foreign other 90 tacplus.dev '*.tacplus.dev'
cat good.crt inter.crt single.key > wrongkey.pem
cat good.crt inter.crt > nokey.pem
printf 'not a certificate\n' > garbage.pem

now=$(date +%s) day=86400
# expect NAME WORD EXIT [NOW] -- FILE HOST...: cert-check.sh prints WORD and exits EXIT.
expect() {
  local name=$1 want=$2 code=$3 at=$4 got rc=0; shift 5
  got=$(CERT_CHECK_CAFILE=$work/root.crt CERT_CHECK_NOW=$at "$here/cert-check.sh" "$@" 2>"$work/err") || rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = "$code" ]; then ok "$name"; else
    fail "$name: got '$got' (exit $rc), want '$want' (exit $code); stderr: $(head -c 400 "$work/err")"; fi
}
expect "a fresh certificate for apex and wildcard is valid" valid 0 "$now" -- good.pem tacplus.dev '*.tacplus.dev' seatrials.tacplus.dev
expect "at half its lifetime it is still valid" valid 0 $((now + 45 * day)) -- good.pem tacplus.dev
expect "inside the last third of its lifetime it is due" due 10 $((now + 61 * day)) -- good.pem tacplus.dev
expect "a day before it ends it is due" due 10 $((now + 89 * day)) -- good.pem tacplus.dev
expect "past notAfter it is expired" expired 11 $((now + 91 * day)) -- good.pem tacplus.dev
expect "before notBefore it is not valid yet, so invalid" invalid 13 $((now - 2 * day)) -- good.pem tacplus.dev
expect "a host the certificate does not name is wrong-hostname" wrong-hostname 12 "$now" -- single.pem tacplus.dev
expect "the wildcard covers one label" valid 0 "$now" -- good.pem seatrials.tacplus.dev
expect "the wildcard does not cover two labels" wrong-hostname 12 "$now" -- good.pem a.seatrials.tacplus.dev
expect "the wildcard does not cover another domain" wrong-hostname 12 "$now" -- good.pem tacplus.dev.example.com
expect "an expired certificate is expired before its hostnames count" expired 11 $((now + 91 * day)) -- single.pem tacplus.dev
expect "a key that is not the leaf's is invalid" invalid 13 "$now" -- wrongkey.pem tacplus.dev
expect "a payload with no key is invalid" invalid 13 "$now" -- nokey.pem tacplus.dev
expect "a chain to a CA it does not trust is invalid" invalid 13 "$now" -- foreign.pem tacplus.dev
expect "a payload with no certificate is invalid" invalid 13 "$now" -- garbage.pem tacplus.dev
expect "a payload missing is invalid" invalid 13 "$now" -- missing.pem tacplus.dev

# Never the key: neither on stdout nor stderr, and what it says on stderr names the certificate.
out=$(CERT_CHECK_CAFILE=$work/root.crt "$here/cert-check.sh" good.pem tacplus.dev 2>&1)
key_line=$(sed -n '2p' good.key)
if grep -qF -- "$key_line" <<<"$out" || grep -q 'PRIVATE KEY' <<<"$out"; then fail "it prints the key"; else ok "it never prints the key"; fi
for want in "subject=" "issuer=" "serial=" "notBefore=" "notAfter="; do
  grep -q "$want" <<<"$out" && ok "it says the certificate's $want" || fail "it does not say $want: $out"
done
CERT_CHECK_CAFILE=$work/root.crt "$here/cert-check.sh" good.pem >/dev/null 2>&1
[ $? = 2 ] && ok "no hostname is a usage error" || fail "no hostname is not a usage error"

[ "$failed" = 0 ] && echo "all passed" || { echo "cert-check tests failed"; exit 1; }
