#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The realms on a throwaway local Keycloak, the image test-idp/keycloak.yaml
# pins, with fresh seeds, imported on start as in the cluster: test-idp/signin.sh's
# checks 1, 2 and 4 (the sign-in at tacplus.dev needs the live fleet). Then a
# second Keycloak, as a new pod would be, imports them again: every sub must be
# the same, and the removed user back. haproxy is not run here: Keycloak is
# reached directly. As in the pod (#54), every container's root is read-only,
# its writable paths fresh for each pod: keycloak.yaml's init containers fill
# lib/quarkus, a directory here as the emptyDir is, then Keycloak starts on it
# read-only, with tmpfs for /tmp and its data. Needs docker, python3, yq, jq and
# curl. No secret leaves this script's temporary directory.
#
#   test-idp/local.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# pod EXPR: EXPR on keycloak.yaml's pod; c NAME: its container or init container NAME.
pod() { yq "select(.kind == \"Deployment\") | .spec.template.spec | $1" "$here/keycloak.yaml"; }
c() { echo "(.containers + .initContainers)[] | select(.name == \"$1\")"; }
image=$(pod "$(c keycloak) | .image")
# Each container's command line, its items one per line (none has a newline).
mapfile -t copy < <(pod "$(c quarkus-copy) | .command[]")
mapfile -t build < <(pod "$(c build) | .args[]")
mapfile -t args < <(pod "$(c keycloak) | .args[]")
name=test-idp-local-$$
tmp=$(mktemp -d)
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
umask 077

python3 "$here/testidp.py" new-seed "$tmp/seed"
python3 "$here/testidp.py" new-seed "$tmp/client-seed"
TEST_IDP_SEED=$(cat "$tmp/seed") TEST_IDP_CLIENT_SEED=$(cat "$tmp/client-seed")
export TEST_IDP_SEED TEST_IDP_CLIENT_SEED
python3 "$here/testidp.py" secret admin "$tmp/admin"
# Keycloak's own environment file: the admin password is on no command line.
{ echo KC_BOOTSTRAP_ADMIN_USERNAME=admin; echo "KC_BOOTSTRAP_ADMIN_PASSWORD=$(cat "$tmp/admin")"
  pod "$(c keycloak) | .env[] | select(has(\"value\")) | select(.name != \"KC_HOSTNAME\") | .name + \"=\" + .value"; } > "$tmp/env"
pod "$(c build) | .env[] | .name + \"=\" + .value" > "$tmp/build-env"

mkdir "$tmp/realms" "$tmp/import"
for f in "$here"/realms/*.yaml; do
  r=$(basename "$f" .yaml)
  yq -o=json '.' "$f" > "$tmp/realms/$r.json"
  python3 "$here/testidp.py" render "$tmp/realms/$r.json" "$tmp/import/$r.json"
done
# Readable by Keycloak's user in the container, as the Secret's files are in the
# pod; the directory around them stays private.
chmod 755 "$tmp/import"; chmod 644 "$tmp"/import/*.json

# As the pod runs each container: Keycloak's user, a read-only root.
run=(--user 1000:0 --read-only --cap-drop ALL --security-opt no-new-privileges)
# start: a new Keycloak, as a new pod starts, the realms imported as it starts;
# its URL in $url.
start() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$tmp/quarkus"; mkdir -m 777 "$tmp/quarkus"
  docker run --rm "${run[@]}" -v "$tmp/quarkus:/quarkus" --entrypoint "${copy[0]}" "$image" "${copy[@]:1}" ||
    { echo "FAIL quarkus-copy: ${copy[*]}"; exit 1; }
  docker run --rm "${run[@]}" --env-file "$tmp/build-env" --tmpfs /tmp:exec,mode=1777 \
    -v "$tmp/quarkus:/opt/keycloak/lib/quarkus" "$image" "${build[@]}" > "$tmp/build.log" 2>&1 ||
    { echo "FAIL build: ${build[*]}"; tail -30 "$tmp/build.log"; exit 1; }
  docker run -d --name "$name" "${run[@]}" --env-file "$tmp/env" \
    --tmpfs /tmp:exec,mode=1777 --tmpfs /opt/keycloak/data:exec,mode=1777 \
    -v "$tmp/import:/opt/keycloak/data/import:ro" -v "$tmp/quarkus:/opt/keycloak/lib/quarkus:ro" \
    "$image" "${args[@]}" --hostname-strict=false >/dev/null
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
