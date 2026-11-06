#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/lib.sh's ci_kube, ci_cert (#35) and the test-idp-signin job (#31),
# against a stub gcloud and kubectl. ci_kube fails, saying why, when gcloud gives it no
# credentials for the cluster or leaves no current context, even where the
# job's && list turns errexit off; it names the context it set. The
# test-idp-signin job skips, saying the test IdP is not set up yet, when the
# environment test-idp has no TEST_IDP_SEED (the test-idp job generates it),
# before it asks GCP or the cluster for anything; with the seed it runs
# test-idp/signin.sh. lib.sh runs from a copy, so its cleanup never touches
# this checkout. ci_cert installs the certificate version the cert job passed
# on (CERT_SECRET, CERT_VERSION), that version and no other, as crypto.yaml's
# edge_tls[0], and fails, saying so, without them or when the secret refuses.
# ci_gcp hands its credential to Application Default Credentials (lego). Needs
# bash, yq and openssl.
#
#   ci/lib_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

# A stub gcloud: WIF login, and get-credentials, which writes the context to
# $KUBECONFIG, or refuses when GKE_REFUSE is set, or writes none when
# GKE_NO_CONTEXT is set. A stub kubectl answers current-context from it.
mkdir -p "$work/bin" "$work/log"
cat > "$work/bin/gcloud" <<EOF
#!/usr/bin/env bash
echo "gcloud \$*" >> "$work/log/gcloud"
case "\$1 \$2" in
  "iam workload-identity-pools") for a in "\$@"; do case "\$a" in --output-file=*) echo '{}' > "\${a#*=}" ;; esac; done ;;
  "config get") echo test-idp-deploy@p.iam.gserviceaccount.com ;;
  "secrets versions")
    [ -z "\${SM_REFUSE:-}" ] || { echo "ERROR: (gcloud.secrets.versions.access) PERMISSION_DENIED: denied" >&2; exit 1; }
    for a in "\$@"; do case "\$a" in --out-file=*) cp "$work/payload.pem" "\${a#*=}" ;; esac; done ;;
  "container clusters")
    echo "Fetching cluster endpoint and auth data." >&2
    if [ -n "\${GKE_REFUSE:-}" ]; then
      echo "ERROR: (gcloud.container.clusters.get-credentials) ResponseError: code=403, message=Required \"container.clusters.get\" permission(s)." >&2
      exit 1
    fi
    [ -n "\${GKE_NO_CONTEXT:-}" ] && : > "\$KUBECONFIG" || echo "gke_p_\$6_\$4" > "\$KUBECONFIG" ;;
esac
exit 0
EOF
cat > "$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "config current-context" ] || { echo "kubectl $*" >&2; exit 2; }
[ -s "${KUBECONFIG:-}" ] || { echo "error: current-context is not set" >&2; exit 1; }
cat "$KUBECONFIG"
EOF
chmod +x "$work/bin/"*

# The job's tree: lib.sh, cert-install.sh, and a stub signin.sh that says it ran.
src=$work/job/src
mkdir -p "$src/ci" "$src/test-idp" "$src/deploy/bootstrap"
cp "$here/ci/lib.sh" "$here/ci/cert-install.sh" "$src/ci/"
# A certificate version: leaf and key (self-signed is enough here).
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$work/leaf.key" -out "$work/leaf.crt" \
  -days 30 -subj /CN=tacplus.dev 2>/dev/null
cat "$work/leaf.crt" "$work/leaf.key" > "$work/payload.pem"
printf '#!/usr/bin/env bash\necho "signin.sh ran on $(kubectl config current-context)"\n' > "$src/test-idp/signin.sh"
chmod +x "$src/test-idp/signin.sh"

# job [VAR=VALUE...] -- SCRIPT: SCRIPT in the job's directory, as the runner
# runs a script line (errexit, pipefail), with the test-idp job's variables.
job() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  rm -f "$work/log/"*
  ( cd "$work/job" && env -i HOME="$work" PATH="$work/bin:$PATH" \
      GCP_ID_TOKEN=the-jobs-id-token GCP_WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/g \
      GCP_DEPLOY_SA=test-idp-deploy@p.iam.gserviceaccount.com CLUSTER=dev ZONE=us-central1-a "${envs[@]}" \
      bash -c "set -eo pipefail; $1" ) > "$work/out" 2>&1
}

# --- ci_kube ------------------------------------------------------------------

if job -- 'cd src && source ci/lib.sh && ci_gcp && ci_kube && echo "next ran"'; then
  grep -qx 'kube: gke_p_us-central1-a_dev' "$work/out" && grep -qx 'next ran' "$work/out" &&
    ok "ci_kube names the context it set" || fail "ci_kube: $(cat "$work/out")"
  grep -q '^gcloud container clusters get-credentials dev --zone us-central1-a --project tacplus-dev' "$work/log/gcloud" &&
    ok "ci_kube asks for CLUSTER in ZONE" || fail "get-credentials: $(cat "$work/log/gcloud")"
else
  fail "ci_kube with credentials: $(cat "$work/out")"
fi

if job GKE_REFUSE=1 -- 'cd src && source ci/lib.sh && ci_gcp && ci_kube && echo "next ran"'; then
  fail "ci_kube succeeded with no credentials: $(cat "$work/out")"
else
  ! grep -q 'next ran' "$work/out" && grep -q 'kube: no credentials for the cluster dev (us-central1-a)' "$work/out" &&
    grep -q 'container.clusters.get' "$work/out" &&
    ok "ci_kube fails with gcloud's error when it gets no credentials" || fail "ci_kube refused: $(cat "$work/out")"
fi

if job GKE_NO_CONTEXT=1 -- 'cd src && source ci/lib.sh && ci_gcp && ci_kube && echo "next ran"'; then
  fail "ci_kube succeeded with no current context: $(cat "$work/out")"
else
  ! grep -q 'next ran' "$work/out" && grep -q 'kube: no current context' "$work/out" &&
    ok "ci_kube fails when it is left no current context" || fail "ci_kube, no context: $(cat "$work/out")"
fi

# --- ci_gcp, ci_cert ------------------------------------------------------------

if job -- 'cd src && source ci/lib.sh && ci_gcp && echo "adc=$GOOGLE_APPLICATION_CREDENTIALS" && test -f "$GOOGLE_APPLICATION_CREDENTIALS"'; then
  ok "ci_gcp hands its federated credential to Application Default Credentials"
else
  fail "ci_gcp, Application Default Credentials: $(cat "$work/out")"
fi

cert_job='cd src && source ci/lib.sh && printf "pki:\n    root_ca: {}\n" > deploy/bootstrap/crypto.yaml && ci_gcp && ci_cert &&
  yq ".pki.edge_tls[0].chain[0].base64" deploy/bootstrap/crypto.yaml | base64 -d > ../installed.pem && echo "next ran"'
if job CERT_SECRET=tls-seatrials CERT_VERSION=7 CERT_PROJECT=tacplus-dev -- "$cert_job"; then
  grep -q 'next ran' "$work/out" && cmp -s "$work/job/installed.pem" "$work/leaf.crt" &&
    ok "ci_cert installs the certificate as crypto.yaml's edge_tls[0]" || fail "ci_cert: $(cat "$work/out")"
  grep -q '^gcloud secrets versions access 7 --secret=tls-seatrials --project=tacplus-dev ' "$work/log/gcloud" &&
    ok "ci_cert reads the version the cert job passed on, not latest" || fail "ci_cert read: $(cat "$work/log/gcloud")"
  ! grep -q 'PRIVATE KEY' "$work/out" && ok "ci_cert prints nothing secret" || fail "ci_cert printed the key"
else
  fail "ci_cert: $(cat "$work/out")"
fi
if job -- "$cert_job"; then
  fail "ci_cert succeeded with no version from the cert job: $(cat "$work/out")"
else
  ! grep -q 'next ran' "$work/out" && grep -q 'the cert job passes them on' "$work/out" &&
    ok "ci_cert fails, saying why, without the cert job's version" || fail "ci_cert, no version: $(cat "$work/out")"
fi
if job CERT_SECRET=tls-seatrials CERT_VERSION=7 CERT_PROJECT=tacplus-dev SM_REFUSE=1 -- "$cert_job"; then
  fail "ci_cert succeeded when Secret Manager refused: $(cat "$work/out")"
else
  ! grep -q 'next ran' "$work/out" && grep -q 'PERMISSION_DENIED' "$work/out" &&
    ok "ci_cert fails with Secret Manager's error" || fail "ci_cert, refused: $(cat "$work/out")"
fi

# --- the test-idp-signin job --------------------------------------------------

script=$(yq '."test-idp-signin".script[0]' "$here/ci/deploy.gitlab-ci.yml")
[ "$(yq '."test-idp-signin".script | length' "$here/ci/deploy.gitlab-ci.yml")" = 1 ] && [ -n "$script" ] ||
  fail "test-idp-signin: want one script line, got $(yq '."test-idp-signin".script' "$here/ci/deploy.gitlab-ci.yml")"

if job -- "$script"; then
  grep -q 'skip: the test IdP is not set up yet' "$work/out" && ! grep -q 'signin.sh ran' "$work/out" &&
    [ ! -e "$work/log/gcloud" ] &&
    ok "test-idp-signin skips, before GCP and the cluster, when the test IdP is not set up" ||
    fail "test-idp-signin, no seed: $(cat "$work/out"; cat "$work/log/gcloud" 2>/dev/null)"
else
  fail "test-idp-signin fails when the test IdP is not set up: $(cat "$work/out")"
fi

if job TEST_IDP_SEED=seed TEST_IDP_CLIENT_SEED=client-seed -- "$script"; then
  grep -qx 'signin.sh ran on gke_p_us-central1-a_dev' "$work/out" && ! grep -q skip "$work/out" &&
    ok "test-idp-signin runs signin.sh on the dev cluster when the test IdP is set up" ||
    fail "test-idp-signin, set up: $(cat "$work/out")"
else
  fail "test-idp-signin, set up: $(cat "$work/out")"
fi

if job TEST_IDP_SEED=seed GKE_REFUSE=1 -- "$script"; then
  fail "test-idp-signin passes when ci_kube gets no credentials: $(cat "$work/out")"
else
  ! grep -q 'signin.sh ran' "$work/out" && ok "test-idp-signin fails when the cluster refuses it" ||
    fail "test-idp-signin, refused: $(cat "$work/out")"
fi

[ "$failed" = 0 ] && echo "lib tests passed" || { echo "lib tests failed"; exit 1; }
