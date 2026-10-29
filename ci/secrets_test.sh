#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/secrets.sh on throwaway repositories carrying this one's gitleaks
# configuration: a key committed is found, and so is a key still in the tree
# at HEAD whose commit .gitleaksignore lists, while the test fixtures the
# configuration allows are not. Needs git and gitleaks.
#
#   ci/secrets_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }

# A private key made up here, never committed to this repository.
key() {
  echo "-----BEGIN EC PRIVATE KEY-----"
  head -c 120 /dev/urandom | base64 -w 64
  echo "-----END EC PRIVATE KEY-----"
}
# repo NAME: a repository with this one's configuration and a first commit.
repo() {
  local r=$work/$1
  git init -q "$r"
  git -C "$r" config user.email test@example.invalid
  git -C "$r" config user.name test
  cp "$here/.gitleaks.toml" "$r/"
  echo "# seatrials" > "$r/README.md"
  git -C "$r" add -A && git -C "$r" commit -qm init
  echo "$r"
}
# scan NAME WANT REPO: ci/secrets.sh on REPO exits 0 (WANT pass) or not (fail).
scan() {
  local out status
  out=$("$here/ci/secrets.sh" "$3" 2>&1); status=$?
  case "$2" in
    pass) [ "$status" -eq 0 ] || { fail "$1: status=$status: $out"; return; } ;;
    fail) [ "$status" -ne 0 ] || { fail "$1: status=0: $out"; return; } ;;
  esac
  echo "ok   $1"
}

r=$(repo clean)
scan "a repository with no key passes" pass "$r"

r=$(repo committed)
mkdir -p "$r/deploy/bootstrap/services"
key > "$r/deploy/bootstrap/services/kernel.yaml"
git -C "$r" add -A && git -C "$r" commit -qm key
scan "a committed key fails" fail "$r"

r=$(repo ignored)
key > "$r/tls.key"
git -C "$r" add -A && git -C "$r" commit -qm key
for rule in private-key generic-api-key; do
  echo "$(git -C "$r" rev-parse HEAD):tls.key:$rule:1"
done > "$r/.gitleaksignore"
git -C "$r" add -A && git -C "$r" commit -qm ignore
scan "a key its commit's fingerprint ignores, still in the tree, fails" fail "$r"
git -C "$r" rm -q tls.key && git -C "$r" commit -qm "remove the key"
scan "that key, removed from the tree, passes" pass "$r"

r=$(repo fixture)
mkdir -p "$r/deploy"
echo 'run "refused" refuse FLEET_MICROSOFT_CLIENT_SECRET=abcdefghijABCDEFGHIJ0123456789abcdefghijABCDEFGHIJ0123456789x' \
  > "$r/deploy/signin-secrets_test.sh"
git -C "$r" add -A && git -C "$r" commit -qm fixture
scan "the sign-in test's fixtures pass" pass "$r"

r=$(repo uncommitted)
key > "$r/crypto.yaml"
scan "an uncommitted file is not scanned (git-ignored key material)" pass "$r"

[ "$failed" = 0 ] && echo "secrets tests passed" || { echo "secrets tests failed"; exit 1; }
