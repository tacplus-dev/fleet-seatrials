#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests of the test IdP's tooling that need no Keycloak (test-idp/testidp_test.py),
# with the realms converted from YAML as test-idp/apply.sh converts them. Needs
# python3, yq and openssl. test-idp/local.sh runs the realms on a real Keycloak.
#
#   test-idp/testidp_test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for f in "$here"/realms/*.yaml; do
  yq -o=json '.' "$f" > "$work/$(basename "$f" .yaml).json"
done
TEST_IDP_REALMS_JSON=$work python3 -B "$here/testidp_test.py" 2>&1
