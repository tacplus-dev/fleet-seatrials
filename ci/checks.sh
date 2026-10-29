#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The repository's script tests, every *_test.sh: the deploy pipeline's checks
# stage and the local gate. Need bash, jq, yq and opa (ci/tools.sh builds the
# last two into bin/).
#
#   ci/checks.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
for t in "$here"/deploy/*_test.sh "$here"/images/*_test.sh; do
  echo "== ${t#"$here"/}"
  "$t" || failed=1
done
[ "$failed" = 0 ] && echo "all script tests passed" || { echo "script tests failed"; exit 1; }
