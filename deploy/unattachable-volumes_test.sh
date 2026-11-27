#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/unattachable-volumes.sh against a stub kubectl: a pod that never started and whose disk type its node
# cannot attach, or whose claim was never provisioned, loses its claims and is deleted; a pod that has run, a pod with another attach failure and a pod
# that is gone are left alone; with no such event nothing is deleted; another cluster's context is refused.
#
#   deploy/unattachable-volumes_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
platform=$("$here/namespaces.sh" platform)
mkdir -p "$work/bin" "$work/pods"
cat > "$work/bin/kubectl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "\$STUB_LOG"
case "\$*" in
  "config current-context") echo "\${STUB_CONTEXT:-gke_tacplus-dev_us-central1-a_dev}" ;;
  "get events -n $platform --field-selector reason=FailedAttachVolume -o json") cat "\$STUB_EVENTS" ;;
  "get events -n $platform --field-selector reason=ProvisioningFailed -o json") cat "\${STUB_CLAIM_EVENTS:-$work/none.json}" ;;
  "get persistentvolumeclaims -n $platform -o json") cat "$work/claims.json" ;;
  "get pods -n $platform -o json") (cd "$work/pods" && jq -s '{items: .}' *) ;;
  "get pod -n $platform "*" -o json") [ -f "$work/pods/\$5" ] || exit 1; cat "$work/pods/\$5" ;;
  "delete persistentvolumeclaim -n $platform "*" --wait=false"|"delete pod -n $platform "*" --wait=false") ;;
  *) echo "unexpected kubectl \$*" >&2; exit 3 ;;
esac
STUB
chmod +x "$work/bin/kubectl"

failures=0
ok() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
event() { # POD MESSAGE
  jq -n --arg p "$1" --arg m "$2" '{reason: "FailedAttachVolume", message: $m, involvedObject: {kind: "Pod", name: $p, uid: ("uid-" + $p)}}'
}
cannot='AttachVolume.Attach failed for volume "pvc-1" : rpc error: code = InvalidArgument desc = Failed to Attach: failed cloud service attach disk call: googleapi: Error 400: pd-balanced disk type cannot be used by c4a-standard-2 machine type., badRequest'
# kernel-0 never started (its init container waits); stratum-0 has run before; eventbus0-x is gone since.
jq -n '{status: {phase: "Pending", initContainerStatuses: [{name: "config-select", restartCount: 0, state: {waiting: {reason: "PodInitializing"}}}],
         containerStatuses: [{name: "kernel", restartCount: 0, state: {waiting: {reason: "PodInitializing"}}}]},
        spec: {volumes: [{name: "data", persistentVolumeClaim: {claimName: "data-kernel-0"}}, {name: "config", configMap: {name: "c"}}]}}' > "$work/pods/kernel-0"
jq -n '{status: {phase: "Pending", containerStatuses: [{name: "stratum", restartCount: 2, state: {waiting: {reason: "ContainerCreating"}}, lastState: {terminated: {exitCode: 1}}}]},
        spec: {volumes: [{name: "data", persistentVolumeClaim: {claimName: "data-stratum-0"}}]}}' > "$work/pods/stratum-0"
jq -n '{status: {phase: "Pending", containerStatuses: []}, spec: {volumes: [{name: "data", persistentVolumeClaim: {claimName: "data-other-0"}}]}}' > "$work/pods/other-0"
{ event kernel-0 "$cannot"; event kernel-0 "$cannot"; event stratum-0 "$cannot"; event eventbus0-x "$cannot"
  event other-0 'AttachVolume.Attach failed for volume "pvc-9" : rpc error: code = Unavailable desc = try again'; } | jq -s '{items: .}' > "$work/events.json"
echo '{"items": []}' > "$work/none.json"
# Claims: kernel's and stratum's bound (to disks their nodes cannot attach), other-0's bound; eventbus's and
# gateway's Pending. The provisioner refused eventbus's (below the disk type's minimum size); gateway's is only new.
for p in kernel-0 stratum-0 other-0; do jq --arg n "$p" '.metadata = {name: $n, uid: ("uid-" + $n)}' "$work/pods/$p" > "$work/pods/$p.new" && mv "$work/pods/$p.new" "$work/pods/$p"; done
jq -n '{metadata: {name: "eventbus0-y", uid: "uid-eventbus0-y"}, status: {phase: "Pending", containerStatuses: []},
        spec: {volumes: [{name: "data", persistentVolumeClaim: {claimName: "eventbus0-data"}}]}}' > "$work/pods/eventbus0-y"
jq -n '{metadata: {name: "gateway0-z", uid: "uid-gateway0-z"}, status: {phase: "Pending", containerStatuses: []},
        spec: {volumes: [{name: "data", persistentVolumeClaim: {claimName: "gateway0-data"}}]}}' > "$work/pods/gateway0-z"
jq -n '{items: [{metadata: {name: "data-kernel-0", uid: "uid-data-kernel-0"}, status: {phase: "Bound"}}, {metadata: {name: "data-stratum-0", uid: "uid-data-stratum-0"}, status: {phase: "Bound"}},
                {metadata: {name: "data-other-0", uid: "uid-data-other-0"}, status: {phase: "Bound"}},
                {metadata: {name: "eventbus0-data", uid: "uid-eventbus0-data"}, status: {phase: "Pending"}}, {metadata: {name: "gateway0-data", uid: "uid-gateway0-data"}, status: {phase: "Pending"}}]}' > "$work/claims.json"
jq -n '{items: [{reason: "ProvisioningFailed", message: "failed to provision volume with StorageClass \"hyperdisk-balanced\": rpc error: code = InvalidArgument desc = disk size 2 GiB is below the minimum",
                 involvedObject: {kind: "PersistentVolumeClaim", name: "eventbus0-data", uid: "uid-eventbus0-data"}},
                {reason: "ProvisioningFailed", message: "an old refusal", involvedObject: {kind: "PersistentVolumeClaim", name: "data-other-0", uid: "uid-data-other-0"}}]}' > "$work/claim-events.json"

# run EVENTS [VAR=VALUE...]: the script's output in $out, its exit in $rc, kubectl's calls in $work/log.
run() {
  local events=$1; shift
  : > "$work/log"
  out=$(env PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_EVENTS="$events" "$@" "$here/unattachable-volumes.sh" 2>&1)
  rc=$?
}
deleted() { grep '^delete ' "$work/log" | sed "s/ -n $platform / /; s/ --wait=false//" | tr '\n' ';'; }

run "$work/events.json"
[ "$rc" = 0 ] && [ "$(deleted)" = "delete persistentvolumeclaim data-kernel-0;delete pod kernel-0;" ] &&
  ok "a pod that never started loses its claim and is deleted; nothing else is" || fail "the deletes: [$(deleted)] rc=$rc out=[$out]"
[[ "$out" == *"kernel-0 has never started: its claim data-kernel-0 is on a disk type its node cannot attach"* ]] &&
  ok "it says which claim and why" || fail "the reason: [$out]"
[[ "$out" == *"stratum-0 has run: its volume is left as it is"* ]] && ok "a pod that has run is left, saying so" || fail "a pod that has run: [$out]"
! grep -q 'eventbus0-x' "$work/log" && ok "a pod gone since is not looked for" || fail "a pod gone: $(cat "$work/log")"
! grep -q 'other-0' "$work/log" && ok "another attach failure is not this one" || fail "another attach failure: $(cat "$work/log")"
# A claim never provisioned: still Pending, and refused by the provisioner. A claim that is only new (Pending, no
# refusal) and a bound claim with an old refusal are left.
run "$work/none.json" STUB_CLAIM_EVENTS="$work/claim-events.json"
[ "$rc" = 0 ] && [ "$(deleted)" = "delete persistentvolumeclaim eventbus0-data;delete pod eventbus0-y;" ] &&
  ok "a pod whose claim was never provisioned loses the claim and is deleted; a new claim and a bound one are left" ||
  fail "never provisioned: [$(deleted)] rc=$rc out=[$out]"
[[ "$out" == *"eventbus0-y has never started: its claim eventbus0-data was never provisioned (no disk)"* ]] &&
  ok "it says the claim was never provisioned" || fail "the reason: [$out]"
run "$work/events.json" STUB_CLAIM_EVENTS="$work/claim-events.json"
[ "$rc" = 0 ] && [ "$(deleted)" = "delete persistentvolumeclaim eventbus0-data;delete pod eventbus0-y;delete persistentvolumeclaim data-kernel-0;delete pod kernel-0;" ] &&
  ok "both kinds in one run" || fail "both kinds: [$(deleted)] rc=$rc out=[$out]"
# What this step made again has its predecessor's name, and the predecessor's events are still there: a claim and a
# pod with another uid than the events name are left.
jq '.items |= map(.involvedObject.uid = "uid-of-the-one-before")' "$work/events.json" > "$work/events-before.json"
jq '.items |= map(.involvedObject.uid = "uid-of-the-one-before")' "$work/claim-events.json" > "$work/claim-events-before.json"
run "$work/events-before.json" STUB_CLAIM_EVENTS="$work/claim-events-before.json"
[ "$rc" = 0 ] && [ -z "$(deleted)" ] && ok "a pod and a claim made again are not deleted for their predecessors' events" ||
  fail "predecessors' events: rc=$rc [$(deleted)] [$out]"
run "$work/none.json"
[ "$rc" = 0 ] && [ -z "$(deleted)" ] && [[ "$out" == *"none in $platform that cannot be had"* ]] &&
  ok "with no such event nothing is deleted" || fail "no event: rc=$rc [$(deleted)] [$out]"
run "$work/events.json" STUB_CONTEXT=gke_tacplus-dev_us-central1-a_other
[ "$rc" != 0 ] && [ -z "$(deleted)" ] && [[ "$out" == *"not gke_tacplus-dev_us-central1-a_dev"* ]] &&
  ok "another cluster's context is refused" || fail "another context: rc=$rc [$out]"

[ "$failures" -eq 0 ] && echo "all unattachable-volumes tests passed" || { echo "$failures failed"; exit 1; }
