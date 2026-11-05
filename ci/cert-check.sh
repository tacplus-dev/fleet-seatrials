#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Checks a certificate as the pipeline keeps it (tacplus-dev/roadmap
# decisions/certificates-by-pipeline-2026-11-03.md): PAYLOAD is one secret
# version, the leaf, its chain and the leaf's private key, in PEM. It prints
# one word and exits with its code:
#
#   valid            0   the chain verifies, the key is the leaf's, every HOST is covered
#   due             10   as valid, but now is inside the last third of notBefore..notAfter
#   expired         11   now is past notAfter
#   wrong-hostname  12   a HOST is not covered by the leaf's names (a wildcard covers one label)
#   invalid         13   no certificate, no key or not the leaf's, a chain that does not
#                        verify, or a certificate not valid yet
#
# It works the same for a Let's Encrypt certificate and one somebody else
# signed. On stderr it says the leaf's subject, issuer, serial and dates, and
# why when it is not valid; never the key.
#
#   ci/cert-check.sh PAYLOAD HOST...
#
# CERT_CHECK_CAFILE: the trust anchors (the system's by default; Let's
# Encrypt's staging roots for a staging run). CERT_CHECK_NOW: the time to check
# at, seconds since the epoch (tests).
set -uo pipefail
[ $# -ge 2 ] || { echo "usage: $0 PAYLOAD HOST..." >&2; exit 2; }
payload=$1; shift
now=${CERT_CHECK_NOW:-$(date +%s)}
say() { echo "cert-check: $*" >&2; }
verdict() { # WORD CODE [WHY]
  [ -z "${3:-}" ] || say "$3"
  echo "$1"; exit "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
[ -r "$payload" ] || verdict invalid 13 "no payload at $payload"
# The certificates, in order (cert0.pem is the leaf), and the key, each in its own file.
awk -v dir="$work" '
  /^-----BEGIN CERTIFICATE-----/ { out = sprintf("%s/cert%d.pem", dir, n++) }
  /^-----BEGIN ([A-Z]+ )?PRIVATE KEY-----/ { out = dir "/key.pem"; keys++ }
  out { print > out }
  /^-----END / { close(out); out = "" }
  END { exit keys > 1 }' "$payload" || verdict invalid 13 "more than one private key"
leaf=$work/cert0.pem
[ -f "$leaf" ] && openssl x509 -in "$leaf" -noout 2>/dev/null || verdict invalid 13 "no certificate"
openssl x509 -in "$leaf" -noout -subject -issuer -serial -startdate -enddate -nameopt RFC2253 2>/dev/null | sed 's/^/cert-check: /' >&2

[ -f "$work/key.pem" ] || verdict invalid 13 "no private key"
leaf_pub=$(openssl x509 -in "$leaf" -noout -pubkey 2>/dev/null)
key_pub=$(openssl pkey -in "$work/key.pem" -pubout 2>/dev/null) || verdict invalid 13 "the private key does not parse"
[ "$leaf_pub" = "$key_pub" ] || verdict invalid 13 "the private key is not the leaf's"

# The chain, at no particular time (the dates are judged below).
cat "$work"/cert[1-9]*.pem > "$work/untrusted.pem" 2>/dev/null || : > "$work/untrusted.pem"
verify=(openssl verify -no_check_time -purpose sslserver)
[ -s "$work/untrusted.pem" ] && verify+=(-untrusted "$work/untrusted.pem")
[ -n "${CERT_CHECK_CAFILE:-}" ] && verify+=(-CAfile "$CERT_CHECK_CAFILE")
"${verify[@]}" "$leaf" > "$work/verify" 2>&1 ||
  verdict invalid 13 "the chain does not verify: $(grep -m1 -i 'error' "$work/verify" || head -c 300 "$work/verify")"

epoch() { date -u -d "$(openssl x509 -in "$leaf" -noout "$1" | cut -d= -f2-)" +%s; }
not_before=$(epoch -startdate) not_after=$(epoch -enddate) || verdict invalid 13 "its dates do not parse"
[ "$now" -ge "$not_before" ] || verdict invalid 13 "not valid until $(date -u -d "@$not_before")"
[ "$now" -le "$not_after" ] || verdict expired 11 "expired on $(date -u -d "@$not_after")"

for host in "$@"; do
  openssl x509 -in "$leaf" -noout -checkhost "$host" 2>/dev/null | grep -q 'does match' ||
    verdict wrong-hostname 12 "it does not cover $host"
done

# Due inside the last third of its lifetime: Let's Encrypt's best practice
# when ARI gives no window (lego's own renewal decides with ARI first).
due_at=$((not_before + (not_after - not_before) * 2 / 3))
[ "$now" -lt "$due_at" ] || verdict due 10 "due since $(date -u -d "@$due_at") (the last third of its lifetime)"
verdict valid 0
