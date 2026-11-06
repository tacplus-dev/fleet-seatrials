#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The test IdP's sign-in checks (#27), the deploy pipeline's test-idp-signin
# job; no person is needed. Each prints ok or FAIL, and the script fails if any
# failed. No password or token is printed (test-idp/testidp.py).
#
#   test-idp/signin.sh
#
#   1. discovery: https://idp.test.tacplus.dev/realms/<realm>/.well-known/openid-configuration
#      answers, naming its realm as issuer, for each realm;
#   2. claims: every user of every realm signs in (authorization code + PKCE,
#      the realm's claims-check client) and the ID token has the shape of the
#      realm's provider (test-idp/README.md);
#   3. tacplus: one user per realm signs in at https://$TACPLUS_HOST (default
#      seatrials.tacplus.dev) through oauth, gets a kernel session, and the
#      session names the realm as issuer and the user's sub;
#   4. removed: gone@personal.test signs in at tacplus.dev, is removed at the
#      IdP, and is then refused; the next test-idp apply puts the user back.
#
# Needs the seeds (TEST_IDP_SEED, TEST_IDP_CLIENT_SEED) and, for 4 and to put
# the realms in step first, kubectl on the dev cluster as test-idp-deploy.
# test-idp/local.sh runs it on a local Keycloak: TEST_IDP_URL is then its URL,
# ADMIN_URL its admin API (no port-forward), and TACPLUS_HOST=- skips 3.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
idp=${TEST_IDP_URL:-https://idp.test.tacplus.dev}
tacplus=${TACPLUS_HOST:-seatrials.tacplus.dev}
port=${ADMIN_PORT:-18080}
# One user per emulated provider for the full sign-in at tacplus.dev.
signin_users=(google:ada@alpha.test microsoft:bo@beta.test apple:cy@personal.test)
removed=google:gone@personal.test
[ $# -eq 0 ] || { echo "usage: $0 (no arguments; see the header)" >&2; exit 2; }
: "${TEST_IDP_SEED:?TEST_IDP_SEED is not set (environment test-idp)}"
: "${TEST_IDP_CLIENT_SEED:?TEST_IDP_CLIENT_SEED is not set (environment test-idp)}"

tmp=$(mktemp -d)
pf=""
cleanup() { [ -z "$pf" ] || kill "$pf" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
failed=0
t() { python3 "$here/testidp.py" "$@" || failed=1; }

mkdir "$tmp/realms"
for f in "$here"/realms/*.yaml; do yq -o=json '.' "$f" > "$tmp/realms/$(basename "$f" .yaml).json"; done
realms=$(cd "$tmp/realms" && ls ./*.json | sed 's|^\./||; s|\.json$||')

# The realms in step with the files (the removed user back), on a port-forward.
admin=${ADMIN_URL:-}
if [ -z "$admin" ]; then
  kubectl -n test-idp port-forward pod/keycloak-0 "$port:8080" > "$tmp/port-forward.log" 2>&1 &
  pf=$!
  for _ in $(seq 30); do curl -fsS -o /dev/null "http://127.0.0.1:$port/realms/master" 2>/dev/null && break; sleep 2; done
  admin=http://127.0.0.1:$port
fi
python3 "$here/testidp.py" sync "$admin" "$tmp"/realms/*.json || { echo "FAIL sync: the realms are not in step"; exit 1; }

for realm in $realms; do
  issuer=$(curl -fsS -m 15 "$idp/realms/$realm/.well-known/openid-configuration" | jq -r '.issuer // empty') || true
  if [ "$issuer" = "$idp/realms/$realm" ]; then echo "ok   discovery $realm: $issuer"
  else echo "FAIL discovery $realm: [$issuer], want $idp/realms/$realm"; failed=1; fi
done

for realm in $realms; do
  while read -r user; do
    t claims "$idp/realms/$realm" "$tmp/realms/$realm.json" "$user"
  done < <(jq -r '.users[].username' "$tmp/realms/$realm.json")
done

for case in "${signin_users[@]}" "$removed"; do
  realm=${case%%:*} user=${case#*:}
  if [ "$tacplus" = - ]; then echo "skip tacplus $realm/$user (TACPLUS_HOST=-)"; continue; fi
  t tacplus "$tacplus" "$idp/realms/$realm" "$tmp/realms/$realm.json" "$user"
done

realm=${removed%%:*} user=${removed#*:}
t remove "$admin" "$tmp/realms/$realm.json" "$user"
t refused "$idp/realms/$realm" "$tmp/realms/$realm.json" "$user"

[ "$failed" = 0 ] && echo "all sign-in checks passed" || { echo "sign-in checks failed"; exit 1; }
