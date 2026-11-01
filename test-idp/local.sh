#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The realms on a throwaway local Keycloak, the image test-idp/keycloak.yaml
# pins, with fresh seeds: test-idp/signin.sh's checks 1, 2 and 4 (the
# discovery, every user's claim shape, the removed user), a second sync that
# must change nothing, and a third after a realm setting changed, which must
# recreate the realm and keep each sub. For a change to the realms before it
# lands; the deploy pipeline does not run it (it needs docker). Needs docker,
# python3, curl, jq and yq; the container goes when it ends.
#
#   test-idp/local.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=$(yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].image' "$here/keycloak.yaml")
name=test-idp-local-$$
tmp=$(mktemp -d)
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
umask 077

TEST_IDP_SEED=$(python3 "$here/testidp.py" new-seed)
TEST_IDP_CLIENT_SEED=$(python3 "$here/testidp.py" new-seed)
export TEST_IDP_SEED TEST_IDP_CLIENT_SEED
python3 "$here/testidp.py" secret admin > "$tmp/admin"
# Keycloak's own environment file: the admin password is on no command line.
{ echo KC_BOOTSTRAP_ADMIN_USERNAME=admin; echo "KC_BOOTSTRAP_ADMIN_PASSWORD=$(cat "$tmp/admin")"
  yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].env[] | select(has("value"))
    | select(.name != "KC_HOSTNAME") | .name + "=" + .value' "$here/keycloak.yaml"; } > "$tmp/env"
docker run -d --name "$name" --env-file "$tmp/env" "$image" start --hostname-strict=false >/dev/null
ip=$(docker inspect "$name" | jq -r '.[0].NetworkSettings.Networks[].IPAddress' | head -1)
url=http://$ip:8080
echo "keycloak $image at $url"
for _ in $(seq 60); do curl -fsS -o /dev/null "$url/realms/master" 2>/dev/null && break; sleep 3; done

mkdir "$tmp/realms"
for f in "$here"/realms/*.yaml; do yq -o=json '.' "$f" > "$tmp/realms/$(basename "$f" .yaml).json"; done
subs() { # the sub of every user, as the claim check prints it
  for r in "$tmp"/realms/*.json; do
    jq -r '.users[].username' "$r" | while read -r u; do
      python3 "$here/testidp.py" claims "$url/realms/$(basename "$r" .json)" "$r" "$u" | grep -o '"sub": "[^"]*"'
    done
  done
}

TEST_IDP_URL=$url ADMIN_URL=$url TACPLUS_HOST=- "$here/signin.sh"
# The second sync puts the removed user back, and changes nothing else.
out=$(python3 "$here/testidp.py" sync "$url" "$tmp"/realms/*.json)
echo "$out"
if grep -q recreated <<<"$out"; then echo "FAIL a second sync recreated a realm"; exit 1; fi
subs > "$tmp/subs-before"
jq '.accessTokenLifespan += 1' "$tmp/realms/microsoft.json" > "$tmp/changed.json"
python3 "$here/testidp.py" sync "$url" "$tmp/changed.json" | grep -q recreated ||
  { echo "FAIL a changed realm setting did not recreate the realm"; exit 1; }
python3 "$here/testidp.py" sync "$url" "$tmp"/realms/*.json >/dev/null
subs > "$tmp/subs-after"
diff "$tmp/subs-before" "$tmp/subs-after" >/dev/null ||
  { echo "FAIL a sub changed when its realm was recreated"; diff "$tmp/subs-before" "$tmp/subs-after"; exit 1; }
echo "ok   every sub the same after a sync and a realm recreated ($(wc -l < "$tmp/subs-after") users)"
echo "local test IdP checks passed"
