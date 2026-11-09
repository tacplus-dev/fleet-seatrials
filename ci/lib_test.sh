#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/lib.sh's ci_kube, ci_cert (#35), ci_test_idp_seeds and the test-idp
# and test-idp-signin jobs (#31, #27),
# against a stub gcloud and kubectl. ci_kube fails, saying why, when gcloud gives it no
# credentials for the cluster or leaves no current context, even where the
# job's && list turns errexit off; it names the context it set. The
# test-idp-signin job skips, saying the test IdP is not set up yet, when the
# secret test-idp-seeds has no version (the test-idp job stores the first),
# before it asks the cluster for anything; with the seeds it runs
# test-idp/apply.sh and test-idp/signin.sh, and it fails, saying why, when
# Secret Manager refuses them or a version lacks one. seatrials' jobs read the
# seeds optional: refused, they go on without them (ci_test_idp_seeds). lib.sh runs from a copy, so its cleanup never touches
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
    payload=$work/payload.pem
    case " \$* " in *" --secret=test-idp-seeds "*)
      [ -z "\${SEEDS_NONE:-}" ] || { echo "ERROR: (gcloud.secrets.versions.access) NOT_FOUND: Secret [projects/1/secrets/test-idp-seeds] not found or has no versions." >&2; exit 1; }
      payload=$work/seeds\${SEEDS_BAD:+-bad} ;;
    esac
    for a in "\$@"; do case "\$a" in --out-file=*) cp "\$payload" "\${a#*=}" ;; esac; done ;;
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

# The job's tree: lib.sh, cert-install.sh, and stubs apply.sh and signin.sh that say they ran.
src=$work/job/src
mkdir -p "$src/ci" "$src/test-idp" "$src/deploy/bootstrap"
cp "$here/ci/lib.sh" "$here/ci/cert-install.sh" "$src/ci/"
# A certificate version: leaf and key (self-signed is enough here).
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$work/leaf.key" -out "$work/leaf.crt" \
  -days 30 -subj /CN=tacplus.dev 2>/dev/null
cat "$work/leaf.crt" "$work/leaf.key" > "$work/payload.pem"
# The test IdP's seeds, as the secret test-idp-seeds holds them; one line only is malformed.
printf 'TEST_IDP_SEED=the-user-seed-0123456789\nTEST_IDP_CLIENT_SEED=the-client-seed-0123456789\n' > "$work/seeds"
head -1 "$work/seeds" > "$work/seeds-bad"
for t in apply signin; do
  printf '#!/usr/bin/env bash\necho "%s.sh ran on $(kubectl config current-context) with ${TEST_IDP_SEED:+the seed}/${TEST_IDP_CLIENT_SEED:+the client seed}"\n' "$t" > "$src/test-idp/$t.sh"
  chmod +x "$src/test-idp/$t.sh"
done

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

ran_on="on gke_p_us-central1-a_dev with the seed/the client seed"
if job SEEDS_NONE=1 -- "$script"; then
  grep -q 'skip: the test IdP is not set up yet' "$work/out" && ! grep -q '\.sh ran' "$work/out" &&
    ! grep -q 'container clusters' "$work/log/gcloud" &&
    ok "test-idp-signin skips, before the cluster, when test-idp-seeds has no version yet" ||
    fail "test-idp-signin, no seeds: $(cat "$work/out"; cat "$work/log/gcloud" 2>/dev/null)"
else
  fail "test-idp-signin fails when the test IdP is not set up: $(cat "$work/out")"
fi

if job -- "$script"; then
  [ "$(grep '\.sh ran' "$work/out")" = "$(printf 'apply.sh ran %s\nsignin.sh ran %s' "$ran_on" "$ran_on")" ] &&
    ! grep -q skip "$work/out" &&
    ok "test-idp-signin applies the test IdP as main has it, then runs signin.sh, on the dev cluster, with the seeds from test-idp-seeds" ||
    fail "test-idp-signin, set up: $(cat "$work/out")"
  grep -q '^gcloud secrets versions access latest --secret=test-idp-seeds --project=tacplus-dev ' "$work/log/gcloud" &&
    ok "the seeds are the latest version of test-idp-seeds" || fail "seeds read: $(cat "$work/log/gcloud")"
  ! grep -q 'seed-0123456789' "$work/out" && ok "the seeds are never printed" || fail "a seed was printed: $(cat "$work/out")"
else
  fail "test-idp-signin, set up: $(cat "$work/out")"
fi

if job GKE_REFUSE=1 -- "$script"; then
  fail "test-idp-signin passes when ci_kube gets no credentials: $(cat "$work/out")"
else
  ! grep -q '\.sh ran' "$work/out" && ok "test-idp-signin fails when the cluster refuses it" ||
    fail "test-idp-signin, refused: $(cat "$work/out")"
fi

if job SM_REFUSE=1 -- "$script"; then
  fail "test-idp-signin passes when Secret Manager refuses the seeds: $(cat "$work/out")"
else
  ! grep -q '\.sh ran' "$work/out" && grep -q 'cannot read the secret test-idp-seeds' "$work/out" &&
    grep -q PERMISSION_DENIED "$work/out" &&
    ok "test-idp-signin fails with Secret Manager's error when it may not read the seeds" ||
    fail "test-idp-signin, seeds refused: $(cat "$work/out")"
fi

if job SEEDS_BAD=1 -- "$script"; then
  fail "test-idp-signin passes with only one seed: $(cat "$work/out")"
else
  ! grep -q '\.sh ran' "$work/out" && grep -q 'not two lines TEST_IDP_SEED=' "$work/out" &&
    ok "test-idp-signin refuses a version of test-idp-seeds without both seeds" ||
    fail "test-idp-signin, one seed: $(cat "$work/out")"
fi

# --- the test-idp job: the seeds, then the apply ------------------------------

script=$(yq '."test-idp".script | join("\n")' "$here/ci/deploy.gitlab-ci.yml")
if job SEEDS_NONE=1 -- "$script"; then
  [ "$(grep '\.sh ran' "$work/out")" = "apply.sh ran on gke_p_us-central1-a_dev with /" ] &&
    ok "test-idp applies with no seeds yet, for apply.sh to generate them" || fail "test-idp, no seeds: $(cat "$work/out")"
else
  fail "test-idp, no seeds: $(cat "$work/out")"
fi
if job -- "$script"; then
  [ "$(grep '\.sh ran' "$work/out")" = "apply.sh ran $ran_on" ] &&
    ok "test-idp applies with the stored seeds" || fail "test-idp, seeds: $(cat "$work/out")"
else
  fail "test-idp, seeds: $(cat "$work/out")"
fi

# --- seatrials' jobs: the seeds when they may read them, else without ---------

if job -- 'cd src && source ci/lib.sh && ci_gcp && ci_test_idp_seeds optional && echo "next ran with ${TEST_IDP_SEED:+the seed}/${TEST_IDP_CLIENT_SEED:+the client seed}"'; then
  grep -qx 'next ran with the seed/the client seed' "$work/out" &&
    ok "ci_test_idp_seeds optional reads the seeds" || fail "optional seeds: $(cat "$work/out")"
else
  fail "optional seeds: $(cat "$work/out")"
fi
if job SM_REFUSE=1 -- 'cd src && source ci/lib.sh && ci_gcp && ci_test_idp_seeds optional && echo "next ran with ${TEST_IDP_SEED:+the seed}/${TEST_IDP_CLIENT_SEED:+the client seed}"'; then
  grep -qx 'next ran with /' "$work/out" && grep -q 'cannot read the secret test-idp-seeds' "$work/out" &&
    ok "ci_test_idp_seeds optional goes on without the seeds when it may not read them, saying so" ||
    fail "optional seeds, refused: $(cat "$work/out")"
else
  fail "ci_test_idp_seeds optional failed when refused: $(cat "$work/out")"
fi
if job TEST_IDP_SEED=from-env TEST_IDP_CLIENT_SEED=from-env -- 'cd src && source ci/lib.sh && ci_gcp && ci_test_idp_seeds && echo "next ran with $TEST_IDP_SEED"'; then
  grep -qx 'next ran with from-env' "$work/out" && ! grep -q 'test-idp-seeds' "$work/log/gcloud" &&
    ok "seeds already in the environment are kept, the secret not read" || fail "seeds from the environment: $(cat "$work/out")"
else
  fail "seeds from the environment: $(cat "$work/out")"
fi
for j in apply signin-secrets test; do
  yq ".\"$j\".script | join(\"\n\")" "$here/ci/deploy.gitlab-ci.yml" | grep -q 'ci_gcp.*ci_test_idp_seeds optional\|^ *ci_test_idp_seeds optional' &&
    ok "$j reads the test IdP's seeds, optional" || fail "$j does not read the test IdP's seeds (ci_test_idp_seeds optional)"
done

# ci_crypto places FLEET_CRYPTO_YAML as it is, or, when init-secrets stored it
# gzipped and base64-encoded (to fit GitLab's 10,000-character limit, #17),
# decoded, joined first with its parts FLEET_CRYPTO_YAML_2 and on; a value that
# decodes to nothing is refused.
printf 'pki:\n  root_ca: x\n' > "$work/crypto-plain"
gzip -9nc "$work/crypto-plain" | base64 -w0 > "$work/crypto-gz"
echo 'H4sIbroken' > "$work/crypto-bad"
echo CA > "$work/ca"
head -c 7 "$work/crypto-gz" > "$work/crypto-gz-1"
tail -c +8 "$work/crypto-gz" | head -c 9 > "$work/crypto-gz-2"
tail -c +17 "$work/crypto-gz" > "$work/crypto-gz-3"
crypto() { # FILE [VAR=VALUE...]: ci_crypto with FLEET_CRYPTO_YAML=FILE, the placed crypto.yaml in $work/placed
  local f=$1; shift
  rm -f "$work/placed"
  ( cd "$src" && env "$@" FLEET_CRYPTO_YAML=$f FLEET_CA_PEM=$work/ca bash -c \
      'source ci/lib.sh && ci_crypto && cp deploy/bootstrap/crypto.yaml "$0"' "$work/placed" ) > "$work/out" 2>&1
}
mkdir -p "$src/deploy/bootstrap"
crypto "$work/crypto-plain" && cmp -s "$work/placed" "$work/crypto-plain" &&
  ok "ci_crypto places a plain crypto.yaml as it is" || fail "ci_crypto, plain: $(cat "$work/out")"
crypto "$work/crypto-gz" && cmp -s "$work/placed" "$work/crypto-plain" &&
  ok "ci_crypto decodes a gzipped, base64-encoded crypto.yaml" || fail "ci_crypto, encoded: $(cat "$work/out")"
crypto "$work/crypto-gz-1" FLEET_CRYPTO_YAML_2="$work/crypto-gz-2" FLEET_CRYPTO_YAML_3="$work/crypto-gz-3" &&
  cmp -s "$work/placed" "$work/crypto-plain" &&
  ok "ci_crypto joins FLEET_CRYPTO_YAML_2, _3 and decodes them" || fail "ci_crypto, parts: $(cat "$work/out")"
if crypto "$work/crypto-gz-1" FLEET_CRYPTO_YAML_2=/nonexistent; then fail "ci_crypto accepts a part that is not a file"
else grep -q "FLEET_CRYPTO_YAML_2 must be a file variable" "$work/out" && ok "ci_crypto refuses a part that is not a file" ||
  fail "ci_crypto, part not a file: $(cat "$work/out")"; fi
if crypto "$work/crypto-bad"; then fail "ci_crypto accepts an encoded value that does not decode"
else grep -q "does not decode" "$work/out" && ok "ci_crypto refuses an encoded value that does not decode" ||
  fail "ci_crypto, bad: $(cat "$work/out")"; fi

[ "$failed" = 0 ] && echo "lib tests passed" || { echo "lib tests failed"; exit 1; }
