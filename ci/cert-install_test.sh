#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/cert-install.sh: the certificate version (leaf, chain, key) becomes
# crypto.yaml's pki.edge_tls[0], the gateway's external certificate, as the
# operator keeps one (base64 of each PEM); nothing else in crypto.yaml changes,
# the file stays private, and nothing is printed. Needs bash, yq and openssl.
#
#   ci/cert-install_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
cd "$work"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.crt -days 30 -subj /CN=ca 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout leaf.key -out leaf.csr -subj /CN=tacplus.dev 2>/dev/null
openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -out leaf.crt 2>/dev/null
cat leaf.crt ca.crt leaf.key > payload.pem
b64() { base64 -w0 < "$1"; }
cat > crypto.yaml <<EOF
pki:
    root_ca:
        chain:
            - base64: cm9vdA==
              id: root
    edge_tls:
        - chain:
            - base64: b2xkLWxlYWY=
              id: old
          key:
            base64: b2xkLWtleQ==
            created: 1793919665
            id: old
        - chain:
            - base64: c2Vjb25k
              id: second
llm_credential: x
EOF
cp crypto.yaml before.yaml
chmod 600 crypto.yaml

out=$("$here/cert-install.sh" payload.pem crypto.yaml 2>&1); rc=$?
[ "$rc" = 0 ] && ok "it installs" || fail "it fails: $out"
[ -z "$out" ] || grep -qv 'PRIVATE KEY' <<<"$out" && ! grep -qF "$(sed -n 2p leaf.key)" <<<"$out" &&
  ok "it prints nothing secret" || fail "it prints the key: $out"
[ "$(yq '.pki.edge_tls[0].chain | length' crypto.yaml)" = 2 ] && ok "the chain has the leaf and its issuer" || fail "chain: $(yq '.pki.edge_tls[0].chain' crypto.yaml)"
[ "$(yq '.pki.edge_tls[0].chain[0].base64' crypto.yaml)" = "$(b64 leaf.crt)" ] && ok "the leaf first, base64 of its PEM" || fail "the leaf"
[ "$(yq '.pki.edge_tls[0].chain[1].base64' crypto.yaml)" = "$(b64 ca.crt)" ] && ok "then its issuer" || fail "the issuer"
[ "$(yq '.pki.edge_tls[0].key.base64' crypto.yaml)" = "$(b64 leaf.key)" ] && ok "the key, base64 of its PEM" || fail "the key"
[ "$(yq '.pki.edge_tls[0].key.created' crypto.yaml)" = "$(date -u -d "$(openssl x509 -in leaf.crt -noout -startdate | cut -d= -f2)" +%s)" ] &&
  ok "the key's created is the leaf's notBefore" || fail "created: $(yq '.pki.edge_tls[0].key.created' crypto.yaml)"
serial=$(openssl x509 -in leaf.crt -noout -serial | cut -d= -f2)
[ "$(yq '.pki.edge_tls[0].chain[0].id' crypto.yaml)" = "$serial" ] && [ "$(yq '.pki.edge_tls[0].key.id' crypto.yaml)" = "$serial" ] &&
  ok "the leaf and key are named by the serial" || fail "ids"
[ "$(yq 'del(.pki.edge_tls[0])' crypto.yaml)" = "$(yq 'del(.pki.edge_tls[0])' before.yaml)" ] &&
  ok "nothing else in crypto.yaml changes" || fail "other fields changed"
[ "$(stat -c %a crypto.yaml)" = 600 ] && ok "crypto.yaml stays private (0600)" || fail "mode $(stat -c %a crypto.yaml)"

printf 'pki:\n    root_ca: {}\n' > bare.yaml
"$here/cert-install.sh" payload.pem bare.yaml >/dev/null 2>&1 && [ "$(yq '.pki.edge_tls | length' bare.yaml)" = 1 ] &&
  ok "with no edge_tls yet, it adds the one" || fail "no edge_tls"
cat leaf.crt ca.crt > nokey.pem
"$here/cert-install.sh" nokey.pem bare.yaml >/dev/null 2>&1 && fail "a payload with no key installs" || ok "a payload with no key is refused"
"$here/cert-install.sh" payload.pem missing.yaml >/dev/null 2>&1 && fail "no crypto.yaml installs" || ok "no crypto.yaml is refused"

[ "$failed" = 0 ] && echo "all passed" || { echo "cert-install tests failed"; exit 1; }
