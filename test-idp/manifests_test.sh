#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the test IdP's pods (test-idp/keycloak.yaml, test-idp/admin-job.yaml) for
# a read-only root (#54, Trivy KSV-0014): every container, init containers too,
# runs with readOnlyRootFilesystem and no privilege escalation, and writes only
# to emptyDirs. Keycloak starts --optimized, on what its init containers built
# into the emptyDir on lib/quarkus (a plain start rebuilds into the image), so
# its build options are the build's only. Needs bash and yq. test-idp/local.sh
# runs the pod's steps on a real Keycloak.
#
#   test-idp/manifests_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
pod='.. | select(tag == "!!map" and has("containers"))'

for f in keycloak.yaml admin-job.yaml; do
  # Each container: NAME, whether its root is read-only, whether it may not escalate.
  while read -r c ro noesc; do
    [ "$ro" = true ] && [ "$noesc" = true ] && ok "$f $c: a read-only root, no privilege escalation" ||
      fail "$f $c: readOnlyRootFilesystem true [$ro], allowPrivilegeEscalation false [$noesc]"
  done < <(yq -N "$pod | (.containers + (.initContainers // []))[]
    | .name + \" \" + (.securityContext.readOnlyRootFilesystem == true | tostring)
      + \" \" + (.securityContext.allowPrivilegeEscalation == false | tostring)" "$here/$f")
  # Each writable mount, and the kind of the volume it mounts.
  while read -r c path kind; do
    [ "$kind" = emptyDir ] && ok "$f $c writes $path, an emptyDir" || fail "$f $c writes $path, a $kind, not an emptyDir"
  done < <(yq -N "$pod | .volumes as \$v | (.containers + (.initContainers // []))[] | .name as \$c
    | (.volumeMounts // [])[] | select(.readOnly != true) | .name as \$n
    | \$c + \" \" + .mountPath + \" \" + ([\$v[] | select(.name == \$n) | keys[] | select(. != \"name\")][0] // \"missing volume\")" "$here/$f")
done

dep='select(.kind == "Deployment") | .spec.template.spec'
# kd EXPR: EXPR on keycloak.yaml's Deployment (its other documents print nothing).
kd() { yq -N "$dep | $1" "$here/keycloak.yaml" | sed '/^$/d'; }
args=$(kd '.containers[] | select(.name == "keycloak") | .args | join(" ")')
[[ "$args " == "start "* && " $args " == *" --optimized "* ]] && ok "keycloak starts --optimized: $args" ||
  fail "keycloak's args are [$args], want start ... --optimized"
mount() { kd ".$1[] | select(.name == \"$2\") | .volumeMounts[] | select(.mountPath == \"$3\") | .name + \" \" + (.readOnly == true | tostring)"; }
copy=$(mount initContainers quarkus-copy /quarkus)
build=$(mount initContainers build /opt/keycloak/lib/quarkus)
run=$(mount containers keycloak /opt/keycloak/lib/quarkus)
[ -n "$copy" ] && [ "${copy% *}" = "${build% *}" ] && [ "$build" = "${run% *} false" ] && [ "$run" = "${run% *} true" ] &&
  ok "quarkus-copy fills the emptyDir ${copy% *}, build writes it on lib/quarkus, keycloak mounts it read-only" ||
  fail "lib/quarkus: quarkus-copy [$copy], build [$build], keycloak [$run]"
order=$(kd '[.initContainers[].name] | join(" ")')
[ "$order" = "quarkus-copy build" ] && ok "the init containers run quarkus-copy, then build" || fail "the init containers: [$order]"
image() { kd ".$1[] | select(.name == \"$2\") | .image"; }
[ "$(image initContainers quarkus-copy)" = "$(image containers keycloak)" ] && [ "$(image initContainers build)" = "$(image containers keycloak)" ] &&
  ok "the init containers run keycloak's image" || fail "the init containers' images are not keycloak's"
# The admin Job's kcadm, too: a pin moved in one file only would run two Keycloaks (#59).
kcadm=$(yq -N "$pod | .containers[] | select(.name == \"kcadm\") | .image" "$here/admin-job.yaml")
[ "$kcadm" = "$(image containers keycloak)" ] && ok "the admin Job's kcadm runs keycloak's image" ||
  fail "the admin Job's kcadm runs [$kcadm], keycloak [$(image containers keycloak)]"
# Keycloak's build-time options (keycloak.org, All configuration: the ones it
# marks build), set at run time, would be refused or ignored by --optimized.
buildopts='KC_DB|KC_HEALTH_ENABLED|KC_METRICS_ENABLED|KC_FEATURES|KC_FEATURES_DISABLED|KC_HTTP_RELATIVE_PATH|KC_TRANSACTION_XA_ENABLED|KC_CACHE_STACK'
at_run=$(kd '.containers[] | select(.name == "keycloak") | .env[].name' | grep -xE "$buildopts")
at_build=$(kd '.initContainers[] | select(.name == "build") | .env[].name' | grep -xE "$buildopts")
[ -z "$at_run" ] && [ -n "$at_build" ] && ok "the build options are the build's only: $(echo $at_build)" ||
  fail "build options at run time [$(echo $at_run)], at build [$(echo $at_build)]"

[ "$failed" = 0 ] && echo "manifest tests passed" || { echo "manifest tests failed"; exit 1; }
