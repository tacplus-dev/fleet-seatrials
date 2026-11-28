#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the fleet's storage shape (#3): each tenant's Stratum, in memory, in its
# own namespace, with operator.yaml's topology.stratum_members members
# (tacplus-dev/operator#2), and redo, its durability, one /system instance in
# the platform namespace, nothing in the restore tenant's (tacplus-dev/operator#57;
# tacplus-dev/roadmap decisions/s2s-never-crosses-tenants-2026-10-31.md, the
# 2026-11-07 addendum). It renders the fleet with the operator on a copy of
# deploy/bootstrap (as deploy/pigeons-namespaces_test.sh does) and requires a
# stratum-<tenant> StatefulSet in tac-seatrials-<tid> for each of operator.yaml's
# tenants and the reserved people tenant, none in tac-seatrials, and redo's in
# tac-seatrials; services/kernel.yaml to give redo its /system delegate only;
# and generate to refuse the retired topology.stratum_nodes. Needs bash, yq,
# jq and the operator (bin/schematic-operator, by ci/tools.sh; OPERATOR
# overrides it).
#
#   deploy/stratum-redo_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
operator=${OPERATOR:-$here/bin/schematic-operator}
bootstrap=$here/deploy/bootstrap
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }

if [ ! -x "$operator" ]; then
  echo "FAIL the operator $operator is built (ci/tools.sh builds it into bin/)"; exit 1
fi

# field FILE KEY: the first `KEY: value` in a chart template (a Helm template, not YAML), its value.
field() { sed -n "s/^ *$2: *//p" "$1" | head -1; }
# render DIR: a root CA into DIR/crypto.yaml, then generate the fleet from the
# config directory DIR, its charts in DIR/charts.
render() {
  (cd "$1" && export SCHEMATIC_OPERATOR_DIR="$1" SCHEMATIC_LOCAL_IMAGES=registry.invalid/seatrials &&
    "$operator" init ca && "$operator" generate --output "$1/charts") > "$1/generate.log" 2>&1
}
errors() { grep -m3 -i 'error' "$1/generate.log" || tail -3 "$1/generate.log"; }
fresh() {
  rm -rf "$work/bootstrap" && cp -R "$bootstrap" "$work/bootstrap"
  rm -rf "$work/bootstrap/configs" "$work/bootstrap/crypto.yaml" "$work/bootstrap/ca.pem"
}

deployment=$(yq '.deployment' "$bootstrap/operator.yaml")
platform=tac-$deployment
members=$(yq '.topology.stratum_members // 1' "$bootstrap/operator.yaml")
[ "$members" = 1 ] && ok "operator.yaml runs 1 Stratum member a tenant on seatrials" \
  || fail "operator.yaml's topology.stratum_members is 1 on seatrials, not [$members]"
[ "$(yq '.topology | has("stratum_nodes")' "$bootstrap/operator.yaml")" = false ] \
  && ok "operator.yaml has no retired topology.stratum_nodes" \
  || fail "operator.yaml has no retired topology.stratum_nodes"

fresh
if ! render "$work/bootstrap"; then
  fail "generate renders the fleet: $(errors "$work/bootstrap")"
else
  templates=$work/bootstrap/charts/schematic/templates
  # Each tenant's Stratum: operator.yaml's tenants by their tids, and the reserved people tenant.
  while read -r tenant tid; do
    set=$templates/stratum-$tenant/statefulset.yaml
    if [ ! -f "$set" ]; then
      fail "$tenant's Stratum is rendered (stratum-$tenant)"; continue
    fi
    ns=$(field "$set" namespace) replicas=$(field "$set" replicas) sa=$(field "$set" serviceAccountName)
    [ "$ns" = "$platform-$tid" ] && ok "$tenant's Stratum runs in its own namespace $ns" \
      || fail "$tenant's Stratum runs in $platform-$tid, not [$ns]"
    [ "$replicas" = "$members" ] && ok "$tenant's Stratum has $members member(s)" \
      || fail "$tenant's Stratum has $members member(s), not [$replicas]"
    [ "$sa" = "stratum-$tenant" ] && ok "$tenant's Stratum runs as stratum-$tenant" \
      || fail "$tenant's Stratum runs as stratum-$tenant, not [$sa]"
    [ -f "$work/bootstrap/configs/stratum-$tenant.yaml" ] && ok "$tenant's Stratum has its config" \
      || fail "$tenant's Stratum has its config (configs/stratum-$tenant.yaml)"
  done < <(yq '.tenant_ids | to_entries | .[] | .key + " " + .value' "$bootstrap/operator.yaml"; echo "people 00000001")
  # No Stratum of the platform's: stratum runs only as a tenant's.
  [ ! -e "$templates/stratum" ] && ok "no Stratum is rendered for the platform" \
    || fail "no Stratum is rendered for the platform (templates/stratum)"
  # redo: one /system instance, in the platform namespace.
  set=$templates/redo/statefulset.yaml
  if [ -f "$set" ]; then
    ns=$(field "$set" namespace) replicas=$(field "$set" replicas)
    [ "$ns" = '{{ .Values.global.namespace }}' ] && ok "redo runs in the platform namespace" \
      || fail "redo runs in the platform namespace, not [$ns]"
    [ "$replicas" = 1 ] && ok "redo is one instance" || fail "redo is one instance, not [$replicas]"
  else
    fail "redo is rendered (templates/redo)"
  fi
  restore=$(ls -d "$templates"/redo-* 2>/dev/null; grep -rl -e "$platform-00000002" -e 'redo-restore' "$templates" 2>/dev/null)
  [ -z "$restore" ] && ok "nothing is rendered into the restore tenant" \
    || fail "nothing is rendered into the restore tenant: [$(echo $restore)]"
  # kernel's delegates (generate's services/kernel.yaml): redo's is /system, the restore tenant's is gone.
  kernel=$work/bootstrap/services/kernel.yaml
  got=$(yq -o=json '[.delegates[] | select(.name == "redo") | .tenant_namespace // "/system"]' "$kernel" | jq -c .)
  [ "$got" = '["/system"]' ] && ok "kernel delegates to redo as /system alone" \
    || fail "kernel delegates to redo as /system alone, not $got"
  got=$(yq -o=json '[.delegates[] | select(.name == "stratum") | .tenant_namespace // "/system"] | sort' "$kernel" | jq -c .)
  [ "$got" = '["/tenants/alpha","/tenants/beta","/tenants/people"]' ] && ok "kernel delegates to each tenant's Stratum, and to no Stratum of the platform's: $got" \
    || fail "kernel delegates to each tenant's Stratum, not $got"
  # generate rewrites kernel.yaml; the committed one is what it writes.
  diff -q "$bootstrap/services/kernel.yaml" "$kernel" >/dev/null \
    && ok "services/kernel.yaml is what generate writes" \
    || fail "services/kernel.yaml is what generate writes: $(diff "$bootstrap/services/kernel.yaml" "$kernel" | head -5)"
fi

# The shared Stratum's member count is retired: refused, saying so.
fresh
yq -i '.topology.stratum_nodes = 3' "$work/bootstrap/operator.yaml"
if render "$work/bootstrap"; then
  fail "an operator.yaml setting topology.stratum_nodes is refused"
elif grep -q 'stratum_nodes is retired' "$work/bootstrap/generate.log"; then
  ok "an operator.yaml setting topology.stratum_nodes is refused"
else
  fail "an operator.yaml setting topology.stratum_nodes is refused, saying so: $(errors "$work/bootstrap")"
fi

[ "$failures" = 0 ] && echo "stratum and redo tests passed" || { echo "stratum and redo tests failed: $failures"; exit 1; }
