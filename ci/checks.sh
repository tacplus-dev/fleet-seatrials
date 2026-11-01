#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The repository's script tests, every *_test.sh, and the secrets scan
# (ci/secrets.sh): the deploy pipeline's checks stage and the local gate. Need
# bash, git, jq, yq, opa, gitleaks (ci/tools.sh builds these three into bin/),
# python3 and openssl.
#
#   ci/checks.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
for t in "$here"/ci/*_test.sh "$here"/deploy/*_test.sh "$here"/images/*_test.sh "$here"/test-idp/*_test.sh; do
  echo "== ${t#"$here"/}"
  "$t" || failed=1
done
echo "== ci/secrets.sh"
"$here/ci/secrets.sh" || failed=1
[ "$failed" = 0 ] && echo "all checks passed" || { echo "checks failed"; exit 1; }
