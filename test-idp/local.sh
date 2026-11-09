#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The realms on a throwaway local Keycloak, the image test-idp/keycloak.yaml
# pins, with fresh seeds, imported on start as in the cluster: test-idp/signin.sh's
# checks 1, 2 and 4 (the sign-in at tacplus.dev needs the live fleet). Then a
# second Keycloak, as a new pod would be, imports them again: every sub must be
# the same, and the removed user back. haproxy is not run here: Keycloak is
# reached directly. Needs docker, python3, yq, jq and curl. No secret leaves this
# script's temporary directory.
#
#   test-idp/local.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "keycloak") | .image' "$here/keycloak.yaml")
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
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "keycloak") | .env[]
    | select(has("value")) | select(.name != "KC_HOSTNAME") | .name + "=" + .value' "$here/keycloak.yaml"; } > "$tmp/env"

mkdir "$tmp/realms" "$tmp/import"
for f in "$here"/realms/*.yaml; do
  r=$(basename "$f" .yaml)
  yq -o=json '.' "$f" > "$tmp/realms/$r.json"
  python3 "$here/testidp.py" render "$tmp/realms/$r.json" > "$tmp/import/$r.json"
done
# Readable by Keycloak's user in the container (docker cp makes them root's), as
# the Secret's files are in the pod; the directory around them stays private.
chmod 644 "$tmp"/import/*.json

# start: a new Keycloak, the realms imported as it starts; its URL in $url.
start() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker create --name "$name" --env-file "$tmp/env" "$image" start --import-realm --hostname-strict=false >/dev/null
  docker cp "$tmp/import" "$name:/opt/keycloak/data/import"
  docker start "$name" >/dev/null
  ip=$(docker inspect "$name" | jq -r '.[0].NetworkSettings.Networks[].IPAddress' | head -1)
  url=http://$ip:8080
  echo "keycloak $image at $url"
  for _ in $(seq 60); do curl -fsS -o /dev/null "$url/realms/google" 2>/dev/null && return; sleep 3; done
  echo "FAIL keycloak did not answer"; docker logs --tail 30 "$name"; exit 1
}
subs() { # the sub of every user, as the claim check prints it
  for r in "$tmp"/realms/*.json; do
    jq -r '.users[].username' "$r" | while read -r u; do
      python3 "$here/testidp.py" claims "$url/realms/$(basename "$r" .json)" "$r" "$u" | grep -o '"sub": "[^"]*"'
    done
  done
}

start
subs > "$tmp/subs-before"
TEST_IDP_URL=$url ADMIN_URL=$url TACPLUS_HOST=- "$here/signin.sh"
# A new pod: the realms imported again, the removed user back, every sub the same.
start
subs > "$tmp/subs-after"
diff "$tmp/subs-before" "$tmp/subs-after" >/dev/null ||
  { echo "FAIL a sub changed when Keycloak imported the realms again"; diff "$tmp/subs-before" "$tmp/subs-after"; exit 1; }
echo "ok   every sub the same after a new import ($(wc -l < "$tmp/subs-after") users, the removed one back)"
echo "local test IdP checks passed"
