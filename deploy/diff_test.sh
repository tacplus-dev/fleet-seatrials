#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/diff.sh against a stub kubectl and operator, with
# deploy/diff-names.sh as kubectl diff's program on LIVE and MERGED
# directories shaped as kubectl diff writes them: it names each object that
# differs and never prints its content; diff.sh records the render's digest,
# and deploy/apply.sh applies only that render (deploy/apply_test.sh). The letsencrypt guard is
# retired (#35): a render that changes or removes letsencrypt passes like any
# other. Needs bash, jq and yq.
#
#   deploy/diff_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
ok() { echo "ok   $1"; }

le_deploy() { # the letsencrypt Deployment, with IMAGE
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: letsencrypt0
  namespace: schematic
spec:
  template:
    spec:
      serviceAccountName: letsencrypt
      containers:
        - name: letsencrypt
          image: $1
          envFrom:
            - secretRef:
                name: acme-account
          env:
            - name: X
              valueFrom:
                configMapKeyRef:
                  name: acme-env
                  key: x
      volumes:
        - name: config
          configMap:
            name: letsencrypt0-config
        - name: shared
          projected:
            sources:
              - secret:
                  name: shared-certs
EOF
}
cm() { # a ConfigMap NAME with VALUE
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n  namespace: schematic\ndata:\n  v: %s\n' "$1" "$2"
}

# fixture NAME: a LIVE and MERGED pair holding the same objects.
fixture() {
  local d=$work/$1
  mkdir -p "$d/LIVE" "$d/MERGED"
  for side in LIVE MERGED; do
    le_deploy letsencrypt:a > "$d/$side/apps.v1.Deployment.schematic.letsencrypt0"
    cm kernel-config one > "$d/$side/v1.ConfigMap.schematic.kernel-config"
    cm letsencrypt0-config one > "$d/$side/v1.ConfigMap.schematic.letsencrypt0-config"
    cm acme-env one > "$d/$side/v1.ConfigMap.schematic.acme-env"
    cm shared-certs one > "$d/$side/v1.Secret.schematic.shared-certs"
    cm acme-account one > "$d/$side/v1.Secret.schematic.acme-account"
    cm gateway0-config one > "$d/$side/v1.ConfigMap.schematic.gateway0-config"
  done
  echo "$d"
}

# names FIXTURE NAME WANT_STATUS WANT_NAMED: runs diff-names.sh on the fixture as changed by the
# caller; WANT_NAMED is what it must name (space-separated, sorted).
names() {
  local d=$work/$1 name=$2 want_status=$3 want_named=$4 out status named
  out=$("$here/diff-names.sh" "$d/LIVE" "$d/MERGED" 2>&1)
  status=$?
  named=$(sed -n 's/^[a-z]*: //p' <<<"$out" | sort | tr '\n' ' ' | sed 's/ $//')
  if [ "$status" -ne "$want_status" ]; then fail "$name: status $status, want $want_status; out=[$out]"; return; fi
  if [ "$named" != "$want_named" ]; then fail "$name: named [$named], want [$want_named]"; return; fi
  if [[ "$out" == *SEKRIT* ]]; then fail "$name: printed an object's content: [$out]"; return; fi
  ok "$name"
}

fixture same >/dev/null
names same "no difference: status 0, nothing named" 0 ""

d=$(fixture kernel); cm kernel-config SEKRIT > "$d/MERGED/v1.ConfigMap.schematic.kernel-config"
names kernel "a changed object is named, not shown" 1 "v1.ConfigMap.schematic.kernel-config"

d=$(fixture deploy); le_deploy letsencrypt:SEKRIT > "$d/MERGED/apps.v1.Deployment.schematic.letsencrypt0"
names deploy "letsencrypt's Deployment is an object like any other" 1 "apps.v1.Deployment.schematic.letsencrypt0"

d=$(fixture added); cm x SEKRIT > "$d/MERGED/v1.Service.schematic.added"
names added "an added object is named" 1 "v1.Service.schematic.added"
out=$("$here/diff-names.sh" "$d/LIVE" "$d/MERGED" 2>&1)
[[ "$out" == "added: v1.Service.schematic.added" ]] && ok "it says how the object differs" || fail "how: [$out]"

d=$(fixture removed); rm "$d/MERGED/apps.v1.Deployment.schematic.letsencrypt0"
names removed "a removed object is named" 1 "apps.v1.Deployment.schematic.letsencrypt0"

# ---- deploy/diff.sh: renders with the operator, diffs with kubectl, names what differs.
mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo "${STUB_CONTEXT:-gke_tacplus-dev_us-central1-a_dev}" ;;
  "diff -f "*)
    { echo "--- kubectl diff"; cat "$3"; } >> "${STUB_DIFFED:-/dev/null}"
    # The deploy account's Role is in the platform namespace only (#75).
    if grep -q 'namespace: tac-seatrials-' "$3"; then
      echo 'Error from server (Forbidden): networkpolicies.networking.k8s.io "platform-ingress" is forbidden' >&2; exit 2
    fi
    [ -n "${STUB_DIFF_STATUS:-}" ] && exit "$STUB_DIFF_STATUS"
    "$KUBECTL_EXTERNAL_DIFF" "$STUB_FIXTURE/LIVE" "$STUB_FIXTURE/MERGED" ;;
  *) echo "unexpected kubectl $*" >&2; exit 3 ;;
esac
EOF
cat > "$work/bin/schematic-operator" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "apply --dry-run" ] || { echo "unexpected operator $*" >&2; exit 3; }
cat "$STUB_MANIFEST"
EOF
chmod +x "$work/bin/"*
# The tree diff.sh runs in: its operator.yaml names a deployment, so its
# platform namespace is tac-seatrials and its tenant namespaces
# tac-seatrials-<tid> (deploy/namespaces.sh, #4).
mkdir -p "$work/dtree/deploy/bootstrap"
cp "$here/diff.sh" "$here/diff-names.sh" "$here/namespaces.sh" "$work/dtree/deploy/"
printf 'deployment: seatrials\ntenants: [alpha]\ntenant_ids: {alpha: 741kqltx}\n' > "$work/dtree/deploy/bootstrap/operator.yaml"
le_deploy letsencrypt:a > "$work/with-le.yaml"; printf -- '---\n' >> "$work/with-le.yaml"; cm kernel-config one >> "$work/with-le.yaml"
cm kernel-config one > "$work/without-le.yaml"

# diffsh NAME WANT(pass|fail) FIXTURE MANIFEST [ENV=VALUE...]
diffsh() {
  local name=$1 want=$2 fx=$3 manifest=$4 out status
  shift 4
  out=$(env PATH="$work/bin:$PATH" OPERATOR="$work/bin/schematic-operator" STUB_FIXTURE="$work/$fx" \
    STUB_MANIFEST="$manifest" "$@" \
    "$work/dtree/deploy/diff.sh" 2>&1)
  status=$?
  if [[ "$out" == *SEKRIT* ]]; then fail "diff.sh $name: printed an object's content"; return; fi
  case "$want" in
    pass) [ "$status" -eq 0 ] || { fail "diff.sh $name: status $status; out=[$out]"; return; } ;;
    fail) [ "$status" -ne 0 ] || { fail "diff.sh $name: passed; out=[$out]"; return; } ;;
  esac
  ok "diff.sh $name"
}

diffsh "no change passes" pass same "$work/with-le.yaml"
diffsh "another service's change passes" pass kernel "$work/with-le.yaml"
diffsh "a change to letsencrypt passes: the guard is retired (#35)" pass deploy "$work/with-le.yaml"
diffsh "a render without letsencrypt, while it runs, passes: its retirement (#35)" pass removed "$work/without-le.yaml"
diffsh "kubectl diff failing fails" fail same "$work/with-le.yaml" STUB_DIFF_STATUS=2
diffsh "another kube context is refused" fail same "$work/with-le.yaml" STUB_CONTEXT=gke_prod
diffsh "the old cluster (jody1's seatrials) is refused" fail same "$work/with-le.yaml" \
  STUB_CONTEXT=gke_old-project_us-central1-a_seatrials
out=$(env PATH="$work/bin:$PATH" OPERATOR="$work/bin/schematic-operator" STUB_FIXTURE="$work/kernel" \
  STUB_MANIFEST="$work/with-le.yaml" "$work/dtree/deploy/diff.sh" 2>&1)
[[ "$out" == *"changed: v1.ConfigMap.schematic.kernel-config"* ]] && ok "diff.sh names what the apply would change" ||
  fail "diff.sh does not name the change: [$out]"

# ---- The render digest (#34): the render diff.sh showed is the one deploy/apply.sh applies.
# other.yaml: the same render but for kernel's config.
le_deploy letsencrypt:a > "$work/other.yaml"; printf -- '---\n' >> "$work/other.yaml"; cm kernel-config two >> "$work/other.yaml"
want=sha256:$(sha256sum < "$work/with-le.yaml" | cut -d' ' -f1)
out=$(env PATH="$work/bin:$PATH" OPERATOR="$work/bin/schematic-operator" STUB_FIXTURE="$work/same" \
  STUB_MANIFEST="$work/with-le.yaml" RENDER_DIGEST_OUT="$work/render.env" "$work/dtree/deploy/diff.sh" 2>&1)
[ "$(cat "$work/render.env" 2>/dev/null)" = "RENDER_DIGEST=$want" ] && [[ "$out" == *"$want"* ]] &&
  ok "diff.sh records and prints its render's digest" || fail "diff.sh digest: [$(cat "$work/render.env" 2>/dev/null)] out=[$out]"
diffsh "the render diff showed passes" pass same "$work/with-le.yaml" RENDER_DIGEST="$want"
diffsh "another render passes without a digest" pass same "$work/other.yaml"
diffsh "a render other than the one diff showed fails" fail same "$work/other.yaml" RENDER_DIGEST="$want"

# ---- Tenant namespaces (#75): the deploy account's Role is in the platform
# namespace only, and the tenant namespaces are deploymentproxy's, so diff.sh
# names a tenant namespace's object and never asks kubectl about it.
np() { # a NetworkPolicy NAME in NAMESPACE
  printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  podSelector: {}\n' "$1" "$2"
}
cp "$work/with-le.yaml" "$work/tenant.yaml"
{ printf -- '---\n'; np platform-ingress tac-seatrials-00000002; printf -- '---\n'; np platform-ingress tac-seatrials-741kqltx; } >> "$work/tenant.yaml"
: > "$work/diffed"
out=$(env PATH="$work/bin:$PATH" OPERATOR="$work/bin/schematic-operator" STUB_FIXTURE="$work/kernel" \
  STUB_MANIFEST="$work/tenant.yaml" STUB_DIFFED="$work/diffed" RENDER_DIGEST_OUT="$work/tenant.env" \
  "$work/dtree/deploy/diff.sh" 2>&1)
status=$?
[ "$status" -eq 0 ] && ok "diff.sh passes a render with objects in tenant namespaces" || fail "diff.sh tenant: status $status; out=[$out]"
[[ "$out" == *"changed: v1.ConfigMap.schematic.kernel-config"* ]] && ok "diff.sh still diffs the platform namespace's objects" ||
  fail "diff.sh tenant: no platform diff: [$out]"
[[ "$out" == *deploymentproxy* &&
  "$out" == *"networking.k8s.io.v1.NetworkPolicy.tac-seatrials-00000002.platform-ingress"* &&
  "$out" == *"networking.k8s.io.v1.NetworkPolicy.tac-seatrials-741kqltx.platform-ingress"* ]] &&
  ok "diff.sh names the tenant namespaces' objects, applied through deploymentproxy" || fail "diff.sh tenant: not named: [$out]"
diffed=$(cat "$work/diffed")
[ "$(grep -c '^--- kubectl diff$' "$work/diffed")" -eq 1 ] && [[ "$diffed" == *kernel-config* && "$diffed" != *tac-seatrials-* ]] &&
  ok "kubectl is asked about the platform namespace's objects only" || fail "diff.sh tenant: kubectl was given [$diffed]"
[ "$(cat "$work/tenant.env" 2>/dev/null)" = "RENDER_DIGEST=sha256:$(sha256sum < "$work/tenant.yaml" | cut -d' ' -f1)" ] &&
  ok "the digest is over the whole render, tenant namespaces' objects included" || fail "diff.sh tenant digest: [$(cat "$work/tenant.env" 2>/dev/null)]"
{ np platform-ingress tac-seatrials-00000002; printf -- '---\n'; np platform-ingress tac-seatrials-00000001; } > "$work/tenant-only.yaml"
: > "$work/diffed"
out=$(env PATH="$work/bin:$PATH" OPERATOR="$work/bin/schematic-operator" STUB_FIXTURE="$work/same" \
  STUB_MANIFEST="$work/tenant-only.yaml" STUB_DIFFED="$work/diffed" "$work/dtree/deploy/diff.sh" 2>&1)
status=$?
[ "$status" -eq 0 ] && [ ! -s "$work/diffed" ] && [[ "$out" == *tac-seatrials-00000001.platform-ingress* ]] &&
  ok "a render with nothing in the platform namespace asks kubectl nothing" || fail "diff.sh tenant-only: status $status, kubectl given [$(cat "$work/diffed")]; out=[$out]"

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
