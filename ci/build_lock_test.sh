#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the build pin (#42): build.lock names the image the gates run in by
# digest, in the form tacplus-dev/build's plan reads (looper-build, read_pin),
# and that image is the deploy pipeline's CI image, the one the gates already
# run in, so a move of one is a move of both. gates.yaml's full set is the
# command the build runs there. Needs bash and yq.
#
#   ci/build_lock_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

lock="$here/build.lock"
if [ -f "$lock" ]; then ok "build.lock is at the root"; else fail "build.lock is at the root"; fi
pin=$(sed -n 's/^build_image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$lock" 2>/dev/null | head -1)
if [[ "$pin" =~ ^[a-z0-9][a-z0-9._/-]*(:([A-Za-z0-9_][A-Za-z0-9._-]*))?@sha256:[0-9a-f]{64}$ ]]; then
  ok "build_image names the image by digest ($pin)"
else
  fail "build_image names the image by digest (<name>[:<tag>]@sha256:<64 hex>), not '$pin'"
fi
if grep -q '^#' "$lock" 2>/dev/null; then ok "build.lock says why this image"; else fail "build.lock says why this image"; fi

ci=$(yq '.default.image' "$here/ci/deploy.gitlab-ci.yml")
# The CI image is pinned by patch and digest (#43): the pin is that image, digest and all.
if [ -n "$ci" ] && [ "$pin" = "$ci" ]; then
  ok "the pin is the deploy pipeline's CI image, digest and all ($ci)"
else
  fail "the pin '$pin' is the deploy pipeline's CI image '$ci'"
fi

full=$(yq '.full.run // ""' "$here/gates.yaml" 2>/dev/null)
if [[ "$full" == *ci/tools.sh* && "$full" == *ci/checks.sh* && "$full" == *ci/security.sh* ]]; then
  ok "gates.yaml's full set runs ci/tools.sh, ci/checks.sh and ci/security.sh"
else
  fail "gates.yaml's full set runs ci/tools.sh, ci/checks.sh and ci/security.sh, not '$full'"
fi
if [[ "$full" != *docker* ]]; then ok "the gates need no Docker"; else fail "the gates need no Docker"; fi

[ "$failed" = 0 ] && echo "build pin tests passed" || { echo "build pin tests failed"; exit 1; }
