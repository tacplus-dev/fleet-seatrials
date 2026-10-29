#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Builds the fleet's images on Cloud Build, one per service in fleet.lock, from
# the exact commits the lock names, against this checkout's build/proto.
#
#   images/build.sh tacplus            # the tacplus image (once per tacplus commit)
#   images/build.sh all                # every service in fleet.lock
#   images/build.sh kernel gateway     # some services
#   images/build.sh changed            # only the services whose fingerprint has no image yet
#   images/build.sh fingerprint        # print each service's fingerprint and whether it is built
#   WAIT=1 images/build.sh changed     # and wait for every build submitted; fail if one fails
#
# Service builds are submitted asynchronously and run in parallel. With WAIT=1
# (the deploy pipeline's images stage) the script then waits for each one and
# fails, naming the service, unless every one succeeds, so nothing deploys
# against an image that does not exist.
#
# Each image is built for the platforms in images/pins.yaml (`platforms:
# [arm64]`; `[arm64, amd64]` builds both): one image per platform, tagged
# fp-<hash>-<arch>, and the tags below name one multi-arch index over them.
# A service's image depends on its own repo and on everything it generates
# from. The compiler says what that is: `tacplus fleet build` writes each
# service's inputs_digest into fleet.lock, a hash over the descriptors of the
# service's scope (its contract, its `depends` and what they reach, the sys
# protos; the whole tree for grpc-servers/grpc-clients/states: all). Its
# FINGERPRINT is the hash of the compiler's MAJOR.MINOR, its own commit, that
# digest and the platforms it is built for (Jody, 2026-10-25: "Tacplus should
# tell us so we can skip rebuilds when they are not necessary"). A dependency's commit that changes
# no descriptor in the scope leaves it alone. The image carries it as the tag
# fp-<hash>; `changed` builds a service only when the registry has no image
# with its current fingerprint.
#
# Each service's repo is cloned here at the locked commit and submitted as the
# build source, with build/proto copied in at .fleet/proto; Cloud Build clones
# nothing (the repos are private). Images land at
#   <registry>/schematic/<service>:<fleet commit>  and  :local  and  :fp-<hash>
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
registry=${REGISTRY:-us-central1-docker.pkg.dev/jody1-328023/seabeam}
tacplus_repo=https://github.com/tacplus-dev/tacplus.git
tacplus_commit=$(sed -n 's/^tacplus_commit: *//p' "$here/images/pins.yaml")
fleet_commit=$(git -C "$here" rev-parse --short=12 HEAD)
# platforms: [arm64, amd64] -> "amd64 arm64", sorted, so the order in pins.yaml
# changes neither the build nor its fingerprint.
platforms=$(sed -n 's/^platforms: *\[\(.*\)\] *$/\1/p' "$here/images/pins.yaml" | tr ', ' '\n\n' | sed '/^$/d' | sort -u | xargs)
for p in $platforms; do
  case "$p" in amd64|arm64) ;; *) echo "images/pins.yaml: unknown platform $p (amd64, arm64)" >&2; exit 1 ;; esac
done
[ -n "$platforms" ] || { echo "images/pins.yaml: platforms is missing or empty: e.g. platforms: [arm64]" >&2; exit 1; }
[ -d "$here/build/proto" ] || { echo "build/proto missing: run tacplus fleet build first" >&2; exit 1; }

lock_field() { # service field -> value, from fleet.lock's flat per-service block
  awk -v svc="$1" -v field="$2" '
    /^    - name: / { cur = $3 }
    cur == svc && $1 == field":" { print $2; exit }
  ' "$here/fleet.lock"
}
services() { awk '/^    - name: / { printf "%s ", $3 }' "$here/fleet.lock"; }

# fingerprint SERVICE -> sha256 (12 hex) over the compiler MAJOR.MINOR, the
# service's own commit, its inputs_digest and the platforms, one per line.
fingerprint() {
  local minor digest
  minor=$(sed -n 's/^tacplus: *"\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p' "$here/fleet.lock")
  digest=$(lock_field "$1" inputs_digest)
  [ -n "$digest" ] || { echo "fleet.lock has no inputs_digest for $1: rerun tacplus fleet build" >&2; exit 1; }
  printf 'tacplus %s\nself %s\ninputs %s\nplatforms %s\n' "$minor" "$(lock_field "$1" commit)" "$digest" "$platforms" | shasum -a 256 | cut -c1-12
}

# built SERVICE FINGERPRINT -> 0 when the registry already holds an image built
# from exactly these inputs.
built() {
  gcloud artifacts docker tags list "$registry/schematic/$1" --format 'value(tag)' 2>/dev/null | grep -qx "fp-$2"
}

build_tacplus() {
  local src; src=$(mktemp -d)
  git clone -q "$tacplus_repo" "$src" && git -C "$src" checkout -q "$tacplus_commit"
  gcloud builds submit "$src" --config "$here/images/tacplus.cloudbuild.yaml" \
    --substitutions "_REGISTRY=$registry,_TACPLUS_COMMIT=$tacplus_commit" --quiet
  rm -rf "$src"
  # The build image the service steps run in: toolchains + this tacplus + the
  # Java launcher, built from its pinned source placed beside the Dockerfile.
  local launcher_commit; launcher_commit=$(sed -n 's/^launcher_commit: *//p' "$here/images/pins.yaml")
  rm -rf "$here/images/launcher" && git clone -q https://github.com/tacplus-dev/launcher.git "$here/images/launcher" \
    && git -C "$here/images/launcher" checkout -q "$launcher_commit" && rm -rf "$here/images/launcher/.git"
  gcloud builds submit "$here/images" --config "$here/images/tacplus-build.cloudbuild.yaml" \
    --substitutions "_REGISTRY=$registry,_TACPLUS_COMMIT=$tacplus_commit" --quiet
  rm -rf "$here/images/launcher"
}

# language and go main package, read from the service checkout itself.
service_facts() { # dir name -> "lang main"
  local dir=$1 lang main="."
  lang=$(sed -n 's/^language: *//p' "$dir/tacplus.yaml")
  if [ "$lang" = go ] && [ -d "$dir/cmd/$2" ]; then main="./cmd/$2"; fi
  echo "$lang $main"
}

build_service() {
  local name=$1 repo commit src
  repo=$(lock_field "$name" repo); commit=$(lock_field "$name" commit)
  src=$(mktemp -d)
  git clone -q "$repo" "$src" && git -C "$src" checkout -q "$commit"
  mkdir -p "$src/.fleet" && cp -R "$here/build/proto" "$src/.fleet/proto"
  read -r lang main <<<"$(service_facts "$src" "$name")"
  echo "== $name ($lang) @ ${commit:0:12}"
  local fp; fp=$(fingerprint "$name")
  local id
  id=$(gcloud builds submit "$src" --config "$here/images/service.cloudbuild.yaml" --async --quiet --format 'value(id)' \
    --substitutions "_REGISTRY=$registry,_SERVICE=$name,_LANG=$lang,_MAIN=$main,_COMMIT=$commit,_FLEET_COMMIT=$fleet_commit,_FINGERPRINT=$fp,_PLATFORMS=$platforms,_TACPLUS_IMAGE=$registry/ci/tacplus-build:$tacplus_commit")
  echo "$id"
  echo "$name $id" >> "$submitted"
  rm -rf "$src"
}

# wait_builds: with WAIT=1, waits for every build submitted by this run; fails
# unless all succeed.
wait_builds() {
  [ "${WAIT:-}" = 1 ] && [ -s "$submitted" ] || return 0
  local name id status failed=0
  while read -r name id; do
    while :; do
      status=$(gcloud builds describe "$id" --format 'value(status)')
      case "$status" in QUEUED|PENDING|WORKING|"") sleep "${WAIT_INTERVAL:-30}" ;; *) break ;; esac
    done
    echo "== $name: $status ($id)"
    [ "$status" = SUCCESS ] || failed=1
  done < "$submitted"
  [ "$failed" = 0 ] || { echo "image builds failed: see the builds above in Cloud Build" >&2; exit 1; }
}
submitted=$(mktemp)
trap 'rm -f "$submitted"' EXIT

case "${1:-}" in
  tacplus) build_tacplus ;;
  all) for s in $(services); do build_service "$s"; done ;;
  fingerprint)
    for s in $(services); do
      fp=$(fingerprint "$s")
      if built "$s" "$fp"; then echo "$s $fp built"; else echo "$s $fp NEEDS BUILD"; fi
    done ;;
  changed)
    for s in $(services); do
      fp=$(fingerprint "$s")
      if built "$s" "$fp"; then echo "== $s unchanged ($fp)"; else build_service "$s"; fi
    done ;;
  "") echo "usage: images/build.sh tacplus | all | changed | fingerprint | <service>..." >&2; exit 2 ;;
  *) for s in "$@"; do build_service "$s"; done ;;
esac
wait_builds
