#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/unattachable-volumes.sh against a stub kubectl: a pod that never started and whose disk type its node
# cannot attach loses its claims and is deleted; a pod that has run, a pod with another attach failure and a pod
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
  jq -n --arg p "$1" --arg m "$2" '{reason: "FailedAttachVolume", message: $m, involvedObject: {kind: "Pod", name: $p}}'
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
[[ "$out" == *"eventbus0-x is gone since"* ]] && ok "a pod gone since is skipped" || fail "a pod gone: [$out]"
! grep -q 'other-0' "$work/log" && ok "another attach failure is not this one" || fail "another attach failure: $(cat "$work/log")"
run "$work/none.json"
[ "$rc" = 0 ] && [ -z "$(deleted)" ] && [[ "$out" == *"none in $platform that its node cannot attach"* ]] &&
  ok "with no such event nothing is deleted" || fail "no event: rc=$rc [$(deleted)] [$out]"
run "$work/events.json" STUB_CONTEXT=gke_tacplus-dev_us-central1-a_other
[ "$rc" != 0 ] && [ -z "$(deleted)" ] && [[ "$out" == *"not gke_tacplus-dev_us-central1-a_dev"* ]] &&
  ok "another cluster's context is refused" || fail "another context: rc=$rc [$out]"

[ "$failures" -eq 0 ] && echo "all unattachable-volumes tests passed" || { echo "$failures failed"; exit 1; }
