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

# The platforms setting in images/pins.yaml: each build is told which platforms
# to build (_PLATFORMS, sorted), and the fingerprint covers them, so an
# arm64-only image is never taken for a multi-arch one. Run against a copy of
# the tree whose pins.yaml says PLATFORMS_LINE.
platforms_run() { # PLATFORMS_LINE ARGS... -> build.sh's output; the gcloud calls in $work/log
  local tree=$work/tree; rm -rf "$tree"
  mkdir -p "$tree/images" "$tree/build/proto"
  cp "$here/build.sh" "$here/service.cloudbuild.yaml" "$tree/images/"
  cp "$here/../fleet.lock" "$tree/"
  grep -v '^platforms:' "$here/pins.yaml" > "$tree/images/pins.yaml"
  [ -z "$1" ] || echo "$1" >> "$tree/images/pins.yaml"
  shift
  : > "$work/log"
  env PATH="$work/bin:$PATH" STUB_LOG="$work/log" "$tree/images/build.sh" "$@" 2>&1
}
substitution() { # NAME -> its value in the first build submitted
  grep -m1 '^builds submit ' "$work/log" | tr ',' '\n' | sed -n "s/^.*$1=//p"
}
check "pins.yaml builds arm64 only" "$(grep '^platforms:' "$here/pins.yaml")" "platforms: [arm64]"
platforms_run "platforms: [arm64]" kernel > /dev/null
check "[arm64]: _PLATFORMS" "$(substitution _PLATFORMS)" "arm64"
fp_arm64=$(substitution _FINGERPRINT)
platforms_run "platforms: [arm64, amd64]" kernel > /dev/null
check "[arm64, amd64]: _PLATFORMS, sorted" "$(substitution _PLATFORMS)" "amd64 arm64"
fp_both=$(substitution _FINGERPRINT)
platforms_run "platforms: [amd64,arm64]" kernel > /dev/null
check "[amd64,arm64]: the same build" "$(substitution _PLATFORMS) $(substitution _FINGERPRINT)" "amd64 arm64 $fp_both"
[ -n "$fp_arm64" ] && [ "$fp_arm64" != "$fp_both" ] && echo "ok   the fingerprint covers the platforms" ||
  { echo "FAIL the fingerprint ignores the platforms: [$fp_arm64] [$fp_both]"; failures=$((failures + 1)); }
check "fingerprint prints the same hash" \
  "$(platforms_run "platforms: [arm64]" fingerprint | awk '$1 == "kernel" { print $2 }')" "$fp_arm64"
for bad in "platforms: [arm64, x86]" "platforms: []" ""; do
  out=$(platforms_run "$bad" kernel) &&
    { echo "FAIL [$bad] is accepted: [$out]"; failures=$((failures + 1)); } ||
    { [ ! -s "$work/log" ] && echo "ok   [$bad] is refused, nothing submitted" ||
      { echo "FAIL [$bad] submitted a build"; failures=$((failures + 1)); }; }
done

# Every submit stages its source and logs in the dedicated bucket: given the
# default bucket, gcloud lists the project's buckets to check it owns it, which
# the deploy account may not (docs/deploy-pipeline.md).
staging_checked() { # NAME -> checks every builds submit in $work/log
  local n bad
  n=$(grep -c '^builds submit ' "$work/log")
  bad=$(grep '^builds submit ' "$work/log" | while read -r line; do
    [[ "$line" == *"--gcs-source-staging-dir gs://jody1-328023-seatrials-build/source"* &&
       "$line" == *"--gcs-log-dir gs://jody1-328023-seatrials-build/logs"* ]] || echo "$line"
  done)
  if [ "$n" -gt 0 ] && [ -z "$bad" ]; then echo "ok   $1: $n submits stage in the build bucket"
  else echo "FAIL $1: $n submits, without the build bucket: [$bad]"; failures=$((failures + 1)); fi
}
platforms_run "platforms: [arm64]" tacplus > /dev/null
check "tacplus: both images submitted" "$(grep -c '^builds submit ' "$work/log")" 2
staging_checked "tacplus"
platforms_run "platforms: [arm64]" all > /dev/null
staging_checked "all services"

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
