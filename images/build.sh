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
#
# Each service's repo is cloned here at the locked commit and submitted as the
# build source, with build/proto copied in at .fleet/proto; Cloud Build clones
# nothing (the repos are private). Images land at
#   <registry>/schematic/<service>:<fleet commit>  and  :local
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
registry=${REGISTRY:-us-central1-docker.pkg.dev/jody1-328023/seabeam}
tacplus_repo=https://github.com/tacplus-dev/tacplus.git
tacplus_commit=$(sed -n 's/^tacplus_commit: *//p' "$here/images/pins.yaml")
fleet_commit=$(git -C "$here" rev-parse --short=12 HEAD)
[ -d "$here/build/proto" ] || { echo "build/proto missing: run tacplus fleet build first" >&2; exit 1; }

lock_field() { # service field -> value, from fleet.lock's flat per-service block
  awk -v svc="$1" -v field="$2" '
    /^    - name: / { cur = $3 }
    cur == svc && $1 == field":" { print $2; exit }
  ' "$here/fleet.lock"
}
services() { awk '/^    - name: / { printf "%s ", $3 }' "$here/fleet.lock"; }

build_tacplus() {
  local src; src=$(mktemp -d)
  git clone -q "$tacplus_repo" "$src" && git -C "$src" checkout -q "$tacplus_commit"
  gcloud builds submit "$src" --config "$here/images/tacplus.cloudbuild.yaml" \
    --substitutions "_REGISTRY=$registry,_TACPLUS_COMMIT=$tacplus_commit" --quiet
  rm -rf "$src"
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
  gcloud builds submit "$src" --config "$here/images/service.cloudbuild.yaml" --async --quiet \
    --substitutions "_REGISTRY=$registry,_SERVICE=$name,_LANG=$lang,_MAIN=$main,_COMMIT=$commit,_FLEET_COMMIT=$fleet_commit,_TACPLUS_IMAGE=$registry/ci/tacplus:$tacplus_commit"
  rm -rf "$src"
}

case "${1:-}" in
  tacplus) build_tacplus ;;
  all) for s in $(services); do build_service "$s"; done ;;
  "") echo "usage: images/build.sh tacplus | all | <service>..." >&2; exit 2 ;;
  *) for s in "$@"; do build_service "$s"; done ;;
esac
