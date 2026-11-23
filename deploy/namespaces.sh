#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The namespaces seatrials runs in, read from deploy/bootstrap/operator.yaml by
# the operator's own rule (operator pkg/deployment: PlatformNamespace,
# TenantTids), so the scripts that reach the cluster (deploy/secrets.sh,
# signin-secrets.sh, apply.sh, checks.sh) name the namespaces the render
# does (#4). With `deployment` set, the platform namespace is
# tac-<deployment> and each tenant's, people's (00000001) and restore's
# (00000002) is tac-<deployment>-<tid> (decisions/deployments-per-cluster-2026-10-26.md);
# without it, the one namespace is `namespace`, by default schematic. A config
# `schematic-operator generate` refuses (a tenant with no tid, another
# namespace beside a deployment) is refused here too.
#
#   deploy/namespaces.sh [OPERATOR_YAML]            # every namespace, the platform one first
#   deploy/namespaces.sh platform [OPERATOR_YAML]   # the platform namespace
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
what=all
case "${1:-}" in platform) what=$1; shift ;; esac
[ $# -le 1 ] && [[ "${1:-}" != -* ]] || { echo "usage: $0 [platform] [OPERATOR_YAML]" >&2; exit 2; }
config=${1:-$here/deploy/bootstrap/operator.yaml}
[ -f "$config" ] || { echo "usage: $0 [platform] [OPERATOR_YAML]: no file $config" >&2; exit 2; }

namespaces=$(yq -o=json '.' "$config" | jq -r '
  {people: "00000001", restore: "00000002"} as $reserved
  | (.deployment // "") as $d | (.namespace // "") as $ns
  | (.tenants // []) as $tenants | (.tenant_ids // {}) as $ids
  | if $d == "" then [if $ns == "" then "schematic" else $ns end]
    elif $ns != "" and $ns != "schematic" and $ns != "tac-\($d)" then
      error("namespace \($ns): a deployment'"'"'s namespace is tac-\($d); leave namespace unset")
    elif any($tenants[]; $reserved[.] == null and $ids[.] == null) then
      error("tenant \"\(first($tenants[] | select($reserved[.] == null and $ids[.] == null)))\" has no tid: tenant_ids must give it one (its namespace is tac-\($d)-<tid>)")
    else ["tac-\($d)"] + ([($tenants[] | $ids[.] // empty), $reserved[]] | unique | map("tac-\($d)-\(.)"))
    end
  | .[]') || { echo "$config: refused (schematic-operator generate refuses it too)" >&2; exit 1; }

case "$what" in
  all) echo "$namespaces" ;;
  platform) head -n1 <<<"$namespaces" ;;
esac
