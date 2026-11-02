#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/lib.sh's ci_kube and the test-idp-signin job (#31), against a stub
# gcloud and kubectl. ci_kube fails, saying why, when gcloud gives it no
# credentials for the cluster or leaves no current context, even where the
# job's && list turns errexit off; it names the context it set. The
# test-idp-signin job skips, saying the test IdP is not set up yet, when the
# environment test-idp has no TEST_IDP_SEED (the test-idp job generates it),
# before it asks GCP or the cluster for anything; with the seed it runs
# test-idp/signin.sh. lib.sh runs from a copy, so its cleanup never touches
# this checkout. Needs bash and yq.
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

# The job's tree: lib.sh, and a stub signin.sh that says it ran.
src=$work/job/src
mkdir -p "$src/ci" "$src/test-idp"
cp "$here/ci/lib.sh" "$src/ci/lib.sh"
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
      GCP_DEPLOY_SA=test-idp-deploy@p.iam.gserviceaccount.com CLUSTER=tacplus ZONE=us-central1-a "${envs[@]}" \
      bash -c "set -eo pipefail; $1" ) > "$work/out" 2>&1
}

# --- ci_kube ------------------------------------------------------------------

if job -- 'cd src && source ci/lib.sh && ci_gcp && ci_kube && echo "next ran"'; then
  grep -qx 'kube: gke_p_us-central1-a_tacplus' "$work/out" && grep -qx 'next ran' "$work/out" &&
    ok "ci_kube names the context it set" || fail "ci_kube: $(cat "$work/out")"
  grep -q '^gcloud container clusters get-credentials tacplus --zone us-central1-a --project jody1-328023' "$work/log/gcloud" &&
    ok "ci_kube asks for CLUSTER in ZONE" || fail "get-credentials: $(cat "$work/log/gcloud")"
else
  fail "ci_kube with credentials: $(cat "$work/out")"
fi

if job GKE_REFUSE=1 -- 'cd src && source ci/lib.sh && ci_gcp && ci_kube && echo "next ran"'; then
  fail "ci_kube succeeded with no credentials: $(cat "$work/out")"
else
  ! grep -q 'next ran' "$work/out" && grep -q 'kube: no credentials for the cluster tacplus (us-central1-a)' "$work/out" &&
    grep -q 'container.clusters.get' "$work/out" &&
    ok "ci_kube fails with gcloud's error when it gets no credentials" || fail "ci_kube refused: $(cat "$work/out")"
fi

if job GKE_NO_CONTEXT=1 -- 'cd src && source ci/lib.sh && ci_gcp && ci_kube && echo "next ran"'; then
  fail "ci_kube succeeded with no current context: $(cat "$work/out")"
else
  ! grep -q 'next ran' "$work/out" && grep -q 'kube: no current context' "$work/out" &&
    ok "ci_kube fails when it is left no current context" || fail "ci_kube, no context: $(cat "$work/out")"
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
  grep -qx 'signin.sh ran on gke_p_us-central1-a_tacplus' "$work/out" && ! grep -q skip "$work/out" &&
    ok "test-idp-signin runs signin.sh on the tacplus cluster when the test IdP is set up" ||
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
