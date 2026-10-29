#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The secrets scan (#22): gitleaks over the history, each commit's additions,
# and over the tree at HEAD, so no key is committed again and none is left in
# the tree. Key material belongs in the deploy pipeline's protected variables
# (docs/deploy-pipeline.md). .gitleaks.toml allows the test fixtures;
# .gitleaksignore lists the findings already in history (they apply to those
# commits only, so the tree scan still finds what they name). Uncommitted files,
# such as the git-ignored deploy/bootstrap/crypto.yaml, are not scanned.
#
#   ci/secrets.sh [REPO]     # needs git and gitleaks (ci/tools.sh builds it into bin/)
set -euo pipefail
repo=$(cd "${1:-$(dirname "$0")/..}" && pwd)
tree=$(mktemp -d)
trap 'rm -rf "$tree"' EXIT

gitleaks git --no-banner --redact --config "$repo/.gitleaks.toml" "$repo"
git -C "$repo" archive HEAD | tar -x -C "$tree"
gitleaks dir --no-banner --redact --config "$repo/.gitleaks.toml" "$tree"
echo "no secrets in the history or the tree at $(git -C "$repo" rev-parse --short=12 HEAD)"
