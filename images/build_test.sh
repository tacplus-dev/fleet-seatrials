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
  # The fleet's Java and Rust services are themselves; every other one is Go.
  "clone -q "*) mkdir -p "$4"
    case "$3" in */kernel.git|*/eventbus.git|*/stratum.git) l=java ;; */gateway.git|*/oauth.git|*/llmproxy.git) l=rust ;; *) l=go ;; esac
    echo "language: $l" > "$4/tacplus.yaml" ;;
  *"checkout -q"*) ;;
  *) echo "unexpected git $*" >&2; exit 3 ;;
esac
STUB
cat > "$work/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  # Nothing built yet, but the build image tags STUB_BUILD_TAGS lists and the
  # service tags STUB_SERVICE_TAGS lists (every service is asked for them all).
  "artifacts docker tags list "*/ci/tacplus-build" "*) for t in ${STUB_BUILD_TAGS:-}; do echo "$t"; done ;;
  "artifacts docker tags list "*) for t in ${STUB_SERVICE_TAGS:-}; do echo "$t"; done ;;
  # The tacplus image just built, by digest; none with STUB_NO_DIGEST.
  "artifacts docker images describe "*/ci/tacplus:*)
    [ -n "${STUB_NO_DIGEST:-}" ] || echo "sha256:$(printf '%064d' 7)" ;;
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
  cp "$here/build.sh" "$here/service.cloudbuild.yaml" "$here/tacplus.cloudbuild.yaml" \
    "$here/tacplus-build.cloudbuild.yaml" "$here/tacplus-build.Dockerfile" "$tree/images/"
  cp "$here/../fleet.lock" "$tree/"
  grep -v '^platforms:' "$here/pins.yaml" > "$tree/images/pins.yaml"
  [ -z "$1" ] || echo "$1" >> "$tree/images/pins.yaml"
  shift
  : > "$work/log"
  env PATH="$work/bin:$PATH" STUB_LOG="$work/log" "$tree/images/build.sh" "$@" 2>&1
}
substitution() { # NAME -> its value in the first service build submitted
  grep -m1 '^builds submit .*service.cloudbuild.yaml' "$work/log" | tr ',' '\n' | sed -n "s/^.*$1=//p"
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
# the deploy account may not (docs/deploy-pipeline.md). And every build runs as
# seatrials-build, the one account the deploy account may act as, which pushes
# to the registry; the default Cloud Build account has no rights (#39,
# tacplus-dev/cloud#20).
staging_checked() { # NAME -> checks every builds submit in $work/log
  local n bad
  n=$(grep -c '^builds submit ' "$work/log")
  bad=$(grep '^builds submit ' "$work/log" | while read -r line; do
    [[ "$line" == *"--gcs-source-staging-dir gs://tacplus-dev-seatrials-build/source"* &&
       "$line" == *"--gcs-log-dir gs://tacplus-dev-seatrials-build/logs"* &&
       "$line" == *"--service-account projects/tacplus-dev/serviceAccounts/seatrials-build@tacplus-dev.iam.gserviceaccount.com"* ]] || echo "$line"
  done)
  if [ "$n" -gt 0 ] && [ -z "$bad" ]; then echo "ok   $1: $n submits stage in the build bucket, as seatrials-build"
  else echo "FAIL $1: $n submits, without the build bucket or seatrials-build: [$bad]"; failures=$((failures + 1)); fi
}
platforms_run "platforms: [arm64]" tacplus > /dev/null
check "tacplus: both images submitted" "$(grep -c '^builds submit ' "$work/log")" 2
staging_checked "tacplus"
platforms_run "platforms: [arm64]" all > /dev/null
staging_checked "all services"

# The build image every service step runs in is tagged by a fingerprint of its
# inputs: the tacplus and launcher commits, its Dockerfile and its Cloud Build
# config. A service build runs in that tag, and the build image is built first
# whenever the registry has no image with it; tagged by the tacplus commit
# alone, an image built before the launcher stage was reused forever (#33).
build_fp() { # ARGS... -> the build image's fingerprint, from `fingerprint`
  platforms_run "platforms: [arm64]" fingerprint | awk '$1 == "tacplus-build" { print $2 }'
}
edit_tree() { # FILE SED-EXPR -> build.sh's fingerprint after editing a copy of the tree's FILE
  local tree=$work/tree2; rm -rf "$tree"; cp -R "$work/tree" "$tree"
  sed -i.bak "$2" "$tree/images/$1" && rm -f "$tree/images/$1.bak"
  env PATH="$work/bin:$PATH" STUB_LOG=/dev/null "$tree/images/build.sh" fingerprint 2>&1 |
    awk '$1 == "tacplus-build" { print $2 }'
}
fp_build=$(build_fp)
[[ "$fp_build" =~ ^[0-9a-f]{12}$ ]] && echo "ok   fingerprint prints the build image's" ||
  { echo "FAIL fingerprint prints no build image fingerprint: [$fp_build]"; failures=$((failures + 1)); }
check "the build image fingerprint is stable" "$(build_fp)" "$fp_build"
for change in "tacplus-build.Dockerfile|\$a # changed" "tacplus-build.cloudbuild.yaml|\$a # changed" \
              "pins.yaml|s/^launcher_commit: .*/launcher_commit: 0000000000000000000000000000000000000000/" \
              "pins.yaml|s/^tacplus_commit: .*/tacplus_commit: 0000000000000000000000000000000000000000/"; do
  fp=$(edit_tree "${change%%|*}" "${change#*|}")
  [ -n "$fp" ] && [ "$fp" != "$fp_build" ] && echo "ok   ${change%%|*} (${change#*|}) changes the build image fingerprint" ||
    { echo "FAIL ${change%%|*} (${change#*|}) leaves the build image fingerprint [$fp]"; failures=$((failures + 1)); }
done
fp_kernel=$(platforms_run "platforms: [arm64]" fingerprint | awk '$1 == "kernel" { print $2 }')
check "a platforms change leaves the build image fingerprint" \
  "$(platforms_run "platforms: [arm64, amd64]" fingerprint | awk '$1 == "tacplus-build" { print $2 }')" "$fp_build"

submits() { grep '^builds submit ' "$work/log" | sed -n 's/.*--config [^ ]*\/\([^ /]*\.cloudbuild\.yaml\).*/\1/p' | uniq | xargs; }
for cmd in changed all kernel; do
  platforms_run "platforms: [arm64]" "$cmd" > /dev/null
  check "$cmd, no build image with its fingerprint: it is built first" \
    "$(submits)" "tacplus.cloudbuild.yaml tacplus-build.cloudbuild.yaml service.cloudbuild.yaml"
  check "$cmd: the build image is tagged by its fingerprint" \
    "$(grep -m1 'tacplus-build.cloudbuild.yaml' "$work/log" | tr ',' '\n' | sed -n 's/^.*_FINGERPRINT=//p' | cut -d' ' -f1)" "$fp_build"
  check "$cmd: services run in the fingerprint's build image" \
    "$(grep 'service.cloudbuild.yaml' "$work/log" | tr ',' '\n' | sed -n 's/^_TACPLUS_IMAGE=//p' | cut -d' ' -f1 | sort -u)" \
    "us-central1-docker.pkg.dev/tacplus-dev/seatrials/ci/tacplus-build:fp-$fp_build"
done
STUB_BUILD_TAGS="seatrials fp-$fp_build" platforms_run "platforms: [arm64]" changed > /dev/null
check "changed, the build image built: it is reused" "$(submits)" "service.cloudbuild.yaml"
STUB_BUILD_TAGS="seatrials fp-$fp_build" platforms_run "platforms: [arm64]" fingerprint > /dev/null
check "fingerprint builds nothing" "$(submits)" ""

# Every FROM of the build image is pinned by digest (Jody, #57): BUILD_IMAGE's
# default in the Dockerfile, and TACPLUS_IMAGE, the tacplus image build.sh has
# just built, which it passes by the digest the registry gives its tag, so a
# rebuild of the same commit under the same tag never changes what it layers.
check "the Dockerfile's BUILD_IMAGE is pinned by digest" \
  "$(sed -n 's/^ARG BUILD_IMAGE=[^@]*@\(sha256:[0-9a-f]\{64\}\)$/pinned/p' "$here/tacplus-build.Dockerfile")" pinned
check "the Dockerfile's FROMs are its ARGs" \
  "$(sed -n 's/^FROM \([^ ]*\).*/\1/p' "$here/tacplus-build.Dockerfile" | sort -u | xargs)" '${BUILD_IMAGE} ${TACPLUS_IMAGE}'
check "the build image is given TACPLUS_IMAGE as _TACPLUS_IMAGE" \
  "$(grep -c -- '--build-arg=TACPLUS_IMAGE=${_TACPLUS_IMAGE}$' "$here/tacplus-build.cloudbuild.yaml")" 1
platforms_run "platforms: [arm64]" tacplus > /dev/null
check "tacplus: the build image layers the tacplus image by digest" \
  "$(grep -m1 'tacplus-build.cloudbuild.yaml' "$work/log" | tr ',' '\n' | sed -n 's/^_TACPLUS_IMAGE=//p' | cut -d' ' -f1)" \
  "us-central1-docker.pkg.dev/tacplus-dev/seatrials/ci/tacplus:$(sed -n 's/^tacplus_commit: *//p' "$here/pins.yaml")@sha256:$(printf '%064d' 7)"
out=$(STUB_NO_DIGEST=1 platforms_run "platforms: [arm64]" tacplus) &&
  { echo "FAIL tacplus, no digest for the tacplus image: passed [$out]"; failures=$((failures + 1)); } ||
  check "tacplus, no digest for the tacplus image: it fails before the build image" "$(submits)" "tacplus.cloudbuild.yaml"
check "fingerprint says the build image is built" \
  "$(STUB_BUILD_TAGS="fp-$fp_build" platforms_run "platforms: [arm64]" fingerprint | awk '$1 == "tacplus-build" { print $3 }')" built
check "the service fingerprint is unchanged by the build image" "$fp_kernel" "$fp_arm64"

# A new build image is proven on every language it builds (#56): when `changed`
# has just built the build image, it also builds the first service of each
# language in fleet.lock that it would otherwise leave alone, so the images job
# fails on a build image that cannot build a Go, Rust or Java service, instead
# of the next change to one. Once the build image is in the registry it does not.
built_services() { grep '^builds submit .*service.cloudbuild.yaml' "$work/log" | tr ',' '\n' | sed -n 's/^_SERVICE=//p' | xargs; }
service_tags() { # [SKIP] -> the fp- tag of every service but SKIP
  platforms_run "platforms: [arm64]" fingerprint | awk -v skip="${1:-}" '$1 != "tacplus-build" && $1 != skip { printf "fp-%s ", $2 }'
}
STUB_SERVICE_TAGS=$(service_tags) platforms_run "platforms: [arm64]" changed > /dev/null
check "changed, a new build image, nothing else: the first service of each language is built in it" \
  "$(submits) / $(built_services)" "tacplus.cloudbuild.yaml tacplus-build.cloudbuild.yaml service.cloudbuild.yaml / kernel opa gateway"
STUB_SERVICE_TAGS=$(service_tags llmproxy) platforms_run "platforms: [arm64]" changed > /dev/null
check "changed, a new build image and a changed Rust service: it stands for Rust" \
  "$(built_services)" "llmproxy kernel opa"
tags=$(service_tags)
STUB_BUILD_TAGS="fp-$fp_build" STUB_SERVICE_TAGS=$tags platforms_run "platforms: [arm64]" changed > /dev/null
check "changed, the build image and every service built: nothing is built" "$(submits)" ""
out=$(STUB_SERVICE_TAGS=$(service_tags) platforms_run "platforms: [arm64]" changed)
[[ "$out" == *"kernel (java): the build image is new"* ]] && echo "ok   a service built for its language says so" ||
  { echo "FAIL a service built for its language does not say so: [$out]"; failures=$((failures + 1)); }
for cmd in all gateway; do
  STUB_SERVICE_TAGS=$(service_tags) platforms_run "platforms: [arm64]" "$cmd" > /dev/null
  check "$cmd, a new build image: the services asked for, once each" "$(built_services | wc -w | tr -d ' ')" \
    "$([ "$cmd" = all ] && echo "$services" || echo 1)"
done

# The build image's steps run unprivileged (#56; Trivy DS-0002): its last USER
# is the base image's build (uid 1000), and a service build's first step, as
# root, hands it the root-owned /workspace and /builder/home it writes.
check "the build image's last USER" "$(sed -n 's/^USER //p' "$here/tacplus-build.Dockerfile" | tail -1)" build
check "a service build's first step hands /workspace and \$HOME to it" \
  "$(awk '/^steps:/ { s = 1 } s && /^  - id: / { n++ } s && n == 1 && /^    (name|entrypoint|args):/' "$here/service.cloudbuild.yaml" | xargs)" \
  'name: gcr.io/cloud-builders/docker entrypoint: chown args: [-R, 1000:1000, /workspace, /builder/home]'

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
