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
  # The same credential for what reads Application Default Credentials (lego's Cloud DNS, ci/cert.sh).
  export GOOGLE_APPLICATION_CREDENTIALS=$ci_tmp/gcp-federation.json
  gcloud config set project "${GCP_PROJECT:-tacplus-dev}" >/dev/null 2>&1
  echo "gcp: $(gcloud config get account 2>/dev/null) through workload identity federation"
}

# ci_kube: kubectl on the cluster seatrials deploys to (CLUSTER in ZONE: dev,
# in tacplus-dev), as the deploy service account. Every job calls it in an &&
# list, where errexit is off, so it returns on its own failures: no credentials
# for the cluster (gcloud's error), or no current context (#31).
ci_kube() {
  local cluster=${CLUSTER:-dev} zone=${ZONE:-us-central1-a} context
  gcloud components install kubectl gke-gcloud-auth-plugin --quiet >/dev/null 2>&1 || true
  export KUBECONFIG=$ci_tmp/kubeconfig USE_GKE_GCLOUD_AUTH_PLUGIN=True
  gcloud container clusters get-credentials "$cluster" --zone "$zone" \
      --project "${GCP_PROJECT:-tacplus-dev}" >/dev/null 2>"$ci_tmp/kube-err" ||
    { echo "kube: no credentials for the cluster $cluster ($zone) as $(gcloud config get account 2>/dev/null): $(grep -m1 '^ERROR' "$ci_tmp/kube-err" || head -c 300 "$ci_tmp/kube-err")" >&2
      return 1; }
  context=$(kubectl config current-context 2>/dev/null) && [ -n "$context" ] ||
    { echo "kube: no current context after get-credentials for the cluster $cluster ($zone)" >&2; return 1; }
  echo "kube: $context"
}

# ci_test_idp_seeds [optional]: the test IdP's seeds, TEST_IDP_SEED and
# TEST_IDP_CLIENT_SEED (test-idp/README.md), into the environment, after ci_gcp:
# the latest version of the Secret Manager secret test-idp-seeds in tacplus-dev
# (tacplus-dev/cloud#32), two lines NAME=value. Seeds already in the
# environment are kept. No version yet (NOT_FOUND) is a test IdP not set up:
# neither is set, and the test-idp job's apply.sh stores the first. A refusal or
# a version without both seeds fails, saying why; with `optional` (seatrials'
# own jobs, which derive the Test providers' secrets and sign the test users in
# with them) it is said and the job goes on without them. No seed is printed.
ci_test_idp_seeds() {
  local secret=test-idp-seeds file=$ci_tmp/test-idp-seeds seed client
  [ -z "${TEST_IDP_SEED:-}" ] || [ -z "${TEST_IDP_CLIENT_SEED:-}" ] || return 0
  if ! ( umask 077
         gcloud secrets versions access latest --secret="$secret" --project="${GCP_PROJECT:-tacplus-dev}" \
           --out-file="$file" 2>"$ci_tmp/seeds-err" ); then
    rm -f "$file"
    if grep -q NOT_FOUND "$ci_tmp/seeds-err"; then
      echo "test idp: the secret $secret has no seeds yet (the test-idp job stores them)"
      return 0
    fi
    echo "test idp: cannot read the secret $secret as $(gcloud config get account 2>/dev/null): $(grep -m1 '^ERROR' "$ci_tmp/seeds-err" || head -c 300 "$ci_tmp/seeds-err")" >&2
    [ "${1:-}" = optional ] && return 0 || return 1
  fi
  seed=$(sed -n 's/^TEST_IDP_SEED=//p' "$file") client=$(sed -n 's/^TEST_IDP_CLIENT_SEED=//p' "$file")
  rm -f "$file"
  if [ -z "$seed" ] || [ -z "$client" ]; then
    echo "test idp: the latest version of the secret $secret is not two lines TEST_IDP_SEED=... and TEST_IDP_CLIENT_SEED=..." >&2
    [ "${1:-}" = optional ] && return 0 || return 1
  fi
  export TEST_IDP_SEED=$seed TEST_IDP_CLIENT_SEED=$client
  echo "test idp: the seeds from the secret $secret"
}

# ci_google_signin: Google's sign-in client secret for deploy/signin-secrets.sh,
# after ci_gcp: the latest version of the Secret Manager secret
# google-signin-seatrials in tacplus-dev, which Jody adds in the Console (Google
# has no API that makes a client or its secret; docs/deploy-pipeline.md, The
# Google sign-in client, #46), into a file of the job's, GOOGLE_SIGNIN_FILE. No
# version yet, or a refusal, is said and the job goes on without it: oauth keeps
# the Google secret the cluster holds. Nothing here prints it.
ci_google_signin() {
  local secret=google-signin-seatrials file=$ci_tmp/google-signin
  if ! ( umask 077
         gcloud secrets versions access latest --secret="$secret" --project="${GCP_PROJECT:-tacplus-dev}" \
           --out-file="$file" 2>"$ci_tmp/google-err" ); then
    rm -f "$file"
    if grep -q NOT_FOUND "$ci_tmp/google-err"; then
      echo "google: the secret $secret has no version yet (docs/deploy-pipeline.md, The Google sign-in client); Google keeps the cluster's secret"
    else
      echo "google: cannot read the secret $secret as $(gcloud config get account 2>/dev/null): $(grep -m1 '^ERROR' "$ci_tmp/google-err" || head -c 300 "$ci_tmp/google-err"); Google keeps the cluster's secret" >&2
    fi
    return 0
  fi
  export GOOGLE_SIGNIN_FILE=$file
  echo "google: the client secret from the secret $secret"
}

# ci_test_idp_set_up: whether the test IdP has its seeds (ci_test_idp_seeds),
# which the manual test-idp job generates on its first run. Without them it is
# not set up yet (a dry run before that apply), and this says so (#31).
ci_test_idp_set_up() {
  [ -n "${TEST_IDP_SEED:-}" ] && return 0
  echo "skip: the test IdP is not set up yet (no seeds in the secret test-idp-seeds); run the manual test-idp job first (test-idp/README.md)"
  return 1
}

# ci_no_gitlab_key_material: fails, naming it, when the job holds a GitLab
# variable that held the fleet's key material, or the bot user's token that
# wrote them (#17): FLEET_CRYPTO_YAML (and its parts _2 and on), FLEET_CA_PEM,
# FLEET_INIT_TOKEN. The key material is in Secret Manager since #44, and no
# GitLab variable holds it: the hub deletes them. Never prints a value.
ci_no_gitlab_key_material() {
  local v
  for v in $(compgen -e); do
    case $v in FLEET_CRYPTO_YAML|FLEET_CRYPTO_YAML_[0-9]*|FLEET_CA_PEM|FLEET_INIT_TOKEN)
      echo "the job holds the GitLab variable $v: delete it from the project, nothing reads it; the fleet's key material is in Secret Manager (docs/deploy-pipeline.md)" >&2
      return 1 ;;
    esac
  done
}

# ci_crypto: the fleet's key material into deploy/bootstrap, where
# schematic-operator reads it, after ci_gcp: the latest versions of the Secret
# Manager secrets FLEET_CRYPTO_SECRET (crypto.yaml) and FLEET_CA_SECRET (ca.pem)
# in GCP_PROJECT, which the init-secrets job adds (#44, deploy/init-secrets.sh).
# Both paths are in .gitignore and in no job's artifacts. Every job calls it in
# an && list, so it returns on its own failures: no version yet (run
# init-secrets), or a refusal, with Secret Manager's error.
ci_crypto() {
  local secret file
  ci_no_gitlab_key_material || return 1
  for secret in "${FLEET_CRYPTO_SECRET:-fleet-crypto-seatrials}:crypto.yaml" "${FLEET_CA_SECRET:-fleet-ca-seatrials}:ca.pem"; do
    file=${secret#*:} secret=${secret%%:*}
    if ! ( umask 077
           gcloud secrets versions access latest --secret="$secret" --project="${GCP_PROJECT:-tacplus-dev}" \
             --out-file="$fleet/deploy/bootstrap/$file" 2>"$ci_tmp/crypto-err" ); then
      rm -f "$fleet/deploy/bootstrap/$file"
      if grep -q NOT_FOUND "$ci_tmp/crypto-err"; then
        echo "crypto: the secret $secret has no version yet: run the manual init-secrets job, then this pipeline again (docs/deploy-pipeline.md)" >&2
      else
        echo "crypto: cannot read the secret $secret as $(gcloud config get account 2>/dev/null): $(grep -m1 '^ERROR' "$ci_tmp/crypto-err" || head -c 300 "$ci_tmp/crypto-err")" >&2
      fi
      return 1
    fi
  done
  echo "crypto: the fleet's key material from the secrets ${FLEET_CRYPTO_SECRET:-fleet-crypto-seatrials} and ${FLEET_CA_SECRET:-fleet-ca-seatrials}"
}

# ci_cert: the fleet's public certificate into crypto.yaml, after ci_crypto and
# ci_gcp: the version the cert job passed on (CERT_SECRET and CERT_VERSION, its
# dotenv), never latest, so generate, diff and apply render the same one
# (ci/cert-install.sh, #35). Every job calls it in an && list, so it returns on
# its own failures.
ci_cert() {
  [ -n "${CERT_VERSION:-}" ] && [ -n "${CERT_SECRET:-}" ] ||
    { echo "cert: no CERT_SECRET and CERT_VERSION: the cert job passes them on (ci/cert.sh); this job needs it" >&2; return 1; }
  ( umask 077
    gcloud secrets versions access "$CERT_VERSION" --secret="$CERT_SECRET" --project="${CERT_PROJECT:-${GCP_PROJECT:-}}" \
      --out-file="$ci_tmp/cert.pem" 2>"$ci_tmp/cert-err" ) ||
    { echo "cert: cannot read version $CERT_VERSION of the secret $CERT_SECRET: $(grep -m1 '^ERROR' "$ci_tmp/cert-err" || head -c 300 "$ci_tmp/cert-err")" >&2
      return 1; }
  "$fleet/ci/cert-install.sh" "$ci_tmp/cert.pem" "$fleet/deploy/bootstrap/crypto.yaml" || return 1
  rm -f "$ci_tmp/cert.pem"
  echo "cert: the secret $CERT_SECRET, version $CERT_VERSION, is the gateway's certificate"
}

# ci_cleanup: removes what the job put in place (after_script; the VM goes too).
ci_cleanup() {
  rm -rf "$ci_tmp" "$fleet/deploy/bootstrap/crypto.yaml" "$fleet/deploy/bootstrap/ca.pem" \
    "$fleet/deploy/bootstrap/configs" "$fleet/charts"
}
trap ci_cleanup EXIT
