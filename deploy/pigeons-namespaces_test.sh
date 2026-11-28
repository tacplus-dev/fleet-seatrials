#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests where the coop runs each tenant's pigeons (#83): beside a deployment the
# operator renders the coop's pigeons_namespaces (tacplus-dev/operator#47, coop
# 0.2's map, tacplus-dev/coop#17) from the tenants it grants the coop's pigeons
# Roles to, so services/coop.yaml names no namespace of its own and generate
# refuses one that does. It renders the fleet with the operator on a copy of
# deploy/bootstrap (as deploy/trust-domain_test.sh does) and requires kernel's
# rendered coop config to map exactly /tenants/alpha to tac-seatrials-741kqltx
# and /tenants/beta to tac-seatrials-ewqybj38 (operator.yaml's tids, the
# namespaces deploy/namespaces.sh lists), with no pigeons_namespace of the
# fleet's own and coop.yaml's mode beside it. Needs
# bash, yq, jq and the operator (bin/schematic-operator, by ci/tools.sh;
# OPERATOR overrides it).
#
#   deploy/pigeons-namespaces_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
operator=${OPERATOR:-$here/bin/schematic-operator}
want='{"/tenants/alpha":"tac-seatrials-741kqltx","/tenants/beta":"tac-seatrials-ewqybj38"}'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }

if [ ! -x "$operator" ]; then
  echo "FAIL the operator $operator is built (ci/tools.sh builds it into bin/)"; exit 1
fi

# render DIR: a root CA into DIR/crypto.yaml, then generate the fleet from the
# config directory DIR, its charts in DIR/charts.
render() {
  (cd "$1" && export SCHEMATIC_OPERATOR_DIR="$1" SCHEMATIC_LOCAL_IMAGES=registry.invalid/seatrials &&
    "$operator" init ca && "$operator" generate --output "$1/charts") > "$1/generate.log" 2>&1
}
errors() { grep -m3 -i 'error' "$1/generate.log" || tail -3 "$1/generate.log"; }
fresh() {
  rm -rf "$work/bootstrap" && cp -R "$here/deploy/bootstrap" "$work/bootstrap"
  rm -rf "$work/bootstrap/configs" "$work/bootstrap/crypto.yaml" "$work/bootstrap/ca.pem"
}
# coop DIR: the coop's config in kernel's first rendered node config, as JSON
# (the holder's coop_config, in either of protojson's spellings).
coop() {
  local kernel
  kernel=$(ls "$1"/configs/bootstrap*.yaml 2>/dev/null | head -1)
  [ -n "$kernel" ] || return 1
  yq -o=json '.' "$kernel" | jq -c '[.. | objects | (.coop_config // .coopConfig // empty)] | first // empty'
}

fresh
if ! render "$work/bootstrap"; then
  fail "generate renders the fleet: $(errors "$work/bootstrap")"
else
  cfg=$(coop "$work/bootstrap")
  if [ -z "$cfg" ]; then
    fail "kernel's rendered config carries the coop's config"
  else
    got=$(jq -cS '.pigeons_namespaces // .pigeonsNamespaces // {}' <<<"$cfg")
    [ "$got" = "$want" ] && ok "the coop's pigeons_namespaces: $got" \
      || fail "the coop's pigeons_namespaces: [$got], want [$want]"
    # pigeons_namespace is unused once the map has entries; the holder's
    # defaults fill it with coop's own default, pigeons, and nothing else may.
    single=$(jq -r '.pigeons_namespace // .pigeonsNamespace // ""' <<<"$cfg")
    case $single in
      '' | pigeons) ok "the coop's config names no pigeons_namespace of the fleet's own: [$single]" ;;
      *) fail "the coop's config names no pigeons_namespace of the fleet's own: [$single]" ;;
    esac
    # The rendered mode is the enum's short form (jobs for MODE_JOBS).
    mode=$(yq '.mode' "$here/deploy/bootstrap/services/coop.yaml")
    got=$(jq -r '.mode' <<<"$cfg")
    [ "$(tr '[:upper:]' '[:lower:]' <<<"${got#MODE_}")" = "$(tr '[:upper:]' '[:lower:]' <<<"${mode#MODE_}")" ] \
      && ok "coop.yaml's mode reaches the coop: $mode ($got)" \
      || fail "coop.yaml's mode reaches the coop: [$got], want [$mode]"
  fi
fi

# A namespace of coop.yaml's own beside the deployment would be stale: refused.
for line in 'pigeons_namespace: schematic-pigeons' 'pigeons_namespaces: {/tenants/alpha: somewhere}'; do
  fresh
  printf '%s\n' "$line" >> "$work/bootstrap/services/coop.yaml"
  field=${line%%:*}
  if render "$work/bootstrap"; then
    fail "a services/coop.yaml setting $field is refused"
  elif grep -q "remove $field from services/coop.yaml" "$work/bootstrap/generate.log"; then
    ok "a services/coop.yaml setting $field is refused"
  else
    fail "a services/coop.yaml setting $field is refused, saying so: $(errors "$work/bootstrap")"
  fi
done

[ "$failures" = 0 ] && echo "pigeons namespaces tests passed" || { echo "pigeons namespaces tests failed: $failures"; exit 1; }
