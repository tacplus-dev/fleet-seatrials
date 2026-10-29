#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests images/build.sh's WAIT=1 against stub git and gcloud: the builds it
# submits (asynchronously, in parallel) are waited for, and it fails, naming
# the service, if any build does not succeed, so the deploy pipeline's images
# stage is green only when every image exists. Without WAIT it returns after
# submitting, as before.
#
#   images/build_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse"*) echo 0123456789ab ;;
  "clone -q "*) mkdir -p "$4"; echo "language: go" > "$4/tacplus.yaml" ;;
  *"checkout -q"*) ;;
  *) echo "unexpected git $*" >&2; exit 3 ;;
esac
STUB
cat > "$work/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  "artifacts docker tags list "*) ;;   # nothing built yet
  "builds submit "*)
    for a in "$@"; do case "$a" in --substitutions=*|_REGISTRY=*) s=$a ;; esac; done
    svc=${s#*_SERVICE=}; svc=${svc%%,*}; echo "build-$svc" ;;
  "builds describe "*)
    id=$3; [ "$id" = "build-${STUB_FAIL:-none}" ] && echo FAILURE || echo SUCCESS ;;
  *) echo "unexpected gcloud $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$work/bin/"*

failures=0
run() { # NAME WANT(pass|fail) [VAR=VALUE...]
  local name=$1 want=$2 out status; shift 2
  : > "$work/log"
  out=$(env PATH="$work/bin:$PATH" STUB_LOG="$work/log" WAIT_INTERVAL=0 "$@" "$here/build.sh" changed 2>&1)
  status=$?
  case "$want" in
    pass) [ "$status" -eq 0 ] || { echo "FAIL $name: status $status; out=[$out]"; failures=$((failures + 1)); return 1; } ;;
    fail) [ "$status" -ne 0 ] || { echo "FAIL $name: passed; out=[$out]"; failures=$((failures + 1)); return 1; } ;;
  esac
  echo "ok   $name"
}
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; failures=$((failures + 1)); fi; }
services=$(grep -c '^    - name: ' "$here/../fleet.lock")

run "without WAIT it returns after submitting" pass &&
  check "nothing waited for" "$(grep -c '^builds describe' "$work/log")" 0
run "WAIT=1: every build succeeds" pass WAIT=1 &&
  check "every build waited for" "$(grep '^builds describe' "$work/log" | sort -u | wc -l | tr -d ' ')" "$services"
run "WAIT=1: one build fails" fail WAIT=1 STUB_FAIL=gateway
out=$(env PATH="$work/bin:$PATH" STUB_LOG="$work/log" WAIT_INTERVAL=0 WAIT=1 STUB_FAIL=gateway "$here/build.sh" changed 2>&1)
[[ "$out" == *gateway*FAILURE* ]] && echo "ok   the failed build is named" ||
  { echo "FAIL the failed build is not named: [$out]"; failures=$((failures + 1)); }

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
