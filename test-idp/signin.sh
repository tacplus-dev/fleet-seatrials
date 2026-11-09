#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The test IdP's sign-in checks (#27), the deploy pipeline's test-idp-signin
# job, after test-idp/apply.sh; no person is needed. Each prints ok or FAIL, and
# the script fails if any failed. No password or token is printed
# (test-idp/testidp.py).
#
#   test-idp/signin.sh
#
#   1. discovery: https://idp.test.tacplus.dev:8443/realms/<realm>/.well-known/openid-configuration
#      answers, naming its realm as issuer, for each realm;
#   2. claims: every user of every realm signs in (authorization code + PKCE,
#      the realm's claims-check client) and the ID token has the shape of the
#      realm's provider (test-idp/README.md);
#   3. tacplus: one user per realm signs in at https://$TACPLUS_HOST (default
#      seatrials.tacplus.dev) through oauth, gets a kernel session, and the
#      session names the realm as issuer and the user's sub;
#   4. removed: gone@personal.test signs in at tacplus.dev, is removed at the
#      IdP, and is then refused; then it is put back.
#
# Needs the seeds (TEST_IDP_SEED, TEST_IDP_CLIENT_SEED) and, for 4, kubectl on
# the dev cluster as test-idp-deploy: the admin API is not on the internet, so
# the admin Job (test-idp/admin-job.yaml) removes the user and puts back what is
# missing, in the cluster. test-idp/local.sh runs it on a local Keycloak:
# TEST_IDP_URL is then its URL, ADMIN_URL its admin API (no Job; a restart puts
# the user back), and TACPLUS_HOST=- skips 3.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
idp=${TEST_IDP_URL:-https://idp.test.tacplus.dev:8443}
tacplus=${TACPLUS_HOST:-seatrials.tacplus.dev}
admin_url=${ADMIN_URL:-}
ns=tac-test-idp
# One user per emulated provider for the full sign-in at tacplus.dev.
signin_users=(google:ada@alpha.test microsoft:bo@beta.test apple:cy@personal.test)
removed=google:gone@personal.test
[ $# -eq 0 ] || { echo "usage: $0 (no arguments; see the header)" >&2; exit 2; }
: "${TEST_IDP_SEED:?TEST_IDP_SEED is not set (the secret test-idp-seeds, ci_test_idp_seeds)}"
: "${TEST_IDP_CLIENT_SEED:?TEST_IDP_CLIENT_SEED is not set (the secret test-idp-seeds, ci_test_idp_seeds)}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
t() { python3 "$here/testidp.py" "$@" || failed=1; }

# admin ACTION REALM [USERNAME]: the admin Job's ACTION (remove, restore), its log
# printed; it fails when the Job does.
admin() {
  if [ -n "$admin_url" ]; then
    case $1 in
      remove) python3 "$here/testidp.py" remove "$admin_url" "$tmp/realms/$2.json" "$3" ;;
      restore) echo "$2: local, nothing to put back (a restart does)" ;;
    esac
    return
  fi
  local job=test-idp-admin state=""
  kubectl -n "$ns" delete job "$job" --ignore-not-found --wait=true >/dev/null || return 1
  ACTION=$1 REALM=$2 USERNAME=${3:-} yq '(.spec.template.spec.containers[0].env[] | select(.name == "ACTION")).value = strenv(ACTION)
      | (.spec.template.spec.containers[0].env[] | select(.name == "REALM")).value = strenv(REALM)
      | (.spec.template.spec.containers[0].env[] | select(.name == "USERNAME")).value = strenv(USERNAME)' \
    "$here/admin-job.yaml" | kubectl apply -f - >/dev/null || return 1
  for _ in $(seq 100); do
    state=$(kubectl -n "$ns" get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}') || return 1
    case $state in 1/*|*/1) break ;; esac
    sleep 3
  done
  kubectl -n "$ns" logs "job/$job" --tail=20 || true
  [[ $state == 1/* ]] || { echo "the admin Job ($1 $2 ${3:-}) did not succeed: [$state]"; return 1; }
}

mkdir "$tmp/realms"
for f in "$here"/realms/*.yaml; do yq -o=json '.' "$f" > "$tmp/realms/$(basename "$f" .yaml).json"; done
realms=$(cd "$tmp/realms" && ls ./*.json | sed 's|^\./||; s|\.json$||')

# Every user of the files there (the one an earlier run removed, put back).
for realm in $realms; do
  admin restore "$realm" || { echo "FAIL restore $realm: the realm's users are not all there"; exit 1; }
done

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
admin remove "$realm" "$user" || failed=1
t refused "$idp/realms/$realm" "$tmp/realms/$realm.json" "$user"
admin restore "$realm" || failed=1

[ "$failed" = 0 ] && echo "all sign-in checks passed" || { echo "sign-in checks failed"; exit 1; }
