#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests where the pipeline deploys (#39): the project tacplus-dev, the cluster
# dev (us-central1-a), the deploy accounts (and init-secrets'), and the image registry of
# tacplus-dev/cloud's dev stack in seabeam.net, in the pipeline file and in the
# defaults of every script it runs; and that nothing in the repository still
# names jody1-328023: the Google OAuth client is tacplus-dev's (#46), the reader
# and its KMS key are tacplus-ci's (#48).
# Needs bash, git, jq and yq.
#
#   ci/target_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

project=tacplus-dev
cluster=dev
zone=us-central1-a
deploy_sa=seatrials-deploy@tacplus-dev.iam.gserviceaccount.com
test_idp_sa=test-idp-deploy@tacplus-dev.iam.gserviceaccount.com
init_secrets_sa=seatrials-init-secrets@tacplus-dev.iam.gserviceaccount.com
registry=us-central1-docker.pkg.dev/tacplus-dev/seatrials
build_bucket=gs://tacplus-dev-seatrials-build

# want WHAT GOT WANT
want() { if [ "$2" = "$3" ]; then ok "$1: $3"; else fail "$1: [$2], want [$3]"; fi; }

# The child pipeline's jobs, rendered as GitLab renders them (as
# ci/pipeline_test.sh does): `default`, what each extends, then the job.
pipeline=$here/ci/deploy.gitlab-ci.yml
jobs=$(yq -o=json 'explode(.)' "$pipeline" | jq '
  . as $root | ($root.default // {}) as $d
  | with_entries(select((.value | type) == "object" and (.value | has("script"))))
  | map_values(. as $j | $d * ([$j.extends // empty] | flatten | map($root[.]) | add // {}) * $j)')
var() { yq ".variables.$1" "$pipeline"; }
# job_var JOB VAR: VAR as JOB sees it, its own variables over the pipeline's.
job_var() { jq -r --arg j "$1" --arg v "$2" --argjson g "$(yq -o=json .variables "$pipeline")" \
  '.[$j].variables[$v] // $g[$v] // ""' <<<"$jobs"; }

want "the pipeline's GCP_PROJECT" "$(var GCP_PROJECT)" "$project"
want "the pipeline's CLUSTER" "$(var CLUSTER)" "$cluster"
want "the pipeline's ZONE" "$(var ZONE)" "$zone"
want "the pipeline's GCP_DEPLOY_SA" "$(var GCP_DEPLOY_SA)" "$deploy_sa"
want "the pipeline's REGISTRY" "$(var REGISTRY)" "$registry"

# Every job reaches the dev cluster in tacplus-dev; the seatrials jobs as
# seatrials-deploy, the test IdP's as its own account, init-secrets as the
# account that may only add the fleet's key material (#44; tacplus-dev/cloud#28).
for j in $(jq -r 'keys[]' <<<"$jobs"); do
  case $j in test-idp|test-idp-signin) sa=$test_idp_sa ;; init-secrets) sa=$init_secrets_sa ;; *) sa=$deploy_sa ;; esac
  got="$(job_var "$j" GCP_PROJECT) $(job_var "$j" CLUSTER) $(job_var "$j" ZONE) $(job_var "$j" GCP_DEPLOY_SA)"
  [ "$got" = "$project $cluster $zone $sa" ] || fail "$j targets [$got], want [$project $cluster $zone $sa]"
done
ok "every job targets $project, $cluster ($zone), each as its account"

# The jobs that render export the pipeline's registry, not a literal.
for j in generate test; do
  jq -r --arg j "$j" '.[$j].script[]' <<<"$jobs" | grep -qx ' *export SCHEMATIC_LOCAL_IMAGES=\$REGISTRY' &&
    ok "$j renders against \$REGISTRY" || fail "$j does not export SCHEMATIC_LOCAL_IMAGES=\$REGISTRY"
done

# The scripts' defaults, for a run outside the pipeline, are the same.
default() { sed -n "s/.*\${$1:-\([^}]*\)}.*/\1/p" "$2" | grep . | sort -u; }
want "ci/lib.sh's GCP_PROJECT default" "$(default GCP_PROJECT "$here/ci/lib.sh")" "$project"
want "ci/lib.sh's CLUSTER default" "$(default CLUSTER "$here/ci/lib.sh")" "$cluster"
want "ci/lib.sh's ZONE default" "$(default ZONE "$here/ci/lib.sh")" "$zone"
for f in images/build.sh deploy/diff.sh deploy/apply.sh; do
  want "$f's REGISTRY default" "$(default REGISTRY "$here/$f")" "$registry"
done
for f in deploy/diff.sh deploy/apply.sh; do
  want "$f's cluster" "$(default GCP_PROJECT "$here/$f") $(default ZONE "$here/$f") $(default CLUSTER "$here/$f")" \
    "$project $zone $cluster"
done
want "images/build.sh's build bucket" "$(sed -n 's/^build_bucket=//p' "$here/images/build.sh")" "$build_bucket"
for f in images/*.cloudbuild.yaml; do
  got=$(yq '.substitutions._REGISTRY' "$here/$f")
  want "$f's _REGISTRY" "$got" "$registry"
done
want "images/service.cloudbuild.yaml's _TACPLUS_IMAGE" \
  "$(yq '.substitutions._TACPLUS_IMAGE' "$here/images/service.cloudbuild.yaml")" "$registry/ci/tacplus-build:seatrials"
want "coop's pigeonhost image" "$(yq '.kinds[] | select(.name == "echo.ping") | .image' "$here/deploy/bootstrap/services/coop.yaml")" \
  "$registry/schematic/pigeonhost:local"

# The test IdP (#27): the namespace tacplus-dev/cluster gives the deployment test-idp,
# and the contract with tacplus-dev/cloud's listener test-idp, port 8443 of the
# address gateway to the NEG seatrials-test-idp, endpoints on 8443.
want "test-idp/*.yaml's namespace" \
  "$(yq -N '.metadata.namespace' "$here/test-idp/keycloak.yaml" "$here/test-idp/admin-job.yaml" | sort -u)" tac-test-idp
want "test-idp/apply.sh's namespace" "$(sed -n 's/^ns=//p' "$here/test-idp/apply.sh")" tac-test-idp
want "test-idp/signin.sh's namespace" "$(sed -n 's/^ns=//p' "$here/test-idp/signin.sh")" tac-test-idp
want "the test IdP's NEG" "$(yq 'select(.kind == "Service" and .metadata.name == "keycloak")
  | .metadata.annotations["cloud.google.com/neg"]' "$here/test-idp/keycloak.yaml" | jq -c .)" \
  '{"exposed_ports":{"8443":{"name":"seatrials-test-idp"}}}'
want "the NEG's endpoints' port" "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[]
  | .ports[] | select(.name == "https") | .containerPort' "$here/test-idp/keycloak.yaml")" 8443
want "the test IdP's issuers in oauth.yaml" "$(yq '.providers[] | select(.name == "Test *") | .issuer' \
  "$here/deploy/bootstrap/services/oauth.yaml" | sed 's|[a-z]*$||' | sort -u)" "https://idp.test.tacplus.dev:8443/realms/"

# Nothing names jody1-328023, or its project number: the Google OAuth client,
# the last thing there, is tacplus-dev's (#46), and the reader and its KMS key are
# tacplus-ci's (#48). HISTORY.md and ROADMAP.md record the past and are not this
# repository's to edit; this test names it.
stray=$(git -C "$here" grep -n -I -e jody1-328023 -e 23279701427 -- . ':!HISTORY.md' ':!ROADMAP.md' ':!ci/target_test.sh' || true)
[ -z "$stray" ] && ok "nothing names jody1-328023" ||
  fail "these still name jody1-328023 (or 23279701427):
$stray"
want "Google's OAuth client is tacplus-dev's (project number 1038314073791)" \
  "$(yq '.providers[] | select(.name == "Google") | .client_id' "$here/deploy/bootstrap/services/oauth.yaml" | cut -d- -f1)" \
  1038314073791

[ "$failed" = 0 ] && echo "target tests passed" || { echo "target tests failed"; exit 1; }
