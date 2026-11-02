# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by the deploy pipeline's jobs (ci/deploy.gitlab-ci.yml), each run
# from the checkout of this repository at the commit being deployed. Every
# credential comes from the GitLab project's protected variables or the job's
# own OIDC token, lives in the job's temporary directory and goes with the job
# (the deploy runner's VMs are used once). Nothing here prints one; never run
# these jobs with `set -x`.
set -euo pipefail
fleet=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ci_tmp=$(mktemp -d)
export PATH="$fleet/bin:$PATH"

# ci_github: git reaches https://github.com with no credential. What the tools
# and images jobs fetch there (tacplus, operator, launcher and every service
# repository in fleet.lock) is public; this repository, the only private one,
# is fetched before any job's script, with a token only that fetch held
# (.github-reader in ci/deploy.gitlab-ci.yml, #29). No GitHub token is stored.
ci_github() {
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0=
  # tacplus sends CI_JOB_TOKEN to every https host it fetches from, github.com
  # included, where the clone then fails (#14).
  unset CI_JOB_TOKEN
}

# ci_gcp: gcloud as the deploy service account, through GitLab OIDC and
# Workload Identity Federation: the job's ID token (id_tokens GCP_ID_TOKEN) is
# exchanged for a short-lived Google token. No key file exists anywhere.
ci_gcp() {
  : "${GCP_ID_TOKEN:?the job has no id_tokens GCP_ID_TOKEN}"
  : "${GCP_WIF_PROVIDER:?the GitLab project variable GCP_WIF_PROVIDER is not set (docs/deploy-pipeline.md)}"
  : "${GCP_DEPLOY_SA:?GCP_DEPLOY_SA is not set}"
  export CLOUDSDK_CONFIG=$ci_tmp/gcloud CLOUDSDK_CORE_DISABLE_PROMPTS=1
  ( umask 077
    printf '%s' "$GCP_ID_TOKEN" > "$ci_tmp/oidc-token"
    gcloud iam workload-identity-pools create-cred-config "$GCP_WIF_PROVIDER" \
      --service-account="$GCP_DEPLOY_SA" --credential-source-file="$ci_tmp/oidc-token" \
      --output-file="$ci_tmp/gcp-federation.json" >/dev/null )
  gcloud auth login --cred-file="$ci_tmp/gcp-federation.json" --quiet >/dev/null
  gcloud config set project "${GCP_PROJECT:-jody1-328023}" >/dev/null 2>&1
  echo "gcp: $(gcloud config get account 2>/dev/null) through workload identity federation"
}

# ci_kube: kubectl on the seatrials cluster (CLUSTER in ZONE), as the deploy
# service account. Every job calls it in an && list, where errexit is off, so
# it returns on its own failures: no credentials for the cluster (gcloud's
# error), or no current context (#31).
ci_kube() {
  local cluster=${CLUSTER:-seatrials} zone=${ZONE:-us-central1-a} context
  gcloud components install kubectl gke-gcloud-auth-plugin --quiet >/dev/null 2>&1 || true
  export KUBECONFIG=$ci_tmp/kubeconfig USE_GKE_GCLOUD_AUTH_PLUGIN=True
  gcloud container clusters get-credentials "$cluster" --zone "$zone" \
      --project "${GCP_PROJECT:-jody1-328023}" >/dev/null 2>"$ci_tmp/kube-err" ||
    { echo "kube: no credentials for the cluster $cluster ($zone) as $(gcloud config get account 2>/dev/null): $(grep -m1 '^ERROR' "$ci_tmp/kube-err" || head -c 300 "$ci_tmp/kube-err")" >&2
      return 1; }
  context=$(kubectl config current-context 2>/dev/null) && [ -n "$context" ] ||
    { echo "kube: no current context after get-credentials for the cluster $cluster ($zone)" >&2; return 1; }
  echo "kube: $context"
}

# ci_test_idp_set_up: whether the environment test-idp has its seed, which the
# manual test-idp job generates on its first run. Without it the test IdP is
# not set up yet (a dry run before that apply), and this says so (#31).
ci_test_idp_set_up() {
  [ -n "${TEST_IDP_SEED:-}" ] && return 0
  echo "skip: the test IdP is not set up yet (no TEST_IDP_SEED in the environment test-idp); run the manual test-idp job first (test-idp/README.md)"
  return 1
}

# ci_crypto: the fleet's key material into deploy/bootstrap, where
# schematic-operator reads it, from the protected file variables
# FLEET_CRYPTO_YAML and FLEET_CA_PEM (environment scope seatrials). Both paths
# are in .gitignore and in no job's artifacts.
ci_crypto() {
  : "${FLEET_CRYPTO_YAML:?the file variable FLEET_CRYPTO_YAML is not set (environment seatrials)}"
  : "${FLEET_CA_PEM:?the file variable FLEET_CA_PEM is not set (environment seatrials)}"
  [ -f "$FLEET_CRYPTO_YAML" ] && [ -f "$FLEET_CA_PEM" ] ||
    { echo "FLEET_CRYPTO_YAML and FLEET_CA_PEM must be file variables" >&2; exit 1; }
  ( umask 077
    cp "$FLEET_CRYPTO_YAML" "$fleet/deploy/bootstrap/crypto.yaml"
    cp "$FLEET_CA_PEM" "$fleet/deploy/bootstrap/ca.pem" )
}

# ci_cleanup: removes what the job put in place (after_script; the VM goes too).
ci_cleanup() {
  rm -rf "$ci_tmp" "$fleet/deploy/bootstrap/crypto.yaml" "$fleet/deploy/bootstrap/ca.pem" \
    "$fleet/deploy/bootstrap/configs" "$fleet/charts"
}
trap ci_cleanup EXIT
