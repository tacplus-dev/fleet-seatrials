#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the rendered deploy pipeline (#34): ci/deploy.gitlab-ci.yml with its
# anchors expanded and each job's `default` and `extends` merged in, as GitLab
# renders it. That pipeline runs only on main (ci/gitlab-project.gitlab-ci.yml's
# workflow). seatrials is not production, so `apply` starts by itself once
# `diff` succeeds: it is not manual, and a failure fails the pipeline. It takes
# the render digest `diff` recorded (a dotenv artifact, RENDER_DIGEST), so the
# render `diff` showed is the one applied. The jobs that stay manual are the
# ones that are not approval of the fleet: `apply-letsencrypt` (Jody's
# never-restart-letsencrypt rule, environment seatrials-letsencrypt),
# `test-idp` and `signin-secrets`. Needs bash, jq and yq.
#
#   ci/pipeline_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

# The child pipeline's jobs, rendered: every key with a script, each with
# `default`, then what it extends, then itself merged, and its effective
# `when` and `allow_failure` (GitLab's defaults: on_success; manual jobs
# allow failure).
jobs=$(yq -o=json 'explode(.)' "$here/ci/deploy.gitlab-ci.yml" | jq '
  . as $root | ($root.default // {}) as $d
  | with_entries(select((.value | type) == "object" and (.value | has("script"))))
  | map_values(. as $j
      | $d * ([$j.extends // empty] | flatten | map($root[.]) | add // {}) * $j
      | .when = (.when // "on_success")
      | .allow_failure = (.allow_failure // (.when == "manual")))')
job() { jq -c --arg j "$1" ".[\$j] | $2" <<<"$jobs"; }

# check NAME JQ-FILTER-ON-JOBS: ok when the filter is true.
check() {
  if [ "$(jq "$2" <<<"$jobs")" = true ]; then ok "$1"; else fail "$1"; fi
}

[ "$(yq '.workflow.rules | length' "$here/ci/gitlab-project.gitlab-ci.yml")" = 1 ] &&
  [[ "$(yq '.workflow.rules[0].if' "$here/ci/gitlab-project.gitlab-ci.yml")" == '$CI_COMMIT_BRANCH == "main" && '* ]] &&
  ok "the pipeline runs on main only" || fail "the pipeline runs on more than main"

check "apply is not manual on main" '.apply.when == "on_success"'
check "apply has no rule that makes it manual" '[.apply.rules[]?.when] | all(. != "manual")'
check "a failed apply fails the pipeline" '.apply.allow_failure == false'
check "apply starts once diff succeeds" '[.apply.needs[] | if type == "object" then .job else . end] | index("diff") != null'
check "apply deploys to the environment seatrials" '.apply.environment.name == "seatrials"'
check "apply waits for any other job on seatrials" '.apply.resource_group == "seatrials"'
check "diff hands its render digest to apply" '.diff.artifacts.reports.dotenv != null'
check "apply applies the render diff showed (RENDER_DIGEST)" \
  '[.apply.needs[] | select(type == "object" and .job == "diff") | .artifacts] | all(. != false)'
check "test follows apply" '.test.needs | index("apply") != null'
check "test runs the functional suite, deploy/e2e.sh (#17)" '.test.script | join("\n") | test("deploy/e2e.sh")'
check "test publishes the suite's JUnit report, failed or not" \
  '.test.artifacts.when == "always" and (.test.artifacts.reports.junit | tostring | test("e2e"))'

check "the security job runs ci/security.sh with the pinned tools (#36)" \
  '.security.script | join("\n") | test("ci/security.sh")'
check "a failed security job fails the pipeline" '.security.when == "on_success" and .security.allow_failure == false'
check "the security job keeps its JSON report, failed or not" \
  '.security.artifacts.when == "always" and (.security.artifacts.paths | index("src/security/") != null)'
check "nothing is built or applied before the security job passes" \
  '([.images.needs[], .generate.needs[]] | map(if type == "object" then .job else . end)) as $n
   | ($n | map(select(. == "security")) | length) == 2'

for j in apply-letsencrypt test-idp signin-secrets; do
  check "$j stays manual" ".[\"$j\"].when == \"manual\""
done
check "apply-letsencrypt is Jody's environment, seatrials-letsencrypt" \
  '."apply-letsencrypt".environment.name == "seatrials-letsencrypt"'
check "apply-letsencrypt checks the render its own diff showed" \
  '."apply-letsencrypt".script | join("\n") | test("RENDER_DIGEST_OUT=.*deploy/diff.sh") and test("deploy/apply.sh")'
check "no other job is manual" \
  '[to_entries[] | select(.value.when == "manual") | .key] | sort == ["apply-letsencrypt", "signin-secrets", "test-idp"]'
[ -n "$(job apply .)" ] || fail "no apply job rendered"

[ "$failed" = 0 ] && echo "all passed" || { echo "pipeline tests failed"; exit 1; }
