#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the fleet's SPIFFE trust domain (#16): it is the fleet's, tacplus.dev
# (Jody, 2026-11-26), set in one place, operator.yaml's spiffe_prefix, which
# kernel and every service config take it from (operator#14). It renders the
# fleet with the operator on a copy of deploy/bootstrap (`init ca` for a root
# CA of its own, as deploy/init-secrets.sh does, then `generate`) and requires every rendered spiffe_trust_domain and
# spiffe_prefix to be tacplus.dev, kernel's among them (kernel mints every
# subject as spiffe://<its trust domain>/...), and no spiffe://local.dev
# anywhere in the render. A services/kernel.yaml naming another domain is
# refused. Needs bash, yq and the operator (bin/schematic-operator, by
# ci/tools.sh; OPERATOR overrides it).
#
#   deploy/trust-domain_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
operator=${OPERATOR:-$here/bin/schematic-operator}
want=tacplus.dev
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }

if [ ! -x "$operator" ]; then
  echo "FAIL the operator $operator is built (ci/tools.sh builds it into bin/)"; exit 1
fi
[ "$(yq '.spiffe_prefix // ""' "$here/deploy/bootstrap/operator.yaml")" = "$want" ] \
  && ok "operator.yaml's spiffe_prefix is $want" || fail "operator.yaml's spiffe_prefix is $want"
[ "$(yq '.spiffe_trust_domain // ""' "$here/deploy/bootstrap/services/kernel.yaml")" = "" ] \
  && ok "services/kernel.yaml sets no trust domain of its own" \
  || fail "services/kernel.yaml sets no trust domain of its own: operator.yaml's spiffe_prefix is the one place"

# render DIR: a root CA into DIR/crypto.yaml, then generate the fleet from the
# config directory DIR, its charts in DIR/charts.
render() {
  (cd "$1" && export SCHEMATIC_OPERATOR_DIR="$1" SCHEMATIC_LOCAL_IMAGES=registry.invalid/seatrials &&
    "$operator" init ca && "$operator" generate --output "$1/charts") > "$1/generate.log" 2>&1
}
# errors DIR: the error lines of DIR's render.
errors() { grep -m3 -i 'error' "$1/generate.log" || tail -3 "$1/generate.log"; }
fresh() {
  rm -rf "$work/bootstrap" && cp -R "$here/deploy/bootstrap" "$work/bootstrap"
  rm -rf "$work/bootstrap/configs" "$work/bootstrap/crypto.yaml" "$work/bootstrap/ca.pem"
}

fresh
if ! render "$work/bootstrap"; then
  fail "generate renders the fleet: $(errors "$work/bootstrap")"
else
  out=$work/bootstrap
  # Every trust-domain setting in the render, YAML or JSON, in configs/ and the charts.
  found=$(grep -rhoE "[\"']?(spiffe_trust_domain|spiffeTrustDomain|spiffe_prefix|spiffePrefix)[\"']?: *[\"']?[^\"', }]*" \
    "$out/configs" "$out/charts" | sed -E "s/^[\"']?([A-Za-z_]+)[\"']?: *[\"']?/\1=/" | sort | uniq -c)
  if [ -z "$found" ]; then
    fail "the render names a trust domain"
  elif grep -vqE "=$want\$" <<<"$found"; then
    fail "every rendered trust domain is $want:
$found"
  else
    ok "every rendered trust domain is $want: $(tr -s ' \n' ' ' <<<"$found")"
  fi
  # Kernel's node configs are configs/bootstrap<i>.yaml.
  kernel=$(grep -lE "(spiffe_trust_domain|spiffeTrustDomain): *[\"']?$want" "$out"/configs/bootstrap*.yaml 2>/dev/null | head -1)
  [ -n "$kernel" ] && ok "kernel mints as spiffe://$want/... (${kernel#"$out"/})" \
    || fail "kernel's rendered config has spiffe_trust_domain $want"
  if stray=$(grep -rlF 'spiffe://local.dev' "$out/configs" "$out/charts"); then
    fail "no spiffe://local.dev in the render: $stray"
  else
    ok "no spiffe://local.dev in the render"
  fi
fi

fresh
printf 'spiffe_trust_domain: local.dev\n' >> "$work/bootstrap/services/kernel.yaml"
if render "$work/bootstrap"; then
  fail "a services/kernel.yaml trust domain other than spiffe_prefix is refused"
elif grep -q 'differ' "$work/bootstrap/generate.log"; then
  ok "a services/kernel.yaml trust domain other than spiffe_prefix is refused"
else
  fail "a services/kernel.yaml trust domain other than spiffe_prefix is refused, saying they differ: $(errors "$work/bootstrap")"
fi

[ "$failures" = 0 ] && echo "all trust-domain tests passed" || { echo "$failures trust-domain test(s) failed"; exit 1; }
