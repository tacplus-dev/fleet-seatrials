#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/apply.sh against stub kubectl, helm, git, operator and
# images/build.sh: it applies only the render diff showed (#34), and only
# through the operator in cluster (#76): it installs the operator's chart in the
# platform namespace, by the image's digest, with the config directory as the
# chart's bundle, never runs the CLI's own apply, never reaches a tenant
# namespace, and passes only once the operator's release is that render. And
# installs nothing until the cluster's render has granted the operator its Role
# (tacplus-dev/cluster#59), and on a timeout names each TenantNamespace
# deploymentproxy has not made Ready (#78). And deploy/operator-post-render.sh:
# the chart's init container pinned, and no RBAC of its own added. Needs bash,
# jq, yq, gzip and GNU tar.
#
#   deploy/apply_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
ok() { echo "ok   $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got [$2], want [$3]"; fi; }

cm() { # a ConfigMap NAME in NAMESPACE with VALUE
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n  namespace: %s\ndata:\n  v: %s\n' "$1" "$2" "$3"
}
# render.yaml: a platform object and a tenant namespace's; other.yaml: another render.
{ cm kernel-config tac-seatrials one; printf -- '---\n'; cm platform-ingress tac-seatrials-00000002 one; } > "$work/render.yaml"
{ cm kernel-config tac-seatrials two; printf -- '---\n'; cm platform-ingress tac-seatrials-00000002 one; } > "$work/other.yaml"
want=sha256:$(sha256sum < "$work/render.yaml" | cut -d' ' -f1)
other=sha256:$(sha256sum < "$work/other.yaml" | cut -d' ' -f1)
image=us-central1-docker.pkg.dev/tacplus-dev/seatrials/schematic/operator@sha256:$(printf '%064d' 1)

# The tree apply.sh runs in: its operator.yaml names a deployment, so its
# platform namespace is tac-seatrials (deploy/namespaces.sh, #4).
tree=$work/tree
mkdir -p "$tree/deploy/bootstrap/services" "$tree/deploy/bootstrap/tenants/alpha" "$tree/deploy/bootstrap/configs" \
  "$tree/bin" "$tree/images" "$work/bin"
cp "$here/apply.sh" "$here/namespaces.sh" "$here/operator-post-render.sh" "$tree/deploy/"
cp "$here/../images/pins.yaml" "$tree/images/"
printf 'deployment: seatrials\ntenants: [alpha]\ntenant_ids: {alpha: 741kqltx}\n' > "$tree/deploy/bootstrap/operator.yaml"
echo 'pki: SEKRIT' > "$tree/deploy/bootstrap/crypto.yaml"
echo 'kernel: {}' > "$tree/deploy/bootstrap/services/kernel.yaml"
echo 'oauth: {}' > "$tree/deploy/bootstrap/tenants/alpha/oauth.yaml"
echo 'generated' > "$tree/deploy/bootstrap/configs/kernel.yaml"

cat > "$tree/bin/schematic-operator" <<'EOF'
#!/usr/bin/env bash
echo "operator $*" >> "$STUB_LOG"
case "$*" in
  generate) ;;
  "apply --dry-run") cat "$STUB_MANIFEST" ;;
  *) echo "unexpected operator $*" >&2; exit 3 ;;
esac
EOF
cat > "$tree/images/build.sh" <<'EOF'
#!/usr/bin/env bash
echo "images/build.sh $*" >> "$STUB_LOG"
[ "$*" = operator-ref ] || { echo "unexpected images/build.sh $*" >&2; exit 3; }
[ -z "${STUB_NO_IMAGE:-}" ] || { echo "no operator image with fingerprint fp-x" >&2; exit 1; }
echo "$STUB_IMAGE"
EOF
cat > "$work/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$STUB_LOG"
case "$*" in
  "clone -q https://github.com/tacplus-dev/operator.git "*) mkdir -p "$4/helm" ;;
  "-C "*" checkout -q "*) ;;
  *) echo "unexpected git $*" >&2; exit 3 ;;
esac
EOF
# helm: logs its arguments, keeps the bundle it is given, and, as the operator
# would once it runs, stores the release schematic as STUB_APPLIED (a render's
# file) in $STUB_STATE, unless STUB_HELM_FAILS.
cat > "$work/bin/helm" <<'EOF'
#!/usr/bin/env bash
printf 'helm' >> "$STUB_LOG"; printf ' [%s]' "$@" >> "$STUB_LOG"; echo >> "$STUB_LOG"
[ "$1 $2" = "upgrade --install" ] || { echo "unexpected helm $*" >&2; exit 3; }
for a in "$@"; do case "$a" in config.bundle=*) cp "${a#config.bundle=}" "$STUB_BUNDLE" ;; esac; done
[ -z "${STUB_HELM_FAILS:-}" ] || { echo "Error: context deadline exceeded" >&2; exit 1; }
release() { jq -n --rawfile m "$1" '{name: "schematic", manifest: $m}' | gzip | base64 -w0; }
[ -z "${STUB_APPLIED:-}" ] || { release "$STUB_APPLIED" > "$STUB_STATE"; release "$STUB_OLDER" > "$STUB_STATE.old"; }
EOF
# kubectl: the context, helm's release secrets (the stored release, encoded as
# helm stores it: base64 of its gzipped JSON, base64 again as Secret data), the
# operator's logs, the pods, the cluster's Role for the operator (unless
# STUB_NO_OPERATOR_ROLE), and the TenantNamespaces (STUB_TENANTNAMESPACES, a
# list's JSON; Forbidden with STUB_TN_FORBIDDEN).
cat > "$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$STUB_LOG"
case "$*" in
  "config current-context") echo "${STUB_CONTEXT:-gke_tacplus-dev_us-central1-a_dev}" ;;
  "get secret -n tac-seatrials -l owner=helm,name=schematic,status=deployed -o json")
    if [ -s "$STUB_STATE" ]; then
      # Revision 10 is the operator's apply; 9, listed after it, is an older render.
      jq -n --arg r "$(base64 -w0 < "$STUB_STATE")" --arg o "$(base64 -w0 < "$STUB_STATE.old")" \
        '{items: [{metadata: {labels: {version: "10"}}, data: {release: $r}}, {metadata: {labels: {version: "9"}}, data: {release: $o}}]}'
    else echo '{"items": []}'; fi ;;
  "logs -n tac-seatrials deployment/schematic-operator "*) echo "waiting for tenant namespace tac-seatrials-741kqltx" ;;
  "get pods -n tac-seatrials") ;;
  "get role/deployment-operator rolebinding/deployment-operator -n tac-seatrials -o name")
    [ -z "${STUB_NO_OPERATOR_ROLE:-}" ] ||
      { echo 'Error from server (NotFound): roles.rbac.authorization.k8s.io "deployment-operator" not found' >&2; exit 1; }
    printf 'role.rbac.authorization.k8s.io/deployment-operator\nrolebinding.rbac.authorization.k8s.io/deployment-operator\n' ;;
  "get tenantnamespaces.deploymentproxy.tacplus.dev -n tac-seatrials -o json --request-timeout=10s")
    [ -z "${STUB_TN_FORBIDDEN:-}" ] || { printf '%s\n' 'Error from server (Forbidden): tenantnamespaces.deploymentproxy.tacplus.dev is forbidden: User "seatrials-deploy" cannot list resource "tenantnamespaces"' >&2; exit 1; }
    cat "${STUB_TENANTNAMESPACES:-/dev/null}" ;;
  *) echo "unexpected kubectl $*" >&2; exit 3 ;;
esac
EOF
chmod +x "$tree/bin/"* "$tree/images/build.sh" "$work/bin/"*

# applysh NAME WANT(applied|refused) MANIFEST [ENV=VALUE...]: runs apply.sh; $out, $status, the calls in $work/log.
applysh() {
  local name=$1 want=$2 manifest=$3
  shift 3
  : > "$work/log"; rm -f "$work/state" "$work/state.old" "$work/bundle"
  out=$(env -u RENDER_DIGEST PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_MANIFEST="$manifest" STUB_IMAGE="$image" \
    STUB_STATE="$work/state" STUB_OLDER="$work/other.yaml" STUB_BUNDLE="$work/bundle" OPERATOR_APPLY_TIMEOUT=2 OPERATOR_APPLY_INTERVAL=0 "$@" \
    "$tree/deploy/apply.sh" 2>&1)
  status=$?
  if [[ "$out" == *SEKRIT* ]]; then fail "apply.sh $name: printed the crypto file"; return 1; fi
  if grep -qx "operator apply" "$work/log"; then fail "apply.sh $name: ran the CLI's own apply as the deploy account"; return 1; fi
  case "$want" in
    applied) [ "$status" -eq 0 ] && grep -q '^helm ' "$work/log" || { fail "apply.sh $name: status $status; out=[$out]"; return 1; } ;;
    refused) [ "$status" -ne 0 ] || { fail "apply.sh $name: passed; out=[$out]"; return 1; } ;;
  esac
  ok "apply.sh $name"
}
helm_arg() { # FLAG -> each value helm was given for FLAG
  grep '^helm ' "$work/log" | grep -o "\[$1\] \[[^]]*\]" | sed "s/^\[$1\] \[\(.*\)\]$/\1/"
}

if applysh "applies the render diff showed, through the operator" applied "$work/render.yaml" \
    RENDER_DIGEST="$want" STUB_APPLIED="$work/render.yaml"; then
  [[ "$out" == *"the operator applied render $want (release schematic, revision 10)"* ]] &&
    ok "it says the operator applied that render, in the release's latest revision" || fail "applied: not said: [$out]"
  check "the operator's chart is installed as the release schematic-operator, from the operator's helm/" \
    "$(grep '^helm ' "$work/log" | cut -d' ' -f1-4) $(grep '^helm ' "$work/log" | cut -d' ' -f5 | grep -c '/operator/helm\]$')" \
    "helm [upgrade] [--install] [schematic-operator] 1"
  check "the chart is the operator's at images/pins.yaml's operator_commit" \
    "$(grep -c "^git -C .*/operator checkout -q $(sed -n 's/^operator_commit: *//p' "$here/../images/pins.yaml")$" "$work/log")" 1
  check "it is installed in the platform namespace, and waited for" \
    "$(helm_arg --namespace) $(grep -c '^helm .*\[--wait\]' "$work/log")" "tac-seatrials 1"
  check "in cluster mode for the deployment, by the image's digest, from the fleet's registry, with no pull secret" \
    "$(helm_arg --set-string | sort | xargs)" \
    "operator.deployment=seatrials operator.image=$image operator.imagePullSecret= operator.localImages=us-central1-docker.pkg.dev/tacplus-dev/seatrials"
  check "its settings and crypto are the generated config directory's" \
    "$(helm_arg --set-file | grep -v '^config.bundle=' | sed "s|$tree/||" | sort | xargs)" \
    "config.crypto=deploy/bootstrap/crypto.yaml config.settings=deploy/bootstrap/operator.yaml"
  check "the post-renderer pins its init container" "$(helm_arg --post-renderer)" "$tree/deploy/operator-post-render.sh"
  check "the bundle is the rest of the config directory, the generated configs/ left out" \
    "$(base64 -d "$work/bundle" | tar -tzf - | grep -v '/$' | xargs)" "services/kernel.yaml tenants/alpha/oauth.yaml"
  cp "$work/bundle" "$work/bundle.1"
  applysh "applies again" applied "$work/render.yaml" RENDER_DIGEST="$want" STUB_APPLIED="$work/render.yaml" >/dev/null &&
    check "the same config is the same bundle, so the operator's pod is not restarted for nothing" \
      "$(cmp -s "$work/bundle" "$work/bundle.1" && echo same || echo differs)" same
  check "nothing reaches a tenant namespace" "$(grep -c 'tac-seatrials-' "$work/log")" 0
  installed=$(grep -n -m1 '^helm ' "$work/log" | cut -d: -f1)
  role=$(grep -n -m1 '^kubectl get role/deployment-operator rolebinding/deployment-operator ' "$work/log" | cut -d: -f1)
  [ "${role:-0}" -gt 0 ] && [ "$role" -lt "${installed:-0}" ] && ok "the cluster's Role for the operator is checked before the install" ||
    fail "the operator's Role is checked at line [$role], the install at [$installed]"
  rendered=$(grep -n -m1 '^operator apply --dry-run$' "$work/log" | cut -d: -f1)
  [ "${rendered:-0}" -gt 0 ] && [ "$rendered" -lt "${installed:-0}" ] && ok "the render is checked before anything is installed" ||
    fail "the render is checked at line [$rendered], the install at [$installed]"
fi
applysh "refuses a render other than the one diff showed" refused "$work/other.yaml" RENDER_DIGEST="$want" &&
  { check "nothing installed" "$(grep -c '^helm ' "$work/log")" 0
    [[ "$out" == *"$want"* && "$out" == *diff* ]] && ok "the refusal says which render diff showed" || fail "refusal: [$out]"; }
applysh "refuses with no render digest" refused "$work/render.yaml" &&
  check "nothing installed without a digest" "$(grep -c '^helm ' "$work/log")" 0
applysh "refuses another kube context" refused "$work/render.yaml" RENDER_DIGEST="$want" STUB_CONTEXT=gke_prod &&
  check "nothing installed in another context" "$(grep -c '^helm ' "$work/log")" 0
applysh "refuses without the operator's image" refused "$work/render.yaml" RENDER_DIGEST="$want" STUB_NO_IMAGE=1 &&
  { check "nothing installed without the image" "$(grep -c '^helm ' "$work/log")" 0
    [[ "$out" == *"images job"* ]] && ok "the refusal names the images job" || fail "no image: [$out]"; }
applysh "fails when the operator does not come up" refused "$work/render.yaml" RENDER_DIGEST="$want" STUB_HELM_FAILS=1 &&
  { [[ "$out" == *"operator| waiting for tenant namespace"* ]] && ok "it shows the operator's log" || fail "helm failed: [$out]"; }
applysh "refuses until the cluster has granted the operator its Role" refused "$work/render.yaml" RENDER_DIGEST="$want" \
    STUB_NO_OPERATOR_ROLE=1 &&
  { check "nothing installed without the cluster's Role" "$(grep -c '^helm ' "$work/log")" 0
    [[ "$out" == *deployment-operator*"tacplus-dev/cluster#59"*"apply the cluster first"* ]] &&
      ok "the refusal names the Role and the cluster's change" || fail "no Role: [$out]"; }
applysh "fails when the operator applies another render" refused "$work/render.yaml" RENDER_DIGEST="$want" \
    STUB_APPLIED="$work/other.yaml" &&
  { [[ "$out" == *"has not applied render $want"* && "$out" == *"$other"* && "$out" == *"operator| "* ]] &&
      ok "it says which render the operator's release is, and shows the operator's log" || fail "other render: [$out]"; }
# The TenantNamespaces in tac-seatrials, by tid: alpha's (741kqltx) not Ready, people's (00000001) Ready,
# restore's (00000002) never made, and one this config does not name.
tn() { # TID [STATUS REASON MESSAGE]
  jq -n --arg tid "$1" --arg s "${2:-}" --arg r "${3:-}" --arg m "${4:-}" \
    '{kind: "TenantNamespace", metadata: {name: $tid, namespace: "tac-seatrials"}, spec: {tid: $tid},
      status: (if $s == "" then {} else {conditions: [{type: "Ready", status: $s, reason: $r, message: $m}]} end)}'
}
{ tn 741kqltx False QuotaExceeded 'resourcequota tenant: exceeded'; tn 00000001 True Ready ''; tn zzzzzzzz False Gone ''; } |
  jq -s '{kind: "TenantNamespaceList", items: .}' > "$work/tns.json"
{ tn 741kqltx True Ready ''; tn 00000001 True Ready ''; tn 00000002 True Ready ''; } | jq -s '{items: .}' > "$work/tns-ready.json"
applysh "fails when the operator never applies" refused "$work/render.yaml" RENDER_DIGEST="$want" STUB_TENANTNAMESPACES="$work/tns.json" &&
  { [[ "$out" == *"has not applied render $want"*"not deployed"* ]] && ok "it says the release is not deployed" ||
      fail "never applied: [$out]"
    [[ "$out" == *"741kqltx: not Ready: QuotaExceeded: resourcequota tenant: exceeded"* ]] &&
      ok "it names the TenantNamespace not Ready, with its reason and message" || fail "not Ready: [$out]"
    [[ "$out" == *"00000002: no TenantNamespace"* ]] && ok "it names the one the operator never made" || fail "missing: [$out]"
    [[ "$out" != *"00000001:"* && "$out" != *zzzzzzzz* ]] && ok "it names neither a Ready one nor one the config does not expect" ||
      fail "too much: [$out]"
    [[ "$out" == *"not Ready"*"operator| "* ]] && ok "the TenantNamespaces come before the operator's log" || fail "order: [$out]"
    check "it reads them in the platform namespace alone" "$(grep -c 'tac-seatrials-' "$work/log")" 0; }
applysh "a timeout with every TenantNamespace Ready" refused "$work/render.yaml" RENDER_DIGEST="$want" \
    STUB_TENANTNAMESPACES="$work/tns-ready.json" &&
  { [[ "$out" == *"every TenantNamespace in tac-seatrials is Ready"*"operator| "* ]] && ok "it says they are all Ready" ||
      fail "all Ready: [$out]"; }
applysh "a timeout when the TenantNamespaces cannot be read" refused "$work/render.yaml" RENDER_DIGEST="$want" STUB_TN_FORBIDDEN=1 &&
  { [[ "$out" == *"has not applied render $want"* && "$out" == *"operator| "* ]] &&
      ok "the timeout and the operator's log are still shown" || fail "forbidden: [$out]"
    check "the read's failure is one line" "$(grep -c 'TenantNamespaces in tac-seatrials could not be read: .*Forbidden' <<<"$out")" 1; }
applysh "an older revision of this render is not this apply" refused "$work/render.yaml" RENDER_DIGEST="$want" \
  STUB_APPLIED="$work/other.yaml" STUB_OLDER="$work/render.yaml"
cp "$tree/deploy/bootstrap/operator.yaml" "$work/operator.yaml.keep"
printf 'tenants: []\n' > "$tree/deploy/bootstrap/operator.yaml"
applysh "refuses a config with no deployment" refused "$work/render.yaml" RENDER_DIGEST="$want" &&
  check "nothing installed with no deployment" "$(grep -c '^helm ' "$work/log")" 0
cp "$work/operator.yaml.keep" "$tree/deploy/bootstrap/operator.yaml"

# ---- deploy/operator-post-render.sh, on a render shaped as the operator chart's (helm/, deployment set).
chart_render() { # INIT_CONTAINER_NAME
  cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: operator
  namespace: tac-seatrials
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: schematic-operator
  namespace: tac-seatrials
spec:
  template:
    spec:
      serviceAccountName: operator
      initContainers:
      - name: $1
        image: busybox:latest
      containers:
      - name: schematic-operator
        image: $image
EOF
}
pinned=$(sed -n 's/^operator_init_image: *//p' "$here/../images/pins.yaml")
check "operator_init_image is busybox, pinned by digest" \
  "$(sed -n 's/^docker\.io\/library\/busybox:[0-9.]*@\(sha256:[0-9a-f]\{64\}\)$/pinned/p' <<<"$pinned")" pinned
post=$(chart_render extract-config | "$tree/deploy/operator-post-render.sh" 2>&1)
status=$?
check "post-render passes the chart's render" "$status" 0
check "the init container runs the pinned image" \
  "$(yq 'select(.kind == "Deployment") | .spec.template.spec.initContainers[0].image' <<<"$post")" "$pinned"
check "the operator's own image is left as it is" \
  "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' <<<"$post")" "$image"
check "the chart's objects are kept, and no Role or binding added: the cluster's render grants them (#78)" \
  "$(yq -N '.kind + "/" + .metadata.namespace + "/" + .metadata.name' <<<"$post" | xargs)" \
  "ServiceAccount/tac-seatrials/operator Deployment/tac-seatrials/schematic-operator"
out=$(chart_render renamed | "$tree/deploy/operator-post-render.sh" 2>&1) &&
  fail "post-render passes a render without extract-config: [$out]" ||
  { [[ "$out" == *extract-config* ]] && ok "post-render refuses a chart with no init container to pin" || fail "no init: [$out]"; }

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
