#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/e2e.sh, the functional end-to-end suite's runner, on manifests
# of stub tests: every item is reported by name as passed, failed or waiting
# (with the issues it waits on), never left out; one failure fails the suite
# and the rest still run; an item that neither runs nor waits, a malformed
# issue reference or a name used twice is a manifest error; an item that waits
# runs once its `ready` check passes; the JUnit report holds one testcase per
# item. Then the repository's own manifest, deploy/e2e.yaml: well formed, and
# naming every capability the SeaBeam gate needs (#17).
#
#   deploy/e2e_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
# run NAME WANT(pass|fail|error) MANIFEST EXPECT... : each EXPECT must be in the output.
run() {
  local name=$1 want=$2 manifest=$3 out status e; shift 3
  out=$(E2E_MANIFEST=$manifest E2E_JUNIT=$work/junit.xml "$here/e2e.sh" 2>&1)
  status=$?
  case $want in
    pass) [ "$status" = 0 ] ;; fail) [ "$status" = 1 ] ;; error) [ "$status" = 2 ] ;;
  esac || { echo "FAIL $name: status=$status, want $want; out=[$out]"; failures=$((failures + 1)); return; }
  for e in "$@"; do
    [[ "$out" == *"$e"* ]] || { echo "FAIL $name: no [$e] in out=[$out]"; failures=$((failures + 1)); return; }
  done
  echo "ok   $name"
}
# junit NAME JQ-FILTER: the JUnit report of the last run, as JSON (yq), passes the filter.
junit() {
  if [ "$(yq -p=xml -o=json '.' "$work/junit.xml" | jq "$2")" = true ]; then echo "ok   $1"
  else echo "FAIL $1: $(cat "$work/junit.xml")"; failures=$((failures + 1)); fi
}

cat > "$work/good.yaml" <<'EOF'
tests:
  - name: platform/up
    what: the stub passes
    run: echo all fine
  - name: records/get
    what: waits on the client
    waits_on: ["#14"]
  - name: tenants/cross-tenant-s2s
    what: waits on two issues, one elsewhere
    waits_on: ["#14", tacplus-dev/tacplus#258]
EOF
run "passed and waiting items, each by name" pass "$work/good.yaml" \
  "PASS     platform/up" "WAITING  records/get: waits on #14" \
  "WAITING  tenants/cross-tenant-s2s: waits on #14, tacplus-dev/tacplus#258" \
  "1 passed, 0 failed, 2 waiting"
run "a passing item's output is in the report" pass "$work/good.yaml" "         all fine"
junit "the JUnit report: one testcase per item, the waiting ones skipped" \
  '.testsuites.testsuite["+@tests"] == "3" and .testsuites.testsuite["+@skipped"] == "2"
   and ([.testsuites.testsuite.testcase[] | .["+@name"]] == ["platform/up", "records/get", "tenants/cross-tenant-s2s"])
   and (.testsuites.testsuite.testcase[1].skipped["+@message"] == "waits on #14")'

cat > "$work/fail.yaml" <<'EOF'
tests:
  - name: platform/broken
    what: fails, saying why
    run: echo "FAIL the gateway is down"; exit 1
  - name: platform/after
    what: still runs
    run: "true"
EOF
run "one failure fails the suite, and the next item still runs" fail "$work/fail.yaml" \
  "FAIL     platform/broken" "         FAIL the gateway is down" "PASS     platform/after" "1 passed, 1 failed, 0 waiting"
junit "the JUnit report: the failure with its output" \
  '.testsuites.testsuite["+@failures"] == "1" and (.testsuites.testsuite.testcase[0].failure["+content"] | test("the gateway is down"))'

cat > "$work/ready.yaml" <<'EOF'
tests:
  - name: signin/ready
    what: its issue is done here
    waits_on: ["#27"]
    ready: "true"
    run: echo signed in
  - name: signin/not-ready
    what: not yet
    waits_on: ["#27"]
    ready: echo "no TEST_IDP_SEED here"; false
    run: echo never; exit 1
EOF
run "an item whose ready check passes runs; one whose check fails waits, saying why" pass "$work/ready.yaml" \
  "PASS     signin/ready" "WAITING  signin/not-ready: waits on #27 (no TEST_IDP_SEED here)" "1 passed, 0 failed, 1 waiting"

cat > "$work/neither.yaml" <<'EOF'
tests:
  - name: records/get
    what: neither runs nor waits
EOF
run "an item that neither runs nor waits is a manifest error" error "$work/neither.yaml" "records/get: neither run nor waits_on"

cat > "$work/badref.yaml" <<'EOF'
tests:
  - name: records/get
    what: a bad reference
    waits_on: [the client]
EOF
run "a waits_on that is not an issue reference is a manifest error" error "$work/badref.yaml" \
  "records/get: waits_on [the client] is not #N or owner/repo#N"

cat > "$work/twice.yaml" <<'EOF'
tests:
  - name: platform/up
    what: one
    run: "true"
  - name: platform/up
    what: two
    run: "true"
EOF
run "a name used twice is a manifest error" error "$work/twice.yaml" "platform/up: named twice"

cat > "$work/nowhat.yaml" <<'EOF'
tests:
  - name: platform/up
    run: "true"
EOF
run "an item that does not say what it proves is a manifest error" error "$work/nowhat.yaml" "platform/up: no what"

# The repository's manifest: well formed (--list checks it and runs nothing),
# and every capability the SeaBeam gate names is an item (#17, Jody 2026-10-31
# and 2026-11-01).
out=$("$here/e2e.sh" --list 2>&1); status=$?
if [ "$status" != 0 ]; then echo "FAIL deploy/e2e.yaml is not well formed: $out"; failures=$((failures + 1))
else
  echo "ok   deploy/e2e.yaml is well formed"
  for want in platform/pods-ready platform/gateway-cert platform/kernel-jwks platform/routing-policy \
    signin/providers-listed signin/google-session signin/microsoft-session signin/oidc-session \
    tenants/create tenants/routing-by-route-field tenants/cross-tenant-user-refused tenants/cross-tenant-service-refused \
    rpcs/through-gateway rpcs/s2s \
    records/get records/insert-if-absent records/replace-if-unchanged records/apply-across-maps records/watch-resume \
    members/two-tenants streams/end-at-token-expiry redo/durability-levels kernel/restart-keeps-data trace/two-terminal; do
    grep -qx "$want" <<<"$out" || { echo "FAIL deploy/e2e.yaml has no item $want"; failures=$((failures + 1)); }
  done
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
