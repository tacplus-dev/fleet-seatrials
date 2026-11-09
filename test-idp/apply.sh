#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The test IdP's apply (#27), the deploy pipeline's test-idp job, and the first
# step of test-idp-signin: its certificate, then Keycloak and its realms in the
# namespace tac-test-idp of the `dev` cluster (test-idp/keycloak.yaml). Run
# where ci_gcp and ci_kube have put gcloud and kubectl in place as
# test-idp-deploy, which may touch nothing outside that namespace, the test
# IdP's two certificate secrets, its seeds and its challenge zone
# (docs/deploy-pipeline.md, the test IdP). Its DNS record and its port on the
# address `gateway` are tacplus-dev/cloud's; nothing here writes them.
#
#   test-idp/apply.sh
#
# The certificate: the test IdP's own, for idp.test.tacplus.dev only, never the
# fleet's: ci/cert.sh, as the cert job does it for the fleet, with its own
# secrets tls-test-idp and acme-account-test-idp and its own challenge zone
# (_acme-challenge.idp.test.tacplus.dev). The version it passes on becomes the
# Secret keycloak-tls, which haproxy serves.
#
# The secrets: every password and client secret is derived from two seeds
# (test-idp/testidp.py), TEST_IDP_SEED (the users' passwords, the admin's) and
# TEST_IDP_CLIENT_SEED (the tacplus-dev clients' secrets), kept as one version
# of the Secret Manager secret test-idp-seeds (tacplus-dev/cloud#32), two lines
# NAME=value. The job reads them into its environment first (ci/lib.sh,
# ci_test_idp_seeds). When it found none, this generates both and adds them as
# that secret's first version, so no person ever sees them: no GitLab token
# writes a variable (gitlab.com Free has no project access tokens; the hub,
# 2026-11-09). Nothing here prints a secret, and none is on a command line or
# in an artifact.
#
# The realms are rendered with their secrets into the Secret keycloak-realms,
# which Keycloak imports on every start. The Deployment is rolled out when the
# realms or the certificate change, and only then.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ns=tac-test-idp
host=idp.test.tacplus.dev
port=8443
project=${GCP_PROJECT:-tacplus-dev}
[ $# -eq 0 ] || { echo "usage: $0 (no arguments; see the header)" >&2; exit 2; }
ctx=$(kubectl config current-context)
want_ctx=gke_${project}_${ZONE:-us-central1-a}_${CLUSTER:-dev}
[ "$ctx" = "$want_ctx" ] || { echo "kube context is $ctx, not $want_ctx, the cluster the test IdP runs on" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
umask 077

# The seeds: those the job read, or, the first time, new ones, stored.
if [ -z "${TEST_IDP_SEED:-}" ] && [ -z "${TEST_IDP_CLIENT_SEED:-}" ]; then
  { printf 'TEST_IDP_SEED=%s\n' "$(python3 "$here/testidp.py" new-seed)"
    printf 'TEST_IDP_CLIENT_SEED=%s\n' "$(python3 "$here/testidp.py" new-seed)"; } > "$tmp/seeds"
  gcloud secrets versions add test-idp-seeds --project="$project" --data-file="$tmp/seeds" >/dev/null 2>"$tmp/err" ||
    { echo "storing the seeds in the secret test-idp-seeds: $(grep -m1 ERROR "$tmp/err" || head -c 300 "$tmp/err")" >&2; exit 1; }
  TEST_IDP_SEED=$(sed -n 's/^TEST_IDP_SEED=//p' "$tmp/seeds") TEST_IDP_CLIENT_SEED=$(sed -n 's/^TEST_IDP_CLIENT_SEED=//p' "$tmp/seeds")
  export TEST_IDP_SEED TEST_IDP_CLIENT_SEED
  rm -f "$tmp/seeds"
  echo "seeds: generated and stored as the first version of the secret test-idp-seeds"
elif [ -z "${TEST_IDP_SEED:-}" ] || [ -z "${TEST_IDP_CLIENT_SEED:-}" ]; then
  echo "one of TEST_IDP_SEED and TEST_IDP_CLIENT_SEED is set, not both: the job reads both from test-idp-seeds" >&2
  exit 1
fi

# The certificate, checked and renewed when due, then the version cert.sh passes on.
CERT_PROJECT=$project CERT_SECRET=tls-test-idp ACME_ACCOUNT_SECRET=acme-account-test-idp \
  CERT_DOMAINS=$host CERT_FQDN=$host CERT_DNS_ZONE=acme-challenge-idp-test-tacplus-dev CERT_SUPPLIED_SECRET= \
  CERT_ENV_OUT=$tmp/cert.env "$here/../ci/cert.sh"
tls_version=$(sed -n 's/^CERT_VERSION=//p' "$tmp/cert.env")
gcloud secrets versions access "$tls_version" --secret=tls-test-idp --project="$project" --out-file="$tmp/tls.pem" 2>"$tmp/err" ||
  { echo "cannot read version $tls_version of the secret tls-test-idp: $(grep -m1 ERROR "$tmp/err" || head -c 300 "$tmp/err")" >&2; exit 1; }
kubectl -n "$ns" create secret generic keycloak-tls --from-file=tls.pem="$tmp/tls.pem" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f "$tmp/tls.pem"

# Keycloak's admin credential, and the realms with their secrets, as it imports them.
printf admin > "$tmp/admin-user"
python3 "$here/testidp.py" secret admin > "$tmp/admin-password"
kubectl -n "$ns" create secret generic keycloak-admin --from-file=username="$tmp/admin-user" \
  --from-file=password="$tmp/admin-password" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f "$tmp/admin-password"
mkdir "$tmp/realms" "$tmp/import"
for f in "$here"/realms/*.yaml; do
  r=$(basename "$f" .yaml)
  yq -o=json '.' "$f" > "$tmp/realms/$r.json"
  python3 "$here/testidp.py" render "$tmp/realms/$r.json" > "$tmp/import/$r.json"
done
kubectl -n "$ns" create secret generic keycloak-realms --from-file="$tmp/import" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
realms_sum=$(cat "$tmp"/import/*.json | sha256sum | cut -c1-64)
rm -rf "$tmp/import"

# Keycloak, rolled out when the realms or the certificate changed.
REALMS=$realms_sum TLS=tls-test-idp/$tls_version yq '(select(.kind == "Deployment") | .spec.template.metadata.annotations)
    |= (.["test-idp.tacplus.dev/realms"] = strenv(REALMS) | .["test-idp.tacplus.dev/tls"] = strenv(TLS))' \
  "$here/keycloak.yaml" | kubectl apply -f -
kubectl -n "$ns" rollout status deployment/keycloak --timeout=600s

# Where the public side is: the NEG GKE made for the Service keycloak, which
# tacplus-dev/cloud's listener test-idp names once it exists (its ready).
echo "neg: $(kubectl -n "$ns" get service keycloak -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}' 2>/dev/null || true)"
for r in "$tmp"/realms/*.json; do
  realm=$(basename "$r" .json)
  if curl -fsS -m 10 -o /dev/null "https://$host:$port/realms/$realm/.well-known/openid-configuration" 2>/dev/null; then
    echo "public: https://$host:$port/realms/$realm answers"
  else
    echo "public: https://$host:$port/realms/$realm does not answer yet (the listener test-idp, tacplus-dev/cloud; the test-idp-signin job checks it)"
  fi
done
