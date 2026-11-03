#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The functional end-to-end suite, the deploy pipeline's test stage (#17): every
# platform capability SeaBeam relies on, run against the deployed fleet after
# every deploy. SeaBeam starts once it is green on the `tacplus` cluster (Jody,
# 2026-10-31: "I just mean everything works").
#
# Each item of the manifest (deploy/e2e.yaml) is a named test with a clear pass
# or fail. An item that cannot run yet names the open issues it waits on and is
# reported as WAITING, never left out: either it has no `run` yet, or its
# `ready` check (run first) fails, and the report says why. The report is the
# evidence: on stdout, and as JUnit XML in E2E_JUNIT (GitLab's test report),
# where a waiting item is a skipped testcase.
#
#   deploy/e2e.sh          # every item; fails if any that ran failed
#   deploy/e2e.sh --list   # the items' names, after checking the manifest; runs nothing
#
# Each `run` and `ready` is a bash script run at the checkout's root, with
# E2E_TIMEOUT seconds (600) each. They see the job's environment: SEATRIALS_HOST,
# E2E_CONFIGS (the configs/ directory `schematic-operator generate` wrote), kubectl's
# context. Like every check here they print no secret. Exit status: 0 passed (some
# may wait), 1 an item failed, 2 the manifest is wrong.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
manifest=${E2E_MANIFEST:-$here/deploy/e2e.yaml}
junit=${E2E_JUNIT:-}
limit=${E2E_TIMEOUT:-600}
case "${1:-}" in
  ""|--list) ;;
  *) echo "usage: $0 [--list]" >&2; exit 2 ;;
esac

items=$(yq -o=json 'explode(.) | .tests // []' "$manifest") || { echo "e2e: $manifest does not parse" >&2; exit 2; }
errors=$(jq -r '
  (map(.name) | group_by(.) | map(select(length > 1) | "\(.[0]): named twice")[]),
  (.[] | (.name // "(an item with no name)") as $n
    | (select((.what // "") == "") | "\($n): no what (what the item proves)"),
      (select((.run // "") == "" and ((.waits_on // []) | length) == 0) | "\($n): neither run nor waits_on"),
      (select((.ready // "") != "" and ((.run // "") == "" or ((.waits_on // []) | length) == 0))
        | "\($n): ready needs both run and waits_on"),
      ((.waits_on // [])[] | select(test("^(#[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)$") | not)
        | "\($n): waits_on [\(.)] is not #N or owner/repo#N"))' <<<"$items")
if [ -n "$errors" ]; then
  sed "s|^|e2e: ${manifest#"$here"/}: |" <<<"$errors" >&2; exit 2
fi
if [ "${1:-}" = --list ]; then jq -r '.[].name' <<<"$items"; exit 0; fi

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' | tr -d '\000-\010\013\014\016-\037'; }
# script SCRIPT: runs it at the checkout's root, its output in $out, its status returned.
script() {
  local status
  out=$(cd "$here" && timeout "$limit" bash -c "$1" 2>&1 </dev/null); status=$?
  [ "$status" != 124 ] || out+=${out:+$'\n'}"timed out after ${limit}s"
  return "$status"
}
indent() { [ -z "$1" ] || sed 's/^/         /' <<<"$1"; }

passed=0 failed=0 waiting=0 cases=""
n=$(jq length <<<"$items")
for ((i = 0; i < n; i++)); do
  item=$(jq -c ".[$i]" <<<"$items")
  name=$(jq -r .name <<<"$item"); what=$(jq -r .what <<<"$item")
  run=$(jq -r '.run // ""' <<<"$item"); ready=$(jq -r '.ready // ""' <<<"$item")
  waits=$(jq -r '(.waits_on // []) | join(", ")' <<<"$item")
  started=$(date +%s)
  reason=""
  if [ -n "$waits" ]; then
    reason="waits on $waits"
    if [ -n "$ready" ]; then
      if script "$ready"; then reason=""
      else [ -z "$out" ] || reason+=" ($(head -n1 <<<"$out"))"; fi
    fi
  fi
  if [ -n "$reason" ]; then
    echo "WAITING  $name: $reason — $what"
    waiting=$((waiting + 1))
    cases+="<testcase classname=\"e2e\" name=\"$(xml <<<"$name")\" time=\"0\"><skipped message=\"$(xml <<<"$reason")\"/></testcase>"
    continue
  fi
  if script "$run"; then
    echo "PASS     $name — $what"; indent "$out"
    passed=$((passed + 1))
    cases+="<testcase classname=\"e2e\" name=\"$(xml <<<"$name")\" time=\"$(($(date +%s) - started))\"><system-out>$(xml <<<"$out")</system-out></testcase>"
  else
    echo "FAIL     $name — $what"; indent "$out"
    failed=$((failed + 1))
    cases+="<testcase classname=\"e2e\" name=\"$(xml <<<"$name")\" time=\"$(($(date +%s) - started))\"><failure message=\"$(xml <<<"$what")\">$(xml <<<"$out")</failure></testcase>"
  fi
done

echo "e2e: $passed passed, $failed failed, $waiting waiting"
if [ -n "$junit" ]; then
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites><testsuite name="e2e" tests="%d" failures="%d" skipped="%d">%s</testsuite></testsuites>\n' \
    "$n" "$failed" "$waiting" "$cases" > "$junit"
fi
[ "$failed" = 0 ]
