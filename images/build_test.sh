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
  *"rev-parse"*) echo 0123456789ab; exit ;;
esac
echo "git $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
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
  "builds submit "*)
    for a in "$@"; do case "$a" in --substitutions=*|_REGISTRY=*) s=$a ;; esac; done
    svc=${s#*_SERVICE=}; svc=${svc%%,*}; echo "build-$svc" ;;
  "builds describe "*)
    id=$3; [ "$id" = "build-${STUB_FAIL:-none}" ] && echo FAILURE || echo SUCCESS ;;
  # A build's log: 100 numbered lines, or refused when STUB_LOG_DENIED is set.
  "builds log "*)
    [ -z "${STUB_LOG_DENIED:-}" ] || { echo "ERROR: (gcloud.builds.log) 403 storage.objects.get denied" >&2; exit 1; }
    for i in $(seq 1 100); do echo "$3 log line $i"; done ;;
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
: > "$work/log"
out=$(env PATH="$work/bin:$PATH" STUB_LOG="$work/log" WAIT_INTERVAL=0 WAIT=1 STUB_FAIL=gateway "$here/build.sh" changed 2>&1)
[[ "$out" == *gateway*FAILURE* ]] && echo "ok   the failed build is named" ||
  { echo "FAIL the failed build is not named: [$out]"; failures=$((failures + 1)); }

# A failed build's cause is in the job's trace (#67): the last 80 lines of its
# log, each under the service's name, and no log of a build that succeeded. A
# log the account cannot read says so and still fails the run on the build.
check "the failed build's log is read, it alone" "$(grep '^builds log' "$work/log" | xargs)" "builds log build-gateway"
check "its last 80 lines, under the service's name" \
  "$(grep -c '^gateway| build-gateway log line ' <<<"$out") $(grep '^gateway| ' <<<"$out" | sed -n '1p;$p' | xargs)" \
  "80 gateway| build-gateway log line 21 gateway| build-gateway log line 100"
out=$(env PATH="$work/bin:$PATH" STUB_LOG="$work/log" WAIT_INTERVAL=0 WAIT=1 STUB_FAIL=gateway STUB_LOG_DENIED=1 "$here/build.sh" changed 2>&1)
status=$?
[ "$status" -ne 0 ] && [[ "$out" == *"gateway| "*"403 storage.objects.get denied"* ]] &&
  [[ "$out" == *"image builds failed"* ]] && echo "ok   an unreadable log says why, and the run still fails" ||
  { echo "FAIL an unreadable log: status $status [$out]"; failures=$((failures + 1)); }

# The platforms setting in images/pins.yaml: each build is told which platforms
# to build (_PLATFORMS, sorted), and the fingerprint covers them, so an
# arm64-only image is never taken for a multi-arch one. Run against a copy of
# the tree whose pins.yaml says PLATFORMS_LINE.
platforms_run() { # PLATFORMS_LINE ARGS... -> build.sh's output; the gcloud calls in $work/log
  local tree=$work/tree; rm -rf "$tree"
  mkdir -p "$tree/images" "$tree/build/proto"
  cp "$here/build.sh" "$here/service.cloudbuild.yaml" \
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
platforms_run "platforms: [arm64]" build-image > /dev/null
check "build-image: the build image alone submitted" "$(grep -c '^builds submit ' "$work/log")" 1
staging_checked "build-image"
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
    "$(submits)" "tacplus-build.cloudbuild.yaml service.cloudbuild.yaml"
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

# Every FROM of the build image is pinned by digest (Jody, #57): it has one,
# BUILD_IMAGE, whose default the Dockerfile pins.
check "the Dockerfile's BUILD_IMAGE is pinned by digest" \
  "$(sed -n 's/^ARG BUILD_IMAGE=[^@]*@\(sha256:[0-9a-f]\{64\}\)$/pinned/p' "$here/tacplus-build.Dockerfile")" pinned
# Its toolchains are of the fleet's tacplus line, fleet.yaml's floor, under which
# the pinned compiler is (#15): a floor move that leaves BUILD_IMAGE on the old
# line pairs the new compiler with the old line's toolchains. A release's patch
# names its line; a line's dated rebuild, <YYYYMMDD>-<tacplus commit> (#64),
# names a commit, which must be the pinned compiler's, of that line too.
# build_image_line TAG: the line TAG is of, or why it is of none.
build_image_line() {
  local commit
  if [[ "$1" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$1" =~ ^[0-9]{8}-([0-9a-f]{7,40})$ ]]; then
    commit=$(sed -n 's/^tacplus_commit: *//p' "$here/pins.yaml")
    [[ "$commit" == "${BASH_REMATCH[1]}"* ]] && fleet_line || echo "rebuild of ${BASH_REMATCH[1]}, not tacplus_commit $commit"
  else
    echo "tag $1, neither a patch nor a dated rebuild"
  fi
}
fleet_line() { sed -n 's/^tacplus: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$here/../fleet.yaml"; }
check "the Dockerfile's BUILD_IMAGE is of fleet.yaml's tacplus line" \
  "$(build_image_line "$(sed -n 's/^ARG BUILD_IMAGE=ghcr\.io\/tacplus-dev\/tacplus\/build:\([^@]*\)@.*/\1/p' "$here/tacplus-build.Dockerfile")")" \
  "$(fleet_line)"
check "the Dockerfile's FROMs are BUILD_IMAGE" \
  "$(sed -n 's/^FROM \([^ ]*\).*/\1/p' "$here/tacplus-build.Dockerfile" | sort -u | xargs)" '${BUILD_IMAGE}'

# There is no tacplus image since tacplus 2.4 (tacplus-dev/tacplus#193; #65):
# its build image runs the release a repository pins, and the fleet pins a
# commit. The build image builds the fleet's tacplus itself, from tacplus's
# source at tacplus_commit, which build.sh clones beside the Dockerfile as it
# does the launcher's, stamped as ci/tools.sh stamps bin/tacplus.
pinned=$(sed -n 's/^tacplus_commit: *//p' "$here/pins.yaml")
platforms_run "platforms: [arm64]" build-image > /dev/null
check "build-image: tacplus is cloned beside the Dockerfile, at tacplus_commit" \
  "$(grep -c "^git clone -q https://github.com/tacplus-dev/tacplus.git $work/tree/images/tacplus$" "$work/log") $(grep -c "^git -C $work/tree/images/tacplus checkout -q $pinned$" "$work/log")" "1 1"
check "build-image: the clone is gone after the submit" "$([ -e "$work/tree/images/tacplus" ] && echo left || echo gone)" gone
check "build-image: the build image is given the pinned commit" \
  "$(grep -m1 'tacplus-build.cloudbuild.yaml' "$work/log" | tr ',' '\n' | sed -n 's/^_TACPLUS_COMMIT=//p' | cut -d' ' -f1)" "$pinned"
check "build-image: no tacplus image is built or asked for" "$(grep -c 'tacplus\.cloudbuild\.yaml\|ci/tacplus:' "$work/log")" 0
check "the build image builds tacplus from that source, stamped" \
  "$(grep -c -- '-X $pkg.Version=${TACPLUS_VERSION} -X $pkg.GitSha=${TACPLUS_COMMIT}' "$here/tacplus-build.Dockerfile") $(grep -c '^COPY tacplus/ ' "$here/tacplus-build.Dockerfile")" "1 1"
check "its stamp is ci/tools.sh's" \
  "$(sed -n 's/.*--build-arg=TACPLUS_VERSION=\(v[0-9.]*-seatrials\)$/\1/p' "$here/tacplus-build.cloudbuild.yaml")" \
  "$(grep -o 'Version=v[0-9.]*-seatrials' "$here/../ci/tools.sh" | cut -d= -f2)"
check "its commit is _TACPLUS_COMMIT" \
  "$(grep -c -- '--build-arg=TACPLUS_COMMIT=${_TACPLUS_COMMIT}$' "$here/tacplus-build.cloudbuild.yaml")" 1
out=$(platforms_run "platforms: [arm64]" tacplus) &&
  { echo "FAIL tacplus, the target there is no image for: passed [$out]"; failures=$((failures + 1)); } ||
  { [[ "$out" == *build-image* ]] && [ ! -s "$work/log" ] && echo "ok   tacplus is refused, naming build-image, nothing submitted" ||
    { echo "FAIL tacplus: [$out] [$(cat "$work/log")]"; failures=$((failures + 1)); }; }
for f in tacplus.cloudbuild.yaml tacplus.Dockerfile; do
  check "images/$f is gone" "$([ -e "$here/$f" ] && echo present || echo gone)" gone
done
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
  "$(submits) / $(built_services)" "tacplus-build.cloudbuild.yaml service.cloudbuild.yaml / kernel opa gateway"
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
# is build (uid 1000), which it creates itself (the base image has no user but
# Debian's own), and a service build's first step, as root, hands it the
# root-owned /workspace and /builder/home it writes.
check "the build image's last USER" "$(sed -n 's/^USER //p' "$here/tacplus-build.Dockerfile" | tail -1)" build
check "the build image creates build, uid and gid 1000, before its USER" \
  "$(sed -n '/^RUN groupadd /,/^USER /p' "$here/tacplus-build.Dockerfile" | grep -v '^#' | xargs)" \
  'RUN groupadd --gid 1000 build && useradd --uid 1000 --gid 1000 --create-home build USER build'
check "a service build's first step hands /workspace and \$HOME to it" \
  "$(awk '/^steps:/ { s = 1 } s && /^  - id: / { n++ } s && n == 1 && /^    (name|entrypoint|args):/' "$here/service.cloudbuild.yaml" | xargs)" \
  'name: gcr.io/cloud-builders/docker entrypoint: chown args: [-R, 1000:1000, /workspace, /builder/home]'

# A service's Dockerfile builds as it does in its own CI (#69): not on the
# BuildKit of Cloud Build's docker daemon, whose old dockerfile frontend cannot
# parse coop's ADD --checksum, but in a builder of the fleet's own, a pinned
# moby/buildkit (and the dockerfile frontend it carries) in a container on
# Cloud Build's network, which every platform's build uses.
image_step=$(awk '/^  - id: image$/ { s = 1; next } s && /^  - id: / { s = 0 } s' "$here/service.cloudbuild.yaml")
check "_BUILDKIT is moby/buildkit, pinned by digest" \
  "$(sed -n 's/^  _BUILDKIT: docker\.io\/moby\/buildkit:v[0-9.]*@\(sha256:[0-9a-f]\{64\}\)$/pinned/p' "$here/service.cloudbuild.yaml")" pinned
check "the image step creates its builder from _BUILDKIT, on Cloud Build's network" \
  "$(grep -c -- 'docker buildx create --name fleet --driver docker-container --driver-opt image=${_BUILDKIT} --driver-opt network=cloudbuild --bootstrap' <<<"$image_step")" 1
check "every buildx build runs in that builder" \
  "$(grep -c 'docker buildx build ' <<<"$image_step") $(grep -c 'docker buildx build --builder fleet ' <<<"$image_step")" "1 1"

# A registry's transient 5xx or 429 on a push is retried with backoff (#74):
# one 502 on eventbus's :local manifest PUT failed a whole deploy. The image
# step's script runs here as Cloud Build would run it, its substitutions made,
# against a stub docker whose pushes (STUB_PUSH_FAIL: push, index or both) fail
# STUB_PUSH_FAILS times with STUB_PUSH_ERROR first, and a sleep that only logs.
step_script=$(awk '/^      - \|$/ { s = 1; next } /^[^ ]/ { s = 0 } s' <<<"$image_step" | sed 's/^        //' |
  sed -e 's/\${_REGISTRY}/registry.test/g' -e 's/\${_SERVICE}/eventbus/g' -e 's/\${_LANG}/go/g' \
      -e 's/\${_PLATFORMS}/arm64/g' -e 's/\${_FINGERPRINT}/85ceb8d1fb7a/g' -e 's/\${_FLEET_COMMIT}/e0dded1980b0/g' \
      -e 's/\${_COMMIT}/0123456789ab/g' -e 's/\${_BINFMT}/binfmt.test/g' -e 's/\${_BUILDKIT}/buildkit.test/g' \
      -e 's/\$\$/$/g')
mkdir -p "$work/push/bin"
cat > "$work/push/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
fail() { # KIND -> fails this call, STUB_PUSH_FAILS times per KIND
  case " ${STUB_PUSH_FAIL:-} " in *" $1 "*) ;; *) return 0 ;; esac
  n=$(grep -c "^failed $1$" "$STUB_LOG")
  [ "$n" -lt "${STUB_PUSH_FAILS:-1}" ] || return 0
  echo "failed $1" >> "$STUB_LOG"
  echo "ERROR: failed commit on ref \"index-sha256:e51f362e\": unexpected status from PUT request to https://registry.test/v2/manifests/local: ${STUB_PUSH_ERROR:-502 Bad Gateway}" >&2
  exit 1
}
case "$*" in
  "version "*) echo arm64 ;;
  "image inspect "*) echo linux/arm64 ;;
  "push "*) fail push; echo "pushed $2" ;;
  "buildx imagetools create "*) fail index ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "sleep $*" >> "$STUB_LOG"\n' > "$work/push/bin/sleep"
chmod +x "$work/push/bin/"*
mkdir -p "$work/push/src/.fleet/out/arm64" && : > "$work/push/src/.fleet/out/arm64/eventbus"
push_run() { # VAR=VALUE... -> the image step's status; its docker and sleep calls in $work/log
  : > "$work/log"
  (cd "$work/push/src" && env PATH="$work/push/bin:$PATH" STUB_LOG="$work/log" "$@" bash -ceu "$step_script" > "$work/push/out" 2>&1)
}
pushes() { grep -c "^docker $1" "$work/log"; }
push_run; check "image step, no failure: one push, one index, no sleep" \
  "$(pushes push) $(pushes 'buildx imagetools create') $(grep -c '^sleep' "$work/log")" "1 1 0"
push_run STUB_PUSH_FAIL=index &&
  check "the :local index PUT fails once with 502, then succeeds" \
    "$(pushes 'buildx imagetools create') $(grep -c '^sleep' "$work/log")" "2 1" ||
  { echo "FAIL a 502 on the index fails the step: [$(cat "$work/push/out")]"; failures=$((failures + 1)); }
push_run STUB_PUSH_FAIL=push STUB_PUSH_ERROR="429 Too Many Requests" &&
  check "a platform push fails once with 429, then succeeds" "$(pushes push)" 2 ||
  { echo "FAIL a 429 on a push fails the step: [$(cat "$work/push/out")]"; failures=$((failures + 1)); }
push_run STUB_PUSH_FAIL="push index" STUB_PUSH_ERROR="503 Service Unavailable" STUB_PUSH_FAILS=2 &&
  check "each push retried on its own, with a growing backoff" \
    "$(pushes push) $(pushes 'buildx imagetools create') $(grep '^sleep' "$work/log" | xargs)" "3 3 sleep 5 sleep 10 sleep 5 sleep 10" ||
  { echo "FAIL two 503s fail the step: [$(cat "$work/push/out")]"; failures=$((failures + 1)); }
push_run STUB_PUSH_FAIL=index STUB_PUSH_FAILS=9 &&
  { echo "FAIL a registry that keeps failing passes the step"; failures=$((failures + 1)); } ||
  check "a registry that keeps failing fails the step after 4 attempts" "$(pushes 'buildx imagetools create')" 4
push_run STUB_PUSH_FAIL=index STUB_PUSH_ERROR="401 Unauthorized" &&
  { echo "FAIL a 401 passes the step"; failures=$((failures + 1)); } ||
  check "a 4xx but 429 is not retried" "$(pushes 'buildx imagetools create') $(grep -c '^sleep' "$work/log")" "1 0"
check "and its error is in the step's log" "$(grep -c '401 Unauthorized' "$work/push/out")" 1

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
