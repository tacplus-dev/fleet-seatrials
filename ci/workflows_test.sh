#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the GitHub security workflow (.github/workflows/security.yml, #36, #37).
# The CI image alone takes most of an ubuntu-latest runner's free disk, so a job
# run inside it (`container:`) ran out of disk in ci/tools.sh and never reached
# ci/security.sh (#37). The job runs on the host instead: it frees the runner's
# preinstalled toolsets first, then runs ci/tools.sh and ci/security.sh in the
# deploy pipeline's CI image, and uploads the report, failed or not. Needs bash,
# jq and yq.
#
#   ci/workflows_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

wf=$(yq -o=json '.' "$here/.github/workflows/security.yml")
image=$(yq '.default.image' "$here/ci/deploy.gitlab-ci.yml")
# check NAME JQ-FILTER-ON-THE-WORKFLOW: ok when the filter is true.
check() {
  if [ "$(jq --arg image "$image" "$2" <<<"$wf")" = true ]; then ok "$1"; else fail "$1"; fi
}

check "it runs on every push to main" '.on.push.branches | index("main") != null'
check "it runs nightly" '[.on.schedule[]?.cron] | length > 0'
check "it runs on pull requests" '.on | has("pull_request")'
check "the job runs on the runner's host, not in the image (#37)" '.jobs.security | has("container") | not'
# Each step's run script, in order, with its index.
steps='[.jobs.security.steps | to_entries[] | {i: .key, run: (.value.run // ""), uses: (.value.uses // "")}]'
check "it frees the runner's preinstalled toolsets before the image runs (#37)" "
  $steps as \$s
  | ([\$s[] | select(.run | test(\"rm -rf .*/usr/share/dotnet\")) | .i] | first) as \$free
  | ([\$s[] | select(.run | test(\"docker (run|pull)\")) | .i] | first) as \$image
  | \$free != null and \$image != null and \$free < \$image"
check "the job's image (IMAGE) is the deploy pipeline's CI image" '.jobs.security.env.IMAGE == $image'
# The CI image is pinned by digest, so the image Trivy scans is the one the jobs
# run (#43), and every build-image reference is that one (#21, #38).
[[ "$image" =~ ^ghcr\.io/tacplus-dev/tacplus/build:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] &&
  ok "the CI image is a tacplus build image pinned by its patch and digest (#43)" ||
  fail "the CI image is a tacplus build image pinned by its patch and digest (#43): $image"
others=$(grep -rhoE 'ghcr\.io/tacplus-dev/tacplus/build[^ "`]*' "$here"/ci/*.gitlab-ci.yml "$here"/images \
  "$here"/.github | LC_ALL=C sort -u)
[ "$others" = "$image" ] && ok "every build-image reference in ci/, images/ and .github/ is the CI image (#21, #38)" ||
  fail "every build-image reference in ci/, images/ and .github/ is the CI image (#21, #38): $(echo $others)"
check "ci/tools.sh and ci/security.sh run in that image" "
  [$steps[] | .run | select(test(\"ci/(tools|security).sh\"))] | length > 0
  and all(test(\"docker run [^\\\\n]*\\\"[\$]IMAGE\\\"\"))"
check "ci/security.sh runs after ci/tools.sh, with its bin/ on PATH" "
  $steps as \$s
  | ([\$s[] | select(.run | test(\"ci/tools.sh\")) | .i] | first) as \$tools
  | ([\$s[] | select(.run | test(\"bin:[^\\\\n]*ci/security.sh\")) | .i] | first) as \$sec
  | \$tools != null and \$sec != null and \$tools <= \$sec"
check "the security-report artifact is security/, uploaded failed or not" '
  [.jobs.security.steps[] | select((.uses // "") | startswith("actions/upload-artifact"))
   | select(.if == "always()" and .with.name == "security-report" and .with.path == "security/")] | length == 1'

[ "$failed" = 0 ] && echo "workflow tests passed" || { echo "workflow tests failed"; exit 1; }
