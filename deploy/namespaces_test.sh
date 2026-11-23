#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/namespaces.sh against operator.yaml files: it names the
# namespaces the operator renders into by the operator's own rule
# (operator pkg/deployment: PlatformNamespace, TenantTids): tac-<deployment>
# and tac-<deployment>-<tid> for each tenant and the reserved people and
# restore when operator.yaml names a deployment, else its namespace, else
# schematic; and it refuses a config generate refuses. Needs bash, jq and yq.
#
#   deploy/namespaces_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
# run NAME WANT(pass|fail) EXPECT YAML [ARGS...]: EXPECT is the whole output on
# a pass, and in the error on a fail.
run() {
  local name=$1 want=$2 expect=$3 out status
  printf '%s\n' "$4" > "$work/operator.yaml"; shift 4
  out=$("$here/namespaces.sh" "$@" "$work/operator.yaml" 2>&1)
  status=$?
  if { [ "$want" = pass ] && { [ "$status" -ne 0 ] || [ "$out" != "$expect" ]; }; } ||
     { [ "$want" = fail ] && { [ "$status" -eq 0 ] || [[ "$out" != *"$expect"* ]]; }; }; then
    echo "FAIL $name: status=$status out=[$out]"; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}

seatrials='deployment: seatrials
tenants: [alpha, beta]
tenant_ids: {alpha: 741kqltx, beta: ewqybj38}'
run "a deployment: its platform namespace first, then each tenant's and people's and restore's" pass \
  "tac-seatrials
tac-seatrials-00000001
tac-seatrials-00000002
tac-seatrials-741kqltx
tac-seatrials-ewqybj38" "$seatrials"
run "platform: the platform namespace alone" pass tac-seatrials "$seatrials" platform
run "no deployment: the one legacy namespace" pass schematic 'tenants: [alpha, beta]'
run "no deployment, a namespace: that namespace" pass fleet 'namespace: fleet
tenants: [alpha]'
run "a deployment with namespace tac-<deployment>: the same" pass tac-seatrials "$seatrials
namespace: tac-seatrials" platform
run "a deployment with another namespace: refused" fail "leave namespace unset" "$seatrials
namespace: other"
run "a tenant without a tid: refused" fail 'tenant "beta" has no tid' 'deployment: seatrials
tenants: [alpha, beta]
tenant_ids: {alpha: 741kqltx}'
run "a reserved tenant listed needs no tid" pass "tac-seatrials
tac-seatrials-00000001
tac-seatrials-00000002" 'deployment: seatrials
tenants: [people]'
run "an unknown argument: refused" fail usage "$seatrials" nonsense
# The fleet's own: one platform namespace, named by the same rule.
out=$("$here/namespaces.sh" platform 2>&1) && [[ "$out" =~ ^(tac-[a-z0-9-]+|schematic)$ ]] &&
  echo "ok   the fleet's operator.yaml names its platform namespace ($out)" ||
  { echo "FAIL the fleet's operator.yaml: [$out]"; failures=$((failures + 1)); }
# Every kernel delegate's service-account matcher names one of the fleet's
# namespaces: a matcher left on another (schematic, before #4) would let a
# service account of that name there, on a shared cluster, take the delegate.
stray=$(yq -o=json '.delegates' "$here/bootstrap/services/kernel.yaml" |
  jq -r --arg ns "$("$here/namespaces.sh")" '($ns | split("\n")) as $ours | .[] | .name as $d
    | .kubernetes_service_accounts[]? | select(.kubernetes_namespace as $n | $ours | index($n) | not)
    | "\($d): \(.kubernetes_namespace)/\(.kubernetes_service_account)"')
[ -z "$stray" ] && echo "ok   every kernel.yaml delegate matcher is in the fleet's namespaces" ||
  { echo "FAIL kernel.yaml matchers outside the fleet's namespaces: $stray"; failures=$((failures + 1)); }

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
