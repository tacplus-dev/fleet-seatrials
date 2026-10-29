#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# kubectl diff's external diff program (KUBECTL_EXTERNAL_DIFF, set by
# deploy/diff.sh): kubectl writes each object of the render, as it is live and
# as it would be after the apply, into two directories, one file per object
# named <group>.<version>.<Kind>.<namespace>.<name>, and calls this with both.
#
#   deploy/letsencrypt-guard.sh LIVE MERGED
#
# It prints the name of each object that differs and never its content (the
# render carries the fleet's Secrets and service configs, and the job log is
# not a place for them). The objects that touch letsencrypt are also written,
# one per line, to $LETSENCRYPT_GUARD_OUT: any object named for it (its
# Deployment, Service, ServiceAccount, ...) and any ConfigMap, Secret or
# ServiceAccount its pods mount or read, as the Deployment is live or will be.
# Letsencrypt is never restarted without Jody's explicit OK (its certificate
# orders are rate-limited), so deploy/diff.sh fails on any of them.
#
# Exit status as kubectl expects of a diff program: 0 no difference, 1 some.
set -euo pipefail
live=$1 merged=$2
out=${LETSENCRYPT_GUARD_OUT:-/dev/null}
: > "$out"

# What the letsencrypt pods read: "<Kind>.<namespace>.<name>" per line, from
# its Deployment on both sides (a reference dropped by the change counts too).
refs=$(
  for f in "$live"/*.Deployment.*letsencrypt* "$merged"/*.Deployment.*letsencrypt*; do
    [ -f "$f" ] || continue
    yq -o=json '.' "$f" | jq -r '
      .metadata.namespace as $ns | .spec.template.spec as $s
      | ([$s.serviceAccountName // empty | "ServiceAccount.\(.)"]
         + [$s | .. | objects | (.configMap?.name, .configMapRef?.name, .configMapKeyRef?.name)
            | strings | "ConfigMap.\(.)"]
         + [$s | .. | objects | (.secret?.secretName, .secret?.name, .secretRef?.name, .secretKeyRef?.name)
            | strings | "Secret.\(.)"])
      | .[] | sub("^(?<k>[A-Za-z]+)\\."; "\(.k).\($ns).")'
  done | sort -u
)

touches() { # object file name -> 0 when it is letsencrypt's or its pods read it
  local name=$1 ref
  [[ "$name" == *letsencrypt* ]] && return 0
  while IFS= read -r ref; do
    [ -n "$ref" ] && [[ "$name" == *".$ref" ]] && return 0
  done <<<"$refs"
  return 1
}

changed=0
for name in $( (ls -A "$live"; ls -A "$merged") | sort -u); do
  if [ -f "$live/$name" ] && [ -f "$merged/$name" ] && cmp -s "$live/$name" "$merged/$name"; then
    continue
  fi
  changed=1
  if [ ! -f "$live/$name" ]; then how=added; elif [ ! -f "$merged/$name" ]; then how=removed; else how=changed; fi
  if touches "$name"; then
    echo "$how: $name   <- letsencrypt"
    echo "$name" >> "$out"
  else
    echo "$how: $name"
  fi
done
exit "$changed"
